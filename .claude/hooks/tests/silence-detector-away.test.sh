#!/usr/bin/env bash
# Tests for silence-detector.sh while the operator is away (issue #2594): no SILENCE CHECK nag,
# an OPERATOR AWAY reminder at most once per AWAY_REMIND_S, the normal nag again once he is here.
# presence.sh is stubbed through PRESENCE_SH; the /tmp marker files use a unique session id.
set -euo pipefail
unset SILENCE_TIME_INJECT_S AWAY_REMIND_S

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/silence-detector.sh"
TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
PAST_STAMP=$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)

STUB="$TEST_HOME/presence.sh"
printf '#!/bin/sh\n[ "$1" = is-away ] && exit "$(cat "%s/away-rc")"\nexit 1\n' "$TEST_HOME" >"$STUB"
chmod +x "$STUB"
export PRESENCE_SH="$STUB"
set_away() { echo 0 >"$TEST_HOME/away-rc"; }
set_here() { echo 1 >"$TEST_HOME/away-rc"; }

fail() { echo "FAIL: $*" >&2; exit 1; }
run_hook() { printf '{"session_id": "%s", "tool_name": "Bash", "cwd": "/tmp"}' "$SID" | "$HOOK"; }
context_of() {
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))"
}
SID="away-test-$$-$RANDOM"
FILES=("/tmp/claude-heartbeat-$SID" "/tmp/claude-silence-warned-$SID" "/tmp/claude-active-$SID"
       "/tmp/claude-time-injected-$SID" "/tmp/claude-away-reminded-$SID")
cleanup() { rm -f "${FILES[@]}"; rm -rf "$TEST_HOME"; }
trap cleanup EXIT
rm -f "${FILES[@]}"

# --- 0. New session while away: the first call carries the reminder -------------------------
set_away
CTX=$(run_hook | context_of)
[[ "$CTX" == *"OPERATOR AWAY"* ]] || fail "new away session should remind on its first call, got: '$CTX'"

# --- 1. Away + long silence: reminder, never the nag ----------------------------------------
touch -t "$PAST_STAMP" /tmp/claude-away-reminded-$SID
touch -t "$PAST_STAMP" /tmp/claude-heartbeat-$SID     # 2 hours of silence
CTX=$(run_hook | context_of)
[[ "$CTX" == *"OPERATOR AWAY"* ]] || fail "away + silence should remind, got: '$CTX'"
[[ "$CTX" != *"SILENCE CHECK"* ]] || fail "away must never emit SILENCE CHECK"
[[ "$CTX" == *"away-log.sh append"* ]] || fail "reminder should name away-log.sh append"

# --- 2. Heartbeat refreshed: silence while away is expected ---------------------------------
if [[ "$(uname -s)" == "Darwin" ]]; then hb=$(stat -f %m /tmp/claude-heartbeat-$SID); else hb=$(stat -c %Y /tmp/claude-heartbeat-$SID); fi
age=$(( $(date +%s) - hb ))
(( age < 60 )) || fail "heartbeat should be refreshed while away (age ${age}s)"

# --- 3. Reminder is throttled: the next due time injection carries only the time ------------
touch -t "$PAST_STAMP" /tmp/claude-time-injected-$SID
CTX=$(run_hook | context_of)
[[ "$CTX" == Current\ system\ time:* && "$CTX" != *"OPERATOR AWAY"* ]] || fail "throttled reminder should emit time only, got: '$CTX'"

# --- 4. Aged reminder marker reminds again ---------------------------------------------------
touch -t "$PAST_STAMP" /tmp/claude-away-reminded-$SID /tmp/claude-time-injected-$SID
CTX=$(run_hook | context_of)
[[ "$CTX" == *"OPERATOR AWAY"* ]] || fail "aged marker should remind again, got: '$CTX'"

# --- 5. Back here: the normal nag returns ----------------------------------------------------
set_here
touch -t "$PAST_STAMP" /tmp/claude-heartbeat-$SID
CTX=$(run_hook | context_of)
[[ "$CTX" == *"SILENCE CHECK"* ]] || fail "here + silence should nag, got: '$CTX'"

# --- 6. Away but nothing due: no output, presence not needed ---------------------------------
set_away
touch /tmp/claude-heartbeat-$SID /tmp/claude-time-injected-$SID
CTX=$(run_hook | context_of)
[[ -z "$CTX" ]] || fail "nothing due should emit nothing, got: '$CTX'"

# --- 7. New session with a stale same-id reminder marker still reminds -----------------------
rm -f /tmp/claude-heartbeat-$SID; touch /tmp/claude-away-reminded-$SID
CTX=$(run_hook | context_of)
[[ "$CTX" == *"OPERATOR AWAY"* ]] || fail "new session must ignore a leftover reminder marker, got: '$CTX'"

# --- 8. presence.sh missing: treated as here (time on a new session, never a reminder) -------
rm -f /tmp/claude-heartbeat-$SID
CTX=$(PRESENCE_SH="$TEST_HOME/missing.sh" run_hook | context_of)
[[ "$CTX" == Current\ system\ time:* && "$CTX" != *"OPERATOR AWAY"* ]] || fail "missing presence.sh should fall back to normal output, got: '$CTX'"

echo "PASS: silence-detector-away (9 checks)"
