#!/usr/bin/env bash
# desk-tick.sh — the /desk Monitor loop: ticks the store on a cadence and
# prints one line only when the desk has something to do (issue #1779).
# catalog: utilities — Human-queue desk tick loop (`desk/bin/desk-tick.sh`): the /desk Monitor command; ticks the store and prints a line only when the desk has something to do
#
# USAGE
#   desk-tick.sh --session SESSION --generation GEN [--cadence MIN] [--once]
#   desk-tick.sh --help
#
# ARGUMENTS
#   --session SESSION  the desk's own session id, as register-control stored it
#   --generation GEN   the Monitor generation the skill recorded; every line
#                      carries it so a line from a superseded loop is ignored
#                      (letters, digits, and - _ . : only, <= 80 characters)
#   --cadence MIN      minutes between ticks, 1 to 60 (default 5)
#   --once             one cycle now, no sleep (tests, and a manual tick)
#
# BEHAVIOR
#   Sleep first, then each cycle:
#     1. `control-status --json`. When the registered control session is no
#        longer SESSION (another desk registered, so the last registration
#        wins), print `desk-tick GEN replaced` and exit 0: two desks must
#        never both tick, because each tick consumes the change feed.
#     2. `tick`. It stamps tick_at, which is what keeps the desk live for
#        the capture hook, and prints the items new or changed since the last
#        tick. When any of them is an open Decision, print
#        `desk-tick GEN new D-43 D-44` (ids in tick order: parked, impact,
#        age). Anything else (Reviews, answers, acknowledgements) prints
#        nothing.
#   A failing call prints `desk-tick GEN error <subcommand> exit <code>: <the
#   CLI's one stderr line>` once, when the loop goes from working to failing,
#   and `desk-tick GEN recovered` once when it works again, so an outage is
#   one line, not one per cadence. A quiet tick prints nothing at all.
#
#   The CLI is desk-cli.sh next to this file (human-queue.sh with the store's
#   URL found the way the capture hook finds it).
#
# ENVIRONMENT
#   HUMAN_QUEUE_TICK_SECONDS  seconds between ticks, overriding --cadence
#                             (tests)
#   HUMAN_QUEUE_CLI           passed through to desk-cli.sh (tests)
#
# EXIT CODES
#   0  replaced by another control session, or --once finished
#   4  usage error
#   (the loop itself never ends on a store failure; the Monitor's own expiry
#   or TaskStop ends it)
#
# Bash 3.2 compatible (macOS /bin/bash).
set -u

