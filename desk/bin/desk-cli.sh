#!/usr/bin/env bash
# desk-cli.sh — human-queue.sh for the /desk skill and its Monitor, with the
# store's URL found the way the capture hook finds it (issue #1779).
# catalog: utilities — Human-queue CLI for the desk (`desk/bin/desk-cli.sh`): runs human-queue.sh with the store URL found the way the capture hook finds it
#
# USAGE
#   desk-cli.sh <subcommand> [args]     exactly as human-queue.sh
#
# WHY
#   The desktop app starts the Bash tool and Monitor commands without the
#   operator's login profile, so HUMAN_QUEUE_DATABASE_URL is often unset there
#   and every human-queue.sh call would exit 7. The capture hook already solves
#   this (desk/README.md, "Capture hook", "Finding the store"): the
#   environment, then ${XDG_CONFIG_HOME:-~/.config}/human-queue/database_url
#   (a file you own, mode 600), then the last literal
#   `export HUMAN_QUEUE_DATABASE_URL=...` line of the first shell profile that
#   sets it — read, never run. This wrapper calls that same resolver
#   (desk/hooks/capture.py's resolve_url), so there is one parser, not two.
#
# BEHAVIOR
#   With the URL in the environment, or with `--help` as the first or second
#   argument (help is offline), it runs human-queue.sh directly. Otherwise it
#   resolves the URL, puts it in human-queue.sh's environment only, and runs
#   it. The URL is never printed, logged, or put on a command line.
#
# ENVIRONMENT
#   HUMAN_QUEUE_CLI   run this program instead of desk/bin/human-queue.sh
#                     (tests; the capture hook honors the same variable)
#
# EXIT CODES
#   human-queue.sh's own, or 7 with one line on stderr when no URL can be
#   found (or python3 is missing), the same code the CLI uses for an unset
#   database, so callers fail open the same way.
#
# Bash 3.2 compatible (macOS /bin/bash).
set -u

# Resolve this file's real directory through any chain of symlinks (the skill
# reaches it through ~/.claude/skills-worktree). `readlink -f` is missing from
# older macOS.
dc_self="${BASH_SOURCE[0]}"
while [ -L "$dc_self" ]; do
  dc_dir=$(cd -P "$(dirname "$dc_self")" && pwd) || exit 1
  dc_self=$(readlink "$dc_self") || exit 1
  case "$dc_self" in
    /*) ;;
    *) dc_self="$dc_dir/$dc_self" ;;
  esac
done
dc_bin=$(cd -P "$(dirname "$dc_self")" && pwd) || exit 1
dc_desk=$(dirname "$dc_bin")
dc_cli="${HUMAN_QUEUE_CLI:-$dc_bin/human-queue.sh}"

dc_unavailable() {
  printf 'desk-cli: %s\n' "$1" >&2
  exit 7
}

dc_run() {
  if [ -x "$dc_cli" ]; then
    exec "$dc_cli" "$@"
  fi
  exec bash "$dc_cli" "$@"
}

case "${1:-}:${2:-}" in
  -h:*|--help:*|help:*|*:-h|*:--help) dc_run "$@" ;;
esac

case "${HUMAN_QUEUE_DATABASE_URL:-}" in
  *[![:space:]]*) dc_run "$@" ;;
esac

dc_py=$(command -v python3 2>/dev/null) || dc_py=""
if [ -z "$dc_py" ] && [ -x /usr/bin/python3 ]; then
  dc_py=/usr/bin/python3
fi
if [ -z "$dc_py" ]; then
  dc_unavailable "HUMAN_QUEUE_DATABASE_URL is unset and python3 is not installed to find it"
fi
if [ ! -f "$dc_desk/hooks/capture.py" ]; then
  dc_unavailable "HUMAN_QUEUE_DATABASE_URL is unset and desk/hooks/capture.py is missing"
fi

# The resolver writes the URL to its stdout, which only this substitution
# reads, or one reason line (no URL in it) to stderr and exits 7. Anything
# else on its stderr (a traceback) is dropped, never shown.
dc_err=$(mktemp "${TMPDIR:-/tmp}/desk-cli.XXXXXX" 2>/dev/null) || dc_err=/dev/null
dc_rc=0
dc_url=$("$dc_py" -I - "$dc_desk/hooks/capture.py" 2>"$dc_err" <<'PY'
import importlib.util
import sys
import time

spec = importlib.util.spec_from_file_location("hq_capture", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    url = mod.resolve_url(mod.Hook(time.monotonic()))
except mod.FailOpen as exc:
    sys.stderr.write("desk-cli: %s\n" % " ".join(str(exc).split()))
    sys.exit(7)
sys.stdout.write(url)
PY
) || dc_rc=$?
dc_reason=""
if [ "$dc_err" != /dev/null ]; then
  dc_reason=$(grep -m1 '^desk-cli: ' "$dc_err" 2>/dev/null || true)
  rm -f "$dc_err"
fi
if [ "$dc_rc" -ne 0 ]; then
  unset dc_url
  if [ -z "$dc_reason" ]; then
    dc_reason="could not find the store URL (the resolver exited $dc_rc)"
  fi
  dc_unavailable "${dc_reason#desk-cli: }"
fi
case "$dc_url" in
  *[![:space:]]*) ;;
  *) dc_unavailable "no store URL was found" ;;
esac

HUMAN_QUEUE_DATABASE_URL="$dc_url"
export HUMAN_QUEUE_DATABASE_URL
unset dc_url
dc_run "$@"
