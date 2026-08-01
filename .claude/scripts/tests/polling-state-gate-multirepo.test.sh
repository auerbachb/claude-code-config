#!/usr/bin/env bash
# Regression test: polling-state-gate.sh must not refuse a valid checkout
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
# Uses --verify-state, the offline mode (no gh, no merge-gate), so the test is
# hermetic. Temporary HOME; never touches the real ~/.claude/. Requires git+jq.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
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

make_repo() { # $1 = dir, $2 = owner/name
  mkdir -p "$1"
  git -C "$1" init --quiet
  git -C "$1" remote add origin "https://github.com/$2.git"
  git -C "$1" -c user.email=t@e -c user.name=T commit --quiet --allow-empty -m init
}

write_handoff() { # $1 = pr, $2 = sha
  cat > "$HOME/.claude/handoffs/pr-$1-handoff.json" <<JSON
{"schema_version":"1.0","pr_number":$1,"head_sha":"$2","reviewer":"cr",
 "phase_completed":"B","created_at":"2026-07-21T00:00:00Z","findings_fixed":[],
 "threads_replied":[],"threads_resolved":[],"files_changed":[],
 "push_timestamp":"2026-07-21T00:00:00Z"}
JSON
}

REPO_A="$WORK/a"; make_repo "$REPO_A" "org/a"
REPO_B="$WORK/b"; make_repo "$REPO_B" "org/b"

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
write_handoff 84 aaa1111
OUT="$( cd "$REPO_A" && bash "$GATE" 84 --verify-state 2>&1 )"; RC=$?
check_eq "polling from repo A is allowed (exit 0)" "0" "$RC"
check_eq "no 'refuse to poll from wrong checkout' message" "0" "$(grep -c 'wrong checkout' <<<"$OUT")"

# And repo B still validates on its own terms, against ITS head_sha.
write_handoff 84 bbb2222
RC=0; ( cd "$REPO_B" && bash "$GATE" 84 --verify-state >/dev/null 2>&1 ) || RC=$?
check_eq "polling from repo B is allowed too" "0" "$RC"

echo
echo "== A sibling worktree of the same repo is not a wrong checkout =="
WT_A="$WORK/a-worktree"
git -C "$REPO_A" worktree add --quiet -b feature "$WT_A" >/dev/null 2>&1
write_handoff 84 aaa1111
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
REPO_C="$WORK/c"; make_repo "$REPO_C" "org/c"
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
STUB_BIN="$WORK/bin"; mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  pr)   echo '{"headRefOid":"ccc3333","state":"OPEN","number":84,"headRefName":"feature","url":"https://github.com/org/c/pull/84","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":""}' ;;
  repo) echo 'org/c' ;;
  api)
    shift
    [[ "${1:-}" == "--paginate" ]] && shift
    case "${1:-}" in
      user) echo 'testuser' ;;
      graphql) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' ;;
      repos/*/pulls/*)
        if [[ "$*" == *"/reviews"* || "$*" == *"/comments"* ]]; then echo '[]'
        else echo '{"user":{"login":"testuser","type":"User"}}'; fi ;;
      repos/*/commits/*/check-runs*) echo '{"check_runs":[]}' ;;
      *) echo '[]' ;;
    esac ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
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
write_handoff 84 ccc3333
RC=0; OUT="$( cd "$REPO_C" && bash "$GATE" 84 --verify-state 2>&1 )" || RC=$?
check_eq "a later tick from repo C validates against C's own state" "0" "$RC"

echo
echo "== --repo / \$CLAUDE_SESSION_REPO select the scope (issue #854) =="
# A checkout with no `origin` remote cannot name itself, so before #854 there was
# no way to tell the gate which repo it was standing in. Both mechanisms must
# now reach the same scope.
NOREMOTE="$WORK/noremote"
mkdir -p "$NOREMOTE"
git -C "$NOREMOTE" init --quiet
git -C "$NOREMOTE" -c user.email=t@e -c user.name=T commit --quiet --allow-empty -m init
write_handoff 84 aaa1111
RC=0; OUT="$( cd "$NOREMOTE" && bash "$GATE" 84 --verify-state --repo org/a 2>&1 )" || RC=$?
check_eq "--repo selects the named scope from an origin-less checkout" "0" "$RC"
RC=0; OUT="$( cd "$NOREMOTE" && CLAUDE_SESSION_REPO=org/a bash "$GATE" 84 --verify-state 2>&1 )" || RC=$?
check_eq "\$CLAUDE_SESSION_REPO selects the named scope too" "0" "$RC"
# --repo outranks the environment variable.
RC=0; OUT="$( cd "$NOREMOTE" && CLAUDE_SESSION_REPO=org/b bash "$GATE" 84 --verify-state --repo org/a 2>&1 )" || RC=$?
check_eq "--repo outranks \$CLAUDE_SESSION_REPO" "0" "$RC"
# A malformed value is a usage error (exit 2), not a silent "_unknown" fallback.
RC=0; OUT="$( cd "$REPO_A" && bash "$GATE" 84 --verify-state --repo not-a-repo-key 2>&1 )" || RC=$?
check_eq "malformed --repo is a usage error (exit 2)" "2" "$RC"
RC=0; OUT="$( cd "$REPO_A" && bash "$GATE" 84 --verify-state --repo 2>&1 )" || RC=$?
check_eq "--repo with no value is a usage error (exit 2)" "2" "$RC"

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
