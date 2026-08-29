#!/usr/bin/env bash
# Offline review gate and approval freshness tests for escalate-review.sh.
# Shared fixtures live in tests/lib/escalate-review-fixtures.sh.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/escalate-review-fixtures.sh
source "$TEST_DIR/lib/escalate-review-fixtures.sh"

############################################################################
echo "== Scenario (h): CR rate-limited + BugBot usage-limit failure + CodeAnt already APPROVED on HEAD -> gate_met (NOT trigger_greptile) =="
reset_state
write_commits "$(ts_seconds_ago 120)"
FAILURE_COMMENT_H="$(failure_comment "$(ts_seconds_ago 60)")"
# The approval body is substantive on purpose (issue #875): escalate-review now
# discounts an APPROVED with no evidence anything read the commit, so a body-less
# fixture would fail for the wrong reason instead of testing the gate_met path.
CODEANT_APPROVED_H='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed the changed files; no issues found.", "submitted_at": "'"$(ts_seconds_ago 90)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H]" "[]" "[$FAILURE_COMMENT_H]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=gate_met" "STATUS=gate_met" "$OUT"

############################################################################
# Scenarios (h2)-(h4) exist because the gh stub originally returned [] for
# `git/commits/{sha}`, leaving push_ts empty in EVERY scenario above. Both
# post-push signals are `if $push == "" then null` guarded, so temporal
# inversion and capability failure were structurally unreachable from this
# suite — (h) passed and would have kept passing with either branch deleted.
echo "== Scenario (h2): CodeAnt APPROVED before its own run-start marker, nothing else -> trigger_greptile (temporal inversion) =="
reset_state
write_commits "$(ts_seconds_ago 300)"
FAILURE_COMMENT_H2="$(failure_comment "$(ts_seconds_ago 60)")"
# Empty body, no inline comments, no status comment naming HEAD — approved at
# T-200 while the bot only announced it had started at T-190. ccc#867's shape.
CODEANT_APPROVED_H2='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "", "submitted_at": "'"$(ts_seconds_ago 200)"'"}'
CODEANT_MARKER_H2='{"user": {"login": "codeant-ai[bot]"}, "created_at": "'"$(ts_seconds_ago 190)"'", "body": "CodeAnt AI is running the review on your pull request. Results will be posted shortly."}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H2]" "[]" "[$FAILURE_COMMENT_H2, $CODEANT_MARKER_H2]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (h3): same inversion, but inline comments on HEAD prove a real read -> gate_met =="
reset_state
write_commits "$(ts_seconds_ago 300)"
FAILURE_COMMENT_H3="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_APPROVED_H3='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "", "submitted_at": "'"$(ts_seconds_ago 200)"'"}'
CODEANT_MARKER_H3='{"user": {"login": "codeant-ai[bot]"}, "created_at": "'"$(ts_seconds_ago 190)"'", "body": "CodeAnt AI is running the review on your pull request. Results will be posted shortly."}'
# Evidence outside the approval object redeems it even though it lands AFTER the
# approval — the documented bodylen=0 + walkthrough shape (mia#172 396ced5).
CODEANT_INLINE_H3='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "original_commit_id": "'"$HEAD_SHA"'", "created_at": "'"$(ts_seconds_ago 180)"'", "path": "a.sh", "body": "Suggestion: this branch is unreachable."}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H3]" "[$CODEANT_INLINE_H3]" "[$FAILURE_COMMENT_H3, $CODEANT_MARKER_H3]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=gate_met" "STATUS=gate_met" "$OUT"

