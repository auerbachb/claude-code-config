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
scope_hash() {
  local repo="$1" sid="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s\0%s' "$repo" "$sid" | sha256sum | awk '{print $1}'
  else
    printf '%s\0%s' "$repo" "$sid" | shasum -a 256 | awk '{print $1}'
  fi
}
mode_of() {
  local mode=""
  mode="$(stat -c %a "$1" 2>/dev/null)" || mode="$(stat -f %Lp "$1" 2>/dev/null)"
  printf '%s' "$mode"
}

gate() {
  local tool="$1" bg="${2:-false}" cwd="${3:-$CWD}"
  jq -nc --arg sid "$SID" --arg cwd "$cwd" --arg tool "$tool" --argjson bg "$bg" \
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
CLAUDE_SESSION_REPO=other/checkout gate Agent >/dev/null 2>&1; scoped_gate_rc=$?
set -e
[[ "$agent_rc" == 2 && "$workflow_rc" == 2 && "$monitor_rc" == 2 && "$bash_bg_rc" == 2 ]] || \
  fail "active pause did not block every background-start class"
[[ "$bash_fg_rc" == 0 ]] || fail "active pause blocked foreground Bash needed for teardown"
[[ "$scoped_gate_rc" == 2 ]] || fail "inherited repo scope bypassed the payload checkout's active gate"
ok "PreToolUse gate blocks background starts but preserves foreground teardown"

"$PAUSE" --repo "$REPO" --clear --session "$SID"
gate Agent >/dev/null || fail "cleared gate still blocked"
ok "explicit clear reopens launches"

set +e
"$PAUSE" --repo "$REPO" --activate --session invalid-command \
  --command suspend --window-minutes 5 >/dev/null 2>&1
invalid_command_rc=$?
set -e
[[ "$invalid_command_rc" == 2 ]] || fail "invalid legacy command was not rejected"
[[ ! -e "$HOME/.claude/session-state.json.lock" ]] || fail "invalid activation leaked the state lock"
"$PAUSE" --repo "$REPO" --activate --session post-invalid \
  --command pause --window-minutes 0
"$PAUSE" --repo "$REPO" --clear --session post-invalid
ok "invalid activation releases state lock before the next lifecycle operation"

ORIGINLESS="$TMP/originless-checkout"
mkdir -p "$ORIGINLESS"
"$PAUSE" --repo _unknown --activate --session "$SID" --command pause --window-minutes 5
set +e
CLAUDE_SESSION_REPO=other/checkout gate Agent false "$ORIGINLESS" >/dev/null 2>&1
originless_gate_rc=$?
set -e
[[ "$originless_gate_rc" == 2 ]] || fail "origin-less payload fell back to inherited repo scope"
"$PAUSE" --repo _unknown --clear --session "$SID"
ok "origin-less payload preserves _unknown repository isolation"

# A valid payload cwd that cannot be resolved is still authoritative: stale
# inherited scope must not be consulted after the lookup itself fails.
FAILED_RESOLVE_ROOT="$TMP/failed-resolve/.claude"
mkdir -p "$FAILED_RESOLVE_ROOT/hooks" "$FAILED_RESOLVE_ROOT/scripts"
cp "$ARM" "$FAILED_RESOLVE_ROOT/hooks/bgwork-ceiling-arm.sh"
cp "$COMPLETE" "$FAILED_RESOLVE_ROOT/hooks/background-task-complete.sh"
cp "$GATE" "$FAILED_RESOLVE_ROOT/hooks/pause-launch-gate.sh"
cp "$REGISTRY" "$FAILED_RESOLVE_ROOT/scripts/background-task-registry.sh"
cp "$ROOT/.claude/scripts/state-lock.sh" "$FAILED_RESOLVE_ROOT/scripts/state-lock.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 4' > "$FAILED_RESOLVE_ROOT/scripts/session-state.sh"
chmod +x "$FAILED_RESOLVE_ROOT/scripts/session-state.sh"
jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Agent",tool_input:{name:"failed-resolve"},tool_response:{agentId:"failed-resolve-runtime"}}' \
  | CLAUDE_SESSION_REPO=other/checkout "$FAILED_RESOLVE_ROOT/hooks/bgwork-ceiling-arm.sh" >/dev/null
[[ "$("$REGISTRY" --repo _unknown --list --session "$SID" | jq -r '.[] | select(.task_id=="failed-resolve-runtime") | .status')" == "running" ]] || \
  fail "failed payload lookup fell back to inherited scope during registration"
printf '%s' "$(jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,agent_id:"failed-resolve-runtime",hook_event_name:"SubagentStop",status:"completed"}')" \
  | CLAUDE_SESSION_REPO=other/checkout "$FAILED_RESOLVE_ROOT/hooks/background-task-complete.sh"
[[ "$("$REGISTRY" --repo _unknown --list --session "$SID" | jq -r '.[] | select(.task_id=="failed-resolve-runtime") | .status')" == "done" ]] || \
  fail "failed payload lookup fell back to inherited scope during completion"
PAUSE_CAPTURE="$TMP/failed-resolve-pause-args"
# shellcheck disable=SC2016 # Generate a stub that expands these at runtime.
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" > "$PAUSE_CAPTURE"' \
  'printf "active\n"' > "$FAILED_RESOLVE_ROOT/scripts/execution-pause.sh"
chmod +x "$FAILED_RESOLVE_ROOT/scripts/execution-pause.sh"
set +e
jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Agent",tool_input:{}}' \
  | CLAUDE_SESSION_REPO=other/checkout PAUSE_CAPTURE="$PAUSE_CAPTURE" \
    "$FAILED_RESOLVE_ROOT/hooks/pause-launch-gate.sh" >/dev/null 2>&1
failed_resolve_gate_rc=$?
set -e
[[ "$failed_resolve_gate_rc" == 2 ]] || fail "failed payload lookup did not keep launch gate closed"
grep -Fq -- '--repo _unknown' "$PAUSE_CAPTURE" || \
  fail "failed payload lookup passed inherited repo to launch gate"
ok "failed payload lookup remains isolated from inherited repository scope"

BAD_MARKER_PATH="$TMP/not-a-marker-directory"
printf 'occupied\n' > "$BAD_MARKER_PATH"
set +e
CLAUDE_EXECUTION_PAUSE_MARKER_DIR="$BAD_MARKER_PATH" \
  "$PAUSE" --repo "$REPO" --activate --session marker-write-failure \
  --command pause --window-minutes 5 >/dev/null 2>&1
marker_failure_rc=$?
set -e
[[ "$marker_failure_rc" == 5 ]] || fail "unwritable marker location did not fail activation"
[[ "$("$PAUSE" --repo "$REPO" --status --session marker-write-failure)" == inactive ]] || \
  fail "failed marker publication left pause state active without durable evidence"
ok "activation publishes durable marker evidence before active state"

RM_STUB_BIN="$TMP/rm-stub"
mkdir -p "$RM_STUB_BIN"
# shellcheck disable=SC2016 # Generate a stub that inspects its runtime argv.
printf '%s\n' '#!/usr/bin/env bash' \
  'for arg in "$@"; do' \
  '  case "$arg" in *claude-execution-pause-v2-*) exit 1 ;; esac' \
  'done' \
  'exec /bin/rm "$@"' > "$RM_STUB_BIN/rm"
chmod +x "$RM_STUB_BIN/rm"
"$PAUSE" --repo "$REPO" --activate --session marker-remove-failure \
  --command pause --window-minutes 5
set +e
PATH="$RM_STUB_BIN:$PATH" "$PAUSE" --repo "$REPO" --clear \
  --session marker-remove-failure >/dev/null 2>&1
marker_remove_rc=$?
set -e
[[ "$marker_remove_rc" == 5 ]] || fail "marker-removal failure was not surfaced"
[[ "$("$PAUSE" --repo "$REPO" --status --session marker-remove-failure)" == active ]] || \
  fail "surviving marker did not remain authoritative after incomplete clear"
"$PAUSE" --repo "$REPO" --clear --session marker-remove-failure
ok "surviving marker keeps an incomplete clear fail-closed"

COLLIDE_A=a_b/c
COLLIDE_B=a/b_c
COLLIDE_SID=collision-scope
COLLIDE_A_MARKER="$CLAUDE_EXECUTION_PAUSE_MARKER_DIR/claude-execution-pause-v2-$(scope_hash "$COLLIDE_A" "$COLLIDE_SID")"
COLLIDE_B_MARKER="$CLAUDE_EXECUTION_PAUSE_MARKER_DIR/claude-execution-pause-v2-$(scope_hash "$COLLIDE_B" "$COLLIDE_SID")"
[[ "$COLLIDE_A_MARKER" != "$COLLIDE_B_MARKER" ]] || fail "distinct scopes produced the same marker identity"
"$PAUSE" --repo "$COLLIDE_A" --activate --session "$COLLIDE_SID" --command pause --window-minutes 5
"$PAUSE" --repo "$COLLIDE_B" --activate --session "$COLLIDE_SID" --command pause --window-minutes 5
[[ -f "$COLLIDE_A_MARKER" && -f "$COLLIDE_B_MARKER" ]] || fail "hashed scope marker missing"
"$PAUSE" --repo "$COLLIDE_A" --clear --session "$COLLIDE_SID"
[[ "$("$PAUSE" --repo "$COLLIDE_B" --status --session "$COLLIDE_SID")" == active ]] || \
  fail "clearing one colliding legacy scope unblocked another"
"$PAUSE" --repo "$COLLIDE_B" --clear --session "$COLLIDE_SID"
ok "marker hashing isolates repository/session scopes without sanitization collisions"

PRIVATE_HOME="$TMP/private-home"
mkdir -p "$PRIVATE_HOME/.claude"
PRIVATE_SESSION=private-marker
env -u CLAUDE_EXECUTION_PAUSE_MARKER_DIR HOME="$PRIVATE_HOME" \
  "$PAUSE" --repo "$REPO" --activate --session "$PRIVATE_SESSION" \
  --command pause --window-minutes 5
PRIVATE_DIR="$PRIVATE_HOME/.claude/execution-pause-markers"
PRIVATE_MARKER="$PRIVATE_DIR/claude-execution-pause-v2-$(scope_hash "$REPO" "$PRIVATE_SESSION")"
[[ "$(mode_of "$PRIVATE_DIR")" == 700 ]] || fail "default marker directory is not private"
[[ "$(mode_of "$PRIVATE_MARKER")" == 600 ]] || fail "default marker file is not owner-only"
env -u CLAUDE_EXECUTION_PAUSE_MARKER_DIR HOME="$PRIVATE_HOME" \
  "$PAUSE" --repo "$REPO" --clear --session "$PRIVATE_SESSION"
ok "default pause markers live in an owner-private directory"

# A partial installation must still honor positive pause evidence even when the
# helper disappeared after activation.
PARTIAL="$TMP/partial/.claude/hooks"
mkdir -p "$PARTIAL"
cp "$GATE" "$PARTIAL/pause-launch-gate.sh"
EXACT_MARKER="$CLAUDE_EXECUTION_PAUSE_MARKER_DIR/claude-execution-pause-v2-$(scope_hash "$REPO" "$SID")"
touch "$EXACT_MARKER"
set +e
jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Agent",tool_input:{}}' \
  | CLAUDE_SESSION_REPO="$REPO" "$PARTIAL/pause-launch-gate.sh" >/dev/null 2>&1
partial_rc=$?
set -e
[[ "$partial_rc" == 2 ]] || fail "missing helper bypassed positive pause marker"
rm -f "$EXACT_MARKER"
touch "$CLAUDE_EXECUTION_PAUSE_MARKER_DIR/claude-execution-pause-v2-$(scope_hash other/checkout "$SID")"
jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Agent",tool_input:{}}' \
  | CLAUDE_SESSION_REPO="$REPO" "$PARTIAL/pause-launch-gate.sh" >/dev/null 2>&1 || \
  fail "foreign-repo marker blocked the payload repository"
ok "partial installation blocks launches when an active marker survives"

# Concurrent activate/clear calls share the canonical state lock. Whichever
# operation wins last must leave marker and state in the same lifecycle.
race_pids=()
for n in 1 2 3 4; do
  "$PAUSE" --repo "$REPO" --activate --session lifecycle-race \
    --command pause --window-minutes "$n" >/dev/null & race_pids+=("$!")
  "$PAUSE" --repo "$REPO" --clear --session lifecycle-race >/dev/null & race_pids+=("$!")
done
for pid in "${race_pids[@]}"; do wait "$pid"; done
RACE_STATE="$("$PAUSE" --repo "$REPO" --status --session lifecycle-race)"
RACE_MARKER="$CLAUDE_EXECUTION_PAUSE_MARKER_DIR/claude-execution-pause-v2-$(scope_hash "$REPO" lifecycle-race)"
if [[ "$RACE_STATE" == active ]]; then
  [[ -f "$RACE_MARKER" ]] || fail "concurrent lifecycle left active state without marker"
else
  [[ ! -f "$RACE_MARKER" ]] || fail "concurrent lifecycle left cleared state with marker"
fi
"$PAUSE" --repo "$REPO" --clear --session lifecycle-race
ok "pause lifecycle serializes concurrent activate and clear operations"

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
CLAUDE_SESSION_REPO=other/checkout post "$(jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Agent",tool_input:{name:"scoped"},tool_response:{agentId:"scoped-agent-runtime"}}')"
CLAUDE_SESSION_REPO=other/checkout post "$(jq -nc --arg sid "$SID" --arg cwd "$ORIGINLESS" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Agent",tool_input:{name:"unknown-scope"},tool_response:{agentId:"unknown-scope-runtime"}}')"
IDS="$("$REGISTRY" --repo "$REPO" --list --session "$SID" --live | jq -r 'map(.task_id) | sort | join(",")')"
[[ "$IDS" == agent-runtime,bash-runtime,monitor-runtime,scoped-agent-runtime ]] || fail "PostToolUse ID capture: $IDS"
[[ "$("$REGISTRY" --repo other/checkout --count --session "$SID")" == 0 ]] || \
  fail "inherited repo scope captured a task from the payload checkout"
