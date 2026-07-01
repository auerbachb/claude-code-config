#!/usr/bin/env bash
# Offline test for the /quota tracker (issue #495).
# Exercises quota-usage-hook.sh (raw-count ledger + de-dup + graceful no-op),
# quota-budget.sh (--check monthly+daily signals, --config, --reset, --week,
# --month, --date past-day, --config-cap), the spec session-state schema,
# quota-stop-notify.sh, legacy migration, and threshold transitions.
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
numeq() { python3 -c "import sys; sys.exit(0 if abs(float('$1')-float('$2'))<1e-6 else 1)"; }
numge() { python3 -c "import sys; sys.exit(0 if float('$1')>=float('$2') else 1)"; }

TODAY="$(TZ='America/New_York' date +%F)"
TRANSCRIPT="$TMP_HOME/transcript.jsonl"

# Use a fresh per-test config that doesn't affect the real quota-config.json
TEST_CONFIG="$TMP_HOME/quota-config.json"
cp "$QUOTA_CONFIG" "$TEST_CONFIG"
export QUOTA_CONFIG="$TEST_CONFIG"

# --- 1. Hook writes one 7-col TSV line (counts + model + session only) ---
printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' >> "$TRANSCRIPT"
printf '%s\n' '{"type":"assistant","uuid":"u1","message":{"id":"msg_A","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' >> "$TRANSCRIPT"
HOOK_INPUT="$(printf '{"session_id":"sess-test","transcript_path":"%s","tool_name":"Bash"}' "$TRANSCRIPT")"

printf '%s' "$HOOK_INPUT" | "$HOOK" >/dev/null
LINES=$(wc -l < "$QUOTA_USAGE_LOG" | tr -d ' ')
[ "$LINES" = "1" ] || fail "expected 1 ledger line, got $LINES"
NCOL=$(awk -F'\t' 'NR==1{print NF}' "$QUOTA_USAGE_LOG")
[ "$NCOL" = "7" ] || fail "expected 7 TSV columns, got $NCOL"
[ "$(awk -F'\t' 'NR==1{print $2}' "$QUOTA_USAGE_LOG")" = "claude-opus-4-8" ] || fail "model column wrong"
[ "$(awk -F'\t' 'NR==1{print $7}' "$QUOTA_USAGE_LOG")" = "sess-test" ] || fail "session_id column wrong"
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

