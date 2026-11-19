#!/usr/bin/env bash
# desk/tests/queue-owner.test.sh — live tests for the queue owner stamp (issue
# #2184): owner set / get / transfer, and the owner check inside register-control,
# tick --session, and add, against the database in HUMAN_QUEUE_DATABASE_URL.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. Every run creates throwaway schemas named
# hq_test_<pid>_<random>_*, points the CLI at them with HUMAN_QUEUE_SCHEMA, and
# drops them on exit. Names used as binding names are hq_test_ names too (the
# desk's test seam accepts only those), so no real account name appears here.
# The suite also asserts that the number of tables in `public` is unchanged.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset. With the
# URL set, an unreachable database FAILS the suite.
#
# Asserts (issue #2184 Test Plan):
#   - a fresh queue has no owner; a named add refuses (instructions, nothing
#     written) while an unnamed add keeps working as before
#   - owner set stamps once; the same name changes nothing; a different name is
#     refused (exit 4), naming both
#   - register-control as the wrong owner exits 4, names both sides, and writes
#     no control_session; the right owner registers
#   - tick --session as the wrong owner exits 4, writes no tick_at and reads no
#     items; the right owner ticks
#   - add as the wrong owner exits 4 and writes no item row; an unnamed call to
#     a stamped queue is refused too
#   - owner transfer without --confirm writes nothing and reports the open
#     items; with --confirm the new owner takes the queue, and the old one is
#     refused from then on
#   - owner transfer on an unstamped queue is refused; state set queue_owner is
#     refused
#   - the number of tables in public is unchanged
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

hq_t_require_db "queue-owner.test.sh"

# Reuse the CLI's own connection library so the URL never reaches argv here
# either. hq_db_connect exits 7 (failing this suite) when unreachable.
HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

# The schema names must not collide across machines that share this database:
# $RANDOM is 15 bits, and a colliding run would DROP ... CASCADE another run's
# schemas. 64 random bits from the kernel make a collision negligible.
RAND_HEX=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
BASE="hq_test_$$_${RAND_HEX}"
S_MAIN="${BASE}_owner"
S_BARE="${BASE}_bare"
NAME_A="${BASE}_a"
NAME_B="${BASE}_b"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-queue-owner-test.XXXXXX")

admin_sql() { hq_psql -At -c "$1"; }

cleanup() {
  admin_sql "DROP SCHEMA IF EXISTS $S_MAIN CASCADE; DROP SCHEMA IF EXISTS $S_BARE CASCADE;" >/dev/null 2>&1 \
    || echo "WARN: could not drop scratch schemas $S_MAIN / $S_BARE — drop them by hand" >&2
  rm -rf "$TMP"
}
trap cleanup EXIT

# sql_in SCHEMA SQL — one query in SCHEMA, unaligned tuples only.
sql_in() { hq_psql -At -c "SET search_path TO $1; $2" 2>&1; }

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