############################################################################
echo "== Scenario (h4): CodeAnt APPROVED after saying it could not review -> trigger_greptile (capability failure) =="
reset_state
write_commits "$(ts_seconds_ago 300)"
FAILURE_COMMENT_H4="$(failure_comment "$(ts_seconds_ago 60)")"
# The notice is long and names HEAD — before this was fixed it counted as the
# reviewer's own substantive status comment AND, by being the latest evidence,
# suppressed the capability-failure check meant to catch it.
CODEANT_NOSUB_H4='{"user": {"login": "codeant-ai[bot]"}, "created_at": "'"$(ts_seconds_ago 210)"'", "body": "User ci@example.com does not have a PR Review subscription, so commit '"$HEAD_SHA"' was not reviewed. Contact your administrator to enable reviews for this account."}'
CODEANT_APPROVED_H4='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "", "submitted_at": "'"$(ts_seconds_ago 200)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H4]" "[]" "[$FAILURE_COMMENT_H4, $CODEANT_NOSUB_H4]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (h5): substantive-but-RETRACTED CR + fresh hollow CodeAnt -> trigger_greptile (same reviewer must clear both gates) =="
reset_state
write_commits "$(ts_seconds_ago 300)"
FAILURE_COMMENT_H5="$(failure_comment "$(ts_seconds_ago 60)")"
# CodeRabbit's approval is substantive, so it lands in the evaluator's
# substantive[] — but it is retracted by a later CHANGES_REQUESTED, so it is not
# a valid approval. CodeAnt's approval IS valid but is an empty rubber stamp.
# Testing "substantive[] is non-empty" on its own reported gate_met here, while
# merge-gate.sh rejected both — stranding the PR with no reviewer and no
# escalation in flight.
CR_APPROVED_H5='{"user": {"login": "coderabbitai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed every changed file; behaviour preserved throughout.", "submitted_at": "'"$(ts_seconds_ago 250)"'"}'
CR_RETRACT_H5='{"user": {"login": "coderabbitai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "CHANGES_REQUESTED", "submitted_at": "'"$(ts_seconds_ago 200)"'"}'
CA_HOLLOW_H5='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "", "submitted_at": "'"$(ts_seconds_ago 150)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CR_APPROVED_H5, $CR_RETRACT_H5, $CA_HOLLOW_H5]" "[]" "[$FAILURE_COMMENT_H5]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (h6): approval RETARGETED onto HEAD but predating the commit -> trigger_greptile (issue #836 freshness) =="
reset_state
write_commits "$(ts_seconds_ago 300)"
FAILURE_COMMENT_H6="$(failure_comment "$(ts_seconds_ago 60)")"
# GitHub retargets commit_id onto HEAD after a force-push without touching
# submitted_at. This approval is substantive AND on HEAD, but it was submitted
# an hour before the commit existed, so merge-gate.sh rejects it — escalation
# must not short-circuit on it either.
CODEANT_STALE_H6='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed every changed file; no blocking issues found.", "submitted_at": "'"$(ts_seconds_ago 3600)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_STALE_H6]" "[]" "[$FAILURE_COMMENT_H6]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (h6b): fresh approval spelled +00:00 against a Z commit date -> gate_met (no false stale) =="
reset_state
# Commit date carries an explicit +00:00 offset while the approval uses Z. As
# raw strings "...+00:00" sorts BEFORE "...Z", so without canonicalisation the
# freshness filter would call this fresh approval stale and withhold gate_met.
PUSH_H6B="$(python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=300)).strftime('%Y-%m-%dT%H:%M:%S+00:00'))
")"
write_commits "$PUSH_H6B"
FAILURE_COMMENT_H6B="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_APPROVED_H6B='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed every changed file; no blocking issues found.", "submitted_at": "'"$(ts_seconds_ago 90)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H6B]" "[]" "[$FAILURE_COMMENT_H6B]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=gate_met" "STATUS=gate_met" "$OUT"

############################################################################
echo "== Scenario (h6e): fresh approval spelled Z against a +0000 commit date -> gate_met (all three UTC spellings normalise) =="
reset_state
# The compact "+0000" spelling of the same instant. BugBot flagged (on c90b32a)
# that this filter stripped it while norm_ts in merge-gate.sh did not, so the two
# disagreed on identical inputs; norm_ts now strips it too. Pins that the spelling
# is normalised rather than compared raw — as raw strings "...+0000" sorts BEFORE
# "...Z", which would mark this fresh approval stale and withhold gate_met.
PUSH_H6E="$(python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=300)).strftime('%Y-%m-%dT%H:%M:%S+0000'))
")"
write_commits "$PUSH_H6E"
FAILURE_COMMENT_H6E="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_APPROVED_H6E='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed every changed file; no blocking issues found.", "submitted_at": "'"$(ts_seconds_ago 90)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H6E]" "[]" "[$FAILURE_COMMENT_H6E]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=gate_met" "STATUS=gate_met" "$OUT"

