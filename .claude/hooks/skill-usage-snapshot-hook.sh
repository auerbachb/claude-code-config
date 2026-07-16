#!/bin/bash
# skill-usage-snapshot-hook.sh — Stop hook: keep the skill-telemetry snapshot
# fresh (issue #572).
#
# Contract mirrors skill-usage-tracker.sh: consume stdin, always emit an empty
# JSON object, always exit 0 — this hook must never block or fail a session.
#
# The throttle pre-check here is deliberately cheap (bash + sed + date; no
# python, no jq, NO network) because Stop fires after every agent response.
# When a push is due, the real work — locking, authoritative throttle
# re-check, gh api calls — is backgrounded via skill-usage-snapshot.sh
# --push --quiet, so the hook returns immediately either way. State only
# advances on a confirmed push, so weeks offline simply retry on later Stops.

set -uo pipefail

# Consume stdin per the hook contract (content unused).
cat >/dev/null

# Always emit empty JSON and never fail — this hook is non-blocking.
trap 'echo "{}"; exit 0' EXIT

STATE_FILE="$HOME/.claude/skill-usage-snapshot-state.json"

INTERVAL_DAYS="${SNAPSHOT_INTERVAL_DAYS:-7}"
case "$INTERVAL_DAYS" in
  ''|*[!0-9]*) INTERVAL_DAYS=7 ;;
esac
# 0 is numeric but would make every Stop spawn a push attempt — clamp to >=1
# (matches the snapshot script, which rejects <1 outright).
[ "$INTERVAL_DAYS" -ge 1 ] || INTERVAL_DAYS=7
INTERVAL_SECS=$(( INTERVAL_DAYS * 86400 ))

# NOTE: no lock-dir short-circuit here on purpose. The snapshot script owns
# all lock handling — in-flight locks make it exit instantly, stale locks
# (crashed pusher) are stolen atomically. An early `[ -d lock ] && exit`
# in the hook would turn one crashed push into permanently disabled pushes.

# Throttle pre-check: parse last_push_epoch out of the state JSON with sed;
# missing/garbled state means "due" (first push ever).
LAST=0
if [ -f "$STATE_FILE" ]; then
  LAST=$(sed -n 's/.*"last_push_epoch"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$STATE_FILE" 2>/dev/null | head -1)
  LAST=${LAST:-0}
fi
NOW=$(date +%s)
if (( NOW - LAST < INTERVAL_SECS )); then
  exit 0
fi

# Due: background the real push. The snapshot script owns the lock and the
# authoritative under-lock throttle re-check, so concurrent Stop hooks from
# parallel sessions collapse to a single push. Pass the SANITIZED interval —
# the child would otherwise inherit the original invalid env value and exit
# on a usage error every Stop, and pushes would never succeed.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT="$HOOK_DIR/../scripts/skill-usage-snapshot.sh"
[ -f "$SNAPSHOT" ] || exit 0
SNAPSHOT_INTERVAL_DAYS="$INTERVAL_DAYS" nohup bash "$SNAPSHOT" --push --quiet >/dev/null 2>&1 &

exit 0
