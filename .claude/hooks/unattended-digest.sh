#!/usr/bin/env bash
# unattended-digest.sh — UserPromptSubmit hook (issues #2283, #2294).
#
# Two jobs, both ending in additionalContext for the model:
#
# 1. The operator's next message (a prompt that is not an automated event) lists the questions
#    recorded while he was away, once, and marks them listed (unattended.sh digest --mark).
#
# 2. Window expiry and return (issue #2294):
#    - An AUTOMATED prompt (a Monitor wake, a task notification) is a turn in which a thread can act,
#      so it is where an expired window is noticed: `presence.sh expire` claims the end once for all
#      threads and prints what to do (the here notice and the phone-push instruction, or the away
#      list). Losing threads get nothing. No question is ever opened on a timer.
#    - The operator's message after a window ran out RETURNS him: `presence.sh return` ends away
#      handling once (a compare-and-set, one winning session), every saved question from every repo
#      is listed first (unattended.sh digest --all --mark), and the presence dialog is asked after
#      them: in the same turn when nothing was saved, otherwise on his next message
#      (`presence.sh dialog-claim`, once in total). A message inside a window he declared and that is
#      still running changes nothing.
#
# The automated/operator split is a heuristic on the prompt's wrapper prefix (the same prefixes
# quota-reserve.sh --classify-prompt uses). An automated event it does not recognise would count as
# the operator: that can end away handling early, and it can never keep it from ending.
#
# Fast path: neither a questions directory nor presence/unattended state → exit at once. Fails open
# (prints nothing) without jq or unattended.sh. Always exits 0.
#
# Bash 3.2 compatible (macOS /bin/bash).
set -u

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || exit 0
UNATTENDED_SH="${UNATTENDED_SH:-${HERE%/hooks}/scripts/unattended.sh}"
PRESENCE_SH="${PRESENCE_SH:-${HERE%/hooks}/scripts/presence.sh}"
[ -x "$UNATTENDED_SH" ] || exit 0

STATE_FILE="${HOME:-/nonexistent}/.claude/session-state.json"
have_state=0
if [ -f "$STATE_FILE" ] && [ -x "$PRESENCE_SH" ] && grep -q -e '"presence"' -e '"unattended"' "$STATE_FILE" 2>/dev/null; then
  have_state=1
fi
if [ "$have_state" -eq 0 ] && [ ! -d "${UNATTENDED_DIR:-${HOME:-/nonexistent}/.claude/unattended}" ]; then
  exit 0
fi

JQ=$(command -v jq 2>/dev/null) || JQ=""
if [ -z "$JQ" ]; then
  for c in /opt/homebrew/bin/jq /usr/local/bin/jq; do
    if [ -x "$c" ]; then JQ="$c"; break; fi
  done
fi
[ -n "$JQ" ] || exit 0
# The scripts this hook runs need jq on PATH too: append, never prepend.
case "$JQ" in /*) PATH="$PATH:$(dirname "$JQ")"; export PATH ;; esac

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

ctx=""
add() { ctx="${ctx:+$ctx
}$1"; }

probe=none
if [ "$have_state" -eq 1 ]; then
  probe=$("$PRESENCE_SH" probe 2>/dev/null) || probe=none
fi

dialog_text="PRESENCE DIALOG (presence.sh, issue #2294): the operator is back. After you answer his message, run '$PRESENCE_SH' ask: exit 0 prints a token; then open the dialog as the /presence skill describes (set --by operator-dialog --generation <token>, or release --dismissed when he dismisses it). Any other exit: do not open it. Skip it entirely when his message already says where he is or for how long: set that from the message instead."

if [ "$kind" = automated ]; then
  # A turn where a thread can act: notice an expired window. The claim decides who prints it.
  if [ "$probe" = lapsed ]; then
    notice=$("$PRESENCE_SH" expire 2>/dev/null) || notice=""
    [ -z "$notice" ] || add "PRESENCE WINDOW ENDED (presence-windows.md): $notice"
  fi
elif [ "$probe" = returning ]; then
  # Another session just returned him and is still listing the saved questions: this hook lists
  # nothing and asks nothing, so the list always comes first and exactly once.
  :
else
  returned=0
  lost=0
  if [ "$probe" = lapsed ] || [ "$probe" = lapsed-claimed ]; then
    rrc=0
    "$PRESENCE_SH" return >/dev/null 2>&1 || rrc=$?
    if [ "$rrc" -eq 0 ]; then returned=1; elif [ "$rrc" -eq 10 ]; then lost=1; fi
  elif [ "$probe" = listing-stale ]; then
    # The return winner stopped listing: take its place, so every repo's questions are still listed.
    rrc=0
    "$PRESENCE_SH" relist >/dev/null 2>&1 || rrc=$?
    if [ "$rrc" -eq 0 ]; then returned=1; elif [ "$rrc" -eq 10 ]; then lost=1; fi
  fi
  if [ "$lost" -eq 1 ]; then
    # Lost the return to another session, which lists every repo's questions: nothing to add.
    :
  elif [ "$returned" -eq 1 ]; then
    # Saved questions first, from every repo: he may return in any thread. A repo whose file
    # could not be read does not hide the others' lines (they are already marked listed).
    lrc=0
    list=$("$UNATTENDED_SH" digest --all --mark 2>/dev/null) || lrc=$?
    if [ "$lrc" -ne 0 ] && [ -z "$list" ]; then
      # A failed listing is not "nothing saved": say so, and leave the dialog for his next message
      # rather than asking it this turn.
      "$PRESENCE_SH" dialog-ready >/dev/null 2>&1 || true
      add "UNATTENDED QUESTIONS (human-queue.md, Unattended): the operator is back, so away handling has ended and menus work again. The saved questions could not be read just now: run '$UNATTENDED_SH' digest --all --mark, and show him the list it prints before anything else. Do NOT ask the presence question in this turn."
    elif [ -n "$list" ]; then
      "$PRESENCE_SH" dialog-ready >/dev/null 2>&1 || true
      [ "$lrc" -eq 0 ] || list="$list
(Some repos' question files could not be read: run '$UNATTENDED_SH' digest --all --mark again for the rest.)"
      add "UNATTENDED QUESTIONS (human-queue.md, Unattended): the operator is back, so away handling has ended and menus work again. Show him this list once in your reply, before anything else, each item with its recommended option and what was done meanwhile. It is now marked listed. Do NOT ask the presence question in this turn: it is asked on his next message, after he has had the list."
      add "$list"
    else
      add "PRESENCE RETURN (presence-windows.md): the operator is back, so away handling has ended and menus work again. No questions were saved."
      "$PRESENCE_SH" dialog-ready --now >/dev/null 2>&1 && add "$dialog_text"
    fi
  else
    digest=$("$UNATTENDED_SH" digest --mark --cwd "$cwd" 2>/dev/null) || digest=""
    if [ -n "$digest" ]; then
      add "UNATTENDED QUESTIONS (human-queue.md, Unattended): show the operator this list once in your reply, before anything else, each item with its recommended option and what was done meanwhile. It is now marked listed and will not be injected again."
      add "$digest"
    fi
    # A return earlier left the dialog pending: ask it once, now that he has had the list.
    if [ "$probe" = dialog ] && "$PRESENCE_SH" dialog-claim >/dev/null 2>&1; then
      add "$dialog_text"
    fi
  fi
fi

[ -n "$ctx" ] || exit 0

# On stdin, not --arg: a long digest must not hit the argument-size limit
# after the watermark is already written.
printf '%s' "$ctx" | "$JQ" -Rsc '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: .}}' 2>/dev/null
exit 0
