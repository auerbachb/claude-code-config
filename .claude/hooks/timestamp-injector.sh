#!/bin/bash
# Timestamp injector — UserPromptSubmit hook (fires before each user-triggered turn)
# Injects the current ET system time as additionalContext so the model always has
# the authoritative time and does not need to estimate or hallucinate it.

# Consume stdin (required by hook protocol)
cat > /dev/null

CURRENT_TIME=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET' 2>/dev/null)

if [[ -z "$CURRENT_TIME" ]]; then
  echo '{}'
  exit 0
fi

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "Current system time: ${CURRENT_TIME}. Use this time (or run the date command for a fresher reading) as your timestamp prefix — never estimate or calculate timestamps."
  }
}
EOF

exit 0
