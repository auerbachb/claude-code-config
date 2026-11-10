#!/usr/bin/env bash
# catalog: backlog-pm — Reserve an attended /subagent launch prompt across threads with the session-state CAS writer
# Usage: prompt-reservation.sh claim|verify|release|snapshot-leave|commit-leave --repo OWNER/REPO --kind leave|overrun
#        [--issue N] [--generation TOKEN]
# claim prints a generation on success. 10 = occupied/lost; 20 = cannot verify;
# 2 = bad arguments. Never time out a prompt whose owner might still be alive.

set -uo pipefail

usage() {
  printf '%s\n' 'Usage: prompt-reservation.sh claim|verify|release|snapshot-leave|commit-leave --repo OWNER/REPO --kind leave|overrun [--issue N] [--generation TOKEN]' \
    'commit-leave also requires --baseline JSON --window JSON --leave JSON'
}

action="${1:-}"
if [[ "$action" == --help ]]; then usage; exit 0; fi
case "$action" in claim|verify|release|snapshot-leave|commit-leave) shift ;; *) usage >&2; exit 2 ;; esac

repo="" kind="" issue="" generation="" baseline="" window="" leave=""
while (( $# > 0 )); do
  (( $# >= 2 )) || { usage >&2; exit 2; }
  case "$1" in
    --repo) repo="$2" ;;
    --kind) kind="$2" ;;
    --issue) issue="$2" ;;
    --generation) generation="$2" ;;
    --baseline) baseline="$2" ;;
    --window) window="$2" ;;
    --leave) leave="$2" ;;
    *) usage >&2; exit 2 ;;
  esac
  shift 2
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { usage >&2; exit 2; }
case "$kind" in
  leave) [[ -z "$issue" ]] || { usage >&2; exit 2; }; key=leave ;;
  overrun) [[ "$issue" =~ ^[1-9][0-9]{0,14}$ ]] || { usage >&2; exit 2; }; key="overrun:$issue" ;;
  *) usage >&2; exit 2 ;;
esac
if [[ "$action" == claim ]]; then
  [[ -z "$generation" ]] || { usage >&2; exit 2; }
else
  [[ "$generation" =~ ^[0-9a-f]{32}$ ]] || { usage >&2; exit 2; }
fi
case "$action" in
  snapshot-leave|commit-leave) [[ "$kind" == leave ]] || { usage >&2; exit 2; } ;;
esac
if [[ "$action" == commit-leave ]]; then
  [[ -n "$baseline" && -n "$window" && -n "$leave" ]] || { usage >&2; exit 2; }
else
  [[ -z "$baseline$window$leave" ]] || { usage >&2; exit 2; }
fi

unavailable() { printf 'prompt-reservation: %s\n' "$1" >&2; exit 20; }
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || unavailable 'cannot resolve helper directory'
state="$script_dir/session-state.sh"
[[ -x "$state" ]] || unavailable 'session-state.sh unavailable'
command -v jq >/dev/null 2>&1 || unavailable 'jq unavailable'
host="$(hostname 2>/dev/null)" || unavailable 'cannot identify local host'
uid="$(id -u 2>/dev/null)" || unavailable 'cannot identify local user'
[[ -n "$host" && "$uid" =~ ^[0-9]{1,10}$ ]] || unavailable 'cannot identify local host and user'

# ps fields: pid uid weekday month day time year state. Require exactly one
# unambiguous row. For a full snapshot a missing PID has a separate result.
process_row() {
  awk -v pid="$1" -v uid="$uid" '
    $1 == pid {
      n++
      if ($2 == uid && NF == 8 &&
          $3 ~ /^[A-Za-z][A-Za-z][A-Za-z]$/ && $4 ~ /^[A-Za-z][A-Za-z][A-Za-z]$/ &&
          $5 ~ /^[0-9][0-9]?$/ && $6 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ &&
          $7 ~ /^[0-9][0-9][0-9][0-9]$/ && $8 ~ /^[A-Za-z]/)
        print $3, $4, $5, $6, $7, $8
      else bad=1
    }
    END { if (n == 0) exit 3; if (n != 1 || bad) exit 1 }'
}

