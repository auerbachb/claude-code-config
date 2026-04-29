#!/usr/bin/env bash
# merge-gate.sh — Verify the merge gate for a PR (CR / BugBot / Greptile).
#
# Implements the authoritative gate defined in .claude/rules/cr-merge-gate.md:
#   - CR path       : 1 explicit CR APPROVED review whose commit_id == current HEAD SHA
#                     + zero unresolved CR threads (SHA freshness enforced; acks /
#                     check-run completion alone do NOT satisfy the gate)
#   - BugBot path   : 1 clean BugBot review on current HEAD + zero unresolved BugBot threads
#   - Greptile path : severity-gated — clean OR only P1/P2 (fixed) OR P0 fixed + re-review clean
# Also enforces the pre-merge CI gate from .claude/rules/cr-merge-gate.md Step 1b
# (incomplete runs OR blocking conclusions = not merge-ready) and the BEHIND check
# (mergeStateStatus != BEHIND) per issue #273.
#
# Usage:
#   merge-gate.sh <pr_number> [--reviewer cr|bugbot|greptile]
#   merge-gate.sh --help
#
# Reviewer resolution order (unless --reviewer is passed):
#   1. ~/.claude/session-state.json  .prs["<N>"].reviewer  ("cr"/"bugbot"/"greptile"/"g")
#   2. Live history scan — greptile-apps[bot] present → greptile;
#      cursor[bot] present AND coderabbitai[bot] absent → bugbot; else cr.
#      (BugBot auto-triggers on every push, so both bots are present on normal
#      CR-owned PRs. The absence check ensures the live scan defaults to cr;
#      CR→BugBot escalation is tracked via session-state, not the live scan.)
#
# Output (always JSON on stdout — one line, even on failure):
#   {
#     "met": true|false,
#     "reviewer": "cr"|"bugbot"|"greptile"|"unknown",
#     "path": "cr"|"bugbot"|"greptile",
#     "missing": ["reason", ...],
#     "head_sha": "abc1234...",
#     "ci_status": {
#       "total": N, "passing": N, "failing": N, "in_progress": N,
#       "blocking": [{"name": "...", "conclusion": "..."}],
#       "incomplete": [{"name": "...", "status": "..."}]
#     },
#     "merge_state": "CLEAN"|"BEHIND"|"BLOCKED"|...
#   }
#
# Exit codes:
#   0 — gate met
#   1 — gate not met (JSON body includes .missing)
#   2 — usage error
#   3 — PR not found (or closed/merged)
#   4 — gh / network / jq error

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log"

# --------------------------------------------------------------------------
# Arg parsing
# --------------------------------------------------------------------------
PR_NUMBER=""
REVIEWER_OVERRIDE=""

print_usage() {
  awk 'NR == 1 { next } /^$/ { exit } { print }' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    --reviewer)
      REVIEWER_OVERRIDE="${2:-}"
      if [[ -z "$REVIEWER_OVERRIDE" ]]; then
        echo "ERROR: --reviewer requires a value (cr|bugbot|greptile)" >&2
        exit 2
      fi
      case "$REVIEWER_OVERRIDE" in
        cr|bugbot|greptile) ;;
        *)
          echo "ERROR: --reviewer must be one of: cr, bugbot, greptile (got: $REVIEWER_OVERRIDE)" >&2
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
      if [[ -n "$PR_NUMBER" ]]; then
        echo "ERROR: unexpected argument: $1 (PR number already set to $PR_NUMBER)" >&2
        exit 2
      fi
      PR_NUMBER="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUMBER" ]]; then
  echo "ERROR: <pr_number> is required" >&2
  print_usage >&2
  exit 2
fi

if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "ERROR: <pr_number> must be a positive integer (got: $PR_NUMBER)" >&2
  exit 2
fi

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
emit_json() {
  # emit_json <met> <reviewer> <path> <missing_json_array> <head_sha> <ci_status_json> <merge_state>
  local met="$1" reviewer="$2" path="$3" missing="$4" head_sha="$5" ci_status="$6" merge_state="$7"
  jq -cn \
    --argjson met "$met" \
    --arg reviewer "$reviewer" \
    --arg path "$path" \
    --argjson missing "$missing" \
    --arg head_sha "$head_sha" \
    --argjson ci_status "$ci_status" \
    --arg merge_state "$merge_state" \
    '{met: $met, reviewer: $reviewer, path: $path, missing: $missing, head_sha: $head_sha, ci_status: $ci_status, merge_state: $merge_state}'
}

