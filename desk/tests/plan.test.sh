#!/usr/bin/env bash
# desk/tests/plan.test.sh — live tests for the day plan and the end-of-day
# sweep (issue #1784), against the database in HUMAN_QUEUE_DATABASE_URL.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. Every run creates a throwaway schema named
# hq_test_<pid>_<random>_plan, points the CLI at it with HUMAN_QUEUE_SCHEMA,
# and drops it on exit; the number of tables in `public` is asserted
# unchanged.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset, or jq or
# python3 is missing. With the URL set, an unreachable database FAILS the
# suite.
#
# Asserts (issue #1784):
#   5.1  the skill's desk-plan-propose block on "I need to work on the PRD, 30
#        minutes a section" proposes a ten-minute clear-first batch before the
#        block, and the desk-plan-store block stores it in `state` as blocks
#        (item, pace, until) with the clear-first list; plan? shows it
#   4.2  a block in force holds new Decisions (`focus … (plan)`), the release
#        after it shows them; `available` releases that block only, the next
#        block holds again; `away` wins; `plan off` releases; a plan that does
#        not parse, or another day's, holds nothing; `plan set` refuses a
#        malformed plan or another session and stores nothing; one sentence
#        (the desk-plan-revise block) revises it; the forecast's counts
#   5.2  at a simulated eod_time desk-tick.sh prints `eod` once a day, and the
#        skill's desk-sweep block renders everything still open as one
#        numbered list, opened as a set that typed replies resolve against
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

hq_t_require_db "plan.test.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: plan.test.sh — jq is not installed (the desk skill needs it)"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: plan.test.sh — python3 is not installed (desk-tick.sh needs it)"
  exit 0
fi

HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

S="hq_test_$$_$(printf '%05d' "$RANDOM")_plan"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-plan-test.XXXXXX")
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

# hq ARGS... — the CLI in the scratch schema; sets OUT, ERR, RC. STDIN_FILE
# feeds its stdin.
hq() {
  RC=0
  HUMAN_QUEUE_SCHEMA="$S" bash "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" <"${STDIN_FILE:-/dev/null}" || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}
# desk — desk-tick.sh --once in the scratch schema, its clock pinned before
# any eod_time (CLOCK overrides it) and the repo's policy (POLICY overrides).
desk() {
  RC=0
  HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_CLOCK="${CLOCK:-2000-01-01 00:00}" \
    HUMAN_QUEUE_POLICY="${POLICY:-$HQ_T_DESK_DIR/policy.json}" \
    bash "$HQ_BIN_DIR/desk-tick.sh" --session desk-1 --generation g1 --once >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}
jqo() { printf '%s' "$OUT" | jq -r "$1"; }
watermark() { sql_in "SELECT value FROM state WHERE key = 'tick_watermark'"; }
iso() { sql_in "SELECT to_char((now() + interval '$1') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"; }

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
# the scratch schema, with the clock pinned for any desk-tick it runs.
run_block() {
  (cd "$TMP" && env -u HUMAN_QUEUE_POLICY -u TZ DESK="$HQ_T_DESK_DIR" HQ="$HQ_BIN_DIR/desk-cli.sh" \
     SID=desk-1 HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_CLOCK="2000-01-01 00:00" TMPDIR="$TMP" bash "$1") 2>&1
}

for a in desk-plan-propose desk-plan-store desk-plan-revise desk-plan-show desk-plan-clear; do block plan.md "$a"; done
block sweep.md desk-sweep
block interrupts.md desk-interrupt-set
block interrupts.md desk-release

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

hq migrate
check "migrate the scratch schema" "$RC" "0"
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$ERR"
  hq_t_finish "plan.test.sh"
  exit 1
fi
echo "scratch schema: $S"

REPO=auerbachb/claude-code-config
# add VAR KEY SESSION QUESTION [FLAGS...] — a Decision; its id goes in VAR.
add() {
  local var="$1" key="$2" session="$3" question="$4"
  shift 4
  hq add --kind decision --repo "$REPO" --key "$key" --session "$session" --question "$question" "$@"
  check "add $var" "$RC" "0"
  printf -v "$var" '%s' "$OUT"
}
MENU=(--option Yes --option No --default No)

