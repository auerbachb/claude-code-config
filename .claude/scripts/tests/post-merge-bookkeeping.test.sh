#!/usr/bin/env bash
# catalog: tests — Exercise actual merge bookkeeping, logger, claim cleanup and resumed workflow boundaries with isolated stateful GitHub fixtures
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
BOOKKEEPING_TEST_SHELL="${BOOKKEEPING_TEST_SHELL:-$BASH}" \
  python3 "$ROOT/tests/test_post_merge_bookkeeping.py" "$@"