[[ "$("$REGISTRY" --repo _unknown --count --session "$SID" --live)" == 1 ]] || \
  fail "origin-less payload did not register in _unknown scope"
ok "PostToolUse captures exact Agent/Bash/Monitor runtime IDs"

printf '%s' "$(jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,agent_id:"agent-runtime",hook_event_name:"SubagentStop",status:"completed"}')" \
  | "$COMPLETE"
[[ "$("$REGISTRY" --repo "$REPO" --list --session "$SID" | jq -r '.[] | select(.task_id=="agent-runtime") | .status')" == "done" ]] || \
  fail "SubagentStop did not transition exact agent"
CLAUDE_SESSION_REPO=other/checkout printf '%s' "$(jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,agent_id:"scoped-agent-runtime",hook_event_name:"SubagentStop",status:"completed"}')" \
  | CLAUDE_SESSION_REPO=other/checkout "$COMPLETE"
[[ "$("$REGISTRY" --repo "$REPO" --list --session "$SID" | jq -r '.[] | select(.task_id=="scoped-agent-runtime") | .status')" == "done" ]] || \
  fail "inherited repo scope misdirected SubagentStop transition"

post "$(jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"TaskStop",tool_input:{task_id:"monitor-runtime"},tool_response:{task_id:"monitor-runtime",task_type:"monitor"}}')"
[[ "$("$REGISTRY" --repo "$REPO" --list --session "$SID" | jq -r '.[] | select(.task_id=="monitor-runtime") | .status')" == stopped ]] || \
  fail "TaskStop did not transition exact monitor"
