#!/usr/bin/env bash
# backlog-health.sh — backlog health aggregator for /pm's always-on summary (issue #598).
#
# PURPOSE:
#   Computes the "Backlog health" data model /pm renders before its ranking
#   output: total open count, a 30-day rolling age split, defer/close
#   candidate count (delegated to backlog-staleness.sh — never re-derived),
#   actionable backlog size, recent throughput, and a time-to-clear estimate
#   from a 30-day rolling closure rate, with graceful zero-rate handling.
#
# USAGE:
#   backlog-health.sh [--days N] [--recent-days N] [--json]
#   backlog-health.sh --help
#
#   --days N          Rolling window (days) for the age split, the candidate
#                      detection threshold, and the closure-rate window.
#                      Default 30.
#   --recent-days N    Rolling window (days) for the "recently closed"
#                      throughput count. Default 7.
#   --json             Emit a single JSON object on stdout. Default emits
#                      "key: value" lines.
#
# OUTPUT (--json fields):
#   total_open, opened_last_N_days, older_than_N_days, candidate_count,
#   actionable_backlog, closed_last_recent_days, closed_last_N_days,
#   closure_rate_per_day (number|null), estimate (
#     {value, unit: "days"|"weeks"} | null), estimate_message (string|null —
#     set when closure_rate_per_day is 0/null, e.g. "cadence too low to
#     estimate").
#
# EXIT CODES:
#   0  OK
#   2  Usage error (unknown flag, --days/--recent-days requires a value)
#   3  gh CLI error (not installed, not authenticated, network/API failure)
#
# EXAMPLES:
#   .claude/scripts/backlog-health.sh --json
#   .claude/scripts/backlog-health.sh --days 45 --recent-days 14 --json
#
# DEPENDENCIES:
#   - gh CLI (authenticated), jq, bash 3.2+ (macOS-compatible), awk
#   - .claude/scripts/gh-window.sh, .claude/scripts/backlog-staleness.sh

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

print_help() {
  sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'
}

err() {
  printf 'backlog-health.sh: %s\n' "$1" >&2
}

DAYS=30
RECENT_DAYS=7
EMIT_JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --days)
      if [ $# -lt 2 ] || [ -z "${2-}" ]; then
        err "--days requires a value"
        exit 2
      fi
      DAYS="$2"
      shift 2
      ;;
    --days=*)
      DAYS="${1#--days=}"
      shift
      ;;
    --recent-days)
      if [ $# -lt 2 ] || [ -z "${2-}" ]; then
        err "--recent-days requires a value"
        exit 2
      fi
      RECENT_DAYS="$2"
      shift 2
      ;;
    --recent-days=*)
      RECENT_DAYS="${1#--recent-days=}"
      shift
      ;;
    --json)
      EMIT_JSON=1
      shift
      ;;
    *)
      err "unknown flag: $1"
      err "Run with --help for usage."
      exit 2
      ;;
  esac
done

case "$DAYS" in
  ''|*[!0-9]*) err "Invalid --days value, defaulting to 30 days"; DAYS=30 ;;
  *) [ "$DAYS" -le 0 ] && { err "--days must be positive, defaulting to 30 days"; DAYS=30; } ;;
esac
case "$RECENT_DAYS" in
  ''|*[!0-9]*) err "Invalid --recent-days value, defaulting to 7 days"; RECENT_DAYS=7 ;;
  *) [ "$RECENT_DAYS" -le 0 ] && { err "--recent-days must be positive, defaulting to 7 days"; RECENT_DAYS=7; } ;;
esac

