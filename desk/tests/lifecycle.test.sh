#!/usr/bin/env bash
# desk/tests/lifecycle.test.sh — live tests for the lifecycle, set, and control
# subcommands (issue #1776), against the database in HUMAN_QUEUE_DATABASE_URL.
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
# Asserts (issue #1776 Test Plan and AC):
#   5.1  answer D-1: pending-for the asking session returns it (text and
#        JSON); after ack it does not; other sessions never see it
#   5.2  set-open on four items numbers them 1 to 4 in `sets`; set-resolve
#        "2: B" writes the answer on the second item only
#   5.3  tick twice with one new item between: the second prints only it;
#        a write whose transaction started before a tick and committed after
#        it is reported by the next tick (a time watermark would miss it:
#        its updated_at is older than that tick); two concurrent ticks report
#        a change exactly once
#   4.2  answer, ack, review, flag, comment, feedback write one event each;
#        a call that changes nothing writes none; pending-for writes none
#   and: answers by letter store the option's text; a letter past the last
#        option, an unknown id, a Review, or an unanswered ack exit 4 and
#        write nothing; a new answer re-opens an acknowledged item; ack
#        --answer refuses a stale answer; set-resolve with several pairs, one
#        transaction that writes nothing when any pair is wrong, --set, and
#        "no set"; set numbering restarts at 1; set-open writes `shown`
#        events and refuses unknown ids; tick ignores annotations (comment,
#        feedback, shown); state get/set round-trips exactly and refuses
#        reserved keys; register-control replaces and reports the previous
#        session; migration 003 over a 002 store (existing rows marked, the
#        set sequence seeded past existing sets, the not-migrated hint before
#        it); the item JSON never carries change_xid
# On macOS a share of the calls run under /bin/bash 3.2.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

hq_t_require_db "lifecycle.test.sh"

# Reuse the CLI's own connection library so the URL never reaches argv here
# either. hq_db_connect exits 7 (failing this suite) when unreachable.
HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

BASE="hq_test_$$_$(printf '%05d' "$RANDOM")"
S_MAIN="${BASE}_life"
S_OLD="${BASE}_old"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-lifecycle-test.XXXXXX")
HELD_PID=""

admin_sql() { hq_psql -At -c "$1"; }

