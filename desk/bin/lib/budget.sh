# shellcheck shell=bash
# desk/bin/lib/budget.sh — the reading budget's measurements (issue #1770):
# one day's throughput from `events` alone, the most recent measured day, and
# today's budget against what has been read. Sourced after lib/common.sh,
# never executed. Every query here is read-only; `checkin set` is the only
# writer, and it writes the `checkin` state key, never an event.
#
# WHAT IS MEASURED (the America/New_York calendar day)
#   reviewed   distinct Reviews (R-<n>) with a `reviewed` or `flagged` event
#              that day: a flag is a reading too (desk/skill/reviews.md)
#   answered   distinct Decisions (D-<n>) with an `answered` event that day
#   median_shown_to_answered_min
#              for each Decision answered that day (its first answer that
#              day), the minutes since that item's latest `shown` event at or
#              before it, on any day; the median of those, to one decimal.
#              answered_after_shown counts them (a Decision answered without
#              ever being shown in a set has no such time)
#   active_min the time at the desk, an estimate: the operator's actions that
#              day (answered, reviewed, flagged, feedback events), each
#              credited the minutes since the previous action when that gap
#              is at most HQ_BUDGET_BREAK_MIN, else HQ_BUDGET_FIRST_MIN (a
#              break, or the day's first action: one item's reading, the same
#              two minutes the day plan's clear-first batch allows a Review)
#   reviews_per_hour
#              reviewed / (active_min / 60), to one decimal
#   The kind of an item is its id's prefix, so nothing here joins `items`:
#   the numbers come from events alone.
#
# THE BUDGET (Reviews to read today; `checkin set` computes it once)
#   The measured day is the most recent of the HQ_BUDGET_LOOKBACK_DAYS before
#   today with at least HQ_BUDGET_MIN_READ Reviews read. Budget =
#   round(its reviews_per_hour × today's hours × the energy factor). With no
#   measured day (the first week), the starting guess:
#   round(HQ_BUDGET_GUESS_ITEMS × the energy factor), the "30 × 20" of
#   desk/DESIGN.md 2.8 (30 Reviews, 20 lines each at level 2). Zero hours is
#   a budget of zero.

HQ_BUDGET_GUESS_ITEMS=30
HQ_BUDGET_LINES_PER_ITEM=20
HQ_BUDGET_BREAK_MIN=15
HQ_BUDGET_FIRST_MIN=2
HQ_BUDGET_MIN_READ=3
HQ_BUDGET_LOOKBACK_DAYS=7
# One word of energy to the factor that scales the budget. The operator
# overrides any word, or adds one, with the plain state key energy_factors
# (`state set energy_factors '{"low": 0.6}'`): entries that are a lowercase
# word of up to 20 letters or hyphens and a number from 0 to 2 apply, others
# are ignored. A word in neither counts 1.
HQ_BUDGET_FACTORS='{"low": 0.7, "tired": 0.7, "ok": 1, "fine": 1, "normal": 1, "good": 1, "high": 1.2, "great": 1.2}'

# hq_budget_factors — the default factor table, the psql variable hq_factors
# that hq_sql_budget_factors reads.
hq_budget_factors() { printf '%s' "$HQ_BUDGET_FACTORS"; }

# hq_sql_budget_guess_json — the starting guess and the measured-day rule, as
# the `guess` object `checkin get --json` prints.
hq_sql_budget_guess_json() {
  printf "jsonb_build_object('items', %s, 'lines_per_item', %s, 'min_read', %s, 'lookback_days', %s)" \
    "$HQ_BUDGET_GUESS_ITEMS" "$HQ_BUDGET_LINES_PER_ITEM" "$HQ_BUDGET_MIN_READ" "$HQ_BUDGET_LOOKBACK_DAYS"
}