emit_empty_ci() {
  echo '{"total":0,"passing":0,"failing":0,"in_progress":0,"blocking":[],"incomplete":[]}'
}

# --------------------------------------------------------------------------
# Fetch PR context
# --------------------------------------------------------------------------
OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
if [[ -z "$OWNER_REPO" ]]; then
  emit_json false unknown cr '["gh repo view failed — not in a git repo or no remote"]' "" "$(emit_empty_ci)" ""
  exit 4
fi
OWNER="${OWNER_REPO%/*}"
REPO="${OWNER_REPO#*/}"

PR_JSON=$(gh pr view "$PR_NUMBER" --json number,state,headRefOid,mergeStateStatus,mergeable 2>/dev/null || true)
if [[ -z "$PR_JSON" ]]; then
  emit_json false unknown cr "[\"PR #$PR_NUMBER not found\"]" "" "$(emit_empty_ci)" ""
  exit 3
fi

PR_STATE=$(echo "$PR_JSON" | jq -r '.state // "UNKNOWN"')
HEAD_SHA=$(echo "$PR_JSON" | jq -r '.headRefOid // ""')
MERGE_STATE=$(echo "$PR_JSON" | jq -r '.mergeStateStatus // ""')

if [[ "$PR_STATE" != "OPEN" ]]; then
  emit_json false unknown cr "[\"PR #$PR_NUMBER is $PR_STATE — not open\"]" "$HEAD_SHA" "$(emit_empty_ci)" "$MERGE_STATE"
  exit 3
fi

if [[ -z "$HEAD_SHA" ]]; then
  emit_json false unknown cr '["could not determine HEAD SHA"]' "" "$(emit_empty_ci)" "$MERGE_STATE"
  exit 4
fi

# --------------------------------------------------------------------------
# Fetch data once, reuse everywhere
# --------------------------------------------------------------------------
# Fail closed on gh api errors — inline checks in the MAIN script context, not
# inside a helper function called via $(), because exit inside $() only kills
# the subshell and the main script continues with garbage data.
die_api() {
  emit_json false "${REVIEWER_OVERRIDE:-unknown}" "unknown" "[\"gh api failed: $1\"]" "$HEAD_SHA" "$(emit_empty_ci)" "$MERGE_STATE"
  exit 4
}

if ! CHECK_RUNS_RAW=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs?per_page=100" 2>/dev/null); then
  die_api "check-runs"
fi
# `gh --paginate` concatenates per-page objects; flatten to a single
# {check_runs: [...]} object so downstream `.check_runs[]` jq queries work.
CHECK_RUNS_JSON=$(echo "$CHECK_RUNS_RAW" | jq -s '{check_runs: [.[].check_runs[]?]}' 2>/dev/null || true)
if [[ -z "$CHECK_RUNS_JSON" ]] || ! echo "$CHECK_RUNS_JSON" | jq -e . >/dev/null 2>&1; then
  die_api "check-runs parse"
fi

# Delegate CI status classification to ci-status.sh — single source of truth for
# the blocking/in-progress/passing splits. Pipe the already-fetched check-runs
# JSON via --check-runs-stdin so we don't make a second identical API call (and
# don't open a data-consistency gap between two fetches). The script exits
# non-zero when CI is not clean; suppress that here (the merge gate consumes the
# JSON and decides itself).
CI_STATUS_JSON=$(echo "$CHECK_RUNS_JSON" | "$(dirname "$0")/ci-status.sh" "$HEAD_SHA" --format json --check-runs-stdin 2>/dev/null || true)
if [[ -z "$CI_STATUS_JSON" ]] || ! echo "$CI_STATUS_JSON" | jq -e . >/dev/null 2>&1; then
  die_api "ci-status.sh"
fi

if ! REVIEWS_JSON=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews?per_page=100" 2>/dev/null); then
  die_api "reviews"
fi
if ! PR_COMMENTS_JSON=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments?per_page=100" 2>/dev/null); then
  die_api "pull-comments"
fi
if ! ISSUE_COMMENTS_JSON=$(gh api "repos/$OWNER/$REPO/issues/$PR_NUMBER/comments?per_page=100" 2>/dev/null); then
  die_api "issue-comments"
fi

