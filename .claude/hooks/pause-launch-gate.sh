#!/usr/bin/env bash
# Session execution-pause gate — PreToolUse hook.
# Blocks every Agent, Workflow, and Monitor launch plus background Bash while
# `/pause` or `/suspend` is winding down this exact repo/session. Foreground
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
[[ -x "$PAUSE_SH" ]] || exit 0

STATUS=""
RC=0
if [[ -n "$CWD" && -d "$CWD" ]]; then
  STATUS="$(cd "$CWD" && "$PAUSE_SH" --status --session "$SESSION_ID" 2>/dev/null)" || RC=$?
else
  STATUS="$("$PAUSE_SH" --status --session "$SESSION_ID" 2>/dev/null)" || RC=$?
fi

# A confirmed active state includes the marker-backed fail-closed path when
# session-state.json became unreadable after the pause was armed. Hook parse or
# dependency failures stay fail-open so a malformed payload cannot brick work.
if [[ "$RC" -eq 0 && "$STATUS" == active ]]; then
  echo "BLOCKED: background launches are paused for this session. Finish the wind-down or run /pause-resume (or /suspend-resume) before starting $TOOL_NAME." >&2
  exit 2
fi
exit 0
