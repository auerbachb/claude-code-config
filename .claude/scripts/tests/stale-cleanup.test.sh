#!/usr/bin/env bash
# stale-cleanup.test.sh — Offline tests for the invoking-repo scope contract
# catalog: tests — Tests for `stale-cleanup.sh`
# (issue #697, contract from issue #687) in stale-cleanup.sh and
# dirty-main-guard.sh.
#
# Layout: repoA hosts a copy of the scripts (simulating the
# ~/.claude/skills-worktree checkout the bug was observed through) and carries
# its own stale branch as a regression tripwire; repoB is the invoking repo
# with stale/fresh/protected branches and worktrees. `gh` is stubbed on PATH;
# it serves a fixture PR list and records its cwd so the tests can prove the
# open-PR safety check runs inside the swept repo.
#
# Requires git, jq. Run from repo root: bash .claude/scripts/tests/stale-cleanup.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

TMP="$(mktemp -d)"
cleanup() {
  # T16's stall stub spawns a self-limiting sleeper; kill any survivor so a
  # failing process-group kill cannot leak one into the runner.
  pkill -f "$TMP/gitstub/stub-sleeper" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Redirect HOME: scripts append to $HOME/.claude/script-usage.log, and the
# temp git identity must not leak into (or depend on) the real ~/.gitconfig.
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
git config --global user.email "test@example.com"
git config --global user.name "Test"
git config --global init.defaultBranch main

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }
# Announced, never counted as a pass: an assertion the environment cannot host
# must not read as one that held. Only for a stated environmental precondition.
skip() { SKIP=$((SKIP + 1)); echo "SKIP — $1"; }

# `chmod 000` does not restrict uid 0, so the unsearchable-ancestor assertions
# below cannot be staged as root: the probe simply succeeds and the entry reads
# live, which is a different path from the one under test. Detected rather than
# assumed — a container image that runs as root would otherwise report a green
# suite that never exercised it.
CAN_STAGE_UNSEARCHABLE=1
if [[ "$(id -u 2>/dev/null || echo 0)" -eq 0 ]]; then CAN_STAGE_UNSEARCHABLE=0; fi

check_json() {
  # $1 desc, $2 json, $3 jq boolean expr — passes when the expr is truthy.
  local desc="$1" json="$2" expr="$3"
  if printf '%s' "$json" | jq -e "$expr" >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

check_eq() {
  local desc="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    pass "$desc"
  else
    fail "$desc (want '$want', got '$got')"
  fi
}

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc (missing '$needle')"
  fi
}

OLD_DATE="2020-01-05T00:00:00"
commit_old() {
  GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" git -C "$1" commit -q -m "$2"
}

# ---- repoA: the repo the scripts live in (skills-worktree stand-in) ---------
REPO_A="$TMP/repoA"
mkdir -p "$REPO_A"
git -C "$REPO_A" init -q
echo "a" > "$REPO_A/README.md"
git -C "$REPO_A" add README.md
commit_old "$REPO_A" "repoA base"
# Stale branch in repoA — must NEVER surface when sweeping from repoB. Before
# the #697 fix, script-location resolution listed exactly this kind of ref.
git -C "$REPO_A" branch issue-999-repoa-stale
mkdir -p "$REPO_A/.claude/scripts"
cp "$REPO_ROOT/.claude/scripts/stale-cleanup.sh" \
   "$REPO_ROOT/.claude/scripts/repo-root.sh" \
   "$REPO_ROOT/.claude/scripts/dirty-main-guard.sh" \
   "$REPO_A/.claude/scripts/"
# All three source the shared wall-clock bound from lib/ (issue #1404) and
# refuse to run git unbounded without it, so the copy includes lib/ too.
mkdir -p "$REPO_A/.claude/scripts/lib"
cp "$REPO_ROOT/.claude/scripts/lib/bounded-run.sh" "$REPO_A/.claude/scripts/lib/"
SUT="$REPO_A/.claude/scripts/stale-cleanup.sh"
GUARD="$REPO_A/.claude/scripts/dirty-main-guard.sh"

# ---- repoB: the invoking repo ------------------------------------------------
REPO_B="$TMP/repoB"
mkdir -p "$REPO_B"
git -C "$REPO_B" init -q
echo "b" > "$REPO_B/README.md"
git -C "$REPO_B" add README.md
commit_old "$REPO_B" "repoB old base"
OLD_SHA="$(git -C "$REPO_B" rev-parse HEAD)"
git -C "$REPO_B" branch issue-100-repob-stale "$OLD_SHA"   # stale
git -C "$REPO_B" branch issue-101-repob-pr "$OLD_SHA"      # old but has open PR
git -C "$REPO_B" branch develop "$OLD_SHA"                 # old but protected
git -C "$REPO_B" worktree add "$TMP/wtB-stale" -b issue-102-repob-wt "$OLD_SHA" >/dev/null 2>&1
git -C "$REPO_B" worktree add "$TMP/wtB-dirty" -b issue-103-repob-dirty "$OLD_SHA" >/dev/null 2>&1
echo "dirty" >> "$TMP/wtB-dirty/README.md"                 # uncommitted tracked change
echo "fresh" >> "$REPO_B/README.md"
git -C "$REPO_B" commit -q -am "repoB fresh tip"           # main tip is fresh (now)
git -C "$REPO_B" branch issue-104-repob-fresh              # fresh — appears nowhere
REPO_B_REAL="$(cd "$REPO_B" && pwd -P)"

mkdir -p "$TMP/plain"                                      # non-repo dir for T4

# ---- gh stub -----------------------------------------------------------------
# Serves an open PR on issue-101-repob-pr and records its cwd per call: the
# scope contract requires the open-PR check to run inside the swept repo.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$TMP/prs.json" <<'FIXTURE'
[{"headRefName":"issue-101-repob-pr","createdAt":"2026-07-01T00:00:00Z"}]
FIXTURE
cat > "$STUB_BIN/gh" <<STUB
#!/usr/bin/env bash
pwd -P >> "$TMP/gh-pwd.log"
case "\$*" in
  "pr list --search"*) cat "$TMP/prs.json" ;;
  *) echo "[]" ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

# ---- T1: cwd=repoB, script living in repoA → sweeps repoB --------------------
OUT="$(cd "$REPO_B" && "$SUT" --check --json 2>&1)"
RC=$?
check_eq "T1: exit 1 (stale items found)" 1 "$RC"
check_json "T1: repoB stale branch listed" "$OUT" \
  '.stale_local_branches | map(.branch) | index("issue-100-repob-stale") != null'
check_json "T1: repoB stale worktree listed" "$OUT" \
  '.stale_worktrees | any(.branch == "issue-102-repob-wt")'
check_json "T1: repoB main worktree skipped as main" "$OUT" \
  '.skipped_worktrees | any(.reason == "main worktree" and (.path | endswith("repoB")))'
check_json "T1: protected branch skipped" "$OUT" \
  '.skipped_local_branches | any(.branch == "develop" and .reason == "protected")'
check_json "T1: open-PR branch skipped" "$OUT" \
  '.skipped_local_branches | any(.branch == "issue-101-repob-pr" and .reason == "open PR")'
check_json "T1: checked-out branch skipped" "$OUT" \
  '.skipped_local_branches | any(.branch == "issue-103-repob-dirty" and .reason == "checked out in a worktree")'
check_json "T1: dirty worktree skipped" "$OUT" \
  '.skipped_worktrees | any((.path | endswith("wtB-dirty")) and .reason == "uncommitted tracked changes")'
check_json "T1: fresh branch appears nowhere" "$OUT" \
  '[.. | strings] | any(contains("issue-104-repob-fresh")) | not'
# Negative control — the tripwire for the #697 regression: nothing from repoA
# (its stale branch or any path under it) may appear in the output.
check_json "T1: no repoA refs leak into the sweep (negative control)" "$OUT" \
  '[.. | strings] | any(contains("repoA") or contains("issue-999")) | not'

# ---- T2: open-PR check ran inside the swept repo -----------------------------
GH_PWD="$(tail -1 "$TMP/gh-pwd.log" 2>/dev/null || echo "")"
check_eq "T2: gh pr list ran from repoB root" "$REPO_B_REAL" "$GH_PWD"

# ---- T1b: subdirectory of repoB still resolves repoB's root ------------------
mkdir -p "$REPO_B/subdir"
OUT="$(cd "$REPO_B/subdir" && "$SUT" --check --json 2>&1)"
check_json "T1b: sweep from a repoB subdirectory finds repoB's stale branch" "$OUT" \
  '.stale_local_branches | map(.branch) | index("issue-100-repob-stale") != null'

# ---- T3: --root override beats cwd -------------------------------------------
OUT="$(cd "$REPO_A" && "$SUT" --check --json --root "$REPO_B" 2>&1)"
RC=$?
check_eq "T3: exit 1 under --root" 1 "$RC"
check_json "T3: --root repoB sweeps repoB from repoA cwd" "$OUT" \
  '.stale_local_branches | map(.branch) | index("issue-100-repob-stale") != null'
check_json "T3: no repoA refs under --root (negative control)" "$OUT" \
  '[.. | strings] | any(contains("repoA") or contains("issue-999")) | not'
GH_PWD="$(tail -1 "$TMP/gh-pwd.log" 2>/dev/null || echo "")"
check_eq "T3: gh pr list pinned to --root repo, not cwd" "$REPO_B_REAL" "$GH_PWD"

# ---- T4: cwd outside any repo, no --root → exit 4 ----------------------------
ERR="$(cd "$TMP/plain" && "$SUT" --check 2>&1 >/dev/null)"
RC=$?
check_eq "T4: non-repo cwd exits 4" 4 "$RC"
check_contains "T4: error suggests --root" "--root" "$ERR"

# ---- T5: caller's-current-worktree safety skip survives ----------------------
OUT="$(cd "$TMP/wtB-stale" && "$SUT" --check --json 2>&1)"
check_json "T5: caller's worktree skipped, not stale" "$OUT" \
  '(.skipped_worktrees | any((.path | endswith("wtB-stale")) and (.reason | contains("current worktree"))))
   and (.stale_worktrees | any(.path | endswith("wtB-stale")) | not)'

# ---- T6: --root with a missing value is a usage error ------------------------
( cd "$REPO_B" && "$SUT" --check --root >/dev/null 2>&1 )
check_eq "T6: bare --root exits 3" 3 "$?"
( cd "$TMP/plain" && "$SUT" --check --root "$TMP/plain" >/dev/null 2>&1 )
check_eq "T6b: --root at a non-repo path exits 4" 4 "$?"

# ---- T7: dirty-main-guard resolves the invoking repo -------------------------
# repoA's main is made dirty; repoB gets an origin and a clean pushed main.
# Before the #697 fix the guard resolved repoA (the script's repo) and could
# never report on repoB at all.
echo "dirty-a" >> "$REPO_A/README.md"
git init -q --bare "$TMP/originB.git"
git -C "$REPO_B" remote add origin "$TMP/originB.git"
git -C "$REPO_B" push -q origin main 2>/dev/null

OUT="$(cd "$REPO_B" && "$GUARD" --check --no-fetch)"
RC=$?
check_eq "T7a: clean repoB reports clean (repoA dirt invisible)" 0 "$RC"
check_eq "T7a: output is 'clean'" "clean" "$OUT"

echo "unpushed" >> "$REPO_B/README.md"
git -C "$REPO_B" commit -q -am "unpushed on main"
OUT="$(cd "$REPO_B" && "$GUARD" --check --no-fetch)"
RC=$?
check_eq "T7b: unpushed commit on repoB main exits 1" 1 "$RC"
check_contains "T7b: reports unpushed commit" "unpushed commit" "$OUT"

# ---- T8: --json root key + --root= form + flag-like values (issue #707) ------
OUT="$(cd "$REPO_B" && "$SUT" --check --json 2>&1)"
check_json "T8a: --json includes top-level root ending in repoB" "$OUT" \
  '.root | endswith("/repoB")'
check_json "T8a: all documented JSON keys present alongside root" "$OUT" \
  'has("root") and has("stale_days") and has("threshold_ts")
   and has("stale_worktrees") and has("stale_local_branches") and has("stale_remote_branches")
   and has("skipped_worktrees") and has("skipped_local_branches") and has("skipped_remote_branches")'

# --root=<path> must behave exactly like the two-arg form.
OUT_TWOARG="$(cd "$TMP/plain" && "$SUT" --check --json --root "$REPO_B" 2>&1)"
RC_TWOARG=$?
OUT_EQFORM="$(cd "$TMP/plain" && "$SUT" --check --json --root="$REPO_B" 2>&1)"
RC_EQFORM=$?
check_eq "T8b: --root=<path> exit code matches two-arg form" "$RC_TWOARG" "$RC_EQFORM"
check_eq "T8b: --root=<path> resolves the same root" \
  "$(printf '%s' "$OUT_TWOARG" | jq -r '.root')" \
  "$(printf '%s' "$OUT_EQFORM" | jq -r '.root')"

