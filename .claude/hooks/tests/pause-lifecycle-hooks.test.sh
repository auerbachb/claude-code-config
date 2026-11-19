#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GATE="$ROOT/.claude/hooks/pause-launch-gate.sh"
ARM="$ROOT/.claude/hooks/bgwork-ceiling-arm.sh"
COMPLETE="$ROOT/.claude/hooks/background-task-complete.sh"
PAUSE="$ROOT/.claude/scripts/execution-pause.sh"
REGISTRY="$ROOT/.claude/scripts/background-task-registry.sh"
TMP="$(mktemp -d)"
# Stop the issue #2402 background writers (if started) before removing $TMP,
# so an early assertion exit never leaves them looping against a deleted tree.
WRITER_PIDS=()
cleanup_tmp() {
  local wp
  # Children first (an in-flight session-state.sh write), then the loop.
  for wp in ${WRITER_PIDS[@]+"${WRITER_PIDS[@]}"}; do
    pkill -P "$wp" 2>/dev/null || true
    kill "$wp" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup_tmp EXIT
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
# Octal permission bits of $1 on stdout; returns non-zero and prints NOTHING
# when they cannot be determined (issue #930).
#
# A `stat -c %a … || stat -f %Lp …` chain is not a valid try-both. GNU reads
# `-f` as --file-system and the format string as a FILE operand, so it prints a
# filesystem block for the real operand AND exits non-zero — the `||` fires as
# well and the substitution ends up holding both outputs as one non-numeric
# blob. Exit status alone therefore cannot say which spelling answered, so each
# form is tried in isolation and the result has to look like octal mode bits
# before it is trusted: "could not determine" must never read as a pass.
mode_of() {
  local target="$1" bits
  bits="$(stat -c '%a' "$target" 2>/dev/null)" || bits=""
  if [[ ! "$bits" =~ ^[0-7]+$ ]]; then
    bits="$(stat -f '%Lp' "$target" 2>/dev/null)" || bits=""
  fi
  [[ "$bits" =~ ^[0-7]+$ ]] || return 1
  printf '%s' "$bits"
}

gate() {
  local tool="$1" bg="${2:-false}" cwd="${3:-$CWD}"
  jq -nc --arg sid "$SID" --arg cwd "$cwd" --arg tool "$tool" --argjson bg "$bg" \
    '{session_id:$sid,cwd:$cwd,tool_name:$tool,tool_input:{run_in_background:$bg}}' | "$GATE"
}

gate Agent >/dev/null || fail "inactive gate blocked Agent"
"$PAUSE" --repo "$REPO" --activate --session "$SID" --command pause --window-minutes 5
set +e
agent_message=$(gate Agent 2>&1 >/dev/null); agent_rc=$?
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
[[ "$agent_message" == *"/end-resume for /end; /pause-resume for /pause"* ]] || \
  fail "active gate did not map each shutdown command to its matching resume command"
[[ "$agent_message" != *"/end-resume (or /pause-resume)"* ]] || \
  fail "active gate still presents mismatched resume commands as interchangeable"
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
PRIVATE_DIR_MODE="$(mode_of "$PRIVATE_DIR")" || PRIVATE_DIR_MODE='<undeterminable>'
PRIVATE_MARKER_MODE="$(mode_of "$PRIVATE_MARKER")" || PRIVATE_MARKER_MODE='<undeterminable>'
[[ "$PRIVATE_DIR_MODE" == 700 ]] || \
  fail "default marker directory is not private (mode: $PRIVATE_DIR_MODE)"
[[ "$PRIVATE_MARKER_MODE" == 600 ]] || \
  fail "default marker file is not owner-only (mode: $PRIVATE_MARKER_MODE)"
ok "default pause markers live in an owner-private directory"

# An undeterminable mode must be refused, not asserted against (issue #930).
# What proves the shim below is actually reached is the negative control, not
# the guard assertion: a guard that never ran reports success just as loudly as
# one that worked. Both PATH overrides are command prefixes inside command
# substitutions, so the shim is scoped to those two lookups and the suite's own
# PATH is untouched. A shim the guard somehow missed still fails closed — real
# `stat` answers 600 with status 0, which is what the guard assertion rejects.
STAT_SHIM_BIN="$TMP/stat-shim"
mkdir -p "$STAT_SHIM_BIN"
# A GNU-flavoured stat: `-f` is --file-system, so it reads the format string as
# a FILE operand, dumps a filesystem block for the real one and exits non-zero.
# The `-c` arm stands in for a coreutils variant that cannot resolve the field
# and emits GNU's own `?` placeholder while still exiting 0.
# shellcheck disable=SC2016 # Generate a stub that expands these at runtime.
printf '%s\n' '#!/usr/bin/env bash' \
  'case "${1:-}" in' \
  '  -c) printf "?\n"; exit 0 ;;' \
  '  -f) printf "  File: \"%s\"\n  ID: 0 Namelen: 255 Type: ext2/ext3\n" "${3:-}"; exit 1 ;;' \
  'esac' \
  'exit 1' > "$STAT_SHIM_BIN/stat"
chmod +x "$STAT_SHIM_BIN/stat"
set +e
# Negative control: the unguarded chain this helper replaced reports success and
# hands back the shim's non-numeric output as if it were a file mode. Without
# this the guard assertion below could pass because the shim never ran.
# shellcheck disable=SC2016 # The chain under test expands in the child shell.
legacy_mode="$(PATH="$STAT_SHIM_BIN:$PATH" bash -c \
  'm="$(stat -c %a "$1" 2>/dev/null)" || m="$(stat -f %Lp "$1" 2>/dev/null)"; printf "%s" "$m"' \
  _ "$PRIVATE_MARKER")"
legacy_rc=$?
guarded_mode="$(PATH="$STAT_SHIM_BIN:$PATH" mode_of "$PRIVATE_MARKER")"
guarded_rc=$?
set -e
[[ "$legacy_rc" == 0 && -n "$legacy_mode" && ! "$legacy_mode" =~ ^[0-7]+$ ]] || \
  fail "negative control did not reproduce the unguarded chain accepting a non-numeric mode (rc=$legacy_rc, value: $legacy_mode)"
[[ "$guarded_rc" != 0 ]] || fail "mode_of accepted an undeterminable mode (value: $guarded_mode)"
[[ -z "$guarded_mode" ]] || fail "mode_of printed a fabricated mode on failure: $guarded_mode"
ok "an undeterminable file mode is refused rather than asserted against"

# Teardown is deferred to here on purpose: the block above stats a marker that
# really exists, so its refusal is about undeterminable output and not a
# missing operand.
env -u CLAUDE_EXECUTION_PAUSE_MARKER_DIR HOME="$PRIVATE_HOME" \
  "$PAUSE" --repo "$REPO" --clear --session "$PRIVATE_SESSION"

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
for pid in ${race_pids[@]+"${race_pids[@]}"}; do wait "$pid"; done
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

gate_sid() {
  local sid="$1" tool="${2:-Agent}"
  jq -nc --arg sid "$sid" --arg cwd "$CWD" --arg tool "$tool" \
    '{session_id:$sid,cwd:$cwd,tool_name:$tool,tool_input:{run_in_background:false}}' | "$GATE"
}
IDLE_SID=pause-gate-idle-2433
ACTIVE_SID=pause-gate-active-2433
"$PAUSE" --repo "$REPO" --activate --session "$ACTIVE_SID" --command pause --window-minutes 5 >/dev/null

# issue #2402: --status is lock-free, so a held state lock no longer refuses a
# launch. The verdict follows the gate state, well inside the hook budget.
# Generous named bound, measured over the whole hook subprocess.
LOCKFREE_BOUND_MS=2000
# Run "$@" with stdin from $1; print "<elapsed-ms> <rc>" (monotonic clock).
timed_run() {
  python3 -c 'import subprocess,sys,time
t=time.monotonic()
r=subprocess.run(sys.argv[2:],stdin=open(sys.argv[1],"rb"),stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
sys.stderr.buffer.write(r.stderr)
print(int((time.monotonic()-t)*1000), r.returncode)' "$@"
}
gate_payload() { # $1 session, $2 file
  jq -nc --arg sid "$1" --arg cwd "$CWD" \
    '{session_id:$sid,cwd:$cwd,tool_name:"Agent",tool_input:{run_in_background:false}}' > "$2"
}
gate_payload "$IDLE_SID" "$TMP/idle-2402.json"
gate_payload "$ACTIVE_SID" "$TMP/active-2402.json"
hold_state_lock
read -r held_idle_ms held_idle_rc < <(timed_run "$TMP/idle-2402.json" "$GATE" 2>"$TMP/held-idle-2402.err")
read -r held_active_ms held_active_rc < <(timed_run "$TMP/active-2402.json" "$GATE" 2>/dev/null)
[[ -d "$LOCK_DIR" ]] || fail "the lock-free status read disturbed the held lock"
rm -rf "$LOCK_DIR"
[[ "$held_idle_rc" == 0 ]] || fail "held lock refused an inactive session's launch (rc=$held_idle_rc): $(cat "$TMP/held-idle-2402.err")"
[[ "$held_active_rc" == 2 ]] || fail "held lock let an armed session launch (rc=$held_active_rc)"
(( held_idle_ms < LOCKFREE_BOUND_MS && held_active_ms < LOCKFREE_BOUND_MS )) || \
  fail "gate under a held lock took ${held_idle_ms}/${held_active_ms}ms (bound ${LOCKFREE_BOUND_MS}ms)"
ok "a held state lock neither refuses nor opens a launch; the verdict follows the gate state"

# Half-applied transitions stay closed without the lock: a marker with
# inactive state (interrupted clear) and a marker with no state record
# (interrupted activation) both read active.
HALF_SID=pause-gate-half-2402
HALF_MARKER="$CLAUDE_EXECUTION_PAUSE_MARKER_DIR/claude-execution-pause-v2-$(scope_hash "$REPO" "$HALF_SID")"
printf '{}\n' > "$HALF_MARKER"
[[ "$("$PAUSE" --repo "$REPO" --status --session "$HALF_SID")" == active ]] || \
  fail "marker without a state record (interrupted activation) read inactive"
"$ROOT/.claude/scripts/session-state.sh" --raw-path \
  --set ".repos[\"$REPO\"].execution_pauses[\"$HALF_SID\"].active=false" >/dev/null
[[ "$("$PAUSE" --repo "$REPO" --status --session "$HALF_SID")" == active ]] || \
  fail "marker with inactive state (interrupted clear) read inactive"
rm -f "$HALF_MARKER"
[[ "$("$PAUSE" --repo "$REPO" --status --session "$HALF_SID")" == inactive ]] || \
  fail "completed clear did not read inactive"
ok "half-applied activation and clear stay active without the lock"

# issue #2433 paths, kept for an older installed helper and the retained locked
# read (CLAUDE_EXECUTION_PAUSE_STATUS_LOCKED=1): the gate retries a busy lock
# briefly, reports busy separately from paused and from unavailable, and stays
# inside the host hook budget.
export CLAUDE_EXECUTION_PAUSE_STATUS_LOCKED=1

hold_state_lock
SECONDS=0
set +e
held_msg=$(gate_sid "$IDLE_SID" 2>&1 >/dev/null); held_rc=$?
set -e
held_elapsed=$SECONDS
rm -rf "$LOCK_DIR"
[[ "$held_rc" == 2 ]] || fail "held lock with an inactive gate did not block (rc=$held_rc)"
[[ "$held_elapsed" -lt 5 ]] || fail "held-lock retries outlived the 5s host hook budget (${held_elapsed}s)"
grep -Fq 'lock-busy' <<<"$held_msg" || fail "held lock was not reported as lock-busy: $held_msg"
grep -Fq "held by pid $$ on ${HOSTNAME:-$(hostname)}" <<<"$held_msg" || \
  fail "busy message omitted the real holder pid/host: $held_msg"
grep -Fq 'NOT a pause' <<<"$held_msg" || fail "busy message did not say it is not a pause"
grep -Eq 'after [2-9][0-9]* attempt' <<<"$held_msg" || fail "held lock was not retried: $held_msg"
ok "a lock held past the budget is reported as busy (not paused) with the real holder"

hold_state_lock
( sleep 1.2; rm -rf "$LOCK_DIR" ) &
set +e
gate_sid "$IDLE_SID" >/dev/null 2>&1; transient_idle_rc=$?
set -e
wait
[[ "$transient_idle_rc" == 0 ]] || fail "a transient lock with an inactive gate did not allow after retry (rc=$transient_idle_rc)"
hold_state_lock
( sleep 1.2; rm -rf "$LOCK_DIR" ) &
set +e
transient_active_msg=$(gate_sid "$ACTIVE_SID" 2>&1 >/dev/null); transient_active_rc=$?
set -e
wait
[[ "$transient_active_rc" == 2 ]] || fail "a transient lock with an active gate did not block"
grep -Fq 'background launches are closed' <<<"$transient_active_msg" || \
  fail "transient lock with an active gate was not reported as paused: $transient_active_msg"
ok "a transient lock is retried and the final verdict follows the gate state"

MKDIR_SHIM="$TMP/mkdir-shim-2433"
mkdir -p "$MKDIR_SHIM"
REAL_MKDIR="$(command -v mkdir)"
cat > "$MKDIR_SHIM/mkdir" <<SH
#!/bin/bash
for a in "\$@"; do case "\$a" in *session-state.json.lock) exit 1 ;; esac; done
exec "$REAL_MKDIR" "\$@"
SH
chmod +x "$MKDIR_SHIM/mkdir"
set +e
unavail_msg=$(PATH="$MKDIR_SHIM:$PATH" gate_sid "$IDLE_SID" 2>&1 >/dev/null); unavail_rc=$?
set -e
[[ "$unavail_rc" == 2 ]] || fail "non-contention exit 6 was treated as inactive (rc=$unavail_rc)"
grep -Fq 'could not be verified' <<<"$unavail_msg" || fail "non-contention exit 6 not reported as unavailable: $unavail_msg"
grep -Fq 'not contention' <<<"$unavail_msg" || fail "unavailable message omitted the reason: $unavail_msg"
if grep -Fq 'lock-busy' <<<"$unavail_msg"; then fail "non-contention exit 6 was called lock-busy"; fi
ok "a lock that cannot be created is reported as unavailable, not busy"
unset CLAUDE_EXECUTION_PAUSE_STATUS_LOCKED

# Call-count shim: the gate never retries an `active` verdict, and other
# non-zero exits stay fail-open after a single call.
SHIM_ROOT="$TMP/gate-shim-2433"
mkdir -p "$SHIM_ROOT/hooks" "$SHIM_ROOT/scripts"
cp "$GATE" "$SHIM_ROOT/hooks/pause-launch-gate.sh"
cat > "$SHIM_ROOT/scripts/execution-pause.sh" <<'SH'
#!/bin/bash
echo x >> "$GATE_SHIM_COUNT"
case "$GATE_SHIM_MODE" in
  active) echo active ;;
  error) echo "execution-pause.sh: boom" >&2; exit 4 ;;
