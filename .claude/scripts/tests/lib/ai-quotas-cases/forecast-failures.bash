#!/usr/bin/env bash
# Source-only quota fixture group: forecast-failures. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# A helper that does not resolve degrades to a table without those three
# columns — and says so. Pointed at a path that is not executable, because the
# reader uses AI_QUOTAS_FORECAST_BIN exclusively: a fall-through would find the
# repo copy and this case could never be exercised from inside a checkout.
overage_case 40 50
FORECAST_BIN_OVERRIDE="$TMP/no-such-quotas-forecast.sh"
run
check_eq "$RC" "0" "an unavailable projection helper does not fail the report"
check_contains "$ERR" "DEGRADED" "it says DEGRADED on stderr"
check_contains "$ERR" "$FORECAST_BIN_OVERRIDE" \
  "naming the path it could not use, so the reader is not sent hunting three others"
check_contains "$ERR" "LEFT" "and which columns lost their figures because of it"
# The COLUMNS stay — one table shape whatever ran, with the same `-` every
# other unknown in this table uses. What must not survive is a FIGURE in them,
# which is what a helper that half-ran would leave.
check_contains "$(table_only "$OUT")" "%/DAY" \
  "the columns are still there, so the table has one shape either way"
# The column is found by NAME in the header rather than counted to. Reading a
# fixed field number would keep passing against whatever ends up fourth after
# the next column change, and reading from $OUT rather than the table would let
# a DEGRADED line printed above it supply the value being asserted on.
check_eq "$(table_only "$OUT" | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "START") c = i; next }
                                     c { print $c }' | sort -u | tr -d '\n')" "-" \
  "control(-): and every START cell is a dash rather than a figure nobody computed"
FORECAST_BIN_OVERRIDE=""
check_contains "$OUT" "OVERAGE" "the rest of the table still renders"
check_contains "$OUT" "40%" "including every figure that was read"

# A projection may only FILL BLANKS. The dangerous shape here is a helper that
# returns the RIGHT NUMBER OF ROWS while dropping fields off them: a row-count
# check passes it, and the report prints missing the very fields a consumer
# reads it for, with exit 0. AI_QUOTAS_FORECAST_BIN points this at anything on
# disk, so the reader has to survive it rather than trust the repo copy.
#
# The pass-through stub is the CONTROL, and it goes first. Without it a
# rejection below could not be attributed to the dropped field — a stub
# mechanism that simply never produced an accepted document would fail the
# same way and the assertion would pass for the wrong reason.
cat > "$TMP/passthrough-forecast.sh" <<'PASSTHROUGH_FORECAST'
#!/usr/bin/env bash
jq '.rows |= map(. + {pct_per_day: 7.5, days_left: 8.0, usage_start_is_floor: false})'
PASSTHROUGH_FORECAST
chmod +x "$TMP/passthrough-forecast.sh"
overage_case 40 50
FORECAST_BIN_OVERRIDE="$TMP/passthrough-forecast.sh"
run --json
check_eq "$(field_of claude-one@example.com "7-day" pct_per_day)" "7.5" \
  "control(+): a helper that only fills blanks has its projection applied"
run
check_not_contains "$ERR" "DEGRADED" \
  "control(+): and nothing is reported as degraded"

# Same length, every projection field filled — but `provider` is gone off each
# row, and the top-level `schema_version` with it.
cat > "$TMP/stripping-forecast.sh" <<'STRIPPING_FORECAST'
#!/usr/bin/env bash
jq 'del(.schema_version)
    | .rows |= map(del(.provider) + {pct_per_day: 7.5, days_left: 8.0})'
STRIPPING_FORECAST
chmod +x "$TMP/stripping-forecast.sh"
FORECAST_BIN_OVERRIDE="$TMP/stripping-forecast.sh"
run
check_eq "$RC" "0" "a helper that strips fields off the report does not fail it"
check_contains "$ERR" "DEGRADED" "the stripped report is stated as a degradation"
check_not_contains "$ERR" "failed (exit" \
  "and is not reported as an exit-code failure, because the exit was zero"
run --json
check_eq "$(printf '%s' "$DOC" | jq -r '.schema_version')" "1.0" \
  "schema_version survives, because the stripped document was discarded whole"
check_eq "$(field_of claude-one@example.com "7-day" provider)" "claude" \
  "and so does every row's provider"
check_eq "$(printf '%s' "$DOC" | jq -r \
  '.rows[] | select(.label == "claude-one@example.com") | .pct_per_day | tostring')" "null" \
  "with no figure from a document that could not be trusted to carry the rest"

