#!/bin/bash
# spend-subagent-tracker.sh — SubagentStop hook
#
# Captures each inline Agent-tool subagent completion in the spend/thread-type
# telemetry log (issue #710). Records exec_type=inline so inline pm-worker /
# phase-{a,b,c} runs are distinguishable from standalone thread spend.
#
# Input  (stdin) : SubagentStop JSON payload with keys:
#                    session_id, agent_id, agent_type, agent_transcript_path
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
SESSION_ID=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("session_id") or "")
except Exception:
    print("")
' 2>/dev/null) || SESSION_ID=""

AGENT_ID=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("agent_id") or "")
except Exception:
    print("")
' 2>/dev/null) || AGENT_ID=""

AGENT_TYPE=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("agent_type") or "")
except Exception:
    print("")
' 2>/dev/null) || AGENT_TYPE=""

TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("agent_transcript_path") or "")
except Exception:
    print("")
' 2>/dev/null) || TRANSCRIPT_PATH=""

# Derive model tier from agent_type via frontmatter lookup
MODEL_TIER="$(_spend_model_tier_from_agent_type "$AGENT_TYPE")"

# Best-effort token count from transcript
TOKENS="$(_spend_tokens_from_transcript "$TRANSCRIPT_PATH")"

record_spend_telemetry "subagent_stop" "inline" "$MODEL_TIER" "$AGENT_TYPE" \
                       "$SESSION_ID" "$AGENT_ID" "$TOKENS"

exit 0
