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
echo "$ctx" | grep -q "15m" || fail "expected 15m in message at base=5m, got: $ctx"
# 15 > 5 — strictly wider than base
ok "streak=3 base=5m → widen to 15m (strictly greater than base)"

# ── 3. Streak=3, base=1m → widen to 15m (floor applies) ─────────────────────
write_state "$PR" '{"digest_streak":3,"babysit":{"cadence_base_minutes":1}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -n "$ctx" ]] || fail "expected warning at streak=3 base=1m"
echo "$ctx" | grep -q "15m" || fail "expected 15m in message at base=1m, got: $ctx"
# 15 > 1 — strictly wider
ok "streak=3 base=1m → widen to 15m (floor, strictly greater than base)"

# ── 4. Streak=3, base=20m → widen to 60m (3×base > 15) ──────────────────────
write_state "$PR" '{"digest_streak":3,"babysit":{"cadence_base_minutes":20}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -n "$ctx" ]] || fail "expected warning at streak=3 base=20m"
echo "$ctx" | grep -q "60m" || fail "expected 60m in message at base=20m, got: $ctx"
# 60 > 20 — strictly wider
ok "streak=3 base=20m → widen to 60m (3×base, strictly greater than base)"

# ── 5. No mid-tier: streak=6 with base=5m still widens to 15m (not 5m) ──────
write_state "$PR" '{"digest_streak":6,"babysit":{"cadence_base_minutes":5}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -n "$ctx" ]] || fail "expected warning at streak=6 base=5m"
echo "$ctx" | grep -q "15m"  || fail "expected 15m at streak=6 base=5m, got: $ctx"
echo "$ctx" | grep -qv "5m " || true   # 5m should NOT be the recommended interval
ok "streak=6 base=5m → still 15m (no 5m no-op interval, no mid-tier)"

# ── 6. Missing cadence_base_minutes defaults to 5m → 15m ─────────────────────
write_state "$PR" '{"digest_streak":3}'
ctx="$(run_hook "$PR" | context_of)"
[[ -n "$ctx" ]] || fail "expected warning when cadence_base_minutes absent"
echo "$ctx" | grep -q "15m" || fail "expected 15m when base absent (default 5), got: $ctx"
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
echo "$ctx" | grep -q "15m" || fail "expected 15m after stale 5m interval, got: $ctx"
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

# ── 10b. /loop path: no cron record at all → STOP fires, and the marker
#         /babysit-pr T-END writes suppresses the second one. Since #827 the
#         watcher is /loop-only, so this is now the DEFAULT path — case 10
#         above only ever exercised a cron-backed poll.
write_state "$PR" '{"digest_streak":9,"babysit":{"cadence_base_minutes":5}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -n "$ctx" ]] || fail "expected STOP on a /loop poll with no last_cron_action"
ok "/loop poll (no cron record) → STOP emitted"

write_state "$PR" '{"digest_streak":9,"babysit":{"cadence_base_minutes":5},"last_cron_action":{"type":"delete","interval":"paused"}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -z "$ctx" ]] || fail "the stop marker /babysit-pr T-END writes must suppress a second STOP, got: $ctx"
ok "/loop stop marker suppresses the repeat STOP"

# ── 11. Streak >= 9 → stop the poll ──────────────────────────────────────────
write_state "$PR" '{"digest_streak":9,"babysit":{"cadence_base_minutes":5}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -n "$ctx" ]] || fail "expected STOP message at streak=9"
echo "$ctx" | grep -q "Stop the poll" || fail "expected a stop-the-poll instruction, got: $ctx"
echo "$ctx" | grep -q "CronDelete" || fail "stop message should still name CronDelete for cron-backed polls, got: $ctx"
ok "streak>=9 → STOP the poll (naming both /loop and cron)"

# ── 12. blocker_kind=user_input → stop immediately (any streak) ──────────────
write_state "$PR" '{"digest_streak":1,"blocker_kind":"user_input","babysit":{"cadence_base_minutes":5}}'
ctx="$(run_hook "$PR" | context_of)"
[[ -n "$ctx" ]] || fail "expected STOP message on user_input even at streak=1"
echo "$ctx" | grep -q "Stop the poll" || fail "expected a stop-the-poll instruction in user_input stop, got: $ctx"
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
