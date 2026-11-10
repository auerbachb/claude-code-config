#!/usr/bin/env bash
# Offline tests for churn-hotspot-wrap-plan.sh (Issue #1307).
# catalog: tests — Tests `/wrap` hotspot suppression, material-growth, evidence, re-file, unknown-state, and aggregate classification

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
SCRIPT="$REPO_ROOT/.claude/scripts/churn-hotspot-wrap-plan.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

ok() {
  echo "ok - $1"
  PASS=$((PASS + 1))
}

bad() {
  echo "not ok - $1"
  FAIL=$((FAIL + 1))
}

check_jq() {
  local name="$1" json="$2" filter="$3"
  if printf '%s' "$json" | jq -e "$filter" >/dev/null 2>&1; then
    ok "$name"
  else
    bad "$name"
    printf '%s\n' "$json"
  fi
}

cat > "$TMP/baselines.json" <<'EOF'
{
  "schema": "churn-hotspot-baselines/v1",
  "material_growth_multiplier": 2,
  "hotspots": {
    "closed-low.md": {"issue": 10, "score_at_decision": 4, "pr_count_at_decision": 4, "as_of": "2026-08-25"},
    "closed-growth.md": {"issue": 11, "score_at_decision": 3, "pr_count_at_decision": 3, "as_of": "2026-08-25"},
    "issue-mismatch.md": {"issue": 999, "score_at_decision": 2, "pr_count_at_decision": 2, "as_of": "2026-08-25"}
  }
}
EOF

cat > "$TMP/detector.json" <<'EOF'
{
  "total_hotspot_count": 9,
  "conflict_weight": 2,
  "truncated": false,
  "existing_lookup_failed": false,
  "hotspots": [
    {"file":"closed-low.md","score":7,"pr_count":7,"pr_numbers":[1,2,3,4,5,6,7],"conflict_rounds":0,"existing_hotspot_issue":10,"existing_hotspot_issue_state":"closed"},
    {"file":"closed-growth.md","score":6,"pr_count":6,"pr_numbers":[1,2,3,4,5,6],"conflict_rounds":0,"existing_hotspot_issue":11,"existing_hotspot_issue_state":"closed"},
    {"file":"closed-conflict.md","score":8,"pr_count":6,"pr_numbers":[1,2,3,4,5,6],"conflict_rounds":1,"existing_hotspot_issue":12,"existing_hotspot_issue_state":"closed"},
    {"file":"open-current.md","score":3,"pr_count":3,"pr_numbers":[20,21,99],"conflict_rounds":0,"existing_hotspot_issue":13,"existing_hotspot_issue_state":"open"},
    {"file":"open-old.md","score":3,"pr_count":3,"pr_numbers":[20,21,22],"conflict_rounds":0,"existing_hotspot_issue":14,"existing_hotspot_issue_state":"open"},
    {"file":"unknown.md","score":4,"pr_count":4,"pr_numbers":[1,2,3,4],"conflict_rounds":0,"existing_hotspot_issue":15,"existing_hotspot_issue_state":"unknown"},
    {"file":"new.md","score":3,"pr_count":3,"pr_numbers":[1,2,3],"conflict_rounds":0,"existing_hotspot_issue":null,"existing_hotspot_issue_state":null},
    {"file":"missing-baseline.md","score":3,"pr_count":3,"pr_numbers":[1,2,3],"conflict_rounds":0,"existing_hotspot_issue":16,"existing_hotspot_issue_state":"closed"},
    {"file":"issue-mismatch.md","score":3,"pr_count":3,"pr_numbers":[1,2,3],"conflict_rounds":0,"existing_hotspot_issue":17,"existing_hotspot_issue_state":"closed"}
  ]
}
EOF

OUT=$($SCRIPT --input "$TMP/detector.json" --baselines "$TMP/baselines.json" --pr 99)
RC=$?
if [[ "$RC" -eq 0 ]]; then
  ok "valid detector envelope is classified"
else
  bad "valid detector envelope is classified"
fi

check_jq "closed zero-cost hotspot below 2x is suppressed" "$OUT" \
  '.suppressed_set | any(.file == "closed-low.md" and .reason == "below_material_growth_threshold")'
check_jq "exactly 2x growth is surfaced" "$OUT" \
  '.material_growth_set == [{"file":"closed-growth.md","score":6,"pr_count":6,"conflict_rounds":0,"issue":11,"issue_state":"closed","kind":"material_growth","baseline_score":3,"growth_multiplier":2,"baseline_as_of":"2026-08-25"}]'
check_jq "closed hotspot with conflict cost stays eligible to re-file" "$OUT" \
  '.file_set | any(.file == "closed-conflict.md" and .kind == "closed_conflict_refile")'
check_jq "never-ticketed hotspot stays eligible to file" "$OUT" \
  '.file_set | any(.file == "new.md" and .kind == "new_issue")'
check_jq "highest-scoring eligible file is the bounded selection" "$OUT" \
  '.selected_file.file == "closed-conflict.md" and .held_back_file_count == 1'
check_jq "open issue receives evidence only for the merged PR" "$OUT" \
  '(.comment_set | map(.file)) == ["open-current.md"]'
