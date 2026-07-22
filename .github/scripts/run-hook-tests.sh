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
#   bash .github/scripts/run-hook-tests.sh
#
# Not `set -e`: the loop deliberately runs every suite and aggregates failures
# so one red test does not hide the rest. The final check is the exit gate.
set -uo pipefail
shopt -s nullglob

# Resolve to the repo root regardless of caller cwd so the globs below resolve.
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || {
  echo "::error::run-hook-tests.sh: cannot cd to repo root" >&2
  exit 1
}

failed=0
total=0
for t in .claude/hooks/tests/*.test.sh \
         .claude/scripts/tests/*.test.sh \
         .github/scripts/tests/*.test.sh; do
  total=$((total + 1))
  printf '::group::%s\n' "$t"
  if bash "$t"; then
    printf 'PASS: %s\n' "$t"
    printf '::endgroup::\n'
  else
    rc=$?
    printf '::endgroup::\n'
    printf '::error::FAIL (rc=%s): %s\n' "$rc" "$t"
    failed=$((failed + 1))
  fi
done

printf '\nDiscovered and ran %s bash test suite(s); %s failed.\n' "$total" "$failed"

# Fail loud if discovery found nothing — a silently-empty run must never pass
# green and masquerade as "all tests passed" (issue #681).
if [ "$total" -eq 0 ]; then
  echo "::error::run-hook-tests.sh discovered no test suites — a glob is broken" >&2
  exit 1
fi

[ "$failed" -eq 0 ]
