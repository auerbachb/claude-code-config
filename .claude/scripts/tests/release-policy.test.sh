#!/usr/bin/env bash
# release-policy.test.sh — Offline unit tests for release-policy.sh (issue #1169).
# catalog: tests — Tests for `release-policy.sh`
# Stubs `gh` so no network or real repo is touched.
# Run from repo root: bash .claude/scripts/tests/release-policy.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SRC="$REPO_ROOT/.claude/scripts/release-policy.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
BIN="$TMP/bin"; mkdir -p "$BIN"
SCRIPTS="$TMP/scripts"; mkdir -p "$SCRIPTS"
cp "$SRC" "$SCRIPTS/release-policy.sh"; chmod +x "$SCRIPTS/release-policy.sh"
SUT="$SCRIPTS/release-policy.sh"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# --- Fake gh ------------------------------------------------------------------
# FAKE_POLICY_B64   base64 policy body; empty => contents call 404s (absent)
# FAKE_WORKFLOWS    newline-separated workflow filenames in .github/workflows
# FAKE_RUNS_JSON    JSON array returned by every `gh run list`
# FAKE_SEARCH_COUNT total_count returned by the search API; "fail" => call errors
# FAKE_MERGED_JSON  JSON array returned by the `gh pr list` fallback
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  "repo view --json nameWithOwner --jq .nameWithOwner")
    echo "${FAKE_OWNER_REPO:-solo/app}"; exit 0 ;;
  *"search/issues"*)
    SC="${FAKE_SEARCH_COUNT:-0}"
    if [ "$SC" = "fail" ]; then echo "gh: search failed" >&2; exit 1; fi
    printf '%s\n' "$SC"; exit 0 ;;
  *"contents/.claude/release-policy.json"*)
    if [ -z "${FAKE_POLICY_B64:-}" ]; then
      echo "gh: Not Found (HTTP 404)" >&2; exit 1
    fi
    printf '%s\n' "$FAKE_POLICY_B64"; exit 0 ;;
  *"contents/.github/workflows"*)
    WF="${FAKE_WORKFLOWS:-}"
    if [ -z "$WF" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    printf '%s\n' "$WF"; exit 0 ;;
  "run list"*)
    RJ="${FAKE_RUNS_JSON:-}"
    if [ -z "$RJ" ]; then RJ='[]'; fi
    printf '%s\n' "$RJ"; exit 0 ;;
  "pr list"*)
    MJ="${FAKE_MERGED_JSON:-}"
    if [ -z "$MJ" ]; then MJ='[]'; fi
    printf '%s\n' "$MJ"; exit 0 ;;
esac
echo "unexpected gh call: $ARGS" >&2; exit 90
EOF
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

PASS=0; FAIL=0
ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL+1)); }
run() { OUT="$("$SUT" "$@" 2>&1)"; RC=$?; }
expect_rc()    { if [[ "$RC" -eq "$1" ]]; then ok "$2"; else bad "$2 (got rc=$RC: $OUT)"; fi; }
expect_field() { local got; got="$(jq -r "$1" <<<"$OUT" 2>/dev/null)"
                 if [[ "$got" == "$2" ]]; then ok "$3"; else bad "$3 ($1 = '$got', want '$2'; out: $OUT)"; fi; }
grep_ok()      { if printf '%s\n' "$OUT" | grep -q "$1"; then ok "$2"; else bad "$2 (output: $OUT)"; fi; }

# Build a run entry RELATIVE TO NOW: mkrun <days_ago> <minutes> <status> <conclusion>
# Relative, not absolute, so the 90-day recency window keeps meaning the same
# thing as the calendar moves — an absolute fixture would quietly age out of the
# window and start passing (or failing) for the wrong reason.
mkrun() {
  python3 - "$@" <<'PY'
import sys, json, datetime
days, minutes, status, concl = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3], sys.argv[4]
c = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
u = c + datetime.timedelta(minutes=minutes)
print(json.dumps({"databaseId": 1, "status": status, "conclusion": concl,
                  "createdAt": c.strftime("%Y-%m-%dT%H:%M:%SZ"),
                  "updatedAt": u.strftime("%Y-%m-%dT%H:%M:%SZ")}))
PY
}

WORKFLOWS_DEFAULT=$'ci.yml\nmobile-testflight.yml\nios-app-store-release.yml'

