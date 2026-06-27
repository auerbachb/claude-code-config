#!/usr/bin/env bash
# Offline test for the /quota tracker (issue #458).
# Exercises quota-usage-hook.sh (raw-count ledger + de-dup + graceful no-op),
# quota-budget.sh (--check sum/projection/thresholds, --config, --reset, --week,
# --date past-day), the spec session-state schema, and quota-stop-notify.sh.
# Requires python3 + jq + git.
set -euo pipefail

TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME"; }
trap cleanup EXIT

export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/quota-usage-hook.sh"
STOP_HOOK="$REPO_ROOT/.claude/hooks/quota-stop-notify.sh"
BUDGET="$REPO_ROOT/.claude/scripts/quota-budget.sh"

export QUOTA_CONFIG="$REPO_ROOT/quota-config.json"
export QUOTA_USAGE_LOG="$HOME/.claude/quota-usage.log"
export QUOTA_STATE_DIR="$HOME/.claude/quota-usage.d"
export QUOTA_STATE_FILE="$HOME/.claude/session-state.json"

fail() { echo "FAIL: $1" >&2; exit 1; }
numeq() { python3 -c "import sys; sys.exit(0 if abs(float('$1')-float('$2'))<1e-9 else 1)"; }

TODAY="$(TZ='America/New_York' date +%F)"
TRANSCRIPT="$TMP_HOME/transcript.jsonl"

# --- 1. Hook writes one 7-col TSV line (counts + model + session only) ---
printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' >> "$TRANSCRIPT"
printf '%s\n' '{"type":"assistant","uuid":"u1","message":{"id":"msg_A","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' >> "$TRANSCRIPT"
HOOK_INPUT="$(printf '{"session_id":"sess-test","transcript_path":"%s","tool_name":"Bash"}' "$TRANSCRIPT")"

printf '%s' "$HOOK_INPUT" | "$HOOK" >/dev/null
LINES=$(wc -l < "$QUOTA_USAGE_LOG" | tr -d ' ')
[ "$LINES" = "1" ] || fail "expected 1 ledger line, got $LINES"
NCOL=$(awk -F'\t' 'NR==1{print NF}' "$QUOTA_USAGE_LOG")
[ "$NCOL" = "7" ] || fail "expected 7 TSV columns, got $NCOL"
# Column order: ts_utc, model, input, output, cache_read, cache_creation, session_id
[ "$(awk -F'\t' 'NR==1{print $2}' "$QUOTA_USAGE_LOG")" = "claude-opus-4-8" ] || fail "model column wrong"
[ "$(awk -F'\t' 'NR==1{print $7}' "$QUOTA_USAGE_LOG")" = "sess-test" ] || fail "session_id column wrong"
# No secrets/prompt text in the ledger
grep -qiE 'content|prompt|"role"|hi' "$QUOTA_USAGE_LOG" && fail "ledger contains unexpected (non-count) content"

# --- 2. De-dup: re-firing the same message must not add a line ---
printf '%s' "$HOOK_INPUT" | "$HOOK" >/dev/null
[ "$(wc -l < "$QUOTA_USAGE_LOG" | tr -d ' ')" = "1" ] || fail "de-dup failed"

# --- 3. New assistant message (sonnet + cache read) is appended ---
printf '%s\n' '{"type":"assistant","uuid":"u2","message":{"id":"msg_B","model":"claude-sonnet-4-6","usage":{"input_tokens":2000000,"output_tokens":50000,"cache_creation_input_tokens":0,"cache_read_input_tokens":1000000}}}' >> "$TRANSCRIPT"
printf '%s' "$HOOK_INPUT" | "$HOOK" >/dev/null
[ "$(wc -l < "$QUOTA_USAGE_LOG" | tr -d ' ')" = "2" ] || fail "expected 2 ledger lines"

# --- 4. Graceful no-op when transcript has no usage block (payload gap) ---
NOUSE="$TMP_HOME/nouse.jsonl"
printf '%s\n' '{"type":"assistant","uuid":"x","message":{"id":"msg_X","model":"claude-opus-4-8"}}' >> "$NOUSE"
NOUSE_INPUT="$(printf '{"session_id":"sess-nouse","transcript_path":"%s","tool_name":"Bash"}' "$NOUSE")"
printf '%s' "$NOUSE_INPUT" | "$HOOK" >/dev/null
[ "$(wc -l < "$QUOTA_USAGE_LOG" | tr -d ' ')" = "2" ] || fail "no-op path wrote a line it should not have"