# hq SCHEMA NAME ARGS... — runs the CLI in SCHEMA with HUMAN_QUEUE_BINDING set
# to NAME ("" for an unnamed call). Sets OUT, ERR, RC.
hq() {
  local schema="$1" name="$2"
  shift 2
  RC=0
  if [ -n "$name" ]; then
    HUMAN_QUEUE_SCHEMA="$schema" HUMAN_QUEUE_BINDING="$name" bash "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  else
    env -u HUMAN_QUEUE_BINDING HUMAN_QUEUE_SCHEMA="$schema" bash "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  fi
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

item_count() { sql_in "$1" "SELECT count(*) FROM items"; }

# --- the scratch queue ------------------------------------------------------
hq "$S_MAIN" "" migrate
check "migrate the scratch schema" "$RC" "0"
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$ERR"
  hq_t_finish "queue-owner.test.sh"
  exit 1
fi

# --- an unstamped queue -----------------------------------------------------
printf '== unstamped queue\n'
hq "$S_MAIN" "" owner get
check "a fresh queue has no owner" "$OUT" "no owner"
hq "$S_MAIN" "$NAME_A" add --kind decision --repo owner/repo --key pr-1 --question "Named before any owner?"
check "a named add to an unstamped queue refuses (exit 4)" "$RC" "4"
check_contains "the unstamped refusal says to run bind" "$ERR" "only bind (desk-cli.sh bind --name NAME --schema SCHEMA) records one"
check "the refused named add wrote no item" "$(item_count "$S_MAIN")" "0"
hq "$S_MAIN" "" add --kind decision --repo owner/repo --key pr-1 --question "Unnamed, as before?"
check "an unnamed add to an unstamped queue keeps working" "$RC" "0"
check_contains "the unnamed add returned an item id" "$OUT" "D-"
check "the unnamed add wrote one item" "$(item_count "$S_MAIN")" "1"
hq "$S_MAIN" "" owner transfer "$NAME_B" --confirm
check "transfer on an unstamped queue is refused (exit 4)" "$RC" "4"
check_contains "transfer on an unstamped queue says to stamp it first" "$ERR" "the first bind stamps it"
hq "$S_MAIN" "" state set queue_owner "$NAME_A"
check "state set queue_owner is refused (exit 4)" "$RC" "4"
check_contains "state set queue_owner is reserved" "$ERR" "queue_owner is reserved"

# --- owner set --------------------------------------------------------------
printf '== owner set\n'
hq "$S_MAIN" "" owner set "$NAME_A"
check "owner set stamps an unstamped queue (exit 0)" "$RC" "0"
check "owner set reports the stamp" "$OUT" "queue owner set to $NAME_A"
hq "$S_MAIN" "" owner get
check "owner get reads the stamp" "$OUT" "$NAME_A"
hq "$S_MAIN" "" owner set "$NAME_A"
check "owner set with the same name changes nothing (exit 0)" "$RC" "0"
check "owner set with the same name says so" "$OUT" "queue owner is already $NAME_A"
hq "$S_MAIN" "" owner set "$NAME_B"
check "owner set with a different name is refused (exit 4)" "$RC" "4"
check_contains "that refusal names the current owner" "$ERR" "belongs to '$NAME_A'"
check_contains "that refusal names the requested name" "$ERR" "cannot be set to '$NAME_B'"
hq "$S_MAIN" "" owner get
check "the refused owner set left the stamp alone" "$OUT" "$NAME_A"

# --- the wrong owner is refused everywhere a desk writes --------------------
printf '== the wrong owner\n'
hq "$S_MAIN" "$NAME_B" register-control desk-1
check "register-control as the wrong owner exits 4" "$RC" "4"
check_contains "register-control refusal names the queue's owner" "$ERR" "belongs to '$NAME_A'"
check_contains "register-control refusal names the caller's binding" "$ERR" "bound as '$NAME_B'"
check "register-control wrote no control_session" "$(sql_in "$S_MAIN" "SELECT count(*) FROM state WHERE key = 'control_session'")" "0"

hq "$S_MAIN" "$NAME_A" register-control desk-1
check "register-control as the owner succeeds" "$RC" "0"
check_contains "register-control names the registered session" "$OUT" "control session desk-1"

hq "$S_MAIN" "$NAME_B" tick --session desk-1
check "tick --session as the wrong owner exits 4" "$RC" "4"
check "a refused tick --session printed no item output" "$OUT" ""
check_contains "tick refusal names both sides" "$ERR" "bound as '$NAME_B'"
check "tick refused: no tick_at was stamped" "$(sql_in "$S_MAIN" "SELECT count(*) FROM state WHERE key = 'tick_at'")" "0"
check "tick refused: the watermark was not moved" "$(sql_in "$S_MAIN" "SELECT count(*) FROM state WHERE key = 'tick_watermark'")" "0"

hq "$S_MAIN" "$NAME_B" tick
check "a sessionless tick as the wrong owner is refused (exit 4)" "$RC" "4"
check "a refused sessionless tick printed no item output" "$OUT" ""
check "a sessionless tick refused: the watermark was not moved" "$(sql_in "$S_MAIN" "SELECT count(*) FROM state WHERE key = 'tick_watermark'")" "0"

hq "$S_MAIN" "" tick
check "a sessionless tick with no name on a stamped queue is refused" "$RC" "4"

hq "$S_MAIN" "" tick --session desk-1
check "tick --session with no name on a stamped queue is refused" "$RC" "4"
check_contains "that refusal says the call names no binding" "$ERR" "names no account binding"

hq "$S_MAIN" "$NAME_A" tick --session desk-1
check "tick --session as the owner succeeds" "$RC" "0"
check "the owner's tick stamped tick_at" "$(sql_in "$S_MAIN" "SELECT count(*) FROM state WHERE key = 'tick_at'")" "1"

hq "$S_MAIN" "$NAME_B" add --kind decision --repo owner/repo --key pr-2 --question "From the wrong desk?"
check "add as the wrong owner exits 4" "$RC" "4"
check "a refused add printed no item id" "$OUT" ""
check_contains "add refusal names both sides" "$ERR" "bound as '$NAME_B'"
check "the refused add wrote no item" "$(item_count "$S_MAIN")" "1"

hq "$S_MAIN" "" add --kind decision --repo owner/repo --key pr-2 --question "Unnamed on a stamped queue?"
check "an unnamed add on a stamped queue is refused" "$RC" "4"
check "the refused unnamed add wrote no item" "$(item_count "$S_MAIN")" "1"

hq "$S_MAIN" "$NAME_A" add --kind decision --repo owner/repo --key pr-2 --question "From the owner?"
check "add as the owner succeeds" "$RC" "0"
check "the owner's add wrote an item" "$(item_count "$S_MAIN")" "2"

# --- transfer ---------------------------------------------------------------
printf '== transfer\n'
hq "$S_MAIN" "" owner transfer "$NAME_B"
check "transfer without --confirm exits 0" "$RC" "0"
check_contains "transfer without --confirm reports the open items" "$OUT" "2 open items"
check_contains "transfer without --confirm says it would write" "$OUT" "would transfer"
check "transfer without --confirm left tick_at in place" "$(sql_in "$S_MAIN" "SELECT count(*) FROM state WHERE key = 'tick_at'")" "1"
check "transfer without --confirm left the control session in place" "$(sql_in "$S_MAIN" "SELECT count(*) FROM state WHERE key = 'control_session'")" "1"
hq "$S_MAIN" "" owner get
check "transfer without --confirm changed nothing" "$OUT" "$NAME_A"

hq "$S_MAIN" "" owner transfer "$NAME_B" --confirm
check "transfer with --confirm exits 0" "$RC" "0"
check_contains "transfer with --confirm reports the move and the open items" "$OUT" "transferred this queue from '$NAME_A' to '$NAME_B' (2 open items)"
hq "$S_MAIN" "" owner get
check "owner get reads the new owner" "$OUT" "$NAME_B"
check "transfer cleared the previous owner's tick_at" "$(sql_in "$S_MAIN" "SELECT count(*) FROM state WHERE key = 'tick_at'")" "0"
check "transfer cleared the previous owner's control session" "$(sql_in "$S_MAIN" "SELECT count(*) FROM state WHERE key = 'control_session'")" "0"

hq "$S_MAIN" "$NAME_A" add --kind decision --repo owner/repo --key pr-3 --question "Old owner after transfer?"
check "the old owner is refused after the transfer" "$RC" "4"
hq "$S_MAIN" "$NAME_B" add --kind decision --repo owner/repo --key pr-3 --question "New owner after transfer?"
check "the new owner adds after the transfer" "$RC" "0"
check "the new owner's add wrote an item" "$(item_count "$S_MAIN")" "3"

hq "$S_MAIN" "" owner transfer "$NAME_B" --confirm
check "transfer to the current owner changes nothing (exit 0)" "$RC" "0"
check_contains "that transfer says nothing changed" "$OUT" "queue owner is already $NAME_B; nothing changed"

# --- an unstamped schema stays unstamped until bind -------------------------
printf '== a second, unstamped queue\n'
hq "$S_BARE" "" migrate
check "migrate the second scratch schema" "$RC" "0"
hq "$S_BARE" "$NAME_A" register-control desk-9
check "a named call to a second unstamped queue is refused" "$RC" "4"
check "the second queue has no owner" "$(sql_in "$S_BARE" "SELECT count(*) FROM state WHERE key = 'queue_owner'")" "0"

# --- no table was created in public -----------------------------------------
PUBLIC_AFTER=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
check "public: the number of tables is unchanged" "$PUBLIC_AFTER" "$PUBLIC_BEFORE"

hq_t_finish "queue-owner.test.sh"
