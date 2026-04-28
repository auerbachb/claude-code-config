#!/bin/bash
# External silence watchdog for macOS launchd.
#
# This complements the in-process PostToolUse hook by checking heartbeat files
# even when Claude is stalled and no tool hook is firing. macOS-only v1.

set -euo pipefail

LABEL="com.user.claude-silence-watchdog"
HEARTBEAT_PREFIX="/tmp/claude-heartbeat-"
THRESHOLD_MINUTES="${SILENCE_THRESHOLD_MINUTES:-10}"
if [[ ! "$THRESHOLD_MINUTES" =~ ^[0-9]+$ ]] || (( THRESHOLD_MINUTES == 0 )); then
  THRESHOLD_MINUTES=10
fi
THRESHOLD_S=$((THRESHOLD_MINUTES * 60))
LOG_DIR="$HOME/.claude/logs"
STATE_FILE="$LOG_DIR/watchdog-state.json"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "$LABEL: macOS-only v1; Linux support is out of scope." >&2
  exit 0
fi

mkdir -p "$LOG_DIR"

if [[ ! -f "$STATE_FILE" ]] || ! jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
  printf '{}\n' > "$STATE_FILE"
fi

file_mtime() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

notify() {
  local session_id="$1"
  osascript \
    -e 'on run argv' \
    -e 'display notification ("Session " & item 1 of argv & " has been silent for " & item 2 of argv & "+ minutes.") with title "Claude silent"' \
    -e 'end run' \
    -- "$session_id" "$THRESHOLD_MINUTES" >/dev/null 2>&1 || true
}

tmp_state=$(mktemp "${STATE_FILE}.tmp.XXXXXX")
trap 'rm -f "$tmp_state" "${tmp_state}.next"' EXIT
cp "$STATE_FILE" "$tmp_state"

now=$(date +%s)
shopt -s nullglob
for heartbeat in "${HEARTBEAT_PREFIX}"*; do
  [[ -f "$heartbeat" ]] || continue

  base="$(basename "$heartbeat")"
  [[ "$base" == claude-heartbeat-warned-* ]] && continue

  session_id="${base#claude-heartbeat-}"
  [[ "$session_id" =~ ^[[:alnum:]_.-]+$ ]] || continue
  mtime="$(file_mtime "$heartbeat")"
  [[ -n "$mtime" ]] || continue

  age=$((now - mtime))
  if (( age < THRESHOLD_S )); then
    jq --arg path "$heartbeat" 'del(.[$path])' "$tmp_state" > "${tmp_state}.next"
    mv "${tmp_state}.next" "$tmp_state"
    continue
  fi

  already_alerted="$(jq -r --arg path "$heartbeat" --arg mtime "$mtime" '.[$path] == ($mtime | tonumber)' "$tmp_state")"
  if [[ "$already_alerted" == "true" ]]; then
    continue
  fi

  notify "$session_id"
  jq --arg path "$heartbeat" --argjson mtime "$mtime" '.[$path] = $mtime' "$tmp_state" > "${tmp_state}.next"
  mv "${tmp_state}.next" "$tmp_state"
done
shopt -u nullglob

# Drop state for heartbeat files that no longer exist.
jq 'with_entries(select(.key | test("^/tmp/claude-heartbeat-warned-") | not))' "$tmp_state" > "${tmp_state}.next"
mv "${tmp_state}.next" "$tmp_state"
jq 'with_entries(select(.key | startswith("/tmp/claude-heartbeat-")))' "$tmp_state" > "${tmp_state}.next"
mv "${tmp_state}.next" "$tmp_state"
while IFS= read -r path; do
  if [[ ! -f "$path" ]]; then
    jq --arg path "$path" 'del(.[$path])' "$tmp_state" > "${tmp_state}.next"
    mv "${tmp_state}.next" "$tmp_state"
  fi
done < <(jq -r 'keys[]' "$tmp_state")

mv "$tmp_state" "$STATE_FILE"
trap - EXIT
