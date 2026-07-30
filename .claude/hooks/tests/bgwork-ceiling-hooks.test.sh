#!/usr/bin/env bash
# Tests for the background-work silence ceiling hooks (issue #803):
#   bgwork-ceiling-arm.sh    PostToolUse — detect background work, advise arming
#   bgwork-ceiling-guard.sh  Stop        — fail closed when it was not armed
#
# Markers and logs are redirected into a temp dir, so the suite never touches
# real session state in /tmp or ~/.claude.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ARM="$REPO_ROOT/.claude/hooks/bgwork-ceiling-arm.sh"
GUARD="$REPO_ROOT/.claude/hooks/bgwork-ceiling-guard.sh"
CEILING="$REPO_ROOT/.claude/scripts/bgwork-ceiling.sh"

TMP_DIR="$(mktemp -d)"
export CLAUDE_BGWORK_MARKER_DIR="$TMP_DIR/markers"
export CLAUDE_BGWORK_LOG_DIR="$TMP_DIR/logs"
mkdir -p "$CLAUDE_BGWORK_MARKER_DIR" "$CLAUDE_BGWORK_LOG_DIR"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

unset CLAUDE_BGWORK_CEILING_S CLAUDE_BGWORK_MAX_BLOCKS

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   — $*"; }

# Each block of assertions gets its own session id so markers never leak
# between cases.
new_sid() { printf 'bgceil-hooks-%s-%s-%s' "$$" "$RANDOM" "$1"; }

run_arm() {
  local sid="$1" tool="$2" cmd="${3:-}" bg="${4:-false}"
  jq -nc --arg sid "$sid" --arg tool "$tool" --arg cmd "$cmd" --argjson bg "$bg" \
    '{session_id: $sid, tool_name: $tool,
      tool_input: ({} | if $cmd == "" then . else .command = $cmd end
                      | if $bg then .run_in_background = true else . end)}' \
    | bash "$ARM"
}

run_guard() {
  printf '{"session_id":"%s","stop_hook_active":%s}' "$1" "${2:-false}" | bash "$GUARD" 2>/dev/null
}

context_of() { jq -r '.hookSpecificOutput.additionalContext // ""'; }
started_kinds() { "$CEILING" --status --session "$1" | jq -r '.background_work | join(",")'; }

# --- 1. A foreground read is not background work -----------------------------
SID=$(new_sid readonly)
OUT=$(run_arm "$SID" Read)
[[ "$(printf '%s' "$OUT" | context_of)" == "" ]] || fail "a Read call should inject no context"
[[ "$(started_kinds "$SID")" == "" ]] || fail "a Read call should not record background work"
ok "an ordinary foreground tool call records nothing and injects nothing"

# --- 2. Each background-starting tool shape is detected ----------------------
SID=$(new_sid agent);    run_arm "$SID" Agent    >/dev/null
[[ "$(started_kinds "$SID")" == "Agent" ]] || fail "Agent spawn should record background work"
SID=$(new_sid workflow); run_arm "$SID" Workflow >/dev/null
[[ "$(started_kinds "$SID")" == "Workflow" ]] || fail "Workflow should record background work"
SID=$(new_sid monitor);  run_arm "$SID" Monitor "tail -f app.log" >/dev/null
[[ "$(started_kinds "$SID")" == "Monitor" ]] || fail "a non-ceiling Monitor should record background work"
SID=$(new_sid bashbg);   run_arm "$SID" Bash "sleep 600" true >/dev/null
[[ "$(started_kinds "$SID")" == "Bash" ]] || fail "a backgrounded Bash should record background work"
ok "Agent / Workflow / Monitor / backgrounded Bash all register as background work"

# --- 3. A foreground Bash does NOT ------------------------------------------
SID=$(new_sid bashfg)
run_arm "$SID" Bash "ls -la" false >/dev/null
[[ "$(started_kinds "$SID")" == "" ]] || fail "a foreground Bash should not record background work"
ok "a foreground Bash is not treated as background work"

