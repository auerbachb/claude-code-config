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
export HOME="$TMP_DIR/home" CLAUDE_SESSION_STATE_FILE="$TMP_DIR/session-state.json"
mkdir -p "$HOME"
printf '{"repos":{}}' > "$CLAUDE_SESSION_STATE_FILE"
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

# --- 16. Arm wording fits a runtime whose Monitor expires (Issue #2201) -----
SID=$(new_sid wording)
CTX=$(run_arm "$SID" Agent | context_of)
[[ "$CTX" == *"timeout_ms at the runtime maximum"* ]] || fail "the advisory must ask for the maximum timeout_ms, got: '$CTX'"
[[ "$CTX" == *"only if the tool schema lists it"* ]] || fail "persistent: true must be conditional, got: '$CTX'"
[[ "$CTX" == *"every expiry notice"* ]] || fail "the advisory must require re-arm on expiry, got: '$CTX'"
REASON=$(run_guard "$SID" | jq -r '.reason')
[[ "$REASON" == *"timeout_ms at the runtime maximum"* && "$REASON" == *"every expiry notice"* ]] || \
  fail "the block reason must carry the expiring-runtime wording, got: '$REASON'"
ok "arm advisory and block reason name timeout_ms, conditional persistent, and re-arm on expiry"

# --- 17. A lapsed watch is reported at Stop, once per lapse, never blocking --
backdate() { touch -t "$(date -v-"$2"M +%Y%m%d%H%M 2>/dev/null || date -d "$2 minutes ago" +%Y%m%d%H%M)" "$1"; }
SID=$(new_sid lapse)
run_arm "$SID" Agent >/dev/null
run_arm "$SID" Monitor "$("$CEILING" --arm-command --session "$SID")" >/dev/null
"$CEILING" --tick --session "$SID" >/dev/null
OUT=$(run_guard "$SID")
[[ "$(printf '%s' "$OUT" | context_of)" == "" ]] || fail "a ticking watch must produce no Stop notice, got: '$OUT'"
backdate "$CLAUDE_BGWORK_MARKER_DIR/claude-bgceiling-armed-$SID" 40
backdate "$CLAUDE_BGWORK_MARKER_DIR/claude-bgceiling-ticked-$SID" 35
"$CEILING" --check --session "$SID"; RC=$?
[[ $RC -eq 3 ]] || fail "--check must exit 3 for an armed watch that stopped ticking, got $RC"
OUT=$(run_guard "$SID")
[[ "$(printf '%s' "$OUT" | jq -r '.decision // ""')" != "block" ]] || fail "a lapsed watch must not block the turn"
[[ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // ""')" == "Stop" ]] || \
  fail "the lapse notice must be a Stop hookSpecificOutput, got: '$OUT'"
[[ "$(printf '%s' "$OUT" | jq -c '[keys, (.hookSpecificOutput | keys)]')" == '[["hookSpecificOutput"],["additionalContext","hookEventName"]]' ]] || \
  fail "the lapse notice must be exactly {hookSpecificOutput:{hookEventName,additionalContext}} (no decision/reason/continue), got: '$OUT'"
CTX=$(printf '%s' "$OUT" | context_of)
[[ "$CTX" == *"CEILING LAPSED"* && "$CTX" == *"bgwork-ceiling.sh --tick --session $SID"* ]] || \
  fail "the lapse notice must name the lapse and carry the re-arm command, got: '$CTX'"
[[ "$CTX" == *"do not re-arm"* ]] || fail "the lapse notice must say not to re-arm when no work remains, got: '$CTX'"
[[ "$(run_guard "$SID" | context_of)" == "" ]] || fail "the same lapse must be reported once, not on every Stop"
[[ "$(run_guard "$SID" true | context_of)" == "" ]] || fail "a continued Stop must not repeat the lapse notice"
[[ "$(run_arm "$SID" Read | context_of)" == "" ]] || fail "the arm hook must not nag about a lapse on every tool call"
ok "a lapsed watch gets one non-blocking Stop notice per lapse, with the re-arm command"

# Re-arming clears the lapse; a later lapse is reportable again.
run_arm "$SID" Monitor "$("$CEILING" --arm-command --session "$SID")" >/dev/null
"$CEILING" --check --session "$SID" || fail "re-arming must make --check pass again"
backdate "$CLAUDE_BGWORK_MARKER_DIR/claude-bgceiling-armed-$SID" 20
[[ "$(run_guard "$SID" | context_of)" == *"CEILING LAPSED"* ]] || fail "a new lapse after re-arming must be reported again"
ok "re-arming clears the lapse, and the next lapse is reported again"

# --- 18. A watch pinned to another session is named, not silently rejected ---
SID=$(new_sid mismatch)
run_arm "$SID" Agent >/dev/null
WRONG=$("$CEILING" --arm-command --session default)
CTX=$(run_arm "$SID" Monitor "$WRONG" | context_of)
[[ "$CTX" == *"SESSION MISMATCH"* && "$CTX" == *"targets session default"* && "$CTX" == *"this session is $SID"* ]] || \
  fail "a mismatched watch must produce the mismatch advisory, got: '$CTX'"
"$CEILING" --check --session "$SID" && fail "a mismatched watch must not count as armed"
CTX=$(run_arm "$SID" Bash "grep -rn 'bgwork-ceiling.sh --tick --session default' ." | context_of)
[[ "$CTX" != *"SESSION MISMATCH"* ]] || fail "merely mentioning another session's tick must not draw the mismatch advisory"
ok "a watch armed for another session gets a mismatch advisory naming both ids"

# --- 19. A bare --arm-command uses the SessionStart handoff id --------------
SID=$(new_sid handoff)
ADVISED=$(run_arm "$SID" Agent | context_of)
BARE=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID CLAUDE_BGCEILING_SESSION_ID="$SID" "$CEILING" --arm-command)
[[ "$ADVISED" == *"$BARE"* ]] || fail "the bare --arm-command must equal the advisory's command, got '$BARE'"
run_arm "$SID" Monitor "$BARE" >/dev/null
"$CEILING" --check --session "$SID" || fail "submitting the bare --arm-command output must arm session $SID"
ok "a bare --arm-command with the handoff id matches the advisory and arms the session"

echo "OK: bgwork-ceiling hook tests passed"
