#!/usr/bin/env bash
# desk/tests/report-offline.test.sh — offline tests for the weekly attention
# report (issue #1771). Needs no database and never connects to one:
# validation comes before any connection attempt, which the black-hole URL
# proves (a connection attempt would take the full 1.5 s).
#
# Asserts:
#   render   lib/report.jq on tests/fixtures/report/week.json (test 5.1's
#            week): the numbered list and the small table exactly; a week to
#            date, singulars, an empty week, no days yet, at most 10 threads
#            (then a count of the rest), durations, and table cells that
#            cannot break the table
#   models   lib/report.sh's hq_thread_model on fixture transcripts, under
#            `set -euo pipefail` like the CLI: the latest reply's model
#            outside a sidechain and never `<synthetic>`, a half-written line
#            skipped, `unknown` for no transcript, no reply, a model name
#            unsafe to print, an id that could name another path, or a
#            missing directory; the newest of two transcripts wins; the
#            default directory is ~/.claude/projects
#   CLI      `report` validation (a bad or impossible --week, a repeated or
#            missing value, an unknown option, a stray argument) exits 4
#            without a connection attempt and never echoes the value; valid
#            calls reach the database step; --help documents it offline and
#            human-queue.sh --help lists it
#   skill    attention.md's desk-report block and sweep.md's
#            desk-sweep-friday block, run as written against stubs (bash,
#            /bin/bash 3.2, zsh): the report printed with its exit code, the
#            Friday offer on a Friday in New York only; the router and the
#            files around them
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: report-offline.test.sh — jq is not installed (the report needs it)"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-report-offline.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

BLACKHOLE_URL="postgresql://u:pw@192.0.2.1:5432/db?sslmode=require"
SKILL_DIR="$HQ_T_DESK_DIR/skill"
BIN="$HQ_T_DESK_DIR/bin"
FIX="$TESTS_DIR/fixtures/report"
S1=11111111-aaaa-4aaa-8aaa-111111111111
S2=22222222-bbbb-4bbb-8bbb-222222222222
S3=33333333-cccc-4ccc-8ccc-333333333333
S4=44444444-dddd-4ddd-8ddd-444444444444

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi
BLOCK_SHELLS="$SHELLS"
if command -v zsh >/dev/null 2>&1; then BLOCK_SHELLS="$BLOCK_SHELLS zsh"; fi

# render [FILTER] — the fixture week, changed by FILTER, as the report's
# text. jq's include must open a program, so FILTER runs in a first jq.
render() {
  jq -c "${1:-.}" "$FIX/week.json" | jq -r -L "$BIN/lib" 'include "report"; report_text' 2>&1
}

# ------------------------------------------------------------------ render
printf '== render\n'

EXPECTED='**Attention report · week of 2026-09-07 to 2026-09-13**

1. Minutes spent answering: 39 min over 5 sittings
2. Items per day: 1.4 per desk day (7 handled on 5 days) · Mon 3 · Tue 1 · Wed 2 · Thu 0 · Fri 1 · Sat 0 · Sun 0
3. Median age of an open Decision: 6h 32m (6 Decisions open during the week, 2 still open at its end)
4. Interrupts tagged not important: 3 (of 6 Decisions shown)
5. Questions tagged should have defaulted: 3, by thread and model:

| Thread | Model | Asked | Should have defaulted | Not important | Good interrupt |
|--------|-------|------:|----------------------:|--------------:|---------------:|
| 11111111 | claude-sonnet-4-5 | 2 | 2 | 1 | 0 |
| 22222222 | unknown | 3 | 1 | 1 | 1 |
| (no thread) | – | – | 0 | 1 | 0 |'
check "4.1 the fixture week: a numbered list and a small table" "$(render)" "$EXPECTED"
check "a week still running is titled (to date)" "$(render '.today = "2026-09-10"' | sed -n 1p)" \
  "**Attention report · week of 2026-09-07 to 2026-09-13 (to date)**"