# Empty or flag-like --root values are usage errors (3), never resolution
# failures (4) — `--root --json` previously swallowed --json as the path.
( cd "$REPO_B" && "$SUT" --check --root --json >/dev/null 2>&1 )
check_eq "T8c: --root with flag-like value exits 3" 3 "$?"
( cd "$REPO_B" && "$SUT" --check --root=--json >/dev/null 2>&1 )
check_eq "T8c: --root= with flag-like value exits 3" 3 "$?"
( cd "$REPO_B" && "$SUT" --check --root= >/dev/null 2>&1 )
check_eq "T8c: --root= with empty value exits 3" 3 "$?"

# ---- T9: orphaned worktree registrations (issue #1402) -----------------------
# repoC carries four linked worktrees: one live, one whose directory was removed
# behind git's back (the debris class that accumulated to 62 entries and froze
# `git worktree list` on 2026-08-26), one orphan carrying a `locked` marker (the
# shape this repo's agent harness leaves behind), and the caller's own.
REPO_C="$TMP/repoC"
mkdir -p "$REPO_C"
git -C "$REPO_C" init -q
echo "c" > "$REPO_C/README.md"
git -C "$REPO_C" add README.md
commit_old "$REPO_C" "repoC base"
git -C "$REPO_C" worktree add "$TMP/wtC-orphan" -b issue-201-c-orphan >/dev/null 2>&1
git -C "$REPO_C" worktree add "$TMP/wtC-locked" -b issue-202-c-locked >/dev/null 2>&1
# The live worktree is deliberately created off a FRESH tip. Were it old, the
# pre-existing stale-worktree pass would remove it on --apply and the
# "live registration untouched" assertions below would pass or fail for a
# reason unrelated to the registration pass they exist to test.
echo "fresh" >> "$REPO_C/README.md"
git -C "$REPO_C" commit -q -am "repoC fresh tip"
git -C "$REPO_C" worktree add "$TMP/wtC-live" -b issue-200-c-live >/dev/null 2>&1
REG_C="$REPO_C/.git/worktrees"
# The live worktree also carries a `locked` marker on purpose. Without it the
# "live registration untouched" assertions below pass even when the live check
# is broken, because a misclassified unlocked entry still routes to
# `git worktree prune`, which refuses to prune a worktree that exists — git's
# own safety, not ours. Locked + --include-locked routes to targeted removal
# instead, where the live check is the ONLY thing standing in the way, so the
# assertions actually bite. Verified by reverting the live check and watching
# them fail.
printf 'claude agent wtC-live (pid 4242)\n' > "$REG_C/wtC-live/locked"
# Remove the working directories without telling git — exactly what leaves a
# registration behind.
rm -rf "$TMP/wtC-orphan" "$TMP/wtC-locked"
printf 'claude agent wtC-locked (pid 4242)\n' > "$REG_C/wtC-locked/locked"

# Tight enough to keep T10's deliberately-hung reads short, loose enough that a
# healthy call on a loaded CI runner is never mistaken for a hang. The bound
# only has to exceed the healthy-case duration, which is milliseconds here.
export STALE_CLEANUP_TIMEOUT_SECS=4
export STALE_CLEANUP_READ_TIMEOUT_SECS=2

OUT="$(cd "$REPO_C" && "$SUT" --check --json 2>/dev/null)"
RC=$?
check_eq "T9: orphaned registrations make --check exit 1" 1 "$RC"
check_json "T9: unlocked orphan reported, routed to git worktree prune" "$OUT" \
  '.orphaned_registrations | any(.id == "wtC-orphan" and .method == "prune"
                                 and (.reason | contains("worktree directory missing")))'
check_json "T9: locked orphan is skipped, not pruned, without --include-locked" "$OUT" \
  '(.skipped_registrations | any(.id == "wtC-locked" and (.reason | contains("locked"))))
   and (.orphaned_registrations | any(.id == "wtC-locked") | not)'
check_json "T9: live registration appears in neither list (negative control)" "$OUT" \
  '(.orphaned_registrations | any(.id == "wtC-live") | not)
   and (.skipped_registrations | any(.id == "wtC-live") | not)'
check_json "T9: enumeration succeeded, so the pre-existing passes still ran" "$OUT" \
  '.worktree_enumeration == "ok" and .registration_scan == "ok"
   and (.skipped_worktrees | any(.reason == "main worktree"))'
check_json "T9: pre-existing safety skips survive the new pass" "$OUT" \
  '(.skipped_local_branches | any(.branch == "master" or .branch == "main") )
   or (.skipped_worktrees | length) > 0'

# --include-locked promotes the locked orphan to a removal candidate, and only
# ever via the targeted path — `git worktree prune` refuses locked entries.
OUT="$(cd "$REPO_C" && "$SUT" --check --json --include-locked 2>/dev/null)"
check_json "T9: --include-locked promotes the locked orphan, targeted path" "$OUT" \
  '.orphaned_registrations | any(.id == "wtC-locked" and .method == "targeted"
                                 and (.reason | contains("--include-locked")))'

# Caller's own registration is never a candidate, mirroring the worktree skip.
OUT="$(cd "$TMP/wtC-live" && "$SUT" --check --json 2>/dev/null)"
check_json "T9: caller's own registration is skipped by id" "$OUT" \
  '(.skipped_registrations | any(.id == "wtC-live" and (.reason | contains("caller"))))
   and (.orphaned_registrations | any(.id == "wtC-live") | not)'

# --apply prunes the unlocked orphan and leaves the live and locked ones alone.
OUT="$(cd "$REPO_C" && "$SUT" --apply 2>&1)"
RC=$?
# The status is asserted, not just the output: without this the suite would
# still pass if a deletion failed and the script wrongly reported success.
check_eq "T9: a clean --apply exits 0" 0 "$RC"
check_contains "T9: --apply reports the prune-path removal" \
  "removed: worktree registration wtC-orphan" "$OUT"
check_eq "T9: unlocked orphan registration is gone after --apply" "gone" \
  "$([[ -e "$REG_C/wtC-orphan" ]] && echo present || echo gone)"
check_eq "T9: LIVE registration untouched by --apply" "present" \
  "$([[ -e "$REG_C/wtC-live" ]] && echo present || echo gone)"
check_eq "T9: locked registration untouched without --include-locked" "present" \
  "$([[ -e "$REG_C/wtC-locked" ]] && echo present || echo gone)"

OUT="$(cd "$REPO_C" && "$SUT" --apply --include-locked 2>&1)"
RC=$?
check_eq "T9: a clean --apply --include-locked exits 0" 0 "$RC"
check_contains "T9: --include-locked clears the locked orphan via targeted removal" \
  "removed: worktree registration wtC-locked (targeted" "$OUT"
# No entry may be reported as failed on a run where every removal succeeded —
# the exit code alone would not catch a failure line the script forgot to count.
if [[ "$OUT" == *"failed:"* ]]; then
  fail "T9: no failure lines on the clean --include-locked run"
else
  pass "T9: no failure lines on the clean --include-locked run"
fi
check_eq "T9: locked registration gone after --include-locked" "gone" \
  "$([[ -e "$REG_C/wtC-locked" ]] && echo present || echo gone)"
check_eq "T9: LIVE registration still untouched (negative control)" "present" \
  "$([[ -e "$REG_C/wtC-live" ]] && echo present || echo gone)"

# ---- T10: unreadable registration metadata (the hang class) ------------------
# A FIFO with no writer stands in for the iCloud-evicted `gitdir` files whose
# reads never returned. `git worktree list --porcelain` blocks on it, so this
# also exercises the bounded-enumeration degradation: without the bound the
# whole sweep would hang here instead of reporting.
REPO_D="$TMP/repoD"
mkdir -p "$REPO_D"
git -C "$REPO_D" init -q
echo "d" > "$REPO_D/README.md"
git -C "$REPO_D" add README.md
commit_old "$REPO_D" "repoD base"
git -C "$REPO_D" worktree add "$TMP/wtD-stuck" -b issue-300-d-stuck >/dev/null 2>&1
REG_D="$REPO_D/.git/worktrees"
rm -f "$REG_D/wtD-stuck/gitdir"
mkfifo "$REG_D/wtD-stuck/gitdir"

OUT="$(cd "$REPO_D" && "$SUT" --check --json 2>/dev/null)"
RC=$?
check_eq "T10: unreadable registration makes --check exit 1" 1 "$RC"
check_json "T10: reported as unreadable, prunable with warning, targeted path" "$OUT" \
  '.orphaned_registrations | any(.id == "wtD-stuck" and .method == "targeted"
                                 and (.reason | contains("unreadable — prunable with warning")))'
# The contract is "degrades instead of hanging", which both "timed_out" and
# "failed" satisfy. Asserting `timed_out` specifically would pin a git
# implementation detail — whether it blocks on the FIFO or errors out — and
# that varies by platform and git version, so a fixture forced to time out
# deterministically would be testing git, not us. The closed set below is the
# tightest portable form: it still fails if enumeration succeeds, and now also
# if some unexpected third state appears. The bound itself is proven
# deterministically by the read-path assertion above, whose reason string is
# emitted only when read_bounded_line hit READ_BOUND_SECS.
check_json "T10: bounded enumeration degrades instead of hanging" "$OUT" \
  '.worktree_enumeration == "timed_out" or .worktree_enumeration == "failed"'
check_json "T10: local branches are not classified when enumeration did not complete" "$OUT" \
  '(.stale_local_branches | length) == 0'

OUT="$(cd "$REPO_D" && "$SUT" --apply 2>&1)"
check_contains "T10: --apply removes it via the targeted path" \
  "removed: worktree registration wtD-stuck (targeted" "$OUT"
check_eq "T10: unreadable registration is gone after --apply" "gone" \
  "$([[ -e "$REG_D/wtD-stuck" ]] && echo present || echo gone)"
# End-to-end proof that clearing the debris unblocks git: the same enumeration
# that timed out above now completes.
OUT="$(cd "$REPO_D" && "$SUT" --check --json 2>/dev/null)"
check_json "T10: enumeration recovers once the debris is cleared" "$OUT" \
  '.worktree_enumeration == "ok" and (.orphaned_registrations | length) == 0'

# ---- T11: --apply reports an incomplete sweep instead of exiting 0 -----------
# --check already exits 1 when enumeration or the registration scan did not
# finish; --apply used to print a note and exit 0, so a caller branching on the
# status recorded a sweep that skipped whole categories as done and never
# re-ran it. Both modes now agree.
#
# The negative control comes first and matters: repoD is clean and fully
# enumerable after T10, so its --apply must still exit 0. Without it, the
# exit-1 assertion below would also pass if --apply had simply started
# returning 1 unconditionally.
OUT="$(cd "$REPO_D" && "$SUT" --apply 2>&1)"
RC=$?
check_eq "T11: complete --apply with nothing to do still exits 0 (control)" 0 "$RC"

REPO_E="$TMP/repoE"
mkdir -p "$REPO_E"
git -C "$REPO_E" init -q
echo "e" > "$REPO_E/README.md"
git -C "$REPO_E" add README.md
commit_old "$REPO_E" "repoE base"
git -C "$REPO_E" worktree add "$TMP/wtE-stuck" -b issue-400-e-stuck >/dev/null 2>&1
REG_E="$REPO_E/.git/worktrees"
rm -f "$REG_E/wtE-stuck/gitdir"
mkfifo "$REG_E/wtE-stuck/gitdir"

OUT="$(cd "$REPO_E" && "$SUT" --apply 2>&1)"
RC=$?
check_eq "T11: --apply exits 1 when enumeration did not complete" 1 "$RC"
check_contains "T11: the incomplete sweep is explained, not just signalled" \
  "so worktrees and local branches were not swept" "$OUT"
# Exit 1 must mean "incomplete", never "did nothing" — the registration sweep
# is the pass that clears the cause, and it still has to run.
check_contains "T11: exit 1 still performed the registration removal" \
  "removed: worktree registration wtE-stuck (targeted" "$OUT"
check_eq "T11: registration is gone despite the nonzero status" "gone" \
  "$([[ -e "$REG_E/wtE-stuck" ]] && echo present || echo gone)"
# End-to-end: once the debris is cleared the same repo enumerates cleanly, so
# the exit 1 above really was "incomplete", not a permanent property of repoE.
check_json "T11: the same repo enumerates cleanly once cleared" \
  "$(cd "$REPO_E" && "$SUT" --check --json 2>/dev/null)" \
  '.worktree_enumeration == "ok"'

# ---- T12: an unsearchable parent is indeterminate, never "missing" ----------
# `test -e` reports no errno, so a live worktree whose parent directory denies
# search looks exactly like a deleted one. Classifying that as an orphan would
# delete a live worktree's registration, so the probe has to fail closed.
# Skipped when running as root, which bypasses directory permissions entirely
# and would make the fixture assert the opposite of what it is built to show.
if (( CAN_STAGE_UNSEARCHABLE == 0 )); then
  skip "T12: unsearchable-parent probe (running as root; permissions do not apply)"
