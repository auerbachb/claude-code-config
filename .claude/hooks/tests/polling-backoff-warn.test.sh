#!/usr/bin/env bash
# Tests for polling-backoff-warn.sh (issue #794).
#
# Verifies the base-relative stable-state backoff ladder:
#   digest_streak >= 3 → widen to max(15m, 3×base); streak >= 9 → stop the poll
# Covers multiple base cadences, the "already applied" no-op guard, and the
# user_input blocker stop. Never touches real session state.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/polling-backoff-warn.sh"

TMP_DIR="$(mktemp -d)"
# Redirect HOME so the hook reads our fixture state file.
export HOME="$TMP_DIR"
export CLAUDE_SESSION_REPO="test/repo"
mkdir -p "$TMP_DIR/.claude"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok   — $*"; }

# Extract additionalContext from hook JSON output.
context_of() {
  jq -r '.hookSpecificOutput.additionalContext // ""'
}

# Write a fixture state file for a given PR.
# $1 = PR number, $2 = JSON object for the PR fields.
write_state() {
  local pr="$1" pr_json="$2"
  jq -n \
    --arg repo "$CLAUDE_SESSION_REPO" \
    --arg pr   "$pr" \
    --argjson  body "$pr_json" \
    '{repos: {($repo): {prs: {($pr): $body}}}}' \
    > "$TMP_DIR/.claude/session-state.json"
}

# Invoke the hook with a Bash tool_input referencing a PR number in the command.
run_hook() {
  local pr="$1"
  local cmd="${2:-gh pr view $1 --json state}"
  jq -cn --arg cmd "$cmd" '{tool_input: {command: $cmd}}' | bash "$HOOK"
}

PR="775"

# ── 1. No warning below streak=3 ─────────────────────────────────────────────
write_state "$PR" '{"digest_streak":2,"babysit":{"cadence_base_minutes":5}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -z "$ctx" ]] || fail "expected no warning at streak=2, got: $ctx"
ok "no warning at streak=2 (below threshold)"

# ── 2. Streak=3, base=5m → widen to 15m ─────────────────────────────────────
write_state "$PR" '{"digest_streak":3,"babysit":{"cadence_base_minutes":5}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -n "$ctx" ]] || fail "expected warning at streak=3 base=5m"
grep -q "15m" <<<"$ctx" || fail "expected 15m in message at base=5m, got: $ctx"
# 15 > 5 — strictly wider than base
ok "streak=3 base=5m → widen to 15m (strictly greater than base)"

# ── 3. Streak=3, base=1m → widen to 15m (floor applies) ─────────────────────
write_state "$PR" '{"digest_streak":3,"babysit":{"cadence_base_minutes":1}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -n "$ctx" ]] || fail "expected warning at streak=3 base=1m"
grep -q "15m" <<<"$ctx" || fail "expected 15m in message at base=1m, got: $ctx"
# 15 > 1 — strictly wider
ok "streak=3 base=1m → widen to 15m (floor, strictly greater than base)"

# ── 4. Streak=3, base=20m → widen to 60m (3×base > 15) ──────────────────────
write_state "$PR" '{"digest_streak":3,"babysit":{"cadence_base_minutes":20}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -n "$ctx" ]] || fail "expected warning at streak=3 base=20m"
grep -q "60m" <<<"$ctx" || fail "expected 60m in message at base=20m, got: $ctx"
# 60 > 20 — strictly wider
ok "streak=3 base=20m → widen to 60m (3×base, strictly greater than base)"

# ── 5. No mid-tier: streak=6 with base=5m still widens to 15m (not 5m) ──────
write_state "$PR" '{"digest_streak":6,"babysit":{"cadence_base_minutes":5}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -n "$ctx" ]] || fail "expected warning at streak=6 base=5m"
grep -q "15m" <<<"$ctx"  || fail "expected 15m at streak=6 base=5m, got: $ctx"
grep -qv "5m " <<<"$ctx" || true   # 5m should NOT be the recommended interval
ok "streak=6 base=5m → still 15m (no 5m no-op interval, no mid-tier)"

# ── 6. Missing cadence_base_minutes defaults to 5m → 15m ─────────────────────
write_state "$PR" '{"digest_streak":3}'
ctx="$(run_hook "$PR" | context_of)"
[[ -n "$ctx" ]] || fail "expected warning when cadence_base_minutes absent"
grep -q "15m" <<<"$ctx" || fail "expected 15m when base absent (default 5), got: $ctx"
ok "absent cadence_base_minutes defaults to 5 → 15m"

# ── 7. Already-applied guard: no re-emit when update matches WIDE_MIN ─────────
# base=5m → WIDE_MIN=15m; last_cron_action already says update/15m → no-op
write_state "$PR" '{"digest_streak":4,"babysit":{"cadence_base_minutes":5},"last_cron_action":{"type":"update","interval":"15m"}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -z "$ctx" ]] || fail "expected no re-emit when update to 15m already applied, got: $ctx"
ok "already-applied guard: update to 15m not re-emitted at base=5m"

# ── 8. Already-applied guard: different interval → still emit ────────────────
# last_cron_action says update/5m (the old no-op interval) → hook must still emit
write_state "$PR" '{"digest_streak":4,"babysit":{"cadence_base_minutes":5},"last_cron_action":{"type":"update","interval":"5m"}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -n "$ctx" ]] || fail "expected warning when previous update was to wrong interval"
grep -q "15m" <<<"$ctx" || fail "expected 15m after stale 5m interval, got: $ctx"
ok "already-applied guard respects WIDE_MIN: stale 5m update → still emit 15m"

