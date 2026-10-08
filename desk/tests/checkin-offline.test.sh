#!/usr/bin/env bash
# desk/tests/checkin-offline.test.sh — offline tests for the morning check-in
# and the adaptive reading budget (issue #1770). Needs no database and never
# connects to one: validation and secret refusal come before any connection
# attempt, which the black-hole URL proves (a connection attempt would take
# the full 1.5 s).
#
# Asserts:
#   desk.jq     checkin_parse (the reply grammar: separators, spaces, skip,
#               hours as typed, energy as one word, the plan kept whole),
#               checkin_planned_plan, checkin_card and budget_card on
#               tests/fixtures/checkin/ (measured, guess, over, an unknown
#               energy word, asking again), budget_line, reviews_view_budget
#               (4.4: the running count under the Reviews view's header, and
#               exactly reviews_view without a check-in), desk_plan_propose's
#               cap (4.3: at most `left` Reviews in the clear-first batch) and
#               the plan card's budget line
#   CLI         stats and checkin: every malformed call exits 4 (a secret 5)
#               without a connection attempt; valid calls reach the database
#               step; `state set` refuses checkin and checkin_asked; --help
#               documents them
#   desk-tick   the morning step against a stub CLI: not called before 04:00
#               or from eod_time on, `checkin due --session S --at 04:00
#               --until EOD` in between, `due` prints `desk-tick G morning`
#               before new and retry, `done` prints nothing, a failure is one
#               error line, a refusal from another desk is `replaced`, the
#               policy's eod_time, once answered no more calls that day
#   skill       checkin.md's anchored blocks, run as written against a stub
#               CLI (bash, /bin/bash 3.2, zsh): the card, the store block
#               (the parsed reply reaches `checkin set`, operator text passes
#               through a quoted here-document untouched, skip and a
#               non-reply store nothing), budget?, and reviews.md's view block
#               with and without a check-in; the router names checkin.md
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: checkin-offline.test.sh — jq is not installed (the desk skill needs it)"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: checkin-offline.test.sh — python3 is not installed (desk-tick.sh needs it)"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-checkin-offline.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

BLACKHOLE_URL="postgresql://u:pw@192.0.2.1:5432/db?sslmode=require"
FAKE_URL="postgres://hq-desk-stub@db.invalid/hq?sslmode=require"
SKILL_DIR="$HQ_T_DESK_DIR/skill"
BIN="$HQ_T_DESK_DIR/bin"
FIX="$TESTS_DIR/fixtures/checkin"
PFIX="$TESTS_DIR/fixtures/plan"
FAKE_AWS="AK""IA""ABCDEFGHIJKLMNOP"
export TZ=America/New_York

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi
BLOCK_SHELLS="$SHELLS"
if command -v zsh >/dev/null 2>&1; then BLOCK_SHELLS="$BLOCK_SHELLS zsh"; fi

djq() { jq -L "$SKILL_DIR" "$@"; }

# ----------------------------------------------------------------- parse
printf '== checkin_parse\n'

# parse MESSAGE — [skip, hours, energy, planned, missing] as compact JSON.
parse() {
  printf '%s' "$1" | djq -c -Rs 'include "desk"; checkin_parse | [.skip, .hours, .energy, .planned, .missing]'
}
check "commas: hours, energy, plan" "$(parse '4, ok, the PRD until noon')" '[false,4,"ok","the PRD until noon",[]]'
check "the plan keeps its own commas" "$(parse '4, ok, the PRD, 30 min a section')" '[false,4,"ok","the PRD, 30 min a section",[]]'
check "semicolons, no plan" "$(parse '4h; tired')" '[false,4,"tired",null,[]]'
check "line breaks" "$(parse "$(printf '4\nOK\nnothing')")" '[false,4,"ok",null,[]]'
check "spaces only" "$(parse '4h ok the PRD, 30 min a section')" '[false,4,"ok","the PRD, 30 min a section",[]]'
check "spaces: hours in words" "$(parse 'four and a half hours great')" '[false,4.5,"great",null,[]]'
check "hours: 4 hours" "$(parse '4 hours, ok')" '[false,4,"ok",null,[]]'
check "hours: 4.5" "$(parse '4.5, ok')" '[false,4.5,"ok",null,[]]'
check "hours: half an hour" "$(parse 'Half an hour, low')" '[false,0.5,"low",null,[]]'
check "hours: an hour" "$(parse 'an hour, low')" '[false,1,"low",null,[]]'
check "hours: 90 min" "$(parse '90 min; high; meetings 11-12')" '[false,1.5,"high","meetings 11-12",[]]'
check "hours: about 3h at the desk" "$(parse 'about 3h at the desk, ok')" '[false,3,"ok",null,[]]'
check "hours: none" "$(parse 'none, low, none')" '[false,0,"low",null,[]]'
check "hours: 0" "$(parse '0, ok')" '[false,0,"ok",null,[]]'
check "hours: over 16 is not hours" "$(parse '17, ok')" '[false,null,"ok",null,["hours"]]'
check "energy: the last of a few words, lowercase" "$(parse '4, Pretty Tired., none')" '[false,4,"tired",null,[]]'
check "energy: a sentence is not one word" "$(parse '4, I am feeling rather low today')" '[false,4,null,null,["energy"]]'
check "energy: digits are not a word" "$(parse '4, 5')" '[false,4,null,null,["energy"]]'
check "planned: a prefix is dropped" "$(parse '2.5, great, plan: the deck until 12:30')" '[false,2.5,"great","the deck until 12:30",[]]'
check "planned: line breaks inside it become spaces" "$(parse "$(printf '4, ok, the PRD\nthen email')")" '[false,4,"ok","the PRD then email",[]]'
check "skip" "$(parse 'skip')" '[true,null,null,null,[]]'
check "skip: not today." "$(parse 'Not today.')" '[true,null,null,null,[]]'
check "hours alone: energy missing" "$(parse '4')" '[false,4,null,null,["energy"]]'
check "a typed reply is not a check-in" "$(parse '1: A, 2: C')" '[false,null,"c",null,["hours"]]'
check "a plan sentence is not a check-in" "$(parse 'I need to work on the PRD, 30 min a section')" '[false,null,null,null,["hours","energy"]]'
check "an answer is not a check-in" "$(parse 'yes')" '[false,null,null,null,["hours","energy"]]'