# A Bash command's immediate parent can change between calls. Resolve the
# nearest Claude CLI ancestor, as usage-horizon.sh does; never use the shared
# desktop application or the short-lived command itself as a prompt owner.
session_owner() {
  local pid="${PPID:-}" line parent command row start depth=0
  while [[ "$pid" =~ ^[1-9][0-9]{0,9}$ && "$pid" != 1 && "$depth" -lt 24 ]]; do
    line="$(LC_ALL=C TZ=UTC0 ps -p "$pid" -o ppid= -o comm= 2>/dev/null)" || return 1
    read -r parent command <<<"$line"
    if [[ "${command##*/}" == claude ]]; then
      row="$(LC_ALL=C TZ=UTC0 ps -p "$pid" -o pid= -o uid= -o lstart= -o stat= 2>/dev/null | process_row "$pid")" || return 1
      [[ -n "$row" && "${row##* }" != Z* ]] || return 1
      start="${row% *}"
      jq -cn --arg pid "$pid" --arg uid "$uid" --arg host "$host" --arg start "$start" \
        '{pid:$pid,uid:$uid,host:$host,start:$start}'
      return $?
    fi
    pid="$parent"
    depth=$((depth + 1))
  done
  return 1
}

valid_process_stamp() {
  [[ "$1" =~ ^darwin-bsd:[1-9][0-9]*:[0-9]{6}$ ||
     "$1" =~ ^linux-stat:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[1-9][0-9]*$ ]]
}

read_process_stamp() {
  local value
  value="$(python3 "$script_dir/lib/prompt_process_stamp.py" "$1" 2>/dev/null)" || return 1
  valid_process_stamp "$value" || return 1
  printf '%s\n' "$value"
}

# Only a same-host, same-user snapshot can prove that this owner went away.
# Verify the snapshot includes our own process before interpreting absence.
owner_gone() {
  local pid start snapshot row rc saved_stamp observed_stamp
  jq -e --arg host "$host" --arg uid "$uid" '.owner.host == $host and .owner.uid == $uid' <<<"$current" >/dev/null || return 1
  pid="$(jq -r '.owner.pid' <<<"$current")" || return 1
  start="$(jq -r '.owner.start' <<<"$current")" || return 1
  snapshot="$(LC_ALL=C TZ=UTC0 ps -A -o pid= -o uid= -o lstart= -o stat= 2>/dev/null)" || return 1
  process_row "$$" <<<"$snapshot" >/dev/null || return 1
  rc=0
  row="$(process_row "$pid" <<<"$snapshot")" || rc=$?
  if [[ "$rc" == 3 ]]; then return 0; fi
  [[ "$rc" == 0 ]] || return 1
  if [[ "${row% *}" != "$start" || "${row##* }" == Z* ]]; then return 0; fi
  saved_stamp="$(jq -r '.process_stamp // empty' <<<"$current")" || return 1
  valid_process_stamp "$saved_stamp" || return 1
  observed_stamp="$(read_process_stamp "$pid")" || return 1
  # Compare within the same Darwin second or Linux boot.
  [[ "${saved_stamp%:*}" == "${observed_stamp%:*}" && "$saved_stamp" != "$observed_stamp" ]]
}

owner="$(session_owner)" || unavailable 'cannot verify the Claude session process'
repo_key="$("$state" --repo "$repo" --repo-key 2>/dev/null)" || unavailable 'cannot resolve repo state key'
[[ "$repo_key" =~ ^[a-z0-9_.-]+/[a-z0-9_.-]+$ ]] || unavailable 'cannot resolve repo state key'
repo_path=".repos[\"$repo_key\"]"
path="$repo_path.prompt_reservations[\"$key\"]"

# Read only these scheduling fields, even in repos with large durable state.
# Snapshot eligibility rejects an explicit declaration or Monitor already in
# progress; a spent planning-only record with no Monitor is replaceable.
read_leave_context() {
  context="$("$state" --repo "$repo" --get-json \
    "$repo_path | {window,leave,reservation:.prompt_reservations.leave}" 2>/dev/null)" ||
    unavailable 'cannot read leave scheduling state'
  jq -e --arg token "$generation" --argjson owner "$owner" \
    '.reservation.version == 1 and .reservation.generation == $token and .reservation.owner == $owner' \
    <<<"$context" >/dev/null || exit 10
}
if [[ "$action" == snapshot-leave ]]; then
  read_leave_context
  now="$(date -u +%s)" || unavailable 'cannot read current time'
  jq -e --argjson now "$now" '
    def slot: . == null or type == "object";
    def spent: . == null or (type == "number" and floor == . and . <= $now);
    (.window | slot) and (.leave | slot) and
    (.window.deadline_epoch | spent) and (.leave.no_deadline_until | spent) and
    .leave.winddown_task_id == null and .leave.winddown_generation == null and
    (.leave.active == null or .leave.active == false or
     (.leave.active == true and .leave.winddown_scheduled == false))' \
    <<<"$context" >/dev/null || exit 10
  jq -c '{window,leave}' <<<"$context" || unavailable 'cannot encode leave snapshot'
  exit 0
