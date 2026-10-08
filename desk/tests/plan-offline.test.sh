#!/usr/bin/env bash
# desk/tests/plan-offline.test.sh — offline tests for the day plan and the
# end-of-day sweep (issue #1784). Needs no database and never connects to one:
# validation and secret refusal come before any connection attempt, which the
# black-hole URL proves (a connection attempt would take the full 1.5 s).
#
# Asserts:
#   desk.jq     desk_plan_parse (the triggers, the fields, the pending modes),
#               desk_plan_merge, desk_plan_propose on fixtures — test 5.1:
#               "I need to work on the PRD, 30 minutes a section" ends with
#               blocks and a proposed order whose ten-minute clear-first batch
#               comes before the block — counts, until, for, a revision,
#               no block fitting, the parked rule; plan_card, plan_record,
#               plan_show; sweep_view (test 5.2's numbered list) on fixtures
#   CLI         plan get/set/clear/forecast and sweep due/list: every
#               malformed call exits 4 (a secret 5) without a connection
#               attempt; valid calls reach the database step; `state set`
#               refuses the new reserved keys; --help documents them
#   desk-tick   the end-of-day step against a stub CLI: not called before
#               eod_time, `sweep due --session S --at EOD` after it, `due`
#               prints `desk-tick G eod` after new and retry, `done` prints
#               nothing, a failure is one error line, a refusal from another
#               desk is `replaced`, once answered no more calls that day, the
#               policy's eod_time, a malformed HUMAN_QUEUE_CLOCK
#   skill       plan.md's and sweep.md's anchored blocks, run as written
#               against a stub CLI serving the fixtures (bash, /bin/bash 3.2,
#               zsh): the propose block prints test 5.1's card, the store
#               block hands `plan set` the record on stdin, operator text
#               passes through quoted here-documents untouched, the sweep
#               block numbers the list through set-open and writes no file
#               (the paper copy is export.md's, #1759); the router and the
#               files around it
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: plan-offline.test.sh — jq is not installed (the desk skill needs it)"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: plan-offline.test.sh — python3 is not installed (the policy parser needs it)"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-plan-offline.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

BLACKHOLE_URL="postgresql://u:pw@192.0.2.1:5432/db?sslmode=require"
FAKE_URL="postgres://hq-desk-stub@db.invalid/hq?sslmode=require"
SKILL_DIR="$HQ_T_DESK_DIR/skill"
BIN="$HQ_T_DESK_DIR/bin"
FIX="$TESTS_DIR/fixtures/plan"
FAKE_AWS="AK""IA""ABCDEFGHIJKLMNOP"
# The desk's clock: every jq call that renders times runs in it.
export TZ=America/New_York

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi
BLOCK_SHELLS="$SHELLS"
if command -v zsh >/dev/null 2>&1; then BLOCK_SHELLS="$BLOCK_SHELLS zsh"; fi

djq() { jq -L "$SKILL_DIR" "$@"; }

# ----------------------------------------------------------------- parse
printf '== desk_plan_parse\n'

# parse MESSAGE [PENDING] — [trigger, confirm, cancel, [item, pace_min,
# chunk, count, until, for_min]] as compact JSON.
parse() {
  printf '%s' "$1" | djq -c -Rs --argjson p "${2:-false}" \
    'include "desk"; desk_plan_parse($p) | [.trigger, .confirm, .cancel,
       (.fields | [.item, .pace_min, .chunk, .count, .until, .for_min])]'
}
NONE='[null,null,null,null,null,null]'

check "5.1 the sentence: a new plan for the PRD, 30 min a section" \
  "$(parse 'I need to work on the PRD, 30 minutes a section')" '["work",false,false,["the PRD",30,"section",null,null,null]]'
check "plan: start one" "$(parse 'plan')" "[\"plan\",false,false,$NONE]"
check "Plan? (any case): show it" "$(parse 'Plan?')" "[\"show\",false,false,$NONE]"
check "plan off.: clear it" "$(parse 'plan off.')" "[\"off\",false,false,$NONE]"
check "no plan: clear it" "$(parse 'no plan')" "[\"off\",false,false,$NONE]"
check "drop the plan: clear it" "$(parse 'Drop the plan')" "[\"off\",false,false,$NONE]"
check "plan: until 12:30 — a revision" "$(parse 'plan: until 12:30')" '["revise",false,false,[null,null,null,null,"12:30",null]]'
check "plan: the deck, 45 min a slide" "$(parse 'plan: the deck, 45 min a slide')" '["revise",false,false,["the deck",45,"slide",null,null,null]]'
check "plan: make it four sections — the filler is no item" \
  "$(parse 'plan: make it four sections')" '["revise",false,false,[null,null,"section",4,null,null]]'
check "this morning is for …, an hour a chapter, four chapters" \
  "$(parse 'this morning is for the PRD — an hour a chapter, four chapters')" '["work",false,false,["the PRD",60,"chapter",4,null,null]]'
check "I'm working on the deck until 3pm" \
  "$(parse "I'm working on the deck until 3pm")" '["work",false,false,["the deck",null,null,null,"3pm",null]]'
CURLY=$(printf '\342\200\231')
check "a curly apostrophe" \
  "$(parse "I${CURLY}ll work on taxes: 20 min each, 5 forms")" '["work",false,false,["taxes",20,"form",5,null,null]]'
check "for an hour and a half" \
  "$(parse 'I need to work on the PRD for an hour and a half')" '["work",false,false,["the PRD",null,null,null,null,90]]'
check "30m per section, until noon" \
  "$(parse 'I need to work on the PRD, 30m per section, until noon')" '["work",false,false,["the PRD",30,"section",null,"noon",null]]'
check "half an hour a section, 3 of them" \
  "$(parse 'plan: half an hour a section, 3 of them')" '["revise",false,false,[null,30,"section",3,null,null]]'
check "a trailing 'today' is not part of the item" \
  "$(parse 'I need to work on the PRD today')" '["work",false,false,["the PRD",null,null,null,null,null]]'
# Replies while a plan is being agreed.
check "pending: each section is about 30 minutes; four sections" \
  "$(parse 'Each section is about 30 minutes; four sections' true)" '[null,false,false,[null,30,"section",4,null,null]]'
check "pending: until 12:30" "$(parse 'until 12:30' true)" '[null,false,false,[null,null,null,null,"12:30",null]]'
check "pending: a remark is no field (never an item)" "$(parse 'What does that mean?' true)" "[null,false,false,$NONE]"
check "pending item: the reply's words are the item" \
  "$(parse 'the PRD, 30 min a section' '"item"')" '[null,false,false,["the PRD",30,"section",null,null,null]]'
check "pending: yes confirms" "$(parse 'Yes' true)" "[null,true,false,$NONE]"
check "pending: sounds right. confirms" "$(parse 'sounds right.' true)" "[null,true,false,$NONE]"
check "pending: never mind cancels" "$(parse 'never mind' true)" "[null,false,true,$NONE]"
# Not plans.
check "not pending: 4 sections reads nothing" "$(parse '4 sections')" "[null,false,false,$NONE]"
check "a question about planning is not the verb" "$(parse 'Can you plan the release?')" "[null,false,false,$NONE]"
check "'I need to fix the build' is no plan sentence" "$(parse 'I need to fix the build')" "[null,false,false,$NONE]"
check "'planning' is not plan" "$(parse 'planning')" "[null,false,false,$NONE]"
HOSTILE_ITEM='$(touch plan-pwned) `x` "q"'
check "an item full of shell text is only text" \
  "$(parse "I need to work on $HOSTILE_ITEM, 30 min a section" | jq -r '.[3][0]')" "$HOSTILE_ITEM"