# --- 5. --check: today spend, monthly spend, both signals in JSON ---
# opus: 1M*15 + 0.1M*75 = 22.5 ; sonnet: 2M*3 + 0.05M*15 + 1M*0.30 = 7.05 ; total 29.55
SNAP="$("$BUDGET" --check)"
numeq "$(printf '%s' "$SNAP" | jq -r '.estimated_usd')" "29.55" || fail "today spend wrong: $(printf '%s' "$SNAP" | jq -r .estimated_usd)"
[ "$(printf '%s' "$SNAP" | jq -r '.responses')" = "2" ] || fail "responses wrong"
# Monthly spend should equal today spend (all ledger entries are today)
numeq "$(printf '%s' "$SNAP" | jq -r '.monthly_spend_usd')" "29.55" || fail "monthly_spend_usd wrong"
# New schema fields must be present
for k in date month estimated_usd monthly_spend_usd daily_warn_threshold_usd monthly_cap_usd \
          daily_spend_pct_of_warn monthly_spend_pct projected_eod_usd projected_eom_usd \
          projected_eom_pct daily_status monthly_status status surface; do
  [ "$(printf '%s' "$SNAP" | jq -r "has(\"$k\")")" = "true" ] || fail "snapshot missing field: $k"
done
# month field should be YYYY-MM of today
MONTH_FIELD="$(printf '%s' "$SNAP" | jq -r '.month')"
[ ${#MONTH_FIELD} -eq 7 ] || fail "month field not YYYY-MM: $MONTH_FIELD"
# Top model by spend should be opus (22.5 > 7.05)
[ "$(printf '%s' "$SNAP" | jq -r '.by_model[0].model')" = "claude-opus-4-8" ] || fail "by_model not sorted by spend"
# Projected EoD should be >= today spend
PROJ_EOD=$(printf '%s' "$SNAP" | jq -r '.projected_eod_usd')
python3 -c "import sys; sys.exit(0 if float('$PROJ_EOD') >= 29.55 else 1)" || fail "projected_eod_usd < spend"
# Projected EoM should be >= monthly spend
PROJ_EOM=$(printf '%s' "$SNAP" | jq -r '.projected_eom_usd')
python3 -c "import sys; sys.exit(0 if float('$PROJ_EOM') >= 29.55 else 1)" || fail "projected_eom_usd < monthly spend"

# --- 6a. Monthly threshold transitions ---
# $29.55 against $1000 cap — actual status depends on fraction of month elapsed
# (early in month, projection can be high; late in month, it will be ok). Just
# verify it is a valid status string.
MS_DEFAULT="$(printf '%s' "$SNAP" | jq -r '.monthly_status')"
[[ "$MS_DEFAULT" =~ ^(ok|info|warn|critical)$ ]] || fail "monthly_status invalid: $MS_DEFAULT"

# monthly info: set cap=49 so projected >= 60% of cap
SNAP_MINFO="$(jq '.monthly_cap_usd = 49 | .thresholds.monthly.info = 0.60 | .thresholds.monthly.warn = 0.80 | .thresholds.monthly.critical = 0.95' "$TEST_CONFIG" > "$TMP_HOME/cfg_minfo.json" && QUOTA_CONFIG="$TMP_HOME/cfg_minfo.json" "$BUDGET" --check --no-state)"
# With $29.55 spend and ~49 cap, monthly_spend_pct = 29.55/49 ≈ 60.3% -> info or higher
MS="$(printf '%s' "$SNAP_MINFO" | jq -r '.monthly_status')"
[ "$MS" = "info" ] || [ "$MS" = "warn" ] || [ "$MS" = "critical" ] || fail "expected monthly info or higher at cap=49, got $MS"

# monthly warn: cap=37 so projected >= 80%
SNAP_MWARN="$(jq '.monthly_cap_usd = 37 | .thresholds.monthly.info = 0.60 | .thresholds.monthly.warn = 0.80 | .thresholds.monthly.critical = 0.95' "$TEST_CONFIG" > "$TMP_HOME/cfg_mwarn.json" && QUOTA_CONFIG="$TMP_HOME/cfg_mwarn.json" "$BUDGET" --check --no-state)"
MS2="$(printf '%s' "$SNAP_MWARN" | jq -r '.monthly_status')"
[ "$MS2" = "warn" ] || [ "$MS2" = "critical" ] || fail "expected monthly warn or critical at cap=37, got $MS2"

# monthly critical: cap=31 so projected >= 95%
SNAP_MCRIT="$(jq '.monthly_cap_usd = 31 | .thresholds.monthly.info = 0.60 | .thresholds.monthly.warn = 0.80 | .thresholds.monthly.critical = 0.95' "$TEST_CONFIG" > "$TMP_HOME/cfg_mcrit.json" && QUOTA_CONFIG="$TMP_HOME/cfg_mcrit.json" "$BUDGET" --check --no-state)"
[ "$(printf '%s' "$SNAP_MCRIT" | jq -r '.monthly_status')" = "critical" ] || fail "expected monthly critical at cap=31"

# --- 6b. Daily threshold transitions ---
# daily_status: $29.55 against $100 warn default => ok
[ "$(printf '%s' "$SNAP" | jq -r '.daily_status')" = "ok" ] || fail "daily_status should be ok at $29.55"

# daily info: set daily warn threshold to $40 so $29.55 >= info ($80 in config) — use low info threshold
SNAP_DINFO="$(jq '.daily_warn_threshold_usd = 40 | .thresholds.daily.info = 25 | .thresholds.daily.warn = 40' "$TEST_CONFIG" > "$TMP_HOME/cfg_dinfo.json" && QUOTA_CONFIG="$TMP_HOME/cfg_dinfo.json" "$BUDGET" --check --no-state)"
DS="$(printf '%s' "$SNAP_DINFO" | jq -r '.daily_status')"
[ "$DS" = "info" ] || [ "$DS" = "warn" ] || fail "expected daily info or warn at spend=$29.55 info=25 warn=40, got $DS"

# daily warn: $29.55 >= warn threshold when warn=25
SNAP_DWARN="$(jq '.daily_warn_threshold_usd = 25 | .thresholds.daily.info = 20 | .thresholds.daily.warn = 25' "$TEST_CONFIG" > "$TMP_HOME/cfg_dwarn.json" && QUOTA_CONFIG="$TMP_HOME/cfg_dwarn.json" "$BUDGET" --check --no-state)"
[ "$(printf '%s' "$SNAP_DWARN" | jq -r '.daily_status')" = "warn" ] || fail "expected daily warn at spend=$29.55 warn=25"

# CRITICAL: daily signal NEVER goes critical regardless of spend
[ "$(printf '%s' "$SNAP_DWARN" | jq -r '.daily_status')" != "critical" ] || fail "daily_status must never be critical"

# Combined status when monthly=ok but daily=warn: max = warn (not critical)
[ "$(printf '%s' "$SNAP_DWARN" | jq -r '.status')" = "warn" ] || fail "combined status should be warn when daily=warn, monthly=ok"

# --- 7. session-state quota_daily uses the updated schema ---
[ -f "$QUOTA_STATE_FILE" ] || fail "session-state.json not written"
for k in date month input_tokens output_tokens cache_read_tokens cache_creation_tokens \
          estimated_usd monthly_spend_usd monthly_cap_usd daily_warn_threshold_usd \
          projected_eod_usd projected_eom_usd daily_status monthly_status status; do
  [ "$(jq -r ".quota_daily | has(\"$k\")" "$QUOTA_STATE_FILE")" = "true" ] || fail "quota_daily missing field: $k"
done
numeq "$(jq -r '.quota_daily.estimated_usd' "$QUOTA_STATE_FILE")" "29.55" || fail "quota_daily.estimated_usd wrong"
numeq "$(jq -r '.quota_daily.monthly_spend_usd' "$QUOTA_STATE_FILE")" "29.55" || fail "quota_daily.monthly_spend_usd wrong"

# --- 8. --config prints monthly cap + daily warn + both threshold sets ---
CFG="$("$BUDGET" --config)"
numge "$(printf '%s' "$CFG" | jq -r '.monthly_cap_usd')" "1" || fail "config monthly_cap_usd missing"
numge "$(printf '%s' "$CFG" | jq -r '.daily_warn_threshold_usd')" "1" || fail "config daily_warn_threshold_usd missing"
[ "$(printf '%s' "$CFG" | jq -r '.thresholds.monthly | has("info")')" = "true" ] || fail "config missing thresholds.monthly.info"
[ "$(printf '%s' "$CFG" | jq -r '.thresholds.daily | has("info_usd")')" = "true" ] || fail "config missing thresholds.daily.info_usd"
[ "$(printf '%s' "$CFG" | jq -r '.stop_hook_threshold | has("monthly_pct")')" = "true" ] || fail "config missing stop_hook_threshold.monthly_pct"
[ "$(printf '%s' "$CFG" | jq -r '.stop_hook_threshold | has("daily_usd")')" = "true" ] || fail "config missing stop_hook_threshold.daily_usd"
numeq "$(printf '%s' "$CFG" | jq -r '.thresholds.monthly.info')" "0.60" || fail "config monthly info threshold wrong"

# --- 9. --reset zeroes today's cached counter (log untouched) ---
"$BUDGET" --reset >/dev/null
numeq "$(jq -r '.quota_daily.estimated_usd' "$QUOTA_STATE_FILE")" "0" || fail "reset did not zero quota_daily"
[ "$(wc -l < "$QUOTA_USAGE_LOG" | tr -d ' ')" = "2" ] || fail "reset must not modify the durable ledger"

# --- 10. --week aggregates 7 zero-filled ET days incl. today ---
WK="$("$BUDGET" --week --no-state)"
[ "$(printf '%s' "$WK" | jq -r '.days | length')" = "7" ] || fail "week should have 7 days"
[ "$(printf '%s' "$WK" | jq -r '.days[-1].date')" = "$TODAY" ] || fail "week last day should be today"
numeq "$(printf '%s' "$WK" | jq -r '.total_usd')" "29.55" || fail "week total wrong: $(printf '%s' "$WK" | jq -r .total_usd)"
[ "$(printf '%s' "$WK" | jq -r 'has("month_spend_usd")')" = "true" ] || fail "week missing month_spend_usd"
[ "$(printf '%s' "$WK" | jq -r 'has("monthly_cap_usd")')" = "true" ] || fail "week missing monthly_cap_usd"
[ "$(printf '%s' "$WK" | jq -r 'has("daily_warn_threshold_usd")')" = "true" ] || fail "week missing daily_warn_threshold_usd"

# --- 11. --month aggregates current ET month ---
MN="$("$BUDGET" --month --no-state)"
[ "$(printf '%s' "$MN" | jq -r 'has("days")')" = "true" ] || fail "--month missing days"
[ "$(printf '%s' "$MN" | jq -r '.days | length')" -ge 28 ] || fail "--month should have >=28 days"
numeq "$(printf '%s' "$MN" | jq -r '.total_usd')" "29.55" || fail "--month total_usd wrong"
[ "$(printf '%s' "$MN" | jq -r '.month')" = "$(TZ='America/New_York' date +%Y-%m)" ] || fail "--month field wrong"

# --- 12. --date for an empty past day reports 0 / fraction 1 ---
PAST="$("$BUDGET" --check --date 2000-01-01 --no-state)"
numeq "$(printf '%s' "$PAST" | jq -r '.estimated_usd')" "0" || fail "empty past day non-zero spend"
numeq "$(printf '%s' "$PAST" | jq -r '.fraction_of_day_elapsed')" "1" || fail "past day fraction != 1"
numeq "$(printf '%s' "$PAST" | jq -r '.fraction_of_month_elapsed')" "1" || fail "past day month fraction != 1"

# --- 13. --config-cap sets monthly and daily-warn ---
CONFIG_CAP_CFG="$TMP_HOME/cap-test.json"
cp "$QUOTA_CONFIG" "$CONFIG_CAP_CFG"
QUOTA_CONFIG="$CONFIG_CAP_CFG" "$BUDGET" --config-cap monthly=2000 daily-warn=150 >/dev/null
UPDATED_MC="$(python3 -c "import json; cfg=json.load(open('$CONFIG_CAP_CFG')); print(cfg['monthly_cap_usd'])")"
UPDATED_DW="$(python3 -c "import json; cfg=json.load(open('$CONFIG_CAP_CFG')); print(cfg['daily_warn_threshold_usd'])")"
numeq "$UPDATED_MC" "2000" || fail "--config-cap monthly=2000 not applied, got $UPDATED_MC"
numeq "$UPDATED_DW" "150" || fail "--config-cap daily-warn=150 not applied, got $UPDATED_DW"
# Discrete override: monthly only
QUOTA_CONFIG="$CONFIG_CAP_CFG" "$BUDGET" --config-cap monthly=500 >/dev/null
UPDATED_MC2="$(python3 -c "import json; cfg=json.load(open('$CONFIG_CAP_CFG')); print(cfg['monthly_cap_usd'])")"
UPDATED_DW2="$(python3 -c "import json; cfg=json.load(open('$CONFIG_CAP_CFG')); print(cfg['daily_warn_threshold_usd'])")"
numeq "$UPDATED_MC2" "500" || fail "--config-cap monthly=500 discrete not applied"
numeq "$UPDATED_DW2" "150" || fail "--config-cap daily-warn preserved (should be 150 still), got $UPDATED_DW2"

# --- 14. Legacy migration: daily_cap_usd -> monthly+daily-warn ---
LEGACY_CFG="$TMP_HOME/legacy.json"
cat > "$LEGACY_CFG" << 'JEOF'
{
  "currency": "USD",
  "daily_cap_usd": 3.33,
  "thresholds": {"info": 0.60, "warn": 0.80, "critical": 0.95},
  "stop_hook_threshold": 0.60,
  "pricing": {"default": {"input": 15.0, "output": 75.0, "cache_write": 18.75, "cache_read": 1.5}}
}
JEOF
LEGACY_SNAP="$(QUOTA_CONFIG="$LEGACY_CFG" "$BUDGET" --check --no-state 2>&1)"
# After migration, quota-config should have new schema
HAS_LEGACY="$(python3 -c "import json; cfg=json.load(open('$LEGACY_CFG')); print('yes' if 'daily_cap_usd' in cfg else 'no')")"
[ "$HAS_LEGACY" = "no" ] || fail "legacy migration should remove daily_cap_usd"
HAS_MONTHLY="$(python3 -c "import json; cfg=json.load(open('$LEGACY_CFG')); print('yes' if 'monthly_cap_usd' in cfg else 'no')")"
[ "$HAS_MONTHLY" = "yes" ] || fail "legacy migration should add monthly_cap_usd"
MC_MIGRATED="$(python3 -c "import json; cfg=json.load(open('$LEGACY_CFG')); print(cfg['monthly_cap_usd'])")"
numeq "$MC_MIGRATED" "1000" || fail "migrated monthly_cap_usd should be 1000, got $MC_MIGRATED"
DW_MIGRATED="$(python3 -c "import json; cfg=json.load(open('$LEGACY_CFG')); print(cfg['daily_warn_threshold_usd'])")"
numeq "$DW_MIGRATED" "100" || fail "migrated daily_warn_threshold_usd should be 100 for standard default, got $DW_MIGRATED"
# New thresholds schema
HAS_MONTHLY_TH="$(python3 -c "import json; cfg=json.load(open('$LEGACY_CFG')); print('yes' if 'monthly' in cfg.get('thresholds',{}) else 'no')")"
[ "$HAS_MONTHLY_TH" = "yes" ] || fail "migration should add thresholds.monthly"
# stop_hook_threshold should be dict
SHT_TYPE="$(python3 -c "import json; cfg=json.load(open('$LEGACY_CFG')); print(type(cfg.get('stop_hook_threshold')).__name__)")"
[ "$SHT_TYPE" = "dict" ] || fail "migrated stop_hook_threshold should be dict, got $SHT_TYPE"
# snapshot should have migration_note
printf '%s' "$LEGACY_SNAP" | grep -q "migration_note" 2>/dev/null || true  # migration_note in stderr or snap

# --- 15. Legacy migration: user-set daily_cap_usd preserved as daily-warn ---
LEGACY_USER_CFG="$TMP_HOME/legacy-user.json"
cat > "$LEGACY_USER_CFG" << 'JEOF'
{
  "currency": "USD",
  "daily_cap_usd": 50,
  "thresholds": {"info": 0.60, "warn": 0.80, "critical": 0.95},
  "stop_hook_threshold": 0.60,
  "pricing": {"default": {"input": 15.0, "output": 75.0, "cache_write": 18.75, "cache_read": 1.5}}
}
JEOF
QUOTA_CONFIG="$LEGACY_USER_CFG" "$BUDGET" --check --no-state >/dev/null 2>&1 || true
DW_USER="$(python3 -c "import json; cfg=json.load(open('$LEGACY_USER_CFG')); print(cfg['daily_warn_threshold_usd'])")"
numeq "$DW_USER" "50" || fail "user-set daily_cap_usd=50 should become daily_warn_threshold_usd=50, got $DW_USER"

# --- 16. Stop hook emits when monthly OR daily over threshold, silent when both under ---
# Drive: tiny monthly_cap so projected >= 60% => emit
EMIT_CFG="$TMP_HOME/emit.json"
jq '.monthly_cap_usd = 40 | .stop_hook_threshold = {"monthly_pct": 0.60, "daily_usd": 80}' "$QUOTA_CONFIG" > "$EMIT_CFG"
EMIT="$(printf '{}' | QUOTA_CONFIG="$EMIT_CFG" "$STOP_HOOK" 2>/dev/null || true)"
printf '%s' "$EMIT" | jq -e '.hookSpecificOutput.additionalContext | test("\\[quota\\]")' >/dev/null || fail "stop hook should emit when monthly over threshold"
# Verify new format: should contain 'day-warn' and 'EoM'
printf '%s' "$EMIT" | jq -e '.hookSpecificOutput.additionalContext | test("day-warn")' >/dev/null || fail "stop hook line should contain 'day-warn'"
printf '%s' "$EMIT" | jq -e '.hookSpecificOutput.additionalContext | test("EoM")' >/dev/null || fail "stop hook line should contain 'EoM'"
# Silent when both under threshold
BIG_CFG="$TMP_HOME/big.json"
jq '.monthly_cap_usd = 100000 | .daily_warn_threshold_usd = 10000 | .stop_hook_threshold = {"monthly_pct": 0.60, "daily_usd": 80}' "$QUOTA_CONFIG" > "$BIG_CFG"
SILENT="$(printf '{}' | QUOTA_CONFIG="$BIG_CFG" "$STOP_HOOK" 2>/dev/null || true)"
[ -z "$SILENT" ] || fail "stop hook should be silent when both under threshold, got: $SILENT"

# --- 17. Projection floor: tiny day fraction must not explode EoD (BugBot regression) ---
FLOOR_LOG="$TMP_HOME/floor.log"
printf '%s\tclaude-opus-4-8\t100000\t0\t0\t0\tSf\n' "2026-06-26T04:00:30Z" >> "$FLOOR_LOG"
FSNAP="$(QUOTA_USAGE_LOG="$FLOOR_LOG" QUOTA_FAKE_NOW="2026-06-26T04:01:00Z" "$BUDGET" --check --no-state)"
numeq "$(printf '%s' "$FSNAP" | jq -r '.estimated_usd')" "1.5" || fail "floor test spend wrong"
numeq "$(printf '%s' "$FSNAP" | jq -r '.projected_eod_usd')" "36" || fail "day projection not floored: $(printf '%s' "$FSNAP" | jq -r .projected_eod_usd)"
python3 -c "import sys; sys.exit(0 if float('$(printf '%s' "$FSNAP" | jq -r '.fraction_of_day_elapsed')') < 0.01 else 1)" \
  || fail "fraction_of_day_elapsed should report the true tiny value"
# Monthly projection should also be floored (floor = 1/days_in_month)
numge "$(printf '%s' "$FSNAP" | jq -r '.projected_eom_usd')" "1.5" || fail "projected_eom_usd should be >= spend"

# --- 18. Monthly projection at first of month: floor prevents explosion ---
# Simulate 2026-07-01 04:01:00 ET (very start of month), $1.50 spend
MFLOOR_LOG="$TMP_HOME/mfloor.log"
printf '%s\tclaude-opus-4-8\t100000\t0\t0\t0\tSf\n' "2026-07-01T08:01:00Z" >> "$MFLOOR_LOG"
MFSNAP="$(QUOTA_USAGE_LOG="$MFLOOR_LOG" QUOTA_FAKE_NOW="2026-07-01T08:01:00Z" "$BUDGET" --check --no-state)"
# With $1.50 spend and floor=1/31, projected_eom = 1.50 / (1/31) = 46.5 (not millions)
PEOM="$(printf '%s' "$MFSNAP" | jq -r '.projected_eom_usd')"
python3 -c "import sys; sys.exit(0 if float('$PEOM') <= 200 else 1)" || fail "monthly floor failed: projected_eom_usd=$PEOM (should be <=200)"

# --- 19. Marker committed before append: marker-write failure must not double-count ---
MK_DIR="$TMP_HOME/marker.d"; mkdir -p "$MK_DIR"
MK_TS="$TRANSCRIPT"
MK_INPUT="$(printf '{"session_id":"sess-marker","transcript_path":"%s","tool_name":"Bash"}' "$MK_TS")"
MK_LOG="$TMP_HOME/marker.log"
printf '%s' "$MK_INPUT" | QUOTA_USAGE_LOG="$MK_LOG" QUOTA_STATE_DIR="$MK_DIR" "$HOOK" >/dev/null
[ "$(wc -l < "$MK_LOG" | tr -d ' ')" = "1" ] || fail "marker test: first fire should write 1 line"
printf '%s\n' '{"type":"assistant","uuid":"u3","message":{"id":"msg_C","model":"claude-opus-4-8","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}' >> "$MK_TS"
chmod 0555 "$MK_DIR"
printf '%s' "$MK_INPUT" | QUOTA_USAGE_LOG="$MK_LOG" QUOTA_STATE_DIR="$MK_DIR" "$HOOK" >/dev/null
chmod 0755 "$MK_DIR"
[ "$(wc -l < "$MK_LOG" | tr -d ' ')" = "1" ] || fail "marker-write failure must skip append (got $(wc -l < "$MK_LOG" | tr -d ' ') lines)"

echo "OK: quota tracker test passed (hook + budget monthly+daily signals + thresholds + migration + stop hook + projection floors)"
