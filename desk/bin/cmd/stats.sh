# shellcheck shell=bash
# summary: one day's throughput from events alone: Reviews read, Decisions answered, shown-to-answered median
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/budget.sh
. "$HQ_BIN_DIR/lib/budget.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh stats — one day's throughput, from events alone (issue #1770).

USAGE
  human-queue.sh stats [--day YYYY-MM-DD] [--json]

ARGUMENTS
  --day YYYY-MM-DD  the America/New_York calendar day to measure (a real
                    date). Default: today on the database's clock.
  --json            print one JSON object instead of a line

WHAT IT COUNTS
  Only the events table is read (an item's kind is its id's prefix):
  reviewed      distinct Reviews (R-<n>) with a `reviewed` or `flagged`
                event that day (a flag is a reading too)
  answered      distinct Decisions (D-<n>) with an `answered` event that day
  median_shown_to_answered_min
                for each Decision answered that day (its first answer that
                day), the minutes since its latest `shown` event at or before
                that answer (on any day); the median, to one decimal. null
                when none was shown first. answered_after_shown counts them
  active_min    the time at the desk, an estimate: the operator's actions
                that day (answered, reviewed, flagged, feedback), each
                credited the minutes since the previous one when that gap is
                at most 15, else 2 (a break, or the day's first action)
  actions       how many such actions there were
  reviews_per_hour
                reviewed / (active_min / 60), to one decimal; null with no
                action that day
  The morning check-in reads the same numbers to set the reading budget
  (`checkin --help`). Read-only: records nothing.

OUTPUT
  One line:
    2026-10-07 · 7 Reviews read · 5 Decisions answered · median 12.0 min
    from shown to answered (4) · about 60 min at the desk · 7.0 Reviews an hour
  --json:
    {"day": "2026-10-07", "reviewed": 7, "answered": 5,
     "median_shown_to_answered_min": 12.0, "answered_after_shown": 4,
     "active_min": 60, "actions": 12, "reviews_per_hour": 7.0}
  Nothing on stderr on success.

EXIT CODES
  0  ok (including a day with no events)
  1  unexpected database failure
  4  a bad --day or a stray argument (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

hq__stats_sql() {
  cat <<'SQL'
WITH hqb_days AS (
  SELECT coalesce(nullif(:'hq_day', '')::date, (statement_timestamp() AT TIME ZONE :'hq_tz')::date) AS day
),
SQL
  hq_sql_budget_stats
  if [ "$1" -eq 1 ]; then
    printf 'SELECT %s\n  FROM hqb_st s;\n' "$(hq_sql_budget_stats_json s)"
    return 0
  fi
  cat <<'SQL'
SELECT concat_ws(' · ',
         to_char(s.day, 'YYYY-MM-DD'),
         s.reviewed || CASE WHEN s.reviewed = 1 THEN ' Review read' ELSE ' Reviews read' END,
         s.answered || CASE WHEN s.answered = 1 THEN ' Decision answered' ELSE ' Decisions answered' END,
         CASE WHEN s.median_min IS NULL THEN 'no shown-to-answered time'
              ELSE 'median ' || s.median_min || ' min from shown to answered (' || s.answered_shown || ')' END,
         'about ' || round(s.active_exact) || ' min at the desk',
         CASE WHEN s.active_exact > 0 THEN round(s.reviewed * 60.0 / s.active_exact, 1) || ' Reviews an hour' END)
  FROM hqb_st s;
SQL
}

cmd_run() {
  local json=0 day="" have_day=0 errf out rc

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --json)
        json=1
        shift
        ;;
      --day)
        if [ "$have_day" -eq 1 ]; then hq_die_validation "stats: --day given more than once"; fi
        if [ "$#" -lt 2 ]; then hq_die_validation "stats: --day needs a value (YYYY-MM-DD)"; fi
        have_day=1
        day="$2"
        shift 2
        ;;
      -*) hq_die_validation "stats: unknown $(hq_flag_name "$1") (run human-queue.sh stats --help)" ;;
      *) hq_die_validation "stats: takes no arguments besides its options (run human-queue.sh stats --help)" ;;
    esac
  done
  if [ "$have_day" -eq 1 ]; then
    hq_budget_check_day "stats: --day" "$day"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__stats_sql "$json" | hq_db_script -At -v "hq_day=$day" -v "hq_tz=$(hq_desk_tz)" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "stats"
  fi
  if [ -z "$out" ]; then
    hq_die_error "stats: the store returned nothing"
  fi
  printf '%s\n' "$out"
}
