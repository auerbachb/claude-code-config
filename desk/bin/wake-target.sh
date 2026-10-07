#!/usr/bin/env bash
# wake-target.sh — where /desk sends the wake-up for an answered Decision: the
# messaging address of the session that asked it, if that session is running
# (issue #1779).
# catalog: utilities — Human-queue wake-up address (`desk/bin/wake-target.sh`): maps a Decision's return address to the running session's messaging address; read-only
#
# USAGE
#   wake-target.sh SESSION [--json]
#   wake-target.sh --help
#
# ARGUMENTS
#   SESSION  a Decision's return address (items.session_id): the Claude Code
#            session id the capture hook recorded, or a desktop-app session
#            id (local_...), which is already an address and is printed as is
#   --json   print {"session", "address", "via", "name", "pid"} instead
#
# BEHAVIOR
#   Claude Code keeps one registry file per running session,
#   ~/.claude/sessions/<pid>.json, holding its sessionId, the desktop app's
#   hostSessionId (local_...) when the app started it, and its name. This
#   reads only those <pid>.json files (never the <pid>.*.key files beside
#   them), finds the one whose sessionId is SESSION and whose pid is still
#   running, and prints its hostSessionId, or its name when it has none (a
#   terminal session). `via` says which: host or name. Both are what
#   SendMessage takes as `to`. Several matches (a session resumed in a new
#   process): the most recently updated running one. Reads nothing else and
#   writes nothing.
#
# ENVIRONMENT
#   HUMAN_QUEUE_SESSIONS_DIR  the registry directory (default
#                             ${CLAUDE_CONFIG_DIR:-~/.claude}/sessions; tests)
#
# OUTPUT
#   The address on one line, or one JSON object with --json. Nothing on
#   stderr on success.
#
# EXIT CODES
#   0  found
#   1  unexpected failure: python3 is missing, the registry directory
#      cannot be listed, or no readable registry file has that id while at
#      least one <pid>.json could not be read or parsed (the session may be
#      that one, so "nobody is running" would be a guess)
#   3  no running session has that id (the session ended, or it never
#      registered): there is nobody to wake; the answer waits in the store
#   5  a session with that id is running, but has no messaging address (no
#      local_ hostSessionId and no name): it is alive, and reads its answer
#      from the store when it next checks; it cannot be messaged
#   4  usage error: a missing, blank, multi-line, or over-long session id, or
#      an unknown argument
#
# Bash 3.2 compatible (macOS /bin/bash).
set -u

wt_usage() {
  sed -n '2,/^# Bash 3.2/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

wt_die() {
  printf 'wake-target: %s\n' "$2" >&2
  exit "$1"
}

wt_session=""
wt_have=0
wt_json=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      wt_usage
      exit 0
      ;;
    --json) wt_json=1 ;;
    -*) wt_die 4 "unknown option (run wake-target.sh --help)" ;;
    *)
      if [ "$wt_have" -eq 1 ]; then wt_die 4 "takes one session id"; fi
      wt_have=1
      wt_session="$1"
      ;;
  esac
  shift
done
if [ "$wt_have" -eq 0 ]; then
  wt_die 4 "missing session id (run wake-target.sh --help)"
fi
case "$wt_session" in
  *$'\n'*|*$'\r'*) wt_die 4 "the session id must be a single line" ;;
esac
case "$wt_session" in
  *[![:space:]]*) ;;
  *) wt_die 4 "the session id is empty" ;;
esac
if [ "${#wt_session}" -gt 200 ]; then
  wt_die 4 "the session id is longer than 200 characters"
fi

wt_dir="${HUMAN_QUEUE_SESSIONS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions}"

wt_py=$(command -v python3 2>/dev/null) || wt_py=""
if [ -z "$wt_py" ] && [ -x /usr/bin/python3 ]; then
  wt_py=/usr/bin/python3
fi
if [ -z "$wt_py" ]; then
  wt_die 1 "python3 is not installed"
fi

# The scan prints the answer and exits 0, or exits 3 (nobody running) or 1
# with one reason line. Session ids and names are data: printed, never run.
"$wt_py" -I - "$wt_dir" "$wt_session" "$wt_json" <<'PY'
import json
import os
import re
import sys

directory, session, as_json = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
PID_FILE = re.compile(r"^[0-9]+\.json$")


def emit(address, via, name, pid):
    if as_json:
        sys.stdout.write(json.dumps({"session": session, "address": address, "via": via,
                                     "name": name, "pid": pid}) + "\n")
    else:
        sys.stdout.write(address + "\n")
    sys.exit(0)


def running(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


if session.startswith("local_"):
    emit(session, "host", None, None)

# Only a registry that provably does not exist means "nobody is running".
# os.path.isdir() would also say False when the path cannot be examined (a
# parent we may not search), turning "cannot tell" into a confident exit 3.
try:
    names = sorted(os.listdir(directory))
except FileNotFoundError:
    # The registry, or a directory above it, does not exist: nobody registered.
    sys.stderr.write("wake-target: no running session has that id (no session registry)\n")
    sys.exit(3)
except OSError as exc:
    # Permission denied on it or a parent, not a directory, ...: cannot tell.
    sys.stderr.write("wake-target: the session registry cannot be listed (%s)\n"
                     % (exc.strerror or "unreadable"))
    sys.exit(1)

best = None
unreadable = 0
for base in names:
    if not PID_FILE.match(base):
        continue
    path = os.path.join(directory, base)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        # Another session's file being rewritten, or one we may not read.
        # Skipped, but counted: if nothing matches, it may have been ours.
        unreadable += 1
        continue
    if not isinstance(data, dict) or data.get("sessionId") != session:
        continue
    pid = data.get("pid")
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0 or not running(pid):
        continue
    updated = data.get("updatedAt")
    if isinstance(updated, bool) or not isinstance(updated, (int, float)):
        updated = 0
    if best is None or updated > best[0]:
        best = (updated, data, pid)

if best is None:
    if unreadable:
        sys.stderr.write("wake-target: no readable registry file has that id, and %d could not "
                         "be read or parsed\n" % unreadable)
        sys.exit(1)
    sys.stderr.write("wake-target: no running session has that id\n")
    sys.exit(3)

_, data, pid = best
host = data.get("hostSessionId")
name = data.get("name")
name = name if isinstance(name, str) and name.strip() else None
if isinstance(host, str) and host.startswith("local_"):
    emit(host, "host", name, pid)
if name and "\n" not in name and "\r" not in name:
    emit(name, "name", name, pid)
sys.stderr.write("wake-target: the session is running but has no messaging address\n")
sys.exit(5)
PY
