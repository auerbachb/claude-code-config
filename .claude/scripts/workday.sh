#!/usr/bin/env bash
# workday.sh — US-business-day calculator (ET-anchored, macOS + GNU date).
#
# PURPOSE:
#   Compute US business days: detect holidays, decide whether a given date
#   is a workday, and walk backward to find the most recent prior workday.
#   "Non-workday" = weekend + US federal holidays + the day after
#   Thanksgiving (de facto holiday for most organizations).
#
#   All date math anchors to America/New_York so /standup and other PM
#   workflows produce consistent windows across contributors.
#
# USAGE:
#   workday.sh --last-workday
#       Print YYYY-MM-DD of the most recent prior workday (starting from
#       yesterday and walking back across weekends + holidays).
#
#   workday.sh --is-workday YYYY-MM-DD
#       Exit 0 if the date is a US workday, exit 1 if it is a weekend or
#       holiday. No stdout.
#
#   workday.sh --holidays-for-year YYYY
#       Print all observed holidays for the given year, one YYYY-MM-DD per
#       line, sorted ascending.
#
#   workday.sh -h|--help
#       Print this header and exit.
#
# EXIT CODES:
#   0   Success. For --is-workday: the date is a workday.
#   1   For --is-workday only: the date is NOT a workday.
#   2   Usage error (unknown flag, missing/invalid argument).
#   3   Runtime failure (system `date` command rejected an input).
#
# DEPENDENCIES:
#   - bash (any modern version)
#   - `date` — either BSD (macOS `date -v`) or GNU (`date -d`); both paths
#     are tried, matching the dual-syntax pattern used in gh-window.sh.
#   - `.claude/scripts/gh-window.sh` — used by --last-workday to seed
#     "yesterday" in an ET-anchored way.
#
# EXAMPLES:
#   LOOKBACK_DATE=$(bash .claude/scripts/workday.sh --last-workday)
#   bash .claude/scripts/workday.sh --is-workday 2026-11-26 || echo "holiday"
#   bash .claude/scripts/workday.sh --holidays-for-year 2026

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Date helpers (cross-platform: BSD on macOS, GNU on Linux)
# ──────────────────────────────────────────────────────────────────────────────
get_day_of_week() {
  # Returns 0=Sun 1=Mon ... 6=Sat for a YYYY-MM-DD date
  TZ='America/New_York' date -d "$1" '+%w' 2>/dev/null && return 0
  TZ='America/New_York' date -jf '%Y-%m-%d' "$1" '+%w' 2>/dev/null && return 0
  echo "Error: failed to parse date: $1" >&2
  return 3
}

subtract_days() {
  # subtract_days YYYY-MM-DD N → returns YYYY-MM-DD minus N days
  TZ='America/New_York' date -d "$1 - $2 days" '+%Y-%m-%d' 2>/dev/null && return 0
  TZ='America/New_York' date -jf '%Y-%m-%d' -v-"$2"d "$1" '+%Y-%m-%d' 2>/dev/null && return 0
  echo "Error: failed to subtract $2 days from: $1" >&2
  return 3
}

add_days() {
  # add_days YYYY-MM-DD N → returns YYYY-MM-DD plus N days
  TZ='America/New_York' date -d "$1 + $2 days" '+%Y-%m-%d' 2>/dev/null && return 0
  TZ='America/New_York' date -jf '%Y-%m-%d' -v+"$2"d "$1" '+%Y-%m-%d' 2>/dev/null && return 0
  echo "Error: failed to add $2 days to: $1" >&2
  return 3
}

days_in_month() {
  # days_in_month YYYY-MM → number of days in that month
  local ym=$1
  local y=${ym%-*} m=${ym#*-}
  m=$((10#$m))  # strip leading zero
  case $m in
    1|3|5|7|8|10|12) echo 31 ;;
    4|6|9|11) echo 30 ;;
    2) # leap year check
      if [ $((y % 400)) -eq 0 ] || { [ $((y % 4)) -eq 0 ] && [ $((y % 100)) -ne 0 ]; }; then
        echo 29
      else
        echo 28
      fi ;;
  esac
}

get_nth_weekday_of_month() {
  # get_nth_weekday_of_month N WEEKDAY YYYY-MM
  # N=occurrence (1-5), WEEKDAY=0-6 (Sun-Sat), YYYY-MM=year-month
  # Returns YYYY-MM-DD of the Nth occurrence of WEEKDAY in that month
  local n=$1 wd=$2 ym=$3
  local max_days
  max_days=$(days_in_month "$ym")
  local count=0 d=1
  while [ "$d" -le "$max_days" ]; do
    local candidate
    candidate="${ym}-$(printf '%02d' $d)"
    local dow
    dow=$(get_day_of_week "$candidate")
    if [ "$dow" -eq "$wd" ]; then
      count=$((count + 1))
      if [ "$count" -eq "$n" ]; then
        echo "$candidate"
        return
      fi
    fi
    d=$((d + 1))
  done
  return 1
}

