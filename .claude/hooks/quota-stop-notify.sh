#!/bin/bash
# quota-stop-notify.sh — Stop hook: surface a one-line daily-spend warning.
#
# Fires when Claude finishes a response. Reads today's spend snapshot from
# quota-budget.sh and, when today's spend has reached the configured
# stop_hook_threshold (default 60% of the daily cap), injects a single
# additionalContext line so the user sees their run-rate. Below the threshold it
# stays silent to keep noise low (issue #458, AC: Stop-hook line emits when daily
# spend >= 60% of cap; suppressed below threshold).
#
# Non-blocking: always exits 0; never blocks the Stop event.
# Env overrides (tests): QUOTA_CONFIG, QUOTA_USAGE_LOG, QUOTA_STATE_FILE.

cat > /dev/null  # drain the Stop payload (unused)

command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
budget="${script_dir%/.claude/hooks}/.claude/scripts/quota-budget.sh"
[[ -x "$budget" ]] || exit 0

# Observational read; do not mutate session-state from a per-turn Stop hook.
snap="$("$budget" --check --no-state 2>/dev/null)" || exit 0
[[ -n "$snap" ]] || exit 0

threshold="$("$budget" --config 2>/dev/null | jq -r '.stop_hook_threshold // 0.60' 2>/dev/null || echo 0.60)"

read -r spend_pct spend cap proj status <<<"$(printf '%s' "$snap" | jq -r '"\(.spend_pct) \(.estimated_usd) \(.budget_usd) \(.projected_eod_usd) \(.status)"' 2>/dev/null)" || exit 0
[[ -n "${spend_pct:-}" && "$spend_pct" != "null" ]] || exit 0

# Emit only when today's actual spend has reached the stop-hook threshold.
emit="$(python3 -c "import sys
try:
    sys.exit(0 if float('$spend_pct') >= float('$threshold') else 1)
except Exception:
    sys.exit(1)" >/dev/null 2>&1 && echo yes || echo no)"
[[ "$emit" == "yes" ]] || exit 0

pct="$(python3 -c "print(f'{float(\"$spend_pct\")*100:.0f}')" 2>/dev/null || echo "?")"
line="$(printf '[quota] today $%.2f/$%.2f (%s%%) projected EoD $%.2f — %s' "$spend" "$cap" "$pct" "$proj" "$status" 2>/dev/null)"
[[ -n "$line" ]] || exit 0

jq -n --arg msg "$line" '{
  hookSpecificOutput: {
    hookEventName: "Stop",
    additionalContext: $msg
  }
}'
exit 0