# ----------------------------------------------------------------- merge
printf '== desk_plan_merge\n'
merge() { djq -c -n --argjson o "$1" --argjson n "$2" 'include "desk"; $o | desk_plan_merge($n) | del(.count_given)'; }
FIELDS='{"item": "the PRD", "pace_min": 30, "chunk": "section", "count": null, "until": null, "for_min": null}'
M1=$(merge '{}' "$FIELDS")
check "merge into nothing" "$M1" '{"item":"the PRD","pace_min":30,"chunk":"section","count":null,"until":null,"for_min":null,"end":null}'
M2=$(merge "$M1" '{"item": null, "pace_min": null, "chunk": "section", "count": 4, "until": null, "for_min": null}')
check "a count keeps the item and pace" "$(printf '%s' "$M2" | jq -c '[.item, .pace_min, .count]')" '["the PRD",30,4]'
M3=$(merge "$(printf '%s' "$M2" | jq -c '.end = "2026-10-08T15:00:00Z"')" '{"item": null, "pace_min": null, "chunk": null, "count": null, "until": "12:30", "for_min": null}')
check "an until replaces the count and the resolved end" "$(printf '%s' "$M3" | jq -c '[.count, .until, .end]')" '[null,"12:30",null]'
M4=$(merge "$(printf '%s' "$M2" | jq -c '.end = "2026-10-08T15:00:00Z"')" '{"item": null, "pace_min": 45, "chunk": null, "count": null, "until": null, "for_min": null}')
check "a pace alone keeps the extent and the end" "$(printf '%s' "$M4" | jq -c '[.pace_min, .chunk, .count, .end]')" '[45,"section",4,"2026-10-08T15:00:00Z"]'

# --------------------------------------------------------------- propose
printf '== desk_plan_propose, plan_card, plan_record\n'
# propose MESSAGE [EXTRA_JQ] — the proposal for MESSAGE over the fixtures,
# as a new plan; EXTRA_JQ edits the context first (default: none).
propose() {
  printf '%s' "$1" | djq -c -Rs --slurpfile fc "$FIX/forecast.json" --slurpfile dec "$FIX/decisions.json" \
    --slurpfile rev "$FIX/reviews.json" \
    "include \"desk\"; desk_plan_parse(false) as \$m
     | {inputs: ({} | desk_plan_merge(\$m.fields)), forecast: \$fc[0], decisions: \$dec[0],
        reviews: \$rev[0].items, gap: 5, batch_min: 10} | ${2:-.} | desk_plan_propose"
}
P=$(propose 'I need to work on the PRD, 30 minutes a section')
check "5.1 the clear-first batch: parked first, then what fits in ten minutes" \
  "$(printf '%s' "$P" | jq -c '[.batch.ids, .batch.minutes]')" '[["D-44","D-41","D-42","D-43","R-7"],10]'
check "5.1 long-form and what did not fit wait for later" "$(printf '%s' "$P" | jq -c '.later')" '["D-45","D-46"]'
check "5.1 one block, after the batch, 30 minutes" \
  "$(printf '%s' "$P" | jq -c '[(.blocks | length), .blocks[0].start, .blocks[0].until, .blocks[0].start_local, .blocks[0].label]')" \
  '[1,"2026-10-08T13:10:00Z","2026-10-08T13:40:00Z","09:10","section 1"]'
check "5.1 nothing missing, no problem" "$(printf '%s' "$P" | jq -c '[.missing, .problem]')" '[[],null]'
CARD=$(printf '%s' "$P" | djq -r 'include "desk"; plan_card')
check_contains "5.1 card: the question" "$CARD" "> **Plan: the PRD, 30 min a section — sound right?**"
check_contains "5.1 card: what is waiting" "$CARD" "> Waiting now: 6 open Decisions (1 parked) and 2 unreviewed Reviews."
check_contains "5.1 card: the forecast" "$CARD" \
  "> Forecast: 3 threads asked 6 questions in the last 3 hours, about 2 an hour — about 1 more by 09:40 ET, held until each block ends."
check_contains "5.1 card: the ten-minute batch" "$CARD" "> 1. Clear first, about 10 min: D-44, D-41, D-42, D-43, R-7."
check_contains "5.1 card: the block" "$CARD" "> 2. 09:10–09:40 ET · the PRD, section 1 · everything held."
check_contains "5.1 card: then the held set and later" "$CARD" "> 3. Then what was held, and later: D-45, D-46."
BATCH_LINE=$(printf '%s\n' "$CARD" | grep -n 'Clear first' | cut -d: -f1)
BLOCK_LINE=$(printf '%s\n' "$CARD" | grep -n '09:10–09:40 ET · the PRD' | cut -d: -f1)
if [ -n "$BATCH_LINE" ] && [ -n "$BLOCK_LINE" ] && [ "$BATCH_LINE" -lt "$BLOCK_LINE" ]; then
  ok "5.1 the ten-minute batch is listed before the block"
else
  bad "5.1 the ten-minute batch is listed before the block (batch line ${BATCH_LINE:-none}, block line ${BLOCK_LINE:-none})"
fi
check_contains "5.1 card: how to reply" "$CARD" "Reply \`yes\` to keep this plan, or change it in one sentence"
check_absent "5.1 card: the reply line never ends in a question mark" "$(printf '%s\n' "$CARD" | grep -v '^>' | grep '?$')" "?"
REC=$(printf '%s' "$P" | djq -c 'include "desk"; plan_record')
check "5.1 the record: item, pace, clear-first list, later" \
  "$(printf '%s' "$REC" | jq -c '[.item, .pace, .clear_first, .later]')" \
  '["the PRD","30 min a section",["D-44","D-41","D-42","D-43","R-7"],["D-45","D-46"]]'
check "5.1 the record: blocks of item, pace, until" \
  "$(printf '%s' "$REC" | jq -c '.blocks')" \
  '[{"item":"the PRD","pace":"30 min a section","start":"2026-10-08T13:10:00Z","until":"2026-10-08T13:40:00Z","label":"section 1"}]'
check "the record keeps the inputs, without count_given" "$(printf '%s' "$REC" | jq -c '.inputs | keys')" \
  '["chunk","count","end","for_min","item","pace_min","until"]'

P=$(propose 'I need to work on the PRD, 30 minutes a section, 4 sections')
check "four sections: four blocks, a five-minute gap between" \
  "$(printf '%s' "$P" | jq -c '[.blocks[] | "\(.start_local)-\(.until_local) \(.label)"]')" \
  '["09:10-09:40 section 1 of 4","09:45-10:15 section 2 of 4","10:20-10:50 section 3 of 4","10:55-11:25 section 4 of 4"]'
check "four sections all fit: nothing wanted beyond them" "$(printf '%s' "$P" | jq -c '.wanted')" "null"
check_absent "four sections: no shortfall line" "$(printf '%s' "$P" | djq -r 'include "desk"; plan_card')" "asked for fit"
P=$(propose 'I need to work on the PRD, 30 minutes a section, 4 sections' '.gap = 10')
check "the gap is the desk's cadence" "$(printf '%s' "$P" | jq -r '.blocks[1].start_local')" "09:50"
P=$(propose 'I need to work on the PRD until 11:30, 45 min a section')
check "until 11:30 at 45 min a section: the sections that fit" \
  "$(printf '%s' "$P" | jq -c '[.blocks[] | "\(.start_local)-\(.until_local)"]')" '["09:10-09:55","10:00-10:45"]'
P=$(propose 'I need to work on the PRD for 90 min')
check "for 90 min, no pace: one block" \
  "$(printf '%s' "$P" | jq -c '[.blocks[] | "\(.start_local)-\(.until_local)"], .pace')" '["09:10-10:40"]
"one block until 10:40"'
INPUTS90=$(printf '%s' "$P" | jq -c '.inputs')
# The same inputs (their end resolved) confirmed five minutes later.
P=$(djq -c -n --argjson in "$INPUTS90" --slurpfile fc "$FIX/forecast.json" --slurpfile dec "$FIX/decisions.json" \
      --slurpfile rev "$FIX/reviews.json" \
      'include "desk"; {inputs: $in, forecast: ($fc[0] + {now: "2026-10-08T13:05:00Z"}), decisions: $dec[0],
                       reviews: $rev[0].items, gap: 5, batch_min: 10} | desk_plan_propose')
