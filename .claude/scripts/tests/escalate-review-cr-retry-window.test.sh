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

############################################################################
# Issue #1364 — CodeRabbit reworded the retry-window line. Everything above this
# point passed throughout the outage: every scenario used `cr_limit_banner`, the
# ONE phrasing the parser was written against, so the suite could not tell "reads
# the window" apart from "reads THIS SENTENCE". These scenarios re-run the same
# assertions against the wording CodeRabbit actually ships.
############################################################################
echo "== (p1): CURRENT wording, window still open -> polling_cr =="
# The regression proper. On main this returns trigger_greptile: `included`
# between "Next" and "review" zeroes the window, and a zero window grants no
# grace — which is how live PRs burned a sticky Greptile assignment while
# CodeRabbit's paid allowance was still coming back.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_P1="$(cr_limit_banner_included "$(ts_seconds_ago 60)" "27 minutes")"
FAIL_P1="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_P1, $BANNER_P1]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"

############################################################################
echo "== (p2): CURRENT wording, window ELAPSED -> escalates =="
# Together with (p1) this pins the extracted MAGNITUDE, not merely that some
# window was read: 27 minutes is 1620s, so a banner 1500s old is inside its
# window and one 1700s old is not. Any other magnitude — 0, or the 12 minutes
# the old fixture carries — flips (p1), and a window read as unbounded flips
# this one. The pair straddles the boundary that only 1620 produces.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_P2="$(cr_limit_banner_included "$(ts_seconds_ago 1700)" "27 minutes")"
FAIL_P2="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_P2, $BANNER_P2]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (p3): control — the SAME banner 1500s old is still INSIDE 27 minutes -> polling_cr =="
# Byte-for-byte (p2) but for the banner's age, 200s to the other side of the
# 1620s boundary. Without it, (p2) would also pass if the new wording read as no
# window at all — proving escalation by proving nothing was parsed.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_P3="$(cr_limit_banner_included "$(ts_seconds_ago 1500)" "27 minutes")"
FAIL_P3="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_P3, $BANNER_P3]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"

############################################################################
echo "== (p4): CURRENT wording, absurd window -> still CAPPED at 1h =="
# The cap is a property of the block, not of one phrasing. (e)/(e2) proved it for
# the old sentence only; a new-wording parser that skipped the cap could park a
# PR for four days.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_P4="$(cr_limit_banner_included "$(ts_seconds_ago 4000)" "99 hours")"
FAIL_P4="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_P4, $BANNER_P4]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (p5): CURRENT wording with NO window -> no grace =="
# The fail-toward-escalation direction survives the rewording: tolerating a new
# sentence must not make an unreadable one grant anything.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_P5="$(cr_limit_banner_included "$(ts_seconds_ago 60)" "")"
FAIL_P5="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_P5, $BANNER_P5]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (p6): MARKER-ONLY banner (no heading prose) -> polling_cr =="
# The wording-independent half. Heading prose is what drifted twice; the auto-
# generated `rate limited by coderabbit.ai` marker is stamped on every one of
# these comments by construction. If CodeRabbit rewrites the heading away
# entirely, this shape is the only thing left to key on.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_P6="$(cr_limit_banner_marker_only "$(ts_seconds_ago 60)" "27 minutes")"
FAIL_P6="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_P6, $BANNER_P6]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"

