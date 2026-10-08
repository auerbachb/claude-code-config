# shellcheck shell=bash
# desk/bin/lib/todo.sh — the operator's personal to-do layer on items (issue
# #1769): tags, a note, a snooze, and a personal priority, shared by `tag`,
# `untag`, `note`, `snooze`, `unsnooze`, `mine`, and `my`. Sourced after
# lib/common.sh, lib/db.sh, lib/items.sh, and lib/lifecycle.sh (and
# lib/interrupts.sh for snooze's clock times); never executed. Bash 3.2
# compatible.
#
# THE FIELDS (migration 010_todo_layer.sql)
#   my_tags        lowercase hyphenated words, at most HQ_TODO_MAX_TAGS
#   my_note        one line, at most HQ_TODO_NOTE_MAX characters
#   my_priority    1 (highest) to 5
#   snoozed_until  while in the future, `my list` hides the item
#   Any item, Decision or Review, may carry them. They are the operator's own
#   annotations: writing one is not a change `tick` reports (010 keeps the
#   row's change marker), and the queue itself (sets, the sweep, wake-ups)
#   ignores them, except that the paper copy prints them.
#   Unrelated to /pm's backlog order (`pm-priority.sh`, issue numbers): this
#   is the order of the operator's own list of desk items.
#
# PUBLIC FUNCTIONS
#   hq_todo_tag CMD VAR RAW     RAW as a stored tag into VAR: a leading `#`
#                               dropped, folded to lowercase; exits 4 unless
#                               it is words of [a-z0-9] joined by single
#                               hyphens, at most 32 characters, with a letter
#   hq_todo_tags CMD VAR ARGS...
#                               every ARG through hq_todo_tag, duplicates
#                               dropped, joined by commas into VAR
#   hq_todo_check_note TEXT     the note: one line, not blank, at most
#                               HQ_TODO_NOTE_MAX characters (exit 4), and not
#                               secret-shaped (exit 5; needs lib/secrets.sh)
#   hq_todo_when WORDS          snooze's WHEN into the HQ_TODO_* variables
#                               below; exits 4 when it is not one
#   hq_todo_duration WORDS      snooze's DURATION into HQ_TODO_MINUTES; exits 4
#   hq_sql_todo_when            SQL expression: the snooze time the HQ_TODO_*
#                               variables (hq_todo_run passes them as psql
#                               variables) name, on the store's clock in
#                               :'hq_tz'
#   hq_sql_todo_write FIELD NEW PROBLEM KIND NOTE JSON
#                               the locked write every to-do command runs
#   hq_todo_run CMD JSON SQL ARGS...
#                               connects, runs SQL (hq_sql_todo_write's
#                               script) with ARGS as extra psql options, maps
#                               failures, and prints the result
#
# THE WRITE
#   One transaction: lock the item's row, then in the next statement (a fresh
#   snapshot) work out the field's new value from the row as it is now, and
#   write it only when it differs, with exactly one event. Writing the value
#   the item already has is a no-op: exit 0, no event. A refusal found after
#   connecting (no such item, more tags than allowed, a snooze time in the
#   past) writes nothing and prints `!<reason>` (lib/lifecycle.sh's problem
#   protocol). Before migration 010 the columns do not exist, and every
#   command exits 1 naming `migrate`.

HQ_TODO_MAX_TAGS=10
HQ_TODO_TAG_MAX=32
HQ_TODO_NOTE_MAX=1000
# A snooze ends at most this many days ahead.
HQ_TODO_SNOOZE_DAYS=366

hq_todo_tag() {
  local LC_ALL=C hq__cmd="$1" hq__v="$3" re='^[a-z0-9]+(-[a-z0-9]+)*$'
  hq__v="${hq__v#\#}"
  hq__v=$(printf '%s' "$hq__v" | tr '[:upper:]' '[:lower:]')
  if [ -z "$hq__v" ] || [ "${#hq__v}" -gt "$HQ_TODO_TAG_MAX" ] || ! [[ $hq__v =~ $re ]]; then
    hq_die_validation "$hq__cmd: a tag is lowercase letters and digits, words joined by single hyphens, at most $HQ_TODO_TAG_MAX characters (for example prd or call-back)"
  fi
  case "$hq__v" in
    *[a-z]*) ;;
    *) hq_die_validation "$hq__cmd: a tag needs a letter (an all-digit tag would read as an issue number)" ;;
  esac
  printf -v "$2" '%s' "$hq__v"
}

