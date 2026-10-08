#!/usr/bin/env bash
# desk/tests/checkin.test.sh — live tests for the morning check-in and the
# adaptive reading budget (issue #1770), against the database in
# HUMAN_QUEUE_DATABASE_URL.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. Every run creates a throwaway schema named
# hq_test_<pid>_<random>_checkin, points the CLI at it with
# HUMAN_QUEUE_SCHEMA, and drops it on exit; the number of tables in `public`
# is asserted unchanged.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset, or jq or
# python3 is missing. With the URL set, an unreachable database FAILS the
# suite.
#
# Asserts (issue #1770):
#   5.1  fixture events for one day (2026-09-15, America/New_York): `stats
#        --day` matches the hand-computed values — Reviews read, Decisions
#        answered, the median minutes from shown to answered, the time at the
#        desk, Reviews an hour — and the days around it hold only their own
#   5.2  a check-in with four hours and a measured 7 Reviews an hour
#        proposes 28; before any measured day, the 30 × 20 guess; energy
#        factors and the operator's overrides; an older measured day; zero
#        hours
#   4.2  `checkin due` once a day, only for the control session; `checkin
#        set` refuses another session and stores nothing; the reserved keys;
#        desk-tick.sh prints `morning` once (when the store's clock is in the
#        morning window)
#   4.3  the budget reaches the day plan: `plan forecast --json` carries it,
#        and the proposal's clear-first batch takes at most what is left
#   4.4  the Reviews view block shows the running count against the budget
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

hq_t_require_db "checkin.test.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: checkin.test.sh — jq is not installed (the desk skill needs it)"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: checkin.test.sh — python3 is not installed (desk-tick.sh needs it)"
  exit 0
fi

HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

S="hq_test_$$_$(printf '%05d' "$RANDOM")_checkin"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-checkin-test.XXXXXX")
SKILL_DIR="$HQ_T_DESK_DIR/skill"
export TZ=America/New_York

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
  HUMAN_QUEUE_SCHEMA="$S" bash "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}
jqo() { printf '%s' "$OUT" | jq -r "$1"; }

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
with_line() { awk -v ph="$2" -v t="$3" '$0 == ph { print t; next } { print }' "$1"; }
# run_block FILE — the block as the desk session desk-1, through desk-cli.sh in
# the scratch schema.
run_block() {
  (cd "$TMP" && env -u HUMAN_QUEUE_POLICY -u TZ DESK="$HQ_T_DESK_DIR" HQ="$HQ_BIN_DIR/desk-cli.sh" \
     SID=desk-1 HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_CLOCK="2000-01-01 00:00" TMPDIR="$TMP" bash "$1") 2>&1
}

block reviews.md desk-reviews-view
block plan.md desk-plan-propose
block checkin.md desk-checkin-card
block checkin.md desk-checkin-store

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

hq migrate
check "migrate the scratch schema" "$RC" "0"
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$ERR"
  hq_t_finish "checkin.test.sh"
  exit 1
fi
echo "scratch schema: $S"

REPO=auerbachb/claude-code-config
# item VAR KIND KEY — a Decision or a Review; its id goes in VAR.
item() {
  local var="$1" kind="$2" key="$3"
  if [ "$kind" = decision ]; then
    hq add --kind decision --repo "$REPO" --key "$key" --session worker-a --question "Question $key?" \
      --option Yes --option No --default No
  else
    hq add --kind review --repo "$REPO" --key "$key" --question "feat: $key"
  fi
  check "add $var" "$RC" "0"
  printf -v "$var" '%s' "$OUT"
}
# ev ITEM KIND 'YYYY-MM-DD HH:MM' — one event at that America/New_York time.
ev() {
  sql_in "INSERT INTO events (item_id, kind, at) VALUES ('$1', '$2', ('$3'::timestamp AT TIME ZONE 'America/New_York'))" >/dev/null
}

hq register-control desk-1
check "register-control desk-1" "$RC:$OUT" "0:control session desk-1"
TODAY=$(sql_in "SELECT to_char(now() AT TIME ZONE 'America/New_York', 'YYYY-MM-DD')")
YESTERDAY=$(sql_in "SELECT to_char((now() AT TIME ZONE 'America/New_York')::date - 1, 'YYYY-MM-DD')")
DAY3=$(sql_in "SELECT to_char((now() AT TIME ZONE 'America/New_York')::date - 3, 'YYYY-MM-DD')")

