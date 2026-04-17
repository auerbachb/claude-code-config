#!/usr/bin/env bash
# ci-status.sh — Summarize CI check-run health for a commit or PR.
#
# Implements the CI-must-pass contract from .claude/rules/cr-merge-gate.md Step 1b:
# "all check-runs must be status=completed AND none in the blocking conclusion set".
# Blocking conclusions: failure, timed_out, action_required, startup_failure, stale.
# Non-blocking: success, neutral, skipped, cancelled.
#
# Used by .claude/scripts/merge-gate.sh (internally) and can be called standalone
# from any skill/agent that needs a CI-only health check without running the full
# merge gate.
#
# Usage:
#   ci-status.sh <head_sha_or_pr_number> [--format json|summary]
#   ci-status.sh --help
#
# Input resolution:
#   - All-digit argument -> treated as PR number; HEAD SHA is resolved via gh pr view
#   - Otherwise -> treated as a commit SHA (full or abbreviated, as accepted by the API)
#
# Output (JSON, default):
#   {
#     "head_sha": "abc1234...",
#     "total": N,
#     "passing": N,
#     "failing": N,
#     "in_progress": N,
#     "blocking": [{"name": "...", "conclusion": "..."}, ...],
#     "in_progress_runs": [{"name": "...", "status": "..."}, ...]
#   }
#
# Output (summary, one line):
#   CI: <passing>/<total> passed, <failing> failing (names), <in_progress> in progress (names)
#
# Exit codes:
#   0 — CI clean and complete (failing=0, in_progress=0)
#   1 — incomplete runs remain (in_progress>0, no failing)  [caller: WAIT]
#   2 — usage error
#   3 — blocking failures present (failing>0)               [caller: FIX]
#   4 — SHA or PR not found
#   5 — gh / network / jq error
#
# Exit-code priority when both failing and in_progress are present: 3 (fix) wins over
# 1 (wait) — a broken check is actionable immediately while the in-progress ones might
# turn red too; the caller should fix the known failures first.

set -uo pipefail

FORMAT="json"
INPUT=""

print_usage() {
  awk 'NR == 1 { next } /^$/ { exit } { print }' "$0"
}

# --------------------------------------------------------------------------
# Arg parsing
# --------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    --format)
      FORMAT="${2:-}"
      if [[ -z "$FORMAT" ]]; then
        echo "ERROR: --format requires a value (json|summary)" >&2
        exit 2
      fi
      case "$FORMAT" in
        json|summary) ;;
        *)
          echo "ERROR: --format must be 'json' or 'summary' (got: $FORMAT)" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    -*)
      echo "ERROR: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$INPUT" ]]; then
        echo "ERROR: unexpected argument: $1 (input already set to $INPUT)" >&2
        exit 2
      fi
      INPUT="$1"
      shift
      ;;
  esac
done

if [[ -z "$INPUT" ]]; then
  echo "ERROR: <head_sha_or_pr_number> is required" >&2
  print_usage >&2
  exit 2
fi

# --------------------------------------------------------------------------
# Resolve owner/repo + HEAD SHA
# --------------------------------------------------------------------------
OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
if [[ -z "$OWNER_REPO" ]]; then
  echo "ERROR: gh repo view failed — not in a git repo or no remote" >&2
  exit 5
fi
OWNER="${OWNER_REPO%/*}"
REPO="${OWNER_REPO#*/}"

HEAD_SHA=""
# All-digits AND length < 10 -> PR number. Longer all-digit strings (e.g. a
# 40-char all-zero SHA, or any numeric-only abbreviated SHA) fall through to
# the SHA path so we don't mis-resolve them as astronomically large PR numbers.
if [[ "$INPUT" =~ ^[0-9]+$ ]] && [[ "${#INPUT}" -lt 10 ]]; then
  # PR number — resolve HEAD SHA via gh pr view.
  PR_JSON=$(gh pr view "$INPUT" --json headRefOid,state 2>/dev/null || true)
  if [[ -z "$PR_JSON" ]]; then
    echo "ERROR: PR #$INPUT not found" >&2
    exit 4
  fi
  HEAD_SHA=$(echo "$PR_JSON" | jq -r '.headRefOid // ""')
  if [[ -z "$HEAD_SHA" ]]; then
    echo "ERROR: could not resolve HEAD SHA for PR #$INPUT" >&2
    exit 4
  fi
