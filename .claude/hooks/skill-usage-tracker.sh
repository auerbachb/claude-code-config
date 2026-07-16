#!/bin/bash
# Skill usage tracker — PostToolUse hook (matcher: Skill)
#
# On each Skill tool invocation: parses the skill name and hands it to the
# shared recorder, which appends one line to ~/.claude/skill-usage.log and
# increments use_count / last_used in the live skill-usage CSV.
#
# Input  (stdin) : JSON with {tool_name, tool_input, cwd, ...}
# Output (stdout): empty JSON object (non-blocking)
# Exit code      : always 0 — never blocks tool execution
#
# This is one of two capture paths. User-typed slash commands never reach a
# Skill tool call on current builds (the prompt arrives pre-expanded), so
# skill-command-tracker.sh captures those at UserPromptSubmit. The recorder
# owns storage layout and the marker-based dedupe that keeps an invocation
# seen by both paths at exactly one line — see lib/skill-usage-recorder.sh.

set -uo pipefail

# Consume stdin
INPUT=$(cat)

# Always emit empty JSON and never fail — this hook is non-blocking
trap 'echo "{}"; exit 0' EXIT

RECORDER="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/skill-usage-recorder.sh"
[ -r "$RECORDER" ] || exit 0
# shellcheck source=lib/skill-usage-recorder.sh
. "$RECORDER" 2>/dev/null || exit 0

# Parse tool_name and skill name from tool_input.
SKILL_NAME=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tool = (d.get("tool_name") or "").strip()
if tool != "Skill":
    sys.exit(0)
ti = d.get("tool_input") or {}
skill = (ti.get("skill") or "").strip()
# Strip plugin prefix (e.g. "anthropic-skills:pdf" -> "pdf")
if ":" in skill:
    skill = skill.split(":", 1)[1]
# Basic sanitization: reject anything that is not safe for a CSV key
if not skill or any(c in skill for c in [",", "\n", "\r", "\"", "/"]):
    sys.exit(0)
print(skill)
' 2>/dev/null) || exit 0

[ -z "$SKILL_NAME" ] && exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)

record_skill_usage "$SKILL_NAME" "$SESSION_ID" posttool

exit 0