hq register-control desk-1
check "register-control desk-1" "$RC:$OUT" "0:control session desk-1"
add D1 issue-21 worker-a "Retry the flaky upload test once?" "${MENU[@]}" --parked
add D2 issue-22 worker-b "Ship the migration first?" "${MENU[@]}" --impact high
add D3 issue-23 worker-c "Rename the gadget flag?" "${MENU[@]}"
add D4 issue-24 worker-a "How should the importer handle partial rows?" --cost 1h
add D5 issue-25 worker-c "Bump the base image?" "${MENU[@]}"
R1=$(HUMAN_QUEUE_SCHEMA="$S" bash "$HQ_T_CLI" add --kind review --repo "$REPO" --key pr-31 --question "feat: widgets" </dev/null)
R2=$(HUMAN_QUEUE_SCHEMA="$S" bash "$HQ_T_CLI" add --kind review --repo "$REPO" --key pr-32 --question "fix: gadgets" </dev/null)

# --- the forecast ---------------------------------------------------------------------------
hq plan forecast --json
check "forecast: five asked by three threads, five open (one parked), two unreviewed" \
  "$RC:$(jqo '[.window_min, .asked, .threads, .open, .parked, .unreviewed] | @json')" "0:[180,5,3,5,1,2]"
sql_in "UPDATE items SET created_at = now() - interval '5 hours' WHERE id = '$D5'" >/dev/null
hq plan forecast --json --window 60
check "forecast: a Decision asked five hours ago is outside an hour's window" "$RC:$(jqo '[.asked, .threads, .open] | @json')" "0:[4,3,5]"
hq plan forecast
check_contains "forecast: one line" "$OUT" "4 asked in the last 180 min by 3 threads · 5 open Decisions (1 parked) · 2 unreviewed Reviews"
desk
check "the first tick reports the backlog in list order" "$RC:$OUT" "0:desk-tick g1 new $D1 $D2 $D5 $D3 $D4"

# --- 5.1: the plan dialogue ends in stored blocks --------------------------------------------
SENTENCE='I need to work on the PRD, 30 minutes a section'
with_line "$TMP/block-desk-plan-propose.sh" "<the operator's message, verbatim>" "$SENTENCE" \
  | with_line /dev/stdin "<the inputs agreed so far, as JSON: {} for a new plan>" '{}' \
  | literal /dev/stdin '<N>' '5' > "$TMP/propose.sh"
OUT=$(run_block "$TMP/propose.sh")
check "5.1 desk-plan-propose: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
PROPOSAL=$(printf '%s\n' "$OUT" | sed -n 1p)
# List order: the parked one, the high-impact one, then by age (D5 was
# backdated five hours above).
check "5.1 the batch: the parked one first, the menu-shaped ones, a Review, ten minutes" \
  "$(printf '%s' "$PROPOSAL" | jq -c '[.batch.ids, .batch.minutes]')" "[[\"$D1\",\"$D2\",\"$D5\",\"$D3\",\"$R1\"],10]"
check "5.1 the long-form one waits for later" "$(printf '%s' "$PROPOSAL" | jq -c '.later')" "[\"$D4\"]"
check "5.1 one block of 30 minutes, ten minutes from now" \
  "$(printf '%s' "$PROPOSAL" | jq -c '[(.blocks | length), .blocks[0].item, .blocks[0].pace]')" '[1,"the PRD","30 min a section"]'
check "5.1 ... starting after the batch" \
  "$(sql_in "SELECT '$(printf '%s' "$PROPOSAL" | jq -r '.blocks[0].start')'::timestamptz BETWEEN now() + interval '9 minutes' AND now() + interval '11 minutes'")" "t"
BATCH_LINE=$(printf '%s\n' "$OUT" | grep -n '^> 1\. Clear first, about 10 min: ' | cut -d: -f1)
BLOCK_LINE=$(printf '%s\n' "$OUT" | grep -n '^> 2\. .* ET · the PRD, section 1 · everything held\.$' | cut -d: -f1)
if [ -n "$BATCH_LINE" ] && [ -n "$BLOCK_LINE" ] && [ "$BATCH_LINE" -lt "$BLOCK_LINE" ]; then
  ok "5.1 the card lists the ten-minute batch before the block"
else
  bad "5.1 the card lists the ten-minute batch before the block (batch ${BATCH_LINE:-none}, block ${BLOCK_LINE:-none}): $OUT"
fi
check "5.1 proposing stores nothing" "$(sql_in "SELECT count(*) FROM state WHERE key = 'plan'")" "0"

