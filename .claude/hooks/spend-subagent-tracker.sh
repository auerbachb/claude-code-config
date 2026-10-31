#!/bin/bash
# spend-subagent-tracker.sh — SubagentStop hook
#
# Captures metadata-only assistant usage rows from each subagent's own transcript
# (issue #1877). Actual model attribution comes from transcript message metadata;
# an agent definition's model is recorded only as a requested default.
#
# Input  (stdin) : SubagentStop JSON payload with keys:
#                    session_id, cwd, agent_id, agent_type, agent_transcript_path
# Output (stdout): empty JSON object (non-blocking, hook protocol)
# Exit code      : always 0 — never blocks subagent lifecycle
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

# Parse payload fields
SESSION_ID="$(_spend_payload_field "$INPUT" session_id)"

AGENT_ID="$(_spend_payload_field "$INPUT" agent_id)"

AGENT_TYPE="$(_spend_payload_field "$INPUT" agent_type)"

TRANSCRIPT_PATH="$(_spend_payload_field "$INPUT" agent_transcript_path)"

CWD="$(_spend_payload_field "$INPUT" cwd)"
SESSION_ID="$(_spend_resolve_session "$SESSION_ID")"

REPO_ROOT=""
REPO_SLUG=""
if [ "${CLAUDE_SPEND_TELEMETRY_RESUME:-}" = "1" ]; then
  RESUME_REPO_FIELDS="$(python3 -c '
import json, os, re, sys
try:
    p=json.load(sys.stdin)
except Exception:
    p={}
root=p.get("repo_root", "")
slug=p.get("repo_slug", "")
if not isinstance(root,str) or len(root)>4096 or (root and not os.path.isabs(root)) or any(ord(c)<32 for c in root): root=""
if not isinstance(slug,str) or len(slug)>255 or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+",slug): slug=""
print(root.replace("\x1f", "")+"\x1f"+slug.replace("\x1f", ""))
' <<<"$INPUT" 2>/dev/null)" || RESUME_REPO_FIELDS=$''
  IFS=$'' read -r REPO_ROOT REPO_SLUG <<< "$RESUME_REPO_FIELDS"
else
  if [ -n "$CWD" ]; then
    REPO_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
    REPO_SLUG="$(_spend_repo_slug_from_cwd "$CWD")"
  fi
fi

REQUESTED_MODEL="$(_spend_requested_model_from_agent_type "$AGENT_TYPE")"
REQUESTED_SOURCE="unavailable"
[ -n "$REQUESTED_MODEL" ] && REQUESTED_SOURCE="agent_frontmatter_default"

if [ -f "$TRANSCRIPT_PATH" ]; then
  record_spend_transcript "$TRANSCRIPT_PATH" "inline" "$SESSION_ID" "$AGENT_ID" \
    "$AGENT_TYPE" "$CWD" "$REQUESTED_MODEL" "$REQUESTED_SOURCE" "subagent" \
    "$REPO_ROOT" "$REPO_SLUG"
else
  # Keep an event denominator even when the installed runtime omits the child
  # transcript path. The actual model and usage remain explicitly unavailable.
  EVENT_KEY="$(_spend_event_key "$SESSION_ID" "$AGENT_ID" subagent_transcript_missing)"
  _spend_append_v2 "subagent_stop" "inline" "unknown" "$AGENT_TYPE" \
    "$SESSION_ID" "$AGENT_ID" "" "$EVENT_KEY" "$REPO_ROOT" "unknown" \
    "$REQUESTED_MODEL" "$REQUESTED_SOURCE" "" "unavailable" "" "" "" "" "" \
    "unsupported:no_authoritative_per_event_cost_field" "" "unknown" \
    "subagent" "unsupported:agent_transcript_path_missing" || true
fi

exit 0
