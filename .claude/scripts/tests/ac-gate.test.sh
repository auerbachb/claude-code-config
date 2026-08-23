#!/usr/bin/env bash
# Offline tests for ac-gate.sh (issue #1281).
# Stubs `gh` with fixture PR bodies and issue states; no real GitHub calls.
# Covers every acceptance criterion plus both real regression failures.
# Run from repo root:
#   bash .claude/scripts/tests/ac-gate.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/ac-gate.sh"
PR_ISSUE_REF_SH="$REPO_ROOT/.claude/scripts/pr-issue-ref.sh"

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

check_exit() {
  local desc="$1" expected_rc="$2" actual_rc="$3"
  if [[ "$actual_rc" -eq "$expected_rc" ]]; then
    pass "$desc (exit $actual_rc)"
  else
    fail "$desc (expected exit $expected_rc, got $actual_rc)"
  fi
}

check_msg() {
  local desc="$1" needle="$2" msg="$3"
  if [[ "$msg" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc (missing '$needle' in message)"
  fi
}

# ---------------------------------------------------------------------------
# Fixtures: PR bodies and issue states
# ---------------------------------------------------------------------------
mkdir -p "$TMP/pr_body" "$TMP/issue_state"

# PR 1001 — unchecked box in Test Plan (outside exemption) → exit 1
cat > "$TMP/pr_body/1001.txt" <<'BODY'
## Summary
Feature work.

## Test Plan
- [ ] verify the feature works
- [x] verify error handling
BODY

# PR 1002 — all boxes checked, no exemption needed → exit 0
cat > "$TMP/pr_body/1002.txt" <<'BODY'
## Test Plan
- [x] verify the feature works
- [x] verify error handling
BODY

# PR 1003 — empty body → exit 0
printf '' > "$TMP/pr_body/1003.txt"

# PR 1004 — Post-merge verification with unchecked boxes but no tracking line → exit 5
# (Regression for PR #593 pattern)
cat > "$TMP/pr_body/1004.txt" <<'BODY'
## Acceptance Criteria
- [x] implement the feature

## Post-merge verification
- [ ] test on physical hardware
- [ ] test on legacy firmware
BODY

# PR 1005 — self-referential tracking issue (closes #99, tracks #99) → exit 6
# Reproduces the PR #588 regression: tracking line points at issue this PR closes.
cat > "$TMP/pr_body/1005.txt" <<'BODY'
Closes #99

## Acceptance Criteria
- [x] feature implemented

## Post-merge verification
- [ ] iOS import path test on dev client
Tracking issue: #99
BODY
echo "OPEN" > "$TMP/issue_state/99.txt"

# PR 1006 — tracking issue is CLOSED → exit 7
cat > "$TMP/pr_body/1006.txt" <<'BODY'
Closes #80

## Acceptance Criteria
- [x] feature implemented

## Post-merge verification
- [ ] test on physical hardware
Tracking issue: #50
BODY
echo "OPEN" > "$TMP/issue_state/80.txt"
echo "CLOSED" > "$TMP/issue_state/50.txt"

# PR 1007 — valid exemption: open tracking issue, not self-referential → exit 0
cat > "$TMP/pr_body/1007.txt" <<'BODY'
Closes #80

## Acceptance Criteria
- [x] feature implemented

## Post-merge verification
- [ ] test on physical hardware
Tracking issue: #60
BODY
echo "OPEN" > "$TMP/issue_state/60.txt"

# PR 1008 — tracking line OUTSIDE the section (before the heading) → exit 5
cat > "$TMP/pr_body/1008.txt" <<'BODY'
Tracking issue: #60

## Acceptance Criteria
- [x] feature implemented

## Post-merge verification
- [ ] test on physical hardware
BODY

# PR 1009 — wrong heading case (not exact "Post-merge verification") → exit 0
# The wrong-case heading is treated as "other"; boxes there are invisible to the gate.
# This confirms the exact-case requirement: no exemption checks run, and the gate passes
# because no unchecked boxes exist in AC/Test Plan sections.
cat > "$TMP/pr_body/1009.txt" <<'BODY'
## Acceptance Criteria
- [x] feature implemented

## Post-Merge Verification
- [ ] test on physical hardware
Tracking issue: #60
BODY

# PR 1010 — Acceptance Criteria section heading (case-insensitive match) → exit 1
cat > "$TMP/pr_body/1010.txt" <<'BODY'
## acceptance criteria
- [ ] unchecked item
BODY

# PR 2001 — owner/repo#N closing form detected (cross-repo self-referential) → exit 6
# The tracking issue #99 is also referenced via the owner/repo#N closing keyword.
cat > "$TMP/pr_body/2001.txt" <<'BODY'
Closes auerbachb/claude-code-config#99

## Acceptance Criteria
- [x] feature implemented

## Post-merge verification
- [ ] test on physical hardware
Tracking issue: #99
BODY

# PR 588 — regression: real self-referential failure from 2026-08-22
# PR closes #588 (via Closes #588) and the tracking line also points at #588.
cat > "$TMP/pr_body/588.txt" <<'BODY'
Closes #588

## Acceptance Criteria
- [x] implement iOS upload path

## Post-merge verification
- [ ] iOS import path test on rebuilt dev client
Tracking issue: #588
BODY
echo "OPEN" > "$TMP/issue_state/588.txt"

# PR 593 — regression: real missing-tracking-line failure from 2026-08-22
# Had Post-merge verification section with five hardware-only criteria but no tracking line.
cat > "$TMP/pr_body/593.txt" <<'BODY'
## Acceptance Criteria
- [x] implement firmware update

## Post-merge verification
- [ ] hardware-only criterion 1
- [ ] hardware-only criterion 2
- [ ] hardware-only criterion 3
- [ ] hardware-only criterion 4
- [ ] hardware-only criterion 5
BODY

# ---------------------------------------------------------------------------
# gh stub — serves PR bodies and issue states.
# Handles all three call patterns:
#   pr view N --json body ...      → PR body text (used by both ac-gate.sh
#                                    AND pr-issue-ref.sh --all inside it)
#   issue view N --json state ...  → OPEN or CLOSED
# The stub absorbs all flags after the pr/issue subcommand so both
# ac-gate.sh and pr-issue-ref.sh can call it without unhandled-arg errors.
# ---------------------------------------------------------------------------
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
subcmd="\$1"
shift
case "\$subcmd" in
  pr)
    # Expect: view <N> [flags...]
    action="\$1"; shift
    case "\$action" in
      view)
        n="\$1"
        if [ -f "$TMP/pr_body/\${n}.txt" ]; then
          cat "$TMP/pr_body/\${n}.txt"
        else
          echo "Error: PR #\${n} not found" >&2
          exit 1
        fi
        ;;
      *)
        echo "gh stub: unhandled pr action: \$action" >&2; exit 1 ;;
    esac
    ;;
  issue)
    action="\$1"; shift
    case "\$action" in
      view)
        n="\$1"
        if [ -f "$TMP/issue_state/\${n}.txt" ]; then
          cat "$TMP/issue_state/\${n}.txt"
        else
          echo "Error: issue #\${n} not found" >&2
          exit 1
        fi
        ;;
      *)
        echo "gh stub: unhandled issue action: \$action" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "gh stub: unhandled subcmd: \$subcmd" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

