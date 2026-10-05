#!/usr/bin/env bash
# desk/tests/items.test.sh — live tests for the item subcommands add, bump,
# get, list, and show (issue #1775), against the database in
# HUMAN_QUEUE_DATABASE_URL.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. Every run creates throwaway schemas named
# hq_test_<pid>_<random>_*, points the CLI at them with HUMAN_QUEUE_SCHEMA,
# and drops them on exit. The suite also asserts that the number of tables in
# `public` is unchanged.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset. With the
# URL set, an unreachable database FAILS the suite.
#
# Asserts (issue #1775 Test Plan and AC):
#   5.1  a Decision with every field: add prints D-1; get prints exactly the
#        expected block (bold question, numbered context, lettered options);
#        get --json and list --json round-trip every field; status is open
#   5.2  the same question again (case and whitespace differ): the same id,
#        one item, events asked then bumped; the session (return address) is
#        refreshed, fields not given keep their values
#   5.3  ten parallel adds of distinct questions: ten distinct ids, all exit 0,
#        nothing on stderr; ten parallel adds of ONE question: one item, one
#        `asked` and nine `bumped` events (AC 4.5)
#   5.4  a missing question exits 4 naming it; a token-shaped question exits 5;
#        neither stores anything
#   and: kind and key are part of the dedupe key; an answered question asked
#        again is a new item; the unique index backs the dedupe up; bump
#        writes `bumped` with its note and exits 4 on an unknown id; get, list,
#        and show record no event; list filters and orders (parked, impact,
#        age); show lists events oldest first; a repeat that replaces the
#        options clears a default that is no longer one of them; migration
#        002 seeds the id sequences past existing rows (skipping an id beyond
#        bigint, which get still reads) and stops, naming the ids and
#        changing nothing, when open items already repeat a question; an
#        unmigrated store exits 1 with a hint
# On macOS, a share of the calls (including half of each parallel batch) run
# under /bin/bash 3.2.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

hq_t_require_db "items.test.sh"

# Reuse the CLI's own connection library so the URL never reaches argv here
# either. hq_db_connect exits 7 (failing this suite) when unreachable.
HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

BASE="hq_test_$$_$(printf '%05d' "$RANDOM")"
S_MAIN="${BASE}_items"
S_SEED="${BASE}_seed"
S_DUP="${BASE}_dup"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-items-test.XXXXXX")

admin_sql() { hq_psql -At -c "$1"; }

cleanup() {
  admin_sql "DROP SCHEMA IF EXISTS $S_MAIN CASCADE; DROP SCHEMA IF EXISTS $S_SEED CASCADE; DROP SCHEMA IF EXISTS $S_DUP CASCADE;" >/dev/null 2>&1 \
    || echo "WARN: could not drop scratch schemas $S_MAIN / $S_SEED / $S_DUP — drop them by hand" >&2
  rm -rf "$TMP"
  hq__cleanup_tmp
}
trap cleanup EXIT

# sql_in SCHEMA SQL — one query in SCHEMA, unaligned tuples only.
sql_in() { hq_psql -At -c "SET search_path TO $1; $2" 2>&1; }

OLD_BASH=bash
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  OLD_BASH=/bin/bash
fi

JQ=""
if command -v jq >/dev/null 2>&1; then JQ=$(command -v jq); fi

