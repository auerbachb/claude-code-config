#!/bin/bash
# Timestamp injector — UserPromptSubmit hook (fires before each user-triggered turn)
# Injects the current ET system time as additionalContext so the model always has
# the authoritative time and does not need to estimate or hallucinate it.

# Consume stdin (required by hook protocol)
cat > /dev/null

CURRENT_TIME=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET' 2>/dev/null)
[[ -z "$CURRENT_TIME" ]] && CURRENT_TIME="ET time unavailable"

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "Current ET system time: ${CURRENT_TIME}. Use as timestamp prefix; never estimate."
  }
}
EOF

exit 0
