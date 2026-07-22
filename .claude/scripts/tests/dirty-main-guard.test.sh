#!/usr/bin/env bash
# Offline tests for dirty-main-guard.sh invoking-repo scoping, including the
# quarantine path (issue #707 — the #697 remainder; stale-cleanup.test.sh T7
# covers the guard's --check paths, this suite adds dirty-tracked, quarantine
# placement/untracked-survival, feature-branch short-circuit, and non-repo cwd).
#
# The SUT is copied (with the real repo-root.sh beside it) into throwaway git
# repo A, which is kept DIRTY on main for the whole run — then invoked with
# cwd inside repo C. Pre-#697 the guard resolved its root from the script's
# location, so every check would have reported A's dirty state (and
# --quarantine would have quarantined A); post-fix it must see only C.
# Repo C gets a local bare origin so origin/main exists without network;
# checks run with --no-fetch anyway per the flag's Stop-hook use case.
# Requires git. Run from repo root:
#   bash .claude/scripts/tests/dirty-main-guard.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: dirty-main-guard.sh — invoking-repo scope incl. quarantine path locked in (issue #707)"