# --- 4. The advisory names the arming call ----------------------------------
SID=$(new_sid advise)
CTX=$(run_arm "$SID" Agent | context_of)
[[ "$CTX" == *"CEILING NOT ARMED"* ]] || fail "unarmed background work should inject a warning, got: '$CTX'"
[[ "$CTX" == *"Monitor"* ]] || fail "the advisory must name the Monitor tool, got: '$CTX'"
[[ "$CTX" == *"bgwork-ceiling.sh --tick"* ]] || fail "the advisory must carry the arm command, got: '$CTX'"
[[ "$CTX" == *"persistent: true"* ]] || fail "the advisory must specify a persistent watch, got: '$CTX'"
ok "the advisory carries the exact arming call, not a description of it"

# --- 4b. The spawning call always advises; later reminders are rate-limited --
SID=$(new_sid cooldown)
[[ -n "$(run_arm "$SID" Agent | context_of)" ]] || fail "the spawning call must always advise"
[[ -z "$(run_arm "$SID" Read | context_of)" ]] || \
  fail "a follow-up call inside the cooldown should not replay the advisory"
[[ -n "$(CLAUDE_BGWORK_ADVISE_COOLDOWN_S=0 run_arm "$SID" Read | context_of)" ]] || \
  fail "the reminder should return once the cooldown lapses"
# A second spawn is the step arming belongs in, so it advises regardless.
[[ -n "$(run_arm "$SID" Agent | context_of)" ]] || \
  fail "a later spawn must advise even inside the cooldown"
ok "the spawning call always advises; follow-up reminders are rate-limited"

# --- 5. Arming is recognised, and is not itself counted as background work ---
SID=$(new_sid armmon)
ARM_CMD=$("$CEILING" --arm-command --session "$SID")
OUT=$(run_arm "$SID" Monitor "$ARM_CMD")
[[ "$(printf '%s' "$OUT" | context_of)" == "" ]] || fail "arming should inject no further advice"
[[ "$(started_kinds "$SID")" == "" ]] || \
  fail "the ceiling watch must not be counted as background work (that would leave the gate unsatisfiable)"
"$CEILING" --check --session "$SID" || fail "--check should pass after the ceiling Monitor is seen"
ok "the ceiling watch registers as arming, never as new background work"

# --- 5b. Merely MENTIONING the sentinel must not count as arming ------------
# A guard that can be satisfied by talking about it is not a guard. In this
# repo especially, commands referencing the watch are routine.
SID=$(new_sid mention)
run_arm "$SID" Agent >/dev/null
for decoy in "grep -rn 'bgwork-ceiling.sh --tick' ." \
             "bash .claude/scripts/tests/bgwork-ceiling.test.sh" \
             "$CEILING --tick --session $SID"; do
  run_arm "$SID" Bash "$decoy" >/dev/null
  "$CEILING" --check --session "$SID" && \
    fail "a command that only mentions the watch must not satisfy the gate: $decoy"
done
ok "mentioning the sentinel does not arm — only the generated watch command does"

# --- 6. Arming is matched on the command, not the tool name -----------------
SID=$(new_sid armbash)
run_arm "$SID" Agent >/dev/null
ARM_CMD=$("$CEILING" --arm-command --session "$SID")
run_arm "$SID" Bash "$ARM_CMD" true >/dev/null
"$CEILING" --check --session "$SID" || fail "arming via a backgrounded Bash should also satisfy --check"
ok "arming is detected by the sentinel, whichever tool starts the watch"

# --- 7. Stop hook is transparent when there is nothing to guard -------------
SID=$(new_sid guardclean)
OUT=$(run_guard "$SID")
[[ "$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)" != "block" ]] || \
  fail "the Stop hook must not block when no background work has started"
ok "the Stop hook is transparent when there is nothing to guard"

