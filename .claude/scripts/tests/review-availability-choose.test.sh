#!/usr/bin/env bash
# review-availability-choose.test.sh — offline fixture tests for the free-reviewer choice in
# review-availability.sh (issue #2257): `choose` picks the reviewer whose answer lands first,
# the other one when the first is limited, a skip when neither answers inside the window,
# ties to the reviewer with fewer recent requests, CodeRabbit's hourly budget as a hard
# exclusion, alternation across PRs that go green together, and `record-request`, which logs
# each request account-wide (pruned after an hour) and records the choice on the PR.
# HOME is a throwaway directory, so no real session state is read or written. Run under
# /bin/bash (3.2) and a 5.x bash.
# catalog: tests — Tests the free-reviewer choice and request log in `review-availability.sh` (choose, record-request) — earliest answer, limited and capped reviewers, fewer-recent tie-break, alternation across PRs, recorded choice
# Run from repo root: bash .claude/scripts/tests/review-availability-choose.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AV="$SCRIPT_DIR/../review-availability.sh"
[[ -f "$AV" ]] || { echo "FAIL: helper not found at $AV" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
STATE_FILE="$HOME/.claude/session-state.json"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1 — $2"; }
expect_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got [$2] want [$3]"; fi; }

NOW=$(date -u +%s)
WIN=600   # no-review window: 10 minutes
iso() { jq -rn --argjson s "$1" '$s | todateiso8601'; }

# av_record <next-available epoch> <notice epoch> — a usable limit record (as `record` writes it).
av_record() {
  jq -cn --argjson n "$1" --argjson t "$2" \
    '{next_available_epoch: $n, next_available: ($n | todateiso8601), notice_epoch: $t, notice_at: ($t | todateiso8601),
      window_seconds: ($n - $t), notice_excerpt: "next review available in", source_repo: "o/r", source_pr: 1,
      read_at: ($t | todateiso8601)}'
}
# write_state <review_availability json> [review_requests json] [cr hourly events json]
write_state() {
  jq -cn --argjson av "${1:-{\}}" --argjson rq "${2:-[]}" --argjson ev "${3:-[]}" \
    '{schema_version: 1, review_availability: $av, review_requests: $rq, cr_hourly: {events: $ev}}' > "$STATE_FILE"
}
# req <reviewer> <seconds before NOW> — one logged request, as record-request writes it.
req() { jq -cn --arg r "$1" --argjson at "$((NOW - $2))" '{reviewer: $r, at_epoch: $at, at: "", pr: 1, head_sha: "x", reason: "t"}'; }
reqs() { printf '%s\n' "$@" | jq -s '.'; }
choose() { "$AV" choose --window-s "$WIN" --now "$NOW" "$@"; }
# eight CodeRabbit events inside the hour: the default CR_HOURLY_BUDGET (8) is spent.
spent_events() { jq -cn --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '[range(8) | $t]'; }
EMPTY_AV='{}'

# --- Both available: the earliest answer wins --------------------------------------------
write_state "$EMPTY_AV"
c=$(choose)
expect_eq "both available, defaults: CodeAnt (4 min) answers before CodeRabbit (5 min)" "$(jq -r '.reviewer' <<<"$c")" "codeant"
expect_eq "both available: reason is earliest_answer" "$(jq -r '.choice_reason' <<<"$c")" "earliest_answer"
c=$(REVIEW_EXPECTED_RESPONSE_CODERABBIT_MIN=1 choose)
expect_eq "both available, CodeRabbit set to 1 min: CodeRabbit answers first" "$(jq -r '.reviewer' <<<"$c")" "coderabbit"

# --- One limited: the other is asked ----------------------------------------------------
write_state "{\"codeant\":$(av_record $((NOW + 1200)) $NOW)}"
c=$(choose)
expect_eq "CodeAnt limited for 20 min: CodeRabbit is asked" "$(jq -r '.reviewer' <<<"$c")" "coderabbit"
expect_eq "CodeAnt limited: reason names the only reviewer able to answer" \
  "$(jq -r '.choice_reason' <<<"$c")" "only_coderabbit_can_answer"
write_state "{\"coderabbit\":$(av_record $((NOW + 1200)) $NOW)}"
c=$(choose)
expect_eq "CodeRabbit limited for 20 min: CodeAnt is asked" "$(jq -r '.reviewer' <<<"$c")" "codeant"

# --- Both limited: skip, as increment 1 -------------------------------------------------
write_state "{\"coderabbit\":$(av_record $((NOW + 1200)) $NOW),\"codeant\":$(av_record $((NOW + 1500)) $NOW)}"
c=$(choose)
expect_eq "both limited: no reviewer chosen" "$(jq -r '.reviewer' <<<"$c")" "null"
expect_eq "both limited: skip is true" "$(jq -r '.skip' <<<"$c")" "true"
expect_eq "both limited: reason names the earliest return (unchanged from increment 1)" \
  "$(jq -r '.reason' <<<"$c")" "no_reviewer_available_until $(iso $((NOW + 1200)))"
dec=$("$AV" decide --window-s "$WIN" --now "$NOW")
expect_eq "both limited: decide gives the same skip choose does" "$(jq -r '.skip' <<<"$dec")" "true"

