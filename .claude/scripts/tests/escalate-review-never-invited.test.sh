#!/usr/bin/env bash
# Offline never-invited and cache-state tests for escalate-review.sh.
# catalog: tests — Invitation, grace-window, and cache-state tests for `escalate-review.sh`
# Shared fixtures live in tests/lib/escalate-review-fixtures.sh.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/escalate-review-fixtures.sh
source "$TEST_DIR/lib/escalate-review-fixtures.sh"

############################################################################
# "BugBot never invited" vs "BugBot failed" (issue #935)
#
# Every scenario above hands the script a `Cursor Bugbot` check-run, so the
# never-invited state — no check-run AND no cursor[bot] comment, the signature
# an unprovisioned CURSOR_REVIEW_PAT produces (issue #905) — was never
# exercised, and the script escalated straight to a PAID Greptile review on a
# tier nobody had asked. Seen live on PRs #929 and #932; both Phase B agents
# declined the verdict, posted `@cursor review` by hand, and BugBot answered in
# seconds.
#
# n1/n2/n3 are Scenarios A/B/C of the implementation plan. n4 and n5 are the
# negative controls that keep the two new terms from being deletable in silence:
# without n4 the freshness filter is dead weight, without n5 the new branch
# could preempt the grace window and nothing would notice.
############################################################################
echo
echo "== Scenario (n1): never invited — no check-run, no cursor[bot] comment, past the grace window -> switch_bugbot (issue #935) =="
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== Scenario (n2): genuine BugBot failure in the SAME no-check-run shape -> trigger_greptile (parity with pre-#935) =="
# Differs from (n1) by exactly one thing: a cursor[bot] usage-limit comment. A
# classified failure means BugBot WAS asked and could not run, so escalation is
# still correct — the fix must not swallow it. Scenario (a) covers this with a
# check-run present; this pins it in the shape (n1) now diverts.
reset_state
write_commits "$(ts_seconds_ago 7200)"
FAILURE_COMMENT_N2="$(failure_comment "$(ts_seconds_ago 3000)")"
write_state "[]" "[]" "[]" "[$FAILURE_COMMENT_N2]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (n3): invited but silent — fresh @cursor review, no BugBot response, past the grace window -> trigger_greptile =="
# Loop avoidance (the issue #552 hazard in reverse): once the invite exists on
# this HEAD and BugBot still says nothing, re-emitting switch_bugbot would just
# post another invite forever. Escalation is the right answer here.
reset_state
write_commits "$(ts_seconds_ago 7200)"
TRIGGER_COMMENT_N3="$(trigger_comment "$(ts_seconds_ago 3000)")"
write_state "[]" "[]" "[]" "[$TRIGGER_COMMENT_N3]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (n4): trigger comment PREDATES the HEAD commit -> switch_bugbot (a stale invite must not mask an unprovisioned one) =="
# Same fixture as (n3) with the timestamps swapped: the invite is older than the
# push, so it belongs to an earlier SHA. Without the freshness filter this reads
# as "already invited" and every subsequent push escalates to paid Greptile.
reset_state
write_commits "$(ts_seconds_ago 7200)"
TRIGGER_COMMENT_N4="$(trigger_comment "$(ts_seconds_ago 9000)")"
write_state "[]" "[]" "[]" "[$TRIGGER_COMMENT_N4]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== Scenario (n5): never invited but still INSIDE the 600s grace window -> polling_cr (the new branch must not preempt the wait) =="
# (n1) with a recent push and the cache key explicitly absent. BugBot may simply
# not have reported yet, so the grace window still owns this cycle;
# switch_bugbot here would cut it short.
reset_state
seed_bugbot_absent
write_commits "$(ts_seconds_ago 120)"
write_state "[]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"

############################################################################
echo "== Scenario (n5b): cached false inside the grace window -> switch_bugbot (issue #955) =="
# Differs from (n5) only by a cached false. That value means an earlier cycle
# already verified BugBot as not installed, so waiting through the same grace
# window again is wasted time. jq's `//` used to collapse false into absent and
# made this return polling_cr exactly like (n5).
reset_state
seed_bugbot_installed false
write_commits "$(ts_seconds_ago 120)"
write_state "[]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
# Stale `bugbot_installed` cache vs. the never-invited branch (issue #948)
#
# PR #945 shipped (n1)-(n5) with the branch gated on BUGBOT_INSTALLED, which is
# read from a per-PR cache that is written once and never reset. n6-n8 pin the
# swap to BUGBOT_CHECK_PRESENT — the same question asked of THIS commit's
# check-run bundle instead of the PR's history.
#
# Against the pre-fix script only n6 fails (trigger_greptile), which is the whole
# behavioural delta: the two terms can only disagree when the cache reads true
# while this commit has no BugBot footprint. n7 and n8 pass before and after, and
# are here so the term cannot be DELETED rather than swapped — a bare deletion
# flips both to switch_bugbot and re-invites a BugBot already running on HEAD.
############################################################################
echo
echo "== Scenario (n6): bugbot_installed cached true from an EARLIER SHA, zero footprint on HEAD, past the grace window -> switch_bugbot (issue #948) =="
# (n1) with the cache pre-seeded, i.e. BugBot answered earlier in this PR's life
# and then a later push went uninvited (issue #905). The cache made the branch
# read "already invited here" forever, so this fell through to a PAID Greptile
# review instead of the free `@cursor review` that resolves it in seconds.
reset_state
seed_bugbot_installed true
write_commits "$(ts_seconds_ago 7200)"
write_state "[]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"
CACHED_AFTER_N6="$(read_bugbot_installed)"
check_eq "cached true bypasses fresh classification" "true" "$CACHED_AFTER_N6"

############################################################################
echo "== Scenario (n7): cache true AND an in-flight Cursor Bugbot run on HEAD -> trigger_greptile (a live footprint still shuts the branch) =="
# The negative control for (n6): dropping the term outright — rather than
# swapping the cached proxy for the live one — would emit switch_bugbot here and
# re-invite a BugBot that is already running on this very commit. Escalation is
# unchanged from pre-fix behaviour.
reset_state
seed_bugbot_installed true
write_commits "$(ts_seconds_ago 7200)"
write_state "[$BUGBOT_CHECK_RUN_IN_PROGRESS]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (n8): same in-flight run on HEAD, cached false -> trigger_greptile (the live footprint still shuts the branch) =="
# (n7)'s mirror over the other cache state. Cached false now round-trips as a
# real value, while the live-footprint guard independently keeps an in-flight
# Cursor run from being re-invited.
reset_state
seed_bugbot_installed false
write_commits "$(ts_seconds_ago 7200)"
write_state "[$BUGBOT_CHECK_RUN_IN_PROGRESS]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (n8b): fresh in-flight run on HEAD overrides cached false for the grace wait =="
# A cached false may describe an earlier HEAD. A live Cursor check on this HEAD
# is stronger evidence that BugBot is available, so the sub-600s grace window
# must wait for that run instead of escalating to paid Greptile.
reset_state
seed_bugbot_installed false
write_commits "$(ts_seconds_ago 120)"
write_state "[$BUGBOT_CHECK_RUN_IN_PROGRESS]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"

finish_escalate_review_tests "never-invited and cache-state"
