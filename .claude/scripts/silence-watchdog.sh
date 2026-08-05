#!/bin/bash
# External silence watchdog for macOS launchd.
#
# This complements the in-process PostToolUse hook by checking heartbeat files
# even when Claude is stalled and no tool hook is firing. macOS-only v1.
#
# Gap 2 fix (issue #809): the unconditional active-marker skip is replaced with
# a conditional check. When the active marker is absent (session ended its
# turn), the watchdog now calls has_bgwork() to determine whether background
# work is in flight for that session. If no background work: existing behavior
# is preserved (clear dedupe state, skip). If background work is in flight: the
# session falls through to the normal staleness evaluation so a genuinely
# stalled background-work session can reach notify().
#
# Gap 1 — injecting back into a stalled session — remains deferred: no harness
# API for external session injection exists today (SDK send/stream removed;
# Channels is a research-preview MCP bridge, not usable from launchd; IPC/tmux
# are community-only). The watchdog's action stays an OS notification only.
#
# Testability env overrides (never affect production defaults):
#   CLAUDE_WATCHDOG_LOG_DIR    — override $HOME/.claude/logs for state/log
#   CLAUDE_WATCHDOG_MARKER_DIR — override /tmp for heartbeat+active markers
#   CLAUDE_BGWORK_MARKER_DIR   — override /tmp for bgwork markers (shared with
#                                bgwork-ceiling.sh)
#   CLAUDE_WATCHDOG_FORCE_RUN  — set to "1" to bypass the Darwin-only guard
#   BGWORK_CEILING_SH          — override path to bgwork-ceiling.sh

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log"

LABEL="com.user.claude-silence-watchdog"
# CLAUDE_BGWORK_MARKER_DIR is the authoritative override for all markers (shared
# with bgwork-ceiling.sh). CLAUDE_WATCHDOG_MARKER_DIR overrides only the
# heartbeat and active markers; when unset it falls back to CLAUDE_BGWORK_MARKER_DIR
# so a single variable is sufficient to redirect all I/O in tests.
BGWORK_MARKER_DIR="${CLAUDE_BGWORK_MARKER_DIR:-/tmp}"
WATCHDOG_MARKER_DIR="${CLAUDE_WATCHDOG_MARKER_DIR:-${CLAUDE_BGWORK_MARKER_DIR:-/tmp}}"
HEARTBEAT_PREFIX="${WATCHDOG_MARKER_DIR}/claude-heartbeat-"
ACTIVE_PREFIX="${WATCHDOG_MARKER_DIR}/claude-active-"
THRESHOLD_MINUTES="${SILENCE_THRESHOLD_MINUTES:-10}"
if [[ ! "$THRESHOLD_MINUTES" =~ ^[0-9]+$ ]] || (( THRESHOLD_MINUTES == 0 )); then
  THRESHOLD_MINUTES=10
fi
THRESHOLD_S=$((THRESHOLD_MINUTES * 60))
LOG_DIR="${CLAUDE_WATCHDOG_LOG_DIR:-$HOME/.claude/logs}"
STATE_FILE="$LOG_DIR/watchdog-state.json"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BGWORK_CEILING_SH="${BGWORK_CEILING_SH:-${SCRIPT_DIR}/bgwork-ceiling.sh}"

if [[ "$(uname -s)" != "Darwin" ]] && [[ "${CLAUDE_WATCHDOG_FORCE_RUN:-}" != "1" ]]; then
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

