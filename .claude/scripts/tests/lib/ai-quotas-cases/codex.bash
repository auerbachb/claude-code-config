#!/usr/bin/env bash
# Source-only quota fixture group: codex. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 14. the codex HTTP fallback, and only when app-server is unavailable ----

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config "$(account_json codex codex-one@example.com "$X1")"
run --json
check_eq "$(field_of codex-one@example.com "7-day" source)" "app-server" \
  "with app-server available, no HTTP call is made"
check_eq "$(grep -c chatgpt "$STUB_CURL_LOG" 2>/dev/null || true)" "0" \
  "control(-): the fallback endpoint is not touched on the app-server path"

# Remove the app-server fixture: the stub then exits non-zero, which is what
# "app-server unavailable" looks like from the reader's side.
rm -f "$X1/rate-limits.json"
jq -n --argjson week "$WEEK_RESET" \
  '{rate_limits: {planType: "pro",
                  primary: {usedPercent: 88, windowDurationMins: 10080, resetsAt: $week},
                  secondary: null}}' > "$STUB_CHATGPT_BODY"
run --json
check_eq "$(field_of codex-one@example.com "7-day" source)" "http" \
  "an unavailable app-server falls back to the HTTP path"
check_eq "$(field_of codex-one@example.com "7-day" used_pct)" "88" \
  "and renders the fallback's figures"
check_contains "$(field_of codex-one@example.com "7-day" detail)" "app-server" \
  "the note says why the fallback was used"
# …and says WHICH failure it was. The stub exits non-zero without answering,
# which is not a timeout; reporting one would send the reader after a hang
# that never happened.
check_contains "$(field_of codex-one@example.com "7-day" detail)" "exited without answering" \
  "a server that exited is reported as an exit, not as a timeout"
check_not_contains "$(field_of codex-one@example.com "7-day" detail)" "did not answer within" \
  "control(-): the timeout wording is not used for a server that exited"

# The HTTP 200 body below was captured through the existing reader on
# 2026-11-07, then stripped of identifiers and opaque account metadata.
# Only this first case is a real wire fixture; mutations below are controls.
HTTP_WIRE_FIXTURE="$ROOT/.claude/scripts/tests/fixtures/codex-wham-usage-2026-11-07.json"
cp "$HTTP_WIRE_FIXTURE" "$STUB_CHATGPT_BODY"
run --json --five-hour
check_eq "$(field_of codex-one@example.com "7-day" source)" "http" "captured snake_case body renders through HTTP"
check_eq "$(field_of codex-one@example.com "7-day" used_pct)" "30" "captured weekly usage survives wire normalization"
check_eq "$(field_of codex-one@example.com "7-day" resets_at_epoch)" "1794531249" "absolute wire reset wins over relative reset"
check_eq "$(field_of codex-one@example.com "5-hour" used_pct)" "null" "absent secondary window does not invent short-window usage"
check_eq "$(field_of codex-one@example.com "7-day" credits_remaining_usd)" "null" "unlabelled wallet balance never becomes USD"

jq 'del(.rate_limit.primary_window.reset_at)' "$HTTP_WIRE_FIXTURE" > "$STUB_CHATGPT_BODY"
run --json
check_eq "$(field_of codex-one@example.com "7-day" resets_at_epoch)" "$(( NOW + 437052 ))" "relative wire reset uses the reader clock"
jq '.rate_limit.primary_window.used_percent="0" | .rate_limit.primary_window.reset_at=null | .rate_limit.primary_window.reset_after_seconds=0' "$HTTP_WIRE_FIXTURE" > "$STUB_CHATGPT_BODY"
run --json
check_eq "$(field_of codex-one@example.com "7-day" used_pct)" "0" "zero numeric-string usage is a valid reported value"
check_eq "$(field_of codex-one@example.com "7-day" resets_at_epoch)" "$NOW" "zero relative reset is immediate rather than missing"
jq 'del(.rate_limit.primary_window.limit_window_seconds)' "$HTTP_WIRE_FIXTURE" > "$STUB_CHATGPT_BODY"
run --json
check_eq "$(field_of codex-one@example.com "window" used_pct)" "30" "missing duration keeps usage under an honest generic label"
for wire_bad in 'true' 'null' '-1' '"unknown"'; do
  jq --argjson bad "$wire_bad" '.rate_limit.primary_window.used_percent=$bad' "$HTTP_WIRE_FIXTURE" > "$STUB_CHATGPT_BODY"
  run --json --five-hour
  check_eq "$(rows_for codex-one@example.com | grep -c '^ok$')" "0" "invalid wire usage $wire_bad cannot become a successful report"
done

# A failed account-wide read (the 7-day placeholder) still shows a saved 5-hour
# reading as last known, labelled with its own window (#2280 review).
CODEX_LKD="$TMP/codex-last-known"
export AI_QUOTAS_LAST_KNOWN_DIR="$CODEX_LKD"
rm -rf "$CODEX_LKD"
printf '%s' '{"accounts":[{"provider":"codex","label":"codex-one@example.com","fetched_at_epoch":'"$NOW"',"fetched_at_et":"fixture","source":"live: fixture","rows":[{"window":"5-hour","pool":null,"used_pct":33,"resets_at_epoch":null,"resets":null,"overage":null}]}]}' \
  | python3 -I "$(cd "$(dirname "$SCRIPT")" && pwd)/lib/quotas-last-known.py" record --dir "$CODEX_LKD"
printf '%s' '{"not": "a usage body"' > "$STUB_CHATGPT_BODY"
run --json --five-hour
check_eq "$(field_of codex-one@example.com "5-hour" last_known_used_pct)" "33" "a saved 5-hour reading shows under a failed account-wide placeholder"
check_eq "$(rows_for codex-one@example.com | grep -c '^ok$')" "0" "the failed read is not reported as ok"
run
check_contains "$OUT" "33% (last known" "the text report labels the saved 5-hour reading as last known"
cp "$HTTP_WIRE_FIXTURE" "$STUB_CHATGPT_BODY"
unset AI_QUOTAS_LAST_KNOWN_DIR
