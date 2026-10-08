# shellcheck shell=bash
# summary: read or set the desk's interrupt rule: everything, away, or focus until a time
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"
# shellcheck source=../lib/interrupts.sh
. "$HQ_BIN_DIR/lib/interrupts.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh interrupt — the desk's interrupt rule (issue #1783).

USAGE
  human-queue.sh interrupt get --session SESSION [--default RULE] [--json]
  human-queue.sh interrupt set everything --session SESSION [--json]
  human-queue.sh interrupt set away --session SESSION [--json]
  human-queue.sh interrupt set focus --session SESSION (--until WHEN | --for MINUTES) [--json]

THE RULES
  everything  every new Decision reaches the desk at its next tick, in sets
              (loud by default: the operator tunes it down item by item)
  away        nothing reaches the desk until the rule changes
  focus       nothing reaches the desk until WHEN; the first tick after it
              shows everything that arrived meanwhile

ARGUMENTS
  --session SESSION  the desk's control session. `set` refuses any other
                     session (exit 4): only the desk sets the rule. The rule
                     belongs to that session, so a desk registered later
                     starts from the default.
  --default RULE     everything or away (default everything): the rule in
                     force when SESSION has set none, or after its focus
                     ended. The desk passes desk/policy.json's interrupt_rule.
  --until WHEN       when a focus ends, at most a day ahead:
                       15:30, 9:05, 0:15    24-hour clock time
                       3:30, 3               12-hour, am or pm, whichever
                                             comes first
                       3:30pm, 3pm, 9 am     12-hour, as written
                       2026-10-07T19:30Z     an ISO 8601 time with a zone
                     A clock time is in the desk's calendar (America/New_York)
                     and means its next occurrence, on the store's clock; it
                     may end in ` ET`. Blank space around WHEN is ignored.
                     Across a daylight-saving change, a time the clock shows
                     twice means its next showing, and one the clock skips
                     means the moment the clock jumps past it.
  --for MINUTES      a focus of 1 to 1440 minutes from now
  --json             print the result as JSON

BEHAVIOR
  `set` stores the rule under the reserved state key `interrupt` (`state set`
  refuses it), replacing any earlier one; state is not an item, so no event
  is recorded. `get` and `set` print the rule in force now: a focus whose
  time has passed is over, and the default is in force again.
  `tick --session SESSION --interrupts RULE` reads the same rule and, while it
  holds items back, stamps tick_at without moving the change feed's
  watermark (`tick --help`).
  The operator's day plan (`plan --help`, issue #1784) holds too: while one
  of its blocks is in force, the rule is `focus until <the block's end>`,
  source plan, unless this session set `away`, a focus not yet over, or
  `everything` during that block (which releases that block only).

OUTPUT
  One line: `everything`, `away`, or `focus until 15:30 ET
  (2026-10-07 19:30 UTC)`, ending ` (default)` when the rule in force is the
  default rather than one the session set, or ` (plan)` when a block of the
  day plan holds. With --json:
    {"rule": "focus", "until": "2026-10-07T19:30:00Z", "until_local":
     "15:30", "held": true, "source": "desk"}
  until and until_local are null unless the rule is focus; source is desk,
  plan, or default. Nothing on stderr on success.

