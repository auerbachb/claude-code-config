#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PAUSE="$ROOT/.claude/skills/pause/SKILL.md"
SUSPEND="$ROOT/.claude/skills/suspend/SKILL.md"
PAUSE_RESUME="$ROOT/.claude/skills/pause-resume/SKILL.md"
SUSPEND_RESUME="$ROOT/.claude/skills/suspend-resume/SKILL.md"
PHASES="$ROOT/.claude/rules/phase-protocols.md"
SETTINGS="$ROOT/global-settings.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -Eq -- "$2" "$1" || fail "$(basename "$1") missing: $2"; }

has "$PAUSE" 'default: --window 5m'
has "$PAUSE" 'WINDOW_MINUTES=5'
has "$PAUSE" "10#\\\$_RAW"
has "$PAUSE" '1440'
has "$SUSPEND" 'default: --window 15m'
has "$SUSPEND" 'WINDOW_MINUTES=15'
has "$SUSPEND" "10#\\\$_RAW"
has "$SUSPEND" '1440'
has "$PAUSE" 'background-task-shutdown.md'
has "$SUSPEND" 'background-task-shutdown.md'
has "$PAUSE" 'hard stop'
has "$SUSPEND" 'hard-stop exact'

has "$PAUSE_RESUME" 'execution-pause.sh --clear'
has "$SUSPEND_RESUME" 'EXECUTION_PAUSE_SH.*clear --session'
has "$PAUSE_RESUME" 'unless --resume-refill'
has "$SUSPEND_RESUME" 'only with --resume-refill'

for edge in 'A→A' 'A→B' 'B→B' 'B→C'; do has "$PHASES" "$edge"; done
has "$PHASES" 'execution-pause.sh --status'
has "$PHASES" 'refill.paused'

jq -e '
  .hooks.PreToolUse[] | select(.matcher == "Agent|Workflow|Monitor|Bash")
  | .hooks[] | select(.command | endswith("/pause-launch-gate.sh"))
' "$SETTINGS" >/dev/null || fail "PreToolUse pause launch gate is not registered"
jq -e '
  .hooks.SubagentStop[].hooks[]
  | select(.command | endswith("/background-task-complete.sh"))
' "$SETTINGS" >/dev/null || fail "SubagentStop registry completion hook is not registered"

echo "OK: pause/suspend command contract tests passed"
