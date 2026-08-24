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

# PR 1009 — wrong heading case (not exact "Post-merge verification") → exit 1
# Near-miss headings are NOT exemption regions and NOT invisible: unchecked boxes
# there count as in-scope failures (exit 1).  Exact-case requirement enforced.
cat > "$TMP/pr_body/1009.txt" <<'BODY'
## Acceptance Criteria
- [x] feature implemented

## Post-Merge Verification
- [ ] test on physical hardware
Tracking issue: #60
BODY

# PR 1010 — Acceptance Criteria section heading (case-insensitive match, all-lowercase) → exit 1
cat > "$TMP/pr_body/1010.txt" <<'BODY'
## acceptance criteria
- [ ] unchecked item
BODY

# PR 1013 — Acceptance Criteria section heading (canonical mixed-case) → exit 1
# Regression for: "## Acceptance Criteria" (the canonical form used by every PR in this repo)
# must be detected as an in-scope section; an unchecked box there must fail the gate.
# The parser normalises the heading with tr 'A-Z' 'a-z' before routing, so this must match
# the "acceptance criteria" case branch.
cat > "$TMP/pr_body/1013.txt" <<'BODY'
## Acceptance Criteria
- [x] Box already checked
- [ ] Unchecked box — gate must fail (exit 1)
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

# PR 1011 — multiple Post-merge verification sections (section 1 no tracking, section 2 has one)
# Regression for the HAS_UNCHECKED_EXEMPT accumulation bug: section 1 has unchecked boxes and no
# tracking issue; section 2 supplies a tracking issue. The gate must fail on section 1 (exit 5).
cat > "$TMP/pr_body/1011.txt" <<'BODY'
## Acceptance Criteria
- [x] feature implemented

## Post-merge verification
- [ ] test on hardware (section 1, no tracking issue)

## Other section

## Post-merge verification
- [ ] another deferred item (section 2)
Tracking issue: #60
BODY

# PR 1012 — pr-issue-ref.sh returns exit 4 (API failure): gate must exit 4.
# The body has a valid Post-merge verification section with a tracking issue so
# the self-referential check runs. A special temp directory supplies a failing
# pr-issue-ref.sh for this test only (see Test15 below).
cat > "$TMP/pr_body/1012.txt" <<'BODY'
## Post-merge verification
- [ ] deferred item
Tracking issue: #77
BODY
echo "OPEN" > "$TMP/issue_state/77.txt"

# PR 1016 — REGRESSION: indented headings. Markdown allows up to three leading
# spaces before '##'. Requiring '^## ' made an indented section invisible, so its
# unchecked boxes bypassed the gate (fail-open). ac-checkboxes.sh already accepted
# these forms, so the two helpers also disagreed. Must fail with exit 1.
printf '%s\n' \
  '  ## Acceptance Criteria' \
  '- [ ] indented heading, unchecked box' \
  > "$TMP/pr_body/1016.txt"

# PR 1017 — same, three spaces and extra space after the marker, on Test Plan.
printf '%s\n' \
  '   ##   Test Plan' \
  '- [ ] deeply indented heading, unchecked box' \
  > "$TMP/pr_body/1017.txt"

# PR 1014 — REGRESSION: earlier exemption section is self-referential, later one is CLEAN.
# The later clean section reset HAS_UNCHECKED_EXEMPT to 0, so Stage 2 was skipped entirely
# and the self-referential section 1 was never validated -- the gate passed (fail-open).
# Section 1 tracks #99, which this PR also closes, so it must fail with exit 6.
cat > "$TMP/pr_body/1014.txt" <<'BODY'
Closes #99

## Acceptance Criteria
- [x] feature implemented

## Post-merge verification
- [ ] deferred item (section 1)
Tracking issue: #99

## Other section

## Post-merge verification
- [x] already done (section 2 — no unchecked boxes)
Tracking issue: #60
BODY

# PR 1015 — REGRESSION: same shape, but section 1 names a CLOSED issue (#50).
# Must fail with exit 7 rather than being laundered by the clean section 2.
cat > "$TMP/pr_body/1015.txt" <<'BODY'
## Acceptance Criteria
- [x] feature implemented

## Post-merge verification
- [ ] deferred item (section 1)
Tracking issue: #50

## Other section

## Post-merge verification
- [x] already done (section 2 — no unchecked boxes)
Tracking issue: #60
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
  repo)
    action="\$1"; shift
    case "\$action" in
      view)
        # Return a dummy repo nameWithOwner for pr-issue-ref.sh --all cross-repo filtering.
        echo "auerbachb/claude-code-config"
        ;;
      *)
        echo "gh stub: unhandled repo action: \$action" >&2; exit 1 ;;
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

