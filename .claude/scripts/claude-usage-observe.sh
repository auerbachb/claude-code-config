#!/usr/bin/env bash
# claude-usage-observe.sh — Save the Claude usage the desktop app's usage tool reported, for /quotas and the weekly reserve.
# catalog: token-measurement — Validates the JSON the desktop app's usage tool (`mcp__ccd_session_mgmt__get_usage`) returned and saves its weekly figure for the account the session runs on, so `/quotas` and `quota-reserve.sh` read it with no token; refuses anything that is not plan status ok with a weekly all-models percent and reset time
#
# PURPOSE
#   The Claude desktop app runs no status line, so its main account had no source
#   that needed no token (#2404). The app does expose usage to the agent through
#   its usage tool. The agent calls it and pipes the result here; this script
#   validates and files it beside the status line's reading
#   (~/.claude/ai-quotas/status-line/claude-app--<label>.json). The quota reader
#   uses whichever of the two is newer and names it in the row's `source`.
#   The figure is the provider's own, reported by the app: nothing is estimated.
#
# USAGE
#   claude-usage-observe.sh <file|->     the tool's whole result, or just its `plan`
#   claude-usage-observe.sh --help | -h
#
# LIMIT RESETS (optional)
#   The usage tool does not return the "Limit resets: N available" the claude.ai usage
#   page shows. An agent that read the page may add it next to the tool result (or inside
#   the plan object) as `limit_resets`: {"count": 2, "items": [{"kind": "Fable reset",
#   "expires_at": "2027-03-09T00:00:00Z"}, ...]}, or a bare list of such items. It is
#   validated (count 0-1000, items matching it, a plain kind, a UTC ISO-8601 expiry); a
#   malformed block refuses the whole input and writes nothing. Absent, the saved reading
#   carries no reset count, and /quotas shows the blank marker, never 0.
#
# ACCOUNT
#   The account the calling session runs on: CLAUDE_CODE_USER_EMAIL when set,
#   else the session's signed-in .claude.json (CLAUDE_CONFIG_DIR, else HOME),
#   matched case-insensitively and exactly against the registered Claude
#   accounts (~/.claude/ai-quotas.json). Both present and different, zero or
#   several matches, or neither readable: refused. Never guessed, never defaulted.
#
# OUTPUT
#   One line. On success it names the account and the 7-day percent. On refusal
#   it names the reason, writes nothing, and exits non-zero.
#
# EXIT CODES
#   0   saved
#   1   refused (not status ok, no weekly all-models window, percent outside
#       0-100, unparseable reset, account not resolvable, write failed)
#   3   usage error
#   5   the reading library could not load
#
# Test seams: AI_QUOTAS_STATUSLINE_DIR, AI_QUOTAS_CONFIG, AI_QUOTAS_NOW.
set -uo pipefail

print_help() {
  awk 'NR == 1 { next } /^# catalog:/ { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

case "${1:-}" in
  -h|--help) print_help; exit 0 ;;
esac
[[ $# -eq 1 ]] || { echo "claude-usage-observe.sh: expected one argument, a file or - for stdin (see --help)" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "claude-usage-observe.sh: jq is required" >&2; exit 5; }

SELF_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SELF_PATH" ]]; do
  _parent="$(cd -P "$(dirname "$SELF_PATH")" && pwd -P)" || exit 5
  SELF_PATH="$(readlink "$SELF_PATH")" || exit 5
  [[ "$SELF_PATH" == /* ]] || SELF_PATH="$_parent/$SELF_PATH"
done
SELF_DIR="$(cd -P "$(dirname "$SELF_PATH")" && pwd -P)" || exit 5
# shellcheck source=/dev/null
source "$SELF_DIR/lib/claude-status-reading.sh" 2>/dev/null \
  || { echo "claude-usage-observe.sh: lib/claude-status-reading.sh could not load" >&2; exit 5; }

if [[ "$1" == "-" ]]; then
  INPUT="$(cat)"
else
  [[ -f "$1" && -r "$1" ]] || { echo "claude-usage-observe.sh: refused: cannot read $1" >&2; exit 1; }
  INPUT="$(cat -- "$1")"
fi

if csr_observe_app "$INPUT"; then
  exit 0
fi
echo "claude-usage-observe.sh: refused: $CSR_OBSERVE_REASON" >&2
exit 1
