#!/usr/bin/env bash
# desk/tests/interrupts.test.sh — live tests for the desk's interrupt rule and
# feedback tags (issue #1783), against the database in
# HUMAN_QUEUE_DATABASE_URL.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. Every run creates a throwaway schema named
# hq_test_<pid>_<random>_interrupts, points the CLI at it with
# HUMAN_QUEUE_SCHEMA, and drops it on exit; the number of tables in `public`
# is asserted unchanged.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset. With the
# URL set, an unreachable database FAILS the suite.
#
# Asserts (issue #1783):
#   5.1  three Decisions with no plan: the next tick names all three, and the
#        skill's desk-split block puts them in one set, which set-open numbers
#        1 to 3
#   5.2  `away` (the skill's desk-interrupt-set block): a tick prints nothing,
#        stamps tick_at, and leaves the watermark; `available` and the skill's
#        desk-release block show the held items, once
#   4.3  a focus in the future holds; one whose time has passed does not, and
#        the default is in force again; clock times resolve to their next
#        occurrence within a day; a past or too-distant time is refused;
#        another session's rule is ignored and only the control session sets
#        one; an invalid stored value reads as no rule; the policy's `away`
#        holds a desk that set none; a tick without --interrupts ignores the
#        rule
#   5.3  a feedback tag (the skill's desk-feedback-parse and desk-feedback
#        blocks) writes one `feedback` event with the tag and the asking
#        thread's session id; again is a no-op; by id; a Review's has no
#        session; a number not in the set writes nothing; tick does not
#        report a tagged item again
#   008  over a 007 store: feedback exits 1 naming migrate; migrate applies
#        008; the old events keep a null session; feedback works again
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

hq_t_require_db "interrupts.test.sh"

# desk-tick.sh's end-of-day step (issue #1784) reads this clock: pinned before
# any eod_time, so no tick here asks for the sweep, whatever the hour the
# suite runs at (plan.test.sh tests the sweep).
export HUMAN_QUEUE_CLOCK="2000-01-01 00:00"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: interrupts.test.sh — jq is not installed (the desk skill needs it)"
  exit 0
fi

HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

S="hq_test_$$_$(printf '%05d' "$RANDOM")_interrupts"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-interrupts-test.XXXXXX")
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

OLD_BASH=bash
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  OLD_BASH=/bin/bash
fi

# hq [SHELL] ARGS... — the CLI in the scratch schema; sets OUT, ERR, RC.
hq() {
  local sh=bash
  case "$1" in bash|/bin/bash) sh="$1"; shift ;; esac
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

jqo() { printf '%s' "$OUT" | jq -r "$1"; }
watermark() { sql_in "SELECT value FROM state WHERE key = 'tick_watermark'"; }
tick_at() { sql_in "SELECT value FROM state WHERE key = 'tick_at'"; }
feedback_rows() {
  sql_in "SELECT string_agg(item_id || ':' || note || ':' || coalesce(session_id, 'null'), ',' ORDER BY id)
            FROM events WHERE kind = 'feedback'"
}

# The skill's blocks, run with the prelude's DESK, HQ, and SID: desk-cli.sh,
# which finds the URL in the environment and runs the CLI in the scratch schema.
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
# run_block FILE [SID] — the block as the desk session SID (default desk-1),
# with the repo's own policy.
run_block() {
  (cd "$TMP" && env -u HUMAN_QUEUE_POLICY DESK="$HQ_T_DESK_DIR" HQ="$HQ_BIN_DIR/desk-cli.sh" \
     SID="${2:-desk-1}" HUMAN_QUEUE_SCHEMA="$S" bash "$1") 2>&1
}

block decisions.md desk-split
block interrupts.md desk-interrupt-set
block interrupts.md desk-interrupt-get
block interrupts.md desk-release
block interrupts.md desk-feedback-parse
block interrupts.md desk-feedback

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

hq migrate
check "migrate the scratch schema" "$RC" "0"
check_contains "migrate applies 008" "$OUT" "applied 008_event_session.sql"
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$ERR"
  hq_t_finish "interrupts.test.sh"
  exit 1
