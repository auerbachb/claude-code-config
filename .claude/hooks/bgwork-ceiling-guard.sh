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

# Nothing to guard, or already armed — clear any block counter and get out of
# the way. The counter is per-stretch-of-unarmed-work, not per-session.
if "$CEILING_SH" --check --session "$SESSION_ID"; then
  rm -f "$BLOCKS_FILE" 2>/dev/null || true
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

REASON="Do not end this turn yet. Background work is in flight and this thread has no silence ceiling armed, so it can now go quiet indefinitely with no tool call left to warn it — the exact failure this guard exists to prevent. Arm it now: call the Monitor tool with persistent: true, description \"background-work silence ceiling\", and command: ${ARM_COMMAND} — then finish the turn as you intended. The watch stays silent unless the thread actually goes quiet, so it adds no noise to a healthy thread. Do not report the arming to the user; it is bookkeeping, not status."

printf 'bgwork-ceiling-guard: blocking turn end (%s/%s) — background work in flight with no ceiling armed for session %s.\n' \
  "$blocks" "$MAX_BLOCKS" "$SAFE_ID" >&2

jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
exit 0
