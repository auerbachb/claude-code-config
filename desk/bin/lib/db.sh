# shellcheck shell=bash
# desk/bin/lib/db.sh — the only code that talks to the human-queue database.
# Sourced after lib/common.sh, never executed. Bash 3.2 compatible.
#
# CONNECTION
#   The connection comes only from HUMAN_QUEUE_DATABASE_URL
#   (postgres://user:password@host[:port]/dbname[?param=value&...]). The value
#   is a secret: it is never printed, logged, written to a file, or passed on a
#   command line (argv is visible to every local user through `ps`). Instead it
#   is parsed here into libpq variables (PGHOST, PGUSER, PGPASSWORD, ...) that
#   are exported ONLY inside the subshell that execs psql. Those subshells, and
#   the watchdogs, also drop HUMAN_QUEUE_DATABASE_URL itself, so no child this
#   library starts inherits the raw URL.
#
# TWO-SECOND BOUND
#   libpq's connect_timeout has a 2 s floor and applies per resolved address,
#   so it cannot bound a call by itself. hq_db_connect runs a `SELECT 1` probe
#   in the background under a HQ_CONNECT_DEADLINE (1.5 s) watchdog; a timeout,
#   refusal, DNS failure, or auth failure exits 7 with one stderr line. Real work
#   runs only after the probe succeeds. A Neon cold start slower than the
#   deadline reads as exit 7 — callers fail open and the next call finds the
#   compute awake.
#   Every later psql call is a new connection, so hq_psql bounds its connect
#   phase the same way: the first thing psql does once connected is write a
#   marker file, and a watchdog that finds no marker at the deadline kills it
#   (hq_db_fail maps that to exit 7). Once connected the watchdog stands down,
#   so SQL itself is never time-limited.
#
# PUBLIC FUNCTIONS
#   hq_db_connect          validate env + probe; exits 7 on any failure
#   hq_psql ARGS...        run psql with the scoped env (-X -w -q, ON_ERROR_STOP)
#                          under the connect-phase deadline; needs hq_db_connect
#   hq_db_script ARGS...   run the SQL script on stdin in ONE transaction with
#                          `SET LOCAL search_path` to hq_schema; ARGS are extra
#                          psql options (e.g. -At, -v name=value)
#   hq_db_fail RC ERRFILE CONTEXT
#                          map a failed psql run to the exit contract and exit

HQ_CONNECT_DEADLINE=1.5

# Parsed connection — shell variables, deliberately NOT exported.
HQ_PSQL=""
HQ_CONN_HOST=""
HQ_CONN_PORT=""
HQ_CONN_USER=""
HQ_CONN_PASSWORD=""
HQ_CONN_DBNAME=""
HQ_CONN_SSLMODE=""
HQ_CONN_CHANNELBINDING=""
HQ_CONN_SSLROOTCERT=""
HQ_CONN_SSLNEGOTIATION=""
HQ_CONN_OPTIONS=""
HQ_SCHEMA=""
# Connect marker for hq_psql's watchdog; created by hq_db_connect.
HQ_CONN_MARKER=""

# hq__find_psql — sets HQ_PSQL or exits 7.
hq__find_psql() {
  local p
  if [ -n "${HUMAN_QUEUE_PSQL:-}" ]; then
    if [ -x "$HUMAN_QUEUE_PSQL" ] && [ ! -d "$HUMAN_QUEUE_PSQL" ]; then
      HQ_PSQL="$HUMAN_QUEUE_PSQL"
      return 0
    fi
    hq_die_unavailable "HUMAN_QUEUE_PSQL is not an executable file — database unavailable"
  fi
  if [ -x /opt/homebrew/bin/psql ]; then
    HQ_PSQL=/opt/homebrew/bin/psql
    return 0
  fi
  if p=$(command -v psql 2>/dev/null) && [ -n "$p" ]; then
    HQ_PSQL="$p"
    return 0
  fi
  hq_die_unavailable "psql not found (/opt/homebrew/bin/psql or PATH) — database unavailable"
}