esac
SH
chmod +x "$SHIM_ROOT/scripts/execution-pause.sh"
shim_gate() {
  jq -nc --arg cwd "$CWD" '{session_id:"shim-sid",cwd:$cwd,tool_name:"Agent",tool_input:{}}' \
    | CLAUDE_SESSION_REPO="$REPO" GATE_SHIM_MODE="$1" GATE_SHIM_COUNT="$TMP/shim-count-$1" \
      "$SHIM_ROOT/hooks/pause-launch-gate.sh"
}
set +e
shim_gate active >/dev/null 2>&1; shim_active_rc=$?
shim_gate error >/dev/null 2>&1; shim_error_rc=$?
set -e
[[ "$shim_active_rc" == 2 ]] || fail "shim active verdict did not block"
[[ "$(wc -l < "$TMP/shim-count-active" | tr -d ' ')" == 1 ]] || fail "an active verdict was retried"
[[ "$shim_error_rc" == 0 ]] || fail "a non-6 status failure no longer fails open"
[[ "$(wc -l < "$TMP/shim-count-error" | tr -d ' ')" == 1 ]] || fail "a non-6 status failure was retried"
ok "active is never retried and non-lock failures stay fail-open"
"$PAUSE" --repo "$REPO" --clear --session "$ACTIVE_SID" >/dev/null 2>&1 || true

