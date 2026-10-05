#!/usr/bin/env bash
# desk/tests/run.sh — run every desk/tests/*.test.sh suite (issue #1774).
#
#   bash desk/tests/run.sh
#
# Suites that need the database skip with a notice when
# HUMAN_QUEUE_DATABASE_URL is unset, so the runner exits 0 on a machine
# without one. With the URL set, the live suites run in throwaway schemas and
# never touch the queue's default schema. CI also runs these suites, one by
# one, through .github/scripts/run-hook-tests.sh.
#
# Exit codes: 0 every suite passed (or skipped); 1 a suite failed;
# 3 no suites were found (a broken glob is never a silent pass).
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ -z "${HUMAN_QUEUE_DATABASE_URL:-}" ]; then
  echo "NOTICE: HUMAN_QUEUE_DATABASE_URL is unset — live database suites skip; offline suites still run"
fi

total=0
failed=0
failed_list=""
for t in "$TESTS_DIR"/*.test.sh; do
  [ -f "$t" ] || continue
  total=$((total + 1))
  echo "===== ${t##*/} ====="
  rc=0
  bash "$t" || rc=$?
  if [ "$rc" -ne 0 ]; then
    failed=$((failed + 1))
    failed_list="$failed_list ${t##*/}(rc=$rc)"
  fi
  echo
done

if [ "$total" -eq 0 ]; then
  echo "ERROR: no desk/tests/*.test.sh suites found" >&2
  exit 3
fi

if [ "$failed" -gt 0 ]; then
  echo "desk tests: $failed of $total suites FAILED:$failed_list"
  exit 1
fi
echo "desk tests: all $total suites passed"
