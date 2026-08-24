#!/usr/bin/env bash
# execution-pause.sh — Session-scoped, repo-scoped background-launch gate.
#
# USAGE
#   execution-pause.sh [--repo owner/name] --activate --session ID
#       --command pause|suspend --window-minutes N
#   execution-pause.sh [--repo owner/name] --clear --session ID
#   execution-pause.sh [--repo owner/name] --status --session ID
#
# `--status` prints active|inactive and exits 0. An on-disk marker mirrors an
# active write so a corrupted/unreadable session-state file fails closed only
# for a session that had positively armed the gate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_STATE_SH="$SCRIPT_DIR/session-state.sh"
MARKER_DIR="${CLAUDE_EXECUTION_PAUSE_MARKER_DIR:-/tmp}"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "execution-pause.sh: $1" >&2; exit 2; }

MODE=""; REPO_OPT=""; SESSION_ID="${CLAUDE_SESSION_ID:-}"; COMMAND_NAME=""; WINDOW=""
while (( $# > 0 )); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --activate|--clear|--status) [[ -z "$MODE" ]] || die "only one mode may be supplied"; MODE="${1#--}" ;;
    --repo|--session|--command|--window-minutes)
      (( $# >= 2 )) || die "$1 requires a value"
      key="$1"; value="$2"; shift
      case "$key" in
        --repo) REPO_OPT="$value" ;;
        --session) SESSION_ID="$value" ;;
        --command) COMMAND_NAME="$value" ;;
        --window-minutes) WINDOW="$value" ;;
      esac ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$MODE" ]] || die "no mode supplied"
[[ -n "$SESSION_ID" ]] || die "--session is required"
[[ -x "$SESSION_STATE_SH" ]] || { echo "execution-pause.sh: session-state.sh unavailable" >&2; exit 5; }

session_state() {
  if [[ -n "$REPO_OPT" ]]; then
    "$SESSION_STATE_SH" --repo "$REPO_OPT" "$@"
  else
    "$SESSION_STATE_SH" "$@"
  fi
}
REPO_KEY="$(session_state --repo-key 2>/dev/null)" || exit 5
SAFE_REPO="${REPO_KEY//[^[:alnum:]_.-]/_}"
SAFE_SESSION="${SESSION_ID//[^[:alnum:]_.-]/_}"
MARKER="$MARKER_DIR/claude-execution-pause-${SAFE_REPO}-${SAFE_SESSION}"
PATH_EXPR=".repos[\"$REPO_KEY\"].execution_pauses[\"$SESSION_ID\"]"

case "$MODE" in
  activate)
    case "$COMMAND_NAME" in pause|suspend) ;; *) die "--activate requires --command pause|suspend" ;; esac
    [[ "$WINDOW" =~ ^[0-9]+$ ]] || die "--activate requires non-negative --window-minutes"
    NOW="$(date -u +%FT%TZ)"
    DEADLINE_EPOCH=$(( $(date -u +%s) + WINDOW * 60 ))
    VALUE="$(jq -nc --arg command "$COMMAND_NAME" --arg session "$SESSION_ID" --arg at "$NOW" \
      --argjson window "$WINDOW" --argjson deadline "$DEADLINE_EPOCH" \
      '{active:true,command:$command,session_id:$session,window_minutes:$window,deadline_epoch:$deadline,at:$at,cleared_at:null}')"
    session_state --raw-path --set "$PATH_EXPR=$VALUE" || exit $?
    mkdir -p "$MARKER_DIR" 2>/dev/null || true
    printf '%s\n' "$VALUE" > "$MARKER" || { echo "execution-pause.sh: could not write marker $MARKER" >&2; exit 5; }
    ;;
  clear)
    NOW="$(date -u +%FT%TZ)"
    session_state --raw-path \
      --set "$PATH_EXPR.active=false" --set "$PATH_EXPR.cleared_at=\"$NOW\"" || exit $?
    rm -f "$MARKER" 2>/dev/null || true
    ;;
  status)
    RC=0
    VALUE="$(session_state --raw-path --get "$PATH_EXPR.active" 2>/dev/null)" || RC=$?
    if [[ "$RC" -eq 0 && "$VALUE" == true ]]; then printf 'active\n'; exit 0; fi
    if [[ "$RC" -eq 0 && ( "$VALUE" == false || "$VALUE" == null ) ]]; then printf 'inactive\n'; exit 0; fi
    if [[ "$RC" -eq 3 && ! -f "$MARKER" ]]; then printf 'inactive\n'; exit 0; fi
    if [[ -f "$MARKER" ]]; then printf 'active\n'; exit 0; fi
    echo "execution-pause.sh: pause state unreadable and no active marker exists" >&2
    exit 4
    ;;
esac
