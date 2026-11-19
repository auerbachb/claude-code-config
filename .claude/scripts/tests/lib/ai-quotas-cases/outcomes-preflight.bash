#!/usr/bin/env bash
# Source-only quota fixture group: outcomes-preflight. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

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
check_eq "$(jq -c 'select(.skip_reason == null)' "$OUTCOMES_LEDGER" | tail -n 1 | jq -r '.status')" "logged_out" "missing Codex access token records logged_out"
check_eq "$(jq -c 'select(.skip_reason == null)' "$OUTCOMES_LEDGER" | tail -n 1 | jq -r '.source')" "credential-store" "missing Codex fallback token records its credential preflight"
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
check_eq "$(jq -c 'select(.skip_reason == null)' "$OUTCOMES_LEDGER" | tail -n 1 | jq -r '.status')" "logged_out" "missing Claude refresh token records logged_out"
check_eq "$(jq -c 'select(.skip_reason == null)' "$OUTCOMES_LEDGER" | tail -n 1 | jq -r '.source')" "credential-store" "missing Claude refresh token records its credential preflight"
check_eq "$(wc -l < "$STUB_CURL_LOG" | tr -d ' ')" "0" "missing Claude refresh token makes no HTTP request"

