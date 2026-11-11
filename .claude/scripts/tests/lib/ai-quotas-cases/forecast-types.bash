#!/usr/bin/env bash
# Source-only quota fixture group: forecast-types. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

cat > "$TMP/badtype-forecast.sh" <<'BADTYPE_FORECAST'
#!/usr/bin/env bash
jq '.rows |= map(. + {pct_per_day: [], days_left: {}, usage_start_display: 7, days_left_note: "later"})'
BADTYPE_FORECAST
chmod +x "$TMP/badtype-forecast.sh"
overage_case 40 50
FORECAST_BIN_OVERRIDE="$TMP/badtype-forecast.sh"
run
check_eq "$RC" "0" "a projection with the wrong field types does not fail the report"
check_contains "$ERR" "DEGRADED" "it is rejected as DEGRADED"
check_eq "$(table_only "$OUT" | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "%/DAY") c = i; next }
                                     c { print $c }' | sort -u | tr -d '\n')" "-" \
  "and no structured value reaches the %/DAY column"
check_contains "$OUT" "40%" "while every figure that was read still prints"
FORECAST_BIN_OVERRIDE=""

# `usage_start_day` is ONE-based. A stub that fills every field with a valid
# value except a day of 0 discriminates the key-specific bound from the
# generic non-negative check: pre-fix, 0 passed as a number >= 0.
cat > "$TMP/dayzero-forecast.sh" <<'DAYZERO_FORECAST'
#!/usr/bin/env bash
jq '.rows |= map(. + {usage_start_day: 0, usage_start_display: "d0", pct_per_day: 7.5, days_left: 8.0, usage_start_is_floor: false})'
DAYZERO_FORECAST
chmod +x "$TMP/dayzero-forecast.sh"
overage_case 40 50
FORECAST_BIN_OVERRIDE="$TMP/dayzero-forecast.sh"
run
check_eq "$RC" "0" "a projection naming day 0 does not fail the report"
check_contains "$ERR" "DEGRADED" "it is rejected as DEGRADED, because day 0 is not a day"
check_eq "$(table_only "$OUT" | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "START") c = i; next }
                                     c { print $c }' | sort -u | tr -d '\n')" "-" \
  "and the START column carries no d0"
FORECAST_BIN_OVERRIDE=""

# jq -e on a stream uses the last result. A valid final projection must not
# admit an earlier, unrelated document into the reader's JSON report.
cat > "$TMP/multi-forecast.sh" <<'MULTI_FORECAST'
#!/usr/bin/env bash
jq -c '{unexpected: true}, (.rows |= map(. + {pct_per_day: 7.5}))'
MULTI_FORECAST
chmod +x "$TMP/multi-forecast.sh"
overage_case 40 50
FORECAST_BIN_OVERRIDE="$TMP/multi-forecast.sh"
run --json
check_eq "$RC" "0" "a multi-document projection leaves the report usable"
check_contains "$ERR" "DEGRADED" "the whole multi-document projection is rejected"
check_eq "$(printf '%s' "$DOC" | jq -rs 'length == 1 and (.[0].rows | all(.pct_per_day == null))')" "true" \
  "only the original single report remains, with no figures from the rejected projection"
FORECAST_BIN_OVERRIDE=""
