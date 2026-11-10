#!/usr/bin/env bash
# catalog: session-state-locking — Capture and classify raw recovery verdict evidence without turning parse/execution failure into success
set -euo pipefail
umask 077
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/recovery_evidence.py" "$@"
