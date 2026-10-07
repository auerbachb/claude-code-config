#!/usr/bin/env bash
# desk/tests/capture.test.sh — live tests for the capture hook (issue #1755)
# and the control-status / tick_at it relies on, against the database in
# HUMAN_QUEUE_DATABASE_URL, through the real CLI.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. The run creates one throwaway schema named
# hq_test_<pid>_<random>_capture, points the CLI (and so the hook, which
# passes its environment on) at it with HUMAN_QUEUE_SCHEMA, and drops it on
# exit. The suite also asserts that the number of tables in `public` is
# unchanged. No control session is ever registered outside that schema.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset. With the
# URL set, an unreachable database FAILS the suite.
#
# Asserts (issue #1755 AC and Test Plan):
#   control-status  null fields on a fresh store; register-control fills the
#                   session; tick writes tick_at and the age is computed
#   4.2             no control session: allow, nothing queued; registered but
#                   never ticked: allow, nothing queued; stale tick (20 min):
#                   allow, nothing queued
#   5.1             live desk, worker session: deny, the item exists with the
#                   worker as its return address, the reason names D-<n> and
#                   the receipt line
#   5.2             live desk, the desk's own session: allow, the item exists
#   4.1             options, the recommended default, kind, repo, key; the
#                   same call again bumps the same item (dedupe); two
#                   questions in one call are two items
#   4.3a            URL absent from the environment but present in a
#                   profile: still captured
#   replacement     re-registering the same session keeps tick_at; a
#                   different session clears it, so nothing is queued
#                   until the new desk ticks, then its questions are
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

hq_t_require_db "capture.test.sh"

if ! command -v python3 >/dev/null 2>&1; then
  bad "python3 is not installed: the capture hook cannot run"
  hq_t_finish "capture.test.sh"
  exit 1
fi

HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

REPO_ROOT=$(dirname "$HQ_T_DESK_DIR")
HOOK="$REPO_ROOT/.claude/hooks/human-queue-capture.sh"
S_MAIN="hq_test_$$_$(printf '%05d' "$RANDOM")_capture"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-capture-test.XXXXXX")
chmod 700 "$TMP"

admin_sql() { hq_psql -At -c "$1"; }

cleanup() {
  admin_sql "DROP SCHEMA IF EXISTS $S_MAIN CASCADE;" >/dev/null 2>&1 \
    || echo "WARN: could not drop scratch schema $S_MAIN — drop it by hand" >&2
  rm -rf "$TMP"
  hq__cleanup_tmp
}
trap cleanup EXIT

sql_in() { hq_psql -At -c "SET search_path TO $S_MAIN; $1" 2>&1; }

# hq ARGS... — the real CLI in the scratch schema; sets OUT, ERR, RC.
hq() {
  RC=0
  HUMAN_QUEUE_SCHEMA="$S_MAIN" bash "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# hook INPUT [VAR=VALUE...] — the hook through its symlink, aimed at the
# scratch schema; sets OUT, ERR, RC.
hook() {
  local input="$1"
  shift
  RC=0
  env HUMAN_QUEUE_SCHEMA="$S_MAIN" "$@" bash "$HOOK" >"$TMP/out" 2>"$TMP/err" <<<"$input" || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

reason() {
  printf '%s' "$OUT" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])
except Exception:
    print("")'
}

# json_of FIELD — a field of the JSON object in $OUT ("<null>" for null).
json_of() {
  printf '%s' "$OUT" | python3 -c 'import json,sys
v = json.load(sys.stdin).get(sys.argv[1])
print("<null>" if v is None else v)' "$1"
}

n_items() { sql_in "SELECT count(*) FROM items"; }

# A checkout for the asking thread: origin acme/widgets, branch issue-77-capture.
REPO_DIR="$TMP/widgets"
git init -q "$REPO_DIR"
git -C "$REPO_DIR" symbolic-ref HEAD refs/heads/issue-77-capture
git -C "$REPO_DIR" remote add origin git@github.com:acme/widgets.git

Q1='{"question": "Ship the migration before the CLI?", "header": "Rollout", "multiSelect": false, "options": [{"label": "Ship now (Recommended)", "description": "Merges today"}, {"label": "Wait for review", "description": "One more day"}]}'
Q2='{"question": "Which region?", "header": "Region", "multiSelect": true, "options": [{"label": "us-east-1"}, {"label": "eu-west-1"}]}'
Q3='{"question": "Name the desk test item?", "options": [{"label": "Yes"}, {"label": "No"}]}'

input() {
  local session="$1" qs=""
  shift
  while [ "$#" -gt 0 ]; do
    qs="$qs${qs:+, }$1"
    shift
  done
  printf '{"session_id": "%s", "cwd": "%s", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": {"questions": [%s]}}' \
    "$session" "$REPO_DIR" "$qs"
}

