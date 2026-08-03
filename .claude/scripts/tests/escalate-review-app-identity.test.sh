#!/usr/bin/env bash
# Offline publishing-app identity tests for escalate-review.sh.
# Shared fixtures live in tests/lib/escalate-review-fixtures.sh.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/escalate-review-fixtures.sh
source "$TEST_DIR/lib/escalate-review-fixtures.sh"

############################################################################
# Same check NAME, different publishing app (issue #956)
#
# `Cursor Bugbot` used to be matched on the name alone, in both places this
# script reads check-runs: the $run content classifier and BUGBOT_CHECK_PRESENT.
# Any GitHub App may publish a check-run under any name, so a same-named run from
# a foreign app read as BugBot's footprint on this commit — which shuts the
# never-invited branch and spends a PAID Greptile review instead of the FREE
# `@cursor review` that arm posts.
#
# o1/o4/o7 are the three behavioural deltas, one per term the old name-only match
# fed (footprint / genuine / failed). Against the pre-fix script all three return
# the opposite verdict. o2/o5 are the parity controls: the SAME fixtures
# published by the real Cursor app must keep their pre-fix verdicts, so the scope
# cannot be satisfied by refusing every check-run. o3/o6 pin the missing-slug
# fallback on both paths.
############################################################################
echo
echo "== Scenario (o1): foreign app publishes a same-named in-flight run, zero real footprint -> switch_bugbot (issue #956) =="
# (n1) with a spoofed footprint bolted on. Pre-fix this is trigger_greptile: the
# foreign run satisfies BUGBOT_CHECK_PRESENT and the never-invited branch shuts.
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[$BUGBOT_RUN_FOREIGN_IN_PROGRESS]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== Scenario (o2): identical fixture published by the REAL Cursor app -> trigger_greptile (parity control for o1) =="
# Differs from (o1) by the app slug and nothing else. This is (n7) without the
# cache seed: a live Cursor run on HEAD is a genuine footprint, so the
# never-invited branch must stay shut and escalation is unchanged from pre-fix.
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[$BUGBOT_CHECK_RUN_IN_PROGRESS]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (o3): same-named in-flight run with NO app identity -> switch_bugbot (missing-slug fallback) =="
# A bundle written before pr-state.sh carried `app`. Unverifiable identity fails
# toward "not a footprint", so the cost is one duplicate `@cursor review`
# (harmless per bugbot.md) rather than a paid Greptile review on an unverified run.
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[$BUGBOT_RUN_NO_APP_IN_PROGRESS]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== Scenario (o4): foreign app's completed run must not read as a genuine BugBot pass -> trigger_greptile =="
# The $run classifier path, isolated from the footprint path by a fresh
# `@cursor review` invite: BugBot WAS asked on this HEAD and never answered, so
# the never-invited branch is closed either way and only BUGBOT_GENUINE decides.
# Pre-fix the foreign completed/neutral run makes BUGBOT_GENUINE true and this
# returns switch_bugbot — i.e. a foreign app got to certify BugBot as responsive.
reset_state
write_commits "$(ts_seconds_ago 7200)"
TRIGGER_COMMENT_O4="$(trigger_comment "$(ts_seconds_ago 3000)")"
write_state "[$BUGBOT_RUN_FOREIGN_OK]" "[]" "[]" "[$TRIGGER_COMMENT_O4]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (o5): identical fixture published by the REAL Cursor app -> switch_bugbot (parity control for o4) =="
# Cursor's own completed/neutral run on HEAD is still a genuine response, invite
# or no invite. Without this control the o4 assertion could be satisfied by the
# classifier having stopped recognising check-runs at all.
reset_state
write_commits "$(ts_seconds_ago 7200)"
TRIGGER_COMMENT_O5="$(trigger_comment "$(ts_seconds_ago 3000)")"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[]" "[]" "[$TRIGGER_COMMENT_O5]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo "== Scenario (o6): completed run with NO app identity, invited on HEAD -> trigger_greptile (missing-slug fallback, classifier path) =="
# (o4)'s fallback twin. The invite postdates the push and nothing verifiable
# answered it, which is exactly (n3)'s invited-but-silent state — escalation,
# not another invite, is the non-looping answer here.
reset_state
write_commits "$(ts_seconds_ago 7200)"
TRIGGER_COMMENT_O6="$(trigger_comment "$(ts_seconds_ago 3000)")"
write_state "[$BUGBOT_RUN_NO_APP_OK]" "[]" "[]" "[$TRIGGER_COMMENT_O6]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (o7): foreign app cannot forge a BugBot FAILURE either -> switch_bugbot =="
# The third term the name-only match fed. Pre-fix the foreign run's usage-limit
# title sets BUGBOT_FAILED, which both skips the grace window and shuts the
# never-invited branch, so a stranger's check title alone sent the PR to paid
# Greptile. (a2) pins the same title as a real failure when Cursor publishes it.
reset_state
write_commits "$(ts_seconds_ago 7200)"
write_state "[$BUGBOT_RUN_FOREIGN_FAILED_TITLE]" "[]" "[]" "[]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

############################################################################
echo
echo "== Scenario (o8): the app scope is not removable one selector at a time (issue #956) =="
# Structural guard. The behavioural scenarios above cover both selectors today,
# but they check verdicts, not that BOTH matches stayed scoped — a future edit
# could re-widen one of them in a shape no current fixture distinguishes. The
# predicate is a single-line jq def in each of the two programs, so every
# occurrence of the quoted check name must share its line with the app.slug term.
NAME_LINES="$(grep -c '"Cursor Bugbot"' "$ESCALATE_SRC" || true)"
SCOPED_LINES="$(grep '"Cursor Bugbot"' "$ESCALATE_SRC" | grep -c 'app\.slug' || true)"
# Positive control first: without it the equality below passes vacuously if the
# selectors are deleted outright (0 == 0). Two programs read check-runs, so two.
check_eq "both Cursor Bugbot selectors present and app-scoped" "2" "$SCOPED_LINES"
check_eq "no unscoped Cursor Bugbot selector remains" "$NAME_LINES" "$SCOPED_LINES"
finish_escalate_review_tests "publishing-app identity"