############################################################################
echo "== Scenario (h6c): approval earlier in the SAME second as a fractional commit date -> trigger_greptile (must agree with merge-gate.sh) =="
reset_state
# BugBot review on 7de2a4c (PR #883): escalate-review.sh and merge-gate.sh
# implement one rule (#836), so they must order the same pair identically. The
# commit date carries fractional seconds and the approval lands earlier within
# that same second, so merge-gate.sh's norm_ts (strip zone suffix, KEEP the
# fraction) rules the approval stale and blocks. The old canon_ts here dropped
# the fraction, collapsing the two to the same instant and reporting gate_met on
# a PR the gate refuses — escalation must never be the more permissive of the two.
# Use a single Python call to get the base second so both timestamps always
# fall within the same clock second — two separate calls can straddle a second
# boundary and make the approval appear LATER than the commit (gate_met instead
# of trigger_greptile).
BASE_H6C="$(python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=300)).strftime('%Y-%m-%dT%H:%M:%S'))
")"
PUSH_H6C="${BASE_H6C}.900000Z"   # commit at 0.9 s into the base second (later)
APPROVED_H6C="${BASE_H6C}Z"       # approval at 0.0 s (start of same second — earlier)
write_commits "$PUSH_H6C"
FAILURE_COMMENT_H6C="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_APPROVED_H6C='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed every changed file; no blocking issues found.", "submitted_at": "'"$APPROVED_H6C"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H6C]" "[]" "[$FAILURE_COMMENT_H6C]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (h6d): fractional-second approval AFTER a whole-second commit date -> gate_met (fraction must not invert the order) =="
reset_state
# The mirror of (h6c), and the reason the fix strips the zone suffix instead of
# rewriting it to "Z": under a trailing "Z", "." (0x2E) sorts below "Z" (0x5A),
# so the LATER instant "…49.900Z" would compare BELOW "…49Z" and a genuinely
# fresh approval would be withheld. With the suffix stripped, plain lexicographic
# order is correct for whole and fractional seconds alike.
# Single Python call for the base second so the two timestamps always stay
# within the same clock second (mirrors the h6c fix — same racy pattern).
BASE_H6D="$(python3 -c "
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=300)).strftime('%Y-%m-%dT%H:%M:%S'))
")"
PUSH_H6D="${BASE_H6D}Z"            # commit at 0.0 s (start of base second — earlier)
APPROVED_H6D="${BASE_H6D}.900000Z"  # approval at 0.9 s into same second (later)
write_commits "$PUSH_H6D"
FAILURE_COMMENT_H6D="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_APPROVED_H6D='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed every changed file; no blocking issues found.", "submitted_at": "'"$APPROVED_H6D"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H6D]" "[]" "[$FAILURE_COMMENT_H6D]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=gate_met" "STATUS=gate_met" "$OUT"

############################################################################
# (h6f)-(h6h) pin the #876 redemption path this script gained in issue #1387.
#
# All three share (h6)'s shape — an APPROVED on HEAD whose submitted_at predates
# the HEAD commit — and differ ONLY in what the reviewer left on HEAD outside
# the review object. (h6) itself stays the control: a substantive approval BODY
# and nothing else still escalates, because a body can never redeem its own
# frozen timestamp.
#
# A shared SHA for the "reviewed a different commit" fixtures below. Full 40
# chars on purpose: a short SHA would prefix-match HEAD and agree vacuously.
OLD_SHA_H6="7c1f2b3a4d5e60718293a4b5c6d7e8f901234567"

echo "== Scenario (h6f): stale submitted_at + HEAD-anchored inline comments -> gate_met (issue #876 redemption, parity with merge-gate.sh) =="
reset_state
write_commits "$(ts_seconds_ago 300)"
FAILURE_COMMENT_H6F="$(failure_comment "$(ts_seconds_ago 60)")"
# The in-place re-review edit: CodeAnt PATCHes its EXISTING review object, so
# commit_id advances to the new HEAD while submitted_at stays frozen at the
# original submission. Body is EMPTY on purpose — the only thing that can make
# this approval count is the external evidence below, so if redemption is ever
# reverted this case fails rather than passing on a substantive body.
CODEANT_STALE_H6F='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "", "submitted_at": "'"$(ts_seconds_ago 3600)"'"}'
# Inline findings anchored to HEAD by BOTH commit_id and original_commit_id, and
# created after the push — first-party proof this reviewer read the current diff.
CODEANT_INLINE_H6F='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "original_commit_id": "'"$HEAD_SHA"'", "created_at": "'"$(ts_seconds_ago 120)"'", "path": "a.sh", "body": "Suggestion: this early return leaves the lock held on the error path."}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_STALE_H6F]" "[$CODEANT_INLINE_H6F]" "[$FAILURE_COMMENT_H6F]"
OUT=$(run_script 2>"$TMP/h6f-stderr.txt"); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=gate_met" "STATUS=gate_met" "$OUT"
# The verdict must come from REDEMPTION, not from the approval having been fresh
# all along — otherwise this case would keep passing with the fix reverted.
# Assert the grant announced itself.
if grep -q "issue #876, escalation parity #1387" "$TMP/h6f-stderr.txt"; then
  check_eq "redemption fired (stderr notice present)" "present" "present"
