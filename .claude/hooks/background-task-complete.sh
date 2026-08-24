#!/usr/bin/env bash
# SubagentStop hook — mark the exact runtime agent terminal in the registry.

set -uo pipefail
INPUT="$(cat 2>/dev/null || true)"
field() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null; }

SESSION_ID="$(field '.session_id')"
AGENT_ID="$(field '.agent_id')"
CWD="$(field '.cwd')"
[[ -n "$SESSION_ID" && -n "$AGENT_ID" ]] || exit 0

STATUS="$(field '.status')"
case "$STATUS" in
  stopped) TARGET=stopped ;;
  failed|error) TARGET=failed ;;
  *) TARGET="done" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_SH="${SCRIPT_DIR%/hooks}/scripts/background-task-registry.sh"
[[ -x "$REGISTRY_SH" ]] || exit 0
if [[ -n "$CWD" && -d "$CWD" ]]; then
  (cd "$CWD" && "$REGISTRY_SH" --transition --session "$SESSION_ID" \
    --task-id "$AGENT_ID" --status "$TARGET") >/dev/null 2>&1 || true
else
  "$REGISTRY_SH" --transition --session "$SESSION_ID" --task-id "$AGENT_ID" \
    --status "$TARGET" >/dev/null 2>&1 || true
fi
exit 0
