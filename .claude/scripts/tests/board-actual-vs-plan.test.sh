#!/usr/bin/env bash
# catalog: tests — Fixture tests for the /board actual-against-plan cell and round roll-up: overrun-check.sh --actual-cell arithmetic, em dash for an unreadable start or bound, and the roll-up partition (under + over + unreadable = delivered)
# Fixture tests for the finished-row Remaining cell (time-estimates.md §"Completed rows").
# The helpers under test are extracted from the real .claude/skills/board/SKILL.md block, so
# the spec and the code cannot drift apart silently. The arithmetic itself is the real
# overrun-check.sh --actual-cell mode; nothing here re-implements it.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$REPO_ROOT/.claude/skills/board/SKILL.md"
OVERRUN="$REPO_ROOT/.claude/scripts/overrun-check.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/board-actual-vs-plan.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAILS=0
PASSES=0

expect() {  # expect <name> <want> <got>
  if [[ "$2" == "$3" ]]; then
    PASSES=$((PASSES + 1))
  else
    FAILS=$((FAILS + 1))
    echo "FAIL: $1: want [$2] got [$3]" >&2
  fi
}

# --- overrun-check.sh --actual-cell: the arithmetic --------------------------------------------
S=2026-11-14T10:00:00Z
expect "under plan, floored minutes" "74 min vs plan 90" \
  "$("$OVERRUN" --actual-cell --bound-min 90 --started-at $S --ended-at 2026-11-14T11:14:30Z)"
expect "exactly on the bound is under plan" "90 min vs plan 90" \
  "$("$OVERRUN" --actual-cell --bound-min 90 --started-at $S --ended-at 2026-11-14T11:30:00Z)"
expect "over by 22 minutes" "+22 min over plan" \
  "$("$OVERRUN" --actual-cell --bound-min 90 --started-at $S --ended-at 2026-11-14T11:52:00Z)"
expect "over by under a minute" "+<1 min over plan" \
  "$("$OVERRUN" --actual-cell --bound-min 90 --started-at $S --ended-at 2026-11-14T11:30:20Z)"
expect "unparseable start prints nothing" "" \
  "$("$OVERRUN" --actual-cell --bound-min 90 --started-at garbage --ended-at 2026-11-14T11:30:20Z)"
expect "end before start prints nothing" "" \
  "$("$OVERRUN" --actual-cell --bound-min 90 --started-at $S --ended-at 2026-11-14T09:00:00Z)"
"$OVERRUN" --actual-cell --bound-min 90 --started-at $S >/dev/null 2>&1
expect "missing --ended-at is a usage error" "3" "$?"
"$OVERRUN" --actual-cell --readout --bound-min 90 --started-at $S --ended-at 2026-11-14T11:00:00Z >/dev/null 2>&1
expect "--actual-cell refuses to combine with --readout" "3" "$?"

# --- board helpers, extracted from SKILL.md -----------------------------------------------------
awk '/^actual_cell\(\) \{/{p=1} p{print} p && /^rollup_line\(\) \{/{r=1} r && /^\}$/{exit}' "$SKILL" > "$WORK/helpers.sh"
if ! grep -q '^actual_cell() {' "$WORK/helpers.sh" || ! grep -q '^rollup_line() {' "$WORK/helpers.sh"; then
  echo "FAIL: could not extract actual_cell/rollup_line from $SKILL" >&2
  exit 1
fi
export OVERRUN_CHECK_SH="$OVERRUN"
eval "$(cat "$WORK/helpers.sh")"

expect "actual_cell: valid row" "74 min vs plan 90" \
  "$(actual_cell 90 $S 2026-11-14T11:14:30Z)"
expect "actual_cell: unestimated (no bound) renders em dash" "—" \
  "$(actual_cell "" $S 2026-11-14T11:14:30Z)"
expect "actual_cell: missing start renders em dash" "—" \
  "$(actual_cell 90 "" 2026-11-14T11:14:30Z)"
expect "actual_cell: missing mergedAt renders em dash" "—" \
  "$(actual_cell 90 $S "")"
expect "actual_cell: unreadable start renders em dash" "—" \
  "$(actual_cell 90 garbage 2026-11-14T11:14:30Z)"

expect "rollup: the example round" "3 delivered: 2 under plan, 1 over by 22 min" \
  "$(rollup_line "74 min vs plan 90" "+22 min over plan" "88 min vs plan 90")"
expect "rollup: several overruns sum their minutes" "2 delivered: 0 under plan, 2 over by 27 min" \
  "$(rollup_line "+22 min over plan" "+5 min over plan")"
expect "rollup: one under-a-minute overrun" \
  "1 delivered: 0 under plan, 1 over, each by <1 min" \
  "$(rollup_line "+<1 min over plan")"
expect "rollup: several under-a-minute overruns are never summed" \
  "2 delivered: 0 under plan, 2 over, each by <1 min" \
  "$(rollup_line "+<1 min over plan" "+<1 min over plan")"
expect "rollup: whole minutes summed, under-a-minute overruns counted apart" \
  "3 delivered: 0 under plan, 3 over by 22 min plus 1 under a minute each" \
  "$(rollup_line "+<1 min over plan" "+20 min over plan" "+2 min over plan")"
expect "rollup: unreadable rows are named, never counted as under plan" \
  "3 delivered: 1 under plan, 1 over by 4 min, 1 without a readable plan or start" \
  "$(rollup_line "—" "+4 min over plan" "30 min vs plan 60")"
expect "rollup: no delivered rows prints nothing" "" "$(rollup_line)"

# Partition invariant: under + over + unreadable always equals the delivered count.
PARTITION_OK=true
for CASE in "74 min vs plan 90|+22 min over plan|—" "—|—" "+<1 min over plan|90 min vs plan 90"; do
  IFS='|' read -r -a CELLS <<< "$CASE"
  LINE=$(rollup_line "${CELLS[@]}")
  DELIVERED=${LINE%% delivered:*}
  [[ "$DELIVERED" == "${#CELLS[@]}" ]] || PARTITION_OK=false
done
expect "rollup: delivered count equals the number of rows" "true" "$PARTITION_OK"

echo "board-actual-vs-plan: $PASSES passed, $FAILS failed"
[[ "$FAILS" -eq 0 ]]