# issue #2402: a realistic ~9 MB state file (many repos, PR and task records,
# Unicode). --status and the whole gate stay well under the hook's lock
# timeout idle, under a held lock, armed, and cleared; with six writers
# hammering the state, no Agent launch is refused for lock contention.
export CLAUDE_STATE_COMPACT_AUTO=0
UUID_SID=22222222-2222-4222-8222-222222222402
python3 - "$STATE_FILE" "$REPO" "$UUID_SID" <<'PY'
import json, os, sys
path, repo, uuid_sid = sys.argv[1:4]
with open(path) as f:
    doc = json.load(f)
repos = doc.setdefault('repos', {})
note = 'Ünïcødé — 漢字 — état ' * 4
# A UUID session with a legacy binding (stale token) over a large current-repo
# task inventory: the launch check projects the inventory down to one boolean.
current = repos.setdefault(repo, {})
current.setdefault('legacy_end_resume_scopes', {})[uuid_sid] = {'legacy': 'legacy-2402', 'native_token': '0' * 64}
current.setdefault('background_tasks', []).extend(
    {'task_id': f'cur-{n}', 'status': 'completed', 'session_id': 'pad-2402',
     'started_at': '2026-01-01T00:00:00Z', 'summary': note} for n in range(5000))
i = 0
while True:
    repos[f'pad-owner/pad-repo-{i}'] = {
        'prs': {str(n): {'reviewer': 'cr', 'head_sha': '%040x' % (i * 1000 + n), 'phase': 'B', 'notes': note}
                for n in range(40)},
        'background_tasks': [{'task_id': f't-{i}-{n}', 'status': 'completed', 'session_id': 'pad',
                              'started_at': '2026-01-01T00:00:00Z', 'summary': note} for n in range(20)],
    }
    i += 1
    if i % 25 == 0 and len(json.dumps(doc, ensure_ascii=False).encode()) >= 9 * 1024 * 1024:
        break
