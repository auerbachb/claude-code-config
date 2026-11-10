#!/usr/bin/env bash
# skill-usage-merge.test.sh — unit tests for skill-usage-merge.sh (issue #572)
# catalog: tests — Tests for `skill-usage-merge.sh`
#
# Covers the merge semantics the issue's AC pins down:
#   - log: line-level union, exact-line dedupe, chronological order
#   - csv (sum): use_count summed, last_used = max (real date beats "never"),
#     start_date = min
#   - csv (recompute): idempotent under full overlap; preserves CSV-only
#     baseline counts (no log lines behind them); adds rows for log-only skills
#   - fresh machine (no live files) degrades to a copy
#   - --dry-run writes nothing; real runs back up live files first
#   - usage/environment error exits
#
# Runs hermetically inside a temp HOME. No network, no git, no gh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE="$SCRIPT_DIR/../skill-usage-merge.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  echo "  ok: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1" >&2
}

assert_eq() {
  # assert_eq <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    ok "$1"
  else
    fail "$1 — expected [$2], got [$3]"
  fi
}

csv_field() {
  # csv_field <file> <skill> <1-based-field>
  # tr strips the \r that csv.writer row endings (CRLF, same as the tracker
  # writes) leave on the final field.
  awk -F, -v s="$2" -v f="$3" '$1 == s { print $f }' "$1" | tr -d '\r'
}

fresh_home() {
  rm -rf "$WORK/home"
  mkdir -p "$WORK/home/.claude"
}

# ---- fixtures ---------------------------------------------------------------
mkdir -p "$WORK/other"
# "other" machine: May–June history, one line shared with live.
printf '2026-05-01T18:02:00Z\twrap\told-1\n2026-05-02T00:00:00Z\tprompt\told-2\n2026-06-01T00:00:00Z\twrap\tshared\n' \
  > "$WORK/other/skill-usage.log"
printf 'skill_name,start_date,use_count,last_used\nwrap,2026-05-01,2,2026-06-01\nprompt,2026-05-01,1,2026-05-02\nlessons,2026-03-01,0,never\n' \
  > "$WORK/other/skill-usage.csv"

seed_live() {
  # live machine: July history + the shared line; later start_date, one
  # skill (lessons) known only as never-used.
  printf '2026-07-10T01:00:00Z\twrap\tnew-1\n2026-07-12T02:00:00Z\tfixpr\tnew-2\n2026-06-01T00:00:00Z\twrap\tshared\n' \
    > "$WORK/home/.claude/skill-usage.log"
  printf 'skill_name,start_date,use_count,last_used\nwrap,2026-04-10,2,2026-07-10\nfixpr,2026-04-10,1,2026-07-12\nlessons,2026-04-10,0,never\n' \
    > "$WORK/home/.claude/skill-usage.csv"
}

# ---- 1. sum-mode disjoint merge (the machine-move path) ----------------------
echo "test: sum-mode merge"
fresh_home
seed_live
HOME="$WORK/home" bash "$MERGE" --log "$WORK/other/skill-usage.log" \
  --csv "$WORK/other/skill-usage.csv" > "$WORK/out1.txt"

LOG="$WORK/home/.claude/skill-usage.log"
CSV="$WORK/home/.claude/skill-usage.csv"

assert_eq "log union deduped (3+3 with 1 shared -> 5)" "5" "$(wc -l < "$LOG" | tr -d ' ')"
assert_eq "log chronological" "$(sort "$LOG")" "$(cat "$LOG")"
assert_eq "first line is the old machine's May 1 entry" \
  "2026-05-01T18:02:00Z" "$(head -1 "$LOG" | cut -f1)"
assert_eq "use_count summed (wrap 2+2)" "4" "$(csv_field "$CSV" wrap 3)"
assert_eq "use_count summed (fixpr 1+0)" "1" "$(csv_field "$CSV" fixpr 3)"
assert_eq "last_used = max (wrap)" "2026-07-10" "$(csv_field "$CSV" wrap 4)"
assert_eq "last_used never+never stays never (lessons)" "never" "$(csv_field "$CSV" lessons 4)"
assert_eq "start_date = min (wrap)" "2026-04-10" "$(csv_field "$CSV" wrap 2)"
assert_eq "start_date = min (lessons, other older)" "2026-03-01" "$(csv_field "$CSV" lessons 2)"
assert_eq "other-only skill row added (prompt)" "1" "$(csv_field "$CSV" prompt 3)"
BACKUPS="$(find "$WORK/home/.claude" -name 'skill-usage.log.bak.*' | wc -l | tr -d ' ')"
assert_eq "log backup created" "1" "$BACKUPS"

