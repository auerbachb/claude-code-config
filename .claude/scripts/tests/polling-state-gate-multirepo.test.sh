#!/usr/bin/env bash
# Regression test: polling-state-gate.sh must not refuse a valid checkout
# catalog: tests — Tests multi-repo isolation in `polling-state-gate.sh`
# because a DIFFERENT repo wrote session-state last (issue #638).
#
# The bug: `.root_repo` was one global scalar for the whole state file, and the
# gate compared it against `git rev-parse --show-toplevel` of the active
# checkout. Any second repo with a live session overwrote that scalar, so the
# next poll in the first repo hit
#   "session-state .root_repo (...) does not match active root (...) —
#    refuse to poll from wrong checkout"
# even though the session was in exactly the right place. It was worked around
# by hand rather than fixed.
#
# A second, subtler false positive: `--show-toplevel` returns the WORKTREE
# path, so polling from a sibling worktree of the SAME repo also refused.
#
# Both are false POSITIVES of a check whose real question is "does this state
# belong to the repo I am in?" — now answered by repo identity, not by path.
#
# Issue #854 closed the last hole in that answer: scope resolution still SEARCHED
# every repo and fell back to an arbitrary other one, so a PR number another repo
# happened to use made the gate refuse (even under --ensure-session, which is
# supposed to create the missing registration) and, when it did not refuse, read
# the other repo's owner_repo and handoff path. The later sections here pin the
# collision case, --repo / $CLAUDE_SESSION_REPO scope selection, and the
# invariant that no refusal ever exits 0.
#
# Issue #967 covers the residual ambient-scope leak: a stale inherited
# $CLAUDE_SESSION_REPO used to outrank the live checkout origin. The invoking
# checkout now wins when it can identify itself; the environment remains a
# supply-only fallback for origin-less checkouts.
#
# Uses --verify-state, the offline mode (no gh, no merge-gate), so the test is
# hermetic. Temporary HOME; never touches the real ~/.claude/. Requires git+jq.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/polling-state-gate-fixtures.sh
source "$TEST_DIR/lib/polling-state-gate-fixtures.sh"
GATE="$REPO_ROOT/.claude/scripts/polling-state-gate.sh"
STATE_SH="$REPO_ROOT/.claude/scripts/session-state.sh"

TMP_HOME="$(mktemp -d)"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME" "$WORK"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude/handoffs"

PASS=0
FAIL=0
check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected '$expected', got '$actual')"
  fi
}

# mk_repo and write_handoff are provided by lib/polling-state-gate-fixtures.sh.
# write_handoff signature: write_handoff <owner_repo_or_empty> <pr_number> <head_sha>

REPO_A="$WORK/a"; mk_repo "$REPO_A" "https://github.com/org/a.git"
REPO_B="$WORK/b"; mk_repo "$REPO_B" "https://github.com/org/b.git"

# Both repos track a PR #84 — the collision case from the issue.
( cd "$REPO_A" && "$STATE_SH" --set '.prs["84"].root_repo='"$REPO_A" \
                              --set '.prs["84"].head_sha=aaa1111' \
                              --set '.prs["84"].owner_repo=org/a' >/dev/null )
# Repo B registers second, so under the old layout B is the "last writer" that
# would poison the global .root_repo for A.
( cd "$REPO_B" && "$STATE_SH" --set '.prs["84"].root_repo='"$REPO_B" \
                              --set '.prs["84"].head_sha=bbb2222' \
                              --set '.prs["84"].owner_repo=org/b' >/dev/null )

echo "== State for the same PR number is kept per repo =="
check_eq "repo A keeps its own head_sha" "aaa1111" "$( cd "$REPO_A" && "$STATE_SH" --get '.prs["84"].head_sha')"
check_eq "repo B keeps its own head_sha" "bbb2222" "$( cd "$REPO_B" && "$STATE_SH" --get '.prs["84"].head_sha')"

echo
echo "== No false 'wrong checkout' refusal when another repo wrote last =="
write_handoff "org/a" 84 aaa1111
check_eq "scoped handoff for org/a written to correct path" "1" \
  "$(test -f "$HOME/.claude/handoffs/org/a/pr-84-handoff.json" && echo 1 || echo 0)"
OUT="$( cd "$REPO_A" && bash "$GATE" 84 --verify-state 2>&1 )"; RC=$?
check_eq "polling from repo A is allowed (exit 0)" "0" "$RC"
check_eq "no 'refuse to poll from wrong checkout' message" "0" "$(grep -c 'wrong checkout' <<<"$OUT")"