# 1. Default OFF — no policy file at all.
FAKE_POLICY_B64="" FAKE_WORKFLOWS="$WORKFLOWS_DEFAULT" run --repo solo/app
expect_rc 1 "absent policy file => OFF (exit 1)"
expect_field '.enabled' 'false' "absent policy reports enabled=false"
expect_field '.policy_source' 'absent' "absent policy reports policy_source=absent"

# 2. Explicitly disabled.
FAKE_POLICY_B64="$(b64 '{"enabled": false}')" FAKE_WORKFLOWS="$WORKFLOWS_DEFAULT" run --repo solo/app
expect_rc 1 "enabled=false => OFF (exit 1)"
grep_ok "enabled=false" "disabled policy explains itself"

# 3. Explicit interval, honored as written and NOT clamped (owner override).
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"45m","trigger":"none","release_workflows":["mobile-testflight.yml"]}')" \
  run --repo solo/app
expect_rc 0 "explicit 45m policy resolves"
expect_field '.min_interval_minutes' '45' "45m parses to 45 minutes"
expect_field '.interval_source' 'policy' "explicit interval reports source=policy"

FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"2h","trigger":"none","release_workflows":["mobile-testflight.yml"]}')" \
  run --repo solo/app
expect_field '.min_interval_minutes' '120' "2h parses to 120 minutes"

FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":5,"trigger":"none","release_workflows":["mobile-testflight.yml"]}')" \
  run --repo solo/app
expect_field '.min_interval_minutes' '5' "a bare 5 is honored below the auto clamp (explicit override)"

# 4. Unparseable interval fails closed.
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"soon","trigger":"none","release_workflows":["mobile-testflight.yml"]}')" \
  run --repo solo/app
expect_rc 4 "unparseable min_interval fails closed (exit 4)"

# 5. Malformed JSON fails closed.
FAKE_POLICY_B64="$(b64 '{not json')" run --repo solo/app
expect_rc 4 "malformed policy JSON fails closed (exit 4)"

# 6. auto derivation EXCLUDES skipped runs — the still-point trap. Twelve 1-second
#    skipped runs alongside six real ~13-minute builds must derive ~13, not ~0.
SKIPS=""; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  SKIPS="$SKIPS$(mkrun "$i" 0.02 completed skipped)"$'\n'
done
BUILDS=""; for i in 1 2 3 4 5 6; do
  BUILDS="$BUILDS$(mkrun "$i" 13 completed success)"$'\n'
done
ALL_RUNS=$(printf '%s%s' "$SKIPS" "$BUILDS" | grep -v '^$' | jq -sc .)
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"auto","trigger":"label:release:ios","release_workflows":["ios-testflight-auto.yml"]}')" \
  FAKE_RUNS_JSON="$ALL_RUNS" FAKE_MERGED_JSON='[{"number":1},{"number":2}]' run --repo solo/app
expect_rc 0 "auto derivation resolves"
expect_field '.derivation.median_build_minutes' '13' "skipped 1-second runs excluded from the median"
expect_field '.derivation.sample_size' '6' "only the six building runs are sampled"
expect_field '.min_interval_minutes' '39' "13-minute builds derive a 39-minute window (3x)"
expect_field '.interval_source' 'auto' "derived interval reports source=auto"

# 6b. Distinct values, odd count. Every median case above uses uniform durations,
#     which pass for any selected index — including a wrong one. [6, 13, 30] only
#     yields 13 if the true middle element is chosen.
DISTINCT=$(printf '%s\n%s\n%s' "$(mkrun 1 6 completed success)" "$(mkrun 2 30 completed success)" "$(mkrun 3 13 completed success)" | grep -v '^$' | jq -sc .)
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"auto","trigger":"none","release_workflows":["w.yml"]}')" \
  FAKE_RUNS_JSON="$DISTINCT" FAKE_SEARCH_COUNT=0 run --repo solo/app
expect_field '.derivation.sample_size' '3' "three distinct builds are all sampled"
expect_field '.derivation.median_build_minutes' '13' "the median is the middle value, not the first or last"

# 7. Outlier cap — one run that sat queued for three days must not move the median.
OUTLIER=$(mkrun 7 4320 completed success)
WITH_OUTLIER=$(printf '%s\n%s' "$BUILDS" "$OUTLIER" | grep -v '^$' | jq -sc .)
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"auto","trigger":"none","release_workflows":["w.yml"]}')" \
  FAKE_RUNS_JSON="$WITH_OUTLIER" FAKE_MERGED_JSON='[]' run --repo solo/app
