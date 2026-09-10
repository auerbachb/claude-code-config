#!/usr/bin/env bash
# quotas-forecast.test.sh — coverage for .claude/scripts/quotas-forecast.sh (issue #1701).
# catalog: tests — Tests `quotas-forecast.sh` — the burn-rate projection over `ai-quotas-history.jsonl`: where usage started in the current window and the floor marker when the record does not reach back to its start, percent per day, days left and the `resets first` cap, one reading per day with the later one winning, the series filters that keep another account, another pool and a previous window out, the null-everywhere cases (no window, no usage, a row that did not read), and the refusals that keep a broken run from printing an empty-but-successful document
#
# WHAT IS UNDER TEST
#
# This script turns a percentage into a pace, and a pace is the number the
# owner will act on when deciding whether to keep working on an account. The
# properties asserted here are the ones that keep it honest:
#
#   * the START is the earliest RECORDED usage in THIS window, and when the
#     record does not reach back to the window start it is marked as a FLOOR
#     and the rate is computed from the window start — the slowest pace the
#     evidence supports, never a faster one that would promise a longer
#     runway;
#   * ONE reading per day, the later one winning, so a hand-run reading
#     supersedes the morning job rather than competing with it;
#   * the series is filtered to this account, this pool, and this window —
#     a previous cycle, another account, or the other Cursor pool must never
#     contribute to a rate;
#   * `days_left` is a NUMBER or null, never the string the table prints:
#     "resets first" lives in `days_left_note`, so no consumer type-tests the
#     field;
#   * nothing is projected without a figure — a failed row, a 0 % row, or a
#     row whose window cannot be placed gets nulls, never a fabricated pace;
#   * a run that could not build a document REFUSES rather than printing an
#     empty one, because `{"rows":[]}` and "I failed" look identical to a
#     caller.
#
# HERMETIC. The history file is scratch state, HOME is redirected, and
# AI_QUOTAS_NOW freezes the clock — every window in these fixtures is
# expressed relative to a Monday 00:00 ET anchor, so `Wed d3` is an exact
# assertion rather than one that rots as the fixtures age.
#
# Run from anywhere: bash .claude/scripts/tests/quotas-forecast.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/quotas-forecast.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[[ -x "$SCRIPT" ]] || { echo "FAIL — $SCRIPT is not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAILED=0
ok()  { PASS=$((PASS + 1)); echo "ok   — $*"; }
bad() { FAILED=$((FAILED + 1)); echo "FAIL — $*" >&2; }

check_eq() { # <actual> <expected> <label>
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi
}
check_contains() { # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) bad "$3 (output did not contain '$2')" ;;
  esac
}

CASE_HOME="$TMP/home"
mkdir -p "$CASE_HOME/.claude"

# Monday 2026-09-07 00:00:00 EDT. Every fixture below is this plus a number of
# days, so the weekday assertions (`Wed d3`, `Tue d2`) are arithmetic rather
# than a lookup — and they hold whatever zone the runner is in, because the
# script formats in Eastern like the table it feeds.
WINDOW_START=1788753600
WEEK=604800
WINDOW_RESET=$(( WINDOW_START + WEEK ))

at_day() { # <days-since-window-start, may be fractional in halves> — epoch
  awk -v s="$WINDOW_START" -v d="$1" 'BEGIN { printf "%d", s + d * 86400 }'
}

# GNU form FIRST, deliberately. GNU date accepts `-r` and reads its argument as
# a FILENAME whose mtime to print, so the BSD form tried first would silently
# print an unrelated timestamp on any machine where a file happens to be named
# for the epoch second — the same trap ai-quotas.sh resolves by asking date(1)
# which dialect it is. BSD simply rejects `-d`, so this order never misreads.
utc_iso() { # <epoch>
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || true
}

HISTORY="$TMP/history.jsonl"

reset_history() { : > "$HISTORY"; }

