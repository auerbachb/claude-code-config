#!/usr/bin/env bash
# diff-survival-check.test.sh — Offline unit tests for diff-survival-check.sh (issue #757).
# catalog: tests — Tests for `diff-survival-check.sh`
#
# Fully hermetic: every scenario builds throwaway git repos under a temp dir and
# points --base at a LOCAL ref, so no network, no `gh`, and no real remote are
# involved. Auto-discovered by .github/scripts/run-hook-tests.sh (issue #681) —
# no workflow edit needed.
#
# Run from anywhere: bash .claude/scripts/tests/diff-survival-check.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/.claude/scripts/diff-survival-check.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Isolate the script-usage.log append and any global git config lookups.
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global"; : > "$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"

PASS=0
FAIL=0
CURRENT_CASE=""

case_start() { CURRENT_CASE="$1"; }
pass() { PASS=$((PASS + 1)); printf 'PASS: %s — %s\n' "$CURRENT_CASE" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s — %s\n' "$CURRENT_CASE" "$1"; }

expect_rc() {
  local want="$1" got="$2" what="$3"
  if [[ "$got" == "$want" ]]; then pass "$what (exit $got)"; else fail "$what: expected exit $want, got $got"; fi
}
expect_contains() {
  local haystack="$1" needle="$2" what="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$what"; else fail "$what: output did not contain '$needle'. Got: $haystack"; fi
}
expect_not_contains() {
  local haystack="$1" needle="$2" what="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$what"; else fail "$what: output unexpectedly contained '$needle'. Got: $haystack"; fi
}
expect_eq() {
  local want="$1" got="$2" what="$3"
  if [[ "$got" == "$want" ]]; then pass "$what"; else fail "$what: expected '$want', got '$got'"; fi
}

# --------------------------------------------------------------------------
# Repo builders
# --------------------------------------------------------------------------

# new_repo <name> — an empty repo whose default branch is `main`, regardless of
# the host git's init.defaultBranch (which is `master` on older versions).
new_repo() {
  local d="$TMP/$1"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" symbolic-ref HEAD refs/heads/main
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"
  printf '%s' "$d"
}

wr() { printf '%s\n' "$2" > "$1/$3"; }
commit_all() { git -C "$1" add -A && git -C "$1" commit -q -m "$2"; }

# conflicting_repo <name> — main and feat both edit a.txt and b.txt, so a rebase
# of feat onto main conflicts in both files. c.txt is feat-only (no conflict).
conflicting_repo() {
  local d; d="$(new_repo "$1")"
  wr "$d" 'A0' a.txt; wr "$d" 'B0' b.txt; wr "$d" 'C0' c.txt
  commit_all "$d" base
  git -C "$d" branch -q feat

  wr "$d" 'A0
main-a' a.txt
  wr "$d" 'B0
main-b' b.txt
  commit_all "$d" main-work

  git -C "$d" checkout -q feat
  wr "$d" 'A0
feat-a' a.txt
  wr "$d" 'B0
feat-b' b.txt
  wr "$d" 'C0
feat-c' c.txt
  commit_all "$d" feat-work
  printf '%s' "$d"
}

# --------------------------------------------------------------------------
# 1. Faithful resolution → intact (exit 0)
# --------------------------------------------------------------------------
case_start "faithful resolution"
D="$(conflicting_repo faithful)"
( cd "$D" && "$SUT" snapshot --base main >/dev/null ) ; expect_rc 0 $? "snapshot before the rebase"
( cd "$D" && git rebase main >/dev/null 2>&1 ) # conflicts
# Resolve keeping BOTH sides in every file — nothing is dropped.
wr "$D" 'A0
main-a
feat-a' a.txt
wr "$D" 'B0
main-b
feat-b' b.txt
( cd "$D" && git add -A && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 )
OUT="$( cd "$D" && "$SUT" verify --base main 2>&1 )"; RC=$?
expect_rc 0 "$RC" "verify after a faithful resolution"
expect_contains "$OUT" "intact" "reports intact"

# --------------------------------------------------------------------------
# 2. Resolution drops one file's changes → files_lost (exit 2), file named
# --------------------------------------------------------------------------
case_start "dropped file"
D="$(conflicting_repo dropped)"
( cd "$D" && "$SUT" snapshot --base main >/dev/null )
( cd "$D" && git rebase main >/dev/null 2>&1 )
# a.txt keeps both sides; b.txt silently keeps ONLY main's side — the incident.
wr "$D" 'A0
main-a
feat-a' a.txt
wr "$D" 'B0
main-b' b.txt
( cd "$D" && git add -A && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 )
OUT="$( cd "$D" && "$SUT" verify --base main 2>&1 )"; RC=$?
expect_rc 2 "$RC" "verify after a resolution that dropped b.txt"
expect_contains "$OUT" "b.txt" "names the lost file"
expect_not_contains "$OUT" "  a.txt" "does not name the surviving file"
expect_contains "$OUT" "unresolved conflict" "tells the caller to treat it as unresolved"
# The same verdict is machine-readable for the skill call sites.
JOUT="$( cd "$D" && "$SUT" verify --base main --json 2>&1 )"; RC=$?
expect_rc 2 "$RC" "--json keeps the exit code"
expect_eq "files_lost" "$(printf '%s' "$JOUT" | jq -r '.verdict')" "--json verdict is files_lost"
expect_eq "b.txt" "$(printf '%s' "$JOUT" | jq -r '.lost_files | join(",")')" "--json lost_files names b.txt"

# --------------------------------------------------------------------------
# 3. Whitespace-aware: only the re-indent survives → still lost
# --------------------------------------------------------------------------
case_start "whitespace-only survivor"
D="$(new_repo whitespace)"
wr "$D" 'header
def f():
return 1' c.py
wr "$D" 'A0' a.txt
commit_all "$D" base
git -C "$D" checkout -q -b feat
# feat re-indents AND changes the logic (1 -> 2), plus a real change elsewhere.
wr "$D" 'header
def f():
    return 2' c.py
wr "$D" 'A0
feat-a' a.txt
commit_all "$D" feat-work
( cd "$D" && "$SUT" snapshot --base main >/dev/null ) ; expect_rc 0 $? "snapshot captures c.py as substantive"
SNAP="$( cd "$D" && "$SUT" status --json )"
expect_contains "$SNAP" "c.py" "c.py recorded as substantive"
# Simulate a resolution that kept only the re-indent: logic reverts to 1.
wr "$D" 'header
def f():
    return 1' c.py
commit_all "$D" resolution
OUT="$( cd "$D" && "$SUT" verify --base main 2>&1 )"; RC=$?
expect_rc 2 "$RC" "whitespace-only survival counts as lost"
expect_contains "$OUT" "c.py" "names the whitespace-only file"

# --------------------------------------------------------------------------
# 4. Clean no-conflict rebase → intact, no noise
# --------------------------------------------------------------------------
case_start "clean rebase"
D="$(new_repo clean)"
wr "$D" 'A0' a.txt; wr "$D" 'B0' b.txt
commit_all "$D" base
git -C "$D" branch -q feat
wr "$D" 'B0
main-b' b.txt          # main touches b.txt only
commit_all "$D" main-work
git -C "$D" checkout -q feat
wr "$D" 'A0
feat-a' a.txt          # feat touches a.txt only — disjoint, no conflict
commit_all "$D" feat-work
( cd "$D" && "$SUT" snapshot --base main >/dev/null )
( cd "$D" && git rebase main >/dev/null 2>&1 ) ; expect_rc 0 $? "clean rebase succeeds"
OUT="$( cd "$D" && "$SUT" verify --base main 2>&1 )"; RC=$?
expect_rc 0 "$RC" "verify after a clean rebase"
expect_not_contains "$OUT" "LOST" "no loss reported"
expect_not_contains "$OUT" "VANISHED" "no vanish reported"

# --------------------------------------------------------------------------
# 5. Entire diff vanished (absorbed by main) → exit 1 + "already on main"
# --------------------------------------------------------------------------
case_start "vanished diff"
D="$(new_repo vanished)"
wr "$D" 'A0' a.txt
commit_all "$D" base
git -C "$D" branch -q feat
git -C "$D" checkout -q feat
wr "$D" 'A0
the-fix' a.txt
commit_all "$D" feat-fix
( cd "$D" && "$SUT" snapshot --base main >/dev/null )
# main independently gains the identical change — the one legitimate empty case.
git -C "$D" checkout -q main
wr "$D" 'A0
the-fix' a.txt
commit_all "$D" main-same-fix
git -C "$D" checkout -q feat
( cd "$D" && git rebase main >/dev/null 2>&1 )
OUT="$( cd "$D" && "$SUT" verify --base main 2>&1 )"; RC=$?
expect_rc 1 "$RC" "verify when the whole diff is gone"
expect_contains "$OUT" "VANISHED" "reports vanished"
expect_contains "$OUT" "identical change" "names the legitimate already-on-main case"
expect_contains "$OUT" "CLOSE the PR" "steers to closing rather than force-pushing an empty branch"

# --------------------------------------------------------------------------
# 6. Interruption survival + orig-head reconstruction (the /go-on resume path)
# --------------------------------------------------------------------------
case_start "interrupted rebase"
D="$(conflicting_repo interrupted)"
PRE_TIP="$(git -C "$D" rev-parse feat)"
( cd "$D" && git rebase main >/dev/null 2>&1 )   # stops on conflict, NO snapshot taken
# A fresh session arrives mid-rebase with nothing on disk.
S0="$( cd "$D" && "$SUT" status --json )"
expect_eq "false" "$(printf '%s' "$S0" | jq -r '.present')" "no snapshot inherited from the killed session"
OUT="$( cd "$D" && "$SUT" snapshot --base main --if-absent --json 2>&1 )"; RC=$?
expect_rc 0 "$RC" "snapshot reconstructs mid-rebase"
expect_eq "rebase-orig-head" "$(printf '%s' "$OUT" | jq -r '.source')" "baseline comes from orig-head, not the half-replayed HEAD"
expect_eq "$PRE_TIP" "$(printf '%s' "$OUT" | jq -r '.pre_head')" "orig-head is the pre-rebase branch tip"
# It lives under the worktree's git dir, so it outlives the shell.
SNAP_PATH="$(printf '%s' "$OUT" | jq -r '.snapshot_path')"
if [[ -f "$D/$SNAP_PATH" || -f "$SNAP_PATH" ]]; then pass "snapshot persisted on disk ($SNAP_PATH)"; else fail "snapshot not found at $SNAP_PATH"; fi
# Unresolved conflicts are not a verdict — there is nothing to judge yet.
OUT="$( cd "$D" && "$SUT" verify --base main 2>&1 )"; RC=$?
expect_rc 4 "$RC" "verify refuses while conflicts are unresolved"
expect_contains "$OUT" "unresolved conflicts remain" "says why it refused"
JOUT="$( cd "$D" && "$SUT" verify --base main --json 2>/dev/null )"
expect_eq "unresolved_conflicts" "$(printf '%s' "$JOUT" | jq -r '.verdict')" "--json verdict while conflicts are unresolved"
# --if-absent must not clobber the snapshot a prior step already took.
OUT2="$( cd "$D" && "$SUT" snapshot --base main --if-absent --json 2>&1 )"
expect_eq "true" "$(printf '%s' "$OUT2" | jq -r '.kept_existing')" "--if-absent keeps the existing snapshot"
# Finish the resolution faithfully; a brand-new invocation reads the persisted snapshot.
wr "$D" 'A0
main-a
feat-a' a.txt
wr "$D" 'B0
main-b
feat-b' b.txt
( cd "$D" && git add -A && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 )
OUT="$( cd "$D" && "$SUT" verify --base main 2>&1 )"; RC=$?
expect_rc 0 "$RC" "resumed session verifies against the persisted snapshot"

# --------------------------------------------------------------------------
# 7. Deferred while commits are still queued for replay
# --------------------------------------------------------------------------
case_start "deferred mid-replay"
D="$(new_repo deferred)"
wr "$D" 'A0' a.txt; wr "$D" 'B0' b.txt
commit_all "$D" base
git -C "$D" branch -q feat
wr "$D" 'A0
main-a' a.txt
commit_all "$D" main-work
git -C "$D" checkout -q feat
wr "$D" 'A0
feat-a' a.txt
commit_all "$D" feat-commit-1
wr "$D" 'B0
feat-b' b.txt
commit_all "$D" feat-commit-2   # b.txt's change lands in the SECOND commit
( cd "$D" && "$SUT" snapshot --base main >/dev/null )
( cd "$D" && git rebase main >/dev/null 2>&1 )   # stops on a.txt in commit 1
wr "$D" 'A0
main-a
feat-a' a.txt
( cd "$D" && git add -A )
OUT="$( cd "$D" && "$SUT" verify --base main --json 2>&1 )"; RC=$?
expect_rc 0 "$RC" "mid-replay does not fail the gate"
expect_eq "deferred" "$(printf '%s' "$OUT" | jq -r '.verdict')" "verdict is deferred, not files_lost (b.txt is simply not replayed yet)"
( cd "$D" && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 )
OUT="$( cd "$D" && "$SUT" verify --base main --json 2>&1 )"; RC=$?
expect_rc 0 "$RC" "verify passes once the replay completes"
expect_eq "intact" "$(printf '%s' "$OUT" | jq -r '.verdict')" "final verdict is intact"

# --------------------------------------------------------------------------
# 7b. Post-hoc snapshot must NOT self-certify (BugBot, PR #763)
#
# The dangerous shape: a rebase finishes having dropped the branch's change, no
# snapshot was ever taken, and a resume path runs `snapshot --if-absent` on the
# now-clean tree. The baseline it records IS the damaged state, so any later
# comparison is X-vs-X and would return intact. Must refuse instead.
# --------------------------------------------------------------------------
case_start "post-hoc snapshot"
D="$(conflicting_repo posthoc)"
( cd "$D" && git rebase main >/dev/null 2>&1 )
# Resolution silently drops BOTH files' feature changes — a fully vaporized diff.
wr "$D" 'A0
main-a' a.txt
wr "$D" 'B0
main-b' b.txt
( cd "$D" && git add -A && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 )
# A resume path arrives after the rebase already finished, with nothing on disk.
expect_eq "false" "$( cd "$D" && "$SUT" status --json | jq -r '.present' )" "no snapshot exists post-rebase"
OUT="$( cd "$D" && "$SUT" snapshot --base main --if-absent 2>&1 )"; RC=$?
expect_rc 0 "$RC" "post-hoc snapshot is still written"
expect_contains "$OUT" "PRE-operation baseline" "snapshot warns it is only valid pre-operation"
OUT="$( cd "$D" && "$SUT" verify --base main 2>&1 )"; RC=$?
expect_rc 4 "$RC" "verify refuses a baseline that is the commit being verified"
expect_contains "$OUT" "UNVERIFIABLE" "reports unverifiable rather than a false intact"
expect_not_contains "$OUT" "intact" "never reports intact on a self-comparison"
JOUT="$( cd "$D" && "$SUT" verify --base main --json 2>/dev/null )"
expect_eq "unverifiable" "$(printf '%s' "$JOUT" | jq -r '.verdict')" "--json verdict is unverifiable"
# Same refusal when the post-hoc tree is empty (the pre_diff_empty bypass).
D="$(new_repo posthoc-empty)"
wr "$D" 'A0' a.txt
commit_all "$D" base
git -C "$D" checkout -q -b feat          # branch with no diff at all vs main
( cd "$D" && "$SUT" snapshot --base main --if-absent >/dev/null )
OUT="$( cd "$D" && "$SUT" verify --base main 2>&1 )"; RC=$?
expect_rc 4 "$RC" "pre_diff_empty does not bypass the self-comparison guard"

# --------------------------------------------------------------------------
# 8. Guard rails: missing snapshot, branch mismatch, usage errors
# --------------------------------------------------------------------------
case_start "guard rails"
D="$(new_repo guards)"
wr "$D" 'A0' a.txt
commit_all "$D" base
git -C "$D" checkout -q -b feat
wr "$D" 'A0
feat-a' a.txt
commit_all "$D" feat-work

OUT="$( cd "$D" && "$SUT" verify --base main 2>&1 )"; RC=$?
expect_rc 5 "$RC" "verify with no snapshot"
expect_contains "$OUT" "BEFORE the rebase" "tells the caller when to snapshot"
# Every --json exit emits a parseable object on stdout, error paths included,
# so a machine caller never has to parse prose off stderr.
JOUT="$( cd "$D" && "$SUT" verify --base main --json 2>/dev/null )"
expect_eq "no_snapshot" "$(printf '%s' "$JOUT" | jq -r '.verdict')" "--json verdict on the no-snapshot path"

( cd "$D" && "$SUT" snapshot --base main >/dev/null )
git -C "$D" checkout -q main
OUT="$( cd "$D" && "$SUT" verify --base main 2>&1 )"; RC=$?
expect_rc 4 "$RC" "verify refuses on a different branch than the snapshot"
expect_contains "$OUT" "refusing to compare" "explains the branch mismatch"
JOUT="$( cd "$D" && "$SUT" verify --base main --json 2>/dev/null )"
expect_eq "branch_mismatch" "$(printf '%s' "$JOUT" | jq -r '.verdict')" "--json verdict on the branch-mismatch path"
git -C "$D" checkout -q feat

OUT="$( cd "$D" && "$SUT" status 2>&1 )"; expect_rc 0 $? "status with a snapshot present"
OUT="$( cd "$D" && "$SUT" clear 2>&1 )"; expect_rc 0 $? "clear removes the snapshot"
expect_eq "false" "$( cd "$D" && "$SUT" status --json | jq -r '.present' )" "status reports absent after clear"

( cd "$D" && "$SUT" >/dev/null 2>&1 ); expect_rc 3 $? "no operation is a usage error"
( cd "$D" && "$SUT" bogus >/dev/null 2>&1 ); expect_rc 3 $? "unknown operation is a usage error"
( cd "$D" && "$SUT" verify --head HEAD >/dev/null 2>&1 ); expect_rc 3 $? "--head is snapshot-only"
( cd "$D" && "$SUT" --help >/dev/null 2>&1 ); expect_rc 0 $? "--help exits 0"

# --------------------------------------------------------------------------
# 9. Linked worktree: the snapshot is per-worktree, not shared
# --------------------------------------------------------------------------
case_start "linked worktree scoping"
D="$(new_repo wt)"
wr "$D" 'A0' a.txt
commit_all "$D" base
git -C "$D" branch -q feat
WT="$TMP/wt-linked"
git -C "$D" worktree add -q "$WT" feat 2>/dev/null
wr "$WT" 'A0
feat-a' a.txt
commit_all "$WT" feat-work
( cd "$WT" && "$SUT" snapshot --base main >/dev/null ); expect_rc 0 $? "snapshot inside a linked worktree"
expect_eq "true"  "$( cd "$WT" && "$SUT" status --json | jq -r '.present' )" "linked worktree sees its own snapshot"
expect_eq "false" "$( cd "$D"  && "$SUT" status --json | jq -r '.present' )" "main worktree is unaffected"

# --------------------------------------------------------------------------
printf '\n=== diff-survival-check: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
