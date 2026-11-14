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
# Delivery (PR #2328 review): a list is never marked listed on the strength of this process alone. The
# hook exports a delivery ref plus the payload's session_id and transcript_path, so every listing it
# triggers (this repo's digest, the all-repos return list, an away-expiry list) is first persisted as a
# pending record (unattended.sh DELIVERY) and only then marked. At the top of an operator prompt it
# settles earlier records: a record whose ref is in its transcript was delivered and is dropped, any
# other is shown again, before anything new and before the presence dialog. A hook killed after the
# mark but before its output reached the model therefore costs a repeat, never a lost question, and a
# takeover of a dead return winner never reports "No questions were saved" over an undelivered list.
# The delivery ref line it appends is how the next settle recognises the list in the transcript.
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
sid=$(printf '%s' "$payload" | "$JQ" -r '(.session_id // "") | tostring' 2>/dev/null) || sid=""
tpath=$(printf '%s' "$payload" | "$JQ" -r '(.transcript_path // "") | tostring' 2>/dev/null) || tpath=""
# One ref per hook run, digits and dashes only so the transcript keeps it verbatim.
DELIVERY_REF="pd-$(date +%s)-$$"
export UNATTENDED_DELIVERY_REF="$DELIVERY_REF" UNATTENDED_DELIVERY_SESSION="$sid" UNATTENDED_DELIVERY_TRANSCRIPT="$tpath"
PENDING_DIR="${UNATTENDED_DIR:-${HOME:-/nonexistent}/.claude/unattended}/pending"
# Did any listing in this run persist a record under this ref? Then the output must carry the ref.
staged_here() { grep -lF "\"ref\":\"$DELIVERY_REF\"" "$PENDING_DIR"/*.json >/dev/null 2>&1; }
record_failure() { # LINE — kept in the questions directory, never in a worktree
  mkdir -p "${PENDING_DIR%/pending}" 2>/dev/null &&
    printf '%s %s\n' "$(date +%s)" "$1" >>"${PENDING_DIR%/pending}/delivery.log" 2>/dev/null || true
}

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

# Earlier lists that did not provably reach the model (see Delivery above), shown again first. FORCE=1
# after a takeover of a dead return winner, whose record may be younger than the usual grace.
settle_owed() { # FORCE
  local f=()
  [ "$1" -eq 1 ] && f=(--force)
  ls "$PENDING_DIR"/*.json >/dev/null 2>&1 || return 0
  "$UNATTENDED_SH" settle --session "$sid" --transcript "$tpath" --ref "$DELIVERY_REF" ${f[@]+"${f[@]}"} 2>/dev/null || true
}
# Records another emission still owns (a live session's list inside the grace window).
others_in_flight() {
  ls "$PENDING_DIR"/*.json >/dev/null 2>&1 || { printf '0\n'; return 0; }
  "$UNATTENDED_SH" undelivered --not-ref "$DELIVERY_REF" 2>/dev/null || printf '0\n'
}
owed_frame="UNATTENDED QUESTIONS (human-queue.md, Unattended): the list below was recorded while the operator was away and has not been confirmed shown to him yet (an earlier hook run may have been interrupted). Show it in your reply, before anything else, each item with its recommended option and what was done meanwhile. A repeat is expected and harmless."

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
  forced=0
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
    # The return winner stopped listing: take its place, so every repo's questions are still listed,
    # including a list it persisted and marked but never delivered.
    rrc=0
    rerr=$("$PRESENCE_SH" relist 2>&1 >/dev/null) || rrc=$?
    case "$rrc" in
      0) returned=1; forced=1 ;;
      10) lost=1 ;;
      1) : ;;
      *) failed=1; record_failure "presence.sh relist exited $rrc: $(printf '%s' "$rerr" | tr '\n' ' ' | cut -c1-200)" ;;
    esac
  fi
  if [ "$lost" -eq 1 ]; then
    # Lost the return to another session, which lists every repo's questions: nothing to add.
    :
  elif [ "$returned" -eq 1 ]; then
    # Undelivered lists from before first, then every repo's saved questions: he may return in any
    # thread. A repo whose file could not be read does not hide the others' lines (they are already
    # marked listed).
    owed=$(settle_owed "$forced")
    lrc=0
    list=$("$UNATTENDED_SH" digest --all --mark 2>/dev/null) || lrc=$?
    if [ "$lrc" -ne 0 ] && [ -z "$list" ] && [ -z "$owed" ]; then
      # A failed listing is not "nothing saved": say so, and leave the dialog for his next message
      # rather than asking it this turn.
      "$PRESENCE_SH" dialog-ready >/dev/null 2>&1 || true
      add "UNATTENDED QUESTIONS (human-queue.md, Unattended): the operator is back, so away handling has ended and menus work again. The saved questions could not be read just now: run '$UNATTENDED_SH' digest --all --mark, and show him the list it prints before anything else. Do NOT ask the presence question in this turn."
    elif [ -n "$list" ] || [ -n "$owed" ]; then
      "$PRESENCE_SH" dialog-ready >/dev/null 2>&1 || true
      [ "$lrc" -eq 0 ] || list="$list
(Some repos' question files could not be read: run '$UNATTENDED_SH' digest --all --mark again for the rest.)"
      add "UNATTENDED QUESTIONS (human-queue.md, Unattended): the operator is back, so away handling has ended and menus work again. Show him this list once in your reply, before anything else, each item with its recommended option and what was done meanwhile. It is now marked listed. Do NOT ask the presence question in this turn: it is asked on his next message, after he has had the list."
      [ -z "$owed" ] || add "(Not yet confirmed shown from an earlier run, listed again:)
$owed"
      [ -z "$list" ] || add "$list"
    else
      add "PRESENCE RETURN (presence-windows.md): the operator is back, so away handling has ended and menus work again. No questions were saved."
      if [ "$(others_in_flight)" -gt 0 ]; then
        # A list another session emitted a moment ago is still being delivered: that list comes first.
        "$PRESENCE_SH" dialog-ready >/dev/null 2>&1 || true
      else
        "$PRESENCE_SH" dialog-ready --now >/dev/null 2>&1 && add "$dialog_text"
      fi
    fi
  else
    if [ "$failed" -eq 1 ]; then
      add "PRESENCE RETURN FAILED (presence-windows.md): the operator is back, but the state write that ends away handling failed, so away handling has NOT ended and menus are still denied. The saved questions of other repos have not been listed and the presence dialog has not been asked. Tell him so in your reply. His next message retries the return; this hook does not retry within the turn."
    fi
    owed=$(settle_owed 0)
    if [ -n "$owed" ]; then
      add "$owed_frame"
      add "$owed"
    fi
    digest=$("$UNATTENDED_SH" digest --mark --cwd "$cwd" 2>/dev/null) || digest=""
    if [ -n "$digest" ]; then
      add "UNATTENDED QUESTIONS (human-queue.md, Unattended): show the operator this list once in your reply, before anything else, each item with its recommended option and what was done meanwhile. It is now marked listed and will not be injected again."
      add "$digest"
    fi
    # A return earlier left the dialog pending: ask it once, after he has had the list. A list another
    # session is still delivering comes first, so the dialog waits for his next message.
    if [ "$probe" = dialog ] && [ "$failed" -eq 0 ] && [ "$(others_in_flight)" -eq 0 ] && "$PRESENCE_SH" dialog-claim >/dev/null 2>&1; then
      add "$dialog_text"
    fi
  fi
fi

[ -n "$ctx" ] || exit 0
# The ref is how the next settle finds this emission in the transcript: say it only when a record
# carries it.
if staged_here; then
  add "(Delivery reference $DELIVERY_REF: internal bookkeeping, do not mention it to the operator.)"
fi

# On stdin, not --arg: a long digest must not hit the argument-size limit
# after the watermark is already written.
printf '%s' "$ctx" | "$JQ" -Rsc '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: .}}' 2>/dev/null
exit 0