# One recorded reading. The defaults are the account every fixture uses; the
# optional arguments exist for the isolation cases, which need a SECOND series
# in the same file. Passing `legacy` as the sixth writes the line WITHOUT
# `window_start_epoch`, which is the shape every line recorded before #1701
# has.
hist_line() { # <epoch> <used_pct> [<window>] [<label>] [<provider>] [legacy]
  local ts
  ts="$(utc_iso "$1")"
  jq -nc --arg ts "$ts" --argjson used "$2" \
    --arg window "${3:-7-day}" --arg label "${4:-claude-one@example.com}" \
    --arg provider "${5:-claude}" --arg legacy "${6:-}" \
    --argjson wstart "$WINDOW_START" --argjson reset "$WINDOW_RESET" \
    '{ts: $ts, provider: $provider, label: $label, nickname: null,
      window: $window, used_pct: $used, resets_at_epoch: $reset,
      source: "scheduled"}
     + (if $legacy == "legacy" then {} else {window_start_epoch: $wstart} end)' >> "$HISTORY"
}

# The live row, in the document shape ai-quotas.sh --json emits.
doc_with() { # <used_pct|null> [<status>] [<window_start|null>] [<reset|null>] [<window>] [<pool|null>]
  jq -nc --argjson used "$1" --arg status "${2:-ok}" \
    --argjson wstart "${3:-$WINDOW_START}" --argjson reset "${4:-$WINDOW_RESET}" \
    --arg window "${5:-7-day}" --arg pool "${6:-}" \
    '{schema_version: "1.0", threshold_pct: 20, basis: "…",
      rows: [{provider: "claude", label: "claude-one@example.com",
              nickname: null, reported_email: "claude-one@example.com",
              window: $window, pool: (if $pool == "" then null else $pool end),
              used_pct: $used,
              remaining_pct: (if $used == null then null else 100 - $used end),
              resets_at_epoch: $reset, window_start_epoch: $wstart,
              status: $status, overage: null}],
      cheapest_next: null}'
}

OUT=""; ERR=""; RC=0

run() { # <stdin-json> [args…] — never aborts the suite; sets OUT, ERR, RC
  local input="$1"; shift
  local errf="$TMP/run.err" inf="$TMP/run.in"
  printf '%s' "$input" > "$inf"
  OUT="$(HOME="$CASE_HOME" AI_QUOTAS_NOW="$NOW" \
        "$SCRIPT" --history "$HISTORY" "$@" < "$inf" 2>"$errf")"
  RC=$?
  ERR="$(cat "$errf")"
}

field() { # <name>
  printf '%s' "$OUT" | jq -r --arg f "$1" \
    '.rows[0][$f] | if . == null then "null" else tostring end' 2>/dev/null || true
}

echo "== quotas-forecast.sh =="

# --- 1. --help contract ------------------------------------------------------

HELP_ERR="$TMP/help.err"
HELP_OUT="$(HOME="$CASE_HOME" "$SCRIPT" --help 2>"$HELP_ERR")"
check_eq "$?" "0" "--help exits 0"
check_contains "$HELP_OUT" "quotas-forecast.sh" "--help names the script"
check_contains "$HELP_OUT" "EXIT STATUS" "--help carries the exit-status section"
check_contains "$HELP_OUT" "DEPENDENCIES" "--help carries the dependencies section"
check_eq "$(wc -c < "$HELP_ERR" | tr -d ' ')" "0" "--help writes nothing to stderr"

# --- 2. usage that started on day 3 ------------------------------------------
#
# The issue's own worked example: nothing on days 1 and 2, 25 % first seen on
# day 3, and today is day 4 still at 25 %. One day of usage at 25 % a day
# leaves three days of runway, and the window still has three and a half — so
# the projection is reported rather than capped.

NOW="$(at_day 3.5)"
reset_history
hist_line "$(at_day 0.5)" 0
hist_line "$(at_day 1.5)" 0
hist_line "$(at_day 2.5)" 25
run "$(doc_with 25)"
check_eq "$RC" "0" "a projected run exits 0"
check_eq "$(field usage_start_epoch)" "$(at_day 2.5)" \
  "usage_start_epoch is the first snapshot that showed usage"
