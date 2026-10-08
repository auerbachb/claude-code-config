# shellcheck shell=bash
# desk/bin/lib/interrupts.sh — the operator's interrupt rule (issue #1783),
# shared by `interrupt` (which sets and reads it) and `tick --interrupts`
# (which holds new items back while it says so). Sourced after lib/common.sh
# and lib/db.sh; never executed. Bash 3.2 compatible.
#
# THE RULE
#   everything  every new Decision reaches the desk at the next tick, in sets
#               (the default: loud until the operator tunes it down)
#   away        nothing reaches the desk until the operator is back
#   focus       nothing reaches the desk until a time (at most a day ahead);
#               the first tick after it releases what was held
#
#   It lives under the reserved state key `interrupt` as JSON:
#     {"session": "<desk session>", "rule": "focus",
#      "until": "2026-10-07T19:30:00Z", "set_at": "2026-10-07T17:00:00Z"}
#   It belongs to the desk session that set it: a desk registered later reads
#   no rule of its own and starts from the default (desk/policy.json's
#   interrupt_rule, which the caller passes as :'hq_default').
#
# PUBLIC FUNCTIONS
#   hq_interrupt_rule_ok RULE   true for everything or away (a default)
#   hq_sql_interrupt_row        SQL query, one row (rule, until, held,
#                               source) for :'hq_session' with :'hq_default'
#   hq_sql_focus_until NOW      SQL scalar subquery: when a `focus until
#                               <clock time>` ends, from :'hq_times' in
#                               :'hq_tz', counted from NOW (an SQL timestamptz
#                               expression; statement_timestamp() in use)
#
# PSQL VARIABLES the SQL reads
#   hq_session  the desk session whose rule applies
#   hq_default  everything or away: the rule when that session set none
#   hq_tz       the desk's calendar (hq_desk_tz)
#   hq_times    candidate clock times, HH:MM, comma-separated

hq_interrupt_rule_ok() {
  case "$1" in
    everything|away) return 0 ;;
  esac
  return 1
}

# One row:
#   rule    everything | away | focus — the rule in force now. A focus whose
#           time has passed is over: the default is in force again.
#   until   the focus's end (timestamptz), else NULL
#   held    true while new items are held back (away, or a focus not over)
#   source  desk (this session set the rule in force) or policy (the default)
# A stored value that is not valid JSON, names another session, or holds an
# unknown rule reads as no rule at all, never as an error: a tick must not
# fail because of it. Every cast sits behind a CASE on pg_input_is_valid
# (PostgreSQL 16 or later), so the planner cannot evaluate it first (it may
# reorder plain AND-ed quals).
hq_sql_interrupt_row() {
  cat <<'SQL'
SELECT r.rule, r.until, r.rule IN ('away', 'focus') AS held, r.source
  FROM (
    SELECT CASE
             WHEN o.rule = 'focus' AND o.until > statement_timestamp() THEN 'focus'
             WHEN o.rule IN ('everything', 'away') THEN o.rule
             ELSE :'hq_default'
           END AS rule,
           CASE WHEN o.rule = 'focus' AND o.until > statement_timestamp() THEN o.until END AS until,
           CASE
             WHEN (o.rule = 'focus' AND o.until > statement_timestamp())
                  OR o.rule IN ('everything', 'away') THEN 'desk'
             ELSE 'policy'
           END AS source
      FROM (SELECT 1) one
      LEFT JOIN (
        SELECT CASE WHEN jsonb_typeof(s.v) = 'object' AND s.v->>'session' = :'hq_session'
                    THEN s.v->>'rule' END AS rule,
               CASE WHEN pg_input_is_valid(s.v->>'until', 'timestamptz')
                    THEN (s.v->>'until')::timestamptz END AS until
          FROM (SELECT CASE WHEN pg_input_is_valid(value, 'jsonb') THEN value::jsonb END AS v
                  FROM state WHERE key = 'interrupt') s
      ) o ON true
  ) r
SQL
}

# The first minute after NOW, within 24 hours, at which the clock in :'hq_tz'
# reaches one of :'hq_times'; NULL when none does. The window is `24 hours`,
# never `1 day`: a timestamptz plus a day keeps the wall clock of the
# session's TimeZone, so it would stretch or shrink with that zone's
# daylight-saving changes. It walks the window minute by minute (1,440 rows)
# rather than adding a day to a local time, because local
# arithmetic is wrong across a daylight-saving change: at 1:05 EDT on the
# night the clock falls back, `1:30` read as a local time is the later 1:30
# EST, an hour late, and on the night it springs forward `2:30` (a time that
# never shows) becomes 3:30 EDT. Walking it, a time the clock shows twice is
# its next showing, and one it skips is the minute the clock jumps past it.
hq_sql_focus_until() {
  local now="$1"
  printf '%s\n' \
    "(SELECT min(c.x)" \
    "   FROM (SELECT x," \
    "                x AT TIME ZONE :'hq_tz' AS cur," \
    "                (x - interval '1 minute') AT TIME ZONE :'hq_tz' AS prev" \
    "           FROM generate_series(date_trunc('minute', $now) + interval '1 minute'," \
    "                                $now + interval '24 hours'," \
    "                                interval '1 minute') AS x) c," \
    "        unnest(string_to_array(nullif(:'hq_times', ''), ',')) AS t" \
    "  WHERE c.cur = c.cur::date + t::time" \
    "     OR (c.prev < c.cur::date + t::time AND c.cur::date + t::time < c.cur))"
}