post "$(jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"TaskStop",tool_input:{task_id:"bash-runtime"},tool_response:{error:"still running"}}')"
[[ "$("$REGISTRY" --repo "$REPO" --list --session "$SID" | jq -r '.[] | select(.task_id=="bash-runtime") | .status')" == stop_failed ]] || \
  fail "failed TaskStop hid a possibly running task"
ok "SubagentStop and TaskStop make exact registry entries terminal"

NO_CEILING_ROOT="$TMP/no-ceiling"
mkdir -p "$NO_CEILING_ROOT/.claude/hooks" "$NO_CEILING_ROOT/.claude/scripts"
cp "$ARM" "$NO_CEILING_ROOT/.claude/hooks/bgwork-ceiling-arm.sh"
cp "$REGISTRY" "$NO_CEILING_ROOT/.claude/scripts/background-task-registry.sh"
cp "$ROOT/.claude/scripts/state-lock.sh" "$NO_CEILING_ROOT/.claude/scripts/state-lock.sh"
jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Agent",tool_input:{name:"no-ceiling"},tool_response:{agentId:"no-ceiling-runtime"}}' \
  | CLAUDE_SESSION_REPO="$REPO" "$NO_CEILING_ROOT/.claude/hooks/bgwork-ceiling-arm.sh" >/dev/null