# ---------------------------------------------------------------------------
# REGRESSION VERIFICATION: confirm each failure fixture fails the real gate.
#
# Run the real gate against each failure fixture to confirm it returns a
# non-zero exit code. This proves the fixtures are gate-sensitive: they were
# written to exercise real failure paths, not pass for an accidental reason.
# ---------------------------------------------------------------------------

echo "--- Regression verification: fixtures fail with the real gate ---"

# Verify PR 1001 (unchecked AC box) fails the real gate.
RC=0
bash "$SCRIPT" 1001 2>/dev/null || RC=$?
if [[ "$RC" -ne 0 ]]; then
  pass "Regression check: PR 1001 (unchecked AC box) correctly fails the real gate (exit $RC)"
else
  fail "Regression check: PR 1001 should fail but gate returned exit 0"
fi

# PR 588 self-referential: verify the real gate fails (not the stub-always-pass)
RC=0
bash "$SCRIPT" 588 2>/dev/null || RC=$?
if [[ "$RC" -ne 0 ]]; then
  pass "Regression check: PR 588 (self-referential tracking) correctly fails the real gate (exit $RC)"
else
  fail "Regression check: PR 588 should fail but gate returned exit 0"
fi

# PR 593 no-tracking-line: verify the real gate fails
RC=0
bash "$SCRIPT" 593 2>/dev/null || RC=$?
if [[ "$RC" -ne 0 ]]; then
  pass "Regression check: PR 593 (no tracking line) correctly fails the real gate (exit $RC)"
else
  fail "Regression check: PR 593 should fail but gate returned exit 0"
fi

echo "--- End regression verification ---"
echo ""

# ---------------------------------------------------------------------------
# Test 1: unchecked box outside exemption section → exit 1 + message
# ---------------------------------------------------------------------------
RC=0
MSG="$(bash "$SCRIPT" 1001 2>&1 >/dev/null)" || RC=$?
check_exit "Test1: unchecked AC box fails gate" 1 "$RC"
check_msg  "Test1: message names the condition" "unchecked acceptance-criteria box" "$MSG"
check_msg  "Test1: message names the fix" "Fix:" "$MSG"

# ---------------------------------------------------------------------------
# Test 2: all boxes checked → exit 0
# ---------------------------------------------------------------------------
RC=0
bash "$SCRIPT" 1002 2>/dev/null || RC=$?
check_exit "Test2: all boxes checked passes gate" 0 "$RC"

# ---------------------------------------------------------------------------
# Test 3: empty body → exit 0
# ---------------------------------------------------------------------------
RC=0
bash "$SCRIPT" 1003 2>/dev/null || RC=$?
check_exit "Test3: empty body passes gate" 0 "$RC"