dt_usage() {
  sed -n '2,/^# Bash 3.2/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

dt_die() {
  printf 'desk-tick: %s\n' "$1" >&2
  exit 4
}

dt_self="${BASH_SOURCE[0]}"
while [ -L "$dt_self" ]; do
  dt_dir=$(cd -P "$(dirname "$dt_self")" && pwd) || exit 1
  dt_self=$(readlink "$dt_self") || exit 1
  case "$dt_self" in
    /*) ;;
    *) dt_self="$dt_dir/$dt_self" ;;
  esac
done
dt_bin=$(cd -P "$(dirname "$dt_self")" && pwd) || exit 1
dt_cli="$dt_bin/desk-cli.sh"

dt_session=""
dt_gen=""
dt_cadence=5
dt_once=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      dt_usage
      exit 0
      ;;
    --session|--generation|--cadence)
      if [ "$#" -lt 2 ]; then dt_die "$1 needs a value"; fi
      case "$1" in
        --session) dt_session="$2" ;;
        --generation) dt_gen="$2" ;;
        *) dt_cadence="$2" ;;
      esac
      shift 2
      continue
      ;;
    --once) dt_once=1 ;;
    *) dt_die "unknown argument (run desk-tick.sh --help)" ;;
  esac
  shift
done
case "$dt_session" in
  *$'\n'*|*$'\r'*) dt_die "--session must be a single line" ;;
  *[![:space:]]*) ;;
  *) dt_die "missing --session" ;;
esac
if [ "${#dt_session}" -gt 200 ]; then dt_die "--session is longer than 200 characters"; fi
case "$dt_gen" in
  '') dt_die "missing --generation" ;;
  *[!A-Za-z0-9_.:-]*) dt_die "--generation may hold only letters, digits, and - _ . :" ;;
esac
if [ "${#dt_gen}" -gt 80 ]; then dt_die "--generation is longer than 80 characters"; fi
case "$dt_cadence" in
  ''|*[!0-9]*) dt_die "--cadence must be a whole number of minutes from 1 to 60" ;;
esac
if [ "${#dt_cadence}" -gt 2 ] || [ "$dt_cadence" -lt 1 ] || [ "$dt_cadence" -gt 60 ]; then
  dt_die "--cadence must be a whole number of minutes from 1 to 60"
fi
dt_secs=$((10#$dt_cadence * 60))
case "${HUMAN_QUEUE_TICK_SECONDS:-}" in
  '') ;;
  *[!0-9]*) dt_die "HUMAN_QUEUE_TICK_SECONDS must be a whole number of seconds" ;;
  *) dt_secs="$HUMAN_QUEUE_TICK_SECONDS" ;;
esac

dt_py=$(command -v python3 2>/dev/null) || dt_py=""
if [ -z "$dt_py" ] && [ -x /usr/bin/python3 ]; then
  dt_py=/usr/bin/python3
fi
if [ -z "$dt_py" ]; then
  printf 'desk-tick: python3 is not installed\n' >&2
  exit 1
fi

dt_err=$(mktemp "${TMPDIR:-/tmp}/desk-tick.XXXXXX") || exit 1
trap 'rm -f "$dt_err"' EXIT

dt_failing=0

# dt_fail SUBCOMMAND RC — one `error` line on the first failure of a streak.
dt_fail() {
  local line
  if [ "$dt_failing" -eq 0 ]; then
    line=$(grep -m1 -v '^[[:space:]]*$' "$dt_err" 2>/dev/null || true)
    printf 'desk-tick %s error %s exit %s%s\n' "$dt_gen" "$1" "$2" "${line:+: $line}"
  fi
  dt_failing=1
}

dt_ok() {
  if [ "$dt_failing" -eq 1 ]; then
    printf 'desk-tick %s recovered\n' "$dt_gen"
  fi
  dt_failing=0
}

# dt_control JSON — the registered control session from control-status --json
# ("" when none is registered); exits 1 when the output is unreadable, which
# is a failure to report, never a reason to stop as if replaced.
dt_control() {
  printf '%s' "$1" | "$dt_py" -I -c '
import json, sys
try:
    data = json.loads(sys.stdin.read().strip().splitlines()[-1])
except (ValueError, IndexError):
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)
s = data.get("session")
sys.stdout.write(s if isinstance(s, str) else "")
'
}

# dt_open_ids JSON — the ids of the open Decisions in a tick's array, in order,
# space-separated; exits 1 when the array is unreadable.
dt_open_ids() {
  printf '%s' "$1" | "$dt_py" -I -c '
import json, re, sys
try:
    items = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(1)
if not isinstance(items, list):
    sys.exit(1)
ids = [i.get("id") for i in items
       if isinstance(i, dict) and i.get("kind") == "decision" and i.get("status") == "open"
       and isinstance(i.get("id"), str) and re.match(r"^D-[1-9][0-9]*$", i["id"])]
sys.stdout.write(" ".join(ids))
'
}

dt_cycle() {
  local out rc control ids
  rc=0
  out=$("$dt_cli" control-status --json 2>"$dt_err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    dt_fail control-status "$rc"
    return 0
  fi
  rc=0
  control=$(dt_control "$out") || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'control-status printed something other than a JSON object\n' >"$dt_err"
    dt_fail control-status 1
    return 0
  fi
  if [ "$control" != "$dt_session" ]; then
    printf 'desk-tick %s replaced\n' "$dt_gen"
    exit 0
  fi
  rc=0
  out=$("$dt_cli" tick 2>"$dt_err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    dt_fail tick "$rc"
    return 0
  fi
  rc=0
  ids=$(dt_open_ids "$out") || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'tick printed something other than a JSON array\n' >"$dt_err"
    dt_fail tick 1
    return 0
  fi
  dt_ok
  if [ -n "$ids" ]; then
    printf 'desk-tick %s new %s\n' "$dt_gen" "$ids"
  fi
}

if [ "$dt_once" -eq 1 ]; then
  dt_cycle
  exit 0
fi
while sleep "$dt_secs"; do
  dt_cycle
done