with open(path + '.tmp-2402', 'w') as f:
    json.dump(doc, f, ensure_ascii=False)
os.replace(path + '.tmp-2402', path)
PY
big_bytes=$(wc -c < "$STATE_FILE" | tr -d ' ')
(( big_bytes >= 9 * 1024 * 1024 )) || fail "large-state fixture is only $big_bytes bytes"
status_of() { CLAUDE_EXECUTION_PAUSE_LAUNCH_CHECK=1 "$PAUSE" --repo "$REPO" --status --session "$1"; }
assert_fast() { # label expected-status expected-gate-rc session payload
  local label="$1" want="$2" want_rc="$3" sid="$4" payload="$5" got ms rc gms grc
  got="$(status_of "$sid")" || fail "$label: --status failed"
  [[ "$got" == "$want" ]] || fail "$label: --status read $got, expected $want"
  read -r ms rc < <(timed_run /dev/null env CLAUDE_EXECUTION_PAUSE_LAUNCH_CHECK=1 \
    "$PAUSE" --repo "$REPO" --status --session "$sid" 2>/dev/null)
  read -r gms grc < <(timed_run "$payload" "$GATE" 2>/dev/null)
  [[ "$rc" == 0 && "$grc" == "$want_rc" ]] || fail "$label: status rc=$rc gate rc=$grc (want gate $want_rc)"
  (( ms < LOCKFREE_BOUND_MS && gms < LOCKFREE_BOUND_MS )) || \
    fail "$label: status ${ms}ms, gate ${gms}ms on a ${big_bytes}-byte state (bound ${LOCKFREE_BOUND_MS}ms)"
}
assert_fast "9 MB idle" inactive 0 "$IDLE_SID" "$TMP/idle-2402.json"
gate_payload "$UUID_SID" "$TMP/uuid-2402.json"
assert_fast "9 MB idle UUID session with a legacy binding" inactive 0 "$UUID_SID" "$TMP/uuid-2402.json"
hold_state_lock
assert_fast "9 MB held lock" inactive 0 "$IDLE_SID" "$TMP/idle-2402.json"
rm -rf "$LOCK_DIR"
"$PAUSE" --repo "$REPO" --activate --session "$ACTIVE_SID" --command pause --window-minutes 5 >/dev/null
assert_fast "9 MB armed" active 2 "$ACTIVE_SID" "$TMP/active-2402.json"
"$PAUSE" --repo "$REPO" --clear --session "$ACTIVE_SID" >/dev/null
assert_fast "9 MB cleared" inactive 0 "$ACTIVE_SID" "$TMP/active-2402.json"
ok "--status and the gate answer within ${LOCKFREE_BOUND_MS}ms on a ${big_bytes}-byte state, idle, held, armed and cleared"

