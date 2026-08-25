#!/usr/bin/env bash
# execution-pause.sh — Session-scoped, repo-scoped background-launch gate.
#
# USAGE
#   execution-pause.sh [--repo owner/name] --activate --session ID
#       --command end|pause --window-minutes N
#   execution-pause.sh [--repo owner/name] --clear --session ID
#   execution-pause.sh [--repo owner/name] --status --session ID
#
# `--status` prints active|inactive and exits 0. An on-disk marker mirrors an
# active write so a corrupted/unreadable session-state file fails closed only
# for a session that had positively armed the gate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_STATE_SH="$SCRIPT_DIR/session-state.sh"
LOCK_LIB="$SCRIPT_DIR/state-lock.sh"
STATE_FILE="${CLAUDE_SESSION_STATE_FILE:-$HOME/.claude/session-state.json}"
DEFAULT_MARKER_DIR="$HOME/.claude/execution-pause-markers"
MARKER_DIR="${CLAUDE_EXECUTION_PAUSE_MARKER_DIR:-$DEFAULT_MARKER_DIR}"
MARKER_DIR_IS_DEFAULT=0
[[ -n "${CLAUDE_EXECUTION_PAUSE_MARKER_DIR:-}" ]] || MARKER_DIR_IS_DEFAULT=1
umask 077

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
if [[ "$MODE" == activate ]]; then
  case "$COMMAND_NAME" in end|pause) ;; *) die "--activate requires --command end|pause" ;; esac
  [[ "$WINDOW" =~ ^[0-9]+$ ]] || die "--activate requires non-negative --window-minutes"
fi

session_state() {
  if [[ -n "$REPO_OPT" ]]; then
    "$SESSION_STATE_SH" --repo "$REPO_OPT" "$@"
  else
    "$SESSION_STATE_SH" "$@"
  fi
}
REPO_KEY="$(session_state --repo-key 2>/dev/null)" || exit 5
scope_hash() {
  local digest=""
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s\0%s' "$REPO_KEY" "$SESSION_ID" | sha256sum | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s\0%s' "$REPO_KEY" "$SESSION_ID" | shasum -a 256 | awk '{print $1}')"
  fi
  [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1
  printf '%s' "$digest" | tr '[:upper:]' '[:lower:]'
}
SCOPE_HASH="$(scope_hash)" || {
  echo "execution-pause.sh: no working SHA-256 utility for marker identity" >&2
  exit 5
}
MARKER="$MARKER_DIR/claude-execution-pause-v2-$SCOPE_HASH"
PATH_EXPR=".repos[\"$REPO_KEY\"].execution_pauses[\"$SESSION_ID\"]"

# Marker and session-state are one lifecycle invariant. Hold the canonical
# state lock across status, activation, and clearing so neither a concurrent
# resume nor a launch-gate read can observe a half-applied transition. The
# nested session-state.sh process inherits this lock and re-enters safely.
[[ -f "$LOCK_LIB" ]] || { echo "execution-pause.sh: state-lock.sh unavailable" >&2; exit 5; }
# shellcheck source=state-lock.sh
source "$LOCK_LIB"
state_lock_acquire "$STATE_FILE" || exit $?
trap 'state_lock_release' EXIT

case "$MODE" in
  activate)
    NOW="$(date -u +%FT%TZ)"
    DEADLINE_EPOCH=$(( $(date -u +%s) + WINDOW * 60 ))
    VALUE="$(jq -nc --arg command "$COMMAND_NAME" --arg session "$SESSION_ID" --arg at "$NOW" \
      --argjson window "$WINDOW" --argjson deadline "$DEADLINE_EPOCH" \
      '{active:true,command:$command,session_id:$session,window_minutes:$window,deadline_epoch:$deadline,at:$at,cleared_at:null}')"
    mkdir -p "$MARKER_DIR" 2>/dev/null || {
      echo "execution-pause.sh: could not create marker directory $MARKER_DIR" >&2
      exit 5
    }
    if [[ "$MARKER_DIR_IS_DEFAULT" == 1 ]]; then
      chmod 700 "$MARKER_DIR" 2>/dev/null || {
        echo "execution-pause.sh: could not secure marker directory $MARKER_DIR" >&2
        exit 5
      }
    fi
    MARKER_TMP="$(mktemp "$MARKER_DIR/.execution-pause.XXXXXX")" || {
      echo "execution-pause.sh: could not create marker temp file in $MARKER_DIR" >&2
      exit 5
    }
    printf '%s\n' "$VALUE" > "$MARKER_TMP" || {
      rm -f "$MARKER_TMP"
      echo "execution-pause.sh: could not write marker temp file $MARKER_TMP" >&2
      exit 5
    }
    mv "$MARKER_TMP" "$MARKER" || {
      rm -f "$MARKER_TMP"
      echo "execution-pause.sh: could not publish marker $MARKER" >&2
      exit 5
    }
    # Publish state only after durable positive marker evidence exists. If the
    # state write fails, the surviving marker deliberately keeps launches
    # blocked until an explicit clear/recovery.
    session_state --raw-path --set "$PATH_EXPR=$VALUE" || exit $?
    state_lock_release
    ;;
  clear)
    NOW="$(date -u +%FT%TZ)"
    session_state --raw-path \
      --set "$PATH_EXPR.active=false" --set "$PATH_EXPR.cleared_at=\"$NOW\"" || exit $?
    rm -f "$MARKER" 2>/dev/null || {
      echo "execution-pause.sh: could not remove marker $MARKER" >&2
      exit 5
    }
    state_lock_release
    ;;
  status)
    RC=0
    VALUE="$(session_state --raw-path --get "$PATH_EXPR.active" 2>/dev/null)" || RC=$?
    # A surviving marker is authoritative. In particular, clear writes
    # active=false before removing the marker; if removal fails, shutdown is
    # incomplete and launches must stay blocked until a successful retry.
    if [[ -f "$MARKER" ]]; then printf 'active\n'; state_lock_release; exit 0; fi
    if [[ "$RC" -eq 0 && "$VALUE" == true ]]; then printf 'active\n'; state_lock_release; exit 0; fi
    if [[ "$RC" -eq 0 && ( "$VALUE" == false || "$VALUE" == null ) ]]; then printf 'inactive\n'; state_lock_release; exit 0; fi
    if [[ "$RC" -eq 3 ]]; then printf 'inactive\n'; state_lock_release; exit 0; fi
    echo "execution-pause.sh: execution-pause state unreadable and no active marker exists" >&2
    exit 4
    ;;
esac