expect_field '.derivation.sample_size' '6' "a 3-day run is discarded as an outlier"
expect_field '.derivation.median_build_minutes' '13' "median unmoved by the outlier"

# 7b. A run that concludes `success` in under five minutes did not build the app —
#     GitHub calls a run successful when its only real job was skipped. Six such
#     runs must not outvote three genuine 15-minute builds.
SHORT=""; for i in 1 2 3 4 5 6; do
  SHORT="$SHORT$(mkrun "$i" 2 completed success)"$'\n'
done
REAL=""; for i in 7 8 9; do
  REAL="$REAL$(mkrun "$i" 15 completed success)"$'\n'
done
MIXED=$(printf '%s%s' "$SHORT" "$REAL" | grep -v '^$' | jq -sc .)
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"auto","trigger":"none","release_workflows":["w.yml"]}')" \
  FAKE_RUNS_JSON="$MIXED" FAKE_SEARCH_COUNT=0 run --repo solo/app
expect_field '.derivation.sample_size' '3' "sub-5-minute successes are not builds"
expect_field '.derivation.median_build_minutes' '15' "median comes from the genuine builds only"

# 7c. Recency — a pipeline's setup-era runs from months ago must not outvote the
#     builds it does today, and the window widens only when it is too thin.
OLD=""; for i in 120 130 140 150 160 170; do
  OLD="$OLD$(mkrun "$i" 6 completed success)"$'\n'
done
RECENT_MANY=""; for i in 2 4 6; do
  RECENT_MANY="$RECENT_MANY$(mkrun "$i" 30 completed success)"$'\n'
done
AGED=$(printf '%s%s' "$OLD" "$RECENT_MANY" | grep -v '^$' | jq -sc .)
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"auto","trigger":"none","release_workflows":["w.yml"]}')" \
  FAKE_RUNS_JSON="$AGED" FAKE_SEARCH_COUNT=0 run --repo solo/app
expect_field '.derivation.sample_size' '3' "runs older than the 90-day window are excluded"
expect_field '.derivation.sample_windowed' 'true' "the windowed sample is reported as windowed"
expect_field '.derivation.median_build_minutes' '30' "median comes from recent builds only"

RECENT_THIN=$(mkrun 2 30 completed success)
THIN=$(printf '%s\n%s' "$OLD" "$RECENT_THIN" | grep -v '^$' | jq -sc .)
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"auto","trigger":"none","release_workflows":["w.yml"]}')" \
  FAKE_RUNS_JSON="$THIN" FAKE_SEARCH_COUNT=0 run --repo solo/app
expect_field '.derivation.sample_size' '7' "a window with too few samples widens to full history"
expect_field '.derivation.sample_windowed' 'false' "the widened sample is reported as not windowed"

# 7d. Only failures in history => derive from them rather than falling to the default.
ONLY_FAIL=""; for i in 1 2 3; do
  ONLY_FAIL="$ONLY_FAIL$(mkrun "$i" 10 completed failure)"$'\n'
done
FAILS=$(printf '%s' "$ONLY_FAIL" | grep -v '^$' | jq -sc .)
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"auto","trigger":"none","release_workflows":["w.yml"]}')" \
  FAKE_RUNS_JSON="$FAILS" FAKE_SEARCH_COUNT=0 run --repo solo/app
expect_field '.derivation.sample_basis' 'failure' "a repo with only failed builds derives from them"
expect_field '.derivation.median_build_minutes' '10' "failure durations measured when there are no successes"

# 8. No building runs at all => documented default.
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"auto","trigger":"none","release_workflows":["w.yml"]}')" \
  FAKE_RUNS_JSON='[]' FAKE_MERGED_JSON='[]' run --repo solo/app
expect_field '.min_interval_minutes' '60' "no history falls back to the documented 60-minute default"
expect_field '.interval_source' 'default' "no-history interval reports source=default"
expect_field '.derivation.history_absent' 'true' "no-history is flagged in the derivation detail"

# 9. Merge-rate budget widens the interval — the inventory case. Eight-minute
#    builds (compute term 24m) plus a merge rate well over the budget must land
#    on the notification budget, not the compute term.
FAST=""; for i in 1 2 3 4 5 6; do
  FAST="$FAST$(mkrun "$i" 8 completed success)"$'\n'