hq_todo_tags() {
  local hq__cmd="$1" hq__var="$2" hq__all="" hq__t hq__a hq__n=0
  shift 2
  for hq__a in "$@"; do
    hq_todo_tag "$hq__cmd" hq__t "$hq__a"
    case ",$hq__all," in
      *",$hq__t,"*) continue ;;
    esac
    hq__all="${hq__all:+$hq__all,}$hq__t"
    hq__n=$((hq__n + 1))
  done
  if [ "$hq__n" -eq 0 ]; then
    hq_die_validation "$hq__cmd: missing tag (run human-queue.sh $hq__cmd --help)"
  fi
  if [ "$hq__n" -gt "$HQ_TODO_MAX_TAGS" ]; then
    hq_die_validation "$hq__cmd: at most $HQ_TODO_MAX_TAGS tags"
  fi
  printf -v "$hq__var" '%s' "$hq__all"
}

hq_todo_check_note() {
  hq_check_text "note: the note" "$1" "$HQ_TODO_NOTE_MAX"
  hq_refuse_secret "note: the note" "$1"
}

# Snooze's WHEN, worked out by hq_todo_when and read by hq_sql_todo_when:
#   HQ_TODO_AT       an ISO 8601 time with a zone, as given
#   HQ_TODO_DAY      date | tomorrow | weekday, when WHEN names a day
#   HQ_TODO_DAYVAL   the date (YYYY-MM-DD), or the ISO weekday (1 Monday … 7)
#   HQ_TODO_TIMES    candidate clock times (HH:MM, comma-separated): with a
#                    day, the one 24-hour time; without, every reading
#   HQ_TODO_MINUTES  a duration in minutes (`snooze … for`)
HQ_TODO_AT=""
HQ_TODO_DAY=""
HQ_TODO_DAYVAL=""
HQ_TODO_TIMES=""
HQ_TODO_MINUTES=""

# hq__todo_weekday WORD — the ISO weekday number of WORD (mon … sunday), or
# returns 1.
hq__todo_weekday() {
  case "$1" in
    mon|monday) printf '1' ;;
    tue|tues|tuesday) printf '2' ;;
    wed|wednesday) printf '3' ;;
    thu|thur|thurs|thursday) printf '4' ;;
    fri|friday) printf '5' ;;
    sat|saturday) printf '6' ;;
    sun|sunday) printf '7' ;;
    *) return 1 ;;
  esac
}

HQ_TODO_WHEN_HELP="tomorrow, a weekday, YYYY-MM-DD, a clock time (15:30, 3pm), a day and a time (friday 9am), or an ISO 8601 time with a zone"

hq_todo_when() {
  local LC_ALL=C hq__w="$1" hq__day hq__rest="" hq__wd
  local hq__iso='^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt ][0-9]{2}:[0-9]{2}.*([Zz]|[+-][0-9]{2}(:?[0-9]{2})?)$'
  # Blank space around WHEN (a here-document's line, say) is not part of it.
  hq__w="${hq__w#"${hq__w%%[![:space:]]*}"}"
  hq__w="${hq__w%"${hq__w##*[![:space:]]}"}"
  HQ_TODO_AT="" HQ_TODO_DAY="" HQ_TODO_DAYVAL="" HQ_TODO_TIMES="" HQ_TODO_MINUTES=""
  if [ -z "$hq__w" ]; then
    hq_die_validation "snooze: missing WHEN ($HQ_TODO_WHEN_HELP)"
  fi
  case "$hq__w" in
    *$'\n'*|*$'\r'*) hq_die_validation "snooze: WHEN must be one line" ;;
  esac
  # An ISO 8601 time: a date joined to a time by T or one space, then a zone.
  if [[ $hq__w =~ $hq__iso ]]; then
    hq_check_timestamp "snooze: WHEN" "$hq__w"
    HQ_TODO_AT="$hq__w"
    return 0
  fi
  hq__w=$(printf '%s' "$hq__w" | tr '[:upper:]' '[:lower:]')
  hq__day="${hq__w%%[[:space:]]*}"
  if [ "$hq__day" != "$hq__w" ]; then
    hq__rest="${hq__w#"$hq__day"}"
    hq__rest="${hq__rest#"${hq__rest%%[![:space:]]*}"}"
  fi
  case "$hq__day" in
    tomorrow)
      HQ_TODO_DAY='tomorrow'
      ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
      # A real calendar date: checked as that day's midnight.
      hq_check_timestamp "snooze: WHEN" "${hq__day}T00:00Z"
      HQ_TODO_DAY='date'
      HQ_TODO_DAYVAL="$hq__day"
      ;;
    *)
      if hq__wd=$(hq__todo_weekday "$hq__day"); then
        HQ_TODO_DAY='weekday'
        HQ_TODO_DAYVAL="$hq__wd"
      fi
      ;;
  esac
  if [ -z "$HQ_TODO_DAY" ]; then
    # No day: the whole of WHEN is a clock time, its next occurrence.
    if ! hq_clock_times "$hq__w"; then
      hq_die_validation "snooze: WHEN must be $HQ_TODO_WHEN_HELP"
    fi
    HQ_TODO_TIMES="$HQ_INT_TIMES"
    return 0
  fi
  if [ -n "$hq__rest" ]; then
    # A day and a time: that day, at the time on the 24-hour clock unless it
    # says am or pm.
    hq__rest="${hq__rest#at }"
    if ! hq_clock_times "$hq__rest"; then
      hq_die_validation "snooze: WHEN must be $HQ_TODO_WHEN_HELP"
    fi
    HQ_TODO_TIMES="$HQ_CLOCK_24"
  fi
  return 0
}