else
  REPO_F="$TMP/repoF"
  mkdir -p "$REPO_F"
  git -C "$REPO_F" init -q
  echo "f" > "$REPO_F/README.md"
  git -C "$REPO_F" add README.md
  commit_old "$REPO_F" "repoF base"
  # The worktree is LIVE and stays live; only its parent becomes unsearchable.
  mkdir -p "$TMP/vaultF"
  git -C "$REPO_F" worktree add "$TMP/vaultF/wtF-live" -b issue-500-f-live >/dev/null 2>&1
  REG_F="$REPO_F/.git/worktrees"
  chmod 000 "$TMP/vaultF"

  OUT="$(cd "$REPO_F" && "$SUT" --check --json 2>/dev/null)"
  check_json "T12: unsearchable parent does NOT make the entry an orphan" "$OUT" \
    '(.orphaned_registrations | any(.id == "wtF-live")) | not'
  check_json "T12: it is reported as skipped, with absence-not-established named" "$OUT" \
    '.skipped_registrations | any(.id == "wtF-live"
                                  and (.reason | contains("absence not established")))'

  OUT="$(cd "$REPO_F" && "$SUT" --apply --include-locked 2>&1)"
  check_eq "T12: the live registration survives --apply --include-locked" "present" \
    "$([[ -e "$REG_F/wtF-live" ]] && echo present || echo gone)"

  # Positive control: the SAME entry must classify as an orphan once the parent
  # is searchable again and the worktree really is gone. Without this the two
  # assertions above would also pass if the registration pass had simply
  # stopped classifying anything at all.
  chmod 755 "$TMP/vaultF"
  rm -rf "$TMP/vaultF/wtF-live"
  OUT="$(cd "$REPO_F" && "$SUT" --check --json 2>/dev/null)"
  check_json "T12: genuinely missing worktree is still classified (control)" "$OUT" \
    '.orphaned_registrations | any(.id == "wtF-live" and .method == "prune")'
fi

# ---- T13: read_bounded_line returns without a subshell ----------------------
# run_bounded's orphan handover is a mutation of the CALLER's shell: on a child
# that outlived SIGKILL it appends that call's capture pair to
# ORPHANED_CAPTURES and points CAPTURE/CAPTURE_ERR at fresh files, so the
# parent stops truncating and re-reading files the orphan still holds open.
# read_bounded_line used to hand its answer back on stdout, which forced every
# call site into `$(...)` — and a command substitution runs run_bounded in a
# subshell, where the handover dies with it.
#
# A real wedged child needs uninterruptible I/O (a hung network mount), which a
# test cannot manufacture: a FIFO read like T11's is interruptible, so SIGKILL
# ends it and the handover branch never runs. The harness therefore stubs
# run_bounded with exactly that branch and drives the extracted function three
# ways — the value path, the wedged path as a statement, and the wedged path
# through the substitution the old shape required. Scenario 3 is the control:
# without it, scenario 2 would also pass against a harness that could not
# detect a lost handover at all.
HARNESS="$TMP/handover-harness.sh"
cat > "$HARNESS" <<'HEOF'
#!/usr/bin/env bash
set -uo pipefail
SUT="$1"
READ_BOUND_SECS=2
BOUNDED_LINE=""
STUB_MODE="ok"
ORPHANED_CAPTURES=()

new_capture_pair() {
  CAPTURE="$(mktemp "${TMPDIR:-/tmp}/harness-cap.XXXXXX")"
  CAPTURE_ERR="$(mktemp "${TMPDIR:-/tmp}/harness-caperr.XXXXXX")"
}

# Stands in for run_bounded. "ok" leaves an answer in $CAPTURE and succeeds;
# "wedged" performs the real handover and returns 124, as run_bounded does for
# a child that survived SIGKILL.
run_bounded() { # bound, command...
  if [[ "$STUB_MODE" == "wedged" ]]; then
    ORPHANED_CAPTURES+=("$CAPTURE" "$CAPTURE_ERR")
    new_capture_pair
    return 124
  fi
  printf '/some/worktree/.git\nsecond line\n' > "$CAPTURE"
  return 0
}

eval "$(awk '/^read_bounded_line\(\) \{/,/^\}/' "$SUT")"

rotated() { [[ "$CAPTURE" != "$1" ]] && echo yes || echo no; }

# 1. Value transport, no command substitution anywhere in the call.
ORPHANED_CAPTURES=(); new_capture_pair; STUB_MODE="ok"
RC=0
read_bounded_line "/path/is/irrelevant/to/the/stub" || RC=$?
echo "scenario1 rc=$RC line=[$BOUNDED_LINE]"

# 2. Wedged path called as a statement — the handover must land right here.
ORPHANED_CAPTURES=(); new_capture_pair; BEFORE="$CAPTURE"; STUB_MODE="wedged"
RC=0
read_bounded_line "/path/is/irrelevant/to/the/stub" || RC=$?
echo "scenario2 rc=$RC orphans=${#ORPHANED_CAPTURES[@]} rotated=$(rotated "$BEFORE")"

# 3. Control: same stub, same wedged path, reached through the substitution the
#    stdout-returning shape forced on every caller. The handover is lost.
ORPHANED_CAPTURES=(); new_capture_pair; BEFORE="$CAPTURE"; STUB_MODE="wedged"
_discard="$(read_bounded_line "/path/is/irrelevant/to/the/stub" || true)"
echo "scenario3 orphans=${#ORPHANED_CAPTURES[@]} rotated=$(rotated "$BEFORE")"
HEOF

OUT="$(bash "$HARNESS" "$SUT" 2>&1)"
check_contains "T13: the read result comes back without a command substitution" \
  "scenario1 rc=0 line=[/some/worktree/.git]" "$OUT"
check_contains "T13: a wedged call hands the orphaned pair to the caller's shell" \
  "scenario2 rc=1 orphans=2 rotated=yes" "$OUT"
check_contains "T13: control — through \$(...) the same handover is lost" \
  "scenario3 orphans=0 rotated=no" "$OUT"

