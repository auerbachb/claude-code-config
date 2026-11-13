#!/usr/bin/env bash
# unattended-question-guard.sh — PreToolUse hook on AskUserQuestion and
# start_session (issue #2283).
#
# While the operator has declared himself away (`unattended.sh on`), a menu
# blocks the turn until he returns. This hook records every question in the
# call to the repo's unattended questions file (unattended.sh record, source
# "hook", recommended = the first option, the ask-menu.md convention) and
# denies the call with a reason telling the agent to print the receipt, take
# the recommended option where it is reversible, park only the step that is
# not, and keep working. No menu opens. A start_session call is denied with
# a reason that says to use a sub-agent.
#
# Not unattended (the common case): prints nothing, the menu renders as usual
# (and human-queue-capture.sh decides as before).
#
# The deny never depends on the record succeeding: if recording fails while
# unattended, the call is still denied and the reason says to put the question
# in the final report instead. Without jq or unattended.sh the hook cannot
# tell, so it fails open (prints nothing). Always exits 0.
#
# Bash 3.2 compatible (macOS /bin/bash).
set -u

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || exit 0
UNATTENDED_SH="${UNATTENDED_SH:-${HERE%/hooks}/scripts/unattended.sh}"
[ -x "$UNATTENDED_SH" ] || exit 0

JQ=$(command -v jq 2>/dev/null) || JQ=""
if [ -z "$JQ" ]; then
  for c in /opt/homebrew/bin/jq /usr/local/bin/jq; do
    if [ -x "$c" ]; then JQ="$c"; break; fi
  done
fi
[ -n "$JQ" ] || exit 0

payload=$(cat 2>/dev/null) || exit 0
[ -n "$payload" ] || exit 0

"$UNATTENDED_SH" is-active >/dev/null 2>&1 || exit 0

deny() { # REASON
  "$JQ" -cn --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse",
    permissionDecision: "deny", permissionDecisionReason: $r}}' 2>/dev/null
  exit 0
}

# start_session can be refused or sit on an approval prompt under Remote
# Control; that refusal is what stalled the manager thread. Sub-agents do not.
tool=$(printf '%s' "$payload" | "$JQ" -r '(.tool_name // "") | tostring' 2>/dev/null) || tool=""
case "$tool" in
  *start_session)
    deny "UNATTENDED (human-queue.md, Unattended): the operator is away, and starting a session can wait on him. Do the work in a sub-agent (Agent tool) instead, with the whole queue in its first brief, and keep working. Do not retry this call." ;;
esac

cwd=$(printf '%s' "$payload" | "$JQ" -r '(.cwd // "") | tostring' 2>/dev/null) || cwd=""
sid=$(printf '%s' "$payload" | "$JQ" -r '(.session_id // "") | tostring' 2>/dev/null) || sid=""
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"

# One line per question: question<US>recommended<US>options joined by |. US
# (0x1f) is not IFS whitespace, so an empty field does not collapse.
lines=$(printf '%s' "$payload" | "$JQ" -r '
  [.tool_input.questions? // [] | .[]? | select(type == "object")]
  | .[] | [ (.question // "" | tostring | gsub("[\n\u001f]"; " ")),
            ((.options // [])[0].label // "" | tostring | gsub("[\n\u001f]"; " ")),
            ([(.options // [])[] | .label? // empty | tostring | gsub("[\n\u001f|]"; " ")] | join("|")) ]
  | join("\u001f")' 2>/dev/null) || lines=""

ids=""
recs=""
failed=0
if [ -n "$lines" ]; then
  US=$(printf '\037')
  while IFS="$US" read -r q rec opts; do
    [ -n "$q" ] || continue
    id=$("$UNATTENDED_SH" record --cwd "$cwd" --source hook --session "$sid" \
      --question "$q" --recommended "$rec" --options "$opts" 2>/dev/null) || id=""
    if [ -n "$id" ]; then
      ids="${ids:+$ids, }$id"
      [ -n "$rec" ] && recs="${recs:+$recs; }$id: $rec"
    else
      failed=1
    fi
  done <<EOF
$lines
EOF
else
  failed=1
fi

if [ -n "$ids" ] && [ "$failed" -eq 0 ]; then
  case "$ids" in *,*) noun="questions" ;; *) noun="question" ;; esac
  reason="UNATTENDED (human-queue.md, Unattended): the operator is away, so no menu opens. Recorded for his return: $ids. Print exactly: $noun $ids recorded for the operator's return. Then take the recommended option${recs:+ ($recs)} only if the step is reversible and no rule requires confirmation, else park only that step and go on with independent work; record what you did with $UNATTENDED_SH update <id> --did '...'; and keep working. Do not ask again."
else
  reason="UNATTENDED (human-queue.md, Unattended): the operator is away, so no menu opens.${ids:+ Recorded: $ids.} The question could not be fully recorded: record it with $UNATTENDED_SH record --question '...' --recommended '...' --did '...', or put it in your final report. Take the recommended option only if the step is reversible and no rule requires confirmation, else park only that step, and keep working. Do not ask again."
fi

deny "$reason"