# --- 4.2: due once a day, before any check-in ------------------------------------------------
hq checkin due --session desk-1 --at 00:00 --until 00:00
check "due: an empty window is never due" "$RC:$OUT:$ERR" "0::"
hq checkin due --session desk-1 --at 00:00 --json
check "4.2 due: the first call today" "$RC:$(jqo '[.due, .done, .day] | @json')" "0:[true,false,\"$TODAY\"]"
check "4.2 due: marks today" "$(sql_in "SELECT value FROM state WHERE key = 'checkin_asked'")" "$TODAY"
hq checkin due --session desk-1 --at 00:00
check "4.2 due: once a day, then done" "$RC:$OUT" "0:done $TODAY"
hq checkin due --session desk-2 --at 00:00
check "due from another session: exit 4" "$RC" "4"
check_contains "... not the control session" "$ERR" "not the registered control session"
hq state set checkin '{}'
check "state set refuses checkin" "$RC" "4"
hq state set checkin_asked "$TODAY"
check "state set refuses checkin_asked" "$RC" "4"

# desk-tick's morning step, when the store's own clock is in its window.
IN_WINDOW=$(sql_in "SELECT ((now() AT TIME ZONE 'America/New_York')::time BETWEEN '04:05' AND '17:25')::text")
if [ "$IN_WINDOW" = true ]; then
  sql_in "DELETE FROM state WHERE key = 'checkin_asked'" >/dev/null
  RC=0
  OUT=$(HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_CLOCK="$TODAY 09:00" HUMAN_QUEUE_POLICY="$HQ_T_DESK_DIR/policy.json" \
    bash "$HQ_BIN_DIR/desk-tick.sh" --session desk-1 --generation g1 --once 2>"$TMP/err" </dev/null) || RC=$?
  check "4.2 desk-tick: the first tick of the morning prints morning" "$RC:$OUT:$(cat "$TMP/err")" "0:desk-tick g1 morning:"
  RC=0
  OUT=$(HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_CLOCK="$TODAY 09:05" HUMAN_QUEUE_POLICY="$HQ_T_DESK_DIR/policy.json" \
    bash "$HQ_BIN_DIR/desk-tick.sh" --session desk-1 --generation g1 --once 2>"$TMP/err" </dev/null) || RC=$?
  check "4.2 desk-tick: once a day" "$RC:$OUT" "0:"
else
  echo "skip — desk-tick's morning line (the store's clock is outside 04:05–17:25 ET; the offline suite covers it)"
fi

# --- 5.1: one day's stats from fixture events ------------------------------------------------
for v in D1 D2 D3 D4 D5; do item "$v" decision "issue-${v#D}"; done
for v in R1 R2 R3 R8 R9; do item "$v" review "pr-${v#R}"; done
ev "$D4" shown    '2026-09-14 23:00'
ev "$R9" reviewed '2026-09-14 23:50'
ev "$D4" answered '2026-09-15 00:10'
ev "$D1" shown    '2026-09-15 09:00'
ev "$D2" shown    '2026-09-15 09:00'
ev "$D1" answered '2026-09-15 09:04'
ev "$D2" answered '2026-09-15 09:10'
ev "$R1" reviewed '2026-09-15 09:20'
ev "$R2" flagged  '2026-09-15 09:30'
ev "$R2" reviewed '2026-09-15 09:35'
ev "$D3" shown    '2026-09-15 10:58'
ev "$R3" reviewed '2026-09-15 11:00'
ev "$D3" answered '2026-09-15 11:12'
ev "$D3" feedback '2026-09-15 11:15'
ev "$D5" answered '2026-09-15 11:20'
ev "$D1" answered '2026-09-15 11:30'
ev "$R8" reviewed '2026-09-16 00:05'
# By hand, on 2026-09-15: Reviews read R1, R2 (flagged, then reviewed:
# once), R3 = 3. Decisions answered D4, D1 (twice: once), D2, D3, D5 = 5.
# Shown to first answer: D4 70 (across midnight), D1 4, D2 10, D3 14; D5 was
# never shown: median of 4, 10, 14, 70 = 12.0, over 4. Actions (answered,
# reviewed, flagged, feedback) 11, credited 2 (the first), 2 (a 534-minute
# gap), 6, 10, 10, 5, 2 (85 minutes), 12, 3, 5, 10 = 67 minutes; 3 Reviews
# in 67 minutes is 2.7 an hour.
hq stats --day 2026-09-15 --json
check "5.1 stats --json: exit 0" "$RC:$ERR" "0:"
check "5.1 stats: the day" "$(jqo .day)" "2026-09-15"
check "5.1 stats: Reviews read, Decisions answered" "$(jqo '[.reviewed, .answered] | @json')" "[3,5]"
check "5.1 stats: the median minutes from shown to answered, over four" \
  "$(jqo '[.median_shown_to_answered_min == 12, .answered_after_shown] | @json')" "[true,4]"
