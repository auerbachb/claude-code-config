#!/usr/bin/env bash
# Source-only quota fixture group: forecast. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 17i. the burn-rate projection reaches the table and --json (#1701) ------
#
# The reader does not compute the pace — quotas-forecast.sh does, and its own
# suite covers the arithmetic. What is asserted here is the WIRING: that the
# window start each provider derives is recorded and handed over, that the
# three columns reach the table, that the fields reach --json, and that a run
# without the helper degrades to a table missing exactly those three columns
# rather than to a broken one.

reset_state
overage_case 40 50
run
check_contains "$OUT" "START" "the table has a START column"
check_contains "$OUT" "%/DAY" "and a %/DAY column"
check_contains "$OUT" "LEFT" "and a LEFT column"
check_not_contains "$OUT" "PROVIDER" "the PROVIDER column is gone"
check_not_contains "$OUT" "STATUS" "and so is the STATUS column"
# The reset cell is the collapsed form now: a weekday and a time, no date and
# no zone — the countdown beside it and the ET in the heading say the rest.
check_not_contains "$(table_only "$OUT")" "EDT" \
  "the table prints the reset without its date and zone"
check_contains "$(table_only "$OUT")" "8:00 PM" "keeping the weekday and the time"
# The window this reader placed the reading in is the reset minus the window
# length the payload reported — the figure every projection is measured from.
run --json
check_eq "$(field_of claude-one@example.com "7-day" window_start_epoch)" \
  "$(( WEEK_RESET - 604800 ))" "a claude weekly row carries its window start"
check_eq "$(field_of codex-one@example.com "7-day" window_start_epoch)" \
  "$(( WEEK_RESET - 604800 ))" "and so does a codex one, from its reported duration"
# 40 % of a week that opened 4d19h ago, projected to a rate and a runway. The
# exact figures are the forecast suite's business; what matters here is that
# they are NUMBERS on the row rather than nulls, which is what a run with no
# projection would leave.
check_eq "$(printf '%s' "$OUT" | jq -r \
  '.[] | select(.label == "claude-one@example.com") | .pct_per_day | type')" "number" \
  "--json carries pct_per_day as a number"
check_eq "$(field_of claude-one@example.com "7-day" usage_start_is_floor)" "true" \
  "the first run of a window is a floor start — nothing recorded reaches back further"
# The only snapshot is this run own reading, so the start is TODAY — day 5 of
# a window that opened 4d19h ago — carrying the <= that says usage may have
# begun earlier and nothing recorded can rule it out.
# GNU form first: GNU date reads `-r` as a FILENAME, so the BSD form tried
# first would print an unrelated file's weekday on the day one is named for
# this epoch second. BSD rejects `-d` outright, so this order never misreads.
ET_TODAY="$(TZ=America/New_York date -d "@$NOW" '+%a' 2>/dev/null \
  || TZ=America/New_York date -r "$NOW" '+%a' 2>/dev/null)"
check_eq "$(field_of claude-one@example.com "7-day" usage_start_display)" \
  "<=${ET_TODAY} d5" \
  "and the cell says so with a <= prefix on the day of the reading"
# The long reset string is still on the row even though the table shortened it.
check_contains "$(field_of claude-one@example.com "7-day" resets_at_et)" "EDT" \
  "--json keeps the full reset string"

