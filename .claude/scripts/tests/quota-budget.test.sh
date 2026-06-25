#!/usr/bin/env bash
# Offline test for the /quota tracker (issue #458).
# Exercises quota-usage-hook.sh (cost + de-dup) and quota-budget.sh (today sum,
# EOD projection, --check exhaustion, --date past-day) in a temporary HOME.
# Requires python3 + jq + git.
set -euo pipefail

TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME"; }
trap cleanup EXIT

export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/quota-usage-hook.sh"
BUDGET="$REPO_ROOT/.claude/scripts/quota-budget.sh"

export QUOTA_CONFIG="$REPO_ROOT/quota-config.json"
export QUOTA_USAGE_LOG="$HOME/.claude/quota-usage.log"
export QUOTA_STATE_DIR="$HOME/.claude/quota-usage.d"
export QUOTA_STATE_FILE="$HOME/.claude/session-state.json"

fail() { echo "FAIL: $1" >&2; exit 1; }
# Numeric equality (tolerates jq 1.7 literal preservation like "0.0" vs "0").
numeq() { python3 -c "import sys; sys.exit(0 if abs(float('$1')-float('$2'))<1e-9 else 1)"; }

TODAY="$(TZ='America/New_York' date +%F)"
TRANSCRIPT="$TMP_HOME/transcript.jsonl"

# --- 1. Hook costs an opus response and writes one TSV line ---
printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' >> "$TRANSCRIPT"
printf '%s\n' '{"type":"assistant","uuid":"u1","message":{"id":"msg_A","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' >> "$TRANSCRIPT"
HOOK_INPUT="$(printf '{"session_id":"sess-test","transcript_path":"%s","tool_name":"Bash"}' "$TRANSCRIPT")"

printf '%s' "$HOOK_INPUT" | "$HOOK" >/dev/null
LINES=$(wc -l < "$QUOTA_USAGE_LOG" | tr -d ' ')
[ "$LINES" = "1" ] || fail "expected 1 ledger line after first fire, got $LINES"

COST_A=$(awk -F'\t' 'NR==1{print $10}' "$QUOTA_USAGE_LOG")
# opus: 1M*15 + 0.1M*75 = 15 + 7.5 = 22.5
[ "$COST_A" = "22.500000" ] || fail "opus cost wrong: $COST_A (expected 22.500000)"
ETCOL=$(awk -F'\t' 'NR==1{print $2}' "$QUOTA_USAGE_LOG")
[ "$ETCOL" = "$TODAY" ] || fail "et_date column wrong: $ETCOL (expected $TODAY)"

# --- 2. De-dup: re-firing the same message must not add a line ---
printf '%s' "$HOOK_INPUT" | "$HOOK" >/dev/null
LINES=$(wc -l < "$QUOTA_USAGE_LOG" | tr -d ' ')
[ "$LINES" = "1" ] || fail "de-dup failed: expected 1 line, got $LINES"

# --- 3. A new assistant message is costed (sonnet, with cache read) ---
printf '%s\n' '{"type":"assistant","uuid":"u2","message":{"id":"msg_B","model":"claude-sonnet-4-6","usage":{"input_tokens":2000000,"output_tokens":50000,"cache_creation_input_tokens":0,"cache_read_input_tokens":1000000}}}' >> "$TRANSCRIPT"
printf '%s' "$HOOK_INPUT" | "$HOOK" >/dev/null
LINES=$(wc -l < "$QUOTA_USAGE_LOG" | tr -d ' ')
[ "$LINES" = "2" ] || fail "expected 2 ledger lines, got $LINES"
COST_B=$(awk -F'\t' 'NR==2{print $10}' "$QUOTA_USAGE_LOG")
# sonnet: 2M*3 + 0.05M*15 + 1M*0.30 = 6 + 0.75 + 0.30 = 7.05
[ "$COST_B" = "7.050000" ] || fail "sonnet cost wrong: $COST_B (expected 7.050000)"

# --- 4. quota-budget.sh sums today and projects EOD ---
SNAP="$("$BUDGET" --project)"
SPEND=$(printf '%s' "$SNAP" | jq -r '.spend_usd')
numeq "$SPEND" "29.55" || fail "today spend wrong: $SPEND (expected 29.55)"
RESP=$(printf '%s' "$SNAP" | jq -r '.responses')
[ "$RESP" = "2" ] || fail "responses wrong: $RESP (expected 2)"
PROJ=$(printf '%s' "$SNAP" | jq -r '.projected_eod_usd')
# projection = spend / fraction_of_day_elapsed  >= spend
python3 -c "import sys; sys.exit(0 if float('$PROJ') >= float('$SPEND') else 1)" \
  || fail "projection $PROJ should be >= spend $SPEND"

# --- 5. session-state.json got the cached snapshot ---
[ -f "$QUOTA_STATE_FILE" ] || fail "session-state.json not written"
SS_SPEND=$(jq -r '.quota_daily.spend_usd' "$QUOTA_STATE_FILE")
numeq "$SS_SPEND" "29.55" || fail "session-state quota_daily.spend_usd wrong: $SS_SPEND"

# --- 6. --check exits 1 when spend >= cap ---
set +e
"$BUDGET" --check --cap 10 --no-state >/dev/null
RC=$?
set -e
[ "$RC" = "1" ] || fail "--check with low cap should exit 1, got $RC"

set +e
"$BUDGET" --check --cap 1000 --no-state >/dev/null
RC=$?
set -e
[ "$RC" = "0" ] || fail "--check under cap should exit 0, got $RC"

# --- 7. --date for a past day reports no projection inflation (fraction 1.0) ---
SNAP_PAST="$("$BUDGET" --date 2000-01-01 --no-state)"
PAST_SPEND=$(printf '%s' "$SNAP_PAST" | jq -r '.spend_usd')
numeq "$PAST_SPEND" "0" || fail "empty past day should report 0 spend, got $PAST_SPEND"
PAST_FRAC=$(printf '%s' "$SNAP_PAST" | jq -r '.fraction_of_day_elapsed')
numeq "$PAST_FRAC" "1" || fail "past day fraction should be 1, got $PAST_FRAC"

echo "OK: quota tracker test passed (hook cost + de-dup, budget sum/projection/check/date, session-state cache)"
