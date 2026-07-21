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
echo "== A genuinely wrong repo is still refused =="
# Repo C has no registration for PR 84: the gate must refuse rather than fall
# through to another repo's entry just because the number matches. It must also
# not silently REDIRECT to the owning repo's recorded checkout — the per-PR
# root_repo outranks the live checkout when resolving a root (issue #647), so
# the cross-repo decision is anchored to the checkout the caller is standing in.
REPO_C="$WORK/c"; make_repo "$REPO_C" "org/c"
RC=0; OUT="$( cd "$REPO_C" && bash "$GATE" 84 --verify-state 2>&1 )" || RC=$?
check_eq "poll from an unrelated repo is refused (exit 4)" "4" "$RC"
check_eq "refusal names the owning repo" "1" "$(grep -c "scoped to repo 'org/a'" <<<"$OUT")"
check_eq "refusal names the active repo" "1" "$(grep -c "active checkout is 'org/c'" <<<"$OUT")"
check_eq "and it did not operate on the other repo" "0" "$(grep -c 'gate met' <<<"$OUT")"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: polling-state-gate.sh multi-repo tests passed"