cleanup() {
  if [ -n "$HELD_PID" ]; then kill "$HELD_PID" 2>/dev/null || true; fi
  exec 3>&- 2>/dev/null || true
  admin_sql "DROP SCHEMA IF EXISTS $S_MAIN CASCADE; DROP SCHEMA IF EXISTS $S_OLD CASCADE;" >/dev/null 2>&1 \
    || echo "WARN: could not drop scratch schemas $S_MAIN / $S_OLD — drop them by hand" >&2
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

# jq_of FILTER — FILTER applied to $OUT (raw output), or SKIP-JQ without jq.
jq_of() {
  if [ -z "$JQ" ]; then printf 'SKIP-JQ'; return 0; fi
  printf '%s' "$OUT" | "$JQ" -r "$1"
}

# check_jq LABEL FILTER EXPECTED — a JSON check; skipped (noted) without jq.
check_jq() {
  if [ -z "$JQ" ]; then
    printf 'skip — %s (jq not installed)\n' "$1"
    return 0
  fi
  check "$1" "$(jq_of "$2")" "$3"
}

events_of() { sql_in "$1" "SELECT string_agg(kind, ',' ORDER BY id) FROM events WHERE item_id = '$2'"; }
n_events() { sql_in "$1" "SELECT count(*) FROM events"; }
field() { sql_in "$1" "SELECT coalesce($3::text, '<null>') FROM items WHERE id = '$2'"; }

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

hq bash "$S_MAIN" migrate
check "migrate the scratch schema" "$RC" "0"
check_contains "migrate applies 003" "$OUT" "applied 003_lifecycle.sql"
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$ERR"
  hq_t_finish "lifecycle.test.sh"
  exit 1
fi
echo "scratch schema: $S_MAIN (old shell: $OLD_BASH)"

REPO=auerbachb/claude-code-config
add_item() {
  # add_item SCHEMA KIND KEY QUESTION [ARGS...] — prints the new id.
  local schema="$1" kind="$2" key="$3" q="$4"
  shift 4
  HUMAN_QUEUE_SCHEMA="$schema" bash "$HQ_T_CLI" add --kind "$kind" --repo "$REPO" --key "$key" \
    --question "$q" "$@" </dev/null
}

# --- 5.3 (first half): the first tick reports everything, the next nothing ----
D1=$(add_item "$S_MAIN" decision pr-1776 "Ship the lifecycle commands first?" --session sess-a --parked \
  --option "Ship now" --option "Wait for review" --default "Wait for review")
check "setup: D-1 added" "$D1" "D-1"
hq "$OLD_BASH" "$S_MAIN" tick
check "the first tick exits 0" "$RC" "0"
check "the first tick is silent on stderr" "$ERR" ""
check_jq "the first tick reports every item" '[.[].id] | join(",")' "D-1"
check_jq "tick items carry the list --json shape, without change_xid" \
  '.[0] | [has("question"), has("status"), has("change_xid")] | map(tostring) | join(",")' "true,true,false"
hq bash "$S_MAIN" tick
check "a second tick with nothing new prints []" "$OUT" "[]"
check_contains "the watermark is a stored snapshot" \
  "$(sql_in "$S_MAIN" "SELECT value FROM state WHERE key = 'tick_watermark'")" ":"

# --- 5.1: answer, pending-for, ack ---------------------------------------------
EV0=$(n_events "$S_MAIN")
hq bash "$S_MAIN" pending-for sess-a
check "5.1 pending-for before any answer prints nothing" "$OUT" ""
check "5.1 pending-for before any answer exits 0" "$RC" "0"
hq "$OLD_BASH" "$S_MAIN" answer d-1 b
check "5.1 answer exits 0" "$RC" "0"
check "5.1 answer prints the canonical id" "$OUT" "D-1"
check "5.1 answer is silent on stderr" "$ERR" ""
check "5.1 a letter stores that option's text" "$(field "$S_MAIN" D-1 answer)" "Wait for review"
check "5.1 the status is answered" "$(field "$S_MAIN" D-1 status)" "answered"
check "5.1 answer wrote one event, noting the letter" \
  "$(sql_in "$S_MAIN" "SELECT kind || '|' || coalesce(note, '') FROM events WHERE item_id = 'D-1' ORDER BY id DESC LIMIT 1")" \
  "answered|option B"
check "5.1 answer wrote exactly one event" "$(n_events "$S_MAIN")" "$((EV0 + 1))"

hq bash "$S_MAIN" pending-for sess-a
check "5.1 pending-for returns the answered item" "$RC" "0"
check_contains "5.1 pending-for prints the question in bold" "$OUT" "**Ship the lifecycle commands first?**"
check_contains "5.1 pending-for prints the answer" "$OUT" "Answer: Wait for review"
hq "$OLD_BASH" "$S_MAIN" pending-for sess-a --json
check_jq "5.1 pending-for --json returns D-1 with its answer" '[.[] | .id + "=" + .answer] | join(",")' "D-1=Wait for review"
hq bash "$S_MAIN" pending-for sess-b --json
check "5.1 another session has nothing pending" "$OUT" "[]"
check "5.1 pending-for wrote no event" "$(n_events "$S_MAIN")" "$((EV0 + 1))"

hq bash "$S_MAIN" ack D-1 --answer "Wait for review"
check "5.1 ack exits 0" "$RC" "0"
check "5.1 ack prints the id" "$OUT" "D-1"
check "5.1 ack sets acknowledged and unparks" \
  "$(sql_in "$S_MAIN" "SELECT status || '|' || parked FROM items WHERE id = 'D-1'")" "acknowledged|false"
check "5.1 ack wrote one acknowledged event" "$(events_of "$S_MAIN" D-1)" "asked,answered,acknowledged"
hq bash "$S_MAIN" pending-for sess-a
check "5.1 after ack, pending-for no longer returns it" "$OUT" ""
hq bash "$S_MAIN" pending-for sess-a --json
check "5.1 after ack, pending-for --json is []" "$OUT" "[]"

# --- no-ops write nothing ---------------------------------------------------------
EV1=$(n_events "$S_MAIN")
hq "$OLD_BASH" "$S_MAIN" ack D-1
check "a second ack exits 0" "$RC" "0"
hq bash "$S_MAIN" answer D-1 "  Wait for review  "
check "re-sending the same answer exits 0" "$RC" "0"
check "the same answer keeps the item acknowledged" "$(field "$S_MAIN" D-1 status)" "acknowledged"
check "a repeated ack and a repeated answer write no event" "$(n_events "$S_MAIN")" "$EV1"

# --- a new answer re-opens an acknowledged item; ack --answer guards it ----------
hq bash "$S_MAIN" answer D-1 "$(printf '  Ship now, then follow up.\nKeep the flag off.  ')"
check "a new answer exits 0" "$RC" "0"
check "a new answer is stored trimmed, lines kept" "$(field "$S_MAIN" D-1 answer)" \
  "$(printf 'Ship now, then follow up.\nKeep the flag off.')"
check "a new answer returns the item to answered" "$(field "$S_MAIN" D-1 status)" "answered"
check "a free-text answer has no event note" \
  "$(sql_in "$S_MAIN" "SELECT coalesce(note, '<null>') FROM events WHERE item_id = 'D-1' ORDER BY id DESC LIMIT 1")" "<null>"
hq bash "$S_MAIN" pending-for sess-a --json
check_jq "a re-answered item is pending again" '[.[].id] | join(",")' "D-1"
EV2=$(n_events "$S_MAIN")
hq bash "$S_MAIN" ack D-1 --answer "Wait for review"
check "ack with a stale --answer exits 4" "$RC" "4"
check_contains "ack with a stale --answer says to read again" "$ERR" "changed after it was read"
check "a refused ack writes nothing" "$(n_events "$S_MAIN"),$(field "$S_MAIN" D-1 status)" "$EV2,answered"
hq "$OLD_BASH" "$S_MAIN" ack D-1 --answer "$(printf 'Ship now, then follow up.\nKeep the flag off.')"
check "ack with the current --answer exits 0" "$RC" "0"
check "ack with the current --answer acknowledges" "$(field "$S_MAIN" D-1 status)" "acknowledged"

# --- answer refusals write nothing -------------------------------------------------
D2=$(add_item "$S_MAIN" decision pr-1776 "Which store goes first?" --session sess-a --option Neon --option SQLite)
D3=$(add_item "$S_MAIN" decision pr-1776 "Anything else before merge?" --session sess-b)
EV3=$(n_events "$S_MAIN")
hq bash "$S_MAIN" answer "$D2" E
check "a letter past the last option exits 4" "$RC" "4"
check_contains "it names the options" "$ERR" "$D2 has options A-B; E is not one of them"
hq bash "$S_MAIN" answer D-999 yes
check "answer to an unknown id exits 4" "$RC" "4"
check_contains "answer names the missing id" "$ERR" "no item D-999"
hq bash "$S_MAIN" ack "$D2"
check "ack of an unanswered item exits 4" "$RC" "4"
check_contains "ack says there is no answer" "$ERR" "$D2 has no answer to acknowledge yet"
hq bash "$S_MAIN" ack D-998
check "ack of an unknown id exits 4" "$RC" "4"
check "refusals wrote nothing" "$(n_events "$S_MAIN"),$(field "$S_MAIN" "$D2" status)" "$EV3,open"
hq bash "$S_MAIN" answer "$D3" A
check "a letter on an item without options is plain text" "$(field "$S_MAIN" "$D3" answer)" "A"

# --- review, flag, comment, feedback: one event each --------------------------------
R1=$(add_item "$S_MAIN" review pr-1786 "Merged: human-queue store 2/3")
check "setup: R-1 added" "$R1" "R-1"
EV4=$(n_events "$S_MAIN")
hq "$OLD_BASH" "$S_MAIN" review r-1
check "review exits 0 and prints the id" "$RC|$OUT" "0|R-1"
check "review sets reviewed" "$(field "$S_MAIN" R-1 status)" "reviewed"
check "review wrote one reviewed event" "$(n_events "$S_MAIN")|$(events_of "$S_MAIN" R-1)" "$((EV4 + 1))|asked,reviewed"
hq bash "$S_MAIN" review R-1
check "reviewing again writes nothing" "$RC|$(n_events "$S_MAIN")" "0|$((EV4 + 1))"
hq bash "$S_MAIN" flag R-1 --note "add a test for an empty set"
check "flag exits 0" "$RC" "0"
check "flag sets flagged" "$(field "$S_MAIN" R-1 status)" "flagged"
check "flag wrote one flagged event with its note" \
  "$(sql_in "$S_MAIN" "SELECT kind || '|' || note FROM events WHERE item_id = 'R-1' ORDER BY id DESC LIMIT 1")" \
  "flagged|add a test for an empty set"
hq bash "$S_MAIN" flag R-1 --note "add a test for an empty set"
check "the same flag again writes nothing" "$RC|$(n_events "$S_MAIN")" "0|$((EV4 + 2))"
hq "$OLD_BASH" "$S_MAIN" flag R-1 --note "and document the cap"
check "a flag with a new note writes one more event" "$(n_events "$S_MAIN")" "$((EV4 + 3))"
hq bash "$S_MAIN" review R-1
check "review clears a flag" "$(field "$S_MAIN" R-1 status)|$(n_events "$S_MAIN")" "reviewed|$((EV4 + 4))"
hq bash "$S_MAIN" comment R-1 "-- read the outline first"
check "comment exits 0" "$RC|$OUT" "0|R-1"
check "comment wrote one commented event, status unchanged" \
  "$(sql_in "$S_MAIN" "SELECT e.kind || '|' || e.note || '|' || i.status FROM events e JOIN items i ON i.id = e.item_id WHERE e.item_id = 'R-1' ORDER BY e.id DESC LIMIT 1")" \
  "commented|-- read the outline first|reviewed"
hq bash "$S_MAIN" comment R-1 "-- read the outline first"
check "every comment appends" "$(n_events "$S_MAIN")" "$((EV4 + 6))"
hq "$OLD_BASH" "$S_MAIN" feedback D-1 good-interrupt
check "feedback exits 0" "$RC|$OUT" "0|D-1"
check "feedback wrote one feedback event" \
  "$(sql_in "$S_MAIN" "SELECT kind || '|' || note FROM events WHERE item_id = 'D-1' ORDER BY id DESC LIMIT 1")" \
  "feedback|good-interrupt"
hq bash "$S_MAIN" feedback D-1 good-interrupt
check "the same tag again writes nothing" "$(n_events "$S_MAIN")" "$((EV4 + 7))"
hq bash "$S_MAIN" feedback D-1 should-have-defaulted
check "a second tag writes one more event" "$(n_events "$S_MAIN")" "$((EV4 + 8))"
unknown_id() {
  hq bash "$S_MAIN" "$@"
  check "$*: an unknown id exits 4" "$RC" "4"
  check_contains "$*: names the id" "$ERR" "no item"
}
unknown_id review R-404
unknown_id flag R-404
unknown_id comment D-404 hello
unknown_id feedback D-404 not-important
check "unknown ids wrote nothing" "$(n_events "$S_MAIN")" "$((EV4 + 8))"

# --- 5.2: sets ------------------------------------------------------------------------
hq bash "$S_MAIN" set-resolve "1: A"
check "set-resolve before any set exits 4" "$RC" "4"
check_contains "set-resolve says no set is open" "$ERR" "no set has been opened"
S1=$(add_item "$S_MAIN" decision pr-sets "Set question one?" --session sess-c --option Yes --option No)
S2=$(add_item "$S_MAIN" decision pr-sets "Set question two?" --session sess-c --option Yes --option No)
S3=$(add_item "$S_MAIN" decision pr-sets "Set question three?" --session sess-c)
S4=$(add_item "$S_MAIN" decision pr-sets "Set question four?" --session sess-c --option Left --option Right)
EV5=$(n_events "$S_MAIN")
hq "$OLD_BASH" "$S_MAIN" set-open "$S1" "$S2" "$S3" "$S4"
check "5.2 set-open exits 0" "$RC" "0"
check "5.2 set-open prints the set and numbers the items 1 to 4" "$OUT" "set 1
1. $S1 **Set question one?**
2. $S2 **Set question two?**
3. $S3 **Set question three?**
4. $S4 **Set question four?**"
check "5.2 sets holds positions 1 to 4 in order" \
  "$(sql_in "$S_MAIN" "SELECT string_agg(position || '=' || item_id, ',' ORDER BY position) FROM sets WHERE set_id = 1")" \
  "1=$S1,2=$S2,3=$S3,4=$S4"
check "5.2 set-open wrote one shown event per item" \
  "$(sql_in "$S_MAIN" "SELECT string_agg(item_id || ':' || note, ',' ORDER BY id) FROM events WHERE id > (SELECT max(id) - 4 FROM events)")" \
  "$S1:set 1 #1,$S2:set 1 #2,$S3:set 1 #3,$S4:set 1 #4"
check "5.2 set-open changed no item" \
  "$(sql_in "$S_MAIN" "SELECT count(*) FROM items WHERE key = 'pr-sets' AND status <> 'open'")|$(n_events "$S_MAIN")" "0|$((EV5 + 4))"

hq bash "$S_MAIN" set-resolve "2: B"
check "5.2 set-resolve exits 0" "$RC" "0"
check "5.2 set-resolve reports the pair" "$OUT" "2. $S2 answered"
check "5.2 the second item holds option B" "$(field "$S_MAIN" "$S2" answer)" "No"
check "5.2 only the second item is answered" \
  "$(sql_in "$S_MAIN" "SELECT string_agg(id || '=' || coalesce(answer, '-'), ',' ORDER BY created_at, id) FROM items WHERE key = 'pr-sets'")" \
  "$S1=-,$S2=No,$S3=-,$S4=-"
check "5.2 one answered event, noting the set and option" \
  "$(sql_in "$S_MAIN" "SELECT item_id || '|' || note FROM events WHERE kind = 'answered' ORDER BY id DESC LIMIT 1")" \
  "$S2|set 1 #2, option B"

EV6=$(n_events "$S_MAIN")
hq "$OLD_BASH" "$S_MAIN" set-resolve "1: A, 3: after CI, not before; 4: b" --json
check "several pairs exit 0" "$RC" "0"
check_jq "several pairs report each answer" \
  '[.set_id|tostring] + [.answers[] | (.n|tostring) + "=" + .id + "=" + .answer + "=" + (.changed|tostring)] | join(",")' \
  "1,1=$S1=Yes=true,3=$S3=after CI, not before=true,4=$S4=Right=true"
check "several pairs answer each item" \
  "$(sql_in "$S_MAIN" "SELECT string_agg(coalesce(answer, '-'), '|' ORDER BY created_at, id) FROM items WHERE key = 'pr-sets'")" \
  "Yes|No|after CI, not before|Right"
check "several pairs write one event per item" "$(n_events "$S_MAIN")" "$((EV6 + 3))"

hq bash "$S_MAIN" set-resolve "2: B, 3: changed my mind"
check "a repeated pair and a new one exit 0" "$RC" "0"
check "the unchanged pair is reported as unchanged" "$OUT" "2. $S2 unchanged (it already had that answer)
3. $S3 answered"
check "only the changed pair wrote an event" "$(n_events "$S_MAIN")" "$((EV6 + 4))"

EV7=$(n_events "$S_MAIN")
SNAP=$(sql_in "$S_MAIN" "SELECT string_agg(coalesce(answer, '-'), '|' ORDER BY created_at, id) FROM items WHERE key = 'pr-sets'")
hq bash "$S_MAIN" set-resolve "1: B, 7: A"
check "a number not in the set exits 4" "$RC" "4"
check_contains "it names the number and that nothing was written" "$ERR" "set 1 has no number 7; no answer was written"
hq bash "$S_MAIN" set-resolve "1: B, 4: Z"
check "a bad letter in any pair exits 4" "$RC" "4"
check_contains "it names the item and its options" "$ERR" "$S4 has options A-B; Z is not one of them"
check "a refused set-resolve writes nothing at all" \
  "$(n_events "$S_MAIN")|$(sql_in "$S_MAIN" "SELECT string_agg(coalesce(answer, '-'), '|' ORDER BY created_at, id) FROM items WHERE key = 'pr-sets'")" \
  "$EV7|$SNAP"

hq bash "$S_MAIN" set-open "$S3" "$R1" D-404
check "set-open with an unknown id exits 4" "$RC" "4"
check_contains "set-open names the unknown id" "$ERR" "no item D-404; no set was opened"
check "a refused set-open writes nothing" \
  "$(n_events "$S_MAIN")|$(sql_in "$S_MAIN" "SELECT count(DISTINCT set_id) FROM sets")" "$EV7|1"
hq bash "$S_MAIN" set-open "$S3" "$R1" --json
check "a second set exits 0" "$RC" "0"
check_jq "a second set gets id 2 and numbers from 1 again" \
  '[.set_id|tostring] + [.items[] | (.n|tostring) + "=" + .id] | join(",")' "2,1=$S3,2=$R1"
hq bash "$S_MAIN" set-resolve "2: looks fine"
check "answering a Review through a set exits 4" "$RC" "4"
check_contains "it says Reviews are not answered" "$ERR" "$R1 is a Review"
hq "$OLD_BASH" "$S_MAIN" set-resolve "1: back to the first plan" --set 1
check "--set resolves against an older set" "$RC|$(field "$S_MAIN" "$S1" answer)" "0|back to the first plan"
hq bash "$S_MAIN" set-resolve "1: A" --set 999
check "--set with an unknown set exits 4" "$RC" "4"
check_contains "it names the set" "$ERR" "set 999 does not exist"

# --- 5.3: tick --------------------------------------------------------------------------
hq bash "$S_MAIN" tick
check "tick exits 0" "$RC" "0"
check_jq "tick reports the items written since the last tick, once each" \
  '[.[].id] | sort | join(",")' \
  "$(printf '%s\n' D-1 "$D2" "$D3" "$R1" "$S1" "$S2" "$S3" "$S4" | LC_ALL=C sort | paste -sd, -)"
hq bash "$S_MAIN" tick
check "5.3 tick right after a tick prints []" "$OUT" "[]"
NEW=$(add_item "$S_MAIN" decision pr-tick "Is this the only new item?")
hq "$OLD_BASH" "$S_MAIN" tick
check_jq "5.3 the second tick prints only the new item" '[.[].id] | join(",")' "$NEW"
hq bash "$S_MAIN" comment "$NEW" "noted"
hq bash "$S_MAIN" feedback "$NEW" good-interrupt
hq bash "$S_MAIN" set-open "$NEW"
hq bash "$S_MAIN" tick
check "comment, feedback, and shown events do not re-report an item" "$OUT" "[]"
hq bash "$S_MAIN" bump "$NEW"
hq bash "$S_MAIN" answer "$D2" a
hq bash "$S_MAIN" tick
check_jq "bump and answer re-report their items" '[.[].id] | sort | join(",")' \
  "$(printf '%s\n' "$NEW" "$D2" | LC_ALL=C sort | paste -sd, -)"

# A write in flight across a tick: its transaction starts (and stamps
# updated_at) BEFORE tick A, and commits AFTER it. Tick A cannot see it; tick B
# must report it. A watermark of "updated_at > time of tick A" would miss it.
mkfifo "$TMP/held.fifo"
(
  HQ_CONN_MARKER="$TMP/held.marker"
  hq_psql -At -f - >"$TMP/held.out" 2>"$TMP/held.err"
) <"$TMP/held.fifo" &
HELD_PID=$!
exec 3>"$TMP/held.fifo"
printf '%s\n' "SET search_path TO $S_MAIN;" "BEGIN;" \
  "INSERT INTO items (id, kind, repo, key, question) VALUES ('D-900', 'decision', 'o/r', 'inflight', 'Started before the tick, committed after it?');" \
  "INSERT INTO events (item_id, kind) VALUES ('D-900', 'asked');" \
  "UPDATE items SET question = 'Answer changed in flight?' WHERE id = '$D3';" \
  '\echo held' >&3
i=0
while [ "$i" -lt 150 ] && ! grep -q '^held$' "$TMP/held.out" 2>/dev/null; do
  sleep 0.1
  i=$((i + 1))
done
check "the in-flight transaction is open" "$(grep -c '^held$' "$TMP/held.out" 2>/dev/null)" "1"
hq bash "$S_MAIN" tick
check "tick A (during the transaction) exits 0" "$RC" "0"
check "tick A cannot see the uncommitted writes" "$OUT" "[]"
TICK_A_DONE=$(sql_in "$S_MAIN" "SELECT clock_timestamp()")
printf '%s\n' "COMMIT;" '\echo committed' >&3
exec 3>&-
wait "$HELD_PID" || true
HELD_PID=""
check "the in-flight transaction committed" "$(grep -c '^committed$' "$TMP/held.out")" "1"
check "its rows carry a time older than tick A (a time watermark would miss them)" \
  "$(sql_in "$S_MAIN" "SELECT bool_and(updated_at < '$TICK_A_DONE'::timestamptz) FROM items WHERE id IN ('D-900', '$D3')")" "t"
hq "$OLD_BASH" "$S_MAIN" tick
check_jq "tick B reports both writes that committed after tick A" '[.[].id] | sort | join(",")' \
  "$(printf '%s\n' D-900 "$D3" | LC_ALL=C sort | paste -sd, -)"
hq bash "$S_MAIN" tick
check "and the tick after that reports nothing" "$OUT" "[]"

# Two concurrent ticks: the advisory lock serializes them, so the change is
# reported by exactly one.
RACE=$(add_item "$S_MAIN" decision pr-tick "Which tick reports me?")
HUMAN_QUEUE_SCHEMA="$S_MAIN" bash "$HQ_T_CLI" tick >"$TMP/t1.out" 2>"$TMP/t1.err" </dev/null &
P1=$!
HUMAN_QUEUE_SCHEMA="$S_MAIN" "$OLD_BASH" "$HQ_T_CLI" tick >"$TMP/t2.out" 2>"$TMP/t2.err" </dev/null &
P2=$!
F=0
wait "$P1" || F=$((F + 1))
wait "$P2" || F=$((F + 1))
check "two concurrent ticks both exit 0" "$F" "0"
check "two concurrent ticks report the change exactly once" \
  "$(cat "$TMP/t1.out" "$TMP/t2.out" | grep -o "\"id\": \"$RACE\"" | grep -c .)" "1"

