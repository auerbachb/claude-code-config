#!/usr/bin/env bash
# background-task-registry.sh — Locked runtime-identity registry for background work.
#
# Tracks current-session Agent, Bash, Monitor, and Workflow tasks by the exact
# runtime ID returned by Claude Code. Entries live under
# .repos["owner/name"].background_tasks in ~/.claude/session-state.json.
#
# USAGE
#   background-task-registry.sh [--repo owner/name] --register --session ID
#       --task-id ID --type agent|bash|monitor|workflow [--name NAME]
#       [--parent-agent ID] [--output-file PATH] [--recovery-path PATH]
#       [--work-item TEXT]
#   background-task-registry.sh [--repo owner/name] --transition --session ID
#       --task-id ID --status running|stopping|stopped|done|failed|stop_failed|rearmed|abandoned
#   background-task-registry.sh [--repo owner/name] --list [--session ID]
#       [--status STATUS] [--live]
#   background-task-registry.sh [--repo owner/name] --count [--session ID]
#       [--status STATUS] [--live]
#
# `--live` includes running, stopping, and stop_failed entries. Stale entries
# remain live (fail closed) and are annotated with `stale: true`; age never
# silently converts a possibly-billable task into a terminal one.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_LIB="$SCRIPT_DIR/state-lock.sh"
STATE_FILE="${CLAUDE_SESSION_STATE_FILE:-$HOME/.claude/session-state.json}"
ORIG_ARGS=("$@")

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }
die_usage() { echo "background-task-registry.sh: $1" >&2; exit 2; }
die_missing() { echo "background-task-registry.sh: $1" >&2; exit 3; }
die_parse() { echo "background-task-registry.sh: $1" >&2; exit 4; }
die_write() { echo "background-task-registry.sh: $1" >&2; exit 5; }

retry_or_fail() {
  local n="${CLAUDE_STATE_RMW_RETRY:-0}" max="${CLAUDE_STATE_RMW_MAX_RETRY:-8}"
  if (( n < max )); then
    export CLAUDE_STATE_RMW_RETRY=$(( n + 1 ))
    sleep "0.0$(( (RANDOM % 8) + 1 ))"
    exec bash "$0" "${ORIG_ARGS[@]}"
  fi
  echo "background-task-registry.sh: lock was broken $max times; giving up" >&2
  exit 6
}

resolve_repo_key() {
  local raw="$1" remote slug
  [[ -n "$raw" ]] || raw="${CLAUDE_SESSION_REPO:-}"
  if [[ -n "$raw" ]]; then
    if [[ "$raw" == "_unknown" ]]; then printf '_unknown'; return; fi
    [[ "$raw" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || \
      die_usage "--repo must look like owner/name (got: $raw)"
    printf '%s' "$raw" | tr '[:upper:]' '[:lower:]'
    return
  fi
  remote="$(git remote get-url origin 2>/dev/null)" || { printf '_unknown'; return; }
  slug="$(printf '%s' "$remote" | sed -e 's|\.git$||' -e 's|.*github\.com[:/]\([^/]*/[^/]*\)$|\1|')"
  [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { printf '_unknown'; return; }
  printf '%s' "$slug" | tr '[:upper:]' '[:lower:]'
}

read_document() {
  if [[ ! -f "$STATE_FILE" ]]; then
    if [[ "$MODE" == list || "$MODE" == count ]]; then
      die_missing "$STATE_FILE is missing; background-task inventory is unavailable"
    fi
    printf '{}'
    return
  fi
  local doc type
  doc="$(<"$STATE_FILE")" || die_write "could not read $STATE_FILE"
  type="$(printf '%s' "$doc" | jq -r 'type' 2>/dev/null)" || \
    die_parse "$STATE_FILE is not valid JSON"
  [[ "$type" == object ]] || die_parse "$STATE_FILE must contain a JSON object"
  printf '%s' "$doc"
}

write_document() {
  local doc="$1" dir tmp
  [[ "$(printf '%s' "$doc" | jq -r 'type' 2>/dev/null)" == object ]] || \
    die_parse "refusing to publish a non-object registry document"
  dir="$(dirname "$STATE_FILE")"
  mkdir -p "$dir" || die_write "could not create $dir"
  tmp="$(mktemp "$dir/.background-tasks.XXXXXX")" || die_write "mktemp failed in $dir"
  printf '%s\n' "$doc" > "$tmp" || { rm -f "$tmp"; die_write "temp write failed"; }
  if ! state_lock_assert_held; then
    rm -f "$tmp"
    state_lock_release
    retry_or_fail
  fi
  mv "$tmp" "$STATE_FILE" || { rm -f "$tmp"; die_write "could not publish $STATE_FILE"; }
}

MODE=""
REPO_OPT=""
SESSION_ID="${CLAUDE_SESSION_ID:-}"
TASK_ID=""
TASK_TYPE=""
TASK_NAME=""
TARGET_STATUS=""
STATUS_FILTER=""
PARENT_AGENT=""
OUTPUT_FILE=""
RECOVERY_PATH=""
WORK_ITEM=""
LIVE_ONLY=false

while (( $# > 0 )); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --register|--transition|--list|--count)
      [[ -z "$MODE" ]] || die_usage "only one mode may be supplied"
      MODE="${1#--}" ;;
    --repo|--session|--task-id|--type|--name|--status|--parent-agent|--output-file|--recovery-path|--work-item)
      (( $# >= 2 )) || die_usage "$1 requires a value"
      key="$1"; value="$2"; shift
      case "$key" in
        --repo) REPO_OPT="$value" ;;
        --session) SESSION_ID="$value" ;;
        --task-id) TASK_ID="$value" ;;
        --type) TASK_TYPE="$value" ;;
        --name) TASK_NAME="$value" ;;
        --status)
          if [[ "$MODE" == list || "$MODE" == count ]]; then STATUS_FILTER="$value"; else TARGET_STATUS="$value"; fi ;;
        --parent-agent) PARENT_AGENT="$value" ;;
        --output-file) OUTPUT_FILE="$value" ;;
        --recovery-path) RECOVERY_PATH="$value" ;;
        --work-item) WORK_ITEM="$value" ;;
      esac ;;
    --live) LIVE_ONLY=true ;;
    *) die_usage "unknown argument: $1" ;;
  esac
  shift