WRITERS=6
WRITER_STOP="$TMP/writers-2402.stop"
WRITER_PIDS=()
for w in $(seq 1 "$WRITERS"); do
  (
    n=0
    while [[ ! -e "$WRITER_STOP" && -d "$TMP" ]]; do
      n=$((n + 1))
      if CLAUDE_STATE_LOCK_TIMEOUT=120 "$ROOT/.claude/scripts/session-state.sh" --raw-path \
           --set ".repos[\"writer-2402/w$w\"].count=$n" >/dev/null 2>&1; then
        : > "$TMP/writer-2402-$w.ready"
      fi
      sleep 0.1
    done
  ) &
  WRITER_PIDS+=("$!")
done
SECONDS=0
until (( $(find "$TMP" -maxdepth 1 -name 'writer-2402-*.ready' | wc -l) == WRITERS )); do
  (( SECONDS < 240 )) || fail "the $WRITERS state writers never all landed a write"
  sleep 0.2
done
for pid in "${WRITER_PIDS[@]}"; do kill -0 "$pid" 2>/dev/null || fail "writer $pid died under load"; done
for i in $(seq 1 13); do
  read -r load_ms load_rc < <(timed_run "$TMP/idle-2402.json" "$GATE" 2>"$TMP/load-2402.err")
  [[ "$load_rc" == 0 ]] || fail "launch $i refused under $WRITERS writers (rc=$load_rc): $(cat "$TMP/load-2402.err")"
  if grep -Eq 'lock-contended|lock-busy|could not be verified' "$TMP/load-2402.err"; then
    fail "launch $i reported lock trouble under load: $(cat "$TMP/load-2402.err")"
  fi
  (( load_ms < LOCKFREE_BOUND_MS )) || fail "launch $i took ${load_ms}ms under load (bound ${LOCKFREE_BOUND_MS}ms)"
