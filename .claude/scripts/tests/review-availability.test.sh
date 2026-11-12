#!/usr/bin/env bash
# review-availability.test.sh — offline fixture tests for review-availability.sh (issue #2256):
# notice recording, the request-skip decision, the recorded skip and its check. HOME is a
# throwaway directory, so no real session state is read or written. Run under /bin/bash (3.2)
# and a 5.x bash.
# catalog: tests — Tests the account-wide reviewer availability record and the request-skip decision in `review-availability.sh` — recording, decide, mark-skip, check-skip, fail-toward-asking cases
# Run from repo root: bash .claude/scripts/tests/review-availability.test.sh
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
iso() { jq -rn --argjson s "$1" '$s | todateiso8601'; }
WIN=600   # no-review window: 10 minutes

# Writes a session-state file holding only the given review_availability object (JSON).
# state_with_av <json object>
state_with_av() {
  printf '{"schema_version":1,"review_availability":%s}\n' "$1" > "$STATE_FILE"
}
# av_record <next-available epoch> <notice epoch> — a usable record for one reviewer, as recorded.
av_record() {
  jq -cn --argjson n "$1" --argjson t "$2" \
    '{next_available_epoch: $n, next_available: ($n | todateiso8601), notice_epoch: $t, notice_at: ($t | todateiso8601),
      window_seconds: ($n - $t), notice_excerpt: "next review available in", source_repo: "o/r", source_pr: 1,
      read_at: ($t | todateiso8601)}'
}
# decide_at <now> [window] — prints the decide JSON for the current fixture state.
decide_at() { "$AV" decide --window-s "${2:-$WIN}" --now "$1"; }

# --- Expected response defaults and settings -------------------------------------------
dec=$(state_with_av "{\"coderabbit\":$(av_record $((NOW + 1200)) $NOW),\"codeant\":$(av_record $((NOW + 1200)) $NOW)}"; decide_at "$NOW")
expect_eq "default expected response: CodeRabbit 5 min" "$(jq -r '.expected_s.coderabbit' <<<"$dec")" "300"
expect_eq "default expected response: CodeAnt 4 min" "$(jq -r '.expected_s.codeant' <<<"$dec")" "240"
dec=$(REVIEW_EXPECTED_RESPONSE_CODERABBIT_MIN=1 "$AV" decide --window-s "$WIN" --now "$NOW")
expect_eq "setting honoured: CodeRabbit expected response from env" "$(jq -r '.expected_s.coderabbit' <<<"$dec")" "60"
dec=$(REVIEW_EXPECTED_RESPONSE_CODEANT_MIN=banana "$AV" decide --window-s "$WIN" --now "$NOW")
expect_eq "invalid setting falls back to the default" "$(jq -r '.expected_s.codeant' <<<"$dec")" "240"

# --- Decide: both free reviewers back late -> skip ----------------------------------------
state_with_av "{\"coderabbit\":$(av_record $((NOW + 1200)) $NOW),\"codeant\":$(av_record $((NOW + 1500)) $NOW)}"
dec=$(decide_at "$NOW")
expect_eq "reviewers back in 20 min: skip" "$(jq -r '.skip' <<<"$dec")" "true"
expect_eq "reviewers back in 20 min: reason names the earliest return" \
  "$(jq -r '.reason' <<<"$dec")" "no_reviewer_available_until $(iso $((NOW + 1200)))"

# --- Decide: CodeRabbit back in 3 min -> request as today ----------------------------------
state_with_av "{\"coderabbit\":$(av_record $((NOW + 180)) $NOW),\"codeant\":$(av_record $((NOW + 1500)) $NOW)}"
dec=$(decide_at "$NOW")
expect_eq "CodeRabbit back in 3 min (codeant late): request" "$(jq -r '.skip' <<<"$dec")" "false"
state_with_av "{\"coderabbit\":$(av_record $((NOW + 180)) $NOW),\"codeant\":$(av_record $((NOW + 180)) $NOW)}"
dec=$(decide_at "$NOW")
expect_eq "both back in 3 min: request" "$(jq -r '.skip' <<<"$dec")" "false"
expect_eq "both back in 3 min: reviewer reason is answers_within_window" \
  "$(jq -r '.reviewers.coderabbit.why' <<<"$dec")" "answers_within_window"

# --- Decide: stale record -> request -----------------------------------------------------
state_with_av "{\"coderabbit\":$(av_record $((NOW - 30)) $((NOW - 1500))),\"codeant\":$(av_record $((NOW + 1500)) $NOW)}"
dec=$(decide_at "$NOW")
expect_eq "stale CodeRabbit record (past next-available): request" "$(jq -r '.skip' <<<"$dec")" "false"
expect_eq "stale CodeRabbit record is reported as record_past" "$(jq -r '.reviewers.coderabbit.why' <<<"$dec")" "record_past"

# --- Decide: unreadable records -> request -----------------------------------------------
state_with_av '"garbage"'
dec=$(decide_at "$NOW")
expect_eq "non-object review_availability: request" "$(jq -r '.skip' <<<"$dec")" "false"
printf '{"review_availability": {"coderabbit": {"next_available_epoch": "soon"}}' > "$STATE_FILE"
dec=$(decide_at "$NOW")
expect_eq "malformed state file: request (state unreadable)" "$(jq -r '.skip' <<<"$dec")" "false"
state_with_av "{\"coderabbit\":{\"next_available_epoch\":\"soon\"},\"codeant\":$(av_record $((NOW + 1500)) $NOW)}"
dec=$(decide_at "$NOW")
expect_eq "malformed next-available value: request" "$(jq -r '.skip' <<<"$dec")" "false"
state_with_av "{\"coderabbit\":$(av_record $((NOW + 1200)) $NOW)}"
dec=$(decide_at "$NOW")
expect_eq "only CodeRabbit known limited (CodeAnt unknown): request" "$(jq -r '.skip' <<<"$dec")" "false"
expect_eq "unknown CodeAnt reads as no_record" "$(jq -r '.reviewers.codeant.why' <<<"$dec")" "no_record"