# --- 5. --check sums today + projects EoD + classifies ---
# opus: 1M*15 + 0.1M*75 = 22.5 ; sonnet: 2M*3 + 0.05M*15 + 1M*0.30 = 7.05 ; total 29.55
SNAP="$("$BUDGET" --check --cap 100)"
numeq "$(printf '%s' "$SNAP" | jq -r '.estimated_usd')" "29.55" || fail "today spend wrong: $(printf '%s' "$SNAP" | jq -r .estimated_usd)"
[ "$(printf '%s' "$SNAP" | jq -r '.responses')" = "2" ] || fail "responses wrong"
numeq "$(printf '%s' "$SNAP" | jq -r '.budget_usd')" "100" || fail "budget_usd wrong"
PROJ=$(printf '%s' "$SNAP" | jq -r '.projected_eod_usd')
SPEND=$(printf '%s' "$SNAP" | jq -r '.estimated_usd')
python3 -c "import sys; sys.exit(0 if float('$PROJ') >= float('$SPEND') else 1)" || fail "projection < spend"
# Top model by spend should be opus (22.5 > 7.05)
[ "$(printf '%s' "$SNAP" | jq -r '.by_model[0].model')" = "claude-opus-4-8" ] || fail "by_model not sorted by spend"

# --- 6. Threshold classification (small cap drives status up) ---
# cap 20 -> spend 29.55 already over; projected even higher -> critical
[ "$(printf '%s' "$SNAP" | jq -r '.status')" != "null" ] || fail "status missing"
SNAP_CRIT="$("$BUDGET" --check --cap 20 --no-state)"
[ "$(printf '%s' "$SNAP_CRIT" | jq -r '.status')" = "critical" ] || fail "expected critical status at cap 20"
[ "$(printf '%s' "$SNAP_CRIT" | jq -r '.over_cap')" = "true" ] || fail "expected over_cap true at cap 20"
# Observational: never exits non-zero even when over cap
"$BUDGET" --check --cap 0.01 --no-state >/dev/null || fail "tiny cap should not block (exit non-zero)"