# hq SHELL SCHEMA ARGS... — runs the CLI; sets OUT, ERR, RC.
hq() {
  local sh="$1" schema="$2"
  shift 2
  RC=0
  HUMAN_QUEUE_SCHEMA="$schema" "$sh" "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# events_of SCHEMA ID — the item's event kinds, oldest first, comma-joined.
events_of() { sql_in "$1" "SELECT string_agg(kind, ',' ORDER BY at, id) FROM events WHERE item_id = '$2'"; }

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

hq bash "$S_MAIN" migrate
check "migrate the scratch schema" "$RC" "0"
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$ERR"
  hq_t_finish "items.test.sh"
  exit 1
fi
echo "scratch schema: $S_MAIN (old shell: $OLD_BASH)"

REPO=auerbachb/claude-code-config
Q1="Ship the migration before the CLI?"

# --- 5.1: a Decision with every field -----------------------------------------
hq "$OLD_BASH" "$S_MAIN" add --kind decision --repo "$REPO" --key pr-1775 --session sess-a \
  --question "$Q1" \
  --context "Migration 002 adds the id sequences." \
  --context "The CLI allocates ids from them." \
  --context "Rolling back means a new migration." \
  --option "Ship now" --option "Wait for review" --default "Wait for review" \
  --default-at 2026-10-05T18:00-04:00 --impact high --parked --cost "~10 min" --focus "no deep focus"
check "5.1 add exits 0" "$RC" "0"
check "5.1 add prints the new id alone" "$OUT" "D-1"
check "5.1 add is silent on stderr" "$ERR" ""

ASKED=$(sql_in "$S_MAIN" "SELECT to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI \"UTC\"') FROM items WHERE id = 'D-1'")
EXPECTED_D1="D-1 · decision · open · $REPO · pr-1775
**$Q1**
1. Migration 002 adds the id sequences.
2. The CLI allocates ids from them.
3. Rolling back means a new migration.
Options: A. Ship now · B. Wait for review
Default: B. Wait for review, at 2026-10-05 22:00 UTC
Asked $ASKED · Impact: high · Cost: ~10 min · Focus: no deep focus · Parked · Session: sess-a"

hq bash "$S_MAIN" get D-1
check "5.1 get exits 0" "$RC" "0"
check "5.1 get prints the item: bold question, numbered context, lettered options" "$OUT" "$EXPECTED_D1"
hq "$OLD_BASH" "$S_MAIN" get d-1
check "get accepts a lowercase id and prints the canonical one" "$OUT" "$EXPECTED_D1"
hq bash "$S_MAIN" list
check "5.1 list prints the same block" "$OUT" "$EXPECTED_D1"

if [ -n "$JQ" ]; then
  hq bash "$S_MAIN" get D-1 --json
  check "5.1 get --json exits 0" "$RC" "0"
  R=$(printf '%s' "$OUT" | "$JQ" -r '[.id, .kind, .status, .repo, .key, .session_id, .question,
        (.context | join("|")), (.options | join("|")), .default_option, .default_at,
        .impact_declared, (.parked | tostring), .cost, .focus, (.answer // "null")] | join("\n")')
  check "5.1 get --json round-trips every field, status open" "$R" "D-1
decision
open
$REPO
pr-1775
sess-a
$Q1
Migration 002 adds the id sequences.|The CLI allocates ids from them.|Rolling back means a new migration.
Ship now|Wait for review
Wait for review
2026-10-05T22:00:00+00:00
high
true
~10 min
no deep focus
null"
  hq bash "$S_MAIN" list --json
  check "5.1 list --json holds one item" "$(printf '%s' "$OUT" | "$JQ" -r 'length')" "1"
  check "5.1 list --json matches get --json" \
    "$(printf '%s' "$OUT" | "$JQ" -cS '.[0]')" \
    "$(HUMAN_QUEUE_SCHEMA="$S_MAIN" bash "$HQ_T_CLI" get D-1 --json | "$JQ" -cS '.')"
else
  echo "NOTICE: jq not installed — JSON round-trip checks skipped (text checks above still ran)"
fi
check "5.1 add recorded exactly one asked event" "$(events_of "$S_MAIN" D-1)" "asked"

# --- 5.2: the same question again ------------------------------------------------
hq bash "$S_MAIN" add --kind decision --repo "$REPO" --key pr-1775 --session sess-b \
  --question "  ship the MIGRATION   before the cli? "
check "5.2 the repeat exits 0" "$RC" "0"
check "5.2 the repeat prints the same id" "$OUT" "D-1"
check "5.2 one item, not two" "$(sql_in "$S_MAIN" "SELECT count(*) FROM items")" "1"
check "5.2 two events: asked, then bumped" "$(events_of "$S_MAIN" D-1)" "asked,bumped"
R=$(sql_in "$S_MAIN" "SELECT session_id || '|' || question || '|' || cardinality(context) || '|' || default_option || '|' || parked FROM items WHERE id = 'D-1'")
check "5.2 the session is refreshed; question and unsent fields keep" "$R" "sess-b|$Q1|3|Wait for review|true"

hq bash "$S_MAIN" add --kind decision --repo "$REPO" --key pr-1775 --question "$Q1" \
  --context "Only one line now." --impact low
check "a repeat replaces the fields it gives" \
  "$(sql_in "$S_MAIN" "SELECT array_to_string(context, '|') || '|' || impact_declared || '|' || session_id FROM items WHERE id = 'D-1'")" \
  "Only one line now.|low|sess-b"

hq bash "$S_MAIN" show D-1
check "show exits 0" "$RC" "0"
check_contains "show starts with the item" "$OUT" "**$Q1**"
EVENT_LINES=$(printf '%s\n' "$OUT" | sed -n '/^Events:$/,$p' | sed -n 's/^- [0-9-]* [0-9:]* UTC  //p' | tr '\n' ',')
check "show lists the events oldest first" "$EVENT_LINES" "asked,bumped,bumped,"
if [ -n "$JQ" ]; then
  hq bash "$S_MAIN" show D-1 --json
  check "show --json lists the events" "$(printf '%s' "$OUT" | "$JQ" -r '[.item.id] + [.events[].kind] | join(",")')" "D-1,asked,bumped,bumped"
fi

# --- the dedupe key: kind, repo, key, question; open items only ------------------
hq bash "$S_MAIN" add --kind review --repo "$REPO" --key pr-1775 --question "$Q1" --impact medium
check "the same question as a Review is a new R- item" "$OUT" "R-1"
hq bash "$S_MAIN" add --kind decision --repo "$REPO" --key pr-1776 --question "$Q1"
check "the same question on another key is a new item" "$OUT" "D-2"
hq bash "$S_MAIN" add --kind decision --repo auerbachb/other --key pr-1775 --question "$Q1"
check "the same question in another repo is a new item" "$OUT" "D-3"

# --- list: filters and order -----------------------------------------------------
if [ -n "$JQ" ]; then
  hq bash "$S_MAIN" list --json
  check "list orders parked first, then impact, then age" \
    "$(printf '%s' "$OUT" | "$JQ" -r '[.[].id] | join(",")')" "D-1,R-1,D-2,D-3"
fi
hq "$OLD_BASH" "$S_MAIN" list --kind review
check "list --kind review exits 0" "$RC" "0"
check "list --kind review prints the review only" "$(printf '%s\n' "$OUT" | grep -c ' · review · ')" "1"
check_absent "list --kind review leaves Decisions out" "$OUT" "D-1 ·"
hq bash "$S_MAIN" list --status answered
check "list with no match exits 0" "$RC" "0"
check "list with no match prints nothing" "$OUT" ""
hq bash "$S_MAIN" list --status answered --json
check "list --json with no match prints []" "$OUT" "[]"
hq bash "$S_MAIN" list --kind decision --status open
check "list separates items with one blank line" "$(printf '%s\n' "$OUT" | grep -c '^$')" "2"
check "list prints every question in bold" "$(printf '%s\n' "$OUT" | grep -c '^\*\*.*\*\*$')" "3"

# --- an answered question asked again is a new item ------------------------------
sql_in "$S_MAIN" "UPDATE items SET status = 'answered', answer = 'Wait for review' WHERE id = 'D-2'" >/dev/null
hq bash "$S_MAIN" add --kind decision --repo "$REPO" --key pr-1776 --question "$Q1"
check "re-asking an answered question opens a new item" "$OUT" "D-4"
hq bash "$S_MAIN" get D-2
check_contains "get prints the answer once there is one" "$OUT" "Answer: Wait for review"
check_contains "get prints the status" "$OUT" "D-2 · decision · answered ·"

# The unique index backs the advisory lock up: a second OPEN row with the same
# kind, repo, key, and question cannot exist even if a writer skips the CLI.
R=$(sql_in "$S_MAIN" "INSERT INTO items (id, kind, repo, key, question) VALUES ('D-900', 'decision', '$REPO', 'pr-1776', 'SHIP the migration before the CLI?')" || true)
check_contains "the unique index refuses a second open copy" "$R" "items_open_question_key"

# --- a repeat that replaces the options keeps the default only if it still fits --
QD="Which default survives a new option list?"
hq bash "$S_MAIN" add --kind decision --repo "$REPO" --key pr-defaults --question "$QD" \
  --option Alpha --option Beta --default Beta --default-at 2026-10-05T18:00Z
DID="$OUT"
hq "$OLD_BASH" "$S_MAIN" add --kind decision --repo "$REPO" --key pr-defaults --question "$QD" \
  --option Alpha --option Beta --option Gamma
check "new options that include the stored default bump the same item" "$OUT" "$DID"
check "new options that include the stored default keep it and its time" \
  "$(sql_in "$S_MAIN" "SELECT default_option || '|' || (default_at IS NOT NULL) FROM items WHERE id = '$DID'")" \
  "Beta|true"
hq bash "$S_MAIN" add --kind decision --repo "$REPO" --key pr-defaults --question "$QD" \
  --option Alpha --option Gamma
check "new options without the stored default clear it and its time" \
  "$(sql_in "$S_MAIN" "SELECT coalesce(default_option, 'none') || '|' || coalesce(default_at::text, 'none') || '|' || array_to_string(options, ',') FROM items WHERE id = '$DID'")" \
  "none|none|Alpha,Gamma"
hq bash "$S_MAIN" get "$DID"
check_absent "a cleared default is not printed" "$OUT" "Default:"
hq bash "$S_MAIN" add --kind decision --repo "$REPO" --key pr-defaults --question "$QD" \
  --option Delta --option Gamma --default Delta
check "new options with a new default store both" \
  "$(sql_in "$S_MAIN" "SELECT default_option || '|' || array_to_string(options, ',') FROM items WHERE id = '$DID'")" \
  "Delta|Delta,Gamma"
hq bash "$S_MAIN" add --kind decision --repo "$REPO" --key pr-defaults --question "$QD" --impact high
check "a repeat without options keeps the stored default" \
  "$(sql_in "$S_MAIN" "SELECT default_option FROM items WHERE id = '$DID'")" "Delta"

# --- bump ------------------------------------------------------------------------
BEFORE=$(sql_in "$S_MAIN" "SELECT updated_at FROM items WHERE id = 'R-1'")
hq "$OLD_BASH" "$S_MAIN" bump r-1 --note "rebased onto main"
check "bump exits 0" "$RC" "0"
check "bump prints the canonical id" "$OUT" "R-1"
check "bump is silent on stderr" "$ERR" ""
check "bump writes one bumped event with its note" \
  "$(sql_in "$S_MAIN" "SELECT kind || '|' || note FROM events WHERE item_id = 'R-1' ORDER BY at DESC, id DESC LIMIT 1")" \
  "bumped|rebased onto main"
check "bump refreshes updated_at" \
  "$(sql_in "$S_MAIN" "SELECT updated_at > '$BEFORE'::timestamptz FROM items WHERE id = 'R-1'")" "t"
check "bump leaves the status alone" "$(sql_in "$S_MAIN" "SELECT status FROM items WHERE id = 'R-1'")" "open"
hq bash "$S_MAIN" bump D-999
check "bump of an unknown id exits 4" "$RC" "4"
check_contains "bump names the missing id" "$ERR" "no item D-999"
check "bump of an unknown id writes nothing" \
  "$(sql_in "$S_MAIN" "SELECT count(*) FROM events WHERE item_id = 'D-999'")" "0"
hq bash "$S_MAIN" get D-999
check "get of an unknown id exits 4" "$RC" "4"
check_contains "get names the missing id" "$ERR" "no item D-999"
hq bash "$S_MAIN" show R-999
check "show of an unknown id exits 4" "$RC" "4"

# --- reads record nothing ----------------------------------------------------------
N_EVENTS=$(sql_in "$S_MAIN" "SELECT count(*) FROM events")
hq bash "$S_MAIN" get D-1
hq bash "$S_MAIN" show D-1
hq bash "$S_MAIN" list
check "get, show, and list record no event" "$(sql_in "$S_MAIN" "SELECT count(*) FROM events")" "$N_EVENTS"

# --- 5.4: refusals store nothing -------------------------------------------------
N_ITEMS=$(sql_in "$S_MAIN" "SELECT count(*) FROM items")
hq bash "$S_MAIN" add --kind decision --repo "$REPO" --key pr-1775
check "5.4 a missing question exits 4" "$RC" "4"
check_contains "5.4 the missing field is named" "$ERR" "--question"
FAKE_GH="gh""p_abcdefghijklmnopqrstuvwxyz0123456789"
hq bash "$S_MAIN" add --kind decision --repo "$REPO" --key pr-1775 --question "Is $FAKE_GH still valid?"
check "5.4 a token-shaped question exits 5" "$RC" "5"
check_absent "5.4 the token is never echoed" "$OUT$ERR" "$FAKE_GH"
check "5.4 neither refusal stored an item" "$(sql_in "$S_MAIN" "SELECT count(*) FROM items")" "$N_ITEMS"

# --- 5.3: ten parallel adds of distinct questions --------------------------------
i=1
PIDS=""
while [ "$i" -le 10 ]; do
  sh=bash
  if [ $((i % 2)) -eq 0 ]; then sh="$OLD_BASH"; fi
  HUMAN_QUEUE_SCHEMA="$S_MAIN" "$sh" "$HQ_T_CLI" add --kind decision --repo "$REPO" --key pr-parallel \
    --question "Parallel question number $i?" >"$TMP/p$i.out" 2>"$TMP/p$i.err" </dev/null &
  PIDS="$PIDS $!"
  i=$((i + 1))
done
FAILS=0
for pid in $PIDS; do
  wait "$pid" || FAILS=$((FAILS + 1))
done
check "5.3 ten parallel adds all exit 0" "$FAILS" "0"
check "5.3 ten parallel adds are silent on stderr" "$(cat "$TMP"/p*.err)" ""
IDS=$(cat "$TMP"/p*.out | LC_ALL=C sort -u)
check "5.3 ten parallel adds print ten distinct ids" "$(hq_t_lines "$IDS")" "10"
check "5.3 every printed id is a Decision id" "$(printf '%s\n' "$IDS" | grep -c '^D-[1-9][0-9]*$')" "10"
check "5.3 ten items exist" \
  "$(sql_in "$S_MAIN" "SELECT count(*) FROM items WHERE key = 'pr-parallel'")" "10"
check "5.3 each has exactly one asked event" \
  "$(sql_in "$S_MAIN" "SELECT count(*) FROM events e JOIN items i ON i.id = e.item_id WHERE i.key = 'pr-parallel' AND e.kind = 'asked'")" "10"
rm -f "$TMP"/p*.out "$TMP"/p*.err

# --- AC 4.5: ten parallel adds of ONE question -----------------------------------
i=1
PIDS=""
while [ "$i" -le 10 ]; do
  sh=bash
  if [ $((i % 2)) -eq 0 ]; then sh="$OLD_BASH"; fi
  HUMAN_QUEUE_SCHEMA="$S_MAIN" "$sh" "$HQ_T_CLI" add --kind decision --repo "$REPO" --key pr-race \
    --question "Which of the racing questions wins?" --session "racer-$i" \
    >"$TMP/p$i.out" 2>"$TMP/p$i.err" </dev/null &
  PIDS="$PIDS $!"
  i=$((i + 1))
done
FAILS=0
for pid in $PIDS; do
  wait "$pid" || FAILS=$((FAILS + 1))
done
check "4.5 ten parallel identical adds all exit 0" "$FAILS" "0"
check "4.5 ten parallel identical adds are silent on stderr" "$(cat "$TMP"/p*.err)" ""
check "4.5 all ten print the same id" "$(hq_t_lines "$(cat "$TMP"/p*.out | LC_ALL=C sort -u)")" "1"
check "4.5 one item exists" "$(sql_in "$S_MAIN" "SELECT count(*) FROM items WHERE key = 'pr-race'")" "1"
check "4.5 one asked and nine bumped events" \
  "$(sql_in "$S_MAIN" "SELECT string_agg(kind || '=' || n, ',' ORDER BY kind) FROM (SELECT e.kind, count(*) AS n FROM events e JOIN items i ON i.id = e.item_id WHERE i.key = 'pr-race' GROUP BY e.kind) s")" \
  "asked=1,bumped=9"
rm -f "$TMP"/p*.out "$TMP"/p*.err

# --- migration 002 seeds the sequences past existing ids -------------------------
mkdir -p "$TMP/only001/desk/schema"
cp -R "$HQ_T_DESK_DIR/bin" "$TMP/only001/desk/"
cp "$HQ_T_DESK_DIR/schema/001_init.sql" "$TMP/only001/desk/schema/"
RC=0
HUMAN_QUEUE_SCHEMA="$S_SEED" bash "$TMP/only001/desk/bin/human-queue.sh" migrate >/dev/null 2>"$TMP/err" </dev/null || RC=$?
check "a schema at 001 only migrates" "$RC" "0"
hq bash "$S_SEED" add --kind decision --repo "$REPO" --key k --question "Before 002?"
check "add on a store without 002 exits 1" "$RC" "1"
check_contains "add on a store without 002 says to migrate" "$ERR" "run human-queue.sh migrate"
HUGE_ID="D-99999999999999999999"
sql_in "$S_SEED" "INSERT INTO items (id, kind, repo, key, question) VALUES ('D-41', 'decision', 'o/r', 'k', 'old one'), ('R-7', 'review', 'o/r', 'k', 'old two'), ('$HUGE_ID', 'decision', 'o/r', 'k', 'beyond bigint'), ('D-9223372036854775808', 'decision', 'o/r', 'k', 'bigint max plus one')" >/dev/null
hq bash "$S_SEED" migrate
check "002 applies over existing rows, two of them beyond bigint" "$RC" "0"
hq bash "$S_SEED" add --kind decision --repo "$REPO" --key k --question "After 002?"
check "the next Decision id follows the highest existing one that fits the sequence" "$OUT" "D-42"
hq bash "$S_SEED" add --kind review --repo "$REPO" --key k --question "Merged: after 002"
check "the next Review id follows the highest existing one" "$OUT" "R-8"
hq "$OLD_BASH" "$S_SEED" get "$HUGE_ID"
check "get reads an id longer than bigint" "$RC" "0"
check_contains "get prints that id" "$OUT" "$HUGE_ID · decision · open"

# --- migration 002 stops, naming the ids, when open items already repeat ---------
RC=0
HUMAN_QUEUE_SCHEMA="$S_DUP" bash "$TMP/only001/desk/bin/human-queue.sh" migrate >/dev/null 2>"$TMP/err" </dev/null || RC=$?
check "a second schema at 001 only migrates" "$RC" "0"
sql_in "$S_DUP" "INSERT INTO items (id, kind, repo, key, question, status) VALUES ('D-5', 'decision', 'o/r', 'k', 'Same question?', 'open'), ('D-6', 'decision', 'o/r', 'k', '  same   QUESTION? ', 'open'), ('D-7', 'decision', 'o/r', 'k', 'Same question?', 'closed'), ('D-8', 'decision', 'o/r', 'other', 'Same question?', 'open'), ('R-9223372036854775806', 'review', 'o/r', 'k', 'One below bigint max', 'open')" >/dev/null
hq bash "$S_DUP" migrate
check "002 refuses open items that repeat a question" "$RC" "1"
check_contains "002 names the repeating ids and what to do" "$ERR" "open items repeat the same question (D-5, D-6); close all but one"
check "a refused 002 records nothing" \
  "$(sql_in "$S_DUP" "SELECT count(*) FROM schema_migrations WHERE filename = '002_item_ids.sql'")" "0"
check "a refused 002 creates nothing" \
  "$(sql_in "$S_DUP" "SELECT count(*) FROM pg_class WHERE relname = 'items_decision_seq' AND relnamespace = '$S_DUP'::regnamespace")" "0"
sql_in "$S_DUP" "UPDATE items SET status = 'closed' WHERE id = 'D-6'" >/dev/null
hq bash "$S_DUP" migrate
check "002 applies once the repeat is closed" "$RC" "0"
hq bash "$S_DUP" add --kind decision --repo o/r --key k --question "same question?"
check "the surviving open item is the one a repeat bumps" "$OUT" "D-5"
hq bash "$S_DUP" add --kind review --repo o/r --key k --question "Merged: the last review id"
check "a 19-digit id that fits bigint seeds its sequence" "$OUT" "R-9223372036854775807"

# --- the live default schema was never touched -----------------------------------
PUBLIC_AFTER=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
check "public schema table count unchanged" "$PUBLIC_AFTER" "$PUBLIC_BEFORE"

hq_t_finish "items.test.sh"
