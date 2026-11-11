#!/usr/bin/env bash
# execution-pause.sh — Session-scoped, repo-scoped background-launch gate.
# catalog: session-state-locking — Arm, inspect, or explicitly clear a repo/session-scoped background-launch gate
#
# USAGE
#   execution-pause.sh [--repo owner/name] --activate --session ID
#       --command end|pause --window-minutes N
#   execution-pause.sh [--repo owner/name] --clear --session ID
#   execution-pause.sh [--repo owner/name] --status --session ID
#   execution-pause.sh --repo owner/name --snapshot-legacy --session ID
#   execution-pause.sh --repo owner/name --clear --session ID
#       --expect-legacy-token SHA256 --native-session UUID
#   execution-pause.sh --repo owner/name --legacy-resume-scope --session ID
#       --native-session UUID
#
# Legacy recovery requires matching active end state and marker. A changed
# token or newly active native gate exits 7. Unreadable evidence exits 4.
#
# `--status` prints active|inactive and exits 0. An on-disk marker mirrors an
# active write so a corrupted/unreadable session-state file fails closed only
# for a session that had positively armed the gate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_STATE_SH="$SCRIPT_DIR/session-state.sh"
LOCK_LIB="$SCRIPT_DIR/state-lock.sh"
# session-state.sh reads this exact file, so the outer marker lock must use it too.
STATE_FILE="$HOME/.claude/session-state.json"
DEFAULT_MARKER_DIR="$HOME/.claude/execution-pause-markers"
MARKER_DIR="${CLAUDE_EXECUTION_PAUSE_MARKER_DIR:-$DEFAULT_MARKER_DIR}"
MARKER_DIR_IS_DEFAULT=0
[[ -n "${CLAUDE_EXECUTION_PAUSE_MARKER_DIR:-}" ]] || MARKER_DIR_IS_DEFAULT=1
umask 077

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "execution-pause.sh: $1" >&2; exit 2; }

MODE=""; REPO_OPT=""; SESSION_ID="${CLAUDE_SESSION_ID:-}"; COMMAND_NAME=""; WINDOW=""
EXPECT_LEGACY_TOKEN=""; NATIVE_SESSION=""
while (( $# > 0 )); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --activate|--clear|--status|--snapshot-legacy|--legacy-resume-scope) [[ -z "$MODE" ]] || die "only one mode may be supplied"; MODE="${1#--}" ;;
    --repo|--session|--command|--window-minutes|--expect-legacy-token|--native-session)
      (( $# >= 2 )) || die "$1 requires a value"
      key="$1"; value="$2"; shift
      case "$key" in
        --repo) REPO_OPT="$value" ;;
        --session) SESSION_ID="$value" ;;
        --command) COMMAND_NAME="$value" ;;
        --window-minutes) WINDOW="$value" ;;
        --expect-legacy-token) [[ -n "$value" ]] || die "empty legacy token"; EXPECT_LEGACY_TOKEN="$value" ;;
        --native-session) [[ -n "$value" ]] || die "empty native session"; NATIVE_SESSION="$value" ;;
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

