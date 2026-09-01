#!/usr/bin/env bash
# Offline tests for the HEAD-observation anchor in escalate-review.sh (issue
# #1517). Shared fixtures live in tests/lib/escalate-review-fixtures.sh.
#
# WHAT IS UNDER TEST
#   AGE_SECONDS used to be derived from the HEAD commit's committer/author date.
#   A commit date is not push attribution — the same class of mistake as the
#   commit_id re-pointing trap. A force-push can move an OLDER commit onto HEAD,
#   and every consumer of AGE_SECONDS then measures from that older date.
#
#   Two consumers encode "posted after the push" as `<other age> -le AGE_SECONDS`:
#   the CodeRabbit rate-limit banner grace, and the `@cursor review` trigger
#   freshness test. An inflated AGE_SECONDS lets a banner or a trigger left over
#   from the PRIOR head read as current, so escalation stalls (banner) or the
#   free `@cursor review` route stays shut and paid Greptile budget is spent
#   instead (trigger).
#
#   The fix anchors on max(commit date, newest `head_ref_force_pushed` event),
#   expressed as min() over ages so both values go through the file's single
#   iso_age_seconds rule rather than a second lexicographic compare.
#
# WHY EVERY SCENARIO PAIRS AN OLD COMMIT WITH A RECENT FORCE-PUSH
#   That pair is the only shape where the two clocks disagree, so any verdict
#   difference is attributable to which clock was read. Each defect scenario is
#   followed by its own NEGATIVE CONTROL — the identical fixture with the
#   force-push event removed — which must reach the pre-fix verdict. Without the
#   control, a scenario could go green because of something else in the fixture
#   and the anchor would never have been exercised.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/escalate-review-fixtures.sh
source "$TEST_DIR/lib/escalate-review-fixtures.sh"

OLD_COMMIT=7200   # well past the 600s BugBot grace and the 720s CR timeout
JUST_PUSHED=30    # the force-push that actually put this SHA on HEAD

############################################################################
echo "== (a): banner from the PRIOR head + fresh force-push -> escalates (no stale grace) =="
# The defect, end to end. The banner is 1800s old and states a 50-minute window,
# so it is inside its own window either way; the ONLY question is whether it
# postdates the push. Against the commit date (7200s) it does, and the PR sat on
# polling_cr for up to a full window on a banner raised for a different HEAD.
# Against the real head-observation time (30s) it does not.
reset_state
write_commits "$(ts_seconds_ago "$OLD_COMMIT")"
write_force_push "$(ts_seconds_ago "$JUST_PUSHED")"
BANNER_A="$(cr_limit_banner "$(ts_seconds_ago 1800)" "50 minutes")"
FAIL_A="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_A, $BANNER_A]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (b): NEGATIVE CONTROL — same fixture, no force-push -> polling_cr as before =="
# Byte-for-byte (a) minus the timeline event. It must reach the PRE-FIX verdict:
# that is what proves (a)'s flip came from the anchor and not from the banner
# age, the window, or the failure comment.
reset_state
write_commits "$(ts_seconds_ago "$OLD_COMMIT")"
BANNER_B="$(cr_limit_banner "$(ts_seconds_ago 1800)" "50 minutes")"
FAIL_B="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_B, $BANNER_B]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"

############################################################################
echo "== (c): a force-push OLDER than the commit is ignored (max, not replace) =="
# Direction guard. The anchor takes the LATER of the two, so a force-push that
# predates the HEAD commit — an earlier rebase, with an ordinary push after it —
# must leave AGE_SECONDS on the commit date. An implementation that simply
# replaced the commit date with the newest force-push would read this PR as
# 9000s old, which is still past every threshold here and so would pass (a)-(b)
# while being wrong; this is the scenario that catches it.
reset_state
write_commits "$(ts_seconds_ago "$OLD_COMMIT")"
write_force_push "$(ts_seconds_ago 9000)"
BANNER_C="$(cr_limit_banner "$(ts_seconds_ago 1800)" "50 minutes")"
FAIL_C="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_C, $BANNER_C]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"

############################################################################
echo "== (d): an unreadable force-push timestamp is IGNORED, not treated as 'just now' =="
# iso_age_seconds returns 0 for anything it cannot parse, and 0 would read as
# "HEAD is brand new" — parking the PR on the current tier on data we cannot
# read. The shape test is what makes an unreadable timeline degrade to today's
# behaviour instead. Same fixture as (b), so a green result is attributable to
# the malformed value alone.
reset_state
write_commits "$(ts_seconds_ago "$OLD_COMMIT")"
write_force_push "not-a-timestamp"
BANNER_D="$(cr_limit_banner "$(ts_seconds_ago 1800)" "50 minutes")"
FAIL_D="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_D, $BANNER_D]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"

