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
SESSION_STATE_SH="${SCRIPT_DIR%/hooks}/scripts/session-state.sh"
FAILURE_DIR="${CLAUDE_BACKGROUND_TASK_FAILURE_DIR:-${CLAUDE_BGWORK_MARKER_DIR:-/tmp}}"
SAFE_SESSION="${SESSION_ID//[^[:alnum:]_.-]/_}"
FAILURE_MARKER="$FAILURE_DIR/claude-background-registry-failed-${SAFE_SESSION:-default}"
FAILURE_FALLBACK="${HOME:-/tmp}/.claude/claude-background-registry-failed-${SAFE_SESSION:-default}"

resolve_payload_repo() {
  local key=""
  if [[ -n "$CWD" && -d "$CWD" && -x "$SESSION_STATE_SH" ]]; then
    key="$(cd "$CWD" && unset CLAUDE_SESSION_REPO && \
      "$SESSION_STATE_SH" --repo-key 2>/dev/null)" || key=""
  fi
  if [[ -z "$key" || "$key" == _unknown ]]; then
    key="${CLAUDE_SESSION_REPO:-${key:-_unknown}}"
  fi
  if [[ "$key" != _unknown && ! "$key" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    key=_unknown
  fi
  printf '%s' "$key" | tr '[:upper:]' '[:lower:]'
}
REPO_KEY="$(resolve_payload_repo)"

record_failure() {
  local rc="$1" line
  line="$(date -u +%FT%TZ)\ttransition\t${AGENT_ID}\t${rc}"
  if mkdir -p "$FAILURE_DIR" 2>/dev/null && printf '%b\n' "$line" >> "$FAILURE_MARKER" 2>/dev/null; then
    return 0
  fi
  if mkdir -p "$(dirname "$FAILURE_FALLBACK")" 2>/dev/null && printf '%b\n' "$line" >> "$FAILURE_FALLBACK" 2>/dev/null; then
    return 0
  fi
  echo "background-task-complete.sh: CRITICAL: could not record failed terminal transition for $AGENT_ID" >&2
  return 1
}

if [[ ! -x "$REGISTRY_SH" ]]; then
  record_failure 127 || exit 1
  exit 0
fi
RC=0
if [[ -n "$CWD" && -d "$CWD" ]]; then
  (cd "$CWD" && "$REGISTRY_SH" --repo "$REPO_KEY" --transition --session "$SESSION_ID" \
    --task-id "$AGENT_ID" --status "$TARGET") >/dev/null 2>&1 || RC=$?
else
  "$REGISTRY_SH" --repo "$REPO_KEY" --transition --session "$SESSION_ID" --task-id "$AGENT_ID" \
    --status "$TARGET" >/dev/null 2>&1 || RC=$?
fi
if (( RC != 0 )); then
  record_failure "$RC" || exit 1
fi
exit 0