# ---------------------------------------------------------------------------
# Test 4: Post-merge verification with no tracking line → exit 5 + message
# (Regression for PR #593 pattern)
# ---------------------------------------------------------------------------
RC=0
MSG="$(bash "$SCRIPT" 1004 2>&1 >/dev/null)" || RC=$?
check_exit "Test4: exemption section with no tracking line fails (exit 5)" 5 "$RC"
check_msg  "Test4: message names the condition (no Tracking issue line)" "no 'Tracking issue: #N' line" "$MSG"
check_msg  "Test4: message names the fix" "Fix:" "$MSG"

# ---------------------------------------------------------------------------
# Test 5: self-referential tracking issue → exit 6 + message
# (Core regression for PR #588 pattern)
# ---------------------------------------------------------------------------
RC=0
MSG="$(bash "$SCRIPT" 1005 2>&1 >/dev/null)" || RC=$?
check_exit "Test5: self-referential tracking issue fails (exit 6)" 6 "$RC"
check_msg  "Test5: message names the PR #588 pattern" "PR #588" "$MSG"
check_msg  "Test5: message names the fix" "Fix:" "$MSG"

# ---------------------------------------------------------------------------
# Test 6: tracking issue is CLOSED → exit 7 + message
# ---------------------------------------------------------------------------
RC=0
MSG="$(bash "$SCRIPT" 1006 2>&1 >/dev/null)" || RC=$?
check_exit "Test6: closed tracking issue fails (exit 7)" 7 "$RC"
check_msg  "Test6: message names the CLOSED condition" "CLOSED" "$MSG"
check_msg  "Test6: message names the fix" "Fix:" "$MSG"

# ---------------------------------------------------------------------------
# Test 7: valid exemption (open tracking issue, not self-referential) → exit 0
# ---------------------------------------------------------------------------
RC=0
bash "$SCRIPT" 1007 2>/dev/null || RC=$?
check_exit "Test7: valid open tracking issue passes gate" 0 "$RC"

# ---------------------------------------------------------------------------
# Test 8: tracking line outside the section grants no exemption → exit 5
# ---------------------------------------------------------------------------
RC=0
MSG="$(bash "$SCRIPT" 1008 2>&1 >/dev/null)" || RC=$?
check_exit "Test8: tracking line outside section → no exemption (exit 5)" 5 "$RC"
check_msg  "Test8: message names the missing-line condition" "no 'Tracking issue: #N' line" "$MSG"

# ---------------------------------------------------------------------------
# Test 9: wrong heading case (Post-Merge Verification) → exit 0
# The wrong-case heading is treated as 'other'; boxes there are not in scope.
# This verifies the exact-case requirement: the wrong-case heading does not
# grant exemption AND does not cause in-scope failures.
# ---------------------------------------------------------------------------
RC=0
bash "$SCRIPT" 1009 2>/dev/null || RC=$?
check_exit "Test9: wrong heading case — not an exemption and not in-scope (passes)" 0 "$RC"

# ---------------------------------------------------------------------------
# Test 10: Acceptance Criteria section — case-insensitive heading match
# ---------------------------------------------------------------------------
RC=0
MSG="$(bash "$SCRIPT" 1010 2>&1 >/dev/null)" || RC=$?
check_exit "Test10: case-insensitive AC heading detected (exit 1)" 1 "$RC"
check_msg  "Test10: message references unchecked box" "unchecked" "$MSG"

# ---------------------------------------------------------------------------
# Test 11: owner/repo#N closing form — self-referential check via --all
# PR 2001 body: Closes auerbachb/claude-code-config#99, tracks #99 → exit 6
# ---------------------------------------------------------------------------
RC=0
MSG="$(bash "$SCRIPT" 2001 2>&1 >/dev/null)" || RC=$?
check_exit "Test11: owner/repo#N closing form detected as self-referential (exit 6)" 6 "$RC"
check_msg  "Test11: message names the PR #588 pattern" "PR #588" "$MSG"

# ---------------------------------------------------------------------------
# Test 12: REGRESSION — PR #588 exact self-referential pattern → exit 6
# ---------------------------------------------------------------------------
RC=0
MSG="$(bash "$SCRIPT" 588 2>&1 >/dev/null)" || RC=$?
check_exit "Test12: regression PR #588 self-referential tracking (exit 6)" 6 "$RC"
check_msg  "Test12: message names the PR #588 pattern" "PR #588" "$MSG"

# ---------------------------------------------------------------------------
# Test 13: REGRESSION — PR #593 no tracking line → exit 5
# ---------------------------------------------------------------------------
RC=0
MSG="$(bash "$SCRIPT" 593 2>&1 >/dev/null)" || RC=$?
check_exit "Test13: regression PR #593 no tracking line (exit 5)" 5 "$RC"
check_msg  "Test13: message names the missing-line condition" "no 'Tracking issue: #N' line" "$MSG"

# ---------------------------------------------------------------------------
# Test 14: usage errors
# ---------------------------------------------------------------------------
RC=0
bash "$SCRIPT" 2>/dev/null || RC=$?
check_exit "Test14a: missing pr_number exits 2" 2 "$RC"
RC=0
bash "$SCRIPT" --bogus 2>/dev/null || RC=$?
check_exit "Test14b: unknown flag exits 2" 2 "$RC"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: ac-gate.sh — all fixtures passed (issue #1281)"
