#!/usr/bin/env bash
# Source-only quota fixture group: overage. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 16. the overage column and the cheapest-next hint (#1669) ---------------
# The issue's own worked example: one Claude account at 5 % remaining, one
# Codex account at 60 %. The Codex account should win — it still has room AND
# the month's free reset is unspent — and the hint should say both.
#
# Discriminating on purpose: the Claude account is the one at 5 %, so a
# selector that simply picked the FIRST row, or the one with the least left,
# would name it and fail here.



overage_case 95 40
run
check_eq "$RC" "0" "the drained-Claude / roomy-Codex table exits 0"
check_contains "$OUT" "OVERAGE" "the table has an Overage column"
check_contains "$OUT" "API rate" "the claude row prices its overage at the API rate"
check_contains "$OUT" "1 free reset" "and the codex row shows the month's free reset"
check_contains "$OUT" \
  "Cheapest to continue on: codex-one@example.com (60 % weekly left, 1 free reset this month)" \
  "and the hint names the codex account, with both reasons"
check_contains "$OUT" "never switches accounts" \
  "and says at the point of use that it never switches, buys, or gates"
check_not_contains "$OUT" "Cheapest to continue on: claude-one@example.com" \
  "control(-): the account at 5 % is not offered as the cheapest one"

run --json
check_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.overage != null)] | length')" "2" \
  "--json carries an overage object on every row"
check_eq "$(printf '%s' "$OUT" | jq -r '.[] | select(.provider == "claude") | .overage.label')" \
  "API rate" "the claude row's overage label is the API rate"
check_eq "$(printf '%s' "$OUT" | jq -r '.[] | select(.provider == "codex") | .overage.label')" \
  "1 free reset" "the codex row's overage label is the free reset"
check_eq "$(printf '%s' "$OUT" | jq -r '.[] | select(.provider == "codex") | .overage.last_verified')" \
  "2026-09-09" "and every priced row carries the date its price was verified"
check_contains "$(printf '%s' "$OUT" | jq -r '.[] | select(.provider == "codex") | .overage.source')" \
  "help.openai.com" "and the source URL that price came from"
check_eq "$(printf '%s' "$DOC" | jq -r '.cheapest_next.provider')" "codex" \
  "--json carries cheapest_next at the top level"
check_eq "$(printf '%s' "$DOC" | jq -r '.threshold_pct')" "20" \
  "and the threshold it was decided against"
check_contains "$(printf '%s' "$DOC" | jq -r '.cheapest_next.basis')" "do not convert" \
  "and states its basis rather than pretending the units match"

# Every account well above the threshold: nothing prints. A hint offered when
# nobody needs one is a line the reader learns to skip.
overage_case 10 20
run
check_eq "$RC" "0" "with every account above the threshold the run still exits 0"
check_contains "$OUT" "OVERAGE" "the overage column is still rendered"
check_not_contains "$OUT" "Cheapest to continue on:" \
  "but no cheapest-next line is printed"
run --json
check_eq "$(printf '%s' "$DOC" | jq -r '.cheapest_next | tostring')" "null" \
  "and --json reports cheapest_next as null"

# Boundary: exactly AT the threshold fires it. An account sitting on the line
# is the case the hint exists for, and a strict comparison would stay silent.
overage_case 80 40
run
check_contains "$OUT" "Cheapest to continue on:" \
  "an account exactly at the threshold fires the hint (boundary inclusive)"

# The helper going missing degrades the report; it never fails it, and never
# silently drops a column the header still promises. Driven through the
# AI_QUOTAS_CHEAPEST_BIN seam rather than by chmod-ing the real script, so an
# interrupted suite cannot leave a repo file non-executable behind it.
overage_case 95 40
CHEAPEST_BIN_OVERRIDE="$TMP/no-such-cheapest.sh"
run
check_eq "$RC" "0" "an unavailable cheapest-next helper does not fail the report"
check_contains "$ERR" "DEGRADED" "and the degradation is stated on stderr"
check_contains "$OUT" "claude-one@example.com" "every account still reports"
check_contains "$OUT" "OVERAGE" "the column header is still printed"
check_not_contains "$OUT" "Cheapest to continue on:" \
  "and no hint is invented without prices to base it on"
run --json
check_eq "$(printf '%s' "$DOC" | jq -r '[.rows[] | select(.overage == null)] | length')" "2" \
  "--json still declares overage on every row, as null"
check_eq "$(printf '%s' "$DOC" | jq -r '.cheapest_next | tostring')" "null" \
  "and cheapest_next is null, not absent"

# A helper that RUNS and fails is a different failure from one that is
# missing, and it must degrade the same way rather than emitting the empty
# document its broken output would otherwise produce.
printf '#!/usr/bin/env bash\necho "boom" >&2\nexit 1\n' > "$TMP/broken-cheapest.sh"
chmod +x "$TMP/broken-cheapest.sh"
CHEAPEST_BIN_OVERRIDE="$TMP/broken-cheapest.sh"
run
CHEAPEST_BIN_OVERRIDE=""
check_eq "$RC" "0" "a cheapest-next helper that exits non-zero does not fail the report"
check_contains "$ERR" "DEGRADED" "and that degradation is stated too"
check_contains "$ERR" "boom" "with the helper's own message passed through"
check_contains "$OUT" "codex-one@example.com" "every account still reports"

# A helper that reports SUCCESS while dropping the rows is the dangerous
# shape: the document is well-formed, so a shape-only check passes it, and the
# populated account list prints as no accounts at all with exit 0. The row
# count is what catches it — and the message must not blame an exit code that
# was zero.
cat > "$TMP/empty-rows-cheapest.sh" <<'EMPTY_ROWS_HELPER'
#!/usr/bin/env bash
cat >/dev/null
echo '{"schema_version":"1.0","threshold_pct":20,"basis":"x","rows":[],"cheapest_next":null}'
EMPTY_ROWS_HELPER
chmod +x "$TMP/empty-rows-cheapest.sh"
CHEAPEST_BIN_OVERRIDE="$TMP/empty-rows-cheapest.sh"
run
check_eq "$RC" "0" "a helper that drops every row does not fail the report"
check_contains "$ERR" "DEGRADED" "the dropped rows are stated as a degradation"
check_not_contains "$ERR" "failed (exit" "and are not reported as an exit-code failure"
check_contains "$OUT" "claude-one@example.com" "every account still reports"
check_contains "$OUT" "codex-one@example.com" "including the second one"
run --json
CHEAPEST_BIN_OVERRIDE=""
check_eq "$(printf '%s' "$DOC" | jq -r '.rows | length')" "2" \
  "--json carries the real rows rather than the helper's empty array"