# ---- 2. recompute idempotency + baseline preservation -----------------------
echo "test: recompute (restore path)"
fresh_home
# Live CSV carries a baseline count (37) far above the log's 1 line for wrap —
# e.g. the #431 fallback baseline. Restore must never zero it.
printf '2026-07-16T02:00:00Z\twrap\ts1\n' > "$WORK/home/.claude/skill-usage.log"
printf 'skill_name,start_date,use_count,last_used\nwrap,2026-05-01,37,2026-07-16\nprompt,2026-05-01,25,2026-06-26\n' \
  > "$WORK/home/.claude/skill-usage.csv"
cp "$WORK/home/.claude/skill-usage.log" "$WORK/snap.log"
cp "$WORK/home/.claude/skill-usage.csv" "$WORK/snap.csv"
# Snapshot also carries a log-only skill the CSVs have never seen.
printf '2026-07-01T00:00:00Z\tstatus\ts2\n' >> "$WORK/snap.log"

HOME="$WORK/home" bash "$MERGE" --log "$WORK/snap.log" --csv "$WORK/snap.csv" \
  --csv-counts recompute > /dev/null
CSV="$WORK/home/.claude/skill-usage.csv"
assert_eq "baseline count preserved (wrap 37 > log 1)" "37" "$(csv_field "$CSV" wrap 3)"
assert_eq "baseline count preserved (prompt 25, 0 log lines)" "25" "$(csv_field "$CSV" prompt 3)"
assert_eq "log-only skill gains a row (status)" "1" "$(csv_field "$CSV" status 3)"
assert_eq "log-only skill dates from log (status)" "2026-07-01" "$(csv_field "$CSV" status 4)"

cp "$CSV" "$WORK/pass1.csv"
cp "$WORK/home/.claude/skill-usage.log" "$WORK/pass1.log"
HOME="$WORK/home" bash "$MERGE" --log "$WORK/snap.log" --csv "$WORK/snap.csv" \
  --csv-counts recompute > /dev/null
if diff -q "$WORK/pass1.csv" "$CSV" > /dev/null \
   && diff -q "$WORK/pass1.log" "$WORK/home/.claude/skill-usage.log" > /dev/null; then
  ok "recompute is idempotent"
else
  fail "recompute is idempotent — second pass changed files"
fi

# ---- 3. fresh machine degrades to a copy ------------------------------------
echo "test: fresh machine restore"
fresh_home
HOME="$WORK/home" bash "$MERGE" --log "$WORK/snap.log" --csv "$WORK/snap.csv" \
  --csv-counts recompute > /dev/null
assert_eq "fresh log equals snapshot (sorted)" \
  "$(sort "$WORK/snap.log")" "$(cat "$WORK/home/.claude/skill-usage.log")"
assert_eq "fresh csv has snapshot counts (wrap)" "37" \
  "$(csv_field "$WORK/home/.claude/skill-usage.csv" wrap 3)"

# ---- 4. dry-run writes nothing ------------------------------------------------
echo "test: dry-run"
fresh_home
seed_live
BEFORE_LOG="$(cat "$WORK/home/.claude/skill-usage.log")"
BEFORE_CSV="$(cat "$WORK/home/.claude/skill-usage.csv")"
HOME="$WORK/home" bash "$MERGE" --log "$WORK/other/skill-usage.log" \
  --csv "$WORK/other/skill-usage.csv" --dry-run > "$WORK/dry.txt"
assert_eq "dry-run left log untouched" "$BEFORE_LOG" "$(cat "$WORK/home/.claude/skill-usage.log")"
assert_eq "dry-run left csv untouched" "$BEFORE_CSV" "$(cat "$WORK/home/.claude/skill-usage.csv")"
BACKUPS="$(find "$WORK/home/.claude" -name '*.bak.*' | wc -l | tr -d ' ')"
assert_eq "dry-run made no backups" "0" "$BACKUPS"
if grep -q "dry-run: no files written" "$WORK/dry.txt"; then
  ok "dry-run announces itself"
else
  fail "dry-run announces itself"
fi

# ---- 5. error exits ------------------------------------------------------------
echo "test: error handling"
set +e
HOME="$WORK/home" bash "$MERGE" > /dev/null 2>&1
assert_eq "no args -> usage exit 2" "2" "$?"
HOME="$WORK/home" bash "$MERGE" --log "$WORK/does-not-exist.log" > /dev/null 2>&1
assert_eq "missing input file -> env exit 3" "3" "$?"
HOME="$WORK/home" bash "$MERGE" --log "$WORK/snap.log" --csv-counts bogus > /dev/null 2>&1
assert_eq "bad --csv-counts -> usage exit 2" "2" "$?"
set -e

# ---- summary ---------------------------------------------------------------
echo ""
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
