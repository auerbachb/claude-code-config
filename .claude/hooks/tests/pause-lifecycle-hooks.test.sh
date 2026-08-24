#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GATE="$ROOT/.claude/hooks/pause-launch-gate.sh"
ARM="$ROOT/.claude/hooks/bgwork-ceiling-arm.sh"
COMPLETE="$ROOT/.claude/hooks/background-task-complete.sh"
PAUSE="$ROOT/.claude/scripts/execution-pause.sh"
REGISTRY="$ROOT/.claude/scripts/background-task-registry.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export CLAUDE_EXECUTION_PAUSE_MARKER_DIR="$TMP/markers"
export CLAUDE_BGWORK_MARKER_DIR="$TMP/bgmarkers"
export CLAUDE_BGWORK_LOG_DIR="$TMP/logs"
mkdir -p "$HOME/.claude" "$CLAUDE_EXECUTION_PAUSE_MARKER_DIR" \
  "$CLAUDE_BGWORK_MARKER_DIR" "$CLAUDE_BGWORK_LOG_DIR"

SID=pause-hook-session
CWD="$ROOT"
REPO=auerbachb/claude-code-config
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   — $*"; }

gate() {
  local tool="$1" bg="${2:-false}"
  jq -nc --arg sid "$SID" --arg cwd "$CWD" --arg tool "$tool" --argjson bg "$bg" \
    '{session_id:$sid,cwd:$cwd,tool_name:$tool,tool_input:{run_in_background:$bg}}' | "$GATE"
}

gate Agent >/dev/null || fail "inactive gate blocked Agent"
"$PAUSE" --repo "$REPO" --activate --session "$SID" --command pause --window-minutes 5
set +e
gate Agent >/dev/null 2>&1; agent_rc=$?
gate Workflow >/dev/null 2>&1; workflow_rc=$?
gate Monitor >/dev/null 2>&1; monitor_rc=$?
gate Bash true >/dev/null 2>&1; bash_bg_rc=$?
gate Bash false >/dev/null 2>&1; bash_fg_rc=$?
set -e
[[ "$agent_rc" == 2 && "$workflow_rc" == 2 && "$monitor_rc" == 2 && "$bash_bg_rc" == 2 ]] || \
  fail "active pause did not block every background-start class"
[[ "$bash_fg_rc" == 0 ]] || fail "active pause blocked foreground Bash needed for teardown"
ok "PreToolUse gate blocks background starts but preserves foreground teardown"

"$PAUSE" --repo "$REPO" --clear --session "$SID"
gate Agent >/dev/null || fail "cleared gate still blocked"
ok "explicit clear reopens launches"

# A partial installation must still honor positive pause evidence even when the
# helper disappeared after activation.
PARTIAL="$TMP/partial/.claude/hooks"
mkdir -p "$PARTIAL"
cp "$GATE" "$PARTIAL/pause-launch-gate.sh"
touch "$CLAUDE_EXECUTION_PAUSE_MARKER_DIR/claude-execution-pause-any-$SID"
set +e
jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Agent",tool_input:{}}' \
  | "$PARTIAL/pause-launch-gate.sh" >/dev/null 2>&1
partial_rc=$?
set -e
[[ "$partial_rc" == 2 ]] || fail "missing helper bypassed positive pause marker"
ok "partial installation blocks launches when an active marker survives"

post() {
  local payload="$1"
  printf '%s' "$payload" | "$ARM" >/dev/null
}

post "$(jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Agent",tool_input:{name:"phase-a"},tool_response:{status:"async_launched",agentId:"agent-runtime",outputFile:"/tmp/agent.out"}}')"
post "$(jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Bash",tool_input:{description:"tests",run_in_background:true},tool_response:{backgroundTaskId:"bash-runtime"}}')"
post "$(jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Monitor",tool_input:{description:"watch",command:"tail -f x"},tool_response:{taskId:"monitor-runtime"}}')"
IDS="$("$REGISTRY" --repo "$REPO" --list --session "$SID" --live | jq -r 'map(.task_id) | sort | join(",")')"
[[ "$IDS" == agent-runtime,bash-runtime,monitor-runtime ]] || fail "PostToolUse ID capture: $IDS"
ok "PostToolUse captures exact Agent/Bash/Monitor runtime IDs"