# The harness proves the function's shape; this pins the call sites, which is
# where the defect actually lived. Any `$(read_bounded_line ...)` reintroduces
# it no matter how the function returns.
check_eq "T13: no call site wraps read_bounded_line in a command substitution" 0 \
  "$(grep -cF "\$(read_bounded_line" "$SUT" || true)"

# ---- T14: the worktree classification loop survives an empty array -----------
# `enumerate_worktrees` failing is a supported degraded run: WORKTREES stays
# empty and the sweep continues to the registration pass, which is the pass
# that clears the cause. On bash 3.2 (macOS system bash) `set -u` makes
# "${WORKTREES[@]}" an `unbound variable` abort on an empty array, so the
# degraded run died before emitting anything at all.
#
# Asserted as "every iteration is guarded" rather than "there is exactly one
# guard": WORKTREES grew a second, correctly guarded consumer in issue #1417
# (the orphaned-checkout scan), which a fixed count of 1 would have failed for
# doing the right thing. Comparing the two counts keeps the invariant — no
# unguarded loop — and strengthens it as consumers are added. The control below
# keeps the comparison from passing vacuously at 0 == 0.
WT_GUARD_COUNT="$(grep -cF "if (( \${#WORKTREES[@]} > 0 )); then" "$SUT" || true)"
WT_LOOP_COUNT="$(grep -cF "for record in \"\${WORKTREES[@]}\"" "$SUT" || true)"
check_eq "T14: control — there is at least one WORKTREES iteration to guard" "yes" \
  "$([[ "$WT_LOOP_COUNT" -ge 1 ]] && echo yes || echo no)"
check_eq "T14: every WORKTREES iteration carries an empty-array guard" \
  "$WT_LOOP_COUNT" "$WT_GUARD_COUNT"

# The abort only reproduces on bash < 4.4, so the runtime half runs only where
# such a bash exists (macOS) and is skipped elsewhere, e.g. CI on bash 5.
BASH32=""
if [[ -x /bin/bash ]] && /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3\.'; then
  BASH32=/bin/bash
fi
if [[ -z "$BASH32" ]]; then
  echo "skip — T14: bash 3.2 runtime repro (no bash < 4.4 on this host; the guard is asserted statically above)"
else
  REPO_G="$TMP/repoG"
  mkdir -p "$REPO_G"
  git -C "$REPO_G" init -q
  echo "g" > "$REPO_G/README.md"
  git -C "$REPO_G" add README.md
  commit_old "$REPO_G" "repoG base"
  git -C "$REPO_G" worktree add "$TMP/wtG-stuck" -b issue-600-g-stuck >/dev/null 2>&1
  REG_G="$REPO_G/.git/worktrees"
  # Same debris shape as T11: a FIFO gitdir stalls `git worktree list`, so
  # enumeration times out and WORKTREES is left empty.
  rm -f "$REG_G/wtG-stuck/gitdir"
  mkfifo "$REG_G/wtG-stuck/gitdir"

  ERR_G="$TMP/repoG.err"
  OUT="$(cd "$REPO_G" && "$BASH32" "$SUT" --check 2>"$ERR_G")"
  # Exit status cannot tell these apart — an aborted run and a correctly
  # reported incomplete sweep both exit 1 — so assert on what was produced.
  check_eq "T14: bash 3.2 degraded run does not abort on the empty array" "" \
    "$(grep -o 'unbound variable' "$ERR_G" | head -1)"
  check_contains "T14: bash 3.2 degraded run still emits its report" \
    "Stale threshold:" "$OUT"
  check_contains "T14: bash 3.2 degraded run still reaches the registration pass" \
    "wtG-stuck" "$OUT"
fi

unset STALE_CLEANUP_TIMEOUT_SECS STALE_CLEANUP_READ_TIMEOUT_SECS

# ---- T15: telemetry must never change the exit contract (issue #1430) -------
# The usage-log append at the top of stale-cleanup.sh ran unguarded before
# argument parsing: an unset HOME died on the `set -u` expansion and a HOME
# without .claude/ died through `set -e` at the failed redirect — both before
# any work. Now both fall through, with no bash redirect diagnostic on stderr
# (stderr-first ordering per issue #1406).
RC=0
ERR="$(env -u HOME bash "$SUT" --help 2>&1 >/dev/null)" || RC=$?
check_eq "T15: --help exits 0 with HOME unset" "0" "$RC"
check_eq "T15b: no stderr with HOME unset" "" "$ERR"
RC=0
ERR="$(HOME="$TMP/t15-no-such-home" bash "$SUT" --help 2>&1 >/dev/null)" || RC=$?
check_eq "T15c: --help exits 0 when \$HOME/.claude is missing" "0" "$RC"
check_eq "T15d: no shell diagnostic when the log dir is missing" "" "$ERR"

# ---- T16: the sweep's own git calls are bounded (issue #1404) ---------------
# PR #1386 bounded the enumeration; the calls the sweep makes AFTER it —
# `for-each-ref`, `branch -D`, the per-worktree dirty checks — were still
# unbounded, and on the filesystem behind #1363 they stall exactly the same way.
# The two halves of the contract are asserted separately because they are
# deliberately different: a classification call DEGRADES (the run continues so
# the registration sweep still clears the cause), a deletion is a per-item
# `failed:` that reaches exit 2.
GIT_STUB="$TMP/gitstub"
mkdir -p "$GIT_STUB"
cp "$STUB_BIN/gh" "$GIT_STUB/gh"
REAL_GIT="$(command -v git)"
export REAL_GIT
cat > "$GIT_STUB/stub-sleeper" <<'EOF'
#!/usr/bin/env bash
# Self-limited (~10s) so a failed process-group kill cannot leak a sleeper.
for _ in $(seq 1 50); do
  printf 'tick\n' >> "$TICK_FILE"
  sleep 0.2
done
EOF
chmod +x "$GIT_STUB/stub-sleeper"
export TICK_FILE="$TMP/t16-tick"
: > "$TICK_FILE"

# A repo of its own: one stale local branch, no worktrees, so exactly one
# deletion is attempted and the stall costs one bound, not one per item.
REPO_T16="$TMP/repoT16"
git init -q -b main "$REPO_T16"
git -C "$REPO_T16" config user.email "test@example.com"
git -C "$REPO_T16" config user.name "Test"
echo "t16" > "$REPO_T16/file.txt"
git -C "$REPO_T16" add file.txt
commit_old "$REPO_T16" "t16 base"
git -C "$REPO_T16" branch issue-900-t16-stale

# The stall marker is the load-immune stand-in for a wall-clock assertion
# (issue #1537). The line after `sleep 30` is reached ONLY when the stall ran to
# completion — i.e. the sweep waited it out instead of cutting it short — and in
# that case it is written before the sweep returns, so the check below cannot
# race it. A duration cannot say this on a loaded host: an elapsed reading is
# scheduler noise (115s observed under ~20 concurrent agents) and `< 40` was in
# any case satisfied by a single fully-waited-out 30s stall, so it asserted
# almost nothing while flaking on load.
make_git_stub() { # stalling-subcommand
  cat > "$GIT_STUB/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/t16-argv.log"
for a in "\$@"; do
  if [[ "\$a" == "$1" ]]; then
    "$GIT_STUB/stub-sleeper" &
    sleep 30
    printf '%s\n' "\$*" >> "$TMP/t16-stall-completed"
  fi
done
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$GIT_STUB/git"
}

# T16a — a wedged `for-each-ref` degrades: no classification, but the run
# finishes, says so, and reports exit 1 (incomplete sweep) rather than 0.
# 3s, not 1s: the clock is whole-second, so a 1s bound can trip before the stub
# is even live.
: > "$TMP/t16-argv.log"
: > "$TMP/t16-stall-completed"
make_git_stub for-each-ref
START="$(date +%s)"
RC=0
OUT="$(cd "$REPO_T16" && PATH="$GIT_STUB:$PATH" STALE_CLEANUP_TIMEOUT_SECS=3 \
  "$SUT" --check --json 2>"$TMP/t16-err.log")" || RC=$?
ELAPSED=$(( $(date +%s) - START ))
check_eq "T16a: a wedged for-each-ref still exits (1, incomplete sweep)" "1" "$RC"
check_json "T16a: ref_scan reports the timeout" "$OUT" '.ref_scan == "timed_out"'
check_json "T16a: and no branch is classified from a pass that never ran" "$OUT" \
  '(.stale_local_branches | length) == 0'
check_contains "T16a: the warning names the bound that tripped" \
  "exceeded 3s and was killed" "$(cat "$TMP/t16-err.log")"
if [[ ! -s "$TMP/t16-stall-completed" ]]; then
  pass "T16a: the 30s stall was cut short, not waited out (ran in ${ELAPSED}s)"
else
  fail "T16a: the stub's 30s stall ran to completion — the bound did not hold"
fi
if grep -q 'for-each-ref' "$TMP/t16-argv.log"; then
  pass "T16a: control — the stalling subcommand really was invoked"
else
  fail "T16a: control — the stub never saw for-each-ref, so nothing was bounded"
fi
# The degrade must not swallow the registration pass, which is the pass that
# clears the cause of the stall in the first place.
check_json "T16a: the registration scan still ran" "$OUT" '.registration_scan != "unavailable"'

# T16b — a wedged deletion is a per-item failure and reaches exit 2, rather
# than aborting the sweep or being reported as a success.
: > "$TMP/t16-argv.log"
: > "$TMP/t16-stall-completed"
make_git_stub -D
START="$(date +%s)"
RC=0
OUT="$(cd "$REPO_T16" && PATH="$GIT_STUB:$PATH" STALE_CLEANUP_TIMEOUT_SECS=3 \
  "$SUT" --apply 2>/dev/null)" || RC=$?
ELAPSED=$(( $(date +%s) - START ))
check_eq "T16b: a wedged branch deletion exits 2 (deletion failure)" "2" "$RC"
check_contains "T16b: reported as a per-item failure naming the bound" \
  "failed: local branch issue-900-t16-stale — 'git branch -D' exceeded 3s and was killed" "$OUT"
if [[ ! -s "$TMP/t16-stall-completed" ]]; then
  pass "T16b: the 30s stall was cut short, not waited out (ran in ${ELAPSED}s)"
else
  fail "T16b: the stub's 30s stall ran to completion — the bound did not hold"
fi
check_eq "T16b: control — the branch is still there, so nothing was reported removed" \
  "issue-900-t16-stale" \
  "$(git -C "$REPO_T16" for-each-ref --format='%(refname:short)' refs/heads/issue-900-t16-stale)"

# T16c — control: with nothing stalling, the same stub sweeps normally. Without
# it, T16a/T16b would also pass against a stub that broke every git call.
: > "$TMP/t16-argv.log"
cat > "$GIT_STUB/git" <<EOF
#!/usr/bin/env bash
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GIT_STUB/git"
RC=0
OUT="$(cd "$REPO_T16" && PATH="$GIT_STUB:$PATH" STALE_CLEANUP_TIMEOUT_SECS=3 \
  "$SUT" --apply 2>/dev/null)" || RC=$?
check_eq "T16c: control — a pass-through stub sweeps cleanly (exit 0)" "0" "$RC"
check_contains "T16c: control — and the branch is removed for real" \
  "removed: local branch issue-900-t16-stale" "$OUT"
pkill -f "$GIT_STUB/stub-sleeper" >/dev/null 2>&1 || true

# ---- T17: the --help network-bound contract (issues #1479, #1509) -----------
# print_help emits the header verbatim, so the header IS the CLI contract. It
# used to state that STALE_CLEANUP_NET_TIMEOUT_SECS bounds "the one NETWORK
# call, `git push origin --delete`". That was false: fetch_open_prs' `gh pr
# list` is a second network call, and until issue #1509 it was the ONLY
# unbounded one — running on every invocation, before any classification. The
# header's "where the bound stops" paragraph, which exists precisely to
# enumerate the unbounded edges, omitted it, so a reader consulting --help for
# the remaining hang surface would conclude every network path was bounded.
#
# Issue #1509 bounded the call, so the disclosure the #1479 guard pinned had to
# invert with it: --help must now tie `gh pr list` to the bound that holds it,
# and must no longer call it unbounded. Both directions are asserted, and both
# are re-run against a reconstructed pre-fix header in T17d so neither can pass
# vacuously.
HELP_OUT="$(bash "$SUT" --help 2>/dev/null)"

# The premise these guards rest on: the open-PR invocation lives in gh_pr_page
# and is bounded there. Read the whole function body rather than one grepped
# line — the bounded call spans several lines, so a line-anchored match would
# report "unbounded" for a reflow (it did exactly that when #1509 landed).
GH_FN="$(awk '/^gh_pr_page\(\) \{/ { inside = 1 } inside { print } inside && /^\}/ { exit }' "$SUT")"
if printf '%s' "$GH_FN" | grep -q 'gh pr list --search'; then
  pass "T17: control — the open-PR gh invocation is present in gh_pr_page"
else
  fail "T17: control — no 'gh pr list --search' invocation in gh_pr_page; the guards below have no premise"
fi
if printf '%s' "$GH_FN" | grep -q 'run_bounded'; then
  pass "T17: the open-PR gh invocation runs under run_bounded (issue #1509)"
else
  fail "T17: the open-PR gh invocation is unbounded again — the --help claims below are now false (issue #1509)"
fi
# The pre-fix shape specifically: an unwrapped subshell around the gh call.
if grep -qF '( cd "$ROOT" && gh pr list' "$SUT"; then
  fail "T17: the pre-#1509 unbounded 'cd \$ROOT && gh pr list' subshell is back"
else
  pass "T17: the pre-#1509 unbounded gh subshell is gone"
fi

# T17a — the false single-network-call claim must not come back.
if printf '%s' "$HELP_OUT" | grep -q 'the one NETWORK call'; then
  fail "T17a: --help still claims 'the one NETWORK call' — gh pr list is a second one"
else
  pass "T17a: --help no longer claims a single network call"
fi

# T17b/T17c — --help must name the open-PR query and TIE it to the bound that
# holds it, on one line. The tie is the env var, not the word "bounded":
# "unbounded" contains "bounded", so the weaker needle would pass on the very
# text this guard exists to catch — the same vacuous-pass trap the pre-#1509
# draft of T17c fell into with a bare search for "unbounded".
check_contains "T17b: --help names the open-PR query" "gh pr list" "$HELP_OUT"
if printf '%s' "$HELP_OUT" | grep -i 'gh pr list' | grep -q 'STALE_CLEANUP_GH_TIMEOUT_SECS'; then
  pass "T17c: --help ties the open-PR query to the bound that holds it"
else
  fail "T17c: --help mentions gh pr list but never names STALE_CLEANUP_GH_TIMEOUT_SECS"
fi
# T17e — and the superseded disclosure must not survive alongside it: no line
# may still describe the open-PR query as unbounded.
if printf '%s' "$HELP_OUT" | grep -i 'gh pr list' | grep -qi 'unbounded'; then
  fail "T17e: --help still calls the open-PR query unbounded (issue #1509 bounded it)"
else
  pass "T17e: --help no longer calls the open-PR query unbounded"
fi

# T17d — negative controls. Each assertion above is re-run against a
# reconstructed PRE-fix header: an assertion that cannot tell the two apart is
# proving nothing. First the #1479 wording, then the #1509 one.
PREFIX_SUT="$TMP/stale-cleanup-prefix.sh"
sed -e 's/the network DELETION, `git push origin --delete`/the one NETWORK call, `git push origin --delete`/' \
    "$SUT" > "$PREFIX_SUT"
PREFIX_HELP="$(bash "$PREFIX_SUT" --help 2>/dev/null)"
if printf '%s' "$PREFIX_HELP" | grep -q 'the one NETWORK call'; then
  pass "T17d: negative control — T17a's assertion does fire on the pre-fix wording"
else
  fail "T17d: negative control — the pre-fix wording was not reproduced, so T17a proves nothing"
fi

PREFIX_SUT_GH="$TMP/stale-cleanup-prefix-gh.sh"
sed -e 's/`gh pr list` (fetch_open_prs) runs under STALE_CLEANUP_GH_TIMEOUT_SECS and/`gh pr list` (fetch_open_prs) is the only network call that runs UNBOUNDED and/' \
    "$SUT" > "$PREFIX_SUT_GH"
PREFIX_HELP_GH="$(bash "$PREFIX_SUT_GH" --help 2>/dev/null)"
if printf '%s' "$PREFIX_HELP_GH" | grep -i 'gh pr list' | grep -q 'STALE_CLEANUP_GH_TIMEOUT_SECS'; then
  fail "T17f: negative control — T17c passes on the pre-#1509 header too, so it proves nothing"
else
  pass "T17f: negative control — T17c's assertion goes red on the pre-#1509 header"
fi
if printf '%s' "$PREFIX_HELP_GH" | grep -i 'gh pr list' | grep -qi 'unbounded'; then
  pass "T17f: negative control — T17e's assertion does fire on the pre-#1509 header"
else
  fail "T17f: negative control — the pre-#1509 disclosure was not reproduced, so T17e proves nothing"
fi

# ---- T18: the open-PR query is bounded and fails closed (issue #1509) -------
# `gh pr list` (fetch_open_prs) runs on EVERY invocation, before any
# classification, and until #1509 it was the one unbounded network call in a
# script whose stated purpose is that the sweep must never hang. Bounding it is
# only half the contract: the open-PR set is what stands between this sweep and
# deleting a branch that has an open PR, so an expired bound has to refuse the
# whole run — "could not verify" must never mean "no open PRs".
GH_STALL_BIN="$TMP/ghstub"
mkdir -p "$GH_STALL_BIN"

# One stale branch WITH an open PR in the fixture and one WITHOUT. The pair is
# what makes the fail-closed assertion bite: a run that fell through to an empty
# PR set would classify both as deletable and, under --apply, remove them.
REPO_T18="$TMP/repoT18"
git init -q -b main "$REPO_T18"
git -C "$REPO_T18" config user.email "test@example.com"
git -C "$REPO_T18" config user.name "Test"
echo "t18" > "$REPO_T18/file.txt"
git -C "$REPO_T18" add file.txt
commit_old "$REPO_T18" "t18 base"
git -C "$REPO_T18" branch issue-901-t18-openpr
git -C "$REPO_T18" branch issue-902-t18-stale

cat > "$TMP/t18-prs.json" <<'FIXTURE'
[{"headRefName":"issue-901-t18-openpr","createdAt":"2026-07-01T00:00:00Z"}]
FIXTURE

# T18a — a wedged `gh pr list` is killed at the bound and the sweep refuses.
cat > "$GH_STALL_BIN/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/t18-argv.log"
case "\$*" in
  "pr list"*)
    # The self-limiting sleeper (shared with T16) so a failed process-group
    # kill cannot leak a survivor; then stall far past any bound under test.
    "$GIT_STUB/stub-sleeper" &
    sleep 30
    # Stall marker — see make_git_stub above (issue #1537).
    printf '%s\n' "\$*" >> "$TMP/t18-stall-completed"
    ;;
esac
cat "$TMP/t18-prs.json"
EOF
chmod +x "$GH_STALL_BIN/gh"
: > "$TMP/t18-argv.log"
: > "$TMP/t18-stall-completed"
START="$(date +%s)"
RC=0
OUT="$(cd "$REPO_T18" && PATH="$GH_STALL_BIN:$PATH" STALE_CLEANUP_GH_TIMEOUT_SECS=3 \
  "$SUT" --apply 2>"$TMP/t18-err.log")" || RC=$?
ELAPSED=$(( $(date +%s) - START ))
T18_ERR="$(cat "$TMP/t18-err.log")"
check_eq "T18a: a wedged 'gh pr list' exits 4" "4" "$RC"
check_contains "T18a: and refuses on an unverified open-PR set" \
  "refusing to run with an unverified open-PR set" "$T18_ERR"
check_contains "T18a: naming the bound that tripped" \
  "exceeded 3s and was killed" "$T18_ERR"
# The stub stalls 30s, which is exactly what the unbounded call waited out, so
# the property to assert is that the stall was CUT SHORT. This used to read
# `ELAPSED < 15` — sound arithmetic (a 3s bound, a 2s TERM grace, a 3s reap) but
# measured against a clock the test does not own, and the tightest of the file's
# three gates. Same marker as T16 (issue #1537): written only if the stall ran
# out, and written before the sweep could return, so load cannot move it.
if [[ ! -s "$TMP/t18-stall-completed" ]]; then
  pass "T18a: the 30s stall was cut short, not waited out (ran in ${ELAPSED}s)"
else
  fail "T18a: the stub's 30s stall ran to completion — the bound did not hold"
fi
if grep -q 'pr list' "$TMP/t18-argv.log"; then
  pass "T18a: control — the stalling 'gh pr list' really was invoked"
else
  fail "T18a: control — the stub never saw 'pr list', so nothing was bounded"
fi
# The fail-closed half, under --apply so a fall-through would really delete.
if git -C "$REPO_T18" show-ref --verify --quiet refs/heads/issue-902-t18-stale; then
  pass "T18a: fail-closed — the PR-free stale branch survives an unverified PR set"
else
  fail "T18a: fail-closed — a branch was deleted on an unverified open-PR set"
fi
if git -C "$REPO_T18" show-ref --verify --quiet refs/heads/issue-901-t18-openpr; then
  pass "T18a: fail-closed — the open-PR branch survives too"
else
  fail "T18a: fail-closed — the open-PR branch was deleted"
fi
if printf '%s' "$OUT" | grep -q 'removed:'; then
  fail "T18a: fail-closed — a deletion was reported despite refusing to classify"
else
  pass "T18a: fail-closed — nothing was reported removed"
fi

# T18b — pagination survives the rewiring. The page now comes out of $CAPTURE
# rather than the function's stdout, and the `created:<cursor` walk runs on it;
# a first page of exactly --limit entries is what forces the second fetch.
GH_PAGE_BIN="$TMP/ghstub-page"
mkdir -p "$GH_PAGE_BIN"
jq -n '[range(1000) | {headRefName: "pr-filler-\(.)", createdAt: "2026-07-02T00:00:00Z"}]' \
  > "$TMP/t18-page1.json"
cp "$TMP/t18-prs.json" "$TMP/t18-page2.json"
cat > "$GH_PAGE_BIN/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/t18-page-argv.log"
case "\$*" in
  *"created:<"*) cat "$TMP/t18-page2.json" ;;
  "pr list"*)    cat "$TMP/t18-page1.json" ;;
  *)             echo "[]" ;;
