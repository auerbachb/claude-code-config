#!/usr/bin/env bash
# check-runs-dedup.sh — Collapse a check-run list to one verdict per check,
# newest check suite wins (issue #675).
#
# Why this exists: GitHub keeps a check-run record for EVERY run of a check on a
# commit. Re-triggering a workflow on the same SHA (a PR-body edit re-firing a
# required workflow, a manual re-run) creates a NEW check suite, so the
# `commits/{sha}/check-runs` endpoint returns the old failed run alongside the new
# passing one. The endpoint's default `filter=latest` does not help — it is
# latest-per-*suite*, and each re-trigger is its own suite. GitHub's own PR page
# and merge box resolve each check name to its newest run; tooling that reads the
# raw list instead reports a superseded failure as currently blocking, refusing a
# merge GitHub itself shows as green.
#
# Dedup rule: group runs by (app identity, check name); within each group find the
# highest `check_suite.id`; retain ALL runs belonging to that newest suite.
#
#   - Newest-SUITE-per-name, never latest-single-RUN-per-name. Matrix legs share a
#     name within one suite, so keeping only one run per name would let a passing
#     leg mask a failing sibling.
#   - The group key includes the app, so same-named checks from different apps
#     (e.g. two bots both publishing "lint") never collapse into each other.
#   - Ordering is by `check_suite.id`, not `completed_at`: an in-progress run has
#     `completed_at: null`, so time-ordering would let an older FAILED run outrank
#     the newest still-running one and report a check as failing when the honest
#     answer is "not finished yet". `check_suite.id` is the only ordering key
#     present on runs in every status. Same-second re-runs also tie on timestamps.
#   - Runs whose `check_suite.id` is null are retained regardless of their group's
#     newest suite. Dropping a run can only ever MASK a failure, so unknown data
#     fails toward blocking.
#
# Retained run objects are emitted with every field intact — callers read varying
# fields (`conclusion`, `status`, `output.title`, `details_url`, `html_url`).
#
# Usage:
#   check-runs-dedup.sh < check-runs.json
#   check-runs-dedup.sh --help
#
# Input (stdin) — any shape the callers already produce:
#   - a bare JSON array of check-run objects            (pr-state.sh)
#   - a single {"check_runs": [...]} object             (merge-gate.sh)
#   - a `gh api --paginate` stream of concatenated objects of either form
#   - a stream of bare check-run objects, as produced by
#     `gh api --paginate --jq '.check_runs[]?'` (the --jq filter runs once PER
#     PAGE, so the output is concatenated objects, not one array)
#
# Output (stdout): a single compact JSON array of the retained check-run objects.
# Empty input yields `[]` — callers relying on a `total == 0` sentinel (see
# ci-status.sh) still see zero runs rather than an error.
#
# Exit codes:
#   0 — deduped array written to stdout
#   2 — usage error
#   5 — stdin could not be parsed as check-run JSON

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

print_usage() {
  awk '
    NR == 1 { next }
    /^# Usage:/ { in_block = 1 }
    in_block && !/^#/ { exit }
    in_block {
      sub(/^# ?/, "")
      print
    }
  ' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "ERROR: unexpected argument: $1 (input is read from stdin)" >&2
      print_usage >&2
      exit 2
      ;;
  esac
done

# `-s` slurps the concatenated-object stream into an array; the normalizer below
# then flattens whichever of the accepted shapes each element turns out to be.
#
# Non-object elements are deliberately NOT filtered out: `.app` on a scalar raises
# a jq error, which surfaces as exit 5 here and as a parse error in the caller.
# Silently dropping unparseable entries could hide a failing run.
DEDUPED=$(jq -s -c '
  [ .[]
    | if type == "array" then .[]
      elif (type == "object" and has("check_runs")) then (.check_runs[]?)
      elif type == "object" then .
      else empty
      end
  ]
  | group_by([.app.slug, .app.id, .name])
  | map(
      ([.[] | .check_suite.id | select(. != null)] | max) as $newest
      | if $newest == null then .
        else [ .[] | select((.check_suite.id == null) or (.check_suite.id == $newest)) ]
        end
    )
  | add // []
' 2>/dev/null)

if [[ -z "$DEDUPED" ]]; then
  echo "ERROR: could not parse check-runs JSON from stdin" >&2
  exit 5
fi

printf '%s\n' "$DEDUPED"
