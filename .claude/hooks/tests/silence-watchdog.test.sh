#!/usr/bin/env bash
# Tests for silence-watchdog.sh (issue #809).
#
# Gap 2 fix: the watchdog now fires an OS notification for marker-absent
# sessions with background work in flight, instead of silently skipping them.
#
# Coverage:
#   (a) active marker present, stale heartbeat -> notifies
#   (b) active marker absent, no background work -> skips, no notification
#   (c) active marker absent, bgwork marker present, stale heartbeat -> notifies
#   (d) dedupe suppresses repeat notification for the same mtime
#   (e) bgwork-ceiling.sh missing -> fallback to direct marker check
#
# Markers and state are redirected into a temp dir; no real session state is
# touched. osascript is PATH-shadowed by a fake that records invocations.
# Darwin guard bypassed via CLAUDE_WATCHDOG_FORCE_RUN=1.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WATCHDOG="$REPO_ROOT/.claude/scripts/silence-watchdog.sh"
BGWORK_CEILING="$REPO_ROOT/.claude/scripts/bgwork-ceiling.sh"

TMP_DIR="$(mktemp -d)"
MARKER_DIR="$TMP_DIR/markers"
LOG_DIR="$TMP_DIR/logs"
FAKE_BIN="$TMP_DIR/bin"
NOTIFY_LOG="$TMP_DIR/notify.log"

mkdir -p "$MARKER_DIR" "$LOG_DIR" "$FAKE_BIN"

