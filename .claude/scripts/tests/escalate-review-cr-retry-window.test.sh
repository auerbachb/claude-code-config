#!/usr/bin/env bash
# Offline tests for the CodeRabbit retry-window grace in escalate-review.sh
# (issue #1199). Shared fixtures live in tests/lib/escalate-review-fixtures.sh.
#
# WHAT IS UNDER TEST
#   CodeRabbit's `Review limit reached` banner names its own retry window
#   ("**Next review available in:** **12 minutes**"). That is a bounded,
#   self-healing wait, not a tier failure — escalating past it spends a lower
#   tier while the allowance we already paid for is still coming back. The 2026-08
#   audit measured that banner as CodeRabbit's ONLY output on 183 of 244 PRs.
#
# WHY EVERY SCENARIO USES AN OLD PUSH PLUS A FAILED BUGBOT
#   Both are required for these tests to prove anything. A recent push
#   (AGE_SECONDS < 600) makes the BugBot grace window emit `polling_cr` on its
#   own, and a BugBot that has not failed does the same — either would let a
#   scenario "pass" while the grace block under test never ran. Old push + a
#   usage-limit failure comment is the one setup whose baseline verdict is
#   `trigger_greptile`, so any `polling_cr` here is attributable to this block
#   and nothing else. The negative cases assert that baseline is still reached.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/escalate-review-fixtures.sh
source "$TEST_DIR/lib/escalate-review-fixtures.sh"

OLD_PUSH=7200   # well past the 600s BugBot grace and the 720s CR timeout

############################################################################
echo "== (a): fresh banner, window still open -> polling_cr (does not escalate) =="
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_A="$(cr_limit_banner "$(ts_seconds_ago 60)" "12 minutes")"
FAIL_A="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_A, $BANNER_A]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"

############################################################################
echo "== (b): window has ELAPSED -> escalates as before =="
# 2000s old banner against a 720s window. Same fixture as (a) but for the
# banner's age, so the verdict flip is attributable to elapsed time alone.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_B="$(cr_limit_banner "$(ts_seconds_ago 2000)" "12 minutes")"
FAIL_B="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_B, $BANNER_B]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (c): banner PREDATES the HEAD commit -> no grace (stale banner) =="
# A leftover banner from an earlier SHA must not buy the current push a wait.
# Push is recent here, so BugBot's usage-limit failure is what keeps the grace
# window from short-circuiting the run.
reset_state
write_commits "$(ts_seconds_ago 60)"
BANNER_C="$(cr_limit_banner "$(ts_seconds_ago 7000)" "12 minutes")"
FAIL_C="$(failure_comment "$(ts_seconds_ago 30)")"
write_state "[]" "[]" "[]" "[$BANNER_C, $FAIL_C]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (d): banner with NO readable window -> no grace (fails toward escalation) =="
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_D="$(cr_limit_banner "$(ts_seconds_ago 60)" "")"
FAIL_D="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_D, $BANNER_D]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (e): absurd window is CAPPED at 1h -> a 4000s-old banner escalates =="
# Uncapped, "99 hours" would hold this PR for over four days. The banner is
# older than the 3600s cap but far younger than the window it claims, so only
# the cap can produce the escalation.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_E="$(cr_limit_banner "$(ts_seconds_ago 4000)" "99 hours")"
FAIL_E="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_E, $BANNER_E]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (e2): control — the SAME absurd window still grants grace under the cap =="
# Byte-for-byte (e) but for the banner's age (60s, inside the 3600s cap). Without
# this control, (e) would also pass if the parser simply failed to read "99
# hours" at all, which would prove the cap works by proving nothing was capped.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_E2="$(cr_limit_banner "$(ts_seconds_ago 60)" "99 hours")"
FAIL_E2="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_E2, $BANNER_E2]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"

############################################################################
echo "== (f): CR has ALREADY reviewed this HEAD -> nothing to wait for =="
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_F="$(cr_limit_banner "$(ts_seconds_ago 60)" "12 minutes")"
FAIL_F="$(failure_comment "$(ts_seconds_ago 7000)")"
REVIEW_F="$(cr_review_on_head "$(ts_seconds_ago 6000)")"
write_state "[]" "[$REVIEW_F]" "[]" "[$FAIL_F, $BANNER_F]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (g): banner text from a NON-CodeRabbit author -> no grace =="
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_G="$(cr_limit_banner_foreign_author "$(ts_seconds_ago 60)" "12 minutes")"
FAIL_G="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_G, $BANNER_G]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (h): NEWEST banner wins — an old open window cannot revive a closed one =="
# Two banners: an old one whose window is long (2h, still notionally open at its
# own age) and a newer one whose short window has already elapsed. Selecting by
# recency must yield escalation; selecting "any banner still inside its window"
# would wrongly hold the PR.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_H_OLD="$(cr_limit_banner "$(ts_seconds_ago 5000)" "2 hours")"
BANNER_H_NEW="$(cr_limit_banner "$(ts_seconds_ago 900)" "5 minutes")"
FAIL_H="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_H, $BANNER_H_OLD, $BANNER_H_NEW]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (i): no banner at all -> pre-#1199 behaviour is untouched =="
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
FAIL_I="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_I]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (j): a genuinely-responding BugBot still wins over an open window =="
# Placement guard. The grace sits BELOW BugBot classification precisely so it can
# only displace a Greptile spend. If it were moved back up beside the other
# CodeRabbit logic, this PR would sit in polling_cr for a full retry window while
# a finished BugBot review was already on the table.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_J="$(cr_limit_banner "$(ts_seconds_ago 60)" "12 minutes")"
GENUINE_J="$(genuine_comment "$(ts_seconds_ago 7000)")"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[]" "[]" "[$GENUINE_J, $BANNER_J]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== (k): a NEVER-INVITED BugBot still wins over an open window =="
# Same guard for the free `@cursor review` route (issue #935): no BugBot
# footprint and no trigger on this HEAD must route to switch_bugbot, not park
# the PR on a CodeRabbit wait.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_K="$(cr_limit_banner "$(ts_seconds_ago 60)" "12 minutes")"
write_state "[]" "[]" "[]" "[$BANNER_K]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== (h2): NEWEST banner has no readable window -> no grace, even if an older one does =="
# The gap in (h): every banner there carried a window, so the suite could not tell
# "newest wins" apart from "newest READABLE wins". If CodeRabbit changes its
# wording, the newest banner becomes unparseable — and selecting by readability
# first would hand the PR a grace period computed from a stale window it had
# already served. Newest-first means an unreadable newest banner grants nothing.
# (CodeRabbit review, PR #1203.)
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_H2_OLD="$(cr_limit_banner "$(ts_seconds_ago 3000)" "2 hours")"   # readable, still open at its own age
BANNER_H2_NEW="$(cr_limit_banner "$(ts_seconds_ago 60)" "")"            # newest, no window
FAIL_H2="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_H2, $BANNER_H2_OLD, $BANNER_H2_NEW]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (h3): control — that same older banner DOES grant grace when it is newest =="
# Without this, (h2) would also pass if the older banner's window were simply
# never readable, proving nothing about ordering.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_H3="$(cr_limit_banner "$(ts_seconds_ago 3000)" "2 hours")"
FAIL_H3="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_H3, $BANNER_H3]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"

finish_escalate_review_tests "CodeRabbit retry-window"