# hq__urldecode VAR VALUE — percent-decodes VALUE into VAR. Returns 1 on a
# malformed escape or an encoded NUL. Existing backslashes are escaped first so
# printf %b decodes only what the URL encoded. Locals are hq__-prefixed so the
# caller's VAR is never shadowed.
hq__urldecode() {
  local hq__var="$1" hq__s="$2" hq__rest hq__re='^[0-9A-Fa-f][0-9A-Fa-f]'
  case "$hq__s" in
    *%*) ;;
    *) printf -v "$hq__var" '%s' "$hq__s"; return 0 ;;
  esac
  hq__rest="$hq__s"
  while :; do
    case "$hq__rest" in
      *%*) hq__rest="${hq__rest#*%}" ;;
      *) break ;;
    esac
    [[ $hq__rest =~ $hq__re ]] || return 1
    case "$hq__rest" in 00*) return 1 ;; esac
  done
  hq__s="${hq__s//\\/\\\\}"
  hq__s="${hq__s//%/\\x}"
  printf -v "$hq__var" '%b' "$hq__s"
}

# hq__parse_url URL — fills HQ_CONN_*; returns 1 (malformed) or 2 (unsupported,
# with the parameter name in HQ__UNSUPPORTED). Follows libpq's own URI rules:
# credentials end at the first '@' before the first '/', the host ends at ':',
# '/' or '?', and the query is '&'-separated key=value pairs.
HQ__UNSUPPORTED=""
hq__parse_url() {
  local url="$1" rest userinfo="" hostport path="" query="" kv k v upto_slash

  case "$url" in
    postgresql://*) rest="${url#postgresql://}" ;;
    postgres://*)   rest="${url#postgres://}" ;;
    *) return 1 ;;
  esac
  case "$url" in *[[:space:]]*) return 1 ;; esac

  upto_slash="${rest%%/*}"
  case "$upto_slash" in
    *@*)
      userinfo="${upto_slash%%@*}"
      rest="${rest#*@}"
      ;;
  esac

  hostport="${rest%%[/?]*}"
  rest="${rest:${#hostport}}"
  case "$rest" in
    /*)
      rest="${rest#/}"
      path="${rest%%\?*}"
      case "$rest" in *\?*) query="${rest#*\?}" ;; esac
      ;;
    \?*)
      query="${rest#\?}"
      ;;
  esac

  # Host and port. Multi-host lists (a,b) are out of scope: the probe bounds
  # ONE target, and a list would multiply libpq's per-host connect timeout.
  case "$hostport" in *,*) HQ__UNSUPPORTED="multiple hosts"; return 2 ;; esac
  case "$hostport" in
    \[*\]*)
      HQ_CONN_HOST="${hostport#\[}"
      HQ_CONN_HOST="${HQ_CONN_HOST%%\]*}"
      v="${hostport#*\]}"
      case "$v" in
        '') ;;
        :*) HQ_CONN_PORT="${v#:}" ;;
        *) return 1 ;;
      esac
      ;;
    *:*)
      HQ_CONN_HOST="${hostport%%:*}"
      HQ_CONN_PORT="${hostport#*:}"
      ;;
    *)
      HQ_CONN_HOST="$hostport"
      ;;
  esac
  hq__urldecode HQ_CONN_HOST "$HQ_CONN_HOST" || return 1
  if [ -n "$HQ_CONN_PORT" ]; then
    case "$HQ_CONN_PORT" in *[!0-9]*) return 1 ;; esac
  fi

  # Credentials.
  if [ -n "$userinfo" ]; then
    case "$userinfo" in
      *:*)
        hq__urldecode HQ_CONN_USER "${userinfo%%:*}" || return 1
        hq__urldecode HQ_CONN_PASSWORD "${userinfo#*:}" || return 1
        ;;
      *)
        hq__urldecode HQ_CONN_USER "$userinfo" || return 1
        ;;
    esac
  fi

  hq__urldecode HQ_CONN_DBNAME "$path" || return 1

  # Query parameters: a short allow-list. Anything else is refused rather than
  # silently dropped — a dropped sslmode would downgrade the connection.
  while [ -n "$query" ]; do
    kv="${query%%&*}"
    case "$query" in *\&*) query="${query#*&}" ;; *) query="" ;; esac
    [ -n "$kv" ] || continue
    k="${kv%%=*}"
    case "$kv" in *=*) v="${kv#*=}" ;; *) v="" ;; esac
    hq__urldecode v "$v" || return 1
    case "$k" in
      sslmode)          HQ_CONN_SSLMODE="$v" ;;
      channel_binding)  HQ_CONN_CHANNELBINDING="$v" ;;
      sslrootcert)      HQ_CONN_SSLROOTCERT="$v" ;;
      sslnegotiation)   HQ_CONN_SSLNEGOTIATION="$v" ;;
      options)          HQ_CONN_OPTIONS="$v" ;;
      # Owned by this library (PGCONNECT_TIMEOUT / PGAPPNAME): ignored.
      connect_timeout|application_name) ;;
      *)
        case "$k" in *[!A-Za-z0-9_]*) k="(non-identifier)" ;; esac
        HQ__UNSUPPORTED="URL parameter '$k'"
        return 2
        ;;
    esac
  done
  return 0
}

# hq__child_env — exports the scoped libpq environment. Call ONLY inside the
# subshell that execs psql, never in the parent: PGPASSWORD must not leak into
# any other child process. The raw URL is dropped too — psql needs only the
# parsed variables, so it never inherits the password-bearing URL. Ambient
# session settings (PGOPTIONS, PGTZ, PGDATESTYLE, PGGEQO) are cleared as well:
# a statement_timeout or search_path left in the operator's shell for other
# Postgres work must not reach the queue. Only the URL's `options` applies.
hq__child_env() {
  unset HUMAN_QUEUE_DATABASE_URL \
    PGHOST PGHOSTADDR PGPORT PGDATABASE PGUSER PGPASSWORD PGPASSFILE \
    PGSERVICE PGSERVICEFILE PGSSLMODE PGREQUIRESSL PGCHANNELBINDING \
    PGSSLROOTCERT PGSSLNEGOTIATION PGTARGETSESSIONATTRS PGGSSENCMODE \
    PGREQUIREAUTH PGLOADBALANCEHOSTS \
    PGOPTIONS PGTZ PGDATESTYLE PGGEQO
  if [ -n "$HQ_CONN_HOST" ]; then export PGHOST="$HQ_CONN_HOST"; fi
  if [ -n "$HQ_CONN_PORT" ]; then export PGPORT="$HQ_CONN_PORT"; fi
  if [ -n "$HQ_CONN_USER" ]; then export PGUSER="$HQ_CONN_USER"; fi
  if [ -n "$HQ_CONN_PASSWORD" ]; then export PGPASSWORD="$HQ_CONN_PASSWORD"; fi
  if [ -n "$HQ_CONN_DBNAME" ]; then export PGDATABASE="$HQ_CONN_DBNAME"; fi
  if [ -n "$HQ_CONN_SSLMODE" ]; then export PGSSLMODE="$HQ_CONN_SSLMODE"; fi
  if [ -n "$HQ_CONN_CHANNELBINDING" ]; then export PGCHANNELBINDING="$HQ_CONN_CHANNELBINDING"; fi
  if [ -n "$HQ_CONN_SSLROOTCERT" ]; then export PGSSLROOTCERT="$HQ_CONN_SSLROOTCERT"; fi
  if [ -n "$HQ_CONN_SSLNEGOTIATION" ]; then export PGSSLNEGOTIATION="$HQ_CONN_SSLNEGOTIATION"; fi
  if [ -n "$HQ_CONN_OPTIONS" ]; then export PGOPTIONS="$HQ_CONN_OPTIONS"; fi
  # GSS encryption is attempted before TLS by default; Neon offers none, and a
  # misconfigured Kerberos setup can stall the attempt.
  export PGGSSENCMODE=disable
  export PGCONNECT_TIMEOUT=2
  export PGAPPNAME=human-queue
  export PGCLIENTENCODING=UTF8
}

# hq_psql ARGS... — psql with the scoped env. -X: never read ~/.psqlrc.
# -w: never prompt for a password (a prompt would hang a hook).
# Needs hq_db_connect (for HQ_CONN_MARKER). psql connects before it runs any
# command, so the three leading -c actions write the marker only once the
# connection is up; the watchdog kills psql (status 143) if the marker is
# still empty at HQ_CONNECT_DEADLINE and otherwise does nothing. stdin is
# passed through explicitly: bash 3.2 gives a background job /dev/null.
hq_psql() {
  local hq__pid hq__wd hq__rc=0
  if [ -z "$HQ_CONN_MARKER" ] || ! : 2>/dev/null >"$HQ_CONN_MARKER"; then
    hq_die_error "hq_psql: no connect marker (call hq_db_connect first)"
  fi
  (
    hq__child_env
    exec "$HQ_PSQL" -X -w -q -v ON_ERROR_STOP=1 -v "hq_marker=$HQ_CONN_MARKER" \
      -c '\o :hq_marker' -c '\qecho connected' -c '\o' "$@"
  ) <&0 &
  hq__pid=$!
  (
    unset HUMAN_QUEUE_DATABASE_URL
    sleep "$HQ_CONNECT_DEADLINE"
    if [ ! -s "$HQ_CONN_MARKER" ]; then kill -TERM "$hq__pid" 2>/dev/null; fi
  ) </dev/null >/dev/null 2>&1 &
  hq__wd=$!
  wait "$hq__pid" || hq__rc=$?
  kill -TERM "$hq__wd" 2>/dev/null || true
  wait "$hq__wd" 2>/dev/null || true
  return "$hq__rc"
}

# hq_db_connect — exits 4 on a bad HUMAN_QUEUE_SCHEMA, 7 on anything that
# makes the database unusable; returns 0 once a probe query has succeeded.
hq_db_connect() {
  local rc pid wd

  HQ_SCHEMA=$(hq_schema) || exit "$?"

  if [ -z "${HUMAN_QUEUE_DATABASE_URL:-}" ]; then
    hq_die_unavailable "HUMAN_QUEUE_DATABASE_URL is not set — database unavailable"
  fi
  # The URL is checked before the client is looked up, so a configuration
  # error is named the same way on a machine with or without psql.
  rc=0
  hq__parse_url "$HUMAN_QUEUE_DATABASE_URL" || rc=$?
  if [ "$rc" -eq 2 ]; then
    hq_die_unavailable "HUMAN_QUEUE_DATABASE_URL uses an unsupported form ($HQ__UNSUPPORTED) — database unavailable"
  elif [ "$rc" -ne 0 ]; then
    hq_die_unavailable "HUMAN_QUEUE_DATABASE_URL is not a valid postgres:// URL — database unavailable"
  fi
  hq__find_psql

  # Probe under a watchdog. Both background jobs get /dev/null for every stdio
  # stream, so neither can hold a caller's $(...) pipe open after we return.
  ( hq__child_env; exec "$HQ_PSQL" -X -w -q -At -c 'SELECT 1' ) </dev/null >/dev/null 2>&1 &
  pid=$!
  ( unset HUMAN_QUEUE_DATABASE_URL; sleep "$HQ_CONNECT_DEADLINE"; kill -TERM "$pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
  wd=$!
  rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill -TERM "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true

  case "$rc" in
    0)
      hq_mktemp HQ_CONN_MARKER
      return 0
      ;;
    143) hq_die_unavailable "database unreachable (no connection within ${HQ_CONNECT_DEADLINE}s)" ;;
    2) hq_die_unavailable "database unreachable (connection refused, failed, or rejected)" ;;
    *) hq_die_unavailable "database unreachable (probe failed with psql status $rc)" ;;
  esac
}

# hq_db_script ARGS... — runs the SQL script on stdin as ONE transaction in
# hq_schema. Scripts may use psql variables (`:'name'`, `:"name"`) and
# meta-commands (\gset, \if); `:"hq_schema"` is always defined.
hq_db_script() {
  {
    printf '%s\n' 'SET LOCAL client_min_messages TO warning;'
    printf '%s\n' 'SET LOCAL search_path TO :"hq_schema";'
    cat
  } | hq_psql --single-transaction -v "hq_schema=$HQ_SCHEMA" "$@" -f -
}

# hq_db_fail RC ERRFILE CONTEXT — maps a failed psql run and exits.
#   psql 2 (connection lost / refused) -> 7, 143 (hq_psql's connect deadline
#   killed it) -> 7, anything else -> 1, quoting the first ERROR/FATAL line psql
#   wrote (never the URL: psql does not print it).
hq_db_fail() {
  local rc="$1" errfile="$2" context="$3" line
  if [ "$rc" -eq 2 ]; then
    hq_die_unavailable "$context: database connection lost"
  fi
  if [ "$rc" -eq 143 ]; then
    hq_die_unavailable "$context: database unreachable (no connection within ${HQ_CONNECT_DEADLINE}s)"
  fi
  line=$(grep -m1 -E 'ERROR:|FATAL:' "$errfile" 2>/dev/null || true)
  if [ -z "$line" ]; then
    line=$(grep -m1 -v '^[[:space:]]*$' "$errfile" 2>/dev/null || true)
  fi
  line="${line#psql:*: }"
  hq_die_error "$context: ${line:-psql exited $rc}"
}