fi
if [[ "$action" == commit-leave ]]; then
  jq -en --argjson baseline "$baseline" --argjson window "$window" --argjson leave "$leave" \
    '$baseline | type == "object" and has("window") and has("leave") and
      ($window | . == null or type == "object") and ($leave | type == "object")' >/dev/null 2>&1 ||
    unavailable 'leave write arguments are invalid'
  for attempt in 1 2; do
    read_leave_context
    # An unrelated decision for the same spent window need not discard a reply.
    # Its latest value still participates in the locked compare, so a concurrent
    # deadline or Monitor replacement between this read and the write is safe.
    jq -e --argjson before "$baseline" '
      def identity: if type == "object" then del(.launch_decisions) else . end;
      (.window | identity) == ($before.window | identity) and .leave == $before.leave' \
      <<<"$context" >/dev/null || exit 10
    current_window="$(jq -c .window <<<"$context")" || unavailable 'cannot encode window'
    current_leave="$(jq -c .leave <<<"$context")" || unavailable 'cannot encode leave state'
    record="$(jq -c .reservation <<<"$context")" || unavailable 'cannot encode reservation'
    rc=0
    "$state" --repo "$repo" --cas "$path=$record" --expect "$record" \
      --expect-at "$repo_path.window" "$current_window" --expect-at "$repo_path.leave" "$current_leave" \
      --set "$repo_path.window=$window" --set "$repo_path.leave=$leave" >/dev/null || rc=$?
    case "$rc" in
      0) exit 0 ;;
      7) [[ "$attempt" == 1 ]] || exit 10 ;;
      6) [[ "$attempt" == 1 ]] || unavailable 'leave answer write timed out twice' ;;
      *) unavailable 'cannot commit the leave answer' ;;
    esac
  done
fi
rc=0
current="$("$state" --repo "$repo" --get-json "$path" 2>/dev/null)" || rc=$?
if [[ "$rc" == 3 ]]; then current=null
elif [[ "$rc" != 0 ]]; then unavailable 'cannot read reservation state'; fi
jq -e 'type == "null" or
  (type == "object" and .version == 1 and
   (.generation | type == "string" and test("^[0-9a-f]{32}$")) and
   (.owner | type == "object" and
    (.pid | type == "string" and test("^[1-9][0-9]{0,9}$")) and
    (.uid | type == "string" and test("^[0-9]{1,10}$")) and
    (.host | type == "string" and length > 0) and
    (.start | type == "string" and test("^[A-Za-z]{3} [A-Za-z]{3} [0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}$"))))' <<<"$current" >/dev/null 2>&1 ||
  unavailable 'reservation state is invalid'

cas() {
  local code=0
  "$state" --repo "$repo" --cas "$path=$1" --expect "$current" >/dev/null || code=$?
  case "$code" in 0) return 0 ;; 7) exit 10 ;; *) unavailable 'cannot update reservation state' ;; esac
}

if [[ "$action" == claim ]]; then
  if [[ "$current" != null ]] && ! owner_gone; then exit 10; fi
  generation="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" || unavailable 'cannot generate a reservation token'
  [[ "$generation" =~ ^[0-9a-f]{32}$ ]] || unavailable 'cannot generate a reservation token'
  owner_pid="$(jq -er .pid <<<"$owner")" || unavailable 'cannot identify reservation owner'
  process_stamp="$(read_process_stamp "$owner_pid")" || process_stamp=""
  next="$(jq -cn --arg generation "$generation" --argjson owner "$owner" --arg stamp "$process_stamp" \
    '{version:1,generation:$generation,owner:$owner} + (if $stamp == "" then {} else {process_stamp:$stamp} end)')" \
    || unavailable 'cannot encode reservation'
  cas "$next"
  printf '%s\n' "$generation"
  exit 0
fi

jq -e --arg token "$generation" --argjson owner "$owner" \
  '. != null and .generation == $token and .owner == $owner' <<<"$current" >/dev/null || exit 10
if [[ "$action" == release ]]; then cas null; fi