############################################################################
echo "== (p7): CodeRabbit comment with NEITHER signal -> no grace (no over-match) =="
# The other direction of the widening. This body carries no heading and no
# marker, but it does say "12 minutes" and it does mention coderabbit.ai — so a
# banner test loosened into a bare `coderabbit\\.ai` or a bare number scan would
# hand an ordinary review comment a grace period. Detection must stay two
# specific signals, not "looks CodeRabbit-ish".
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
NONBANNER_P7="$(cr_non_banner_comment "$(ts_seconds_ago 60)")"
FAIL_P7="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_P7, $NONBANNER_P7]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (p8): CURRENT wording from a NON-CodeRabbit author -> no grace =="
# (g) proved the author gate for the old sentence. The banner select was edited
# for #1364; this re-proves the author term was not loosened along with it.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_P8="$(cr_limit_banner_included "$(ts_seconds_ago 60)" "27 minutes" | jq -c '.user.login = "test-user"')"
FAIL_P8="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_P8, $BANNER_P8]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (p9): CURRENT wording is still subject to the stale-banner guard =="
# A leftover new-wording banner from an earlier SHA must not buy the current push
# a wait — (c)'s guard, re-proved on the phrasing the parser now accepts.
#
# The banner is 300s old with a 1620s window, so it is WELL INSIDE its own window
# and the stale guard is the only thing that can deny grace here. That is
# deliberate: a fixture whose window has already elapsed would return
# trigger_greptile with the guard deleted, and prove nothing. (p9b) is the
# control.
reset_state
write_commits "$(ts_seconds_ago 60)"
BANNER_P9="$(cr_limit_banner_included "$(ts_seconds_ago 300)" "27 minutes")"
FAIL_P9="$(failure_comment "$(ts_seconds_ago 30)")"
write_state "[]" "[]" "[]" "[$BANNER_P9, $FAIL_P9]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (p9b): control — the SAME banner grants grace once the push predates it =="
# Identical to (p9) but for the commit date, which moves the banner from
# "predates this push" to "describes it". Only the stale guard separates the two
# verdicts, so (p9) cannot pass by accident.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_P9B="$(cr_limit_banner_included "$(ts_seconds_ago 300)" "27 minutes")"
FAIL_P9B="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$BANNER_P9B, $FAIL_P9B]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"

############################################################################
echo "== (p10): MIXED wordings — newest still wins regardless of phrasing =="
# The newest-first ordering (h/h2) must not become phrasing-sensitive. Here the
# newest banner is the OLD wording with an ELAPSED window (400s old, 300s window)
# and the older one is the CURRENT wording with a window GENUINELY STILL OPEN
# (600s old, 1620s window, comfortably under the 3600s cap). Selecting by recency
# must escalate; a parser that preferred the dialect it could read best, or that
# took any-banner-still-inside-its-window, would revive the stale wait and return
# polling_cr. Both ages are chosen to sit inside the cap — an older banner whose
# capped window had also elapsed would make this scenario unfalsifiable.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_P10_OLD="$(cr_limit_banner_included "$(ts_seconds_ago 600)" "27 minutes")"
BANNER_P10_NEW="$(cr_limit_banner "$(ts_seconds_ago 400)" "5 minutes")"
FAIL_P10="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_P10, $BANNER_P10_OLD, $BANNER_P10_NEW]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (p11): per-word emphasis leaves double spaces -> window still read =="
# The parser strips markdown emphasis before matching, so IT creates the spacing
# variation it then has to survive: `**review**  **available in**` becomes
# `review  available in`. A literal single space between the anchor words would
# read no window from a banner CodeRabbit had merely emphasised differently —
# the same silent-zero failure as #1364, from a different direction. Window is
# 27 minutes at 60s old, so grace requires the magnitude to survive too.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_P11="$(printf '{"user": {"login": "coderabbitai[bot]"}, "created_at": "%s", "body": "> ## Review limit reached\\n> **Next** **review**  **available in** **27 minutes**"}' "$(ts_seconds_ago 60)")"
FAIL_P11="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_P11, $BANNER_P11]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"

############################################################################
echo "== (p12): marker PHRASE in CodeRabbit prose (not the marker) -> no grace =="
# The precision bound on the marker alternative (CodeRabbit CLI review of this
# PR). This body is authored by coderabbitai[bot], says "rate limited by
# coderabbit.ai", and carries a parseable window sentence — everything a bare
# phrase match needs. It is still not a banner: the words are prose, not the
# `<!-- ... -->` machine comment. The author gate cannot tell these apart, so the
# HTML-comment anchor is the only thing standing between CodeRabbit's own
# walkthroughs and a grace period they never earned.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
PROSE_P12="$(cr_marker_phrase_in_prose "$(ts_seconds_ago 60)")"
FAIL_P12="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_P12, $PROSE_P12]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
# CodeAnt review of PR #1393 — the FUTURE-TENSE window sentence. Everything above
# varies the words BEFORE "review"; CodeRabbit also varies the ones after it
# (`Your next review will be available in 22 minutes.`, PR #554), and the
# classifier had been tolerating exactly that since #557 while this parser could
# not reach it. Same assertions, third dialect.
############################################################################
echo "== (q1): FUTURE-TENSE wording, window still open -> polling_cr =="
# 27 minutes is 1620s and this banner is 1500s old, so it is inside its window by
# 120s. Before the fix `will be` sits between the anchors, no window is read, and
# a zero window escalates — the #1364 failure arriving through the other slot.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_Q1="$(cr_limit_banner_will_be "$(ts_seconds_ago 1500)" "27 minutes")"
FAIL_Q1="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_Q1, $BANNER_Q1]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"

