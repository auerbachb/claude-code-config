# shellcheck shell=bash
# summary: list the Decisions answered on one day (default today, America/New_York)
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"

# The operator's calendar: the desk's day, like the repo's other calendar
# helpers, is the America/New_York day (issue #1781).
HQ_HISTORY_TZ="America/New_York"

cmd_usage() {
  cat <<'EOF'
human-queue.sh history — the Decisions answered on one day.

USAGE
  human-queue.sh history [--date YYYY-MM-DD] [--json]

ARGUMENTS
  --date YYYY-MM-DD  the day to list (a real calendar date). Default: today
                     on the database's clock.
  --json             print one JSON array of item objects instead ([] when
                     none), each with one more field, answered_at: the time
                     of its latest answer that day

BEHAVIOR
  Lists every Decision with an `answered` event on that America/New_York
  calendar day, whatever its status now (answered, acknowledged,
  answer-parked, or answered again later). An item answered more than once
  that day is listed once, at its latest answer that day; items come in the
  order of those answers, earliest first. Read-only: records nothing.

OUTPUT
  One block per item, separated by blank lines; nothing at all when none:

    D-43 · answered 14:02 ET · acknowledged · owner/repo · issue-901
    **The question, in bold?**
    Answer: the answer as stored

EXIT CODES
  0  ok (including when nothing was answered)
  1  unexpected database failure
  4  a bad --date or a stray argument (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# hq__history_check_date VALUE — exits 4 unless VALUE is YYYY-MM-DD and a real
# calendar date.
hq__history_check_date() {
  local v="$1" y mo d dim
  if ! [[ $v =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
    hq_die_validation "history: --date must be YYYY-MM-DD, for example 2026-10-07"
  fi
  y=$((10#${BASH_REMATCH[1]}))
  mo=$((10#${BASH_REMATCH[2]}))
  d=$((10#${BASH_REMATCH[3]}))
  case "$mo" in
    2)
      dim=28
      if [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; }; then
        dim=29
      fi
      ;;
    4|6|9|11) dim=30 ;;
    *) dim=31 ;;
  esac
  if [ "$y" -lt 1 ] || [ "$mo" -lt 1 ] || [ "$mo" -gt 12 ] || [ "$d" -lt 1 ] || [ "$d" -gt "$dim" ]; then
    hq_die_validation "history: --date is not a real calendar date"
  fi
}

# hq__history_sql JSON — the day's latest answer per Decision, then the items,
# ordered by that answer's time (an event's id need not follow its time: a
# transaction stamps `at` when it starts), the latest event id breaking ties.
hq__history_sql() {
  cat <<'SQL'
WITH d AS (
  SELECT coalesce(nullif(:'hq_date', '')::date,
                  (statement_timestamp() AT TIME ZONE :'hq_tz')::date) AS day
), h AS (
  SELECT e.item_id, max(e.at) AS answered_at, max(e.id) AS last_id
    FROM events e CROSS JOIN d
   WHERE e.kind = 'answered'
     AND (e.at AT TIME ZONE :'hq_tz')::date = d.day
   GROUP BY e.item_id
)
SQL
  if [ "$1" -eq 1 ]; then
    printf "SELECT coalesce(jsonb_agg(%s || jsonb_build_object('answered_at', h.answered_at)\n" "$(hq_sql_item_json)"
    cat <<'SQL'
                          ORDER BY h.answered_at, h.last_id), '[]'::jsonb)
  FROM h JOIN items i ON i.id = h.item_id
 WHERE i.kind = 'decision';
SQL
  else
    cat <<'SQL'
SELECT string_agg(concat_ws(E'\n',
         concat_ws(' · ', i.id,
                   'answered ' || to_char(h.answered_at AT TIME ZONE :'hq_tz', 'HH24:MI') || ' ET',
                   i.status, i.repo, i.key),
         '**' || i.question || '**',
         'Answer: ' || i.answer),
       E'\n\n' ORDER BY h.answered_at, h.last_id)
  FROM h JOIN items i ON i.id = h.item_id
 WHERE i.kind = 'decision'
HAVING count(*) > 0;
SQL
  fi
}

cmd_run() {
  local json=0 date="" have_date=0 errf out rc

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
      --date)
        if [ "$have_date" -eq 1 ]; then hq_die_validation "history: --date given more than once"; fi
        if [ "$#" -lt 2 ]; then hq_die_validation "history: --date needs a value (YYYY-MM-DD)"; fi
        have_date=1
        date="$2"
        shift 2
        ;;
      -*) hq_die_validation "history: unknown $(hq_flag_name "$1") (run human-queue.sh history --help)" ;;
      *) hq_die_validation "history: takes no arguments besides its options (run human-queue.sh history --help)" ;;
    esac
  done
  if [ "$have_date" -eq 1 ]; then
    hq__history_check_date "$date"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__history_sql "$json" | hq_db_script -At -v "hq_date=$date" -v "hq_tz=$HQ_HISTORY_TZ" \
    2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "history"
  fi
  if [ "$json" -eq 1 ] && [ -z "$out" ]; then
    hq_die_error "history: the store returned nothing"
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
}