# --- 8. Stop hook fails CLOSED: unarmed background work blocks the turn ------
SID=$(new_sid guardblock)
run_arm "$SID" Agent >/dev/null
OUT=$(run_guard "$SID")
[[ "$(printf '%s' "$OUT" | jq -r '.decision')" == "block" ]] || \
  fail "unarmed background work must block the turn end, got: '$OUT'"
REASON=$(printf '%s' "$OUT" | jq -r '.reason')
[[ "$REASON" == *"bgwork-ceiling.sh --tick"* ]] || \
  fail "the block reason must carry the arm command so the next step can act, got: '$REASON'"
ok "the Stop hook blocks the turn when background work is in flight and unarmed"

# --- 9. Blocking is bounded, and standing down is LOUD, never silent --------
SID=$(new_sid guardbound)
run_arm "$SID" Agent >/dev/null
D1=$(run_guard "$SID" | jq -r '.decision // ""')
D2=$(run_guard "$SID" true | jq -r '.decision // ""')
[[ "$D1" == "block" && "$D2" == "block" ]] || fail "the first two turn ends should block, got '$D1' / '$D2'"
ERR=$(printf '{"session_id":"%s","stop_hook_active":true}' "$SID" | bash "$GUARD" 2>&1 >/dev/null)
D3=$(run_guard "$SID" true | jq -r '.decision // ""')
[[ "$D3" != "block" ]] || fail "blocking must be bounded — the third turn end should stand down"
[[ "$ERR" == *"STOOD DOWN"* ]] || fail "standing down must be announced on stderr, got: '$ERR'"
[[ -f "$CLAUDE_BGWORK_MARKER_DIR/claude-bgceiling-unguarded-$SID" ]] || \
  fail "standing down must leave an unguarded marker behind"
grep -q "guard-stood-down" "$CLAUDE_BGWORK_LOG_DIR/bgwork-ceiling.log" || \
  fail "standing down must be logged"
ok "blocking is bounded, and standing down is loud on stderr, in state, and in the log"

# --- 10. Once unguarded, every later tool call resurfaces it ----------------
CTX=$(run_arm "$SID" Read | context_of)
[[ "$CTX" == *"UNGUARDED"* ]] || fail "an unguarded thread should be resurfaced on later tool calls, got: '$CTX'"
ok "an unguarded thread is resurfaced on every subsequent tool call"

# --- 11. Arming clears the block counter and the unguarded marker ----------
ARM_CMD=$("$CEILING" --arm-command --session "$SID")
run_arm "$SID" Monitor "$ARM_CMD" >/dev/null
[[ -f "$CLAUDE_BGWORK_MARKER_DIR/claude-bgceiling-unguarded-$SID" ]] && \
  fail "arming should clear the unguarded marker"
OUT=$(run_guard "$SID")
[[ "$(printf '%s' "$OUT" | jq -r '.decision // ""')" != "block" ]] || \
  fail "the Stop hook should pass once armed"
[[ "$(printf '%s' "$(run_arm "$SID" Read)" | context_of)" == "" ]] || \
  fail "an armed thread should get no further advisories"
ok "arming clears the block counter, the unguarded marker, and all advisories"

# --- 12. A later spawn is already covered — arm once, not once per spawn ----
run_arm "$SID" Agent >/dev/null
OUT=$(run_guard "$SID")
[[ "$(printf '%s' "$OUT" | jq -r '.decision // ""')" != "block" ]] || \
  fail "a second spawn under an armed persistent watch must not re-block"
ok "the persistent watch covers later spawns — arming is once per session"

