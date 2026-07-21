#!/usr/bin/env bash
# check-runs-dedup.test.sh — Offline unit tests for check-runs-dedup.sh (issue #675).
#
# The helper is pure stdin -> stdout, so these need no gh stub and no network.
# Run from repo root: bash .claude/scripts/tests/check-runs-dedup.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/.claude/scripts/check-runs-dedup.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# The helper appends to $HOME/.claude/script-usage.log; point it at the sandbox.
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

OUT=""
RC=0
run() { OUT=$(printf '%s' "$1" | "$SUT" 2>/dev/null); RC=$?; }

check_eq() { # expected actual label
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected: $1, got: $2)"; fi
}

# Sorted, comma-joined `id` list of the retained runs — order-independent so the
# assertions don't depend on jq's group_by ordering.
ids() { echo "$OUT" | jq -r '[.[].id] | sort | map(tostring) | join(",")'; }

# A check-run with the fields the dedup keys on. Extra fields are added per-case.
run_json() { # id name conclusion suite_id app_slug app_id [status]
  jq -cn --argjson id "$1" --arg name "$2" --arg concl "$3" --argjson suite "$4" \
         --arg slug "$5" --argjson appid "$6" --arg status "${7:-completed}" \
    '{id:$id, name:$name, status:$status,
      conclusion:(if $concl == "null" then null else $concl end),
      check_suite:{id:$suite}, app:{slug:$slug, id:$appid}}'
}

# --------------------------------------------------------------------------
# 1. Input shapes — every form the callers actually produce.
# --------------------------------------------------------------------------
A=$(run_json 1 test failure 100 gha 1)
B=$(run_json 2 test success 200 gha 1)

run ""
check_eq "[]" "$OUT" "empty stdin yields an empty array"
check_eq 0 "$RC" "empty stdin exits 0 (feeds the total==0 sentinel, not an error)"

run "[]"
check_eq "[]" "$OUT" "empty array yields an empty array"

run '{"check_runs":[]}'
check_eq "[]" "$OUT" "empty check_runs object yields an empty array"

run "[$A,$B]"
check_eq "2" "$(ids)" "bare array input (pr-state.sh shape)"

run "{\"check_runs\":[$A,$B]}"
check_eq "2" "$(ids)" "single {check_runs:[...]} object (merge-gate.sh shape)"

run "{\"check_runs\":[$A]}{\"check_runs\":[$B]}"
check_eq "2" "$(ids)" "concatenated per-page objects (gh --paginate shape)"

run "$A
$B"
check_eq "2" "$(ids)" "stream of bare run objects (gh --paginate --jq '.check_runs[]?' shape)"

# --------------------------------------------------------------------------
# 2. The core bug: a superseded failure must not survive.
# --------------------------------------------------------------------------
run "{\"check_runs\":[$(run_json 1 test failure 100 gha 1),$(run_json 2 test failure 200 gha 1),$(run_json 3 test success 300 gha 1)]}"
check_eq "3" "$(ids)" "3 runs of one name across 3 suites -> only the newest suite's run survives"

run "{\"check_runs\":[$(run_json 3 test success 300 gha 1),$(run_json 1 test failure 100 gha 1)]}"
check_eq "3" "$(ids)" "newest suite wins regardless of input order"

# --------------------------------------------------------------------------
# 3. Matrix legs — newest-SUITE-per-name, not latest-single-RUN-per-name.
# --------------------------------------------------------------------------
run "{\"check_runs\":[$(run_json 1 test failure 100 gha 1),$(run_json 2 test success 200 gha 1),$(run_json 3 test failure 200 gha 1)]}"
check_eq "2,3" "$(ids)" "all legs sharing a name in the newest suite are retained"

run "{\"check_runs\":[$(run_json 1 test success 200 gha 1),$(run_json 2 test success 200 gha 1),$(run_json 3 test failure 200 gha 1)]}"
check_eq "1,2,3" "$(ids)" "a failing leg is never masked by passing siblings in the same suite"

# --------------------------------------------------------------------------
# 4. Group key — app identity and name both participate.
# --------------------------------------------------------------------------
run "{\"check_runs\":[$(run_json 1 lint failure 100 appA 11),$(run_json 2 lint success 200 appB 22)]}"
check_eq "1,2" "$(ids)" "same name from two different apps never collapses"

run "{\"check_runs\":[$(run_json 1 lint failure 100 gha 1),$(run_json 2 test success 200 gha 1)]}"
check_eq "1,2" "$(ids)" "different names in the same app never collapse"

# A concatenated string key would fuse ("a-b" + "c") with ("a" + "b-c"); the
# array key cannot. Both runs must survive as distinct groups.
run "{\"check_runs\":[$(run_json 1 c failure 100 a-b 1),$(run_json 2 b-c success 200 a 2)]}"
check_eq "1,2" "$(ids)" "slug/name boundary is unambiguous (no string-concat key collision)"

# --------------------------------------------------------------------------
# 5. Unknown ordering data fails toward blocking, never toward silence.
# --------------------------------------------------------------------------
NO_SUITE='{"id":9,"name":"test","status":"completed","conclusion":"failure","app":{"slug":"gha","id":1}}'
run "{\"check_runs\":[$NO_SUITE,$(run_json 2 test success 200 gha 1)]}"
check_eq "2,9" "$(ids)" "a run with no check_suite.id is retained beside the newest suite"