check "the week's last day is not (to date)" "$(render '.today = "2026-09-13"' | sed -n 1p)" \
  "**Attention report · week of 2026-09-07 to 2026-09-13**"

SINGLE=$(render '.minutes = {"total": 3, "sittings": 1}
  | .handled = {"total": 1, "desk_days": 1, "per_desk_day": 1}
  | .open_age = {"decisions": 1, "still_open": 0, "median_minutes": 45}
  | .not_important = {"tagged": 1, "shown": 1}')
check "singulars" "$(printf '%s\n' "$SINGLE" | sed -n '3,6p')" \
  "1. Minutes spent answering: 3 min over 1 sitting
2. Items per day: 1 per desk day (1 handled on 1 day) · Mon 3 · Tue 1 · Wed 2 · Thu 0 · Fri 1 · Sat 0 · Sun 0
3. Median age of an open Decision: 45m (1 Decision open during the week, 0 still open at its end)
4. Interrupts tagged not important: 1 (of 1 Decision shown)"

EMPTY='**Attention report · week of 2026-09-07 to 2026-09-13**

1. Minutes spent answering: 0 (no desk activity)
2. Items per day: none handled · Mon 0 · Tue 0 · Wed 0 · Thu 0 · Fri 0 · Sat 0 · Sun 0
3. Median age of an open Decision: none was open this week
4. Interrupts tagged not important: 0 (of 0 Decisions shown)
5. Questions tagged should have defaulted: 0

No thread was tagged this week.'
check "an empty week: every measure as none, no table" "$(render '.minutes = {"total": 0, "sittings": 0}
  | .days |= map(.handled = 0) | .handled = {"total": 0, "desk_days": 0, "per_desk_day": 0}
  | .open_age = {"decisions": 0, "still_open": 0, "median_minutes": null}
  | .not_important = {"tagged": 0, "shown": 0} | .should_have_defaulted.tagged = 0 | .threads = []')" "$EMPTY"
check "a week with no days yet lists none" "$(render '.days = [] | .handled = {"total": 0, "desk_days": 0, "per_desk_day": 0}' | sed -n 4p)" \
  "2. Items per day: none handled"
check "tags but no should-have-defaulted: the table still shows" \
  "$(render '.should_have_defaulted.tagged = 0' | sed -n '7p;9p')" \
  "5. Questions tagged should have defaulted: 0, by thread and model:
| Thread | Model | Asked | Should have defaulted | Not important | Good interrupt |"

MANY='.threads = [range(12) as $i | {session: "s\($i)-thread", model: "m", asked: 1, should_have_defaulted: 1, not_important: 0, good_interrupt: 0}]'
OUT=$(render "$MANY")
check "12 threads: 10 rows" "$(printf '%s\n' "$OUT" | grep -c '^| s[0-9]')" "10"
check "12 threads: the rest counted" "$(printf '%s\n' "$OUT" | tail -n 1)" '2 more threads: `report --json` lists every one.'
OUT=$(render "${MANY/range(12)/range(11)}")
check "11 threads: one more thread" "$(printf '%s\n' "$OUT" | tail -n 1)" '1 more thread: `report --json` lists every one.'
OUT=$(render "${MANY/range(12)/range(10)}")
check "10 threads: all of them, nothing after" "$(printf '%s\n' "$OUT" | tail -n 1)" '| s9-threa | m | 1 | 1 | 0 | 0 |'

check "durations" "$(jq -n -c -L "$BIN/lib" 'include "report"; [0, 45, 60, 85, 1439.6, 1440, 1500, 9480] | map(report_dur)')" \
  '["0m","45m","1h","1h 25m","1d","1d","1d 1h","6d 14h"]'
check "a cell never ends the cell or the row" \
  "$(render '.threads = [{session: "ab|c`d\\e", model: "x|y\nz", asked: 1, should_have_defaulted: 1, not_important: 0, good_interrupt: 0}]' | tail -n 1)" \
  '| ab?c?d?e | x?y?z | 1 | 1 | 0 | 0 |'

# ------------------------------------------------------------------ models
printf '== models\n'

DRIVER="$TMP/model-driver.sh"
printf '%s\n' \
  'set -euo pipefail' \
  'HQ_BIN_DIR="$1"; shift' \
  '. "$HQ_BIN_DIR/lib/common.sh"' \
  '. "$HQ_BIN_DIR/lib/github.sh"' \
  '. "$HQ_BIN_DIR/lib/report.sh"' \
  'hq_jq_find' \
  'for s in "$@"; do hq_thread_model m "$s"; printf "%s\n" "$m"; done' \
  'echo done' > "$DRIVER"
# models SHELL DIR SESSION... — one model per line, then `done` when the
# driver ran to its end under set -euo pipefail.
models() {
  local sh="$1" dir="$2"
  shift 2
  if [ -n "$dir" ]; then
    HUMAN_QUEUE_TRANSCRIPTS_DIR="$dir" "$sh" "$DRIVER" "$BIN" "$@" 2>&1
  else
    env -u HUMAN_QUEUE_TRANSCRIPTS_DIR "$sh" "$DRIVER" "$BIN" "$@" 2>&1
  fi
}

mkdir -p "$TMP/tx" "$TMP/home/.claude/projects/-Users-op-home"
cp -R "$FIX/transcripts/." "$TMP/tx/"
mkdir -p "$TMP/tx/-Users-op-other"
printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"model":"claude-older-1","role":"assistant","content":[]}}' \
  > "$TMP/tx/-Users-op-other/$S1.jsonl"
cp "$FIX/transcripts/-Users-op-work-widgets/$S1.jsonl" "$TMP/home/.claude/projects/-Users-op-home/"

for SH in $SHELLS; do
  check "[$SH] the latest reply outside a sidechain, never <synthetic>, a half line skipped" \
    "$(models "$SH" "$FIX/transcripts" "$S1")" "claude-sonnet-4-5
done"
  check "[$SH] unknown: no transcript, no reply, an unsafe model name" \
    "$(models "$SH" "$FIX/transcripts" "$S2" "$S3" "$S4")" "unknown
unknown
unknown
done"
  check "[$SH] unknown: an id that could name another path" \
    "$(models "$SH" "$FIX/transcripts" "../-Users-op-work-widgets/$S1" '*' "$S1.jsonl" "" "-$S1")" "unknown
unknown
unknown
unknown
unknown
done"
  check "[$SH] unknown: no transcripts directory" "$(models "$SH" "$TMP/missing" "$S1")" "unknown
done"
  touch -t 202001010000 "$TMP/tx/-Users-op-other/$S1.jsonl"
  touch -t 202101010000 "$TMP/tx/-Users-op-work-widgets/$S1.jsonl"
  check "[$SH] two transcripts: the newer one's model" "$(models "$SH" "$TMP/tx" "$S1")" "claude-sonnet-4-5
done"
  touch -t 202201010000 "$TMP/tx/-Users-op-other/$S1.jsonl"
  check "[$SH] two transcripts: the newer one's model (swapped)" "$(models "$SH" "$TMP/tx" "$S1")" "claude-older-1
done"
  check "[$SH] the default directory is ~/.claude/projects" \
    "$(HOME="$TMP/home" models "$SH" "" "$S1")" "claude-sonnet-4-5
done"
done

# --------------------------------------------------------------------- CLI
printf '== CLI\n'

run_cli() {
  local sh="$1"
  shift
  ELAPSED_START=$(hq_t_now)
  RC=0
  env HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" "$sh" "$HQ_T_CLI" "$@" \
    >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
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
  env -u HUMAN_QUEUE_DATABASE_URL -u HUMAN_QUEUE_SCHEMA "$sh" "$HQ_T_CLI" "$@" >/dev/null 2>"$TMP/err" </dev/null || rc=$?
  check "[$sh] $label passes validation (exit 7, URL unset)" "$rc" "7"
}

SECRET="token=""abc123def456ghi789"
for SH in $SHELLS; do
  echo "=== shell: $SH — $("$SH" --version 2>&1 | sed -n 1p) ==="
  HELP=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" --help 2>&1)
  check_contains "[$SH] human-queue.sh --help lists report" "$HELP" "  report "
  RC=0
  OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" report --help 2>"$TMP/err") || RC=$?
  check "[$SH] report --help: exit 0 without a database" "$RC" "0"
  check "[$SH] report --help: silent on stderr" "$(cat "$TMP/err")" ""
  for needle in "human-queue.sh report [--week YYYY-MM-DD] [--json]" "EXIT CODES" "MEASURES" \
                "HUMAN_QUEUE_TRANSCRIPTS_DIR" "Monday to Sunday" "records nothing"; do
    check_contains "[$SH] report --help documents: $needle" "$OUT" "$needle"
  done
  RC=0
  OUT=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" report --week 2026-10-05 --help 2>&1) || RC=$?
  check "[$SH] --help after an option still prints the help" "$RC:$(printf '%s\n' "$OUT" | sed -n 1p)" \
    "0:human-queue.sh report — the weekly attention report (issue #1771)."

  expect_rc "$SH" 4 "--week not a date" "--week must be a date YYYY-MM-DD" report --week 2026-10
  expect_rc "$SH" 4 "--week with a time" "--week must be a date YYYY-MM-DD" report --week "2026-10-05 10:00"
  expect_rc "$SH" 4 "--week 2026-02-29 (no leap day)" "--week is not a real calendar date" report --week 2026-02-29
  expect_rc "$SH" 4 "--week month 13" "--week is not a real calendar date" report --week 2026-13-01
  expect_rc "$SH" 4 "--week day 31 of a 30-day month" "--week is not a real calendar date" report --week 2026-09-31
  expect_rc "$SH" 4 "--week with no value" "--week needs a value" report --week
  expect_rc "$SH" 4 "--week twice" "--week given more than once" report --week 2026-10-05 --week 2026-10-06
  expect_rc "$SH" 4 "an unknown option" "unknown option '--day'" report --day 2026-10-05
  expect_rc "$SH" 4 "a stray argument" "takes no arguments besides its options" report 2026-10-05
  expect_rc "$SH" 4 "a stray secret" "takes no arguments" report "$SECRET"
  check_absent "[$SH] a stray secret is never echoed" "$ERR" "abc123def456"
  expect_rc "$SH" 4 "a secret as --week" "--week must be a date" report --week "$SECRET"
  check_absent "[$SH] a secret --week is never echoed" "$ERR" "abc123def456"

  expect_db "$SH" "report" report
  expect_db "$SH" "report --json" report --json
  expect_db "$SH" "report --week 2024-02-29 (a leap day)" report --week 2024-02-29
  expect_db "$SH" "report --json --week 2026-10-05" report --json --week 2026-10-05
done

# ------------------------------------------------------------------- skill
printf '== skill\n'
ATTN_MD="$SKILL_DIR/attention.md"
SWEEP_MD="$SKILL_DIR/sweep.md"
RC=0
hq_t_skill_block "$ATTN_MD" desk-report > "$TMP/block-desk-report.sh" 2>"$TMP/err" || RC=$?
check "attention.md: anchor desk-report extracts" "$RC:$(cat "$TMP/err")" "0:"
RC=0
hq_t_skill_block "$SWEEP_MD" desk-sweep-friday > "$TMP/block-desk-sweep-friday.sh" 2>"$TMP/err" || RC=$?
check "sweep.md: anchor desk-sweep-friday extracts" "$RC:$(cat "$TMP/err")" "0:"

# The stub CLI logs its arguments and prints a page, exiting STUB_RC; the stub
# date logs its TZ and arguments and prints STUB_DOW.
mkdir -p "$TMP/stub-bin" "$TMP/run"
HSTUB="$TMP/hq-stub.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >> "$STUB_DIR/hq-args"' \
  'printf "%s\n" "**Attention report · week of 2026-10-05 to 2026-10-11 (to date)**" "" "1. Minutes spent answering: 12 min over 2 sittings"' \
  'exit "${STUB_RC:-0}"' > "$HSTUB"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s|%s\n" "${TZ:-}" "$*" >> "$STUB_DIR/date-args"' \
  'printf "%s\n" "$STUB_DOW"' > "$TMP/stub-bin/date"
chmod +x "$HSTUB" "$TMP/stub-bin/date"
STUB_DIR="$TMP"

# run_block SHELL FILE [VAR=VALUE...] — FILE with the prelude's DESK, HQ, and
# SID, the stub date first on PATH, and TZ unset (the block sets it).
run_block() {
  local sh="$1" file="$2"
  shift 2
  rm -f "$STUB_DIR/hq-args" "$STUB_DIR/date-args"
  (cd "$TMP/run" && env -u TZ PATH="$TMP/stub-bin:$PATH" DESK="$HQ_T_DESK_DIR" HQ="$HSTUB" SID="desk-1" \
     STUB_DIR="$STUB_DIR" "$@" "$sh" "$file") 2>&1
}

for SH in $BLOCK_SHELLS; do
  OUT=$(run_block "$SH" "$TMP/block-desk-report.sh")
  check "[$SH] desk-report: the page, then the exit code" "$OUT" \
    "**Attention report · week of 2026-10-05 to 2026-10-11 (to date)**

1. Minutes spent answering: 12 min over 2 sittings
exit=0"
  check "[$SH] desk-report: runs report with no arguments" "$(cat "$STUB_DIR/hq-args" 2>/dev/null)" "report"
  OUT=$(run_block "$SH" "$TMP/block-desk-report.sh" STUB_RC=7)
  check "[$SH] desk-report: an unreachable store's exit code" "$(printf '%s\n' "$OUT" | tail -n 1)" "exit=7"

  OUT=$(run_block "$SH" "$TMP/block-desk-sweep-friday.sh" STUB_DOW=5)
  check "[$SH] desk-sweep-friday: a Friday offers the report" "$OUT" "offer=report"
  check "[$SH] desk-sweep-friday: the day is New York's" "$(cat "$STUB_DIR/date-args" 2>/dev/null)" "America/New_York|+%u"
  OUT=$(run_block "$SH" "$TMP/block-desk-sweep-friday.sh" STUB_DOW=4)
  check "[$SH] desk-sweep-friday: a Thursday offers nothing" "$OUT" "offer=none"
  OUT=$(run_block "$SH" "$TMP/block-desk-sweep-friday.sh" STUB_DOW=6)
  check "[$SH] desk-sweep-friday: a Saturday offers nothing" "$OUT" "offer=none"
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
| `attention.md` |
**`report`** (`report <YYYY-MM-DD>` for the week holding that day), as the whole message → load `attention.md`
Load `sweep.md` and follow "The sweep", then "Friday" (the weekly report's offer)
the weekly report, `attention.md`
(#1771)
NEEDLES
contract attention.md "$(cat "$ATTN_MD")" <<'NEEDLES'
Print the CLI's output and nothing else.
"$HQ" report --week 2026-10-05
`exit=4` (a bad date)
`exit=1` naming `migrate`
`exit=7` → `Store unreachable — can't build the report right now.`
not to be read daily
NEEDLES
contract sweep.md "$(cat "$SWEEP_MD")" <<'NEEDLES'
## Friday: the weekly report
(never a typed `sweep`)
`It's Friday: say report for this week's attention report.`
so the offer comes once a week
NEEDLES
contract "skill README" "$(cat "$SKILL_DIR/README.md")" <<'NEEDLES'
| `attention.md` |
NEEDLES

hq_t_finish "report-offline.test.sh"
