#!/usr/bin/env bash
# Session execution-pause gate — PreToolUse hook.
# Blocks every Agent, Workflow, and Monitor launch plus background Bash while
# `/end` or `/pause` is winding down this exact repo/session. Foreground
# Bash remains available for checkpoint, TaskStop bookkeeping, and handoffs.

set -uo pipefail
INPUT="$(cat 2>/dev/null || true)"

field() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null; }

TOOL_NAME="$(field '.tool_name')"
BACKGROUND="$(field '.tool_input.run_in_background')"
case "$TOOL_NAME" in
  Agent|Workflow|Monitor) ;;
  Bash) [[ "$BACKGROUND" == true ]] || exit 0 ;;
  *) exit 0 ;;
esac

SESSION_ID="$(field '.session_id')"
CWD="$(field '.cwd')"
[[ -n "$SESSION_ID" ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAUSE_SH="${SCRIPT_DIR%/hooks}/scripts/execution-pause.sh"
SESSION_STATE_SH="${SCRIPT_DIR%/hooks}/scripts/session-state.sh"

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
if [[ ! -x "$PAUSE_SH" ]]; then
  MARKER_DIR="${CLAUDE_EXECUTION_PAUSE_MARKER_DIR:-$HOME/.claude/execution-pause-markers}"
  scope_hash() {
    local digest=""
    if command -v sha256sum >/dev/null 2>&1; then
      digest="$(printf '%s\0%s' "$REPO_KEY" "$SESSION_ID" | sha256sum | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
      digest="$(printf '%s\0%s' "$REPO_KEY" "$SESSION_ID" | shasum -a 256 | awk '{print $1}')"
    fi
    [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    printf '%s' "$digest" | tr '[:upper:]' '[:lower:]'
  }
  SCOPE_HASH="$(scope_hash)" || {
    echo "BLOCKED: execution-pause helper is unavailable and marker scope cannot be resolved; refusing to start $TOOL_NAME." >&2
    exit 2
  }
  MARKER="$MARKER_DIR/claude-execution-pause-v2-$SCOPE_HASH"
  if [[ -f "$MARKER" ]]; then
    echo "BLOCKED: execution-pause helper is unavailable while an active repo/session marker exists; refusing to start $TOOL_NAME." >&2
    exit 2
  fi
  echo "pause-launch-gate.sh: execution-pause.sh unavailable; no active marker found" >&2
  exit 0
fi

STATUS=""
RC=0
if [[ -n "$CWD" && -d "$CWD" ]]; then
  STATUS="$(cd "$CWD" && CLAUDE_STATE_LOCK_TIMEOUT=3 \
    "$PAUSE_SH" --repo "$REPO_KEY" --status --session "$SESSION_ID" 2>/dev/null)" || RC=$?
else
  STATUS="$(CLAUDE_STATE_LOCK_TIMEOUT=3 \
    "$PAUSE_SH" --repo "$REPO_KEY" --status --session "$SESSION_ID" 2>/dev/null)" || RC=$?
fi

# A confirmed active state includes the marker-backed fail-closed path when
# session-state.json became unreadable after the pause was armed. Hook parse or
# dependency failures stay fail-open so a malformed payload cannot brick work.
if [[ "$RC" -eq 0 && "$STATUS" == active ]]; then
  echo "BLOCKED: background launches are closed for this session. Finish the wind-down, then run its matching resume command: /end-resume for /end; /pause-resume for /pause. Refusing to start $TOOL_NAME." >&2
  exit 2
fi
if [[ "$RC" -eq 6 ]]; then
  echo "BLOCKED: pause state is lock-contended and cannot be verified within the launch-hook budget; refusing to start $TOOL_NAME." >&2
  exit 2
fi
exit 0