check "for 90 min, confirmed five minutes later: still 90 minutes" \
  "$(printf '%s' "$P" | jq -c '[.blocks[] | "\(.start_local)-\(.until_local)"]')" '["09:15-10:45"]'
P=$(propose 'I need to work on the PRD, 30 min a section, until 3')
# 09:00 now: 03:00 has passed, so 15:00; ten 35-minute steps from 09:10.
check "until 3: the sooner of 3:00 and 15:00" "$(printf '%s' "$P" | jq -c '[(.blocks | length), (.blocks | last | .until_local)]')" '[10,"14:55"]'
# Tomorrow's showing of a time sits at tomorrow's offset.
check "until 9am, asked the evening before the clocks fall back: 09:00 EST" \
  "$(djq -n -r 'include "desk"; "9am" | plan_until_epoch("2026-11-01T00:00:00Z" | fromdateiso8601) | todate')" "2026-11-01T14:00:00Z"
check "until 9am, asked the evening before the clocks spring forward: 09:00 EDT" \
  "$(djq -n -r 'include "desk"; "9am" | plan_until_epoch("2026-03-08T02:00:00Z" | fromdateiso8601) | todate')" "2026-03-08T13:00:00Z"
check "until 8am, the next morning on an ordinary day" \
  "$(djq -n -r 'include "desk"; "8am" | plan_until_epoch("2026-10-08T13:00:00Z" | fromdateiso8601) | todate')" "2026-10-09T12:00:00Z"
P=$(propose 'I need to work on the PRD, 30 min a section, 30 sections')
check "30 sections: the first 24, and how many were asked for" \
  "$(printf '%s' "$P" | jq -c '[(.blocks | length), .wanted, (.blocks | last | .label)]')" '[24,30,"section 24 of 24"]'
check_contains "30 sections: the card says only 24 fit, and why" "$(printf '%s' "$P" | djq -r 'include "desk"; plan_card')" \
  "> Only 24 of the 30 asked for fit: at most 24 blocks in a plan."
P=$(propose 'I need to work on the PRD, 30 min a section, 4 sections until 10:30')
check "4 sections until 10:30: the shortfall names the time box" \
  "$(printf '%s' "$P" | jq -c '[(.blocks | length), .wanted, .shortfall]')" '[3,4,"Only 3 of the 4 asked for fit before 10:30 ET."]'
P=$(propose 'I need to work on the PRD, 60 min a section, 24 sections')
check "24 hour-long sections: the shortfall names the day" \
  "$(printf '%s' "$P" | jq -c '[(.blocks | length), .shortfall]')" '[22,"Only 22 of the 24 asked for fit within a day."]'
# Saturday 09:30 EDT before the clocks fall back: 9:15 tomorrow is 24 h 45 min
# on, past what plan set takes, so the block ends a day from now.
P=$(propose 'I need to work on the deck until 9:15am' '.forecast.now = "2026-10-31T13:30:00Z"')
check "until 9:15am across the fall-back night: the block ends a day from now" \
  "$(printf '%s' "$P" | jq -c '[(.blocks | length), .blocks[0].until, .inputs.end]')" \
  '[1,"2026-11-01T13:30:00Z","2026-11-01T13:30:00Z"]'
P=$(propose 'I need to work on the PRD, 30 min a section, until 9:05')
check "nothing fits before 9:05: a problem, no blocks" "$(printf '%s' "$P" | jq -c '[(.blocks | length), .problem]')" '[0,"no block fits before 09:05 ET"]'
check_contains "the problem card" "$(printf '%s' "$P" | djq -r 'include "desk"; plan_card')" "**No plan for the PRD: no block fits before 09:05 ET.**"
P=$(propose 'I need to work on the PRD')
check "no pace: missing pace" "$(printf '%s' "$P" | jq -c '[.missing, (.blocks | length)]')" '[["pace"],0]'
CARD=$(printf '%s' "$P" | djq -r 'include "desk"; plan_card')
check_contains "no pace: the desk asks for pace and chunking" "$CARD" "> **How fast will the PRD go, and in what chunks?**"
check_contains "no pace: the forecast is there too" "$CARD" "> Forecast: 3 threads asked 6 questions"
P=$(propose 'plan')
check "plan alone: missing item" "$(printf '%s' "$P" | jq -c '.missing')" '["item"]'
check_contains "plan alone: the desk asks what" "$(printf '%s' "$P" | djq -r 'include "desk"; plan_card')" "> **What are you working on, and how fast?**"
P=$(propose 'I need to work on the PRD, 30 minutes a section' '.batch_min = 0')
check "a zero budget: the parked Decision still goes first" "$(printf '%s' "$P" | jq -c '.batch.ids')" '["D-44"]'
P=$(propose 'I need to work on the PRD, 30 minutes a section' '.forecast.asked = 0')
check_contains "nobody asked lately" "$(printf '%s' "$P" | djq -r 'include "desk"; plan_card')" \
  "> Forecast: no thread asked anything in the last 3 hours, so few new questions are likely."
P=$(propose 'I need to work on the PRD, 30 minutes a section' '.decisions = [] | .reviews = [] | .forecast.open = 0 | .forecast.parked = 0 | .forecast.unreviewed = 0')
check "nothing open: the block starts now" "$(printf '%s' "$P" | jq -c '[.batch.ids, .blocks[0].start_local]')" '[[],"09:00"]'
CARD=$(printf '%s' "$P" | djq -r 'include "desk"; plan_card')
check_contains "nothing open: said so" "$CARD" "> 1. Nothing quick to clear first."
check_contains "nothing open: waiting nothing" "$CARD" "> Waiting now: nothing."

# A revision of a stored plan: four sections from 09:10; at 10:00 section 1 is
# over and section 2 runs.
STORED=$(propose 'I need to work on the PRD, 30 minutes a section, 4 sections' | djq -c 'include "desk"; plan_record')
revise() {
  printf '%s' "$1" | djq -c -Rs --argjson st "$STORED" --slurpfile fc "$FIX/forecast.json" --arg now "$2" \
    'include "desk"; desk_plan_parse(false) as $m
     | {inputs: ($st.inputs | desk_plan_merge($m.fields)), forecast: ($fc[0] + {now: $now}), stored: $st, gap: 5}
     | desk_plan_propose'
}
R=$(revise 'plan: 45 min a section' 2026-10-08T14:00:00Z)
check "revise mid-plan: the three sections still to do, from now" \
  "$(printf '%s' "$R" | jq -c '[.blocks[] | "\(.start_local)-\(.until_local) \(.label)"]')" \
  '["10:00-10:45 section 2 of 4","10:50-11:35 section 3 of 4","11:40-12:25 section 4 of 4"]'
check "revise: the batch and later are kept" "$(printf '%s' "$R" | jq -c '[.batch.ids, .later, .revision]')" \
  '[["D-44","D-41","D-42","D-43","R-7"],["D-45","D-46"],true]'
CARD=$(printf '%s' "$R" | djq -r 'include "desk"; plan_card')
check_contains "revise: the card says revised and stored" "$CARD" "> **Plan revised: the PRD, 45 min a section**"
check_absent "revise: no new clear-first line" "$CARD" "Clear first"
check_contains "revise: stored, no yes needed" "$CARD" "Stored. Change it again in one sentence"
R=$(revise 'plan: 2 sections' 2026-10-08T14:00:00Z)
check "revise with a count: that many still to do" \
  "$(printf '%s' "$R" | jq -c '[.blocks[] | .label]')" '["section 2 of 3","section 3 of 3"]'