done
FAST_RUNS=$(printf '%s' "$FAST" | grep -v '^$' | jq -sc .)
# 168 merges / 14 days = 12/day, over the 8/day budget.
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"auto","trigger":"none","release_workflows":["mobile-testflight.yml"],"max_builds_per_day":8}')" \
  FAKE_RUNS_JSON="$FAST_RUNS" FAKE_SEARCH_COUNT=168 run --repo solo/app
expect_field '.derivation.median_build_minutes' '8' "8-minute builds measured"
expect_field '.derivation.compute_term' '24' "compute term is 3x the median"
expect_field '.derivation.merges_per_day' '12' "merge rate counted from the search total"
expect_field '.derivation.budget_term' '180' "over-budget merge rate contributes a 180-minute term"
expect_field '.min_interval_minutes' '180' "flooding repo derives the wider notification-budget interval"

# 10. A merge rate under budget leaves the compute term in charge.
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"auto","trigger":"none","release_workflows":["mobile-testflight.yml"],"max_builds_per_day":8}')" \
  FAKE_RUNS_JSON="$FAST_RUNS" FAKE_SEARCH_COUNT=2 run --repo solo/app
expect_field '.derivation.budget_term' '0' "under-budget merge rate contributes nothing"
expect_field '.min_interval_minutes' '24' "under-budget repo keeps the compute-term interval"

# 10b. The pr-list fallback flags saturation rather than reporting a capped rate
#      as a genuinely low one — the bug that made the budget term unreachable.
MANY=$(jq -cn '[range(0;100) | {number: .}]')
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"auto","trigger":"none","release_workflows":["mobile-testflight.yml"],"max_builds_per_day":8}')" \
  FAKE_RUNS_JSON="$FAST_RUNS" FAKE_SEARCH_COUNT=fail FAKE_MERGED_JSON="$MANY" run --repo solo/app
expect_field '.derivation.merged_prs' '100' "search failure falls back to pr list"
expect_field '.derivation.merged_prs_saturated' 'true' "a capped fallback count is flagged as saturated"

# 11. Trigger mechanisms are respected, never normalized.
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":30,"trigger":"label:release:ios","release_workflows":["w.yml"]}')" \
  run --repo solo/app
expect_field '.trigger' 'label:release:ios' "label mechanism preserved verbatim"
expect_field '.deferred_trigger' '' "label mechanism has no deferred form (cannot fire on a merged PR)"

FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":30,"trigger":"none","release_workflows":["w.yml"]}')" \
  run --repo solo/app
expect_field '.trigger' 'none' "none mechanism preserved"
expect_field '.deferred_trigger' 'none' "none defers to itself"

FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":30,"trigger":"workflow_dispatch:w.yml","release_workflows":["w.yml"]}')" \
  run --repo solo/app
expect_field '.deferred_trigger' 'workflow_dispatch:w.yml' "workflow_dispatch defers to itself"

FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":30,"trigger":"telepathy","release_workflows":["w.yml"]}')" \
  run --repo solo/app
expect_rc 4 "unrecognized mechanism fails closed (exit 4)"
grep_ok "unrecognized trigger mechanism" "unrecognized mechanism explains itself"

FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":30,"trigger":"none","deferred_trigger":"label:release:ios","release_workflows":["w.yml"]}')" \
  run --repo solo/app
expect_rc 4 "a label deferred_trigger fails closed (exit 4)"

# 12. The App Store path is structurally unreachable.
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":30,"trigger":"none","release_workflows":["ios-app-store-release.yml"]}')" \
  run --repo solo/app
expect_rc 4 "declaring the App Store workflow fails closed (exit 4)"

FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":30,"trigger":"workflow_dispatch:other.yml","release_workflows":["w.yml"]}')" \
  run --repo solo/app
expect_rc 4 "dispatching a workflow outside release_workflows fails closed (exit 4)"

# 13. Detection is by pipeline presence, and excludes the App Store workflow.
FAKE_WORKFLOWS="$WORKFLOWS_DEFAULT" run --detect --repo solo/app
expect_rc 0 "detect finds the TestFlight workflow"
grep_ok "mobile-testflight.yml" "detect names the TestFlight workflow"
if printf '%s\n' "$OUT" | grep -q 'app-store'; then bad "detect excludes the App Store workflow"; else ok "detect excludes the App Store workflow"; fi

FAKE_WORKFLOWS=$'ci.yml\nlint.yml' run --detect --repo solo/app
expect_rc 3 "a repo with no TestFlight workflow reports no pipeline (exit 3)"

