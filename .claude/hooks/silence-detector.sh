#!/bin/bash
# Silence detector — PostToolUse hook (fires after every tool call)
# Checks if >5 minutes have passed since the agent last sent a visible message.
# If so, injects an additionalContext warning into the agent's context.
#
# Steady-state time injection is deduped (issue #773): the "Current system
# time" context is emitted at most once per SILENCE_TIME_INJECT_S (default
# 60s), so bursts of tool calls don't re-inject a near-identical value into
# the transcript on every call. The >5-min warning path always emits.
#
# Acknowledgment is handled automatically by the companion Stop hook
# (silence-detector-ack.sh), which touches the heartbeat file whenever
# Claude finishes a response.

# Capture stdin once so we can parse hook metadata while preserving the hook
# protocol's requirement to consume the payload.
STDIN_JSON=$(cat)

current_time=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET' 2>/dev/null)
[[ -z "$current_time" ]] && current_time="ET time unavailable"

emit_context() {
  printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PostToolUse",\n    "additionalContext": "%s"\n  }\n}\n' "$1"
}

file_mtime() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

file_size() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f %z "$1" 2>/dev/null
  else
    stat -c %s "$1" 2>/dev/null
  fi
}

parse_json_field() {
  local field="$1"
  printf '%s' "$STDIN_JSON" | jq -r "$field // empty" 2>/dev/null
}

rotate_log_if_needed() {
  local pending_size="$1"
  local size=0

  if [[ -f "$LOG_FILE" ]]; then
    size=$(file_size "$LOG_FILE")
  fi
  [[ -n "$size" ]] || size=0

  if (( size + pending_size >= LOG_MAX_SIZE )); then
    rm -f "${LOG_FILE}.1" 2>/dev/null || true
    mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
  fi
}

write_log() {
  local elapsed_s="$1"
  local ts entry pending_size

  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$LOG_DIR"
  entry=$(jq -nc \
    --arg ts "$ts" \
    --arg sid "$SESSION_ID" \
    --arg cwd "$CWD" \
    --arg tool "$TOOL_NAME" \
    --argjson elapsed "$elapsed_s" \
    '{ts: $ts, session_id: $sid, cwd: $cwd, elapsed_s: $elapsed, tool_name: $tool}')

  pending_size=$(printf '%s\n' "$entry" | LC_ALL=C wc -c | tr -d ' ')
  rotate_log_if_needed "$pending_size"

  printf '%s\n' "$entry" >> "$LOG_FILE"
}

# Session-scoped heartbeat file in /tmp
SESSION_ID=$(parse_json_field '.session_id')
SESSION_ID="${SESSION_ID:-${CLAUDE_SESSION_ID:-default}}"
SESSION_ID="${SESSION_ID//[^[:alnum:]_.-]/_}"
HEARTBEAT_FILE="/tmp/claude-heartbeat-${SESSION_ID}"
WARNED_FILE="/tmp/claude-silence-warned-${SESSION_ID}"
ACTIVE_FILE="/tmp/claude-active-${SESSION_ID}"
TIME_FILE="/tmp/claude-time-injected-${SESSION_ID}"
THRESHOLD=300  # 5 minutes in seconds
COOLDOWN_S="${SILENCE_WARN_COOLDOWN_S:-90}"
[[ "$COOLDOWN_S" =~ ^[0-9]+$ ]] || COOLDOWN_S=90
TIME_INJECT_S="${SILENCE_TIME_INJECT_S:-60}"
[[ "$TIME_INJECT_S" =~ ^[0-9]+$ ]] || TIME_INJECT_S=60

emit_time_if_due() {
  # Dedupe (issue #773): skip the time injection when one landed < TIME_INJECT_S ago.
  # $1 = "force": bypass the dedupe check — new-session paths must always emit,
  # even when a marker from a prior same-id session (e.g. the shared "default"
  # id) survives in /tmp.
  if [[ "${1:-}" != "force" && -f "$TIME_FILE" ]]; then
    local last_inject inject_age
    last_inject=$(file_mtime "$TIME_FILE")
    if [[ -n "$last_inject" ]]; then
      inject_age=$(( $(date +%s) - last_inject ))
      # Negative age = future-dated marker (clock rollback) — treat as stale, re-inject.
      if (( inject_age >= 0 && inject_age < TIME_INJECT_S )); then
        echo '{}'
        return
      fi
    fi
  fi
  if ! touch "$TIME_FILE" 2>/dev/null; then
    # Deliberate fail-open: an unwritable marker degrades to the pre-dedupe
    # behavior (inject every call) rather than losing time context. Surface it
    # so the condition is visible in hook logs instead of silent.
    echo "silence-detector: cannot write $TIME_FILE — time-injection dedupe disabled this call" >&2
  fi
  emit_context "Current system time: ${current_time}"
}
LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/silence.log"
LOG_MAX_SIZE=$((10 * 1024 * 1024))
TOOL_NAME=$(parse_json_field '.tool_name')
CWD=$(parse_json_field '.cwd')

