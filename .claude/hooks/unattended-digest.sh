#!/usr/bin/env bash
# unattended-digest.sh — UserPromptSubmit hook (issues #2283, #2294).
#
# Two jobs, both ending in additionalContext for the model:
#
# 1. The operator's next message (a prompt that is not an automated event) lists the questions
#    recorded while he was away that nobody has answered or dismissed (unattended.sh digest).
#
# 2. Window expiry and return (issue #2294):
#    - An AUTOMATED prompt (a Monitor wake, a task notification) is a turn in which a thread can act,
#      so it is where an expired window is noticed: `presence.sh expire` claims the end once for all
#      threads and prints what to do (the here notice and the phone-push instruction, or the away
#      list). Losing threads get nothing. No question is ever opened on a timer.
#    - The operator's message after a window ran out RETURNS him: `presence.sh return` ends away
#      handling once (a compare-and-set, one winning session), every unresolved question from every repo
#      is listed first (unattended.sh digest --all), and the presence dialog is asked after
#      them: in the same turn when nothing was saved, otherwise on his next message
#      (`presence.sh dialog-claim`, once in total). A message inside a window he declared and that is
#      still running changes nothing.
#
# Listing (issue #2352): a saved question is listed until it is ANSWERED or DISMISSED
# (unattended.sh answer|dismiss), and listing alone never hides it. The hook therefore marks
# nothing and keeps no delivery record: it reads the unresolved questions, prints its output, and
# only AFTER the print succeeds records which ids this session was shown in full (unattended.sh
# seen). A hook killed anywhere before its output leaves no record, so the next prompt lists the
# same questions in full; a kill between the print and the record costs a repeat, never a loss.
# A question this session already saw in full during the current return (the unattended
# since_epoch) is one summary line with a count after that.
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
# The session id: the payload's, else the environment's; usable only as a plain token (it names a
# file). With none, every list is in full and nothing is recorded as shown.
sid=$(printf '%s' "$payload" | "$JQ" -r '(.session_id // "") | tostring' 2>/dev/null) || sid=""
[ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
case "$sid" in *[!A-Za-z0-9._-]*) sid="" ;; esac
[ "${#sid}" -le 128 ] || sid=""
STATE_DIR="${UNATTENDED_DIR:-${HOME:-/nonexistent}/.claude/unattended}"
SHOWN=$(mktemp "${TMPDIR:-/tmp}/unattended-shown.XXXXXX" 2>/dev/null) || SHOWN=""
trap '[ -z "$SHOWN" ] || rm -f "$SHOWN"' EXIT
record_failure() { # LINE — kept in the questions directory, never in a worktree
  mkdir -p "$STATE_DIR" 2>/dev/null &&
    printf '%s %s\n' "$(date +%s)" "$1" >>"$STATE_DIR/hook.log" 2>/dev/null || true
}
# The one digest call every listing here makes: nothing is marked, and the ids shown in full go to
# $SHOWN for `seen` once the output was printed.
digest_args=(--session "$sid")
[ -z "$SHOWN" ] || digest_args=(--session "$sid" --shown-file "$SHOWN")

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

# Set when a return's list is in $ctx: the presence state leaves `listing` (dialog-ready) only AFTER
# that output was printed, so a hook killed before printing leaves the return stale-recoverable (the
# next operator message lists every repo again through `relist`).
ready_after=0
ctx=""
add() { ctx="${ctx:+$ctx
}$1"; }

probe=none
if [ "$have_state" -eq 1 ]; then
  probe=$("$PRESENCE_SH" probe 2>/dev/null) || probe=none
fi

dialog_text="PRESENCE DIALOG (presence.sh, issue #2294): the operator is back. After you answer his message, run '$PRESENCE_SH' ask: exit 0 prints a token; then open the dialog as the /presence skill describes (set --by operator-dialog --generation <token>, or release --dismissed when he dismisses it). Any other exit: do not open it. Skip it entirely when his message already says where he is or for how long: set that from the message instead."

back_pointer="BACK (issue #2541): tell him in one line that /back gives the whole return in one go: waiting questions as menus, his open tasks, and a digest of what happened while he was away. If his message is itself /back, skip that line and do not print the question list above as plain text: /back opens those questions as menus first, which is the showing this hook asks for."

