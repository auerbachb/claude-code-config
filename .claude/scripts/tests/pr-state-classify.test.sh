#!/usr/bin/env bash
# Unit test for the `classify` jq function inside `pr-state.sh --since` (issue #535).
#
# Verifies that the three comment bodies misclassified on auerbachb/inventory PR #2
# (Jul 2 2026) are now correctly classified as acknowledgments, and that existing
# patterns are not regressed.
#
# Strategy: extract the classify function definition via sed from pr-state.sh and
# exercise it in isolation with jq -n. This tests the actual production code rather
# than a copied duplicate, so the two can never drift apart.
#
# Requires: jq, bash 3.2+ (macOS-compatible — no mapfile/readarray, no head -n -N).
# Offline: no gh, no git, no network calls needed.
set -euo pipefail

# Resolve pr-state.sh relative to this test file — no git required, so the test
# runs from a source archive without .git metadata (matches the "no git" note above).
# This test lives in .claude/scripts/tests/; the script under test is one dir up.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../pr-state.sh"

PASS=0
FAIL=0

fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# Extract the classify function from the production script.
# Pattern: from "def classify:" through the first "end;" that sits at 6-space indent.
# On macOS (BSD) sed -n with ranges works the same as GNU sed here.
CLASSIFY_DEF=$(sed -n '/def classify:/,/^      end;/p' "$SCRIPT")

if [[ -z "$CLASSIFY_DEF" ]]; then
  echo "ERROR: could not extract classify function from $SCRIPT" >&2
  exit 1
fi

# Run classify on a single body string and return "class|reason".
classify_body() {
  local body="$1"
  jq -rn \
    --arg body "$body" \
    "${CLASSIFY_DEF}
    \$body | classify | .class + \"|\" + .reason"
}

# ---------------------------------------------------------------------------
# Bug 1: BugBot clean-pass review body
# Observed body: "✅ Bugbot reviewed your changes and found no new issues!"
# Was: default → finding; Should be: BugBot clean pass → acknowledgment
# ---------------------------------------------------------------------------
BODY="✅ Bugbot reviewed your changes and found no new issues!"
result=$(classify_body "$BODY")
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "BugBot clean pass" ]]; then
  pass "Bug1: BugBot clean-pass ('found no new issues') → acknowledgment"
else
  fail "Bug1: BugBot clean-pass — expected acknowledgment/BugBot clean pass, got $class/$reason"
fi

# ---------------------------------------------------------------------------
# Bug 2a: BugBot BUGBOT_REVIEW summary with 0 issues
# Observed body: "<!-- BUGBOT_REVIEW -->\nCursor Bugbot ... found 0 potential issues."
# Was: 'issues? found' finding phrase → finding; Should be: BugBot zero-issue summary → acknowledgment
# ---------------------------------------------------------------------------
BODY="<!-- BUGBOT_REVIEW -->
Cursor Bugbot has reviewed your changes and found 0 potential issues."
result=$(classify_body "$BODY")
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "BugBot zero-issue summary" ]]; then
  pass "Bug2a: BugBot BUGBOT_REVIEW 0 issues → acknowledgment"
else
  fail "Bug2a: BugBot BUGBOT_REVIEW 0 issues — expected acknowledgment/BugBot zero-issue summary, got $class/$reason"
fi

# ---------------------------------------------------------------------------
# Bug 2b: BugBot BUGBOT_REVIEW summary with N>0 issues (must remain finding)
# ---------------------------------------------------------------------------
BODY="<!-- BUGBOT_REVIEW -->
Cursor Bugbot has reviewed your changes and found 3 potential issues."
result=$(classify_body "$BODY")
class="${result%%|*}"
if [[ "$class" == "finding" ]]; then
  pass "Bug2b: BugBot BUGBOT_REVIEW 3 issues → finding (unchanged behavior)"
else
  fail "Bug2b: BugBot BUGBOT_REVIEW 3 issues — expected finding, got $class"
fi

# ---------------------------------------------------------------------------
# Bug 2c: BugBot BUGBOT_REVIEW double-digit count (must remain finding)
# ---------------------------------------------------------------------------
BODY="<!-- BUGBOT_REVIEW -->
Cursor Bugbot has reviewed your changes and found 12 potential issues."
result=$(classify_body "$BODY")
class="${result%%|*}"
if [[ "$class" == "finding" ]]; then
  pass "Bug2c: BugBot BUGBOT_REVIEW 12 issues → finding (unchanged behavior)"
else
  fail "Bug2c: BugBot BUGBOT_REVIEW 12 issues — expected finding, got $class"
fi

