#!/usr/bin/env bash
# merge-gate-bugbot.test.sh — Offline integration tests for the BugBot reviewer
# path in merge-gate.sh (issues #844 and #962).
#
# Covers the gate's BugBot path (--reviewer bugbot):
#   - Silent-pass: completed/success check-run published by Cursor app → gate met (issue #844)
#   - Failure-phrase: success check-run + spend-limit comment → gate blocked
#   - Neutral: conclusion:neutral does not satisfy silent-pass path
#   - Review object: CHANGES_REQUESTED cursor[bot] review object → findings entry in missing
#   - Stale comment: failure-phrase comment predating HEAD commit must be ignored (issue #836)
#   - Empty timestamp: missing completed_at/started_at fails closed
#   - Publisher scoping: foreign-app or absent-app check-run does not satisfy gate (issue #962)
#   - Review-object path: shape 1 (cursor[bot] APPROVED review) is untouched by issue #962
#
# Shared harness (fake gh, cr(), bundle()) lives in tests/lib/merge-gate-test-fixtures.sh.
# CI check-run dedup coverage lives in merge-gate-ci-dedup.test.sh.
# Run from repo root: bash .claude/scripts/tests/merge-gate-bugbot.test.sh
# shellcheck source=tests/lib/merge-gate-test-fixtures.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/merge-gate-test-fixtures.sh"

OUT=""
RC=0
run_gate_bugbot() { # $1 = check-runs JSON; FAKE_REVIEWS/FAKE_PR_COMMENTS/FAKE_ISSUE_COMMENTS from env
  OUT=$(PATH="$BIN:$PATH" FAKE_CHECK_RUNS="$1" \
        FAKE_REVIEWS="${FAKE_REVIEWS:-[]}" \
        FAKE_PR_COMMENTS="${FAKE_PR_COMMENTS:-[]}" \
        FAKE_ISSUE_COMMENTS="${FAKE_ISSUE_COMMENTS:-[]}" \
        "$SUT" 1 --reviewer bugbot 2>/dev/null)
  RC=$?
}

# BugBot-specific missing-entry helpers.
has_bugbot_no_review_entry() { echo "$OUT" | jq -e '[.missing[]? | select(startswith("no BugBot review on HEAD"))] | length > 0' >/dev/null && echo yes || echo no; }
has_bugbot_findings_entry() { echo "$OUT" | jq -e '[.missing[]? | select(startswith("latest BugBot review on HEAD has findings"))] | length > 0' >/dev/null && echo yes || echo no; }
has_bugbot_ts_unavail_entry() { echo "$OUT" | jq -e '[.missing[]? | select(contains("completed_at/started_at unavailable"))] | length > 0' >/dev/null && echo yes || echo no; }
# Publisher-scoping block on the silent-pass check-run (issue #962).
has_bugbot_app_mismatch_entry() { echo "$OUT" | jq -e '[.missing[]? | select(contains("was not published by the Cursor app"))] | length > 0' >/dev/null && echo yes || echo no; }

# --------------------------------------------------------------------------
# 7. BugBot silent-pass (issue #844): completed/success check-run published by
#    the Cursor app, no review object, no cursor[bot] comments → gate met
#    (met:true).
#    NOTE: this test FAILS against pre-fix code because the old bugbot) case
#    only accepted review objects, so "no BugBot review on HEAD" was always
#    added when no review object existed, leaving the gate permanently blocked.
#    The explicit `cursor` slug (issue #962) is what a genuine BugBot run
#    carries; it is the parity pin for the publisher scoping — this scenario must
#    keep reading met:true exactly as it did before that change.
# --------------------------------------------------------------------------
FAKE_REVIEWS='[]'
FAKE_PR_COMMENTS='[]'
FAKE_ISSUE_COMMENTS='[]'
run_gate_bugbot "$(bundle "$(cr 1 "Cursor Bugbot" success 100 cursor)")"
check_eq "true" "$(echo "$OUT" | jq -r '.met')"  "BugBot silent-pass: gate met with success check-run (issue #844)"
check_eq "no"   "$(has_bugbot_no_review_entry)"  "BugBot silent-pass: no 'no BugBot review' in missing"