# --- 13. Hooks degrade quietly when the enforcement script is absent --------
SANDBOX="$TMP_DIR/sandbox"
mkdir -p "$SANDBOX/hooks" "$SANDBOX/scripts"
cp "$ARM" "$GUARD" "$SANDBOX/hooks/"
SID=$(new_sid noscript)
OUT=$(printf '{"session_id":"%s","tool_name":"Agent","tool_input":{}}' "$SID" | bash "$SANDBOX/hooks/bgwork-ceiling-arm.sh" 2>&1)
RC=$?
[[ $RC -eq 0 ]] || fail "the arm hook should exit 0 when bgwork-ceiling.sh is missing, got $RC"
[[ -z "$OUT" ]] || fail "the arm hook should stay quiet when bgwork-ceiling.sh is missing, got: '$OUT'"
OUT=$(printf '{"session_id":"%s"}' "$SID" | bash "$SANDBOX/hooks/bgwork-ceiling-guard.sh" 2>&1)
RC=$?
[[ $RC -eq 0 ]] || fail "the guard hook should exit 0 when bgwork-ceiling.sh is missing, got $RC"
[[ -z "$OUT" ]] || fail "the guard hook should stay quiet when bgwork-ceiling.sh is missing, got: '$OUT'"
ok "both hooks degrade quietly in a checkout without the enforcement script"

# --- 14. Both hooks emit well-formed JSON or nothing at all ----------------
SID=$(new_sid json)
for payload in '{"session_id":"'"$SID"'","tool_name":"Read","tool_input":{}}' \
               '{"session_id":"'"$SID"'","tool_name":"Agent","tool_input":{}}'; do
  printf '%s' "$payload" | bash "$ARM" | jq -e . >/dev/null || fail "arm hook emitted invalid JSON for: $payload"
done
run_guard "$SID" | jq -e . >/dev/null || fail "guard hook emitted invalid JSON"
ok "both hooks emit well-formed JSON"

# --- 15. End-to-end: the exact failing case from issue #803 ----------------
# Parent spawns a subagent, ends its turn, and waits on the completion
# notification with ZERO intervening tool calls. Replayed in order, with no
# hook invocation at all between arming and the breach — which is the whole
# point: nothing in-turn can fire, so only the out-of-turn watch can speak.
SID=$(new_sid e2e)
HB="$CLAUDE_BGWORK_MARKER_DIR/claude-heartbeat-$SID"

touch "$HB"                                              # parent's last message
run_arm "$SID" Agent >/dev/null                          # spawn a subagent
OUT=$(run_guard "$SID")                                  # try to end the turn
[[ "$(printf '%s' "$OUT" | jq -r '.decision')" == "block" ]] || \
  fail "ending the turn right after a spawn must be blocked while unarmed"

ARM_CMD=$(printf '%s' "$OUT" | jq -r '.reason' | sed -n 's/.*command: \(.*\) — then finish.*/\1/p')
[[ -n "$ARM_CMD" ]] || fail "the block reason must yield a runnable arm command"
run_arm "$SID" Monitor "$ARM_CMD" >/dev/null             # arm as instructed
OUT=$(run_guard "$SID")                                  # now the turn may end
[[ "$(printf '%s' "$OUT" | jq -r '.decision // ""')" != "block" ]] || \
  fail "the turn should be allowed to end once the ceiling is armed"

# The thread is now idle: no tool calls, no turns, nothing in-context running.
# `--tick` is exactly what the armed watch loop runs, so calling it directly
# reproduces the watch without spawning a real background loop in the suite.
OUT=$("$CEILING" --tick --session "$SID")
[[ -z "$OUT" ]] || fail "a freshly-quiet thread should not breach yet, got: '$OUT'"
touch -t "$(date -v-25M +%Y%m%d%H%M 2>/dev/null || date -d '25 minutes ago' +%Y%m%d%H%M)" "$HB"
OUT=$("$CEILING" --tick --session "$SID")
[[ "$OUT" == *"CEILING BREACH"* ]] || \
  fail "the armed watch must break the silence with zero intervening tool calls, got: '$OUT'"
ok "end-to-end: spawn → blocked → armed → turn ends → watch breaks the silence unaided"

echo "OK: bgwork-ceiling hook tests passed"