planplan() { printf '%s' "$1" | djq -c -Rs 'include "desk"; checkin_planned_plan'; }
check "planned as a plan: an item and a pace" "$(planplan 'the PRD, 30 min a section')" "true"
check "planned as a plan: an item and an until" "$(planplan 'the deck until 12:30')" "true"
check "planned as a plan: meetings until noon" "$(planplan 'meetings until noon')" "true"
check "planned, not a plan: no pace or extent" "$(planplan 'meetings 11-12')" "false"
check "planned, not a plan: nothing planned" "$(djq -c -n 'include "desk"; null | checkin_planned_plan')" "false"

# ----------------------------------------------------------------- cards
printf '== cards\n'
card() { djq -r 'include "desk"; checkin_card' "$FIX/$1.json"; }
bcard() { djq -r 'include "desk"; budget_card' "$FIX/$1.json"; }

check "checkin_card: the morning card" "$(card get-none)" "> **Morning check-in · Thu Oct 8**
> Yesterday: 22 Reviews read in about 3 h at the desk, 7.3 an hour; 6 Decisions answered, median 4 min from shown to answered.
> Waiting now: 18 unreviewed Reviews.
> 1. Hours at the desk today?
> 2. Energy, in one word? (for example low, ok, high)
> 3. Anything planned? (a piece of work and its pace, meetings, or none)

