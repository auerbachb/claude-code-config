#!/usr/bin/env bash
# catalog: token-measurement — Preview verified Claude /end stops and dispatch an explicitly approved resume batch once
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -B "$SCRIPT_DIR/lib/quota_resume_batch.py" "$@"