# And repo B still validates on its own terms, against ITS head_sha.
write_handoff "org/b" 84 bbb2222
check_eq "scoped handoff for org/b written to correct path" "1" \
  "$(test -f "$HOME/.claude/handoffs/org/b/pr-84-handoff.json" && echo 1 || echo 0)"
RC=0; ( cd "$REPO_B" && bash "$GATE" 84 --verify-state >/dev/null 2>&1 ) || RC=$?
check_eq "polling from repo B is allowed too" "0" "$RC"

echo
echo "== A sibling worktree of the same repo is not a wrong checkout =="
WT_A="$WORK/a-worktree"
git -C "$REPO_A" worktree add --quiet -b feature "$WT_A" >/dev/null 2>&1
write_handoff "org/a" 84 aaa1111
OUT="$( cd "$WT_A" && bash "$GATE" 84 --verify-state 2>&1 )"; RC=$?
check_eq "polling from a worktree of repo A is allowed" "0" "$RC"
check_eq "worktree poll emits no wrong-checkout refusal" "0" "$(grep -c 'wrong checkout' <<<"$OUT")"

echo
echo "== A repo that never registered this PR is refused, not answered for =="
# Repo C has no registration for PR 84: the gate must refuse rather than fall
# through to another repo's entry just because the number matches. It must also
# not silently REDIRECT to the owning repo's recorded checkout — the per-PR
# root_repo outranks the live checkout when resolving a root (issue #647), so
# the cross-repo decision is anchored to the checkout the caller is standing in.
#
# Issue #854 changed what this refusal SAYS, not whether it happens. PR numbers
# are per-repo, so "repo A also has an 84" is not a reason to accuse repo C of
# polling the wrong repo — 84 is simply not registered for C, and
# --ensure-session is the remedy. A/B's entries are named as diagnostics only.
REPO_C="$WORK/c"; mk_repo "$REPO_C" "https://github.com/org/c.git"
RC=0; OUT="$( cd "$REPO_C" && bash "$GATE" 84 --verify-state 2>&1 )" || RC=$?
check_eq "poll from an unregistered repo is refused (exit 4)" "4" "$RC"
check_eq "refusal names the active repo" "1" "$(grep -c "not registered in session-state for 'org/c'" <<<"$OUT")"
check_eq "refusal points at --ensure-session" "1" "$(grep -c -- '--ensure-session' <<<"$OUT")"
check_eq "refusal names the colliding repo as a diagnostic" "1" "$(grep -c "also registered under 'org/a'" <<<"$OUT")"
check_eq "and it did not operate on the other repo" "0" "$(grep -c 'gate met' <<<"$OUT")"

echo
echo "== A colliding PR number does not block registering our own (issue #854) =="
# The reported bug: --ensure-session for repo C's PR 84 refused outright because
# repos A and B already tracked an 84. Registration must succeed and must leave
# every other repo's entry byte-identical.
A_BEFORE="$(jq -Sc '.repos["org/a"].prs["84"]' "$HOME/.claude/session-state.json")"
B_BEFORE="$(jq -Sc '.repos["org/b"].prs["84"]' "$HOME/.claude/session-state.json")"
STUB_BIN="$WORK/bin"
write_polling_gh_stub "$STUB_BIN"
RC=0; OUT="$( cd "$REPO_C" && PATH="$STUB_BIN:$PATH" bash "$GATE" 84 --ensure-session 2>&1 )" || RC=$?
check_eq "--ensure-session succeeds despite a colliding PR number" "0" "$RC"
check_eq "…and registers under our own scope" "ccc3333" \
  "$(jq -r '.repos["org/c"].prs["84"].head_sha // ""' "$HOME/.claude/session-state.json")"
check_eq "…and records our own owner_repo" "org/c" \
  "$(jq -r '.repos["org/c"].prs["84"].owner_repo // ""' "$HOME/.claude/session-state.json")"
check_eq "repo A's entry is untouched" "$A_BEFORE" \
  "$(jq -Sc '.repos["org/a"].prs["84"]' "$HOME/.claude/session-state.json")"
check_eq "repo B's entry is untouched" "$B_BEFORE" \
  "$(jq -Sc '.repos["org/b"].prs["84"]' "$HOME/.claude/session-state.json")"

# And a subsequent poll from C reads C's own head_sha, not A's or B's.
write_handoff "org/c" 84 ccc3333
RC=0; OUT="$( cd "$REPO_C" && bash "$GATE" 84 --verify-state 2>&1 )" || RC=$?
check_eq "a later tick from repo C validates against C's own state" "0" "$RC"

