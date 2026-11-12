#!/usr/bin/env bash
# review-ci-report.test.sh — Offline regression tests for review-ci-report.sh (issue #2196).
# catalog: tests — Tests that the review timing report keeps CodeAnt pre-review approvals and refusals out of the review count, measures response time from the request when one exists and from push otherwise, and reports a failed query as unread with a non-zero exit
#
# Every assertion runs against the committed fixture (no network). Each one
# covers a specific piece of logic, and the comment above it names the mutation
# that would make it fail. Runs under bash 3.2 and bash 5.x.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/../review-ci-report.sh"
FIXTURE="$SCRIPT_DIR/fixtures/review-ci-report/fixture.json"
PASS=0
FAIL=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/review-ci-report-test.XXXXXX") || { echo "FAIL: mktemp" >&2; exit 1; }
trap 'rm -f "$TMP"/* "$TMP"/stub/* "$TMP"/empty/* 2>/dev/null; rmdir "$TMP"/stub "$TMP"/empty "$TMP" 2>/dev/null' EXIT

check() {
  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $1 — expected [$2] got [$3]" >&2
  fi
}

check_contains() {
  # check_contains <name> <needle> <haystack-file>
  if grep -F -q -- "$2" "$3"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $1 — missing text: $2" >&2
  fi
}

if [ ! -f "$SCRIPT" ] || [ ! -f "$FIXTURE" ]; then
  echo "FAIL: script or fixture missing" >&2
  exit 1
fi

JSON_OUT="$TMP/report.json"
"$SCRIPT" --fixture "$FIXTURE" --json >"$JSON_OUT" 2>"$TMP/json.err"
JSON_RC=$?

# Exit code: an unread repo makes the whole run exit non-zero (mutation: always 0).
check "unread repo gives non-zero exit" "1" "$JSON_RC"

# Repo-level status: a failed query and a GraphQL-errors response are unread, never zeros.
# Mutation: treating a gh failure as an empty repo would report status "read".
check "failed gh query reported unread" "unread" "$(jq -r '.per_repo[] | select(.repo == "example/broken") | .status' "$JSON_OUT")"
check "failed gh query metrics are null" "null" "$(jq -c '.per_repo[] | select(.repo == "example/broken") | .ci' "$JSON_OUT")"
check "failed gh query carries a reason" "gh exited 1: HTTP 502: Bad Gateway" "$(jq -r '.per_repo[] | select(.repo == "example/broken") | .reason' "$JSON_OUT")"
# Mutation: ignoring top-level errors when data is present would report status "read".
check "GraphQL errors with data present reported unread" "unread" "$(jq -r '.per_repo[] | select(.repo == "example/errors") | .status' "$JSON_OUT")"
check "healthy repo stays read" "read" "$(jq -r '.per_repo[] | select(.repo == "example/app") | .status' "$JSON_OUT")"

# CodeAnt's empty APPROVED on aaaa1111 (10:02) has no completed run on its SHA: a pre-review stub, counted
# in its own bucket. Mutation: a blanket exclusion of every APPROVED also drops the substantiated one below.
check "unsubstantiated CodeAnt approval counted as pre-review" "1" "$(jq -r '.per_repo[] | select(.repo == "example/app") | .reviewers["codeant-ai"].pre_review_approvals' "$JSON_OUT")"
# The APPROVED on bbbb2222 (10:40) is substantiated by a done run finished 10:44:00.25 (naive UTC marker):
# it counts as a review, timed from push (10:30) to the run's finish, not to the approval.
# Mutation: a blanket exclusion makes reviews 0; timing at the approval instant gives 10.0, not 14.0.
check "substantiated CodeAnt approval counts as a review" "1" "$(jq -r '.per_repo[] | select(.repo == "example/app") | .reviewers["codeant-ai"].reviews' "$JSON_OUT")"
check "substantiated CodeAnt approval timed at run finish" "14.0" "$(jq -r '.per_repo[] | select(.repo == "example/app") | .reviewers["codeant-ai"].response_median_min' "$JSON_OUT")"

# Build CI: an unrecognised conclusion is never counted as passed. example/edge has one commit whose only
# check concludes WEIRD_NEW_VALUE: it stays pending. Mutation: falling through to passed gives completed 1.
check "unrecognised conclusion stays pending" "1" "$(jq -r '.per_repo[] | select(.repo == "example/edge") | .ci.commits_ci_pending' "$JSON_OUT")"
check "unrecognised conclusion is not a completed pass" "0" "$(jq -r '.per_repo[] | select(.repo == "example/edge") | .ci.commits_ci_completed' "$JSON_OUT")"

# A refusal (rate limit) is counted per reviewer and is not a review.
# A walkthrough that quotes a rate-limit note is a review, not a refusal (the 10:55 review).
# Mutation: dropping the refusal rule makes coderabbitai reviews 2 (aaaa1111 refusal review also counts);
# dropping the walkthrough exception makes refusals 3.
check "CodeRabbit reviews exclude refusals" "1" "$(jq -r '.per_repo[] | select(.repo == "example/app") | .reviewers.coderabbitai.reviews' "$JSON_OUT")"
check "CodeRabbit refusals counted separately" "2" "$(jq -r '.per_repo[] | select(.repo == "example/app") | .reviewers.coderabbitai.refusals' "$JSON_OUT")"

# A review counts as on failed CI when the commit's final CI failed, even if the check finished after
# the review (bbbb2222's build failed at 10:41, after CodeRabbit's 10:38 review). Mutation: judging the
# CI state as of submission gives 0.
check "review on a commit whose final CI failed counts as failed-CI" "1" "$(jq -r '.per_repo[] | select(.repo == "example/app") | .reviewers.coderabbitai.reviews_on_failed_ci' "$JSON_OUT")"