check_eq "$(field usage_start_is_floor)" "false" \
  "and it is not a floor, because a zero-usage snapshot precedes it"
check_eq "$(field usage_start_day)" "3" "which was day 3 of the window"
check_eq "$(field usage_start_display)" "Wed d3" \
  "rendered as the weekday plus the day number"
check_eq "$(field pct_per_day)" "25" "25 % over one day is 25 % a day"
check_eq "$(field days_left)" "3" "and 75 % left at that pace is three more days"
check_eq "$(field days_left_note)" "null" "with no note, because the window outlasts it"

# The test plan asks for these as NUMBERS: a consumer that has to tell 25 from
# "25" is a consumer that will eventually compare a string to a threshold.
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].pct_per_day | type')" "number" \
  "--json carries pct_per_day as a number"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].days_left | type')" "number" \
  "and days_left as a number"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].usage_start_epoch | type')" "number" \
  "and usage_start_epoch as a number"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].usage_start_is_floor | type')" "boolean" \
  "and usage_start_is_floor as a boolean"
# The document is handed back whole: a caller that piped a document in must get
# one out, or the fields it already carried would be lost in the annotation.
check_eq "$(printf '%s' "$OUT" | jq -r '.cheapest_next | tostring')" "null" \
  "the rest of the document survives the annotation"
check_eq "$(printf '%s' "$OUT" | jq -r '.threshold_pct | tostring')" "20" \
  "including the fields this script has no opinion about"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].remaining_pct | tostring')" "75" \
  "and the row keeps every field it arrived with"

# --- 3. the projection that runs past the reset ------------------------------
#
# Day 2, 10 % spent in the one day of usage there has been: nine days of
# runway against five and a half days of window. The cell must say the window
# resets first rather than promising nine.

NOW="$(at_day 1.5)"
reset_history
hist_line "$(at_day 0.5)" 0
run "$(doc_with 10)"
check_eq "$RC" "0" "a capped projection still exits 0"
check_eq "$(field days_left)" "null" \
  "days_left is null when the pace would carry past the reset"
check_eq "$(field days_left_note)" "resets first" \
  "and the note says which — the phrase never lands in the numeric field"
check_eq "$(field pct_per_day)" "10" \
  "control(+): the rate itself is still reported"

# --- 4. a record that does not reach back to the window start ----------------
#
# The first snapshot of the window already shows 40 %, so usage may have
# started earlier than it and nothing here can tell. The cell is marked as a
# floor and the RATE is computed from the window start — 40 % over a day and a
# half rather than over the zero elapsed days since the snapshot, which would
# divide by the max(…, 1) guard and report 40 %/day.

NOW="$(at_day 1.5)"
reset_history
hist_line "$(at_day 1.5)" 40
run "$(doc_with 40)"
check_eq "$(field usage_start_is_floor)" "true" \
  "the earliest snapshot already showing usage marks the start as a floor"
check_eq "$(field usage_start_display)" "<=Tue d2" \
  "which the cell says with a <= prefix"
check_eq "$(field pct_per_day)" "26.7" \
  "and the rate is computed from the window start, not from the snapshot"
check_eq "$(field days_left)" "2.3" "60 % left at that pace is 2.3 days"

# --- 5. no history for the window --------------------------------------------
#
# A row whose window cannot be placed — no recorded window start, and no reset
# to derive one from — has nothing to project against. Every projection field
# is null, which the table renders as a dash, and the run still succeeds.