# Overwriting a MEASURED figure is the same failure wearing different clothes:
# the document is complete, so a field-presence check passes it, and the table
# prints a usage percentage this run never read.
# DELETING a blank is not filling it. A helper that drops `pct_per_day` off
# every row rather than computing one returns a document whose every surviving
# field matches — and a check that excused null-valued keys from having to come
# back would take it, leaving `--json` consumers a row where the field is
# ABSENT rather than null. One shape either way is the whole reason these
# fields are declared null on rows nothing was projected for.
cat > "$TMP/deleting-forecast.sh" <<'DELETING_FORECAST'
#!/usr/bin/env bash
jq '.rows |= map(del(.pct_per_day))'
DELETING_FORECAST
chmod +x "$TMP/deleting-forecast.sh"
FORECAST_BIN_OVERRIDE="$TMP/deleting-forecast.sh"
run
check_eq "$RC" "0" "a helper that deletes a blank instead of filling it does not fail the report"
check_contains "$ERR" "DEGRADED" "the deleted field is stated as a degradation"
run --json
check_eq "$(printf '%s' "$DOC" | jq -r \
  '.rows | map(has("pct_per_day")) | all | tostring')" "true" \
  "and every row still HAS pct_per_day, because the document was discarded whole"
check_eq "$(field_of claude-one@example.com "7-day" pct_per_day)" "null" \
  "carrying it as null — the shape a consumer gets when nothing was projected"

# Filling a blank the projection does NOT own. `overage` is null on every row
# whenever the cheapest-next helper degraded, and a price appearing in it did
# not come from any provider — the report would state a dollar figure nobody
# read, in the column owners use to choose what to spend next, with exit 0.
# Only the seven fields the projection declares may be written.
cat > "$TMP/foreign-field-forecast.sh" <<'FOREIGN_FIELD_FORECAST'
#!/usr/bin/env bash
jq '.rows |= map(.overage = "$42.00" | . + {pct_per_day: 7.5})'
FOREIGN_FIELD_FORECAST
chmod +x "$TMP/foreign-field-forecast.sh"
FORECAST_BIN_OVERRIDE="$TMP/foreign-field-forecast.sh"
run
check_eq "$RC" "0" "a helper that fills a field it does not own does not fail the report"
check_contains "$ERR" "DEGRADED" "filling a blank outside the projection is a degradation"
check_not_contains "$OUT" "42.00" "and the fabricated figure never reaches the table"

# A field the report never declared. Every value the projection writes has a
# null already waiting for it on the row, so a key that was not sent has no
# legitimate way back — and a --json consumer reading a field this reader never
# promised is reading whatever the helper felt like saying.
cat > "$TMP/extra-field-forecast.sh" <<'EXTRA_FIELD_FORECAST'
#!/usr/bin/env bash
jq '.rows |= map(. + {pct_per_day: 7.5, projected_spend_usd: 99})'
EXTRA_FIELD_FORECAST
chmod +x "$TMP/extra-field-forecast.sh"
FORECAST_BIN_OVERRIDE="$TMP/extra-field-forecast.sh"
run --json
check_eq "$(printf '%s' "$DOC" | jq -r \
  '.rows | map(has("projected_spend_usd")) | any | tostring')" "false" \
  "a field the report never declared does not reach --json"
check_eq "$(field_of claude-one@example.com "7-day" pct_per_day)" "null" \
  "and the projection that arrived with it is discarded whole"

# Rows that are not objects at all. The comparison the check runs against each
# row is only defined over objects, so the arm that matters is what happens
# when it is not: the run has to end in the SAME discard-and-degrade as every
# other malformed answer, rather than in an error escaping to the terminal or
# a report built on rows nobody can read.
cat > "$TMP/scalar-rows-forecast.sh" <<'SCALAR_ROWS_FORECAST'
#!/usr/bin/env bash
jq '.rows |= map("gone")'
SCALAR_ROWS_FORECAST
chmod +x "$TMP/scalar-rows-forecast.sh"
FORECAST_BIN_OVERRIDE="$TMP/scalar-rows-forecast.sh"
run
check_eq "$RC" "0" "rows that are not objects do not fail the report"
check_contains "$ERR" "DEGRADED" "they degrade like any other answer that cannot be trusted"
check_contains "$OUT" "claude-one@example.com" "and every account still reports from the rows this run built"

cat > "$TMP/overwriting-forecast.sh" <<'OVERWRITING_FORECAST'
#!/usr/bin/env bash
jq '.rows |= map(.used_pct = 99 | . + {pct_per_day: 7.5})'
OVERWRITING_FORECAST
chmod +x "$TMP/overwriting-forecast.sh"
FORECAST_BIN_OVERRIDE="$TMP/overwriting-forecast.sh"
run
FORECAST_BIN_OVERRIDE=""

# A blank may be filled only with the DOCUMENTED type. A helper that answers
# with a structured value in a scalar slot — or a note that is not the one
# the contract names — is rejected whole: the projection is discarded and the
# table degrades, because the TSV renderer would otherwise print JSON into a
# column and a --json consumer would meet an array where a number was promised.
