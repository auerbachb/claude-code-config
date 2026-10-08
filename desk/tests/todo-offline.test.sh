#!/usr/bin/env bash
# desk/tests/todo-offline.test.sh — offline contract tests for the operator's
# to-do layer (issue #1769): tag, untag, note, snooze, unsnooze, mine, and my
# list. Needs no database and never connects to one: validation and secret
# refusal happen before any connection attempt, which the black-hole URL below
# proves (a connection attempt would take the full 1.5 s deadline).
#
# Asserts:
#   - each command's --help is offline (exit 0, stdout only, documented exit
#     codes) and human-queue.sh --help lists all seven
#   - every usage and validation error exits 4 with one stderr line and no
#     connection attempt: missing ids, tags, notes, priorities, WHEN and
#     DURATION; malformed tags (all digits, underscores, too long, eleven of
#     them); notes that are blank, two lines, over 1000 characters, or hold a
#     control character (never echoed); --clear with a value; WHEN that is
#     not a date, a weekday, a clock time, or ISO 8601; a DURATION out of
#     range; priorities outside 1 to 5; `my` without `list`, a bad --tag
#   - a secret-shaped note exits 5 and is never echoed
#   - valid calls reach the database step (exit 7 with the URL unset): every
#     WHEN and DURATION shape the help documents; a note after `--` that reads
#     as an option (--clear, --json, --help) is a note, and `--` misplaced or
#     followed by more than one argument exits 4
#   - snooze's WHEN parser, called directly: which day, which clock times
#     (a 12-hour time without a day has two readings, with a day one, on the
#     24-hour clock), ISO kept as given, durations in minutes
#   - desk.jq's todo_line on fixtures, and sweep_lines' nested line (the
#     paper copy, AC 4.3) only for an item that carries the fields
#   - the skill: todo.md's anchored blocks extract and parse, the note goes
#     through a quoted here-document and after `--`, a note holding the
#     delimiter gets another one, and SKILL.md routes the verbs to it
#
# Every case runs under `bash` on PATH and, when /bin/bash is 3.x (macOS),
# under /bin/bash too. Token-shaped values are assembled at run time so this
# file never contains one verbatim.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-todo-offline-test.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

BLACKHOLE_URL="postgresql://u:pw@192.0.2.1:5432/db?sslmode=require"

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi

ALNUM36="abcdefghijklmnopqrstuvwxyz0123456789"
FAKE_GH="gh""p_$ALNUM36"
CMDS="tag untag note snooze unsnooze mine my"