############################################################################
echo "== (d2): a VALID-LOOKING PREFIX with trailing junk is rejected too =="
# The shape test has to be anchored at both ends, not just matched at the start.
# `…T12:00:00-GARBAGE` is well-formed for nineteen characters, is unparseable to
# iso_age_seconds, and would therefore score 0 — "HEAD is brand new" — reaching
# the exact failure the test exists to stop, through the test itself. (d) alone
# does not catch this: its value fails a prefix match as well as an anchored one.
reset_state
write_commits "$(ts_seconds_ago "$OLD_COMMIT")"
write_force_push "$(ts_seconds_ago "$JUST_PUSHED")-GARBAGE"
BANNER_D2="$(cr_limit_banner "$(ts_seconds_ago 1800)" "50 minutes")"
FAIL_D2="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_D2, $BANNER_D2]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"

############################################################################
echo "== (d3): CONTROL — the other UTC spelling is still ACCEPTED (anchored, not narrowed) =="
# Bounds (d2) in the opposite direction. GitHub ships "…Z" and "…+00:00" for the
# same instant (ts-normalizer.sh), so an anchored test keyed on `Z` alone would
# silently stop anchoring the moment the wire spelling changed — degrading to the
# commit date with nothing to say why. Same fixture as (a) but for the spelling,
# so it must reach (a)'s verdict.
reset_state
write_commits "$(ts_seconds_ago "$OLD_COMMIT")"
write_force_push "$(ts_seconds_ago_utc_offset "$JUST_PUSHED")"
BANNER_D3="$(cr_limit_banner "$(ts_seconds_ago 1800)" "50 minutes")"
FAIL_D3="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_D3, $BANNER_D3]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (e): trigger comment from the PRIOR head + fresh force-push -> switch_bugbot =="
# The SECOND consumer of AGE_SECONDS: `BUGBOT_TRIGGER_AGE -le AGE_SECONDS` asks
# whether an `@cursor review` invitation postdates the push. Against the commit
# date the 1800s-old trigger from the previous HEAD counted as covering this one,
# the never-invited branch stayed shut, and escalation spent PAID Greptile budget
# on a HEAD nobody had asked BugBot about. Against the real anchor the trigger is
# stale, the branch opens, and the FREE `@cursor review` route is taken instead.
#
# bugbot_installed is pre-seeded so the cache-miss branch (which emits polling_cr
# on a young push all by itself) cannot produce this verdict — the never-invited
# branch is then the only thing that can, which is what makes the flip
# attributable to the trigger-freshness compare.
reset_state
write_commits "$(ts_seconds_ago "$OLD_COMMIT")"
write_force_push "$(ts_seconds_ago "$JUST_PUSHED")"
seed_bugbot_installed false
TRIGGER_E="$(trigger_comment "$(ts_seconds_ago 1800)")"
write_state "[]" "[]" "[]" "[$TRIGGER_E]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== (f): NEGATIVE CONTROL — same fixture, no force-push -> trigger_greptile as before =="
reset_state
write_commits "$(ts_seconds_ago "$OLD_COMMIT")"
seed_bugbot_installed false
TRIGGER_F="$(trigger_comment "$(ts_seconds_ago 1800)")"
write_state "[]" "[]" "[]" "[$TRIGGER_F]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (g): the anchor adds no second timestamp-ordering rule =="
# ts-normalizer-parity.test.sh pins the ONE `def canon_ts:` in escalate-review.sh
# against merge-gate.sh's norm_ts, and the file's own comment warns that a
# near-copy under another name reintroduces the drift that guard exists to
# prevent. The anchor therefore compares AGES as integers rather than ordering
# two timestamp strings. Assert that here so a future "simplification" back to a
# string compare is caught by this suite as well as by the parity guard.
CANON_DEFS="$(grep -c '^[[:space:]]*def canon_ts:' "$ESCALATE_SRC" || true)"
check_eq "still exactly one canon_ts definition" "1" "$CANON_DEFS"
# ...and the anchor really is the min-over-ages form, so (g) cannot pass by the
# anchor having been deleted entirely.
if grep -q 'FORCE_PUSH_AGE" -lt "\$AGE_SECONDS' "$ESCALATE_SRC"; then
  check_eq "anchor compares ages, not timestamp strings" "present" "present"
else
  check_eq "anchor compares ages, not timestamp strings" "present" "absent"
fi

finish_escalate_review_tests "head-observation anchor"