receipt() {
  printf 'Queued as %s. Print exactly: question %s sent to human queue. Then proceed on your recommended default or park and wait for a wake-up.' "$1" "$1"
}

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

hq migrate
check "migrate the scratch schema" "$RC" "0"

# ------------------------------------------------------------- control-status
hq control-status --json
check "control-status on a fresh store: exit 0" "$RC" "0"
check "control-status: no session" "$(json_of session)" "<null>"
check "control-status: no tick" "$(json_of last_tick_at)/$(json_of tick_age_seconds)" "<null>/<null>"
hq control-status
check "control-status text on a fresh store" "$OUT" "no control session
no tick yet"

# --------------------------------------------------------- 4.2: no live desk
hook "$(input worker-1 "$Q1")"
check "no control session: exit 0" "$RC" "0"
check "no control session: allow (nothing on stdout)" "$OUT" ""
check "no control session: nothing on stderr" "$ERR" ""
check "no control session: nothing queued" "$(n_items)" "0"

hq register-control desk-1
check "register-control desk-1" "$RC" "0"
hook "$(input worker-1 "$Q1")"
check "registered, never ticked: allow" "$OUT/$ERR" "/"
check "registered, never ticked: nothing queued" "$(n_items)" "0"

hq tick
check "tick" "$RC" "0"
TICK_AT=$(sql_in "SELECT value FROM state WHERE key = 'tick_at'")
if [[ $TICK_AT =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  ok "tick writes tick_at as UTC ISO 8601 ($TICK_AT)"
else
  bad "tick_at is not UTC ISO 8601: '$TICK_AT'"
fi
hq control-status --json
check "control-status: the registered session" "$(json_of session)" "desk-1"
check "control-status: last_tick_at is tick_at" "$(json_of last_tick_at)" "$TICK_AT"
AGE=$(json_of tick_age_seconds)
if [[ $AGE =~ ^[0-9]+$ ]] && [ "$AGE" -le 120 ]; then
  ok "control-status: a fresh tick is $AGE seconds old"
else
  bad "control-status: unexpected tick age '$AGE'"
fi
hq control-status
check_contains "control-status text names the session" "$OUT" "control session desk-1"
check_contains "control-status text gives the age" "$OUT" "seconds ago)"

sql_in "UPDATE state SET value = to_char((now() - interval '20 minutes') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') WHERE key = 'tick_at'" >/dev/null
hq control-status --json
AGE=$(json_of tick_age_seconds)
if [[ $AGE =~ ^[0-9]+$ ]] && [ "$AGE" -ge 1190 ] && [ "$AGE" -le 1400 ]; then
  ok "control-status: the backdated tick is $AGE seconds old"
else
  bad "control-status: unexpected backdated age '$AGE'"
fi
hook "$(input worker-1 "$Q1")"
check "stale tick (20 min > 15): allow" "$OUT/$ERR" "/"
check "stale tick: nothing queued" "$(n_items)" "0"

# ------------------------------------------------- 5.1: live desk, a worker
hq tick
hook "$(input worker-1 "$Q1")"
ID1=$(sql_in "SELECT id FROM items WHERE question = 'Ship the migration before the CLI?'")
check "worker: exit 0" "$RC" "0"
check "worker: one item exists" "$(n_items)" "1"
check "worker: the item id is D-<n>" "$(printf '%s' "$ID1" | grep -cE '^D-[1-9][0-9]*$')" "1"
check "worker: denied with the receipt reason" "$(reason)" "$(receipt "$ID1")"
check "worker: nothing on stderr" "$ERR" ""
check "worker: the item's fields" \
  "$(sql_in "SELECT kind || ' ' || repo || ' ' || key || ' ' || session_id || ' ' || status FROM items WHERE id = '$ID1'")" \
  "decision acme/widgets issue-77 worker-1 open"
check "worker: the options and the recommended default" \
  "$(sql_in "SELECT array_to_string(options, ' / ') || ' => ' || default_option FROM items WHERE id = '$ID1'")" \
  "Ship now (Recommended) / Wait for review => Ship now (Recommended)"
check "worker: the header and descriptions are context" \
  "$(sql_in "SELECT array_to_string(context, ' / ') FROM items WHERE id = '$ID1'")" \
  "Header: Rollout / Options: Ship now (Recommended): Merges today; Wait for review: One more day"
check "worker: an asked event" "$(sql_in "SELECT string_agg(kind, ',' ORDER BY id) FROM events WHERE item_id = '$ID1'")" "asked"

hook "$(input worker-1 "$Q1")"
check "the same question again: the same id (dedupe)" "$(reason)" "$(receipt "$ID1")"
check "the same question again: still one item" "$(n_items)" "1"
check "the same question again: bumped" "$(sql_in "SELECT string_agg(kind, ',' ORDER BY id) FROM events WHERE item_id = '$ID1'")" "asked,bumped"

# -------------------------------------------- 5.2: live desk, the desk itself
hook "$(input desk-1 "$Q3")"
ID3=$(sql_in "SELECT id FROM items WHERE question = 'Name the desk test item?'")
check "desk session: exit 0" "$RC" "0"
check "desk session: allow (nothing on stdout)" "$OUT" ""
check "desk session: nothing on stderr" "$ERR" ""
check "desk session: the item exists" "$(sql_in "SELECT session_id FROM items WHERE id = '$ID3'")" "desk-1"

# ------------------------------------------------- two questions in one call
BEFORE=$(n_items)
hook "$(input worker-2 "$Q2" '{"question": "And the instance size?", "options": [{"label": "small"}, {"label": "large"}]}')"
IDA=$(sql_in "SELECT id FROM items WHERE question = 'Which region?'")
IDB=$(sql_in "SELECT id FROM items WHERE question = 'And the instance size?'")
check "two questions: two new items" "$(n_items)" "$((BEFORE + 2))"
check "two questions: both ids in the reason" "$(reason)" \
  "Queued as $IDA, $IDB. Print exactly: questions $IDA, $IDB sent to human queue. Then proceed on your recommended defaults or park and wait for a wake-up."

# --------------------------------------- 4.3a: the URL only in a shell profile
case "$HUMAN_QUEUE_DATABASE_URL" in
  *"'"*)
    printf 'skip — the URL holds a single quote; the profile case needs another form\n'
    ;;
  *)
    mkdir -p "$TMP/home"
    ( umask 077 && printf "export HUMAN_QUEUE_DATABASE_URL='%s'\n" "$HUMAN_QUEUE_DATABASE_URL" > "$TMP/home/.zprofile" )
    RC=0
    env -i HOME="$TMP/home" PATH="/usr/bin:/bin" TMPDIR="$TMP" HUMAN_QUEUE_SCHEMA="$S_MAIN" \
      ${HUMAN_QUEUE_PSQL:+HUMAN_QUEUE_PSQL="$HUMAN_QUEUE_PSQL"} \
      bash "$HOOK" >"$TMP/out" 2>"$TMP/err" <<<"$(input worker-3 '{"question": "Captured from the profile?", "options": [{"label": "Yes"}]}')" || RC=$?
    OUT=$(cat "$TMP/out")
    ERR=$(cat "$TMP/err")
    rm -f "$TMP/home/.zprofile"
    IDP=$(sql_in "SELECT id FROM items WHERE question = 'Captured from the profile?'")
    check "URL only in the profile: captured" "$(reason)" "$(receipt "$IDP")"
    check "URL only in the profile: the item exists" "$(sql_in "SELECT session_id FROM items WHERE id = '$IDP'")" "worker-3"
    check "URL only in the profile: nothing on stderr" "$ERR" ""
    ;;