fi
echo "scratch schema: $S (old shell: $OLD_BASH)"

REPO=auerbachb/claude-code-config
# add VAR KEY SESSION QUESTION — a menu-shaped Decision; its id goes in VAR.
add() {
  hq add --kind decision --repo "$REPO" --key "$2" --session "$3" --question "$4" \
    --option "Yes" --option "No" --default "No"
  check "add $1" "$RC" "0"
  printf -v "$1" '%s' "$OUT"
}

hq register-control desk-1
check "register-control desk-1" "$RC:$OUT" "0:control session desk-1"
desk --session desk-1 --generation g1 --once
check "the first desk tick on an empty store prints nothing" "$RC:$OUT:$ERR" "0::"

# --- 5.1: three Decisions with no plan, one set -----------------------------------------
add D1 issue-11 worker-a "Ship the migration first?"
add D2 issue-12 worker-b "Rotate the staging key today?"
add D3 issue-13 worker-c "Split the importer PR?"
desk --session desk-1 --generation g1 --once
check "5.1 the next tick names all three" "$RC:$OUT:$ERR" "0:desk-tick g1 new $D1 $D2 $D3:"
literal "$TMP/block-desk-split.sh" "<the event's ids, or empty for all>" "$D1 $D2 $D3" > "$TMP/split.sh"
OUT=$(run_block "$TMP/split.sh")
check "5.1 the desk-split block: one set of three" "$(printf '%s' "$OUT" | jq -c '.sets')" "[[\"$D1\",\"$D2\",\"$D3\"]]"
check "5.1 the desk-split block: all three simple" "$(jqo '.simple | join(" ")')" "$D1 $D2 $D3"
hq set-open "$D1" "$D2" "$D3" --json
check "5.1 set-open numbers them 1 to 3" "$RC:$(jqo '[.items[] | "\(.n)=\(.id)"] | join(",")')" "0:1=$D1,2=$D2,3=$D3"
SET1=$(jqo '.set_id')

# --- 5.2: away holds, available releases ------------------------------------------------
literal "$TMP/block-desk-interrupt-set.sh" "<away|everything>" "away" > "$TMP/away.sh"
literal "$TMP/block-desk-interrupt-set.sh" "<away|everything>" "everything" > "$TMP/available.sh"
OUT=$(run_block "$TMP/away.sh")
check "5.2 away: the block sets it" "$(printf '%s\n' "$OUT" | sed -n 1p | jq -c '[.rule, .held, .source, .until]')" \
  '["away",true,"desk",null]'
check "5.2 away: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
check "5.2 away: stored for this session" \
  "$(sql_in "SELECT value::jsonb->>'session' || ' ' || (value::jsonb->>'rule') FROM state WHERE key = 'interrupt'")" "desk-1 away"
check "5.2 away: no event" "$(sql_in "SELECT count(*) FROM events WHERE kind NOT IN ('asked', 'shown')")" "0"
add D4 issue-14 worker-d "Bump the base image?"
add D5 issue-15 worker-e "Retire the old webhook?"
WM_BEFORE=$(watermark)
sql_in "UPDATE state SET value = '2026-01-01T00:00:00Z' WHERE key = 'tick_at'" >/dev/null
desk --session desk-1 --generation g1 --once
check "5.2 away: the tick shows nothing" "$RC:$OUT:$ERR" "0::"
check "5.2 away: the watermark did not move" "$(watermark)" "$WM_BEFORE"
check "5.2 away: tick_at was stamped (the desk stays live)" \
  "$(sql_in "SELECT (value::timestamptz > now() - interval '1 minute')::text FROM state WHERE key = 'tick_at'")" "true"
hq control-status --json
check "5.2 away: control-status sees a fresh tick" "$(jqo '.tick_age_seconds <= 60')" "true"
hq "$OLD_BASH" tick --session desk-1 --interrupts everything
check "5.2 away: tick --interrupts prints []" "$RC:$OUT:$ERR" "0:[]:"
check "5.2 away: still no watermark move" "$(watermark)" "$WM_BEFORE"
OUT=$(run_block "$TMP/block-desk-interrupt-get.sh")
check "5.2 interrupts?: away" "$OUT" "$(printf 'away\nexit=0')"
OUT=$(run_block "$TMP/available.sh")
check "5.2 available: the block sets everything" "$(printf '%s\n' "$OUT" | sed -n 1p | jq -c '[.rule, .held, .source]')" \
  '["everything",false,"desk"]'
