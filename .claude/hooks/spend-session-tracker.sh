#!/bin/bash
# spend-session-tracker.sh — SessionStart hook
#
# Captures session-level model tier so standalone threads are attributable
# in the spend/thread-type telemetry log (issue #710).
#
# Records ONE line to ~/.claude/spend-telemetry.log on each new session startup
# (exec_type=thread, event_type=session_start). Compact/resume/clear events are
# skipped because they fire inside a live session, not at a new thread boundary.
#
# Input  (stdin) : SessionStart JSON payload with keys:
#                    session_id, model, source
#                  source in {startup, resume, clear, compact}
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

# Parse payload fields
SESSION_SOURCE=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("source") or "")
except Exception:
    print("")
' 2>/dev/null) || SESSION_SOURCE=""

# Compact/resume/clear fire inside a live session — not a new thread boundary.
# An absent source (older harness) is treated conservatively as startup.
case "${SESSION_SOURCE:-startup}" in
  resume|clear|compact)
    # Not a new thread — skip recording.
    exit 0
    ;;
esac

SESSION_ID=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("session_id") or "")
except Exception:
    print("")
' 2>/dev/null) || SESSION_ID=""

MODEL=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("model") or "")
except Exception:
    print("")
' 2>/dev/null) || MODEL=""

# Normalize model name to tier (lowercase; strip version suffixes).
# Examples: "claude-opus-4-5" -> "opus", "claude-sonnet-4-5" -> "sonnet"
MODEL_TIER=$(printf '%s' "$MODEL" | python3 -c '
import re, sys
raw = sys.stdin.read().strip().lower()
for tier in ("opus", "sonnet", "haiku", "fable"):
    if tier in raw:
        print(tier)
        raise SystemExit(0)
print("unknown")
' 2>/dev/null) || MODEL_TIER="unknown"

record_spend_telemetry "session_start" "thread" "$MODEL_TIER" "session" \
                       "$SESSION_ID" "" ""

exit 0
