#!/usr/bin/env bash
# Source-only quota fixture group: codex-duration. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# Independent HTTP fixture for the original duration/secondary-window cases.
reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config "$(account_json codex codex-one@example.com "$X1")"
rm -f "$X1/rate-limits.json"
HTTP_WIRE_FIXTURE="$ROOT/.claude/scripts/tests/fixtures/codex-wham-usage-2026-11-07.json"
for wire_bad in '0' '-60' '60' '61' '1800' '5400' 'true' '"one week"'; do
  jq --argjson bad "$wire_bad" '.rate_limit.primary_window.limit_window_seconds=$bad' "$HTTP_WIRE_FIXTURE" > "$STUB_CHATGPT_BODY"
  run --json
  check_eq "$(rows_for codex-one@example.com)" "unreachable" "invalid wire duration $wire_bad cannot invent a window unit"
done
# A present unsupported short window must not become a claim that the plan
# reports no short window merely because a separate weekly window is valid.
jq '.rate_limit.secondary_window={used_percent:12,limit_window_seconds:5400,reset_after_seconds:600}' "$HTTP_WIRE_FIXTURE" > "$STUB_CHATGPT_BODY"
run --json --five-hour
check_eq "$(rows_for codex-one@example.com)" "unreachable" "present unsupported window cannot be silently presented as absent"
jq '.rate_limit.secondary_window=.rate_limit.primary_window | .rate_limit.primary_window={used_percent:12,limit_window_seconds:18000,reset_after_seconds:600}' "$HTTP_WIRE_FIXTURE" > "$STUB_CHATGPT_BODY"
run --json --five-hour
check_eq "$(field_of codex-one@example.com "7-day" used_pct)" "30" "weekly wire window is selected from secondary by duration"
check_eq "$(field_of codex-one@example.com "5-hour" used_pct)" "12" "short wire window is selected from primary by duration"

# --- 14a. a spaced `"id" : 2` is the same response, not a timeout ------------
# JSON puts no constraint on whitespace around the name separator, so a server
# is free to answer `"id" : 2`. A reader that matches only the compact form
# reads a perfectly good answer as silence, burns the whole CODEX_TIMEOUT, and
# degrades to the HTTP fallback with a timeout note — a wrong number's worth of
# wrong, reported as if the server had hung.

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config "$(account_json codex codex-one@example.com "$X1")"
# The fallback body is deliberately DIFFERENT from the fixture, so an answer
# read off the HTTP path could not be mistaken for the app-server's.
jq -n --argjson week "$WEEK_RESET" \
  '{rate_limits: {planType: "pro",
                  primary: {usedPercent: 11, windowDurationMins: 10080, resetsAt: $week},
                  secondary: null}}' > "$STUB_CHATGPT_BODY"
STUB_CODEX_SPACED_ID=1 run --json
unset STUB_CODEX_SPACED_ID
check_eq "$(field_of codex-one@example.com "7-day" source)" "app-server" \
  "a spaced \`\"id\" : 2\` is still read off app-server, not fallen back on"
check_not_contains "$(field_of codex-one@example.com "7-day" detail)" "did not answer within" \
  "control(-): a spaced id is not reported as a timeout"
check_eq "$(field_of codex-one@example.com "7-day" used_pct)" "71" \
  "control(+): the figures are the fixture's 71, not the HTTP body's 11"

