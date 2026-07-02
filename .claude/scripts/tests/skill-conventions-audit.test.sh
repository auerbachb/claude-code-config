#!/usr/bin/env bash
# Unit smoke test for skill-conventions-audit.sh (issue #417)
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
AUDIT="${REPO_ROOT}/.claude/scripts/skill-conventions-audit.sh"

[[ -x "$AUDIT" ]] || chmod +x "$AUDIT"

# Default run: may emit warnings on legacy skills; must not error on structure
if ! "$AUDIT" >/tmp/skill-audit.out 2>/tmp/skill-audit.err; then
  echo "FAIL: audit exited non-zero in default mode" >&2
  cat /tmp/skill-audit.err >&2
  exit 1
fi

grep -q "Summary:" /tmp/skill-audit.out || { echo "FAIL: missing summary line"; exit 1; }

echo "OK: skill-conventions-audit smoke test passed"