# Unresolved review threads via GraphQL (covers all bot authors consistently).
if ! THREADS_JSON=$(gh api graphql -f query="query { repository(owner: \"$OWNER\", name: \"$REPO\") { pullRequest(number: $PR_NUMBER) { reviewThreads(first: 100) { nodes { isResolved comments(first: 100) { nodes { author { login } } } } } } } }" 2>/dev/null); then
  die_api "GraphQL-reviewThreads"
fi

# --------------------------------------------------------------------------
# CI status — delegated to ci-status.sh; adapt its shape for this script's
# legacy output key names (ci-status.sh uses `in_progress_runs`; this script's
# emitted JSON has always called that field `incomplete`). Drop the `head_sha`
# field ci-status.sh adds — this script emits it at the top level already.
# --------------------------------------------------------------------------
CI_STATUS=$(echo "$CI_STATUS_JSON" | jq -c '{
  total,
  passing,
  failing,
  in_progress,
  blocking,
  incomplete: .in_progress_runs
}')

# --------------------------------------------------------------------------
# Reviewer resolution
# --------------------------------------------------------------------------
resolve_reviewer() {
  local from_override="$REVIEWER_OVERRIDE"
  if [[ -n "$from_override" ]]; then
    echo "$from_override"
    return
  fi

  local state_file="${HOME}/.claude/session-state.json"
  if [[ -f "$state_file" ]]; then
    local from_state
    from_state=$(jq -r --arg pr "$PR_NUMBER" '.prs[$pr].reviewer // ""' "$state_file" 2>/dev/null || echo "")
    case "$from_state" in
      cr|bugbot|greptile) echo "$from_state"; return ;;
      g) echo "greptile"; return ;;
      "") ;;
      *) ;; # unknown value — fall through to live scan
    esac
  fi

  # Live history scan — collect all distinct bot authors from reviews + comments.
  local authors
  authors=$(
    {
      echo "$REVIEWS_JSON" | jq -r '.[]?.user.login // empty'
      echo "$PR_COMMENTS_JSON" | jq -r '.[]?.user.login // empty'
      echo "$ISSUE_COMMENTS_JSON" | jq -r '.[]?.user.login // empty'
    } | sort -u
  )

  if echo "$authors" | grep -q '^greptile-apps\[bot\]$'; then
    echo "greptile"; return
  fi
  # Only return bugbot when cursor[bot] is the sole reviewer — if coderabbitai[bot]
  # is also present, CR is the primary reviewer (BugBot auto-triggers on every push).
  # CR→BugBot escalation is tracked via session-state, not the live scan.
  if echo "$authors" | grep -q '^cursor\[bot\]$' && ! echo "$authors" | grep -q '^coderabbitai\[bot\]$'; then
    echo "bugbot"; return
  fi
  echo "cr"
}

REVIEWER=$(resolve_reviewer)

# --------------------------------------------------------------------------
# Gate evaluation — collect MISSING reasons; determinism comes from jq data paths.
# --------------------------------------------------------------------------
MISSING=()

# BEHIND check (#273) — applies to all paths.
if [[ "$MERGE_STATE" == "BEHIND" ]]; then
  MISSING+=("branch is BEHIND base — rebase + force-push before merging")
fi

# CI gate (#270) — applies to all paths.
CI_INCOMPLETE=$(echo "$CI_STATUS" | jq -r '.in_progress')
CI_FAILING=$(echo "$CI_STATUS" | jq -r '.failing')
if [[ "$CI_INCOMPLETE" -gt 0 ]]; then
  INCOMPLETE_NAMES=$(echo "$CI_STATUS" | jq -r '.incomplete | map(.name) | join(", ")')
  MISSING+=("CI has $CI_INCOMPLETE incomplete check-run(s): $INCOMPLETE_NAMES")
fi
if [[ "$CI_FAILING" -gt 0 ]]; then
  BLOCKING_NAMES=$(echo "$CI_STATUS" | jq -r '.blocking | map("\(.name) (\(.conclusion))") | join(", ")')
  MISSING+=("CI has $CI_FAILING failing check-run(s): $BLOCKING_NAMES")
fi