esac
EOF
chmod +x "$GH_PAGE_BIN/gh"
: > "$TMP/t18-page-argv.log"
RC=0
OUT="$(cd "$REPO_T18" && PATH="$GH_PAGE_BIN:$PATH" "$SUT" --check --json 2>/dev/null)" || RC=$?
check_eq "T18b: a multi-page fetch completes (exit 1, stale items found)" "1" "$RC"
if grep -q 'created:<' "$TMP/t18-page-argv.log"; then
  pass "T18b: control — a second page really was requested"
else
  fail "T18b: control — no 'created:<' page was requested, so pagination never ran"
fi
check_json "T18b: the open-PR branch served on page 2 is skipped as such" "$OUT" \
  '.skipped_local_branches | any(.branch == "issue-901-t18-openpr" and .reason == "open PR")'
check_json "T18b: and the PR-free branch is still classified stale" "$OUT" \
  '.stale_local_branches | map(.branch) | index("issue-902-t18-stale") != null'

# T18c — control: with nothing stalling, the same stub shape sweeps for real.
# Without it, T18a would also pass against a stub that simply broke every call.
: > "$TMP/t18-argv.log"
cat > "$GH_STALL_BIN/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/t18-argv.log"
case "\$*" in
  "pr list"*) cat "$TMP/t18-prs.json" ;;
  *)          echo "[]" ;;
esac
EOF
chmod +x "$GH_STALL_BIN/gh"
RC=0
OUT="$(cd "$REPO_T18" && PATH="$GH_STALL_BIN:$PATH" STALE_CLEANUP_GH_TIMEOUT_SECS=3 \
  "$SUT" --apply 2>/dev/null)" || RC=$?
check_eq "T18c: control — a non-stalling gh sweeps cleanly (exit 0)" "0" "$RC"
check_contains "T18c: control — the PR-free branch is removed for real" \
  "removed: local branch issue-902-t18-stale" "$OUT"
if git -C "$REPO_T18" show-ref --verify --quiet refs/heads/issue-901-t18-openpr; then
  pass "T18c: control — the open-PR branch is skipped, not deleted"
else
  fail "T18c: control — the open-PR branch was deleted despite an open PR"
fi
pkill -f "$GIT_STUB/stub-sleeper" >/dev/null 2>&1 || true

# ---- T19: orphaned worktree checkouts (issue #1417) --------------------------
# The inverse of T9's class: a checkout on disk whose registration is gone.
# repoH holds two checkouts under .claude/worktrees/ — one whose registration is
# moved aside (the shape the 2026-08-26 incident left 59 of) and one left
# registered as the negative control.
#
# Both are created off a FRESH tip, for the same reason T9's live worktree is:
# on an old tip the pre-existing stale-worktree pass would remove the registered
# control under --apply, and "the control survived" would then pass or fail for
# a reason unrelated to this class.
REPO_H="$TMP/repoH"
mkdir -p "$REPO_H"
git -C "$REPO_H" init -q
echo "e" > "$REPO_H/README.md"
git -C "$REPO_H" add README.md
commit_old "$REPO_H" "repoH base"
echo "fresh" >> "$REPO_H/README.md"
git -C "$REPO_H" commit -q -am "repoH fresh tip"
mkdir -p "$REPO_H/.claude/worktrees"
CO_ORPHAN="$REPO_H/.claude/worktrees/orphan-co"
CO_LIVE="$REPO_H/.claude/worktrees/registered-co"
git -C "$REPO_H" worktree add "$CO_ORPHAN" -b issue-400-h-orphan >/dev/null 2>&1
git -C "$REPO_H" worktree add "$CO_LIVE" -b issue-401-h-registered >/dev/null 2>&1
# Carry a file that exists nowhere else, so "the working tree was deleted" is
# observable as more than the directory's absence.
echo "work in progress" > "$CO_ORPHAN/NOTES.md"
# Move the registration aside rather than deleting it — this is exactly what the
# incident's quarantine did, and it leaves the checkout's .git gitdir dangling.
mv "$REPO_H/.git/worktrees/orphan-co" "$TMP/quarantined-orphan-co"

OUT="$(cd "$REPO_H" && "$SUT" --check --json 2>/dev/null)"
RC=$?
# The exit code is the contract under test as much as the report is: this class
# is report-only, and plain --apply can never clear it, so it must NOT raise
# exit 1 the way every other reported class does.
check_eq "T19: an orphaned checkout alone does NOT change the exit code" 0 "$RC"
check_json "T19: the orphaned checkout is reported" "$OUT" \
  '.orphaned_checkouts | any((.path | endswith("/orphan-co"))
                             and (.gitdir | endswith("/.git/worktrees/orphan-co"))
                             and (.reason | contains("registration missing")))'
check_json "T19: checkout_scan is ok" "$OUT" '.checkout_scan == "ok"'
# Negative control — a registered worktree in the same scanned directory is
# never this class, and is not parked in the skipped list either.
check_json "T19: registered checkout appears in neither checkout list (negative control)" "$OUT" \
  '(.orphaned_checkouts | any(.path | endswith("/registered-co")) | not)
   and (.skipped_checkouts | any(.path | endswith("/registered-co")) | not)'
check_json "T19: the pre-existing classes are unaffected" "$OUT" \
  '.worktree_enumeration == "ok" and .registration_scan == "ok" and .ref_scan == "ok"
   and (.orphaned_registrations | length) == 0'

OUT="$(cd "$REPO_H" && "$SUT" --check 2>/dev/null)"
check_contains "T19: text output carries the report-only section" \
  "Orphaned worktree checkouts (report-only" "$OUT"
check_contains "T19: text output names the checkout" "orphan-co" "$OUT"

# --- plain --apply must never delete a working tree ---------------------------
OUT="$(cd "$REPO_H" && "$SUT" --apply 2>&1)"
RC=$?
check_eq "T19: plain --apply exits 0" 0 "$RC"
check_eq "T19: plain --apply leaves the orphaned checkout on disk" "present" \
  "$([[ -d "$CO_ORPHAN" ]] && echo present || echo gone)"
check_eq "T19: and leaves its uncommitted file intact" "present" \
  "$([[ -f "$CO_ORPHAN/NOTES.md" ]] && echo present || echo gone)"
check_contains "T19: plain --apply says why it removed nothing" \
  "were NOT removed" "$OUT"

# --- the flag without --apply is a usage error --------------------------------
( cd "$REPO_H" && "$SUT" --check --remove-orphaned-checkouts >/dev/null 2>&1 )
check_eq "T19: --remove-orphaned-checkouts without --apply exits 3" 3 "$?"
( cd "$REPO_H" && "$SUT" --remove-orphaned-checkouts >/dev/null 2>&1 )
check_eq "T19: and exits 3 in the default (check) mode too" 3 "$?"
check_eq "T19: neither usage error deleted anything" "present" \
  "$([[ -d "$CO_ORPHAN" ]] && echo present || echo gone)"

# --- the explicit gate does remove it, and only it ----------------------------
OUT="$(cd "$REPO_H" && "$SUT" --apply --remove-orphaned-checkouts 2>&1)"
RC=$?
check_eq "T19: --apply --remove-orphaned-checkouts exits 0" 0 "$RC"
check_contains "T19: the removal is reported per item" \
  "removed: orphaned checkout" "$OUT"
if [[ "$OUT" == *"failed:"* ]]; then
  fail "T19: no failure lines on the clean removal run"
else
  pass "T19: no failure lines on the clean removal run"
fi
check_eq "T19: the orphaned checkout is gone" "gone" \
  "$([[ -e "$CO_ORPHAN" ]] && echo present || echo gone)"
check_eq "T19: the REGISTERED checkout survives the removal run (negative control)" "present" \
  "$([[ -d "$CO_LIVE" ]] && echo present || echo gone)"
# The quarantined registration is the operator's recovery material — the flag
# deletes checkouts, never the bookkeeping that was moved aside.
check_eq "T19: the moved-aside registration is untouched" "present" \
  "$([[ -d "$TMP/quarantined-orphan-co" ]] && echo present || echo gone)"

OUT="$(cd "$REPO_H" && "$SUT" --check --json 2>/dev/null)"
RC=$?
check_eq "T19: a swept repoH is clean (exit 0)" 0 "$RC"
check_json "T19: nothing is left in the orphaned-checkout list" "$OUT" \
  '(.orphaned_checkouts | length) == 0 and .checkout_scan == "ok"'

# --- a symlinked .git is never this class -------------------------------------
# `-f` follows symlinks, so a `.git` swapped for a link to an arbitrary file
# carrying a `gitdir:` line would otherwise classify — and then be deleted by
# the removal flag. The link here points at a dangling target, which is exactly
# the content that would classify if the symlink check were missing.
CO_SYMLINK="$REPO_H/.claude/worktrees/symlinked-co"
mkdir -p "$CO_SYMLINK"
printf 'gitdir: %s\n' "$TMP/definitely-not-here" > "$TMP/planted-gitdir"
ln -s "$TMP/planted-gitdir" "$CO_SYMLINK/.git"
OUT="$(cd "$REPO_H" && "$SUT" --check --json 2>/dev/null)"
check_json "T19: a symlinked .git is skipped, never classified orphaned" "$OUT" \
  '(.skipped_checkouts | any((.path | endswith("/symlinked-co"))
                             and (.reason | contains("symlink"))))
   and (.orphaned_checkouts | any(.path | endswith("/symlinked-co")) | not)'
OUT="$(cd "$REPO_H" && "$SUT" --apply --remove-orphaned-checkouts 2>&1)"
check_eq "T19: the removal flag leaves the symlinked-.git directory alone" "present" \
  "$([[ -d "$CO_SYMLINK" ]] && echo present || echo gone)"
check_eq "T19: and does not follow the link to delete its target" "present" \
  "$([[ -f "$TMP/planted-gitdir" ]] && echo present || echo gone)"

# --- the flag is documented where operators look for it ------------------------
# The header block IS the --help output, so a flag that deletes working trees
# must be discoverable there and must say so.
HELP_OUT="$("$SUT" --help 2>&1)"
check_contains "T19: --help documents the removal flag" \
  "--remove-orphaned-checkouts" "$HELP_OUT"
check_contains "T19: --help says the flag deletes working-tree files" \
  "DELETES WORKING-TREE" "$HELP_OUT"
check_contains "T19: --help documents the report-only class" \
  "ORPHANED WORKTREE CHECKOUTS" "$HELP_OUT"