[[ "$("$REGISTRY" --repo "$REPO" --list --session "$SID" | jq -r '.[] | select(.task_id=="no-ceiling-runtime") | .status')" == "running" ]] || \
  fail "missing ceiling helper bypassed runtime registration"
ok "runtime registration survives a missing silence-ceiling helper"

# The PostToolUse hook has a 5s host timeout. Registry lock contention must
# fail sooner and leave durable audit evidence rather than being killed while
# still waiting inside the 30s default lock contract.
STATE_FILE="$HOME/.claude/session-state.json"
LOCK_DIR="$STATE_FILE.lock"
hold_state_lock() {
  mkdir "$LOCK_DIR"
  {
    printf 'pid=%s\n' "$$"
    printf 'host=%s\n' "${HOSTNAME:-$(hostname)}"
    printf 'epoch=%s\n' "$(date +%s)"
    printf 'started=%s\n' "$(date -u +%FT%TZ)"
    printf 'cmd=test\n'
    printf 'token=contention-test\n'
  } > "$LOCK_DIR/owner"
}
hold_state_lock
SECONDS=0
post "$(jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Agent",tool_input:{name:"contended"},tool_response:{agentId:"contended-runtime"}}')"
contention_elapsed=$SECONDS
rm -rf "$LOCK_DIR"
[[ "$contention_elapsed" -lt 5 ]] || fail "registry contention outlived the PostToolUse timeout budget"
FAILURE_MARKER="$CLAUDE_BGWORK_MARKER_DIR/claude-background-registry-failed-$SID"
grep -Fq $'\tregister\tcontended-runtime\t6' "$FAILURE_MARKER" || \
  fail "registry contention did not leave durable audit evidence"

