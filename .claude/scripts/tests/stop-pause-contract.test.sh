#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STOP="$ROOT/.claude/skills/stop/SKILL.md"
PAUSE="$ROOT/.claude/skills/pause/SKILL.md"
STOP_RESUME="$ROOT/.claude/skills/stop-resume/SKILL.md"
PAUSE_RESUME="$ROOT/.claude/skills/pause-resume/SKILL.md"
PM="$ROOT/.claude/skills/pm/SKILL.md"
PHASES="$ROOT/.claude/rules/phase-protocols.md"
SETTINGS="$ROOT/global-settings.json"
ARM_HOOK="$ROOT/.claude/hooks/bgwork-ceiling-arm.sh"
COMPLETE_HOOK="$ROOT/.claude/hooks/background-task-complete.sh"
GATE_HOOK="$ROOT/.claude/hooks/pause-launch-gate.sh"
REGISTRY="$ROOT/.claude/scripts/background-task-registry.sh"
PAUSE_SCRIPT="$ROOT/.claude/scripts/execution-pause.sh"
HANDOFF_CONTEXT="$ROOT/.claude/scripts/portable-handoff-context.sh"
HANDOFF_PUBLISH="$ROOT/.claude/scripts/portable-handoff-publish.sh"
HANDOFF_LINT="$ROOT/.claude/scripts/portable-handoff-lint.sh"
CHECKPOINT="$ROOT/.claude/hooks/checkpoint-handoff.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -Eq -- "$2" "$1" || fail "$(basename "$1") missing: $2"; }

has "$STOP" '^name: stop$'
has "$STOP" 'default: --window 5m'
has "$STOP" 'WINDOW_MINUTES=5'
has "$STOP" "10#\\\$_NORMALIZED"
has "$STOP" '1440'
has "$PAUSE" '^name: pause$'
has "$PAUSE" 'default: --window 15m'
has "$PAUSE" 'WINDOW_MINUTES=15'
has "$PAUSE" "10#\\\$_NORMALIZED"
has "$PAUSE" '1440'
has "$STOP" 'background-task-shutdown.md'
has "$PAUSE" 'background-task-shutdown.md'
has "$STOP" 'hard stop'
has "$PAUSE" 'hard stop'
has "$PAUSE" 'hard-stop exact'
has "$ARM_HOOK" 'CLAUDE_STATE_LOCK_TIMEOUT=3'
has "$ARM_HOOK" 'CLAUDE_STATE_RMW_MAX_RETRY=0'
has "$COMPLETE_HOOK" 'CLAUDE_STATE_LOCK_TIMEOUT=3'
has "$COMPLETE_HOOK" 'CLAUDE_STATE_RMW_MAX_RETRY=0'
has "$GATE_HOOK" 'CLAUDE_STATE_LOCK_TIMEOUT=3'
has "$GATE_HOOK" 'RC.*-eq 6'
has "$PAUSE_SCRIPT" 'execution-pause-markers'
has "$PAUSE_SCRIPT" 'chmod 700'
has "$REGISTRY" 'failed|stop_failed|rearmed'
has "$PAUSE" 'PAUSE_PERSISTED!=0'
has "$PAUSE" 'PAUSE_PERSISTED != 0.*INCOMPLETE SHUTDOWN'
has "$PAUSE" '\.repos\[.*\]\.pause='
has "$PAUSE_RESUME" 'STATE_KEY="suspend"'
has "$PAUSE_RESUME" 'handoffs/suspend-'
has "$PAUSE_RESUME" 'MARKER_NAME.*suspend-'
has "$PAUSE_RESUME" 'STATE_KEY="suspend"'
has "$PAUSE_RESUME" 'paused_at // \.suspended_at'