hq_todo_duration() {
  local LC_ALL=C hq__d="$1" re='^([0-9]{1,6})[[:space:]]*([a-z]+)$' hq__n hq__per
  hq__d="${hq__d#"${hq__d%%[![:space:]]*}"}"
  hq__d="${hq__d%"${hq__d##*[![:space:]]}"}"
  hq__d=$(printf '%s' "$hq__d" | tr '[:upper:]' '[:lower:]')
  if ! [[ $hq__d =~ $re ]]; then
    hq_die_validation "snooze: DURATION must be a whole number and a unit (30m, 2h, 3 days, 1w)"
  fi
  hq__n=$((10#${BASH_REMATCH[1]}))
  case "${BASH_REMATCH[2]}" in
    m|min|mins|minute|minutes) hq__per=1 ;;
    h|hr|hrs|hour|hours) hq__per=60 ;;
    d|day|days) hq__per=1440 ;;
    w|wk|wks|week|weeks) hq__per=10080 ;;
    *) hq_die_validation "snooze: DURATION's unit must be minutes, hours, days, or weeks (30m, 2h, 3d, 1w)" ;;
  esac
  hq__n=$((hq__n * hq__per))
  if [ "$hq__n" -lt 1 ] || [ "$hq__n" -gt $((HQ_TODO_SNOOZE_DAYS * 1440)) ]; then
    hq_die_validation "snooze: DURATION must be from 1 minute to $HQ_TODO_SNOOZE_DAYS days"
  fi
  HQ_TODO_AT="" HQ_TODO_DAY="" HQ_TODO_DAYVAL="" HQ_TODO_TIMES=""
  HQ_TODO_MINUTES="$hq__n"
}

# The SQL below lives in functions (not heredocs inside $(...)) because bash
# 3.2's command-substitution scanner does not understand here-documents.

# hq_sql_todo_when — the snooze time, a timestamptz (NULL when a clock time
# has no occurrence in the next 24 hours, which cannot happen for a real
# time). A duration ends on the whole minute at or after now plus it; a day
# starts at 00:00 in :'hq_tz' unless a time is given; `tomorrow` and a
# weekday are counted from today on the store's clock in :'hq_tz', a weekday
# meaning its next occurrence after today (`friday` on a Friday is a week
# ahead). Local times go through `AT TIME ZONE`, so a time a daylight-saving
# change skips is read as if the clock had not jumped yet.
hq_sql_todo_when() {
  cat <<'SQL'
(SELECT CASE
          WHEN :'hq_minutes' <> '' THEN
            date_trunc('minute', statement_timestamp() + make_interval(mins => nullif(:'hq_minutes', '')::int) - interval '1 microsecond')
            + interval '1 minute'
          WHEN :'hq_at' <> '' THEN nullif(:'hq_at', '')::timestamptz
          WHEN :'hq_day' <> '' THEN
            ((CASE :'hq_day'
                WHEN 'date' THEN nullif(:'hq_dayval', '')::date
                WHEN 'tomorrow' THEN w.today + 1
                ELSE w.today + ((nullif(:'hq_dayval', '')::int - extract(isodow FROM w.today)::int + 6) % 7 + 1)
              END) + coalesce(nullif(:'hq_times', '')::time, time '00:00')) AT TIME ZONE :'hq_tz'
          ELSE
SQL
  hq_sql_focus_until 'statement_timestamp()'
  cat <<'SQL'
        END
   FROM (SELECT (statement_timestamp() AT TIME ZONE :'hq_tz')::date AS today) w)
SQL
}