post "$(jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Agent",tool_input:{name:"terminal-contention"},tool_response:{agentId:"terminal-contention-runtime"}}')"
hold_state_lock
SECONDS=0
printf '%s' "$(jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,agent_id:"terminal-contention-runtime",hook_event_name:"SubagentStop",status:"completed"}')" \
  | "$COMPLETE"
terminal_contention_elapsed=$SECONDS
rm -rf "$LOCK_DIR"
[[ "$terminal_contention_elapsed" -lt 5 ]] || fail "SubagentStop contention outlived its hook timeout budget"
grep -Fq $'\ttransition\tterminal-contention-runtime\t6' "$FAILURE_MARKER" || \
  fail "SubagentStop contention did not leave durable audit evidence"
[[ "$("$REGISTRY" --repo "$REPO" --list --session "$SID" | jq -r '.[] | select(.task_id=="terminal-contention-runtime") | .status')" == "running" ]] || \
  fail "failed terminal transition incorrectly changed task lifecycle"
ok "registry lock contention records launch and terminal failures within hook budgets"

hold_state_lock
SECONDS=0
set +e
gate Agent >/dev/null 2>&1
gate_contention_rc=$?
set -e
gate_contention_elapsed=$SECONDS
rm -rf "$LOCK_DIR"
[[ "$gate_contention_rc" == 2 ]] || fail "lock-contended launch gate failed open"
[[ "$gate_contention_elapsed" -lt 5 ]] || fail "launch-gate contention outlived its hook timeout budget"
ok "launch-gate lock contention fails closed within the hook budget"

