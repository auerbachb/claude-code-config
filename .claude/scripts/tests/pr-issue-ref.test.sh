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

# Self-check: every check_*/assert_* helper this file calls must be defined in
# this file. A typo'd or cross-suite helper (e.g. calling check_msg where only
# check_contains exists) is command-not-found; with `set -uo pipefail` and no
# `-e` that neither aborts nor increments FAIL, so the suite reports success
# having never run the assertion. That is exactly how two Test 8 message checks
# silently vanished. Portable to bash 3.2 (macOS) as well as CI's bash 5.
# Comment lines are stripped first: prose that merely NAMES a helper (including
# the comment above) is not a call, and scanning it produced a false positive.
_undefined_helpers="$(comm -23 \
  <(grep -v '^[[:space:]]*#' "$0" | grep -ohE '\b(check|assert)_[a-z_]+' | sort -u) \
  <(grep -oE '^[a-z_]+\(\)' "$0" | tr -d '()' | sort -u))"
if [[ -n "$_undefined_helpers" ]]; then
  echo "FAIL — assertion helper(s) called but never defined in $0:" >&2
  printf '  %s\n' $_undefined_helpers >&2
  exit 1
fi

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

# PR 107 — cross-repo ref to a DIFFERENT repo and same issue number in this repo
# Regression for: Closes other-org/other-repo#99 must NOT collide with local #99.
# When GITHUB_REPOSITORY=auerbachb/claude-code-config, the cross-repo ref is filtered out.
printf 'Closes other-org/other-repo#99\nCloses #42\n' > "$TMP/pr_body/107.txt"

# PR 108 — cross-repo ref to the CURRENT repo (should be included like a bare #N)
printf 'Closes auerbachb/claude-code-config#55\n' > "$TMP/pr_body/108.txt"

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
  "repo view "*)
    # Tests 13/14 set GITHUB_REPOSITORY directly; this branch is unreachable for them.
    # Failing here is what lets a test reach the unfiltered fallback -- but ONLY when
    # GITHUB_REPOSITORY is also empty. Every test that depends on a particular repo
    # context must set GITHUB_REPOSITORY explicitly (to a value, or to "" for the
    # fallback): GitHub Actions always sets it, so a test that merely omits it reads
    # the ambient repo in CI and silently exercises a different branch than it does
    # locally. That leak is what made Tests 8 and 9 pass locally and fail in CI.
    exit 1
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
# With no resolvable repo context, --all must REFUSE rather than guess: including
# the ref risks a false collision with a local issue, excluding it risks missing a
# genuine self-reference. Both are wrong answers, so it exits 4.
# Qualified-ref PARSING is still covered with real context by Tests 13 and 14.
# ---------------------------------------------------------------------------
RC=0
MSG="$(GITHUB_REPOSITORY="" bash "$SCRIPT" --all 103 2>&1 >/dev/null)" || RC=$?
[[ "$RC" -eq 4 ]] && pass "Test8: --all refuses qualified refs with no repo context (exit 4)" \
  || fail "Test8: expected exit 4 with no repo context, got $RC"
check_contains "Test8: message names the missing repo context" "cannot resolve the current repository" "$MSG"
check_contains "Test8: message names the fix" "GITHUB_REPOSITORY" "$MSG"

# ---------------------------------------------------------------------------
# Test 9: --all mode — both bare #N and owner/repo#N
# PR 104 has "Closes #30" and "Fixes auerbachb/inventory#40"
# Mixed bare + qualified with no repo context: still refuses (exit 4), because the
# qualified ref cannot be classified. With real context the same body yields the
# bare ref only -- asserted immediately below.
# ---------------------------------------------------------------------------
RC=0
GITHUB_REPOSITORY="" bash "$SCRIPT" --all 104 >/dev/null 2>&1 || RC=$?
[[ "$RC" -eq 4 ]] && pass "Test9a: mixed refs with no repo context refuse (exit 4)" \
  || fail "Test9a: expected exit 4 with no repo context, got $RC"

OUT="$(GITHUB_REPOSITORY=auerbachb/claude-code-config bash "$SCRIPT" --all 104 2>/dev/null)"
check_line_present "Test9b: with real context, bare #30 is included" "30" "$OUT"
if printf '%s\n' "$OUT" | grep -Fxq -- "40"; then
  fail "Test9c: cross-repo #40 (auerbachb/inventory) must be excluded under real context"
else
  pass "Test9c: cross-repo #40 correctly excluded under real context"
fi

# ---------------------------------------------------------------------------
# Test 9d: no repo context is fine when the body has NO qualified refs --
# there is nothing to classify, so the refusal must not fire.
# ---------------------------------------------------------------------------
OUT="$(GITHUB_REPOSITORY="" bash "$SCRIPT" --all 102 2>/dev/null)"
check_line_present "Test9d: bare-only body works with no repo context (#10)" "10" "$OUT"
check_line_present "Test9d: bare-only body works with no repo context (#20)" "20" "$OUT"

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

# ---------------------------------------------------------------------------
# Test 13: REGRESSION — cross-repo ref to a DIFFERENT repo is excluded from --all.
# PR 107 has "Closes other-org/other-repo#99" and "Closes #42".
# With GITHUB_REPOSITORY set to this repo, only the bare #42 is returned.
# ---------------------------------------------------------------------------
OUT="$(GITHUB_REPOSITORY=auerbachb/claude-code-config bash "$SCRIPT" --all 107 2>/dev/null)"
check_line_present "Test13a: bare #42 included (same PR, different issue)" "42" "$OUT"
if printf '%s\n' "$OUT" | grep -Fxq -- "99"; then
  fail "Test13b: other-repo#99 must be excluded (got '99' in output)"
else
  pass "Test13b: other-repo#99 correctly excluded from --all output"
fi

# ---------------------------------------------------------------------------
# Test 14: REGRESSION — cross-repo ref to the CURRENT repo IS included in --all.
# PR 108 has "Closes auerbachb/claude-code-config#55".
# With GITHUB_REPOSITORY matching, issue 55 should be returned.
# ---------------------------------------------------------------------------
OUT="$(GITHUB_REPOSITORY=auerbachb/claude-code-config bash "$SCRIPT" --all 108 2>/dev/null)"
check_eq "Test14: same-repo cross-ref included in --all" "55" "$OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: pr-issue-ref.sh — all fixtures passed (issue #1281)"
