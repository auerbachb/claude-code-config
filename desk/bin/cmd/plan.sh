# shellcheck shell=bash
# summary: the operator's day plan: store, read, or clear it, and forecast incoming questions
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"
# shellcheck source=../lib/budget.sh
. "$HQ_BIN_DIR/lib/budget.sh"

# The plan travels to psql as one argument (-v hq_plan=...), far under the
# 128 KiB a single argument may take.
HQ_PLAN_MAX_BYTES=16384
HQ_PLAN_WINDOW_DEFAULT=180

cmd_usage() {
  cat <<'EOF'
human-queue.sh plan — the operator's day plan (issue #1784).

USAGE
  human-queue.sh plan get [--json]
  human-queue.sh plan set --session SESSION [--json]      (the plan on stdin)
  human-queue.sh plan clear --session SESSION [--json]
  human-queue.sh plan forecast [--window MINUTES] [--json]

THE PLAN
  What the operator agreed with the desk for today: what they work on, at
  what pace, until when, and what to clear first. `set` reads it as one JSON
  object on stdin (the desk builds it with desk/skill/desk.jq's plan_record):
    {"item": "the PRD", "pace": "30 min a section",
     "inputs": {...the dialogue's parsed fields...},
     "clear_first": ["D-41", "R-7"], "later": ["D-45"],
     "blocks": [{"item": "the PRD", "label": "section 1 of 4",
                 "pace": "30 min a section",
                 "start": "2026-10-08T13:10:00Z", "until": "2026-10-08T13:40:00Z"}]}
  blocks     1 to 24, in order and not overlapping; each has an item and a
             pace (1 to 200 characters, one line, no control characters), an
             optional label, and a start before its until (ISO 8601 with a
             zone, at most a day long). The last block ends after now and
             within a day of it.
  clear_first, later
             optional; at most 99 item ids each (D-<n> or R-<n>)
  inputs     optional object, stored as given
  item, pace optional; default to the first block's
  The store adds version, day (the America/New_York calendar day on the
  store's clock), session, and set_at, and keeps only the fields above.

WHAT A PLAN DOES
  While a block is in force (start <= now < until), the desk's interrupt rule
  is `focus until <the block's until>`, source plan (`interrupt --help`): new
  Decisions wait in the store and the first tick after the block shows them.
  The desk's own `away`, an unexpired focus, or `available` said during that
  block take precedence. Only today's plan holds: one stored on another day
  holds nothing, even a block of it that runs past midnight.

ACTIONS
  get       today's plan; a plan stored on another day is not today's
  set       store the plan, replacing any earlier one. Only the registered
            control session may (exit 4 otherwise)
  clear     delete the plan (control session only); any hold it caused ends
  forecast  what the desk forecasts from: the Decisions asked in the last
            --window minutes (1 to 1440, default 180), the distinct threads
            that asked them, open Decisions (and how many are parked), and
            unreviewed Reviews, with the store's clock

OUTPUT
  get, set: the plan as lines (`no plan for today` when there is none).
    --json: {"now": "...Z", "today": "YYYY-MM-DD", "plan": {...} | null}
  clear: `cleared` or `no plan`. --json: {"cleared": true|false}
  forecast: one line. --json: {"now", "today", "window_min", "asked",
    "threads", "open", "parked", "unreviewed", "read_today", "budget",
    "left"}; the last three are today's reading budget (issue #1770,
    `checkin --help`): Reviews read today, today's budget (null with no
    check-in today), and what is left of it (negative once over; null
    with no check-in). The proposal's clear-first batch takes at most
    `left` Reviews.
  Nothing on stderr on success.

STATE
  The plan lives in the reserved state key `plan` (`state set` refuses it).
  State is not an item, so no event is recorded.

EXIT CODES
  0  ok
  1  unexpected database failure, or stdin could not be read
  4  a missing or unknown action, a missing --session, a bad --window, a
     stray argument, stdin that is a terminal, a plan over 16384 bytes
     (before any connection attempt); a plan that is not valid or a session
     that is not the registered control session (after connecting, nothing
     written)
  5  the plan or the session id looks like a secret (before any connection
     attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# hq__plan_bytes VAR VALUE — VALUE's size in bytes (LC_ALL=C: ${#} counts
# bytes, whatever the caller's locale), into VAR.
hq__plan_bytes() {
  local LC_ALL=C
  printf -v "$1" '%s' "${#2}"
}

# hq__plan_read_stdin VAR — the plan from stdin into VAR, at most one byte
# past the cap (a runaway producer cannot fill memory). A NUL byte becomes
# \001, which is not valid JSON, so the store refuses it. The trailing `x`
# keeps trailing newlines through the command substitution.
hq__plan_read_stdin() {
  local hq__v hq__rc=0 hq__n
  if [ -t 0 ]; then
    hq_die_validation "plan set: pipe the plan's JSON on stdin"
  fi
  hq__v=$(set -o pipefail
          head -c "$((HQ_PLAN_MAX_BYTES + 1))" 2>/dev/null | LC_ALL=C tr '\000' '\001' 2>/dev/null
          hq__s=$?
          printf x
          exit "$hq__s") || hq__rc=$?
  if [ "$hq__rc" -ne 0 ]; then
    hq_die_error "plan set: standard input could not be read (exit $hq__rc); nothing was stored"
  fi
  hq__v="${hq__v%x}"
  hq__plan_bytes hq__n "$hq__v"
  if [ "$hq__n" -gt "$HQ_PLAN_MAX_BYTES" ]; then
    hq_die_validation "plan set: the plan is larger than $HQ_PLAN_MAX_BYTES bytes"
  fi
  case "$hq__v" in
    *[![:space:]]*) ;;
    *) hq_die_validation "plan set: the plan is empty (pipe its JSON on stdin)" ;;
  esac
  printf -v "$1" '%s' "$hq__v"
}

# The register-control lock and the control-session check, shared by set and
# clear: only the desk writes the plan.
hq__plan_control_sql() {
  cat <<'SQL'
SET LOCAL lock_timeout TO '30s';
SELECT pg_advisory_xact_lock(hashtextextended('human-queue:control:' || :'hq_schema', 0)) AS hq_control_locked \gset
SELECT coalesce((SELECT value FROM state WHERE key = 'control_session'), '') = :'hq_session' AS hq_ok \gset
SQL
}

# hq__plan_today_sql — `p`: today's stored plan (one row, NULL when there is
# none, it is not a JSON object, or it was stored on another day).
hq__plan_today_sql() {
  cat <<'SQL'
p AS (
  SELECT (SELECT CASE WHEN jsonb_typeof(s.v) = 'object'
                       AND s.v->>'day' = to_char(statement_timestamp() AT TIME ZONE :'hq_tz', 'YYYY-MM-DD')
                      THEN s.v END
            FROM (SELECT CASE WHEN pg_input_is_valid(value, 'jsonb') THEN value::jsonb END AS v
                    FROM state WHERE key = 'plan') s) AS v
)
SQL
}

# hq__plan_out_sql JSON — prints today's plan: the wrapper object with
# --json, else lines.
hq__plan_out_sql() {
  printf '%s\n' 'WITH'
  hq__plan_today_sql
  if [ "$1" -eq 1 ]; then
    cat <<'SQL'
SELECT jsonb_build_object(
         'now', to_char(statement_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
         'today', to_char(statement_timestamp() AT TIME ZONE :'hq_tz', 'YYYY-MM-DD'),
         'plan', (SELECT v FROM p));
SQL
    return 0
  fi
  # Lines: the header, what to clear first, one line per block in ET, and
  # what waits for later. A block's times are rendered only when they parse.
  cat <<'SQL'
SELECT CASE WHEN (SELECT v FROM p) IS NULL THEN 'no plan for today'
       ELSE concat_ws(E'\n',
         'plan for ' || (SELECT v->>'day' FROM p)
           || coalesce(' · ' || (SELECT v->>'item' FROM p), '')
           || coalesce(' · ' || (SELECT v->>'pace' FROM p), ''),
         (SELECT 'clear first: ' || string_agg(x, ' ' ORDER BY o)
            FROM p, jsonb_array_elements_text(CASE WHEN jsonb_typeof(p.v->'clear_first') = 'array'
                                                   THEN p.v->'clear_first' ELSE '[]' END) WITH ORDINALITY c(x, o)),
         (SELECT string_agg(o || '. '
                            || CASE WHEN pg_input_is_valid(b->>'start', 'timestamptz')
                                     AND pg_input_is_valid(b->>'until', 'timestamptz')
                                    THEN to_char((b->>'start')::timestamptz AT TIME ZONE :'hq_tz', 'HH24:MI') || '–'
                                         || to_char((b->>'until')::timestamptz AT TIME ZONE :'hq_tz', 'HH24:MI') || ' ET · '
                                    ELSE '' END
                            || coalesce(b->>'item', '?')
                            || coalesce(' · ' || (b->>'label'), ''), E'\n' ORDER BY o)
            FROM p, jsonb_array_elements(CASE WHEN jsonb_typeof(p.v->'blocks') = 'array'
                                              THEN p.v->'blocks' ELSE '[]' END) WITH ORDINALITY e(b, o)),
         (SELECT 'later: ' || string_agg(x, ' ' ORDER BY o)
            FROM p, jsonb_array_elements_text(CASE WHEN jsonb_typeof(p.v->'later') = 'array'
                                                   THEN p.v->'later' ELSE '[]' END) WITH ORDINALITY c(x, o)))
       END;
SQL
}

# hq__plan_set_sql JSON — under register-control's lock: refuse a session
# that is not the control session, check the plan, store it, print it. Each
# cast sits behind a CASE on pg_input_is_valid, so a malformed field is a
# refusal (`!reason`), never an SQL error.
hq__plan_set_sql() {
  hq__plan_control_sql
  cat <<'SQL'
\if :hq_ok
SELECT pg_input_is_valid(:'hq_plan', 'jsonb') AS hq_json \gset
\if :hq_json
WITH v AS (SELECT :'hq_plan'::jsonb AS v),
b AS (
  SELECT e.o, e.b,
         CASE WHEN jsonb_typeof(e.b) = 'object' AND jsonb_typeof(e.b->'start') = 'string'
                   AND pg_input_is_valid(e.b->>'start', 'timestamptz')
              THEN (e.b->>'start')::timestamptz END AS start,
         CASE WHEN jsonb_typeof(e.b) = 'object' AND jsonb_typeof(e.b->'until') = 'string'
                   AND pg_input_is_valid(e.b->>'until', 'timestamptz')
              THEN (e.b->>'until')::timestamptz END AS until
    FROM v, jsonb_array_elements(CASE WHEN jsonb_typeof(v.v) = 'object' AND jsonb_typeof(v.v->'blocks') = 'array'
                                      THEN v.v->'blocks' ELSE '[]' END) WITH ORDINALITY e(b, o)
),
ids AS (
  SELECT k, x
    FROM v, LATERAL (VALUES ('clear_first'), ('later')) f(k),
         LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(v.v->k) = 'array' THEN v.v->k ELSE '[]' END) a(x)
)
SELECT CASE
         WHEN jsonb_typeof((SELECT v FROM v)) <> 'object' THEN 'the plan must be a JSON object'
         WHEN jsonb_typeof((SELECT v->'blocks' FROM v)) IS DISTINCT FROM 'array' THEN 'the plan needs a blocks array'
         WHEN (SELECT count(*) FROM b) NOT BETWEEN 1 AND 24 THEN 'the plan needs 1 to 24 blocks'
         WHEN EXISTS (SELECT 1 FROM b WHERE jsonb_typeof(b.b) <> 'object') THEN 'each block must be a JSON object'
         WHEN EXISTS (SELECT 1 FROM b
                       WHERE jsonb_typeof(b.b->'item') IS DISTINCT FROM 'string'
                          OR char_length(b.b->>'item') NOT BETWEEN 1 AND 200
                          OR (b.b->>'item') ~ '[[:cntrl:]]'
                          OR btrim(b.b->>'item') = '')
           THEN 'each block needs an item: 1 to 200 characters on one line'
         WHEN EXISTS (SELECT 1 FROM b
                       WHERE jsonb_typeof(b.b->'pace') IS DISTINCT FROM 'string'
                          OR char_length(b.b->>'pace') NOT BETWEEN 1 AND 200
                          OR (b.b->>'pace') ~ '[[:cntrl:]]'
                          OR btrim(b.b->>'pace') = '')
           THEN 'each block needs a pace: 1 to 200 characters on one line'
         WHEN EXISTS (SELECT 1 FROM b
                       WHERE b.b ? 'label' AND jsonb_typeof(b.b->'label') <> 'null'
                         AND (jsonb_typeof(b.b->'label') <> 'string'
                              OR char_length(b.b->>'label') NOT BETWEEN 1 AND 200
                              OR (b.b->>'label') ~ '[[:cntrl:]]'))
           THEN 'a block''s label must be 1 to 200 characters on one line'
         WHEN EXISTS (SELECT 1 FROM b WHERE b.start IS NULL OR b.until IS NULL)
           THEN 'each block needs a start and an until: ISO 8601 times with a zone'
         WHEN EXISTS (SELECT 1 FROM b WHERE b.until <= b.start) THEN 'a block ends before it starts'
         WHEN EXISTS (SELECT 1 FROM b WHERE b.until - b.start > interval '24 hours') THEN 'a block is longer than a day'
         WHEN EXISTS (SELECT 1 FROM (SELECT b.start, lag(b.until) OVER (ORDER BY b.o) AS prev FROM b) l
                       WHERE l.start < l.prev)
           THEN 'the blocks overlap or are out of order'
         WHEN (SELECT max(until) FROM b) <= statement_timestamp() THEN 'every block has already ended'
         WHEN (SELECT max(until) FROM b) > statement_timestamp() + interval '24 hours'
           THEN 'the plan runs more than a day ahead'
         WHEN (SELECT min(start) FROM b) < statement_timestamp() - interval '24 hours'
           THEN 'the plan starts more than a day ago'
         WHEN EXISTS (SELECT 1 FROM v, LATERAL (VALUES ('item'), ('pace')) f(k)
                       WHERE v.v ? k AND jsonb_typeof(v.v->k) <> 'null'
                         AND (jsonb_typeof(v.v->k) <> 'string'
                              OR char_length(v.v->>k) NOT BETWEEN 1 AND 200
                              OR (v.v->>k) ~ '[[:cntrl:]]'))
           THEN 'the plan''s item and pace must be 1 to 200 characters on one line'
         WHEN EXISTS (SELECT 1 FROM v WHERE v.v ? 'inputs' AND jsonb_typeof(v.v->'inputs') NOT IN ('object', 'null'))
           THEN 'the plan''s inputs must be a JSON object'
         WHEN EXISTS (SELECT 1 FROM v, LATERAL (VALUES ('clear_first'), ('later')) f(k)
                       WHERE v.v ? k AND jsonb_typeof(v.v->k) NOT IN ('array', 'null'))
           THEN 'clear_first and later must be arrays of item ids'
         WHEN EXISTS (SELECT 1 FROM v, LATERAL (VALUES ('clear_first'), ('later')) f(k)
                       WHERE jsonb_typeof(v.v->k) = 'array' AND jsonb_array_length(v.v->k) > 99)
           THEN 'clear_first and later hold at most 99 ids each'
         WHEN EXISTS (SELECT 1 FROM ids
                       WHERE jsonb_typeof(ids.x) <> 'string' OR (ids.x #>> '{}') !~ '^[DR]-[1-9][0-9]*$')
           THEN 'clear_first and later hold item ids only (D-<n> or R-<n>)'
         ELSE ''
       END AS hq_problem \gset
\else
SELECT 'the plan is not valid JSON' AS hq_problem \gset
\endif
SELECT :'hq_problem' = '' AS hq_valid \gset
\if :hq_valid
WITH v AS (SELECT :'hq_plan'::jsonb AS v),
b AS (
  SELECT e.o, e.b, (e.b->>'start')::timestamptz AS start, (e.b->>'until')::timestamptz AS until
    FROM v, jsonb_array_elements(v.v->'blocks') WITH ORDINALITY e(b, o)
)
INSERT INTO state (key, value)
SELECT 'plan', jsonb_build_object(
         'version', 1,
         'day', to_char(statement_timestamp() AT TIME ZONE :'hq_tz', 'YYYY-MM-DD'),
         'session', :'hq_session',
         'set_at', to_char(statement_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
         'item', coalesce(nullif(v.v->'item', 'null'::jsonb), (SELECT b.b->'item' FROM b ORDER BY b.o LIMIT 1)),
         'pace', coalesce(nullif(v.v->'pace', 'null'::jsonb), (SELECT b.b->'pace' FROM b ORDER BY b.o LIMIT 1)),
         'inputs', coalesce(CASE WHEN jsonb_typeof(v.v->'inputs') = 'object' THEN v.v->'inputs' END, '{}'::jsonb),
         'clear_first', coalesce(CASE WHEN jsonb_typeof(v.v->'clear_first') = 'array' THEN v.v->'clear_first' END, '[]'::jsonb),
         'later', coalesce(CASE WHEN jsonb_typeof(v.v->'later') = 'array' THEN v.v->'later' END, '[]'::jsonb),
         'blocks', (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                                       'item', b.b->'item',
                                       'label', nullif(b.b->'label', 'null'::jsonb),
                                       'pace', b.b->'pace',
                                       'start', to_char(b.start AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                                       'until', to_char(b.until AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))
                                     ORDER BY b.o)
                      FROM b))::text
  FROM v
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
SQL
  hq__plan_out_sql "$1"
  cat <<'SQL'
\else
SELECT '!' || :'hq_problem' || '; nothing was stored';
\endif
\else
SELECT '!this session is not the registered control session; only the desk sets the day plan, and nothing was stored';
\endif
SQL
}

hq__plan_clear_sql() {
  hq__plan_control_sql
  cat <<'SQL'
\if :hq_ok
WITH d AS (DELETE FROM state WHERE key = 'plan' RETURNING 1)
SQL
  if [ "$1" -eq 1 ]; then
    printf '%s\n' "SELECT jsonb_build_object('cleared', EXISTS (SELECT 1 FROM d));"
  else
    printf '%s\n' "SELECT CASE WHEN EXISTS (SELECT 1 FROM d) THEN 'cleared' ELSE 'no plan' END;"
  fi
  cat <<'SQL'
\else
SELECT '!this session is not the registered control session; only the desk clears the day plan, and nothing was changed';
\endif
SQL
}

# hq__plan_forecast_sql JSON — counts over the trailing window, and today's
# reading budget (lib/budget.sh); read-only.
hq__plan_forecast_sql() {
  printf '%s\n' 'WITH'
  hq_sql_budget_today
  cat <<'SQL'
,
f AS (
  SELECT (SELECT count(*) FROM items
           WHERE kind = 'decision' AND created_at > statement_timestamp() - make_interval(mins => :hq_window)) AS asked,
         (SELECT count(DISTINCT session_id) FROM items
           WHERE kind = 'decision' AND session_id IS NOT NULL
             AND created_at > statement_timestamp() - make_interval(mins => :hq_window)) AS threads,
         (SELECT count(*) FROM items WHERE kind = 'decision' AND status = 'open') AS open,
         (SELECT count(*) FROM items WHERE kind = 'decision' AND status = 'open' AND parked) AS parked,
         (SELECT count(*) FROM items WHERE kind = 'review' AND status = 'open') AS unreviewed
)
SQL
  if [ "$1" -eq 1 ]; then
    cat <<'SQL'
SELECT jsonb_build_object(
         'now', to_char(statement_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
         'today', to_char(statement_timestamp() AT TIME ZONE :'hq_tz', 'YYYY-MM-DD'),
         'window_min', :hq_window, 'asked', asked, 'threads', threads,
         'open', open, 'parked', parked, 'unreviewed', unreviewed,
SQL
    hq_sql_budget_fields
    cat <<'SQL'
)
  FROM f;
SQL
  else
    cat <<'SQL'
SELECT asked || ' asked in the last ' || :hq_window || ' min by ' || threads
       || CASE WHEN threads = 1 THEN ' thread' ELSE ' threads' END
       || ' · ' || open || ' open ' || CASE WHEN open = 1 THEN 'Decision' ELSE 'Decisions' END
       || ' (' || parked || ' parked) · ' || unreviewed || ' unreviewed '
       || CASE WHEN unreviewed = 1 THEN 'Review' ELSE 'Reviews' END
  FROM f;
SQL
  fi
}

cmd_run() {
  local action="" session="" have_session=0 window="$HQ_PLAN_WINDOW_DEFAULT" have_window=0 json=0
  local plan="" errf out rc
  case "${1:-}" in
    -h|--help)
      cmd_usage
      exit 0
      ;;
    '') hq_die_validation "plan: missing action: get, set, clear, or forecast (run human-queue.sh plan --help)" ;;
    get|set|clear|forecast) action="$1" ;;
    -*) hq_die_validation "plan: unknown $(hq_flag_name "$1") (run human-queue.sh plan --help)" ;;
    *) hq_die_validation "plan: unknown action (expected get, set, clear, or forecast)" ;;
  esac
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --json) json=1 ;;
      --session|--window)
        if [ "$#" -lt 2 ]; then hq_die_validation "plan $action: $1 needs a value"; fi
        if [ "$1" = --session ]; then
          if [ "$have_session" -eq 1 ]; then hq_die_validation "plan $action: --session given more than once"; fi
          have_session=1
          session="$2"
        else
          if [ "$have_window" -eq 1 ]; then hq_die_validation "plan $action: --window given more than once"; fi
          have_window=1
          window="$2"
        fi
        shift
        ;;
      -*) hq_die_validation "plan $action: unknown $(hq_flag_name "$1") (run human-queue.sh plan --help)" ;;
      *) hq_die_validation "plan $action: takes no arguments (the plan comes on stdin)" ;;
    esac
    shift
  done

  case "$action" in
    set|clear)
      if [ "$have_session" -eq 0 ]; then
        hq_die_validation "plan $action: missing --session (the desk's control session)"
      fi
      if [ "$have_window" -eq 1 ]; then hq_die_validation "plan $action: --window goes only with forecast"; fi
      hq_check_text "plan $action: the session id" "$session" 200
      ;;
    get)
      if [ "$have_session" -eq 1 ]; then hq_die_validation "plan get: --session goes only with set and clear"; fi
      if [ "$have_window" -eq 1 ]; then hq_die_validation "plan get: --window goes only with forecast"; fi
      ;;
    forecast)
      if [ "$have_session" -eq 1 ]; then hq_die_validation "plan forecast: --session goes only with set and clear"; fi
      case "$window" in
        ''|*[!0-9]*) hq_die_validation "plan forecast: --window must be a whole number of minutes from 1 to 1440" ;;
      esac
      if [ "${#window}" -gt 4 ] || [ "$((10#$window))" -lt 1 ] || [ "$((10#$window))" -gt 1440 ]; then
        hq_die_validation "plan forecast: --window must be a whole number of minutes from 1 to 1440"
      fi
      window="$((10#$window))"
      ;;
  esac
  if [ "$action" = set ]; then
    hq__plan_read_stdin plan
    hq_refuse_secret "plan set: the plan" "$plan"
  fi
  if [ "$have_session" -eq 1 ]; then
    # The session id reaches psql's argv: a secret-shaped one stops here.
    hq_refuse_secret "plan $action: the session id" "$session"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  case "$action" in
    get)
      out=$(hq__plan_out_sql "$json" | hq_db_script -At -v "hq_tz=$(hq_desk_tz)" 2>"$errf") || rc=$?
      ;;
    set)
      out=$(hq__plan_set_sql "$json" | hq_db_script -At -v "hq_tz=$(hq_desk_tz)" \
              -v "hq_session=$session" -v "hq_plan=$plan" 2>"$errf") || rc=$?
      ;;
    clear)
      out=$(hq__plan_clear_sql "$json" | hq_db_script -At -v "hq_session=$session" 2>"$errf") || rc=$?
      ;;
    forecast)
      out=$(hq__plan_forecast_sql "$json" | hq_db_script -At -v "hq_tz=$(hq_desk_tz)" \
              -v "hq_window=$window" 2>"$errf") || rc=$?
      ;;
  esac
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "plan $action"
  fi
  hq_problem_check "plan $action" "$out"
  if [ -z "$out" ]; then
    hq_die_error "plan $action: the store returned nothing"
  fi
  printf '%s\n' "$out"
}