# --------------------------------------------------------------------------
# 8. Negative: success check-run + failure-phrase issue comment → gate NOT met.
#    BugBot spend-limit failure can produce a success check-run AND a comment
#    containing a failure phrase; the failure-phrase scan must block the gate.
# --------------------------------------------------------------------------
FAKE_REVIEWS='[]'
FAKE_PR_COMMENTS='[]'
FAKE_ISSUE_COMMENTS="$(jq -cn '[{user:{login:"cursor[bot]"},body:"I could not run this review — usage limit reached"}]')"
run_gate_bugbot "$(bundle "$(cr 1 "Cursor Bugbot" success 100 cursor)")"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "BugBot failure comment: gate blocked despite success check-run"
check_eq "yes"   "$(has_bugbot_no_review_entry)" "BugBot failure comment: 'no BugBot review' entry in missing"

# --------------------------------------------------------------------------
# 9. Negative: neutral check-run + inline cursor[bot] PR comment → gate NOT met.
#    conclusion:neutral means BugBot posted findings; the success-check path is
#    not taken (only conclusion:success qualifies), so there is still no valid
#    review signal and "no BugBot review on HEAD" is added to missing.
# --------------------------------------------------------------------------
FAKE_REVIEWS='[]'
FAKE_PR_COMMENTS="$(jq -cn --arg sha "$HEAD_SHA" \
  '[{user:{login:"cursor[bot]"},body:"Found an issue on line 42",commit_id:$sha,original_commit_id:$sha}]')"
FAKE_ISSUE_COMMENTS='[]'
run_gate_bugbot "$(bundle "$(cr 1 "Cursor Bugbot" neutral 100)")"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "BugBot neutral check-run: gate blocked (conclusion:neutral does not satisfy)"
check_eq "yes"   "$(has_bugbot_no_review_entry)" "BugBot neutral check-run: 'no BugBot review' entry in missing"

# --------------------------------------------------------------------------
# 10. Negative: CHANGES_REQUESTED cursor[bot] review object on HEAD → NOT met.
#     When a review object exists, the review-object path applies; a
#     CHANGES_REQUESTED state adds the findings entry to missing.
# --------------------------------------------------------------------------
FAKE_REVIEWS="$(jq -cn --arg sha "$HEAD_SHA" \
  '[{user:{login:"cursor[bot]"},state:"CHANGES_REQUESTED",commit_id:$sha,submitted_at:"2026-07-21T10:01:00Z"}]')"
FAKE_PR_COMMENTS='[]'
FAKE_ISSUE_COMMENTS='[]'
run_gate_bugbot "$(bundle "$(cr 1 "Cursor Bugbot" neutral 100)")"
check_eq "false" "$(echo "$OUT" | jq -r '.met')" "BugBot CHANGES_REQUESTED: gate blocked"
check_eq "yes"   "$(has_bugbot_findings_entry)"  "BugBot CHANGES_REQUESTED: findings entry in missing"

# --------------------------------------------------------------------------
# (m) Stale failure-phrase comment (pre-HEAD created_at) must NOT block.
#     The freshness filter on BB_HAS_FAILURE_COMMENT only counts comments
#     posted AFTER the HEAD commit. HEAD committer date is 2026-07-21T09:59:00Z
#     (set by the fake gh git/commits endpoint); a comment with created_at
#     2026-07-21T09:00:00Z is stale and must be ignored.
# --------------------------------------------------------------------------
FAKE_REVIEWS='[]'
FAKE_PR_COMMENTS='[]'
FAKE_ISSUE_COMMENTS="$(jq -cn '[{user:{login:"cursor[bot]"},body:"I could not run this review — usage limit reached",created_at:"2026-07-21T09:00:00Z"}]')"
run_gate_bugbot "$(bundle "$(cr 1 "Cursor Bugbot" success 100 cursor)")"
check_eq "true" "$(echo "$OUT" | jq -r '.met')"           "BugBot stale failure comment: gate met (comment predates HEAD commit)"
check_eq "no"   "$(has_bugbot_no_review_entry)"            "BugBot stale failure comment: no 'no BugBot review' entry"

# --------------------------------------------------------------------------
# (n) Success check-run with empty completed_at/started_at must fail-closed.
#     When LAST_COMMIT_TS is known but neither timestamp field is set,
#     freshness cannot be verified — gate must block (mirrors CodeAnt gate).
# --------------------------------------------------------------------------
BB_NO_TS_RUN="$(jq -cn '{id:1, name:"Cursor Bugbot", status:"completed",
  conclusion:"success", completed_at:null, started_at:null,
  check_suite:{id:100}, app:{slug:"cursor",id:1}}')"
FAKE_REVIEWS='[]'
FAKE_PR_COMMENTS='[]'
FAKE_ISSUE_COMMENTS='[]'
run_gate_bugbot "$(bundle "$BB_NO_TS_RUN")"
check_eq "false" "$(echo "$OUT" | jq -r '.met')"          "BugBot empty check timestamp: gate blocked (cannot verify freshness)"
check_eq "yes"   "$(has_bugbot_ts_unavail_entry)"          "BugBot empty check timestamp: 'completed_at/started_at unavailable' in missing"

