# shellcheck shell=bash
# summary: hide an item from my list until a time (to-do layer; unsnooze brings it back)
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"
# shellcheck source=../lib/interrupts.sh
. "$HQ_BIN_DIR/lib/interrupts.sh"
# shellcheck source=../lib/todo.sh
. "$HQ_BIN_DIR/lib/todo.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh snooze — hide an item from my list until a time (issue #1769).

USAGE
  human-queue.sh snooze ID until WHEN [--json]
  human-queue.sh snooze ID for DURATION [--json]
  (--until WHEN and --for DURATION are the same; WHEN and DURATION may be
  several words: snooze D-43 until friday 9am)

ARGUMENTS
  ID        any item id, for example D-43 or R-88 (d-43 is accepted)
  WHEN      when the item comes back, in the desk's calendar
            (America/New_York), on the store's clock:
              tomorrow             00:00 tomorrow
              friday, fri          00:00 on its next occurrence after today
                                   (`friday` on a Friday is a week ahead)
              2026-10-12           00:00 that day
              15:30, 3pm, 9 am     its next occurrence, within a day; a
                                   12-hour time without am or pm is whichever
                                   comes first (the `interrupt set focus`
                                   grammar); it may end in ` ET`
              friday 9am, tomorrow 14:30, 2026-10-12 at 8:15
                                   that day at that time; without am or pm
                                   the time is read on the 24-hour clock
                                   (`tomorrow 9:30` is 09:30, `friday 3` is
                                   03:00)
              2026-10-12T13:00Z    an ISO 8601 time with a zone
  DURATION  a whole number and a unit: 30m, 90 min, 2h, 3 days, 1w; the end
            is rounded up to the whole minute
  --json    print the item's to-do fields after the call, as `tag --json`
            does; snoozed_until_local is the end in the desk's calendar
            (`Fri 2026-10-09 09:00`)

BEHAVIOR
  While the time is in the future, `my list` hides the item (it counts it,
  and names when the next one comes back); at that time it reappears, with
  nothing to run. The queue itself is unchanged: a snoozed Decision still
  reaches the desk at the next tick, the sweep still lists it, and its
  thread still waits on it. The time must be in the future and at most 366
  days ahead. A new snooze replaces the old one; the same time again changes
  nothing and records nothing. Otherwise one `snoozed` event, note `until
  <the time, UTC>`. Not a change `tick` reports. `unsnooze` ends a snooze.

OUTPUT
  The canonical item id on stdout (JSON with --json). Nothing on stderr on
  success.

EXIT CODES
  0  ok (including the same time again)
  1  unexpected database failure (for example the store is not migrated:
     run human-queue.sh migrate)
  4  invalid id, a missing or malformed WHEN or DURATION, or a stray option
     (before any connection attempt); no item has that id, or the time is
     in the past or more than 366 days ahead (after connecting, nothing
     changed)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

cmd_run() {
  local id="" raw="" have_id=0 json=0 mode="" spec="" sql="" a
  for a in "$@"; do
    case "$a" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
    esac
  done
  for a in "$@"; do
    if [ -n "$mode" ]; then
      case "$a" in
        --json) json=1 ;;
        *) spec="${spec:+$spec }$a" ;;
      esac
      continue
    fi
    case "$a" in
      --json) json=1 ;;
      until|--until|for|--for)
        if [ "$have_id" -eq 0 ]; then
          hq_die_validation "snooze: missing item id before $a (run human-queue.sh snooze --help)"
        fi
        mode="${a#--}"
        ;;
      -*) hq_die_validation "snooze: unknown $(hq_flag_name "$a") (run human-queue.sh snooze --help)" ;;
      *)
        if [ "$have_id" -eq 1 ]; then
          hq_die_validation "snooze: say when: snooze ID until WHEN, or snooze ID for DURATION"
        fi
        have_id=1
        raw="$a"
        ;;
    esac
  done
  if [ "$have_id" -eq 0 ]; then
    hq_die_validation "snooze: missing item id (run human-queue.sh snooze --help)"
  fi
  hq_item_id id "$raw"
  case "$mode" in
    '') hq_die_validation "snooze: say when: snooze ID until WHEN, or snooze ID for DURATION" ;;
    until) hq_todo_when "$spec" ;;
    *)
      if [ -z "$spec" ]; then
        hq_die_validation "snooze: missing DURATION (30m, 2h, 3 days, 1w)"
      fi
      hq_todo_duration "$spec"
      ;;
  esac

  # The limit is elapsed time, not calendar days: 24-hour days as hours, so a
  # daylight-saving change in the session's time zone moves it by no hour.
  # It is rounded up to the whole minute exactly as a duration is, so
  # `for 366d` (the most a duration allows) is never refused for its rounding.
  sql=$(hq_sql_todo_write snoozed_until \
    "$(hq_sql_todo_when)" \
    "CASE WHEN nxt.v IS NULL THEN 'the snooze time could not be worked out'
          WHEN nxt.v <= statement_timestamp() THEN 'the snooze time is in the past'
          WHEN nxt.v > date_trunc('minute', statement_timestamp()
                                            + make_interval(hours => 24 * $HQ_TODO_SNOOZE_DAYS)
                                            - interval '1 microsecond') + interval '1 minute'
            THEN 'the snooze time is more than $HQ_TODO_SNOOZE_DAYS days ahead' END" \
    snoozed \
    "'until ' || to_char(u.snoozed_until AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')" \
    "$json")
  hq_todo_run snooze "$json" "$sql" -v "hq_id=$id"
}
