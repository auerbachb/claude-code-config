#!/bin/bash
# quota-stop-notify.sh — Stop hook: surface a one-line monthly+daily spend warning.
#
# Fires when Claude finishes a response. Reads today's spend snapshot from
# quota-budget.sh and, when spend has reached either stop-hook threshold
# (monthly_pct >= 60% OR daily spend >= $80), injects a single additionalContext
# line so the user sees their run-rate. Below both thresholds it stays silent
# to keep noise low (issue #495).
#
# Line format:
#   [quota] today $X / day-warn $DW (Y%) — month $A / $MC (B%) projected EoM $C — <severity>
#
# Non-blocking: always exits 0; never blocks the Stop event.
# Env overrides (tests): QUOTA_CONFIG, QUOTA_USAGE_LOG, QUOTA_STATE_FILE.

cat > /dev/null  # drain the Stop payload (unused)

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
budget="${script_dir%/.claude/hooks}/.claude/scripts/quota-budget.sh"
[[ -r "$budget" ]] || exit 0

# Observational read; do not mutate session-state from a per-turn Stop hook.
snap="$(bash "$budget" --check --no-state 2>/dev/null)" || exit 0
[[ -n "$snap" ]] || exit 0

# Read stop-hook thresholds from config
cfg_out="$(bash "$budget" --config 2>/dev/null)" || exit 0
sht_monthly="$(printf '%s' "$cfg_out" | jq -r '.stop_hook_threshold.monthly_pct // 0.60' 2>/dev/null || echo 0.60)"
sht_daily="$(printf '%s' "$cfg_out" | jq -r '.stop_hook_threshold.daily_usd // 80' 2>/dev/null || echo 80)"

read -r today_spend daily_warn monthly_spend monthly_cap proj_eom proj_eom_pct daily_status monthly_status status <<<"$(printf '%s' "$snap" | jq -r '"\(.estimated_usd) \(.daily_warn_threshold_usd) \(.monthly_spend_usd) \(.monthly_cap_usd) \(.projected_eom_usd) \(.projected_eom_pct) \(.daily_status) \(.monthly_status) \(.status)"' 2>/dev/null)" || exit 0
[[ -n "${today_spend:-}" && "$today_spend" != "null" ]] || exit 0

# Determine whether to emit: monthly_pct >= sht_monthly OR daily_spend >= sht_daily
emit="$(python3 -c "
import sys
try:
    monthly_pct = float('$proj_eom_pct')
    daily_spend = float('$today_spend')
    sht_m = float('$sht_monthly')
    sht_d = float('$sht_daily')
    sys.exit(0 if (monthly_pct >= sht_m or daily_spend >= sht_d) else 1)
except Exception:
    sys.exit(1)
" >/dev/null 2>&1 && echo yes || echo no)"
[[ "$emit" == "yes" ]] || exit 0

line="$(python3 - "$today_spend" "$daily_warn" "$monthly_spend" "$monthly_cap" "$proj_eom" "$proj_eom_pct" "$status" <<'PY' 2>/dev/null
import sys
today_spend = float(sys.argv[1])
daily_warn = float(sys.argv[2])
monthly_spend = float(sys.argv[3])
monthly_cap = float(sys.argv[4])
proj_eom = float(sys.argv[5])
proj_eom_pct = float(sys.argv[6])
status = sys.argv[7]

day_pct = (today_spend / daily_warn * 100) if daily_warn > 0 else 0.0
month_pct = (monthly_spend / monthly_cap * 100) if monthly_cap > 0 else 0.0

line = (
    f"[quota] today ${today_spend:.2f} / day-warn ${daily_warn:.0f} ({day_pct:.0f}%)"
    f" — month ${monthly_spend:.2f} / ${monthly_cap:.0f} ({month_pct:.0f}%)"
    f" projected EoM ${proj_eom:.2f} ({proj_eom_pct*100:.0f}%)"
    f" — {status}"
)
print(line)
PY
)"
[[ -n "$line" ]] || exit 0

jq -n --arg msg "$line" '{
  hookSpecificOutput: {
    hookEventName: "Stop",
    additionalContext: $msg
  }
}'
exit 0