INPUTS=$(printf '%s' "$PROPOSAL" | jq -c '.inputs')
with_line "$TMP/block-desk-plan-store.sh" "<the inputs of the proposal on screen, as JSON>" "$INPUTS" \
  | literal /dev/stdin '<N>' '5' > "$TMP/store.sh"
OUT=$(run_block "$TMP/store.sh")
check "5.1 desk-plan-store: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
check_contains "5.1 desk-plan-store: today's plan card" "$OUT" "> **Today's plan: the PRD, 30 min a section**"
check_contains "5.1 desk-plan-store: the batch's Review line" "$OUT" "$R1 · PR #31 · feat: widgets (title; not summarized yet)"
hq plan get --json
check "5.1 stored in state as blocks: item, pace, until" \
  "$RC:$(jqo '[.plan.blocks[] | [.item, .pace, (.until | test("Z$"))]] | @json')" '0:[["the PRD","30 min a section",true]]'
check "5.1 stored: the clear-first list and later" "$(jqo '[.plan.clear_first, .plan.later] | @json')" \
  "[[\"$D1\",\"$D2\",\"$D5\",\"$D3\",\"$R1\"],[\"$D4\"]]"
check "5.1 stored: today, by this desk" "$(jqo '[.plan.day == .today, .plan.session, .plan.version] | @json')" '[true,"desk-1",1]'
check "5.1 stored: no event" "$(sql_in "SELECT count(*) FROM events WHERE kind NOT IN ('asked')")" "0"
OUT=$(run_block "$TMP/block-desk-plan-show.sh")
check_contains "plan?: the stored plan" "$OUT" "> **Today's plan: the PRD, 30 min a section**"
hq interrupt get --session desk-1
check "before the block starts: nothing held yet" "$RC:$OUT" "0:everything (default)"

# One sentence revises it, at once.
with_line "$TMP/block-desk-plan-revise.sh" "<the operator's message, verbatim>" "plan: 4 sections" \
  | literal /dev/stdin '<N>' '5' > "$TMP/revise.sh"
OUT=$(run_block "$TMP/revise.sh")
check "revise: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
check_contains "revise: the card" "$OUT" "> **Plan revised: the PRD, 30 min a section**"
hq plan get --json
check "revise: four blocks stored, the first one's start kept" \
  "$(jqo '[(.plan.blocks | length), .plan.blocks[3].label, .plan.clear_first[0]] | @json')" "[4,\"section 4 of 4\",\"$D1\"]"

# --- 4.2: a block in force holds -------------------------------------------------------------
# plan set with times on the store's clock: block 1 runs now, block 2 later.
plan_json() { # B1_START B1_UNTIL B2_START B2_UNTIL
  printf '{"item": "the PRD", "pace": "30 min a section", "clear_first": [], "later": [], "blocks": [
    {"item": "the PRD", "label": "section 1 of 2", "pace": "30 min a section", "start": "%s", "until": "%s"},
    {"item": "the PRD", "label": "section 2 of 2", "pace": "30 min a section", "start": "%s", "until": "%s"}]}\n' "$@"
}
plan_json "$(iso '-5 minutes')" "$(iso '20 minutes')" "$(iso '25 minutes')" "$(iso '55 minutes')" > "$TMP/plan.json"
STDIN_FILE="$TMP/plan.json" hq plan set --session desk-1 --json
check "plan set: exit 0, today's plan back" "$RC:$(jqo '.plan.blocks | length')" "0:2"
hq interrupt get --session desk-1 --json
check "4.2 a block in force: focus until its end, source plan" "$RC:$(jqo '[.rule, .held, .source] | @json')" '0:["focus",true,"plan"]'
check "4.2 ... the block's end" "$(jqo '.until')" "$(sql_in "SELECT value::jsonb->'blocks'->0->>'until' FROM state WHERE key = 'plan'")"
hq interrupt get --session desk-1
check_contains "4.2 interrupts? names the plan" "$OUT" " (plan)"
add D6 issue-26 worker-d "Retire the old webhook?" "${MENU[@]}"
WM=$(watermark)
desk
check "4.2 a block holds: the tick shows nothing" "$RC:$OUT:$ERR" "0::"
check "4.2 ... and leaves the watermark" "$(watermark)" "$WM"
check "4.2 ... and stays live" "$(sql_in "SELECT (value::timestamptz > now() - interval '1 minute')::text FROM state WHERE key = 'tick_at'")" "true"