done

[[ -n "$MODE" ]] || die_usage "no mode supplied"
REPO_KEY="$(resolve_repo_key "$REPO_OPT")"

case "$MODE" in
  register)
    [[ -n "$SESSION_ID" ]] || die_usage "--register requires --session"
    [[ -n "$TASK_ID" ]] || die_usage "--register requires --task-id"
    case "$TASK_TYPE" in agent|bash|monitor|workflow) ;; *) die_usage "invalid --type '$TASK_TYPE'" ;; esac
    [[ -n "$TASK_NAME" ]] || TASK_NAME="$TASK_TYPE:$TASK_ID"
    [[ -f "$LOCK_LIB" ]] || die_write "state-lock.sh not found at $LOCK_LIB"
    # shellcheck source=state-lock.sh
    source "$LOCK_LIB"
    state_lock_acquire "$STATE_FILE" || exit $?
    trap 'state_lock_release' EXIT
    DOC="$(read_document)" || exit $?
    NOW="$(date -u +%FT%TZ)"
    NEW_DOC="$(printf '%s' "$DOC" | jq \
      --arg repo "$REPO_KEY" --arg sid "$SESSION_ID" --arg id "$TASK_ID" \
      --arg type "$TASK_TYPE" --arg name "$TASK_NAME" --arg parent "$PARENT_AGENT" \
      --arg output "$OUTPUT_FILE" --arg recovery "$RECOVERY_PATH" \
      --arg work "$WORK_ITEM" --arg now "$NOW" '
        .repos = (.repos // {})
        | .repos[$repo] = (.repos[$repo] // {})
        | (.repos[$repo].background_tasks // []) as $tasks
        | ({task_id:$id, name:$name, type:$type, session_id:$sid,
            repo_key:$repo,
            parent_agent_id:($parent | if length > 0 then . else null end),
            work_item:($work | if length > 0 then . else null end),
            output_file:($output | if length > 0 then . else null end),
            recovery_path:($recovery | if length > 0 then . else null end),
            status:"running", started_at:$now, updated_at:$now}
           | with_entries(select(.value != null))) as $entry
        | .repos[$repo].background_tasks =
            (if any($tasks[]?; .task_id == $id and .session_id == $sid)
             then $tasks | map(if .task_id == $id and .session_id == $sid
                               then . as $current
                                 | ($current + $entry)
                                 | .status = ($current.status // "running")
                                 | .started_at = ($current.started_at // $now)
                               else . end)
             else $tasks + [$entry] end)
        | .last_updated = $now
        | .schema_version = (.schema_version // 2)
      ' 2>/dev/null)" || die_parse "could not register task"
    write_document "$NEW_DOC"
    ;;

  transition)
    [[ -n "$SESSION_ID" ]] || die_usage "--transition requires --session"
    [[ -n "$TASK_ID" ]] || die_usage "--transition requires --task-id"
    case "$TARGET_STATUS" in running|stopping|stopped|done|failed|stop_failed|rearmed|abandoned) ;;
      *) die_usage "invalid transition status '$TARGET_STATUS'" ;;
    esac
    [[ -f "$LOCK_LIB" ]] || die_write "state-lock.sh not found at $LOCK_LIB"
    # shellcheck source=state-lock.sh
    source "$LOCK_LIB"
    state_lock_acquire "$STATE_FILE" || exit $?
    trap 'state_lock_release' EXIT
    DOC="$(read_document)" || exit $?
    FOUND="$(printf '%s' "$DOC" | jq -r --arg r "$REPO_KEY" --arg s "$SESSION_ID" --arg i "$TASK_ID" \
      '[.repos[$r].background_tasks[]? | select(.session_id==$s and .task_id==$i)] | length' 2>/dev/null)" || \
      die_parse "could not inspect registry"
    (( FOUND > 0 )) || die_missing "task '$TASK_ID' not found for session '$SESSION_ID'"
    CURRENT_STATUS="$(printf '%s' "$DOC" | jq -r --arg r "$REPO_KEY" --arg s "$SESSION_ID" --arg i "$TASK_ID" \
      '.repos[$r].background_tasks[]? | select(.session_id==$s and .task_id==$i) | .status' 2>/dev/null)" || \
      die_parse "could not inspect current task status"
    # Terminal outcomes are monotonic. Delayed SubagentStop/TaskStop events
    # are common during wind-down and must not rewrite a newer recovery
    # decision (for example stopped -> done or done -> stopped).
    TRANSITION_ALLOWED=0
    if [[ "$CURRENT_STATUS" == "$TARGET_STATUS" ]]; then
      TRANSITION_ALLOWED=1
    else
      case "$CURRENT_STATUS:$TARGET_STATUS" in
        running:stopping|running:stopped|running:done|running:failed|running:stop_failed|running:abandoned|\
        stopping:stopped|stopping:done|stopping:failed|stopping:stop_failed|stopping:abandoned|\
        stop_failed:stopping|stop_failed:stopped|stop_failed:done|stop_failed:failed|stop_failed:abandoned|\
        stopped:rearmed)
          TRANSITION_ALLOWED=1 ;;
      esac
    fi
    # A stale terminal notification is an idempotent no-op, not a tracking
    # failure: preserve the newer state and let the hook complete cleanly.
    (( TRANSITION_ALLOWED == 1 )) || exit 0
    NOW="$(date -u +%FT%TZ)"
    NEW_DOC="$(printf '%s' "$DOC" | jq --arg r "$REPO_KEY" --arg s "$SESSION_ID" \
      --arg i "$TASK_ID" --arg status "$TARGET_STATUS" --arg now "$NOW" '
        .repos[$r].background_tasks |= map(
          if .session_id==$s and .task_id==$i
          then .status=$status | .updated_at=$now else . end)
        | .last_updated=$now
      ' 2>/dev/null)" || die_parse "could not transition task"
    write_document "$NEW_DOC"
    ;;

  list|count)
    DOC="$(read_document)" || exit $?
    TTL="${CLAUDE_BACKGROUND_TASK_TTL_S:-86400}"
    [[ "$TTL" =~ ^[0-9]+$ ]] || TTL=86400
    NOW_EPOCH="$(date -u +%s)"
    OUT="$(printf '%s' "$DOC" | jq \
      --arg r "$REPO_KEY" --arg sid "$SESSION_ID" --arg status "$STATUS_FILTER" \
      --argjson live "$LIVE_ONLY" --argjson now "$NOW_EPOCH" --argjson ttl "$TTL" '
        [ .repos[$r].background_tasks[]?
          | select($sid == "" or .session_id == $sid)
          | select($status == "" or .status == $status)
          | select(($live | not) or (.status == "running" or .status == "stopping" or .status == "stop_failed"))
          | . + {stale: ((.updated_at // .started_at // "") as $t
              | if $t == "" then true
                else ($t | fromdateiso8601? // null) as $e
                | if $e == null then true else ($now - $e) >= $ttl end end)}
        ]
      ' 2>/dev/null)" || die_parse "could not list background tasks"
    if [[ "$MODE" == count ]]; then jq -r 'length' <<<"$OUT"; else printf '%s\n' "$OUT"; fi
    ;;
esac
