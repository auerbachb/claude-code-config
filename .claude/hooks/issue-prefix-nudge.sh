#!/bin/bash
# Issue prefix nudge — UserPromptSubmit hook (first user message per session only).
# When the first prompt does not start with a leading [#N] style token, injects
# additionalContext pointing at CLAUDE.md. Non-blocking; always exits 0.
#
# Sentinel (per session): /tmp/issue-prefix-nudge-first-<session_id> — OS-managed cleanup.

INPUT=$(cat 2>/dev/null || true)

if ! command -v jq >/dev/null 2>&1; then
  echo '{}'
  exit 0
fi

session_id=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
session_id="${session_id:-${CLAUDE_SESSION_ID:-}}"
session_id="${session_id//[^[:alnum:]_.-]/_}"

# Without a session_id we cannot track "first message of this session" — skip nudge.
if [[ -z "$session_id" ]]; then
  echo '{}'
  exit 0
fi

state_dir="/tmp"
sentinel="${state_dir}/issue-prefix-nudge-first-${session_id}"

if [[ -f "$sentinel" ]]; then
  echo '{}'
  exit 0
fi

mkdir -p "$state_dir" 2>/dev/null || true
if ! touch "$sentinel" 2>/dev/null; then
  echo '{}'
  exit 0
fi

prompt=$(printf '%s' "$INPUT" | jq -r '(.prompt // .message // "") | tostring' 2>/dev/null) || prompt=""

# Trim leading ASCII whitespace
while [[ "$prompt" == [[:space:]]* ]]; do
  prompt="${prompt#?}"
done

# Match CLAUDE.md: [#339] or [#339, #341] — leading [# then a digit
if [[ "$prompt" =~ ^\[[#][0-9] ]]; then
  echo '{}'
  exit 0
fi

nudge='Optional thread title hint: start the first user message with a leading [#N] token (e.g. [#339] or [#339, #341]) so auto-summarized tab titles are likelier to include the issue. See CLAUDE.md "Thread title".'

jq -n --arg msg "$nudge" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $msg
  }
}'

exit 0
