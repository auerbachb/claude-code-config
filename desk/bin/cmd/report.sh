# shellcheck shell=bash
# summary: the weekly attention report: what the queue cost the operator, from the events table
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"
# shellcheck source=../lib/github.sh
. "$HQ_BIN_DIR/lib/github.sh"
# shellcheck source=../lib/report.sh
. "$HQ_BIN_DIR/lib/report.sh"

# Sittings: a gap longer than this many minutes between two desk events
# starts a new one, and each sitting adds this floor for its last action.
HQ_REPORT_GAP_MIN=10
HQ_REPORT_FLOOR_MIN=1

cmd_usage() {
  cat <<'EOF'
human-queue.sh report — the weekly attention report (issue #1771).

USAGE
  human-queue.sh report [--week YYYY-MM-DD] [--json]

ARGUMENTS
  --week YYYY-MM-DD  any day of the week to report (a real calendar date).
                     A week runs Monday to Sunday on the America/New_York
                     calendar. Default: this week, on the store's clock.
  --json             print the measures as one JSON object instead

MEASURES
  Computed from the events table alone, which logs state changes only: the
  report adds no logging and records nothing. A desk event is `shown` or one
  of the operator's own actions (`answered`, `reviewed`, `flagged`,
  `feedback`, `commented`).
  1. Minutes spent answering: the week's desk events in time order, split
     into sittings wherever two are more than 10 minutes apart. A sitting
     with at least one operator action counts from its first event to its
     last, plus 1 minute; one with only `shown` events counts nothing.
  2. Items per day: the items with an `answered`, `reviewed`, or `flagged`
     event on each day, once per day; the average is over desk days (days
     with an operator action), and each day of the week so far is listed.
  3. Median age of an open Decision: over every Decision open at some time
     in the week (asked before it ended, not answered before it began), the
     time from its `asked` event to its first `answered` event, or, when it
     was still open at the week's end, to that end (or now, if sooner). A
     week that has not started yet has none.
  4. Interrupts tagged not important: items tagged `not-important` that
     week, beside the number of Decisions shown that week.
  5. Questions tagged should have defaulted: items tagged
     `should-have-defaulted` that week, by thread and model, in a small
     table that also counts each thread's `not-important` and
     `good-interrupt` tags and the Decisions it asked that week. The thread
     is the feedback event's session (migration 008); the model is the one
     that thread's latest reply ran on, read from its Claude Code transcript
     on this machine when the report runs (`unknown` when the thread ran
     elsewhere). At most 10 threads are printed; --json lists every one.
     A Decision asked that week counts for the thread that is its return
     address when the report runs: an `asked` event names no session, so
     one another thread has since bumped counts for that thread.

OUTPUT
  Markdown, one page: a bold title naming the week, the five measures as a
  numbered list, and the table of tagged threads (or one line saying no
  thread was tagged). --json: {"week": {"start", "end", "tz"}, "today",
  "minutes": {"total", "sittings"}, "days": [{"day", "dow", "handled",
  "decisions", "reviews", "asked", "minutes", "desk"}], "handled":
  {"total", "desk_days", "per_desk_day"}, "open_age": {"decisions",
  "still_open", "median_minutes"}, "not_important": {"tagged", "shown"},
  "should_have_defaulted": {"tagged"}, "threads": [{"session", "model",
  "asked", "should_have_defaulted", "not_important", "good_interrupt"}]}.
  Nothing on stderr on success.

ENVIRONMENT
  HUMAN_QUEUE_TRANSCRIPTS_DIR  where Claude Code keeps transcripts, read
                               for thread models (default ~/.claude/projects)

EXIT CODES
  0  ok (including a week with nothing in it)
  1  unexpected database failure, a store not migrated to 008 (run
     human-queue.sh migrate), or jq is missing
  4  a bad --week or a stray argument (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# hq__report_check_date VALUE — exits 4 unless VALUE is YYYY-MM-DD and a real
# calendar date.
hq__report_check_date() {
  local v="$1" y mo d dim
  if ! [[ $v =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
    hq_die_validation "report: --week must be a date YYYY-MM-DD, for example 2026-10-05"
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
    hq_die_validation "report: --week is not a real calendar date"
  fi
}

# hq__report_sql — one read-only statement returning the report as JSON.
#   p       the week: its Monday, its bounds as instants, today
#   ev      the week's events
#   sit     sittings (see MEASURES 1); a gap test needs the previous event,
#           and (at, id) orders ties the same way in both windows
#   op      Decisions open at some time in the week, with their ages
#   tg      the week's interrupt tags
hq__report_sql() {
  cat <<'SQL'
WITH p AS (
  SELECT w.monday, w.today,
         w.monday::timestamp AT TIME ZONE :'hq_tz' AS ws,
         (w.monday + 7)::timestamp AT TIME ZONE :'hq_tz' AS we
    FROM (SELECT d.day - (extract(isodow FROM d.day)::int - 1) AS monday, d.today
            FROM (SELECT coalesce(nullif(:'hq_date', '')::date, t.today) AS day, t.today
                    FROM (SELECT (statement_timestamp() AT TIME ZONE :'hq_tz')::date AS today) t) d) w
), ev AS (
  SELECT e.id, e.item_id, e.kind, e.at, e.note, e.session_id,
         (e.at AT TIME ZONE :'hq_tz')::date AS day
    FROM events e, p
   WHERE e.at >= p.ws AND e.at < p.we
), att AS (
  SELECT e.id, e.at, e.kind <> 'shown' AS act,
         CASE WHEN lag(e.at) OVER (ORDER BY e.at, e.id) IS NULL
                OR e.at - lag(e.at) OVER (ORDER BY e.at, e.id) > make_interval(mins => :'hq_gap'::int)
              THEN 1 ELSE 0 END AS brk
    FROM ev e
   WHERE e.kind IN ('shown', 'answered', 'reviewed', 'flagged', 'feedback', 'commented')
), sit AS (
  SELECT (min(s.at) AT TIME ZONE :'hq_tz')::date AS day,
         extract(epoch FROM max(s.at) - min(s.at)) / 60 + :'hq_floor'::numeric AS minutes
    FROM (SELECT a.at, a.act, sum(a.brk) OVER (ORDER BY a.at, a.id) AS sid FROM att a) s
   GROUP BY s.sid
  HAVING bool_or(s.act)
), days AS (
  SELECT g::date AS day
    FROM p, generate_series(p.monday::timestamp, (p.monday + 6)::timestamp, interval '1 day') g
   WHERE g::date <= p.today
), handled AS (
  SELECT day, count(DISTINCT item_id) AS n,
         count(DISTINCT item_id) FILTER (WHERE kind = 'answered') AS decisions,
         count(DISTINCT item_id) FILTER (WHERE kind IN ('reviewed', 'flagged')) AS reviews
    FROM ev WHERE kind IN ('answered', 'reviewed', 'flagged')
   GROUP BY day
), asked AS (
  SELECT day, count(DISTINCT item_id) AS n
    FROM ev WHERE kind = 'asked' AND item_id LIKE 'D-%'
   GROUP BY day
), active AS (
  SELECT DISTINCT day FROM ev
   WHERE kind IN ('answered', 'reviewed', 'flagged', 'feedback', 'commented')
), mins AS (
  SELECT day, sum(minutes) AS m FROM sit GROUP BY day
), dec AS (
  SELECT coalesce(a.asked_at, i.created_at) AS asked_at, a.answered_at
    FROM items i
    CROSS JOIN LATERAL (
      SELECT min(e.at) FILTER (WHERE e.kind = 'asked') AS asked_at,
             min(e.at) FILTER (WHERE e.kind = 'answered') AS answered_at
        FROM events e WHERE e.item_id = i.id
    ) a
   WHERE i.kind = 'decision' AND i.created_at < (SELECT we FROM p)
), op AS (
  SELECT greatest(extract(epoch FROM least(coalesce(d.answered_at, 'infinity'::timestamptz),
                                           p.we, statement_timestamp()) - d.asked_at), 0) / 60 AS age,
         d.answered_at IS NULL OR d.answered_at >= p.we AS still_open
    FROM dec d, p
   WHERE p.ws <= statement_timestamp()
     AND d.asked_at < p.we
     AND (d.answered_at IS NULL OR d.answered_at >= p.ws)
), tg AS (
  SELECT item_id, note AS tag, session_id FROM ev
   WHERE kind = 'feedback' AND note IN ('not-important', 'should-have-defaulted', 'good-interrupt')
), th AS (
  SELECT session_id,
         count(DISTINCT item_id) FILTER (WHERE tag = 'should-have-defaulted') AS shd,
         count(DISTINCT item_id) FILTER (WHERE tag = 'not-important') AS ni,
         count(DISTINCT item_id) FILTER (WHERE tag = 'good-interrupt') AS gi
    FROM tg GROUP BY session_id
), asked_by AS (
  SELECT i.session_id, count(DISTINCT i.id) AS n
    FROM ev JOIN items i ON i.id = ev.item_id
   WHERE ev.kind = 'asked' AND i.kind = 'decision' AND i.session_id IS NOT NULL
   GROUP BY i.session_id
)
SELECT jsonb_build_object(
  'week', jsonb_build_object('start', to_char(p.monday, 'YYYY-MM-DD'),
                             'end', to_char(p.monday + 6, 'YYYY-MM-DD'),
                             'tz', :'hq_tz'),
  'today', to_char(p.today, 'YYYY-MM-DD'),
  'minutes', jsonb_build_object(
    'total', (SELECT coalesce(round(sum(minutes)), 0)::int FROM sit),
    'sittings', (SELECT count(*) FROM sit)),
  'days', coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'day', to_char(d.day, 'YYYY-MM-DD'), 'dow', to_char(d.day, 'Dy'),
             'handled', coalesce(h.n, 0), 'decisions', coalesce(h.decisions, 0),
             'reviews', coalesce(h.reviews, 0), 'asked', coalesce(a.n, 0),
             'minutes', coalesce(round(m.m), 0)::int,
             'desk', d.day IN (SELECT day FROM active)) ORDER BY d.day)
      FROM days d
      LEFT JOIN handled h USING (day)
      LEFT JOIN asked a USING (day)
      LEFT JOIN mins m USING (day)), '[]'::jsonb),
  'handled', (SELECT jsonb_build_object(
                'total', x.total, 'desk_days', x.desk_days,
                'per_desk_day', CASE WHEN x.desk_days > 0 THEN round(x.total::numeric / x.desk_days, 1) ELSE 0 END)
                FROM (SELECT (SELECT coalesce(sum(n), 0)::int FROM handled) AS total,
                             (SELECT count(*)::int FROM active) AS desk_days) x),
  'open_age', jsonb_build_object(
    'decisions', (SELECT count(*) FROM op),
    'still_open', (SELECT count(*) FILTER (WHERE still_open) FROM op),
    'median_minutes', (SELECT round((percentile_cont(0.5) WITHIN GROUP (ORDER BY age::float8))::numeric)::int FROM op)),
  'not_important', jsonb_build_object(
    'tagged', (SELECT count(DISTINCT item_id) FILTER (WHERE tag = 'not-important') FROM tg),
    'shown', (SELECT count(DISTINCT item_id) FROM ev WHERE kind = 'shown' AND item_id LIKE 'D-%')),
  'should_have_defaulted', jsonb_build_object(
    'tagged', (SELECT count(DISTINCT item_id) FILTER (WHERE tag = 'should-have-defaulted') FROM tg)),
  'threads', coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'session', t.session_id,
             'asked', CASE WHEN t.session_id IS NULL THEN NULL ELSE coalesce(b.n, 0) END,
             'should_have_defaulted', t.shd, 'not_important', t.ni, 'good_interrupt', t.gi)
             ORDER BY t.shd DESC, t.ni DESC, t.gi DESC, t.session_id NULLS LAST)
      FROM th t LEFT JOIN asked_by b ON b.session_id = t.session_id), '[]'::jsonb))
  FROM p;
