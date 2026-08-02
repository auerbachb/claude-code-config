#!/usr/bin/env bash
#
# Discover and run every bash hook/script test suite in the repo. Adding a test
# needs NO workflow edit: drop a `<name>.test.sh` into one of the discovered
# dirs and it runs automatically. This retired the per-test step list in
# .github/workflows/hook-scripts.yml that made that file a recurring
# merge-conflict hotspot (issue #681).
#
# Discovered dirs:
#   .claude/hooks/tests/    .claude/scripts/tests/    .github/scripts/tests/
#
# Test contract: exit 0 on pass / non-zero on fail; invoked via `bash` so the
# executable bit is NOT required (some suites are intentionally non-exec); no
# positional args needed.
#
# Usage (CI or local, runnable from anywhere):
#   bash .github/scripts/run-hook-tests.sh            # human/CI folds (default)
#   bash .github/scripts/run-hook-tests.sh --json     # compact result contract
#   bash .github/scripts/run-hook-tests.sh --help
#
# --json (issue #782): emits the compact result contract from
# .claude/reference/compact-result-contract.md as the ONLY thing on stdout:
#
#   {"ok":false,"failed_tests":[".claude/scripts/tests/foo.test.sh"],
#    "relevant_error":"foo.test.sh: FAIL: expects exit 3","log_path":"/tmp/run-hook-tests-....log",
#    "total":94,"failed":1}
#
# Compact mode silences PASSING suites — that is where the savings are. Failing
# suites still print their captured output IN FULL, on stderr, because a failing
# test must never be compacted down to a status line (token-efficiency-audit-2026-07.md
# §"What NOT to change"). The complete capture of every suite, pass or fail, is always
# written to `log_path` in both modes.
#
# Log location: $RUN_TESTS_LOG_DIR, else $RUNNER_TEMP (GitHub Actions), else $TMPDIR, else /tmp.
#
# Exit codes:
#   0  every discovered suite passed
#   1  one or more suites failed
#   2  usage error (unknown flag)
#   3  discovery found no suites — a glob is broken (issue #681); never a silent green
#
# Not `set -e`: the loop deliberately runs every suite and aggregates failures
# so one red test does not hide the rest. The final check is the exit gate.
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
      echo "::error::run-hook-tests.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Resolve to the repo root regardless of caller cwd so the globs below resolve.
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || {
  echo "::error::run-hook-tests.sh: cannot cd to repo root" >&2
  exit 1
}

LOG_DIR="${RUN_TESTS_LOG_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
LOG_DIR="${LOG_DIR%/}"   # $TMPDIR usually ends in / — keep log_path free of a doubled slash
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
LOG="$LOG_DIR/run-hook-tests-$(date -u +%s)-$$.log"
: > "$LOG"

# Every human-facing line goes to stderr in --json mode so stdout stays parseable.
say() { if [ "$JSON" -eq 1 ]; then printf '%s\n' "$1" >&2; else printf '%s\n' "$1"; fi; }

SUITE_OUT="$(mktemp "${TMPDIR:-/tmp}/run-hook-tests-suite-XXXXXX")"
cleanup() { rm -f "$SUITE_OUT"; }
trap cleanup EXIT

failed=0
total=0
FAILED_LIST=""
RELEVANT=""
for t in .claude/hooks/tests/*.test.sh \
         .claude/scripts/tests/*.test.sh \
         .github/scripts/tests/*.test.sh; do
  total=$((total + 1))
  rc=0
  bash "$t" >"$SUITE_OUT" 2>&1 || rc=$?

  # The full capture always reaches the log, pass or fail, in both modes.
  {
    printf '===== %s (rc=%s) =====\n' "$t" "$rc"
    cat "$SUITE_OUT"
    printf '\n'
  } >> "$LOG"

  if [ "$rc" -eq 0 ]; then
    if [ "$JSON" -eq 0 ]; then
      printf '::group::%s\n' "$t"
      cat "$SUITE_OUT"
      printf 'PASS: %s\n' "$t"
      printf '::endgroup::\n'
    fi
  else
    # Failures print in full in BOTH modes — compaction never hides a red test.
    if [ "$JSON" -eq 0 ]; then
      printf '::group::%s\n' "$t"
      cat "$SUITE_OUT"
      printf '::endgroup::\n'
      printf '::error::FAIL (rc=%s): %s\n' "$rc" "$t"
    else
      {
        printf '::group::FAIL %s (rc=%s)\n' "$t" "$rc"
        cat "$SUITE_OUT"
        printf '::endgroup::\n'
      } >&2
    fi
    failed=$((failed + 1))
    FAILED_LIST="${FAILED_LIST}${t}"$'\n'
    # relevant_error: the decisive line(s) from THIS suite's capture only —
    # anchored so a suite's own "FAIL:" tally lines are picked up but ordinary
    # prose mentioning "fail" is not. Scanning the aggregate log instead would
    # attribute another suite's lines to this one.
    RELEVANT="${RELEVANT}$(awk -v s="$t" '
        /^(FAIL|ERROR|not ok)/ || /AssertionError/ || /^::error::/ || / line [0-9]+: / {
          print s ": " $0
          if (++n >= 3) exit
        }' "$SUITE_OUT" 2>/dev/null)"$'\n'
  fi
done

say "$(printf '\nDiscovered and ran %s bash test suite(s); %s failed.\nFull output: %s' "$total" "$failed" "$LOG")"

# Fail loud if discovery found nothing — a silently-empty run must never pass
# green and masquerade as "all tests passed" (issue #681).
if [ "$total" -eq 0 ]; then
  if [ "$JSON" -eq 1 ]; then
    jq -cn --arg log "$LOG" \
      '{ok: false, failed_tests: [], relevant_error: "run-hook-tests.sh discovered no test suites — a glob is broken", log_path: $log, total: 0, failed: 0}'
  fi
  echo "::error::run-hook-tests.sh discovered no test suites — a glob is broken" >&2
  exit 3
fi

if [ "$JSON" -eq 1 ]; then
  # Cap per the contract — relevant_error indexes the failure, log_path holds it all.
  RELEVANT="$(printf '%s' "$RELEVANT" | sed '/^$/d' \
    | awk 'NR <= 20 { print } NR == 21 { print "… (truncated; see log_path)"; exit }' | cut -c1-2000)"
  # A suite can fail without printing any recognized marker (e.g. a bare non-zero
  # exit). Naming it is still better than a null error.
  [ -n "$RELEVANT" ] || RELEVANT="$(printf '%s' "$FAILED_LIST" | sed '/^$/d' | sed 's/^/failed suite: /' | head -n 20)"
  jq -cn \
    --argjson ok "$( [ "$failed" -eq 0 ] && echo true || echo false )" \
    --arg failed_list "$FAILED_LIST" \
    --arg relevant "$RELEVANT" \
    --arg log "$LOG" \
    --argjson total "$total" \
    --argjson failed "$failed" \
    '{ok: $ok,
      failed_tests: ($failed_list | split("\n") | map(select(length > 0))),
      relevant_error: (if $relevant == "" then null else $relevant end),
      log_path: $log, total: $total, failed: $failed}'
fi

[ "$failed" -eq 0 ]