has "$STOP_RESUME" 'execution-pause.sh --clear'
has "$PAUSE_RESUME" 'EXECUTION_PAUSE_SH.*clear --session'
has "$STOP_RESUME" 'unless --resume-refill'
has "$PAUSE_RESUME" 'only with --resume-refill'
has "$PAUSE_SCRIPT" 'stop|pause'
has "$PM" 'rolling-window limit is temporary and auto-resuming'
has "$PM" 'execution-pause\.sh --activate --command pause --window-minutes 0'
has "$PM" 'Do not invoke the user-only `/stop`'
has "$PM" 'execute `/stop/SKILL\.md` Steps 0–6 inline'
has "$PM" '/stop-resume --resume-refill'
has "$PAUSE_RESUME" 'stopped: true.*rearmed.*not'
has "$PAUSE_RESUME" '--status rearming --from-status stopped'
has "$PAUSE_RESUME" 'concurrent invocations single-writer'
has "$PAUSE" 'Immediate branch.*WINDOW_MINUTES == 0'
has "$PAUSE" 'MARKER_AUTO_DISCOVERABLE=false'
has "$PAUSE" 'Repository:.*exact owner/repo'
has "$PAUSE_RESUME" 'Repository:.*owner/repo'
has "$STOP_RESUME" '--from-status stopped'
has "$REGISTRY" 'rearming'
has "$STOP" 'portable-handoff-context\.sh'
has "$STOP" 'portable-handoff-publish\.sh'
has "$STOP" 'one deterministic filename'
has "$STOP" 'tracked and untracked'

# Behavioral smoke for the helper chain named by the /stop workflow: collect
# exact dirty state, stage those bytes, and update one deterministic target.
TMP_HANDOFF=$(mktemp -d)
trap 'rm -rf "$TMP_HANDOFF"' EXIT
git init -q "$TMP_HANDOFF/repo"
git -C "$TMP_HANDOFF/repo" symbolic-ref HEAD refs/heads/main
git -C "$TMP_HANDOFF/repo" config user.email "test@example.com"
git -C "$TMP_HANDOFF/repo" config user.name "Test"
printf 'seed\n' >"$TMP_HANDOFF/repo/tracked.txt"
git -C "$TMP_HANDOFF/repo" add tracked.txt
git -C "$TMP_HANDOFF/repo" commit -qm seed
git -C "$TMP_HANDOFF/repo" remote add origin https://github.com/test/portable-stop.git
printf 'changed\n' >"$TMP_HANDOFF/repo/tracked.txt"
printf 'new\n' >"$TMP_HANDOFF/repo/untracked.txt"
CONTEXT_JSON=$("$HANDOFF_CONTEXT" --cwd "$TMP_HANDOFF/repo" --session contract --no-remote)
jq -e '
  .repository.identity == "test/portable-stop"
  and .working_copy.tracked_changes == ["tracked.txt"]
  and .working_copy.untracked_changes == ["untracked.txt"]
' <<<"$CONTEXT_JSON" >/dev/null || fail "portable handoff context did not preserve tracked and untracked state"
(cd "$TMP_HANDOFF/repo" && "$CHECKPOINT" --stdout --no-remote) >"$TMP_HANDOFF/staged.md"
PUBLISHED_ONE=$("$HANDOFF_PUBLISH" --input "$TMP_HANDOFF/staged.md" \
  --repo test/portable-stop --session contract --out-dir "$TMP_HANDOFF/out" \
  --lint "$HANDOFF_LINT" --lint-root "$ROOT")
PUBLISHED_TWO=$("$HANDOFF_PUBLISH" --input "$TMP_HANDOFF/staged.md" \
  --repo test/portable-stop --session contract --out-dir "$TMP_HANDOFF/out" \
  --lint "$HANDOFF_LINT" --lint-root "$ROOT")
[[ "$PUBLISHED_ONE" == "$PUBLISHED_TWO" ]] || fail "portable handoff publisher target is not deterministic"
cmp -s "$TMP_HANDOFF/staged.md" "$PUBLISHED_TWO" || fail "portable handoff publisher changed the staged bytes"

[[ ! -e "$ROOT/.claude/skills/suspend" ]] || fail "retired suspend skill still exists"
[[ ! -e "$ROOT/.claude/skills/suspend-resume" ]] || fail "retired suspend-resume skill still exists"

DUPLICATE_NAMES=$(find "$ROOT/.claude/skills" -name SKILL.md -type f -exec \
  awk '/^name: / { print substr($0, 7); exit }' {} \; | sort | uniq -d)
[[ -z "$DUPLICATE_NAMES" ]] || fail "duplicate skill name(s): $DUPLICATE_NAMES"

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

echo "OK: stop/pause command contract tests passed"
