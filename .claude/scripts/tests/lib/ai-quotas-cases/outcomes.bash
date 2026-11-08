#!/usr/bin/env bash
# Source-only quota fixture group: outcomes. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- read outcome ledger (#1883) ---------------------------------------------
reset_state
mkdir -p "$TMP/empty-outcomes-profile"
write_config "$(account_json claude outcomes-fixture "$TMP/empty-outcomes-profile")"
run --json
OUTCOMES_LEDGER="$CASE_HOME/.claude/ai-quotas-history.outcomes.jsonl"
check_eq "$(jq -s 'length' "$OUTCOMES_LEDGER")" "1" "one outcome for an empty-profile account attempt"
check_eq "$(jq -r '.status' "$OUTCOMES_LEDGER")" "logged_out" "empty profile outcome is logged_out"
check_eq "$(jq -r '.source' "$OUTCOMES_LEDGER")" "credential-store" "missing credentials identify their local preflight source"
check_eq "$(printf '%s' "$DOC" | jq -r '.account_reliability[0].streak_count')" "1" "first failure has streak one"
run --json --quiet
check_eq "$(printf '%s' "$DOC" | jq -r '.account_reliability[0].streak_count')" "2" "second failure has streak two"
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.trigger')" "scheduled" "quiet all-failure attempt is scheduled"
check_eq "$(printf '%s' "$DOC" | jq -r '.last_scheduled_snapshot_at')" "null" "failed scheduled reads do not change success freshness"
run --account no-match --json
check_eq "$(jq -s 'length' "$OUTCOMES_LEDGER")" "2" "unmatched account filter records no attempt"
check_eq "$(printf '%s' "$DOC" | jq -r '.account_reliability | if type == "array" then length else "missing" end')" "0" "unmatched filter has empty reliability array"
C1="$(seed_claude_profile outcomes-fixture Claude-outcomes-service)"
write_config "$(account_json claude outcomes-fixture "$C1" Claude-outcomes-service)"
run --json --five-hour
check_eq "$(jq -s 'length' "$OUTCOMES_LEDGER")" "3" "multi-window success records one account attempt"
check_eq "$(printf '%s' "$DOC" | jq -r '.account_reliability[0].streak_count')" "0" "success resets consecutive-failure streak"
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.error_class')" "null" "success outcome has null error class"
if grep -Eq 'sk-ant-|eyJ|FAKE-CODEX|WorkosCursorSessionToken' "$OUTCOMES_LEDGER"; then
  bad "outcomes ledger leaked credential-shaped fixture strings"
else ok "outcomes ledger has no credential-shaped fixture strings"; fi
printf 'ratelimit' > "$STUB_ANTHROPIC_MODE"
run --json
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.status')" "rate_limited" "HTTP 429 produces rate_limited outcome"
printf 'shape' > "$STUB_ANTHROPIC_MODE"
printf 'not-json' > "$STUB_ANTHROPIC_BODY"
run --json
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.status')" "parse_error" "HTTP 200 non-JSON produces parse_error outcome"
run
check_contains "$OUT" "RELIABILITY" "table displays account reliability footer"
check_contains "$OUT" "7d" "reliability footer names seven-day window"
run --quiet
check_not_contains "$OUT" "RELIABILITY" "quiet table omits reliability footer"
printf 'timeout' > "$STUB_ANTHROPIC_MODE"
run --json
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.status')" "timeout" "curl exit 28 is an explicit timeout outcome"
printf 'ok' > "$STUB_ANTHROPIC_MODE"
printf '{"seven_day":{"utilization":"invalid-number"}}' > "$STUB_ANTHROPIC_BODY"
run --json
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.status')" "parse_error" "valid JSON with malformed numeric usage is parse_error"
