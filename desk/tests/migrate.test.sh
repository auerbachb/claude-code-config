#!/usr/bin/env bash
# desk/tests/migrate.test.sh — live tests for `human-queue.sh migrate` and
# migration 001 (issue #1774), against the database in HUMAN_QUEUE_DATABASE_URL.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. Every run creates throwaway schemas named
# hq_test_<pid>_<random>[_suffix], points the CLI at them with
# HUMAN_QUEUE_SCHEMA, and drops them on exit. The suite also asserts that the
# number of tables in `public` is unchanged.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset. With the
# URL set, an unreachable database FAILS the suite.
#
# Asserts (Test Plan 5.1 and AC 4.3/4.4):
#   - migrate on an empty schema creates items, events, sets, state and
#     schema_migrations, and records 001_init.sql by full filename
#   - a second migrate applies nothing
#   - two files sharing a prefix (002_alpha, 002_beta) both apply, in order
#   - a failing migration rolls back its DDL and its ledger row, exit 1
#   - two concurrent migrates both exit 0 and apply 001 exactly once
#   - 001's constraints: id format and kind prefix, context <= 3 lines and
#     <= 600 chars, note <= 200 chars, status and event-kind sets, and the
#     updated_at trigger
#   - hq_psql's connect deadline stands down once connected: a query longer
#     than 1.5 s survives, with a space in the marker path
# On macOS the first migrate and one side of the race run under /bin/bash 3.2.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

hq_t_require_db "migrate.test.sh"

# Reuse the CLI's own connection library so the URL never reaches argv here
# either. hq_db_connect exits 7 (failing this suite) when unreachable.
HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

BASE="hq_test_$$_$(printf '%05d' "$RANDOM")"
S_MAIN="$BASE"
S_RACE="${BASE}_race"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-migrate-test.XXXXXX")

admin_sql() { hq_psql -At -c "$1"; }

cleanup() {
  admin_sql "DROP SCHEMA IF EXISTS $S_MAIN CASCADE; DROP SCHEMA IF EXISTS $S_RACE CASCADE;" >/dev/null 2>&1 \
    || echo "WARN: could not drop scratch schemas $S_MAIN / $S_RACE — drop them by hand" >&2
  rm -rf "$TMP"
  hq__cleanup_tmp
}
trap cleanup EXIT

# sql_in SCHEMA SQL — one query in SCHEMA, unaligned tuples only.
sql_in() { hq_psql -At -c "SET search_path TO $1; $2" 2>&1; }

# expect_reject LABEL SCHEMA SQL — the statement must fail on a constraint.
expect_reject() {
  local out rc=0
  out=$(hq_psql -At -c "SET search_path TO $2; $3" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *violates*) ok "$1" ;;
      *) bad "$1 (failed, but not on a constraint: $out)" ;;
    esac
  else
    bad "$1 (accepted)"
  fi
}

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

if ! admin_sql "CREATE SCHEMA $S_MAIN" >/dev/null; then
  bad "create scratch schema $S_MAIN"
  hq_t_finish "migrate.test.sh"
  exit 1
fi
echo "scratch schema: $S_MAIN"

# The CLI must work under macOS /bin/bash 3.2 as well as a modern bash. When
# /bin/bash is 3.x, the first migrate and one side of the race run under it.
OLD_BASH=bash
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  OLD_BASH=/bin/bash
fi

