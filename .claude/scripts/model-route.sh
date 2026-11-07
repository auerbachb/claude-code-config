#!/usr/bin/env bash
# catalog: token-measurement — Select a capable cheap worker and diagnose task-local retry/escalation evidence
# Pure decision helper: no model calls, state writes, credential reads or gate overrides.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/model-route.py" "$@"