# PATH-shadowed fake osascript: records each argv to NOTIFY_LOG.
cat > "$FAKE_BIN/osascript" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${NOTIFY_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$FAKE_BIN/osascript"
export PATH="$FAKE_BIN:$PATH"
export NOTIFY_LOG

# Redirect all marker and state I/O into the temp dir.
export CLAUDE_WATCHDOG_MARKER_DIR="$MARKER_DIR"
export CLAUDE_BGWORK_MARKER_DIR="$MARKER_DIR"
export CLAUDE_WATCHDOG_LOG_DIR="$LOG_DIR"
# Bypass Darwin-only guard so the suite runs on Linux CI.
export CLAUDE_WATCHDOG_FORCE_RUN="1"
# Short threshold so stale stamps are easily constructed.
export SILENCE_THRESHOLD_MINUTES="5"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok   — $*"; }

# past_stamp MINUTES — emit a touch -t format stamp MINUTES minutes in the past.
# BSD (macOS) date -v, GNU date -d.  Fails fast if neither works.
past_stamp() {
  local mins="$1"
  date -v-"${mins}"M +%Y%m%d%H%M 2>/dev/null || date -d "${mins} minutes ago" +%Y%m%d%H%M
}

_probe="$(past_stamp 1)" || fail "no usable date implementation"
[[ "$_probe" =~ ^[0-9]{12}$ ]] || fail "past_stamp probe produced malformed stamp: '$_probe'"

# Unique session id per test case so markers never leak.
new_sid() { printf 'watchdog-%s-%s-%s' "$$" "$RANDOM" "$1"; }

run_watchdog() {
  bash "$WATCHDOG"
}

# Count lines in NOTIFY_LOG (each osascript call appends one line).
notify_count() {
  [[ -f "$NOTIFY_LOG" ]] && wc -l < "$NOTIFY_LOG" | tr -d '[:space:]' || printf '0'
}

# Remove all per-session markers and the notify log before each test case so
# cases are independent.
reset_all() {
  rm -f "$NOTIFY_LOG"
  rm -f "${LOG_DIR}/watchdog-state.json"
  rm -f "${MARKER_DIR}"/claude-*
}

# ── (a) Active marker present, stale heartbeat -> notifies ──────────────────
reset_all
SID=$(new_sid active)
touch -t "$(past_stamp 12)" "${MARKER_DIR}/claude-heartbeat-${SID}"
touch "${MARKER_DIR}/claude-active-${SID}"
run_watchdog
[[ "$(notify_count)" -ge 1 ]] || fail "(a) active+stale heartbeat should notify"
ok "(a) active marker + stale heartbeat -> notifies"

# ── (b) Active marker absent, no background work -> skips ───────────────────
reset_all
SID=$(new_sid idle)
touch -t "$(past_stamp 12)" "${MARKER_DIR}/claude-heartbeat-${SID}"
# No active marker; no bgwork marker.
run_watchdog
[[ "$(notify_count)" -eq 0 ]] || fail "(b) idle session without bgwork should NOT notify"
ok "(b) active marker absent, no bgwork -> skips silently"

# ── (c) Active marker absent, bgwork present, stale -> notifies ─────────────
reset_all
SID=$(new_sid bgwork)
touch -t "$(past_stamp 12)" "${MARKER_DIR}/claude-heartbeat-${SID}"
# No active marker (session ended its turn).
# Create bgwork marker via bgwork-ceiling.sh so state is canonical.
CLAUDE_BGWORK_MARKER_DIR="$MARKER_DIR" CLAUDE_BGWORK_LOG_DIR="$LOG_DIR" \
  "$BGWORK_CEILING" --note-started "Agent" --session "$SID"
run_watchdog
[[ "$(notify_count)" -ge 1 ]] || fail "(c) stale bgwork session should notify"
# The notification body must mention background work.
grep -qi "background work" "$NOTIFY_LOG" || fail "(c) notification should mention background work"
ok "(c) active marker absent + bgwork + stale -> notifies with background-work message"

# ── (d) Dedupe suppresses repeat notification for the same mtime ────────────
reset_all
SID=$(new_sid dedupe)
STALE_STAMP="$(past_stamp 12)"
touch -t "$STALE_STAMP" "${MARKER_DIR}/claude-heartbeat-${SID}"
CLAUDE_BGWORK_MARKER_DIR="$MARKER_DIR" CLAUDE_BGWORK_LOG_DIR="$LOG_DIR" \
  "$BGWORK_CEILING" --note-started "Agent" --session "$SID"
run_watchdog
COUNT1="$(notify_count)"
[[ "$COUNT1" -ge 1 ]] || fail "(d) first run should notify"
# Second run with the same mtime must be deduped.
run_watchdog
COUNT2="$(notify_count)"
[[ "$COUNT2" -eq "$COUNT1" ]] || fail "(d) second run with same mtime should be deduped (count went $COUNT1 -> $COUNT2)"
ok "(d) dedupe suppresses repeat notification for the same heartbeat mtime"

# ── (e) bgwork-ceiling.sh missing -> fallback to direct marker check ─────────
reset_all
SID=$(new_sid fallback)
touch -t "$(past_stamp 12)" "${MARKER_DIR}/claude-heartbeat-${SID}"
# Point BGWORK_CEILING_SH at a non-existent path to force the fallback.
# Create the bgwork marker directly (bypassing bgwork-ceiling.sh).
touch "${MARKER_DIR}/claude-bgwork-${SID}"
BGWORK_CEILING_SH="/nonexistent/bgwork-ceiling.sh" run_watchdog
[[ "$(notify_count)" -ge 1 ]] || fail "(e) fallback to direct marker check should notify"
ok "(e) bgwork-ceiling.sh missing -> direct marker fallback -> notifies"

# ── (f) NEGATIVE CONTROL: active marker absent, bgwork present, fresh heartbeat -> silent
reset_all
SID=$(new_sid fresh)
# Heartbeat is fresh (2 min ago, threshold is 5 min).
touch -t "$(past_stamp 2)" "${MARKER_DIR}/claude-heartbeat-${SID}"
CLAUDE_BGWORK_MARKER_DIR="$MARKER_DIR" CLAUDE_BGWORK_LOG_DIR="$LOG_DIR" \
  "$BGWORK_CEILING" --note-started "Agent" --session "$SID"
run_watchdog
[[ "$(notify_count)" -eq 0 ]] || fail "(f) fresh heartbeat with bgwork should NOT notify"
ok "(f) active marker absent + bgwork + fresh heartbeat -> silent (not stale enough)"

echo "PASS: silence-watchdog tests"