echo
echo "== A self-identifying checkout overrides a stale inherited scope (issue #967) =="
# Reproduce the reported persistent-shell leak with the same PR number present
# in both repos. The gate is invoked from repo A without --repo while the
# environment still names repo B. Both registration and verification must use A,
# and B's existing entry must remain byte-identical.
B_BEFORE_STALE_ENV="$(jq -Sc '.repos["org/b"].prs["84"]' "$HOME/.claude/session-state.json")"
write_handoff "org/a" 84 aaa1111
RC=0; OUT="$( cd "$REPO_A" && CLAUDE_SESSION_REPO=org/b STUB_HEAD_SHA=aaa1111 STUB_OWNER_REPO=org/a PATH="$STUB_BIN:$PATH" bash "$GATE" 84 --ensure-session 2>&1 )" || RC=$?
check_eq "stale inherited scope does not block --ensure-session" "0" "$RC"
check_eq "--ensure-session remains scoped to the invoking repo" "org/a" \
  "$(jq -r '.repos["org/a"].prs["84"].owner_repo // ""' "$HOME/.claude/session-state.json")"
check_eq "stale inherited scope does not mutate repo B" "$B_BEFORE_STALE_ENV" \
  "$(jq -Sc '.repos["org/b"].prs["84"]' "$HOME/.claude/session-state.json")"
RC=0; OUT="$( cd "$REPO_A" && CLAUDE_SESSION_REPO=org/b bash "$GATE" 84 --verify-state 2>&1 )" || RC=$?
check_eq "stale inherited scope does not block --verify-state" "0" "$RC"
check_eq "stale inherited scope emits no contradiction refusal" "0" \
  "$(grep -c 'contradicts the checkout being operated on' <<<"$OUT")"

echo
echo "== --repo / \$CLAUDE_SESSION_REPO select the scope (issue #854) =="
# A checkout with no `origin` remote cannot name itself, so before #854 there was
# no way to tell the gate which repo it was standing in. Both mechanisms must
# now reach the same scope.
NOREMOTE="$WORK/noremote"
mkdir -p "$NOREMOTE"
git -C "$NOREMOTE" init --quiet
git -C "$NOREMOTE" -c user.email=t@e -c user.name=T commit --quiet --allow-empty -m init
write_handoff "org/a" 84 aaa1111
RC=0; OUT="$( cd "$NOREMOTE" && bash "$GATE" 84 --verify-state --repo org/a 2>&1 )" || RC=$?
check_eq "--repo selects the named scope from an origin-less checkout" "0" "$RC"
RC=0; OUT="$( cd "$NOREMOTE" && CLAUDE_SESSION_REPO=org/a bash "$GATE" 84 --verify-state 2>&1 )" || RC=$?
check_eq "\$CLAUDE_SESSION_REPO selects the named scope too" "0" "$RC"
# Pin the origin-less checkout itself: the inherited value must remain available
# as identity supply rather than being discarded or replaced with gitdir:/path:.
RC=0; OUT="$( cd "$NOREMOTE" && CLAUDE_SESSION_REPO=org/a bash "$GATE" 84 --verify-state --root-repo "$NOREMOTE" 2>&1 )" || RC=$?
check_eq "inherited scope supplies identity for a pinned origin-less checkout" "0" "$RC"
check_eq "origin-less supply emits no contradiction refusal" "0" \
  "$(grep -c 'contradicts the checkout being operated on' <<<"$OUT")"
# --repo outranks the environment variable.
RC=0; OUT="$( cd "$NOREMOTE" && CLAUDE_SESSION_REPO=org/b bash "$GATE" 84 --verify-state --repo org/a 2>&1 )" || RC=$?
check_eq "--repo outranks \$CLAUDE_SESSION_REPO" "0" "$RC"
# A malformed value is a usage error (exit 2), not a silent "_unknown" fallback.
# The charset must match session-state.sh's is_valid_repo_key() ([A-Za-z0-9._/-]):
# checking slash placement alone let "org/repo name" through to be exported and
# then silently rewritten to "_unknown" by the helper (CodeAnt, PR #856).
RC=0; OUT="$( cd "$REPO_A" && bash "$GATE" 84 --verify-state --repo not-a-repo-key 2>&1 )" || RC=$?
check_eq "malformed --repo is a usage error (exit 2)" "2" "$RC"
RC=0; OUT="$( cd "$REPO_A" && bash "$GATE" 84 --verify-state --repo 2>&1 )" || RC=$?
check_eq "--repo with no value is a usage error (exit 2)" "2" "$RC"
for BAD in 'org/repo name' 'org/repo:x' 'org//repo' 'org/a/b' '/org/repo' 'org/repo!'; do
  RC=0; OUT="$( cd "$REPO_A" && bash "$GATE" 84 --verify-state --repo "$BAD" 2>&1 )" || RC=$?
  check_eq "--repo '$BAD' is a usage error, not a silent _unknown scope" "2" "$RC"