# --- a DANGLING registration symlink is not proven absence ---------------------
# `test -e` follows symlinks, so a link whose target is missing reads as
# "provably absent" — and the 2026-08-26 mitigation moved registrations aside,
# so a link into a quarantine on an unmounted volume dangles exactly like this.
# Deleting the working tree on that basis is the data loss this class exists to
# avoid.
CO_DANGLE="$REPO_H/.claude/worktrees/dangling-co"
mkdir -p "$CO_DANGLE"
ln -s "$TMP/quarantine-that-is-not-mounted" "$REPO_H/.git/worktrees/dangling-reg"
printf 'gitdir: %s\n' "$REPO_H/.git/worktrees/dangling-reg" > "$CO_DANGLE/.git"
# Control in the same run — a plainly missing target still classifies, so the
# assertion below pins the dangling-link discriminator, not "nothing classifies".
CO_PLAIN="$REPO_H/.claude/worktrees/plain-missing-co"
mkdir -p "$CO_PLAIN"
printf 'gitdir: %s\n' "$REPO_H/.git/worktrees/never-existed" > "$CO_PLAIN/.git"
OUT="$(cd "$REPO_H" && "$SUT" --check --json 2>/dev/null)"
check_json "T19: a dangling registration symlink is skipped, not classified orphaned" "$OUT" \
  '(.skipped_checkouts | any((.path | endswith("/dangling-co"))
                             and (.reason | contains("dangling symlink"))))
   and (.orphaned_checkouts | any(.path | endswith("/dangling-co")) | not)'
check_json "T19: control — a plainly missing target in the same run does classify" "$OUT" \
  '.orphaned_checkouts | any(.path | endswith("/plain-missing-co"))'
OUT="$(cd "$REPO_H" && "$SUT" --apply --remove-orphaned-checkouts 2>&1)"
check_eq "T19: the removal flag leaves the dangling-symlink checkout alone" "present" \
  "$([[ -d "$CO_DANGLE" ]] && echo present || echo gone)"
check_eq "T19: control — the plainly-missing one was removed in that same run" "gone" \
  "$([[ -e "$CO_PLAIN" ]] && echo present || echo gone)"
rm -rf "$CO_DANGLE" "$REPO_H/.git/worktrees/dangling-reg"

# --- an oversized .git is refused, not truncated -------------------------------
# The read that decides this class feeds a working-tree deletion, so a `.git`
# too large to be one is rejected rather than read whole and truncated — a
# truncated `gitdir:` path names a registration that does not exist, which is
# precisely the shape that classifies a checkout as orphaned.
CO_FAT="$REPO_H/.claude/worktrees/fat-co"
mkdir -p "$CO_FAT"
{ printf 'gitdir: %s' "$TMP/definitely-not-here"; head -c 8192 /dev/zero | tr '\0' 'x'; } > "$CO_FAT/.git"
OUT="$(cd "$REPO_H" && "$SUT" --check --json 2>/dev/null)"
check_json "T19: an oversized .git is skipped, never classified orphaned" "$OUT" \
  '(.skipped_checkouts | any((.path | endswith("/fat-co"))
                             and (.reason | contains("gitdir target"))))
   and (.orphaned_checkouts | any(.path | endswith("/fat-co")) | not)'
OUT="$(cd "$REPO_H" && "$SUT" --apply --remove-orphaned-checkouts 2>&1)"
check_eq "T19: and the removal flag leaves it alone" "present" \
  "$([[ -d "$CO_FAT" ]] && echo present || echo gone)"
# Control — the same content UNDER the cap classifies, so the assertions above
# are pinning the size gate rather than the dangling target.
CO_THIN="$REPO_H/.claude/worktrees/thin-co"
mkdir -p "$CO_THIN"
printf 'gitdir: %s\n' "$TMP/definitely-not-here" > "$CO_THIN/.git"
OUT="$(cd "$REPO_H" && "$SUT" --check --json 2>/dev/null)"
check_json "T19: control — the same dangling target under the cap does classify" "$OUT" \
  '.orphaned_checkouts | any(.path | endswith("/thin-co"))'
rm -rf "$CO_FAT" "$CO_THIN"

# --- the scan dir is resolved before the wide-path guard ----------------------
# A symlink pointing at the repo root sails past a literal comparison, and a
# scan dir that wide would offer every top-level directory to a flag that
# deletes working trees. The guard must reject what the path RESOLVES to.
ln -s "$REPO_H" "$TMP/link-to-repoH"
( cd "$REPO_H" && STALE_CLEANUP_CHECKOUT_DIR="$TMP/link-to-repoH" "$SUT" --check >/dev/null 2>&1 )
check_eq "T19: a scan dir symlinked to the repo root is refused (exit 3)" 3 "$?"
( cd "$REPO_H" && STALE_CLEANUP_CHECKOUT_DIR="$REPO_H" "$SUT" --check >/dev/null 2>&1 )
check_eq "T19: and so is the repo root named directly" 3 "$?"
# Control — without it the two assertions above would also pass against a
# script that rejected every override, or every run.
( cd "$REPO_H" && STALE_CLEANUP_CHECKOUT_DIR="$REPO_H/.claude/worktrees" "$SUT" --check >/dev/null 2>&1 )
check_eq "T19: control — an ordinary override is accepted (exit 0)" 0 "$?"

# --- a repo with no checkout directory reports "none", not a finding ----------
OUT="$(cd "$REPO_D" && "$SUT" --check --json 2>/dev/null)"
check_json "T19: checkout_scan is none where .claude/worktrees does not exist" "$OUT" \
  '.checkout_scan == "none" and (.orphaned_checkouts | length) == 0'

# --- a dangling symlink ABOVE the registration is refused too -----------------
# `-L` on the final component alone misses this: under a `wt-link -> <gone>`
# parent, lstat cannot see the final component at all, so the final-component
# test reads FALSE while `test -e` still reports absent — "provably absent",
# and the working tree gets deleted. The target returns when the volume does.
CO_ANC="$REPO_H/.claude/worktrees/anc-dangling-co"
mkdir -p "$CO_ANC"
ln -s "$TMP/volume-that-is-not-mounted" "$REPO_H/.git/wt-link"
printf 'gitdir: %s\n' "$REPO_H/.git/wt-link/some-id" > "$CO_ANC/.git"
# Control in the same run — a RESOLVING symlink ancestor must still classify.
# Without it these assertions would also pass against a script that refused
# every path with any symlink above it, which on macOS ($TMPDIR under
# /var -> /private/var) would be very nearly every path there is.
CO_ANC_OK="$REPO_H/.claude/worktrees/anc-resolving-co"
mkdir -p "$CO_ANC_OK" "$TMP/live-reg-dir"
ln -s "$TMP/live-reg-dir" "$REPO_H/.git/wt-link-live"
printf 'gitdir: %s\n' "$REPO_H/.git/wt-link-live/never-existed" > "$CO_ANC_OK/.git"
OUT="$(cd "$REPO_H" && "$SUT" --check --json 2>/dev/null)"
check_json "T19: a dangling symlink ANCESTOR is skipped, not classified orphaned" "$OUT" \
  '(.skipped_checkouts | any((.path | endswith("/anc-dangling-co"))
                             and (.reason | contains("dangling symlink"))))
   and (.orphaned_checkouts | any(.path | endswith("/anc-dangling-co")) | not)'
check_json "T19: control — a RESOLVING symlink ancestor still classifies" "$OUT" \
  '.orphaned_checkouts | any(.path | endswith("/anc-resolving-co"))'
OUT="$(cd "$REPO_H" && "$SUT" --apply --remove-orphaned-checkouts 2>&1)"
check_eq "T19: the removal flag leaves the dangling-ancestor checkout alone" "present" \
  "$([[ -d "$CO_ANC" ]] && echo present || echo gone)"
check_eq "T19: control — the resolving-ancestor one was removed in that same run" "gone" \
  "$([[ -e "$CO_ANC_OK" ]] && echo present || echo gone)"
rm -rf "$CO_ANC" "$REPO_H/.git/wt-link" "$REPO_H/.git/wt-link-live" "$TMP/live-reg-dir"

# --- the pre-rm re-check refuses a dangling ANCESTOR too ----------------------
# The scan runs at start-up; the rm runs at the very end. A dangling ancestor
# appearing in THAT WINDOW is the state change this re-check exists to catch, so
# it must apply the same whole-path rule as the scan and not merely the
# final-component test — otherwise the working tree is deleted.
#
# Breaking the link between the two runs would prove nothing: the scan would
# then refuse it on its own and the re-check would never be consulted (that
# version of this test passed with the fix reverted). So the link is broken
# from INSIDE the window, by a git stub that fires on the `worktree prune` the
# apply phase runs before it reaches any checkout.
RACE_STUB="$TMP/race-stub"; mkdir -p "$RACE_STUB"
mkdir -p "$TMP/race-reg-dir"
cat > "$RACE_STUB/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == "prune" ]]; then rm -rf "$TMP/race-reg-dir"; fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$RACE_STUB/git"
# Bait so the apply phase actually reaches `worktree prune`: a registration
# whose worktree is gone is pruned, and that call sits between the two.
git -C "$REPO_H" worktree add "$TMP/prune-bait" -b issue-402-h-prunebait >/dev/null 2>&1
rm -rf "$TMP/prune-bait"
CO_RACE="$REPO_H/.claude/worktrees/race-co"
mkdir -p "$CO_RACE"
ln -s "$TMP/race-reg-dir" "$REPO_H/.git/wt-race"
printf 'gitdir: %s\n' "$REPO_H/.git/wt-race/never-existed" > "$CO_RACE/.git"
echo "only copy" > "$CO_RACE/unique.txt"
OUT="$(cd "$REPO_H" && "$SUT" --check --json 2>/dev/null)"
check_json "T19: the race checkout classifies while its ancestor link resolves" "$OUT" \
  '.orphaned_checkouts | any(.path | endswith("/race-co"))'
OUT="$(cd "$REPO_H" && PATH="$RACE_STUB:$PATH" "$SUT" --apply --remove-orphaned-checkouts 2>&1)"
check_eq "T19: the ancestor link really was broken mid-run" "gone" \
  "$([[ -e "$TMP/race-reg-dir" ]] && echo present || echo gone)"
check_eq "T19: the pre-rm re-check spares a checkout whose ancestor dangled mid-run" "present" \
  "$([[ -f "$CO_RACE/unique.txt" ]] && echo present || echo gone)"
# Positive control: with the ancestor intact for the whole run, that SAME
# checkout IS removed — so the assertion above pins the mid-run refusal rather
# than a re-check that had simply stopped removing anything.
mkdir -p "$TMP/race-reg-dir"
OUT="$(cd "$REPO_H" && "$SUT" --apply --remove-orphaned-checkouts 2>&1)"
check_eq "T19: control — an un-broken ancestor lets that same checkout be removed" "gone" \
  "$([[ -e "$CO_RACE" ]] && echo present || echo gone)"
rm -rf "$CO_RACE" "$REPO_H/.git/wt-race" "$TMP/race-reg-dir" "$RACE_STUB"

# --- a dangling ENTRY symlink is recorded, not silently dropped ---------------
# `-d` follows links, so testing it before `-L` both traverses into whatever the
# link points at — a stalled volume hangs the sweep — and drops a DANGLING
# directory symlink entirely, since its `-d` is false. It must be reported.
ln -s "$TMP/entry-target-not-mounted" "$REPO_H/.claude/worktrees/dangling-entry"
ln -s "$TMP/entry-target-live" "$REPO_H/.claude/worktrees/live-entry"
mkdir -p "$TMP/entry-target-live"
OUT="$(cd "$REPO_H" && "$SUT" --check --json 2>/dev/null)"
check_json "T19: a dangling entry symlink is recorded as skipped, not dropped" "$OUT" \
  '.skipped_checkouts | any((.path | endswith("/dangling-entry")) and (.reason | contains("symlink")))'
# Control — a RESOLVING entry symlink is still refused as a symlink (and was
# already, so this pins that the reorder did not stop recording either kind).
check_json "T19: control — a resolving entry symlink is still skipped as a symlink" "$OUT" \
  '.skipped_checkouts | any((.path | endswith("/live-entry")) and (.reason | contains("symlink")))'
check_json "T19: control — neither entry symlink is ever classified orphaned" "$OUT" \
  '.orphaned_checkouts | any((.path | endswith("-entry"))) | not'
rm -rf "$REPO_H/.claude/worktrees/dangling-entry" "$REPO_H/.claude/worktrees/live-entry" "$TMP/entry-target-live"

# --- a dangling SCAN dir is "unreadable", not "none" --------------------------
# `test -e` follows links, so a dangling scan directory probes as proven
# absence. But the name is a present entry whose target may return — the same
# detachable-volume case this pass refuses for gitdir targets.
ln -s "$TMP/scan-dir-not-mounted" "$TMP/dangling-scan"
OUT="$(cd "$REPO_H" && STALE_CLEANUP_CHECKOUT_DIR="$TMP/dangling-scan" "$SUT" --check --json 2>/dev/null)"
check_json "T19: a dangling scan dir reports unreadable, not none" "$OUT" \
  '.checkout_scan == "unreadable"'
# Control — a plainly absent scan dir (no link involved) still reports none, so
# the assertion above pins the dangling-link case and not "never says none".
OUT="$(cd "$REPO_H" && STALE_CLEANUP_CHECKOUT_DIR="$TMP/plainly-absent-scan" "$SUT" --check --json 2>/dev/null)"
check_json "T19: control — a plainly absent scan dir still reports none" "$OUT" \
  '.checkout_scan == "none"'
