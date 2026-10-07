#!/usr/bin/env bash
# desk/tests/desk.test.sh — live tests for the /desk control loop (issue
# #1779), against the database in HUMAN_QUEUE_DATABASE_URL.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. Every run creates a throwaway schema named
# hq_test_<pid>_<random>_desk, points the CLI at it with HUMAN_QUEUE_SCHEMA,
# and drops it on exit. Registering a control session in the default schema
# would turn the capture hook on for every session on the machine; here it
# only ever happens in the throwaway schema. The suite asserts that the
# number of tables in `public` is unchanged.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset. With the
# URL set, an unreachable database FAILS the suite.
#
# Asserts (issue #1779):
#   5.1  two worker sessions post Decisions; the desk's tick reports both;
#        one set numbers them 1 and 2; the reply "1: A, 2: C" writes two
#        answers (by option text) in one transaction and returns each asking
#        session; two wake-ups are recorded as events (one woken, one
#        wake-failed); each worker's pending-for returns its own answer
#   4.2  register-control + desk-tick.sh --once make the desk live
#        (control-status: this session, a fresh tick); a second desk
#        registering makes the first loop print `replaced`; `tick --session`
#        as the replaced desk reads nothing, moves no watermark, and stamps
#        no tick_at, so the new desk's tick still reports what came in
#   4.3  replies by id (`D-<n>: B`) resolve through set-resolve; an id not in
#        the set, or one item by number and by id, writes nothing
#   4.4  wake records woken / wake-failed with its note, changes no item
#        (tick does not report it again), refuses an unanswered Decision and
#        an unknown id, and names `migrate` on a store without 005
#   and  desk-cli.sh reaches the store with the URL from the environment;
#        after the answers, desk-tick.sh prints nothing (answered items are
#        not new open Decisions)
# On macOS a share of the calls run under /bin/bash 3.2.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

hq_t_require_db "desk.test.sh"

HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

S="hq_test_$$_$(printf '%05d' "$RANDOM")_desk"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-desk-test.XXXXXX")

admin_sql() { hq_psql -At -c "$1"; }
cleanup() {
  admin_sql "DROP SCHEMA IF EXISTS $S CASCADE;" >/dev/null 2>&1 \
    || echo "WARN: could not drop scratch schema $S — drop it by hand" >&2
  rm -rf "$TMP"
  hq__cleanup_tmp
}
trap cleanup EXIT

sql_in() { hq_psql -At -c "SET search_path TO $S; $1" 2>&1; }

OLD_BASH=bash
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  OLD_BASH=/bin/bash
fi
JQ=""
if command -v jq >/dev/null 2>&1; then JQ=$(command -v jq); fi