literal "$TMP/block-desk-release.sh" "<GEN>" "g1" > "$TMP/release.sh"
OUT=$(run_block "$TMP/release.sh")
check "5.2 available: the release shows the held items" "$OUT" "desk-tick g1 new $D4 $D5"
desk --session desk-1 --generation g1 --once
check "5.2 available: they are not shown twice" "$RC:$OUT:$ERR" "0::"
OUT=$(run_block "$TMP/block-desk-interrupt-get.sh")
check "5.2 interrupts?: everything, set at the desk" "$OUT" "$(printf 'everything\nexit=0')"

# --- 4.3: focus ---------------------------------------------------------------------------
hq interrupt set focus --session desk-1 --for 30 --json
check "focus --for 30: held until about 30 minutes from now" \
  "$RC:$(jqo '[.rule, .held, .source] | join(",")'):$(sql_in "SELECT abs(extract(epoch FROM ('$(jqo .until)'::timestamptz - now() - interval '30 minutes'))) < 60")" \
  "0:focus,true,desk:t"
hq interrupt get --session desk-1
check_contains "focus: get names its end in ET" "$RC:$OUT" "0:focus until "
check_contains "focus: ... and in UTC" "$OUT" " UTC)"
add D6 issue-16 worker-f "Pin the linter version?"
desk --session desk-1 --generation g1 --once
check "focus in the future: the tick shows nothing" "$RC:$OUT:$ERR" "0::"
sql_in "UPDATE state SET value = jsonb_set(value::jsonb, '{until}', to_jsonb(to_char((now() - interval '1 minute') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')))::text WHERE key = 'interrupt'" >/dev/null
hq interrupt get --session desk-1 --json
check "a focus whose time has passed is over: the default again" "$RC:$(jqo '[.rule, .held, .source, .until] | @json')" \
  '0:["everything",false,"default",null]'
# A focus ends back in the policy's rule: under `away`, the hold goes on.
hq interrupt get --session desk-1 --default away --json
check "a focus over under an away policy: away again, still held" \
  "$RC:$(jqo '[.rule, .held, .source] | join(",")')" "0:away,true,default"
hq tick --session desk-1 --interrupts away
check "... and its tick still holds" "$RC:$OUT" "0:[]"
desk --session desk-1 --generation g1 --once
check "a focus whose time has passed: the next tick shows what it held" "$RC:$OUT:$ERR" "0:desk-tick g1 new $D6:"

hq interrupt set focus --session desk-1 --until "3:30" --json
check "focus until 3:30: the sooner of 03:30 and 15:30 ET" "$RC:$(jqo '.until_local | IN("03:30", "15:30")')" "0:true"
check "focus until 3:30: within twelve hours" \
  "$(sql_in "SELECT '$(jqo .until)'::timestamptz > now() AND '$(jqo .until)'::timestamptz <= now() + interval '12 hours'")" "t"
hq /bin/bash interrupt set focus --session desk-1 --until "3:30pm ET" --json
check "focus until 3:30pm ET: 15:30 ET, the next one" "$RC:$(jqo .until_local)" "0:15:30"
check "focus until 3:30pm ET: within a day" \
  "$(sql_in "SELECT '$(jqo .until)'::timestamptz > now() AND '$(jqo .until)'::timestamptz <= now() + interval '1 day'
                AND to_char('$(jqo .until)'::timestamptz AT TIME ZONE 'America/New_York', 'HH24:MI') = '15:30'")" "t"
