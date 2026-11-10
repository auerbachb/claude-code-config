#!/usr/bin/env bash
# Source-only quota fixture group: row-shape. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 12c. a row that cannot be built is never a successful empty report -----
# Every provider path funnels through emit_row. If its jq program cannot build a
# row, the old code appended nothing and the run still exited 0 — an empty table,
# or `[]` under --json, presented as a successful read. That is the report saying
# "no accounts" when it means "I could not build a row", and for a display-only
# tool whose whole output is a claim about accounts, it is the worst shape the
# failure could take. A jq that always fails is what that looks like from the
# script's side.

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config "$(account_json codex codex-one@example.com "$X1")"
run --json
check_eq "$RC" "0" "control(+): the same registry reports normally with a working jq"
check_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "control(+): and yields a row"

# Fails ONLY the `-nc` invocation, which in this script is emit_row and nothing
# else. A jq that fails outright would be caught by the registry checks long
# before any row is built, and this case would pass without ever reaching the
# guard it is named for.
real_jq="$(command -v jq)"
{
  printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do [[ "$a" == "-nc" ]] && exit 91; done\n'
  printf 'exec %s "$@"\n' "$real_jq"
} > "$BIN/jq"
chmod +x "$BIN/jq"
saved_path="$PATH"
PATH="$BIN:$PATH"
run --json
PATH="$saved_path"
rm -f "$BIN/jq"
check_eq "$RC" "70" "a row that cannot be built exits 70, not 0 with an empty report"
check_not_contains "$OUT" "[]" \
  "control(-): and does not print an empty JSON array as if the read succeeded"
check_contains "$ERR" "could not build" \
  "and names the account whose row was lost"

# --- 12b. no `column` degrades the table, it does not replace it ------------
# The fallback for a missing `column` printed the TSV header and then `cat` of
# the ROW FILE — which holds JSON objects, not the rendered columns. That is not
# an unaligned table, it is a different output wearing the table's header.

reset_state
X1="$(seed_codex_profile codex-one@example.com "$(codex_snapshot_primary_weekly)")"
write_config "$(account_json codex codex-one@example.com "$X1")"
# A `column` that always fails is what "column is unavailable" looks like from
# the script's side, without removing it from the sandbox PATH wholesale.
printf '#!/usr/bin/env bash\nexit 127\n' > "$BIN/column"
chmod +x "$BIN/column"
saved_path="$PATH"
PATH="$BIN:$PATH"
run
PATH="$saved_path"
rm -f "$BIN/column"
check_eq "$RC" "0" "a missing column does not fail the run"
check_contains "$OUT" "ACCOUNT" "the fallback still prints the table header"
check_contains "$OUT" "codex-one@example.com" "and the account's row"
check_not_contains "$OUT" '"provider"' \
  "control(-): and does NOT print the raw JSON rows under that header"
check_not_contains "$OUT" '{' \
  "control(-): no JSON object survives into the table output at all"

# --- 13b. one window is one row, even when it stands in for the weekly one ---
# A plan reporting a single sub-weekly window is valid input, and the weekly
# selector's longest-window fallback renders it as the weekly row. The short
# selector must not then pick the SAME slot: that prints one window as two rows
# differing only in the note, which reads as two windows.

reset_state
X1="$(seed_codex_profile codex-one@example.com \
  "$(jq -n --argjson five "$FIVE_RESET" \
     '{rateLimits: {limitId: "codex", planType: "pro",
                    primary: {usedPercent: 33, windowDurationMins: 300, resetsAt: $five},
                    secondary: null}}')")"
write_config "$(account_json codex codex-one@example.com "$X1")"
run --json --five-hour
check_eq "$RC" "0" "a single-short-window plan is not an error"
check_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.label == "codex-one@example.com")] | length')" "1" \
  "one reported window renders exactly one row under --five-hour"
check_eq "$(field_of codex-one@example.com "5-hour" used_pct)" "33" \
  "and it is the window the payload actually reported"
check_contains "$(field_of codex-one@example.com "5-hour" detail)" "no 7-day window reported" \
  "the row says it is standing in for a weekly one"
check_not_contains "$(field_of codex-one@example.com "5-hour" detail)" "reports no short window" \
  "control(-): and does not also claim the plan reports no short window"

# --- 13c. a short window is labelled from its duration, never assumed 5-hour -
# `--five-hour` names the FLAG, not a promise about the window that comes back.
# With two sub-weekly windows and no weekly one, the weekly row takes the longer
# (its longest-window fallback) and the short row takes what is left — and each
# is labelled from its own windowDurationMins. Calling a 60-minute window
# "5-hour" would put a real number under a heading that is wrong, which is the
# failure the whole selector exists to avoid.

reset_state
X1="$(seed_codex_profile codex-one@example.com \
  "$(jq -n --argjson five "$FIVE_RESET" \
     '{rateLimits: {limitId: "codex", planType: "pro",
                    primary: {usedPercent: 41, windowDurationMins: 300, resetsAt: $five},
                    secondary: {usedPercent: 12, windowDurationMins: 60, resetsAt: $five}}}')")"
write_config "$(account_json codex codex-one@example.com "$X1")"
run --json --five-hour
check_eq "$(field_of codex-one@example.com "5-hour" used_pct)" "41" \
  "the 300-minute window is the 5-hour row"
check_eq "$(field_of codex-one@example.com "1-hour" used_pct)" "12" \
  "and the 60-minute window is labelled 1-hour from its own duration"
check_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.window == "5-hour")] | length')" "1" \
  "control(-): the shorter window is not also emitted as a second 5-hour row"