# `available` during block 1 releases block 1 only.
literal "$TMP/block-desk-interrupt-set.sh" "<away|everything>" "everything" > "$TMP/available.sh"
OUT=$(run_block "$TMP/available.sh")
check "4.2 available during a block: everything" "$(printf '%s\n' "$OUT" | sed -n 1p | jq -c '[.rule, .source]')" '["everything","desk"]'
literal "$TMP/block-desk-release.sh" "<GEN>" "g1" > "$TMP/release.sh"
OUT=$(run_block "$TMP/release.sh")
check "4.2 available: the release shows what the block held" "$OUT" "desk-tick g1 new $D6"
sleep 2
# Block 1 is over and block 2 starts now: it began after `available`.
sql_in "UPDATE state SET value = jsonb_set(jsonb_set(jsonb_set(value::jsonb,
          '{blocks,0,until}', to_jsonb(to_char((now() - interval '1 minute') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'))),
          '{blocks,0,start}', to_jsonb(to_char((now() - interval '30 minutes') AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'))),
          '{blocks,1,start}', to_jsonb(to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')))::text
        WHERE key = 'plan'" >/dev/null
hq interrupt get --session desk-1 --json
check "4.2 the next block holds again after available" "$RC:$(jqo '[.rule, .source] | @json')" '0:["focus","plan"]'
add D7 issue-27 worker-e "Pin the linter version?" "${MENU[@]}"
desk
check "4.2 ... its tick shows nothing" "$RC:$OUT:$ERR" "0::"
hq interrupt set away --session desk-1 --json
check "4.2 away wins over a block" "$RC:$(jqo '[.rule, .source] | @json')" '0:["away","desk"]'
hq interrupt set everything --session desk-1
hq interrupt set focus --session desk-1 --for 90 --json
check "4.2 a focus the desk set wins over a block, until its own end" "$RC:$(jqo '[.rule, .source] | @json')" '0:["focus","desk"]'
hq interrupt set everything --session desk-1
OUT=$(run_block "$TMP/release.sh")
check "4.2 the release after available shows the held item" "$OUT" "desk-tick g1 new $D7"
sleep 2
sql_in "UPDATE state SET value = jsonb_set(value::jsonb, '{blocks,1,start}',
          to_jsonb(to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')))::text WHERE key = 'plan'" >/dev/null
add D8 issue-28 worker-e "Archive the old dashboards?" "${MENU[@]}"
desk
check "4.2 held again in a block that started after the rule" "$RC:$OUT" "0:"
OUT=$(run_block "$TMP/block-desk-plan-clear.sh")
check "4.2 plan off: cleared" "$OUT" "$(printf '%s\nexit=0' '{"cleared": true}')"
desk
check "4.2 plan off: the next tick shows what the plan held" "$RC:$OUT" "0:desk-tick g1 new $D8"
hq interrupt get --session desk-1
check "4.2 plan off: no hold left" "$RC:$OUT" "0:everything"
OUT=$(run_block "$TMP/block-desk-plan-clear.sh")
check "plan off again: nothing to clear" "$OUT" "$(printf '%s\nexit=0' '{"cleared": false}')"

# A plan that does not parse, or another day's, holds nothing and fails nothing.
STDIN_FILE="$TMP/plan.json" hq plan set --session desk-1
sql_in "UPDATE state SET value = 'not json' WHERE key = 'plan'" >/dev/null
hq interrupt get --session desk-1 --json
check "an unreadable plan holds nothing" "$RC:$(jqo '.rule')" "0:everything"
hq tick --session desk-1 --interrupts everything
check "an unreadable plan never fails a tick" "$RC:$OUT" "0:[]"
hq plan get --json
check "an unreadable plan reads as none" "$RC:$(jqo '.plan')" "0:null"
sql_in "UPDATE state SET value = '{\"blocks\": [{\"start\": \"soon\", \"until\": \"later\"}, 7]}' WHERE key = 'plan'" >/dev/null
hq interrupt get --session desk-1
check "blocks with unreadable times hold nothing" "$RC:$OUT" "0:everything"
plan_json "$(iso '-5 minutes')" "$(iso '20 minutes')" "$(iso '25 minutes')" "$(iso '55 minutes')" > "$TMP/plan.json"
STDIN_FILE="$TMP/plan.json" hq plan set --session desk-1
# No rule of the desk's own, so only the plan can hold.
sql_in "DELETE FROM state WHERE key = 'interrupt'" >/dev/null
hq interrupt get --session desk-1 --json
check "today's plan: its block in force holds" "$RC:$(jqo '[.held, .source] | @json')" '0:[true,"plan"]'
sql_in "UPDATE state SET value = jsonb_set(value::jsonb, '{day}', '\"2000-01-01\"')::text WHERE key = 'plan'" >/dev/null
hq plan get
check "another day's plan is not today's" "$RC:$OUT" "0:no plan for today"
hq interrupt get --session desk-1 --json
check "another day's plan holds nothing, even a block still in force" \
  "$RC:$(jqo '[.rule, .held, .source] | @json')" '0:["everything",false,"default"]'
hq interrupt set everything --session desk-1
hq plan clear --session desk-1

# plan set refuses, and stores nothing.
STDIN_FILE="$TMP/plan.json" hq plan set --session desk-1
STORED=$(sql_in "SELECT value FROM state WHERE key = 'plan'")
refuse() { # LABEL NEEDLE JSON
  printf '%s\n' "$3" > "$TMP/bad.json"
  STDIN_FILE="$TMP/bad.json" hq plan set --session desk-1
  check "plan set refuses $1: exit 4" "$RC" "4"
  check_contains "plan set refuses $1: says why" "$ERR" "$2"
  check "plan set refuses $1: nothing stored" "$(sql_in "SELECT value FROM state WHERE key = 'plan'")" "$STORED"
}
B="{\"item\": \"x\", \"pace\": \"30 min\", \"start\": \"$(iso '1 minute')\", \"until\": \"$(iso '31 minutes')\"}"
refuse "not JSON" "not valid JSON" '{"blocks": ['
refuse "an array" "must be a JSON object" '[1]'
refuse "no blocks" "needs a blocks array" '{"item": "x"}'
refuse "zero blocks" "1 to 24 blocks" '{"blocks": []}'
refuse "a block that is not an object" "each block must be a JSON object" '{"blocks": [7]}'
refuse "a block with no item" "each block needs an item" "{\"blocks\": [$(printf '%s' "$B" | jq -c 'del(.item)')]}"
refuse "an item with a control character" "each block needs an item" "{\"blocks\": [$(printf '%s' "$B" | jq -c '.item = "x\u001b[31m"')]}"
refuse "a block with no pace" "each block needs a pace" "{\"blocks\": [$(printf '%s' "$B" | jq -c 'del(.pace)')]}"
refuse "a label of the wrong type" "label must be" "{\"blocks\": [$(printf '%s' "$B" | jq -c '.label = 4')]}"
refuse "an unreadable time" "ISO 8601 times with a zone" "{\"blocks\": [$(printf '%s' "$B" | jq -c '.until = "soon"')]}"
refuse "a block ending before it starts" "ends before it starts" "{\"blocks\": [$(printf '%s' "$B" | jq -c '.until = .start')]}"
refuse "overlapping blocks" "overlap or are out of order" "{\"blocks\": [$B, $B]}"
refuse "a plan already over" "every block has already ended" \
  "{\"blocks\": [$(printf '%s' "$B" | jq -c --arg s "$(iso '-2 hours')" --arg u "$(iso '-1 hour')" '.start = $s | .until = $u')]}"
refuse "a plan more than a day ahead" "more than a day ahead" \
  "{\"blocks\": [$(printf '%s' "$B" | jq -c --arg s "$(iso '2 hours')" --arg u "$(iso '25 hours')" '.start = $s | .until = $u')]}"
refuse "a block longer than a day" "longer than a day" \
  "{\"blocks\": [$(printf '%s' "$B" | jq -c --arg u "$(iso '25 hours')" '.until = $u')]}"
refuse "a clear-first entry that is no id" "item ids only" "{\"clear_first\": [\"D-1\", \"rm -rf\"], \"blocks\": [$B]}"
refuse "later as a string" "must be arrays of item ids" "{\"later\": \"D-1\", \"blocks\": [$B]}"
refuse "inputs as a list" "inputs must be a JSON object" "{\"inputs\": [1], \"blocks\": [$B]}"
STDIN_FILE="$TMP/plan.json" hq plan set --session desk-2
check "plan set from another session: exit 4" "$RC" "4"
check_contains "... not the control session" "$ERR" "not the registered control session"
hq plan clear --session desk-2
check "plan clear from another session: exit 4" "$RC" "4"
check "... and the plan stands" "$(sql_in "SELECT value FROM state WHERE key = 'plan'")" "$STORED"
hq state set plan '{}'
check "state set refuses the plan key" "$RC" "4"
hq plan clear --session desk-1

# --- 5.2: the end-of-day sweep ---------------------------------------------------------------
printf '{"eod_time": "00:00"}\n' > "$TMP/eod.json"
TODAY=$(sql_in "SELECT to_char(now() AT TIME ZONE 'America/New_York', 'YYYY-MM-DD')")
desk
check "before the sweep: a quiet tick" "$RC:$OUT:$ERR" "0::"
CLOCK="$TODAY 23:59" POLICY="$TMP/eod.json" desk
check "5.2 at a simulated eod_time: the eod line" "$RC:$OUT:$ERR" "0:desk-tick g1 eod:"
check "5.2 the store marked today" "$(sql_in "SELECT value FROM state WHERE key = 'eod_sweep'")" "$TODAY"
CLOCK="$TODAY 23:59" POLICY="$TMP/eod.json" desk
check "5.2 once a day: the next tick prints nothing" "$RC:$OUT:$ERR" "0::"
hq sweep due --session desk-1 --at 00:00 --json
check "sweep due again: done" "$RC:$(jqo '[.due, .done, .day] | @json')" "0:[false,true,\"$TODAY\"]"
hq sweep due --session desk-2 --at 00:00
check "sweep due from another session: exit 4" "$RC" "4"
hq state set eod_sweep "$TODAY"
check "state set refuses eod_sweep" "$RC" "4"

hq answer "$D2" Yes
hq review "$R2"
OUT=$(run_block "$TMP/block-desk-sweep.sh")
check "5.2 desk-sweep: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
SET_ID=$(sql_in "SELECT max(set_id) FROM sets")
EXPECTED="> **End of day · 8 items still open · set $SET_ID**
> 1. $D1 · Retry the flaky upload test once? (claude-code-config · issue-21) · parked
> 2. $D5 · Bump the base image? (claude-code-config · issue-25)
> 3. $D3 · Rename the gadget flag? (claude-code-config · issue-23)
> 4. $D4 · How should the importer handle partial rows? (claude-code-config · issue-24) · long-form
> 5. $D6 · Retire the old webhook? (claude-code-config · issue-26)
> 6. $D7 · Pin the linter version? (claude-code-config · issue-27)
> 7. $D8 · Archive the old dashboards? (claude-code-config · issue-28)
> 8. $R1 · PR #31 · feat: widgets (title; not summarized yet)

Reply by number or id any time (\`2: B\`, \`D-43: B\`, \`reviewed R-7\`). Take it to paper: say \`export\` for a numbered PDF (#1759)."
CARD=$(printf '%s\n' "$OUT" | sed -n '/^> \*\*End of day/,/Take it to paper/p')
check "5.2 everything still open as one numbered list" "$CARD" "$EXPECTED"
check "5.2 the list is a set, in that order" "$(sql_in "SELECT string_agg(position || '=' || item_id, ',' ORDER BY position) FROM sets WHERE set_id = $SET_ID")" \
  "1=$D1,2=$D5,3=$D3,4=$D4,5=$D6,6=$D7,7=$D8,8=$R1"
MD=$(printf '%s\n' "$OUT" | sed -n 's/^md=//p')
check "5.2 the paper copy is written" "$(sed -n 1p "$MD" 2>/dev/null)" "# End of day · $TODAY"
hq set-resolve "2: A" --set "$SET_ID" --json
check "5.2 a typed number resolves against the sweep's set" "$RC:$(jqo '[.answers[0].id, .answers[0].answer] | @json')" "0:[\"$D5\",\"Yes\"]"
hq sweep list
check_contains "sweep list, as lines" "$OUT" "1. $D1 Retry the flaky upload test once?"
sql_in "UPDATE items SET status = 'closed' WHERE status = 'open'" >/dev/null
OUT=$(run_block "$TMP/block-desk-sweep.sh")
check "nothing open: one line, no set" "$OUT" "$(printf 'End of day: nothing is open.\nexit=0')"
check "nothing open: no new set" "$(sql_in "SELECT max(set_id) FROM sets")" "$SET_ID"

PUBLIC_AFTER=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
check "the public schema is unchanged" "$PUBLIC_AFTER" "$PUBLIC_BEFORE"

hq_t_finish "plan.test.sh"