# A PostToolUse event means the agent is still in a turn until the Stop hook
# clears this marker after the next visible response.
touch "$ACTIVE_FILE" 2>/dev/null || true

# Operator away (issue #2594): he reads no chat, so never nag for a visible
# message. Instead remind the thread, at most once per AWAY_REMIND_S, to write
# nothing to chat and log what it would have said for /back. presence.sh is
# consulted only on a new session or when this call would otherwise emit
# something (warning or time injection), so the common no-output path stays cheap.
AWAY_FILE="/tmp/claude-away-reminded-${SESSION_ID}"
AWAY_REMIND_S="${AWAY_REMIND_S:-900}"
[[ "$AWAY_REMIND_S" =~ ^[0-9]+$ ]] || AWAY_REMIND_S=900
operator_away() {
  local p="${PRESENCE_SH:-}" c dir
  if [[ -z "$p" ]]; then
    dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
    for c in "$dir/../scripts/presence.sh" \
             "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/presence.sh}" \
             "${HOME:+$HOME/.claude/scripts/presence.sh}"; do
      [[ -n "$c" && -x "$c" ]] && { p="$c"; break; }
    done
  fi
  [[ -n "$p" && -x "$p" ]] || return 1
  "$p" is-away >/dev/null 2>&1
}
time_due() {
  [[ -f "$TIME_FILE" ]] || return 0
  local m; m=$(file_mtime "$TIME_FILE"); [[ -n "$m" ]] || return 0
  local age=$(( $(date +%s) - m )); (( age < 0 || age >= TIME_INJECT_S ))
}
# Away handling: refresh the heartbeat (silence is expected), then the reminder
# when its throttle allows, else the time injection. $1 = "force" on new-session
# paths: the reminder ignores a marker left by an earlier same-id session.
away_emit() {
  local remind=1 am now_s
  now_s=$(date +%s)
  touch "$HEARTBEAT_FILE" 2>/dev/null || true
  rm -f "$WARNED_FILE" 2>/dev/null || true
  if [[ "${1:-}" != "force" && -f "$AWAY_FILE" ]]; then
    am=$(file_mtime "$AWAY_FILE")
    if [[ -n "$am" ]] && (( now_s - am >= 0 && now_s - am < AWAY_REMIND_S )); then remind=0; fi
  fi
  if (( remind )); then
    touch "$AWAY_FILE" "$TIME_FILE" 2>/dev/null || true
    emit_context "Current system time: ${current_time}. OPERATOR AWAY (presence): while presence reports away he reads no chat; he catches up with /back. Write NO chat text: no progress, status, merge line, blocker notice, recap or closing summary (if a turn must end with text, the shortest allowed close). Append each thing you would have said with away-log.sh append --kind blocker|decision|owner-task|merged|stopped|summary|note --text '<one line, no secret values>' (first of ~/.claude/skills-worktree/.claude/scripts/, ~/.claude/scripts/, .claude/scripts/). Questions still go to the unattended queue; gates, safety stops and records are unchanged. Contract: .claude/reference/away-log.md."
  else
    emit_time_if_due
  fi
}

# If heartbeat file doesn't exist, create it (first tool call in session)
if [[ ! -f "$HEARTBEAT_FILE" ]]; then
  touch "$HEARTBEAT_FILE"
  if operator_away; then away_emit force; else emit_time_if_due force; fi
  exit 0
fi
last_ack=$(file_mtime "$HEARTBEAT_FILE")

# Fallback if stat failed
if [[ -z "$last_ack" ]]; then
  touch "$HEARTBEAT_FILE"
  if operator_away; then away_emit force; else emit_time_if_due force; fi
  exit 0
fi

now=$(date +%s)
elapsed=$((now - last_ack))

if { [[ $elapsed -ge $THRESHOLD ]] || time_due; } && operator_away; then
  away_emit
  exit 0
fi

if [[ $elapsed -ge $THRESHOLD ]]; then
  if [[ -f "$WARNED_FILE" ]]; then
    warned_mtime=$(file_mtime "$WARNED_FILE")
    if [[ -n "$warned_mtime" ]]; then
      warned_age=$((now - warned_mtime))
      if (( warned_age < COOLDOWN_S )); then
        echo '{}'
        exit 0
      fi
    fi
  fi

  elapsed_min=$((elapsed / 60))
  ( write_log "$elapsed" ) || true
  touch "$WARNED_FILE"
  touch "$TIME_FILE" 2>/dev/null || true  # warning carries a fresh time — restart the dedupe window
  emit_context "Current system time: ${current_time}. SILENCE CHECK: No visible message in ${elapsed_min}+ minutes (${elapsed}s). Apply decision-only-output.md: surface an explicit status request, requested periodic report, blocker, failure, decision, safety event, verified stall, unknown health, stopped or exhausted recovery, or defined always-emit exception now. Keep the notice concise and action first. Otherwise continue silently; routine progress and unchanged work need no status or timestamp prefix."
else
  emit_time_if_due
fi

exit 0