check "5.1 stats: the time at the desk and its actions" "$(jqo '[.active_min, .actions] | @json')" "[67,11]"
check "5.1 stats: Reviews an hour" "$(jqo '.reviews_per_hour == 2.7')" "true"
hq stats --day 2026-09-15
check "5.1 stats: one line" "$RC:$OUT" \
  "0:2026-09-15 · 3 Reviews read · 5 Decisions answered · median 12.0 min from shown to answered (4) · about 67 min at the desk · 2.7 Reviews an hour"
hq stats --day 2026-09-14 --json
check "5.1 the day before holds only its own" \
  "$(jqo '[.reviewed, .answered, .median_shown_to_answered_min, .active_min, .actions] | @json')" "[1,0,null,2,1]"
hq stats --day 2026-09-16 --json
check "5.1 the day after holds only its own" "$(jqo '[.reviewed, .answered] | @json')" "[1,0]"
hq stats --day 2026-09-10
check "a day with no events: zeros, no rate" "$RC:$OUT" \
  "0:2026-09-10 · 0 Reviews read · 0 Decisions answered · no shown-to-answered time · about 0 min at the desk"
hq stats --json
check "stats with no --day: today" "$RC:$(jqo .day)" "0:$TODAY"
hq stats --day 2026-02-30
check "stats --day not a real date: exit 4" "$RC" "4"

# --- 5.2: the budget -------------------------------------------------------------------------
hq checkin get --json
check "get: no check-in yet, no measured day in the last week" \
  "$RC:$(jqo '[.checkin, .measured, .budget, .left, .guess.items] | @json')" "0:[null,null,null,null,30]"
hq checkin set --session desk-1 --hours 4 --energy ok --json
check "5.2 no measured day: the 30 × 20 guess" \
  "$RC:$(jqo '[.checkin.budget, .checkin.lines, .checkin.basis.kind, .budget] | @json')" '0:[30,600,"guess",30]'
hq checkin set --session desk-1 --hours 4 --energy LOW --json
check "5.2 the guess, scaled by energy (low 0.7)" "$RC:$(jqo '[.checkin.budget, .checkin.energy] | @json')" '0:[21,"low"]'

# Yesterday: seven Reviews read, the first at 10:00 and then 10, 10, 10,
# 10, 10, 8 minutes apart: 2 + 58 = 60 minutes, 7 an hour.
N=0
for t in 10:00 10:10 10:20 10:30 10:40 10:50 10:58; do
  N=$((N + 1))
  item "Y$N" review "pr-y$N"
  eval "ev \"\$Y$N\" reviewed '$YESTERDAY $t'"
done
hq checkin get --json
check "5.2 get: yesterday is the measured day, 7 an hour over 60 minutes" \
  "$RC:$(jqo '[.measured.day, .measured.reviewed, .measured.active_min, (.measured.reviews_per_hour == 7)] | @json')" \
  "0:[\"$YESTERDAY\",7,60,true]"
hq checkin set --session desk-1 --hours 4 --energy ok --planned "the PRD until noon" --json
check "5.2 four hours at a measured 7 an hour proposes 28" "$RC:$(jqo '.checkin.budget')" "0:28"
check "5.2 ... from yesterday's pace" "$(jqo '[.checkin.basis.kind, .checkin.basis.day, (.checkin.basis.rate == 7)] | @json')" \
  "[\"measured\",\"$YESTERDAY\",true]"
check "4.2 stored in state: hours, energy, planned, by this desk, today" \
  "$(sql_in "SELECT value::jsonb->>'hours', value::jsonb->>'energy', value::jsonb->>'planned', value::jsonb->>'session', value::jsonb->>'day' FROM state WHERE key = 'checkin'")" \
  "4|ok|the PRD until noon|desk-1|$TODAY"