# run_migrate SCHEMA [CLI [SHELL]] — sets OUT, ERR, RC.
run_migrate() {
  local cli="${2:-$HQ_T_CLI}" sh="${3:-bash}"
  RC=0
  HUMAN_QUEUE_SCHEMA="$1" "$sh" "$cli" migrate >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# --- 5.1: empty schema -> four tables + ledger -----------------------------
echo "first migrate runs under: $OLD_BASH"
run_migrate "$S_MAIN" "$HQ_T_CLI" "$OLD_BASH"
check "first migrate exits 0" "$RC" "0"
check "first migrate applies 001_init.sql" "$OUT" "applied 001_init.sql"
check "first migrate is silent on stderr" "$ERR" ""
TABLES=$(sql_in "$S_MAIN" "SELECT string_agg(table_name, ',' ORDER BY table_name) FROM information_schema.tables WHERE table_schema = '$S_MAIN'")
check "migrate created exactly the expected tables" "$TABLES" "events,items,schema_migrations,sets,state"
LEDGER=$(sql_in "$S_MAIN" "SELECT string_agg(filename, ',' ORDER BY filename) FROM schema_migrations")
check "ledger records the full filename" "$LEDGER" "001_init.sql"

run_migrate "$S_MAIN"
check "second migrate exits 0" "$RC" "0"
check "second migrate applies nothing" "$OUT" "nothing to apply"

# --- 001 constraints --------------------------------------------------------
VALID_COLS="id, kind, repo, key, session_id, question, context, options, default_option, impact_declared"
VALID_ROW="'D-1', 'decision', 'auerbachb/claude-code-config', 'pr-1774', 'sess-1', 'Ship it?', ARRAY['one','two','three'], ARRAY['Yes','No'], 'Yes', 'medium'"
R=$(sql_in "$S_MAIN" "INSERT INTO items ($VALID_COLS) VALUES ($VALID_ROW) RETURNING status")
check "a valid Decision inserts with status open" "$R" "open"
R=$(sql_in "$S_MAIN" "INSERT INTO items (id, kind, repo, key, question) VALUES ('R-1', 'review', 'o/r', 'pr-1', 'Merged: thing') RETURNING id")
check "a valid Review inserts" "$R" "R-1"
expect_reject "id prefix must match kind (R- for a decision)" "$S_MAIN" \
  "INSERT INTO items (id, kind, repo, key, question) VALUES ('R-2', 'decision', 'o/r', 'k', 'q')"
expect_reject "id must look like D-n / R-n" "$S_MAIN" \
  "INSERT INTO items (id, kind, repo, key, question) VALUES ('D-01', 'decision', 'o/r', 'k', 'q')"
expect_reject "kind is decision or review" "$S_MAIN" \
  "INSERT INTO items (id, kind, repo, key, question) VALUES ('D-3', 'idea', 'o/r', 'k', 'q')"
expect_reject "context holds at most three lines" "$S_MAIN" \
  "INSERT INTO items (id, kind, repo, key, question, context) VALUES ('D-4', 'decision', 'o/r', 'k', 'q', ARRAY['a','b','c','d'])"
expect_reject "context is at most 600 characters" "$S_MAIN" \
  "INSERT INTO items (id, kind, repo, key, question, context) VALUES ('D-5', 'decision', 'o/r', 'k', 'q', ARRAY[repeat('x', 300), repeat('y', 301)])"
R=$(sql_in "$S_MAIN" "INSERT INTO items (id, kind, repo, key, question, context) VALUES ('D-6', 'decision', 'o/r', 'k', 'q', ARRAY[repeat('x', 300), repeat('y', 300)]) RETURNING id")
check "context of exactly 600 characters is accepted" "$R" "D-6"
expect_reject "a context line cannot hide a newline" "$S_MAIN" \
  "INSERT INTO items (id, kind, repo, key, question, context) VALUES ('D-7', 'decision', 'o/r', 'k', 'q', ARRAY[E'a\nb'])"
expect_reject "the question is one line" "$S_MAIN" \
  "INSERT INTO items (id, kind, repo, key, question) VALUES ('D-8', 'decision', 'o/r', 'k', E'two\nlines')"
expect_reject "status is from the closed set" "$S_MAIN" \
  "INSERT INTO items (id, kind, repo, key, question, status) VALUES ('D-9', 'decision', 'o/r', 'k', 'q', 'pending')"
expect_reject "repo is owner/name" "$S_MAIN" \
  "INSERT INTO items (id, kind, repo, key, question) VALUES ('D-10', 'decision', 'not-a-repo', 'k', 'q')"
expect_reject "impact_declared is low/medium/high" "$S_MAIN" \
  "INSERT INTO items (id, kind, repo, key, question, impact_declared) VALUES ('D-11', 'decision', 'o/r', 'k', 'q', 'huge')"

R=$(sql_in "$S_MAIN" "INSERT INTO events (item_id, kind, note) VALUES ('D-1', 'asked', repeat('n', 200)) RETURNING kind")
check "a 200-character event note is accepted" "$R" "asked"
expect_reject "an event note is at most 200 characters" "$S_MAIN" \
  "INSERT INTO events (item_id, kind, note) VALUES ('D-1', 'bumped', repeat('n', 201))"
expect_reject "event kind is from the state-change list" "$S_MAIN" \
  "INSERT INTO events (item_id, kind) VALUES ('D-1', 'transcript')"
expect_reject "an event needs an existing item" "$S_MAIN" \
  "INSERT INTO events (item_id, kind) VALUES ('D-999', 'asked')"
R=$(sql_in "$S_MAIN" "INSERT INTO sets (set_id, position, item_id) VALUES (1, 1, 'D-1') RETURNING position")
check "a set row inserts" "$R" "1"
expect_reject "an item appears once per set" "$S_MAIN" \
  "INSERT INTO sets (set_id, position, item_id) VALUES (1, 2, 'D-1')"
expect_reject "set positions start at 1" "$S_MAIN" \
  "INSERT INTO sets (set_id, position, item_id) VALUES (1, 0, 'R-1')"
R=$(sql_in "$S_MAIN" "INSERT INTO state (key, value) VALUES ('tick_watermark', '0') RETURNING key")
check "a state row inserts" "$R" "tick_watermark"

R=$(sql_in "$S_MAIN" "UPDATE items SET created_at = now() - interval '1 hour', updated_at = now() - interval '1 hour' WHERE id = 'D-1'; UPDATE items SET answer = 'Yes' WHERE id = 'D-1'; SELECT updated_at > created_at FROM items WHERE id = 'D-1'")
check "the trigger refreshes updated_at on every update" "$R" "t"

R=$(sql_in "$S_MAIN" "DELETE FROM items WHERE id = 'D-1'; SELECT count(*) FROM events WHERE item_id = 'D-1'")
check "deleting an item cascades to its events" "$R" "0"

# --- same-prefix migrations both apply (full-filename ledger) ---------------
mkdir -p "$TMP/tree dir/desk"
cp -R "$HQ_T_DESK_DIR/bin" "$HQ_T_DESK_DIR/schema" "$TMP/tree dir/desk/"
TREE_CLI="$TMP/tree dir/desk/bin/human-queue.sh"
printf 'CREATE TABLE alpha_t (x int);\n' > "$TMP/tree dir/desk/schema/002_alpha.sql"
printf 'CREATE TABLE beta_t (x int);\n' > "$TMP/tree dir/desk/schema/002_beta.sql"
run_migrate "$S_MAIN" "$TREE_CLI"
check "two 002_ files exit 0" "$RC" "0"
check "two 002_ files both apply, in lexical order" "$OUT" "applied 002_alpha.sql
applied 002_beta.sql"
LEDGER=$(sql_in "$S_MAIN" "SELECT string_agg(filename, ',' ORDER BY filename) FROM schema_migrations")
check "ledger holds both same-prefix files" "$LEDGER" "001_init.sql,002_alpha.sql,002_beta.sql"

# --- a failing migration rolls back completely ------------------------------
printf 'CREATE TABLE partial_t (x int);\nSELECT * FROM no_such_table_hq;\n' > "$TMP/tree dir/desk/schema/003_broken.sql"
run_migrate "$S_MAIN" "$TREE_CLI"
check "a failing migration exits 1" "$RC" "1"
check "a failing migration reports one stderr line" "$(hq_t_lines "$ERR")" "1"
check_contains "the failing file is named" "$ERR" "003_broken.sql"
check_contains "the database error is quoted" "$ERR" "no_such_table_hq"
R=$(sql_in "$S_MAIN" "SELECT count(*) FROM schema_migrations WHERE filename = '003_broken.sql'")
check "the failed file has no ledger row" "$R" "0"
R=$(sql_in "$S_MAIN" "SELECT to_regclass('partial_t') IS NULL")
check "the failed file's DDL was rolled back" "$R" "t"
rm -f "$TMP/tree dir/desk/schema/003_broken.sql"
run_migrate "$S_MAIN" "$TREE_CLI"
check "after removing the broken file, nothing is pending" "$OUT" "nothing to apply"

# --- concurrent runs serialize; the schema is created on demand -------------
RC_A=0; RC_B=0
HUMAN_QUEUE_SCHEMA="$S_RACE" bash "$HQ_T_CLI" migrate >"$TMP/race_a.out" 2>"$TMP/race_a.err" </dev/null &
PID_A=$!
HUMAN_QUEUE_SCHEMA="$S_RACE" "$OLD_BASH" "$HQ_T_CLI" migrate >"$TMP/race_b.out" 2>"$TMP/race_b.err" </dev/null &
PID_B=$!
wait "$PID_A" || RC_A=$?
wait "$PID_B" || RC_B=$?
check "concurrent migrate A exits 0" "$RC_A" "0"
check "concurrent migrate B exits 0" "$RC_B" "0"
APPLIED_COUNT=$(cat "$TMP/race_a.out" "$TMP/race_b.out" | grep -c '^applied 001_init.sql$' || true)
check "001 applied exactly once across both runs" "$APPLIED_COUNT" "1"
check "concurrent runs are silent on stderr" "$(cat "$TMP/race_a.err" "$TMP/race_b.err")" ""
R=$(sql_in "$S_RACE" "SELECT count(*) FROM schema_migrations")
check "the race left one ledger row" "$R" "1"

# --- once connected, the connect deadline never limits SQL ------------------
# hq_psql's watchdog kills psql only when its connect marker is still empty at
# 1.5 s. A query that outlasts the deadline must survive, with the marker path
# (TMPDIR) containing a space: psql must write the marker to the whole path.
mkdir -p "$TMP/marker dir"
RC=0
R=$(
  TMPDIR="$TMP/marker dir/"
  HQ_CONN_MARKER=""
  hq_db_connect
  hq_psql -At -c "SELECT pg_sleep(2)" -c "SELECT 'survived'" || exit "$?"
  printf 'marker=%s\n' "$(cat "$HQ_CONN_MARKER")"
  case "$HQ_CONN_MARKER" in *"marker dir/"*) printf 'spaced=yes\n' ;; esac
) || RC=$?
check "a 2 s query outlives the 1.5 s connect deadline" "$RC" "0"
check_contains "the long query completes" "$R" "survived"
check_contains "psql wrote the connect marker" "$R" "marker=connected"
check_contains "the marker path contained a space" "$R" "spaced=yes"

# --- the live default schema was never touched -----------------------------
PUBLIC_AFTER=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
check "public schema table count unchanged" "$PUBLIC_AFTER" "$PUBLIC_BEFORE"

hq_t_finish "migrate.test.sh"
