#!/usr/bin/env bash
# Bounded evaluator-outage suppression in escalate-review.sh (issue #1465).
#
# THE BUG: escalate-review.sh and merge-gate.sh call the same review-substance.sh
# evaluator. merge-gate.sh die_local()s when it is unusable; escalate-review.sh
# only set PRIMARY_REVIEW_MET=false, which is indistinguishable from "no reviewer
# has approved". A sustained outage therefore walked the whole chain and
# authorised a PAID Greptile review that no reviewer had withheld — a tooling
# fault spending money (CodeAnt, PR #1463).
#
# THE FIX (recorded decision, 2026-09-02 — option 3 plus option 4's
# documentation): while the evaluator is unusable AND the PR is inside
# EVALUATOR_OUTAGE_CAP_SECONDS, the verdict is capped at polling_cr; past the cap
# escalation resumes so a permanent outage cannot strand the PR. No new STATUS
# value — every caller's `case` treats an unrecognised verdict as fatal.
#
# EVERY scenario carries a valid APPROVED on HEAD, because escalate-review.sh
# only consults the evaluator when one exists. Without it both outage branches
# are unreachable and this whole suite would pass while testing nothing.
#
# Ages are chosen so polling_cr can come from NOTHING BUT the cap: every fixture
# is CR-rate-limited (so the 720 s CR window never emits) and carries a BugBot
# usage-limit failure (so neither the BugBot grace window, which needs
# age < 600 s, nor the never-invited route can emit). 900 s therefore isolates
# the guard, and the 3540/4000 pair brackets the 3600 s cap without racing the
# clock the way an exactly-3600 fixture would.
#
# Shared fixtures live in tests/lib/escalate-review-fixtures.sh.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/escalate-review-fixtures.sh
source "$TEST_DIR/lib/escalate-review-fixtures.sh"

INSIDE_CAP_AGE=900        # inside the cap, past every other polling_cr source
NEAR_CAP_AGE=3540         # still inside, 60 s under the cap
PAST_CAP_AGE=4000         # past the cap — escalation must resume

check_stderr_has() { # label file needle
  if grep -qF -- "$3" "$2"; then
    check_eq "$1" "present" "present"
  else
    check_eq "$1" "present" "absent"
  fi
}
check_stderr_lacks() { # label file needle
  if grep -qF -- "$3" "$2"; then
    check_eq "$1" "absent" "present"
  else
    check_eq "$1" "absent" "absent"
  fi
}

# ---- evaluator health, and PROOF the manipulation landed --------------------
# A silent failure here would leave the evaluator healthy and turn every outage
# scenario into an ordinary run that happens to expect the same verdict for the
# wrong reason. Assert the setup RAN, not just its outcome.
EVALUATOR="$STUB_DIR/review-substance.sh"

break_evaluator_missing() {
  rm -f "$EVALUATOR"
  [[ -e "$EVALUATOR" ]] \
    && check_eq "evaluator removed from the stub dir" "absent" "present" \
    || check_eq "evaluator removed from the stub dir" "absent" "absent"
}

# $1 = the body the broken evaluator prints. stdin is drained so the jq producer
# feeding it never dies on SIGPIPE instead of the branch under test firing.
break_evaluator_output() {
  { printf '#!/usr/bin/env bash\ncat >/dev/null\n'; printf 'printf %s\n' "'$1\n'"; } > "$EVALUATOR"
  chmod +x "$EVALUATOR"
  local got
  got="$(printf '{}' | "$EVALUATOR" 2>/dev/null)"
  check_eq "evaluator replaced with a non-conforming stub" "$1" "$got"
}

restore_evaluator() {
  cp "$REPO_ROOT/.claude/scripts/review-substance.sh" "$EVALUATOR"
  chmod +x "$EVALUATOR"
  [[ -x "$EVALUATOR" ]] \
    && check_eq "real evaluator restored" "executable" "executable" \
    || check_eq "real evaluator restored" "executable" "missing"
}