check "4.2 storing writes no event" "$(sql_in "SELECT count(*) FROM events WHERE at > now() - interval '1 hour' AND kind <> 'asked'")" "0"
hq checkin get
check "get: one line" "$RC:$OUT" "0:budget 28 Reviews today · 0 read · 28 left · 4 h · energy ok (×1)"
hq checkin set --session desk-1 --hours 4 --energy low --json
check "5.2 energy low: round(7 × 4 × 0.7) = 20" "$(jqo '.checkin.budget')" "20"
hq checkin set --session desk-1 --hours 2.5 --energy ok --json
check "5.2 2.5 hours: round(17.5) = 18" "$(jqo '[.checkin.budget, .checkin.hours] | @json')" "[18,2.5]"
hq checkin set --session desk-1 --hours 0 --energy great --json
check "5.2 zero hours: a budget of zero" "$(jqo '.checkin.budget')" "0"
hq checkin set --session desk-1 --hours 4 --energy meh --json
check "5.2 a word not in the table counts 1" "$(jqo '[.checkin.budget, .checkin.factor, .checkin.factor_known] | @json')" "[28,1,false]"
hq state set energy_factors '{"meh": 0.5, "low": "x", "BAD": 0.1, "huge": 3}'
check "the operator's factors: state set" "$RC" "0"
hq checkin set --session desk-1 --hours 4 --energy meh --json
check "5.2 the operator's factor applies" "$(jqo '[.checkin.budget, .checkin.factor_known, .factors.meh, .factors.low, (.factors | has("BAD")), (.factors | has("huge"))] | @json')" \
  "[14,true,0.5,0.7,false,false]"

hq checkin set --session desk-2 --hours 4 --energy ok
check "set from another session: exit 4" "$RC" "4"
check "... and the check-in stands" "$(sql_in "SELECT value::jsonb->>'energy' FROM state WHERE key = 'checkin'")" "meh"
hq checkin due --session desk-1 --at 00:00 --json
check "4.2 due with today's check-in stored: done" "$(jqo '[.due, .done] | @json')" "[false,true]"

# An older measured day: yesterday reads two only (under three), three days
# ago four, 10 minutes apart (2 + 30 = 32 minutes, 7.5 an hour).
sql_in "DELETE FROM events WHERE kind = 'reviewed' AND item_id NOT IN ('$Y1', '$Y2')
          AND (at AT TIME ZONE 'America/New_York')::date = '$YESTERDAY'::date" >/dev/null
ev "$Y3" reviewed "$DAY3 10:00"
ev "$Y4" reviewed "$DAY3 10:10"
ev "$Y5" reviewed "$DAY3 10:20"
ev "$Y6" reviewed "$DAY3 10:30"
hq stats --day "$YESTERDAY" --json
check "yesterday now reads two (under three)" "$(jqo .reviewed)" "2"
hq checkin set --session desk-1 --hours 2 --energy ok --json
check "5.2 the most recent day with three read: three days ago, 7.5 an hour × 2 h = 15" \
  "$(jqo '[.checkin.basis.day, (.checkin.basis.rate == 7.5), .checkin.budget, .measured.day] | @json')" "[\"$DAY3\",true,15,\"$DAY3\"]"
# A fifth Review 7 minutes on (2 + 37 = 39 minutes, 5 read: 7.69 an hour,
# shown 7.7): the budget multiplies the rate the card shows, 7.7 × 5 = 38.5,
# so 39, where the unrounded 7.69 × 5 = 38.46 would give 38.
ev "$Y7" reviewed "$DAY3 10:37"
hq checkin set --session desk-1 --hours 5 --energy ok --json
check "5.2 the budget multiplies the one-decimal rate the card shows: 7.7 × 5 = 38.5 -> 39" \
  "$RC:$(jqo '[(.checkin.basis.rate == 7.7), .checkin.budget] | @json')" "0:[true,39]"
sql_in "DELETE FROM events WHERE item_id = '$Y7' AND kind = 'reviewed'
          AND (at AT TIME ZONE 'America/New_York')::date = '$DAY3'::date" >/dev/null

