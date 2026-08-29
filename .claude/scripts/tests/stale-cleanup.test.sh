#!/usr/bin/env bash
# stale-cleanup.test.sh — Offline tests for the invoking-repo scope contract
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
pass() { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }

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
if [[ "$(id -u)" -eq 0 ]]; then
  echo "skip — T12: unsearchable-parent probe (running as root; permissions do not apply)"
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
check_eq "T14: the classification loop carries an empty-array guard" 1 \
  "$(grep -cF "if (( \${#WORKTREES[@]} > 0 )); then" "$SUT" || true)"

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

make_git_stub() { # stalling-subcommand
  cat > "$GIT_STUB/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/t16-argv.log"
for a in "\$@"; do
  if [[ "\$a" == "$1" ]]; then
    "$GIT_STUB/stub-sleeper" &
    sleep 30
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
if (( ELAPSED < 40 )); then
  pass "T16a: returned in ${ELAPSED}s — the bound held (each stub call sleeps 30s)"
else
  fail "T16a: took ${ELAPSED}s — the bound did not hold"
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
make_git_stub -D
START="$(date +%s)"
RC=0
OUT="$(cd "$REPO_T16" && PATH="$GIT_STUB:$PATH" STALE_CLEANUP_TIMEOUT_SECS=3 \
  "$SUT" --apply 2>/dev/null)" || RC=$?
ELAPSED=$(( $(date +%s) - START ))
check_eq "T16b: a wedged branch deletion exits 2 (deletion failure)" "2" "$RC"
check_contains "T16b: reported as a per-item failure naming the bound" \
  "failed: local branch issue-900-t16-stale — 'git branch -D' exceeded 3s and was killed" "$OUT"
if (( ELAPSED < 40 )); then
  pass "T16b: returned in ${ELAPSED}s — the bound held"
else
  fail "T16b: took ${ELAPSED}s — the bound did not hold"
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: stale-cleanup.sh + dirty-main-guard.sh — invoking-repo scope (issue #697) and the sweep's git bounds (issue #1404) verified"