printf '%s' "$(jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,agent_id:"agent-runtime",hook_event_name:"SubagentStop",status:"completed"}')" \
  | "$COMPLETE"
[[ "$("$REGISTRY" --repo "$REPO" --list --session "$SID" | jq -r '.[] | select(.task_id=="agent-runtime") | .status')" == "done" ]] || \
  fail "SubagentStop did not transition exact agent"

post "$(jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"TaskStop",tool_input:{task_id:"monitor-runtime"},tool_response:{task_id:"monitor-runtime",task_type:"monitor"}}')"
[[ "$("$REGISTRY" --repo "$REPO" --list --session "$SID" | jq -r '.[] | select(.task_id=="monitor-runtime") | .status')" == stopped ]] || \
  fail "TaskStop did not transition exact monitor"
ok "SubagentStop and TaskStop make exact registry entries terminal"

# If state becomes unreadable after activation, the positive marker keeps the
# gate closed. A random parse failure without such a marker stays fail-open.
"$PAUSE" --repo "$REPO" --activate --session "$SID" --command suspend --window-minutes 15
printf 'not-json\n' > "$HOME/.claude/session-state.json"
set +e
gate Agent >/dev/null 2>&1; corrupt_rc=$?
set -e
[[ "$corrupt_rc" == 2 ]] || fail "marker-backed unreadable state did not fail closed"
ok "armed marker fails closed across unreadable session state"

post "$(jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Agent",tool_input:{name:"untracked"},tool_response:{agentId:"untracked-runtime"}}')"
FAILURE_MARKER="$CLAUDE_BGWORK_MARKER_DIR/claude-background-registry-failed-$SID"
[[ -s "$FAILURE_MARKER" ]] || fail "registry write failure left no durable marker"
rg -q $'\tregister\tuntracked-runtime\t' "$FAILURE_MARKER" || \
  fail "registry failure marker omitted operation/runtime identity"

printf '%s' "$(jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,agent_id:"agent-runtime",hook_event_name:"SubagentStop",status:"completed"}')" \
  | "$COMPLETE"
rg -q $'\ttransition\tagent-runtime\t' "$FAILURE_MARKER" || \
  fail "SubagentStop transition failure was swallowed"
ok "registration and terminal-transition failures remain visible to shutdown audit"

FALLBACK_MARKER="$HOME/.claude/claude-background-registry-failed-$SID"
jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Agent",tool_input:{name:"fallback"},tool_response:{agentId:"fallback-runtime"}}' \
  | CLAUDE_BACKGROUND_TASK_FAILURE_DIR=/dev/null/no-child "$ARM" >/dev/null
rg -q $'\tregister\tfallback-runtime\t' "$FALLBACK_MARKER" || \
  fail "unwritable primary marker directory did not use HOME fallback"
ok "tracking failures fall back durably when the primary marker directory is unwritable"

PARTIAL_ARM_ROOT="$TMP/partial-arm"
mkdir -p "$PARTIAL_ARM_ROOT/.claude/hooks" "$PARTIAL_ARM_ROOT/.claude/scripts"
cp "$ARM" "$PARTIAL_ARM_ROOT/.claude/hooks/bgwork-ceiling-arm.sh"
cp "$ROOT/.claude/scripts/bgwork-ceiling.sh" "$PARTIAL_ARM_ROOT/.claude/scripts/bgwork-ceiling.sh"
jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Agent",tool_input:{name:"missing-helper"},tool_response:{agentId:"missing-helper-runtime"}}' \
  | "$PARTIAL_ARM_ROOT/.claude/hooks/bgwork-ceiling-arm.sh" >/dev/null
rg -q $'\tmissing_helper\tmissing-helper-runtime\t127' "$FAILURE_MARKER" || \
  fail "missing registry helper left no audit marker"
ok "missing registry helper is visible to shutdown audit"

echo "OK: pause lifecycle hook tests passed"