done

echo
echo "== a declared scope routes the checkpoint handoff, not the flat path (CodeAnt, PR #1423) =="
# The checkpoint written by --ensure-session used to pick its handoff path from
# `gh repo view` -> repo_identity() alone. When BOTH failed it fell to
# --legacy-flat, on the stated grounds that the checkout was "genuinely
# repo-less". That reasoning ignored a scope the session had already declared:
# with --repo (or a supply-only inherited $CLAUDE_SESSION_REPO) the session IS
# named, and session-state.sh scopes its half of the write under that key. The
# handoff then landed on the shared flat path while session-state sat under
# .repos["org/a"] — two halves of one poll disagreeing, and no scoped reader
# ever finding the handoff. The flat file is shared by every repo, so it is also
# the more collision-prone of the two destinations.
#
# An origin-less checkout plus a `gh repo view` that yields nothing
# (STUB_REPO_VIEW_FAIL) is exactly that state.
NOREMOTE_PR=91
FLAT_CHECKPOINT="$HOME/.claude/handoffs/pr-${NOREMOTE_PR}-handoff.json"
SCOPED_CHECKPOINT="$HOME/.claude/handoffs/org/a/pr-${NOREMOTE_PR}-handoff.json"
rm -f "$FLAT_CHECKPOINT" "$SCOPED_CHECKPOINT"
RC=0; OUT="$( cd "$NOREMOTE" && STUB_REPO_VIEW_FAIL=1 STUB_HEAD_SHA=eee9111 STUB_PR_NUMBER="$NOREMOTE_PR" \
  PATH="$STUB_BIN:$PATH" bash "$GATE" "$NOREMOTE_PR" --ensure-session --repo org/a 2>&1 )" || RC=$?
# The run ends 4, but downstream of everything under test: poll-watermarks.sh
# shells out to pr-state.sh, which needs the same `gh repo view` this scenario
# deliberately breaks. That is a limit of the stub, not the gate — so pin the
# failure to that step and assert no scope-resolution refusal happened. A
# regression in scope resolution would abort BEFORE the checkpoint write, so the
# path assertions below are the ones that actually carry this test.
check_eq "the only failure is downstream watermark init, not scope resolution" "1" \
  "$(grep -c 'poll-watermarks.sh --init failed' <<<"$OUT")"
check_eq "no scope refusal on the way there" "0" \
  "$(grep -cE 'contradicts the checkout being operated on|refuse to poll from wrong checkout|could not resolve' <<<"$OUT")"
check_eq "checkpoint is NOT written to the shared flat path" "0" \
  "$(test -f "$FLAT_CHECKPOINT" && echo 1 || echo 0)"
check_eq "checkpoint lands under the declared scope" "1" \
  "$(test -f "$SCOPED_CHECKPOINT" && echo 1 || echo 0)"
check_eq "…and the handoff records that scope" "org/a" \
  "$(jq -r '.owner_repo // ""' "$SCOPED_CHECKPOINT" 2>/dev/null)"
check_eq "…and session-state agrees with it" "org/a" \
  "$(jq -r '.repos["org/a"].prs["'"$NOREMOTE_PR"'"].owner_repo // ""' "$HOME/.claude/session-state.json")"
check_eq "the fallback says which scope it used and why" "1" \
  "$(grep -c "scoping PR #${NOREMOTE_PR}'s handoff to the session repo 'org/a'" <<<"$OUT")"

# The flat path stays reachable for a checkout that genuinely names no repo:
# no --repo, no inherited scope, nothing derivable. That is the case
# --legacy-flat exists for, and it must not have been swallowed by the above.
UNSCOPED_PR=92
UNSCOPED_FLAT="$HOME/.claude/handoffs/pr-${UNSCOPED_PR}-handoff.json"
rm -f "$UNSCOPED_FLAT"
RC=0; OUT="$( cd "$NOREMOTE" && env -u CLAUDE_SESSION_REPO STUB_REPO_VIEW_FAIL=1 STUB_HEAD_SHA=fff9222 \
  STUB_PR_NUMBER="$UNSCOPED_PR" PATH="$STUB_BIN:$PATH" bash "$GATE" "$UNSCOPED_PR" --ensure-session 2>&1 )" || RC=$?