check_jq "unknown issue state stays a decision" "$OUT" \
  '(.unknown_state_set | map(.file)) == ["unknown.md"]'
check_jq "missing and mismatched baselines do not invent growth" "$OUT" \
  '([.suppressed_set[] | select(.reason == "no_matching_baseline") | .file] | sort) == ["issue-mismatch.md","missing-baseline.md"]'
check_jq "aggregate counts are explicit" "$OUT" \
  '.total_hotspot_count == 9 and .conflict_cost_count == 1 and .surfaced_decision_count == 3 and .suppressed_count == 3'
check_jq "aggregate summary reports the suppression" "$OUT" \
  '.summary == "9 churn hotspots, 1 with conflict cost, 3 surfaced for decision, 3 suppressed (closed, no conflict cost)"'

STDIN_OUT=$(printf '%s' "$(cat "$TMP/detector.json")" | \
  $SCRIPT --baselines "$TMP/baselines.json" --pr 99)
check_jq "stdin is the default input" "$STDIN_OUT" '.schema == "wrap-churn-plan/v1"'

LEADING_ZERO_OUT=$($SCRIPT --input "$TMP/detector.json" --baselines "$TMP/baselines.json" --pr 099)
check_jq "leading-zero PR numbers normalize before jq" "$LEADING_ZERO_OUT" \
  '(.comment_set | map(.file)) == ["open-current.md"]'

cp "$TMP/detector.json" "$TMP/-detector.json"
cp "$TMP/baselines.json" "$TMP/-baselines.json"
DASH_PATH_OUT=$(cd "$TMP" && "$SCRIPT" --input -detector.json --baselines -baselines.json --pr 99)
check_jq "dash-prefixed input paths are treated as files" "$DASH_PATH_OUT" \
  '.schema == "wrap-churn-plan/v1"'

jq '.existing_lookup_failed = true' "$TMP/detector.json" > "$TMP/lookup-failed.json"
if $SCRIPT --input "$TMP/lookup-failed.json" --baselines "$TMP/baselines.json" --pr 99 >/dev/null 2>&1; then
  bad "incomplete issue lookup fails before producing a mutation plan"
else
  ok "incomplete issue lookup fails before producing a mutation plan"
fi

jq '.truncated = true' "$TMP/detector.json" > "$TMP/truncated.json"
if $SCRIPT --input "$TMP/truncated.json" --baselines "$TMP/baselines.json" --pr 99 >/dev/null 2>&1; then
  bad "truncated detector output fails before producing a mutation plan"
else
  ok "truncated detector output fails before producing a mutation plan"
fi

jq '.total_hotspot_count = 10' "$TMP/detector.json" > "$TMP/count-mismatch.json"
if $SCRIPT --input "$TMP/count-mismatch.json" --baselines "$TMP/baselines.json" --pr 99 >/dev/null 2>&1; then
  bad "untruncated count mismatch fails instead of producing an incomplete plan"
else
  ok "untruncated count mismatch fails instead of producing an incomplete plan"
fi

jq 'del(.hotspots[0].existing_hotspot_issue)' "$TMP/detector.json" > "$TMP/missing-metadata.json"
if $SCRIPT --input "$TMP/missing-metadata.json" --baselines "$TMP/baselines.json" --pr 99 >/dev/null 2>&1; then
  bad "missing issue metadata is invalid instead of never-ticketed"
else
  ok "missing issue metadata is invalid instead of never-ticketed"
fi

jq '.hotspots[0].score = -1' "$TMP/detector.json" > "$TMP/invalid-metric.json"
if $SCRIPT --input "$TMP/invalid-metric.json" --baselines "$TMP/baselines.json" --pr 99 >/dev/null 2>&1; then
  bad "invalid numeric detector metrics fail validation"
else
  ok "invalid numeric detector metrics fail validation"
fi

jq '.hotspots["closed-growth.md"].score_at_decision = -3' "$TMP/baselines.json" > "$TMP/invalid-baseline.json"
if $SCRIPT --input "$TMP/detector.json" --baselines "$TMP/invalid-baseline.json" --pr 99 >/dev/null 2>&1; then
  bad "malformed baseline entries fail validation"
else
  ok "malformed baseline entries fail validation"
fi

jq '.hotspots["closed-growth.md"].score_at_decision = 3.5' "$TMP/baselines.json" > "$TMP/fractional-baseline.json"
if $SCRIPT --input "$TMP/detector.json" --baselines "$TMP/fractional-baseline.json" --pr 99 >/dev/null 2>&1; then
  bad "fractional baseline metrics fail validation"
else
  ok "fractional baseline metrics fail validation"
fi

if $SCRIPT --input "$TMP/detector.json" --baselines "$TMP/baselines.json" --pr nope >/dev/null 2>&1; then
  bad "invalid PR number fails closed"
else
  ok "invalid PR number fails closed"
fi

if $SCRIPT --input "$TMP/detector.json" --baselines "$TMP/baselines.json" --pr 99999999999999999999 >/dev/null 2>&1; then
  bad "overflow-sized PR number fails before arithmetic normalization"
else
  ok "overflow-sized PR number fails before arithmetic normalization"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
