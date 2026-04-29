#!/bin/bash
# PostToolUse hook: warn when polling keeps reporting an unchanged PR digest.
#
# The scheduling rule owns the behavior; this hook is a non-blocking safety net
# for compaction drift. It only inspects Bash calls that look like polling work
# or explicit cron actions, then injects additionalContext when the PR state has
# stayed stable long enough to require backoff or pause.

input=$(cat)

emit_context() {
  local message="$1"
  jq -n --arg message "$message" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $message
    }
  }'
}

json_field() {
  local field="$1"
  printf '%s' "$input" | jq -r "$field // empty" 2>/dev/null
}

command=$(json_field '.tool_input.command')
cwd=$(json_field '.cwd')
session_id=$(json_field '.session_id')
session_id="${session_id:-${CLAUDE_SESSION_ID:-default}}"
session_id="${session_id//[^[:alnum:]_.-]/_}"

[[ -n "$command" ]] || exit 0

case "$command" in
  *CronUpdate*|*CronDelete*|*CronCreate*)
    sentinel="/tmp/claude-polling-cron-action-${session_id}"
    mkdir -p "$(dirname "$sentinel")" 2>/dev/null || true
    date -u +'%Y-%m-%dT%H:%M:%SZ' > "$sentinel" 2>/dev/null || true
    exit 0
    ;;
esac

is_polling_command=0
if [[ "$command" == *"gh pr view"* || "$command" == *"gh api"* ]]; then
  is_polling_command=1
elif [[ "$command" == *"session-state.sh"* && "$command" == *"--set"* ]]; then
  if [[ "$command" == *".prs["* || "$command" == *".polling_failures"* || "$command" == *".polling_backoffs"* ]]; then
    is_polling_command=1
  fi
fi

(( is_polling_command == 1 )) || exit 0

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_helper="${script_dir%/.claude/hooks}/.claude/scripts/session-state.sh"
state_file="${HOME}/.claude/session-state.json"

if [[ ! -x "$state_helper" || ! -f "$state_file" ]]; then
  exit 0
fi

pr_number=""
if [[ "$command" =~ gh[[:space:]]+pr[[:space:]]+view[[:space:]]+([0-9]+) ]]; then
  pr_number="${BASH_REMATCH[1]}"
elif [[ "$command" =~ /pulls/([0-9]+) ]]; then
  pr_number="${BASH_REMATCH[1]}"
elif [[ "$command" =~ \.prs\[[\"\']?([0-9]+)[\"\']?\] ]]; then
  pr_number="${BASH_REMATCH[1]}"
fi

if [[ -z "$pr_number" ]]; then
  pr_number=$(jq -r '
    .prs // {} | to_entries
    | map(select((.value.digest_streak // 0) >= 3 or .value.blocker_kind == "user_input"))
    | sort_by(.value.digest_streak // 0)
    | reverse
    | .[0].key // empty
  ' "$state_file" 2>/dev/null)
fi

[[ -n "$pr_number" ]] || exit 0

pr_jq=".prs[\"${pr_number}\"]"
streak=$("$state_helper" --get "${pr_jq}.digest_streak // 0" 2>/dev/null || printf '0')
blocker=$("$state_helper" --get "${pr_jq}.blocker // empty" 2>/dev/null || true)
blocker_kind=$("$state_helper" --get "${pr_jq}.blocker_kind // empty" 2>/dev/null || true)
last_cron_type=$("$state_helper" --get "${pr_jq}.last_cron_action.type // empty" 2>/dev/null || true)
last_cron_interval=$("$state_helper" --get "${pr_jq}.last_cron_action.interval // empty" 2>/dev/null || true)

if ! [[ "$streak" =~ ^[0-9]+$ ]]; then
  streak=0
fi

user_blocker=0
if [[ "$blocker_kind" == "user_input" ]]; then
  user_blocker=1
elif [[ "$blocker" =~ [Aa]waiting[[:space:]]+(your[[:space:]]+)?direction|[Aa]waiting[[:space:]]+user|[Uu]ser[[:space:]]+input|[Uu]ser[[:space:]]+decision ]]; then
  user_blocker=1
fi

if (( streak < 3 )) && (( user_blocker == 0 )); then
  exit 0
fi

if (( user_blocker == 1 || streak >= 9 )); then
  [[ "$last_cron_type" == "delete" ]] && exit 0
  emit_context "STOP - PR #${pr_number} is stable-blocked (digest_streak=${streak}, blocker_kind=${blocker_kind:-null}). Call CronDelete and cancel any sibling ScheduleWakeup before exiting this turn. Do not heartbeat again until the user nudges or the digest changes."
  exit 0
fi

if (( streak >= 6 )); then
  if [[ "$last_cron_type" == "update" && "$last_cron_interval" == "15m" ]]; then
    exit 0
  fi
  emit_context "STOP - PR #${pr_number} has ${streak} identical polling ticks. Call CronUpdate to widen the interval to 15m before exiting this turn, update prs.${pr_number}.last_cron_action, and suppress duplicate heartbeat noise."
  exit 0
fi

if (( streak >= 3 )); then
  if [[ "$last_cron_type" == "update" && ( "$last_cron_interval" == "5m" || "$last_cron_interval" == "15m" ) ]]; then
    exit 0
  fi
  emit_context "STOP - PR #${pr_number} has ${streak} identical polling ticks. Call CronUpdate to widen the interval to 5m before exiting this turn, update prs.${pr_number}.last_cron_action, and suppress duplicate heartbeat noise."
fi

exit 0
