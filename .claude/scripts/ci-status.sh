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
#   ci-status.sh <head_sha_or_pr_number> [--format json|summary] [--check-runs-stdin]
#   ci-status.sh --help
#
# Input resolution:
#   - All-digit argument -> treated as PR number; HEAD SHA is resolved via gh pr view
#   - Otherwise -> treated as a commit SHA (full or abbreviated, as accepted by the API)
#
# --check-runs-stdin:
#   Read the GitHub check-runs JSON from stdin instead of calling `gh api`. Lets
#   callers that already fetched the same endpoint (e.g. merge-gate.sh) avoid a
#   redundant API round-trip and eliminates the data-consistency gap between two
#   separate fetches. Accepts either a single `{check_runs: [...]}` object or the
#   `--paginate`-style stream of concatenated objects. Requires a full SHA input
#   (PR-number resolution still calls `gh pr view`, but the check-runs fetch is
#   skipped).
#
# Output (JSON, default):
#   {
#     "head_sha": "abc1234...",
#     "total": N,
#     "passing": N,
#     "failing": N,
#     "in_progress": N,
#     "blocking": [{"id": N, "name": "...", "conclusion": "..."}, ...],
#     "in_progress_runs": [{"id": N, "name": "...", "status": "..."}, ...]
#   }
#
# `id` is the GitHub check-run ID — included so callers (e.g. the /merge and
# /wrap flows that fetch `gh api repos/.../check-runs/{id}` for output.summary)
# can disambiguate matrix jobs that share a `name`. Synthesized "no check-runs
# reported yet" sentinels have id: null.
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
CHECK_RUNS_STDIN=0

print_usage() {
  awk '
    NR == 1 { next }
    /^# Usage:/, /^# Exit-code priority/ {
      sub(/^# ?/, "")
      print
    }
  ' "$0"
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
    --check-runs-stdin)
      CHECK_RUNS_STDIN=1
      shift
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
# Resolve HEAD SHA (+ owner/repo only if we need to fetch check-runs ourselves)
# --------------------------------------------------------------------------
HEAD_SHA=""
# All-digits AND length < 10 -> PR number. Longer all-digit strings (e.g. a
# 40-char all-zero SHA, or any numeric-only abbreviated SHA) fall through to
# the SHA path so we don't mis-resolve them as astronomically large PR numbers.
if [[ "$INPUT" =~ ^[0-9]+$ ]] && [[ "${#INPUT}" -lt 10 ]]; then
  # Numeric-only short input — try resolving as a PR number first. If GitHub
  # returns 404, fall back to treating the input as an abbreviated commit SHA
  # (short numeric-only SHAs like "1234567" are otherwise misclassified and
  # rejected). Auth / network errors still exit 5. Capture stderr from
  # `gh pr view` so we can distinguish 404 ("no pull requests found" /
  # "GraphQL: Could not resolve to a PullRequest") from other gh failures
  # (e.g. "HTTP 401", "connection refused", DNS resolver failures).
  PR_VIEW_RC=0
  PR_VIEW_OUT=$(gh pr view "$INPUT" --json headRefOid 2>&1) || PR_VIEW_RC=$?
  if [[ "$PR_VIEW_RC" -ne 0 ]] || [[ -z "$PR_VIEW_OUT" ]]; then
    if echo "$PR_VIEW_OUT" | grep -qiE 'no pull requests found|could not resolve to a pullrequest|HTTP 404'; then
      # Not a PR — treat as an abbreviated commit SHA. The check-runs API
      # accepts abbreviated forms; if the SHA is also invalid, that request
      # will return 404 below and we exit 4 there.
      HEAD_SHA="$INPUT"
    else
      echo "ERROR: gh pr view failed: $PR_VIEW_OUT" >&2
      exit 5
    fi
  else
    HEAD_SHA=$(echo "$PR_VIEW_OUT" | jq -r '.headRefOid // ""' 2>/dev/null)
    if [[ -z "$HEAD_SHA" ]]; then
      echo "ERROR: could not resolve HEAD SHA for PR #$INPUT" >&2
      exit 4
    fi
  fi
else
  # Treat as SHA — API accepts full or abbreviated forms.
  HEAD_SHA="$INPUT"
fi

# --------------------------------------------------------------------------
# Obtain check-runs — from stdin (caller-provided) or via gh api (paginated).
# --------------------------------------------------------------------------
if [[ "$CHECK_RUNS_STDIN" -eq 1 ]]; then
  CHECK_RUNS_RAW=$(cat)
  if [[ -z "$CHECK_RUNS_RAW" ]]; then
    echo "ERROR: --check-runs-stdin set but stdin was empty" >&2
    exit 2
  fi
else
  OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
  if [[ -z "$OWNER_REPO" ]]; then
    echo "ERROR: gh repo view failed — not in a git repo or no remote" >&2
    exit 5
  fi
  OWNER="${OWNER_REPO%/*}"
  REPO="${OWNER_REPO#*/}"

  if ! CHECK_RUNS_RAW=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs?per_page=100" 2>&1); then
    # Distinguish 404 (SHA not found) from other gh errors by pattern-matching
    # the stderr message text. `gh api` exits non-zero and writes "HTTP 404" /
    # "Not Found" / "No commit found for SHA" to stderr; it does not expose the
    # HTTP status code as a structured field on the error path, so a text grep
    # is the available signal. Narrow to explicit 404 indicators only — DNS
    # "could not resolve host" failures, auth errors, etc. must fall through
    # to exit 5, not be mis-classified as commit-not-found (exit 4).
    # Pre-existing behavior — not affected by the --check-runs-stdin path
    # (stdin callers are responsible for their own HTTP error handling).
    if echo "$CHECK_RUNS_RAW" | grep -qiE 'HTTP 404|Not Found|No commit found for SHA'; then
      echo "ERROR: commit $HEAD_SHA not found" >&2
      exit 4
    fi
    echo "ERROR: gh api check-runs failed: $CHECK_RUNS_RAW" >&2
    exit 5
  fi
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
# An empty check_runs array (right after a push, before GitHub has wired up
# any workflows) must NOT be reported as clean — otherwise merge-gate.sh and
# downstream `/merge` / `/wrap` callers will proceed as if CI passed when no
# checks have even started. Surface total==0 as in_progress in the JSON AND
# via exit 1, not just implicitly via exit 0.
SPLIT=$(echo "$RUNS_JSON" | jq -c --arg head_sha "$HEAD_SHA" '
  def is_blocking: . == "failure" or . == "timed_out" or . == "action_required" or . == "startup_failure" or . == "stale";
  . as $runs
  | ([$runs[] | select(.status != "completed")]) as $incomplete
  | {
    head_sha: $head_sha,
    total: ($runs | length),
    passing: ([$runs[] | select(.status == "completed" and (.conclusion | is_blocking | not))] | length),
    failing: ([$runs[] | select(.status == "completed" and (.conclusion | is_blocking))] | length),
    in_progress: (($incomplete | length) + (if ($runs | length) == 0 then 1 else 0 end)),
    blocking: [$runs[] | select(.status == "completed" and (.conclusion | is_blocking)) | {id, name, conclusion}],
    in_progress_runs: (($incomplete | map({id, name, status})) + (if ($runs | length) == 0 then [{id: null, name: "(no check-runs reported yet)", status: "queued"}] else [] end))
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