# ---- shared fixture ---------------------------------------------------------
# A SUBSTANTIVE approval on purpose: with a hollow one the outage scenarios would
# still escalate once the evaluator came back, so the healthy-evaluator control
# (d) could not distinguish "the cap suppressed it" from "the approval was never
# good enough". $1 = push age in seconds.
outage_fixture() {
  local age="$1" approved_at
  reset_state
  write_commits "$(ts_seconds_ago "$age")"
  approved_at="$(ts_seconds_ago $(( age - 30 )))"
  local approval failure
  approval='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed every changed file in the escalation gate; no blocking issues found.", "submitted_at": "'"$approved_at"'"}'
  failure="$(failure_comment "$(ts_seconds_ago 60)")"
  write_state "[$BUGBOT_CHECK_RUN_OK]" "[$approval]" "[]" "[$failure]"
}

############################################################################
echo "== Scenario (a): evaluator MISSING, age inside the cap -> polling_cr (paid escalation suppressed) =="
break_evaluator_missing
outage_fixture "$INSIDE_CAP_AGE"
OUT=$(run_script 2>"$TMP/a-stderr.txt"); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"
# Attribution, both halves: the outage site announced the fault, and the cap
# announced what it cost. Without these, (a) would keep passing if the verdict
# ever came from an unrelated polling_cr arm.
check_stderr_has "(a) outage site announced the missing evaluator" "$TMP/a-stderr.txt" \
  "review-substance.sh not found or not executable"
check_stderr_has "(a) cap announced the suppression" "$TMP/a-stderr.txt" \
  "DEGRADED: review-substance.sh unavailable — paid escalation suppressed"

############################################################################
echo "== Scenario (a2): evaluator MISSING, 60 s under the cap -> still polling_cr =="
outage_fixture "$NEAR_CAP_AGE"
OUT=$(run_script 2>"$TMP/a2-stderr.txt"); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"
check_stderr_has "(a2) cap announced the suppression near its boundary" "$TMP/a2-stderr.txt" \
  "paid escalation suppressed"

############################################################################
echo "== Scenario (b): evaluator emits NON-JSON, age inside the cap -> polling_cr =="
break_evaluator_output "not json at all"
outage_fixture "$INSIDE_CAP_AGE"
OUT=$(run_script 2>"$TMP/b-stderr.txt"); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"
check_stderr_has "(b) outage site announced the unusable output" "$TMP/b-stderr.txt" \
  "review-substance.sh produced no usable JSON"
check_stderr_has "(b) cap announced the suppression" "$TMP/b-stderr.txt" \
  "DEGRADED: review-substance.sh unavailable — paid escalation suppressed"

############################################################################
echo "== Scenario (b2): evaluator emits well-formed JSON of the WRONG SHAPE -> polling_cr =="
# Parseable but structurally wrong. escalate-review.sh tests the structure, not
# just parseability, because a bare string or a missing .reviewers object reads
# as "nothing is substantive" for every reviewer — a degraded run wearing a
# legitimate verdict. That path must reach the cap too.
break_evaluator_output '{"reviewers": "not-an-object"}'
outage_fixture "$INSIDE_CAP_AGE"
OUT=$(run_script 2>"$TMP/b2-stderr.txt"); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"
check_stderr_has "(b2) structure test rejected the wrong shape" "$TMP/b2-stderr.txt" \
  "review-substance.sh produced no usable JSON"
check_stderr_has "(b2) cap announced the suppression" "$TMP/b2-stderr.txt" \
  "paid escalation suppressed"

############################################################################
echo "== Scenario (c): evaluator MISSING, age PAST the cap -> trigger_greptile (no permanent stranding) =="
break_evaluator_missing
outage_fixture "$PAST_CAP_AGE"
OUT=$(run_script 2>"$TMP/c-stderr.txt"); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"
# The resumed path is announced too, so a `DEGRADED:` grep sees the whole outage
# rather than only the half where spending was suppressed.
check_stderr_has "(c) resumption announced" "$TMP/c-stderr.txt" \
  "outage window of 3600s exceeded"
check_stderr_lacks "(c) suppression did NOT fire past the cap" "$TMP/c-stderr.txt" \
  "paid escalation suppressed"