done
CLAUDE_STATE_LOCK_TIMEOUT=240 "$PAUSE" --repo "$REPO" --activate --session "$ACTIVE_SID" \
  --command pause --window-minutes 5 >/dev/null || fail "could not arm the gate under writer load"
set +e; gate_sid "$ACTIVE_SID" >/dev/null 2>&1; load_armed_rc=$?; set -e
[[ "$load_armed_rc" == 2 ]] || fail "an armed gate let a launch through under writer load (rc=$load_armed_rc)"
CLAUDE_STATE_LOCK_TIMEOUT=240 "$PAUSE" --repo "$REPO" --clear --session "$ACTIVE_SID" >/dev/null || \
  fail "could not clear the gate under writer load"
set +e; gate_sid "$ACTIVE_SID" >/dev/null 2>&1; load_cleared_rc=$?; set -e
[[ "$load_cleared_rc" == 0 ]] || fail "a cleared gate still refused under writer load (rc=$load_cleared_rc)"
: > "$WRITER_STOP"
for pid in "${WRITER_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
jq -se --argjson n "$WRITERS" 'length == 1 and (.[0] | type == "object") and (.[0] as $d
  | [range(1; $n + 1)] | all(. as $w | ($d.repos["writer-2402/w\($w)"].count | type) == "number"))' \
  "$STATE_FILE" >/dev/null || fail "state after concurrent writers is not one object holding every writer key"
ok "13 launches under $WRITERS concurrent writers on a 9 MB state: none refused; arm and clear still gate"
unset CLAUDE_STATE_COMPACT_AUTO

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