run "{\"check_runs\":[$NO_SUITE]}"
check_eq "9" "$(ids)" "a group with only null suite ids retains everything"

NULL_SUITE='{"id":8,"name":"test","status":"completed","conclusion":"failure","check_suite":{"id":null},"app":{"slug":"gha","id":1}}'
run "{\"check_runs\":[$NULL_SUITE,$(run_json 2 test success 200 gha 1)]}"
check_eq "2,8" "$(ids)" "an explicit null check_suite.id is retained too"

APP_NULL='{"id":7,"name":"test","status":"completed","conclusion":"failure","check_suite":{"id":100},"app":null}'
run "{\"check_runs\":[$APP_NULL,$(run_json 2 test success 200 gha 1)]}"
check_eq "2,7" "$(ids)" "a null app is its own group rather than being folded into a named app"

# --------------------------------------------------------------------------
# 6. Ordering key is check_suite.id, not completed_at.
#    An in-progress run has completed_at: null — time-ordering would let the
#    older FAILED run win and report a failure where the answer is "not done".
# --------------------------------------------------------------------------
OLD_FAILED='{"id":1,"name":"test","status":"completed","conclusion":"failure","completed_at":"2026-07-21T10:00:00Z","check_suite":{"id":100},"app":{"slug":"gha","id":1}}'
NEW_RUNNING='{"id":2,"name":"test","status":"in_progress","conclusion":null,"completed_at":null,"check_suite":{"id":200},"app":{"slug":"gha","id":1}}'
run "{\"check_runs\":[$OLD_FAILED,$NEW_RUNNING]}"
check_eq "2" "$(ids)" "an in-progress newest run outranks an older failed run (completed_at is null)"

# Same-second re-runs tie on timestamps but not on suite id.
TIE_A='{"id":1,"name":"test","status":"completed","conclusion":"failure","completed_at":"2026-07-21T10:00:00Z","check_suite":{"id":100},"app":{"slug":"gha","id":1}}'
TIE_B='{"id":2,"name":"test","status":"completed","conclusion":"success","completed_at":"2026-07-21T10:00:00Z","check_suite":{"id":200},"app":{"slug":"gha","id":1}}'
run "{\"check_runs\":[$TIE_A,$TIE_B]}"
check_eq "2" "$(ids)" "same-second re-runs are ordered by suite id, not by timestamp"

# --------------------------------------------------------------------------
# 7. Retained objects are passed through untouched.
# --------------------------------------------------------------------------
RICH='{"id":5,"name":"test","status":"completed","conclusion":"failure","check_suite":{"id":300},
       "app":{"slug":"gha","id":1},"output":{"title":"2 failed"},
       "details_url":"https://example.test/d","html_url":"https://example.test/h","started_at":"2026-07-21T09:00:00Z"}'
run "{\"check_runs\":[$RICH]}"
check_eq "2 failed" "$(echo "$OUT" | jq -r '.[0].output.title')" "output.title survives"
check_eq "https://example.test/d" "$(echo "$OUT" | jq -r '.[0].details_url')" "details_url survives"
check_eq "https://example.test/h" "$(echo "$OUT" | jq -r '.[0].html_url')" "html_url survives"
check_eq "true" "$(echo "$OUT" | jq --argjson r "$RICH" -e '.[0] == $r' >/dev/null && echo true || echo false)" \
  "the retained run object is byte-identical to the input run"

# --------------------------------------------------------------------------
# 8. Idempotency — merge-gate.sh dedups, then ci-status.sh dedups its output again.
# --------------------------------------------------------------------------
ONCE=$(printf '%s' "{\"check_runs\":[$(run_json 1 test failure 100 gha 1),$(run_json 2 test success 200 gha 1),$(run_json 3 test failure 200 gha 1)]}" | "$SUT" 2>/dev/null)
TWICE=$(printf '%s' "$ONCE" | "$SUT" 2>/dev/null)
check_eq "$ONCE" "$TWICE" "running the dedup on its own output changes nothing"

# --------------------------------------------------------------------------
# 9. Error and usage contracts.
# --------------------------------------------------------------------------
run "not json"
check_eq 5 "$RC" "unparseable stdin exits 5"
check_eq "" "$OUT" "unparseable stdin writes no partial output"

# A scalar where a run object belongs must fail loudly, not be silently dropped —
# dropping an unclassifiable entry could hide a failing run.
run '["oops"]'
check_eq 5 "$RC" "a non-object entry exits 5 rather than being silently discarded"

# A top-level scalar is malformed input, not an empty check-run list — it must
# exit 5, never read as a legitimate zero-check result.
run '"malformed"'
check_eq 5 "$RC" "a top-level scalar exits 5 rather than reading as zero checks"
check_eq "" "$OUT" "a top-level scalar writes no partial output"

"$SUT" bogus </dev/null >/dev/null 2>&1
check_eq 2 "$?" "an unexpected positional argument exits 2"

HELP_OUT=$("$SUT" --help 2>/dev/null); HELP_RC=$?
check_eq 0 "$HELP_RC" "--help exits 0"
if echo "$HELP_OUT" | grep -q "check-runs-dedup.sh"; then
  ok "--help prints the usage block"
else
  bad "--help prints the usage block (got: $HELP_OUT)"
fi

echo "----------------------------------------"
echo "check-runs-dedup.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
