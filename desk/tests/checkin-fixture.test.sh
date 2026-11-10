#!/usr/bin/env bash
# Verify actual check-in fixture insertion failure accounting without a database.
set -uo pipefail
TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FIXTURE_SOURCE=$(printenv CHECKIN_FIXTURE_SOURCE 2>/dev/null || true)
if [ -z "$FIXTURE_SOURCE" ]; then FIXTURE_SOURCE="$TESTS_DIR/checkin.test.sh"; fi
awk '/^ev\(\) \{/ {copy=1} copy {print} copy && /^}$/ {exit}' "$FIXTURE_SOURCE" > "$TMP/ev.sh"
if ! grep -q '^ev() {' "$TMP/ev.sh"; then
  bad "actual ev helper extracts"
  hq_t_finish checkin-fixture.test.sh
  exit 1
fi

cat > "$TMP/child.sh" <<'CHILD'
#!/usr/bin/env bash
set -uo pipefail
# Paths name this disposable fixture and the checked-in helper definitions.
source "$CASE_TESTLIB"
source "$CASE_EV"
sql_in() {
  printf '%s\n' "$1" >> "$CASE_SQL"
  printf 'synthetic SQL stdout diagnostic\n'
  printf 'synthetic SQL stderr diagnostic\n' >&2
  if [ "$CASE_MIXED" -eq 1 ] && [ "$(wc -l < "$CASE_SQL")" -gt 1 ]; then return 0; fi
  return "$CASE_SQL_STATUS"
}
i=0
while [ "$i" -lt "$CASE_REPEAT" ]; do
  status=0
  ev "$CASE_ITEM" "$CASE_KIND" "$CASE_AT" >> "$CASE_OUTPUT" 2>&1 || status=$?
  printf '%s\n' "$status" >> "$CASE_STATUSES"
  i=$((i + 1))
done
printf '%s %s\n' "$HQ_T_FAIL" "$HQ_T_PASS" > "$CASE_COUNTERS"
hq_t_finish fixture-child > "$CASE_FINISH"
CHILD
export CASE_TESTLIB="$TESTS_DIR/lib/testlib.sh" CASE_EV="$TMP/ev.sh"
export CASE_ITEM=fixture-item CASE_KIND=shown CASE_AT='2026-09-15 10:00'
export CASE_SQL="$TMP/sql" CASE_OUTPUT="$TMP/output" CASE_STATUSES="$TMP/statuses"
export CASE_COUNTERS="$TMP/counters" CASE_FINISH="$TMP/finish"
CASE_SQL_STATUS=0 CASE_REPEAT=1 CASE_MIXED=0
export CASE_SQL_STATUS CASE_REPEAT CASE_MIXED
run_case() {
  : > "$CASE_SQL"; : > "$CASE_OUTPUT"; : > "$CASE_STATUSES"
  CHILD_RC=0
  "$BASH" "$TMP/child.sh" > "$TMP/child-out" 2> "$TMP/child-err" || CHILD_RC=$?
  read -r FAILURES PASSES < "$CASE_COUNTERS"
}

run_case
check "successful fixture child passes" "$CHILD_RC" 0
check "success adds no failure" "$FAILURES" 0
check "success does not inflate the live pass count" "$PASSES" 0
check "successful insertion stays quiet" "$(cat "$CASE_OUTPUT")" ""
check "successful insertion calls SQL once" "$(wc -l < "$CASE_SQL" | tr -d ' ')" 1
check "successful insertion returns zero" "$(cat "$CASE_STATUSES")" 0
EXPECTED_SQL="INSERT INTO events (item_id, kind, at) VALUES ('$CASE_ITEM', '$CASE_KIND', ('$CASE_AT'::timestamp AT TIME ZONE 'America/New_York'))"
check "fixture SQL and timezone remain unchanged" "$(cat "$CASE_SQL")" "$EXPECTED_SQL"

for CASE_SQL_STATUS in 1 2 124 127; do
  export CASE_SQL_STATUS
  run_case
  check "SQL exit $CASE_SQL_STATUS fails suite finish" "$CHILD_RC" 1
  check "SQL exit $CASE_SQL_STATUS records one parent-shell failure" "$FAILURES" 1
  check "SQL exit $CASE_SQL_STATUS adds no pass" "$PASSES" 0
  check "SQL exit $CASE_SQL_STATUS is preserved" "$(cat "$CASE_STATUSES")" "$CASE_SQL_STATUS"
  check "SQL exit $CASE_SQL_STATUS is not retried" "$(wc -l < "$CASE_SQL" | tr -d ' ')" 1
  check_contains "failure names the fixture and status" "$(cat "$CASE_OUTPUT")" "fixture event shown for fixture-item at 2026-09-15 10:00 failed (rc=$CASE_SQL_STATUS:"
  check_contains "failure retains stdout diagnostic" "$(cat "$CASE_OUTPUT")" "synthetic SQL stdout diagnostic"
  check_contains "failure retains stderr diagnostic" "$(cat "$CASE_OUTPUT")" "synthetic SQL stderr diagnostic"
done

CASE_SQL_STATUS=2 CASE_REPEAT=2 CASE_MIXED=0
run_case
check "two failed fixtures retain both failures" "$FAILURES" 2
check "two failures still reach suite finish" "$CHILD_RC" 1
check "each failed fixture executes once" "$(wc -l < "$CASE_SQL" | tr -d ' ')" 2
CASE_MIXED=1
run_case
check "later success does not erase earlier setup failure" "$FAILURES" 1
check "mixed result remains a failed suite" "$CHILD_RC" 1
check "mixed result preserves both statuses" "$(tr '\n' ',' < "$CASE_STATUSES")" "2,0,"
hq_t_finish checkin-fixture.test.sh