# Response time from the review request when one exists: request 10:35, review 10:38 -> 3.0.
# Mutation: measuring from push (10:30) would give 8.0.
check "response time measured from the request" "3.0" "$(jq -r '.per_repo[] | select(.repo == "example/app") | .reviewers.coderabbitai.response_median_min' "$JSON_OUT")"
check "request anchor sample counted" "1" "$(jq -r '.per_repo[] | select(.repo == "example/app") | .reviewers.coderabbitai.anchor_samples.request' "$JSON_OUT")"

# Response time from push when no request exists: BugBot review 10:21, push 10:01 -> 20.0.
# Mutation: a human-authored look-alike at 10:15 (login "cursor", type User) would give 14.0.
check "response time measured from push when no request" "20.0" "$(jq -r '.per_repo[] | select(.repo == "example/app") | .reviewers.cursor.response_median_min' "$JSON_OUT")"
check "push anchor sample counted" "1" "$(jq -r '.per_repo[] | select(.repo == "example/app") | .reviewers.cursor.anchor_samples.push' "$JSON_OUT")"
check "bot identity: BugBot reviews exclude the User look-alike" "1" "$(jq -r '.per_repo[] | select(.repo == "example/app") | .reviewers.cursor.reviews' "$JSON_OUT")"

# CI: C2's FAILURE counts; the Cursor Bugbot check run is reviewer CI and is ignored.
# Mutation: ignoring failed conclusions gives 0.0; counting the reviewer check as build CI changes durations.
check "failed-CI share from completed commits" "50.0" "$(jq -r '.per_repo[] | select(.repo == "example/app") | .ci.failed_share_pct' "$JSON_OUT")"
check "CI duration median excludes reviewer check" "10.0" "$(jq -r '.per_repo[] | select(.repo == "example/app") | .ci.duration_median_min' "$JSON_OUT")"
check "force-push proxy used for the rewritten commit" "1" "$(jq -r '.per_repo[] | select(.repo == "example/app") | .ci.push_proxy_kinds.force_push' "$JSON_OUT")"

# Request budget: one GraphQL request per repo, stated.
check "request budget stated per repo" "1" "$(jq -r '.request_budget.graphql_requests_per_repo' "$JSON_OUT")"
check "request budget total" "4" "$(jq -r '.request_budget.graphql_requests_total' "$JSON_OUT")"

# Blind spots are printed in plain words in the table.
TABLE_OUT="$TMP/table.md"
"$SCRIPT" --fixture "$FIXTURE" >"$TABLE_OUT" 2>/dev/null
check_contains "blind spot: force-push" "Commits replaced by a force-push leave no record" "$TABLE_OUT"
check_contains "blind spot: no cost data" "No cost data: see the review-stack audit for billing." "$TABLE_OUT"
check_contains "blind spot: sample size" "too small to draw conclusions" "$TABLE_OUT"
check_contains "unread cells rendered as unread ()" "unread ()" "$TABLE_OUT"

# Usage errors exit 2 before any request is made.
"$SCRIPT" --limit 0 --fixture "$FIXTURE" >/dev/null 2>&1
check "--limit 0 is a usage error" "2" "$?"
"$SCRIPT" --repo "not-a-repo" --fixture "$FIXTURE" >/dev/null 2>&1
check "malformed --repo is a usage error" "2" "$?"
# Shape-valid but impossible calendar dates are usage errors too.
"$SCRIPT" --since 2026-02-31 --fixture "$FIXTURE" >/dev/null 2>&1
check "impossible --since date is a usage error" "2" "$?"

# An explicitly empty --since is a usage error, never "no filter".
"$SCRIPT" --since "" --fixture "$FIXTURE" >/dev/null 2>&1
check "explicitly empty --since is a usage error" "2" "$?"

# Without python3 the date cannot be validated: report unavailability (exit 1), not a bad date (exit 2).
mkdir -p "$TMP/empty"
env PATH="$TMP/empty" /bin/bash "$SCRIPT" --since 2026-01-02 --fixture "$FIXTURE" >/dev/null 2>"$TMP/nopy.err"
check "missing python3 reports unavailable, exit 1" "1" "$?"
check_contains "missing python3 names the dependency" "python3 not found" "$TMP/nopy.err"

# gh receives owner and name with -f (raw strings), so 1234 and true stay strings.
# Mutation: -F sends owner=1234 and name=true type-converted; the awk finds no "-f" before them.
mkdir -p "$TMP/stub"
cat > "$TMP/stub/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$REPORT_GH_ARGS"
printf '%s\n' '{"data":{"rateLimit":{"cost":1},"repository":{"pullRequests":{"totalCount":0,"nodes":[]}}}}'
STUB
chmod +x "$TMP/stub/gh"
REPORT_GH_ARGS="$TMP/gh-args.txt" PATH="$TMP/stub:$PATH" "$SCRIPT" --repo 1234/true >/dev/null 2>&1
RAW_OK=no
if awk 'prev == "-f" && ($0 == "owner=1234" || $0 == "name=true") { n++ } { prev = $0 } END { exit n == 2 ? 0 : 1 }' "$TMP/gh-args.txt"; then
  RAW_OK=yes
fi
check "owner and name are sent as raw strings (-f)" "yes" "$RAW_OK"

rm -f "$TMP"/* 2>/dev/null
echo "review-ci-report tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
