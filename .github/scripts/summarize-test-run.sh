#!/usr/bin/env bash
#
# Run a compact-contract test runner and surface its verdict in CI (issue #782).
#
# Wraps run-hook-tests.sh / run-python-tests.sh in --json mode so a CI job log carries
# the one-line result contract instead of every passing suite's raw fold, then mirrors
# that contract into $GITHUB_STEP_SUMMARY and turns a red run into an ::error::
# annotation carrying `relevant_error` + `log_path`.
#
# It lives here rather than inline in .github/workflows/hook-scripts.yml for the same
# reason test discovery does (issue #681): that file's shared step tail is a
# merge-conflict hotspot, and inline `run:` blocks cannot be unit-tested.
#
# Contract consumed: .claude/reference/compact-result-contract.md
#   {"ok":bool,"failed_tests":[...],"relevant_error":str|null,"log_path":str, ...}
#
# Usage:
#   summarize-test-run.sh <label> <runner-script> [extra runner args...]
#   summarize-test-run.sh --help
#
#   <label>          Heading used in the step summary (e.g. "Bash test suites").
#   <runner-script>  Path to a runner that supports --json. `--json` is appended
#                    automatically; extra args are passed through before it.
#
# The runner's own stderr is NOT captured — it passes straight through, so a failing
# suite's full output still reaches the job log. Only stdout (the contract) is read.
#
# Exit codes:
#   0  runner reported ok
#   2  usage error
#   4  runner emitted no parseable contract on stdout (a wrapper bug — fails loud
#      rather than passing green on a guard that did not run)
#   *  otherwise the runner's own exit code, propagated unchanged
set -uo pipefail

usage() {
  awk 'NR == 1 { next } /^#/ { print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ "$#" -lt 2 ]; then
  echo "::error::summarize-test-run.sh: usage: summarize-test-run.sh <label> <runner-script> [args...]" >&2
  exit 2
fi

LABEL="$1"
RUNNER="$2"
shift 2

if [ ! -f "$RUNNER" ]; then
  echo "::error::summarize-test-run.sh: runner not found: $RUNNER" >&2
  exit 2
fi

RC=0
CONTRACT="$(bash "$RUNNER" "$@" --json)" || RC=$?

if ! printf '%s' "$CONTRACT" | jq -e 'has("ok") and has("log_path")' >/dev/null 2>&1; then
  echo "::error::summarize-test-run.sh: $RUNNER emitted no parseable result contract on stdout" >&2
  printf 'raw stdout was:\n%s\n' "$CONTRACT" >&2
  [ "$RC" -ne 0 ] && exit "$RC"
  exit 4
fi

# `printf '%s'` not `echo` — echo mangles JSON into jq on some shells
# (memory: zsh-echo-jq-json-corruption).
OK="$(printf '%s' "$CONTRACT" | jq -r '.ok')"
LOG_PATH="$(printf '%s' "$CONTRACT" | jq -r '.log_path // ""')"
FAILED_COUNT="$(printf '%s' "$CONTRACT" | jq -r '(.failed_tests // []) | length')"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### %s — %s\n\n' "$LABEL" "$( [ "$OK" = "true" ] && echo 'passed' || echo 'FAILED' )"
    if [ "$FAILED_COUNT" -gt 0 ]; then
      printf 'Failing (%s):\n\n' "$FAILED_COUNT"
      printf '%s' "$CONTRACT" | jq -r '(.failed_tests // [])[] | "- `" + . + "`"'
      printf '\n'
    fi
    printf '```json\n%s\n```\n\n' "$CONTRACT"
    printf 'Full output on the runner: `%s`\n\n' "$LOG_PATH"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$OK" != "true" ]; then
  # Annotations are single-line; take the first line and point at the full log.
  FIRST_LINE="$(printf '%s' "$CONTRACT" | jq -r '.relevant_error // ""' | head -n 1)"
  [ -n "$FIRST_LINE" ] || FIRST_LINE="$LABEL failed"
  echo "::error::${LABEL}: ${FIRST_LINE} (full output: ${LOG_PATH})" >&2
fi

exit "$RC"
