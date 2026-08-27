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
cleanup() { rm -rf "$TMP"; }
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

unset STALE_CLEANUP_TIMEOUT_SECS STALE_CLEANUP_READ_TIMEOUT_SECS

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: stale-cleanup.sh + dirty-main-guard.sh — invoking-repo scope verified (issue #697)"