# --- 7. session-state quota_daily uses the spec schema ---
[ -f "$QUOTA_STATE_FILE" ] || fail "session-state.json not written"
for k in date input_tokens output_tokens cache_read_tokens cache_creation_tokens estimated_usd budget_usd; do
  [ "$(jq -r ".quota_daily | has(\"$k\")" "$QUOTA_STATE_FILE")" = "true" ] || fail "quota_daily missing field: $k"
done
numeq "$(jq -r '.quota_daily.estimated_usd' "$QUOTA_STATE_FILE")" "29.55" || fail "quota_daily.estimated_usd wrong"

# --- 8. --config prints cap + thresholds + stop_hook_threshold ---
CFG="$("$BUDGET" --config)"
numeq "$(printf '%s' "$CFG" | jq -r '.thresholds.info')" "0.60" || fail "config info threshold wrong"
numeq "$(printf '%s' "$CFG" | jq -r '.stop_hook_threshold')" "0.60" || fail "stop_hook_threshold wrong"

# --- 9. --reset zeroes today's cached counter (log untouched) ---
"$BUDGET" --reset --cap 100 >/dev/null
numeq "$(jq -r '.quota_daily.estimated_usd' "$QUOTA_STATE_FILE")" "0" || fail "reset did not zero quota_daily"
[ "$(wc -l < "$QUOTA_USAGE_LOG" | tr -d ' ')" = "2" ] || fail "reset must not modify the durable ledger"

# --- 10. --week aggregates 7 zero-filled ET days incl. today ---
WK="$("$BUDGET" --week --cap 100 --no-state)"
[ "$(printf '%s' "$WK" | jq -r '.days | length')" = "7" ] || fail "week should have 7 days"
[ "$(printf '%s' "$WK" | jq -r '.days[-1].date')" = "$TODAY" ] || fail "week last day should be today"
numeq "$(printf '%s' "$WK" | jq -r '.total_usd')" "29.55" || fail "week total wrong: $(printf '%s' "$WK" | jq -r .total_usd)"

# --- 11. --date for an empty past day reports 0 / fraction 1 ---
PAST="$("$BUDGET" --check --date 2000-01-01 --no-state)"
numeq "$(printf '%s' "$PAST" | jq -r '.estimated_usd')" "0" || fail "empty past day non-zero spend"
numeq "$(printf '%s' "$PAST" | jq -r '.fraction_of_day_elapsed')" "1" || fail "past day fraction != 1"

# --- 12. Stop hook emits a line when over threshold, silent when under ---
# Drive the hook with temp configs: a tiny cap (over threshold -> emit) and a
# huge cap (under threshold -> silent).
TINY_CFG="$TMP_HOME/tiny.json"; jq '.daily_cap_usd = 1 | .stop_hook_threshold = 0.6' "$QUOTA_CONFIG" > "$TINY_CFG"
BIG_CFG="$TMP_HOME/big.json"; jq '.daily_cap_usd = 100000 | .stop_hook_threshold = 0.6' "$QUOTA_CONFIG" > "$BIG_CFG"
EMIT="$(printf '{}' | QUOTA_CONFIG="$TINY_CFG" "$STOP_HOOK" 2>/dev/null || true)"
printf '%s' "$EMIT" | jq -e '.hookSpecificOutput.additionalContext | test("\\[quota\\]")' >/dev/null || fail "stop hook should emit over threshold"
SILENT="$(printf '{}' | QUOTA_CONFIG="$BIG_CFG" "$STOP_HOOK" 2>/dev/null || true)"
[ -z "$SILENT" ] || fail "stop hook should be silent under threshold, got: $SILENT"

# --- 13. Projection floor: tiny elapsed fraction must not explode EoD (BugBot) ---
# Pin "now" to one minute after ET midnight (EDT = UTC-4 on 2026-06-26).
FLOOR_LOG="$TMP_HOME/floor.log"
printf '%s\tclaude-opus-4-8\t100000\t0\t0\t0\tSf\n' "2026-06-26T04:00:30Z" >> "$FLOOR_LOG"
FSNAP="$(QUOTA_USAGE_LOG="$FLOOR_LOG" QUOTA_FAKE_NOW="2026-06-26T04:01:00Z" "$BUDGET" --check --cap 100 --no-state)"
# spend = 100000*15/1e6 = 1.5 ; floored fraction = 1/24 -> projected = 1.5*24 = 36.0
numeq "$(printf '%s' "$FSNAP" | jq -r '.estimated_usd')" "1.5" || fail "floor test spend wrong"
numeq "$(printf '%s' "$FSNAP" | jq -r '.projected_eod_usd')" "36" || fail "projection not floored: $(printf '%s' "$FSNAP" | jq -r .projected_eod_usd)"
# true elapsed fraction is still reported tiny (transparency), not the floor
python3 -c "import sys; sys.exit(0 if float('$(printf '%s' "$FSNAP" | jq -r '.fraction_of_day_elapsed')') < 0.01 else 1)" \
  || fail "fraction_of_day_elapsed should report the true tiny value"

# --- 14. Marker committed before append: marker-write failure must not double-count ---
MK_DIR="$TMP_HOME/marker.d"; mkdir -p "$MK_DIR"
MK_TS="$TRANSCRIPT"  # reuse transcript with msg_A/msg_B; use a fresh session id
MK_INPUT="$(printf '{"session_id":"sess-marker","transcript_path":"%s","tool_name":"Bash"}' "$MK_TS")"
MK_LOG="$TMP_HOME/marker.log"
# First fire writes one line and a marker.
printf '%s' "$MK_INPUT" | QUOTA_USAGE_LOG="$MK_LOG" QUOTA_STATE_DIR="$MK_DIR" "$HOOK" >/dev/null
[ "$(wc -l < "$MK_LOG" | tr -d ' ')" = "1" ] || fail "marker test: first fire should write 1 line"
# Make the marker dir non-writable so a NEW message cannot commit its marker.
# Mutate the transcript so the latest assistant id changes (msg_C).
printf '%s\n' '{"type":"assistant","uuid":"u3","message":{"id":"msg_C","model":"claude-opus-4-8","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' >> "$MK_TS"
chmod 0555 "$MK_DIR"
printf '%s' "$MK_INPUT" | QUOTA_USAGE_LOG="$MK_LOG" QUOTA_STATE_DIR="$MK_DIR" "$HOOK" >/dev/null
chmod 0755 "$MK_DIR"
# Because the marker could not be committed, the append must be skipped (no double-count).
[ "$(wc -l < "$MK_LOG" | tr -d ' ')" = "1" ] || fail "marker-write failure must skip append (got $(wc -l < "$MK_LOG" | tr -d ' ') lines)"

echo "OK: quota tracker test passed (hook 7-col ledger + de-dup + no-op + marker-before-append, budget check/config/reset/week/date + thresholds + projection floor, spec session-state, stop hook)"