else
  check_eq "redemption fired (stderr notice present)" "present" "absent"
fi

############################################################################
echo "== Scenario (h6g): stale submitted_at REDEEMED, but the approval is hollow -> trigger_greptile (issue #875 guard survives redemption) =="
reset_state
write_commits "$(ts_seconds_ago 300)"
FAILURE_COMMENT_H6G="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_STALE_H6G='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "", "submitted_at": "'"$(ts_seconds_ago 3600)"'"}'
# A post-push status comment NAMING HEAD — genuine external evidence, so the
# freshness filter redeems the frozen timestamp exactly as in (h6f).
CODEANT_NAMES_HEAD_H6G="$(jq -cn --arg ts "$(ts_seconds_ago 200)" --arg sha "$HEAD_SHA" \
  '{user: {login: "codeant-ai[bot]"}, created_at: $ts,
    body: ("CodeAnt AI reviewed commit " + $sha + " and walked every changed hunk in the escalation gate before reporting back.")}')"
# ...and then this bot own newest SHA-naming self-report names a DIFFERENT
# commit, which is not suppressed by external evidence (self_report_mismatch).
# So redemption grants at the freshness stage and the hollow guard withholds
# afterwards — the exact laundering path this scenario exists to close.
CODEANT_OLD_SHA_H6G="$(jq -cn --arg ts "$(ts_seconds_ago 150)" --arg sha "$OLD_SHA_H6" \
  '{user: {login: "codeant-ai[bot]"}, created_at: $ts,
    body: ("CodeAnt AI - Review Status: reviewed your PR at commit " + $sha + " and finished without blocking findings.")}')"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_STALE_H6G]" "[]" \
  "[$FAILURE_COMMENT_H6G, $CODEANT_NAMES_HEAD_H6G, $CODEANT_OLD_SHA_H6G]"
OUT=$(run_script 2>"$TMP/h6g-stderr.txt"); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"
# Both halves must be observed: redemption GRANTED (so this is genuinely the
# redeemed path, not a stale approval that never got that far), and the #875
# guard is what withheld. Without the first assertion this case would keep
# passing if redemption silently stopped working.
if grep -q "issue #876, escalation parity #1387" "$TMP/h6g-stderr.txt"; then
  check_eq "redemption fired before the substance guard" "present" "present"
else
  check_eq "redemption fired before the substance guard" "present" "absent"
fi
if grep -q "no reviewer holds BOTH a valid APPROVED on HEAD and substantive review evidence" "$TMP/h6g-stderr.txt"; then
  check_eq "substance guard still withheld a redeemed approval" "present" "present"
else
  check_eq "substance guard still withheld a redeemed approval" "present" "absent"
fi

############################################################################
echo "== Scenario (h6h): stale submitted_at + only run-start/completion markers -> trigger_greptile (a constant redeems nothing) =="
reset_state
write_commits "$(ts_seconds_ago 300)"
FAILURE_COMMENT_H6H="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_STALE_H6H='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "", "submitted_at": "'"$(ts_seconds_ago 3600)"'"}'
# The fixed strings a bot posts around every run. Accepting either as the
# redeemer would let a bot certify its own freshness with a constant, so
# review-substance.sh excludes them from external_evidence_on_head and this PR
# must still escalate.
CODEANT_MARKER_H6H='{"user": {"login": "codeant-ai[bot]"}, "created_at": "'"$(ts_seconds_ago 200)"'", "body": "CodeAnt AI is running the review on your pull request. Results will be posted shortly."}'
CODEANT_FINISH_H6H='{"user": {"login": "codeant-ai[bot]"}, "created_at": "'"$(ts_seconds_ago 150)"'", "body": "CodeAnt AI finished running the review."}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_STALE_H6H]" "[]" \
  "[$FAILURE_COMMENT_H6H, $CODEANT_MARKER_H6H, $CODEANT_FINISH_H6H]"
