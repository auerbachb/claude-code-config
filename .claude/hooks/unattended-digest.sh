#!/usr/bin/env bash
# unattended-digest.sh — UserPromptSubmit hook (issue #2283).
#
# Lists the questions recorded while the operator was away, once:
#   - on the operator's next message (a prompt that is not an automated event),
#     whether or not the unattended window is still running;
#   - on any prompt, automated ones included (a Monitor wake), once the
#     declared window has ended.
# It injects the list as additionalContext with the instruction to show it
# once, each item with its recommended option and what was done meanwhile,
# and records the items as listed (unattended.sh digest --mark), so the next
# prompt does not list them again.
#
# Automated prompts are recognized by the same wrapped-event prefixes
# quota-reserve.sh --classify-prompt uses.
#
# Fast path: no questions directory → exit at once. Fails open (prints
# nothing) without jq or unattended.sh. Always exits 0.
#
# Bash 3.2 compatible (macOS /bin/bash).
set -u

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || exit 0
UNATTENDED_SH="${UNATTENDED_SH:-${HERE%/hooks}/scripts/unattended.sh}"
[ -x "$UNATTENDED_SH" ] || exit 0
[ -d "${UNATTENDED_DIR:-${HOME:-/nonexistent}/.claude/unattended}" ] || exit 0

JQ=$(command -v jq 2>/dev/null) || JQ=""
if [ -z "$JQ" ]; then
  for c in /opt/homebrew/bin/jq /usr/local/bin/jq; do
    if [ -x "$c" ]; then JQ="$c"; break; fi
  done
fi
[ -n "$JQ" ] || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0
prompt=$(printf '%s' "$payload" | "$JQ" -r '(.prompt // .message // "") | tostring' 2>/dev/null) || exit 0
cwd=$(printf '%s' "$payload" | "$JQ" -r '(.cwd // "") | tostring' 2>/dev/null) || cwd=""
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"

while :; do
  case "$prompt" in
    [[:space:]]*) prompt="${prompt#?}" ;;
    *) break ;;
  esac
done
kind=operator
case "$prompt" in
  "<ci-monitor-event>"*|"<task-notification>"*|"<side-sessions-event>"*|"[SYSTEM NOTIFICATION"*|\
  "<system-reminder>"*|"human-queue: D-"*|"[Artifact comment"*|"<scheduled-task"*|"<scheduled_task"*) kind=automated ;;
esac

if [ "$kind" = automated ]; then
  "$UNATTENDED_SH" window-ended >/dev/null 2>&1 || exit 0
fi

digest=$("$UNATTENDED_SH" digest --mark --cwd "$cwd" 2>/dev/null) || digest=""
[ -n "$digest" ] || exit 0

# On stdin, not --arg: a long digest must not hit the argument-size limit
# after the watermark is already written.
printf '%s' "$digest" | "$JQ" -Rsc '. as $d | {hookSpecificOutput: {hookEventName: "UserPromptSubmit",
  additionalContext: ("UNATTENDED QUESTIONS (human-queue.md, Unattended): show the operator this list once in your reply, before anything else, each item with its recommended option and what was done meanwhile. It is now marked listed and will not be injected again.\n" + $d)}}' 2>/dev/null
exit 0
