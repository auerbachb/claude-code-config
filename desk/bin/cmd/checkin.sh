# shellcheck shell=bash
# summary: the morning check-in and today's reading budget: store, read, or ask whether it is due
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

cmd_usage() {
  cat <<'EOF'
human-queue.sh checkin — the morning check-in and today's reading budget
(issue #1770).

USAGE
  human-queue.sh checkin get [--json]
  human-queue.sh checkin set --session SESSION --hours H --energy WORD
                             [--planned TEXT] [--json]
  human-queue.sh checkin due --session SESSION --at HH:MM [--until HH:MM] [--json]

THE CHECK-IN
  Three answers, once a day: hours at the desk today (0 to 16, up to two
  decimals), energy in one word (letters and hyphens, up to 20, any case;
  stored lowercase), and what is planned (optional, one line, up to 200
  characters). `set` stores them under the reserved state key `checkin`
  with today's reading budget, computed once, then:

  THE BUDGET  Reviews to read today. The measured day is the most recent of
              the 7 days before today with at least 3 Reviews read (`stats
              --help` says how a day is measured). Budget = round(its
              Reviews an hour, to one decimal as the card shows it × hours
              × the energy factor), half away from zero. With no measured
              day, the starting guess: round(30 × the energy factor), the
              "30 × 20" of desk/DESIGN.md 2.8 (30 Reviews, 20 lines each at
              level 2). 0 hours is a budget of 0.
  ENERGY      The factor for the word: low 0.7, tired 0.7, ok 1, fine 1,
              normal 1, good 1, high 1.2, great 1.2. The operator changes
              or adds a word with the plain state key energy_factors, a JSON
              object (`state set energy_factors '{"low": 0.6, "meh": 0.8}'`):
              each lowercase word up to 20 letters or hyphens with a number
              from 0 to 2 applies, anything else is ignored. A word in
              neither counts 1 (factor_known false).

ACTIONS
  get   today's check-in (null when none was stored today), the measured
        day as it stands now, the factor table, and the running count:
        Reviews read today, unreviewed Reviews, the budget, and what is left
  set   store today's check-in, replacing an earlier one today (its budget
        is computed again). Only the registered control session may (exit 4
        otherwise)
  due   whether the morning check-in is due now. HH:MM (--at) and --until
        are 24-hour times in America/New_York; the check-in is due once a
        day, the first time the store's clock reads --at or later and
        before --until (default: the end of the day), unless today's
        check-in is already stored. That first call marks today under the
        reserved state key checkin_asked. Only the registered control
        session may ask (exit 4 otherwise), under register-control's lock.
        desk-tick.sh calls it after every tick, from 04:00 until the
        policy's eod_time, and prints `desk-tick GEN morning` when it is due.

OUTPUT
  get, set: one line,
    budget 28 Reviews today · 9 read · 19 left · 4 h · energy ok (×1)
    or: no check-in today · 9 Reviews read today · last measured day
    2026-10-07: 7.0 Reviews an hour
  --json:
    {"now": "...Z", "today": "YYYY-MM-DD",
     "checkin": {"version": 1, "day", "session", "set_at", "hours",
                 "energy", "factor", "factor_known", "planned", "budget",
                 "lines", "basis": {"kind": "measured", "day", "reviewed",
                 "active_min", "rate"} | {"kind": "guess", "items": 30,
                 "lines_per_item": 20}} | null,
     "measured": {...a `stats --json` object...} | null,
     "factors": {...}, "guess": {"items": 30, "lines_per_item": 20,
                                 "min_read": 3, "lookback_days": 7},
     "read_today": N, "answered_today": N, "unreviewed": N,
     "budget": N | null, "left": N | null}
  due: `due 2026-10-08` the one time it is due, `done 2026-10-08` once
    it was marked today (or the check-in is stored), nothing outside the
    window. --json: {"due": true|false, "done": true|false, "day": "..."}
  Nothing on stderr on success.

STATE
  checkin and checkin_asked are reserved (`state set` refuses them); state
  is not an item, so no event is recorded.

EXIT CODES
  0  ok
  1  unexpected database failure
  4  a missing or unknown action, a missing or malformed --session,
     --hours, --energy, --at, or --until, a --planned that is not one line
     of up to 200 characters, a stray argument (before any connection
     attempt); a session that is not the registered control session (after
     connecting, nothing written)
  5  the session id or --planned looks like a secret (before any
     connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# hq__checkin_time_ok HH:MM — a 24-hour time. LC_ALL=C so the classes are
# byte ranges, never a locale's.
hq__checkin_time_ok() {
  local LC_ALL=C re='^([01][0-9]|2[0-3]):[0-5][0-9]$'
  [[ $1 =~ $re ]]
}

# hq__checkin_hours VAR VALUE — VALUE as hours from 0 to 16 with at most two
# decimals, canonical (no leading zeros, no trailing zero decimals), into VAR;
# exits 4 otherwise.
hq__checkin_hours() {
  local hq__v="$2" hq__i hq__f="" LC_ALL=C
  if ! [[ $hq__v =~ ^([0-9]{1,2})(\.([0-9]{1,2}))?$ ]]; then
    hq_die_validation "checkin set: --hours must be a number of hours from 0 to 16 (for example 4 or 4.5)"
  fi
  hq__i=$((10#${BASH_REMATCH[1]}))
  hq__f="${BASH_REMATCH[3]}"
  while [ -n "$hq__f" ] && [ "${hq__f%0}" != "$hq__f" ]; do hq__f="${hq__f%0}"; done
  if [ "$hq__i" -gt 16 ] || { [ "$hq__i" -eq 16 ] && [ -n "$hq__f" ]; }; then
    hq_die_validation "checkin set: --hours must be a number of hours from 0 to 16 (for example 4 or 4.5)"
  fi
  if [ -n "$hq__f" ]; then
    printf -v "$1" '%s.%s' "$hq__i" "$hq__f"
  else
    printf -v "$1" '%s' "$hq__i"
  fi
}

# hq__checkin_energy VAR VALUE — VALUE as one lowercase word of up to 20
# letters or hyphens, into VAR; exits 4 otherwise. LC_ALL=C so the classes
# are byte ranges (A-Z never matches an accented letter).
hq__checkin_energy() {
  local hq__v="$2" LC_ALL=C
  if ! [[ $hq__v =~ ^[A-Za-z][A-Za-z-]{0,19}$ ]]; then
    hq_die_validation "checkin set: --energy must be one word: letters and hyphens, up to 20 (for example ok, low, high)"
  fi
  hq__v=$(printf '%s' "$hq__v" | tr '[:upper:]' '[:lower:]')
  printf -v "$1" '%s' "$hq__v"
}

# The register-control lock and the control-session check: only the desk
# stores the check-in or marks it asked.
hq__checkin_control_sql() {
  cat <<'SQL'
SET LOCAL lock_timeout TO '30s';
SELECT pg_advisory_xact_lock(hashtextextended('human-queue:control:' || :'hq_schema', 0)) AS hq_control_locked \gset
SELECT coalesce((SELECT value FROM state WHERE key = 'control_session'), '') = :'hq_session' AS hq_ok \gset
SQL
}

# hq__checkin_out_sql JSON — today's check-in and running count: the object
# with --json, else one line. Read-only.
hq__checkin_out_sql() {
  printf '%s\n' 'WITH'
  hq_sql_budget_today
  printf '%s\n' ','
  hq_sql_budget_factors
  if [ "$1" -eq 1 ]; then
    cat <<SQL
SELECT jsonb_build_object(
         'now', to_char(statement_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
         'today', to_char((SELECT t.today FROM hqb_t t), 'YYYY-MM-DD'),
         'checkin', (SELECT c.v FROM hqb_c c),
         'measured', (SELECT $(hq_sql_budget_stats_json m) FROM hqb_m m),
         'factors', (SELECT fx.t FROM hqb_fx fx),
         'guess', $(hq_sql_budget_guess_json),
         'answered_today', coalesce((SELECT td.answered FROM hqb_td td), 0),
         'unreviewed', (SELECT count(*) FROM items WHERE kind = 'review' AND status = 'open'),
$(hq_sql_budget_fields));
SQL
    return 0
  fi
  cat <<'SQL'
SELECT CASE WHEN c.v IS NULL THEN
         concat_ws(' · ', 'no check-in today',
                   coalesce((SELECT td.reviewed FROM hqb_td td), 0) || ' Reviews read today',
                   coalesce((SELECT 'last measured day ' || to_char(m.day, 'YYYY-MM-DD') || ': '
                                    || round(m.reviewed * 60.0 / m.active_exact, 1) || ' Reviews an hour'
                               FROM hqb_m m),
                            'no measured day in the last week (the starting guess is ' || :'hq_guess' || ')'))
       ELSE
         concat_ws(' · ', 'budget ' || coalesce(c.v->>'budget', '?') || ' Reviews today',
                   coalesce((SELECT td.reviewed FROM hqb_td td), 0) || ' read',
                   CASE WHEN jsonb_typeof(c.v->'budget') = 'number' THEN
                          CASE WHEN (c.v->>'budget')::numeric >= coalesce((SELECT td.reviewed FROM hqb_td td), 0)
                               THEN ((c.v->>'budget')::numeric - coalesce((SELECT td.reviewed FROM hqb_td td), 0)) || ' left'
                               ELSE (coalesce((SELECT td.reviewed FROM hqb_td td), 0) - (c.v->>'budget')::numeric) || ' over' END
                   END,
                   coalesce(c.v->>'hours', '?') || ' h',
                   'energy ' || coalesce(c.v->>'energy', '?') || ' (×' || coalesce(c.v->>'factor', '?') || ')')
       END
  FROM hqb_c c;
SQL
}

# hq__checkin_set_sql JSON — under register-control's lock: refuse a session
# that is not the control session; then compute today's budget and store the
# check-in, and print it as `get` does.
hq__checkin_set_sql() {
  hq__checkin_control_sql
  printf '%s\n' '\if :hq_ok'
  printf '%s\n' 'WITH'
  hq_sql_budget_today
  printf '%s\n' ','
  hq_sql_budget_factors
  cat <<SQL
,
hqb_calc AS (
  SELECT trim_scale(:'hq_hours'::numeric) AS hours,
         trim_scale(coalesce(CASE WHEN jsonb_typeof(fx.t->:'hq_energy') = 'number'
                                  THEN (fx.t->>:'hq_energy')::numeric END, 1)) AS factor,
         coalesce(jsonb_typeof(fx.t->:'hq_energy') = 'number', false) AS known
    FROM hqb_fx fx
),
hqb_r AS (
  SELECT c.hours, c.factor, c.known, m.day AS mday, m.reviewed AS mread, m.active_exact AS mactive,
         (CASE WHEN c.hours = 0 THEN 0
               WHEN m.day IS NOT NULL THEN round(round(m.reviewed * 60.0 / m.active_exact, 1) * c.hours * c.factor)
               ELSE round($HQ_BUDGET_GUESS_ITEMS * c.factor) END)::int AS budget
    FROM hqb_calc c LEFT JOIN hqb_m m ON true
)
INSERT INTO state (key, value)
SELECT 'checkin', jsonb_build_object(
         'version', 1,
         'day', to_char(t.today, 'YYYY-MM-DD'),
         'session', :'hq_session',
         'set_at', to_char(statement_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
         'hours', r.hours,
         'energy', :'hq_energy',
         'factor', r.factor,
         'factor_known', r.known,
         'planned', nullif(:'hq_planned', ''),
         'budget', r.budget,
         'lines', r.budget * $HQ_BUDGET_LINES_PER_ITEM,
         'basis', CASE WHEN r.mday IS NOT NULL
                       THEN jsonb_build_object('kind', 'measured', 'day', to_char(r.mday, 'YYYY-MM-DD'),
                                               'reviewed', r.mread, 'active_min', round(r.mactive)::int,
                                               'rate', round(r.mread * 60.0 / r.mactive, 1))
                       ELSE jsonb_build_object('kind', 'guess', 'items', $HQ_BUDGET_GUESS_ITEMS,
                                               'lines_per_item', $HQ_BUDGET_LINES_PER_ITEM) END)::text
  FROM hqb_r r, hqb_t t
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
SQL
  hq__checkin_out_sql "$1"
  cat <<'SQL'
\else
SELECT '!this session is not the registered control session; only the desk stores the check-in, and nothing was stored';
\endif
SQL
}

# hq__checkin_due_sql JSON — under register-control's lock: refuse a session
# that is not the control session; then, while the store's clock in :'hq_tz'
# reads from :'hq_at' up to (not including) :'hq_until', mark today. The
# upsert's WHERE makes the mark once a day: a second call the same day
# updates nothing and returns no row. A check-in already stored today makes
# the mark `done` too. hq_until is always a valid time ('24:00' for the end
# of the day), never an empty string: a constant cast is evaluated when the
# statement is planned, whatever a CASE around it says.
hq__checkin_due_sql() {
  hq__checkin_control_sql
  cat <<'SQL'
\if :hq_ok
WITH t AS (
  SELECT to_char(statement_timestamp() AT TIME ZONE :'hq_tz', 'YYYY-MM-DD') AS day,
         (statement_timestamp() AT TIME ZONE :'hq_tz')::time AS now_t
), w AS (
  SELECT t.day,
         t.now_t >= :'hq_at'::time AND t.now_t < :'hq_until'::time AS inside,
         EXISTS (SELECT 1 FROM state s
                  WHERE s.key = 'checkin'
                    AND CASE WHEN pg_input_is_valid(s.value, 'jsonb')
                             THEN jsonb_typeof(s.value::jsonb) = 'object' AND s.value::jsonb->>'day' = t.day
                             ELSE false END) AS have
    FROM t
), up AS (
  INSERT INTO state (key, value)
  SELECT 'checkin_asked', w.day FROM w WHERE w.inside
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
    WHERE state.value IS DISTINCT FROM EXCLUDED.value
  RETURNING value
), r AS (
  SELECT w.day, EXISTS (SELECT 1 FROM up) AND NOT w.have AS due,
         w.inside AND NOT (EXISTS (SELECT 1 FROM up) AND NOT w.have) AS done
    FROM w
)
SQL
  if [ "$1" -eq 1 ]; then
    printf '%s\n' "SELECT jsonb_build_object('due', due, 'done', done, 'day', day) FROM r;"
  else
    printf '%s\n' "SELECT CASE WHEN due THEN 'due ' || day WHEN done THEN 'done ' || day ELSE '' END FROM r;"
  fi
  cat <<'SQL'
\else
SELECT '!this session is not the registered control session; nothing was marked';
\endif
SQL
}

cmd_run() {
  local action="" json=0 session="" have_session=0 hours="" have_hours=0 energy="" have_energy=0
  local planned="" have_planned=0 at="" have_at=0 until="" have_until=0 errf out rc flag
  case "${1:-}" in
    -h|--help)
      cmd_usage
      exit 0
      ;;
    '') hq_die_validation "checkin: missing action: get, set, or due (run human-queue.sh checkin --help)" ;;
    get|set|due) action="$1" ;;
    -*) hq_die_validation "checkin: unknown $(hq_flag_name "$1") (run human-queue.sh checkin --help)" ;;
    *) hq_die_validation "checkin: unknown action (expected get, set, or due)" ;;
  esac
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --json) json=1 ;;
      --session|--hours|--energy|--planned|--at|--until)
        flag="$1"
        if [ "$#" -lt 2 ]; then hq_die_validation "checkin $action: $flag needs a value"; fi
        case "$flag" in
          --session)
            if [ "$have_session" -eq 1 ]; then hq_die_validation "checkin $action: --session given more than once"; fi
            have_session=1 session="$2" ;;
          --hours)
            if [ "$have_hours" -eq 1 ]; then hq_die_validation "checkin $action: --hours given more than once"; fi
            have_hours=1 hours="$2" ;;
          --energy)
            if [ "$have_energy" -eq 1 ]; then hq_die_validation "checkin $action: --energy given more than once"; fi
            have_energy=1 energy="$2" ;;
          --planned)
            if [ "$have_planned" -eq 1 ]; then hq_die_validation "checkin $action: --planned given more than once"; fi
            have_planned=1 planned="$2" ;;
          --at)
            if [ "$have_at" -eq 1 ]; then hq_die_validation "checkin $action: --at given more than once"; fi
            have_at=1 at="$2" ;;
          *)
            if [ "$have_until" -eq 1 ]; then hq_die_validation "checkin $action: --until given more than once"; fi
            have_until=1 until="$2" ;;
        esac
        shift
        ;;
      -*) hq_die_validation "checkin $action: unknown $(hq_flag_name "$1") (run human-queue.sh checkin --help)" ;;
      *) hq_die_validation "checkin $action: takes no arguments besides its options (run human-queue.sh checkin --help)" ;;
    esac
    shift
  done

  # Which options go with which action.
  case "$action" in
    get)
      if [ "$have_session" -eq 1 ]; then hq_die_validation "checkin get: --session goes only with set and due"; fi
      if [ "$have_hours" -eq 1 ] || [ "$have_energy" -eq 1 ] || [ "$have_planned" -eq 1 ]; then
        hq_die_validation "checkin get: --hours, --energy, and --planned go only with set"
      fi
      if [ "$have_at" -eq 1 ] || [ "$have_until" -eq 1 ]; then
        hq_die_validation "checkin get: --at and --until go only with due"
      fi
      ;;
    set)
      if [ "$have_at" -eq 1 ] || [ "$have_until" -eq 1 ]; then
        hq_die_validation "checkin set: --at and --until go only with due"
      fi
      if [ "$have_session" -eq 0 ]; then hq_die_validation "checkin set: missing --session (the desk's control session)"; fi
      if [ "$have_hours" -eq 0 ]; then hq_die_validation "checkin set: missing --hours (hours at the desk today)"; fi
      if [ "$have_energy" -eq 0 ]; then hq_die_validation "checkin set: missing --energy (one word)"; fi
      hq__checkin_hours hours "$hours"
      hq__checkin_energy energy "$energy"
      if [ -n "$planned" ]; then
        hq_check_text "checkin set: --planned" "$planned" 200
      fi
      ;;
    due)
      if [ "$have_hours" -eq 1 ] || [ "$have_energy" -eq 1 ] || [ "$have_planned" -eq 1 ]; then
        hq_die_validation "checkin due: --hours, --energy, and --planned go only with set"
      fi
      if [ "$have_session" -eq 0 ]; then hq_die_validation "checkin due: missing --session (the desk's control session)"; fi
      if [ "$have_at" -eq 0 ]; then hq_die_validation "checkin due: missing --at HH:MM (when the morning starts)"; fi
      if ! hq__checkin_time_ok "$at"; then
        hq_die_validation "checkin due: --at must be a 24-hour time HH:MM, for example 04:00"
      fi
      if [ "$have_until" -eq 1 ]; then
        if ! hq__checkin_time_ok "$until"; then
          hq_die_validation "checkin due: --until must be a 24-hour time HH:MM, for example 17:30"
        fi
      else
        until="24:00"
      fi
      ;;
  esac
  if [ "$have_session" -eq 1 ]; then
    hq_check_text "checkin $action: the session id" "$session" 200
    # The session id reaches psql's argv: a secret-shaped one stops here.
    hq_refuse_secret "checkin $action: the session id" "$session"
  fi
  if [ -n "$planned" ]; then
    hq_refuse_secret "checkin set: --planned" "$planned"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  case "$action" in
    get)
      out=$(hq__checkin_out_sql "$json" | hq_db_script -At -v "hq_tz=$(hq_desk_tz)" \
              -v "hq_factors=$(hq_budget_factors)" -v "hq_guess=$HQ_BUDGET_GUESS_ITEMS" 2>"$errf") || rc=$?
      ;;
    set)
      out=$(hq__checkin_set_sql "$json" | hq_db_script -At -v "hq_tz=$(hq_desk_tz)" \
              -v "hq_factors=$(hq_budget_factors)" -v "hq_guess=$HQ_BUDGET_GUESS_ITEMS" \
              -v "hq_session=$session" -v "hq_hours=$hours" -v "hq_energy=$energy" \
              -v "hq_planned=$planned" 2>"$errf") || rc=$?
      ;;
    due)
      out=$(hq__checkin_due_sql "$json" | hq_db_script -At -v "hq_tz=$(hq_desk_tz)" \
              -v "hq_session=$session" -v "hq_at=$at" -v "hq_until=$until" 2>"$errf") || rc=$?
      ;;
  esac
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "checkin $action"
  fi
  hq_problem_check "checkin $action" "$out"
  if [ "$action" != due ] && [ -z "$out" ]; then
    hq_die_error "checkin $action: the store returned nothing"
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
}
