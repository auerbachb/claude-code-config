#!/usr/bin/env bash
# gh-window.sh — GitHub date-window builder (ET-anchored, macOS + GNU dual-syntax)
#
# PURPOSE:
#   Compute a $DAYS-ago window in both a date-only form (YYYY-MM-DD — for
#   GitHub search qualifiers like `merged:>=$SINCE_DATE`) and an ISO 8601
#   form with colon-separated timezone offset (YYYY-MM-DDTHH:MM:SS±HH:MM —
#   for JSON comparisons against GitHub API timestamps).
#
#   All time calculations anchor to America/New_York so PM workflows stay
#   consistent across contributors in different timezones.
#
# USAGE:
#   gh-window.sh --days N [--format date|iso|both]
#   gh-window.sh --help
#
#   --days N          Required. Days to look back (positive integer).
#   --format FMT      Optional (default: both).
#                       date  → prints $SINCE_DATE only
#                       iso   → prints $SINCE_ISO only
#                       both  → prints "$SINCE_DATE\t$SINCE_ISO"
#
# OUTPUT:
#   Single stdout line. `both` prints two tab-separated values.
#
# EXIT CODES:
#   0   OK
#   2   Usage error (missing/invalid --days, unknown flag, bad format value)
#   3   The system `date` command could not compute the window on this platform
#
# EXAMPLES:
#   SINCE_DATE=$(bash .claude/scripts/gh-window.sh --days 14 --format date)
#   SINCE_ISO=$(bash .claude/scripts/gh-window.sh --days 14 --format iso)
#   # Or both at once:
#   IFS=$'\t' read -r SINCE_DATE SINCE_ISO < <(bash .claude/scripts/gh-window.sh --days 14)
#
# DEPENDENCIES:
#   - bash (any modern version)
#   - `date` — either BSD (macOS `date -v`) or GNU (`date -d`); the script
#     tries BSD first, falls back to GNU.
#   - `sed` — for the +HHMM → +HH:MM offset post-process.

set -u
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log"

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

err() {
  printf 'gh-window.sh: %s\n' "$1" >&2
}

DAYS=""
FORMAT="both"

while [ $# -gt 0 ]; do
  case "$1" in
    --days)
      shift
      if [ $# -eq 0 ]; then
        err "--days requires a value"
        exit 2
      fi
      DAYS="$1"
      ;;
    --days=*)
      DAYS="${1#--days=}"
      ;;
    --format)
      shift
      if [ $# -eq 0 ]; then
        err "--format requires a value"
        exit 2
      fi
      FORMAT="$1"
      ;;
    --format=*)
      FORMAT="${1#--format=}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "unknown argument: $1"
      exit 2
      ;;
  esac
  shift
done

if [ -z "$DAYS" ]; then
  err "missing required --days N"
  exit 2
fi

if ! printf '%s' "$DAYS" | grep -Eq '^[0-9]+$'; then
  err "--days must be a non-negative integer, got: $DAYS"
  exit 2
fi

case "$FORMAT" in
  date|iso|both) ;;
  *)
    err "--format must be one of: date, iso, both (got: $FORMAT)"
    exit 2
    ;;
esac

# Compute SINCE_DATE (date-only) — try BSD, fall back to GNU
SINCE_DATE=$(TZ='America/New_York' date -v-"${DAYS}"d '+%Y-%m-%d' 2>/dev/null \
  || TZ='America/New_York' date -d "$DAYS days ago" '+%Y-%m-%d' 2>/dev/null) || true

if [ -z "$SINCE_DATE" ]; then
  err "date command failed to compute SINCE_DATE"
  exit 3
fi

# Compute SINCE_ISO (ISO 8601 with timezone) — try BSD, fall back to GNU
SINCE_ISO=$(TZ='America/New_York' date -v-"${DAYS}"d '+%Y-%m-%dT00:00:00%z' 2>/dev/null \
  || TZ='America/New_York' date -d "$DAYS days ago" '+%Y-%m-%dT00:00:00%z' 2>/dev/null) || true

if [ -z "$SINCE_ISO" ]; then
  err "date command failed to compute SINCE_ISO"
  exit 3
fi

# GitHub search requires colon-separated offset (+HH:MM); `date` emits +HHMM
SINCE_ISO=$(printf '%s' "$SINCE_ISO" | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/')

case "$FORMAT" in
  date) printf '%s\n' "$SINCE_DATE" ;;
  iso)  printf '%s\n' "$SINCE_ISO" ;;
  both) printf '%s\t%s\n' "$SINCE_DATE" "$SINCE_ISO" ;;
esac