# --- CodeRabbit hourly budget spent: CodeRabbit is not eligible ------------------------
write_state "$EMPTY_AV" "[]" "$(spent_events)"
c=$(REVIEW_EXPECTED_RESPONSE_CODERABBIT_MIN=1 choose)
expect_eq "CodeRabbit hourly cap spent: CodeAnt is asked even though CodeRabbit would answer first" \
  "$(jq -r '.reviewer' <<<"$c")" "codeant"
c=$(choose --no-coderabbit)
expect_eq "--no-coderabbit excludes CodeRabbit" "$(jq -r '.reviewer' <<<"$c")" "codeant"

# --- Ties go to the reviewer with fewer requests in the last hour -----------------------
# Both free and equally quick (4 min); CodeAnt has two requests in the last hour, CodeRabbit none.
write_state "$EMPTY_AV" "$(reqs "$(req codeant 3500)" "$(req codeant 3400)")"
c=$(REVIEW_EXPECTED_RESPONSE_CODERABBIT_MIN=4 choose)
expect_eq "tie on answer time: fewer recent requests wins (CodeRabbit)" "$(jq -r '.reviewer' <<<"$c")" "coderabbit"
expect_eq "tie on answer time: reason is tie_fewer_recent_requests" \
  "$(jq -r '.choice_reason' <<<"$c")" "tie_fewer_recent_requests"
# Requests older than an hour do not count toward the tie.
write_state "$EMPTY_AV" "$(reqs "$(req codeant 7300)" "$(req codeant 7200)")"
c=$(REVIEW_EXPECTED_RESPONSE_CODERABBIT_MIN=4 choose)
expect_eq "requests older than an hour do not break the tie (CodeAnt wins the order tie)" \
  "$(jq -r '.reviewer' <<<"$c")" "codeant"

# --- Several PRs going green together alternate reviewers --------------------------------
# Each choice is logged before the next PR is judged, all at the same instant.
write_state "$EMPTY_AV"
seq=""
for pr in 1 2 3 4; do
  c=$(choose)
  r=$(jq -r '.reviewer' <<<"$c")
  seq="$seq $r"
  "$AV" record-request --pr "$pr" --head "h$pr" --reviewer "$r" --reason test --now "$NOW" >/dev/null || bad "record-request for PR $pr" "exit $?"
done
expect_eq "four PRs green together alternate reviewers" "$seq" " codeant coderabbit codeant coderabbit"
c=$(choose)
# A busy queue is an estimate, not a limit: the fifth PR is still asked (fail toward
# asking). Only a real limit notice may skip a review (#2274 review).
expect_eq "a fifth PR in the same window is still asked, not skipped" \
  "$(jq -r '.skip' <<<"$c")" "false"
expect_eq "the fifth PR goes to a reviewer, marked busy but asked" \
  "$(jq -r '[.reviewers.coderabbit.why, .reviewers.codeant.why] | index("busy_but_asked") != null' <<<"$c")" "true"
# A no-review window shorter than both expected response times never skips without a limit.
c=$(REVIEW_EXPECTED_RESPONSE_CODEANT_MIN=30 REVIEW_EXPECTED_RESPONSE_CODERABBIT_MIN=30 "$AV" choose --window-s 120 --now "$NOW")
expect_eq "window shorter than the expected response, no limit notice: still asked" "$(jq -r '.skip' <<<"$c")" "false"

# --- record-request: log, choice on the PR, prune --------------------------------------
write_state "$EMPTY_AV" "$(reqs "$(req codeant 7300)")"
out=$("$AV" record-request --pr 42 --head abc123 --reviewer coderabbit --reason earliest_answer \
  --detail '{"expected_s":{"coderabbit":300}}' --now "$NOW")
expect_eq "record-request reports the recorded reviewer" "$(jq -r '.reviewer' <<<"$out")" "coderabbit"
expect_eq "record-request prunes entries older than an hour" \
  "$(jq -r '[.review_requests[] | select(.at_epoch < ($n|tonumber) - 3600)] | length' --arg n "$NOW" "$STATE_FILE")" "0"
expect_eq "record-request appends the new request" \
  "$(jq -r '[.review_requests[] | select(.reviewer == "coderabbit" and .head_sha == "abc123")] | length' "$STATE_FILE")" "1"
choice=$(jq -r '.. | objects | select(has("review_request_choices")) | .review_request_choices.abc123.reviewer' "$STATE_FILE" | head -1)
expect_eq "the choice is recorded per PR and HEAD" "$choice" "coderabbit"
reason=$(jq -r '.. | objects | select(has("review_request_choices")) | .review_request_choices.abc123.reason' "$STATE_FILE" | head -1)
expect_eq "the choice carries its reason" "$reason" "earliest_answer"
"$AV" record-request --pr 42 --head abc123 --reviewer bugbot --reason x >/dev/null 2>&1
expect_eq "record-request refuses a paid or unknown reviewer" "$?" "2"
"$AV" record-request --pr 42 --head abc123 --reviewer codeant --reason x --detail '[1]' >/dev/null 2>&1
expect_eq "record-request refuses a non-object detail" "$?" "2"

# --- choose usage ------------------------------------------------------------------------
"$AV" choose --window-s 0 >/dev/null 2>&1
expect_eq "choose: zero window is a usage error" "$?" "2"

echo "review-availability choose tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
