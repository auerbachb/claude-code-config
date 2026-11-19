#!/usr/bin/env bash
# catalog: token-measurement — Recommend the cheapest suitable worker, apply a reasoned parent choice, and diagnose retry/escalation evidence
# Pure decision helper: no model calls, state writes, credential reads or gate overrides.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/model-route.py" "$@"
