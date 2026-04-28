#!/bin/bash
# Silence detector acknowledgment — Stop hook (fires when Claude finishes responding)
# Touches the heartbeat file to record that a user-visible message was just sent.
# This is the automatic counterpart to silence-detector.sh.

# Capture stdin once for session-scoped heartbeat paths.
STDIN_JSON=$(cat)

SESSION_ID=$(printf '%s' "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null)
SESSION_ID="${SESSION_ID:-${CLAUDE_SESSION_ID:-default}}"
SESSION_ID="${SESSION_ID//[^[:alnum:]_.-]/_}"
SESSION_ID="${SESSION_ID:-default}"

# Touch the heartbeat file to reset the silence timer
HEARTBEAT_FILE="/tmp/claude-heartbeat-${SESSION_ID}"
WARNED_FILE="/tmp/claude-heartbeat-warned-${SESSION_ID}"
touch "$HEARTBEAT_FILE"
rm -f "$WARNED_FILE"

exit 0
