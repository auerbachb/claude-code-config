#!/usr/bin/env bash
# Source-only quota fixture group: outcomes-protocol. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

reset_state
X1="$(seed_codex_profile outcomes-codex "$(codex_snapshot_primary_weekly)")"
write_config "$(account_json codex outcomes-codex "$X1")"
rm -f "$X1/rate-limits.json"
printf '{"primary":{"usedPercent":28,"windowDurationMins":10080}}' > "$STUB_CHATGPT_BODY"
run --json
OUTCOMES_LEDGER="$CASE_HOME/.claude/ai-quotas-history.outcomes.jsonl"
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.source')" "http" "recovered Codex fallback records actual HTTP source"


# Empty display placeholders do not establish read success. Any actual usable
# window does, even if another returned window has a malformed percentage.
reset_state
X1="$(seed_codex_profile outcomes-codex '{"rateLimits":{"primary":{"windowDurationMins":10080}}}')"
write_config "$(account_json codex outcomes-codex "$X1")"
run --json --five-hour
OUTCOMES_LEDGER="$CASE_HOME/.claude/ai-quotas-history.outcomes.jsonl"
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.status')" "parse_error" "empty Codex short-window placeholder cannot create success"
printf '{"rateLimits":{"primary":{"usedPercent":71,"windowDurationMins":10080},"secondary":{"usedPercent":"invalid","windowDurationMins":300}}}' > "$X1/rate-limits.json"
run --json --five-hour
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.status')" "ok" "valid weekly percentage survives a malformed short window"
printf '{"rateLimits":{"primary":{"usedPercent":"invalid","windowDurationMins":10080},"secondary":{"usedPercent":9,"windowDurationMins":300}}}' > "$X1/rate-limits.json"
run --json --five-hour
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.status')" "ok" "valid short-window percentage establishes account success"

# Refresh-body syntax and HTTP failures remain distinct, without persisting bodies.
reset_state
C1="$(seed_claude_profile outcomes-refresh Claude-outcomes-refresh "$(( (NOW - 100) * 1000 ))")"
write_config "$(account_json claude outcomes-refresh "$C1" Claude-outcomes-refresh)"
printf 'invalid_json' > "$STUB_TOKEN_MODE"
run --json
OUTCOMES_LEDGER="$CASE_HOME/.claude/ai-quotas-history.outcomes.jsonl"
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.status')" "parse_error" "invalid HTTP200 refresh body is parse_error"
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.error_class')" "invalid_json" "refresh syntax error has fixed invalid_json class"
printf 'server' > "$STUB_TOKEN_MODE"
run --json
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.status')" "unreadable" "HTTP500 refresh failure remains unreadable"
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.error_class')" "http_500" "refresh HTTP failure records only numeric status class"