# --- state, register-control -------------------------------------------------------------
EV8=$(n_events "$S_MAIN")
VALUE=$(printf 'PRD first, a section at a time\n\nthen four questions  ')
hq bash "$S_MAIN" state set day_plan:2026-10-05 "$VALUE"
check "state set exits 0 and prints nothing" "$RC|$OUT" "0|"
hq "$OLD_BASH" "$S_MAIN" state get day_plan:2026-10-05
check "state get round-trips the value exactly" "$OUT" "$VALUE"
hq bash "$S_MAIN" state set day_plan:2026-10-05 "replaced"
hq bash "$S_MAIN" state get day_plan:2026-10-05
check "state set replaces" "$OUT" "replaced"
hq bash "$S_MAIN" state set empty ""
hq bash "$S_MAIN" state get empty
check "an empty value round-trips" "$RC|$OUT" "0|"
hq bash "$S_MAIN" state get never-set
check "state get of a missing key exits 4" "$RC" "4"
check_contains "it names the key" "$ERR" "no value is set for never-set"
hq bash "$S_MAIN" state get tick_watermark
check "the reserved watermark is readable" "$RC" "0"
check_contains "the watermark is a snapshot (xmin:xmax:xip)" "$OUT" ":"
hq bash "$S_MAIN" state set tick_watermark "1:1:"
check "state set refuses the watermark" "$RC" "4"