# --- Record: CodeRabbit banner writes a parsed time; unparseable writes nothing -----------
rm -f "$STATE_FILE"
T=$(iso $((NOW - 60)))
jq -cn --arg t "$T" '[{user:{login:"coderabbitai[bot]"},
  body:"**Review limit reached**\n**Next review available in:** **20 minutes**", created_at:$t, updated_at:$t}]' > "$TMP/banner.json"
out=$("$AV" record --repo o/r --pr 7 < "$TMP/banner.json") && rc=0 || rc=$?
expect_eq "record: banner accepted (exit 0)" "$rc" "0"
expect_eq "record: CodeRabbit written" "$(jq -c '.written' <<<"$out")" '["coderabbit"]'
expect_eq "record: next-available = banner time + 20 min" \
  "$(jq -r '.review_availability.coderabbit.next_available_epoch' "$STATE_FILE")" "$(( $(jq -rn --arg t "$T" '$t | fromdateiso8601') + 1200 ))"
expect_eq "record: source PR and repo kept" "$(jq -r '.review_availability.coderabbit.source_pr' "$STATE_FILE")" "7"

rm -f "$STATE_FILE"
jq -cn --arg t "$T" '[{user:{login:"coderabbitai[bot]"},
  body:"**Review limit reached** and then nothing readable about when", created_at:$t, updated_at:$t}]' > "$TMP/nowindow.json"
out=$("$AV" record --repo o/r --pr 7 < "$TMP/nowindow.json")
expect_eq "record: unparseable notice writes nothing" "$(jq -c '.written' <<<"$out")" "[]"
expect_eq "record: no state file created for an unparseable notice" "$(test -f "$STATE_FILE" && echo yes || echo no)" "no"

# A newer statement on file outranks an older notice (no overwrite with an older time).
state_with_av "{\"coderabbit\":$(av_record $((NOW + 3000)) $((NOW + 100)))}"
out=$("$AV" record --repo o/r --pr 8 < "$TMP/banner.json")
expect_eq "record: older notice does not overwrite a newer one" \
  "$(jq -r '.review_availability.coderabbit.next_available_epoch' "$STATE_FILE")" "$((NOW + 3000))"

out=$(printf 'not json' | "$AV" record --repo o/r --pr 7 2>/dev/null) && rc=0 || rc=$?
expect_eq "record: malformed comments exit 4" "$rc" "4"

# --- Mark-skip and check-skip ------------------------------------------------------------
state_with_av "{\"coderabbit\":$(av_record $((NOW + 1200)) $NOW),\"codeant\":$(av_record $((NOW + 1500)) $NOW)}"
"$AV" mark-skip --repo o/r --pr 9 --head aaa111 --reason "no_reviewer_available_until x" >/dev/null
expect_eq "mark-skip: skip recorded on the PR (repo-scoped)" \
  "$(jq -r '.repos["o/r"].prs["9"].review_request_skip.head_sha' "$STATE_FILE")" "aaa111"
out=$("$AV" check-skip --repo o/r --pr 9 --head aaa111 --window-s "$WIN" --now "$NOW")
expect_eq "check-skip: same HEAD, still in force: applies" "$(jq -r '.applies' <<<"$out")" "true"
out=$("$AV" check-skip --repo o/r --pr 9 --head bbb222 --window-s "$WIN" --now "$NOW")
expect_eq "check-skip: other HEAD does not apply" "$(jq -r '.applies' <<<"$out")" "false"
out=$("$AV" check-skip --repo o/r --pr 9 --head aaa111 --window-s "$WIN" --now $((NOW + 1400)))
expect_eq "check-skip: reviewer back in time since the skip (CodeRabbit at +1200, now +1400): does not apply" \
  "$(jq -r '.applies' <<<"$out")" "false"
out=$("$AV" check-skip --repo o/r --pr 9 --head aaa111 --window-s "$WIN" --now $((NOW + 60)))
expect_eq "check-skip: still unavailable a minute later: applies" "$(jq -r '.applies' <<<"$out")" "true"

state_with_av "{\"coderabbit\":$(av_record $((NOW + 180)) $NOW),\"codeant\":$(av_record $((NOW + 180)) $NOW)}"
out=$("$AV" check-skip --repo o/r --pr 9 --head aaa111 --window-s "$WIN" --now "$NOW")
expect_eq "check-skip: record no longer justifies the skip: does not apply" "$(jq -r '.applies' <<<"$out")" "false"

printf '{"schema_version":1' > "$STATE_FILE"
out=$("$AV" check-skip --repo o/r --pr 9 --head aaa111 --window-s "$WIN" --now "$NOW")
expect_eq "check-skip: unreadable state fails closed" "$(jq -r '.applies' <<<"$out")" "false"

# --- Usage ---------------------------------------------------------------------------------
"$AV" decide --window-s 0 >/dev/null 2>&1 && rc=0 || rc=$?
expect_eq "decide: zero window is a usage error" "$rc" "2"
"$AV" bogus >/dev/null 2>&1 && rc=0 || rc=$?
expect_eq "unknown subcommand is a usage error" "$rc" "2"

echo
echo "review-availability tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