Reply in one line, \`hours, energy, plan\`: \`4, ok, the PRD until noon\`. \`skip\` leaves today without a reading budget."
check "checkin_card: asked again, it says what is stored" "$(card get-set)" "> **Check-in again · Thu Oct 8**
> Yesterday: 7 Reviews read in about 1 h at the desk, 7 an hour.
> Now: 4 h, energy ok, budget 28 (9 read). A new answer replaces it.
> Waiting now: 18 unreviewed Reviews.
> 1. Hours at the desk today?
> 2. Energy, in one word? (for example low, ok, high)
> 3. Anything planned? (a piece of work and its pace, meetings, or none)

Reply in one line, \`hours, energy, plan\`: \`4, ok, the PRD until noon\`. \`skip\` keeps the one stored."
check_contains "checkin_card: no measured day yet, the guess" "$(card get-guess)" \
  "> No measured pace yet: no day in the last 7 has 3 Reviews read, so today starts from the 30 × 20 guess."
OLDER=$(jq -c '.measured.day = "2026-10-05"' "$FIX/get-none.json")
check_contains "checkin_card: an older measured day is named" \
  "$(printf '%s' "$OLDER" | djq -r 'include "desk"; checkin_card')" "> Last measured day, Mon Oct 5: 22 Reviews read"

check "budget_card: measured, shown once" "$(bcard get-set)" "> **Reading budget today: 28 Reviews (~560 lines at level 2)**
> Yesterday's pace, 7 an hour × 4 h × energy ok (1) = 28.
> 18 waiting now · 9 read so far today.
> Planned: the PRD until noon

\`reviews\` keeps the running count against it; \`check-in\` changes the hours or the energy; \`budget?\` shows this again."
check "budget_card: the guess, an unknown word, over" "$(bcard get-guess | sed -n 1,3p)" "> **Reading budget today: 30 Reviews (~600 lines at level 2)**
> The starting guess, 30 Reviews (no measured pace yet) × energy meh (not in the table: 1) = 30.
> 0 waiting now · 33 read so far today · 3 over."
ZERO=$(jq -c '.checkin.hours = 0 | .checkin.budget = 0 | .checkin.lines = 0' "$FIX/get-set.json")
check_contains "budget_card: zero hours" "$(printf '%s' "$ZERO" | djq -r 'include "desk"; budget_card')" "> 0 h at the desk today: nothing to read."
check_contains "budget_card: zero hours, no lines" "$(printf '%s' "$ZERO" | djq -r 'include "desk"; budget_card')" "> **Reading budget today: 0 Reviews**"
OLDB=$(jq -c '.checkin.basis.day = "2026-10-05" | .checkin.basis.rate = 6.5 | .checkin.factor = 0.7 | .checkin.energy = "low"' "$FIX/get-set.json")
check_contains "budget_card: an older day's pace, a factor" "$(printf '%s' "$OLDB" | djq -r 'include "desk"; budget_card')" \
  "> The pace on Mon Oct 5, 6.5 an hour × 4 h × energy low (0.7) = 28."
check "budget_card: no check-in" "$(bcard get-none)" "No check-in today, so no reading budget. Say \`check-in\` to set one."

bline() { djq -r 'include "desk"; [budget_line] | .[0] // "(none)"' "$@"; }
check "budget_line: left" "$(bline "$FIX/get-set.json")" "Reading budget: 9 of 28 Reviews read today · 19 left"
check "budget_line: over" "$(bline "$FIX/get-guess.json")" "Reading budget: 33 of 30 Reviews read today · 3 over"
check "budget_line: none without a check-in" "$(bline "$FIX/get-none.json")" "(none)"
check "budget_line: none on a forecast without one" "$(bline "$PFIX/forecast.json")" "(none)"

# --- 4.4: the Reviews view's running count ----------------------------------
printf '== reviews view\n'
PLAIN=$(djq -r 'include "desk"; reviews_view' "$PFIX/reviews.json")
check "4.4 without a check-in: exactly the view" \
  "$(djq -r --slurpfile c "$FIX/get-none.json" 'include "desk"; reviews_view_budget($c[0])' "$PFIX/reviews.json")" "$PLAIN"
check "4.4 with no check-in JSON at all: exactly the view" \
  "$(djq -r 'include "desk"; reviews_view_budget(null)' "$PFIX/reviews.json")" "$PLAIN"
VIEW=$(djq -r --slurpfile c "$FIX/get-set.json" 'include "desk"; reviews_view_budget($c[0])' "$PFIX/reviews.json")
check "4.4 the running count under the header" "$(printf '%s\n' "$VIEW" | sed -n 1,3p)" "Reviews · 2 unreviewed · ~40 lines at level 2
Reading budget: 9 of 28 Reviews read today · 19 left"
check "4.4 ... then the view's blank line" "$(printf '%s\n' "$VIEW" | sed -n 3p)" ""
check "4.4 ... and the rest of the view unchanged" "$(printf '%s\n' "$VIEW" | sed 2d)" "$PLAIN"
check "4.4 nothing unreviewed: the count after the one line" \
  "$(jq -c '.items = [] | .count = 0' "$PFIX/reviews.json" | djq -r --slurpfile c "$FIX/get-set.json" 'include "desk"; reviews_view_budget($c[0])')" \
  "No unreviewed Reviews.
Reading budget: 9 of 28 Reviews read today · 19 left."

# --- 4.3: the day plan's cap -------------------------------------------------
printf '== day plan\n'
# capped LEFT — the batch's Reviews for a new plan with no Decisions waiting,
# the forecast's `left` set to LEFT (null: no check-in today).
capped() {
  printf '%s' 'I need to work on the PRD, 30 minutes a section' \
    | djq -c -Rs --slurpfile fc "$PFIX/forecast.json" --slurpfile rev "$PFIX/reviews.json" --argjson left "$1" \
      'include "desk"; desk_plan_parse(false) as $m
       | {inputs: ({} | desk_plan_merge($m.fields)),
          forecast: ($fc[0] + (if $left == null then {} else {budget: 10, read_today: (10 - $left), left: $left} end)),
          decisions: [], reviews: $rev[0].items, gap: 5, batch_min: 10} | desk_plan_propose | .batch.reviews'
}
check "4.3 no check-in today: the batch as before" "$(capped null)" '["R-7","R-9"]'
check "4.3 one left: one Review" "$(capped 1)" '["R-7"]'
check "4.3 none left: no Review" "$(capped 0)" '[]'
check "4.3 over the budget: no Review" "$(capped -3)" '[]'
check "4.3 plenty left: what fits in ten minutes" "$(capped 25)" '["R-7","R-9"]'
CARD=$(printf '%s' 'I need to work on the PRD, 30 minutes a section' \
  | djq -r -Rs --slurpfile fc "$PFIX/forecast.json" --slurpfile dec "$PFIX/decisions.json" --slurpfile rev "$PFIX/reviews.json" \
      'include "desk"; desk_plan_parse(false) as $m
       | {inputs: ({} | desk_plan_merge($m.fields)), forecast: ($fc[0] + {budget: 28, read_today: 9, left: 19}),
          decisions: $dec[0], reviews: $rev[0].items, gap: 5, batch_min: 10} | desk_plan_propose | plan_card')
check_contains "4.3 the plan card shows the budget under what waits" "$CARD" "> Waiting now: 6 open Decisions (1 parked) and 2 unreviewed Reviews.
> Reading budget: 9 of 28 Reviews read today · 19 left.
> Forecast:"
CARD=$(printf '%s' 'I need to work on the PRD, 30 minutes a section' \
  | djq -r -Rs --slurpfile fc "$PFIX/forecast.json" --slurpfile dec "$PFIX/decisions.json" --slurpfile rev "$PFIX/reviews.json" \
      'include "desk"; desk_plan_parse(false) as $m
       | {inputs: ({} | desk_plan_merge($m.fields)), forecast: $fc[0],
          decisions: $dec[0], reviews: $rev[0].items, gap: 5, batch_min: 10} | desk_plan_propose | plan_card')
check_absent "4.3 no check-in: no budget line" "$CARD" "Reading budget"

# ------------------------------------------------------------------- CLI
printf '== CLI\n'
run_cli() {
  local sh="$1"
  shift
  ELAPSED_START=$(hq_t_now)
  RC=0
  env HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" "$sh" "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
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
# expect_db SHELL LABEL ARGS... — passes validation: exit 7 with the URL unset.
expect_db() {
  local sh="$1" label="$2" rc=0
  shift 2
  env -u HUMAN_QUEUE_DATABASE_URL -u HUMAN_QUEUE_SCHEMA "$sh" "$HQ_T_CLI" "$@" >/dev/null 2>"$TMP/err" </dev/null || rc=$?
  check "[$sh] $label passes validation (exit 7, URL unset)" "$rc" "7"
}

for SH in $SHELLS; do
  echo "=== shell: $SH — $("$SH" --version 2>&1 | sed -n 1p) ==="
  expect_rc "$SH" 4 "stats --day malformed" "--day must be YYYY-MM-DD" stats --day 2026-9-15
  expect_rc "$SH" 4 "stats --day not a date" "--day is not a real calendar date" stats --day 2026-02-30
  expect_rc "$SH" 4 "stats --day twice" "--day given more than once" stats --day 2026-09-15 --day 2026-09-16
  expect_rc "$SH" 4 "stats --day without a value" "--day needs a value" stats --day
  expect_rc "$SH" 4 "stats with a stray argument" "takes no arguments" stats today
  expect_rc "$SH" 4 "stats with an unknown option" "unknown option '--since'" stats --since 2026-09-15
  expect_db "$SH" "stats" stats
  expect_db "$SH" "stats --day --json" stats --day 2026-09-15 --json

  expect_rc "$SH" 4 "checkin with no action" "missing action" checkin
  expect_rc "$SH" 4 "checkin with an unknown action" "unknown action" checkin show
  expect_rc "$SH" 4 "checkin set without --session" "missing --session" checkin set --hours 4 --energy ok
  expect_rc "$SH" 4 "checkin set without --hours" "missing --hours" checkin set --session s1 --energy ok
  expect_rc "$SH" 4 "checkin set without --energy" "missing --energy" checkin set --session s1 --hours 4
  for bad_hours in 17 16.5 4.555 -1 abc '4h' '' 100; do
    expect_rc "$SH" 4 "checkin set --hours '$bad_hours'" "--hours must be a number of hours from 0 to 16" \
      checkin set --session s1 --hours "$bad_hours" --energy ok
  done
  for bad_energy in 'pretty tired' '5' 'ok!' 'abcdefghijklmnopqrstu' '-ok' ''; do
    expect_rc "$SH" 4 "checkin set --energy '$bad_energy'" "--energy must be one word" \
      checkin set --session s1 --hours 4 --energy "$bad_energy"
  done
  expect_rc "$SH" 4 "checkin set --planned on two lines" "--planned must be a single line" \
    checkin set --session s1 --hours 4 --energy ok --planned "$(printf 'a\nb')"
  expect_rc "$SH" 4 "checkin set --planned with an escape" "control character" \
    checkin set --session s1 --hours 4 --energy ok --planned "$(printf 'a\033[31mb')"
  expect_rc "$SH" 4 "checkin set --planned over 200" "longer than 200 characters" \
    checkin set --session s1 --hours 4 --energy ok --planned "$(printf '%0201d' 0)"
  expect_rc "$SH" 5 "checkin set --planned with a secret" "--planned" \
    checkin set --session s1 --hours 4 --energy ok --planned "review $FAKE_AWS"
  check_absent "[$SH] the secret is never echoed" "$ERR" "$FAKE_AWS"
  expect_rc "$SH" 5 "checkin set with a secret-shaped session" "the session id" \
    checkin set --session "$FAKE_AWS" --hours 4 --energy ok
  expect_rc "$SH" 4 "checkin set --at" "go only with due" checkin set --session s1 --hours 4 --energy ok --at 04:00
  expect_rc "$SH" 4 "checkin set --hours twice" "--hours given more than once" \
    checkin set --session s1 --hours 4 --hours 5 --energy ok
  expect_rc "$SH" 4 "checkin get --session" "--session goes only with set and due" checkin get --session s1
  expect_rc "$SH" 4 "checkin get --hours" "go only with set" checkin get --hours 4
  expect_rc "$SH" 4 "checkin get --until" "go only with due" checkin get --until 17:30
  expect_rc "$SH" 4 "checkin get with a stray argument" "takes no arguments" checkin get today
  expect_rc "$SH" 4 "checkin due without --at" "missing --at" checkin due --session s1
  expect_rc "$SH" 4 "checkin due without --session" "missing --session" checkin due --at 04:00
  expect_rc "$SH" 4 "checkin due --at 4:00" "--at must be a 24-hour time" checkin due --session s1 --at 4:00
  expect_rc "$SH" 4 "checkin due --at 24:00" "--at must be a 24-hour time" checkin due --session s1 --at 24:00
  expect_rc "$SH" 4 "checkin due --until late" "--until must be a 24-hour time" checkin due --session s1 --at 04:00 --until late
  expect_rc "$SH" 4 "checkin due --energy" "go only with set" checkin due --session s1 --at 04:00 --energy ok
  expect_db "$SH" "checkin get" checkin get
  expect_db "$SH" "checkin get --json" checkin get --json
  expect_db "$SH" "checkin set" checkin set --session s1 --hours 4.5 --energy OK --planned "the PRD until noon" --json
  expect_db "$SH" "checkin set, 0 hours, an empty plan" checkin set --session s1 --hours 0 --energy low --planned ""
  expect_db "$SH" "checkin set, 16 hours" checkin set --session s1 --hours 16.00 --energy high
  expect_db "$SH" "checkin due" checkin due --session s1 --at 04:00 --until 17:30 --json
  expect_rc "$SH" 4 "state set checkin" "checkin is reserved: use checkin set" state set checkin '{}'
  expect_rc "$SH" 4 "state set checkin_asked" "checkin_asked is reserved: only checkin due writes it" state set checkin_asked 2026-10-08
  expect_db "$SH" "state set energy_factors (not reserved)" state set energy_factors '{"low": 0.6}'

  for c in stats checkin; do
    RC=0
    OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" "$c" --help 2>"$TMP/err") || RC=$?
    check "[$SH] $c --help: exit 0, silent" "$RC:$(cat "$TMP/err")" "0:"
    check_contains "[$SH] $c --help documents exit codes" "$OUT" "EXIT CODES"
  done
  RC=0
  OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" --help 2>&1) || RC=$?
  check_contains "[$SH] --help lists checkin" "$OUT" "  checkin "
  check_contains "[$SH] --help lists stats" "$OUT" "  stats "
  OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" state --help 2>&1)
  check_contains "[$SH] state --help names checkin" "$OUT" "written by \`checkin set\`"
  OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" plan --help 2>&1)
  check_contains "[$SH] plan --help names the forecast's budget" "$OUT" '"read_today", "budget",'
done

# --------------------------------------------------------------- desk-tick
printf '== desk-tick.sh: the morning step\n'
STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR"
TSTUB="$STUB_DIR/loopcli.sh"
# Records each call; `checkin` answers from $STUB_DIR/checkin-out (exit from
# checkin-rc); control-status from status (status-checkin after a refusal).
cat > "$TSTUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/args"
case "$1" in
  control-status)
    if [ -f "$STUB_DIR/refused" ] && [ -f "$STUB_DIR/status-checkin" ]; then cat "$STUB_DIR/status-checkin"
    else cat "$STUB_DIR/status"; fi ;;
  tick) cat "$STUB_DIR/tick" ;;
  wake-due) cat "$STUB_DIR/due" ;;
  checkin)
    rc=$(cat "$STUB_DIR/checkin-rc" 2>/dev/null || echo 0)
    if [ "$rc" -ne 0 ]; then
      : > "$STUB_DIR/refused"
      echo "human-queue: checkin due: this session is not the registered control session; nothing was marked (stub)" >&2
      exit "$rc"
    fi
    cat "$STUB_DIR/checkin-out" 2>/dev/null || true ;;
esac
EOF
chmod +x "$TSTUB"
OURS='{"session": "desk-1", "last_tick_at": "2026-10-08T11:00:00Z", "tick_age_seconds": 1}'
THEIRS='{"session": "desk-2", "last_tick_at": null, "tick_age_seconds": null}'
treset() {
  rm -f "$STUB_DIR"/args "$STUB_DIR"/checkin-out "$STUB_DIR"/checkin-rc "$STUB_DIR"/refused "$STUB_DIR"/status-checkin
  printf '%s\n' "$OURS" > "$STUB_DIR/status"
  printf '[]\n' > "$STUB_DIR/tick"
  printf '[]\n' > "$STUB_DIR/due"
}
checkin_calls() { grep -c '^checkin ' "$STUB_DIR/args" 2>/dev/null || true; }
# dtick SHELL CLOCK POLICY ARGS... — desk-tick.sh for desk-1 at CLOCK.
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
  printf 'due 2026-10-08\n' > "$STUB_DIR/checkin-out"
  dtick "$SH" "2026-10-08 03:59" "" --once
  check "[$SH] before 04:00: quiet, the store is not asked" "$RC:$OUT:$ERR:$(checkin_calls)" "0:::0"

  treset
  printf 'due 2026-10-08\n' > "$STUB_DIR/checkin-out"
  dtick "$SH" "2026-10-08 04:00" "" --once
  check "[$SH] at 04:00: due prints morning" "$RC:$OUT:$ERR" "0:desk-tick g1 morning:"
  check "[$SH] at 04:00: asks with the session, the morning, and eod_time" \
    "$(grep '^checkin ' "$STUB_DIR/args")" "checkin due --session desk-1 --at 04:00 --until 17:30"

  treset
  printf 'due 2026-10-08\n' > "$STUB_DIR/checkin-out"
  printf '%s\n' "$NEWD" > "$STUB_DIR/tick"
  printf '%s\n' "$DUE" > "$STUB_DIR/due"
  dtick "$SH" "2026-10-08 08:15" "" --once
  check "[$SH] morning comes before new and retry" "$RC:$OUT" "0:desk-tick g1 morning
desk-tick g1 new D-4
desk-tick g1 retry D-9"

  treset
  printf 'done 2026-10-08\n' > "$STUB_DIR/checkin-out"
  dtick "$SH" "2026-10-08 09:00" "" --once
  check "[$SH] done: nothing printed" "$RC:$OUT:$ERR" "0::"
  treset
  dtick "$SH" "2026-10-08 09:00" "" --once
  check "[$SH] not yet on the store's clock: nothing printed" "$RC:$OUT:$ERR" "0::"

  treset
  printf 'due 2026-10-08\n' > "$STUB_DIR/checkin-out"
  dtick "$SH" "2026-10-08 17:30" "" --once
  check "[$SH] from eod_time on: the store is not asked" "$(checkin_calls)" "0"
  printf '{"eod_time": "09:05"}\n' > "$TMP/eod-0905.json"
  treset
  printf 'due 2026-10-08\n' > "$STUB_DIR/checkin-out"
  dtick "$SH" "2026-10-08 09:04" "$TMP/eod-0905.json" --once
  check "[$SH] the policy's eod_time ends the window: --until 09:05" \
    "$OUT|$(grep '^checkin ' "$STUB_DIR/args")" "desk-tick g1 morning|checkin due --session desk-1 --at 04:00 --until 09:05"
  printf '{"eod_time": "00:00"}\n' > "$TMP/eod-0000.json"
  treset
  printf 'due 2026-10-08\n' > "$STUB_DIR/checkin-out"
  dtick "$SH" "2026-10-08 12:00" "$TMP/eod-0000.json" --once
  check "[$SH] eod_time at midnight: the window is empty" "$OUT:$(checkin_calls)" ":0"

  # A failing check-in call is one error line, then the tick's own lines.
  treset
  printf '%s\n' "$NEWD" > "$STUB_DIR/tick"
  printf '7\n' > "$STUB_DIR/checkin-rc"
  printf '%s\n' "$OURS" > "$STUB_DIR/status-checkin"
  dtick "$SH" "2026-10-08 10:00" "" --once
  check "[$SH] checkin unreachable: an error line, then the new line" "$RC:$OUT" \
    "0:desk-tick g1 error checkin exit 7: human-queue: checkin due: this session is not the registered control session; nothing was marked (stub)
desk-tick g1 new D-4"
  # A refusal because another desk registered: replaced.
  treset
  printf '4\n' > "$STUB_DIR/checkin-rc"
  printf '%s\n' "$THEIRS" > "$STUB_DIR/status-checkin"
  dtick "$SH" "2026-10-08 10:00" "" --once
  check "[$SH] checkin refused for another desk: replaced" "$RC:$OUT" "0:desk-tick g1 replaced"

  # The loop asks once a day: after `due` no further check-in call that day.
  treset
  printf 'due 2026-10-08\n' > "$STUB_DIR/checkin-out"
  RC=0
  env STUB_DIR="$STUB_DIR" HUMAN_QUEUE_CLI="$TSTUB" HUMAN_QUEUE_DATABASE_URL="$FAKE_URL" \
    HUMAN_QUEUE_CLOCK="2026-10-08 08:00" HUMAN_QUEUE_POLICY="$TMP/no-policy.json" HUMAN_QUEUE_TICK_SECONDS=1 \
    perl -e 'alarm 4; exec @ARGV' "$SH" "$BIN/desk-tick.sh" --session desk-1 --generation g2 >"$TMP/out" 2>/dev/null </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  check "[$SH] the loop: morning once" "$(printf '%s\n' "$OUT" | grep -c 'desk-tick g2 morning')" "1"
  check "[$SH] the loop: the store asked once that day" "$(checkin_calls)" "1"
  if [ "$(grep -c '^tick ' "$STUB_DIR/args")" -ge 2 ]; then ok "[$SH] the loop ran more than one cycle"; else bad "[$SH] the loop ran more than one cycle"; fi
done

# ------------------------------------------------------------------- skill
printf '== skill\n'
CHECKIN_MD="$SKILL_DIR/checkin.md"
for anchor in desk-checkin-card desk-checkin-store desk-budget-show; do
  RC=0
  hq_t_skill_block "$CHECKIN_MD" "$anchor" > "$TMP/block-$anchor.sh" 2>"$TMP/err" || RC=$?
  check "checkin.md: anchor $anchor extracts" "$RC:$(cat "$TMP/err")" "0:"
  if bash -n "$TMP/block-$anchor.sh" 2>"$TMP/syntax"; then ok "checkin.md: anchor $anchor is valid bash"
  else bad "checkin.md: anchor $anchor is valid bash ($(cat "$TMP/syntax"))"; fi
done
RC=0
hq_t_skill_block "$SKILL_DIR/reviews.md" desk-reviews-view > "$TMP/block-desk-reviews-view.sh" 2>"$TMP/err" || RC=$?
check "reviews.md: anchor desk-reviews-view extracts" "$RC:$(cat "$TMP/err")" "0:"

# The stub CLI the blocks run against: it serves the fixtures, logs each
# call's arguments on one line (each argument in brackets, so one holding
# spaces stays one), and answers `checkin set` with the fixture named in
# $STUB_DIR/set-reply.
HSTUB="$TMP/hq-stub.sh"
cat > "$HSTUB" <<'EOF'
#!/usr/bin/env bash
line=""
for a in "$@"; do line="$line[$a]"; done
printf '%s\n' "$line" >> "$STUB_DIR/hq-args"
case "$1 ${2:-}" in
  "checkin get")
    if [ -f "$STUB_DIR/checkin-fail" ]; then echo "human-queue: database unreachable (stub)" >&2; exit 7; fi
    cat "$FIX/$(cat "$STUB_DIR/get-reply")" ;;
  "checkin set") cat "$FIX/get-set.json" ;;
  "list --kind") cat "$PFIX/reviews.json" ;;
esac
EOF
chmod +x "$HSTUB"
mkdir -p "$TMP/run" "$TMP/blocktmp"
run_block() {
  rm -f "$STUB_DIR/hq-args"
  (cd "$TMP/run" && env -u TZ DESK="$HQ_T_DESK_DIR" HQ="$HSTUB" SID="desk-1" STUB_DIR="$STUB_DIR" FIX="$FIX" PFIX="$PFIX" \
     TMPDIR="$TMP/blocktmp" "$1" "$2") 2>&1
}
hq_args() { cat "$STUB_DIR/hq-args" 2>/dev/null; }
leftovers() { find "$TMP/blocktmp" -type f | wc -l | tr -d ' '; }
with_line() { awk -v ph="$2" -v t="$3" '$0 == ph { print t; next } { print }' "$1"; }

HOSTILE='4, ok, the $(touch store-pwned) `touch store-pwned-2` "PRD" '"'"'x'"'"' until noon'
with_line "$TMP/block-desk-checkin-store.sh" "<the operator's reply, verbatim>" "4, OK, the PRD, 30 min a section" > "$TMP/store.sh"
with_line "$TMP/block-desk-checkin-store.sh" "<the operator's reply, verbatim>" "$HOSTILE" > "$TMP/store-hostile.sh"
with_line "$TMP/block-desk-checkin-store.sh" "<the operator's reply, verbatim>" "skip" > "$TMP/store-skip.sh"
with_line "$TMP/block-desk-checkin-store.sh" "<the operator's reply, verbatim>" "1: A, 2: C" > "$TMP/store-not.sh"
with_line "$TMP/block-desk-checkin-store.sh" "<the operator's reply, verbatim>" "Half an hour, tired" > "$TMP/store-half.sh"

for SH in $BLOCK_SHELLS; do
  printf 'get-none.json\n' > "$STUB_DIR/get-reply"
  rm -f "$STUB_DIR/checkin-fail"
  OUT=$(run_block "$SH" "$TMP/block-desk-checkin-card.sh")
  check "[$SH] desk-checkin-card: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
  check "[$SH] desk-checkin-card: whether a check-in is stored, first" "$(printf '%s\n' "$OUT" | sed -n 1p)" '{"checked_in":false}'
  check_contains "[$SH] desk-checkin-card: the card" "$OUT" "> **Morning check-in · Thu Oct 8**"
  check "[$SH] desk-checkin-card: one read" "$(hq_args)" "[checkin][get][--json]"
  check "[$SH] desk-checkin-card: removes its file" "$(leftovers)" "0"
  printf 'get-set.json\n' > "$STUB_DIR/get-reply"
  OUT=$(run_block "$SH" "$TMP/block-desk-checkin-card.sh")
  check "[$SH] desk-checkin-card: today's check-in is stored" "$(printf '%s\n' "$OUT" | sed -n 1p)" '{"checked_in":true}'
  : > "$STUB_DIR/checkin-fail"
  OUT=$(run_block "$SH" "$TMP/block-desk-checkin-card.sh")
  check "[$SH] desk-checkin-card: the store unreachable" "$(printf '%s\n' "$OUT" | tail -1)" "exit=7"
  rm -f "$STUB_DIR/checkin-fail"

  OUT=$(run_block "$SH" "$TMP/store.sh")
  check "[$SH] desk-checkin-store: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"
  check "[$SH] desk-checkin-store: the parsed reply first" "$(printf '%s\n' "$OUT" | sed -n 1p)" \
    '{"skip":false,"hours":4,"energy":"ok","planned":"the PRD, 30 min a section","missing":[],"plan":true}'
  check "[$SH] desk-checkin-store: checkin set as this session, the plan as one argument" "$(hq_args)" \
    "[checkin][set][--session][desk-1][--hours][4][--energy][ok][--planned][the PRD, 30 min a section][--json]"
  check_contains "[$SH] desk-checkin-store: the budget card" "$OUT" "> **Reading budget today: 28 Reviews (~560 lines at level 2)**"
  check "[$SH] desk-checkin-store: removes its files" "$(leftovers)" "0"
  OUT=$(run_block "$SH" "$TMP/store-hostile.sh")
  check "[$SH] desk-checkin-store: hostile text arrives as typed" "$(hq_args | sed 's/.*\[--planned\]\[//; s/\]\[--json\]$//')" \
    'the $(touch store-pwned) `touch store-pwned-2` "PRD" '"'"'x'"'"' until noon'
  check "[$SH] desk-checkin-store: nothing in it ran" "$(find "$TMP/run" -name '*pwned*' | wc -l | tr -d ' ')" "0"
  OUT=$(run_block "$SH" "$TMP/store-half.sh")
  check "[$SH] desk-checkin-store: half an hour, no plan" "$(hq_args)" "[checkin][set][--session][desk-1][--hours][0.5][--energy][tired][--json]"
  OUT=$(run_block "$SH" "$TMP/store-skip.sh")
  check "[$SH] desk-checkin-store: skip stores nothing" "$(hq_args):$(printf '%s\n' "$OUT" | tail -1)" ":exit=0"
  check "[$SH] desk-checkin-store: skip is said" "$(printf '%s\n' "$OUT" | sed -n 1p | jq -c .skip)" "true"
  OUT=$(run_block "$SH" "$TMP/store-not.sh")
  check "[$SH] desk-checkin-store: a non-reply stores nothing" "$(hq_args):$(printf '%s\n' "$OUT" | sed -n 1p | jq -c .missing)" ':["hours"]'

  printf 'get-set.json\n' > "$STUB_DIR/get-reply"
  OUT=$(run_block "$SH" "$TMP/block-desk-budget-show.sh")
  check "[$SH] desk-budget-show: the budget card" "$(printf '%s\n' "$OUT" | sed -n 1p)" "> **Reading budget today: 28 Reviews (~560 lines at level 2)**"
  check "[$SH] desk-budget-show: exit=0" "$(printf '%s\n' "$OUT" | tail -1)" "exit=0"

  OUT=$(run_block "$SH" "$TMP/block-desk-reviews-view.sh")
  check "[$SH] 4.4 desk-reviews-view: the running count under the header" "$(printf '%s\n' "$OUT" | sed -n 2p)" \
    "Reading budget: 9 of 28 Reviews read today · 19 left"
  printf 'get-none.json\n' > "$STUB_DIR/get-reply"
  OUT=$(run_block "$SH" "$TMP/block-desk-reviews-view.sh")
  check "[$SH] 4.4 desk-reviews-view: no check-in, the view as before" "$OUT" "$PLAIN"
  : > "$STUB_DIR/checkin-fail"
  OUT=$(run_block "$SH" "$TMP/block-desk-reviews-view.sh")
  check "[$SH] 4.4 desk-reviews-view: the check-in unreadable, the view as before" "$OUT" "$PLAIN"
  rm -f "$STUB_DIR/checkin-fail"
done

# The router and the files around it.
SKILL_MD=$(cat "$SKILL_DIR/SKILL.md")
check_contains "SKILL.md routes to checkin.md" "$SKILL_MD" '| `checkin.md` |'
check_contains "SKILL.md handles the morning event" "$SKILL_MD" '| `desk-tick <GEN> morning` |'
check_contains "SKILL.md: the check-in verbs" "$SKILL_MD" '**A check-in verb**'
check_contains "plan.md: a new plan checks in first" "$(cat "$SKILL_DIR/plan.md")" '`checkin.md` first'
check_contains "reviews.md: the running count" "$(cat "$SKILL_DIR/reviews.md")" '**The running count** (#1770'
check_contains "the README documents it" "$(cat "$HQ_T_DESK_DIR/README.md")" "## Morning check-in and reading budget (issue #1770)"

hq_t_finish "checkin-offline.test.sh"