# 14. An enabled policy with no release_workflows falls back to detection.
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":30,"trigger":"none"}')" \
  FAKE_WORKFLOWS="$WORKFLOWS_DEFAULT" run --repo solo/app
expect_rc 0 "policy without release_workflows resolves via detection"
expect_field '.release_workflows_source' 'detected' "workflow source reported as detected"
expect_field '.release_workflows | length' '1' "only the TestFlight workflow is detected"

FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":30,"trigger":"none"}')" \
  FAKE_WORKFLOWS=$'ci.yml' run --repo solo/app
expect_rc 3 "enabled policy with no pipeline anywhere reports no_pipeline (exit 3)"

# 15. --no-derive skips the derivation API calls.
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"auto","trigger":"none","release_workflows":["w.yml"]}')" \
  run --repo solo/app --no-derive
expect_rc 0 "--no-derive resolves the policy"
expect_field '.min_interval_minutes' 'null' "--no-derive leaves the interval undetermined"
expect_field '.interval_source' 'auto-undetermined' "--no-derive reports auto-undetermined"

# max_builds_per_day feeds the budget term, so a bad value must fail closed
# rather than silently divide by zero or coerce to a default.
for BAD in '0' '-3' '"eight"'; do
  FAKE_POLICY_B64="$(b64 "{\"enabled\":true,\"min_interval\":\"auto\",\"trigger\":\"none\",\"release_workflows\":[\"w.yml\"],\"max_builds_per_day\":$BAD}")" \
    FAKE_RUNS_JSON='[]' FAKE_SEARCH_COUNT=0 run --repo solo/app
  expect_rc 4 "max_builds_per_day=$BAD fails closed (exit 4)"
done

# JSON null is "unset", not "invalid" — jq's `//` default is the intended
# behavior here, so pin it rather than leaving it as an accident.
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"auto","trigger":"none","release_workflows":["w.yml"],"max_builds_per_day":null}')" \
  FAKE_RUNS_JSON='[]' FAKE_SEARCH_COUNT=0 run --repo solo/app
expect_rc 0 "an explicit null max_builds_per_day means unset, not invalid"
expect_field '.max_builds_per_day' '8' "unset max_builds_per_day takes the documented default"

# One OLD success plus recent failures must still derive from the success:
# failures are a fallback for when no successful run exists at all, not for when
# the successes are merely too few to clear MIN_SAMPLE.
OLD_SUCCESS=$(mkrun 200 22 completed success)
RECENT_FAILS=""; for i in 1 2 3; do RECENT_FAILS="$RECENT_FAILS$(mkrun "$i" 9 completed failure)"$'\n'; done
THIN=$(printf '%s\n%s' "$OLD_SUCCESS" "$RECENT_FAILS" | grep -v '^$' | jq -sc .)
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"auto","trigger":"none","release_workflows":["w.yml"]}')" \
  FAKE_RUNS_JSON="$THIN" FAKE_SEARCH_COUNT=0 run --repo solo/app
expect_field '.derivation.sample_basis' 'success' "a lone old success still outranks recent failures"
expect_field '.derivation.median_build_minutes' '22' "the median comes from that success, not the failures"

# A tester-notification budget the 240-minute clamp can override is not a budget:
# max_builds_per_day=1 must not resolve to an interval that permits six a day.
FAKE_POLICY_B64="$(b64 '{"enabled":true,"min_interval":"auto","trigger":"none","release_workflows":["w.yml"],"max_builds_per_day":1}')" \
  FAKE_RUNS_JSON="$(printf '%s' "$(mkrun 1 8 completed success)" | jq -sc .)" FAKE_SEARCH_COUNT=140 run --repo solo/app
expect_field '.min_interval_minutes' '1440' "a budget of 1/day derives a 24-hour interval, not the 240m clamp"

# A declared workflow must be a bare filename — a path or an extensionless value
# matches nothing downstream and would read as "this repo never builds".
for BADWF in '["a/b.yml"]' '[""]' '["mobile-testflight"]'; do
  FAKE_POLICY_B64="$(b64 "{\"enabled\":true,\"min_interval\":\"auto\",\"trigger\":\"none\",\"release_workflows\":$BADWF}")" \
    FAKE_RUNS_JSON='[]' FAKE_SEARCH_COUNT=0 run --repo solo/app
  expect_rc 4 "release_workflows=$BADWF fails closed (exit 4)"
done

echo "----------------------------------------"
echo "release-policy.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