# hq_budget_check_day LABEL VALUE — exits 4 unless VALUE is YYYY-MM-DD and a
# real calendar date.
hq_budget_check_day() {
  local label="$1" v="$2" y mo d dim
  if ! [[ $v =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
    hq_die_validation "$label must be YYYY-MM-DD, for example 2026-10-07"
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
    hq_die_validation "$label is not a real calendar date"
  fi
}

# hq_sql_budget_stats — CTEs measuring every day in a preceding CTE
# hqb_days(day date), ending in hqb_st(day, reviewed, answered, median_min,
# answered_shown, actions, active_exact). No leading WITH, no trailing comma.
# Needs the psql variable hq_tz. Names carry an hqb_ prefix so a caller's own
# CTEs never collide with them.
hq_sql_budget_stats() {
  cat <<SQL
hqb_ev AS (
  SELECT e.id, e.item_id, e.kind, e.at, (e.at AT TIME ZONE :'hq_tz')::date AS day
    FROM events e
   WHERE e.kind IN ('answered', 'reviewed', 'flagged', 'feedback')
     AND e.at >= ((SELECT min(d.day) FROM hqb_days d)::timestamp AT TIME ZONE :'hq_tz')
     AND e.at < (((SELECT max(d.day) FROM hqb_days d) + 1)::timestamp AT TIME ZONE :'hq_tz')
),
hqb_act AS (
  SELECT ev.day,
         extract(epoch FROM ev.at - lag(ev.at) OVER (PARTITION BY ev.day ORDER BY ev.at, ev.id)) / 60.0 AS gap
    FROM hqb_ev ev
),
hqb_ans AS (
  SELECT DISTINCT ON (ev.day, ev.item_id) ev.day, ev.item_id, ev.at
    FROM hqb_ev ev
   WHERE ev.kind = 'answered' AND ev.item_id LIKE 'D-%'
   ORDER BY ev.day, ev.item_id, ev.at, ev.id
),
hqb_lat AS (
  SELECT a.day, extract(epoch FROM a.at - s.at) / 60.0 AS m
    FROM hqb_ans a
    CROSS JOIN LATERAL (SELECT max(e.at) AS at FROM events e
                         WHERE e.item_id = a.item_id AND e.kind = 'shown' AND e.at <= a.at) s
   WHERE s.at IS NOT NULL
),
hqb_st AS (
  SELECT d.day,
         (SELECT count(DISTINCT ev.item_id) FROM hqb_ev ev
           WHERE ev.day = d.day AND ev.kind IN ('reviewed', 'flagged') AND ev.item_id LIKE 'R-%') AS reviewed,
         (SELECT count(*) FROM hqb_ans a WHERE a.day = d.day) AS answered,
         (SELECT round((percentile_cont(0.5) WITHIN GROUP (ORDER BY l.m))::numeric, 1)
            FROM hqb_lat l WHERE l.day = d.day) AS median_min,
         (SELECT count(*) FROM hqb_lat l WHERE l.day = d.day) AS answered_shown,
         (SELECT count(*) FROM hqb_ev ev WHERE ev.day = d.day) AS actions,
         coalesce((SELECT sum(CASE WHEN a.gap IS NOT NULL AND a.gap <= $HQ_BUDGET_BREAK_MIN THEN a.gap
                                   ELSE $HQ_BUDGET_FIRST_MIN END)
                     FROM hqb_act a WHERE a.day = d.day), 0) AS active_exact
    FROM hqb_days d
)
SQL
}

# hq_sql_budget_stats_json ALIAS — one hqb_st row (named ALIAS in the FROM)
# as the `stats --json` object.
hq_sql_budget_stats_json() {
  local a="$1"
  printf "jsonb_build_object('day', to_char(%s.day, 'YYYY-MM-DD'), 'reviewed', %s.reviewed, 'answered', %s.answered,\n" "$a" "$a" "$a"
  printf "  'median_shown_to_answered_min', %s.median_min, 'answered_after_shown', %s.answered_shown,\n" "$a" "$a"
  printf "  'active_min', round(%s.active_exact)::int, 'actions', %s.actions,\n" "$a" "$a"
  printf "  'reviews_per_hour', CASE WHEN %s.active_exact > 0 THEN round(%s.reviewed * 60.0 / %s.active_exact, 1) END)" "$a" "$a" "$a"
}

# hq_sql_budget_today — CTEs for today's budget, with no leading WITH and no
# trailing comma: hqb_t(today), hqb_days (today and the lookback days before
# it), the stats above, hqb_m (the measured day, at most one row), hqb_td
# (today's row), and hqb_c(v) (today's stored check-in, or NULL: a check-in
# stored on another day, or not a JSON object, is not today's). Needs hq_tz.
hq_sql_budget_today() {
  cat <<SQL
hqb_t AS (
  SELECT (statement_timestamp() AT TIME ZONE :'hq_tz')::date AS today
),
hqb_days AS (
  SELECT (t.today - g)::date AS day FROM hqb_t t, generate_series(0, $HQ_BUDGET_LOOKBACK_DAYS) g
),
SQL
  hq_sql_budget_stats
  cat <<SQL
,
hqb_m AS (
  SELECT s.* FROM hqb_st s, hqb_t t
   WHERE s.day < t.today AND s.reviewed >= $HQ_BUDGET_MIN_READ AND s.active_exact > 0
   ORDER BY s.day DESC
   LIMIT 1
),
hqb_td AS (
  SELECT s.* FROM hqb_st s, hqb_t t WHERE s.day = t.today
),
hqb_c AS (
  SELECT (SELECT CASE WHEN jsonb_typeof(s.v) = 'object' AND s.v->>'day' = to_char(t.today, 'YYYY-MM-DD')
                      THEN s.v END
            FROM (SELECT CASE WHEN pg_input_is_valid(value, 'jsonb') THEN value::jsonb END AS v
                    FROM state WHERE key = 'checkin') s) AS v
    FROM hqb_t t
)
SQL
}

# hq_sql_budget_fields — the key/value pairs today's running count adds to a
# jsonb_build_object (after hq_sql_budget_today): read_today (Reviews read
# today), budget (today's check-in's, else null), and left (budget less
# read_today; negative once over; null without a check-in). No trailing comma.
hq_sql_budget_fields() {
  cat <<'SQL'
'read_today', coalesce((SELECT td.reviewed FROM hqb_td td), 0),
'budget', (SELECT CASE WHEN jsonb_typeof(c.v->'budget') = 'number' THEN (c.v->>'budget')::numeric END FROM hqb_c c),
'left', (SELECT CASE WHEN jsonb_typeof(c.v->'budget') = 'number'
                     THEN (c.v->>'budget')::numeric - coalesce((SELECT td.reviewed FROM hqb_td td), 0) END
           FROM hqb_c c)
SQL
}

# hq_sql_budget_factors — CTEs hqb_fo and hqb_fx(t): the energy factor table,
# the defaults (psql variable hq_factors, HQ_BUDGET_FACTORS) with the
# operator's valid overrides from the state key energy_factors on top. No
# leading WITH, no trailing comma.
hq_sql_budget_factors() {
  cat <<'SQL'
hqb_fo AS (
  SELECT CASE WHEN pg_input_is_valid(value, 'jsonb') AND jsonb_typeof(value::jsonb) = 'object'
              THEN value::jsonb END AS o
    FROM state WHERE key = 'energy_factors'
),
hqb_fx AS (
  SELECT :'hq_factors'::jsonb
         || coalesce((SELECT jsonb_object_agg(x.k, x.v)
                        FROM hqb_fo fo, jsonb_each(fo.o) x(k, v)
                       WHERE x.k ~ '^[a-z][a-z-]{0,19}$'
                         AND CASE WHEN jsonb_typeof(x.v) = 'number' THEN (x.v)::numeric BETWEEN 0 AND 2
                                  ELSE false END), '{}'::jsonb) AS t
)
SQL
}