OUT=$(run_script 2>"$TMP/h6h-stderr.txt"); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"
# Redemption must NOT have fired — the verdict has to come from the approval
# still being stale, not from a later guard mopping up after a bad grant.
if grep -q "issue #876, escalation parity #1387" "$TMP/h6h-stderr.txt"; then
  check_eq "no redemption from markers alone" "absent" "present"
else
  check_eq "no redemption from markers alone" "absent" "absent"
fi

############################################################################
echo "== Scenario (h7): HEAD commit timestamp unavailable -> fail closed, no gate_met =="
reset_state
write_commits "$(ts_seconds_ago 300)"
# Blank out ONLY the git/commits fixture: freshness becomes unverifiable, which
# merge-gate.sh treats as blocking (CR_APPROVAL_FRESHNESS_UNKNOWN). Escalation
# must match rather than reporting gate_met on an approval it cannot vouch for.
echo '{}' > "$TMP/git-commit-empty.json"
FIXTURE_GIT_COMMIT_JSON="$TMP/git-commit-empty.json"
export FIXTURE_GIT_COMMIT_JSON
FAILURE_COMMENT_H7="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_APPROVED_H7='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed every changed file; no blocking issues found.", "submitted_at": "'"$(ts_seconds_ago 90)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_H7]" "[]" "[$FAILURE_COMMENT_H7]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (i): CodeAnt APPROVED on an OLDER SHA (not HEAD) -> still trigger_greptile (stale approval doesn't satisfy the gate) =="
reset_state
write_commits "$(ts_seconds_ago 120)"
FAILURE_COMMENT_I="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_APPROVED_STALE='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "stale0000000000000000000000000000000000", "state": "APPROVED", "submitted_at": "'"$(ts_seconds_ago 9000)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_STALE]" "[]" "[$FAILURE_COMMENT_I]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (j): CodeAnt APPROVED on HEAD but retracted by a LATER CHANGES_REQUESTED on HEAD -> still trigger_greptile =="
reset_state
write_commits "$(ts_seconds_ago 120)"
FAILURE_COMMENT_J="$(failure_comment "$(ts_seconds_ago 60)")"
CODEANT_APPROVED_J='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "Actionable comments posted: 0. Reviewed the changed files; no issues found.", "submitted_at": "'"$(ts_seconds_ago 200)"'"}'
CODEANT_RETRACT_J='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "CHANGES_REQUESTED", "submitted_at": "'"$(ts_seconds_ago 100)"'"}'
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_APPROVED_J, $CODEANT_RETRACT_J]" "[]" "[$FAILURE_COMMENT_J]"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile" "STATUS=trigger_greptile" "$OUT"

############################################################################
echo "== Scenario (k): CR commit-status rate-limit via state:success + description only (issue #708) -> skips CR gate immediately, no 12-min wait =="
reset_state
write_commits "$(ts_seconds_ago 60)"   # recent push (AGE_SECONDS well under 720) — proves no dependency on the AGE_SECONDS fallback
CR_STATUS_RATE_LIMITED='{"context": "CodeRabbit", "state": "success", "description": "Review rate limited"}'
jq -n \
  --arg owner "$OWNER" --arg repo "$REPO" --arg sha "$HEAD_SHA" \
  --argjson bugbot_run "$BUGBOT_CHECK_RUN_OK" \
  --argjson status "$CR_STATUS_RATE_LIMITED" \
  '{
    pr: {owner: $owner, repo: $repo, head_sha: $sha},
    check_runs: {all: [$bugbot_run]},
    commit_statuses: [$status],
    comments: {reviews: [], inline: [], conversation: []}
  }' > "$TMP/state.json"
export FIXTURE_STATE_JSON="$TMP/state.json"
OUT=$(run_script); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=switch_bugbot" "STATUS=switch_bugbot" "$OUT"

echo
echo "== Scenario L: check-run data still comes only from pr-state.sh's bundle (#675) =="
# escalate-review.sh reads check-runs via pr-state.sh's `check_runs.all`, which is
# deduped at the source (newest check suite per (app, name)). That inheritance is
# the whole reason this script needs no dedup of its own — so guard it: a direct
# `commits/<sha>/check-runs` fetch added here later would silently reintroduce the
# superseded-run bug, and no behavioral test would catch it.
ESCALATE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../escalate-review.sh"
if grep -qE 'commits/[^"]*/check-runs' "$ESCALATE_SRC"; then
  check_eq "no direct check-runs fetch in escalate-review.sh" "absent" "present"
