#!/bin/bash
# Silence detector acknowledgment — Stop hook (fires when Claude finishes responding)
# Touches the heartbeat file to record that a user-visible message was just sent.
# This is the automatic counterpart to silence-detector.sh.

# Consume stdin (required by hook protocol)
cat > /dev/null

# Touch the heartbeat file to reset the silence timer
HEARTBEAT_FILE="/tmp/claude-heartbeat-${CLAUDE_SESSION_ID:-default}"
touch "$HEARTBEAT_FILE"

exit 0
