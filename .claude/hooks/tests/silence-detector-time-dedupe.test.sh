#!/usr/bin/env bash
# Tests for silence-detector.sh steady-state time-injection dedupe (issue #773).
# Uses a unique session id per test so the /tmp marker files are isolated;
# does not touch real session state.
set -euo pipefail

# Isolate from caller environment — default-window assertions must not inherit
# a CI/user override; test 6 passes the env var explicitly.
unset SILENCE_TIME_INJECT_S

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/silence-detector.sh"

# Relative timestamps (BSD/macOS then GNU date) — never a hard-coded calendar
# date, which flips future/past depending on when the test runs.
PAST_STAMP=$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)
FUTURE_STAMP=$(date -v+2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours' +%Y%m%d%H%M)

fail() { echo "FAIL: $*" >&2; exit 1; }

run_hook() {
  local sid="$1"
  printf '{"session_id": "%s", "tool_name": "Bash", "cwd": "/tmp"}' "$sid" | "$HOOK"
}

context_of() {
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))"
}

# Session-scoped tmp files the hook derives from the session id
tmp_files() {
  local sid="$1"
  echo "/tmp/claude-heartbeat-${sid}" "/tmp/claude-silence-warned-${sid}" \
       "/tmp/claude-active-${sid}" "/tmp/claude-time-injected-${sid}"
}

SID="dedupe-test-$$-$RANDOM"
cleanup() { rm -f $(tmp_files "$SID"); }
trap cleanup EXIT
cleanup

# --- 1. First call in a session injects the time -----------------------------
CTX=$(run_hook "$SID" | context_of)
[[ "$CTX" == Current\ system\ time:* ]] || fail "first call should inject time, got: '$CTX'"

# --- 2. Immediate second call is deduped to {} -------------------------------
OUT=$(run_hook "$SID")
CTX=$(printf '%s' "$OUT" | context_of)
[[ -z "$CTX" ]] || fail "second call within SILENCE_TIME_INJECT_S should emit no context, got: '$CTX'"
printf '%s' "$OUT" | python3 -c "import json,sys; json.load(sys.stdin)" || fail "deduped output is not valid JSON"

# --- 3. An aged marker re-injects --------------------------------------------
touch -t "$PAST_STAMP" "/tmp/claude-time-injected-${SID}"
CTX=$(run_hook "$SID" | context_of)
[[ "$CTX" == Current\ system\ time:* ]] || fail "aged marker should re-inject time, got: '$CTX'"

# --- 3b. A future-dated marker (clock rollback) re-injects -------------------
touch -t "$FUTURE_STAMP" "/tmp/claude-time-injected-${SID}"
CTX=$(run_hook "$SID" | context_of)
[[ "$CTX" == Current\ system\ time:* ]] || fail "future-dated marker should be treated as stale and re-inject, got: '$CTX'"

# --- 4. Warning path fires with time even inside the dedupe window -----------
# Fresh time marker (just injected in step 3b) + stale heartbeat => warning must
# still be emitted and must carry the timestamp.
touch -t "$PAST_STAMP" "/tmp/claude-heartbeat-${SID}"
rm -f "/tmp/claude-silence-warned-${SID}"
CTX=$(run_hook "$SID" | context_of)
[[ "$CTX" == *"HEARTBEAT WARNING"* ]] || fail "stale heartbeat should warn, got: '$CTX'"
[[ "$CTX" == Current\ system\ time:* ]] || fail "warning should include current time, got: '$CTX'"

# --- 5. Warned-cooldown path still emits {} ----------------------------------
# Heartbeat still stale, warned file fresh from step 4 => cooldown suppression.
CTX=$(run_hook "$SID" | context_of)
[[ -z "$CTX" ]] || fail "warned-cooldown call should emit no context, got: '$CTX'"

# --- 5b. New session with a leftover marker still gets its first timestamp ---
# Simulates same-session-id reuse (e.g. the shared "default" id): heartbeat
# file absent, fresh time marker present — the first call must force-emit.
touch "/tmp/claude-time-injected-${SID}"          # fresh marker, deterministically
rm -f "/tmp/claude-heartbeat-${SID}" "/tmp/claude-silence-warned-${SID}"
CTX=$(run_hook "$SID" | context_of)
[[ "$CTX" == Current\ system\ time:* ]] || fail "new session with leftover marker should force-inject, got: '$CTX'"

# --- 6. Env override is respected --------------------------------------------
SID2="dedupe-test-env-$$-$RANDOM"
rm -f $(tmp_files "$SID2")
run_hook "$SID2" >/dev/null                      # seeds marker
sleep 1
CTX=$(printf '{"session_id": "%s", "tool_name": "Bash", "cwd": "/tmp"}' "$SID2" | SILENCE_TIME_INJECT_S=1 "$HOOK" | context_of)
rm -f $(tmp_files "$SID2")
[[ "$CTX" == Current\ system\ time:* ]] || fail "SILENCE_TIME_INJECT_S=1 after 1s sleep should re-inject, got: '$CTX'"

echo "PASS: silence-detector time-dedupe tests"