# run_cli SHELL ARGS... — the CLI against the black-hole URL; sets OUT, ERR,
# RC, ELAPSED_START, ELAPSED_END.
run_cli() {
  local sh="$1"
  shift
  ELAPSED_START=$(hq_t_now)
  RC=0
  env HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" "$sh" "$HQ_T_CLI" "$@" \
    >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  ELAPSED_END=$(hq_t_now)
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# expect_rc SHELL CODE LABEL NEEDLE ARGS... — exit CODE, one stderr line
# containing NEEDLE, nothing on stdout, and no connection attempt.
expect_rc() {
  local sh="$1" code="$2" label="$3" needle="$4"
  shift 4
  run_cli "$sh" "$@"
  check "[$sh] $label: exit $code" "$RC" "$code"
  check "[$sh] $label: one stderr line" "$(hq_t_lines "$ERR")" "1"
  check "[$sh] $label: nothing on stdout" "$OUT" ""
  if [ -n "$needle" ]; then check_contains "[$sh] $label: names it" "$ERR" "$needle"; fi
  if hq_t_elapsed_under "$ELAPSED_START" "$ELAPSED_END" 1.0; then
    ok "[$sh] $label (no connection attempt)"
  else
    bad "[$sh] $label took $(hq_t_elapsed "$ELAPSED_START" "$ELAPSED_END")s — it tried to connect"
  fi
}

# expect_db SHELL LABEL ARGS... — valid input reaches the database step: with
# the URL unset that is exit 7.
expect_db() {
  local sh="$1" label="$2" rc=0
  shift 2
  env -u HUMAN_QUEUE_DATABASE_URL "$sh" "$HQ_T_CLI" "$@" >/dev/null 2>"$TMP/err" </dev/null || rc=$?
  check "[$sh] $label passes validation (exit 7, URL unset)" "$rc:$(cat "$TMP/err")" \
    "7:human-queue: HUMAN_QUEUE_DATABASE_URL is not set — database unavailable"
}

repeat() { printf "%${2}s" "" | tr ' ' "$1"; }

# The WHEN parser harness: sources the CLI's libraries, parses WHEN (or, with
# --for, a DURATION), and prints AT|DAY|DAYVAL|TIMES|MINUTES.
cat > "$TMP/when.sh" <<'EOF'
set -euo pipefail
HQ_BIN_DIR="$1"
. "$HQ_BIN_DIR/lib/common.sh"
. "$HQ_BIN_DIR/lib/db.sh"
. "$HQ_BIN_DIR/lib/items.sh"
. "$HQ_BIN_DIR/lib/lifecycle.sh"
. "$HQ_BIN_DIR/lib/interrupts.sh"
. "$HQ_BIN_DIR/lib/todo.sh"
if [ "$2" = --for ]; then hq_todo_duration "$3"; else hq_todo_when "$2"; fi
printf '%s|%s|%s|%s|%s\n' "$HQ_TODO_AT" "$HQ_TODO_DAY" "$HQ_TODO_DAYVAL" "$HQ_TODO_TIMES" "$HQ_TODO_MINUTES"
EOF
when() { "$1" "$TMP/when.sh" "$HQ_T_DESK_DIR/bin" "${@:2}" 2>&1; }

for SH in $SHELLS; do
  echo "=== shell: $SH — $("$SH" --version 2>&1 | sed -n 1p) ==="

  # --- help --------------------------------------------------------------------
  RC=0
  OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" --help 2>&1) || RC=$?
  check "[$SH] human-queue.sh --help exits 0" "$RC" "0"
  for c in $CMDS; do
    check_contains "[$SH] --help lists $c" "$OUT" "  $c "
  done
  for c in $CMDS; do
    RC=0
    OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" "$c" --help 2>"$TMP/err") || RC=$?
    check "[$SH] $c --help exits 0 without a database" "$RC" "0"
    check_contains "[$SH] $c --help documents its usage" "$OUT" "human-queue.sh $c"
    check_contains "[$SH] $c --help documents exit codes" "$OUT" "EXIT CODES"
    check "[$SH] $c --help is silent on stderr" "$(cat "$TMP/err")" ""
  done
  RC=0
  OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" note D-1 x --help 2>&1) || RC=$?
  check "[$SH] --help after other arguments" "$RC:$(printf '%s\n' "$OUT" | sed -n 1p | cut -c1-19)" "0:human-queue.sh note"

  # --- tag / untag ---------------------------------------------------------------
  expect_rc "$SH" 4 "tag: no id" "tag: missing item id" tag
  expect_rc "$SH" 4 "tag: no tag" "tag: missing tag" tag D-1
  expect_rc "$SH" 4 "tag: a bad id" "invalid item id" tag X-1 prd
  expect_rc "$SH" 4 "tag: all digits" "a tag needs a letter" tag D-1 1234
  expect_rc "$SH" 4 "tag: an underscore" "tag: a tag is lowercase letters and digits" tag D-1 a_b
  expect_rc "$SH" 4 "tag: a doubled hyphen" "tag: a tag is lowercase" tag D-1 a--b
  expect_rc "$SH" 4 "tag: 33 characters" "at most 32 characters" tag D-1 "$(repeat a 33)"
  expect_rc "$SH" 4 "tag: eleven tags" "tag: at most 10 tags" tag D-1 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11
  expect_rc "$SH" 4 "tag: an unknown option" "tag: unknown option '--bogus'" tag D-1 prd --bogus
  expect_rc "$SH" 4 "untag: no tag" "untag: missing tag" untag D-1
  expect_db "$SH" "tag: #PRD and two words" tag D-1 '#PRD' call-back
  expect_db "$SH" "tag: a duplicate word is dropped, not refused" tag d-1 prd PRD
  expect_db "$SH" "tag: ten tags" tag D-1 a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 --json
  expect_db "$SH" "untag a Review's tag" untag R-3 prd --json

  # --- note ------------------------------------------------------------------------
  expect_rc "$SH" 4 "note: no id" "note: missing item id" note
  expect_rc "$SH" 4 "note: no note" "note: missing note" note D-1
  expect_rc "$SH" 4 "note: blank" "note: the note is empty" note D-1 "   "
  expect_rc "$SH" 4 "note: two lines" "note: the note must be a single line" note D-1 "$(printf 'one\ntwo')"
  run_cli "$SH" note D-1 "$(printf 'red \033[31m alert')"
  check "[$SH] note: an escape sequence: exit 4" "$RC" "4"
  check_contains "[$SH] note: an escape sequence: named" "$ERR" "control character"
  check_absent "[$SH] note: an escape sequence: never echoed" "$ERR" "alert"
  expect_rc "$SH" 4 "note: 1001 characters" "longer than 1000 characters" note D-1 "$(repeat a 1001)"
  expect_rc "$SH" 4 "note: a note and --clear" "give a note or --clear, not both" note D-1 x --clear
  expect_rc "$SH" 4 "note: two notes" "takes one item id and one note" note D-1 a b
  expect_rc "$SH" 4 "note: an option-shaped note" "note: unknown option '--bogus'" note D-1 --bogus
  run_cli "$SH" note D-1 "remember $FAKE_GH"
  check "[$SH] note: a token: exit 5" "$RC" "5"
  check_absent "[$SH] note: a token: never echoed" "$ERR" "$FAKE_GH"
  expect_db "$SH" "note: a note that starts with a dash" note D-1 "-- see above"
  expect_db "$SH" "note: 1000 characters" note D-1 "$(repeat a 1000)"
  expect_db "$SH" "note --clear" note D-1 --clear --json
  # After `--` the note is word for word: one that reads as an option is a note.
  expect_db "$SH" "note -- --clear (a note, not the option)" note D-1 --json -- --clear
  expect_db "$SH" "note -- --json (a note, not the option)" note D-1 -- --json
  expect_db "$SH" "note -- --help (a note, not help)" note D-1 -- --help
  expect_db "$SH" "note -- with an ordinary note" note D-1 --json -- "ask Sam first"
  expect_rc "$SH" 4 "note: -- with no note" "note: missing note" note D-1 --
  expect_rc "$SH" 4 "note: -- with two notes" "note: -- takes exactly one note after it" note D-1 -- a b
  expect_rc "$SH" 4 "note: an option after the note" "note: -- takes exactly one note after it" note D-1 -- a --json
  expect_rc "$SH" 4 "note: -- before the id" "note: -- goes after the item id" note -- D-1 x
  expect_rc "$SH" 4 "note: -- after a note" "note: -- goes after the item id" note D-1 x --
  expect_rc "$SH" 4 "note: --clear and a note after --" "give a note or --clear, not both" note D-1 --clear -- x
  expect_rc "$SH" 4 "note: a two-line note after --" "note: the note must be a single line" note D-1 -- "$(printf 'one\nDESK_NOTE')"

  # --- snooze / unsnooze ------------------------------------------------------------
  expect_rc "$SH" 4 "snooze: no when" "say when" snooze D-1
  expect_rc "$SH" 4 "snooze: until nothing" "snooze: missing WHEN" snooze D-1 until
  expect_rc "$SH" 4 "snooze: for nothing" "snooze: missing DURATION" snooze D-1 for
  expect_rc "$SH" 4 "snooze: until before the id" "missing item id before until" snooze until tomorrow
  expect_rc "$SH" 4 "snooze: two ids" "say when" snooze D-1 D-2 until tomorrow
  expect_rc "$SH" 4 "snooze: prose" "snooze: WHEN must be tomorrow, a weekday" snooze D-1 until next-ish
  expect_rc "$SH" 4 "snooze: not a real date" "snooze: WHEN is not a real date and time" snooze D-1 until 2026-02-30
  expect_rc "$SH" 4 "snooze: 25:00" "snooze: WHEN must be" snooze D-1 until 25:00
  expect_rc "$SH" 4 "snooze: a day and 13pm" "snooze: WHEN must be" snooze D-1 until friday 13pm
  expect_rc "$SH" 4 "snooze: ISO without a zone and a T" "snooze: WHEN must be" snooze D-1 until 2026-10-12T13:00
  expect_rc "$SH" 4 "snooze: two lines" "snooze: WHEN must be one line" snooze D-1 until "$(printf 'tomorrow\n9am')"
  expect_rc "$SH" 4 "snooze: for 0m" "from 1 minute to 366 days" snooze D-1 for 0m
  expect_rc "$SH" 4 "snooze: for 400d" "from 1 minute to 366 days" snooze D-1 for 400d
  expect_rc "$SH" 4 "snooze: for 2 fortnights" "DURATION's unit" snooze D-1 for 2 fortnights
  expect_rc "$SH" 4 "snooze: for soon" "DURATION must be a whole number and a unit" snooze D-1 for soon
  expect_rc "$SH" 4 "snooze: an unknown option" "snooze: unknown option '--bogus'" snooze D-1 --bogus until tomorrow
  for w in tomorrow friday Fri 2026-10-12 15:30 3pm '9 am' '15:30 ET' 'friday 9am' 'tomorrow 14:30' \
           '2026-10-12 at 8:15' 2026-10-12T13:00Z '2026-10-12 13:00-04:00'; do
    expect_db "$SH" "snooze until $w" snooze D-1 until "$w" --json
  done
  expect_db "$SH" "snooze until friday 9am, unquoted" snooze D-1 until friday 9am
  expect_db "$SH" "snooze --until" snooze D-1 --until tomorrow
  for d in 30m '90 min' 2h '3 days' 1w 366d; do
    expect_db "$SH" "snooze for $d" snooze D-1 for "$d"
  done
  expect_rc "$SH" 4 "unsnooze: no id" "unsnooze: missing item id" unsnooze
  expect_rc "$SH" 4 "unsnooze: two ids" "unsnooze: takes one item id" unsnooze D-1 D-2
  expect_db "$SH" "unsnooze" unsnooze r-2 --json

  # --- mine ------------------------------------------------------------------------
  expect_rc "$SH" 4 "mine: no id" "mine: missing item id" mine
  expect_rc "$SH" 4 "mine: no priority" "mine: missing priority" mine D-1
  expect_rc "$SH" 4 "mine: 0" "mine: the priority must be 1 (highest) to 5" mine D-1 0
  expect_rc "$SH" 4 "mine: 6" "mine: the priority must be 1 (highest) to 5" mine D-1 6
  expect_rc "$SH" 4 "mine: 12" "mine: the priority must be 1 (highest) to 5" mine D-1 12
  expect_rc "$SH" 4 "mine: a priority and --clear" "give a priority or --clear, not both" mine D-1 2 --clear
  expect_rc "$SH" 4 "mine: two priorities" "takes one item id and one priority" mine D-1 1 2
  expect_db "$SH" "mine 1" mine D-1 1
  expect_db "$SH" "mine 5 --json" mine R-7 5 --json
  expect_db "$SH" "mine --clear" mine D-1 --clear

  # --- my list -----------------------------------------------------------------------
  expect_rc "$SH" 4 "my: no action" "my: missing action: list" my
  expect_rc "$SH" 4 "my: an unknown action" "my: unknown action (expected list)" my lists
  expect_rc "$SH" 4 "my list: a stray argument" "my list: unknown argument" my list extra
  expect_rc "$SH" 4 "my list: --tag without a value" "my list: --tag needs a value" my list --tag
  expect_rc "$SH" 4 "my list: --tag twice" "my list: --tag given more than once" my list --tag a --tag b
  expect_rc "$SH" 4 "my list: a malformed --tag" "my list: a tag is lowercase" my list --tag 'a b'
  expect_db "$SH" "my list" my list
  expect_db "$SH" "my list with every option" my list --tag '#Prd' --all --snoozed --json

  # --- the WHEN parser ----------------------------------------------------------------
  check "[$SH] when: tomorrow" "$(when "$SH" tomorrow)" "|tomorrow|||"
  check "[$SH] when: Friday" "$(when "$SH" Friday)" "|weekday|5||"
  check "[$SH] when: sun" "$(when "$SH" sun)" "|weekday|7||"
  check "[$SH] when: a date" "$(when "$SH" 2026-10-12)" "|date|2026-10-12||"
  check "[$SH] when: 3:30 alone has two readings" "$(when "$SH" 3:30)" "|||03:30,15:30|"
  check "[$SH] when: 12 alone" "$(when "$SH" 12)" "|||00:00,12:00|"
  check "[$SH] when: 15:30 ET" "$(when "$SH" '15:30 ET')" "|||15:30|"
  check "[$SH] when: 9 am" "$(when "$SH" '9 am')" "|||09:00|"
  check "[$SH] when: Friday 9am" "$(when "$SH" 'Friday 9am')" "|weekday|5|09:00|"
  check "[$SH] when: fri 3 reads the 24-hour clock" "$(when "$SH" 'fri 3')" "|weekday|5|03:00|"
  check "[$SH] when: tomorrow 12:30 reads the 24-hour clock" "$(when "$SH" 'tomorrow 12:30')" "|tomorrow||12:30|"
  check "[$SH] when: a date at a time" "$(when "$SH" '2026-10-12 at 8:15pm')" "|date|2026-10-12|20:15|"
  check "[$SH] when: ISO is kept as given" "$(when "$SH" ' 2026-10-12T13:00Z ')" "2026-10-12T13:00Z||||"
  check "[$SH] when: ISO with a space and an offset" "$(when "$SH" '2026-10-12 13:00-04:00')" "2026-10-12 13:00-04:00||||"
  check "[$SH] for: 90 min" "$(when "$SH" --for '90 min')" "||||90"
  check "[$SH] for: 2h" "$(when "$SH" --for 2H)" "||||120"
  check "[$SH] for: 1w" "$(when "$SH" --for 1w)" "||||10080"
done

# --- desk.jq --------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  tl() { printf '%s' "$1" | jq -r -L "$HQ_T_DESK_DIR/skill" 'include "desk"; todo_line'; }
  check "todo_line: nothing for an item without the fields (a store before 010)" "$(tl '{"id":"D-1"}')" ""
  check "todo_line: nothing for empty fields" "$(tl '{"my_tags":[],"my_note":null,"my_priority":null}')" ""
  check "todo_line: all three" "$(tl '{"my_priority":2,"my_tags":["prd","urgent"],"my_note":"ask Sam first"}')" \
    "P2 · tags: prd, urgent · note: ask Sam first"
  check "todo_line: a note alone" "$(tl '{"my_tags":[],"my_note":"after lunch"}')" "note: after lunch"
  check "todo_line: the snooze is left out" "$(tl '{"snoozed_until":"2026-10-09T13:00:00+00:00"}')" ""
  FIX="$HQ_T_DESK_DIR/tests/fixtures/plan/sweep.json"
  PLAIN=$(jq -r -L "$HQ_T_DESK_DIR/skill" 'include "desk"; sweep_lines(null)[]' "$FIX")
  WITH=$(jq -r -L "$HQ_T_DESK_DIR/skill" \
    'include "desk"; .items[0] += {my_priority: 1, my_tags: ["prd"], my_note: "ask Sam"} | .items[3].my_tags = [] | sweep_lines(null)[]' "$FIX")
  check "4.3 sweep_lines: one nested line, under the item that carries the fields" \
    "$(diff <(printf '%s\n' "$PLAIN") <(printf '%s\n' "$WITH") | sed -n '/^>/p')" ">    - P1 · tags: prd · note: ask Sam"
  check "4.3 sweep_lines: it follows its item" "$(printf '%s\n' "$WITH" | sed -n 2p)" "   - P1 · tags: prd · note: ask Sam"
  check "4.3 sweep_lines: the numbering is unchanged" "$(printf '%s\n' "$WITH" | grep -c '^[0-9]')" "$(printf '%s\n' "$PLAIN" | grep -c '^[0-9]')"
  CARD=$(jq -r -L "$HQ_T_DESK_DIR/skill" \
    'include "desk"; .items[0] += {my_tags: ["prd"]} | sweep_view(null)' "$FIX")
  check_contains "4.3 sweep_view: the card quotes it too" "$CARD" ">    - tags: prd"
else
  echo "SKIP: desk.jq checks — jq is not installed"
fi

# --- the skill ------------------------------------------------------------------------
SKILL_DIR="$HQ_T_DESK_DIR/skill"
for a in desk-todo-write desk-todo-note desk-todo-list; do
  RC=0
  BODY=$(hq_t_skill_block "$SKILL_DIR/todo.md" "$a" 2>&1) || RC=$?
  check "todo.md: anchor $a extracts" "$RC" "0"
  printf '%s\n' "$BODY" > "$TMP/$a.sh"
  RC=0
  bash -n "$TMP/$a.sh" 2>/dev/null || RC=$?
  check "todo.md: block $a parses" "$RC" "0"
done
check_contains "todo.md: the note goes through a quoted here-document" "$(cat "$TMP/desk-todo-note.sh")" "<<'DESK_NOTE'"
check_contains "todo.md: the note never sits inside the command's quotes" "$(cat "$TMP/desk-todo-note.sh")" '"$(cat "$NOTE_FILE")"'
check_contains "todo.md: the note comes after --, so it is never read as an option" "$(cat "$TMP/desk-todo-note.sh")" \
  '--json -- "$(cat "$NOTE_FILE")"'
TODO=$(cat "$SKILL_DIR/todo.md")
check_contains "todo.md: a note holding the delimiter gets another one" "$TODO" \
  'If it contains a line that is exactly `DESK_NOTE`, pick another delimiter for both lines.'
check_contains "todo.md: keeps itself apart from /pm's priorities" "$TODO" "**Not \`/pm\`'s priorities.**"
check_contains "todo.md: my list is unnumbered on purpose" "$TODO" "unnumbered on purpose"
SKILL=$(cat "$SKILL_DIR/SKILL.md")
check_contains "SKILL.md: routes to todo.md" "$SKILL" "| \`todo.md\` |"
check_contains "SKILL.md: the reply order names the to-do verbs" "$SKILL" "**A to-do verb** as the whole message"
check_contains "skill README lists todo.md" "$(cat "$SKILL_DIR/README.md")" "| \`todo.md\` |"

hq_t_finish "todo-offline.test.sh"
