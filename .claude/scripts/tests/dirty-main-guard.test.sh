#!/usr/bin/env bash
# Offline tests for dirty-main-guard.sh invoking-repo scoping, including the
# quarantine path (issue #707 — the #697 remainder; stale-cleanup.test.sh T7
# covers the guard's --check paths, this suite adds dirty-tracked, quarantine
# placement/untracked-survival, feature-branch short-circuit, and non-repo cwd).
# catalog: tests — Tests for `dirty-main-guard.sh`
#
# The SUT is copied (with the real repo-root.sh beside it) into throwaway git
# repo A, which is kept DIRTY on main for the whole run — then invoked with
# cwd inside repo C. Pre-#697 the guard resolved its root from the script's
# location, so every check would have reported A's dirty state (and
# --quarantine would have quarantined A); post-fix it must see only C.
# Repo C gets a local bare origin so origin/main exists without network;
# checks run with --no-fetch anyway per the flag's Stop-hook use case.
#
# Cases 7-11 cover the --repo flag (issue #1411). The parity cases run the
# --repo form from a NON-repo cwd, so a --repo that was ignored (or that fell
# back to cwd resolution) exits 2 and fails the comparison instead of passing
# vacuously. Case 11 pins the safety posture: --repo <a-worktree> resolves to
# that worktree's ROOT repo, never the worktree's own checkout.
# Requires git. Run from repo root:
#   bash .claude/scripts/tests/dirty-main-guard.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() {
  # case12's stall stub spawns a self-limiting sleeper; kill any survivor so a
  # failing process-group test cannot leak one into the runner.
  pkill -f "$TMP/stubbin/stub-sleeper" >/dev/null 2>&1 || true
  rm -rf "$TMP" "$TMP_HOME"
}
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }

check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$desc"
  else
    fail "$desc (expected '$expected', got '$actual')"
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

# ---- repo A: hosts the script copy; dirty on main; must never be touched ----
REPO_A="$TMP/repoA"
mkdir -p "$REPO_A/.claude/scripts"
git init -q -b main "$REPO_A"
git -C "$REPO_A" config user.email "test@example.com"
git -C "$REPO_A" config user.name "Test"
echo "pristine" > "$REPO_A/marker.txt"
git -C "$REPO_A" add marker.txt
git -C "$REPO_A" commit -q -m "init A"
echo "dirty A state" >> "$REPO_A/marker.txt"   # tracked, uncommitted → dirty
cp "$REPO_ROOT/.claude/scripts/dirty-main-guard.sh" "$REPO_A/.claude/scripts/"
cp "$REPO_ROOT/.claude/scripts/repo-root.sh" "$REPO_A/.claude/scripts/"
# Both scripts source the shared wall-clock bound from lib/ (issue #1404), and
# both refuse to run git unbounded without it — so the copy has to include it,
# exactly as a real install does.
mkdir -p "$REPO_A/.claude/scripts/lib"
cp "$REPO_ROOT/.claude/scripts/lib/bounded-run.sh" "$REPO_A/.claude/scripts/lib/"
chmod +x "$REPO_A/.claude/scripts/dirty-main-guard.sh" "$REPO_A/.claude/scripts/repo-root.sh"
GUARD="$REPO_A/.claude/scripts/dirty-main-guard.sh"

# ---- repo C: the invoking repo, with a local bare origin --------------------
REPO_C="$TMP/repoC"
git init -q -b main "$REPO_C"
git -C "$REPO_C" config user.email "test@example.com"
git -C "$REPO_C" config user.name "Test"
echo "content" > "$REPO_C/file.txt"
git -C "$REPO_C" add file.txt
git -C "$REPO_C" commit -q -m "init C"
git init -q --bare "$TMP/origin.git"
git -C "$REPO_C" remote add origin "$TMP/origin.git"
git -C "$REPO_C" push -q -u origin main

NONREPO="$TMP/nonrepo"
mkdir -p "$NONREPO"

# ---- Case 1: clean C, dirty A → clean (the #697 regression direction) -------
OUT=$(cd "$REPO_C" && "$GUARD" --check --no-fetch)
RC=$?
check_eq "case1: clean invoking repo reports clean despite dirty script repo" "clean" "$OUT"
check_eq "case1: exit 0" "0" "$RC"

# ---- Case 2: tracked change in C → dirty ------------------------------------
echo "local edit" >> "$REPO_C/file.txt"
OUT=$(cd "$REPO_C" && "$GUARD" --check --no-fetch)
RC=$?
check_contains "case2: uncommitted tracked change detected in C" \
  "dirty: uncommitted tracked changes" "$OUT"