NOW="$(at_day 3.5)"
reset_history
run "$(doc_with 25 ok null null)"
check_eq "$RC" "0" "a row with no window still exits 0"
check_eq "$(field usage_start_epoch)" "null" "no window start means no usage start"
check_eq "$(field usage_start_display)" "null" "and nothing for the table to print"
check_eq "$(field pct_per_day)" "null" "no rate"
check_eq "$(field days_left)" "null" "and no runway"
check_eq "$(field days_left_note)" "null" "with no note claiming a reason it does not have"
# Declared, not absent. A consumer forced to test whether a key exists before
# reading it is one that will eventually read a partial row as a complete one.
check_eq "$(printf '%s' "$OUT" | jq -r \
  '.rows[0] | [has("usage_start_epoch"), has("usage_start_is_floor"),
               has("usage_start_day"), has("usage_start_display"),
               has("pct_per_day"), has("days_left"), has("days_left_note")]
   | all | tostring')" "true" \
  "every projection field is declared even when nothing could be projected"

# --- 6. the window LABEL derives a start when the row carries none -----------
#
# Older history lines predate `window_start_epoch`, and a row rebuilt from one
# can still be placed: a `7-day` window that resets at T started at T - 7 days.

NOW="$(at_day 3.5)"
reset_history
hist_line "$(at_day 0.5)" 0
hist_line "$(at_day 2.5)" 25
run "$(doc_with 25 ok null)"
check_eq "$(field usage_start_day)" "3" \
  "a row with no recorded window start is placed from its label and reset"
check_eq "$(field pct_per_day)" "25" "and projected exactly as a recorded one is"
check_eq "$(field usage_start_is_floor)" "false" \
  "control(+): the derived window start is real enough to place a day-1 zero in it"

# --- 6b. history lines written before #1701 still count ----------------------
#
# Those lines carry no `window_start_epoch`. They are still readable: a line is
# assigned to a window by its TIMESTAMP, and the window start comes from the
# row being projected. A reader that needed the field on every line would
# silently drop months of record the day it shipped.

NOW="$(at_day 3.5)"
reset_history
hist_line "$(at_day 0.5)" 0 "7-day" "claude-one@example.com" claude legacy
hist_line "$(at_day 2.5)" 25 "7-day" "claude-one@example.com" claude legacy
# The fixture builds its own premise: a line that still carried the field
# would pass this case for the wrong reason.
check_eq "$(jq -s '[.[] | select(has("window_start_epoch"))] | length' "$HISTORY")" "0" \
  "premise: neither recorded line carries a window start"
run "$(doc_with 25)"
check_eq "$(field usage_start_day)" "3" \
  "a line with no recorded window start is placed by its timestamp"
check_eq "$(field usage_start_is_floor)" "false" \
  "and the day-1 zero it records still rules out an earlier start"

# --- 7. one reading per day, the later one winning ---------------------------
#
# The unattended job reads at 08:00 and the owner runs /quotas at 20:00. Day
# granularity is what was asked for, so the later reading is the day - and a
# day whose first reading was 0 % is NOT the day usage started when the second
# says otherwise.

NOW="$(at_day 3.5)"
reset_history
hist_line "$(at_day 2.3)" 0
hist_line "$(at_day 2.8)" 25
run "$(doc_with 25)"
check_eq "$(field usage_start_epoch)" "$(at_day 2.8)" \
  "two readings on one day resolve to the later one"
check_eq "$(field usage_start_day)" "3" "on the day they were both taken"
check_eq "$(field usage_start_is_floor)" "true" \
  "and with no earlier day recorded, that start is a floor"

# --- 8. the series is this account, this pool, this window -------------------
#
# A file holding several accounts is the ordinary case, and a Cursor account
# contributes two pools against one billing cycle. A rate computed across
# either is the average of unrelated series.

NOW="$(at_day 3.5)"
reset_history
hist_line "$(at_day 0.5)" 90 "7-day" "other@example.com" claude
hist_line "$(at_day 0.5)" 90 "cursor-models" "claude-one@example.com" claude
hist_line "$(at_day 0.5)" 90 "5-hour"
hist_line "$(at_day 2.5)" 25
run "$(doc_with 25)"
check_eq "$(field usage_start_epoch)" "$(at_day 2.5)" \
  "another account, another pool, and another window are all excluded"