esac

# ---------------------------- a replacement desk is not live until it ticks
hq tick
hq register-control desk-1
check "re-registering the same session: exit 0" "$RC" "0"
hq control-status --json
if [ "$(json_of last_tick_at)" != "<null>" ]; then
  ok "re-registering the same session keeps its tick"
else
  bad "re-registering the same session cleared tick_at"
fi
hq register-control desk-2
check "register-control desk-2 names the one it replaces" "$OUT" "control session desk-2 (replaces desk-1)"
hq control-status --json
check "a replacement session: the previous desk's tick is cleared" "$(json_of session) $(json_of last_tick_at)" "desk-2 <null>"
BEFORE=$(n_items)
hook "$(input worker-4 '{"question": "Queued before the new desk ticks?", "options": [{"label": "No"}]}')"
check "replacement desk, not yet ticked: allow" "$OUT/$ERR" "/"
check "replacement desk, not yet ticked: nothing queued" "$(n_items)" "$BEFORE"
hq tick
hook "$(input worker-4 '{"question": "Queued after the new desk ticks?", "options": [{"label": "Yes"}]}')"
IDR=$(sql_in "SELECT id FROM items WHERE question = 'Queued after the new desk ticks?'")
check "replacement desk after its own tick: queued" "$(reason)" "$(receipt "$IDR")"

PUBLIC_AFTER=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
check "the public schema's tables are unchanged" "$PUBLIC_AFTER" "$PUBLIC_BEFORE"

hq_t_finish "capture.test.sh"