# --- 4.3 and 4.4: the running count, the day plan, the Reviews view ----------------------------
hq checkin set --session desk-1 --hours 4 --energy ok --json
BUDGET=$(jqo '.checkin.budget')
item T1 review pr-t1
hq review "$T1"
check "read one today" "$RC" "0"
hq flag "$R1" --note "check the colours"
check "flag one today" "$RC" "0"
hq checkin get --json
check "4.4 the running count: two read today" "$(jqo '[.read_today, .budget, .left] | @json')" "[2,$BUDGET,$((BUDGET - 2))]"
hq plan forecast --json
check "4.3 plan forecast carries the budget" "$RC:$(jqo '[.read_today, .budget, .left] | @json')" "0:[2,$BUDGET,$((BUDGET - 2))]"
OUT=$(run_block "$TMP/block-desk-reviews-view.sh")
check_contains "4.4 the Reviews view shows the running count under its header" "$OUT" \
  "Reading budget: 2 of $BUDGET Reviews read today · $((BUDGET - 2)) left"
check "4.4 ... as its second line" "$(printf '%s\n' "$OUT" | sed -n 2p)" "Reading budget: 2 of $BUDGET Reviews read today · $((BUDGET - 2)) left"

# A budget with one left: the plan's clear-first batch takes one Review. The
# Decisions are answered first, so the ten-minute batch has room for Reviews.
for v in "$D1" "$D2" "$D3" "$D4" "$D5"; do hq answer "$v" Yes; done
check "the Decisions are answered" "$(sql_in "SELECT count(*) FROM items WHERE kind = 'decision' AND status = 'open'")" "0"
hq state set energy_factors '{"tiny": 0.1}'
hq checkin set --session desk-1 --hours 4 --energy tiny --json
check "a budget of 3 (round(7.5 × 4 × 0.1))" "$(jqo '[.checkin.budget, .left] | @json')" "[3,1]"
with_line "$TMP/block-desk-plan-propose.sh" "<the operator's message, verbatim>" "I need to work on the PRD, 30 minutes a section" \
  | with_line /dev/stdin "<the inputs agreed so far, as JSON: {} for a new plan>" '{}' \
  | literal /dev/stdin '<N>' '5' > "$TMP/propose.sh"
OUT=$(run_block "$TMP/propose.sh")
check "4.3 desk-plan-propose: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
check "4.3 the batch takes one Review: what the budget has left" \
  "$(printf '%s\n' "$OUT" | sed -n 1p | jq -c '.batch.reviews | length')" "1"
check_contains "4.3 the plan card shows the budget" "$OUT" "> Reading budget: 2 of 3 Reviews read today · 1 left."
hq checkin set --session desk-1 --hours 0 --energy ok
OUT=$(run_block "$TMP/propose.sh")
check "4.3 nothing left: no Review in the batch" "$(printf '%s\n' "$OUT" | sed -n 1p | jq -c '.batch.reviews | length')" "0"
check_contains "... and the card says it is over" "$OUT" "> Reading budget: 2 of 0 Reviews read today · 2 over."

# --- the skill's check-in blocks, run as written -----------------------------------------------
OUT=$(run_block "$TMP/block-desk-checkin-card.sh")
check "desk-checkin-card: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
check_contains "desk-checkin-card: a check-in exists, so it asks again" "$OUT" "> **Check-in again · "
check_contains "desk-checkin-card: the measured pace" "$OUT" "7.5 an hour"
REPLY='4, OK, the PRD, 30 min a section'
with_line "$TMP/block-desk-checkin-store.sh" "<the operator's reply, verbatim>" "$REPLY" > "$TMP/store.sh"
OUT=$(run_block "$TMP/store.sh")
check "desk-checkin-store: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
check "desk-checkin-store: the parsed reply first" "$(printf '%s\n' "$OUT" | sed -n 1p)" \
  '{"skip":false,"hours":4,"energy":"ok","planned":"the PRD, 30 min a section","missing":[],"plan":true}'
check_contains "4.3 desk-checkin-store: the budget, shown once" "$OUT" "> **Reading budget today: "
check "desk-checkin-store: stored the plan text as typed" \
  "$(sql_in "SELECT value::jsonb->>'planned' FROM state WHERE key = 'checkin'")" "the PRD, 30 min a section"

PUBLIC_AFTER=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
check "public schema table count unchanged" "$PUBLIC_AFTER" "$PUBLIC_BEFORE"

hq_t_finish "checkin.test.sh"