else
  # Treat as SHA — API accepts full or abbreviated forms.
  HEAD_SHA="$INPUT"
fi

# --------------------------------------------------------------------------
# Fetch check-runs (paginated)
# --------------------------------------------------------------------------
if ! CHECK_RUNS_RAW=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs?per_page=100" 2>&1); then
  # Distinguish 404 (SHA not found) from other gh errors.
  if echo "$CHECK_RUNS_RAW" | grep -qiE 'not found|no commit found|could not resolve'; then
    echo "ERROR: commit $HEAD_SHA not found" >&2
    exit 4
  fi
  echo "ERROR: gh api check-runs failed: $CHECK_RUNS_RAW" >&2
  exit 5
fi

# gh --paginate concatenates per-page objects; flatten to a single check_runs array.
RUNS_JSON=$(echo "$CHECK_RUNS_RAW" | jq -s '[.[].check_runs[]?]' 2>/dev/null || true)
if [[ -z "$RUNS_JSON" ]]; then
  echo "ERROR: could not parse check-runs JSON" >&2
  exit 5
fi

# --------------------------------------------------------------------------
# Classify runs
# --------------------------------------------------------------------------
SPLIT=$(echo "$RUNS_JSON" | jq -c --arg head_sha "$HEAD_SHA" '
  def is_blocking: . == "failure" or . == "timed_out" or . == "action_required" or . == "startup_failure" or . == "stale";
  {
    head_sha: $head_sha,
    total: length,
    passing: ([.[] | select(.status == "completed" and (.conclusion | is_blocking | not))] | length),
    failing: ([.[] | select(.status == "completed" and (.conclusion | is_blocking))] | length),
    in_progress: ([.[] | select(.status != "completed")] | length),
    blocking: [.[] | select(.status == "completed" and (.conclusion | is_blocking)) | {name, conclusion}],
    in_progress_runs: [.[] | select(.status != "completed") | {name, status}]
  }
' 2>/dev/null)

if [[ -z "$SPLIT" ]] || ! echo "$SPLIT" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: could not classify check-runs JSON" >&2
  exit 5
fi

FAILING=$(echo "$SPLIT" | jq -r '.failing // 0')
IN_PROGRESS=$(echo "$SPLIT" | jq -r '.in_progress // 0')

# --------------------------------------------------------------------------
# Emit output
# --------------------------------------------------------------------------
if [[ "$FORMAT" == "summary" ]]; then
  TOTAL=$(echo "$SPLIT" | jq -r '.total')
  PASSING=$(echo "$SPLIT" | jq -r '.passing')
  BLOCKING_NAMES=$(echo "$SPLIT" | jq -r '.blocking | map(.name) | join(", ")')
  IN_PROG_NAMES=$(echo "$SPLIT" | jq -r '.in_progress_runs | map(.name) | join(", ")')
  LINE="CI: $PASSING/$TOTAL passed"
  if [[ "$FAILING" -gt 0 ]]; then
    LINE="$LINE, $FAILING failing ($BLOCKING_NAMES)"
  fi
  if [[ "$IN_PROGRESS" -gt 0 ]]; then
    LINE="$LINE, $IN_PROGRESS in progress ($IN_PROG_NAMES)"
  fi
  echo "$LINE"
else
  echo "$SPLIT"
fi

# --------------------------------------------------------------------------
# Exit code — fix (3) beats wait (1).
# --------------------------------------------------------------------------
if [[ "$FAILING" -gt 0 ]]; then
  exit 3
fi
if [[ "$IN_PROGRESS" -gt 0 ]]; then
  exit 1
fi
exit 0