# --------------------------------------------------------------------------
# (o) Foreign-app same-name success run must NOT satisfy the silent pass
#     (issue #962). Any GitHub App may publish a check-run under any name, so
#     `Cursor Bugbot` names a check, not a publisher. Everything else here is
#     byte-identical to scenario 7 — the ONLY difference is the app slug — so
#     this pair isolates the publisher requirement from every other condition.
#     Fails closed: unlike escalate-review.sh's routing fallback (issue #956),
#     an unverifiable publisher here would satisfy the merge gate outright.
# --------------------------------------------------------------------------
FAKE_REVIEWS='[]'
FAKE_PR_COMMENTS='[]'
FAKE_ISSUE_COMMENTS='[]'
run_gate_bugbot "$(bundle "$(cr 1 "Cursor Bugbot" success 100 not-cursor)")"
check_eq "false" "$(echo "$OUT" | jq -r '.met')"            "BugBot foreign-app check-run: gate blocked (publisher is not the Cursor app)"
check_eq "yes"   "$(has_bugbot_app_mismatch_entry)"         "BugBot foreign-app check-run: publisher entry in missing"
check_eq "no"    "$(has_bugbot_no_review_entry)"            "BugBot foreign-app check-run: publisher reason replaces the generic 'no BugBot review' entry"

# --------------------------------------------------------------------------
# (p) Same-name success run with NO app identity at all must also fail closed
#     (issue #962). An absent/empty `app` block is unattributable, which is not
#     the same as trusted — the slug compare treats missing exactly like foreign.
#     Timestamps are valid here so freshness cannot be what blocks it; the
#     publisher check is deliberately evaluated ahead of the freshness checks.
# --------------------------------------------------------------------------
BB_NO_APP_RUN="$(jq -cn '{id:1, name:"Cursor Bugbot", status:"completed",
  conclusion:"success", completed_at:"2026-07-21T10:00:01Z",
  started_at:"2026-07-21T10:00:01Z", check_suite:{id:100}}')"
FAKE_REVIEWS='[]'
FAKE_PR_COMMENTS='[]'
FAKE_ISSUE_COMMENTS='[]'
run_gate_bugbot "$(bundle "$BB_NO_APP_RUN")"
check_eq "false" "$(echo "$OUT" | jq -r '.met')"            "BugBot missing-app check-run: gate blocked (publisher unverifiable)"
check_eq "yes"   "$(has_bugbot_app_mismatch_entry)"         "BugBot missing-app check-run: publisher entry in missing"
check_eq "no"    "$(has_bugbot_ts_unavail_entry)"           "BugBot missing-app check-run: blocked on publisher, not freshness"

# --------------------------------------------------------------------------
# (q) The review-object path (bugbot.md shape 1) is untouched by issue #962.
#     A clean cursor[bot] review object on HEAD satisfies the gate even with a
#     foreign-app same-name check-run sitting beside it — shape 1 keys on
#     `.user.login == "cursor[bot]"`, which is already an identity match, and
#     the check-run block is not evaluated at all once a review object exists.
#     Same payload, same verdict as before the publisher scoping.
# --------------------------------------------------------------------------
FAKE_REVIEWS="$(jq -cn --arg sha "$HEAD_SHA" \
  '[{user:{login:"cursor[bot]"},state:"APPROVED",commit_id:$sha,submitted_at:"2026-07-21T10:01:00Z"}]')"
FAKE_PR_COMMENTS='[]'
FAKE_ISSUE_COMMENTS='[]'
run_gate_bugbot "$(bundle "$(cr 1 "Cursor Bugbot" success 100 not-cursor)")"
check_eq "true" "$(echo "$OUT" | jq -r '.met')"             "BugBot review object: gate met via shape 1 despite a foreign-app check-run"
check_eq "no"   "$(has_bugbot_app_mismatch_entry)"          "BugBot review object: publisher entry not added (check-run path not evaluated)"
check_eq "no"   "$(has_bugbot_findings_entry)"              "BugBot review object: clean APPROVED adds no findings entry"

# Reset BugBot-specific env vars so they don't bleed into a re-run.
unset FAKE_REVIEWS FAKE_PR_COMMENTS FAKE_ISSUE_COMMENTS

echo "----------------------------------------"
echo "merge-gate-bugbot.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
