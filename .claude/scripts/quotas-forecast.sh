#!/usr/bin/env bash
# quotas-forecast.sh — project each /quotas row forward from its recorded
# history: when usage started in this window, how fast it is being spent, and
# how many days are left at that pace (issue #1701).
# catalog: token-measurement — Annotate `ai-quotas.sh --json` rows with a burn-rate projection read from `~/.claude/ai-quotas-history.jsonl` — when usage started in the current window (with a `floor` marker when the record does not reach back to the window start), percent per day, and days left at that pace, capped by the window reset; informational only, never a dispatch or spend gate
#
# PURPOSE
#   `ai-quotas.sh` answers "how much is gone" and `quotas-cheapest-next.sh`
#   answers "what does continuing cost". Neither answers the question the
#   owner actually asks each morning: 57 % of a weekly cap means something
#   different on day two than on day six. This script reads the snapshot
#   history #1700 records and turns a percentage into a pace —
#
#     "usage started 3 days in on Wednesday, 25 % was used then, you will
#      make it 3 more days at this rate"
#
#   — as three fields per row that the table renders as START, %/DAY and LEFT.
#
#   INFORMATIONAL ONLY. The projection never gates dispatch, never pauses or
#   defers work, never downgrades a model, and never feeds
#   `credit-budget.sh`. Quota and spend authority stays where
#   `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority" puts it:
#   Anthropic's own in-app UI and upstream harness signals. The earlier
#   `/quota` skill was rolled back in issue #499 for gating agent decisions on
#   locally-read numbers; this one prints a pace and stops.
#
#   IT WRITES NOTHING. Not the history file, not `session-state.json`, not any
#   state at all — it reads the history and its stdin and prints a document.
#
# USAGE
#   ai-quotas.sh --json | quotas-forecast.sh [--history <path>]
#   quotas-forecast.sh --help | -h
#
#   --history <path>   Read snapshots from this file instead of
#                      ~/.claude/ai-quotas-history.jsonl. Highest precedence:
#                      an explicit flag beats AI_QUOTAS_HISTORY.
#
# INPUT
#   On stdin, either the DOCUMENT `ai-quotas.sh --json` emits ({rows: [...],
#   ...}) or a bare JSON ARRAY of its rows. Whichever arrives comes back in
#   the same shape, so a caller never has to unwrap or re-wrap.
#
#   Each row is read for `provider`, `label`, `window`, `pool`, `used_pct`,
#   `resets_at_epoch`, `window_start_epoch`, and `status`. Unknown fields are
#   carried through untouched: a row gains the projection and loses nothing.
#
# OUTPUT
#   The same document (or array), with these fields set on every row:
#
#     usage_start_epoch    When usage was first RECORDED in this window — the
#                          `ts` of the earliest snapshot showing more than
#                          0 %. Null when nothing can be projected.
#     usage_start_is_floor True when that earliest snapshot is also the
#                          earliest snapshot of the window, i.e. the record
#                          does not reach back far enough to prove usage did
#                          not start sooner. The rate is then computed from
#                          the WINDOW START, which is the slowest pace
#                          consistent with what was recorded, and the table
#                          prefixes the cell with a `<=`-style marker.
#     usage_start_day      Which day of the window that was, 1-based, so
#                          "Wed d3" reads as "day 3, a Wednesday".
#     usage_start_display  What the table shows, weekday plus day number.
#     pct_per_day          used_pct / max(days_since_start, 1), one decimal.
#     days_left            remaining_pct / pct_per_day in days, one decimal —
#                          or null when the pace would carry past the reset,
#                          in which case `days_left_note` says so.
#     days_left_note       "resets first", or null.
#
#   All seven are DECLARED on every row, null where nothing could be computed,
#   so `--json` has one shape whatever produced it. `days_left` is a NUMBER or
#   null — never the string "resets first"; that phrasing belongs to the table
#   and lives in `days_left_note`, so no consumer has to type-test the field.
#
# HOW THE PROJECTION IS BUILT
#   The series for a row is every history line with the same `provider`,
#   `label`, and `window` — where `window` is the row's POOL when the provider
#   has pools, exactly as #1700 records it — whose `ts` falls inside the
#   current window, PLUS this run's own live reading at `now`. Including the
#   live reading in memory rather than requiring it to be on disk is what
#   makes the projection correct on the very first run, and on a run whose
#   history append failed.
#
#   ONE READING PER DAY, THE LATER ONE WINNING. Snapshots are bucketed by day
#   of the window and the newest in each bucket is kept, so a hand-run
#   `/quotas` at 9 pm supersedes the unattended reading at 8 am rather than
#   competing with it. Day granularity is what the owner asked for; a rate
#   computed over two readings an hour apart would swing wildly.
#
#   THE WINDOW START comes from the row's `window_start_epoch` (recorded per
#   provider by `ai-quotas.sh`: `resets_at − 7 days` for a Claude week,
#   `resets_at − windowDurationMins × 60` for Codex, the billing-cycle start
#   for Cursor). A row that carries none — an older history line, a provider
#   that reported no duration — falls back to deriving it from the window
#   LABEL (`7-day`, `5-hour`) and the reset time. When neither works there is
#   no window to place a reading in, so every projection field stays null and
#   the table shows a dash: a rate over an unknown window is a guess.
#
#   A line that recorded its OWN window start is checked against this row's,
#   and dropped when the two are more than half a window apart — that is the
#   cycle next door, whatever its timestamp says. Near rather than equal on
#   purpose: a provider may move a reset by an hour inside a cycle, and strict
#   equality would then drop every earlier line and report every day as a
#   fresh floor start.
#
#   NOTHING IS PROJECTED without a figure: a row whose status is not `ok`,
#   whose `used_pct` is null or 0, or whose reading does not fall inside its
#   own window — a reset that has already passed while the provider still
#   reports the old figure — gets nulls. A 0 % row has no pace to report,
#   dividing by a zero rate would print an infinite runway, and placing today
#   in a window that is over would print `d9` of a seven-day one.
#
#   REMAINING IS FLOORED AT ZERO. Cursor percentages are not clamped at 100,
#   and a negative remainder divided by a positive rate prints a runway of
#   `-0.4` days. Nothing left is `0.0`.
#
# ENVIRONMENT (test seams; the defaults are what you want)
#   AI_QUOTAS_HISTORY   Snapshot history path
#                       (~/.claude/ai-quotas-history.jsonl). --history wins.
#   AI_QUOTAS_NOW       Epoch seconds to treat as "now", so a suite's
#                       assertions are exact rather than clock-dependent. A
#                       value that is not epoch seconds is refused on stderr
#                       and the real clock is used.
#
# EXIT STATUS
#   0   A document was written. A row nothing could be projected for is not a
#       failure: this is a report, never a gate.
#   3   Usage error — unknown flag, or --history without a path.
#   5   The tool cannot run: `jq` missing, stdin was not a rows array or a
#       document carrying one, or the annotated document could not be built.
#   70  --help header extraction produced no output (internal defect).
#
# DEPENDENCIES
#   bash 3.2+, jq, date(1) (either GNU or BSD dialect)
#
# SEE ALSO
#   ai-quotas.sh --help              the reader that produces the rows
#   quotas-cheapest-next.sh --help   the overage annotation, same row-in /
#                                    row-out shape
#   .claude/reference/ai-quotas.md   the history schema and the projection in
#                                    prose
#   .claude/skills/quotas/SKILL.md   the /quotas surface

