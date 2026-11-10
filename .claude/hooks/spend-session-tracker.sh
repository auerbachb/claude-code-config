#!/bin/bash
# spend-session-tracker.sh — SessionStart hook
#
# Captures session-level model tier so standalone threads are attributable
# in the spend/thread-type telemetry log (issue #710).
#
# Records a model-attributed session_start row and, on SessionEnd, metadata-only
# assistant message usage rows from the main transcript. The message parser
# ignores all content and never persists prompts, code, or tool arguments.
#
# Input  (stdin) : SessionStart JSON payload with keys:
#                    SessionStart: session_id, model, source, cwd, agent_type
#                    SessionEnd: session_id, transcript_path, cwd, agent_type
# Output (stdout): empty JSON object (non-blocking, hook protocol)
# Exit code      : always 0 — never blocks session start
#
# OBSERVATIONAL-ONLY: this hook collects data for audit purposes only. Per
# safety.md §"Anthropic Quota & Spend Authority" the recorded data MUST NOT
# gate any agent decision, spending estimate, or quota check.

set -uo pipefail

# Consume stdin (required by hook protocol)
INPUT=$(cat)

# Always emit empty JSON and never fail
trap 'echo "{}"; exit 0' EXIT

RECORDER="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/spend-telemetry-recorder.sh"
[ -r "$RECORDER" ] || exit 0
# shellcheck source=lib/spend-telemetry-recorder.sh
. "$RECORDER" 2>/dev/null || exit 0

# Parse the hook payload once. Unit-separator is non-whitespace, so Bash 3.2's
# read preserves empty fields; the Python side removes separators/newlines.
PARSED_FIELDS="$(python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    payload = {}
keys = ("hook_event_name", "source", "session_id", "model", "cwd", "agent_type", "transcript_path")
values = []
for key in keys:
    value = payload.get(key) or ""
    if not isinstance(value, str):
        value = ""
    values.append(value.replace("\x1f", "").replace("\t", "").replace("\r", "").replace("\n", ""))
values[0] = values[0] or "SessionStart"
print("\x1f".join(values))
' 2>/dev/null <<< "$INPUT")" || PARSED_FIELDS=$'SessionStart\x1f\x1f\x1f\x1f\x1f\x1f\x1f'
IFS=$'\x1f' read -r HOOK_EVENT SESSION_SOURCE SESSION_ID MODEL CWD AGENT_TYPE TRANSCRIPT_PATH <<< "$PARSED_FIELDS"

SESSION_ID="$(_spend_resolve_session "$SESSION_ID")"
MODEL="$(_spend_payload_field "$INPUT" model)"
AGENT_TYPE="$(_spend_payload_field "$INPUT" agent_type)"

if [ "$HOOK_EVENT" = "SessionEnd" ]; then
  REQUESTED_MODEL="$(_spend_requested_model_from_agent_type "$AGENT_TYPE")"
  REQUESTED_SOURCE="unavailable"
  [ -n "$REQUESTED_MODEL" ] && REQUESTED_SOURCE="agent_frontmatter_default"
  if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    record_spend_transcript "$TRANSCRIPT_PATH" "thread" "$SESSION_ID" "" \
      "$AGENT_TYPE" "$CWD" "$REQUESTED_MODEL" "$REQUESTED_SOURCE" "session"
  else
    EVENT_KEY="$(_spend_event_key "$SESSION_ID" session_end "$TRANSCRIPT_PATH")"
    REPO_ROOT=""
    [ -n "$CWD" ] && REPO_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
    _spend_append_v2 "session_end" "thread" "unknown" "session" "$SESSION_ID" \
      "" "" "$EVENT_KEY" "$REPO_ROOT" "unknown" "$REQUESTED_MODEL" \
      "$REQUESTED_SOURCE" "" "unavailable" "" "" "" "" "" \
      "unsupported:no_authoritative_per_event_cost_field" "" "unknown" \
      "session" "unsupported:transcript_path_missing" || true
  fi
  exit 0
fi

# Compact/resume/clear fire inside a live session — not a new thread boundary.
# An absent source (older harness) is treated conservatively as startup.
case "${SESSION_SOURCE:-startup}" in
  resume|clear|compact)
    # Not a new thread — skip recording.
    exit 0
    ;;
esac

# Normalize model name to tier (lowercase; strip version suffixes).
# Examples: "claude-opus-4-5" -> "opus", "claude-sonnet-4-5" -> "sonnet"
MODEL_TIER="$(_spend_model_family "$MODEL")"
ACTUAL_SOURCE="unavailable"
[ -n "$MODEL" ] && ACTUAL_SOURCE="session_start.model"
REPO_ROOT=""
[ -n "$CWD" ] && REPO_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"

_spend_append_v2 "session_start" "thread" "$MODEL_TIER" "session" \
  "$SESSION_ID" "" "" "" "$REPO_ROOT" "unknown" "" "unavailable" \
  "$MODEL" "$ACTUAL_SOURCE" "" "" "" "" "" \
  "unsupported:no_authoritative_per_event_cost_field" "" "unknown" \
  "session_start" "unavailable" || true

exit 0