############################################################################
echo "== (q2): FUTURE-TENSE wording, window ELAPSED -> escalates =="
# Paired with (q1) across the 1620s boundary, 200s to the other side. The pair
# pins the extracted MAGNITUDE rather than mere match/no-match: 0 flips (q1), and
# an unbounded read flips this one. Only 1620 satisfies both.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_Q2="$(cr_limit_banner_will_be "$(ts_seconds_ago 1700)" "27 minutes")"
FAIL_Q2="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_Q2, $BANNER_Q2]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (q3): BOTH slots at once — inserted word AND future tense -> polling_cr =="
# The slots are independent, so the combination is its own case: a future drift
# reading `Next included review will be available in 27 minutes.` must not need a
# third patch. Same 1500s-inside-1620s geometry as (q1).
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_Q3="$(printf '{"user": {"login": "coderabbitai[bot]"}, "created_at": "%s", "body": "> [!WARNING]\\n> ## Review limit reached\\n>\\n> **Next included review will be available in 27 minutes.**"}' "$(ts_seconds_ago 1500)")"
FAIL_Q3="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_Q3, $BANNER_Q3]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=polling_cr" "STATUS=polling_cr" "$OUT"

############################################################################
echo "== (q4): UNRECOGNISED copula -> no grace (the widening stays bounded) =="
# The other direction. `is now` is not the literal `will be`, so no window is read
# and the PR escalates on the normal schedule. This is the deliberate failure
# direction for an unlogged drift — degraded to escalation, never a stalled PR —
# and it is what stops the copula slot being widened into a free bridge that
# `available in <number>` prose could satisfy. The two-word copula is what makes
# this discriminating: a generic `(?:\s+\w+){0,2}` slot would match it and grant
# grace, so widening either file's pattern fails HERE. (q1) is the control: same
# banner, same age, same window, recognised wording -> polling_cr.
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
BANNER_Q4="$(cr_limit_banner_unknown_copula "$(ts_seconds_ago 1500)" "27 minutes")"
FAIL_Q4="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_Q4, $BANNER_Q4]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== (q5): ADAPTIVE-LIMITS notice is still not a banner -> no grace =="
# The #554 body verbatim: the wording the parser now reads, on the family the
# grace deliberately excludes. CR wraps it in `Full review finished.`, so it
# reports a review that ALREADY LANDED and times the next one — there is nothing
# to wait out on this HEAD. Widening the window regex must not smuggle this
# family in through the select, which is keyed on heading prose or the marker and
# was left untouched. (cr-rate-limits.md: the two families are not
# interchangeable.)
reset_state
write_commits "$(ts_seconds_ago "$OLD_PUSH")"
ADAPTIVE_Q5="$(printf '{"user": {"login": "coderabbitai[bot]"}, "created_at": "%s", "body": "<!-- This is an auto-generated reply by CodeRabbit -->\\n\\nFull review finished.\\n\\n---\\n\\nYou are currently rate limited under our Fair Usage Limits Policy. Your next review will be available in 27 minutes."}' "$(ts_seconds_ago 1500)")"
FAIL_Q5="$(failure_comment "$(ts_seconds_ago 7000)")"
write_state "[]" "[]" "[]" "[$FAIL_Q5, $ADAPTIVE_Q5]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

finish_escalate_review_tests "CodeRabbit retry-window"