# Revised twice: the record keeps the blocks already over, so the second
# revision still counts them (section 2 ran 10:00-10:45).
REC1=$(revise 'plan: 45 min a section' 2026-10-08T14:00:00Z | djq -c 'include "desk"; plan_record')
check "revise: the record keeps the block already over, first" \
  "$(printf '%s' "$REC1" | jq -c '[.blocks[] | "\(.start)-\(.until) \(.label)"]')" \
  '["2026-10-08T13:10:00Z-2026-10-08T13:40:00Z section 1 of 4","2026-10-08T14:00:00Z-2026-10-08T14:45:00Z section 2 of 4","2026-10-08T14:50:00Z-2026-10-08T15:35:00Z section 3 of 4","2026-10-08T15:40:00Z-2026-10-08T16:25:00Z section 4 of 4"]'
R=$(printf '%s' 'plan: 40 min a section' | djq -c -Rs --argjson st "$REC1" --slurpfile fc "$FIX/forecast.json" \
      'include "desk"; desk_plan_parse(false) as $m
       | {inputs: ($st.inputs | desk_plan_merge($m.fields)), forecast: ($fc[0] + {now: "2026-10-08T15:00:00Z"}), stored: $st, gap: 5}
       | desk_plan_propose')
check "revise twice: only the sections still to do, numbered for the whole plan" \
  "$(printf '%s' "$R" | jq -c '[.blocks[] | "\(.start_local)-\(.until_local) \(.label)"]')" \
  '["11:00-11:40 section 3 of 4","11:45-12:25 section 4 of 4"]'
check "revise twice: the record holds both blocks already over, then these" \
  "$(printf '%s' "$R" | djq -c 'include "desk"; [plan_record.blocks[] | .label]')" \
  '["section 1 of 4","section 2 of 4","section 3 of 4","section 4 of 4"]'
# A count in a revision is what is left; the record stores the whole count,
# so a later revision without one still plans every section left.
REC2=$(revise 'plan: 2 sections' 2026-10-08T14:00:00Z | djq -c 'include "desk"; plan_record')
check "revise with a count: the record stores the whole count" \
  "$(printf '%s' "$REC2" | jq -c '[.inputs.count, (.blocks | length)]')" '[3,3]'
R=$(printf '%s' 'plan: 45 min a section' | djq -c -Rs --argjson st "$REC2" --slurpfile fc "$FIX/forecast.json" \
      'include "desk"; desk_plan_parse(false) as $m
       | {inputs: ($st.inputs | desk_plan_merge($m.fields)), forecast: ($fc[0] + {now: "2026-10-08T14:20:00Z"}), stored: $st, gap: 5}
       | desk_plan_propose')
check "a count, then a pace: both sections left are planned" \
  "$(printf '%s' "$R" | jq -c '[.blocks[] | "\(.start_local)-\(.until_local) \(.label)"]')" \
  '["10:20-11:05 section 2 of 3","11:10-11:55 section 3 of 3"]'
R=$(revise 'plan: 45 min a section' 2026-10-08T15:30:00Z)
check "revise after every block is over: no block comes back, a problem says so" \
  "$(printf '%s' "$R" | jq -c '[(.blocks | length), .problem]')" '[0,"every section planned is done; name how many more (`2 sections`)"]'
R=$(revise 'plan: 2 sections' 2026-10-08T15:30:00Z)
check "revise after every block is over, with a count: that many more" \
  "$(printf '%s' "$R" | jq -c '[.blocks[] | .label]')" '["section 5 of 6","section 6 of 6"]'
R=$(revise 'plan: until noon' 2026-10-08T13:05:00Z)
check "revise before the first block: it keeps its start" \
  "$(printf '%s' "$R" | jq -c '[.blocks[0].start_local, (.blocks | last | .until_local), (.blocks | length)]')" '["09:10","12:00",5]'

# plan_show
SHOW=$(djq -n -r --argjson st "$STORED" 'include "desk"; {now: "2026-10-08T14:00:00Z", today: "2026-10-08", plan: ($st + {day: "2026-10-08"})} | plan_show')
check_contains "plan?: the header" "$SHOW" "> **Today's plan: the PRD, 30 min a section**"
check_contains "plan?: what to clear first" "$SHOW" "> Clear first: D-44, D-41, D-42, D-43, R-7."
check_contains "plan?: a block over" "$SHOW" "> 1. 09:10–09:40 ET · the PRD, section 1 of 4 · over"
check_contains "plan?: the block running" "$SHOW" "> 2. 09:45–10:15 ET · the PRD, section 2 of 4 · now, everything held"
check_contains "plan?: a block to come" "$SHOW" "> 3. 10:20–10:50 ET · the PRD, section 3 of 4"
check_contains "plan?: later" "$SHOW" "> Later: D-45, D-46."
check "plan?: none today" "$(djq -n -r 'include "desk"; {now: "2026-10-08T14:00:00Z", plan: null} | plan_show')" "No plan for today."

# ------------------------------------------------------------------ sweep
printf '== sweep_view\n'
SET31='{"set_id": 31, "items": [{"n": 1, "id": "D-44"}, {"n": 2, "id": "D-41"}, {"n": 3, "id": "D-45"}, {"n": 4, "id": "R-9"}]}'
VIEW=$(djq -r --argjson set "$SET31" 'include "desk"; sweep_view($set)' "$FIX/sweep.json")
EXPECTED='> **End of day · 4 items still open · set 31**
> 1. D-44 · Retry the flaky upload test once? (widgets · pr-12) · parked
> 2. D-41 · Ship the migration first? (widgets · issue-11)
> 3. D-45 · How should the importer handle partial rows? (widgets · issue-13) · long-form
> 4. R-9 · Issue #202 · Idea: export gadgets (title; not summarized yet)

Reply by number or id any time (`2: B`, `D-43: B`, `reviewed R-7`). Take it to paper: say `export` for a numbered PDF (#1759).'
check "5.2 the sweep: one numbered list, Decisions then Reviews, and the paper offer" "$VIEW" "$EXPECTED"
VIEW=$(djq -r 'include "desk"; sweep_view(null)' "$FIX/sweep.json")
check_contains "no set: numbered in list order" "$VIEW" "> 4. R-9 · Issue #202"
check_contains "no set: replies by id" "$VIEW" "Reply by id any time"
check "nothing open" "$(djq -n -r 'include "desk"; {items: [], count: 0} | sweep_view(null)')" "End of day: nothing is open."
check_contains "more than 99: the rest counted" \
  "$(djq -r 'include "desk"; .more = 3 | sweep_view(null)' "$FIX/sweep.json")" "> … and 3 more; \`sweep\` lists them once some are cleared."
check "a Review's cached line" \
  "$(djq -r 'include "desk"; .items[3].summary_l1 = "Gadgets export to paper." | sweep_lines(null) | .[3]' "$FIX/sweep.json")" \
  "4. R-9 · Issue #202 · Gadgets export to paper."

# --------------------------------------------------------------------- CLI
printf '== CLI\n'

run_cli() {
  local sh="$1"
  shift
  ELAPSED_START=$(hq_t_now)
  RC=0
  env HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" "$sh" "$HQ_T_CLI" "$@" \
    >"$TMP/out" 2>"$TMP/err" <"${STDIN_FILE:-/dev/null}" || RC=$?
  ELAPSED_END=$(hq_t_now)
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# expect_rc SHELL CODE LABEL NEEDLE ARGS... — exit CODE, one stderr line
# naming NEEDLE, nothing on stdout, no connection attempt.
expect_rc() {
  local sh="$1" code="$2" label="$3" needle="$4"
  shift 4
  run_cli "$sh" "$@"
  check "[$sh] $label: exit $code" "$RC" "$code"
  check "[$sh] $label: one stderr line" "$(hq_t_lines "$ERR")" "1"
  check "[$sh] $label: nothing on stdout" "$OUT" ""
  check_contains "[$sh] $label: names it" "$ERR" "$needle"
  if hq_t_elapsed_under "$ELAPSED_START" "$ELAPSED_END" 1.0; then
    ok "[$sh] $label (no connection attempt)"
  else
    bad "[$sh] $label took $(hq_t_elapsed "$ELAPSED_START" "$ELAPSED_END")s — it tried to connect"
  fi
}

# expect_db SHELL LABEL ARGS... — valid input reaches the database step (exit
# 7 with the URL unset).
expect_db() {
  local sh="$1" label="$2" rc=0
  shift 2
  env -u HUMAN_QUEUE_DATABASE_URL -u HUMAN_QUEUE_SCHEMA "$sh" "$HQ_T_CLI" "$@" >/dev/null 2>"$TMP/err" \
    <"${STDIN_FILE:-/dev/null}" || rc=$?
  check "[$sh] $label passes validation (exit 7, URL unset)" "$rc" "7"
}

printf '%s\n' "$REC" > "$TMP/plan.json"
printf '{"item": "token=%s", "blocks": []}\n' "abc123def456" > "$TMP/secret-plan.json"
printf '   \n' > "$TMP/blank-plan.json"
python3 -c 'import sys; sys.stdout.write("{\"item\": \"" + "x" * 17000 + "\"}")' > "$TMP/big-plan.json"

for SH in $SHELLS; do
  echo "=== shell: $SH — $("$SH" --version 2>&1 | sed -n 1p) ==="
  HELP=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" --help 2>&1)
  check_contains "[$SH] --help lists plan" "$HELP" "  plan         the operator's day plan"
  check_contains "[$SH] --help lists sweep" "$HELP" "  sweep        the end-of-day sweep"
  HELP=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" plan --help 2>&1)
  check_contains "[$SH] plan --help: set reads stdin" "$HELP" "human-queue.sh plan set --session SESSION [--json]      (the plan on stdin)"
  check_contains "[$SH] plan --help: a block holds like a focus" "$HELP" "\`focus until <the block's until>\`, source plan"
  HELP=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" sweep --help 2>&1)
  check_contains "[$SH] sweep --help: due" "$HELP" "human-queue.sh sweep due --session SESSION --at HH:MM [--json]"
  HELP=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" state --help 2>&1)
  check_contains "[$SH] state --help: plan is reserved" "$HELP" "plan             the operator's day plan"
  check_contains "[$SH] state --help: eod_sweep is reserved" "$HELP" "eod_sweep        the day the end-of-day sweep last ran"
  HELP=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" interrupt --help 2>&1)
  check_contains "[$SH] interrupt --help: the plan holds too" "$HELP" "The operator's day plan (\`plan --help\`, issue #1784) holds too"

  # --- plan --------------------------------------------------------------------
  expect_rc "$SH" 4 "plan with no action" "missing action" plan
  expect_rc "$SH" 4 "plan make" "unknown action" plan make
  expect_rc "$SH" 4 "plan --json first" "unknown option '--json'" plan --json
  expect_rc "$SH" 4 "plan set without --session" "missing --session" plan set
  expect_rc "$SH" 4 "plan clear without --session" "missing --session" plan clear
  expect_rc "$SH" 4 "plan get --session" "--session goes only with set and clear" plan get --session s1
  expect_rc "$SH" 4 "plan forecast --session" "--session goes only with set and clear" plan forecast --session s1
  expect_rc "$SH" 4 "plan get --window" "--window goes only with forecast" plan get --window 60
  expect_rc "$SH" 4 "plan set --window" "--window goes only with forecast" plan set --session s1 --window 60
  expect_rc "$SH" 4 "plan --session twice" "--session given more than once" plan clear --session a --session b
  expect_rc "$SH" 4 "plan --session with no value" "--session needs a value" plan clear --session
  expect_rc "$SH" 4 "plan a stray argument" "takes no arguments" plan get today
  expect_rc "$SH" 4 "plan an unknown flag" "unknown option '--all'" plan get --all
  for bad_window in 0 1441 x 12345 -5 ''; do
    expect_rc "$SH" 4 "plan forecast --window '$bad_window'" "--window must be a whole number of minutes from 1 to 1440" \
      plan forecast --window "$bad_window"
  done
  expect_rc "$SH" 4 "plan forecast --window twice" "--window given more than once" plan forecast --window 1 --window 2
  expect_rc "$SH" 4 "plan set with a two-line session" "single line" plan set --session "$(printf 'a\nb')"
  expect_rc "$SH" 4 "plan set with nothing on stdin" "the plan is empty" plan set --session s1
  STDIN_FILE="$TMP/blank-plan.json" expect_rc "$SH" 4 "plan set with only blank space" "the plan is empty" plan set --session s1
  STDIN_FILE="$TMP/big-plan.json" expect_rc "$SH" 4 "plan set over 16384 bytes" "larger than 16384 bytes" plan set --session s1
  STDIN_FILE="$TMP/secret-plan.json" expect_rc "$SH" 5 "plan set with a secret in it" "the plan looks like" plan set --session s1
  check_absent "[$SH] the secret is not echoed" "$OUT$ERR" "abc123def456"
  expect_rc "$SH" 5 "plan clear with a secret-shaped session" "the session id" plan clear --session "$FAKE_AWS"
  check_absent "[$SH] the secret-shaped session is not echoed" "$OUT$ERR" "$FAKE_AWS"
  expect_db "$SH" "plan get" plan get
  expect_db "$SH" "plan get --json" plan get --json
  expect_db "$SH" "plan clear" plan clear --session s1
  expect_db "$SH" "plan clear --json" plan clear --session s1 --json
  expect_db "$SH" "plan forecast" plan forecast
  expect_db "$SH" "plan forecast --window 60 --json" plan forecast --window 60 --json
  expect_db "$SH" "plan forecast --window 1440" plan forecast --window 1440
  STDIN_FILE="$TMP/plan.json" expect_db "$SH" "plan set with the record on stdin" plan set --session s1 --json

  # --- sweep -------------------------------------------------------------------
  expect_rc "$SH" 4 "sweep with no action" "missing action" sweep
  expect_rc "$SH" 4 "sweep now" "unknown action" sweep now
  expect_rc "$SH" 4 "sweep due without --session" "missing --session" sweep due --at 17:30
  expect_rc "$SH" 4 "sweep due without --at" "missing --at HH:MM" sweep due --session s1
  for bad_at in 5:30 24:00 17:60 1730 '17:30 ' 5pm '' x; do
    expect_rc "$SH" 4 "sweep due --at '$bad_at'" "--at must be a 24-hour time HH:MM" sweep due --session s1 --at "$bad_at"
  done
  expect_rc "$SH" 4 "sweep due --at twice" "--at given more than once" sweep due --session s1 --at 17:30 --at 18:00
  expect_rc "$SH" 4 "sweep list --session" "--session and --at go only with due" sweep list --session s1
  expect_rc "$SH" 4 "sweep list --at" "--session and --at go only with due" sweep list --at 17:30
  expect_rc "$SH" 4 "sweep a stray argument" "takes no arguments" sweep list everything
  expect_rc "$SH" 5 "sweep due with a secret-shaped session" "the session id" sweep due --session "$FAKE_AWS" --at 17:30
  expect_db "$SH" "sweep due" sweep due --session s1 --at 17:30
  expect_db "$SH" "sweep due --at 00:00 --json" sweep due --session s1 --at 00:00 --json
  expect_db "$SH" "sweep due --at 23:59" sweep due --session s1 --at 23:59
  expect_db "$SH" "sweep list" sweep list
  expect_db "$SH" "sweep list --json" sweep list --json

  # --- state ---------------------------------------------------------------------
  expect_rc "$SH" 4 "state set plan" "plan is reserved: use plan set" state set plan '{}'
  expect_rc "$SH" 4 "state set eod_sweep" "eod_sweep is reserved: only sweep due writes it" state set eod_sweep 2026-10-08
  expect_db "$SH" "state get plan" state get plan
  expect_db "$SH" "state set day_plan (not reserved)" state set day_plan "PRD first"
done

# --------------------------------------------------------------- desk-tick
printf '== desk-tick.sh: the end-of-day step\n'
STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR"
TSTUB="$STUB_DIR/loopcli.sh"
# Records each call; `sweep` answers from $STUB_DIR/sweep-out (exit from
# sweep-rc); control-status from status (status-sweep after a sweep refusal).
cat > "$TSTUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/args"
case "$1" in
  control-status)
    if [ -f "$STUB_DIR/refused" ] && [ -f "$STUB_DIR/status-sweep" ]; then cat "$STUB_DIR/status-sweep"
    else cat "$STUB_DIR/status"; fi ;;
  tick) cat "$STUB_DIR/tick" ;;
  wake-due) cat "$STUB_DIR/due" ;;
  sweep)
    rc=$(cat "$STUB_DIR/sweep-rc" 2>/dev/null || echo 0)
    if [ "$rc" -ne 0 ]; then
      : > "$STUB_DIR/refused"
      echo "human-queue: sweep due: this session is not the registered control session; nothing was marked (stub)" >&2
      exit "$rc"
    fi
    cat "$STUB_DIR/sweep-out" 2>/dev/null || true ;;