set -uo pipefail

SELF_NAME="$(basename "$0")"

# Telemetry logs the script name and the action word only, never "$*": the
# arguments can name a history path under a home directory. Same reasoning as
# ai-quotas.sh.
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$SELF_NAME" "read" \
  2>/dev/null >> "${HOME:-/tmp}/.claude/script-usage.log" || true

print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

die_usage() {
  echo "${SELF_NAME}: $1" >&2
  echo "Run with --help for usage." >&2
  exit 3
}
die() { echo "${SELF_NAME}: $2" >&2; exit "$1"; }
warn() { echo "${SELF_NAME}: $1" >&2; }

# --- arg parsing -------------------------------------------------------------

HISTORY_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --history)
      [[ $# -ge 2 && -n "${2:-}" ]] || die_usage "--history requires a path"
      HISTORY_OVERRIDE="$2"; shift 2 ;;
    --history=*) HISTORY_OVERRIDE="${1#--history=}"
      [[ -n "$HISTORY_OVERRIDE" ]] || die_usage "--history requires a path"
      shift ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die 5 "'jq' not found on PATH"

HISTORY_FILE="$HISTORY_OVERRIDE"
if [[ -z "$HISTORY_FILE" ]]; then
  HISTORY_FILE="${AI_QUOTAS_HISTORY:-}"
fi
if [[ -z "$HISTORY_FILE" && -n "${HOME:-}" ]]; then
  HISTORY_FILE="${HOME}/.claude/ai-quotas-history.jsonl"
fi

# --- time --------------------------------------------------------------------

# Validated, not trusted: a non-numeric override would reach jq as a string and
# every comparison against it would be a jq type error, which would abort the
# program and print nothing at all. A bad override falls back to the real clock
# and says so once, exactly as ai-quotas.sh does.
now_seconds() {
  if [[ -n "${AI_QUOTAS_NOW:-}" ]]; then
    if [[ "$AI_QUOTAS_NOW" =~ ^[0-9]+$ ]]; then printf '%s' "$AI_QUOTAS_NOW"; return 0; fi
    warn "ignoring AI_QUOTAS_NOW='${AI_QUOTAS_NOW}' — not epoch seconds; using the real clock"
  fi
  date -u +%s
}

NOW="$(now_seconds)"
[[ "$NOW" =~ ^[0-9]+$ ]] || die 5 "could not read the current time from date(1)"

# Which date(1) dialect is on PATH, decided once. GNU accepts `-r` and reads
# its argument as a FILENAME, so falling through from BSD's `-r <epoch>` would
# silently print an unrelated file's mtime on the day such a file exists.
DATE_IS_GNU=0
if date --version 2>/dev/null | grep -i 'GNU coreutils' >/dev/null; then
  DATE_IS_GNU=1
fi

# The weekday of an instant in Eastern time — the same zone the table's reset
# column is formatted in, so "Wed" in START and "Wed" in RESETS mean the same
# Wednesday.
epoch_to_et_weekday() { # <epoch>
  local e="${1:-}"
  [[ -n "$e" && "$e" != "null" ]] || return 0
  if [[ "$DATE_IS_GNU" -eq 1 ]]; then
    TZ='America/New_York' date -d "@$e" '+%a' 2>/dev/null || true
  else
    TZ='America/New_York' date -r "$e" '+%a' 2>/dev/null || true
  fi
}

TMP="$(mktemp -d)" || die 5 "could not create a temp directory"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- input -------------------------------------------------------------------

IN="$TMP/in.json"
cat > "$IN"
# A document or a bare array, and nothing else. Refusing here is deliberate:
# an unrecognised stdin that produced an empty document would read to the
# caller as "no accounts", which is the one thing an advisory surface must
# never say when it means "I could not read the input".
SHAPE="$(jq -r 'if type == "array" then "array"
                elif type == "object" and (.rows | type == "array") then "doc"
                else "other" end' "$IN" 2>/dev/null || printf 'other')"
case "$SHAPE" in
  array|doc) ;;
  *) die 5 "stdin was neither a JSON array of rows nor a document carrying a rows array" ;;
