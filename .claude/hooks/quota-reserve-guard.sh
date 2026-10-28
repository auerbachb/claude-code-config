#!/usr/bin/env bash
# Quota-reserve guard — PreToolUse hook (issue #1863).
# While the Claude account this session runs on is at or above the owner's weekly
# threshold (95% default), block autonomous work on it: launches, and any tool
# call made by a subagent or an automated turn beyond reads and the harness's own
# bookkeeping. The owner's own interactive turns are never blocked. The decision
# lives in quota-reserve.sh --decide; this wrapper only turns `deny` into exit 2.
#
# Fails open: a missing script, an unreadable marker, or any error allows the
# call. The common path (a fresh marker with no account in reserve) costs one
# grep and one stat, with no jq.

set -uo pipefail
INPUT="$(cat 2>/dev/null || true)"

[[ -n "${HOME:-}" ]] || exit 0   # no home, no marker: nothing to read, so allow
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
SCRIPT="${HERE%/hooks}/scripts/quota-reserve.sh"
[[ -x "$SCRIPT" ]] || exit 0

MARKER="${QUOTA_RESERVE_DIR:-$HOME/.claude/quota-reserve}/marker.json"
REFRESH="${QUOTA_RESERVE_REFRESH_SECONDS:-600}"
[[ "$REFRESH" =~ ^[0-9]+$ ]] || REFRESH=600

if [[ -f "$MARKER" ]] && ! grep -q '"state": *"reserve"' "$MARKER" 2>/dev/null; then
  NOW="${QUOTA_RESERVE_NOW:-$(date +%s)}"
  # GNU stat first: on Linux `stat -f` means filesystem status and can print a number that is not a mtime.
  MTIME="$(stat -c %Y "$MARKER" 2>/dev/null || stat -f %m "$MARKER" 2>/dev/null || echo 0)"
  [[ "$MTIME" =~ ^[0-9]+$ ]] || MTIME=0
  if [[ "$NOW" =~ ^[0-9]+$ ]] && (( NOW - MTIME >= 0 && NOW - MTIME < REFRESH )); then
    exit 0
  fi
fi

VERDICT="$(printf '%s' "$INPUT" | "$SCRIPT" --decide 2>/dev/null)" || exit 0
case "$VERDICT" in
  "deny "*)
    echo "BLOCKED: ${VERDICT#deny }" >&2
    exit 2 ;;
esac
exit 0