else
  check_eq "no direct check-runs fetch in escalate-review.sh" "absent" "absent"
fi
# ...and it does still read the bundle, so the guard above cannot pass by the
# script having dropped check-runs entirely.
if grep -q 'check_runs\.all' "$ESCALATE_SRC"; then
  check_eq "escalate-review.sh reads check_runs.all from the bundle" "present" "present"
else
  check_eq "escalate-review.sh reads check_runs.all from the bundle" "present" "absent"
fi

############################################################################
echo
echo "== Scenario (m): PR #1351 hollow shape — empty APPROVED 52s after push + stale-SHA status comment + repointed inline comment -> trigger_greptile (issue #1362) =="
reset_state
write_commits "$(ts_seconds_ago 300)"
FAILURE_COMMENT_M="$(failure_comment "$(ts_seconds_ago 60)")"
OLD_SHA_M="990a2b2a56c49e2d188ebc807eeb8c4be41154f5"
# Round-1 COMMENTED review on the PREVIOUS SHA, empty body — off-HEAD, so it may
# not lend substance to the approval below.
CODEANT_COMMENTED_M='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$OLD_SHA_M"'", "state": "COMMENTED", "body": "", "submitted_at": "'"$(ts_seconds_ago 660)"'"}'
# The rubber stamp: empty body, 52 s after the push — the live gap on PR #1351.
CODEANT_APPROVED_M='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "state": "APPROVED", "body": "", "submitted_at": "'"$(ts_seconds_ago 248)"'"}'
# Round-1 inline finding whose commit_id GitHub repointed onto HEAD; only
# original_commit_id still names the commit that was actually reviewed. It must
# NOT count as a HEAD-anchored footprint — dropping the original_commit_id
# filter in review-substance.sh would flip this scenario to gate_met.
CODEANT_INLINE_M='{"user": {"login": "codeant-ai[bot]"}, "commit_id": "'"$HEAD_SHA"'", "original_commit_id": "'"$OLD_SHA_M"'", "created_at": "'"$(ts_seconds_ago 660)"'", "path": "a.sh", "body": "Major: the persisted override flag is not session-scoped and outlives the invocation that granted it."}'
# CodeAnt status comment naming ONLY the previous SHA (short token in the table,
# full SHA in the machine-readable HTML comment) — the bot's newest SHA-naming
# self-report does not name HEAD, so self_report_mismatch must fire alongside
# no_substantive_footprint, exactly as merge-gate.sh reported live.
# Unquoted heredoc so the SHA variables expand; the code-span backticks are
# escaped so they stay literal instead of running command substitution.
STATUS_BODY_M="$(cat <<STATUS_M_EOF
CodeAnt AI - Review Status

| Status | Commit | Started (UTC) | Finished (UTC) |
| --- | --- | --- | --- |
| Reviewed your PR | \`${OLD_SHA_M:0:7}\` | Aug 26, 2026 17:40 | 17:43 |

<!-- codeant-review-status:[{"label":"Reviewed your PR","commit":"$OLD_SHA_M","done":true}] -->
STATUS_M_EOF
)"
CODEANT_STATUS_M="$(jq -cn --arg ts "$(ts_seconds_ago 350)" --arg body "$STATUS_BODY_M" '{user: {login: "codeant-ai[bot]"}, created_at: $ts, body: $body}')"
write_state "[$BUGBOT_CHECK_RUN_OK]" "[$CODEANT_COMMENTED_M, $CODEANT_APPROVED_M]" "[$CODEANT_INLINE_M]" "[$FAILURE_COMMENT_M, $CODEANT_STATUS_M]"
OUT=$(run_script 2>"$TMP/m-stderr.txt"); RC=$?
check_eq "exit 0" 0 "$RC"
check_eq "STATUS=trigger_greptile (not gate_met)" "STATUS=trigger_greptile" "$OUT"
# The verdict must come from the substance guard REJECTING a valid, fresh
# approval — not from the approval failing validity or freshness upstream, which
# would let this scenario keep passing with the guard deleted. Assert the guard
# announced itself.
if grep -q "no reviewer holds BOTH a valid APPROVED on HEAD and substantive review evidence" "$TMP/m-stderr.txt"; then
  check_eq "substance guard fired (stderr notice present)" "present" "present"
else
  check_eq "substance guard fired (stderr notice present)" "present" "absent"
fi

finish_escalate_review_tests "gate and approval freshness"
