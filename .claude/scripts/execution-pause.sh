#!/usr/bin/env bash
# execution-pause.sh — Session-scoped, repo-scoped background-launch gate.
# catalog: session-state-locking — Arm, inspect, or explicitly clear a repo/session-scoped background-launch gate
#
# USAGE
#   execution-pause.sh [--repo owner/name] --activate --session ID
#       --command end|pause --window-minutes N
#   execution-pause.sh [--repo owner/name] --clear --session ID
#   execution-pause.sh [--repo owner/name] --status --session ID
#   execution-pause.sh --repo owner/name --end-proof --session NATIVE_UUID
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
# for a session that had positively armed the gate. --end-proof returns
# matching positive /end evidence from both sources, without clearing either.

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
    --activate|--clear|--status|--snapshot-legacy|--legacy-resume-scope|--end-proof) [[ -z "$MODE" ]] || die "only one mode may be supplied"; MODE="${1#--}" ;;
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
if [[ "$MODE" == end-proof ]]; then
  [[ -n "$REPO_OPT" && "$REPO_KEY" =~ ^[a-z0-9][a-z0-9-]*/[a-z0-9_.-]+$ &&
     "$SESSION_ID" =~ ^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$ ]] ||
    die "--end-proof requires an explicit repository and native session UUID"
fi
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
# In-flight activation record (issue #2402, CodeRabbit 4636153100): written by
# an activating process before it does anything else, removed by that process
# after its marker and state are final. Clear never touches it, so a clear
# racing an activation cannot hide the activation from the lock-free status.
ACTIVATING_PREFIX="$MARKER_DIR/claude-execution-pause-activating-"
INTENT=""

# Start time of process $1 as `ps` prints it, whitespace squeezed; empty when
# it cannot be read. With the pid it identifies one process across pid reuse.
pid_start_time() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//'; }

