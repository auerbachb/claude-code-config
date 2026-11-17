#!/usr/bin/env bash
# orchestrator-cost-report.sh — Read-only parent-thread vs worker token report for one session (issue #2434).
# catalog: token-measurement — Split one session's observed tokens into parent-thread and worker totals, with coverage labels
#
# Strictly read-only: writes no telemetry, cursor, spool, lock or log, and makes
# no provider call. Missing figures are reported as unknown, never zero. This
# report gates nothing (safety.md quota authority). See spend-telemetry-pipeline.md.
#
# USAGE: orchestrator-cost-report.sh [--session ID] [--transcript PATH] [--projects-dir DIR]
#                                    [--log PATH] [--json | --one-line] [--top N] | --help
#   --session ID        Session to report (else CLAUDE_CODE_SESSION_ID, then CLAUDE_SESSION_ID).
#   --transcript PATH   Main transcript file (else resolved under --projects-dir).
#   --projects-dir DIR  Projects root (default ~/.claude/projects).
#   --log PATH          Spend telemetry log (default ~/.claude/spend-telemetry.log).
#   --json              Emit one JSON document.
#   --one-line          Emit the one-line parent share.
#   --top N             Number of top turns to list (default 5).
#   --help              Print this help.
#
# EXIT STATUS: 0 report produced (figures may be unknown); 1 named input error on
# stderr (session_unknown, transcript_not_found, transcript_unreadable,
# transcript_ambiguous); 2 invalid arguments.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$SCRIPT_DIR/lib/orchestrator-cost-report.py"

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --session|--transcript|--projects-dir|--log|--top)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "orchestrator-cost-report: $1 requires a value" >&2
        usage >&2
        exit 2
      fi
      ARGS+=("$1" "$2"); shift 2 ;;
    --json|--one-line) ARGS+=("$1"); shift ;;
    *)
      echo "orchestrator-cost-report: unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [[ ! -f "$PY" ]]; then
  echo "ERROR: orchestrator-cost-report.py not found — report unavailable" >&2
  exit 1
fi

exec python3 "$PY" ${ARGS[@]+"${ARGS[@]}"}
