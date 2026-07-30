#!/bin/bash
# Background-work ceiling — arming half (PostToolUse hook, all tools).
#
# Two jobs, both driven off the tool call that just ran:
#
#   1. Notice that the thread started background work it will wait on — a
#      subagent spawn, a backgrounded Bash command, a Workflow, or a Monitor —
#      and record it via bgwork-ceiling.sh --note-started.
#   2. While background work is in flight and the ceiling watch is NOT armed,
#      inject the exact arming call into the agent's context, so arming happens
#      as part of the same step rather than as a separate thing to remember.
#
# Arming itself is recognised by the `--tick` sentinel in the command text, so
# the ceiling watch is never miscounted as new background work (which would
# leave the guard permanently unsatisfiable).
#
# The companion Stop hook (bgwork-ceiling-guard.sh) is what makes this
# non-optional: this hook only advises, it cannot stop a turn from ending.

STDIN_JSON=$(cat)

emit_context() {
  jq -n --arg message "$1" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $message
    }
  }'
}

json_field() {
  printf '%s' "$STDIN_JSON" | jq -r "$1 // empty" 2>/dev/null
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CEILING_SH="${SCRIPT_DIR%/hooks}/scripts/bgwork-ceiling.sh"
[[ -x "$CEILING_SH" ]] || exit 0

SESSION_ID=$(json_field '.session_id')
SESSION_ID="${SESSION_ID:-${CLAUDE_SESSION_ID:-default}}"

TOOL_NAME=$(json_field '.tool_name')
COMMAND=$(json_field '.tool_input.command')
BACKGROUNDED=$(json_field '.tool_input.run_in_background')

# --- 1. Is this call arming the ceiling watch? -------------------------------
# Matched on the command text rather than the tool name, so arming still
# registers if the watch is started some other way (e.g. a backgrounded Bash).
#
# The match is against the WHOLE generated command, not just a `--tick`
# substring: in this repo plenty of commands merely mention the sentinel (a
# grep, a docs edit, a test run), and treating one of those as "armed" would
# satisfy the Stop hook with no watch actually running — a guard defeated by
# talking about it. Regenerating the expected command here also keeps detection
# in step with --arm-command automatically if its shape ever changes.
if [[ "$COMMAND" == *bgwork-ceiling.sh* ]]; then
  EXPECTED_ARM=$("$CEILING_SH" --arm-command --session "$SESSION_ID" 2>/dev/null)
  if [[ -n "$EXPECTED_ARM" && "$COMMAND" == *"$EXPECTED_ARM"* ]]; then
    "$CEILING_SH" --record-armed --session "$SESSION_ID" || true
    echo '{}'
    exit 0
  fi
fi

# --- 2. Did this call start background work the thread will wait on? --------
started=0
case "$TOOL_NAME" in
  Agent|Workflow|Monitor)
    started=1
    ;;
  Bash)
    [[ "$BACKGROUNDED" == "true" ]] && started=1
    ;;
esac

if (( started == 1 )); then
  "$CEILING_SH" --note-started "$TOOL_NAME" --session "$SESSION_ID" || true
fi

# --- 3. Advise arming while in flight and unarmed ----------------------------
if "$CEILING_SH" --check --session "$SESSION_ID"; then
  echo '{}'
  exit 0
fi

ARM_COMMAND=$("$CEILING_SH" --arm-command --session "$SESSION_ID" 2>/dev/null)
if [[ -z "$ARM_COMMAND" ]]; then
  echo '{}'
  exit 0
fi

MARKER_DIR="${CLAUDE_BGWORK_MARKER_DIR:-/tmp}"
SAFE_ID="${SESSION_ID//[^[:alnum:]_.-]/_}"
SAFE_ID="${SAFE_ID:-default}"

UNGUARDED_NOTE=""
if [[ -f "${MARKER_DIR}/claude-bgceiling-unguarded-${SAFE_ID}" ]]; then
  UNGUARDED_NOTE="This thread is currently UNGUARDED — the Stop hook already blocked twice and stood down. Arm it now. "
fi

# The call that STARTED the work always gets the advisory — that is the step
# arming belongs in. Every later call while still unarmed is a reminder, and
# reminders are rate-limited so a burst of tool calls cannot replay this whole
# paragraph into context on each one. The Stop hook, not repetition, is what
# makes arming actually happen.
#
# The rate limit deliberately does NOT apply once the guard has stood down: at
# that point the thread really is unguarded, and quietly throttling the only
# remaining signal would be the same silent degradation this whole change
# exists to remove (feedback_guard_must_fail_closed.md).
ADVISED_FILE="${MARKER_DIR}/claude-bgceiling-advised-${SAFE_ID}"
COOLDOWN_S="${CLAUDE_BGWORK_ADVISE_COOLDOWN_S:-60}"
[[ "$COOLDOWN_S" =~ ^[0-9]+$ ]] || COOLDOWN_S=60

if (( started == 0 )) && [[ -z "$UNGUARDED_NOTE" ]] && [[ -f "$ADVISED_FILE" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    last_advice=$(stat -f %m "$ADVISED_FILE" 2>/dev/null)
  else
    last_advice=$(stat -c %Y "$ADVISED_FILE" 2>/dev/null)
  fi
  if [[ -n "$last_advice" ]]; then
    advice_age=$(( $(date +%s) - last_advice ))
    # A negative age means a future-dated marker (clock rollback) — treat it as
    # stale and re-advise rather than suppressing indefinitely.
    if (( advice_age >= 0 && advice_age < COOLDOWN_S )); then
      echo '{}'
      exit 0
    fi
  fi
fi
touch "$ADVISED_FILE" 2>/dev/null || true

emit_context "BACKGROUND WORK CEILING NOT ARMED. ${UNGUARDED_NOTE}This thread has background work in flight, so it can end its turn and go silent with no tool call left to warn it. Arm the ceiling in THIS step, before ending the turn: call the Monitor tool with persistent: true, description \"background-work silence ceiling\", and command: ${ARM_COMMAND} — the watch stays silent unless the thread actually goes quiet, so a thread sending normal heartbeats will never see a message from it. Do not announce the arming to the user; it is bookkeeping, not status."

exit 0
