#!/usr/bin/env bash
# catalog: token-measurement — Save the text of the Google Antigravity `agy` `/usage` panel, with its capture time, where `/quotas` reads it (Issue #2407); ingests pasted text or a file, runs `agy -p "/usage"` only when asked with --live, or runs interactive `agy` in the terminal you are looking at with --terminal; reads no credential, display only
#
# Usage:
#   quotas-antigravity-capture.sh --from-file FILE     save a panel you saved or pasted
#   quotas-antigravity-capture.sh --stdin              same, read from standard input
#   quotas-antigravity-capture.sh --live               run `agy -p "/usage"` (UNVERIFIED, see below)
#   quotas-antigravity-capture.sh --terminal           run interactive agy HERE, type /usage, save the panel
#   --captured-at EPOCH   when the text was captured (default: now)
#   --observation FILE    where to write (default ~/.claude/ai-quotas-antigravity.json,
#                         or AI_QUOTAS_ANTIGRAVITY_OBSERVATION)
#
# Manual route: run `agy`, type `/usage`, copy the panel text, then
#   pbpaste | quotas-antigravity-capture.sh --stdin
#
# --terminal (Issue #2466) must run in a terminal you can see and type into: it starts `agy`
# on that terminal, types /usage for you and saves the panel (source `terminal`). If agy asks
# you to sign in, sign in right there; the read finishes by itself and gives up after
# AI_QUOTAS_TERMINAL_TIMEOUT seconds (default 300). It never logs in for you. With no terminal
# on its input (an agent's shell, cron, CI) it refuses at once. In the Claude desktop app the
# agent runs this command in the Terminal panel; elsewhere run it yourself.
#
# --live is opt-in because print mode with a slash command has not been confirmed to
# print the panel (it might send "/usage" to a model instead). It runs the CLI's own
# command with stdin closed and a 90 s limit, keeps stdout only, and stores nothing when
# the output holds no usage panel. Input without a usage window is refused and the saved
# observation is left as it was. Exit: 0 saved, 2 usage, 3 refused/unreadable, 5 setup.
set -euo pipefail

SELF_PATH="${BASH_SOURCE[0]}"
while [[ -L "$SELF_PATH" ]]; do
  d="$(cd -P "$(dirname "$SELF_PATH")" && pwd -P)"
  SELF_PATH="$(readlink "$SELF_PATH")"
  [[ "$SELF_PATH" == /* ]] || SELF_PATH="$d/$SELF_PATH"
done
SELF_DIR="$(cd -P "$(dirname "$SELF_PATH")" && pwd -P)"
PARSER="$SELF_DIR/lib/quotas-antigravity.py"

die() { echo "quotas-antigravity-capture.sh: $2" >&2; exit "$1"; }

MODE=""; SRC=""; CAPTURED="${AI_QUOTAS_NOW:-$(date +%s)}"
OBS="${AI_QUOTAS_ANTIGRAVITY_OBSERVATION:-${HOME:-}/.claude/ai-quotas-antigravity.json}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-file) [[ $# -ge 2 ]] || die 2 "--from-file needs a file"; MODE="file"; SRC="$2"; shift 2 ;;
    --stdin) MODE=stdin; shift ;;
    --live) MODE=live; shift ;;
    --terminal) MODE=terminal; shift ;;
    --captured-at) [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || die 2 "--captured-at needs an epoch"; CAPTURED="$2"; shift 2 ;;
    --observation) [[ $# -ge 2 ]] || die 2 "--observation needs a path"; OBS="$2"; shift 2 ;;
    -h|--help) awk 'NR >= 3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$SELF_PATH"; exit 0 ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done
[[ -n "$MODE" ]] || die 2 "choose --from-file, --stdin, --live or --terminal (try --help)"
[[ "$CAPTURED" -le $(( ${AI_QUOTAS_NOW:-$(date +%s)} + 300 )) ]] || die 2 "--captured-at is in the future"
[[ "$OBS" == /* ]] || die 2 "observation path must be absolute (HOME unset?)"
command -v python3 >/dev/null 2>&1 || die 5 "python3 is required"
[[ -r "$PARSER" ]] || die 5 "lib/quotas-antigravity.py not found — install the complete scripts directory"

RESULT=""
RC=0
case "$MODE" in
  file) [[ -r "$SRC" ]] || die 2 "cannot read $SRC"; RESULT="$(python3 -I "$PARSER" ingest "$SRC" "$CAPTURED" pasted "$OBS")" || RC=$? ;;
  stdin) RESULT="$(python3 -I "$PARSER" ingest - "$CAPTURED" pasted "$OBS")" || RC=$? ;;
  terminal)
    AGY="${AI_QUOTAS_AGY_BIN:-}"
    [[ -n "$AGY" ]] || AGY="$(command -v agy 2>/dev/null || true)"
    for candidate in /opt/homebrew/bin/agy /usr/local/bin/agy; do
      [[ -n "$AGY" ]] || { [[ -x "$candidate" ]] && AGY="$candidate"; } || true
    done
    [[ -x "$AGY" ]] || die 5 "no agy CLI found; install Antigravity or use --from-file"
    RESULT="$(python3 -I "$PARSER" terminal "$AGY" "$CAPTURED" "$OBS")" || RC=$? ;;
  live)
    AGY="${AI_QUOTAS_AGY_BIN:-}"
    [[ -n "$AGY" ]] || AGY="$(command -v agy 2>/dev/null || true)"
    # Same install locations ai-quotas-setup.sh accepts.
    for candidate in /opt/homebrew/bin/agy /usr/local/bin/agy; do
      [[ -n "$AGY" ]] || { [[ -x "$candidate" ]] && AGY="$candidate"; } || true
    done
    [[ -x "$AGY" ]] || die 5 "no agy CLI found; install Antigravity or use --from-file"
    RESULT="$(python3 -I "$PARSER" capture "$AGY" "$CAPTURED" "$OBS")" || RC=$? ;;
esac

if [[ "$RC" -ne 0 ]]; then
  reason="$(printf '%s' "$RESULT" | jq -r '.reason // "unreadable"' 2>/dev/null || echo unreadable)"
  die 3 "nothing saved: $reason. Run agy, type /usage, copy the panel, then: pbpaste | $(basename "$SELF_PATH") --stdin"
fi
printf '%s' "$RESULT" | jq -r '"saved: " + ([.groups[] | .windows | length] | add | tostring) + " windows in " + (.groups | length | tostring) + " groups"'