hq bash "$S_MAIN" register-control desk-1
check "register-control exits 0" "$RC" "0"
check "the first registration replaces nothing" "$OUT" "control session desk-1"
hq "$OLD_BASH" "$S_MAIN" register-control desk-2
check "a new registration names the one it replaces" "$OUT" "control session desk-2 (replaces desk-1)"
hq bash "$S_MAIN" register-control desk-2 --json
check_jq "register-control --json" '.session + "|" + (.previous // "null")' "desk-2|desk-2"
hq bash "$S_MAIN" state get control_session
check "state get control_session reads the registration" "$OUT" "desk-2"
check "state and register-control write no event (state is not an item)" "$(n_events "$S_MAIN")" "$EV8"

# --- migration 003 over a 002 store --------------------------------------------------------
mkdir -p "$TMP/only002/desk/schema"
cp -R "$HQ_T_DESK_DIR/bin" "$TMP/only002/desk/"
cp "$HQ_T_DESK_DIR/schema/001_init.sql" "$HQ_T_DESK_DIR/schema/002_item_ids.sql" "$TMP/only002/desk/schema/"
RC=0
HUMAN_QUEUE_SCHEMA="$S_OLD" bash "$TMP/only002/desk/bin/human-queue.sh" migrate >/dev/null 2>"$TMP/err" </dev/null || RC=$?
check "a schema at 002 migrates" "$RC" "0"
O1=$(add_item "$S_OLD" decision k "Asked before 003?" --session sess-o)
O2=$(add_item "$S_OLD" review k "Merged before 003")
sql_in "$S_OLD" "INSERT INTO sets (set_id, position, item_id) VALUES (41, 1, '$O1')" >/dev/null
hq bash "$S_OLD" set-open "$O1"
check "set-open on a store without 003 exits 1" "$RC" "1"
check_contains "set-open says to migrate" "$ERR" "run human-queue.sh migrate"
hq bash "$S_OLD" tick
check "tick on a store without 003 exits 1" "$RC" "1"
check_contains "tick says to migrate" "$ERR" "run human-queue.sh migrate"
hq bash "$S_OLD" answer "$O1" "works before 003 too"
check "answer works on a store without 003" "$RC" "0"
hq bash "$S_OLD" migrate
check "003 applies over existing rows" "$RC|$OUT" "0|applied 003_lifecycle.sql"
check "existing rows get a change marker" \
  "$(sql_in "$S_OLD" "SELECT count(*) FROM items WHERE change_xid IS NULL")" "0"
hq bash "$S_OLD" set-open "$O1" "$O2"
check_contains "the set sequence starts past an existing set" "$OUT" "set 42"
hq bash "$S_OLD" tick
check_jq "the first tick after 003 reports the existing items" '[.[].id] | sort | join(",")' \
  "$(printf '%s\n' "$O1" "$O2" | LC_ALL=C sort | paste -sd, -)"
hq bash "$S_OLD" get "$O1" --json
check_jq "get --json leaves change_xid out" 'has("change_xid")' "false"
hq bash "$S_OLD" list --json
check_jq "list --json leaves change_xid out" '[.[] | has("change_xid")] | any' "false"
hq bash "$S_OLD" show "$O1" --json
check_jq "show --json leaves change_xid out" '.item | has("change_xid")' "false"

# --- the live default schema was never touched ----------------------------------------------
PUBLIC_AFTER=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
check "public schema table count unchanged" "$PUBLIC_AFTER" "$PUBLIC_BEFORE"

hq_t_finish "lifecycle.test.sh"
