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
#   --cadence MIN      minutes between ticks, 1 to 60 (default: the policy's
#                      tick_cadence_min, 5 unless desk/policy.json sets it), and
#                      shorter than the capture hook's live-desk bound (15
#                      unless desk/policy.json sets live_desk_max_tick_age_min;
#                      read with the hook's own parser): a desk that ticks less
#                      often goes stale between ticks, and worker menus stop
#                      being queued
#   --once             one cycle now, no sleep (tests, and a manual tick)
#
# BEHAVIOR
#   Sleep first, then each cycle:
#     0. The sleep runs in steps of at most 30 seconds, reading
#        desk/policy.json again (same parser) after each, as the capture
#        hook reads it on every call: RULE below follows an edit, and when
#        the live-desk bound has dropped to the interval or below, the loop
#        sleeps 30 seconds less than the bound (at least 1) from then on,
#        cutting short a sleep already under way, so the desk stays live.
#        The cadence itself is fixed at start.
#     1. `control-status --json`. When the registered control session is no
#        longer SESSION (another desk registered, so the last registration
#        wins), print `desk-tick GEN replaced` and exit 0: two desks must
#        never both tick, because each tick consumes the change feed.
#     2. `tick --session SESSION --interrupts RULE` (RULE: the policy's
#        interrupt_rule, issue #1783). It stamps tick_at, which is what keeps
#        the desk live for the capture hook, and prints the items new or
#        changed since the last tick. While the operator's interrupt rule
#        holds items (`away`, or `focus` until a time not yet reached), it
#        prints [] and leaves the watermark where it is, so the first tick
#        after the hold reports everything that arrived during it. When any
#        of them is an open Decision, print
#        `desk-tick GEN new D-43 D-44` (ids in tick order: parked, impact,
#        age). Anything else (Reviews, answers, acknowledgements) prints
#        nothing. Step 1 alone cannot keep two desks apart: a registration
#        can land between the two calls. `--session` repeats the check
#        inside the tick's own transaction, under register-control's lock,
#        and refuses (exit 4, nothing consumed) when SESSION is no longer the
#        control session; the loop then confirms with `control-status` and
#        prints `replaced` as in step 1.
#     3. `wake-due --json` (issue #1781): the answers whose last wake-up
#        failed and that have a retry left. When there are any, print
#        `desk-tick GEN retry D-43 D-44` (oldest failure first) after any
#        `new` line; the desk wakes each one again and records the result,
#        and the last failed retry parks the answer. One retry per answer
#        per tick: the desk records every attempt, so the next tick sees it.
#        When this call fails after the tick succeeded, the `new` line is
#        still printed (that tick already moved the watermark) after the
#        error line.
#   A failing call prints `desk-tick GEN error <subcommand> exit <code>: <the
#   CLI's one stderr line>` once, when the loop goes from working to failing,
#   and `desk-tick GEN recovered` once when it works again, so an outage is
#   one line, not one per cadence. A quiet tick prints nothing at all.
#
#   The CLI is desk-cli.sh next to this file (human-queue.sh with the store's
#   URL found the way the capture hook finds it).
#
# ENVIRONMENT
#   HUMAN_QUEUE_TICK_SECONDS  seconds between ticks, 1 to 3600 and shorter
#                             than the live-desk bound, overriding --cadence
#                             (tests); 0 is refused (exit 4), never a loop that
#                             calls the store without a pause
#   HUMAN_QUEUE_POLICY        the policy file, as the capture hook reads it
#                             (an invalid file is the defaults: desk-policy.sh
#                             prints its warning, this loop does not)
#   HUMAN_QUEUE_CLI           passed through to desk-cli.sh (tests)
#
# EXIT CODES
#   0  replaced by another control session, or --once finished
#   4  usage error, including a cadence at or past the live-desk bound
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
dt_capture="$(dirname "$dt_bin")/hooks/capture.py"

