#!/usr/bin/env bash
# Offline tests for pr-issue-ref.sh — default mode and --all mode (issue #1281).
# Stubs `gh` with fixture PR bodies; no real GitHub calls.
# Run from repo root:
#   bash .claude/scripts/tests/pr-issue-ref.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/pr-issue-ref.sh"

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
    fail "$desc (missing '$needle' in '$haystack')"
  fi
}

check_line_present() {
  local desc="$1" line="$2" hay="$3"
  if printf '%s\n' "$hay" | grep -Fxq -- "$line"; then
    pass "$desc"
  else
    fail "$desc (missing exact line '$line')"
  fi
}

# ---------------------------------------------------------------------------
# Fixtures: pr_body per PR number
# ---------------------------------------------------------------------------
mkdir -p "$TMP/pr_body"

# PR 101 — single bare #N reference
echo "Implements the feature. Closes #42" > "$TMP/pr_body/101.txt"

# PR 102 — multiple bare #N references (two different issues)
echo "Fixes #10. Also resolves #20" > "$TMP/pr_body/102.txt"

# PR 103 — cross-repo owner/repo#N only
echo "Closes auerbachb/inventory#55" > "$TMP/pr_body/103.txt"

# PR 104 — both bare #N and cross-repo on same PR
printf 'Closes #30\nFixes auerbachb/inventory#40\n' > "$TMP/pr_body/104.txt"

# PR 105 — no closing keyword
echo "General update, no linked issue" > "$TMP/pr_body/105.txt"

# PR 106 — bare #N that should not match embedded in word
echo "encloses#77 and enclosed #78" > "$TMP/pr_body/106.txt"

# ---------------------------------------------------------------------------
# gh stub — serves pr body files for `pr view N ...` calls
# ---------------------------------------------------------------------------
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
args="\$*"
case "\$args" in
  "pr view "*)
    n=\$(echo "\$args" | sed -n 's/^pr view \([0-9]*\).*/\1/p')
    if [ -f "$TMP/pr_body/\${n}.txt" ]; then
      cat "$TMP/pr_body/\${n}.txt"
    else
      echo ""
    fi
    ;;
  *)
    echo "gh stub: unhandled args: \$args" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

# ---------------------------------------------------------------------------
# Test 1: default mode — single bare #N reference
# ---------------------------------------------------------------------------
OUT="$(bash "$SCRIPT" 101 2>/dev/null)"
check_eq "Test1: default mode extracts single bare #N" "42" "$OUT"

# ---------------------------------------------------------------------------
# Test 2: default mode — first match only when multiple references
# ---------------------------------------------------------------------------
OUT="$(bash "$SCRIPT" 102 2>/dev/null)"
check_eq "Test2: default mode returns first match only" "10" "$OUT"

# ---------------------------------------------------------------------------
# Test 3: default mode — cross-repo form NOT matched (bare #N only)
# ---------------------------------------------------------------------------
RC=0
OUT="$(bash "$SCRIPT" 103 2>/dev/null)" || RC=$?
[[ "$RC" -eq 1 ]] && pass "Test3: default mode does not match cross-repo form (exit 1)" \
  || fail "Test3: default mode should exit 1 for cross-repo-only body (got RC=$RC, OUT='$OUT')"

# ---------------------------------------------------------------------------
# Test 4: default mode output unchanged when both forms present
# PR 104 has both "Closes #30" and cross-repo ref; default returns "30"
# ---------------------------------------------------------------------------
OUT="$(bash "$SCRIPT" 104 2>/dev/null)"
check_eq "Test4: default mode still returns first bare #N when cross-repo also present" "30" "$OUT"

# ---------------------------------------------------------------------------
# Test 5: default mode — no closing keyword exits 1
# ---------------------------------------------------------------------------
RC=0
bash "$SCRIPT" 105 2>/dev/null || RC=$?
[[ "$RC" -eq 1 ]] && pass "Test5: default mode exits 1 when no reference found" \
  || fail "Test5: expected exit 1 for no closing keyword (got $RC)"

