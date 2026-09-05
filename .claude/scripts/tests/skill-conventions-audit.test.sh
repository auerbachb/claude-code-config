#!/usr/bin/env bash
# Unit smoke test for skill-conventions-audit.sh (issue #417)
# catalog: tests — Tests for `skill-conventions-audit.sh`
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
AUDIT="${REPO_ROOT}/.claude/scripts/skill-conventions-audit.sh"

OUT=$(mktemp -t skill-audit.out.XXXXXX)
ERR=$(mktemp -t skill-audit.err.XXXXXX)
trap 'rm -f "$OUT" "$ERR"' EXIT

# Default run: may emit warnings on legacy skills; must not error on structure
if ! bash "$AUDIT" >"$OUT" 2>"$ERR"; then
  echo "FAIL: audit exited non-zero in default mode" >&2
  cat "$ERR" >&2
  exit 1
fi

grep -q "Summary:" "$OUT" || { echo "FAIL: missing summary line"; exit 1; }

echo "OK: skill-conventions-audit smoke test passed"