# ── 9. Already-applied guard for base=20m (WIDE_MIN=60m) ─────────────────────
write_state "$PR" '{"digest_streak":4,"babysit":{"cadence_base_minutes":20},"last_cron_action":{"type":"update","interval":"60m"}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -z "$ctx" ]] || fail "expected no re-emit when update to 60m already applied, got: $ctx"
ok "already-applied guard: update to 60m not re-emitted at base=20m"

# ── 10. stop already issued → no re-emit for either branch ───────────────────
write_state "$PR" '{"digest_streak":5,"babysit":{"cadence_base_minutes":5},"last_cron_action":{"type":"delete","interval":"paused"}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -z "$ctx" ]] || fail "expected no re-emit when delete already applied, got: $ctx"
ok "delete already applied → no re-emit from widen branch"

# ── 10b. Monitor path: no lifecycle record yet → STOP fires, and the marker
#         /babysit-pr T-END writes suppresses the second one.
write_state "$PR" '{"digest_streak":9,"babysit":{"cadence_base_minutes":5}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -n "$ctx" ]] || fail "expected STOP on a Monitor poll with no last_cron_action"
grep -q "TaskStop" <<<"$ctx" || fail "stop advisory must name TaskStop, got: $ctx"
grep -q "monitor_task_id" <<<"$ctx" || fail "stop advisory must name the recorded Monitor ID, got: $ctx"
grep -q "monitor_generation" <<<"$ctx" || fail "stop advisory must clear the matching Monitor generation, got: $ctx"
grep -q "atomically clear" <<<"$ctx" || fail "stop advisory must clear the Monitor identity atomically, got: $ctx"
ok "Monitor poll (no lifecycle record) → STOP emitted with exact teardown"

write_state "$PR" '{"digest_streak":9,"babysit":{"cadence_base_minutes":5},"last_cron_action":{"type":"delete","interval":"paused"}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -z "$ctx" ]] || fail "the stop marker /babysit-pr T-END writes must suppress a second STOP, got: $ctx"
ok "Monitor stop marker suppresses the repeat STOP"

# ── 10c. The widen advisory must never read as "stop the poll" ───────────────
# streak 3..8 means keep polling, slower. The stop instruction belongs only to
# the >=9 / user-blocked branch; conflating them silently kills the watcher at
# the first backoff threshold.
write_state "$PR" '{"digest_streak":4,"babysit":{"cadence_base_minutes":5}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -n "$ctx" ]] || fail "expected a widen advisory at streak=4"
grep -q "WIDEN" <<<"$ctx" || fail "widen advisory should be labelled WIDEN, got: $ctx"
grep -q "KEEP RUNNING" <<<"$ctx" || fail "widen advisory must say the poll keeps running, got: $ctx"
grep -q "Stop the poll" <<<"$ctx" && fail "widen advisory must not carry a stop-the-poll instruction, got: $ctx"
grep -q "TaskStop" <<<"$ctx" || fail "widen advisory must stop the prior Monitor task, got: $ctx"
grep -q "replacement at 15m" <<<"$ctx" || fail "widen advisory must arm the replacement cadence, got: $ctx"
grep -q "fresh monitor_generation" <<<"$ctx" || fail "widen advisory must generate a new Monitor generation, got: $ctx"
grep -q "atomically persist the new monitor_task_id + monitor_generation + effective cadence" <<<"$ctx" \
  || fail "widen advisory must atomically publish replacement identity and cadence, got: $ctx"
ok "widen advisory (streak 3..8) says keep running, never stop"

# ── 11. Streak >= 9 → stop the poll ──────────────────────────────────────────
write_state "$PR" '{"digest_streak":9,"babysit":{"cadence_base_minutes":5}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -n "$ctx" ]] || fail "expected STOP message at streak=9"
grep -q "Stop the poll" <<<"$ctx" || fail "expected a stop-the-poll instruction, got: $ctx"
grep -q "TaskStop" <<<"$ctx" || fail "stop message should name TaskStop for Monitor-backed polls, got: $ctx"
ok "streak>=9 → STOP the recorded Monitor task"

# ── 12. blocker_kind=user_input → stop immediately (any streak) ──────────────
write_state "$PR" '{"digest_streak":1,"blocker_kind":"user_input","babysit":{"cadence_base_minutes":5}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -n "$ctx" ]] || fail "expected STOP message on user_input even at streak=1"
grep -q "Stop the poll" <<<"$ctx" || fail "expected a stop-the-poll instruction in user_input stop, got: $ctx"
ok "blocker_kind=user_input → STOP the poll regardless of streak"

# ── 13. Stop branch "already applied" guard ───────────────────────────────────
write_state "$PR" '{"digest_streak":9,"babysit":{"cadence_base_minutes":5},"last_cron_action":{"type":"delete","interval":"paused"}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -z "$ctx" ]] || fail "expected no re-emit on stop branch when delete already applied, got: $ctx"
ok "stop branch: stop already applied → no re-emit"

# ── 14. Non-polling command exits silently ────────────────────────────────────
write_state "$PR" '{"digest_streak":5,"babysit":{"cadence_base_minutes":5}}'
ctx="$(jq -cn '{"tool_input":{"command":"echo hello"}}' | bash "$HOOK" | context_of)"
[[ -z "$ctx" ]] || fail "non-polling command should produce no context, got: $ctx"
ok "non-polling command → no context injected"

echo ""
echo "OK: polling-backoff-warn tests passed"
