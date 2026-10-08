#!/usr/bin/env bash
# desk/tests/todo.test.sh — live tests for the operator's to-do layer (issue
# #1769), against the database in HUMAN_QUEUE_DATABASE_URL.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. Every run creates a throwaway schema named
# hq_test_<pid>_<random>_todo, points the CLI at it with HUMAN_QUEUE_SCHEMA,
# and drops it on exit; the number of tables in `public` is asserted unchanged.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset. With the
# URL set, an unreachable database FAILS the suite.
#
# Asserts (issue #1769):
#   5.1  through the skill's own blocks (todo.md): one item tagged, noted (a
#        note full of shell metacharacters, stored byte for byte), snoozed,
#        and prioritized; `my list` shows the items with a priority or a note
#        by priority (unset last), then age; the snoozed one is hidden and
#        counted, and after its time it is back in its place
#   4.1  tag, untag, note, note --clear, snooze, unsnooze, mine, mine --clear
#        write through the CLI, one event each with its note; a write that
#        changes nothing (a tag it has, the same note or priority, unsnooze of
#        an unsnoozed item, untag of a tag it lacks) records nothing; more
#        than 10 tags is refused with nothing changed; an unknown id is exit
#        4; two concurrent tag calls both land
#   4.2  my list: only items still waiting (open, flagged) unless --all; --tag
#        lists the tagged items with or without a priority or note;
#        --snoozed shows snoozed ones, marked; JSON shape
#        snooze's WHEN on the store's clock: a duration rounds up to the
#        minute; tomorrow and a date are 00:00 America/New_York; a weekday
#        with a time; a clock time's next occurrence; past and too-far
#        times refused
#   4.3  get renders the to-do fields; the end-of-day sweep's card
#        (sweep.md's desk-sweep block) and its paper copy (`export --set`
#        of the sweep's set, #1759) carry the tags and the note
#   tick a to-do write is not a change `tick` reports; a bump still is
#   010  over a store without it: every to-do command exits 1 naming migrate,
#        get and list still render; a parallel migration's event kind
#        survives 010's additive constraint; to-do writes work after it
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

hq_t_require_db "todo.test.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: todo.test.sh — jq is not installed (the desk skill needs it)"
  exit 0
fi

HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

S="hq_test_$$_$(printf '%05d' "$RANDOM")_todo"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-todo-test.XXXXXX")
SKILL_DIR="$HQ_T_DESK_DIR/skill"

admin_sql() { hq_psql -At -c "$1"; }
cleanup() {
  admin_sql "DROP SCHEMA IF EXISTS $S CASCADE;" >/dev/null 2>&1 \
    || echo "WARN: could not drop scratch schema $S — drop it by hand" >&2
  rm -rf "$TMP"
  hq__cleanup_tmp
}
trap cleanup EXIT

sql_in() { hq_psql -At -c "SET search_path TO $S; $1" 2>&1; }