# The control is the same file with ONE of those lines moved into this row own
# series: if the exclusions were not doing the work, the day-1 line would win
# on both runs and this assertion would be identical to the one above.
reset_history
hist_line "$(at_day 0.5)" 90
hist_line "$(at_day 2.5)" 25
run "$(doc_with 25)"
check_eq "$(field usage_start_epoch)" "$(at_day 0.5)" \
  "control(+): the same reading INSIDE the series does move the usage start"

# A reading from the PREVIOUS cycle sits before this window opened. It
# describes a window that has already reset, and averaging it in would report
# a pace nobody set this week.
reset_history
hist_line "$(at_day -3)" 95
hist_line "$(at_day 2.5)" 25
run "$(doc_with 25)"
check_eq "$(field usage_start_epoch)" "$(at_day 2.5)" \
  "a reading from before the window start is not part of this window"

# --- 8b. a line that records a DIFFERENT window start is another cycle -------
#
# A line whose own `window_start_epoch` sits a full window away describes the
# cycle next door, however its timestamp reads. The check is NEAR, not equal —
# a provider is free to move a reset by an hour inside a cycle, and strict
# equality would drop every earlier line and report every day as a fresh floor
# start.

NOW="$(at_day 3.5)"
reset_history
# Same series, timestamp inside this window, but stamped with last week's
# window start. Written by hand because hist_line always stamps this cycle.
FOREIGN_TS="$(utc_iso "$(at_day 0.5)")"
jq -nc --arg ts "$FOREIGN_TS" --argjson wstart "$(( WINDOW_START - WEEK ))" \
  --argjson reset "$(( WINDOW_RESET - WEEK ))" \
  '{ts: $ts, provider: "claude", label: "claude-one@example.com", nickname: null,
    window: "7-day", used_pct: 90, resets_at_epoch: $reset,
    window_start_epoch: $wstart, source: "scheduled"}' >> "$HISTORY"
hist_line "$(at_day 2.5)" 25
run "$(doc_with 25)"
check_eq "$(field usage_start_epoch)" "$(at_day 2.5)" \
  "a line stamped with another cycle does not join this window"
# The tolerance half of the rule: the same line, stamped an hour off THIS
# cycle rather than a week off, is the same cycle and still counts.
reset_history
jq -nc --arg ts "$FOREIGN_TS" --argjson wstart "$(( WINDOW_START + 3600 ))" \
  --argjson reset "$(( WINDOW_RESET + 3600 ))" \
  '{ts: $ts, provider: "claude", label: "claude-one@example.com", nickname: null,
    window: "7-day", used_pct: 90, resets_at_epoch: $reset,
    window_start_epoch: $wstart, source: "scheduled"}' >> "$HISTORY"
hist_line "$(at_day 2.5)" 25
run "$(doc_with 25)"
check_eq "$(field usage_start_epoch)" "$(at_day 0.5)" \
  "control(+): a reset that merely drifted by an hour is still this cycle"

# --- 9. nothing is projected without a figure --------------------------------

NOW="$(at_day 3.5)"
reset_history
hist_line "$(at_day 2.5)" 25
run "$(doc_with 25 needs-login)"
check_eq "$(field pct_per_day)" "null" \
  "a row that did not read is not projected, whatever the history holds"
check_eq "$(field usage_start_epoch)" "null" "and carries no usage start"

reset_history
run "$(doc_with 0)"
check_eq "$(field pct_per_day)" "null" "a 0 % row has no pace to report"
check_eq "$(field days_left)" "null" \
  "and no runway — dividing by a zero rate would print an infinite one"

run "$(doc_with null)"
check_eq "$(field pct_per_day)" "null" "and neither has a row with no figure at all"

# --- 9b. a reading that is not inside its own window --------------------------
#
# The reset has passed and the provider is still reporting the old figure — the
# countdown says `reset`. That window is over: placing today in it would print
# `d9` of a seven-day window and measure a runway against a reset in the past.

NOW="$(at_day 8)"
reset_history
hist_line "$(at_day 2.5)" 25
run "$(doc_with 25)"
check_eq "$(field usage_start_day)" "null" \
  "a reading taken after its window reset is not projected"
