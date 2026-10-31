#!/usr/bin/env bash
# spend-telemetry-report.sh — Report legacy execution events and v2 usage coverage.
# catalog: token-measurement — Summarize model, usage, lifecycle, and coverage from `~/.claude/spend-telemetry.log`
#
# Metadata only. Missing usage/cost/outcome fields remain unknown; this report
# never estimates spend or gates work. See spend-telemetry-pipeline.md.
#
# USAGE: spend-telemetry-report.sh [--days N] | --help
#   --days N  Include coverage for the most recent N UTC days (positive integer).
#   --help    Print this help.
#
# EXIT STATUS: 0 success; 2 invalid arguments.

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

DAYS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)
      DAYS="${2:-}"
      if [[ -z "$DAYS" ]]; then echo "ERROR: --days requires a value" >&2; exit 2; fi
      shift 2
      ;;
    --days=*)
      DAYS="${1#--days=}"
      if [[ -z "$DAYS" ]]; then echo "ERROR: --days requires a positive integer" >&2; exit 2; fi
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "$DAYS" ]] && { ! [[ "$DAYS" =~ ^[0-9]+$ ]] || [[ "$DAYS" -lt 1 ]]; }; then
  echo "ERROR: --days must be a positive integer" >&2
  exit 2
fi

LOG_PATH="${HOME}/.claude/spend-telemetry.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/lib/spend-telemetry-report-v2.py" "${DAYS:-0}" "$LOG_PATH"
