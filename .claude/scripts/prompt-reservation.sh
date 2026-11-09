#!/usr/bin/env bash
# catalog: backlog-pm — Reserve an attended /subagent launch prompt across threads with the session-state CAS writer
# Usage: prompt-reservation.sh claim|verify|release --repo OWNER/REPO --kind leave|overrun
#        [--issue N] [--generation TOKEN]
# claim prints a generation on success. 10 = occupied/lost; 20 = cannot verify;
# 2 = bad arguments. Never time out a prompt whose owner might still be alive.

set -uo pipefail

usage() {
  printf '%s\n' 'Usage: prompt-reservation.sh claim|verify|release --repo OWNER/REPO --kind leave|overrun [--issue N] [--generation TOKEN]'
}

action="${1:-}"
if [[ "$action" == --help ]]; then usage; exit 0; fi
case "$action" in claim|verify|release) shift ;; *) usage >&2; exit 2 ;; esac

repo="" kind="" issue="" generation=""
while (( $# > 0 )); do
  (( $# >= 2 )) || { usage >&2; exit 2; }
  case "$1" in
    --repo) repo="$2" ;;
    --kind) kind="$2" ;;
    --issue) issue="$2" ;;
    --generation) generation="$2" ;;
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

# Only a same-host, same-user snapshot can prove that this owner went away.
# Verify the snapshot includes our own process before interpreting absence.
owner_gone() {
  local pid start snapshot row rc
  jq -e --arg host "$host" --arg uid "$uid" '.owner.host == $host and .owner.uid == $uid' <<<"$current" >/dev/null || return 1
  pid="$(jq -r '.owner.pid' <<<"$current")" || return 1
  start="$(jq -r '.owner.start' <<<"$current")" || return 1
  snapshot="$(LC_ALL=C TZ=UTC0 ps -A -o pid= -o uid= -o lstart= -o stat= 2>/dev/null)" || return 1
  process_row "$$" <<<"$snapshot" >/dev/null || return 1
  rc=0
  row="$(process_row "$pid" <<<"$snapshot")" || rc=$?
  if [[ "$rc" == 3 ]]; then return 0; fi
  [[ "$rc" == 0 && ( "${row% *}" != "$start" || "${row##* }" == Z* ) ]]
}

owner="$(session_owner)" || unavailable 'cannot verify the Claude session process'
repo_key="$("$state" --repo "$repo" --repo-key 2>/dev/null)" || unavailable 'cannot resolve repo state key'
[[ "$repo_key" =~ ^[a-z0-9_.-]+/[a-z0-9_.-]+$ ]] || unavailable 'cannot resolve repo state key'
path=".repos[\"$repo_key\"].prompt_reservations[\"$key\"]"
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
  next="$(jq -cn --arg generation "$generation" --argjson owner "$owner" \
    '{version:1,generation:$generation,owner:$owner}')" || unavailable 'cannot encode reservation'
  cas "$next"
  printf '%s\n' "$generation"
  exit 0
fi

jq -e --arg token "$generation" --argjson owner "$owner" \
  '. != null and .generation == $token and .owner == $owner' <<<"$current" >/dev/null || exit 10
if [[ "$action" == release ]]; then cas null; fi