check_eq "$(field pct_per_day)" "null" "and reports no pace for a window that is over"
# The control is the same fixture one day EARLIER, inside the window: without
# it this case would pass for any reason at all, including a broken projection.
NOW="$(at_day 6)"
run "$(doc_with 25)"
check_eq "$(field usage_start_day)" "3" \
  "control(+): the same reading inside the window is projected normally"

# --- 10. this run own reading counts as a snapshot ---------------------------
#
# The very first run has an empty history file, and a projection that needed
# yesterday to exist would print dashes on the day the owner installs this.

NOW="$(at_day 1.5)"
reset_history
run "$(doc_with 40)"
check_eq "$(field usage_start_day)" "2" \
  "with no history at all, the live reading is the only snapshot"
check_eq "$(field usage_start_is_floor)" "true" "and is a floor start"
check_eq "$(field pct_per_day)" "26.7" "projected from the window start"

# --- 11. a torn history line costs only itself -------------------------------

NOW="$(at_day 3.5)"
reset_history
printf 'this line is not json\n' >> "$HISTORY"
printf '5\n' >> "$HISTORY"
hist_line "$(at_day 0.5)" 0
hist_line "$(at_day 2.5)" 25
run "$(doc_with 25)"
check_eq "$RC" "0" "a torn history line does not fail the run"
check_eq "$(field usage_start_epoch)" "$(at_day 2.5)" \
  "and does not cost the projection the lines that do parse"

# --- 12. a bare rows array comes back as a bare rows array -------------------

NOW="$(at_day 3.5)"
reset_history
hist_line "$(at_day 0.5)" 0
hist_line "$(at_day 2.5)" 25
ARRAY_IN="$(printf '%s' "$(doc_with 25)" | jq -c '.rows')"
run "$ARRAY_IN"
check_eq "$(printf '%s' "$OUT" | jq -r 'type')" "array" \
  "an array in is an array out — no caller has to unwrap what it did not wrap"
check_eq "$(printf '%s' "$OUT" | jq -r '.[0].pct_per_day | tostring')" "25" \
  "and it is annotated exactly as a document row is"

# --- 13. refusals ------------------------------------------------------------

run '{"schema_version":"1.0"}'
check_eq "$RC" "5" "a document with no rows array is refused"
check_contains "$ERR" "rows" "and the refusal says what was expected"

run '["not-json'
check_eq "$RC" "5" "input that is not JSON at all is refused"

run "$(doc_with 25)" --bogus
check_eq "$RC" "3" "an unknown flag is a usage error"

run "$(doc_with 25)" --history
check_eq "$RC" "3" "and --history with no path is too"

# An unreadable history path is not a failure: the projection degrades to this
# run own reading, which is exactly what an empty history does.
OUT="$(HOME="$CASE_HOME" AI_QUOTAS_NOW="$(at_day 1.5)" \
      "$SCRIPT" --history "$TMP/no-such-history.jsonl" <<< "$(doc_with 40)" 2>/dev/null)"
check_eq "$?" "0" "a history file that does not exist does not fail the run"
check_eq "$(printf '%s' "$OUT" | jq -r '.rows[0].pct_per_day | tostring')" "26.7" \
  "it projects from the live reading alone"

# A clock override that is not epoch seconds falls back to the real clock and
# says so, rather than reaching jq as a string and aborting every comparison.
ERRF="$TMP/badnow.err"
OUT="$(HOME="$CASE_HOME" AI_QUOTAS_NOW="not-a-clock" \
      "$SCRIPT" --history "$HISTORY" <<< "$(doc_with 40)" 2>"$ERRF")"
check_eq "$?" "0" "an unusable AI_QUOTAS_NOW does not fail the run"
check_contains "$(cat "$ERRF")" "AI_QUOTAS_NOW" "and is refused on stderr"

# --- summary -----------------------------------------------------------------

echo
echo "passed: $PASS   failed: $FAILED"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
