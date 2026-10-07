#!/usr/bin/env bash
# desk/tests/wakeups.test.sh — live tests for the desk's last part-1
# increment (issue #1781): wake-up retries, answer-parked, show, and history,
# against the database in HUMAN_QUEUE_DATABASE_URL, through the skill's own
# bash blocks where the skill has one.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. Every run creates a throwaway schema named
# hq_test_<pid>_<random>_wakeups, points the CLI at it with
# HUMAN_QUEUE_SCHEMA, and drops it on exit. The control session it registers
# exists only in that schema. No wake-up is ever sent: the asking sessions are
# ids no session has, resolved against a fixture registry
# (HUMAN_QUEUE_SESSIONS_DIR), and the failures are recorded the way the skill
# records them. The suite asserts that the number of tables in `public` is
# unchanged.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset or jq or
# python3 is missing. With the URL set, an unreachable database FAILS the
# suite.
#
# Asserts (issue #1781):
#   5.2  history after two answers today lists both, in answer order (text
#        and --json, through the skill's desk-history block); an answer at
#        23:30 America/New_York yesterday is not today's, and --date for that
#        day lists it alone
#   5.1  an invalid owning session id: the answer is stored; wake-target
#        finds no running session; the first failed wake-up writes a
#        `wake-failed` event and leaves the item `answered` with 3 retries
#        left; each of three ticks (desk-tick.sh --once) prints `retry D-n`,
#        the skill's desk-retry-due block lists it, and its failure is
#        recorded; after ticks 1 and 2 the item is still `answered`, after
#        tick 3 it is `answer-parked` with one `answer-parked` event, and
#        `parked: true` came back exactly once; a fourth tick is quiet; a
#        later failure on the parked item parks nothing again
#   4.2  wake-due --min-age skips an answer retried a moment ago; a `sent`
#        wake-up is never due; an item with no return address parks on its
#        first failure; a new answer starts the count again; re-sending the
#        answer a parked item holds changes nothing; a store without
#        migration 006 refuses to park with "run migrate", recording nothing
#   4.3  show D-<n> (the skill's desk-show block) prints the item and its
#        events in order: asked, answered, four wake-failed, answer-parked
#   and  pending-for --repo --key lists the parked answer for any thread on
#        that work (not another thread's answered one), pending-for SESSION
#        lists its own parked answer, ack accepts it, and history still lists
#        it after the ack
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

hq_t_require_db "wakeups.test.sh"
JQ=$(command -v jq 2>/dev/null || true)
if [ -z "$JQ" ]; then
  echo "SKIP: wakeups.test.sh — jq is not installed (the desk skill needs it)"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: wakeups.test.sh — python3 is not installed (the desk scripts need it)"
  exit 0
fi

HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

S="hq_test_$$_$(printf '%05d' "$RANDOM")_wakeups"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-wakeups-test.XXXXXX")
SKILL_DIR="$HQ_T_DESK_DIR/skill"
REG="$TMP/sessions"
mkdir -p "$REG"

admin_sql() { hq_psql -At -c "$1"; }
cleanup() {
  admin_sql "DROP SCHEMA IF EXISTS $S CASCADE;" >/dev/null 2>&1 \
    || echo "WARN: could not drop scratch schema $S — drop it by hand" >&2
  rm -rf "$TMP"
  hq__cleanup_tmp
}
trap cleanup EXIT

sql_in() { hq_psql -At -c "SET search_path TO $S; $1" 2>&1; }
events_of() { sql_in "SELECT string_agg(kind, ',' ORDER BY id) FROM events WHERE item_id = '$1'"; }

