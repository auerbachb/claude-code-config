#!/usr/bin/env bash
# Offline BugBot failure and response classification tests for escalate-review.sh.
# catalog: tests — BugBot failure and response-classification tests for `escalate-review.sh`
# Shared fixtures live in tests/lib/escalate-review-fixtures.sh.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/escalate-review-fixtures.sh
source "$TEST_DIR/lib/escalate-review-fixtures.sh"

############################################################################
echo "== Scenario (a): usage-limit failure comment + completed check-run -> trigger_greptile =="
reset_state
write_commits "$(ts_seconds_ago 120)"   # recent push (AGE_SECONDS < 600) — proves grace-window skip
FAILURE_COMMENT="$(failure_comment "$(ts_seconds_ago 60)")"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[]" "[]" "[$FAILURE_COMMENT]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (a2): usage-limit failure via check-run title only (no comment) -> trigger_greptile =="
reset_state
write_commits "$(ts_seconds_ago 120)"
write_state "[$BUGBOT_CHECK_RUN_FAILED_TITLE]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (b): genuine BugBot findings comment -> switch_bugbot =="
reset_state
write_commits "$(ts_seconds_ago 7200)"
GENUINE_COMMENT="$(genuine_comment "$(ts_seconds_ago 7000)")"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[]" "[]" "[$GENUINE_COMMENT]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== Scenario (c): genuine clean pass via completed check-run, no comment -> switch_bugbot =="
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== Scenario (d): failure comment followed by a LATER genuine review (by timestamp) -> switch_bugbot =="
reset_state
write_commits "$(ts_seconds_ago 7200)"
FAILURE_COMMENT_D="$(failure_comment "$(ts_seconds_ago 7000)")"
GENUINE_COMMENT_D="$(genuine_comment "$(ts_seconds_ago 3000)")"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[]" "[]" "[$FAILURE_COMMENT_D, $GENUINE_COMMENT_D]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== Scenario (e): alt failure phrasing (\"usage or spend limit\") also detected -> trigger_greptile =="
reset_state
write_commits "$(ts_seconds_ago 120)"
FAILURE_COMMENT_ALT="$(failure_comment_alt "$(ts_seconds_ago 60)")"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[]" "[]" "[$FAILURE_COMMENT_ALT]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (f): genuine review followed by a LATER failure comment -> trigger_greptile (CodeRabbit finding) =="
reset_state
write_commits "$(ts_seconds_ago 120)"
GENUINE_COMMENT_F="$(genuine_comment "$(ts_seconds_ago 7000)")"
FAILURE_COMMENT_F="$(failure_comment "$(ts_seconds_ago 60)")"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[]" "[]" "[$GENUINE_COMMENT_F, $FAILURE_COMMENT_F]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (g): check-run has a blocking conclusion (timed_out) with a non-matching title, no comment -> trigger_greptile (CodeAnt finding) =="
reset_state
write_commits "$(ts_seconds_ago 120)"
write_state "[$BUGBOT_CHECK_RUN_TIMED_OUT]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo
echo "== Scenario (m): silent-pass shape — conclusion:success check-run, no comments -> switch_bugbot (issue #844) =="
# BUGBOT_GENUINE is true for a completed/non-failure check-run with no failure comment,
# regardless of conclusion:success vs neutral. escalate-review.sh must still emit
# switch_bugbot so the caller persists sticky ownership; merge-gate.sh's new check-run
# path (issue #844 primary fix) then accepts the success shape as gate-satisfied.
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[$BUGBOT_CHECK_RUN_SUCCESS]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

finish_escalate_review_tests "BugBot classification"
