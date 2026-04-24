#!/bin/bash
# Silence detector — PostToolUse hook (fires after every tool call)
# Checks if >5 minutes have passed since the agent last sent a visible message.
# If so, injects an additionalContext warning into the agent's context.
#
# Acknowledgment is handled automatically by the companion Stop hook
# (silence-detector-ack.sh), which touches the heartbeat file whenever
# Claude finishes a response.

# Consume stdin (required by hook protocol)
cat > /dev/null

# Session-scoped heartbeat file in /tmp
HEARTBEAT_FILE="/tmp/claude-heartbeat-${CLAUDE_SESSION_ID:-default}"
THRESHOLD=300  # 5 minutes in seconds

# If heartbeat file doesn't exist, create it (first tool call in session)
if [[ ! -f "$HEARTBEAT_FILE" ]]; then
  touch "$HEARTBEAT_FILE"
  echo '{}'
  exit 0
fi

# Get mtime of heartbeat file (macOS stat format)
if [[ "$(uname)" == "Darwin" ]]; then
  last_ack=$(stat -f %m "$HEARTBEAT_FILE" 2>/dev/null)
else
  last_ack=$(stat -c %Y "$HEARTBEAT_FILE" 2>/dev/null)
fi

# Fallback if stat failed
if [[ -z "$last_ack" ]]; then
  touch "$HEARTBEAT_FILE"
  echo '{}'
  exit 0
fi

now=$(date +%s)
elapsed=$((now - last_ack))
current_time=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET' 2>/dev/null)
[[ -z "$current_time" ]] && current_time="ET time unavailable"

if [[ $elapsed -gt $THRESHOLD ]]; then
  elapsed_min=$((elapsed / 60))
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "HEARTBEAT WARNING: No visible message to user in ${elapsed_min}+ minutes (${elapsed}s). Per the 5-minute heartbeat rule, you MUST send a status update to the user NOW — before making any more tool calls. Include: what you are doing, what is pending, any blockers. Start with a timestamp (run date command)."
  }
}
EOF
else
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "Current system time: ${current_time}"
  }
}
EOF
fi

exit 0