get_last_weekday_of_month() {
  # get_last_weekday_of_month WEEKDAY YYYY-MM
  # Returns the last occurrence of WEEKDAY (0-6) in the given month
  local wd=$1 ym=$2
  local max_days
  max_days=$(days_in_month "$ym")
  local last=""
  local d=1
  while [ "$d" -le "$max_days" ]; do
    local candidate
    candidate="${ym}-$(printf '%02d' $d)"
    local dow
    dow=$(get_day_of_week "$candidate")
    if [ "$dow" -eq "$wd" ]; then
      last="$candidate"
    fi
    d=$((d + 1))
  done
  if [ -z "$last" ]; then
    return 1
  fi
  echo "$last"
}

apply_observed_rule() {
  # If a fixed holiday falls on Sat, observe on Fri. If Sun, observe on Mon.
  local date=$1
  local dow
  dow=$(get_day_of_week "$date")
  if [ "$dow" -eq 6 ]; then
    subtract_days "$date" 1   # Saturday → Friday
  elif [ "$dow" -eq 0 ]; then
    add_days "$date" 1        # Sunday → Monday
  else
    echo "$date"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Holiday computation
# ──────────────────────────────────────────────────────────────────────────────
compute_holidays_for_year() {
  local y=$1
  local holidays=""

  # Fixed-date holidays (with observed-date rules)
  holidays="$holidays $(apply_observed_rule "$y-01-01")"  # New Year's Day
  holidays="$holidays $(apply_observed_rule "$y-06-19")"  # Juneteenth
  holidays="$holidays $(apply_observed_rule "$y-07-04")"  # Independence Day
  holidays="$holidays $(apply_observed_rule "$y-11-11")"  # Veterans Day
  holidays="$holidays $(apply_observed_rule "$y-12-25")"  # Christmas Day

  # Floating holidays
  holidays="$holidays $(get_nth_weekday_of_month 3 1 "$y-01")"  # MLK Day: 3rd Mon Jan
  holidays="$holidays $(get_nth_weekday_of_month 3 1 "$y-02")"  # Presidents' Day: 3rd Mon Feb
  holidays="$holidays $(get_last_weekday_of_month 1 "$y-05")"   # Memorial Day: last Mon May
  holidays="$holidays $(get_nth_weekday_of_month 1 1 "$y-09")"  # Labor Day: 1st Mon Sep
  holidays="$holidays $(get_nth_weekday_of_month 2 1 "$y-10")"  # Columbus Day: 2nd Mon Oct

  local thanksgiving
  thanksgiving=$(get_nth_weekday_of_month 4 4 "$y-11")          # Thanksgiving: 4th Thu Nov
  holidays="$holidays $thanksgiving"

  # Day after Thanksgiving (Friday) — not a federal holiday, but a de facto
  # holiday for most organizations; included to avoid gaps in standup reporting
  local day_after
  day_after=$(add_days "$thanksgiving" 1)
  holidays="$holidays $day_after"

  echo "$holidays"
}

# Populate HOLIDAYS with the current and previous year so cross-year lookbacks
# (e.g., early January asking about late December) resolve correctly.
populate_holidays_window() {
  local current_year
  current_year=$(TZ='America/New_York' date '+%Y')
  local prev_year=$((current_year - 1))
  HOLIDAYS="$(compute_holidays_for_year "$current_year") $(compute_holidays_for_year "$prev_year")"
}

is_workday() {
  local date=$1
  local dow
  # Propagate runtime failure from get_day_of_week (exit 3) without collapsing
  # it to exit 1. Under `set -e`, callers like `while ! is_workday ...` and
  # `if is_workday ...; else ...; fi` run is_workday in a conditional context,
  # which suppresses `set -e` inside the function. So we must check and
  # propagate get_day_of_week's status explicitly here.
  if ! dow=$(get_day_of_week "$date"); then
    return 3
  fi
  # Weekend check: 0=Sun, 6=Sat
  [ "$dow" -eq 0 ] && return 1
  [ "$dow" -eq 6 ] && return 1
  # Holiday check
  case " $HOLIDAYS " in
    *" $date "*) return 1 ;;
  esac
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Subcommand implementations
# ──────────────────────────────────────────────────────────────────────────────
cmd_last_workday() {
  populate_holidays_window

  # Seed "yesterday" via the shared ET-anchored helper so this script stays
  # consistent with other PM workflows that use the same window builder.
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local candidate
  if ! candidate=$(bash "$script_dir/gh-window.sh" --days 1 --format date 2>/dev/null); then
    echo "Error: gh-window.sh failed to compute yesterday" >&2
    exit 3
  fi
  if [ -z "$candidate" ]; then
    echo "Error: gh-window.sh returned empty output" >&2
    exit 3
  fi

  # Defensive cap: the worst real-world gap (Thanksgiving + weekend, or
  # Christmas Eve through New Year across a weekend) is well under 10 days,
  # so 14 iterations is ample headroom. If we ever exhaust it, something is
  # wrong upstream (e.g., HOLIDAYS malformed) — fail loudly rather than hang.
  local attempts=0
  local status
  while true; do
    if is_workday "$candidate"; then
      break
    else
      # NOTE: $? must be captured INSIDE the else branch. After `fi`, $? is
      # the exit status of the if-statement itself (zero when no branch ran),
      # not the condition's exit status.
      status=$?
    fi
    # Exit 1 = "not a workday" → keep walking back. Any other non-zero status
    # (e.g., exit 3 = runtime failure from get_day_of_week) must propagate.
    if [ "$status" -ne 1 ]; then
      exit "$status"
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 14 ]; then
      echo "Error: no workday found within 14 days of seed; aborting" >&2
      exit 3
    fi
    candidate=$(subtract_days "$candidate" 1)
  done
  echo "$candidate"
}

