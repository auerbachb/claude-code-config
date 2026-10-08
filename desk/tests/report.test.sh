#!/usr/bin/env bash
# desk/tests/report.test.sh — live tests for the weekly attention report
# (issue #1771), against the database in HUMAN_QUEUE_DATABASE_URL.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. Every run creates a throwaway schema named
# hq_test_<pid>_<random>_report, points the CLI at it with HUMAN_QUEUE_SCHEMA,
# and drops it on exit; the number of tables in `public` is asserted
# unchanged.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset or jq is
# missing. With the URL set, an unreachable database FAILS the suite.
#
# Asserts (issue #1771):
#   5.1  a fixture week of events (Mon 2026-09-07 to Sun 2026-09-13, with
#        events just outside it on both sides) gives every measure its
#        hand-computed value: 39 minutes over 5 sittings (a gap of exactly
#        10 minutes joins a sitting, 11 splits it, a sitting of `shown`
#        alone counts nothing, `woken` and `acknowledged` are not desk
#        events); 7 items handled on 5 desk days, per day; a median open age
#        of 392 minutes over 6 Decisions, 2 still open at the week's end;
#        3 tagged not important of 6 Decisions shown; 3 tagged should have
#        defaulted, by thread (11111111 2, 22222222 1) with each thread's
#        model read from a fixture transcript (`unknown` when it has none)
#   4.1  `report --week <any day of it>` prints that as a numbered list and a
#        small table; any day of the week reports the same week; the next
#        week and an empty week; the default week is this one on the
#        store's clock; the report records nothing; before migration 008 it
#        exits 1 naming migrate
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

hq_t_require_db "report.test.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: report.test.sh — jq is not installed (the report needs it)"
  exit 0
fi

HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

S="hq_test_$$_$(printf '%05d' "$RANDOM")_report"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-report-test.XXXXXX")
TRANSCRIPTS="$TESTS_DIR/fixtures/report/transcripts"
S1=11111111-aaaa-4aaa-8aaa-111111111111
S2=22222222-bbbb-4bbb-8bbb-222222222222

admin_sql() { hq_psql -At -c "$1"; }
cleanup() {
  admin_sql "DROP SCHEMA IF EXISTS $S CASCADE;" >/dev/null 2>&1 \
    || echo "WARN: could not drop scratch schema $S — drop it by hand" >&2
  rm -rf "$TMP"
  hq__cleanup_tmp
}
trap cleanup EXIT

sql_in() { hq_psql -At -c "SET search_path TO $S; $1" 2>&1; }