dt_session=""
dt_gen=""
dt_cadence=""
dt_cadence_given=0
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
        *)
          dt_cadence="$2"
          dt_cadence_given=1
          ;;
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
if [ "$dt_cadence_given" -eq 1 ]; then
  case "$dt_cadence" in
    ''|*[!0-9]*) dt_die "--cadence must be a whole number of minutes from 1 to 60" ;;
  esac
  if [ "${#dt_cadence}" -gt 2 ] || [ "$dt_cadence" -lt 1 ] || [ "$dt_cadence" -gt 60 ]; then
    dt_die "--cadence must be a whole number of minutes from 1 to 60"
  fi
fi
# At least one second: 0 would make the persistent loop call the store
# back-to-back with no pause at all.
dt_tick_secs=""
case "${HUMAN_QUEUE_TICK_SECONDS:-}" in
  '') ;;
  *[!0-9]*) dt_die "HUMAN_QUEUE_TICK_SECONDS must be a whole number of seconds from 1 to 3600" ;;
  *)
    if [ "${#HUMAN_QUEUE_TICK_SECONDS}" -gt 4 ] || [ "$((10#$HUMAN_QUEUE_TICK_SECONDS))" -lt 1 ] \
      || [ "$((10#$HUMAN_QUEUE_TICK_SECONDS))" -gt 3600 ]; then
      dt_die "HUMAN_QUEUE_TICK_SECONDS must be a whole number of seconds from 1 to 3600"
    fi
    dt_tick_secs="$((10#$HUMAN_QUEUE_TICK_SECONDS))"
    ;;
esac

dt_py=$(command -v python3 2>/dev/null) || dt_py=""
if [ -z "$dt_py" ] && [ -x /usr/bin/python3 ]; then
  dt_py=/usr/bin/python3
fi
if [ -z "$dt_py" ]; then
  printf 'desk-tick: python3 is not installed\n' >&2
  exit 1
fi

# dt_read_policy — the policy, from the capture hook's own parser (one
# parser, not two), into dt_live (the live-desk bound), dt_policy_cadence
# (the default cadence), and dt_rule (the interrupt rule that holds until the
# operator sets one at the desk). An unreadable or missing hook leaves the
# documented defaults; an invalid policy file is the defaults too
# (desk-policy.sh is what warns about it). Read at start and again before
# every cycle, so an edit reaches a running loop at its next tick, as it
# reaches the capture hook at its next call.
dt_read_policy() {
  local policy
  policy=$("$dt_py" -I - "$dt_capture" 2>/dev/null <<'POLICY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("hq_capture", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
policy, _ = mod.load_policy()
sys.stdout.write("%s %s %s" % (policy[mod.POLICY_KEY], policy["tick_cadence_min"],
                               policy["interrupt_rule"]))
POLICY
) || policy=""
  dt_live="" dt_policy_cadence="" dt_rule=""
  read -r dt_live dt_policy_cadence dt_rule <<EOF
$policy
EOF
  case "$dt_live" in
    ''|*[!0-9]*) dt_live=15 ;;
  esac
  case "$dt_policy_cadence" in
    ''|*[!0-9]*) dt_policy_cadence=5 ;;
  esac
  case "$dt_rule" in
    everything|away) ;;
    *) dt_rule=everything ;;
  esac
}

