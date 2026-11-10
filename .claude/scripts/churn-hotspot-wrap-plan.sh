#!/usr/bin/env bash
# churn-hotspot-wrap-plan.sh — Classify detector output for /wrap (Issue #1307).
# catalog: backlog-pm — Classify churn detector JSON into `/wrap` action and suppression sets using recorded decision baselines
#
# The detector stays read-only and policy-free. This consumer turns its JSON
# envelope into disjoint action sets plus the aggregate that /wrap records.
# It never calls git/gh and never mutates state.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_BASELINES="$SCRIPT_DIR/../reference/churn-hotspot-baselines.json"

INPUT="-"
BASELINES="$DEFAULT_BASELINES"
PR_NUMBER=""

usage() {
  cat <<'EOF'
Usage: churn-hotspot-wrap-plan.sh [--input FILE] [--baselines FILE] --pr N

Reads a churn-hotspots.sh --json envelope and emits wrap-churn-plan/v1 JSON.
FILE defaults to stdin. The baseline defaults to:
  .claude/reference/churn-hotspot-baselines.json

The script is read-only. It does not call churn-hotspots.sh, git, or gh.
EOF
}

die() {
  echo "churn-hotspot-wrap-plan.sh: $1" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      [[ $# -ge 2 ]] || die "--input requires a file"
      INPUT="$2"
      shift 2
      ;;
    --baselines)
      [[ $# -ge 2 ]] || die "--baselines requires a file"
      BASELINES="$2"
      shift 2
      ;;
    --pr)
      [[ $# -ge 2 ]] || die "--pr requires a number"
      PR_NUMBER="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$PR_NUMBER" =~ ^[0-9]{1,10}$ ]] || die "--pr must be a positive 32-bit integer"
PR_NUMBER=$((10#$PR_NUMBER))
[[ "$PR_NUMBER" -gt 0 && "$PR_NUMBER" -le 2147483647 ]] ||
  die "--pr must be a positive 32-bit integer"
INPUT_PATH="$INPUT"
BASELINES_PATH="$BASELINES"
[[ "$INPUT_PATH" == -* && "$INPUT_PATH" != "-" ]] && INPUT_PATH="./$INPUT_PATH"
[[ "$BASELINES_PATH" == -* ]] && BASELINES_PATH="./$BASELINES_PATH"

[[ -r "$BASELINES_PATH" ]] || die "baseline file is not readable: $BASELINES"
if [[ "$INPUT_PATH" != "-" ]]; then
  [[ -r "$INPUT_PATH" ]] || die "input file is not readable: $INPUT"
fi

for dep in jq mktemp; do
  command -v "$dep" >/dev/null 2>&1 || die "'$dep' not found on PATH"
done

TMP_INPUT=$(mktemp)
trap 'rm -f "$TMP_INPUT"' EXIT
if [[ "$INPUT_PATH" == "-" ]]; then
  cp /dev/stdin "$TMP_INPUT"
else
  cp "$INPUT_PATH" "$TMP_INPUT"
fi

jq -e '
  (.total_hotspot_count | type == "number" and . >= 0 and floor == .) and
  (.conflict_weight | type == "number" and . >= 0 and floor == .) and
  (.truncated | type == "boolean") and
  (.existing_lookup_failed | type == "boolean") and
  (.hotspots | type == "array") and
  (.total_hotspot_count == (.hotspots | length)) and
  (. as $detector | [.hotspots[] |
    (.file | type == "string") and
    (.file | length > 0) and
    (.score | type == "number" and . >= 0 and floor == .) and
    (.pr_count | type == "number" and . >= 2 and floor == .) and
    (.score == (.pr_count + ($detector.conflict_weight * .conflict_rounds))) and
    (.conflict_rounds | type == "number" and . >= 0 and floor == .) and
    (.pr_numbers | type == "array") and
    ((.pr_numbers | length) == .pr_count) and
    (all(.pr_numbers[]; type == "number" and . > 0 and floor == .)) and
    has("existing_hotspot_issue") and
    has("existing_hotspot_issue_state") and
    (
      (.existing_hotspot_issue == null and .existing_hotspot_issue_state == null) or
      ((.existing_hotspot_issue | type) == "number" and
       .existing_hotspot_issue > 0 and
       (.existing_hotspot_issue | floor) == .existing_hotspot_issue and
       (.existing_hotspot_issue_state == "open" or
        .existing_hotspot_issue_state == "closed" or
        .existing_hotspot_issue_state == "unknown"))
    )
  ] | all)
' "$TMP_INPUT" >/dev/null || die "input is not a valid churn-hotspots JSON envelope"

jq -e '.existing_lookup_failed == false' "$TMP_INPUT" >/dev/null ||
  die "existing hotspot issue lookup is incomplete; refusing to classify mutations"

jq -e '.truncated == false' "$TMP_INPUT" >/dev/null ||
  die "detector output is truncated; refusing to classify mutations"

jq -e '
  .schema == "churn-hotspot-baselines/v1" and
  (.material_growth_multiplier | type == "number" and . >= 2) and
  (.hotspots | type == "object") and
  (all(.hotspots | to_entries[];
    (.key | type == "string" and length > 0) and
    (.value | type == "object") and
    ((.value.issue | type) == "number") and
    (.value.issue > 0) and
    (.value.issue == (.value.issue | floor)) and
    ((.value.score_at_decision | type) == "number") and
    (.value.score_at_decision > 0) and
    (.value.score_at_decision == (.value.score_at_decision | floor)) and
    ((.value.pr_count_at_decision | type) == "number") and
    (.value.pr_count_at_decision >= 2) and
    (.value.pr_count_at_decision == (.value.pr_count_at_decision | floor)) and
    (.value.score_at_decision >= .value.pr_count_at_decision) and
    (.value.as_of | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
  ))
' "$BASELINES_PATH" >/dev/null || die "baseline file is not churn-hotspot-baselines/v1"

jq -n \
  --slurpfile detector "$TMP_INPUT" \
  --slurpfile baseline "$BASELINES_PATH" \
  --argjson pr "$PR_NUMBER" '
  ($detector[0]) as $d |
  ($baseline[0]) as $b |
  ($b.material_growth_multiplier) as $multiplier |

  def issue_state:
    if .existing_hotspot_issue == null then "none"
    elif .existing_hotspot_issue_state == "open" then "open"
    elif .existing_hotspot_issue_state == "closed" then "closed"
    else "unknown"
    end;

  def baseline_for($h):
    $b.hotspots[$h.file] as $entry |
    if ($entry | type) == "object" and
       ($entry.issue == $h.existing_hotspot_issue) and
       (($entry.score_at_decision | type) == "number")
    then $entry
    else null
    end;

  def base_row($h):
    {
      file: $h.file,
      score: $h.score,
      pr_count: $h.pr_count,
      conflict_rounds: $h.conflict_rounds,
      issue: $h.existing_hotspot_issue,
      issue_state: ($h | issue_state)
    };

  [ $d.hotspots[] | select((issue_state) == "open" and (.pr_numbers | index($pr) != null)) |
    base_row(.) + {kind: "append_evidence"}
  ] as $comments |

  [ $d.hotspots[] |
    select((issue_state) == "none" or ((issue_state) == "closed" and .conflict_rounds > 0)) |
    base_row(.) + {
      kind: (if (issue_state) == "none" then "new_issue" else "closed_conflict_refile" end)
    }
  ] | sort_by([-.score, -.pr_count, .file]) as $files |

  [ $d.hotspots[] | select((issue_state) == "unknown") |
    base_row(.) + {kind: "unknown_issue_state"}
  ] as $unknown |

  [ $d.hotspots[] |
    select((issue_state) == "closed" and .conflict_rounds == 0) |
    . as $h |
    (baseline_for($h)) as $entry |
    select($entry != null and $h.score >= ($entry.score_at_decision * $multiplier)) |
    base_row($h) + {
      kind: "material_growth",
      baseline_score: $entry.score_at_decision,
      growth_multiplier: $multiplier,
      baseline_as_of: $entry.as_of
    }
  ] as $growth |

  [ $d.hotspots[] |
    select((issue_state) == "closed" and .conflict_rounds == 0) |
    . as $h |
    (baseline_for($h)) as $entry |
    select($entry == null or $h.score < ($entry.score_at_decision * $multiplier)) |
    base_row($h) + {
      kind: "closed_no_conflict_suppressed",
      baseline_score: ($entry.score_at_decision // null),
      growth_multiplier: $multiplier,
      baseline_as_of: ($entry.as_of // null),
      reason: (if $entry == null then "no_matching_baseline" else "below_material_growth_threshold" end)
    }
  ] as $suppressed |

  ($files[0] // null) as $selected_file |
  ($growth + $unknown +
    (if $selected_file != null and $selected_file.kind == "closed_conflict_refile"
     then [$selected_file] else [] end)) as $decisions |
  {
    schema: "wrap-churn-plan/v1",
    total_hotspot_count: $d.total_hotspot_count,
    returned_hotspot_count: ($d.hotspots | length),
    conflict_cost_count: ([ $d.hotspots[] | select(.conflict_rounds > 0) ] | length),
    surfaced_decision_count: ($decisions | length),
    suppressed_count: ($suppressed | length),
    material_growth_multiplier: $multiplier,
    comment_set: $comments,
    file_set: $files,
    selected_file: $selected_file,
    held_back_file_count: ([$files | length - 1, 0] | max),
    material_growth_set: $growth,
    unknown_state_set: $unknown,
    suppressed_set: $suppressed,
    summary: (
      "\($d.total_hotspot_count) churn hotspots, " +
      "\([ $d.hotspots[] | select(.conflict_rounds > 0) ] | length) with conflict cost, " +
      "\($decisions | length) surfaced for decision, " +
      "\($suppressed | length) suppressed (closed, no conflict cost)"
    )
  }
' 