# ---------------------------------------------------------------------------
# Bug 3: CodeRabbit error stub
# Observed body: "Oops, something went wrong! Please try again later."
# Was: default → finding; Should be: CR error stub / transient noise → acknowledgment
# ---------------------------------------------------------------------------
BODY="Oops, something went wrong! Please try again later."
result=$(classify_body "$BODY")
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "CR error stub / transient noise" ]]; then
  pass "Bug3: CR error stub ('Oops, something went wrong') → acknowledgment"
else
  fail "Bug3: CR error stub — expected acknowledgment/CR error stub / transient noise, got $class/$reason"
fi

# ---------------------------------------------------------------------------
# Regression tests — existing patterns must not be broken
# ---------------------------------------------------------------------------

# Empty body
result=$(classify_body "")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Regression: empty body → acknowledgment" \
  || fail "Regression: empty body — got $class"

# Addressed marker
result=$(classify_body "<!-- <review_comment_addressed> -->")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Regression: addressed marker → acknowledgment" \
  || fail "Regression: addressed marker — got $class"

# CR zero actionable (old format)
result=$(classify_body "actionable comments posted: 0 — all good!")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Regression: 'actionable comments posted: 0' → acknowledgment" \
  || fail "Regression: 'actionable comments posted: 0' — got $class"

# CR no actionable comments generated (PR #424 fix)
result=$(classify_body "No actionable comments were generated in the recent review. 🎉")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Regression: 'no actionable comments were generated' → acknowledgment" \
  || fail "Regression: 'no actionable comments were generated' — got $class"

# Rate limit notice
result=$(classify_body "Rate limit exceeded — please try again.")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Regression: rate limit notice → acknowledgment" \
  || fail "Regression: rate limit notice — got $class"

# Review-started ack
result=$(classify_body "Actions performed: Full review triggered.")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Regression: 'full review triggered' → acknowledgment" \
  || fail "Regression: 'full review triggered' — got $class"

# Severity keyword — finding
result=$(classify_body "This is a critical security issue in the auth flow.")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Regression: severity keyword 'critical' → finding" \
  || fail "Regression: severity keyword 'critical' — got $class"

# Severity badge — finding
result=$(classify_body "🔴 High severity: SQL injection vulnerability detected.")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Regression: severity badge 🔴 → finding" \
  || fail "Regression: severity badge 🔴 — got $class"

# Actionable phrase (non-zero) — finding
result=$(classify_body "actionable comments posted: 3")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Regression: 'actionable comments posted: 3' → finding" \
  || fail "Regression: 'actionable comments posted: 3' — got $class"

# Finding phrase: issues found
result=$(classify_body "2 issues found in the diff.")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Regression: 'issues found' phrase → finding" \
  || fail "Regression: 'issues found' phrase — got $class"

# CR fix prompt
result=$(classify_body "Prompt for AI Agent: refactor this function.")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Regression: 'Prompt for AI Agent' → finding" \
  || fail "Regression: 'Prompt for AI Agent' — got $class"

# Suggestion block
result=$(classify_body $'```suggestion\nconst x = 1;\n```')
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Regression: suggestion block → finding" \
  || fail "Regression: suggestion block — got $class"

# LGTM variant
result=$(classify_body "LGTM! Great work on this PR.")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Regression: LGTM → acknowledgment" \
  || fail "Regression: LGTM — got $class"

# Default — unknown body → finding
result=$(classify_body "Some random comment that matches no pattern at all.")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Regression: default unknown body → finding" \
  || fail "Regression: default unknown body — got $class"

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

# Case-insensitivity: BugBot clean pass with different casing
result=$(classify_body "✅ BUGBOT REVIEWED YOUR CHANGES AND FOUND NO NEW ISSUES!")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Edge: BugBot clean-pass case-insensitive → acknowledgment" \
  || fail "Edge: BugBot clean-pass case-insensitive — got $class"

# Case-insensitivity: CR error stub lowercase
result=$(classify_body "oops, something went wrong! please try again later.")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Edge: CR error stub lowercase → acknowledgment" \
  || fail "Edge: CR error stub lowercase — got $class"

# BUGBOT_REVIEW with 1 potential issue — must be finding ([1-9][0-9]* matches 1)
BODY="<!-- BUGBOT_REVIEW -->
Cursor Bugbot has reviewed your changes and found 1 potential issues."
result=$(classify_body "$BODY")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Edge: BugBot BUGBOT_REVIEW 1 issue → finding" \
  || fail "Edge: BugBot BUGBOT_REVIEW 1 issue — got $class"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: pr-state.sh classify — all fixtures and regressions passed (issue #535)"