if [[ "$MODE" == snapshot-legacy || "$MODE" == legacy-resume-scope || -n "$EXPECT_LEGACY_TOKEN$NATIVE_SESSION" ]]; then
  [[ "$REPO_OPT" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "legacy proof requires an explicit repo"
fi
if [[ "$MODE" == legacy-resume-scope || -n "$EXPECT_LEGACY_TOKEN$NATIVE_SESSION" ]]; then
  [[ "$NATIVE_SESSION" =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ &&
     "$NATIVE_SESSION" != "$SESSION_ID" ]] || die "legacy recovery requires a distinct native UUID"
  if [[ "$MODE" == legacy-resume-scope ]]; then
    [[ -z "$EXPECT_LEGACY_TOKEN" ]] || die "legacy resume scope does not take a token"
  else
    [[ "$MODE" == clear && "$EXPECT_LEGACY_TOKEN" =~ ^[0-9a-f]{64}$ ]] ||
      die "guarded clear requires an exact token"
  fi
fi

session_state() {
  if [[ -n "$REPO_OPT" ]]; then
    "$SESSION_STATE_SH" --repo "$REPO_OPT" "$@"
  else
    "$SESSION_STATE_SH" "$@"
  fi
}
REPO_KEY="$(session_state --repo-key 2>/dev/null)" || exit 5
sha256_input() {
  local digest=""
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 | awk '{print $1}')"
  fi
  [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1
  printf '%s' "$digest" | tr '[:upper:]' '[:lower:]'
}
scope_hash() { printf '%s\0%s' "$REPO_KEY" "$1" | sha256_input; }
pause_path() {
  jq -nr --arg repo "$REPO_KEY" --arg session "$1" \
    '".repos[\($repo|tojson)].execution_pauses[\($session|tojson)]"'
}
legacy_launch_scope_path() {
  jq -nr --arg repo "$REPO_KEY" --arg session "$1" \
    '".repos[\($repo|tojson)].legacy_end_resume_scopes[\($session|tojson)]"'
}

SCOPE_HASH="$(scope_hash "$SESSION_ID")" || {
  echo "execution-pause.sh: no working SHA-256 utility for marker identity" >&2
  exit 5
}
MARKER="$MARKER_DIR/claude-execution-pause-v2-$SCOPE_HASH"
PATH_EXPR="$(pause_path "$SESSION_ID")" || exit 5

# Marker and session-state are one lifecycle invariant. Hold the canonical
# state lock across status, activation, and clearing so neither a concurrent
# resume nor a launch-gate read can observe a half-applied transition. The
# nested session-state.sh process inherits this lock and re-enters safely.
[[ -f "$LOCK_LIB" ]] || { echo "execution-pause.sh: state-lock.sh unavailable" >&2; exit 5; }
# shellcheck source=state-lock.sh
source "$LOCK_LIB"
state_lock_acquire "$STATE_FILE" || exit $?
trap 'state_lock_release' EXIT

legacy_snapshot() {
  local state marker normalized_marker token pending
  state="$(session_state --raw-path --get-json "$PATH_EXPR")" || return 4
  [[ -f "$MARKER" && ! -L "$MARKER" ]] || return 4
  marker="$(cat "$MARKER")" || return 4
  normalized_marker="$(jq -cSe . <<< "$marker")" || return 4
  pending="$(jq -c 'if type == "object" and .active == false then .legacy_resume // null else null end' \
    <<< "$state")" || return 4
  state="$(jq -cSe --arg session "$SESSION_ID" '
    select(type == "object" and .command == "end" and .session_id == $session and (.at | type == "string"))
    | if .active == true and .cleared_at == null then .
      elif .active == false and (.legacy_resume | type == "object") then
        del(.legacy_resume) | .active = true | .cleared_at = null
      else empty end
  ' <<< "$state")" || return 4
  [[ "$normalized_marker" == "$state" ]] || return 4
  token="$(printf '%s\0%s\0%s' "$SCOPE_HASH" "$state" "$marker" | sha256_input)" || return 4
  jq -nc --arg token "$token" --argjson state "$state" --argjson pending "$pending" \
    '{token:$token,at:$state.at,pending:$pending}'
}

native_gate_token() {
  local session="$1" native_hash native_path state
  native_hash="$(scope_hash "$session")" || return 4
  native_path="$(pause_path "$session")" || return 4
  if [[ -e "$MARKER_DIR/claude-execution-pause-v2-$native_hash" ||
        -L "$MARKER_DIR/claude-execution-pause-v2-$native_hash" ]]; then
    return 7
  fi
  state="$(session_state --raw-path --get-json "$native_path")" || return 4
  if jq -e 'type == "object" and .active == true' <<< "$state" >/dev/null; then return 7; fi
  state="$(jq -cS 'if . == null or (type == "object" and .active == false)
                   then . else error("native gate malformed") end' <<< "$state")" || return 4
  printf '%s\0%s' "$native_hash" "$state" | sha256_input
}

legacy_resume_scope() {
  local state binding expected current rc
  rc=0
  state="$(session_state --raw-path --get-json "$PATH_EXPR")" || rc=$?
  [[ "$rc" -ne 3 ]] || return 3
  [[ "$rc" -eq 0 ]] || return 4
  binding="$(jq -c --arg native "$NATIVE_SESSION" --arg legacy "$SESSION_ID" '
    if type == "object" and .command == "end" and .active == false and .session_id == $legacy
       and .legacy_resume.native == $native then .legacy_resume else null end
  ' <<< "$state")" || return 4
  [[ "$binding" != null ]] || return 3
  [[ ! -e "$MARKER" && ! -L "$MARKER" ]] || return 4
  expected="$(jq -er '.native_token | select(type == "string" and test("^[a-f0-9]{64}$"))' \
    <<< "$binding")" || return 4
  rc=0
  current="$(native_gate_token "$NATIVE_SESSION")" || rc=$?
  [[ "$rc" -ne 7 ]] || return 3
  [[ "$rc" -eq 0 ]] || return "$rc"
  [[ "$current" == "$expected" ]] || return 3
  printf '%s\n' "$SESSION_ID"
}

legacy_launch_held() {
  local scope binding legacy recorded current tasks_path tasks legacy_hash legacy_path active
  scope="$(legacy_launch_scope_path "$SESSION_ID")" || return 1
  binding="$(session_state --raw-path --get-json "$scope")" || return 1
  [[ "$binding" != null ]] || return 1
  legacy="$(jq -er '.legacy | select(type == "string" and length > 0)' <<< "$binding")" || return 0
  recorded="$(jq -er '.native_token | select(type == "string" and test("^[a-f0-9]{64}$"))' \
    <<< "$binding")" || return 0
  current="$(native_gate_token "$SESSION_ID")" || return 0
  [[ "$current" == "$recorded" ]] || return 1
  tasks_path="$(jq -nr --arg repo "$REPO_KEY" '".repos[\($repo|tojson)].background_tasks"')" || return 0
  tasks="$(session_state --raw-path --get-json "$tasks_path")" || return 0
  active="$(jq -r --arg legacy "$legacy" '
    if . == null then false
    elif type == "array" then any(.[]; .session_id == $legacy and .status == "rearming")
    else error("task inventory malformed") end
  ' <<< "$tasks")" || return 0
  [[ "$active" == true ]] || return 1
  legacy_hash="$(scope_hash "$legacy")" || return 0
  if [[ -e "$MARKER_DIR/claude-execution-pause-v2-$legacy_hash" ||
        -L "$MARKER_DIR/claude-execution-pause-v2-$legacy_hash" ]]; then
    return 0
  fi
  legacy_path="$(pause_path "$legacy")" || return 0
  active="$(session_state --raw-path --get-json "$legacy_path.active")" || return 0
  [[ "$active" != false && "$active" != null ]]
}

case "$MODE" in
  snapshot-legacy)
    legacy_snapshot || exit $?
    ;;
  legacy-resume-scope)
    legacy_resume_scope || exit $?
    ;;
  activate)
    NOW="$(date -u +%FT%TZ)"
    DEADLINE_EPOCH=$(( $(date -u +%s) + WINDOW * 60 ))
    GENERATION="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" || exit 5
    [[ "$GENERATION" =~ ^[0-9a-f]{32}$ ]] || exit 5
    VALUE="$(jq -nc --arg command "$COMMAND_NAME" --arg session "$SESSION_ID" --arg at "$NOW" \
      --argjson window "$WINDOW" --argjson deadline "$DEADLINE_EPOCH" --arg generation "$GENERATION" \
      '{generation:$generation,active:true,command:$command,session_id:$session,window_minutes:$window,deadline_epoch:$deadline,at:$at,cleared_at:null}')" || exit 5
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
    EXTRA_CLEAR_ARGS=()
    if [[ -n "$EXPECT_LEGACY_TOKEN" ]]; then
      CURRENT="$(legacy_snapshot)" || exit $?
      CURRENT_TOKEN="$(jq -er .token <<< "$CURRENT")" || exit 4
      [[ "$CURRENT_TOKEN" == "$EXPECT_LEGACY_TOKEN" ]] || exit 7
      NATIVE_TOKEN="$(native_gate_token "$NATIVE_SESSION")" || exit $?
      BINDING="$(jq -nc --arg native "$NATIVE_SESSION" --arg token "$NATIVE_TOKEN" \
        '{native:$native,native_token:$token}')" || exit 4
      jq -e --argjson binding "$BINDING" '.pending == null or .pending == $binding' \
        <<< "$CURRENT" >/dev/null || exit 7
      LAUNCH_SCOPE="$(legacy_launch_scope_path "$NATIVE_SESSION")" || exit 4
      LAUNCH_BINDING="$(jq -nc --arg legacy "$SESSION_ID" --arg token "$NATIVE_TOKEN" \
        '{legacy:$legacy,native_token:$token}')" || exit 4
      EXTRA_CLEAR_ARGS=(--set "$PATH_EXPR.legacy_resume=$BINDING" --set "$LAUNCH_SCOPE=$LAUNCH_BINDING")
    fi
    NOW="$(date -u +%FT%TZ)"
    session_state --raw-path \
      --set "$PATH_EXPR.active=false" --set "$PATH_EXPR.cleared_at=\"$NOW\"" \
      ${EXTRA_CLEAR_ARGS[@]+"${EXTRA_CLEAR_ARGS[@]}"} || exit $?
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
    if [[ "$RC" -eq 0 && ( "$VALUE" == false || "$VALUE" == null ) ]]; then
      if [[ "${CLAUDE_EXECUTION_PAUSE_LAUNCH_CHECK:-}" == 1 &&
            "$SESSION_ID" =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]] &&
        legacy_launch_held; then
        printf 'active\n'
      else
        printf 'inactive\n'
      fi
      state_lock_release
      exit 0
    fi
    if [[ "$RC" -eq 3 ]]; then printf 'inactive\n'; state_lock_release; exit 0; fi
    echo "execution-pause.sh: execution-pause state unreadable and no active marker exists" >&2
    exit 4
    ;;
esac