# PR 1009 malformed heading: verify the real gate now fails (wrong-case = in-scope failure)
RC=0
bash "$SCRIPT" 1009 2>/dev/null || RC=$?
if [[ "$RC" -ne 0 ]]; then
  pass "Regression check: PR 1009 (malformed heading) correctly fails the real gate (exit $RC)"
else
  fail "Regression check: PR 1009 should fail but gate returned exit 0"
fi

# PR 1013 canonical '## Acceptance Criteria' heading: verify the real gate fails
RC=0
bash "$SCRIPT" 1013 2>/dev/null || RC=$?
if [[ "$RC" -ne 0 ]]; then
  pass "Regression check: PR 1013 (canonical AC heading, unchecked box) correctly fails the real gate (exit $RC)"
else
  fail "Regression check: PR 1013 should fail but gate returned exit 0 (heading not recognised as in-scope)"
fi

# PR 1011 multiple postmerge sections: verify the real gate fails on section 1
RC=0
bash "$SCRIPT" 1011 2>/dev/null || RC=$?
if [[ "$RC" -ne 0 ]]; then
  pass "Regression check: PR 1011 (multiple sections, section 1 no tracking) correctly fails (exit $RC)"
else
  fail "Regression check: PR 1011 should fail but gate returned exit 0"
fi

# PR 1014 multi-section self-referential: the real gate must fail (was fail-open)
RC=0
bash "$SCRIPT" 1014 2>/dev/null || RC=$?
if [[ "$RC" -ne 0 ]]; then
  pass "Regression check: PR 1014 (section 1 self-referential, section 2 clean) correctly fails (exit $RC)"
else
  fail "Regression check: PR 1014 should fail but gate returned exit 0 (earlier section discarded)"
fi

# PR 1015 multi-section closed tracking issue: the real gate must fail (was fail-open)
RC=0
bash "$SCRIPT" 1015 2>/dev/null || RC=$?
if [[ "$RC" -ne 0 ]]; then
  pass "Regression check: PR 1015 (section 1 closed issue, section 2 clean) correctly fails (exit $RC)"
else
  fail "Regression check: PR 1015 should fail but gate returned exit 0 (earlier section discarded)"
fi

# PR 1016/1017 indented headings: the real gate must fail (was fail-open)
for _p in 1016 1017; do
  RC=0
  bash "$SCRIPT" "$_p" 2>/dev/null || RC=$?
  if [[ "$RC" -ne 0 ]]; then
    pass "Regression check: PR $_p (indented heading) correctly fails (exit $RC)"
  else
    fail "Regression check: PR $_p should fail but gate returned exit 0 (indented heading ignored)"
  fi
done

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
# Test 9: wrong heading case (Post-Merge Verification) → exit 1
# A near-miss heading (case-insensitive match but wrong case) is NOT an exemption
# region and its unchecked boxes ARE in-scope failures. Boxes there are not
# invisible — they cause a hard exit 1.
# ---------------------------------------------------------------------------
RC=0
MSG="$(bash "$SCRIPT" 1009 2>&1 >/dev/null)" || RC=$?
check_exit "Test9: malformed heading — boxes count as in-scope (exit 1)" 1 "$RC"
check_msg  "Test9: message names the unchecked box condition" "unchecked" "$MSG"

# ---------------------------------------------------------------------------
# Test 10: Acceptance Criteria section — case-insensitive heading (all-lowercase)
# ---------------------------------------------------------------------------
RC=0
MSG="$(bash "$SCRIPT" 1010 2>&1 >/dev/null)" || RC=$?
check_exit "Test10: all-lowercase AC heading detected (exit 1)" 1 "$RC"
check_msg  "Test10: message references unchecked box" "unchecked" "$MSG"

# ---------------------------------------------------------------------------
# Test 10a: REGRESSION — canonical '## Acceptance Criteria' heading (mixed case)
# Regression guard: the parser normalises headings via tr 'A-Z' 'a-z' before
# routing, so '## Acceptance Criteria' must match the "acceptance criteria" case
# branch and mark its unchecked boxes as in-scope failures (exit 1).
# ---------------------------------------------------------------------------
RC=0
MSG="$(bash "$SCRIPT" 1013 2>&1 >/dev/null)" || RC=$?
check_exit "Test10a: canonical mixed-case AC heading detected (exit 1)" 1 "$RC"
check_msg  "Test10a: message references unchecked box" "unchecked" "$MSG"