# hq ARGS... — the CLI in the scratch schema, reading the fixture
# transcripts; sets OUT, ERR, RC.
hq() {
  RC=0
  HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_TRANSCRIPTS_DIR="$TRANSCRIPTS" \
    bash "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}
# jqo FILTER — compact, keys sorted, so no check depends on key order.
jqo() { printf '%s' "$OUT" | jq -S -c "$1"; }

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

hq migrate
check "migrate the scratch schema" "$RC" "0"
if [ "$RC" -ne 0 ]; then
  printf 'migrate failed: %s\n' "$ERR"
  hq_t_finish "report.test.sh"
  exit 1
fi

# --- the fixture week ---------------------------------------------------------
# Every time is America/New_York, in EDT (UTC-4) throughout September.
# Decisions (asked -> first answer; age in minutes when open in the week):
#   D-1  S1  Sun 09-06 22:00 -> Mon 09:04             664
#   D-2  S1  Mon 08:55       -> Mon 09:06              11
#   D-3  S2  Tue 13:00       -> Tue 15:00             120
#   D-4  S2  Wed 10:00       -> never         (open) 6600 = to Mon 09-14 00:00
#   D-5  S1  Thu 16:00       -> Tue 09-15     (open) 4800 = to Mon 09-14 00:00
#   D-6  S1  Wed 09-02       -> Thu 09-03       (not in the week)
#   D-7  S1  Mon 09-14 10:00 -> never           (next week)
#   D-8  S2  Fri 11:00       -> Fri 11:03               3
#   median of 3, 11, 120, 664, 4800, 6600 = (120 + 664) / 2 = 392 = 6h 32m
# Reviews: R-1 reviewed Mon, R-2 flagged Wed, R-3 reviewed Wed.
FIXTURE=$(sql_in "
INSERT INTO items (id, kind, repo, key, session_id, question, status, created_at) VALUES
  ('D-1', 'decision', 'acme/widgets', 'issue-1', '$S1', 'Ship it?',        'answered', '2026-09-06 22:00-04'),
  ('D-2', 'decision', 'acme/widgets', 'issue-2', '$S1', 'Rename it?',      'answered', '2026-09-07 08:55-04'),
  ('D-3', 'decision', 'acme/gadgets', 'issue-3', '$S2', 'Split it?',       'answered', '2026-09-08 13:00-04'),
  ('D-4', 'decision', 'acme/gadgets', 'issue-4', '$S2', 'Drop it?',        'open',     '2026-09-09 10:00-04'),
  ('D-5', 'decision', 'acme/widgets', 'issue-5', '$S1', 'Pin it?',         'answered', '2026-09-10 16:00-04'),
  ('D-6', 'decision', 'acme/widgets', 'issue-6', '$S1', 'Retry it?',       'answered', '2026-09-02 10:00-04'),
  ('D-7', 'decision', 'acme/widgets', 'issue-7', '$S1', 'Cache it?',       'open',     '2026-09-14 10:00-04'),
  ('D-8', 'decision', 'acme/gadgets', 'issue-8', '$S2', 'Log it?',         'answered', '2026-09-11 11:00-04'),
  ('R-1', 'review',   'acme/widgets', 'pr-1',    NULL,  'PR #1',           'reviewed', '2026-09-07 07:00-04'),
  ('R-2', 'review',   'acme/widgets', 'pr-2',    NULL,  'PR #2',           'flagged',  '2026-09-08 07:00-04'),
  ('R-3', 'review',   'acme/gadgets', 'pr-3',    NULL,  'PR #3',           'reviewed', '2026-09-09 07:00-04');
INSERT INTO events (item_id, kind, at, note, session_id) VALUES
  -- the week before
  ('D-6', 'asked',        '2026-09-02 10:00-04', NULL, NULL),
  ('D-6', 'answered',     '2026-09-03 10:00-04', 'option A', NULL),
  ('D-6', 'feedback',     '2026-09-03 10:01-04', 'should-have-defaulted', '$S1'),
  ('D-1', 'asked',        '2026-09-06 22:00-04', NULL, NULL),
  ('D-1', 'shown',        '2026-09-06 23:55-04', 'set 1 #1', NULL),
  -- Monday: one sitting 09:00 -> 09:09 (10 min); a lone shown at 14:00 (0)
  ('D-2', 'asked',        '2026-09-07 08:55-04', NULL, NULL),
  ('R-1', 'asked',        '2026-09-07 07:00-04', 'synced from GitHub', NULL),
  ('D-1', 'shown',        '2026-09-07 09:00-04', 'set 2 #1', NULL),
  ('D-2', 'shown',        '2026-09-07 09:00-04', 'set 2 #2', NULL),
  ('D-1', 'answered',     '2026-09-07 09:04-04', 'option A', NULL),
  ('D-1', 'feedback',     '2026-09-07 09:05-04', 'should-have-defaulted', '$S1'),
  ('D-2', 'answered',     '2026-09-07 09:06-04', 'option B', NULL),
  ('D-2', 'feedback',     '2026-09-07 09:07-04', 'not-important', '$S1'),
  ('R-1', 'reviewed',     '2026-09-07 09:08-04', NULL, NULL),
  ('D-2', 'feedback',     '2026-09-07 09:08-04', 'too-wordy', '$S1'),
  ('R-1', 'feedback',     '2026-09-07 09:09-04', 'not-important', NULL),
  ('D-1', 'woken',        '2026-09-07 09:10-04', 'local_1', NULL),
  ('D-1', 'acknowledged', '2026-09-07 09:11-04', NULL, NULL),
  ('D-2', 'shown',        '2026-09-07 14:00-04', 'set 3 #1', NULL),
  -- Tuesday: a lone shown at 13:00 (0); 14:58 -> 15:01 (4 min)
  ('D-3', 'asked',        '2026-09-08 13:00-04', NULL, NULL),
  ('R-2', 'asked',        '2026-09-08 07:00-04', 'synced from GitHub', NULL),
  ('D-3', 'shown',        '2026-09-08 13:00-04', 'set 4 #1', NULL),
  ('D-3', 'commented',    '2026-09-08 14:58-04', 'talked it through', NULL),
  ('D-3', 'answered',     '2026-09-08 15:00-04', 'option A', NULL),
  ('D-3', 'feedback',     '2026-09-08 15:01-04', 'should-have-defaulted', '$S2'),
  -- Wednesday: 10:01 -> 10:17, the last gap exactly 10 minutes (17 min)
  ('D-4', 'asked',        '2026-09-09 10:00-04', NULL, NULL),
  ('R-3', 'asked',        '2026-09-09 07:00-04', 'synced from GitHub', NULL),
  ('D-4', 'shown',        '2026-09-09 10:01-04', 'set 5 #1', NULL),
  ('R-2', 'flagged',      '2026-09-09 10:05-04', 'needs a test', NULL),
  ('D-4', 'feedback',     '2026-09-09 10:06-04', 'not-important', '$S2'),
  ('R-3', 'reviewed',     '2026-09-09 10:07-04', NULL, NULL),
  ('R-3', 'commented',    '2026-09-09 10:17-04', 'follow up later', NULL),
  -- Thursday: 16:00 -> 16:02 (3 min); a shown 11 minutes later is alone (0)
  ('D-5', 'asked',        '2026-09-10 16:00-04', NULL, NULL),
  ('D-5', 'shown',        '2026-09-10 16:00-04', 'set 6 #1', NULL),
  ('D-5', 'feedback',     '2026-09-10 16:02-04', 'should-have-defaulted', '$S1'),
  ('D-5', 'shown',        '2026-09-10 16:13-04', 'set 7 #1', NULL),
  -- Friday: 11:00 -> 11:04 (5 min)
  ('D-8', 'asked',        '2026-09-11 11:00-04', NULL, NULL),
  ('D-8', 'shown',        '2026-09-11 11:00-04', 'set 8 #1', NULL),
  ('D-8', 'answered',     '2026-09-11 11:03-04', 'option A', NULL),
  ('D-8', 'feedback',     '2026-09-11 11:04-04', 'good-interrupt', '$S2'),
  -- the week after
  ('D-7', 'asked',        '2026-09-14 10:00-04', NULL, NULL),
  ('D-7', 'shown',        '2026-09-14 10:00-04', 'set 9 #1', NULL),
  ('D-5', 'answered',     '2026-09-15 10:00-04', 'option B', NULL),
  ('D-7', 'feedback',     '2026-09-14 10:02-04', 'should-have-defaulted', '$S1');
")
check "setup: the fixture week loads (no error)" "$FIXTURE" ""
EVENTS_BEFORE=$(sql_in "SELECT count(*) || ':' || max(id) FROM events")

# --- 5.1 every measure against hand-computed values -----------------------
hq report --week 2026-09-09 --json
check "report --json: exit 0" "$RC" "0"
check "report --json: nothing on stderr" "$ERR" ""
check "5.1 the week: Monday to Sunday, New York" "$(jqo '.week')" \
  '{"end":"2026-09-13","start":"2026-09-07","tz":"America/New_York"}'
check "5.1 minutes: 10 + 4 + 17 + 3 + 5 over 5 sittings" "$(jqo '.minutes')" '{"sittings":5,"total":39}'
check "5.1 minutes per day" "$(jqo '[.days[] | .minutes]')" '[10,4,17,3,5,0,0]'
check "5.1 items handled per day" "$(jqo '[.days[] | [.dow, .handled, .decisions, .reviews]]')" \
  '[["Mon",3,2,1],["Tue",1,1,0],["Wed",2,0,2],["Thu",0,0,0],["Fri",1,1,0],["Sat",0,0,0],["Sun",0,0,0]]'
check "5.1 Decisions asked per day" "$(jqo '[.days[] | .asked]')" '[1,1,1,1,1,0,0]'
check "5.1 desk days: Thursday's tag counts, the weekend does not" "$(jqo '[.days[] | .desk]')" \
  '[true,true,true,true,true,false,false]'
check "5.1 items per day: 7 handled on 5 desk days" "$(jqo '.handled')" \
  '{"desk_days":5,"per_desk_day":1.4,"total":7}'
check "5.1 median open age: 392 min over 6 Decisions, 2 still open" "$(jqo '.open_age')" \
  '{"decisions":6,"median_minutes":392,"still_open":2}'
check "5.1 not important: 3 of 6 Decisions shown" "$(jqo '.not_important')" '{"shown":6,"tagged":3}'
check "5.1 should have defaulted: 3 (the week before and after left out)" "$(jqo '.should_have_defaulted')" '{"tagged":3}'
check "5.1 by thread and model" "$(jqo '.threads')" \
  "[{\"asked\":2,\"good_interrupt\":0,\"model\":\"claude-sonnet-4-5\",\"not_important\":1,\"session\":\"$S1\",\"should_have_defaulted\":2},{\"asked\":3,\"good_interrupt\":1,\"model\":\"unknown\",\"not_important\":1,\"session\":\"$S2\",\"should_have_defaulted\":1},{\"asked\":null,\"good_interrupt\":0,\"model\":null,\"not_important\":1,\"session\":null,\"should_have_defaulted\":0}]"
JSON_WEEK="$OUT"

# --- 4.1 the text: a numbered list and a small table ------------------------
hq report --week 2026-09-09
check "report: exit 0" "$RC" "0"
EXPECTED='**Attention report · week of 2026-09-07 to 2026-09-13**

1. Minutes spent answering: 39 min over 5 sittings
2. Items per day: 1.4 per desk day (7 handled on 5 days) · Mon 3 · Tue 1 · Wed 2 · Thu 0 · Fri 1 · Sat 0 · Sun 0
3. Median age of an open Decision: 6h 32m (6 Decisions open during the week, 2 still open at its end)
4. Interrupts tagged not important: 3 (of 6 Decisions shown)
5. Questions tagged should have defaulted: 3, by thread and model:

| Thread | Model | Asked | Should have defaulted | Not important | Good interrupt |
|--------|-------|------:|----------------------:|--------------:|---------------:|
| 11111111 | claude-sonnet-4-5 | 2 | 2 | 1 | 0 |
| 22222222 | unknown | 3 | 1 | 1 | 1 |
| (no thread) | – | – | 0 | 1 | 0 |'
check "4.1 the report as a numbered list and a small table" "$OUT" "$EXPECTED"
for day in 2026-09-07 2026-09-13; do
  hq report --week "$day" --json
  check "4.1 --week $day reports the same week" "$RC:$OUT" "0:$JSON_WEEK"
done

# --- the next week, and an empty one -----------------------------------------
# D-4 (asked Wed 09-09 10:00, never answered: 16680), D-5 (asked Thu 09-10
# 16:00, answered Tue 09-15 10:00: 6840), D-7 (asked Mon 09-14 10:00, never
# answered: 9480); median 9480 = 6d 14h.
hq report --week 2026-09-14 --json
check "the next week: its open Decisions" "$RC:$(jqo '.open_age')" '0:{"decisions":3,"median_minutes":9480,"still_open":2}'
check "the next week: D-7's tag, by its thread" "$(jqo '[.should_have_defaulted.tagged, (.threads | map([.session, .should_have_defaulted, .asked]))]')" \
  "[1,[[\"$S1\",1,1]]]"
check "the next week: one sitting of 3 minutes (D-5's answer is alone: 1)" "$(jqo '.minutes')" '{"sittings":2,"total":4}'
hq report --week 2026-08-05
check "an empty week: exit 0" "$RC" "0"
EMPTY='**Attention report · week of 2026-08-03 to 2026-08-09**

1. Minutes spent answering: 0 (no desk activity)
2. Items per day: none handled · Mon 0 · Tue 0 · Wed 0 · Thu 0 · Fri 0 · Sat 0 · Sun 0
3. Median age of an open Decision: none was open this week
4. Interrupts tagged not important: 0 (of 0 Decisions shown)
5. Questions tagged should have defaulted: 0

No thread was tagged this week.'
check "an empty week renders every measure as none" "$OUT" "$EMPTY"

# --- the default week is this one on the store's clock -------------------------
TODAY=$(sql_in "SELECT to_char(statement_timestamp() AT TIME ZONE 'America/New_York', 'YYYY-MM-DD')")
MONDAY=$(sql_in "SELECT to_char(d - (extract(isodow FROM d)::int - 1), 'YYYY-MM-DD') FROM (SELECT (statement_timestamp() AT TIME ZONE 'America/New_York')::date AS d) t")
hq report --json
check "no --week: this week" "$RC:$(jqo '[.week.start, .today]')" "0:[\"$MONDAY\",\"$TODAY\"]"
check "no --week: the days so far, Monday to today" "$(jqo '.days[-1].day')" "\"$TODAY\""

# --- read-only ----------------------------------------------------------------
check "the report records nothing" "$(sql_in "SELECT count(*) || ':' || max(id) FROM events")" "$EVENTS_BEFORE"

# --- before migration 008 ------------------------------------------------------
OLD=$(sql_in "ALTER TABLE events DROP COLUMN session_id; DELETE FROM schema_migrations WHERE filename = '008_event_session.sql';")
check "setup: the store is 007's again (no error)" "$OLD" ""
hq report --week 2026-09-09
check "before 008: exit 1 naming migrate" "$RC|$ERR" \
  "1|human-queue: report: the store is not migrated (run human-queue.sh migrate)"

check "the public schema is untouched" \
  "$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")" "$PUBLIC_BEFORE"

hq_t_finish "report.test.sh"
