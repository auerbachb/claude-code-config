#!/bin/bash
# Background-work ceiling — enforcement half (Stop hook).
#
# The companion PostToolUse hook (bgwork-ceiling-arm.sh) only advises, and
# advice is exactly what the current bug is made of: the model can end its turn
# without arming anything and nothing notices. This hook is the turn boundary
# where that becomes impossible — when background work is in flight and the
# ceiling watch is unarmed, it returns `decision: block`, so the turn does not
# end silently and the agent gets another step in which to arm it.
#
# Fail-closed, bounded, never silent. An unbounded block would hang the thread,
# so consecutive blocks are capped. Past the cap the hook stands down, but it
# stands down LOUDLY: a breach marker is written, the event is logged, and the
# reason goes to stderr. The arm hook then resurfaces the unguarded state on
# every subsequent tool call. A silent no-op here would re-create the very bug
# this guard exists to close (feedback_guard_must_fail_closed.md).

STDIN_JSON=$(cat)

json_field() {
  printf '%s' "$STDIN_JSON" | jq -r "$1 // empty" 2>/dev/null
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CEILING_SH="${SCRIPT_DIR%/hooks}/scripts/bgwork-ceiling.sh"
[[ -x "$CEILING_SH" ]] || exit 0

SESSION_ID=$(json_field '.session_id')
SESSION_ID="${SESSION_ID:-${CLAUDE_SESSION_ID:-default}}"
SAFE_ID="${SESSION_ID//[^[:alnum:]_.-]/_}"
SAFE_ID="${SAFE_ID:-default}"

MARKER_DIR="${CLAUDE_BGWORK_MARKER_DIR:-/tmp}"
BLOCKS_FILE="${MARKER_DIR}/claude-bgceiling-blocks-${SAFE_ID}"
BREACH_FILE="${MARKER_DIR}/claude-bgceiling-unguarded-${SAFE_ID}"
MAX_BLOCKS="${CLAUDE_BGWORK_MAX_BLOCKS:-2}"
[[ "$MAX_BLOCKS" =~ ^[0-9]+$ ]] || MAX_BLOCKS=2

# How to arm, worded for every runtime: the desktop Monitor has no
# `persistent` parameter and caps timeout_ms at 30 minutes (Issue #2201).
MONITOR_HOW='call the Monitor tool with description "background-work silence ceiling", timeout_ms at the runtime maximum (1800000 where capped; pass persistent: true only if the tool schema lists it), and command:'
REARM_NOTE='Re-arm it the same way on every expiry notice while background work runs (.claude/reference/monitor-expiry.md).'

file_mtime() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# Nothing to guard, or armed and ticking — clear any block counter and get out
# of the way. The counter is per-stretch-of-unarmed-work, not per-session.
lapse_key() {
  local a t
  a=$(file_mtime "${MARKER_DIR}/claude-bgceiling-armed-${SAFE_ID}")
  t=$(file_mtime "${MARKER_DIR}/claude-bgceiling-ticked-${SAFE_ID}")
  printf '%s-%s' "${a:-0}" "${t:-0}"
}
# Snapshot the arm/tick markers BEFORE the check, so a lapse is recorded under
# the exact marker state that produced it (a tick landing in between is
# detected below rather than recorded as already reported).
PRE_LAPSE_KEY=$(lapse_key)
CHECK_RC=0
"$CEILING_SH" --check --session "$SESSION_ID" || CHECK_RC=$?
if (( CHECK_RC == 0 )); then
  rm -f "$BLOCKS_FILE" 2>/dev/null || true
  exit 0
fi

# Armed but no longer ticking: the Monitor most likely expired and the thread
# did not act on the expiry notice. Never a block — the background-work marker
# is append-only, so a block here would fire on every Stop long after the work
# ended. One non-blocking notice per lapse instead, deduped on the arm/tick
# marker mtimes; a lapse that cannot be recorded stays silent rather than
# repeating on every Stop (a Stop notice costs a model request).
if (( CHECK_RC == 3 )); then
  rm -f "$BLOCKS_FILE" 2>/dev/null || true
  LAPSE_KEY="$PRE_LAPSE_KEY"
  if [[ "$(lapse_key)" != "$LAPSE_KEY" ]]; then
    # A tick or re-arm landed after the stale check: the watch is alive again.
    echo '{}'
    exit 0
  fi
  LAPSE_FILE="${MARKER_DIR}/claude-bgceiling-lapsenotice-${SAFE_ID}"
  if [[ -f "$LAPSE_FILE" && "$(cat "$LAPSE_FILE" 2>/dev/null)" == "$LAPSE_KEY" ]]; then
    echo '{}'
    exit 0
  fi
  if ! printf '%s' "$LAPSE_KEY" > "$LAPSE_FILE" 2>/dev/null; then
    echo '{}'
    exit 0
  fi
  AGE=$("$CEILING_SH" --status --session "$SESSION_ID" 2>/dev/null | jq -r '.tick_age_s // empty' 2>/dev/null)
  [[ "$AGE" =~ ^[0-9]+$ ]] || AGE="?"
  ARM_COMMAND=$("$CEILING_SH" --arm-command --session "$SESSION_ID" 2>/dev/null)
  NOTICE="BACKGROUND WORK CEILING LAPSED: no ceiling tick for ${AGE}s, so its Monitor most likely expired and was not re-armed. If background work this thread waits on is still running, re-arm now: ${MONITOR_HOW} ${ARM_COMMAND} — ${REARM_NOTE} If none is still running, do not re-arm. Either way this is automatic recovery, not status: do not report it to the user."
  jq -n --arg message "$NOTICE" '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $message}}'
  exit 0
fi

blocks=0
if [[ -f "$BLOCKS_FILE" ]]; then
  blocks=$(cat "$BLOCKS_FILE" 2>/dev/null)
  [[ "$blocks" =~ ^[0-9]+$ ]] || blocks=0
fi

ARM_COMMAND=$("$CEILING_SH" --arm-command --session "$SESSION_ID" 2>/dev/null)

if (( blocks >= MAX_BLOCKS )); then
  # Stand down — but loudly, and leave evidence the arm hook keeps resurfacing.
  printf '%s' "$(date -u +%FT%TZ)" > "$BREACH_FILE" 2>/dev/null || true
  printf 'bgwork-ceiling-guard: STOOD DOWN after %s blocked turns — background work is in flight with NO silence ceiling armed for session %s. Chat silence in this thread is now unbounded.\n' \
    "$blocks" "$SAFE_ID" >&2
  log_dir="${CLAUDE_BGWORK_LOG_DIR:-$HOME/.claude/logs}"
  mkdir -p "$log_dir" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$SAFE_ID" "guard-stood-down" "blocks=${blocks}" \
    >> "$log_dir/bgwork-ceiling.log" 2>/dev/null || true
  echo '{}'
  exit 0
fi

blocks=$(( blocks + 1 ))
if ! printf '%s' "$blocks" > "$BLOCKS_FILE" 2>/dev/null; then
  # Cannot count blocks -> cannot bound them. Refuse to start an unbounded
  # block loop; surface instead. (feedback_guard_must_fail_closed.md — the
  # failure is reported, never swallowed into a silent pass.)
  printf 'bgwork-ceiling-guard: cannot write %s — refusing to block unbounded; background work is UNGUARDED for session %s.\n' \
    "$BLOCKS_FILE" "$SAFE_ID" >&2
  echo '{}'
  exit 0
fi

REASON="Do not end this turn yet. Background work is in flight and this thread has no silence ceiling armed, so it can now go quiet indefinitely with no tool call left to warn it — the exact failure this guard exists to prevent. Arm it now: ${MONITOR_HOW} ${ARM_COMMAND} — then finish the turn as you intended. ${REARM_NOTE} The watch stays silent unless the thread actually goes quiet, so it adds no noise to a healthy thread. Do not report the arming to the user; it is bookkeeping, not status."

printf 'bgwork-ceiling-guard: blocking turn end (%s/%s) — background work in flight with no ceiling armed for session %s.\n' \
  "$blocks" "$MAX_BLOCKS" "$SAFE_ID" >&2

jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
exit 0