esac

# --- history -----------------------------------------------------------------

# Every line that parses, as one array. `fromjson?` DROPS a line it cannot
# parse rather than aborting: a run killed mid-append can leave one torn line,
# and one torn line must not cost the projection every good line before it.
# The `type` guard is the other half — `fromjson?` catches only the PARSE
# error, so a line holding a bare `5` parses fine and then aborts jq on `.ts`.
HIST="$TMP/history.json"
printf '[]' > "$HIST"
if [[ -n "$HISTORY_FILE" && -r "$HISTORY_FILE" && -f "$HISTORY_FILE" ]]; then
  if ! jq -R -s -c '
        split("\n")
        | map(select(length > 0) | (fromjson? // empty))
        | map(select(type == "object"))' "$HISTORY_FILE" > "$HIST" 2>/dev/null; then
    warn "could not read $HISTORY_FILE — projecting from this run only"
    printf '[]' > "$HIST"
  fi
  [[ -s "$HIST" ]] || printf '[]' > "$HIST"
fi

# --- the projection ----------------------------------------------------------
#
# Written to a file rather than passed inline: bash 3.2 — the fleet's primary
# shell — scans command substitutions by counting parens, and this program is
# full of them.
#
# NO APOSTROPHES ANYWHERE IN THIS PROGRAM. It is written through a quoted
# heredoc here, but it is read by the same eyes that maintain the
# single-quoted jq programs next door, and one apostrophe in a comment there
# closes the shell string and hands the rest of the jq source to bash.
PROG="$TMP/forecast.jq"
cat > "$PROG" <<'JQ'
def as_num: if type == "number" then .
            elif type == "string" and test("^-?[0-9]+(\\.[0-9]+)?$") then tonumber
            else null end;

def round1: if . == null then null else (. * 10 | round) / 10 end;

# The window length a row LABEL implies, in seconds. Only the two shapes this
# reader emits are recognised — `7-day` (and `7-day (opus)`) and `<n>-hour` —
# because a label this script does not understand must produce no window
# rather than a plausible-looking wrong one.
def label_span:
  if type != "string" then null
  elif startswith("7-day") then 604800
  elif test("^[0-9]+-hour$") then (split("-")[0] | tonumber) * 3600
  else null end;

# The start of the window this row is reporting on. The recorded figure first
# — the provider told us the window length, so it is the only non-derived
# answer — then the label-and-reset derivation for a row (or an older history
# line) that carries none.
def window_start($row):
  ($row.window_start_epoch | as_num) as $recorded
  | if $recorded != null then $recorded
    else (($row.resets_at_epoch | as_num) as $reset
          | ($row.window // "" | label_span) as $span
          | if $reset != null and $span != null then $reset - $span else null end)
    end;

($rows_file[0] // []) as $rows
| ($hist_file[0] // []) as $hist
| ($ctx.now) as $now
| [ $rows[]
    | . as $row
    | (window_start($row)) as $wstart
    | ($row.used_pct | as_num) as $used
    | ($row.pool // $row.window) as $series
    # THIS reading has to fall inside THIS window, or there is nothing to
    # project. A row whose reset has already passed — the countdown says
    # `reset` and the provider has not refreshed the figure yet — describes a
    # window that is over: placing today in it would print `d9` of a seven-day
    # window and a runway measured against a reset in the past.
    | (($row.resets_at_epoch | as_num)) as $reset
    # How long this window is, when both ends are known. Used only to decide
    # how far a recorded window start may drift and still be this cycle.
    | (if $reset == null or $wstart == null then null else $reset - $wstart end) as $wspan
    | ($wstart != null and $now >= $wstart
       and ($reset == null or $now <= $reset)) as $in_window
    | (if ($row.status? // "") != "ok" or $used == null or $used <= 0
          or $wstart == null or ($in_window | not)
       then null
       else
         # The series: every recorded reading of THIS account and THIS pool
         # that falls inside the current window, plus this run own live
         # reading. The time filter is what keeps a previous cycle out — a
         # line recorded before the window opened describes a window that has
         # already reset.
         ([ $hist[]
            | select((.provider? // "") == ($row.provider // "")
                     and (.label? // "") == ($row.label // "")
                     and (.window? // "") == $series)
            # A line that recorded its own window start is checked against
            # this one, so a reading from a neighbouring cycle cannot join
            # the series on its timestamp alone. NEAR, not equal: a provider
            # is free to move a reset by an hour inside a cycle, and strict
            # equality would then drop every earlier line and report every
            # day as a fresh floor start. Half a window is the widest gap
            # that still cannot reach the cycle next door. A pre-#1701 line
            # carries no start at all and is left to the time filter below,
            # which is what keeps months of existing record readable.
            # `length` on a number is its absolute value, and it is in every
            # jq this repo may meet; `fabs` is not.
            | select(($wspan == null)
                     or (((.window_start_epoch | as_num) // $wstart) as $lw
                         | (($lw - $wstart) | length) < ($wspan / 2)))
            | {ts: ((.ts // "") | (fromdateiso8601? // null)),
               used: (.used_pct | as_num)}
            | select(.ts != null and .used != null
                     and .ts >= $wstart and .ts <= $now)
          ] + [{ts: $now, used: $used}])
         # One reading per day of the window, the later one winning. Two
         # readings an hour apart would otherwise set the pace for the day.
         | map(. + {day: (((.ts - $wstart) / 86400) | floor)})
         | group_by(.day)
         | map(sort_by(.ts) | last)
         | sort_by(.ts)
       end) as $series_days
    | (if $series_days == null then null
       else ($series_days | map(select(.used > 0)) | first) end) as $first_used
    | (if $first_used == null then null
       else ($first_used.ts == ($series_days | first | .ts)) end) as $is_floor
    # A floor start is not a measurement: the record simply does not reach
    # back far enough to show usage starting later. Pricing the rate from the
    # WINDOW START is the slowest pace consistent with what was recorded,
    # which is the honest direction to be wrong in — it never claims a longer
    # runway than the evidence supports.
    | (if $first_used == null then null
       elif $is_floor then $wstart
       else $first_used.ts end) as $rate_from
    | (if $rate_from == null then null
       else ([($now - $rate_from) / 86400, 1] | max) end) as $days_since
    | (if $days_since == null then null else ($used / $days_since) end) as $rate_raw
    # Remaining is FLOORED AT ZERO. A provider that reports past its own cap —
    # Cursor percentages are not clamped — would otherwise divide a negative
    # remainder by a positive rate and print a runway of `-0.4` days, which is
    # not a reading anybody can act on. Nothing left is `0.0`.
    | (if $rate_raw == null or $rate_raw <= 0 then null
       else (([100 - $used, 0] | max) / $rate_raw) end) as $left_raw
    | (if $reset == null then null else ($reset - $now) / 86400 end) as $to_reset
    | ($left_raw != null and $to_reset != null and $left_raw > $to_reset) as $resets_first
    | $row
      + {usage_start_epoch: (if $first_used == null then null else $first_used.ts end),
         usage_start_is_floor: $is_floor,
         usage_start_day: (if $first_used == null then null
                           else ((($first_used.ts - $wstart) / 86400) | floor) + 1 end),
         # Filled in by the caller, which owns the weekday formatting: jq
         # strflocaltime is not available on every jq this repo may meet.
         usage_start_display: null,
         pct_per_day: ($rate_raw | round1),
         days_left: (if $resets_first then null else ($left_raw | round1) end),
         days_left_note: (if $resets_first then "resets first" else null end)}
  ]
JQ

ROWS_IN="$TMP/rows-in.json"
if [[ "$SHAPE" == "doc" ]]; then
  jq -c '.rows' "$IN" > "$ROWS_IN" 2>/dev/null || die 5 "could not read the rows out of the document on stdin"
else
  cp "$IN" "$ROWS_IN"
fi

CTX="$TMP/ctx.json"
jq -nc --argjson now "$NOW" '{now: $now}' > "$CTX" 2>/dev/null \
  || die 5 "could not build the projection context"

# The rows and the history reach the program as NAMED arguments rather than on
# stdin, so the program reads the same way whichever shape arrived on stdin —
# and `-n` keeps jq from waiting on a stdin that has already been consumed.
ANNOTATED="$TMP/rows-out.json"
: > "$ANNOTATED"
jq -n --slurpfile rows_file "$ROWS_IN" --slurpfile hist_file "$HIST" \
  --argjson ctx "$(cat "$CTX")" -f "$PROG" \
  > "$ANNOTATED" 2>"$TMP/jq.err"
# Checked, not assumed. A jq program that failed here would otherwise leave an
# empty stdout that the caller reads as "no rows and no projection" — the
# report saying "nothing to say" when it means "I could not compute anything".
if [[ ! -s "$ANNOTATED" ]]; then
  die 5 "could not build the projection$(sed -n '1p' "$TMP/jq.err" 2>/dev/null | sed 's/^/: /')"
fi

# --- the START cell ----------------------------------------------------------
#
# Weekday formatting happens HERE rather than in jq: `strflocaltime` is a jq
# 1.6 builtin and nothing in this repo pins a jq version, so a 1.5 on the PATH
# would abort the whole program over a cosmetic string. date(1) is already a
# dependency and its dialect is already resolved above.
# One jq pass, not three per row: every row emits its epoch, its day number
# and its floor flag as one tab-separated line, in row order, and the loop
# below only formats. A `-` stands in for a row with nothing to render, so the
# line count always matches the row count and a row can never be skipped into
# the wrong slot.
CELLS="$TMP/cells.tsv"
if ! jq -r '.[]
      | [ (.usage_start_epoch | if . == null then "-" else (floor | tostring) end),
          (.usage_start_day | if . == null then "-" else tostring end),
          (if .usage_start_is_floor == true then "floor" else "exact" end) ]
      | @tsv' "$ANNOTATED" > "$CELLS" 2>/dev/null; then
  warn "could not read the usage starts back — reporting the projection without the start cells"
  : > "$CELLS"
fi

# The loop writes PLAIN LINES, one per row, and a single jq turns them into
# the array below — rather than one jq per row to quote one short string. An
# empty line is a row with nothing to render; the cells themselves are a
# weekday, a `d`, digits and an optional `<=`, so no line can carry a tab or a
# newline that would break the mapping back.
CELL_LINES="$TMP/cells.txt"
: > "$CELL_LINES"
{
  while IFS=$'\t' read -r start day floor_flag; do
    if [[ -z "$start" || "$start" == "-" || -z "$day" || "$day" == "-" ]]; then
      printf '\n'; continue
    fi
    weekday="$(epoch_to_et_weekday "$start")"
    # A weekday date(1) could not format leaves the day number, which is the
    # part that carries the information. Dropping the whole cell over a
    # missing three-letter abbreviation would hide a start we do know.
    cell="d${day}"
    [[ -z "$weekday" ]] || cell="${weekday} d${day}"
    # `<=`, the ASCII spelling of the mathematical symbol, and deliberately
    # not the symbol itself. The table is aligned by `column -t`, which pads
    # by counting BYTES under the C locale this fleet runs in — a 3-byte
    # character in one cell shifts every column to its right on that row
    # only, so the marker that says "we are not sure it started this late"
    # would be paid for in a table nobody can read across. The meaning is
    # the same and it survives a pipe into anything.
    [[ "$floor_flag" != "floor" ]] || cell="<=${cell}"
    printf '%s\n' "$cell"
  done < "$CELLS"
} > "$CELL_LINES"

DISPLAYS="$TMP/displays.json"
# `.[:-1]` drops the empty element the trailing newline produces, so the array
# is exactly one entry per row.
if ! jq -R -s 'split("\n") | .[:-1] | map(if . == "" then null else . end)' \
      "$CELL_LINES" > "$DISPLAYS" 2>/dev/null; then
  printf '[]' > "$DISPLAYS"
fi
# A malformed array here would take the merge below down with it, and the merge
# failing is what drops every start cell at once.
jq -e 'type == "array"' "$DISPLAYS" >/dev/null 2>&1 || printf '[]' > "$DISPLAYS"

WITH_DISPLAY="$TMP/rows-display.json"
if ! jq --slurpfile d "$DISPLAYS" \
      '[ to_entries[] | .value + {usage_start_display: ($d[0][.key] // null)} ]' \
      "$ANNOTATED" > "$WITH_DISPLAY" 2>/dev/null || [[ ! -s "$WITH_DISPLAY" ]]; then
  warn "could not render the usage-start cells — reporting the projection without them"
  cp "$ANNOTATED" "$WITH_DISPLAY"
fi

OUT="$TMP/out.json"
: > "$OUT"
if [[ "$SHAPE" == "doc" ]]; then
  jq --slurpfile rows "$WITH_DISPLAY" '. + {rows: $rows[0]}' "$IN" > "$OUT" 2>/dev/null
else
  cp "$WITH_DISPLAY" "$OUT" 2>/dev/null
fi
# Checked, never assumed. An empty stdout here reads to the caller as "no rows
# and no projection" — the report saying "nothing to say" when it means "I
# could not build the document".
[[ -s "$OUT" ]] || die 5 "could not build the projected document"
cat "$OUT"
exit 0