# A clock time across a daylight-saving change, on a fixed clock (the
# resolver set uses, hq_sql_focus_until, with NOW pinned): the next showing of
# a time the clock shows twice, the jump for one it skips.
# shellcheck source=../bin/lib/interrupts.sh
. "$HQ_BIN_DIR/lib/interrupts.sh"
focus_at() { # NOW TIMES [SESSION_TZ] -> the focus's end, UTC
  printf '%s\n' "SET TIME ZONE '${3:-UTC}';" \
    "SELECT to_char($(hq_sql_focus_until "'$1'::timestamptz") AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI');" \
    | hq_psql -At -v "hq_tz=America/New_York" -v "hq_times=$2" -f - 2>&1
}
check "until 15:30 at 15:00 EDT: 15:30 today" "$(focus_at '2026-10-07 19:00Z' '15:30')" "2026-10-07 19:30"
check "until 3:30 at 15:00 EDT: the sooner, 15:30" "$(focus_at '2026-10-07 19:00Z' '03:30,15:30')" "2026-10-07 19:30"
check "until 15:30 at 15:30 EDT: tomorrow" "$(focus_at '2026-10-07 19:30Z' '15:30')" "2026-10-08 19:30"
check "until 0:00 at 23:50 EDT: midnight" "$(focus_at '2026-10-07 03:50Z' '00:00')" "2026-10-07 04:00"
check "fall back, until 1:30 at 1:05 EDT: 1:30 EDT, not EST" "$(focus_at '2026-11-01 05:05Z' '01:30,13:30')" "2026-11-01 05:30"
check "fall back, until 1:30 at 1:40 EDT: 1:30 EST" "$(focus_at '2026-11-01 05:40Z' '01:30,13:30')" "2026-11-01 06:30"
check "fall back, until 1:00 at 1:30 EDT: 1:00 EST" "$(focus_at '2026-11-01 05:30Z' '01:00')" "2026-11-01 06:00"
check "spring forward, until 2:30 at 1:05 EST: 3:00 EDT" "$(focus_at '2026-03-08 06:05Z' '02:30')" "2026-03-08 07:00"
check "spring forward, until 3:00 at 1:05 EST: 3:00 EDT" "$(focus_at '2026-03-08 06:05Z' '03:00')" "2026-03-08 07:00"
check "spring forward, until 3:30 at 1:05 EST: 3:30 EDT" "$(focus_at '2026-03-08 06:05Z' '03:30')" "2026-03-08 07:30"
# The window is 24 hours whatever the session's TimeZone: London springs
# forward overnight, so `1 day` from noon there would end an hour early and
# miss 7:30 EDT, 23.5 hours ahead.
check "a session zone's own clock change: still a 24-hour window" \
  "$(focus_at '2026-03-28 12:00Z' '07:30' 'Europe/London')" "2026-03-29 11:30"

# The documented maximum is accepted: the limit judges the end as worked out,
# not the stored end rounded up to the next second.
hq interrupt set focus --session desk-1 --for 1440 --json
check "focus --for 1440, the maximum: accepted, a day from now" \
  "$RC:$(sql_in "SELECT abs(extract(epoch FROM ('$(jqo .until)'::timestamptz - now() - interval '24 hours'))) < 60")" "0:t"
# A fractional ISO --until is stored rounded up to the second, never early.
FRAC=$(sql_in "SELECT to_char((now() + interval '1 hour') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS') || '.400Z'")
hq interrupt set focus --session desk-1 --until "$FRAC" --json
check "focus until a fractional second: rounded up" \
  "$RC:$(sql_in "SELECT '$(jqo .until)'::timestamptz - '$FRAC'::timestamptz = interval '0.6 seconds'")" "0:t"

PAST=$(sql_in "SELECT to_char((now() - interval '1 hour') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI\"Z\"')")
FAR=$(sql_in "SELECT to_char((now() + interval '2 days') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI\"Z\"')")
STORED=$(sql_in "SELECT value FROM state WHERE key = 'interrupt'")
hq interrupt set focus --session desk-1 --until "$PAST"
check "a focus time in the past: exit 4" "$RC" "4"
check_contains "... says so" "$ERR" "the focus time is in the past"
hq interrupt set focus --session desk-1 --until "$FAR"
check "a focus time two days ahead: exit 4" "$RC" "4"
check_contains "... says so" "$ERR" "more than a day ahead"
check "a refused focus stores nothing" "$(sql_in "SELECT value FROM state WHERE key = 'interrupt'")" "$STORED"