SQL
}

cmd_run() {
  local json=0 week="" have_week=0 errf out rc sessions sid model models="" sep
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
      --week)
        if [ "$have_week" -eq 1 ]; then hq_die_validation "report: --week given more than once"; fi
        if [ "$#" -lt 2 ]; then hq_die_validation "report: --week needs a value (YYYY-MM-DD)"; fi
        have_week=1
        week="$2"
        shift 2
        ;;
      -*) hq_die_validation "report: unknown $(hq_flag_name "$1") (run human-queue.sh report --help)" ;;
      *) hq_die_validation "report: takes no arguments besides its options (run human-queue.sh report --help)" ;;
    esac
  done
  if [ "$have_week" -eq 1 ]; then
    hq__report_check_date "$week"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__report_sql | hq_db_script -At -v "hq_date=$week" -v "hq_tz=$(hq_desk_tz)" \
          -v "hq_gap=$HQ_REPORT_GAP_MIN" -v "hq_floor=$HQ_REPORT_FLOOR_MIN" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_fail_unmigrated "$rc" "$errf" "report" 'session_id'
  fi
  if [ -z "$out" ]; then
    hq_die_error "report: the store returned nothing"
  fi
  hq_jq_find || hq_die_error "report: jq not found (PATH, /opt/homebrew/bin/jq, or /usr/bin/jq)"

  # Each tagged thread's model, as `session<US>model` lines: a unit separator
  # can never sit inside either.
  sep=$(printf '\037')
  sessions=$(printf '%s' "$out" | hq_jq -r '.threads[] | .session | strings') \
    || hq_die_error "report: the store returned malformed JSON"
  while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    hq_thread_model model "$sid"
    models="$models$sid$sep$model
"
  done <<EOF
$sessions
EOF
  out=$(printf '%s' "$models" | hq_jq -R -s -c --argjson r "$out" '
          (split("\n") | map(select(length > 0) | split("\u001f") | {(.[0]): .[1]}) | add // {}) as $m
          | $r | .threads |= map(.model = (if .session == null then null else ($m[.session] // "unknown") end))') \
    || hq_die_error "report: could not attach the thread models"

  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$out"
  else
    hq_report_render "$out" || hq_die_error "report: could not render the report"
  fi
}
