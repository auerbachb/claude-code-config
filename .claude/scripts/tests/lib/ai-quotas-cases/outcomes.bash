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

# Cursor rate limits use the existing display status and matching ledger status.
reset_state
mkdir -p "$TMP/outcomes-cursor-profile"
write_config "$(account_json cursor outcomes-cursor "$TMP/outcomes-cursor-profile")"
printf 'ratelimit' > "$STUB_CURSOR_MODE"
run --json
OUTCOMES_LEDGER="$CASE_HOME/.claude/ai-quotas-history.outcomes.jsonl"
check_eq "$RC" "0" "Cursor429 fixture reaches the reader"
check_eq "$(printf '%s' "$OUT" | jq -r '.[0].status')" "rate-limited" "Cursor429 report row names the rate limit"
check_eq "$(jq -r 'select(.source == "ide-token") | .status' "$OUTCOMES_LEDGER" | tail -n 1)" "rate_limited" "Cursor429 outcome agrees with the report"

# Credential-only failures in fallback/refresh preflight must not claim HTTP reads.
reset_state
X1="$(seed_codex_profile outcomes-no-access "$(codex_snapshot_primary_weekly)")"
jq 'del(.tokens.access_token)' "$X1/auth.json" > "$TMP/no-access-auth.json"
mv "$TMP/no-access-auth.json" "$X1/auth.json"
rm -f "$X1/rate-limits.json"
write_config "$(account_json codex outcomes-no-access "$X1")"
run --json
OUTCOMES_LEDGER="$CASE_HOME/.claude/ai-quotas-history.outcomes.jsonl"
check_eq "$RC" "0" "missing-access Codex fallback fixture reaches the reader"
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.status')" "logged_out" "missing Codex access token records logged_out"
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.source')" "credential-store" "missing Codex fallback token records its credential preflight"
check_eq "$(wc -l < "$STUB_CURL_LOG" | tr -d ' ')" "0" "missing Codex fallback token makes no HTTP request"

reset_state
C1="$(seed_claude_profile outcomes-no-refresh Claude-outcomes-no-refresh "$(( (NOW - 100) * 1000 ))")"
python3 - <<'NO_REFRESH_FIXTURE'
import json
import os
from pathlib import Path
p = Path(os.environ['STUB_KEYCHAIN_DB'])
rows = []
for line in p.read_text().splitlines():
    service, account, raw = line.split('\t', 2)
    doc = json.loads(raw)
    doc['claudeAiOauth'].pop('refreshToken', None)
    rows.append('\t'.join((service, account, json.dumps(doc, separators=(',', ':')))))
p.write_text('\n'.join(rows) + '\n')
NO_REFRESH_FIXTURE
check_eq "$(keychain_doc Claude-outcomes-no-refresh | jq -r '.claudeAiOauth | has("accessToken") and (has("refreshToken") | not)')" "true" "refresh fixture retains its expired access credential only"
write_config "$(account_json claude outcomes-no-refresh "$C1" Claude-outcomes-no-refresh)"
run --json
OUTCOMES_LEDGER="$CASE_HOME/.claude/ai-quotas-history.outcomes.jsonl"
check_eq "$RC" "0" "missing-refresh Claude fixture reaches the reader"
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.status')" "logged_out" "missing Claude refresh token records logged_out"
check_eq "$(tail -n 1 "$OUTCOMES_LEDGER" | jq -r '.source')" "credential-store" "missing Claude refresh token records its credential preflight"
check_eq "$(wc -l < "$STUB_CURL_LOG" | tr -d ' ')" "0" "missing Claude refresh token makes no HTTP request"