# hq_sql_todo_write FIELD NEW PROBLEM KIND NOTE JSON — the locked write.
#   FIELD    the items column written (a constant from the command file)
#   NEW      SQL expression for the new value, reading the current row as
#            `cur` (any psql variables it needs are the command's)
#   PROBLEM  SQL expression: NULL, or the reason to refuse (ids, numbers,
#            and fixed words only, never free text), reading `cur` and the
#            new value as `nxt.v`
#   KIND     the event kind recorded when the value changes
#   NOTE     SQL expression: the event's note, reading the row before as
#            `cur` and after as `u` (cut to the 200 characters events allow)
#   JSON     1: print the item's to-do fields as JSON; 0: its id
# Every value reaches SQL as a psql variable; only these constant fragments
# are spliced in.
hq_sql_todo_write() {
  local field="$1" new="$2" problem="$3" kind="$4" note="$5" json="$6"
  hq_sql_lock_item "NO KEY UPDATE"
  cat <<SQL
WITH cur AS (
  SELECT i.* FROM items i WHERE i.id = :'hq_id'
), nxt AS (
  SELECT cur.id, ($new) AS v FROM cur
), chk AS (
  SELECT nxt.id, nxt.v, ($problem)::text AS problem FROM nxt, cur
), upd AS (
  UPDATE items i SET $field = chk.v FROM chk
   WHERE i.id = chk.id AND chk.problem IS NULL AND i.$field IS DISTINCT FROM chk.v
  RETURNING i.*
), ev AS (
  INSERT INTO events (item_id, kind, note)
  SELECT u.id, '$kind', left(($note)::text, 200) FROM upd u, cur
  RETURNING 1
)
SELECT CASE
         WHEN :hq_n = 0 THEN '!no item ' || :'hq_id'
         WHEN (SELECT problem FROM chk) IS NOT NULL THEN '!' || (SELECT problem FROM chk)
SQL
  if [ "$json" -eq 1 ]; then
    cat <<'SQL'
         ELSE (SELECT jsonb_build_object(
                        'id', r.id,
                        'changed', EXISTS (SELECT 1 FROM upd),
                        'my_priority', r.my_priority,
                        'my_tags', to_jsonb(r.my_tags),
                        'my_note', r.my_note,
                        'snoozed_until', to_char(r.snoozed_until AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                        'snoozed_until_local', to_char(r.snoozed_until AT TIME ZONE :'hq_tz', 'Dy YYYY-MM-DD HH24:MI'))::text
                 FROM (SELECT * FROM upd
                       UNION ALL
                       SELECT * FROM cur WHERE NOT EXISTS (SELECT 1 FROM upd)) r)
       END;
SQL
  else
    cat <<'SQL'
         ELSE :'hq_id'
       END;
SQL
  fi
}

# hq_todo_run CMD JSON SQL ARGS... — runs SQL (the write's script) in one
# transaction with ARGS as extra psql options (:'hq_id' among them); prints
# the item's id (or its JSON). Exits 1 naming `migrate` before 010, 4 on a
# refusal, 7 when the store is unreachable. Called directly, never at the end
# of a pipeline: there it would run in a subshell, which does not inherit the
# EXIT trap that removes the temp files hq_db_connect and hq_mktemp make.
hq_todo_run() {
  local cmd="$1" json="$2" sql="$3" errf out rc=0
  shift 3
  hq_db_connect
  hq_mktemp errf
  # The snooze time's variables go to every write; only snooze's SQL reads
  # them, and they are empty unless hq_todo_when or hq_todo_duration ran.
  out=$(printf '%s\n' "$sql" | hq_db_script -At -v "hq_tz=$(hq_desk_tz)" \
          -v "hq_at=$HQ_TODO_AT" -v "hq_day=$HQ_TODO_DAY" -v "hq_dayval=$HQ_TODO_DAYVAL" \
          -v "hq_times=$HQ_TODO_TIMES" -v "hq_minutes=$HQ_TODO_MINUTES" "$@" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_fail_unmigrated "$rc" "$errf" "$cmd: nothing was changed" 'my_tags|my_note|my_priority|snoozed_until'
  fi
  hq_problem_check "$cmd" "$out" "; nothing was changed"
  case "$json:$out" in
    0:[DR]-[1-9]*|1:'{'*) ;;
    *) hq_die_error "$cmd: the store returned no item" ;;
  esac
  printf '%s\n' "$out"
}