esac
EOF
chmod +x "$TSTUB"
OURS='{"session": "desk-1", "last_tick_at": "2026-10-08T21:00:00Z", "tick_age_seconds": 1}'
THEIRS='{"session": "desk-2", "last_tick_at": null, "tick_age_seconds": null}'
treset() {
  rm -f "$STUB_DIR"/args "$STUB_DIR"/sweep-out "$STUB_DIR"/sweep-rc "$STUB_DIR"/refused "$STUB_DIR"/status-sweep
  printf '%s\n' "$OURS" > "$STUB_DIR/status"
  printf '[]\n' > "$STUB_DIR/tick"
  printf '[]\n' > "$STUB_DIR/due"
}
sweep_calls() { grep -c '^sweep ' "$STUB_DIR/args" 2>/dev/null || true; }
# dtick SHELL CLOCK [POLICY] ARGS... — desk-tick.sh for desk-1 at CLOCK.
dtick() {
  local sh="$1" clock="$2" pol="$3"
  shift 3
  RC=0
  env STUB_DIR="$STUB_DIR" HUMAN_QUEUE_CLI="$TSTUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" \
    HUMAN_QUEUE_CLOCK="$clock" HUMAN_QUEUE_POLICY="${pol:-$TMP/no-policy.json}" \
    "$sh" "$BIN/desk-tick.sh" --session desk-1 --generation g1 "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}
NEWD='[{"id": "D-4", "kind": "decision", "status": "open"}]'
DUE='[{"id": "D-9", "session": "s9", "failures": 1, "retry": 1}]'

for SH in $SHELLS; do
  treset
  printf 'due 2026-10-08\n' > "$STUB_DIR/sweep-out"
  dtick "$SH" "2026-10-08 17:29" "" --once
  check "[$SH] before eod_time: quiet" "$RC:$OUT:$ERR" "0::"
  check "[$SH] before eod_time: the store is not asked" "$(sweep_calls)" "0"

  treset
  printf 'due 2026-10-08\n' > "$STUB_DIR/sweep-out"
  dtick "$SH" "2026-10-08 17:30" "" --once
  check "[$SH] at eod_time: due prints eod" "$RC:$OUT:$ERR" "0:desk-tick g1 eod:"
  check "[$SH] at eod_time: asks with the session and the policy's time" \
    "$(grep '^sweep ' "$STUB_DIR/args")" "sweep due --session desk-1 --at 17:30"

  treset
  printf 'due 2026-10-08\n' > "$STUB_DIR/sweep-out"
  printf '%s\n' "$NEWD" > "$STUB_DIR/tick"
  printf '%s\n' "$DUE" > "$STUB_DIR/due"
  dtick "$SH" "2026-10-08 21:15" "" --once
  check "[$SH] eod comes after new and retry" "$RC:$OUT" "0:desk-tick g1 new D-4
desk-tick g1 retry D-9
desk-tick g1 eod"

  treset
  printf 'done 2026-10-08\n' > "$STUB_DIR/sweep-out"
  dtick "$SH" "2026-10-08 18:00" "" --once
  check "[$SH] done: nothing printed" "$RC:$OUT:$ERR" "0::"
  treset
  dtick "$SH" "2026-10-08 18:00" "" --once
  check "[$SH] not yet on the store's clock: nothing printed" "$RC:$OUT:$ERR" "0::"

  printf '{"eod_time": "09:05"}\n' > "$TMP/eod-0905.json"
  treset
  printf 'due 2026-10-08\n' > "$STUB_DIR/sweep-out"
  dtick "$SH" "2026-10-08 09:04" "$TMP/eod-0905.json" --once
  check "[$SH] the policy's eod_time: not before 09:05" "$OUT:$(sweep_calls)" ":0"
  dtick "$SH" "2026-10-08 09:05" "$TMP/eod-0905.json" --once
  check "[$SH] the policy's eod_time: at 09:05" "$OUT" "desk-tick g1 eod"
  check "[$SH] the policy's eod_time reaches --at" "$(grep '^sweep ' "$STUB_DIR/args")" "sweep due --session desk-1 --at 09:05"
  printf '{"eod_time": "late"}\n' > "$TMP/eod-bad.json"
  treset
  printf 'due 2026-10-08\n' > "$STUB_DIR/sweep-out"
  dtick "$SH" "2026-10-08 17:31" "$TMP/eod-bad.json" --once
  check "[$SH] an invalid policy is the default 17:30" "$(grep '^sweep ' "$STUB_DIR/args")" "sweep due --session desk-1 --at 17:30"

  # A failing sweep is one error line, then the tick's own lines.
  treset
  printf '%s\n' "$NEWD" > "$STUB_DIR/tick"
  cat > "$STUB_DIR/sweep-rc" <<'EOF'
7
EOF
  printf '%s\n' "$OURS" > "$STUB_DIR/status-sweep"
  dtick "$SH" "2026-10-08 17:45" "" --once
  check "[$SH] sweep unreachable: an error line, then the new line" "$RC:$OUT" \
    "0:desk-tick g1 error sweep exit 7: human-queue: sweep due: this session is not the registered control session; nothing was marked (stub)
desk-tick g1 new D-4"
  # A refusal because another desk registered: replaced.
  treset
  printf '4\n' > "$STUB_DIR/sweep-rc"
  printf '%s\n' "$THEIRS" > "$STUB_DIR/status-sweep"
  dtick "$SH" "2026-10-08 17:45" "" --once
  check "[$SH] sweep refused for another desk: replaced" "$RC:$OUT" "0:desk-tick g1 replaced"
  # Refused while still the desk: an error line, never replaced.
  treset
  printf '4\n' > "$STUB_DIR/sweep-rc"
  printf '%s\n' "$OURS" > "$STUB_DIR/status-sweep"
  dtick "$SH" "2026-10-08 17:45" "" --once
  check_contains "[$SH] sweep refused but still the desk: an error line" "$OUT" "desk-tick g1 error sweep exit 4"
  check_absent "[$SH] sweep refused but still the desk: never replaced" "$OUT" "replaced"

  # The loop asks once a day: after `due` no further sweep call that day.
  treset
  printf 'due 2026-10-08\n' > "$STUB_DIR/sweep-out"
  RC=0
  env STUB_DIR="$STUB_DIR" HUMAN_QUEUE_CLI="$TSTUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" \
    HUMAN_QUEUE_CLOCK="2026-10-08 17:40" HUMAN_QUEUE_POLICY="$TMP/no-policy.json" HUMAN_QUEUE_TICK_SECONDS=1 \
    perl -e 'alarm 4; exec @ARGV' "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g2 >"$TMP/out" 2>/dev/null </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  check "[$SH] the loop: eod once" "$(printf '%s\n' "$OUT" | grep -c 'desk-tick g2 eod')" "1"
  check "[$SH] the loop: the store asked once that day" "$(sweep_calls)" "1"
  if [ "$(grep -c '^tick ' "$STUB_DIR/args")" -ge 2 ]; then ok "[$SH] the loop ran more than one cycle"; else bad "[$SH] the loop ran more than one cycle"; fi

  for bad_clock in 'now' '2026-10-08' '2026-10-08T17:30' '17:30'; do
    treset
    dtick "$SH" "$bad_clock" "" --once
    check "[$SH] HUMAN_QUEUE_CLOCK '$bad_clock': exit 4" "$RC" "4"
  done
done

# ------------------------------------------------------------------- skill
printf '== skill\n'
PLAN_MD="$SKILL_DIR/plan.md"
SWEEP_MD="$SKILL_DIR/sweep.md"
for anchor in desk-plan-parse desk-plan-propose desk-plan-store desk-plan-revise desk-plan-show desk-plan-clear; do
  RC=0
  hq_t_skill_block "$PLAN_MD" "$anchor" > "$TMP/block-$anchor.sh" 2>"$TMP/err" || RC=$?
  check "plan.md: anchor $anchor extracts" "$RC:$(cat "$TMP/err")" "0:"
done
RC=0
hq_t_skill_block "$SWEEP_MD" desk-sweep > "$TMP/block-desk-sweep.sh" 2>"$TMP/err" || RC=$?
check "sweep.md: anchor desk-sweep extracts" "$RC:$(cat "$TMP/err")" "0:"

# The stub CLI the blocks run against: it serves the fixtures, logs each
# call's arguments on one line, and keeps what `plan set` read on stdin.
HSTUB="$TMP/hq-stub.sh"
cat > "$HSTUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/hq-args"
case "$1 ${2:-}" in
  "plan forecast") cat "$FIX/forecast.json" ;;
  "list --kind")
    case "$3" in
      decision) cat "$FIX/decisions.json" ;;
      reviews) cat "$FIX/reviews.json" ;;
    esac ;;
  "plan set")
    cat > "$STUB_DIR/plan-set-stdin"
    jq -c --arg now "$PLAN_NOW" '{now: $now, today: "2026-10-08", plan: (. + {day: "2026-10-08", version: 1})}' "$STUB_DIR/plan-set-stdin" ;;
  "plan get")
    if [ -f "$STUB_DIR/stored" ]; then jq -c --arg now "$PLAN_NOW" '{now: $now, today: "2026-10-08", plan: .}' "$STUB_DIR/stored"
    else echo "{\"now\": \"$PLAN_NOW\", \"today\": \"2026-10-08\", \"plan\": null}"; fi ;;
  "plan clear") echo '{"cleared": true}' ;;
  "sweep list") cat "$FIX/sweep.json" ;;
  "set-open"*) echo '{"set_id": 31, "items": [{"n": 1, "id": "D-44"}, {"n": 2, "id": "D-41"}, {"n": 3, "id": "D-45"}, {"n": 4, "id": "R-9"}]}' ;;