# --- 4.3: another session's rule is ignored; only the desk sets one --------------------------
hq interrupt set away --session desk-1
check "away again" "$RC:$OUT" "0:away"
add D7 issue-17 worker-g "Drop the legacy flag?"
hq register-control desk-2
check "a second desk registers" "$RC:$OUT" "0:control session desk-2 (replaces desk-1)"
OUT=$(run_block "$TMP/block-desk-interrupt-get.sh" desk-2)
check "the new desk starts from the policy default" "$OUT" "$(printf 'everything (default)\nexit=0')"
hq tick --session desk-2 --interrupts everything
check "desk-1's away does not hold desk-2" "$RC:$(jqo '[.[] | select(.kind == "decision" and .status == "open") | .id] | join(" ")')" "0:$D7"
hq interrupt set away --session desk-1
check "the replaced desk cannot set a rule: exit 4" "$RC" "4"
check_contains "... it is not the control session" "$ERR" "not the registered control session"
check "... and nothing changed" "$(sql_in "SELECT value::jsonb->>'session' FROM state WHERE key = 'interrupt'")" "desk-1"
add D8 issue-18 worker-h "Archive the old dashboards?"
hq tick --session desk-2 --interrupts away
check "the policy's away holds a desk that set no rule" "$RC:$OUT" "0:[]"
hq interrupt get --session desk-2 --default away
check "... and get says so" "$RC:$OUT" "0:away (default)"
sql_in "UPDATE state SET value = 'not json' WHERE key = 'interrupt'" >/dev/null
hq interrupt get --session desk-2 --json
check "an invalid stored value reads as no rule" "$RC:$(jqo '[.rule, .source] | join(",")')" "0:everything,default"
hq tick --session desk-2 --interrupts everything
check "an invalid stored value never fails a tick" "$RC:$(jqo '[.[] | .id] | join(" ")')" "0:$D8"
sql_in "UPDATE state SET value = '{\"session\": \"desk-2\", \"rule\": \"focus\", \"until\": \"soon\"}' WHERE key = 'interrupt'" >/dev/null
hq interrupt get --session desk-2
check "a focus with an unreadable time reads as no rule" "$RC:$OUT" "0:everything (default)"
hq interrupt set away --session desk-2
add D9 issue-19 worker-i "Turn on the merge queue?"
hq tick --session desk-2
check "a tick without --interrupts ignores the rule" "$RC:$(jqo '[.[] | .id] | join(" ")')" "0:$D9"
hq interrupt set everything --session desk-2
hq register-control desk-1
check "desk-1 registers again" "$RC" "0"
OUT=$(run_block "$TMP/block-desk-interrupt-get.sh")
check "the rule is the last desk's to set: desk-1 starts from the default" "$OUT" \
  "$(printf 'everything (default)\nexit=0')"
hq interrupt set everything --session desk-1
check "desk-1 sets its own" "$RC:$OUT" "0:everything"

# --- 5.3: feedback tags ------------------------------------------------------------------------
fb_parse() {
  awk -v ph="<the operator's message, verbatim>" -v m="$1" '$0 == ph { print m; next } { print }' \
    "$TMP/block-desk-feedback-parse.sh" > "$TMP/fb-parse.sh"
  run_block "$TMP/fb-parse.sh"
}
fb_write() {
  literal "$TMP/block-desk-feedback.sh" "<ref> <tag> --set <latest set_id>" "$1" > "$TMP/fb-write.sh"
  run_block "$TMP/fb-write.sh"
}
OUT=$(fb_parse "2: not important")
check "5.3 the reply parses as a tag" "$OUT" "$(printf '%s\nexit=0' '[{"ref":"2","tag":"not-important"}]')"
REF=$(printf '%s\n' "$OUT" | sed -n 1p | jq -r '.[0].ref')
TAG=$(printf '%s\n' "$OUT" | sed -n 1p | jq -r '.[0].tag')
OUT=$(fb_write "$REF $TAG --set $SET1")
check "5.3 the desk-feedback block records it" "$(printf '%s\n' "$OUT" | sed -n 1p | jq -c .)" \
  "{\"id\":\"$D2\",\"tag\":\"not-important\",\"session\":\"worker-b\",\"recorded\":true}"