rm -f "$TMP/dangling-scan"

# --- an unreadable scan dir is "unreadable", never "none" ---------------------
# `-d` is false for BOTH "not there" and "there but unreadable". Collapsing the
# second into "none" would report a positive claim of absence — "this repo keeps
# no worktrees here" — drawn from a lookup that never happened. That is the
# macOS TCC shape that retired the old checkout in the first place.
mkdir -p "$TMP/vaultCO/worktrees"
chmod 000 "$TMP/vaultCO"
OUT="$(cd "$REPO_H" && STALE_CLEANUP_CHECKOUT_DIR="$TMP/vaultCO/worktrees" "$SUT" --check --json 2>/dev/null)"
check_json "T19: an unreadable scan dir reports checkout_scan unreadable, not none" "$OUT" \
  '.checkout_scan == "unreadable" and (.orphaned_checkouts | length) == 0'
check_json "T19: and says why, with absence-not-established named" "$OUT" \
  '.skipped_checkouts | any(.reason | contains("absence not established"))'
# Positive control: the SAME directory reports a clean scan once it is readable
# again. Without it the assertions above would also pass against a script that
# reported "unreadable" for every override, or every run.
chmod 755 "$TMP/vaultCO"
OUT="$(cd "$REPO_H" && STALE_CLEANUP_CHECKOUT_DIR="$TMP/vaultCO/worktrees" "$SUT" --check --json 2>/dev/null)"
check_json "T19: control — the same dir reports ok once readable" "$OUT" \
  '.checkout_scan == "ok"'
rm -rf "$TMP/vaultCO"

# ---- T20: the registration removal path's own guards (issue #1592) -----------
# PR #1591 hardened the orphaned-CHECKOUT removal path against four classes of
# defect. remove_registration is the sibling that deletes registration metadata,
# and it runs in the same directory shapes. These pin the three classes that
# turned out to apply to it. (The fourth — the checkout scan dir's
# "/-or-repo-root" width guard — has no analogue: $WORKTREE_REG_DIR is git's own
# <git-common-dir>/worktrees, never operator-supplied, and remove_registration
# only ever clears one segment beneath it.)
#
# repoI holds one registration per shape plus a live one, all created off a
# FRESH tip for the reason T9's live worktree is: on an old tip the pre-existing
# stale-worktree pass would remove the controls and the assertions would pass or
# fail for an unrelated reason.
REPO_I="$TMP/repoI"
mkdir -p "$REPO_I"
git -C "$REPO_I" init -q
echo "i" > "$REPO_I/README.md"
git -C "$REPO_I" add README.md
commit_old "$REPO_I" "repoI base"
echo "fresh" >> "$REPO_I/README.md"
git -C "$REPO_I" commit -q -am "repoI fresh tip"
REG_I="$REPO_I/.git/worktrees"

# Build a registration whose worktree is gone, then point its `gitdir` wherever
# the case needs. A registration's `gitdir` holds the bare path of the
# worktree's own .git file — no "gitdir:" prefix, unlike a checkout's .git.
make_reg() { # repo, id, gitdir contents (optional; default leaves git's own)
  git -C "$1" worktree add "$TMP/$2" -b "issue-500-$2" >/dev/null 2>&1
  rm -rf "${TMP:?}/$2"
  if [[ $# -ge 3 ]]; then printf '%s\n' "$3" > "$1/.git/worktrees/$2/gitdir"; fi
}

git -C "$REPO_I" worktree add "$TMP/wtI-live" -b issue-500-live >/dev/null 2>&1
make_reg "$REPO_I" wtI-plainmissing
make_reg "$REPO_I" wtI-thin "$TMP/definitely-not-here/.git"

# --- a worktree path that is a DANGLING SYMLINK is not proven absence --------
# `test -e` follows symlinks, so a link whose target is missing reads as
# "provably absent" and the registration is pruned — but the name is a present
# entry whose target can come back, which is exactly what the 2026-08-26
# quarantine-onto-a-detachable-volume shape looks like.
make_reg "$REPO_I" wtI-dangleleaf "$TMP/wtI-leaf-link/.git"
ln -s "$TMP/leaf-target-not-mounted" "$TMP/wtI-leaf-link"

# --- and so is a dangling symlink ABOVE it ------------------------------------
# `-L` on the final component alone misses this: under a dangling parent, lstat
# cannot see the leaf at all, so the leaf test reads FALSE while `test -e` still
# reports absent. One such ancestor covers EVERY registration beneath it, so a
# leaf-only test would clear a whole shelf of live entries in one sweep.
make_reg "$REPO_I" wtI-ancdangle "$TMP/anc-link-dead/wtI-ancdangle/.git"
ln -s "$TMP/anc-volume-not-mounted" "$TMP/anc-link-dead"
# Control in the same run — a RESOLVING symlink ancestor must still classify.
# Without it these assertions would also pass against a build that refused every
# path with any symlink above it, which on macOS ($TMPDIR under /var ->
# /private/var) is very nearly every path there is.
mkdir -p "$TMP/anc-live-dir"
make_reg "$REPO_I" wtI-ancok "$TMP/anc-link-live/wtI-ancok/.git"
ln -s "$TMP/anc-live-dir" "$TMP/anc-link-live"

# --- an oversized or symlinked `gitdir` is refused, not read whole -----------
# This read decides whether an entry is an orphan, and that verdict ends in an
# `rm -rf`. Uncapped, a planted `gitdir` is copied whole into a temp file and
# then a shell variable by the pass that makes that decision; followed, a link
# hands the same decision to a file we cannot vouch for.
make_reg "$REPO_I" wtI-fat
{ printf '%s' "$TMP/definitely-not-here/.git"; head -c 8192 /dev/zero | tr '\0' 'x'; } > "$REG_I/wtI-fat/gitdir"
make_reg "$REPO_I" wtI-symgitdir
printf '%s\n' "$TMP/definitely-not-here/.git" > "$TMP/planted-gitdir"
rm -f "$REG_I/wtI-symgitdir/gitdir"
ln -s "$TMP/planted-gitdir" "$REG_I/wtI-symgitdir/gitdir"

# --- a symlinked registration ENTRY is recorded, never classified ------------
# `-d` follows links, so testing it before `-L` traverses into whatever the link
# points at — a stalled volume hangs the sweep — and silently DROPS a dangling
# entry, whose `-d` is false. A resolving one is worse than dropped: it used to
# classify here and then hard-fail inside remove_registration as "not a plain
# directory", raising exit 2 on a sweep that had done nothing wrong.
ln -s "$TMP/reg-entry-not-mounted" "$REG_I/wtI-dangling-entry"
mkdir -p "$TMP/reg-entry-live-dir"
ln -s "$TMP/reg-entry-live-dir" "$REG_I/wtI-live-entry"

# --- an oversized `locked` reason never reaches the report -------------------
make_reg "$REPO_I" wtI-fatlock "$TMP/definitely-not-here/.git"
head -c 8192 /dev/zero | tr '\0' 'y' > "$REG_I/wtI-fatlock/locked"
make_reg "$REPO_I" wtI-thinlock "$TMP/definitely-not-here/.git"
printf 'claude agent wtI-thinlock (pid 4242)\n' > "$REG_I/wtI-thinlock/locked"

OUT="$(cd "$REPO_I" && "$SUT" --check --json 2>/dev/null)"
check_json "T20: the registration scan still completed" "$OUT" \
  '.registration_scan == "ok"'
check_json "T20: control — a plainly missing worktree still classifies" "$OUT" \
  '.orphaned_registrations | any(.id == "wtI-plainmissing" and .method == "prune")'
check_json "T20: control — the live registration is in neither list" "$OUT" \
  '(.orphaned_registrations | any(.id == "wtI-live") | not)
   and (.skipped_registrations | any(.id == "wtI-live") | not)'
check_json "T20: a dangling worktree symlink is skipped, not classified orphaned" "$OUT" \
  '(.skipped_registrations | any(.id == "wtI-dangleleaf" and (.reason | contains("dangling symlink"))))
   and (.orphaned_registrations | any(.id == "wtI-dangleleaf") | not)'
check_json "T20: a dangling symlink ANCESTOR is skipped too" "$OUT" \
  '(.skipped_registrations | any(.id == "wtI-ancdangle" and (.reason | contains("dangling symlink"))))
   and (.orphaned_registrations | any(.id == "wtI-ancdangle") | not)'
check_json "T20: control — a RESOLVING symlink ancestor still classifies" "$OUT" \
  '.orphaned_registrations | any(.id == "wtI-ancok")'
check_json "T20: an oversized gitdir is skipped, never the unreadable-orphan class" "$OUT" \
  '(.skipped_registrations | any(.id == "wtI-fat" and (.reason | contains("not one of these files"))))
   and (.orphaned_registrations | any(.id == "wtI-fat") | not)'
check_json "T20: control — the same gitdir contents under the cap classify" "$OUT" \
  '.orphaned_registrations | any(.id == "wtI-thin")'
check_json "T20: a symlinked gitdir is skipped, never classified" "$OUT" \
  '(.skipped_registrations | any(.id == "wtI-symgitdir" and (.reason | contains("symlink"))))
   and (.orphaned_registrations | any(.id == "wtI-symgitdir") | not)'
check_json "T20: a dangling registration entry symlink is recorded, not dropped" "$OUT" \
  '.skipped_registrations | any(.id == "wtI-dangling-entry" and (.reason | contains("symlink")))'
check_json "T20: control — a resolving entry symlink is skipped as a symlink too" "$OUT" \
  '(.skipped_registrations | any(.id == "wtI-live-entry" and (.reason | contains("symlink"))))
   and (.orphaned_registrations | any(.id == "wtI-live-entry") | not)'
check_json "T20: an oversized locked reason is dropped, not echoed into the report" "$OUT" \
  '.skipped_registrations | any(.id == "wtI-fatlock" and (.reason | contains("locked"))
                                and ((.reason | contains("yyyy")) | not))'
check_json "T20: control — a normal locked reason is still named" "$OUT" \
  '.skipped_registrations | any(.id == "wtI-thinlock" and (.reason | contains("pid 4242")))'

# --apply must clear the two controls and leave every refused shape alone —
# and refusing something is not a deletion failure, so the run stays clean.
OUT="$(cd "$REPO_I" && "$SUT" --apply --include-locked 2>&1)"
RC=$?
check_eq "T20: --apply exits 0 — a refusal is not a failure" 0 "$RC"
if [[ "$OUT" == *"failed:"* ]]; then
  fail "T20: no failure lines — a symlinked entry is declined, not hard-failed"
else
  pass "T20: no failure lines — a symlinked entry is declined, not hard-failed"
fi
check_eq "T20: control — the plainly missing registration was removed" "gone" \
  "$([[ -e "$REG_I/wtI-plainmissing" ]] && echo present || echo gone)"
check_eq "T20: control — the resolving-ancestor registration was removed" "gone" \
  "$([[ -e "$REG_I/wtI-ancok" ]] && echo present || echo gone)"
check_eq "T20: the live registration survives --apply --include-locked" "present" \
  "$([[ -e "$REG_I/wtI-live" ]] && echo present || echo gone)"

# --- and --apply removes none of the refused shapes ---------------------------
# In their own repo, because `git worktree prune` is all-or-nothing across the
# registry: a run that prunes for some OTHER entry applies git's rule — a bare
# stat that follows symlinks — to every entry, refused or not. That boundary is
# git's and predates this change (the "parent not searchable" skip has always
# shared it); what this script owns is what it REPORTS and what it deletes
# itself. repoK therefore holds only refused shapes plus one entry that routes
# to the targeted path, so nothing hands the registry to prune.
REPO_K="$TMP/repoK"
mkdir -p "$REPO_K"
git -C "$REPO_K" init -q
echo "k" > "$REPO_K/README.md"
git -C "$REPO_K" add README.md
commit_old "$REPO_K" "repoK base"
echo "fresh" >> "$REPO_K/README.md"
git -C "$REPO_K" commit -q -am "repoK fresh tip"
REG_K="$REPO_K/.git/worktrees"
make_reg "$REPO_K" wtK-dangleleaf "$TMP/wtK-leaf-link/.git"
ln -s "$TMP/leaf-target-not-mounted" "$TMP/wtK-leaf-link"
make_reg "$REPO_K" wtK-ancdangle "$TMP/anc-link-dead/wtK-ancdangle/.git"
make_reg "$REPO_K" wtK-fat
{ printf '%s' "$TMP/definitely-not-here/.git"; head -c 8192 /dev/zero | tr '\0' 'x'; } > "$REG_K/wtK-fat/gitdir"
make_reg "$REPO_K" wtK-symgitdir
rm -f "$REG_K/wtK-symgitdir/gitdir"
ln -s "$TMP/planted-gitdir" "$REG_K/wtK-symgitdir/gitdir"
ln -s "$TMP/reg-entry-live-dir" "$REG_K/wtK-live-entry"
# Positive control: the one entry that DOES route to targeted removal, so the
# assertions below pin the refusals rather than an apply phase that never ran.
make_reg "$REPO_K" wtK-bait
printf 'claude agent wtK-bait (pid 4242)\n' > "$REG_K/wtK-bait/locked"

OUT="$(cd "$REPO_K" && "$SUT" --apply --include-locked 2>&1)"
RC=$?
check_eq "T20: repoK --apply exits 0" 0 "$RC"
check_eq "T20: control — the targeted bait was removed, so the phase really ran" "gone" \
  "$([[ -e "$REG_K/wtK-bait" ]] && echo present || echo gone)"
for kept in wtK-dangleleaf wtK-ancdangle wtK-fat wtK-symgitdir wtK-live-entry; do
  check_eq "T20: --apply left $kept in place" "present" \
    "$([[ -e "$REG_K/$kept" ]] && echo present || echo gone)"
done

# --- the pre-rm re-check catches an ancestor that dangles MID-RUN ------------
# The scan runs at start-up; the rm runs at the very end. An ancestor going
# dangling in THAT WINDOW is the state change this gate exists to catch, so it
# must apply the same whole-path rule as the scan.
#
# Breaking the link between two runs would prove nothing: the scan would refuse
# it on its own and the gate would never be consulted. So the link is broken
# from INSIDE the window, by an `rm` stub that fires on an EARLIER targeted
# removal in the same apply phase. `locked` + --include-locked is the one route
# that sends an entry with a READABLE gitdir to remove_registration rather than
# to `git worktree prune` (T9 documents that reachability), so both entries
# carry the marker, and the bait's id sorts first.
REPO_J="$TMP/repoJ"
mkdir -p "$REPO_J"
git -C "$REPO_J" init -q
echo "j" > "$REPO_J/README.md"
git -C "$REPO_J" add README.md
commit_old "$REPO_J" "repoJ base"
echo "fresh" >> "$REPO_J/README.md"
git -C "$REPO_J" commit -q -am "repoJ fresh tip"
REG_J="$REPO_J/.git/worktrees"
mkdir -p "$TMP/race-anc-real"
ln -s "$TMP/race-anc-real" "$TMP/race-anc-link"
for rid in aaa-bait zzz-race; do
  git -C "$REPO_J" worktree add "$TMP/$rid" -b "issue-501-$rid" >/dev/null 2>&1
  rm -rf "${TMP:?}/$rid"
  printf 'claude agent %s (pid 4242)\n' "$rid" > "$REG_J/$rid/locked"
done
printf '%s\n' "$TMP/race-anc-link/zzz-race/.git" > "$REG_J/zzz-race/gitdir"

RM_STUB="$TMP/rm-stub"; mkdir -p "$RM_STUB"
cat > "$RM_STUB/rm" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *aaa-bait) /bin/rm -rf "$TMP/race-anc-real" ;;
  esac
