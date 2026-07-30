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
#   bash .github/scripts/run-python-tests.sh
#
# Python version: determined by whatever `python3` is on PATH. The CI workflow
# handles version pinning via the `setup-python` step before calling this
# script, so the script itself takes no arguments.
set -euo pipefail
shopt -s nullglob

# Resolve to the repo root regardless of caller cwd so the glob below resolves.
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || {
  echo "::error::run-python-tests.sh: cannot cd to repo root" >&2
  exit 1
}

# Discover tests/test_*.py and fail loud on an empty set — a silent
# "Ran 0 tests ... OK" must never pass green (issue #681).
mods=(tests/test_*.py)
if [ "${#mods[@]}" -eq 0 ]; then
  echo "::error::No tests/test_*.py modules discovered — a glob is broken or tests/ is empty" >&2
  exit 1
fi

echo "Discovered ${#mods[@]} Python test module(s)."
python3 -m unittest discover -s tests -p 'test_*.py' -v