check_eq "case2: exit 1" "1" "$RC"

# ---- Case 3: quarantine acts on C, leaves A alone ---------------------------
# Untracked fixture: the quarantine contract says untracked files are never
# touched (reset --hard leaves them; the guard never runs git clean).
echo "keep me" > "$REPO_C/untracked-keep.txt"
OUT=$(cd "$REPO_C" && "$GUARD" --quarantine)
RC=$?
check_eq "case3: quarantine exit 0" "0" "$RC"
check_contains "case3: recovery branch reported" "quarantined: recovery/dirty-main-" "$OUT"
check_eq "case3: C back on main" "main" "$(git -C "$REPO_C" symbolic-ref --short HEAD)"
if git -C "$REPO_C" diff --quiet && git -C "$REPO_C" diff --cached --quiet; then
  pass "case3: C main clean after quarantine"
else
  fail "case3: C main still dirty after quarantine"
fi
RECOVERY_COUNT="$(git -C "$REPO_C" branch --list 'recovery/dirty-main-*' | wc -l | tr -d ' ')"
check_eq "case3: exactly one recovery branch in C" "1" "$RECOVERY_COUNT"
check_eq "case3: repo A's dirty state untouched" "dirty A state" \
  "$(tail -1 "$REPO_A/marker.txt")"
check_eq "case3: repo A grew no recovery branch" "0" \
  "$(git -C "$REPO_A" branch --list 'recovery/dirty-main-*' | wc -l | tr -d ' ')"
check_eq "case3: untracked file in C survives quarantine" "keep me" \
  "$(cat "$REPO_C/untracked-keep.txt" 2>/dev/null)"

# ---- Case 4: unpushed commit on C main → dirty ------------------------------
git -C "$REPO_C" commit -q --allow-empty -m "unpushed"
OUT=$(cd "$REPO_C" && "$GUARD" --check --no-fetch)
RC=$?
check_contains "case4: unpushed commit detected" "1 unpushed commit(s) on main" "$OUT"
check_eq "case4: exit 1" "1" "$RC"
git -C "$REPO_C" reset -q --hard origin/main

# ---- Case 5: feature branch short-circuit -----------------------------------
git -C "$REPO_C" checkout -q -b feature-x
OUT=$(cd "$REPO_C" && "$GUARD" --check --no-fetch)
RC=$?
check_eq "case5: non-main branch reports clean (not applicable)" "clean" "$OUT"
check_eq "case5: exit 0" "0" "$RC"
git -C "$REPO_C" checkout -q main

# ---- Case 6: non-repo cwd → resolution error, exit 2 ------------------------
OUT=$(cd "$NONREPO" && "$GUARD" --check --no-fetch)
RC=$?
check_contains "case6: resolution error surfaced" "could not resolve root repo" "$OUT"
check_eq "case6: exit 2" "2" "$RC"

# ============================ --repo flag (#1411) ============================
# C is back on main and clean at this point (case 4 reset, case 5 returned).

# ---- Case 7: --repo works with no cd at all (the #1411 use case) ------------
# Run from a non-repo cwd: cwd resolution would exit 2 here, so a clean exit 0
# can only come from --repo actually being honoured.
OUT=$(cd "$NONREPO" && "$GUARD" --check --no-fetch --repo "$REPO_C")
RC=$?
check_eq "case7: --repo resolves C from an unrelated cwd" "clean" "$OUT"
check_eq "case7: exit 0" "0" "$RC"

# ---- Case 8: --repo is byte-for-byte the cwd form, state by state -----------
# --check only: --quarantine is not idempotent, so it cannot be run twice on
# one state. Each state also asserts the expected verdict, so the pair cannot
# agree vacuously on a wrong answer.
parity_check() { # desc, expected-stdout, expected-rc
  local desc="$1" exp_out="$2" exp_rc="$3"
  local cwd_out cwd_rc=0 repo_out repo_rc=0
  cwd_out=$(cd "$REPO_C" && "$GUARD" --check --no-fetch) || cwd_rc=$?
  repo_out=$(cd "$NONREPO" && "$GUARD" --check --no-fetch --repo "$REPO_C") || repo_rc=$?
  check_eq "$desc: cwd form reports the expected verdict" "$exp_out" "$cwd_out"
  check_eq "$desc: cwd form exits $exp_rc" "$exp_rc" "$cwd_rc"
  check_eq "$desc: --repo stdout matches the cwd form" "$cwd_out" "$repo_out"
  check_eq "$desc: --repo exit status matches the cwd form" "$cwd_rc" "$repo_rc"
}

parity_check "case8a (clean main)" "clean" "0"