check "5.3 one feedback event: the tag and the asking session" "$(feedback_rows)" "$D2:not-important:worker-b"
OUT=$(fb_write "2 not-important --set $SET1")
check "5.3 the same tag again: recorded false" "$(printf '%s\n' "$OUT" | sed -n 1p | jq -r .recorded)" "false"
check "5.3 ... and no second event" "$(feedback_rows)" "$D2:not-important:worker-b"
hq /bin/bash feedback "$D3" good-interrupt --json
check "5.3 by id" "$RC:$(jqo '[.id, .tag, .session, .recorded] | @json')" "0:[\"$D3\",\"good-interrupt\",\"worker-c\",true]"
hq feedback 1 should-have-defaulted --set "$SET1"
check "5.3 by number, plain output: the id" "$RC:$OUT" "0:$D1"
R1=$(HUMAN_QUEUE_SCHEMA="$S" bash "$HQ_T_CLI" add --kind review --repo "$REPO" --key pr-20 --question "Review PR 20?" </dev/null)
hq feedback "$R1" good-interrupt --json
check "5.3 a Review has no asking thread" "$RC:$(jqo '.session')" "0:null"
check "5.3 every tag, with its session" "$(feedback_rows)" \
  "$D2:not-important:worker-b,$D3:good-interrupt:worker-c,$D1:should-have-defaulted:worker-a,$R1:good-interrupt:null"
hq feedback 9 good-interrupt --set "$SET1"
check "5.3 a number not in the set: exit 4" "$RC" "4"
check_contains "... names the set and the number" "$ERR" "set $SET1 has no item 9"
hq feedback 2 good-interrupt --set 999999
check "5.3 a set that does not exist: exit 4" "$RC" "4"
hq feedback D-999 good-interrupt
check "5.3 an unknown id: exit 4" "$RC" "4"
check "5.3 refusals write nothing" "$(sql_in "SELECT count(*) FROM events WHERE kind = 'feedback'")" "4"
hq tick --session desk-1 --interrupts everything
check "5.3 tick does not report a tagged item again" "$RC:$(jqo '[.[] | select(.kind == "decision") | .id] | join(" ")')" "0:"

# --- 008 over a 007 store ------------------------------------------------------------------
OLD=$(sql_in "ALTER TABLE events DROP COLUMN session_id; DELETE FROM schema_migrations WHERE filename = '008_event_session.sql';")
check "setup: the store is 007's again (no error)" "$OLD" ""
hq feedback "$D4" good-interrupt
check "before 008: feedback exits 1 naming migrate" "$RC|$ERR" \
  "1|human-queue: feedback: nothing was recorded: the store is not migrated (run human-queue.sh migrate)"
check "before 008: nothing written" "$(sql_in "SELECT count(*) FROM events WHERE kind = 'feedback'")" "4"
hq interrupt get --session desk-1
check "before 008: the interrupt rule still reads" "$RC:$OUT" "0:everything"
hq migrate
check "migrate applies 008 over 007" "$RC" "0"
check_contains "... names it" "$OUT" "applied 008_event_session.sql"
check "the old feedback events keep a null session" \
  "$(sql_in "SELECT count(*) FROM events WHERE kind = 'feedback' AND session_id IS NULL")" "4"
hq feedback "$D4" good-interrupt --json
check "after 008: feedback records the session again" "$RC:$(jqo '.session')" "0:worker-d"
hq migrate
check "migrate again applies nothing" "$RC" "0"
check_absent "... 008 is not applied twice" "$OUT" "applied 008"

PUBLIC_AFTER=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
check "the public schema is unchanged" "$PUBLIC_AFTER" "$PUBLIC_BEFORE"

hq_t_finish "interrupts.test.sh"
