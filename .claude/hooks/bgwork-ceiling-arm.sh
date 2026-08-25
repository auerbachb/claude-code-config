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
REGISTRY_SH="${SCRIPT_DIR%/hooks}/scripts/background-task-registry.sh"
SESSION_STATE_SH="${SCRIPT_DIR%/hooks}/scripts/session-state.sh"

SESSION_ID=$(json_field '.session_id')
SESSION_ID="${SESSION_ID:-${CLAUDE_SESSION_ID:-default}}"

TOOL_NAME=$(json_field '.tool_name')
COMMAND=$(json_field '.tool_input.command')
BACKGROUNDED=$(json_field '.tool_input.run_in_background')
CWD=$(json_field '.cwd')
PARENT_AGENT_ID=$(json_field '.agent_id')
TASK_NAME=$(json_field '.tool_input.name // .tool_input.description')
OUTPUT_FILE=$(json_field '.tool_response.outputFile // .tool_response.output_file')
RECOVERY_PATH=$(json_field '.tool_response.worktreePath // .tool_response.worktree_path')

resolve_payload_repo() {
  local key="" payload_examined=0
  if [[ -n "$CWD" && -d "$CWD" && -x "$SESSION_STATE_SH" ]]; then
    payload_examined=1
    if key="$(cd "$CWD" && unset CLAUDE_SESSION_REPO && \
      "$SESSION_STATE_SH" --repo-key 2>/dev/null)"; then
      :
    else
      key=_unknown
    fi
  fi
  if [[ -z "$key" && "$payload_examined" == 0 ]]; then
    key="${CLAUDE_SESSION_REPO:-_unknown}"
  fi
  [[ -n "$key" ]] || key=_unknown
  if [[ "$key" != _unknown && ! "$key" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    key=_unknown
  fi
  printf '%s' "$key" | tr '[:upper:]' '[:lower:]'
}
REPO_KEY="$(resolve_payload_repo)"

REGISTRY_FAILURE_DIR="${CLAUDE_BACKGROUND_TASK_FAILURE_DIR:-${CLAUDE_BGWORK_MARKER_DIR:-/tmp}}"
SAFE_SESSION_ID="${SESSION_ID//[^[:alnum:]_.-]/_}"
REGISTRY_FAILURE_MARKER="$REGISTRY_FAILURE_DIR/claude-background-registry-failed-${SAFE_SESSION_ID:-default}"
REGISTRY_FAILURE_FALLBACK="${HOME:-/tmp}/.claude/claude-background-registry-failed-${SAFE_SESSION_ID:-default}"
REGISTRY_FAILURE_UNRECORDED=0

record_registry_failure() {
  local operation="$1" task_id="$2" rc="$3" line
  line="$(date -u +%FT%TZ)\t${operation}\t${task_id}\t${rc}"
  if mkdir -p "$REGISTRY_FAILURE_DIR" 2>/dev/null && \
     printf '%b\n' "$line" >> "$REGISTRY_FAILURE_MARKER" 2>/dev/null; then
    return 0
  fi
  if mkdir -p "$(dirname "$REGISTRY_FAILURE_FALLBACK")" 2>/dev/null && \
     printf '%b\n' "$line" >> "$REGISTRY_FAILURE_FALLBACK" 2>/dev/null; then
    return 0
  fi
  REGISTRY_FAILURE_UNRECORDED=1
  echo "bgwork-ceiling-arm.sh: CRITICAL: could not record registry failure for $task_id ($operation rc=$rc)" >&2
  return 1
}

register_runtime_task() {
  [[ -n "$1" && -n "$2" ]] || return 0
  local task_id="$1" task_type="$2" name="${3:-$2:$1}"
  if [[ ! -x "$REGISTRY_SH" ]]; then
    record_registry_failure missing_helper "$task_id" 127 || true
    return 0
  fi
  local -a args
  args=(--repo "$REPO_KEY" --register --session "$SESSION_ID" --task-id "$task_id"
        --type "$task_type" --name "$name")
  [[ -n "$PARENT_AGENT_ID" ]] && args+=(--parent-agent "$PARENT_AGENT_ID")
  [[ -n "$OUTPUT_FILE" ]] && args+=(--output-file "$OUTPUT_FILE")
  [[ -n "$RECOVERY_PATH" ]] && args+=(--recovery-path "$RECOVERY_PATH")
  local rc=0
  if [[ -n "$CWD" && -d "$CWD" ]]; then
    (cd "$CWD" && CLAUDE_STATE_LOCK_TIMEOUT=3 CLAUDE_STATE_RMW_MAX_RETRY=0 \
      "$REGISTRY_SH" "${args[@]}") >/dev/null 2>&1 || rc=$?
  else
    CLAUDE_STATE_LOCK_TIMEOUT=3 CLAUDE_STATE_RMW_MAX_RETRY=0 \
      "$REGISTRY_SH" "${args[@]}" >/dev/null 2>&1 || rc=$?
  fi
  (( rc == 0 )) || record_registry_failure register "$task_id" "$rc"
}

transition_runtime_task() {
  [[ -n "$1" ]] || return 0
  local task_id="$1" status="$2"
  if [[ ! -x "$REGISTRY_SH" ]]; then
    record_registry_failure missing_helper "$task_id" 127 || true
    return 0
  fi
  local -a args
  args=(--repo "$REPO_KEY" --transition --session "$SESSION_ID" --task-id "$task_id" --status "$status")
  local rc=0
  if [[ -n "$CWD" && -d "$CWD" ]]; then
    (cd "$CWD" && CLAUDE_STATE_LOCK_TIMEOUT=3 CLAUDE_STATE_RMW_MAX_RETRY=0 \
      "$REGISTRY_SH" "${args[@]}") >/dev/null 2>&1 || rc=$?
  else
    CLAUDE_STATE_LOCK_TIMEOUT=3 CLAUDE_STATE_RMW_MAX_RETRY=0 \
      "$REGISTRY_SH" "${args[@]}" >/dev/null 2>&1 || rc=$?
  fi
  (( rc == 0 )) || record_registry_failure transition "$task_id" "$rc"
}

# Capture the exact runtime identity while the structured tool result is still
# available. The old marker recorded only "Agent"/"Bash"/etc., which was enough
# for liveness but could not later drive TaskStop.
case "$TOOL_NAME" in
  Agent)
    RUNTIME_TASK_ID=$(json_field '.tool_response.agentId')
    [[ -n "$RUNTIME_TASK_ID" ]] && register_runtime_task "$RUNTIME_TASK_ID" agent "${TASK_NAME:-agent:$RUNTIME_TASK_ID}"
    ;;
  Workflow)
    RUNTIME_TASK_ID=$(json_field '.tool_response.taskId // .tool_response.backgroundTaskId // .tool_response.workflowId')
    [[ -n "$RUNTIME_TASK_ID" ]] && register_runtime_task "$RUNTIME_TASK_ID" workflow "${TASK_NAME:-workflow:$RUNTIME_TASK_ID}"
    ;;
  Monitor)
    RUNTIME_TASK_ID=$(json_field '.tool_response.taskId')
    [[ -n "$RUNTIME_TASK_ID" ]] && register_runtime_task "$RUNTIME_TASK_ID" monitor "${TASK_NAME:-monitor:$RUNTIME_TASK_ID}"
    ;;
  Bash)
    if [[ "$BACKGROUNDED" == true ]]; then
      RUNTIME_TASK_ID=$(json_field '.tool_response.backgroundTaskId')
      [[ -n "$RUNTIME_TASK_ID" ]] && register_runtime_task "$RUNTIME_TASK_ID" bash "${TASK_NAME:-bash:$RUNTIME_TASK_ID}"
    fi
    ;;
  TaskStop)
    STOPPED_TASK_ID=$(json_field '.tool_response.task_id // .tool_response.taskId')
    REQUESTED_TASK_ID=$(json_field '.tool_input.task_id // .tool_input.taskId')
    STOP_ERROR=$(json_field '.tool_response.error // .tool_response.errorMessage')
    STOP_STATUS=$(json_field '.tool_response.status')
    if [[ -n "$STOPPED_TASK_ID" && -z "$STOP_ERROR" && "$STOP_STATUS" != failed && "$STOP_STATUS" != error ]]; then
      transition_runtime_task "$STOPPED_TASK_ID" stopped
    elif [[ -n "$REQUESTED_TASK_ID" ]]; then
      transition_runtime_task "$REQUESTED_TASK_ID" stop_failed
    fi
    ;;
esac

# Runtime identity tracking is safety-critical and independent of the optional
# silence-ceiling helper. A partial installation may lose reminders, but it
# must not lose the exact IDs needed by /end and /pause.
[[ -x "$CEILING_SH" ]] || exit "$REGISTRY_FAILURE_UNRECORDED"

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

exit "$REGISTRY_FAILURE_UNRECORDED"
