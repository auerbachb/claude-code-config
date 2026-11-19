#!/usr/bin/env bash
# desk/tests/stoppage.test.sh — live tests for the stoppage log (issue #2292),
# against the database in HUMAN_QUEUE_DATABASE_URL.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. Every run creates a throwaway schema named
# hq_test_<pid>_<random>_stoppage, points the CLI at it with
# HUMAN_QUEUE_SCHEMA, and drops it on exit; the number of tables in `public` is
# asserted unchanged. The keep directory is a temp directory too.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset. With the
# URL set, an unreachable database FAILS the suite.
#
# Asserts:
#   - migration 018 applies and creates the table with its checks (a cause off
#     the list, an evidence line over 200 characters, a half-closed entry)
#   - record stores one row; the same thread and time stores nothing new and
#     answers with the first row's id
#   - resume adds the idle time to the thread's open entries only, once
#   - correct saves a correction beside the original cause (by id and by
#     thread's latest); an unknown id is exit 4 with nothing changed
#   - why reads the latest entry, with the correction; JSON shape
#   - list groups a date range by cause (a correction counts instead), totals
#     idle time, reports open entries, and leaves out entries outside it
#   - an operation kept while the database was unreachable is stored by the
#     next call, in order (record, then resume), and the keep directory empties
#   - the stored row holds no more than the contract fields
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

hq_t_require_db "stoppage.test.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: stoppage.test.sh — jq is not installed"
  exit 0
fi

HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

S="hq_test_$$_$(printf '%05d' "$RANDOM")_stoppage"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-stoppage-test.XXXXXX")
KEEP="$TMP/keep"

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
  HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_STOPPAGE_DIR="$KEEP" bash "$HQ_T_CLI" "$@" \
    >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

hq migrate
check "migrate the scratch schema" "$RC" "0"
check_contains "migrate applies 018" "$OUT" "applied 018_stoppages.sql"
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$ERR"
  hq_t_finish "stoppage.test.sh"
  exit 1
fi

# ---- table checks -----------------------------------------------------------
INS="INSERT INTO stoppages (dedupe_key, stopped_at, thread, repo, cause, evidence, source) VALUES"
KEY32="0123456789abcdef0123456789abcdef"
check_contains "a cause off the list is refused" \
  "$(sql_in "$INS ('$KEY32', now(), 't', 'a/b', 'bored', 'e', 'hook')")" "violates check constraint"
check_contains "an evidence line over 200 characters is refused" \
  "$(sql_in "$INS ('$KEY32', now(), 't', 'a/b', 'crash', repeat('x', 201), 'hook')")" "violates check constraint"
check_contains "an idle time without a resume time is refused" \
  "$(sql_in "$INS ('$KEY32', now(), 't', 'a/b', 'crash', 'e', 'hook'); UPDATE stoppages SET idle_seconds = 5;")" "violates check constraint"
check "no row from the refused inserts" "$(sql_in "SELECT count(*) FROM stoppages")" "0"

# ---- record / dedupe --------------------------------------------------------
hq stoppage record --thread s1 --repo acme/widgets --ref issue#5 --cause waiting_on_review \
  --evidence "ci pending" --at 2026-11-10T10:00:00Z