# hq ARGS... — the CLI in the scratch schema; sets OUT, ERR, RC.
hq() {
  RC=0
  HUMAN_QUEUE_SCHEMA="$S" bash "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}
jqo() { printf '%s' "$OUT" | jq -r "$1"; }
events() { sql_in "SELECT count(*) FROM events WHERE item_id = '$1' AND kind = '$2'"; }
last_note() { sql_in "SELECT note FROM events WHERE item_id = '$1' AND kind = '$2' ORDER BY id DESC LIMIT 1"; }
my_ids() { hq my list --json "$@"; jqo '[.items[].id] | join(",")'; }

block() {
  local file="$1" name="$2" out rc=0
  out=$(hq_t_skill_block "$SKILL_DIR/$file" "$name" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "anchor $name extracts (rc=$rc: $out)"
    return 1
  fi
  printf '%s\n' "$out" > "$TMP/block-$name.sh"
}
literal() { FROM="$2" TO="$3" perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$1"; }
# with_line FILE PLACEHOLDER TEXT — FILE with the line PLACEHOLDER replaced by
# TEXT, exactly (through the environment: `awk -v` would turn a `\n` in TEXT
# into a line break).
with_line() { PH="$2" T="$3" awk '$0 == ENVIRON["PH"] { print ENVIRON["T"]; next } { print }' "$1"; }
# run_block FILE — the block as the desk session desk-1, through desk-cli.sh in
# the scratch schema.
run_block() {
  (cd "$TMP" && env -u HUMAN_QUEUE_POLICY DESK="$HQ_T_DESK_DIR" HQ="$HQ_BIN_DIR/desk-cli.sh" \
     SID=desk-1 HUMAN_QUEUE_SCHEMA="$S" TMPDIR="$TMP" bash "$1") 2>&1
}

block todo.md desk-todo-write
block todo.md desk-todo-note
block todo.md desk-todo-list
block sweep.md desk-sweep

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

hq migrate
check "migrate the scratch schema" "$RC" "0"
check_contains "migrate applies 010" "$OUT" "applied 010_todo_layer.sql"
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$ERR"
  hq_t_finish "todo.test.sh"
  exit 1
fi
echo "scratch schema: $S"

# add VAR KIND KEY QUESTION — an item; its id goes in VAR. Each a moment
# apart, so "oldest first" has an order to keep.
add() {
  local var="$1" kind="$2" key="$3" question="$4"
  hq add --kind "$kind" --repo auerbachb/widgets --key "$key" --question "$question" \
    --option Yes --option No
  check "add $var" "$RC" "0"
  printf -v "$var" '%s' "$OUT"
  sql_in "UPDATE items SET created_at = created_at - interval '1 hour' * (20 - (SELECT count(*) FROM items)) WHERE id = '$OUT'" >/dev/null
}
add D1 decision pr-12 "Retry the flaky upload test once?"
add D2 decision issue-11 "Ship the migration first?"
add D3 decision issue-13 "Rename the gadget flag?"
add D4 decision issue-14 "Pin the linter version?"
add D5 decision issue-15 "Archive the old dashboards?"
hq add --kind review --repo auerbachb/widgets --key pr-31 --question "feat: widgets"
R1="$OUT"
check "add R1" "$RC" "0"
sql_in "UPDATE items SET created_at = created_at - interval '1 hour' WHERE id = '$R1'" >/dev/null

# ---------------------------------------------------------------- 5.1, skill blocks
hq my list
check "an empty list says so" "$RC:$OUT" "0:My list is empty"

literal "$TMP/block-desk-todo-write.sh" "D-43" "$D1" > "$TMP/tag.sh"
OUT=$(run_block "$TMP/tag.sh")
check "5.1 desk-todo-write: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
check "5.1 tag: the item carries prd and urgent" \
  "$(printf '%s\n' "$OUT" | sed -n 1p | jq -c '[.id, .my_tags, .changed]')" "[\"$D1\",[\"prd\",\"urgent\"],true]"
check "5.1 tag: one tagged event, its note the tags" "$(events "$D1" tagged):$(last_note "$D1" tagged)" "1:prd, urgent"

NOTE_TEXT='Ask Sam first; $(rm -rf /) `id` "quoted" '"'"'single'"'"' \n 2: B'
literal "$TMP/block-desk-todo-note.sh" "D-43" "$D1" \
  | with_line /dev/stdin "<the note, verbatim, without its surrounding quotes>" "$NOTE_TEXT" > "$TMP/note.sh"
OUT=$(run_block "$TMP/note.sh")
check "5.1 desk-todo-note: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
hq get "$D1" --json
check "5.1 the note is stored byte for byte" "$(jqo '.my_note')" "$NOTE_TEXT"
check "5.1 note: one noted event, note set" "$(events "$D1" noted):$(last_note "$D1" noted)" "1:set"

hq mine "$D1" 2 --json
check "5.1 mine: P2" "$RC:$(jqo '[.my_priority, .changed] | @json')" "0:[2,true]"
check "5.1 mine: one prioritized event, note 2" "$(events "$D1" prioritized):$(last_note "$D1" prioritized)" "1:2"
hq mine "$D3" 1
check "mine D3 1" "$RC:$OUT" "0:$D3"
hq mine "$D4" 1
check "mine D4 1" "$RC" "0"
hq note "$R1" "Read after lunch"
check "note R1" "$RC" "0"
hq tag "$D5" waiting
check "tag D5 (a tag alone does not put an item on the list)" "$RC" "0"

check "5.1 my list: priority first, unset last, then oldest first" "$(my_ids)" "$D3,$D4,$D1,$R1"

# Far enough ahead that the six store round trips before the block runs (each
# a fresh connection to a remote database, slower on a loaded machine) finish
# while it is still snoozed: at 3 seconds the block saw it already back.
UNTIL=$(sql_in "SELECT to_char((statement_timestamp() + interval '20 seconds') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")
hq snooze "$D1" until "$UNTIL" --json
check "5.1 snooze until a time just ahead" "$RC:$(jqo '.changed')" "0:true"
check "5.1 snooze: one snoozed event, note the time" "$(events "$D1" snoozed):$(last_note "$D1" snoozed)" "1:until $UNTIL"
check "5.1 while snoozed, my list hides it" "$(my_ids)" "$D3,$D4,$R1"
hq my list --json
check "5.1 ... and counts it, with when it is back" "$(jqo '[.count, .snoozed, .next_back] | @json')" "[3,1,\"$UNTIL\"]"
OUT=$(run_block "$TMP/block-desk-todo-list.sh")
check_contains "5.1 desk-todo-list: the header counts the snooze" "$(printf '%s\n' "$OUT" | sed -n 1p)" "My list · 3 items · 1 snoozed (next back "
check_absent "5.1 desk-todo-list: the snoozed item is not listed" "$OUT" "$D1 ·"
# Wait for the store's clock to pass the snooze (at most 30 seconds).
n=0
while [ "$n" -lt 60 ] &&[ "$(sql_in "SELECT statement_timestamp() > '$UNTIL'::timestamptz")" != "t" ]; do
  sleep 0.5
  n=$((n + 1))
done
check "5.1 after the snooze time, it is back in its place" "$(my_ids)" "$D3,$D4,$D1,$R1"
OUT=$(run_block "$TMP/block-desk-todo-list.sh")
EXPECTED="My list · 4 items
- P1 · $D3 · Rename the gadget flag? (widgets · issue-13)
- P1 · $D4 · Pin the linter version? (widgets · issue-14)
- P2 · $D1 · Retry the flaky upload test once? (widgets · pr-12) · tags: prd, urgent
  Note: $NOTE_TEXT
- $R1 · feat: widgets (widgets · pr-31)
  Note: Read after lunch
exit=0"
check "5.1 desk-todo-list: the list as the operator reads it" "$OUT" "$EXPECTED"

# ---------------------------------------------------------------- 4.1 no-ops and the rest
hq tag "$D1" prd '#URGENT' --json
check "tagging tags it has: no change" "$RC:$(jqo '.changed')" "0:false"
check "... and no event" "$(events "$D1" tagged)" "1"
hq note "$D1" "$NOTE_TEXT"
check "the same note: no event" "$RC:$(events "$D1" noted)" "0:1"
hq mine "$D1" 2
check "the same priority: no event" "$RC:$(events "$D1" prioritized)" "0:1"
hq untag "$D1" nope
check "untag of a tag it lacks: no event" "$RC:$(events "$D1" untagged)" "0:0"
hq unsnooze "$D1" --json
check "unsnooze after the time passed clears it, with its event" "$RC:$(jqo '[.changed, .snoozed_until] | @json'):$(events "$D1" unsnoozed)" "0:[true,null]:1"
hq unsnooze "$D1"
check "unsnooze of an unsnoozed item: no event" "$RC:$(events "$D1" unsnoozed)" "0:1"
hq untag "$D1" '#PRD' --json
check "untag removes it, the rest keep their order" "$RC:$(jqo '.my_tags | join(",")')" "0:urgent"
check "... one untagged event, its note the tag" "$(events "$D1" untagged):$(last_note "$D1" untagged)" "1:prd"
hq note "$D1" --clear
check "note --clear" "$RC:$(last_note "$D1" noted)" "0:cleared"
hq note "$D1" --clear
check "note --clear again: no event" "$RC:$(events "$D1" noted)" "0:2"
hq mine "$D1" --clear --json
check "mine --clear" "$RC:$(jqo '.my_priority'):$(last_note "$D1" prioritized)" "0:null:cleared"
check "with neither a priority nor a note, it leaves the list" "$(my_ids)" "$D3,$D4,$R1"
hq mine "$D1" 3
hq tag "$D2" a1 a2 a3 a4 a5 a6 a7 a8 a9 a10
check "ten tags fit" "$RC" "0"
hq tag "$D2" b1
check "an eleventh is refused" "$RC" "4"
check_contains "... naming the limit" "$ERR" "$D2 would carry more than 10 tags"
check "... with nothing changed" "$(sql_in "SELECT cardinality(my_tags) FROM items WHERE id = '$D2'"):$(events "$D2" tagged)" "10:1"
hq mine D-999 1
check "an unknown id: exit 4" "$RC:$ERR" "4:human-queue: mine: no item D-999; nothing was changed"
hq untag "$D2" a1 a2 a3 a4 a5 a6 a7 a8 a9 a10
check "untag them all" "$RC:$(sql_in "SELECT cardinality(my_tags) FROM items WHERE id = '$D2'")" "0:0"
# Two writers at once both land: each locks the row, then reads it afresh.
( HUMAN_QUEUE_SCHEMA="$S" bash "$HQ_T_CLI" tag "$D2" left >/dev/null 2>&1 ) &
P1=$!
( HUMAN_QUEUE_SCHEMA="$S" bash "$HQ_T_CLI" tag "$D2" right >/dev/null 2>&1 ) &
P2=$!
wait "$P1"; wait "$P2"
check "two concurrent tags both land" "$(sql_in "SELECT array_to_string(ARRAY(SELECT t FROM unnest(my_tags) t ORDER BY t), ',') FROM items WHERE id = '$D2'")" "left,right"

# ---------------------------------------------------------------- 4.2 the list's filters
hq answer "$D4" A
check "answer D4" "$RC" "0"
check "an answered Decision leaves the list" "$(my_ids)" "$D3,$D1,$R1"
hq my list --all
check_contains "--all lists it, naming its status" "$OUT" "- P1 · $D4 · Pin the linter version? (widgets · issue-14) · answered"
check_contains "--all says so in the header" "$(printf '%s\n' "$OUT" | sed -n 1p)" "My list · 4 items · every status"
hq flag "$R1" --note "check the docs"
check "a flagged Review stays on the list" "$(my_ids)" "$D3,$D1,$R1"
check "--tag lists the tagged items, with or without a priority or note" "$(my_ids --tag waiting)" "$D5"
hq my list --tag '#Waiting'
check "--tag text" "$OUT" "My list · 1 item · tag waiting
- $D5 · Archive the old dashboards? (widgets · issue-15) · tags: waiting"
hq snooze "$D3" for 2h
check "snooze for 2h" "$RC" "0"
check "--snoozed lists the snoozed ones too" "$(my_ids --snoozed)" "$D3,$D1,$R1"
hq my list --snoozed
check_contains "... marked" "$OUT" "· snoozed until "
hq my list --json
check "JSON: an item carries snoozed: false and leaves out summary_l2" \
  "$(jqo '.items[0] | [.snoozed, has("summary_l2"), has("change_xid"), .my_priority] | @json')" "[false,false,false,3]"

# ---------------------------------------------------------------- 4.2 snooze's WHEN
# when_ok LABEL EXPECTED_SQL ARGS... — snooze D5 as ARGS, then compare the
# stored time with EXPECTED_SQL evaluated on the store's clock.
when_ok() {
  local label="$1" expect="$2"
  shift 2
  hq snooze "$D5" "$@"
  check "$label: exit 0" "$RC:$ERR" "0:"
  check "$label" "$(sql_in "SELECT snoozed_until = ($expect) FROM items WHERE id = '$D5'")" "t"
}
hq snooze "$D5" for 90m
check "for 90m: a whole minute, 90 to 91 minutes ahead" \
  "$RC:$(sql_in "SELECT snoozed_until = date_trunc('minute', snoozed_until)
                    AND snoozed_until - statement_timestamp() BETWEEN interval '89 minutes' AND interval '91 minutes'
                   FROM items WHERE id = '$D5'")" "0:t"
when_ok "until tomorrow is 00:00 tomorrow, New York" \
  "((statement_timestamp() AT TIME ZONE 'America/New_York')::date + 1)::timestamp AT TIME ZONE 'America/New_York'" \
  until tomorrow
FAR=$(sql_in "SELECT to_char((statement_timestamp() AT TIME ZONE 'America/New_York')::date + 40, 'YYYY-MM-DD')")
when_ok "until a date is 00:00 that day" "'$FAR'::timestamp AT TIME ZONE 'America/New_York'" until "$FAR"
when_ok "until friday 9am, as two words" \
  "(SELECT (d + time '09:00') AT TIME ZONE 'America/New_York'
      FROM (SELECT t + ((5 - extract(isodow FROM t)::int + 6) % 7 + 1) AS d
              FROM (SELECT (statement_timestamp() AT TIME ZONE 'America/New_York')::date AS t) x) y)" \
  until friday 9am
when_ok "until fri 14:30 reads the 24-hour clock" \
  "(SELECT (d + time '14:30') AT TIME ZONE 'America/New_York'
      FROM (SELECT t + ((5 - extract(isodow FROM t)::int + 6) % 7 + 1) AS d
              FROM (SELECT (statement_timestamp() AT TIME ZONE 'America/New_York')::date AS t) x) y)" \
  until 'fri 14:30'
hq snooze "$D5" until '23:59 ET' --json
check "until a clock time: its next occurrence, within a day" \
  "$RC:$(sql_in "SELECT snoozed_until > statement_timestamp() AND snoozed_until <= statement_timestamp() + interval '24 hours'
                    AND to_char(snoozed_until AT TIME ZONE 'America/New_York', 'HH24:MI') = '23:59' FROM items WHERE id = '$D5'")" "0:t"
check_contains "... and --json names it in New York time" "$(jqo '.snoozed_until_local')" " 23:59"
hq snooze "$D5" until 2020-01-01
check "a time in the past is refused" "$RC:$ERR" "4:human-queue: snooze: the snooze time is in the past; nothing was changed"
hq snooze "$D5" until "$(sql_in "SELECT to_char(current_date + 400, 'YYYY-MM-DD')")"
check "more than 366 days ahead is refused" "$RC" "4"
check_contains "... naming the limit" "$ERR" "more than 366 days ahead"
# The longest duration is rounded up to the whole minute like any other; the
# limit is rounded the same way, so that never pushes it past the limit.
hq snooze "$D5" for 366d
check "for 366d, the longest duration, is accepted" "$RC:$ERR" "0:"
check "... a whole minute, 366 days of 24 hours ahead" \
  "$(sql_in "SELECT snoozed_until = date_trunc('minute', snoozed_until)
                AND snoozed_until - statement_timestamp() BETWEEN interval '8783 hours 59 minutes' AND interval '8784 hours 1 minute'
               FROM items WHERE id = '$D5'")" "t"
hq snooze "$D5" until "$(sql_in "SELECT to_char((statement_timestamp() + interval '8784 hours 2 minutes') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')")"
check "a time a minute past the limit is refused" "$RC" "4"

# ---------------------------------------------------------------- tick
hq tick
check "tick: read the backlog once" "$RC" "0"
hq untag "$D2" left right
hq tag "$D2" later
hq note "$D2" "after the release"
hq mine "$D2" 4
hq snooze "$D2" for 1d
hq tick
check "to-do writes are not changes tick reports" "$RC:$OUT" "0:[]"
hq bump "$D2"
hq tick
check "a bump still is" "$RC:$(jqo '[.[].id] | join(",")')" "0:$D2"

# ---------------------------------------------------------------- 4.3 rendering and paper
hq get "$D2"
check_contains "get: the to-do line" "$OUT" "My priority: 4 · Tags: later · Snoozed until "
check_contains "get: the note" "$OUT" "My note: after the release"
add D6 decision issue-16 "Drop the legacy flag?"
hq get "$D6"
check "get: an item without them" "$RC:$(printf '%s\n' "$OUT" | sed -n 2p)" "0:**Drop the legacy flag?**"
check_absent "... prints no to-do lines" "$OUT" "My "
hq show "$D2"
check_contains "show: the events" "$OUT" "prioritized — 4"
check_contains "show: the snooze" "$OUT" "snoozed — until "
hq unsnooze "$D2"
OUT=$(run_block "$TMP/block-desk-sweep.sh")
check "4.3 desk-sweep: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
check_contains "4.3 the card carries the tags and the note" "$OUT" "   - P4 · tags: later · note: after the release"
# The paper copy is `export` of the sweep's set (#1759; the sweep no longer
# writes one of its own), here as Markdown, so the check needs no renderer.
SWEEP_SET=$(printf '%s\n' "$OUT" | sed -n 's/^> \*\*End of day · .* · set \([0-9][0-9]*\)\*\*$/\1/p' | head -n 1)
check "4.3 the sweep opened a set" "$([ -n "$SWEEP_SET" ] && echo yes || echo no)" "yes"
RC=0
HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_EXPORT_RENDERER=markdown bash "$HQ_T_CLI" export --set "${SWEEP_SET:-0}" \
  --out "$TMP/sweep-paper.pdf" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
check "4.3 export of the sweep's set: exit 0" "$RC:$(cat "$TMP/err")" \
  "0:human-queue: export: no PDF renderer produced a PDF (HUMAN_QUEUE_EXPORT_RENDERER=markdown); wrote the Markdown instead: $(cd -P "$TMP" && pwd)/sweep-paper.md"
PAPER=$(awk -v id="$D2 · " 'index($0, "## ") == 1 { inside = (index($0, id) > 0) } inside' "$TMP/sweep-paper.md" 2>/dev/null)
check_contains "4.3 the paper copy heads the item by number and id" "$PAPER" "$D2 · Ship the migration first?"
check_contains "4.3 the paper copy carries them, in the item's section" "$PAPER" "P4 · tags: later · note: after the release"

# ---------------------------------------------------------------- 010 over an older store
# Back to a store without 010, whose event-kind list a parallel branch's
# migration extended first (its kind, `sibling-kind`, must survive 010). The
# list below predates 013 too, so 4.3's `exported` events go with the rest.
OLD=$(sql_in "DELETE FROM events WHERE kind IN ('tagged', 'untagged', 'noted', 'snoozed', 'unsnoozed', 'prioritized', 'exported');
ALTER TABLE items DROP COLUMN my_tags, DROP COLUMN my_note, DROP COLUMN my_priority, DROP COLUMN snoozed_until;
ALTER TABLE events DROP CONSTRAINT events_kind_check;
ALTER TABLE events ADD CONSTRAINT events_kind_check
  CHECK (kind IN ('asked', 'bumped', 'shown', 'answered', 'acknowledged', 'reviewed', 'flagged', 'feedback',
                  'commented', 'woken', 'wake-failed', 'answer-parked', 'sibling-kind'));
CREATE OR REPLACE FUNCTION items_mark_change() RETURNS trigger LANGUAGE plpgsql AS \$f\$
BEGIN
  IF TG_OP = 'UPDATE'
     AND (NEW.summary_l1 IS DISTINCT FROM OLD.summary_l1 OR NEW.summary_l2 IS DISTINCT FROM OLD.summary_l2)
     AND to_jsonb(NEW) - ARRAY['summary_l1', 'summary_l2', 'change_xid', 'updated_at']
       = to_jsonb(OLD) - ARRAY['summary_l1', 'summary_l2', 'change_xid', 'updated_at'] THEN
    NEW.change_xid := OLD.change_xid;
    RETURN NEW;
  END IF;
  NEW.change_xid := pg_current_xact_id();
  RETURN NEW;
END;
\$f\$;
INSERT INTO events (item_id, kind) VALUES ('$D1', 'sibling-kind');
DELETE FROM schema_migrations WHERE filename = '010_todo_layer.sql';" | grep -v -E '^(DELETE|ALTER|CREATE|INSERT|SET)' )
check "setup: the store is pre-010 again (no error)" "$OLD" ""
# pre010 CONTEXT ARGS... — before 010, the command exits 1 naming migrate.
pre010() {
  local context="$1"
  shift
  hq "$@"
  check "before 010: $* exits 1 naming migrate" "$RC:$ERR" \
    "1:human-queue: $context: the store is not migrated (run human-queue.sh migrate)"
}
pre010 "tag: nothing was changed" tag "$D1" prd
pre010 "untag: nothing was changed" untag "$D1" prd
pre010 "note: nothing was changed" note "$D1" x
pre010 "snooze: nothing was changed" snooze "$D1" for 1h
pre010 "unsnooze: nothing was changed" unsnooze "$D1"
pre010 "mine: nothing was changed" mine "$D1" 1
pre010 "my list" my list
hq get "$D1"
check "before 010: get still renders" "$RC:$(printf '%s\n' "$OUT" | sed -n 2p)" "0:**Retry the flaky upload test once?**"
check_absent "... with no to-do lines" "$OUT" "My "
hq list --status open
check "before 010: list still renders" "$RC" "0"
hq migrate
check "migrate applies 010 over it" "$RC" "0"
check_contains "... names it" "$OUT" "applied 010_todo_layer.sql"
DEF=$(sql_in "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'events'::regclass AND conname = 'events_kind_check'")
check_contains "the parallel branch's kind survives" "$DEF" "'sibling-kind'::text"
check_contains "... next to 010's" "$DEF" "'prioritized'::text"
check "the old event is still there" "$(events "$D1" sibling-kind)" "1"
hq tick
hq tag "$D1" prd
check "after 010: tag works again" "$RC:$(events "$D1" tagged)" "0:1"
hq tick
check "after 010: the new trigger keeps the write out of tick" "$RC:$OUT" "0:[]"
hq migrate
check_absent "010 is not applied twice" "$OUT" "applied 010"

PUBLIC_AFTER=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
check "the public schema is unchanged" "$PUBLIC_AFTER" "$PUBLIC_BEFORE"

hq_t_finish "todo.test.sh"
