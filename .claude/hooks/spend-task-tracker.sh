#!/bin/bash
# spend-task-tracker.sh — metadata-only TaskCreated/TaskCompleted recorder.
# Human task subject and description fields are intentionally ignored.

set -uo pipefail
INPUT=$(cat)
trap 'echo "{}"; exit 0' EXIT

RECORDER="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/spend-telemetry-recorder.sh"
[ -r "$RECORDER" ] || exit 0
# shellcheck source=lib/spend-telemetry-recorder.sh
. "$RECORDER" 2>/dev/null || exit 0

HOOK_EVENT="$(_spend_payload_field "$INPUT" hook_event_name)"
TASK_ID="$(_spend_payload_field "$INPUT" task_id)"
SESSION_ID="$(_spend_payload_field "$INPUT" session_id)"
CWD="$(_spend_payload_field "$INPUT" cwd)"
AGENT_ID="$(_spend_payload_field "$INPUT" agent_id)"

case "$HOOK_EVENT" in
  TaskCreated) record_spend_task_lifecycle "created" "$TASK_ID" "$SESSION_ID" "$CWD" "$AGENT_ID" ;;
  TaskCompleted) record_spend_task_lifecycle "completed" "$TASK_ID" "$SESSION_ID" "$CWD" "$AGENT_ID" ;;
esac

exit 0