# hq SHELL ARGS... — the CLI in the scratch schema; sets OUT, ERR, RC.
hq() {
  local sh="$1"
  shift
  RC=0
  HUMAN_QUEUE_SCHEMA="$S" "$sh" "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# desk ARGS... — desk-tick.sh in the scratch schema (through desk-cli.sh).
desk() {
  RC=0
  HUMAN_QUEUE_SCHEMA="$S" bash "$HQ_BIN_DIR/desk-tick.sh" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

check_jq() {
  if [ -z "$JQ" ]; then
    printf 'skip — %s (jq not installed)\n' "$1"
    return 0
  fi
  check "$1" "$(printf '%s' "$OUT" | "$JQ" -r "$2")" "$3"
}

events_of() { sql_in "SELECT string_agg(kind || coalesce(':' || note, ''), ',' ORDER BY id) FROM events WHERE item_id = '$1'"; }

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

hq bash migrate
check "migrate the scratch schema" "$RC" "0"
check_contains "migrate applies 005" "$OUT" "applied 005_wake_events.sql"
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$ERR"
  hq_t_finish "desk.test.sh"
  exit 1
fi
echo "scratch schema: $S (old shell: $OLD_BASH)"

REPO=auerbachb/claude-code-config
# add_decision KEY SESSION QUESTION OPTIONS... — prints the new id.
add_decision() {
  local key="$1" session="$2" q="$3" o
  shift 3
  local -a args=(add --kind decision --repo "$REPO" --key "$key" --question "$q" --session "$session")
  for o in "$@"; do args[${#args[@]}]=--option; args[${#args[@]}]="$o"; done
  args[${#args[@]}]=--default
  args[${#args[@]}]="$1"
  HUMAN_QUEUE_SCHEMA="$S" bash "$HQ_T_CLI" "${args[@]}" </dev/null
}

# --- 4.2: the desk registers and ticks ------------------------------------
hq bash register-control desk-1
check "register-control desk-1" "$RC:$OUT" "0:control session desk-1"
desk --session desk-1 --generation g1 --once
check "the first desk tick on an empty store prints nothing" "$RC:$OUT:$ERR" "0::"
hq bash control-status --json
check_jq "control-status: the desk is registered" '.session' "desk-1"
check_jq "control-status: the tick is fresh" '.tick_age_seconds <= 5' "true"

# --- 5.1: two worker sessions post Decisions --------------------------------
D1=$(add_decision issue-901 worker-a "Ship the migration before the CLI?" "Ship now" "Wait for review")
D2=$(add_decision issue-902 worker-b "Which region for the replica?" "us-east-1" "eu-west-1" "ap-south-1")
check "5.1 setup: two Decisions" "$D1 $D2" "D-1 D-2"
R1=$(HUMAN_QUEUE_SCHEMA="$S" bash "$HQ_T_CLI" add --kind review --repo "$REPO" --key pr-903 --question "Review PR 903?" </dev/null)
check "5.1 setup: one Review" "$R1" "R-1"

desk --session desk-1 --generation g1 --once
check "5.1 the desk tick reports both open Decisions, not the Review" "$RC:$OUT" "0:desk-tick g1 new D-1 D-2"

hq "$OLD_BASH" set-open D-1 D-2 --json
check "5.1 set-open exits 0" "$RC" "0"
check_jq "5.1 one set numbers them 1 and 2" '[.items[] | "\(.n)=\(.id)"] | join(",")' "1=D-1,2=D-2"
SET1=$(printf '%s' "$OUT" | sed -n 's/.*"set_id": *\([0-9]*\).*/\1/p')
check "5.1 shown events" "$(events_of D-1)|$(events_of D-2)" "asked,shown:set $SET1 #1|asked,shown:set $SET1 #2"

hq "$OLD_BASH" set-resolve "1: A, 2: C" --set "$SET1" --json
check "5.1 set-resolve exits 0" "$RC" "0"
check_jq "5.1 two answers, by option text, with each asking session" \
  '[.answers[] | "\(.n)|\(.id)|\(.answer)|\(.changed)|\(.session)"] | join(",")' \
  "1|D-1|Ship now|true|worker-a,2|D-2|ap-south-1|true|worker-b"

# The desk's wake-ups: worker-a's session is running (woken), worker-b's is not.
hq bash wake D-1 --result sent --note "SendMessage to local_aaaa: delivered"
check "5.1 wake D-1 sent: exit 0, prints the id" "$RC:$OUT:$ERR" "0:D-1:"
hq "$OLD_BASH" wake d-2 --result failed --note "no running session"
check "5.1 wake D-2 failed: exit 0" "$RC:$OUT" "0:D-2"
check "5.1 D-1's events" "$(events_of D-1)" \
  "asked,shown:set $SET1 #1,answered:set $SET1 #1, option A,woken:SendMessage to local_aaaa: delivered"
check "5.1 D-2's events" "$(events_of D-2)" \
  "asked,shown:set $SET1 #2,answered:set $SET1 #2, option C,wake-failed:no running session"

hq bash pending-for worker-a --json
check_jq "5.1 worker-a reads its own answer" '[.[] | "\(.id)=\(.answer)"] | join(",")' "D-1=Ship now"
hq bash pending-for worker-b --json
check_jq "5.1 worker-b reads its own answer" '[.[] | "\(.id)=\(.answer)"] | join(",")' "D-2=ap-south-1"

# Answered items are changes, but not new open Decisions: the loop is quiet.
desk --session desk-1 --generation g1 --once
check "after the answers the desk tick prints nothing" "$RC:$OUT:$ERR" "0::"
# A wake event changes no item, so tick does not report it again.
hq bash wake D-1 --result failed --note "second attempt"
hq bash tick
check "a wake event does not re-report its item" "$OUT" "[]"
check "every wake attempt is its own event" \
  "$(sql_in "SELECT count(*) FROM events WHERE item_id = 'D-1' AND kind IN ('woken', 'wake-failed')")" "2"

# --- 4.4: wake refusals -----------------------------------------------------
D3=$(add_decision issue-904 worker-a "Rename the flag?" "Yes" "No")
EV0=$(sql_in "SELECT count(*) FROM events")
hq bash wake "$D3" --result sent
check "wake on an unanswered Decision: exit 4" "$RC" "4"
check_contains "wake on an unanswered Decision: says why" "$ERR" "has no answer yet"
hq bash wake D-999 --result sent
check "wake on an unknown id: exit 4" "$RC" "4"
check_contains "wake on an unknown id: names it" "$ERR" "no item D-999"
check "the refusals wrote nothing" "$(sql_in "SELECT count(*) FROM events")" "$EV0"

# --- 4.3: replies by id ------------------------------------------------------
D4=$(add_decision issue-905 worker-b "Keep the old endpoint?" "Keep" "Drop")
hq bash set-open "$D3" "$D4" --json
SET2=$(printf '%s' "$OUT" | sed -n 's/.*"set_id": *\([0-9]*\).*/\1/p')
EV0=$(sql_in "SELECT count(*) FROM events")
hq bash set-resolve "D-1: A" --set "$SET2"
check "an id not in the set: exit 4" "$RC" "4"
check_contains "an id not in the set: names it" "$ERR" "D-1 is not in set $SET2"
hq bash set-resolve "1: A, $D3: B" --set "$SET2"
check "one item by number and by id: exit 4" "$RC" "4"
check_contains "one item by number and by id: says so" "$ERR" "($D3) is answered twice"
check "the refused replies wrote nothing" "$(sql_in "SELECT count(*) FROM events")" "$EV0"
hq "$OLD_BASH" set-resolve "d-$((${D4#D-})): B, 1: free text, with a comma" --set "$SET2" --json
check "a reply by id and by number: exit 0" "$RC" "0"
check_jq "the id resolves to its number in the set" \
  '[.answers[] | "\(.n)|\(.id)|\(.answer)"] | join(",")' "2|$D4|Drop,1|$D3|free text, with a comma"

# --- 4.2: a second desk replaces the first ----------------------------------
hq bash register-control desk-2
check "a second desk registers" "$OUT" "control session desk-2 (replaces desk-1)"
# The replaced desk's tick, as if its control-status had run just before the
# registration: refused inside the tick's transaction, nothing consumed.
D5=$(add_decision issue-906 worker-a "Cut the release today?" "Now" "Monday")
WM0=$(sql_in "SELECT value FROM state WHERE key = 'tick_watermark'")
hq bash tick --session desk-1
check "tick --session as the replaced desk: exit 4" "$RC" "4"
check_contains "tick --session as the replaced desk: says why" "$ERR" "not the registered control session"
check "tick --session as the replaced desk: prints nothing" "$OUT" ""
check "tick --session as the replaced desk: the watermark is unmoved" \
  "$(sql_in "SELECT value FROM state WHERE key = 'tick_watermark'")" "$WM0"
check "tick --session as the replaced desk: no tick_at stamped" \
  "$(sql_in "SELECT count(*) FROM state WHERE key = 'tick_at'")" "0"
hq bash tick --session
check "tick --session with no value: exit 4" "$RC" "4"
hq "$OLD_BASH" tick --session desk-2
check "tick --session as the control session: exit 0" "$RC" "0"
check_jq "the new desk's tick reports what the refused tick left" "[.[].id] | any(. == \"$D5\")" "true"
desk --session desk-1 --generation g1 --once
check "the first desk's loop sees it was replaced" "$RC:$OUT" "0:desk-tick g1 replaced"

# --- desk-cli.sh against the real store ---------------------------------------
RC=0
OUT=$(HUMAN_QUEUE_SCHEMA="$S" bash "$HQ_BIN_DIR/desk-cli.sh" control-status --json 2>&1 </dev/null) || RC=$?
check "desk-cli.sh reaches the store" "$RC" "0"
check_contains "desk-cli.sh prints the CLI's output" "$OUT" '"session": "desk-2"'

# --- 4.4: a store without migration 005 ---------------------------------------
# 004's kinds back, NOT VALID so the wake events already written stay.
OLD_KINDS=$(sql_in "ALTER TABLE events DROP CONSTRAINT events_kind_check; ALTER TABLE events ADD CONSTRAINT events_kind_check CHECK (kind IN ('asked', 'bumped', 'shown', 'answered', 'acknowledged', 'reviewed', 'flagged', 'feedback', 'commented')) NOT VALID;")
check "setup: the store's event kinds are 004's again (no error)" "$OLD_KINDS" ""
check_absent "setup: woken is no longer an event kind" \
  "$(sql_in "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'events_kind_check' AND conrelid = 'events'::regclass")" "woken"
hq bash wake D-1 --result sent
check "wake before migration 005: exit 1" "$RC" "1"
check_contains "wake before migration 005: names migrate" "$ERR" "run human-queue.sh migrate"

check "the public schema is untouched" \
  "$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")" "$PUBLIC_BEFORE"

hq_t_finish "desk.test.sh"