done
exec /bin/rm "\$@"
EOF
chmod +x "$RM_STUB/rm"

OUT="$(cd "$REPO_J" && "$SUT" --check --json --include-locked 2>/dev/null)"
check_json "T20: the race registration classifies while its ancestor resolves" "$OUT" \
  '.orphaned_registrations | any(.id == "zzz-race" and .method == "targeted")'
OUT="$(cd "$REPO_J" && PATH="$RM_STUB:$PATH" "$SUT" --apply --include-locked 2>&1)"
check_eq "T20: the bait really was removed, so the stub ran mid-phase" "gone" \
  "$([[ -e "$REG_J/aaa-bait" ]] && echo present || echo gone)"
check_eq "T20: and the ancestor link really was broken mid-run" "gone" \
  "$([[ -e "$TMP/race-anc-real" ]] && echo present || echo gone)"
check_eq "T20: the pre-rm gate spares a registration whose ancestor dangled mid-run" "present" \
  "$([[ -e "$REG_J/zzz-race" ]] && echo present || echo gone)"
check_contains "T20: and says absence could not be re-established" \
  "absence could not be re-established" "$OUT"
# Positive control: with the ancestor intact for the whole run, that SAME entry
# IS removed — so the assertion above pins the mid-run refusal rather than a
# gate that had simply stopped removing anything.
mkdir -p "$TMP/race-anc-real"
OUT="$(cd "$REPO_J" && "$SUT" --apply --include-locked 2>&1)"
check_eq "T20: control — an un-broken ancestor lets that same registration go" "gone" \
  "$([[ -e "$REG_J/zzz-race" ]] && echo present || echo gone)"
rm -rf "$RM_STUB" "$TMP/race-anc-link" "$TMP/race-anc-real"

# ---------------------------------------------------------------------------
# T21 (#1597, GitHub review round): the two remaining routes by which the
# registration pass could hand a LIVE worktree's entry to the deletion path.
# Both are "absence" that was never actually established — the same class the
# dangling-link guard above closes, reached without any symlink involved.
# ---------------------------------------------------------------------------
REPO_L="$TMP/repoL"
mkdir -p "$REPO_L"
git -C "$REPO_L" init -q
echo "l" > "$REPO_L/README.md"
git -C "$REPO_L" add README.md
commit_old "$REPO_L" "repoL base"
echo "fresh" >> "$REPO_L/README.md"
git -C "$REPO_L" commit -q -am "repoL fresh tip"
REG_L="$REPO_L/.git/worktrees"

# (a) A live worktree whose GRANDparent refuses search. `test -e` reports no
# errno, so it is false on the worktree AND on its parent — testing the
# immediate parent alone read that second false as "the parent is gone, so
# absence holds" and queued a live entry for removal. Only climbing to the
# nearest ancestor that actually answers catches it.
mkdir -p "$TMP/anc000/mid"
git -C "$REPO_L" worktree add "$TMP/anc000/mid/wt-deep" -b issue-1597-deep >/dev/null 2>&1

# (b) A live worktree registered with a RELATIVE gitdir — the shape
# `git worktree add --relative-paths` (git >= 2.48) writes. Left unanchored it
# was probed against the caller's cwd, so a live worktree read as absent.
git -C "$REPO_L" worktree add "$TMP/wt-rel" -b issue-1597-rel >/dev/null 2>&1
printf '../../../../wt-rel/.git\n' > "$REG_L/wt-rel/gitdir"

# Control for (b): the identical relative shape naming a worktree that really
# is gone. Pins the anchoring rather than a pass that stopped classifying.
git -C "$REPO_L" worktree add "$TMP/wt-relgone" -b issue-1597-relgone >/dev/null 2>&1
rm -rf "${TMP:?}/wt-relgone"
printf '../../../../wt-relgone/.git\n' > "$REG_L/wt-relgone/gitdir"

chmod 000 "$TMP/anc000"
OUT="$(cd "$REPO_L" && "$SUT" --check --json 2>/dev/null)"
chmod 755 "$TMP/anc000"

if (( CAN_STAGE_UNSEARCHABLE == 1 )); then
  check_json "T21: a live worktree behind an unsearchable grandparent is not an orphan" \
    "$OUT" '.orphaned_registrations | all(.id != "wt-deep")'
  check_json "T21: it is recorded as skipped, absence not established" \
    "$OUT" '.skipped_registrations | any(.id == "wt-deep" and (.reason | test("not searchable")))'
else
  skip "T21: unsearchable-grandparent classification (running as root; chmod 000 does not restrict uid 0)"
fi
check_json "T21: a live worktree with a relative gitdir is not an orphan" \
  "$OUT" '.orphaned_registrations | all(.id != "wt-rel")'
check_json "T21: control — the same relative shape, genuinely gone, still classifies" \
  "$OUT" '.orphaned_registrations | any(.id == "wt-relgone")'

# --apply, in a repo scoped AROUND the `git worktree prune` boundary. Pruning is
# all-or-nothing across the registry (see the scan_registrations note), so a run
# that prunes for some other entry applies git's own bare stat to these too and
# takes the unsearchable-grandparent entry with it — the pre-existing boundary
# this change does not move, shared with the "parent not searchable" skip. What
# this script owns is what IT classifies and what IT removes, so repoM carries
# only a targeted (locked) orphan: the apply phase runs, no prune is issued, and
# the live entry survives on this script's own decision. Same scoping as repoK.
REPO_M="$TMP/repoM"
mkdir -p "$REPO_M"
git -C "$REPO_M" init -q
echo "m" > "$REPO_M/README.md"
git -C "$REPO_M" add README.md
commit_old "$REPO_M" "repoM base"
echo "fresh" >> "$REPO_M/README.md"
git -C "$REPO_M" commit -q -am "repoM fresh tip"
REG_M="$REPO_M/.git/worktrees"
mkdir -p "$TMP/anc000b/mid"
git -C "$REPO_M" worktree add "$TMP/anc000b/mid/wt-deep2" -b issue-1597-deep2 >/dev/null 2>&1
git -C "$REPO_M" worktree add "$TMP/m-bait" -b issue-1597-mbait >/dev/null 2>&1
rm -rf "${TMP:?}/m-bait"
printf 'claude agent m-bait (pid 4242)\n' > "$REG_M/m-bait/locked"

chmod 000 "$TMP/anc000b"
OUT="$(cd "$REPO_M" && "$SUT" --check --json --include-locked 2>/dev/null)"
# Every candidate here is targeted, so no `git worktree prune` is issued at all
# — whatever survives --apply below survives on this script's own decision.
check_json "T21: repoM issues no prune, so nothing else can clear an entry" \
  "$OUT" '.orphaned_registrations | length > 0 and all(.[]; .method == "targeted")'
if (( CAN_STAGE_UNSEARCHABLE == 1 )); then
  check_json "T21: repoM skips the unsearchable-grandparent entry at classification" \
    "$OUT" '.skipped_registrations | any(.id == "wt-deep2")'
else
  skip "T21: repoM unsearchable-grandparent classification (running as root)"
fi
OUT="$(cd "$REPO_M" && "$SUT" --apply --include-locked 2>&1)"
chmod 755 "$TMP/anc000b"

check_eq "T21: control — the targeted bait was removed, so the apply phase ran" "gone" \
  "$([[ -e "$REG_M/m-bait" ]] && echo present || echo gone)"
if (( CAN_STAGE_UNSEARCHABLE == 1 )); then
  check_eq "T21: --apply leaves the unsearchable-grandparent registration in place" "present" \
    "$([[ -e "$REG_M/wt-deep2" ]] && echo present || echo gone)"
else
  skip "T21: unsearchable-grandparent survives --apply (running as root)"
fi

# ---- T22 (#1597 review): a symlinked `locked` marker is never read through ---
# The cap bounds how MUCH of a file reaches stdout, not WHICH file. The lock
# reason is echoed into the report and into --json, so a marker pointed at an
# arbitrary file would publish its first line.
REPO_N="$TMP/repoN"
mkdir -p "$REPO_N"
git -C "$REPO_N" init -q
echo "n" > "$REPO_N/README.md"
git -C "$REPO_N" add README.md
commit_old "$REPO_N" "repoN base"
REG_N="$REPO_N/.git/worktrees"
printf 'TOPSECRET-CANARY-DO-NOT-PUBLISH\nsecond line\n' > "$TMP/n-secret"
git -C "$REPO_N" worktree add "$TMP/wtN-symlock" -b issue-1597-symlock >/dev/null 2>&1
rm -rf "${TMP:?}/wtN-symlock"
ln -s "$TMP/n-secret" "$REG_N/wtN-symlock/locked"
# Control: an ordinary locked marker whose reason SHOULD still be named.
git -C "$REPO_N" worktree add "$TMP/wtN-plainlock" -b issue-1597-plainlock >/dev/null 2>&1
rm -rf "${TMP:?}/wtN-plainlock"
printf 'claude agent plainlock (pid 4242)\n' > "$REG_N/wtN-plainlock/locked"

OUT="$(cd "$REPO_N" && "$SUT" --check --json 2>/dev/null)"
check_json "T22: a symlinked locked marker never leaks the target's contents" \
  "$OUT" '[.. | strings] | any(test("TOPSECRET-CANARY")) | not'
check_json "T22: the entry is still reported as locked, reason withheld" \
  "$OUT" '.skipped_registrations | any(.id == "wtN-symlock" and (.reason | test("symlink and was not read through")))'
check_json "T22: control — a plain locked marker's reason is still named" \
  "$OUT" '.skipped_registrations | any(.id == "wtN-plainlock" and (.reason | test("plainlock")))'
OUT_TEXT="$(cd "$REPO_N" && "$SUT" --check 2>&1)"
check_contains "T22: the text report withholds it too" "no-canary" \
  "$(printf '%s' "$OUT_TEXT" | grep -q 'TOPSECRET-CANARY' && echo leaked || echo no-canary)"

echo ""
if (( SKIP > 0 )); then
  echo "Results: $PASS passed, $FAIL failed, $SKIP skipped (environment could not host them — see SKIP lines)"
else
  echo "Results: $PASS passed, $FAIL failed"
fi
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: stale-cleanup.sh + dirty-main-guard.sh — invoking-repo scope (issue #697) and the sweep's git bounds (issue #1404) verified"