check_eq "a truly repo-less checkout still reaches the flat path" "1" \
  "$(test -f "$UNSCOPED_FLAT" && echo 1 || echo 0)"

echo
echo "== a declared repo key may supply an identity, never override one (issue #854) =="
# --repo / \$CLAUDE_SESSION_REPO answer "which scope key"; --root-repo answers
# "which checkout". When both resolve to a real owner/repo and disagree, the old
# code validated every per-PR field against the DECLARED repo while gh,
# merge-gate.sh and the session-state writes all ran against the checkout —
# polling one repo's PR while acting on another (CodeAnt Major + BugBot, PR #856).
write_handoff "org/a" 84 aaa1111
RC=0; OUT="$( cd "$REPO_B" && bash "$GATE" 84 --verify-state --repo org/a --root-repo "$REPO_B" 2>&1 )" || RC=$?
check_eq "--repo contradicting --root-repo is refused" "4" "$RC"
check_eq "…and the refusal names both sides" "1" "$(grep -c "contradicts the checkout being operated on" <<<"$OUT")"
check_eq "…and it did not operate on the declared repo" "0" "$(grep -c 'gate met' <<<"$OUT")"
# An inherited environment value is ambient rather than explicit. A
# self-identifying checkout replaces it before scope resolution, whether or not
# --root-repo pins that checkout.
write_handoff "org/b" 84 bbb2222
RC=0; OUT="$( cd "$REPO_B" && CLAUDE_SESSION_REPO=org/a bash "$GATE" 84 --verify-state --root-repo "$REPO_B" 2>&1 )" || RC=$?
check_eq "stale environment value yields to explicit checkout identity" "0" "$RC"
RC=0; OUT="$( cd "$REPO_B" && CLAUDE_SESSION_REPO=org/a bash "$GATE" 84 --verify-state 2>&1 )" || RC=$?
check_eq "stale environment value yields to live cwd identity" "0" "$RC"
# Explicit --repo remains a per-invocation declaration even without
# --root-repo; a stored root must not silently redirect away from the invoking
# checkout and hide the mismatch.
RC=0; OUT="$( cd "$REPO_A" && bash "$GATE" 84 --verify-state --repo org/b 2>&1 )" || RC=$?
check_eq "explicit --repo contradicting live cwd is refused" "4" "$RC"
check_eq "…and the explicit mismatch keeps the contradiction message" "1" \
  "$(grep -c "contradicts the checkout being operated on" <<<"$OUT")"
# A key merely DERIVED from the checkout can never contradict it, so the ordinary
# no-override path must stay clean — this is the regression guard for the fix.
write_handoff "org/a" 84 aaa1111
RC=0; OUT="$( cd "$REPO_A" && bash "$GATE" 84 --verify-state 2>&1 )" || RC=$?
check_eq "no declared key: ordinary poll is unaffected" "0" "$RC"
check_eq "…and emits no contradiction message" "0" "$(grep -c 'contradicts the checkout' <<<"$OUT")"
# And a declared key that AGREES with the checkout is still fine.
RC=0; OUT="$( cd "$REPO_A" && bash "$GATE" 84 --verify-state --repo org/a 2>&1 )" || RC=$?
check_eq "declared key agreeing with the checkout passes" "0" "$RC"

echo
echo "== every refusal exits non-zero (issue #854) =="
# The reported worry: a refusal message printed while the shell saw exit 0 would
# let a caller treat "refused" as "gate met". Assert message-and-code agree.
assert_refusal_nonzero() { # $1 = desc, rest = gate args (run from repo C)
  local desc="$1"; shift
  local rc=0 out
  out="$( cd "$REPO_C" && bash "$GATE" "$@" 2>&1 )" || rc=$?
  if [[ "$out" == *"polling-state-gate.sh:"* && "$rc" -eq 0 ]]; then
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (printed a message but exited 0: $out)"
  else
    PASS=$((PASS + 1)); echo "ok   — $desc"
  fi
}
assert_refusal_nonzero "unregistered PR does not exit 0" 999884 --verify-state
assert_refusal_nonzero "unknown flag does not exit 0" 84 --nope
assert_refusal_nonzero "missing PR number does not exit 0" --verify-state

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: polling-state-gate.sh multi-repo tests passed"