# hq ARGS... — the CLI in the scratch schema; sets OUT, ERR, RC.
hq() {
  RC=0
  HUMAN_QUEUE_SCHEMA="$S" bash "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# desk_once — one cycle of the desk's tick loop in the scratch schema.
desk_once() {
  RC=0
  HUMAN_QUEUE_SCHEMA="$S" bash "$HQ_BIN_DIR/desk-tick.sh" --session desk-w --generation gw --once \
    >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

jqr() { printf '%s' "$1" | "$JQ" -r "$2"; }

# The skill's blocks, run with the prelude's DESK and HQ (desk-cli.sh, which
# finds the URL in the environment) and the fixture session registry.
block() {
  local name="$2" out rc=0
  out=$(hq_t_skill_block "$SKILL_DIR/$1" "$name" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "anchor $name extracts (rc=$rc: $out)"
    return 1
  fi
  printf '%s\n' "$out" > "$TMP/block-$name.sh"
}
literal() { FROM="$2" TO="$3" perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$1"; }
# run_block FILE — sets OUT and RC.
run_block() {
  RC=0
  OUT=$(cd "$TMP" && env DESK="$HQ_T_DESK_DIR" HQ="$HQ_BIN_DIR/desk-cli.sh" HUMAN_QUEUE_SCHEMA="$S" \
    HUMAN_QUEUE_SESSIONS_DIR="$REG" bash "$1" 2>&1) || RC=$?
}

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

hq migrate
check "migrate the scratch schema" "$RC" "0"
check_contains "migrate applies 006" "$OUT" "applied 006_answer_parked.sql"
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$ERR"
  hq_t_finish "wakeups.test.sh"
  exit 1
fi
echo "scratch schema: $S"

block wakeups.md desk-retry-due
block history.md desk-show
block history.md desk-history
block decisions.md desk-wake-target
block decisions.md desk-wake-record
# The skill's record line for a failure, with --json, as the desk runs it.
grep -e '--result failed' "$TMP/block-desk-wake-record.sh" > "$TMP/record-failed.sh"
check_contains "the skill records a failed wake-up with --json" "$(cat "$TMP/record-failed.sh")" "--result failed"
check_contains "the skill's record line asks for --json" "$(cat "$TMP/record-failed.sh")" "--json"

# A fixture registry: one running session, never the ones the items name.
printf '{"pid": %s, "sessionId": "someone-else", "hostSessionId": "local_fixture", "updatedAt": 1}\n' "$$" \
  > "$REG/$$.json"

REPO=auerbachb/claude-code-config
# add VAR ARGS... — adds a Decision and stores its id in VAR.
add() {
  local var="$1"
  shift
  hq add --kind decision --repo "$REPO" "$@"
  check "add $var" "$RC" "0"
  printf -v "$var" '%s' "$OUT"
}
# shift_back ID — moves an item's events 70 seconds into the past, so the
# next retry reads them as a tick's worth older (the skill reads wake-due with
# --min-age 30).
shift_back() { sql_in "UPDATE events SET at = at - interval '70 seconds' WHERE item_id = '$1'" >/dev/null; }

hq register-control desk-w
check "register a control session in the scratch schema" "$RC:$OUT" "0:control session desk-w"
desk_once
check "the first tick on an empty store is quiet" "$RC:$OUT:$ERR" "0::"

# --- 5.2: history after two answers today --------------------------------------
add H1 --key issue-1801 --session sess-h1 --question "Use the staging bucket?" --option "Yes" --option "No"
add H2 --key issue-1802 --session sess-h2 --question "What should the changelog call the desk?"
hq answer "$H1" A
check "5.2 answer H1" "$RC" "0"
hq answer "$H2" "The human queue's desk"
check "5.2 answer H2" "$RC" "0"
hq history --json
check "5.2 history --json exits 0" "$RC" "0"
check "5.2 history lists both of today's answers, in answer order" "$(jqr "$OUT" '[.[].id] | join(" ")')" "$H1 $H2"
check "5.2 history --json carries each answer" "$(jqr "$OUT" '[.[].answer] | join("|")')" "Yes|The human queue's desk"
check "5.2 history --json carries answered_at" "$(jqr "$OUT" '[.[] | has("answered_at")] | all')" "true"
run_block "$TMP/block-desk-history.sh"
check_contains "5.2 the desk-history block reports exit 0" "$OUT" "exit=0"
check_contains "5.2 the text lists H1 with its time in ET" "$OUT" "$H1 · answered "
check_contains "5.2 the text lists H1's question" "$OUT" "**Use the staging bucket?**"
check_contains "5.2 the text lists H2's answer" "$OUT" "Answer: The human queue's desk"
check_contains "5.2 the time is America/New_York" "$OUT" " ET · answered · $REPO · issue-1801"
check_absent "5.2 history prints no state line" "$OUT" "Desk live"

# An answer at 23:30 New York time yesterday: today in UTC for part of the
# day, never today in New York.
add H3 --key issue-1803 --session sess-h3 --question "Keep the old endpoint?" --option "Keep" --option "Drop"
hq answer "$H3" B
YESTERDAY=$(sql_in "SELECT ((statement_timestamp() AT TIME ZONE 'America/New_York')::date - 1)::text")
sql_in "UPDATE events SET at = ('$YESTERDAY 23:30'::timestamp AT TIME ZONE 'America/New_York') WHERE item_id = '$H3' AND kind = 'answered'" >/dev/null
hq history --json
check "5.2 yesterday's 23:30 ET answer is not today's" "$(jqr "$OUT" '[.[].id] | join(" ")')" "$H1 $H2"
hq history --date "$YESTERDAY" --json
check "5.2 history --date yesterday lists it alone" "$(jqr "$OUT" '[.[].id] | join(" ")')" "$H3"
hq history --date 1999-01-01
check "5.2 a day with no answers prints nothing" "$RC:$OUT" "0:"
hq history --date 2026-02-30
check "5.2 an impossible date: exit 4 before connecting" "$RC" "4"

# --- 5.1: an invalid owning session id ------------------------------------------
DEAD=no-such-session-1781
add D --key issue-1781 --session "$DEAD" --question "Ship the retries before the history view?" \
  --option "Ship now" --option "Wait"
hq answer "$D" A --json
check "5.1 the answer is stored (changed)" "$(jqr "$OUT" '.changed')" "true"
check "5.1 the answer names the asking session" "$(jqr "$OUT" '.session')" "$DEAD"
hq get "$D" --json
check "5.1 the stored answer" "$(jqr "$OUT" '.answer'):$(jqr "$OUT" '.status')" "Ship now:answered"

# The first wake-up, as decisions.md makes it right after the answer.
literal "$TMP/block-desk-wake-target.sh" "<session>" "$DEAD" > "$TMP/target.sh"
run_block "$TMP/target.sh"
check "5.1 wake-target: no running session (exit 3)" "$RC" "3"
check_contains "5.1 wake-target says so" "$OUT" "no running session"

PARKED_TRUE=0
# record ID — the skill's failed-wake record for ID; sets OUT (the JSON).
record() {
  literal "$TMP/record-failed.sh" "D-43" "$1" > "$TMP/record.sh"
  run_block "$TMP/record.sh"
  if [ "$RC" -eq 0 ] && [ "$(jqr "$OUT" '.parked')" = "true" ]; then
    PARKED_TRUE=$((PARKED_TRUE + 1))
  fi
}
record "$D"
check "5.1 the first failed wake-up is recorded" "$RC" "0"
check "5.1 after the first failure: 1 failure, 3 retries left, answered, not parked" \
  "$(jqr "$OUT" '"\(.failures) \(.retries_left) \(.status) \(.parked)"')" "1 3 answered false"
check "5.1 a wake-failed event is written" "$(events_of "$D")" "asked,answered,wake-failed"
check "5.1 its note is the reason" \
  "$(sql_in "SELECT note FROM events WHERE item_id = '$D' AND kind = 'wake-failed'")" "no running session"

hq wake-due --json --min-age 30
check "4.2 wake-due --min-age 30 skips an answer retried a moment ago" "$OUT" "[]"
hq wake-due --json
check "4.2 wake-due without --min-age lists it" "$(jqr "$OUT" '[.[] | "\(.id)|\(.session)|\(.retry)"] | join(",")')" "$D|$DEAD|1"
hq wake-due
check "4.2 wake-due's text line" "$OUT" "$D · retry 1 of 3 · session $DEAD"
shift_back "$D"

for T in 1 2 3; do
  desk_once
  check "5.1 tick $T prints the retry" "$RC:$OUT" "0:desk-tick gw retry $D"
  run_block "$TMP/block-desk-retry-due.sh"
  check_contains "5.1 tick $T: the skill's desk-retry-due block reports exit 0" "$OUT" "exit=0"
  DUE=$(printf '%s\n' "$OUT" | sed -n 1p)
  check "5.1 tick $T: the block lists it with its session and retry number" \
    "$(jqr "$DUE" '[.[] | "\(.id)|\(.session)|\(.retry)"] | join(",")')" "$D|$DEAD|$T"
  run_block "$TMP/target.sh"
  check "5.1 tick $T: still no running session" "$RC" "3"
  record "$D"
  check "5.1 tick $T: the failure is recorded" "$RC" "0"
  case "$T" in
    1|2)
      check "5.1 after tick $T: still answered" \
        "$(jqr "$OUT" '"\(.failures) \(.retries_left) \(.status) \(.parked)"')" "$((T + 1)) $((3 - T)) answered false"
      ;;
    3)
      check "5.1 after tick 3: answer-parked" \
        "$(jqr "$OUT" '"\(.failures) \(.retries_left) \(.status) \(.parked)"')" "4 0 answer-parked true"
      ;;
  esac
  shift_back "$D"
done
hq get "$D" --json
check "5.1 the item reaches answer-parked after three ticks" "$(jqr "$OUT" '.status')" "answer-parked"
check "5.1 the answer is still stored" "$(jqr "$OUT" '.answer')" "Ship now"
check "5.1 the events: the first attempt, three retries, then parked" "$(events_of "$D")" \
  "asked,answered,wake-failed,wake-failed,wake-failed,wake-failed,answer-parked"
check "5.1 the answer-parked event's note" \
  "$(sql_in "SELECT note FROM events WHERE item_id = '$D' AND kind = 'answer-parked'")" "4 wake-ups failed"
check "5.1 parked: true came back exactly once (shown once)" "$PARKED_TRUE" "1"
desk_once
check "5.1 a fourth tick is quiet: no retry left" "$RC:$OUT:$ERR" "0::"
hq wake-due --json
check "5.1 wake-due no longer lists it" "$OUT" "[]"

# --- 4.3: show D-<n> -----------------------------------------------------------------
literal "$TMP/block-desk-show.sh" "D-43" "$D" > "$TMP/show.sh"
run_block "$TMP/show.sh"
check_contains "4.3 the desk-show block reports exit 0" "$OUT" "exit=0"
check "4.3 show's first line is the item's header, parked" "$(printf '%s\n' "$OUT" | sed -n 1p)" \
  "$D · decision · answer-parked · $REPO · issue-1781"
check_contains "4.3 show prints the answer" "$OUT" "Answer: Ship now"
check_contains "4.3 show prints the events" "$OUT" "Events:"
check "4.3 show lists the events in order" \
  "$(printf '%s\n' "$OUT" | sed -n 's/^- [0-9-]* [0-9:]* UTC  \([a-z-]*\).*/\1/p' | tr '\n' ',')" \
  "asked,answered,wake-failed,wake-failed,wake-failed,wake-failed,answer-parked,"
check_contains "4.3 show carries the notes" "$OUT" "wake-failed — no running session"
check_contains "4.3 show carries the parked note" "$OUT" "answer-parked — 4 wake-ups failed"
check_absent "4.3 show prints no state line" "$OUT" "Desk live"
literal "$TMP/block-desk-show.sh" "D-43" "D-99999" > "$TMP/show-gone.sh"
run_block "$TMP/show-gone.sh"
check_contains "4.3 show of an unknown id: exit=4" "$OUT" "exit=4"
check_contains "4.3 show of an unknown id: names it" "$OUT" "no item D-99999"

# A late failure on a parked item is recorded, and parks nothing again.
record "$D"
check "4.2 a failure after parking: recorded, nothing parked again" \
  "$(jqr "$OUT" '"\(.status) \(.parked) \(.retries_left)"')" "answer-parked false 0"
check "4.2 still exactly one answer-parked event" \
  "$(sql_in "SELECT count(*) FROM events WHERE item_id = '$D' AND kind = 'answer-parked'")" "1"
check "4.2 still shown once" "$PARKED_TRUE" "1"

# Re-sending the answer a parked item holds changes nothing.
hq answer "$D" A --json
check "4.2 the same answer to a parked item: unchanged" "$(jqr "$OUT" '.changed')" "false"
hq get "$D" --json
check "4.2 the parked item stays parked" "$(jqr "$OUT" '.status')" "answer-parked"

# --- the next thread on that work --------------------------------------------------
add D2 --key issue-1781 --session sess-alive --question "Rename the retry flag?" --option "Yes" --option "No"
hq answer "$D2" B
hq wake "$D2" --result sent --note "SendMessage to local_alive: delivered" --json
check "4.2 a sent wake-up: nothing due, nothing parked" \
  "$(jqr "$OUT" '"\(.result) \(.failures) \(.retries_left) \(.status) \(.parked)"')" "sent 0 0 answered false"
hq wake-due --json
check "4.2 a woken answer is never due" "$OUT" "[]"
hq pending-for --repo "$REPO" --key issue-1781 --json
check "pending-for --repo --key: the parked answer, not another thread's" \
  "$(jqr "$OUT" '[.[] | "\(.id)=\(.answer)"] | join(",")')" "$D=Ship now"
hq pending-for --repo "$REPO" --key issue-1781
check_contains "pending-for --repo --key prints the item as get does" "$OUT" "**Ship the retries before the history view?**"
hq pending-for "$DEAD" --json
check "pending-for SESSION lists its own parked answer" "$(jqr "$OUT" '[.[].id] | join(",")')" "$D"
hq pending-for sess-alive --repo "$REPO" --key issue-1781 --json
check "pending-for SESSION --repo --key merges both lists" "$(jqr "$OUT" '[.[].id] | join(",")')" "$D,$D2"
hq pending-for --repo "$REPO" --key issue-9999 --json
check "pending-for --repo --key on other work: none" "$OUT" "[]"
hq ack "$D" --answer "Ship now"
check "ack accepts a parked answer" "$RC:$OUT" "0:$D"
hq get "$D" --json
check "the parked answer is acknowledged" "$(jqr "$OUT" '.status')" "acknowledged"
check "one acknowledged event" "$(sql_in "SELECT count(*) FROM events WHERE item_id = '$D' AND kind = 'acknowledged'")" "1"
hq pending-for --repo "$REPO" --key issue-1781 --json
check "after the ack the parked answer no longer waits" "$OUT" "[]"
hq history --json
check "history still lists the acknowledged item" \
  "$(jqr "$OUT" "[.[] | select(.id == \"$D\") | .status] | join(\",\")")" "acknowledged"

# --- 4.2: no return address -----------------------------------------------------------
add D3 --key issue-1781 --question "Which name for the store?"
hq answer "$D3" "human-queue"
hq wake "$D3" --result failed --note "no return address" --json
check "4.2 no return address: parked on the first failure" \
  "$(jqr "$OUT" '"\(.failures) \(.retries_left) \(.status) \(.parked)"')" "1 0 answer-parked true"
check "4.2 its answer-parked note" \
  "$(sql_in "SELECT note FROM events WHERE item_id = '$D3' AND kind = 'answer-parked'")" "no return address"
hq pending-for --repo "$REPO" --key issue-1781 --json
check "4.2 the next thread on that work finds it" "$(jqr "$OUT" '[.[].id] | join(",")')" "$D3"

# --- 4.2: a new answer starts the count again -------------------------------------------
add D4 --key issue-1804 --session dead-two --question "Batch size for the sync?" --option "50" --option "100"
hq answer "$D4" A
hq wake "$D4" --result failed --note "no running session"
hq wake "$D4" --result failed --note "no running session"
hq wake-due --json
check "4.2 two failures: retry 2 due" "$(jqr "$OUT" "[.[] | select(.id == \"$D4\") | .retry] | join(\",\")")" "2"
hq answer "$D4" B --json
check "4.2 a new answer is a change" "$(jqr "$OUT" '.changed')" "true"
hq wake-due --json
check "4.2 a new answer leaves nothing due until its own wake-up" \
  "$(jqr "$OUT" "[.[] | select(.id == \"$D4\")] | length")" "0"
hq wake "$D4" --result failed --note "no running session" --json
check "4.2 the new answer's first failure counts from one" \
  "$(jqr "$OUT" '"\(.failures) \(.retries_left) \(.status)"')" "1 3 answered"

# --- 4.2: a store without migration 006 ------------------------------------------------
add D5 --key issue-1805 --question "Parks at once?"
hq answer "$D5" "yes"
OLD=$(sql_in "ALTER TABLE items DROP CONSTRAINT items_status_check; ALTER TABLE items ADD CONSTRAINT items_status_check CHECK (status IN ('open', 'answered', 'acknowledged', 'reviewed', 'flagged', 'closed')) NOT VALID;")
check "setup: the store's statuses are 005's again (no error)" "$OLD" ""
EV0=$(events_of "$D5")
hq wake "$D5" --result failed --note "no return address"
check "4.2 parking before migration 006: exit 1" "$RC" "1"
check_contains "4.2 parking before migration 006: names migrate" "$ERR" "run human-queue.sh migrate"
check "4.2 parking before migration 006: nothing recorded" "$(events_of "$D5")" "$EV0"

PUBLIC_AFTER=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
check "the public schema is untouched" "$PUBLIC_AFTER" "$PUBLIC_BEFORE"

hq_t_finish "wakeups.test.sh"