echo "parity edit" >> "$REPO_C/file.txt"
parity_check "case8b (uncommitted tracked)" "dirty: uncommitted tracked changes" "1"
git -C "$REPO_C" checkout -q -- file.txt

git -C "$REPO_C" commit -q --allow-empty -m "parity unpushed"
parity_check "case8c (unpushed commit)" "dirty: 1 unpushed commit(s) on main" "1"
git -C "$REPO_C" reset -q --hard origin/main

git -C "$REPO_C" checkout -q -b feature-parity
parity_check "case8d (feature branch)" "clean" "0"
git -C "$REPO_C" checkout -q main

# ---- Case 9: --repo value validation → usage error, exit 3 ------------------
OUT=$(cd "$REPO_C" && "$GUARD" --check --no-fetch --repo 2>&1)
RC=$?
check_contains "case9a: missing --repo value rejected" "--repo requires a value" "$OUT"
check_eq "case9a: exit 3" "3" "$RC"

OUT=$(cd "$REPO_C" && "$GUARD" --check --no-fetch --repo "" 2>&1)
RC=$?
check_contains "case9b: empty --repo value rejected" "--repo value cannot be empty" "$OUT"
check_eq "case9b: exit 3" "3" "$RC"

OUT=$(cd "$REPO_C" && "$GUARD" --check --no-fetch --repo= 2>&1)
RC=$?
check_contains "case9c: empty --repo=<> value rejected" "--repo value cannot be empty" "$OUT"
check_eq "case9c: exit 3" "3" "$RC"

OUT=$(cd "$REPO_C" && "$GUARD" --check --no-fetch --repo "$TMP/does-not-exist" 2>&1)
RC=$?
check_contains "case9d: nonexistent --repo path rejected" "--repo path does not exist" "$OUT"
check_eq "case9d: exit 3" "3" "$RC"

# --repo=<path> is the second accepted spelling and must resolve identically.
OUT=$(cd "$NONREPO" && "$GUARD" --check --no-fetch --repo="$REPO_C")
RC=$?
check_eq "case9e: --repo=<path> spelling resolves C" "clean" "$OUT"
check_eq "case9e: exit 0" "0" "$RC"

# ---- Case 10: --repo at a non-repo dir → resolution error, exit 2 ----------
# Run from inside repo C, where cwd resolution would have reported "clean" —
# so this also proves --repo overrides the cwd rather than merely defaulting.
OUT=$(cd "$REPO_C" && "$GUARD" --check --no-fetch --repo "$NONREPO" 2>&1)
RC=$?
check_contains "case10: resolution error surfaced" "could not resolve root repo" "$OUT"
check_contains "case10: error names --repo as the source, not the cwd" \
  "from --repo $NONREPO" "$OUT"
check_eq "case10: exit 2" "2" "$RC"

# ---- Case 11: --repo <worktree> guards the ROOT, never the worktree --------
# Safety posture pin. Repo D sits dirty on main; its linked worktree W sits on
# a feature branch with its own dirty tracked file. A --repo that targeted the
# named path directly would see W's feature branch and short-circuit "clean";
# resolving through repo-root.sh sees D's dirty main instead. The two answers
# differ, so this case cannot pass under the wrong implementation.
REPO_D="$TMP/repoD"
git init -q -b main "$REPO_D"
git -C "$REPO_D" config user.email "test@example.com"
git -C "$REPO_D" config user.name "Test"
echo "root content" > "$REPO_D/root.txt"
git -C "$REPO_D" add root.txt
git -C "$REPO_D" commit -q -m "init D"
git init -q --bare "$TMP/originD.git"
git -C "$REPO_D" remote add origin "$TMP/originD.git"
git -C "$REPO_D" push -q -u origin main

WT_W="$TMP/wtW"
git -C "$REPO_D" worktree add -q "$WT_W" -b feature-w
echo "worktree edit" >> "$WT_W/root.txt"   # dirty tracked file, W's checkout
echo "root edit" >> "$REPO_D/root.txt"     # dirty tracked file, D's main

OUT=$(cd "$WT_W" && "$GUARD" --check --no-fetch)
CWD_RC=$?
OUT_REPO=$(cd "$NONREPO" && "$GUARD" --check --no-fetch --repo "$WT_W")
RC=$?
check_eq "case11: worktree path reports the ROOT's dirty main" \
  "dirty: uncommitted tracked changes" "$OUT_REPO"
check_eq "case11: --repo <worktree> stdout matches cd-into-worktree" "$OUT" "$OUT_REPO"
check_eq "case11: --repo <worktree> exit status matches cd-into-worktree" "$CWD_RC" "$RC"