############################################################################
echo "== Scenario (d): SAME fixture, HEALTHY evaluator, age inside the cap -> gate_met =="
# The discrimination control. Without it, (a)/(b) would pass on a fixture that
# could never have produced anything but polling_cr, and the suite would prove
# nothing about the cap. Same age, same approval, same BugBot failure — the only
# difference is that the evaluator works.
restore_evaluator
outage_fixture "$INSIDE_CAP_AGE"
OUT=$(run_script 2>"$TMP/d-stderr.txt"); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=gate_met" "STATUS=gate_met" "$OUT"
check_stderr_lacks "(d) no degraded notice on a healthy run" "$TMP/d-stderr.txt" "DEGRADED:"

############################################################################
echo "== Scenario (e): HEALTHY evaluator, HOLLOW approval, age inside the cap -> trigger_greptile (the flag must not leak) =="
# The scope control. "No reviewer holds BOTH a valid APPROVED and substantive
# evidence" is the evaluator ANSWERING, not failing — an adjudicated verdict that
# must keep escalating exactly as before. If EVALUATOR_UNUSABLE were ever set on
# that branch, this age (inside the cap) would return polling_cr instead, and the
# #875 hollow-approval guard would be silently defeated by the #1465 fix.
reset_state
write_commits "$(ts_seconds_ago "$INSIDE_CAP_AGE")"
CA_HOLLOW_E='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "", "submitted_at": "'"$(ts_seconds_ago $(( INSIDE_CAP_AGE - 30 )))"'"}'
FAILURE_COMMENT_E="$(failure_comment "$(ts_seconds_ago 60)")"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CA_HOLLOW_E]" "[]" "[$FAILURE_COMMENT_E]"
OUT=$(run_script 2>"$TMP/e-stderr.txt"); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"
check_stderr_has "(e) the hollow-approval guard is what withheld" "$TMP/e-stderr.txt" \
  "no reviewer holds BOTH a valid APPROVED on HEAD and substantive review evidence"
check_stderr_lacks "(e) an adjudicated verdict is not an outage" "$TMP/e-stderr.txt" "DEGRADED:"

############################################################################
echo "== Scenario (f): the recorded cap value is pinned in the source =="
# 3600 s is the decision, not an implementation detail: "suppression holds while
# AGE_SECONDS <= 3600". The 3540/4000 pair above brackets it, but only loosely —
# this pins the number itself so a silent retune has to come with a decision.
if grep -qE '^EVALUATOR_OUTAGE_CAP_SECONDS=3600$' "$ESCALATE_SRC"; then
  check_eq "(f) EVALUATOR_OUTAGE_CAP_SECONDS is 3600" "present" "present"
else
  check_eq "(f) EVALUATOR_OUTAGE_CAP_SECONDS is 3600" "present" "absent"
fi
# ...and the bound is INCLUSIVE, as the decision states. A `-lt` would still pass
# every behavioural scenario above, since none of them lands on the boundary.
if grep -qF -- '-le "$EVALUATOR_OUTAGE_CAP_SECONDS"' "$ESCALATE_SRC"; then
  check_eq "(f) the cap comparison is inclusive (-le)" "present" "present"
else
  check_eq "(f) the cap comparison is inclusive (-le)" "present" "absent"
fi

############################################################################
echo
echo "== NEGATIVE CONTROL: the pre-change script emits trigger_greptile on scenario (a)'s fixture =="
# HERMETIC ON PURPOSE. Reading the pre-change script back from `origin/main` is
# the obvious reproduction and is wrong twice over: CI checks out shallow
# (.github/workflows/hook-scripts.yml), so the control would SKIP in the very
# environment it protects, and once this fix merges origin/main would carry it,
# so the control would silently invert. Same reasoning recorded in
# churn-hotspots.test.sh scenario 26 and pr-issue-ref.test.sh tests 15-18.
#
# Instead the guard block is stripped between its own markers. The strip yields
# PRE-CHANGE BEHAVIOUR, not merely different behaviour, because nothing outside
# that block reads EVALUATOR_UNUSABLE — asserted below rather than assumed.
#
# The reconstruction runs from a FULL SIBLING MIRROR, never a bare copy in a temp
# dir: escalate-review.sh resolves session-state.sh, pr-state.sh,
# greptile-budget.sh, state-lock.sh and lib/ from its own directory and exits 2
# without them, which would read as a passing control that never reached a
# verdict.
BASE_DIR="$TMP/base-scripts"
mkdir -p "$BASE_DIR"
cp -R "$STUB_DIR/." "$BASE_DIR/"