cmd_is_workday() {
  local date=$1
  if ! [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "Error: --is-workday requires a YYYY-MM-DD date (got: $date)" >&2
    exit 2
  fi
  # Validate the date parses — rejects e.g. 2026-02-30.
  local verified
  verified=$(TZ='America/New_York' date -d "$date" '+%Y-%m-%d' 2>/dev/null \
    || TZ='America/New_York' date -jf '%Y-%m-%d' "$date" '+%Y-%m-%d' 2>/dev/null || true)
  if [ "$verified" != "$date" ]; then
    echo "Error: invalid calendar date: $date" >&2
    exit 2
  fi

  # Populate holidays for the date's year and the adjacent years so observed
  # rules that shift across year boundaries (Jan 1 on Sat → Dec 31 of prior
  # year; Dec 31 on Sun → Jan 1 of next year) still match.
  local year=${date%%-*}
  HOLIDAYS="$(compute_holidays_for_year "$year") \
$(compute_holidays_for_year "$((year - 1))") \
$(compute_holidays_for_year "$((year + 1))")"

  local status
  if is_workday "$date"; then
    exit 0
  else
    # NOTE: $? must be captured INSIDE the else branch. After `fi`, $? is the
    # exit status of the if-statement itself (zero when no branch ran), not
    # the condition's exit status.
    status=$?
  fi
  # Exit 1 = "not a workday" (contract). Exit 3 = runtime failure from
  # get_day_of_week; propagate directly rather than collapsing to 1.
  if [ "$status" -eq 1 ]; then
    exit 1
  fi
  exit "$status"
}

cmd_holidays_for_year() {
  local year=$1
  if ! [[ "$year" =~ ^[0-9]{4}$ ]]; then
    echo "Error: --holidays-for-year requires a 4-digit year (got: $year)" >&2
    exit 2
  fi
  # Gather the same 3-year window cmd_is_workday uses so observed-date rules
  # that shift a holiday across a year boundary (e.g., Jan 1 on Sat → Dec 31
  # of prior year) are listed under the year they actually fall in. Then
  # filter to dates whose YYYY prefix matches the requested year.
  {
    compute_holidays_for_year "$year"
    compute_holidays_for_year "$((year - 1))"
    compute_holidays_for_year "$((year + 1))"
  } | tr ' ' '\n' | sed '/^$/d' | grep -E "^${year}-" | sort -u
}

# ──────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
  echo "Error: no subcommand given. Run with --help for usage." >&2
  exit 2
fi

case "$1" in
  -h|--help)
    # Print the leading comment header (lines 2..first blank line), stripping
    # the leading `# `. Portable across BSD + GNU awk.
    awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"
    exit 0
    ;;
  --last-workday)
    if [[ $# -ne 1 ]]; then
      echo "Error: --last-workday takes no arguments" >&2
      exit 2
    fi
    cmd_last_workday
    ;;
  --is-workday)
    if [[ $# -ne 2 ]]; then
      echo "Error: --is-workday requires exactly one YYYY-MM-DD argument" >&2
      exit 2
    fi
    cmd_is_workday "$2"
    ;;
  --holidays-for-year)
    if [[ $# -ne 2 ]]; then
      echo "Error: --holidays-for-year requires exactly one YYYY argument" >&2
      exit 2
    fi
    cmd_holidays_for_year "$2"
    ;;
  *)
    echo "Error: unknown argument: $1" >&2
    echo "Run with --help for usage." >&2
    exit 2
    ;;
esac