OUT=$(cd "$NONREPO" && "$GUARD" --quarantine --repo "$WT_W")
RC=$?
check_eq "case11: quarantine exit 0" "0" "$RC"
check_contains "case11: recovery branch reported" "quarantined: recovery/dirty-main-" "$OUT"
check_eq "case11: W still on its own feature branch" "feature-w" \
  "$(git -C "$WT_W" symbolic-ref --short HEAD)"
check_eq "case11: W's dirty tracked file untouched" "worktree edit" \
  "$(tail -1 "$WT_W/root.txt")"
check_eq "case11: D's main is clean after quarantine" "root content" \
  "$(tail -1 "$REPO_D/root.txt")"
check_eq "case11: exactly one recovery branch in D" "1" \
  "$(git -C "$REPO_D" branch --list 'recovery/dirty-main-*' | wc -l | tr -d ' ')"

# ---- case 12: a wedged git after resolution fails fast, loudly (issue #1404) --
# repo-root.sh has bounded the calls that RESOLVE the root since #1363; every
# call the guard then makes against that root was still unbounded, and on the
# filesystem behind that incident a single-file `symbolic-ref` read stalls just
# as thoroughly. Stub a git that stalls ONLY `symbolic-ref` and forwards
# everything else to the real one, so resolution succeeds and the stall lands
# exactly where the bound was missing.
REAL_GIT="$(command -v git)"
STUB="$TMP/stubbin"
mkdir -p "$STUB"
TICK_FILE="$TMP/tick"
export TICK_FILE REAL_GIT
cat > "$STUB/stub-sleeper" <<'EOF'
#!/usr/bin/env bash
# Descendant of the stubbed git: self-limited (~10s) so a failing process-group
# kill cannot leave a sleeper running for the rest of the suite.
for _ in $(seq 1 50); do
  printf 'tick\n' >> "$TICK_FILE"
  sleep 0.2
done
EOF
chmod +x "$STUB/stub-sleeper"
cat > "$STUB/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/stub-argv.log"
for a in "\$@"; do
  if [[ "\$a" == "symbolic-ref" ]]; then
    "$STUB/stub-sleeper" &
    sleep 30
  fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$STUB/git"

# A 3s bound, not 1s: the clock is whole-second, so an N-second bound trips
# anywhere in (N-1, N] — at N=1 the kill can land before the stub is even live.
: > "$TMP/stub-argv.log"
: > "$TICK_FILE"
START="$(date +%s)"
RC=0
OUT="$(cd "$NONREPO" && PATH="$STUB:$PATH" REPO_ROOT_TIMEOUT_SECS=3 \
  "$GUARD" --check --no-fetch --repo "$REPO_C" 2>/dev/null)" || RC=$?
ELAPSED=$(( $(date +%s) - START ))

check_eq "case12: a wedged git exits 2 (failure), not 0 and not a hang" "2" "$RC"
check_contains "case12: the diagnostic names the command that was killed" \
  "git symbolic-ref --short HEAD" "$OUT"
check_contains "case12: and names the bound that tripped" "exceeded 3s" "$OUT"
if (( ELAPSED < 15 )); then
  pass "case12: returned in ${ELAPSED}s — the bound held (the stub sleeps 30s)"
else
  fail "case12: took ${ELAPSED}s — the bound did not hold"
fi
# The `|| RC=$?` above would swallow a guard that died before reaching git at
# all, so prove the stall was actually reached rather than assumed.
if grep -q 'symbolic-ref' "$TMP/stub-argv.log"; then
  pass "case12: control — the stalling subcommand really was invoked"
else
  fail "case12: control — the stub never saw symbolic-ref, so nothing was bounded"
fi
# Control the other way: with nothing stalling, the same stub answers normally.
# Without this, case12 would also pass against a stub that broke every git call.
# Compared against a freshly measured unstubbed run rather than a literal, so
# the control cannot rot as earlier cases change what repo C holds.
BASE_RC=0
BASELINE="$(cd "$NONREPO" && "$GUARD" --check --no-fetch --repo "$REPO_C" 2>/dev/null)" || BASE_RC=$?
: > "$TMP/stub-argv.log"
cat > "$STUB/git" <<EOF
#!/usr/bin/env bash
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$STUB/git"
RC=0
OUT="$(cd "$NONREPO" && PATH="$STUB:$PATH" REPO_ROOT_TIMEOUT_SECS=3 \
  "$GUARD" --check --no-fetch --repo "$REPO_C" 2>/dev/null)" || RC=$?
check_eq "case12: control — a pass-through stub matches the unstubbed status" "$BASE_RC" "$RC"
check_eq "case12: control — and the unstubbed answer" "$BASELINE" "$OUT"
pkill -f "$STUB/stub-sleeper" >/dev/null 2>&1 || true