list_frame="UNATTENDED QUESTIONS (human-queue.md, Unattended): show the operator the questions below in your reply, before anything else, each item with its recommended option and what was done meanwhile. A question stays listed until it is answered or dismissed, so a repeat is expected and harmless. When he answers one in chat, record it: '$UNATTENDED_SH' answer U-<n> --answer '<his answer>' --by operator. When he dismisses one without answering, run '$UNATTENDED_SH' dismiss U-<n> --reason '<why>'. For a question of another repo (a list labelled [owner/repo]) add --repo <owner/repo> to answer and to dismiss; leave it off for this repo's own. Record an answer only when he gave one."

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
  failed=0
  if [ "$probe" = lapsed ] || [ "$probe" = lapsed-claimed ]; then
    rrc=0
    rerr=$("$PRESENCE_SH" return 2>&1 >/dev/null) || rrc=$?
    # 0 returned; 10 another session won; 1 nothing to return from any more (he declared a window, or
    # another return finished: not a failure). Anything else is a failed return.
    case "$rrc" in
      0) returned=1 ;;
      10) lost=1 ;;
      1) : ;;
      *) failed=1; record_failure "presence.sh return exited $rrc: $(printf '%s' "$rerr" | tr '\n' ' ' | cut -c1-200)" ;;
    esac
  elif [ "$probe" = listing-stale ]; then
    # The return winner stopped listing: take its place, so every repo's questions are still listed.
    rrc=0
    rerr=$("$PRESENCE_SH" relist 2>&1 >/dev/null) || rrc=$?
    case "$rrc" in
      0) returned=1 ;;
      10) lost=1 ;;
      1) : ;;
      *) failed=1; record_failure "presence.sh relist exited $rrc: $(printf '%s' "$rerr" | tr '\n' ' ' | cut -c1-200)" ;;
    esac
  fi
  if [ "$lost" -eq 1 ]; then
    # Lost the return to another session, which lists every repo's questions: nothing to add.
    :
  elif [ "$returned" -eq 1 ]; then
    # Every repo's unresolved questions: he may return in any thread. A repo whose file could not be
    # read does not hide the others' lines.
    lrc=0
    list=$("$UNATTENDED_SH" digest --all "${digest_args[@]}" 2>/dev/null) || lrc=$?
    if [ "$lrc" -ne 0 ] && [ -z "$list" ]; then
      # A failed listing is not "nothing saved": say so, and leave the dialog for his next message
      # rather than asking it this turn.
      ready_after=1
      add "UNATTENDED QUESTIONS (human-queue.md, Unattended): the operator is back, so away handling has ended and menus work again. The saved questions could not be read just now: run '$UNATTENDED_SH' digest --all, and show him the list it prints before anything else. Do NOT ask the presence question in this turn."
    elif [ -n "$list" ]; then
      ready_after=1
      [ "$lrc" -eq 0 ] || list="$list
(Some repos' question files could not be read: run '$UNATTENDED_SH' digest --all again for the rest.)"
      add "PRESENCE RETURN (presence-windows.md): the operator is back, so away handling has ended and menus work again. Do NOT ask the presence question in this turn: it is asked on his next message, after he has had the list."
      add "$list_frame"
      add "$list"
    else
      add "PRESENCE RETURN (presence-windows.md): the operator is back, so away handling has ended and menus work again. No questions are waiting."
      "$PRESENCE_SH" dialog-ready --now >/dev/null 2>&1 && add "$dialog_text"
    fi
    add "$back_pointer"
  else
    if [ "$failed" -eq 1 ]; then
      add "PRESENCE RETURN FAILED (presence-windows.md): the operator is back, but the state write that ends away handling failed, so away handling has NOT ended and menus are still denied. The saved questions of other repos have not been listed and the presence dialog has not been asked. Tell him so in your reply. His next message retries the return; this hook does not retry within the turn."
    fi
    digest=$("$UNATTENDED_SH" digest --cwd "$cwd" "${digest_args[@]}" 2>/dev/null) || digest=""
    if [ -n "$digest" ]; then
      add "$list_frame"
      add "$digest"
    fi
    # A return earlier left the dialog pending: ask it once, after he has had the list.
    if [ "$probe" = dialog ] && [ "$failed" -eq 0 ] && "$PRESENCE_SH" dialog-claim >/dev/null 2>&1; then
      add "$dialog_text"
    fi
  fi
fi

[ -n "$ctx" ] || exit 0
# On stdin, not --arg: a long digest must not hit the argument-size limit. Print first; only a
# successful print is followed by the record of what was shown in full (a kill before it repeats the
# list, never loses it).
out=$(printf '%s' "$ctx" | "$JQ" -Rsc '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: .}}' 2>/dev/null) || out=""
[ -n "$out" ] || exit 0
printf '%s\n' "$out" || exit 0
[ "$ready_after" -eq 0 ] || "$PRESENCE_SH" dialog-ready >/dev/null 2>&1 || true
if [ -n "$SHOWN" ] && [ -s "$SHOWN" ] && [ -n "$sid" ]; then
  "$UNATTENDED_SH" seen --session "$sid" --from "$SHOWN" >/dev/null 2>&1 || true
fi
exit 0
