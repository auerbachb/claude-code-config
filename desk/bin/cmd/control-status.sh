# shellcheck shell=bash
# summary: show the registered control session and how long ago the last tick ran
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh control-status — the desk's control session and its last tick.

USAGE
  human-queue.sh control-status [--json]

ARGUMENTS
  --json   print {"session": ..., "last_tick_at": ..., "tick_age_seconds": ...}

BEHAVIOR
  Reads the control session `register-control` stored and the time the last
  `tick` stored (the reserved state keys control_session and tick_at), and
  works out how long ago that tick ran on the database's clock, so a machine
  whose clock is off cannot change the answer. The age is in whole seconds,
  rounded up, so a tick even a fraction of a second past a bound reads as
  past it. Read-only: records nothing.

  The capture hook runs this on every question: a registered control session
  whose last tick is recent is a live desk, and only then are questions
  queued instead of shown in the asking thread (desk/README.md, "Capture
  hook"). Any tick counts; in practice only the desk ticks.

OUTPUT
  Two lines: `control session SESSION` (or `no control session`), then
  `last tick YYYY-MM-DD HH:MM UTC (N seconds ago)` (or `no tick yet`).
  With --json, one object; each field is null when it is not set:
    {"session": "abc", "last_tick_at": "2026-10-06T21:40:00Z",
     "tick_age_seconds": 180}
  Nothing on stderr on success.

EXIT CODES
  0  ok (including when nothing is registered or nothing has ticked)
  1  unexpected database failure
  4  a stray argument (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# One read. tick_at is written by tick in exactly this shape, and `state set`
# refuses the key, so anything else is only possible by editing the table by
# hand. A value of another shape reads as "no tick yet" rather than failing
# the cast; an impossible date in the right shape (February 30) still fails
# it, which exits 1, and the capture hook fails open on that like any error.
# The age is rounded up (ceil), so the hook's `age > bound` check is strict.
hq__control_status_sql() {
  cat <<'SQL'
WITH raw AS (
  SELECT (SELECT value FROM state WHERE key = 'control_session') AS session,
         (SELECT value FROM state WHERE key = 'tick_at') AS tick_text
), s AS (
  SELECT session,
         CASE WHEN tick_text ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
              THEN tick_text::timestamptz END AS tick_at
    FROM raw
), a AS (
  SELECT session, tick_at,
         ceil(extract(epoch FROM statement_timestamp() - tick_at))::bigint AS age
    FROM s
)
SQL
  if [ "$1" -eq 1 ]; then
    cat <<'SQL'
SELECT jsonb_build_object(
         'session', session,
         'last_tick_at', to_char(tick_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
         'tick_age_seconds', age)
  FROM a;
SQL
  else
    cat <<'SQL'
SELECT coalesce('control session ' || session, 'no control session') || E'\n'
       || coalesce('last tick ' || to_char(tick_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI')
                   || ' UTC (' || age || ' seconds ago)', 'no tick yet')
  FROM a;
SQL
  fi
}

cmd_run() {
  local json=0 errf out rc

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --json) json=1 ;;
      -*) hq_die_validation "control-status: unknown $(hq_flag_name "$1") (run human-queue.sh control-status --help)" ;;
      *) hq_die_validation "control-status: takes no arguments (run human-queue.sh control-status --help)" ;;
    esac
    shift
  done

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__control_status_sql "$json" | hq_db_script -At 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "control-status"
  fi
  if [ -z "$out" ]; then
    hq_die_error "control-status: the store returned nothing"
  fi
  printf '%s\n' "$out"
}
