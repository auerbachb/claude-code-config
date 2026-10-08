# shellcheck shell=bash
# summary: read or write one key of operator state (state get KEY | state set KEY VALUE)
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"

HQ_STATE_VALUE_MAX=65536
# The value reaches psql as one argument, `hq_value=VALUE`, and Linux caps one
# argument at 131072 bytes (MAX_ARG_STRLEN). 65536 characters of multi-byte
# text can exceed that, so the UTF-8 size is capped too, with room to spare.
HQ_STATE_VALUE_MAX_BYTES=131000
# Owned by the subcommand named after each; `state set` refuses them.
HQ_STATE_RESERVED="tick_watermark tick_at control_session reviews_watermark interrupt plan eod_sweep checkin checkin_asked"

cmd_usage() {
  cat <<'EOF'
human-queue.sh state — read or write one key of operator state.

USAGE
  human-queue.sh state get KEY
  human-queue.sh state set KEY VALUE

ARGUMENTS
  KEY    1 to 200 characters of letters, digits, and _ . : / -
         (for example note or note:2026-10-05)
  VALUE  any text, up to 65536 characters (and 131000 bytes as UTF-8),
         lines included; may be empty. Quote it.

BEHAVIOR
  `get` prints the value stored under KEY exactly, followed by one newline.
  `set` stores VALUE under KEY, replacing any earlier value. State holds the
  desk's bookkeeping (the day plan has its own command, `plan`); it is not an
  item, so no event is recorded.

RESERVED KEYS (readable with get; `set` refuses them)
  interrupt        the desk's interrupt rule (JSON); written by `interrupt set`
  plan             the operator's day plan (JSON); written by `plan set`,
                   deleted by `plan clear`
  eod_sweep        the day the end-of-day sweep last ran (YYYY-MM-DD);
                   written by `sweep due`
  checkin          today's morning check-in and reading budget (JSON);
                   written by `checkin set`
  checkin_asked    the day the morning check-in was last due (YYYY-MM-DD);
                   written by `checkin due`
  tick_watermark   the snapshot the last `tick` read under; written by tick
  tick_at          when the last `tick` ran (UTC ISO 8601); written by tick,
                   cleared by register-control when the session changes
  control_session  the registered desk control session; written by
                   register-control
  reviews_watermark  the start of the last successful sync-reviews;
                   written by sync-reviews (move it with --since)
  filed:*          a pending desk filing, filed:<owner/name>:issue-<N>;
                   written by filed, deleted by filed or sync-reviews once
                   the issue's Review carries the event

SECRETS
  KEY and VALUE are checked for secret shapes before anything is sent; a
  match exits 5 and the value is never echoed.

OUTPUT
  get: the value. set: nothing. Nothing on stderr on success.

EXIT CODES
  0  ok
  1  unexpected database failure
  4  a missing or unknown action, a malformed key, a reserved key for set,
     a value over the limit, or a stray argument (before any connection
     attempt); get of a key that is not set (after connecting)
  5  the key or value looks like a secret (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# hq__state_key_ok KEY — LC_ALL=C so the class is a byte range, never a
# locale's collation range.
hq__state_key_ok() {
  local LC_ALL=C re='^[A-Za-z0-9_.:/-]+$'
  [ "${#1}" -ge 1 ] && [ "${#1}" -le 200 ] && [[ $1 =~ $re ]]
}

# hq__state_bytes VAR VALUE — VALUE's size in bytes (LC_ALL=C: ${#} counts
# bytes, whatever the caller's locale), into VAR.
hq__state_bytes() {
  local LC_ALL=C
  printf -v "$1" '%s' "${#2}"
}

# The value is framed by `v` on both sides, so an empty value and a missing
# key (no row: nothing printed) stay distinct, and a value's own trailing
# newlines survive the command substitution.
hq__state_get_sql() {
  printf '%s\n' "SELECT 'v' || value || 'v' FROM state WHERE key = :'hq_key';"
}

hq__state_set_sql() {
  cat <<'SQL'
INSERT INTO state (key, value) VALUES (:'hq_key', :'hq_value')
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
SQL
}

cmd_run() {
  local action="" key="" value="" n=0 nbytes errf out rc
  # --help in the action or key position; a VALUE is never read as a flag,
  # so `state set note --help` stores the text "--help".
  case "${1:-}" in
    -h|--help)
      cmd_usage
      exit 0
      ;;
  esac
  case "${2:-}" in
    -h|--help)
      cmd_usage
      exit 0
      ;;
  esac
  if [ "$#" -eq 0 ]; then
    hq_die_validation "state: missing action: get or set (run human-queue.sh state --help)"
  fi
  action="$1"
  shift
  case "$action" in
    get) n=1 ;;
    set) n=2 ;;
    -*) hq_die_validation "state: unknown $(hq_flag_name "$action") (run human-queue.sh state --help)" ;;
    *) hq_die_validation "state: unknown action (expected get or set)" ;;
  esac
  if [ "$#" -lt 1 ]; then
    hq_die_validation "state $action: missing key"
  fi
  key="$1"
  case "$key" in
    -*) hq_die_validation "state $action: unknown $(hq_flag_name "$key") (run human-queue.sh state --help)" ;;
  esac
  if ! hq__state_key_ok "$key"; then
    hq_die_validation "state $action: the key must be 1 to 200 letters, digits, or _ . : / -"
  fi
  if [ "$n" -eq 2 ]; then
    if [ "$#" -lt 2 ]; then
      hq_die_validation "state set: missing value (quote it; \"\" stores an empty value)"
    fi
    value="$2"
  fi
  if [ "$#" -gt "$n" ]; then
    hq_die_validation "state $action: too many arguments (quote a value that has spaces)"
  fi

  if [ "$action" = set ]; then
    if hq_in_list "$key" "$HQ_STATE_RESERVED"; then
      case "$key" in
        tick_watermark|tick_at) hq_die_validation "state set: $key is reserved: only tick writes it" ;;
        reviews_watermark) hq_die_validation "state set: reviews_watermark is reserved: only sync-reviews writes it (pass it --since instead)" ;;
        interrupt) hq_die_validation "state set: interrupt is reserved: use interrupt set" ;;
        plan) hq_die_validation "state set: plan is reserved: use plan set" ;;
        eod_sweep) hq_die_validation "state set: eod_sweep is reserved: only sweep due writes it" ;;
        checkin) hq_die_validation "state set: checkin is reserved: use checkin set" ;;
        checkin_asked) hq_die_validation "state set: checkin_asked is reserved: only checkin due writes it" ;;
        *) hq_die_validation "state set: control_session is reserved: use register-control" ;;
      esac
    fi
    case "$key" in
      filed:*) hq_die_validation "state set: filed:* keys are reserved: only filed writes them (and sync-reviews deletes them)" ;;
    esac
    if [ "${#value}" -gt "$HQ_STATE_VALUE_MAX" ]; then
      hq_die_validation "state set: the value is longer than $HQ_STATE_VALUE_MAX characters"
    fi
    hq__state_bytes nbytes "$value"
    if [ "$nbytes" -gt "$HQ_STATE_VALUE_MAX_BYTES" ]; then
      hq_die_validation "state set: the value is larger than $HQ_STATE_VALUE_MAX_BYTES bytes"
    fi
  fi
  # Both actions hand the key to psql's argv, so `get` checks it too.
  hq_refuse_secret "state $action: the key" "$key"
  if [ "$action" = set ]; then
    hq_refuse_secret "state set: the value" "$value"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  if [ "$action" = get ]; then
    out=$(hq__state_get_sql | hq_db_script -At -v "hq_key=$key" 2>"$errf") || rc=$?
  else
    out=$(hq__state_set_sql | hq_db_script -At -v "hq_key=$key" -v "hq_value=$value" 2>"$errf") || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "state $action"
  fi
  if [ "$action" = set ]; then
    return 0
  fi
  if [ -z "$out" ]; then
    hq_die_validation "state get: no value is set for $key"
  fi
  out="${out#v}"
  printf '%s\n' "${out%v}"
}
