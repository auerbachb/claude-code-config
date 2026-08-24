#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REGISTRY="$ROOT/.claude/scripts/background-task-registry.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   — $*"; }
run() { "$REGISTRY" --repo auerbachb/claude-code-config "$@"; }

run --register --session s1 --task-id agent-1 --type agent --name phase-a \
  --output-file /tmp/agent-1.out --recovery-path /tmp/worktree-1
run --register --session s1 --task-id mon-1 --type monitor --name silence-ceiling
run --register --session s2 --task-id bash-2 --type bash --name tests

[[ "$(run --count --session s1 --live)" == 2 ]] || fail "s1 live count"
[[ "$(run --count --session s2 --live)" == 1 ]] || fail "s2 live count"
[[ "$(run --list --session s1 --live | jq -r '.[0] | has("task_id") and has("name")')" == true ]] || \
  fail "runtime ID and logical name must be separate fields"
ok "register/list/count are repo- and session-scoped"

# Duplicate registration is an upsert, not a second billable task.
run --register --session s1 --task-id agent-1 --type agent --name renamed-agent
[[ "$(run --count --session s1 --live)" == 2 ]] || fail "duplicate register appended"
[[ "$(run --list --session s1 --live | jq -r '.[] | select(.task_id=="agent-1") | .name')" == renamed-agent ]] || \
  fail "duplicate register did not update metadata"
ok "duplicate runtime identities upsert safely"

run --transition --session s1 --task-id agent-1 --status "done"
run --transition --session s1 --task-id mon-1 --status stop_failed
[[ "$(run --count --session s1 --live)" == 1 ]] || fail "terminal/live status accounting"
[[ "$(run --list --session s1 --live | jq -r '.[0].status')" == stop_failed ]] || \
  fail "failed stop identity was not retained"
ok "terminal tasks drain while failed stops remain live"

# Age is advisory only: a stale running task remains live (fail closed).
STATE="$HOME/.claude/session-state.json"
TMP_STATE="$TMP/state.json"
jq '(.repos["auerbachb/claude-code-config"].background_tasks[] | select(.task_id=="mon-1") | .updated_at) = "2000-01-01T00:00:00Z"' \
  "$STATE" > "$TMP_STATE"
mv "$TMP_STATE" "$STATE"
[[ "$(CLAUDE_BACKGROUND_TASK_TTL_S=1 run --count --session s1 --live)" == 1 ]] || \
  fail "stale task was silently treated terminal"
[[ "$(CLAUDE_BACKGROUND_TASK_TTL_S=1 run --list --session s1 --live | jq -r '.[0].stale')" == true ]] || \
  fail "stale annotation missing"
ok "stale possibly-live tasks fail closed"

# Parallel PostToolUse hooks can register without lost updates.
pids=()
for n in $(seq 1 12); do
  run --register --session race --task-id "agent-$n" --type agent --name "race-$n" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
[[ "$(run --count --session race --live)" == 12 ]] || fail "concurrent registrations lost updates"
ok "locked concurrent registrations preserve every runtime identity"

# Corrupt state must fail non-zero and remain untouched so hooks can surface a
# durable tracking-failure marker; an empty successful rewrite hides the loss.
printf 'not-json\n' > "$STATE"
BEFORE="$(<"$STATE")"
set +e
run --register --session corrupt --task-id lost-agent --type agent >/dev/null 2>&1
corrupt_rc=$?
set -e
[[ "$corrupt_rc" == 4 ]] || fail "corrupt state returned $corrupt_rc instead of parse failure"
[[ "$(<"$STATE")" == "$BEFORE" ]] || fail "corrupt state was overwritten"
ok "corrupt state fails loudly without publishing an empty document"

echo "OK: background task registry tests passed"
