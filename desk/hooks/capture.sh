#!/usr/bin/env bash
# desk/hooks/capture.sh — the capture hook (issue #1755): a PreToolUse hook on
# AskUserQuestion that sends a thread's questions to the human queue instead
# of rendering them in the thread, while a live desk exists.
#
# Registered as .claude/hooks/human-queue-capture.sh, a symlink to this file
# (global-settings.json, matcher AskUserQuestion). The behavior lives in
# capture.py next to this file; desk/README.md ("Capture hook") is the
# contract. In short:
#   - no live desk (no control session registered, or its last tick is older
#     than the bound): the menu renders as usual and nothing is queued;
#   - live desk: every question becomes a Decision (human-queue.sh add). The
#     desk's own session still sees its menu (and a question in the desk's
#     set format, `1. [D-43] ...`, is an item shown again, so nothing is
#     added); any other session gets the call denied with a reason that tells
#     it to print `question D-<n> sent to human queue` and carry on.
#
# This launcher only finds its own location (through symlinks) and runs
# capture.py with the hook input on stdin. It never blocks a thread: when
# python3 or capture.py is missing, or capture.py fails to start, it allows
# the menu and prints one warning line on stderr. Always exits 0.
#
# Bash 3.2 compatible (macOS /bin/bash).
set -u

hqc_fail_open() {
  printf 'human-queue-capture: %s; the menu renders in this thread\n' "$1" >&2
  exit 0
}

# Resolve this file's real directory through any chain of symlinks. Portable:
# `readlink -f` is missing from older macOS.
hqc_self="${BASH_SOURCE[0]}"
while [ -L "$hqc_self" ]; do
  hqc_dir=$(cd -P "$(dirname "$hqc_self")" 2>/dev/null && pwd) || hqc_fail_open "cannot resolve the hook's location"
  hqc_self=$(readlink "$hqc_self") || hqc_fail_open "cannot resolve the hook's location"
  case "$hqc_self" in
    /*) ;;
    *) hqc_self="$hqc_dir/$hqc_self" ;;
  esac
done
hqc_here=$(cd -P "$(dirname "$hqc_self")" 2>/dev/null && pwd) || hqc_fail_open "cannot resolve the hook's location"

if [ ! -f "$hqc_here/capture.py" ]; then
  hqc_fail_open "capture.py is missing next to capture.sh"
fi
hqc_py=$(command -v python3 2>/dev/null) || hqc_py=""
if [ -z "$hqc_py" ] && [ -x /usr/bin/python3 ]; then
  hqc_py=/usr/bin/python3
fi
if [ -z "$hqc_py" ]; then
  hqc_fail_open "python3 is not installed"
fi

# capture.py prints at most one warning line itself and always exits 0. A
# non-zero status means it could not run at all (for example a Python too old
# to parse it); its own output is then replaced by one line of ours. -I keeps
# PYTHON* variables and the user's site-packages out of the hook.
hqc_err=$(mktemp "${TMPDIR:-/tmp}/human-queue-capture.XXXXXX" 2>/dev/null) || hqc_err=/dev/null
hqc_rc=0
"$hqc_py" -I "$hqc_here/capture.py" 2>"$hqc_err" || hqc_rc=$?
if [ "$hqc_rc" -eq 0 ]; then
  if [ "$hqc_err" != /dev/null ]; then sed -n '1p' "$hqc_err" >&2; fi
else
  printf 'human-queue-capture: capture.py exited %s; the menu renders in this thread\n' "$hqc_rc" >&2
fi
if [ "$hqc_err" != /dev/null ]; then rm -f "$hqc_err"; fi
exit 0