EXIT CODES
  0  ok
  1  unexpected database failure
  4  a missing or unknown action or rule, a missing --session, --until or
     --for with a rule other than focus (or neither, or both, with focus), a
     malformed time, a stray argument (before any connection attempt); a
     focus time in the past or more than a day ahead, or `set` from a session
     that is not the registered control session (after connecting, nothing
     written)
  5  the session id looks like a secret (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# hq__interrupt_clock WHEN — a clock time into HQ_INT_TIMES, the candidate
# 24-hour times (HH:MM, comma-separated) it may mean; returns 1 when WHEN is
# not a clock time. A 12-hour time without am or pm has two candidates.
HQ_INT_TIMES=""
hq__interrupt_clock() {
  local LC_ALL=C re h m ap
  re='^([0-9]{1,2})(:([0-5][0-9]))?[[:space:]]?([AaPp][Mm])?([[:space:]]+[Ee][Tt])?$'
  [[ $1 =~ $re ]] || return 1
  h=$((10#${BASH_REMATCH[1]}))
  m="${BASH_REMATCH[3]:-00}"
  ap="${BASH_REMATCH[4]}"
  if [ -n "$ap" ]; then
    if [ "$h" -lt 1 ] || [ "$h" -gt 12 ]; then return 1; fi
    h=$((h % 12))
    case "$ap" in
      [Pp]*) h=$((h + 12)) ;;
    esac
    HQ_INT_TIMES=$(printf '%02d:%s' "$h" "$m")
    return 0
  fi
  if [ "$h" -gt 23 ]; then return 1; fi
  if [ "$h" -ge 1 ] && [ "$h" -le 12 ]; then
    HQ_INT_TIMES=$(printf '%02d:%s,%02d:%s' "$((h % 12))" "$m" "$((h % 12 + 12))" "$m")
  else
    HQ_INT_TIMES=$(printf '%02d:%s' "$h" "$m")
  fi
  return 0
}

# The rule in force, as text or JSON, from hq_sql_interrupt_row.
hq__interrupt_out_sql() {
  if [ "$1" -eq 1 ]; then
    cat <<'SQL'
SELECT jsonb_build_object(
         'rule', rule,
         'until', to_char(until AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
         'until_local', to_char(until AT TIME ZONE :'hq_tz', 'HH24:MI'),
         'held', held,
         'source', CASE source WHEN 'desk' THEN 'desk' WHEN 'plan' THEN 'plan' ELSE 'default' END)
  FROM (
SQL
  else
    cat <<'SQL'
SELECT rule
       || CASE WHEN until IS NULL THEN ''
               ELSE ' until ' || to_char(until AT TIME ZONE :'hq_tz', 'HH24:MI') || ' ET ('
                    || to_char(until AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC)' END
       || CASE source WHEN 'desk' THEN '' WHEN 'plan' THEN ' (plan)' ELSE ' (default)' END
  FROM (
SQL
  fi
  hq_sql_interrupt_row
  printf '%s\n' ') ir;'
}

# hq__interrupt_set_sql JSON — under register-control's lock, refuse a
# session that is not the control session, resolve the focus's end on the
# store's clock, refuse one in the past or more than a day ahead, store the
# rule, then print the rule in force.
hq__interrupt_set_sql() {
  cat <<'SQL'
SET LOCAL lock_timeout TO '30s';
SELECT pg_advisory_xact_lock(hashtextextended('human-queue:control:' || :'hq_schema', 0)) AS hq_control_locked \gset
SELECT coalesce((SELECT value FROM state WHERE key = 'control_session'), '') = :'hq_session' AS hq_ok \gset
\if :hq_ok
-- hq_until_raw is the end as given or worked out, to the microsecond; the
-- limits below judge it. hq_until, what is stored, is whole seconds rounded
-- up, so a fractional ISO --until never ends the focus early. Judging the
-- rounded value instead would refuse --for 1440 (the documented maximum)
-- whenever the clock is part-way through a second.
SELECT coalesce(to_char((date_trunc('second', u)
                          + CASE WHEN u > date_trunc('second', u) THEN interval '1 second'
                                 ELSE interval '0' END)
                         AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '') AS hq_until,
       coalesce(to_char(u AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), '') AS hq_until_raw
  FROM (SELECT CASE
                 WHEN :'hq_rule' <> 'focus' THEN NULL
                 WHEN :'hq_minutes' <> ''
                   THEN statement_timestamp() + make_interval(mins => nullif(:'hq_minutes', '')::int)
                 WHEN :'hq_at' <> '' THEN nullif(:'hq_at', '')::timestamptz
                 ELSE
SQL
  hq_sql_focus_until 'statement_timestamp()'
  cat <<'SQL'
               END AS u) f \gset
SELECT CASE
         WHEN :'hq_rule' <> 'focus' THEN ''
         WHEN :'hq_until_raw' = '' THEN 'the focus time could not be worked out'
         WHEN nullif(:'hq_until_raw', '')::timestamptz <= statement_timestamp() THEN 'the focus time is in the past'
         WHEN nullif(:'hq_until_raw', '')::timestamptz > statement_timestamp() + interval '24 hours'
           THEN 'the focus time is more than a day ahead (use away instead)'
         ELSE ''
       END AS hq_problem \gset
SELECT :'hq_problem' = '' AS hq_valid \gset
\if :hq_valid
INSERT INTO state (key, value)
  VALUES ('interrupt',
          jsonb_build_object(
            'session', :'hq_session',
            'rule', :'hq_rule',
            'until', nullif(:'hq_until', ''),
            'set_at', to_char(statement_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
SQL
  hq__interrupt_out_sql "$1"
  cat <<'SQL'
\else
SELECT '!' || :'hq_problem' || '; nothing was stored';
\endif
\else
SELECT '!this session is not the registered control session; only the desk sets the interrupt rule, and nothing was stored';
\endif
SQL
}

cmd_run() {
  local action="" rule="" session="" have_session=0 default_rule="everything" have_default=0
  local until="" have_until=0 minutes="" have_for=0 json=0 at="" times="" errf out rc
  case "${1:-}" in
    -h|--help)
      cmd_usage
      exit 0
      ;;
    '') hq_die_validation "interrupt: missing action: get or set (run human-queue.sh interrupt --help)" ;;
    get|set) action="$1" ;;
    -*) hq_die_validation "interrupt: unknown $(hq_flag_name "$1") (run human-queue.sh interrupt --help)" ;;
    *) hq_die_validation "interrupt: unknown action (expected get or set)" ;;
  esac
  shift
  if [ "$action" = set ]; then
    case "${1:-}" in
      everything|away|focus) rule="$1" ;;
      '') hq_die_validation "interrupt set: missing rule: everything, away, or focus" ;;
      -*) hq_die_validation "interrupt set: missing rule: everything, away, or focus (before $(hq_flag_name "$1"))" ;;
      *) hq_die_validation "interrupt set: the rule must be everything, away, or focus" ;;
    esac
    shift
  fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --json) json=1 ;;
      --session|--default|--until|--for)
        if [ "$#" -lt 2 ]; then hq_die_validation "interrupt: $1 needs a value"; fi
        case "$1" in
          --session)
            if [ "$have_session" -eq 1 ]; then hq_die_validation "interrupt: --session given more than once"; fi
            have_session=1
            session="$2"
            ;;
          --default)
            if [ "$have_default" -eq 1 ]; then hq_die_validation "interrupt: --default given more than once"; fi
            have_default=1
            default_rule="$2"
            ;;
          --until)
            if [ "$have_until" -eq 1 ]; then hq_die_validation "interrupt: --until given more than once"; fi
            have_until=1
            until="$2"
            ;;
          *)
            if [ "$have_for" -eq 1 ]; then hq_die_validation "interrupt: --for given more than once"; fi
            have_for=1
            minutes="$2"
            ;;
        esac
        shift
        ;;
      *) hq_die_validation "interrupt: unknown $(hq_flag_name "$1") (run human-queue.sh interrupt --help)" ;;
    esac
    shift
  done

  if [ "$have_session" -eq 0 ]; then
    hq_die_validation "interrupt $action: missing --session (the desk's control session)"
  fi
  hq_check_text "interrupt: the session id" "$session" 200
  if ! hq_interrupt_rule_ok "$default_rule"; then
    hq_die_validation "interrupt: --default must be everything or away"
  fi
  if [ "$action" = get ] || [ "$rule" != focus ]; then
    if [ "$have_until" -eq 1 ] || [ "$have_for" -eq 1 ]; then
      hq_die_validation "interrupt: --until and --for go only with set focus"
    fi
  else
    if [ "$have_until" -eq 1 ] && [ "$have_for" -eq 1 ]; then
      hq_die_validation "interrupt set focus: give --until or --for, not both"
    fi
    if [ "$have_until" -eq 0 ] && [ "$have_for" -eq 0 ]; then
      hq_die_validation "interrupt set focus: missing --until WHEN or --for MINUTES"
    fi
    if [ "$have_for" -eq 1 ]; then
      case "$minutes" in
        ''|*[!0-9]*) hq_die_validation "interrupt set focus: --for must be a whole number of minutes from 1 to 1440" ;;
      esac
      if [ "${#minutes}" -gt 4 ] || [ "$((10#$minutes))" -lt 1 ] || [ "$((10#$minutes))" -gt 1440 ]; then
        hq_die_validation "interrupt set focus: --for must be a whole number of minutes from 1 to 1440"
      fi
      minutes="$((10#$minutes))"
    else
      # Blank space around WHEN (a here-document's line, say) is not part of it.
      until="${until#"${until%%[![:space:]]*}"}"
      until="${until%"${until##*[![:space:]]}"}"
      if hq__interrupt_clock "$until"; then
        times="$HQ_INT_TIMES"
      else
        case "$until" in
          [0-9][0-9][0-9][0-9]-*) ;;
          *) hq_die_validation "interrupt set focus: --until must be a clock time (15:30, 3:30pm) or an ISO 8601 time with a zone" ;;
        esac
        hq_check_timestamp "interrupt set focus: --until" "$until"
        at="$until"
      fi
    fi
  fi
  # The session id reaches psql's argv: a secret-shaped one stops here.
  hq_refuse_secret "interrupt: the session id" "$session"

  hq_db_connect
  hq_mktemp errf
  rc=0
  if [ "$action" = get ]; then
    out=$(hq__interrupt_out_sql "$json" | hq_db_script -At -v "hq_session=$session" \
            -v "hq_default=$default_rule" -v "hq_tz=$(hq_desk_tz)" 2>"$errf") || rc=$?
  else
    out=$(hq__interrupt_set_sql "$json" | hq_db_script -At -v "hq_session=$session" \
            -v "hq_default=$default_rule" -v "hq_tz=$(hq_desk_tz)" -v "hq_rule=$rule" \
            -v "hq_minutes=$minutes" -v "hq_at=$at" -v "hq_times=$times" 2>"$errf") || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "interrupt $action: nothing was stored"
  fi
  hq_problem_check "interrupt $action" "$out"
  if [ -z "$out" ]; then
    hq_die_error "interrupt $action: the store returned nothing"
  fi
  printf '%s\n' "$out"
}