esac
EOF
chmod +x "$HSTUB"

literal() { FROM="$2" TO="$3" perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$1"; }
# with_line FILE PLACEHOLDER TEXT — FILE with the line PLACEHOLDER replaced
# by TEXT (which may hold anything a shell would run).
with_line() { awk -v ph="$2" -v t="$3" '$0 == ph { print t; next } { print }' "$1"; }

mkdir -p "$TMP/run" "$TMP/blocktmp"
# run_block SHELL FILE — FILE with the prelude's DESK, HQ, and SID, in
# $TMP/run, with its own TMPDIR, and TZ unset (the blocks set it themselves).
run_block() {
  rm -f "$STUB_DIR/hq-args"
  (cd "$TMP/run" && env -u TZ DESK="$HQ_T_DESK_DIR" HQ="$HSTUB" SID="desk-1" STUB_DIR="$STUB_DIR" FIX="$FIX" \
     PLAN_NOW="2026-10-08T13:00:00Z" TMPDIR="$TMP/blocktmp" "$1" "$2") 2>&1
}
hq_args() { cat "$STUB_DIR/hq-args" 2>/dev/null; }
leftovers() { find "$TMP/blocktmp" -mindepth 1 | wc -l | tr -d ' '; }

SENTENCE='I need to work on the PRD, 30 minutes a section'
with_line "$TMP/block-desk-plan-parse.sh" "<the operator's message, verbatim>" "$SENTENCE" \
  | literal /dev/stdin '<false|true|"item">' 'false' > "$TMP/parse.sh"
with_line "$TMP/block-desk-plan-parse.sh" "<the operator's message, verbatim>" "I need to work on $HOSTILE_ITEM" \
  | literal /dev/stdin '<false|true|"item">' 'false' > "$TMP/parse-hostile.sh"
with_line "$TMP/block-desk-plan-propose.sh" "<the operator's message, verbatim>" "$SENTENCE" \
  | with_line /dev/stdin "<the inputs agreed so far, as JSON: {} for a new plan>" '{}' \
  | literal /dev/stdin '<N>' '5' > "$TMP/propose.sh"
with_line "$TMP/block-desk-plan-propose.sh" "<the operator's message, verbatim>" "I need to work on $HOSTILE_ITEM, 30 min a section" \
  | with_line /dev/stdin "<the inputs agreed so far, as JSON: {} for a new plan>" '{}' \
  | literal /dev/stdin '<N>' '5' > "$TMP/propose-hostile.sh"
with_line "$TMP/block-desk-plan-propose.sh" "<the operator's message, verbatim>" "4 sections" \
  | with_line /dev/stdin "<the inputs agreed so far, as JSON: {} for a new plan>" \
      '{"item": "the PRD", "pace_min": 30, "chunk": "section", "count": null, "until": null, "for_min": null, "end": null}' \
  | literal /dev/stdin '<N>' '5' > "$TMP/propose-reply.sh"
INPUTS='{"item":"the PRD","pace_min":30,"chunk":"section","count":null,"until":null,"for_min":null,"end":null}'
with_line "$TMP/block-desk-plan-store.sh" "<the inputs of the proposal on screen, as JSON>" "$INPUTS" \
  | literal /dev/stdin '<N>' '5' > "$TMP/store.sh"
with_line "$TMP/block-desk-plan-revise.sh" "<the operator's message, verbatim>" "plan: 45 min a section" \
  | literal /dev/stdin '<N>' '5' > "$TMP/revise.sh"

for SH in $BLOCK_SHELLS; do
  OUT=$(run_block "$SH" "$TMP/parse.sh")
  check "[$SH] desk-plan-parse: the sentence's trigger and fields" "$OUT" \
    "$(printf '%s\nexit=0' '{"confirm":false,"cancel":false,"trigger":"work","fields":{"item":"the PRD","pace_min":30,"chunk":"section","count":null,"until":null,"for_min":null}}')"
  OUT=$(run_block "$SH" "$TMP/parse-hostile.sh")
  check "[$SH] desk-plan-parse: a hostile item arrives as typed" "$(printf '%s\n' "$OUT" | sed -n 1p | jq -r '.fields.item')" "$HOSTILE_ITEM"
  check "[$SH] desk-plan-parse: nothing in it ran" "$(find "$TMP/run" -name '*pwned*' | wc -l | tr -d ' ')" "0"
  check "[$SH] desk-plan-parse: removes its file" "$(leftovers)" "0"

  OUT=$(run_block "$SH" "$TMP/propose.sh")
  check "[$SH] desk-plan-propose: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
  check "[$SH] desk-plan-propose: forecast, then the two lists" "$(hq_args | tr '\n' '|')" \
    "plan forecast --json|list --kind decision --status open --json|list --kind reviews --unreviewed --json|"
  check "[$SH] 5.1 desk-plan-propose: the proposal's batch and block" \
    "$(printf '%s\n' "$OUT" | sed -n 1p | jq -c '[.batch.ids, .blocks[0].start_local, .blocks[0].until_local]')" \
    '[["D-44","D-41","D-42","D-43","R-7"],"09:10","09:40"]'
  check_contains "[$SH] 5.1 desk-plan-propose: the card's batch line" "$OUT" "> 1. Clear first, about 10 min: D-44, D-41, D-42, D-43, R-7."
  check_contains "[$SH] 5.1 desk-plan-propose: the card's block line, in ET" "$OUT" "> 2. 09:10–09:40 ET · the PRD, section 1 · everything held."
  check "[$SH] desk-plan-propose: removes its files" "$(leftovers)" "0"
  OUT=$(run_block "$SH" "$TMP/propose-hostile.sh")
  check "[$SH] desk-plan-propose: a hostile item arrives as typed" \
    "$(printf '%s\n' "$OUT" | sed -n 1p | jq -r '.inputs.item')" "$HOSTILE_ITEM"
  check "[$SH] desk-plan-propose: nothing in it ran" "$(find "$TMP/run" -name '*pwned*' | wc -l | tr -d ' ')" "0"
  OUT=$(run_block "$SH" "$TMP/propose-reply.sh")
  check "[$SH] desk-plan-propose: a reply changes the plan being agreed" \
    "$(printf '%s\n' "$OUT" | sed -n 1p | jq -c '[.inputs.item, .inputs.count, (.blocks | length)]')" '["the PRD",4,4]'

  rm -f "$STUB_DIR/plan-set-stdin"
  OUT=$(run_block "$SH" "$TMP/store.sh")
  check "[$SH] desk-plan-store: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
  check "[$SH] desk-plan-store: plan set as this session" "$(hq_args | grep '^plan set')" "plan set --session desk-1 --json"
  check "[$SH] 5.1 desk-plan-store: plan set read the blocks and the clear-first list" \
    "$(jq -c '[.item, .pace, .clear_first, [.blocks[] | .item, .pace, .until]]' "$STUB_DIR/plan-set-stdin" 2>/dev/null)" \
    '["the PRD","30 min a section",["D-44","D-41","D-42","D-43","R-7"],["the PRD","30 min a section","2026-10-08T13:40:00Z"]]'
  check "[$SH] desk-plan-store: the batch's ids first" "$(printf '%s\n' "$OUT" | sed -n 1p)" \
    '{"batch_decisions":["D-44","D-41","D-42","D-43"],"batch_reviews":["R-7"]}'
  check_contains "[$SH] desk-plan-store: today's plan" "$OUT" "> 1. 09:10–09:40 ET · the PRD, section 1"
  check_contains "[$SH] desk-plan-store: the batch's Review line" "$OUT" "R-7 · PR #101 · Widgets become reviewable from the desk."
  check "[$SH] desk-plan-store: removes its files" "$(leftovers)" "0"

  rm -f "$STUB_DIR/stored"
  OUT=$(run_block "$SH" "$TMP/revise.sh")
  check "[$SH] desk-plan-revise: no plan today" "$OUT" "$(printf 'no-plan\nexit=3')"
  propose 'I need to work on the PRD, 30 minutes a section, 4 sections' | djq -c 'include "desk"; plan_record' > "$STUB_DIR/stored"
  rm -f "$STUB_DIR/plan-set-stdin"
  OUT=$(run_block "$SH" "$TMP/revise.sh")
  check "[$SH] desk-plan-revise: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
  check "[$SH] desk-plan-revise: stored at once" "$(jq -c '[.blocks[] | .pace] | unique' "$STUB_DIR/plan-set-stdin" 2>/dev/null)" '["45 min a section"]'
  check_contains "[$SH] desk-plan-revise: the revised card" "$OUT" "> **Plan revised: the PRD, 45 min a section**"
  rm -f "$STUB_DIR/stored"

  OUT=$(run_block "$SH" "$TMP/block-desk-plan-show.sh")
  check "[$SH] desk-plan-show: none" "$OUT" "$(printf 'No plan for today.\nexit=0')"
  OUT=$(run_block "$SH" "$TMP/block-desk-plan-clear.sh")
  check "[$SH] desk-plan-clear: the command" "$(hq_args)" "plan clear --session desk-1 --json"

  OUT=$(run_block "$SH" "$TMP/block-desk-sweep.sh")
  check "[$SH] desk-sweep: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
  check "[$SH] 5.2 desk-sweep: set-open numbers the list in its order" "$(hq_args | grep '^set-open')" \
    "set-open D-44 D-41 D-45 R-9 --json"
  check_contains "[$SH] 5.2 desk-sweep: the header" "$OUT" "> **End of day · 4 items still open · set 31**"
  check_contains "[$SH] 5.2 desk-sweep: item 1" "$OUT" "> 1. D-44 · Retry the flaky upload test once? (widgets · pr-12) · parked"
  check_contains "[$SH] 5.2 desk-sweep: item 4" "$OUT" "> 4. R-9 · Issue #202 · Idea: export gadgets (title; not summarized yet)"
  check_contains "[$SH] desk-sweep: the paper offer" "$OUT" "Take it to paper: say \`export\` for a numbered PDF (#1759)."
  # The paper copy is export.md's now (#1759): the sweep writes no file.
  check_absent "[$SH] desk-sweep: no Markdown copy of its own" "$OUT" "md="
  check "[$SH] desk-sweep: removes its temp files and writes none" "$(leftovers)" "0"
done

# The router and the files around it.
contract() {
  local name="$1" text="$2" needle
  while IFS= read -r needle; do
    [ -n "$needle" ] || continue
    check_contains "$name: $needle" "$text" "$needle"
  done
}
contract SKILL.md "$(cat "$SKILL_DIR/SKILL.md")" <<'NEEDLES'
| `plan.md` |
| `sweep.md` |
| `desk-tick <GEN> eod` |
**A plan verb** as the whole message — `plan`, `plan?`, `plan off`, or `plan: …` — → load `plan.md`
**`sweep`** → load `sweep.md`
6. **A plan sentence**
7. Any other message is ordinary conversation.
(#1784)
NEEDLES
check_absent "SKILL.md: no 'no verb here yet' for #1784" "$(cat "$SKILL_DIR/SKILL.md")" "have no verb here yet"
contract plan.md "$(cat "$PLAN_MD")" <<'NEEDLES'
**Plain text only, never AskUserQuestion.**
<<'DESK_PLAN_MSG'
<<'DESK_PLAN_PREV'
'include "desk"; desk_plan_parse($pending)'
"$HQ" plan set --session "$SID" --json < "$PLAN_REC"
releases **that block only**
`plan off` ends every hold the plan made.
NEEDLES
contract sweep.md "$(cat "$SWEEP_MD")" <<'NEEDLES'
**one numbered list**
"$HQ" sweep list --json
'include "desk"; sweep_view($set[0])'
#1759
NEEDLES
contract interrupts.md "$(cat "$SKILL_DIR/interrupts.md")" <<'NEEDLES'
| a block of the day plan |
`available` said during a block releases that block only
NEEDLES
contract longform.md "$(cat "$SKILL_DIR/longform.md")" <<'NEEDLES'
A plan sentence (`I need to work on …`) is this part's answer, never a plan.
and so is a `desk-tick <GEN> eod` event
NEEDLES
contract discuss.md "$(cat "$SKILL_DIR/discuss.md")" <<'NEEDLES'
A plan sentence (`I need to work on …`) is a follow-up here, never a plan.
NEEDLES

hq_t_finish plan-offline.test.sh