# ---------------------------------------------------------------------------
# Test 11: owner/repo#N closing form — self-referential check via --all
# PR 2001 body: Closes auerbachb/claude-code-config#99, tracks #99 → exit 6
# ---------------------------------------------------------------------------
RC=0
MSG="$(bash "$SCRIPT" 2001 2>&1 >/dev/null)" || RC=$?
check_exit "Test11: owner/repo#N closing form detected as self-referential (exit 6)" 6 "$RC"
check_msg  "Test11: message names the PR #588 pattern" "PR #588" "$MSG"

# ---------------------------------------------------------------------------
# Test 11b: REGRESSION — every exemption section is validated, not just the last.
# PR 1014: section 1 self-referential (#99, also closed by this PR), section 2 clean.
# ---------------------------------------------------------------------------
RC=0
MSG="$(bash "$SCRIPT" 1014 2>&1 >/dev/null)" || RC=$?
check_exit "Test11b: earlier self-referential section still fails (exit 6)" 6 "$RC"
check_msg  "Test11b: message names the offending tracking issue" "#99" "$MSG"

# ---------------------------------------------------------------------------
# Test 11c: REGRESSION — same, with a CLOSED tracking issue in the earlier section.
# PR 1015: section 1 tracks closed #50, section 2 clean.
# ---------------------------------------------------------------------------
RC=0
MSG="$(bash "$SCRIPT" 1015 2>&1 >/dev/null)" || RC=$?
check_exit "Test11c: earlier section with CLOSED tracking issue still fails (exit 7)" 7 "$RC"
check_msg  "Test11c: message names the closed tracking issue" "#50" "$MSG"

# ---------------------------------------------------------------------------
# Test 11d: REGRESSION — indented '## Acceptance Criteria' is still in scope.
# ---------------------------------------------------------------------------
RC=0
MSG="$(bash "$SCRIPT" 1016 2>&1 >/dev/null)" || RC=$?
check_exit "Test11d: indented AC heading still gated (exit 1)" 1 "$RC"
check_msg  "Test11d: message names the unchecked-box condition" "unchecked acceptance-criteria box" "$MSG"

# ---------------------------------------------------------------------------
# Test 11e: REGRESSION — three-space indent plus extra space after '##'.
# ---------------------------------------------------------------------------
RC=0
bash "$SCRIPT" 1017 2>/dev/null || RC=$?
check_exit "Test11e: deeply indented Test Plan heading still gated (exit 1)" 1 "$RC"

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

# ---------------------------------------------------------------------------
# Test 15: REGRESSION — multiple Post-merge verification sections.
# Section 1 has an unchecked box and no tracking issue; section 2 supplies a
# tracking issue. Gate must reject on section 1 (exit 5), not let section 2
# cover section 1's unchecked boxes.
# ---------------------------------------------------------------------------
RC=0
MSG="$(bash "$SCRIPT" 1011 2>&1 >/dev/null)" || RC=$?
check_exit "Test15: multiple postmerge sections — section 1 fails without tracking (exit 5)" 5 "$RC"
check_msg  "Test15: message names the missing-line condition" "no 'Tracking issue: #N' line" "$MSG"

# ---------------------------------------------------------------------------
# Test 16: pr-issue-ref.sh API failure propagated as gate exit 4.
# Uses a temporary ac-gate.sh copy alongside a failing pr-issue-ref.sh stub
# to verify the gate does not silently swallow subprocess errors.
# ---------------------------------------------------------------------------
AC_GATE_TMP="$TMP/ac_gate_issue2"
mkdir -p "$AC_GATE_TMP"
cp "$SCRIPT" "$AC_GATE_TMP/ac-gate.sh"
cat > "$AC_GATE_TMP/pr-issue-ref.sh" <<'FAILING_REF'
#!/usr/bin/env bash
echo "Error: simulated gh API failure" >&2
exit 4
FAILING_REF
RC=0
MSG="$(bash "$AC_GATE_TMP/ac-gate.sh" 1012 2>&1 >/dev/null)" || RC=$?
check_exit "Test16: pr-issue-ref.sh exit 4 → gate exits 4" 4 "$RC"
check_msg  "Test16: message names the pr-issue-ref failure" "pr-issue-ref.sh" "$MSG"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: ac-gate.sh — all fixtures passed (issue #1281)"