# dt_interval — the seconds to sleep before the next cycle: dt_secs, or,
# when the live-desk bound has since dropped to it or below (the policy was
# edited while the loop runs), 30 seconds less than the bound (at least 1),
# so the desk stays live for the capture hook.
dt_interval() {
  local bound=$((10#$dt_live * 60))
  if [ "$dt_secs" -lt "$bound" ]; then
    printf '%s' "$dt_secs"
  elif [ "$bound" -gt 30 ]; then
    printf '%s' "$((bound - 30))"
  else
    printf '1'
  fi
}

dt_read_policy
if [ "$dt_cadence_given" -eq 0 ]; then
  dt_cadence="$dt_policy_cadence"
fi
dt_secs=$((10#$dt_cadence * 60))
if [ -n "$dt_tick_secs" ]; then
  dt_secs="$dt_tick_secs"
fi
if [ "$((10#$dt_cadence))" -ge "$dt_live" ]; then
  dt_die "--cadence must be shorter than the live-desk bound ($dt_live min, desk/policy.json live_desk_max_tick_age_min), or the desk goes stale between ticks"
fi
# The interval actually slept: the cadence, or HUMAN_QUEUE_TICK_SECONDS when
# set. The same bound holds for it, so an override cannot leave the desk stale.
if [ "$dt_secs" -ge "$((dt_live * 60))" ]; then
  dt_die "HUMAN_QUEUE_TICK_SECONDS ($dt_secs s) must be shorter than the live-desk bound ($dt_live min), or the desk goes stale between ticks"
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

# dt_due_ids JSON — the ids in wake-due's array, in order, space-separated;
# exits 1 when the array is unreadable.
dt_due_ids() {
  printf '%s' "$1" | "$dt_py" -I -c '
import json, re, sys
try:
    items = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(1)
if not isinstance(items, list):
    sys.exit(1)
ids = [i.get("id") for i in items
       if isinstance(i, dict) and isinstance(i.get("id"), str)
       and re.match(r"^D-[1-9][0-9]*$", i["id"])]
sys.stdout.write(" ".join(ids))
'
}

# dt_new IDS — the `new` line, when there is anything new.
dt_new() {
  if [ -n "$1" ]; then
    printf 'desk-tick %s new %s\n' "$dt_gen" "$1"
  fi
}

dt_cycle() {
  local out rc control ids due
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
  out=$("$dt_cli" tick --session "$dt_session" --interrupts "$dt_rule" 2>"$dt_err") || rc=$?
  if [ "$rc" -eq 4 ]; then
    # Refused: most likely another desk registered after step 1. Confirm
    # before stopping, so any other exit-4 cause stays an error line.
    rc=0
    out=$("$dt_cli" control-status --json 2>/dev/null) || rc=$?
    if [ "$rc" -eq 0 ]; then
      control=$(dt_control "$out") || control="$dt_session"
      if [ "$control" != "$dt_session" ]; then
        printf 'desk-tick %s replaced\n' "$dt_gen"
        exit 0
      fi
    fi
    rc=4
  fi
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
  rc=0
  out=$("$dt_cli" wake-due --json 2>"$dt_err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    dt_fail wake-due "$rc"
    dt_new "$ids"
    return 0
  fi
  rc=0
  due=$(dt_due_ids "$out") || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'wake-due printed something other than a JSON array\n' >"$dt_err"
    dt_fail wake-due 1
    dt_new "$ids"
    return 0
  fi
  dt_ok
  dt_new "$ids"
  if [ -n "$due" ]; then
    printf 'desk-tick %s retry %s\n' "$dt_gen" "$due"
  fi
}

if [ "$dt_once" -eq 1 ]; then
  dt_cycle
  exit 0
fi
# dt_wait — sleep until the next tick is due, in steps of at most 30 seconds,
# reading the policy again after each step, so a live bound lowered while the
# loop sleeps shortens this very sleep (dt_interval) instead of the next one:
# the desk ticks within 30 seconds of the edit or by the new interval,
# whichever is later, and stays live. Fails when `sleep` does (the loop ends).
dt_wait() {
  local slept=0 step interval
  while :; do
    interval=$(dt_interval)
    if [ "$slept" -ge "$interval" ]; then
      return 0
    fi
    step=$((interval - slept))
    if [ "$step" -gt 30 ]; then
      step=30
    fi
    sleep "$step" || return 1
    slept=$((slept + step))
    dt_read_policy
  done
}

while dt_wait; do
  dt_cycle
done