# ---------------------------------------------------------------------------
# Test 6: --all mode — single bare #N
# ---------------------------------------------------------------------------
OUT="$(bash "$SCRIPT" --all 101 2>/dev/null)"
check_eq "Test6: --all returns single bare #N" "42" "$OUT"

# ---------------------------------------------------------------------------
# Test 7: --all mode — multiple bare #N references
# ---------------------------------------------------------------------------
OUT="$(bash "$SCRIPT" --all 102 2>/dev/null)"
check_line_present "Test7a: --all includes first ref #10" "10" "$OUT"
check_line_present "Test7b: --all includes second ref #20" "20" "$OUT"
LINE_COUNT="$(printf '%s\n' "$OUT" | grep -c . || true)"
[[ "$LINE_COUNT" -eq 2 ]] && pass "Test7c: --all emits exactly 2 lines for 2 refs" \
  || fail "Test7c: expected 2 lines, got $LINE_COUNT"

# ---------------------------------------------------------------------------
# Test 8: --all mode — cross-repo owner/repo#N form detected separately
# PR 103 has only "Closes auerbachb/inventory#55" (no bare #N)
# ---------------------------------------------------------------------------
OUT="$(bash "$SCRIPT" --all 103 2>/dev/null)"
check_eq "Test8: --all matches owner/repo#N form and extracts number" "55" "$OUT"

# ---------------------------------------------------------------------------
# Test 9: --all mode — both bare #N and owner/repo#N
# PR 104 has "Closes #30" and "Fixes auerbachb/inventory#40"
# ---------------------------------------------------------------------------
OUT="$(bash "$SCRIPT" --all 104 2>/dev/null)"
check_line_present "Test9a: --all includes bare #30" "30" "$OUT"
check_line_present "Test9b: --all includes cross-repo #40" "40" "$OUT"
LINE_COUNT="$(printf '%s\n' "$OUT" | grep -c . || true)"
[[ "$LINE_COUNT" -eq 2 ]] && pass "Test9c: --all emits exactly 2 lines for mixed refs" \
  || fail "Test9c: expected 2 lines, got $LINE_COUNT"

# ---------------------------------------------------------------------------
# Test 10: --all mode — no reference exits 1
# ---------------------------------------------------------------------------
RC=0
bash "$SCRIPT" --all 105 2>/dev/null || RC=$?
[[ "$RC" -eq 1 ]] && pass "Test10: --all exits 1 when no reference found" \
  || fail "Test10: expected exit 1 for no closing keyword (got $RC)"

# ---------------------------------------------------------------------------
# Test 11: word-boundary — "encloses#77" should NOT match (not in --all either)
# "enclosed #78" → "closed" is a prefix issue: left boundary blocks "enclosed"
# ---------------------------------------------------------------------------
RC=0
bash "$SCRIPT" --all 106 2>/dev/null || RC=$?
[[ "$RC" -eq 1 ]] && pass "Test11: word-boundary prevents match inside 'encloses#77' and 'enclosed #78'" \
  || fail "Test11: boundary test failed (expected exit 1, got $RC)"

# ---------------------------------------------------------------------------
# Test 12: usage errors
# ---------------------------------------------------------------------------
RC=0
bash "$SCRIPT" 2>/dev/null || RC=$?
[[ "$RC" -eq 2 ]] && pass "Test12a: missing pr_number exits 2" || fail "Test12a: expected 2, got $RC"

RC=0
bash "$SCRIPT" --bogus 2>/dev/null || RC=$?
[[ "$RC" -eq 2 ]] && pass "Test12b: unknown flag exits 2" || fail "Test12b: expected 2, got $RC"

RC=0
bash "$SCRIPT" --all 2>/dev/null || RC=$?
[[ "$RC" -eq 2 ]] && pass "Test12c: --all with no pr_number exits 2" || fail "Test12c: expected 2, got $RC"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: pr-issue-ref.sh — all fixtures passed (issue #1281)"
