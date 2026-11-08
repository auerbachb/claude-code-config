#!/usr/bin/env bash
# catalog: session-state-locking — Independently verify merged-issue completion and reconcile one explicitly scope-verified issue
set -euo pipefail
umask 077
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/issue_completion.py" "$@"
