# shellcheck shell=bash
# summary: register the desk's control session (the one /desk thread workers wake)
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh register-control — register the desk's control session.

USAGE
  human-queue.sh register-control SESSION [--json]

ARGUMENTS
  SESSION  the /desk thread's session id (one line, <= 200 characters)
  --json   print {"session": "...", "previous": "..." or null}

BEHAVIOR
  There is one control session: the thread that answers for the operator
  and is woken with a pointer when something needs them. Registering stores
  SESSION in state under the reserved key control_session; the last
  registration wins (concurrent registrations are serialized). Read it with
  `state get control_session`. No event is recorded (state is not an item).

OUTPUT
  `control session SESSION`, plus `(replaces PREVIOUS)` when another session
  was registered before. Nothing on stderr on success.

EXIT CODES
  0  ok
  1  unexpected database failure
  4  a missing or invalid session, or a stray argument (before any
     connection attempt)
  5  the session id looks like a secret (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

hq__register_sql() {
  cat <<'SQL'
SET LOCAL lock_timeout TO '30s';
SELECT pg_advisory_xact_lock(hashtextextended('human-queue:control:' || :'hq_schema', 0)) AS hq_locked \gset
WITH prev AS (
  SELECT value FROM state WHERE key = 'control_session'
), up AS (
  INSERT INTO state (key, value) VALUES ('control_session', :'hq_session')
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
)
SQL
  if [ "$1" -eq 1 ]; then
    printf '%s\n' "SELECT jsonb_build_object('session', :'hq_session', 'previous', (SELECT value FROM prev));"
  else
    cat <<'SQL'
SELECT 'control session ' || :'hq_session'
       || coalesce(' (replaces ' || (SELECT value FROM prev WHERE value <> :'hq_session') || ')', '');
SQL
  fi
}

cmd_run() {
  local session="" have=0 json=0 errf out rc

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --json) json=1 ;;
      -*) hq_die_validation "register-control: unknown $(hq_flag_name "$1") (run human-queue.sh register-control --help)" ;;
      *)
        if [ "$have" -eq 1 ]; then hq_die_validation "register-control: takes one session id"; fi
        have=1
        session="$1"
        ;;
    esac
    shift
  done
  if [ "$have" -eq 0 ]; then
    hq_die_validation "register-control: missing session id (run human-queue.sh register-control --help)"
  fi
  hq_check_text "register-control: the session id" "$session" 200
  hq_refuse_secret "register-control: the session id" "$session"

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__register_sql "$json" | hq_db_script -At -v "hq_session=$session" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "register-control: nothing was recorded"
  fi
  if [ -z "$out" ]; then
    hq_die_error "register-control: the store returned nothing"
  fi
  printf '%s\n' "$out"
}