command -v gh >/dev/null 2>&1 || { err "gh CLI not found"; exit 3; }
command -v jq >/dev/null 2>&1 || { err "jq not found"; exit 3; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

IFS=$'\t' read -r SINCE_DATE SINCE_ISO < <(bash "$SCRIPT_DIR/gh-window.sh" --days "$DAYS")
IFS=$'\t' read -r RECENT_SINCE_DATE RECENT_SINCE_ISO < <(bash "$SCRIPT_DIR/gh-window.sh" --days "$RECENT_DAYS")

# ---------------------------------------------------------------------------
# Total open + age split
# ---------------------------------------------------------------------------

if ! OPEN_ISSUES=$(gh issue list --state open --limit 500 --json number,createdAt 2>"$TMP/open.err"); then
  err "gh issue list (open) failed: $(cat "$TMP/open.err")"
  exit 3
fi
printf '%s' "$OPEN_ISSUES" > "$TMP/open.json"

TOTAL_OPEN=$(jq 'length' "$TMP/open.json")
if [ "$TOTAL_OPEN" -eq 500 ]; then
  err "Open issue count hit the 500-item fetch cap — total_open/actionable_backlog may be undercounted."
fi
OPENED_RECENT=$(jq --arg since "$SINCE_ISO" '[.[] | select(.createdAt >= $since)] | length' "$TMP/open.json")
OPENED_OLDER=$((TOTAL_OPEN - OPENED_RECENT))

# ---------------------------------------------------------------------------
# Defer/close candidates — delegated entirely to backlog-staleness.sh.
# Per issue #598 AC, only the inactive/superseded/potential-duplicate
# categories count as defer/close candidates (solved-by-pr is a separate,
# factual signal /pm-clean surfaces on its own — not a defer/close call).
# Intersected with the >$DAYS-day-old bucket.
# ---------------------------------------------------------------------------

if ! FLAGS=$(bash "$SCRIPT_DIR/backlog-staleness.sh" --days "$DAYS" --json 2>"$TMP/staleness.err"); then
  err "backlog-staleness.sh failed: $(cat "$TMP/staleness.err")"
  exit 3
fi
printf '%s' "$FLAGS" > "$TMP/flags.json"

CANDIDATE_COUNT=$(jq -n --slurpfile flags "$TMP/flags.json" --slurpfile open "$TMP/open.json" --arg since "$SINCE_ISO" '
  ($flags[0] | map(select(.category=="inactive" or .category=="superseded" or .category=="potential-duplicate")) | map(.number) | unique) as $nums |
  [$open[0][] | select(.number as $n | $nums | index($n)) | select(.createdAt < $since)] | length
')
ACTIONABLE_BACKLOG=$((TOTAL_OPEN - CANDIDATE_COUNT))

# ---------------------------------------------------------------------------
# Throughput: recent closures + 30-day rolling closure rate
# ---------------------------------------------------------------------------

if ! CLOSED_RECENT_COUNT=$(gh issue list --state closed --search "closed:>=$RECENT_SINCE_DATE" --json number --limit 500 2>"$TMP/closedrecent.err" | jq 'length'); then
  err "gh issue list (recent closed) failed: $(cat "$TMP/closedrecent.err")"
  exit 3
fi
if [ "$CLOSED_RECENT_COUNT" -eq 500 ]; then
  err "Recent-closed count hit the 500-item fetch cap — closed_last_recent_days may be undercounted."
fi

if ! CLOSED_WINDOW_COUNT=$(gh issue list --state closed --search "closed:>=$SINCE_DATE" --json number --limit 500 2>"$TMP/closedwindow.err" | jq 'length'); then
  err "gh issue list (window closed) failed: $(cat "$TMP/closedwindow.err")"
  exit 3
fi
if [ "$CLOSED_WINDOW_COUNT" -eq 500 ]; then
  err "Closure-window count hit the 500-item fetch cap — closure_rate_per_day/estimate may be undercounted."
fi

CLOSURE_RATE=$(awk -v c="$CLOSED_WINDOW_COUNT" -v d="$DAYS" 'BEGIN { printf "%.6f", c / d }')
RATE_IS_ZERO=$(awk -v r="$CLOSURE_RATE" 'BEGIN { print (r <= 0) ? 1 : 0 }')

ESTIMATE_JSON="null"
ESTIMATE_MESSAGE="null"
if [ "$RATE_IS_ZERO" -eq 1 ]; then
  ESTIMATE_MESSAGE='"cadence too low to estimate"'
else
  TTC_DAYS=$(awk -v a="$ACTIONABLE_BACKLOG" -v r="$CLOSURE_RATE" 'BEGIN { printf "%.2f", a / r }')
  USE_WEEKS=$(awk -v d="$TTC_DAYS" 'BEGIN { print (d >= 14) ? 1 : 0 }')
  if [ "$USE_WEEKS" -eq 1 ]; then
    VALUE=$(awk -v d="$TTC_DAYS" 'BEGIN { w = d / 7; printf "%d", int(w + 0.5) }')
    UNIT="weeks"
  else
    VALUE=$(awk -v d="$TTC_DAYS" 'BEGIN { printf "%d", (d == int(d)) ? d : int(d) + 1 }')
    UNIT="days"
  fi
  ESTIMATE_JSON="{\"value\": $VALUE, \"unit\": \"$UNIT\"}"
fi

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------

if [ "$EMIT_JSON" -eq 1 ]; then
  jq -nc \
    --argjson total_open "$TOTAL_OPEN" \
    --argjson opened_recent "$OPENED_RECENT" \
    --argjson opened_older "$OPENED_OLDER" \
    --argjson candidate_count "$CANDIDATE_COUNT" \
    --argjson actionable_backlog "$ACTIONABLE_BACKLOG" \
    --argjson closed_recent "$CLOSED_RECENT_COUNT" \
    --argjson closed_window "$CLOSED_WINDOW_COUNT" \
    --argjson rate "$([ "$RATE_IS_ZERO" -eq 1 ] && echo null || echo "$CLOSURE_RATE")" \
    --argjson estimate "$ESTIMATE_JSON" \
    --argjson estimate_message "$ESTIMATE_MESSAGE" \
    --argjson days "$DAYS" \
    --argjson recent_days "$RECENT_DAYS" \
    '{
      total_open: $total_open,
      window_days: $days,
      recent_window_days: $recent_days,
      opened_last_N_days: $opened_recent,
      older_than_N_days: $opened_older,
      candidate_count: $candidate_count,
      actionable_backlog: $actionable_backlog,
      closed_last_recent_days: $closed_recent,
      closed_last_N_days: $closed_window,
      closure_rate_per_day: $rate,
      estimate: $estimate,
      estimate_message: $estimate_message
    }'
else
  echo "total_open: $TOTAL_OPEN"
  echo "opened_last_${DAYS}_days: $OPENED_RECENT"
  echo "older_than_${DAYS}_days: $OPENED_OLDER"
  echo "candidate_count: $CANDIDATE_COUNT"
  echo "actionable_backlog: $ACTIONABLE_BACKLOG"
  echo "closed_last_${RECENT_DAYS}_days: $CLOSED_RECENT_COUNT"
  echo "closed_last_${DAYS}_days: $CLOSED_WINDOW_COUNT"
  if [ "$RATE_IS_ZERO" -eq 1 ]; then
    echo "estimate: cadence too low to estimate"
  else
    echo "estimate: $VALUE $UNIT"
  fi
fi

exit 0
