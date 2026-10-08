#!/usr/bin/env bash
# desk-policy.sh — the desk's effective policy, from desk/policy.json, as one
# JSON object (issue #1783).
# catalog: utilities — Human-queue desk policy (`desk/bin/desk-policy.sh`): prints desk/policy.json's effective values (tick cadence, interrupt rule, end of day, set size, live-desk bound) as JSON; an invalid file is the defaults with one warning
#
# USAGE
#   desk-policy.sh
#   desk-policy.sh --help
#
# OUTPUT
#   One line of JSON on stdout, every key present:
#     {"tick_cadence_min": 5, "interrupt_rule": "everything",
#      "eod_time": "17:30", "set_size": 4, "live_desk_max_tick_age_min": 15}
#
#   tick_cadence_min            minutes between desk ticks, 1 to 60, and
#                               shorter than live_desk_max_tick_age_min
#   interrupt_rule              everything (every new Decision at the next
#                               tick, in sets) or away (hold everything);
#                               the rule until the operator sets one at the desk
#   eod_time                    HH:MM, 24-hour, America/New_York (the desk's
#                               calendar): when the end-of-day sweep runs (#1784)
#   set_size                    Decisions per menu, 1 to 4 (four questions is
#                               the menu tool's limit)
#   live_desk_max_tick_age_min  how old the desk's last tick may be for the
#                               capture hook to treat the desk as live, 1 to 1440
#
# BEHAVIOR
#   Reads the file through the capture hook's own parser (capture.py's
#   load_policy), so the hook, desk-tick.sh, and the skill read one policy. A
#   missing file is the defaults, silently. A file that cannot be read, is not
#   a JSON object, or holds any invalid value is the defaults, with one
#   warning line on stderr naming the first problem: one bad value never
#   leaves the others half-applied. Unknown keys are ignored.
#
# ENVIRONMENT
#   HUMAN_QUEUE_POLICY  read this file instead of desk/policy.json (tests;
#                       the capture hook and desk-tick.sh honor it too)
#
# EXIT CODES
#   0  printed (including the defaults after a warning)
#   1  python3 is missing or the parser could not load (one line on stderr)
#   4  a usage error
#
# Bash 3.2 compatible (macOS /bin/bash).
set -u

dp_self="${BASH_SOURCE[0]}"
while [ -L "$dp_self" ]; do
  dp_dir=$(cd -P "$(dirname "$dp_self")" && pwd) || exit 1
  dp_self=$(readlink "$dp_self") || exit 1
  case "$dp_self" in
    /*) ;;
    *) dp_self="$dp_dir/$dp_self" ;;
  esac
done
dp_bin=$(cd -P "$(dirname "$dp_self")" && pwd) || exit 1
dp_capture="$(dirname "$dp_bin")/hooks/capture.py"

case "${1:-}" in
  -h|--help)
    sed -n '2,/^# Bash 3.2/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  '') ;;
  *)
    printf 'desk-policy: unknown argument (run desk-policy.sh --help)\n' >&2
    exit 4
    ;;
esac

dp_py=$(command -v python3 2>/dev/null) || dp_py=""
if [ -z "$dp_py" ] && [ -x /usr/bin/python3 ]; then
  dp_py=/usr/bin/python3
fi
if [ -z "$dp_py" ]; then
  printf 'desk-policy: python3 is not installed\n' >&2
  exit 1
fi
if [ ! -f "$dp_capture" ]; then
  printf 'desk-policy: desk/hooks/capture.py is missing\n' >&2
  exit 1
fi

# The parser's warning arrives on stderr prefixed `desk-policy: `; anything
# else there (a traceback) is reduced to one line.
dp_err=$(mktemp "${TMPDIR:-/tmp}/desk-policy.XXXXXX") || exit 1
trap 'rm -f "$dp_err"' EXIT
dp_rc=0
"$dp_py" -I - "$dp_capture" 2>"$dp_err" <<'PY' || dp_rc=$?
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("hq_capture", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
policy, warning = mod.load_policy()
sys.stdout.write(json.dumps(policy) + "\n")
if warning:
    sys.stderr.write("desk-policy: %s\n" % " ".join(warning.split()))
PY
if [ "$dp_rc" -ne 0 ]; then
  printf 'desk-policy: the policy parser failed (python exit %s)\n' "$dp_rc" >&2
  exit 1
fi
grep -m1 '^desk-policy: ' "$dp_err" >&2 || true
exit 0