BEGIN_COUNT="$(grep -c '^# --- BEGIN evaluator-outage cap' "$ESCALATE_SRC")"
END_COUNT="$(grep -c '^# --- END evaluator-outage cap' "$ESCALATE_SRC")"
check_eq "control: exactly one BEGIN marker in the shipped script" "1" "$BEGIN_COUNT"
check_eq "control: exactly one END marker in the shipped script" "1" "$END_COUNT"

awk '
  /^# --- BEGIN evaluator-outage cap/ { skip = 1 }
  !skip { print }
  /^# --- END evaluator-outage cap/   { skip = 0 }
' "$ESCALATE_SRC" > "$BASE_DIR/escalate-review.sh"
chmod +x "$BASE_DIR/escalate-review.sh"
# The evaluator outage is the same one scenario (a) ran under.
rm -f "$BASE_DIR/review-substance.sh"

# The strip must have REMOVED the feature — a no-op awk would leave the control
# asserting the post-change script and passing for the wrong reason.
SRC_LINES="$(wc -l < "$ESCALATE_SRC")"
BASE_LINES="$(wc -l < "$BASE_DIR/escalate-review.sh")"
if [[ "$BASE_LINES" -lt "$SRC_LINES" ]]; then
  check_eq "control: the strip removed lines ($SRC_LINES -> $BASE_LINES)" "shorter" "shorter"
else
  check_eq "control: the strip removed lines ($SRC_LINES -> $BASE_LINES)" "shorter" "unchanged"
fi
check_eq "control: no cap constant survives the strip" "0" \
  "$(grep -c 'EVALUATOR_OUTAGE_CAP_SECONDS' "$BASE_DIR/escalate-review.sh")"
check_eq "control: no DEGRADED line survives the strip" "0" \
  "$(grep -c 'DEGRADED:' "$BASE_DIR/escalate-review.sh")"
# Every surviving mention of the flag is an ASSIGNMENT — so the stripped file
# cannot act on it, which is what makes it behaviourally pre-change.
FLAG_TOTAL="$(grep -c 'EVALUATOR_UNUSABLE' "$BASE_DIR/escalate-review.sh")"
FLAG_ASSIGNMENTS="$(grep -cE '^[[:space:]]*EVALUATOR_UNUSABLE=(true|false)$' "$BASE_DIR/escalate-review.sh")"
check_eq "control: the flag survives (declaration + both outage sites)" "3" "$FLAG_TOTAL"
check_eq "control: and every surviving mention is an assignment, never a read" \
  "$FLAG_TOTAL" "$FLAG_ASSIGNMENTS"
# A stripped file that cannot parse would exit 2 and never reach a verdict.
if bash -n "$BASE_DIR/escalate-review.sh" 2>/dev/null; then
  check_eq "control: the reconstructed script parses" "ok" "ok"
else
  check_eq "control: the reconstructed script parses" "ok" "syntax error"
fi

break_evaluator_missing   # keep $STUB_DIR consistent with the fixture below
outage_fixture "$INSIDE_CAP_AGE"
BASE_OUT=$( cd "$REPO_ROOT" && bash "$BASE_DIR/escalate-review.sh" "$PR_NUM" 2>"$TMP/base-stderr.txt" ); BASE_RC=$?
check_eq "control: exit 0" 0 "$BASE_RC"
check_eq "control: pre-change script emits trigger_greptile (the #1465 bug)" \
  "STATUS=trigger_greptile" "$BASE_OUT"
# It got there through the SAME outage, not through some other failure the
# reconstruction introduced.
check_stderr_has "control: same outage drove it" "$TMP/base-stderr.txt" \
  "review-substance.sh not found or not executable"

restore_evaluator

finish_escalate_review_tests "evaluator outage"
