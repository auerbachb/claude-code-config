#!/bin/bash
# quota-stop-notify.sh — Stop hook: surface a one-line monthly+daily spend warning.
#
# Fires when Claude finishes a response. Reads today's spend snapshot from
# quota-budget.sh and, when spend has reached either stop-hook threshold
# (monthly_pct >= 60% OR daily spend >= $80), injects a single additionalContext
# line so the user sees their run-rate. Below both thresholds it stays silent
# to keep noise low (issue #495).
#
# ACK / QUIET (issue #496):
#   /quota ack — silences the Stop hook for the rest of the session (until
#   severity escalates or a new ET day rolls over). Ack state is stored in
#   ~/.claude/quota-ack.json as:
#     { "session_id": "...", "acked_at_severity": "warn", "acked_date": "YYYY-MM-DD" }
#   The Stop hook skips emission when the current session+date+severity match the
#   acked state. Severity escalation (e.g. warn -> critical) breaks the ack so
#   the user is notified of meaningfully worse conditions.
#
# Line format:
#   [quota] today $X / day-warn $DW (Y%) — month $A / $MC (B%) projected EoM $C — <severity>
#   (appended with " [/quota ack to quiet]" on first emission to hint at ack)
#
# Non-blocking: always exits 0; never blocks the Stop event.
# Env overrides (tests): QUOTA_CONFIG, QUOTA_USAGE_LOG, QUOTA_STATE_FILE,
#   QUOTA_ACK_FILE, CLAUDE_SESSION_ID.

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

read -r today_spend daily_warn monthly_spend monthly_cap proj_eom proj_eom_pct daily_status monthly_status status today_et <<<"$(printf '%s' "$snap" | jq -r '"\(.estimated_usd) \(.daily_warn_threshold_usd) \(.monthly_spend_usd) \(.monthly_cap_usd) \(.projected_eom_usd) \(.projected_eom_pct) \(.daily_status) \(.monthly_status) \(.status) \(.date)"' 2>/dev/null)" || exit 0
[[ -n "${today_spend:-}" && "$today_spend" != "null" ]] || exit 0

# Determine whether to emit: monthly_pct >= sht_monthly OR daily_spend >= sht_daily
emit="$(python3 - "$proj_eom_pct" "$today_spend" "$sht_monthly" "$sht_daily" <<'PYEMIT' >/dev/null 2>&1 && echo yes || echo no
import sys
try:
    monthly_pct = float(sys.argv[1])
    daily_spend = float(sys.argv[2])
    sht_m = float(sys.argv[3])
    sht_d = float(sys.argv[4])
    sys.exit(0 if (monthly_pct >= sht_m or daily_spend >= sht_d) else 1)
except Exception:
    sys.exit(1)
PYEMIT
)"
[[ "$emit" == "yes" ]] || exit 0

# --- ACK CHECK: skip emission if this session+date+severity was acknowledged ---
ACK_FILE="${QUOTA_ACK_FILE:-$HOME/.claude/quota-ack.json}"
session_id="${CLAUDE_SESSION_ID:-}"
# If session_id is empty, try reading from session-state.json
if [[ -z "$session_id" ]] && command -v jq >/dev/null 2>&1; then
  STATE_FILE="${QUOTA_STATE_FILE:-$HOME/.claude/session-state.json}"
  session_id="$(jq -r '.session_id // empty' "$STATE_FILE" 2>/dev/null || true)"
fi

ack_silenced="no"
if [[ -f "$ACK_FILE" && -n "$session_id" ]]; then
  ack_silenced="$(python3 - "$ACK_FILE" "$session_id" "$today_et" "$status" <<'PYACK' 2>/dev/null
import json, sys
path, session_id, today_et, current_status = sys.argv[1:5]
severity_order = {"ok": 0, "info": 1, "warn": 2, "critical": 3}
try:
    with open(path, encoding="utf-8") as f:
        ack = json.load(f)
    if (ack.get("session_id") == session_id and
        ack.get("acked_date") == today_et):
        acked_sev = ack.get("acked_at_severity", "ok")
        current_order = severity_order.get(current_status, 0)
        acked_order = severity_order.get(acked_sev, 0)
        if current_order <= acked_order:
            print("yes")
            sys.exit(0)
except Exception:
    pass
print("no")
PYACK
)"
fi
[[ "$ack_silenced" == "yes" ]] || ack_silenced="no"
[[ "$ack_silenced" == "yes" ]] && exit 0

# Check if this is the first emission this session+day (for ack hint)
ACK_HINT_MARKER="${QUOTA_ACK_FILE:-$HOME/.claude/quota-ack.json}.hint_${session_id:-unknown}_${today_et:-unknown}"
show_ack_hint="no"
if [[ ! -f "$ACK_HINT_MARKER" ]]; then
  show_ack_hint="yes"
  touch "$ACK_HINT_MARKER" 2>/dev/null || true
  # Prune stale markers (older than today) to prevent unbounded growth
  _hint_dir="$(dirname "${QUOTA_ACK_FILE:-$HOME/.claude/quota-ack.json}")"
  _hint_base="$(basename "${QUOTA_ACK_FILE:-$HOME/.claude/quota-ack.json}")"
  find "$_hint_dir" -maxdepth 1 -name "${_hint_base}.hint_*" \
    ! -name "${_hint_base}.hint_*_${today_et:-9999-99-99}" \
    -delete 2>/dev/null || true
fi

line="$(python3 - "$today_spend" "$daily_warn" "$monthly_spend" "$monthly_cap" "$proj_eom" "$proj_eom_pct" "$status" "$show_ack_hint" <<'PY' 2>/dev/null
import sys
today_spend = float(sys.argv[1])
daily_warn = float(sys.argv[2])
monthly_spend = float(sys.argv[3])
monthly_cap = float(sys.argv[4])
proj_eom = float(sys.argv[5])
proj_eom_pct = float(sys.argv[6])
status = sys.argv[7]
show_ack_hint = sys.argv[8] == "yes"

day_pct = (today_spend / daily_warn * 100) if daily_warn > 0 else 0.0
month_pct = (monthly_spend / monthly_cap * 100) if monthly_cap > 0 else 0.0

line = (
    f"[quota] today ${today_spend:.2f} / day-warn ${daily_warn:.0f} ({day_pct:.0f}%)"
    f" — month ${monthly_spend:.2f} / ${monthly_cap:.0f} ({month_pct:.0f}%)"
    f" projected EoM ${proj_eom:.2f} ({proj_eom_pct*100:.0f}%)"
    f" — {status}"
)
if show_ack_hint:
    line += "  [/quota ack to quiet]"
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