# has_bgwork SESSION_ID — exits 0 if background work is in flight for the
# session, 1 otherwise. Strictly side-effect-free: only read-only modes.
#
# Primary: invoke bgwork-ceiling.sh --status --session ID and check the
# background_work array length. Falls back to a direct read-only marker
# existence check when bgwork-ceiling.sh is missing or non-executable,
# honouring BGWORK_MARKER_DIR (via CLAUDE_BGWORK_MARKER_DIR) so the watchdog
# stays consistent with the ceiling machinery's marker location.
#
# Armed-marker guard: when the ceiling was previously armed (armed==true in
# --status, or the claude-bgceiling-armed-<id> file is present), the Monitor
# watch is (or was) responsible for ceiling enforcement. We skip the notification
# in that case to avoid false positives from sessions where background work
# already completed and the bgwork marker was never cleaned up. The bgwork
# marker is append-only by design — it has no production cleanup path — so
# has_bgwork() would otherwise return true for any session that ever had
# background work, even long-idle or dead sessions. Sessions that were never
# armed (the gap-2 scenario) still fall through to notify() as intended.
has_bgwork() {
  local sid="$1"
  if [[ -x "$BGWORK_CEILING_SH" ]]; then
    local status_json bg_count armed RC
    RC=0
    status_json="$("$BGWORK_CEILING_SH" --status --session "$sid" 2>/dev/null)" || RC=$?
    if [[ $RC -eq 0 && -n "$status_json" ]]; then
      # If the ceiling was armed, the Monitor watch handles detection; skip to
      # avoid false positives from historical bgwork markers.
      armed="$(printf '%s' "$status_json" | jq -r '.armed // false' 2>/dev/null)"
      [[ "$armed" == "true" ]] && return 1
      # Use -e (error on null/false) and type-check so a schema failure or
      # malformed JSON falls through to the marker check rather than returning
      # "no background work" — failing open on a probe failure is safer here.
      if bg_count="$(printf '%s' "$status_json" | jq -er '
        .background_work
        | if type == "array" then length else error("background_work is not an array") end
      ' 2>/dev/null)"; then
        (( bg_count > 0 )) && return 0
        return 1
      fi
    fi
  fi
  # Fallback: direct read-only existence check. Skip sessions where the ceiling
  # was previously armed (same guard as the primary path above).
  local armed_file="${BGWORK_MARKER_DIR}/claude-bgceiling-armed-${sid}"
  [[ -f "$armed_file" ]] && return 1
  [[ -f "${BGWORK_MARKER_DIR}/claude-bgwork-${sid}" ]]
}

notify() {
  local session_id="$1" is_bgwork="${2:-false}"
  local title body
  if [[ "$is_bgwork" == "true" ]]; then
    title="Claude stalled — background work in flight"
    body="Session ${session_id} has been silent for ${THRESHOLD_MINUTES}+ minutes while background work is in flight."
  else
    title="Claude silent"
    body="Session ${session_id} has been silent for ${THRESHOLD_MINUTES}+ minutes."
  fi
  osascript \
    -e 'on run argv' \
    -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
    -e 'end run' \
    -- "$title" "$body" >/dev/null 2>&1
}

tmp_state=$(mktemp "${STATE_FILE}.tmp.XXXXXX")
trap 'rm -f "$tmp_state" "${tmp_state}.next"' EXIT
cp "$STATE_FILE" "$tmp_state"

now=$(date +%s)
shopt -s nullglob
for heartbeat in "${HEARTBEAT_PREFIX}"*; do
  [[ -f "$heartbeat" ]] || continue

  base="$(basename "$heartbeat")"

  session_id="${base#claude-heartbeat-}"
  [[ "$session_id" =~ ^[[:alnum:]_.-]+$ ]] || continue
  active_file="${ACTIVE_PREFIX}${session_id}"
  if [[ ! -f "$active_file" ]]; then
    # Active marker absent: the session has ended its turn and is waiting.
    # Only fall through to staleness evaluation when background work is in
    # flight — that is the stalled-background-work case this fix targets.
    # Normal idle sessions and finished sessions must not notify.
    if ! has_bgwork "$session_id"; then
      jq --arg path "$heartbeat" 'del(.[$path])' "$tmp_state" > "${tmp_state}.next"
      mv "${tmp_state}.next" "$tmp_state"
      continue
    fi
    # Background work in flight: fall through to staleness evaluation.
  fi

  # Determine whether this is a background-work session (no active marker) or
  # an in-turn session (active marker present), so notify() can use a distinct
  # message for the background-work case.
  is_bgwork="false"
  [[ ! -f "$active_file" ]] && is_bgwork="true"

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

  if notify "$session_id" "$is_bgwork"; then
    jq --arg path "$heartbeat" --argjson mtime "$mtime" '.[$path] = $mtime' "$tmp_state" > "${tmp_state}.next"
    mv "${tmp_state}.next" "$tmp_state"
  fi
done
shopt -u nullglob

# Drop state for heartbeat files that no longer exist.
jq --arg pfx "$HEARTBEAT_PREFIX" 'with_entries(select(.key | startswith($pfx)))' "$tmp_state" > "${tmp_state}.next"
mv "${tmp_state}.next" "$tmp_state"
while IFS= read -r path; do
  if [[ ! -f "$path" ]]; then
    jq --arg path "$path" 'del(.[$path])' "$tmp_state" > "${tmp_state}.next"
    mv "${tmp_state}.next" "$tmp_state"
  fi
done < <(jq -r 'keys[]' "$tmp_state")

mv "$tmp_state" "$STATE_FILE"
trap - EXIT
