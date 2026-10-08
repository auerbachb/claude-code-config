# shellcheck shell=bash
# summary: the end-of-day sweep: whether it is due today, and everything still open as one list
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"

# The most a sweep lists: set-open numbers at most 99 items.
HQ_SWEEP_MAX=99

cmd_usage() {
  cat <<'EOF'
human-queue.sh sweep — the end-of-day sweep (issue #1784).

USAGE
  human-queue.sh sweep due --session SESSION --at HH:MM [--json]
  human-queue.sh sweep list [--json]

ACTIONS
  due   whether the end-of-day sweep is due now. HH:MM is desk/policy.json's
        eod_time, a 24-hour time in America/New_York. The sweep is due once
        a day: the first call at or after that time on the store's clock
        marks today under the reserved state key eod_sweep and reports it
        due; later calls that day report it done. Only the registered control
        session may ask (exit 4 otherwise), under register-control's lock, so
        two desks never both sweep. desk-tick.sh calls it after every tick
        and prints `desk-tick GEN eod` when it is due.
  list  everything still open, in the sweep's order: open Decisions (parked
        first, then impact, then age), then unreviewed Reviews (oldest
        first); at most 99 (set-open numbers at most 99), `more` counts the
        rest. Read-only.

OUTPUT
  due: `due 2026-10-08` the one time it is due, `done 2026-10-08` once it was
    marked today, nothing before HH:MM. --json: {"due": true|false,
    "done": true|false, "day": "YYYY-MM-DD"}
  list: one line per item, `1. D-43 The question?` (Reviews: their cached
    level-1 line, else their title), then `N more` when there are. Nothing
    when nothing is open. --json: {"today": "YYYY-MM-DD", "count": N,
    "decisions": N, "reviews": N, "more": N, "items": [...]}, each item the
    `list --json` shape without summary_l2.
  Nothing on stderr on success.

EXIT CODES
  0  ok (including when the sweep is not due, or nothing is open)
  1  unexpected database failure
  4  a missing or unknown action, a missing --session or --at, a malformed
     time, a stray argument (before any connection attempt); a session that
     is not the registered control session (after connecting, nothing marked)
  5  the session id looks like a secret (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# hq__sweep_time_ok HH:MM — the policy's eod_time shape (capture.py's
# EOD_RE). LC_ALL=C so the classes are byte ranges, never a locale's.
hq__sweep_time_ok() {
  local LC_ALL=C re='^([01][0-9]|2[0-3]):[0-5][0-9]$'
  [[ $1 =~ $re ]]
}

# hq__sweep_due_sql JSON — under register-control's lock: refuse a session
# that is not the control session; then, once the store's clock in :'hq_tz'
# reads :'hq_at' or later, mark today. The upsert's WHERE makes the mark
# once a day: a second call the same day updates nothing and returns no row.
hq__sweep_due_sql() {
  cat <<'SQL'
SET LOCAL lock_timeout TO '30s';
SELECT pg_advisory_xact_lock(hashtextextended('human-queue:control:' || :'hq_schema', 0)) AS hq_control_locked \gset
SELECT coalesce((SELECT value FROM state WHERE key = 'control_session'), '') = :'hq_session' AS hq_ok \gset
\if :hq_ok
WITH t AS (
  SELECT to_char(statement_timestamp() AT TIME ZONE :'hq_tz', 'YYYY-MM-DD') AS day,
         (statement_timestamp() AT TIME ZONE :'hq_tz')::time >= :'hq_at'::time AS past
), up AS (
  INSERT INTO state (key, value)
  SELECT 'eod_sweep', t.day FROM t WHERE t.past
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
    WHERE state.value IS DISTINCT FROM EXCLUDED.value
  RETURNING value
), r AS (
  SELECT t.day, EXISTS (SELECT 1 FROM up) AS due,
         t.past AND NOT EXISTS (SELECT 1 FROM up) AS done
    FROM t
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

# hq__sweep_list_sql JSON — Decisions in list order, then Reviews oldest
# first, numbered in that order; the first HQ_SWEEP_MAX are listed.
hq__sweep_list_sql() {
  printf '%s\n' "WITH o AS ("
  # summary_l1 is read through the row's JSON, so a store before 007 lists
  # titles instead of failing on the column.
  printf '  SELECT i.id, (%s - %s) AS j, i.kind, i.question, to_jsonb(i)->>%s AS summary_l1,\n' \
    "$(hq_sql_item_json)" "'summary_l2'" "'summary_l1'"
  printf '%s\n' "         row_number() OVER (ORDER BY CASE i.kind WHEN 'decision' THEN 0 ELSE 1 END,"
  printf '%s\n' "           CASE WHEN i.kind = 'decision' THEN i.parked END DESC NULLS LAST,"
  printf '%s\n' "           CASE WHEN i.kind = 'decision' THEN $(hq_sql_impact_rank) END,"
  printf '%s\n' "           i.created_at, i.id) AS n"
  printf '%s\n' "    FROM items i WHERE i.status = 'open'"
  printf '%s\n' ")"
  if [ "$1" -eq 1 ]; then
    cat <<SQL
SELECT jsonb_build_object(
         'today', to_char(statement_timestamp() AT TIME ZONE :'hq_tz', 'YYYY-MM-DD'),
         'count', (SELECT count(*) FROM o),
         'decisions', (SELECT count(*) FROM o WHERE kind = 'decision'),
         'reviews', (SELECT count(*) FROM o WHERE kind = 'review'),
         'more', greatest((SELECT count(*) FROM o) - $HQ_SWEEP_MAX, 0),
         'items', coalesce((SELECT jsonb_agg(j ORDER BY n) FROM o WHERE n <= $HQ_SWEEP_MAX), '[]'::jsonb));
SQL
  else
    cat <<SQL
SELECT concat_ws(E'\\n',
         (SELECT string_agg(n || '. ' || id || ' '
                            || CASE WHEN kind = 'review' AND coalesce(summary_l1, '') <> '' THEN summary_l1
                                    ELSE question END, E'\\n' ORDER BY n)
            FROM o WHERE n <= $HQ_SWEEP_MAX),
         (SELECT nullif(count(*) - $HQ_SWEEP_MAX, 0) || ' more' FROM o HAVING count(*) > $HQ_SWEEP_MAX))
 WHERE EXISTS (SELECT 1 FROM o);
SQL
  fi
}

cmd_run() {
  local action="" session="" have_session=0 at="" have_at=0 json=0 errf out rc
  case "${1:-}" in
    -h|--help)
      cmd_usage
      exit 0
      ;;
    '') hq_die_validation "sweep: missing action: due or list (run human-queue.sh sweep --help)" ;;
    due|list) action="$1" ;;
    -*) hq_die_validation "sweep: unknown $(hq_flag_name "$1") (run human-queue.sh sweep --help)" ;;
    *) hq_die_validation "sweep: unknown action (expected due or list)" ;;
  esac
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --json) json=1 ;;
      --session|--at)
        if [ "$#" -lt 2 ]; then hq_die_validation "sweep $action: $1 needs a value"; fi
        if [ "$1" = --session ]; then
          if [ "$have_session" -eq 1 ]; then hq_die_validation "sweep $action: --session given more than once"; fi
          have_session=1
          session="$2"
        else
          if [ "$have_at" -eq 1 ]; then hq_die_validation "sweep $action: --at given more than once"; fi
          have_at=1
          at="$2"
        fi
        shift
        ;;
      -*) hq_die_validation "sweep $action: unknown $(hq_flag_name "$1") (run human-queue.sh sweep --help)" ;;
      *) hq_die_validation "sweep $action: takes no arguments" ;;
    esac
    shift
  done
  if [ "$action" = list ]; then
    if [ "$have_session" -eq 1 ] || [ "$have_at" -eq 1 ]; then
      hq_die_validation "sweep list: --session and --at go only with due"
    fi
  else
    if [ "$have_session" -eq 0 ]; then
      hq_die_validation "sweep due: missing --session (the desk's control session)"
    fi
    if [ "$have_at" -eq 0 ]; then
      hq_die_validation "sweep due: missing --at HH:MM (desk/policy.json's eod_time)"
    fi
    hq_check_text "sweep due: the session id" "$session" 200
    if ! hq__sweep_time_ok "$at"; then
      hq_die_validation "sweep due: --at must be a 24-hour time HH:MM, for example 17:30"
    fi
    # The session id reaches psql's argv: a secret-shaped one stops here.
    hq_refuse_secret "sweep due: the session id" "$session"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  if [ "$action" = due ]; then
    out=$(hq__sweep_due_sql "$json" | hq_db_script -At -v "hq_session=$session" \
            -v "hq_tz=$(hq_desk_tz)" -v "hq_at=$at" 2>"$errf") || rc=$?
  else
    out=$(hq__sweep_list_sql "$json" | hq_db_script -At -v "hq_tz=$(hq_desk_tz)" 2>"$errf") || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "sweep $action"
  fi
  hq_problem_check "sweep $action" "$out"
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
}