# 0 when a live activation for scope hash $1 is in flight. A record counts
# only while it is a regular, non-symlink file of ours naming a running
# process. Its first line is `<pid> <start time>`: when both start times can
# be read, they decide (equal -> held at any age, so an activation stuck
# behind the lock for a long time still holds — CodeAnt 4636571089; unequal ->
# the pid was reused, not held). Only when identity cannot be proven does a
# 15-minute age cutoff bound how long a record can hold. A crashed
# activation never completed, so its leftover record holds nothing.
activation_in_flight() {
  local f pid line recorded current
  for f in "$ACTIVATING_PREFIX$1".*; do
    [[ -f "$f" && ! -L "$f" && -O "$f" ]] || continue
    pid="${f##*.}"
    [[ "$pid" =~ ^[1-9][0-9]{0,9}$ ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    line=""; IFS= read -r line < "$f" 2>/dev/null || [[ -n "$line" ]] || line=""
    recorded=""
    [[ "$line" == "$pid "* ]] && recorded="${line#"$pid "}"
    current="$(pid_start_time "$pid")"
    if [[ -n "$recorded" && -n "$current" ]]; then
      [[ "$recorded" == "$current" ]] && return 0
      continue
    fi
    [[ -n "$(find "$f" -prune -mmin -15 2>/dev/null)" ]] && return 0
  done
  return 1
}
PATH_EXPR="$(pause_path "$SESSION_ID")" || exit 5

read_end_proof() {
  jq -Sce --arg session "$SESSION_ID" '
    select(type == "object" and .active == true and .command == "end"
           and .session_id == $session and .cleared_at == null)
    | select((.at | type) == "string" and (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
             and (.deadline_epoch | type) == "number" and (.window_minutes | type) == "number")
    | {session_id, command, at, deadline_epoch, window_minutes}
  '
}

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

# Token of an already-read native gate record ($2, compact JSON as --get-json
# prints it) for the scope hash $1. Shared by the guarded legacy clear (which
# records the token) and both status paths (which compare against it), so the
# canonicalization can never drift between writer and reader. Returns 7 when
# the gate is active, 4 when it is malformed.
native_token_of() {
  local native_hash="$1" state="$2"
  if jq -e 'type == "object" and .active == true' <<< "$state" >/dev/null; then return 7; fi
  state="$(jq -cS 'if . == null or (type == "object" and .active == false)
                   then . else error("native gate malformed") end' <<< "$state")" || return 4
  printf '%s\0%s' "$native_hash" "$state" | sha256_input
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
  native_token_of "$native_hash" "$state"
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

# ----------------------------------------------------------------------------
# Lock-free status (issue #2402)
#
# `--status` reads the state file ONCE, without the state lock, then checks
# markers. Writers publish the state by atomic rename, so one open of the file
# is one consistent snapshot. Every marker check happens AFTER the snapshot,
# which keeps half-applied transitions conservative:
#   - activation publishes the marker before it even takes the lock, and so
#     before the state: a snapshot taken before the state write still sees
#     the marker afterwards -> active;
#   - an activation also leaves a per-process in-flight record for its whole
#     run that only it removes, checked before the marker: a clear racing
#     the activation can remove the marker but not that record -> active;
#   - clear writes inactive state before removing the marker: `inactive` needs
#     an inactive snapshot AND a missing marker afterwards, i.e. a clear that
#     had already finished removing it.
# The answer is a point-in-time check, not a reservation through the launch —
# exactly what the locked read gave. The locked read is kept behind
# CLAUDE_EXECUTION_PAUSE_STATUS_LOCKED=1 as parity oracle and rollback; only it
# can return exit 6. One intended difference: the unlocked read does not run
# session-state.sh's in-memory flat-.prs migration, so a malformed legacy flat
# container no longer turns status into exit 4.
# ----------------------------------------------------------------------------
STATUS_SNAPSHOT_JQ="$(cat <<'JQ'
  def field(f): try {ok: f} catch {err: true};
  [inputs]
  | if length != 1 or (.[0] | type) != "object"
    then error("state file must contain exactly one top-level JSON object") else .[0] end
  | . as $d
  | {primary: field($d.repos[$repo].execution_pauses[$session].active
                    | if type == "string" then . else tojson end)}
  + if $launch then
      field($d.repos[$repo].legacy_end_resume_scopes[$session]) as $binding
      | {binding: $binding}
      # Legacy-only inputs only when a usable binding exists; the task
      # inventory is reduced to the one boolean the hold needs, so a large
      # inventory is never copied out (errors stay errors: they hold).
      + if ($binding.ok | type) == "object" and ($binding.ok.legacy | type) == "string" then
          {native: field($d.repos[$repo].execution_pauses[$session]),
           rearming: field($d.repos[$repo].background_tasks
             | if . == null then false
               elif type == "array" then any(.[]; .session_id == $binding.ok.legacy and .status == "rearming")
               else error("task inventory malformed") end),
           legacy_active: field($d.repos[$repo].execution_pauses[$binding.ok.legacy].active)}
        else {} end
    else {} end
JQ
)"

# Mirror of legacy_launch_held over the snapshot in $SNAP. 0 = launch held.
# Same hold / no-hold branches; markers are read here, after the snapshot.
snapshot_legacy_held() {
  local binding legacy recorded native_hash state current active legacy_hash
  jq -e '.binding | has("ok")' <<< "$SNAP" >/dev/null 2>&1 || return 1
  binding="$(jq -c '.binding.ok' <<< "$SNAP")" || return 1
  [[ "$binding" != null ]] || return 1
  legacy="$(jq -er '.legacy | select(type == "string" and length > 0)' <<< "$binding" 2>/dev/null)" || return 0
  recorded="$(jq -er '.native_token | select(type == "string" and test("^[a-f0-9]{64}$"))' \
    <<< "$binding" 2>/dev/null)" || return 0
  native_hash="$(scope_hash "$SESSION_ID")" || return 0
  if activation_in_flight "$native_hash" ||
     [[ -e "$MARKER_DIR/claude-execution-pause-v2-$native_hash" ||
        -L "$MARKER_DIR/claude-execution-pause-v2-$native_hash" ]]; then
    return 0
  fi
  jq -e '.native | has("ok")' <<< "$SNAP" >/dev/null 2>&1 || return 0
  state="$(jq -c '.native.ok' <<< "$SNAP")" || return 0
  current="$(native_token_of "$native_hash" "$state" 2>/dev/null)" || return 0
  [[ "$current" == "$recorded" ]] || return 1
  jq -e '.rearming | has("ok")' <<< "$SNAP" >/dev/null 2>&1 || return 0
  active="$(jq -r '.rearming.ok' <<< "$SNAP")" || return 0
  [[ "$active" == true ]] || return 1
  legacy_hash="$(scope_hash "$legacy")" || return 0
  if activation_in_flight "$legacy_hash" ||
     [[ -e "$MARKER_DIR/claude-execution-pause-v2-$legacy_hash" ||
        -L "$MARKER_DIR/claude-execution-pause-v2-$legacy_hash" ]]; then
    return 0
  fi
  jq -e '.legacy_active | has("ok")' <<< "$SNAP" >/dev/null 2>&1 || return 0
  active="$(jq -c '.legacy_active.ok' <<< "$SNAP")" || return 0
  [[ "$active" != false && "$active" != null ]]
}

status_unlocked() {
  local launch=false class=ok value
  if [[ "${CLAUDE_EXECUTION_PAUSE_LAUNCH_CHECK:-}" == 1 &&
        "$SESSION_ID" =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]; then
    launch=true
  fi
  SNAP=""
  if [[ ! -f "$STATE_FILE" ]]; then
    class=missing
  elif ! SNAP="$(jq -cn --arg repo "$REPO_KEY" --arg session "$SESSION_ID" --argjson launch "$launch" \
                 "$STATUS_SNAPSHOT_JQ" "$STATE_FILE" 2>/dev/null)"; then
    # A file that vanished between the test and jq's open reads as missing.
    if [[ -e "$STATE_FILE" ]]; then class=unreadable; else class=missing; fi
  elif ! value="$(jq -er '.primary.ok' <<< "$SNAP" 2>/dev/null)"; then
    class=unreadable
  fi
  # Markers only after the snapshot, in-flight activations before the marker:
  # an activation that finishes between the two checks has already published
  # its marker. A live activation or a surviving marker is authoritative.
  if activation_in_flight "$SCOPE_HASH" || [[ -f "$MARKER" ]]; then printf 'active\n'; return 0; fi
  case "$class" in
    missing) printf 'inactive\n'; return 0 ;;
    unreadable)
      echo "execution-pause.sh: execution-pause state unreadable and no active marker exists" >&2
      return 4 ;;
  esac
  if [[ "$value" == true ]]; then printf 'active\n'; return 0; fi
  if [[ "$value" == false || "$value" == null ]]; then
    if [[ "$launch" == true ]] && snapshot_legacy_held; then
      printf 'active\n'
    else
      printf 'inactive\n'
    fi
    return 0
  fi
  echo "execution-pause.sh: execution-pause state unreadable and no active marker exists" >&2
  return 4
}

if [[ "$MODE" == status && "${CLAUDE_EXECUTION_PAUSE_STATUS_LOCKED:-}" != 1 ]]; then
  status_unlocked
  exit $?
fi

# Activation publishes its marker BEFORE taking the state lock (issue #2402,
# CodeAnt 4630476552). The lock-free `--status` never waits on the lock, so a
# marker published only after acquisition left a window — lock held or still
# being waited for, marker not yet written — where status read `inactive` for
# an activation already under way; the locked read would have waited and said
# `active`. Publishing first makes every status that starts after this point
# see the pause. If the lock is never acquired the marker survives and keeps
# launches blocked until an explicit clear (same fail-closed stance as a
# failed state write below).
publish_marker() {
  local tmp
  mkdir -p "$MARKER_DIR" 2>/dev/null || {
    echo "execution-pause.sh: could not create marker directory $MARKER_DIR" >&2
    return 1
  }
  if [[ "$MARKER_DIR_IS_DEFAULT" == 1 ]]; then
    chmod 700 "$MARKER_DIR" 2>/dev/null || {
      echo "execution-pause.sh: could not secure marker directory $MARKER_DIR" >&2
      return 1
    }
  fi
  tmp="$(mktemp "$MARKER_DIR/.execution-pause.XXXXXX")" || {
    echo "execution-pause.sh: could not create marker temp file in $MARKER_DIR" >&2
    return 1
  }
  printf '%s\n' "$VALUE" > "$tmp" || {
    rm -f "$tmp"
    echo "execution-pause.sh: could not write marker temp file $tmp" >&2
    return 1
  }
  mv "$tmp" "$MARKER" || {
    rm -f "$tmp"
    echo "execution-pause.sh: could not publish marker $MARKER" >&2
    return 1
  }
}

if [[ "$MODE" == activate ]]; then
  # In-flight record first, before the marker and the lock: from here until
  # this process exits, the lock-free status reads this scope as active, even
  # if a concurrent clear removes the pre-lock marker before this process
  # takes the lock and re-publishes it (CodeRabbit 4636153100).
  mkdir -p "$MARKER_DIR" 2>/dev/null || {
    echo "execution-pause.sh: could not create marker directory $MARKER_DIR" >&2
    exit 5
  }
  INTENT="$ACTIVATING_PREFIX$SCOPE_HASH.$$"
  trap '[[ -z "$INTENT" ]] || rm -f -- "$INTENT"' EXIT
  printf '%s %s\n' "$$" "$(pid_start_time "$$")" > "$INTENT" || {
    echo "execution-pause.sh: could not write activation record $INTENT" >&2
    exit 5
  }
  NOW="$(date -u +%FT%TZ)"
  DEADLINE_EPOCH=$(( $(date -u +%s) + WINDOW * 60 ))
  GENERATION="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" || exit 5
  [[ "$GENERATION" =~ ^[0-9a-f]{32}$ ]] || exit 5
  VALUE="$(jq -nc --arg command "$COMMAND_NAME" --arg session "$SESSION_ID" --arg at "$NOW" \
    --argjson window "$WINDOW" --argjson deadline "$DEADLINE_EPOCH" --arg generation "$GENERATION" \
    '{generation:$generation,active:true,command:$command,session_id:$session,window_minutes:$window,deadline_epoch:$deadline,at:$at,cleared_at:null}')" || exit 5
  publish_marker || exit 5
fi

# Marker and session-state are one lifecycle invariant. Hold the canonical
# state lock across activation, clearing, and the legacy proofs so a
# concurrent resume never observes a half-applied transition. The nested
# session-state.sh process inherits this lock and re-enters safely. (Status is
# unlocked by default — see "Lock-free status" above.)
[[ -f "$LOCK_LIB" ]] || { echo "execution-pause.sh: state-lock.sh unavailable" >&2; exit 5; }
# shellcheck source=state-lock.sh
source "$LOCK_LIB"
state_lock_acquire "$STATE_FILE" || exit $?
trap 'state_lock_release; [[ -z "$INTENT" ]] || rm -f -- "$INTENT"' EXIT

case "$MODE" in
  snapshot-legacy)
    legacy_snapshot || exit $?
    ;;
  legacy-resume-scope)
    legacy_resume_scope || exit $?
    ;;
  activate)
    # Re-publish under the lock: a clear that ran between the pre-lock publish
    # and this acquisition removed the marker, and this activation is newer.
    publish_marker || exit 5
    # Publish state only after durable positive marker evidence exists. If the
    # state write fails, the surviving marker deliberately keeps launches
    # blocked until an explicit clear/recovery.
    session_state --raw-path --set "$PATH_EXPR=$VALUE" || exit $?
    state_lock_release
    # Marker and state are final: the in-flight record has done its job.
    rm -f -- "$INTENT"; INTENT=""
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
  end-proof)
    # A positive /end must have completed both writes. A marker alone
    # continues to block launches, but is not permission to resume.
    if [[ -f "$MARKER" && ! -L "$MARKER" && -O "$MARKER" ]] &&
       MARKER_BYTES="$(wc -c < "$MARKER")" && (( MARKER_BYTES <= 4096 )) &&
       MARKER_PROOF="$(read_end_proof < "$MARKER" 2>/dev/null)" &&
       STATE_PROOF="$(session_state --raw-path --get "$PATH_EXPR" 2>/dev/null | read_end_proof 2>/dev/null)" &&
       [[ -n "$MARKER_PROOF" && "$MARKER_PROOF" == "$STATE_PROOF" ]]; then
      printf '%s\n' "$MARKER_PROOF"
      state_lock_release
      exit 0
    fi
    echo "execution-pause.sh: exact /end proof is unavailable" >&2
    exit 4
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
