#!/usr/bin/env bash
#
# Discover and run every Python unittest module in tests/. Adding a test needs
# NO workflow edit: drop a `test_*.py` module into tests/ and it runs
# automatically under both the default-Python job and the pinned-3.9 job.
# This script extracts the duplicated inline discovery block that appeared
# verbatim in both jobs of .github/workflows/hook-scripts.yml, so future
# edits to Python test discovery touch exactly one file instead of two job
# bodies (issue #771; companion to the bash-test extraction done in issue #681
# via run-hook-tests.sh).
#
# Discovery contract: tests/test_*.py modules, invoked via
# `python3 -m unittest discover`.
#
# Usage (CI or local, runnable from anywhere):
#   bash .github/scripts/run-python-tests.sh          # verbose unittest output (default)
#   bash .github/scripts/run-python-tests.sh --json   # compact result contract
#   bash .github/scripts/run-python-tests.sh --help
#
# --json (issue #782): emits the compact result contract from
# .claude/reference/compact-result-contract.md as the ONLY thing on stdout:
#
#   {"ok":false,"failed_tests":["test_x (tests.test_y.Case)"],
#    "relevant_error":"AssertionError: 3 != 4","log_path":"/tmp/run-python-tests-....log",
#    "modules":12}
#
# `unittest discover -v` prints one line per test, so a green run is pure noise in an
# agent's context — compact mode drops it. A FAILING run still prints the full unittest
# output on stderr: a red test is never compacted to a status line
# (token-efficiency-audit-2026-07.md §"What NOT to change"). The complete output is
# always written to `log_path` in both modes.
#
# Log location: $RUN_TESTS_LOG_DIR, else $RUNNER_TEMP (GitHub Actions), else $TMPDIR, else /tmp.
#
# Exit codes:
#   0  all discovered tests passed
#   1  one or more tests failed or errored
#   2  usage error (unknown flag)
#   3  discovery found no tests/test_*.py modules — a glob is broken; never a silent green
#
# Python version: determined by whatever `python3` is on PATH. The CI workflow
# handles version pinning via the `setup-python` step before calling this
# script, so the script itself takes no positional arguments.
set -uo pipefail
shopt -s nullglob

JSON=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    -h|--help)
      awk 'NR == 1 { next } /^$/ { exit } { print }' "$0"
      exit 0
      ;;
    *)
      echo "::error::run-python-tests.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Resolve to the repo root regardless of caller cwd so the glob below resolves.
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || {
  echo "::error::run-python-tests.sh: cannot cd to repo root" >&2
  exit 1
}

LOG_DIR="${RUN_TESTS_LOG_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
LOG_DIR="${LOG_DIR%/}"   # $TMPDIR usually ends in / — keep log_path free of a doubled slash
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
LOG="$LOG_DIR/run-python-tests-$(date -u +%s)-$$.log"
: > "$LOG"

# Discover tests/test_*.py and fail loud on an empty set — a silent
# "Ran 0 tests ... OK" must never pass green (issue #681).
mods=(tests/test_*.py)
if [ "${#mods[@]}" -eq 0 ]; then
  if [ "$JSON" -eq 1 ]; then
    jq -cn --arg log "$LOG" \
      '{ok: false, failed_tests: [], relevant_error: "No tests/test_*.py modules discovered — a glob is broken or tests/ is empty", log_path: $log, modules: 0}'
  fi
  echo "::error::No tests/test_*.py modules discovered — a glob is broken or tests/ is empty" >&2
  exit 3
fi

if [ "$JSON" -eq 1 ]; then
  echo "Discovered ${#mods[@]} Python test module(s)." >&2
else
  echo "Discovered ${#mods[@]} Python test module(s)."
fi

rc=0
if [ "$JSON" -eq 1 ]; then
  # unittest writes its report to stderr; capture both streams into the log and
  # keep stdout clean for the contract.
  python3 -m unittest discover -s tests -p 'test_*.py' -v >"$LOG" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    # A red run prints in full — see the header note.
    {
      printf '::group::Python unittest output (rc=%s)\n' "$rc"
      cat "$LOG"
      printf '::endgroup::\n'
    } >&2
  fi

  # unittest marks each failure as `FAIL: test_x (mod.Case)` / `ERROR: test_x (mod.Case)`.
  FAILED_LIST="$(awk '/^(FAIL|ERROR): / { sub(/^(FAIL|ERROR): /, ""); print }' "$LOG" 2>/dev/null | sort -u)"
  # The decisive line of each traceback, not the traceback itself. No `\b` here:
  # macOS ships one-true-awk, where `\b` is a backspace character, not a word
  # boundary, so an anchored `...Error\b` silently matches nothing.
  RELEVANT="$(awk '/^[A-Za-z_.]*(Error|Exception)(:|$)/ || /^(FAIL|ERROR): / { print; if (++n >= 20) exit }' "$LOG" 2>/dev/null \
    | awk 'NR <= 20 { print } NR == 21 { print "… (truncated; see log_path)"; exit }' | cut -c1-2000)"
  if [ "$rc" -ne 0 ] && [ -z "$RELEVANT" ]; then
    RELEVANT="$(tail -n 5 "$LOG" | cut -c1-2000)"
  fi
  [ "$rc" -eq 0 ] && RELEVANT=""

  jq -cn \
    --argjson ok "$( [ "$rc" -eq 0 ] && echo true || echo false )" \
    --arg failed_list "$FAILED_LIST" \
    --arg relevant "$RELEVANT" \
    --arg log "$LOG" \
    --argjson modules "${#mods[@]}" \
    '{ok: $ok,
      failed_tests: ($failed_list | split("\n") | map(select(length > 0))),
      relevant_error: (if $relevant == "" then null else $relevant end),
      log_path: $log, modules: $modules}'
else
  # Default mode is unchanged: stream verbose output, and also persist it so
  # `log_path` means the same thing in both modes.
  python3 -m unittest discover -s tests -p 'test_*.py' -v 2>&1 | tee "$LOG"
  rc="${PIPESTATUS[0]}"
  echo "Full output: $LOG"
fi

exit "$rc"