check "record: exit 0" "$RC" "0"
check_contains "record: stored" "$OUT" "stored "
ID1=${OUT#stored }
hq stoppage record --thread s1 --repo acme/widgets --ref issue#5 --cause crash \
  --evidence "again" --at 2026-11-10T10:00:00Z
check "record again: the same entry's id" "$OUT" "stored $ID1"
check "record again: one row" "$(sql_in "SELECT count(*) FROM stoppages WHERE thread = 's1'")" "1"
check "record again: the first cause stands" "$(sql_in "SELECT cause FROM stoppages WHERE thread = 's1'")" "waiting_on_review"
hq stoppage record --thread s2 --repo acme/widgets --cause out_of_work --evidence "queue empty" \
  --at 2026-11-11T10:00:00Z --json
check "record --json: stored" "$(printf '%s' "$OUT" | jq -r .stored)" "true"
hq stoppage record --thread s3 --at 2026-11-12T10:00:00Z --cause nonsense --evidence "x"
check "a bad cause is stored as unknown" "$(sql_in "SELECT cause FROM stoppages WHERE thread = 's3'")" "unknown"
hq stoppage record --thread s4 --repo acme/widgets --cause crash --evidence "found dead" \
  --source go-on --at 2026-10-01T10:00:00Z
check "an entry outside the range is stored" "$RC" "0"

# ---- resume -----------------------------------------------------------------
hq stoppage resume --thread s1 --at 2026-11-10T11:10:00Z
check "resume: closes one entry" "$OUT" "closed 1"
check "resume: idle seconds" "$(sql_in "SELECT idle_seconds FROM stoppages WHERE thread = 's1'")" "4200"
hq stoppage resume --thread s1 --at 2026-11-10T12:00:00Z
check "resume again: closes nothing" "$OUT" "closed 0"
check "resume again: idle seconds unchanged" "$(sql_in "SELECT idle_seconds FROM stoppages WHERE thread = 's1'")" "4200"
hq stoppage resume --thread s2 --at 2026-11-11T09:00:00Z
check "resume before the stop closes nothing" "$OUT" "closed 0"
hq stoppage resume --thread s2 --at 2026-11-11T14:00:00Z
check "resume: a later time closes it" "$(sql_in "SELECT idle_seconds FROM stoppages WHERE thread = 's2'")" "14400"
hq stoppage resume --thread s4 --at 2026-10-01T10:30:00Z

# ---- correct / why ----------------------------------------------------------
hq stoppage why --thread s1
check "why: exit 0" "$RC" "0"
check_contains "why: names the cause and evidence" "$OUT" "waiting_on_review"
check_contains "why: idle" "$OUT" "idle 1h 10m"
hq stoppage correct "$ID1" --cause waiting_on_operator --note "I had not answered"
check "correct by id" "$OUT" "corrected $ID1"
check "correct: the original cause is kept" "$(sql_in "SELECT cause FROM stoppages WHERE id = $ID1")" "waiting_on_review"
check "correct: the correction is saved" "$(sql_in "SELECT corrected_cause || ' / ' || correction_note FROM stoppages WHERE id = $ID1")" \
  "waiting_on_operator / I had not answered"
hq stoppage why --thread s1
check_contains "why: shows the correction" "$OUT" "waiting_on_operator (corrected from waiting_on_review)"
check_contains "why: shows the note" "$OUT" "operator note: I had not answered"
hq stoppage why --thread s1 --json
check "why --json: keys" "$(printf '%s' "$OUT" | jq -c 'keys')" \
  '["cause","corrected_cause","correction_note","evidence","id","idle_seconds","ref","repo","source","stopped_at","thread"]'
hq stoppage why --thread nobody
check "why: no entry" "$RC:$OUT" "0:no stoppage entry for this thread"
hq stoppage correct --thread s3 --cause crash
check "correct by thread's latest" "$RC" "0"
hq stoppage correct 999999 --cause crash
check "correct: an unknown id is exit 4" "$RC" "4"
check_contains "correct: says so" "$ERR" "no entry to correct"

# ---- list -------------------------------------------------------------------
hq stoppage list --from 2026-11-09 --to 2026-11-13 --json
check "list: total in range" "$(printf '%s' "$OUT" | jq -r .total)" "3"
check "list: open entries" "$(printf '%s' "$OUT" | jq -r .open)" "1"
check "list: idle total" "$(printf '%s' "$OUT" | jq -r .idle_seconds)" "18600"
check "list: grouped by cause, corrections counted" \
  "$(printf '%s' "$OUT" | jq -c '[.causes[] | [.cause, .count, .idle_seconds]]')" \
  '[["out_of_work",1,14400],["waiting_on_operator",1,4200],["crash",1,0]]'
hq stoppage list --from 2026-11-09 --to 2026-11-13
check_contains "list: text heading" "$OUT" "2026-11-09 to 2026-11-13 · 3 stoppages · 5h 10m idle · 1 still stopped, not totalled"
hq stoppage list --from 2026-10-01 --to 2026-10-01 --json
check "list: another range" "$(printf '%s' "$OUT" | jq -r .total)" "1"
hq stoppage list --from 2025-01-01 --to 2025-01-02 --json
check "list: an empty range" "$(printf '%s' "$OUT" | jq -r '.total, (.causes | length)' | tr '\n' ' ')" "0 0 "

# ---- the stored row ---------------------------------------------------------
check "the table holds only the contract fields" \
  "$(sql_in "SELECT string_agg(column_name, ',' ORDER BY column_name COLLATE \"C\") FROM information_schema.columns WHERE table_schema = '$S' AND table_name = 'stoppages'")" \
  "cause,corrected_at,corrected_cause,correction_note,created_at,dedupe_key,evidence,id,idle_seconds,ref,repo,resumed_at,source,stopped_at,thread"

# ---- kept locally, then sent --------------------------------------------------
rm -rf "$KEEP"
RC=0
env HUMAN_QUEUE_DATABASE_URL="postgresql://u:pw@127.0.0.1:1/db" HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_STOPPAGE_DIR="$KEEP" \
  bash "$HQ_T_CLI" stoppage record --thread s5 --repo acme/widgets --cause crash --evidence "while down" \
  --at 2026-11-12T08:00:00Z >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
check "down: record exits 0" "$RC" "0"
RC=0
env HUMAN_QUEUE_DATABASE_URL="postgresql://u:pw@127.0.0.1:1/db" HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_STOPPAGE_DIR="$KEEP" \
  bash "$HQ_T_CLI" stoppage resume --thread s5 --at 2026-11-12T08:45:00Z >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
check "down: resume exits 0" "$RC" "0"
check "down: two operations kept" "$(find "$KEEP" -maxdepth 1 -name '[0-9]*.json' | wc -l | tr -d ' ')" "2"
check "down: nothing stored yet" "$(sql_in "SELECT count(*) FROM stoppages WHERE thread = 's5'")" "0"
hq stoppage flush
check "flush: sends both" "$OUT" "sent 2"
check "flush: the keep directory empties" "$(find "$KEEP" -maxdepth 1 -name '[0-9]*.json' | wc -l | tr -d ' ')" "0"
check "flush: stored in order, idle time added" "$(sql_in "SELECT cause || ' ' || idle_seconds FROM stoppages WHERE thread = 's5'")" "crash 2700"

# ---- order: a kept correction lands before a newer record ----------------------
# The correction was made against the thread's older entry; when the database
# returns, a new record must not be written ahead of it, or the correction would
# land on the newer entry.
rm -rf "$KEEP"
hq stoppage record --thread s6 --repo acme/widgets --cause crash --evidence "older" --at 2026-11-12T09:00:00Z
check "order: the older entry is stored" "$RC" "0"
hq stoppage resume --thread s6 --at 2026-11-12T09:10:00Z
RC=0
env HUMAN_QUEUE_DATABASE_URL="postgresql://u:pw@127.0.0.1:1/db" HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_STOPPAGE_DIR="$KEEP" \
  bash "$HQ_T_CLI" stoppage correct --thread s6 --cause out_of_work >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
check "order: down: the correction is kept" "$(find "$KEEP" -maxdepth 1 -name '[0-9]*.json' | wc -l | tr -d ' ')" "1"
hq stoppage record --thread s6 --repo acme/widgets --cause usage_limit --evidence "newer" --at 2026-11-12T10:00:00Z
check "order: the newer record is stored" "$RC" "0"
check "order: the correction reached the older entry" \
  "$(sql_in "SELECT coalesce(corrected_cause, '-') FROM stoppages WHERE thread = 's6' AND evidence = 'older'")" "out_of_work"
check "order: the newer entry is not corrected" \
  "$(sql_in "SELECT coalesce(corrected_cause, '-') FROM stoppages WHERE thread = 's6' AND evidence = 'newer'")" "-"
check "order: the keep directory is empty" "$(find "$KEEP" -maxdepth 1 -name '[0-9]*.json' | wc -l | tr -d ' ')" "0"

# ---- order: one writer at a time -------------------------------------------------
# While another call holds the lock (it is sending earlier entries), a resume
# must not write ahead of it: it is kept behind them, unapplied.
mkdir -p "$KEEP/.flush.lock"
hq stoppage resume --thread s6 --at 2026-11-12T10:30:00Z
check "lock held: resume exits 0" "$RC" "0"
check_contains "lock held: the resume is kept" "$OUT" "kept locally"
check "lock held: one operation kept" "$(find "$KEEP" -maxdepth 1 -name '[0-9]*.json' | wc -l | tr -d ' ')" "1"
check "lock held: nothing written ahead" \
  "$(sql_in "SELECT count(*) FROM stoppages WHERE thread = 's6' AND evidence = 'newer' AND resumed_at IS NULL")" "1"
rmdir "$KEEP/.flush.lock"
hq stoppage flush
check "lock released: flush sends it" "$OUT" "sent 1"
check "lock released: the entry is closed" \
  "$(sql_in "SELECT idle_seconds FROM stoppages WHERE thread = 's6' AND evidence = 'newer'")" "1800"

# ---- withdraw: a stop another hook continued ------------------------------------
rm -rf "$KEEP"
hq stoppage record --thread s7 --repo acme/widgets --cause unknown --evidence "continued turn" --at 2026-11-12T11:00:00Z
check "withdraw: the entry is stored" "$(sql_in "SELECT count(*) FROM stoppages WHERE thread = 's7'")" "1"
hq stoppage withdraw --thread s7 --at 2026-11-12T11:00:00Z
check "withdraw: exit 0" "$RC" "0"
check "withdraw: says one withdrawn" "$OUT" "withdrawn 1"
check "withdraw: the entry is deleted, not closed" "$(sql_in "SELECT count(*) FROM stoppages WHERE thread = 's7'")" "0"
hq stoppage withdraw --thread s7 --at 2026-11-12T11:00:00Z
check "withdraw again: nothing left, still exit 0" "$RC:$OUT" "0:withdrawn 0"
hq stoppage record --thread s8 --repo acme/widgets --cause crash --evidence "real stop" --at 2026-11-12T12:00:00Z
hq stoppage resume --thread s8 --at 2026-11-12T12:20:00Z
hq stoppage withdraw --thread s8 --at 2026-11-12T12:00:00Z
check "withdraw: an entry already resumed is left alone" "$(sql_in "SELECT idle_seconds FROM stoppages WHERE thread = 's8'")" "1200"
hq stoppage record --thread s9 --repo acme/widgets --cause crash --evidence "other entry" --at 2026-11-12T13:00:00Z
hq stoppage withdraw --thread s9 --at 2026-11-12T13:00:01Z
check "withdraw: only the entry with that stop time" "$(sql_in "SELECT count(*) FROM stoppages WHERE thread = 's9'")" "1"
# kept while the database is down, then sent in order: record, then withdraw
rm -rf "$KEEP"
DOWN_URL="postgresql://u:pw@127.0.0.1:1/db"
env HUMAN_QUEUE_DATABASE_URL="$DOWN_URL" HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_STOPPAGE_DIR="$KEEP" \
  bash "$HQ_T_CLI" stoppage record --thread s10 --repo acme/widgets --cause unknown --evidence "continued" \
  --at 2026-11-12T14:00:00Z >/dev/null 2>&1 </dev/null
env HUMAN_QUEUE_DATABASE_URL="$DOWN_URL" HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_STOPPAGE_DIR="$KEEP" \
  bash "$HQ_T_CLI" stoppage withdraw --thread s10 --at 2026-11-12T14:00:00Z >/dev/null 2>&1 </dev/null
check "withdraw: kept behind its record" "$(find "$KEEP" -maxdepth 1 -name '[0-9]*.json' | wc -l | tr -d ' ')" "2"
hq stoppage flush
check "withdraw: flush sends both" "$OUT" "sent 2"
check "withdraw: the entry never shows up" "$(sql_in "SELECT count(*) FROM stoppages WHERE thread = 's10'")" "0"

# ---- why accounts for a kept resume while the database is reachable ----------------
rm -rf "$KEEP"
hq stoppage record --thread s11 --repo acme/widgets --cause crash --evidence "x" --at 2026-11-12T15:00:00Z
mkdir -p "$KEEP"
printf '%s\n' '{"op":"resume","thread":"s11","at":"2026-11-12T15:10:00Z"}' >"$KEEP/0000000000000001-1.json"
mkdir "$KEEP/.flush.lock"
hq stoppage why --thread s11
check_contains "why: a kept resume closes an open entry the database still shows" "$OUT" "idle 10m"
rmdir "$KEEP/.flush.lock"
rm -rf "$KEEP"

# ---- list: a real calendar date reaches the database, a false one never does -----
hq stoppage list --from 2026-02-31
check "list: 31 February is validation, not a database error" "$RC" "4"

PUBLIC_AFTER=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
check "the public schema is untouched" "$PUBLIC_AFTER" "$PUBLIC_BEFORE"

hq_t_finish "stoppage.test.sh"