# If state becomes unreadable after activation, the positive marker keeps the
# gate closed. A random parse failure without such a marker stays fail-open.
set +e
"$PAUSE" --repo "$REPO" --activate --session legacy-command \
  --command suspend --window-minutes 15 >/dev/null 2>&1
legacy_command_rc=$?
set -e
[[ "$legacy_command_rc" == 2 ]] || fail "retired suspend command value was accepted"

"$PAUSE" --repo "$REPO" --activate --session "$SID" --command end --window-minutes 5
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
grep -Fq $'\tregister\tuntracked-runtime\t' "$FAILURE_MARKER" || \
  fail "registry failure marker omitted operation/runtime identity"

printf '%s' "$(jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,agent_id:"agent-runtime",hook_event_name:"SubagentStop",status:"completed"}')" \
  | "$COMPLETE"
grep -Fq $'\ttransition\tagent-runtime\t' "$FAILURE_MARKER" || \
  fail "SubagentStop transition failure was swallowed"
ok "registration and terminal-transition failures remain visible to shutdown audit"

FALLBACK_MARKER="$HOME/.claude/claude-background-registry-failed-$SID"
jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Agent",tool_input:{name:"fallback"},tool_response:{agentId:"fallback-runtime"}}' \
  | CLAUDE_BACKGROUND_TASK_FAILURE_DIR=/dev/null/no-child "$ARM" >/dev/null
grep -Fq $'\tregister\tfallback-runtime\t' "$FALLBACK_MARKER" || \
  fail "unwritable primary marker directory did not use HOME fallback"
ok "tracking failures fall back durably when the primary marker directory is unwritable"

PARTIAL_ARM_ROOT="$TMP/partial-arm"
mkdir -p "$PARTIAL_ARM_ROOT/.claude/hooks" "$PARTIAL_ARM_ROOT/.claude/scripts"
cp "$ARM" "$PARTIAL_ARM_ROOT/.claude/hooks/bgwork-ceiling-arm.sh"
cp "$ROOT/.claude/scripts/bgwork-ceiling.sh" "$PARTIAL_ARM_ROOT/.claude/scripts/bgwork-ceiling.sh"
jq -nc --arg sid "$SID" --arg cwd "$CWD" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Agent",tool_input:{name:"missing-helper"},tool_response:{agentId:"missing-helper-runtime"}}' \
  | "$PARTIAL_ARM_ROOT/.claude/hooks/bgwork-ceiling-arm.sh" >/dev/null
grep -Fq $'\tmissing_helper\tmissing-helper-runtime\t127' "$FAILURE_MARKER" || \
  fail "missing registry helper left no audit marker"
ok "missing registry helper is visible to shutdown audit"

echo "OK: pause lifecycle hook tests passed"