# ---- case 13: a bound that trips mid-quarantine still returns to main --------
# The quarantine path checks out the recovery branch, commits onto it, and
# checks main back out. A bound tripping between those two checkouts used to
# `exit 2` from inside the bounded wrapper, skipping the return trip that the
# ordinary commit-failure path performs — leaving the ROOT REPO on the recovery
# branch. That is not a cosmetic exit: the guard's own short-circuit reads any
# non-main branch as "nothing to guard", so the next --check answers `clean`
# for a repo whose main is still dirty, and --quarantine no-ops. The guard
# stops guarding, and the Stop hook (exit 1 only) never says so.
#
# Stub a git that stalls ONLY `commit` and forwards everything else, so the
# checkout onto recovery succeeds and the stall lands inside the window.
REPO_E="$TMP/repoE"
git init -q -b main "$REPO_E"
git -C "$REPO_E" config user.email "test@example.com"
git -C "$REPO_E" config user.name "Test"
echo "base" > "$REPO_E/f.txt"
git -C "$REPO_E" add f.txt
git -C "$REPO_E" commit -q -m "init E"
git init -q --bare "$TMP/originE.git"
git -C "$REPO_E" remote add origin "$TMP/originE.git"
git -C "$REPO_E" push -q -u origin main
echo "dirty edit" >> "$REPO_E/f.txt"

: > "$TMP/stub-argv.log"
: > "$TICK_FILE"
cat > "$STUB/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/stub-argv.log"
for a in "\$@"; do
  if [[ "\$a" == "commit" ]]; then
    "$STUB/stub-sleeper" &
    sleep 30
  fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$STUB/git"

START="$(date +%s)"
RC=0
OUT="$(cd "$NONREPO" && PATH="$STUB:$PATH" REPO_ROOT_TIMEOUT_SECS=3 \
  "$GUARD" --quarantine --repo "$REPO_E" 2>/dev/null)" || RC=$?
ELAPSED=$(( $(date +%s) - START ))

check_eq "case13: a stalled commit exits 2, not 0 and not a hang" "2" "$RC"
check_contains "case13: the diagnostic names the call that was killed" "commit" "$OUT"
check_contains "case13: and names the bound that tripped" "exceeded 3s" "$OUT"
# The regression itself: whatever the guard reports, it must not walk away
# leaving the root repo parked on the recovery branch.
check_eq "case13: the root repo is back on main, not stranded on recovery" "main" \
  "$(git -C "$REPO_E" symbolic-ref --short HEAD)"
check_contains "case13: and the report says where the quarantined work went" \
  "recovery/dirty-main-" "$OUT"
# Stranding is silent by construction, so prove the guard did not simply go on
# reporting `clean` for a main that is still dirty.
check_eq "case13: a later --check still sees the dirty main" \
  "dirty: uncommitted tracked changes" \
  "$(cd "$NONREPO" && "$GUARD" --check --no-fetch --repo "$REPO_E" 2>/dev/null)"
if (( ELAPSED < 15 )); then
  pass "case13: returned in ${ELAPSED}s — the bound held (the stub sleeps 30s)"
else
  fail "case13: took ${ELAPSED}s — the bound did not hold"
fi
if grep -q 'commit' "$TMP/stub-argv.log"; then
  pass "case13: control — the stalling subcommand really was invoked"
else
  fail "case13: control — the stub never saw commit, so nothing was bounded"
fi
# Control the other way: with nothing stalling, the same stub quarantines
# normally. Without it, case13 would also pass against a stub that broke the
# whole quarantine before it ever reached the recovery branch.
cat > "$STUB/git" <<EOF
#!/usr/bin/env bash
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$STUB/git"
RC=0
OUT="$(cd "$NONREPO" && PATH="$STUB:$PATH" REPO_ROOT_TIMEOUT_SECS=3 \
  "$GUARD" --quarantine --repo "$REPO_E" 2>/dev/null)" || RC=$?
check_eq "case13: control — an unstalled quarantine still succeeds" "0" "$RC"
check_contains "case13: control — and reports its recovery branch" \
  "quarantined: recovery/dirty-main-" "$OUT"
check_eq "case13: control — and lands back on main" "main" \
  "$(git -C "$REPO_E" symbolic-ref --short HEAD)"
pkill -f "$STUB/stub-sleeper" >/dev/null 2>&1 || true

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: dirty-main-guard.sh — invoking-repo scope incl. quarantine path (issue #707), --repo targeting (issue #1411), and the post-resolution git bound (issue #1404) locked in"