# Universal unresolved-thread gate (#211) — applies to all paths regardless of
# author. Catches threads from any reviewer (CR, BugBot, Greptile, Copilot,
# human) that the per-path author-scoped checks would miss.
UNRESOLVED_TOTAL=$(echo "$THREADS_JSON" | jq -r '
  [.data.repository.pullRequest.reviewThreads.nodes[]?
    | select(.isResolved == false)]
  | length')
if [[ "$UNRESOLVED_TOTAL" -gt 0 ]]; then
  MISSING+=("$UNRESOLVED_TOTAL unresolved review thread(s) — resolve via GraphQL before merge")
fi

# Path-specific checks.
case "$REVIEWER" in
  cr)

    # CodeRabbit check-run status on current HEAD.
    CR_CHECK=$(echo "$CHECK_RUNS_JSON" | jq -c '[.check_runs[]? | select(.name == "CodeRabbit")] | first // empty')
    CR_CHECK_OK=false
    if [[ -n "$CR_CHECK" ]]; then
      CR_STATUS=$(echo "$CR_CHECK" | jq -r '.status // ""')
      CR_CONCLUSION=$(echo "$CR_CHECK" | jq -r '.conclusion // ""')
      if [[ "$CR_STATUS" == "completed" && "$CR_CONCLUSION" == "success" ]]; then
        CR_CHECK_OK=true
      fi
    else
      # Fallback: legacy commit-status API.
      STATUSES_JSON=$(gh api "repos/$OWNER/$REPO/commits/$HEAD_SHA/statuses" 2>/dev/null || echo '[]')
      if echo "$STATUSES_JSON" | jq -e '.[] | select(.context | test("CodeRabbit"; "i")) | select(.state == "success")' >/dev/null 2>&1; then
        CR_CHECK_OK=true
      fi
    fi

    if [[ "$CR_CHECK_OK" != true ]]; then
      MISSING+=("CodeRabbit check-run not green on HEAD ${HEAD_SHA:0:7}")
    fi

    # Require 1 explicit CR APPROVED review on the current HEAD SHA (per issue #337).
    # SHA freshness is intrinsic to the filter: commit_id must equal $HEAD_SHA, so a
    # prior APPROVED on a stale SHA does NOT satisfy the gate.
    #
    # Also check for approval retraction on the current SHA — if CR posts an
    # APPROVED review and later posts a CHANGES_REQUESTED on the same SHA, the
    # approval is retracted and the gate is NOT met (even if a still-later
    # COMMENTED review is the literal last review). Compare the newest
    # APPROVED timestamp to the newest CHANGES_REQUESTED timestamp directly,
    # not just the overall latest-review state — a COMMENTED follow-up must
    # not paper over a retraction.
    LATEST_CR_APPROVED_AT=$(echo "$REVIEWS_JSON" | jq -r --arg sha "$HEAD_SHA" '
      [.[]?
        | select(.user.login == "coderabbitai[bot]" and .commit_id == $sha and .state == "APPROVED")
        | .submitted_at]
      | sort | last // ""')
    LATEST_CR_CHANGES_REQUESTED_AT=$(echo "$REVIEWS_JSON" | jq -r --arg sha "$HEAD_SHA" '
      [.[]?
        | select(.user.login == "coderabbitai[bot]" and .commit_id == $sha and .state == "CHANGES_REQUESTED")
        | .submitted_at]
      | sort | last // ""')
    APPROVED_CR_ON_HEAD=$(echo "$REVIEWS_JSON" | jq --arg sha "$HEAD_SHA" '
      [.[]? | select(.user.login == "coderabbitai[bot]" and .commit_id == $sha and .state == "APPROVED")]
      | length')
    TOTAL_CR_ON_HEAD=$(echo "$REVIEWS_JSON" | jq --arg sha "$HEAD_SHA" '
      [.[]? | select(.user.login == "coderabbitai[bot]" and .commit_id == $sha)]
      | length')

    if [[ "$APPROVED_CR_ON_HEAD" -lt 1 ]]; then
      MISSING+=("need 1 explicit CR APPROVED review on HEAD ${HEAD_SHA:0:7} (have 0 approved of $TOTAL_CR_ON_HEAD CR review(s) on this SHA)")
    elif [[ -n "$LATEST_CR_CHANGES_REQUESTED_AT" && "$LATEST_CR_CHANGES_REQUESTED_AT" > "$LATEST_CR_APPROVED_AT" ]]; then
      MISSING+=("CR approval on HEAD ${HEAD_SHA:0:7} retracted by later CHANGES_REQUESTED — fix and re-trigger")
    fi
    ;;

  bugbot)
    # Need at least 1 BugBot review on current HEAD, with no actionable findings.
    # Unresolved BugBot threads are caught by the universal unresolved-thread gate above.
    BB_REVIEWS_ON_HEAD=$(echo "$REVIEWS_JSON" | jq --arg sha "$HEAD_SHA" '
      [.[]? | select(.user.login == "cursor[bot]" and .commit_id == $sha)] | length')

    if [[ "$BB_REVIEWS_ON_HEAD" -lt 1 ]]; then
      MISSING+=("no BugBot review on HEAD ${HEAD_SHA:0:7}")
    else
      LATEST_BB=$(echo "$REVIEWS_JSON" | jq -c --arg sha "$HEAD_SHA" '
        [.[]? | select(.user.login == "cursor[bot]" and .commit_id == $sha)]
        | sort_by(.submitted_at) | last // empty')
      if [[ -n "$LATEST_BB" ]]; then
        BB_STATE=$(echo "$LATEST_BB" | jq -r '.state // ""')
        # Always check for inline findings — BugBot can post inline diff comments
        # without a review body, so gating on body length would miss them.
        INLINE_BB=$(echo "$PR_COMMENTS_JSON" | jq --arg sha "$HEAD_SHA" '
          [.[]? | select(.user.login == "cursor[bot]" and .commit_id == $sha)] | length')
        if [[ "$BB_STATE" == "CHANGES_REQUESTED" ]] || [[ "$INLINE_BB" -gt 0 ]]; then
          MISSING+=("latest BugBot review on HEAD has findings ($INLINE_BB inline)")
        fi
      fi
    fi
    ;;

  greptile)
    # Severity-gated. Greptile-specific count handling is intentionally NOT here —
    # the universal unresolved-thread gate above already reports the count for any
    # unresolved thread. This path adds severity context (P0 vs P1/P2) only.

    # Latest Greptile review.
    LATEST_G=$(echo "$REVIEWS_JSON" | jq -c '
      [.[]? | select(.user.login == "greptile-apps[bot]")]
      | sort_by(.submitted_at) | last // empty')

    if [[ -z "$LATEST_G" ]]; then
      MISSING+=("no Greptile review yet")
    else
      # Did the latest Greptile review include a P0 finding (in its body or its
      # inline comments)? Used for severity-gated logic below.
      G_BODY=$(echo "$LATEST_G" | jq -r '.body // ""')
      G_SUBMITTED=$(echo "$LATEST_G" | jq -r '.submitted_at // ""')
      G_INLINE_BODIES=$(echo "$PR_COMMENTS_JSON" | jq -r --arg ts "$G_SUBMITTED" '
        [.[]? | select(.user.login == "greptile-apps[bot]" and .created_at >= $ts) | .body] | join("\n---\n")')
      P0_COUNT=$( { echo "$G_BODY"; echo "$G_INLINE_BODIES"; } | grep -oE '\bP0\b' | wc -l | tr -d ' ')

      # Are there unresolved Greptile-authored threads? If so, P0 vs P1/P2 changes
      # whether a re-review is required after fixing.
      UNRESOLVED_G=$(echo "$THREADS_JSON" | jq -r '
        [.data.repository.pullRequest.reviewThreads.nodes[]?
          | select(.isResolved == false)
          | select(any(.comments.nodes[]?; .author.login == "greptile-apps[bot]"))]
        | length')

      if [[ "$UNRESOLVED_G" -gt 0 && "$P0_COUNT" -gt 0 ]]; then
        # Universal gate already reports the count; add severity-aware advice only.
        MISSING+=("Greptile threads include P0 finding(s) — need clean re-review after fix")
      elif [[ "$UNRESOLVED_G" -eq 0 && "$P0_COUNT" -gt 0 ]]; then
        # Threads are resolved but the latest (most recent) Greptile review had P0.
        # Since LATEST_G is already the last review by submitted_at, a clean re-review
        # would BE the latest review and wouldn't have P0. So if we're here, no clean
        # re-review exists yet — always require one.
        MISSING+=("latest Greptile review had P0 findings — need clean re-review after fix (trigger @greptileai)")
      fi
      # No unresolved threads + no P0 in latest review → gate is met.
    fi
    ;;
esac

# --------------------------------------------------------------------------
# Emit result
# --------------------------------------------------------------------------
if [[ "${#MISSING[@]}" -eq 0 ]]; then
  MET=true
else
  MET=false
fi

MISSING_JSON=$(printf '%s\n' "${MISSING[@]:-}" | jq -R . | jq -cs 'map(select(length > 0))')

emit_json "$MET" "$REVIEWER" "$REVIEWER" "$MISSING_JSON" "$HEAD_SHA" "$CI_STATUS" "$MERGE_STATE"

if [[ "$MET" == true ]]; then
  exit 0
else
  exit 1
fi
