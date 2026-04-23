#!/usr/bin/env bash
# cycle-count.sh — Reconstruct review-then-fix cycle count for a PR.
#
# A "cycle" is one review followed by at least one commit before the next
# review (or before merge for the final review). Reviews with no subsequent
# commits are non-actionable and do not count. Clean passes and confirmation
# reviews therefore do not count.
#
# USAGE:
#   cycle-count.sh <pr_number> [--exclude-bots]
#   cycle-count.sh --help | -h
#
# OUTPUT:
#   Integer cycle count on stdout.
#
# FLAGS:
#   --exclude-bots    Filter out reviews whose user.login ends in "[bot]"
#                     or equals "github-actions". Matches the bot filter in
#                     .claude/reference/pm-data-patterns.md. Use this for
#                     human-review metrics (e.g., PM reports). Omit to count
#                     all reviews including bots (e.g., /merge, /wrap logging).
#
# EXIT CODES:
#   0    OK (count printed on stdout)
#   2    Usage error (missing/invalid args)
#   3    PR not found
#   4    gh / GitHub API error (including jq failure, network error)
#
# DEPENDENCIES:
#   - gh (authenticated)
#   - jq
#
# ALGORITHM:
#   1. Fetch PR metadata (mergedAt). If open, treat "now" as the end boundary.
#   2. Fetch reviews (optionally bot-filtered), sorted by submitted_at.
#   3. Fetch inline comments to identify actionable reviews (those with at least
#      one inline comment).
#   4. Annotate each review with an `actionable` flag: true when
#      state == "CHANGES_REQUESTED" OR the review has at least one inline
#      comment attached.
#   5. Fetch commits, sorted by committer date.
#   6. Walk reviews in chronological order. At each position, the boundary is
#      the next review's submitted_at (actionable or not — every review serves
#      as a boundary). Count the position only if its own review is actionable
#      and there exists a commit c with
#      reviews[i].submitted_at < c.date < boundary, where boundary is
#      reviews[i+1].submitted_at or mergedAt (or now for open PRs).
#      Non-actionable reviews (approvals with no findings, bare COMMENTED
#      reviews with no inline comments) are NOT counted themselves but DO
#      serve as boundaries for earlier actionable reviews, preventing
#      over-counting when a commit is triggered by feedback that arrives
#      after an actionable review but before a later non-actionable one.

set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage: cycle-count.sh <pr_number> [--exclude-bots]
       cycle-count.sh --help | -h

Reconstruct the review-then-fix cycle count for a PR and print it to stdout.

Options:
  --exclude-bots    Exclude bot reviewers (logins ending in "[bot]" or
                    equal to "github-actions"). Default: include all reviews.
  -h, --help        Print this usage message.

Exit codes:
  0  OK (count on stdout)
  2  usage error
  3  PR not found
  4  gh / GitHub API error
EOF
}

# --- arg parsing ---
PR_NUM=""
EXCLUDE_BOTS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    --exclude-bots)
      EXCLUDE_BOTS=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Error: unknown flag: $1" >&2
      print_usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$PR_NUM" ]]; then
        echo "Error: unexpected positional argument: $1" >&2
        print_usage >&2
        exit 2
      fi
      PR_NUM="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUM" ]]; then
  echo "Error: <pr_number> is required" >&2
  print_usage >&2
  exit 2
fi

if ! [[ "$PR_NUM" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: <pr_number> must be a positive integer, got: $PR_NUM" >&2
  exit 2
fi

# --- dependency check ---
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: 'gh' CLI not found on PATH" >&2
  exit 4
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: 'jq' not found on PATH" >&2
  exit 4
fi

# --- fetch PR metadata ---
# gh pr view returns exit 1 when the PR is not found. We distinguish "not found"
# (exit 3) from generic gh errors (exit 4) by inspecting stderr.
PR_META_STDERR="$(mktemp)"
REVIEWS_RAW=""
COMMITS_RAW=""
INLINE_RAW=""
GH_CALL_STDERR="$(mktemp)"
cleanup() {
  rm -f "$PR_META_STDERR" "$GH_CALL_STDERR" 2>/dev/null || true
  [[ -n "$REVIEWS_RAW" ]] && rm -f "$REVIEWS_RAW" 2>/dev/null
  [[ -n "$COMMITS_RAW" ]] && rm -f "$COMMITS_RAW" 2>/dev/null
  [[ -n "$INLINE_RAW" ]]  && rm -f "$INLINE_RAW"  2>/dev/null
  return 0  # never propagate cleanup failures to the script's exit code
}
trap cleanup EXIT

if ! PR_META="$(gh pr view "$PR_NUM" --json mergedAt,state 2>"$PR_META_STDERR")"; then
  if grep -qiE 'not.?found|could not resolve|no pull requests? found' "$PR_META_STDERR"; then
    echo "Error: PR #$PR_NUM not found" >&2
    exit 3
  fi
  sed 's/^/gh: /' "$PR_META_STDERR" >&2
  echo "Error: gh pr view failed for PR #$PR_NUM" >&2
  exit 4
fi

MERGED_AT="$(printf '%s' "$PR_META" | jq -r '.mergedAt // empty')"
# Boundary for the final review: mergedAt if merged, else "now" in ISO 8601 UTC.
if [[ -n "$MERGED_AT" && "$MERGED_AT" != "null" ]]; then
  END_BOUNDARY="$MERGED_AT"
else
  END_BOUNDARY="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
fi

# --- fetch reviews ---
REVIEWS_RAW="$(mktemp)"
if ! gh api "repos/{owner}/{repo}/pulls/$PR_NUM/reviews?per_page=100" --paginate >"$REVIEWS_RAW" 2>"$GH_CALL_STDERR"; then
  sed 's/^/gh: /' "$GH_CALL_STDERR" >&2
  echo "Error: gh api failed fetching reviews for PR #$PR_NUM" >&2
  exit 4
fi

# `gh api --paginate` concatenates JSON arrays with no separator; the first
# `jq -s` flattens them into a single array.
if (( EXCLUDE_BOTS )); then
  REVIEWS_JSON="$(jq -s '
    [.[][] | select(.submitted_at != null)
           | select(.user.login | (endswith("[bot]") or . == "github-actions") | not)]
    | sort_by(.submitted_at)
  ' "$REVIEWS_RAW" 2>/dev/null)" || {
    echo "Error: jq failed parsing reviews for PR #$PR_NUM" >&2
    exit 4
  }
else
  REVIEWS_JSON="$(jq -s '
    [.[][] | select(.submitted_at != null)]
    | sort_by(.submitted_at)
  ' "$REVIEWS_RAW" 2>/dev/null)" || {
    echo "Error: jq failed parsing reviews for PR #$PR_NUM" >&2
    exit 4
  }
fi

# --- fetch inline comments (for actionable-review detection) ---
# A review is "actionable" if it requests changes or has at least one inline
# comment. We fetch the PR's inline comments and extract the set of review IDs
# they belong to.
INLINE_RAW="$(mktemp)"
if ! gh api "repos/{owner}/{repo}/pulls/$PR_NUM/comments?per_page=100" --paginate >"$INLINE_RAW" 2>"$GH_CALL_STDERR"; then
  sed 's/^/gh: /' "$GH_CALL_STDERR" >&2
  echo "Error: gh api failed fetching inline comments for PR #$PR_NUM" >&2
  exit 4
fi

ACTIONABLE_REVIEW_IDS="$(jq -s '
  [.[][] | .pull_request_review_id | select(. != null)] | unique
' "$INLINE_RAW" 2>/dev/null)" || {
  echo "Error: jq failed parsing inline comments for PR #$PR_NUM" >&2
  exit 4
}

# --- annotate reviews with actionable flag ---
# Keep the full chronological review stream — every review (actionable or not)
# still serves as a boundary for earlier reviews. Only the "actionable" flag
# decides whether a given review is *counted*.
# A review is actionable when state == "CHANGES_REQUESTED" OR its id appears in
# ACTIONABLE_REVIEW_IDS (i.e., it has at least one inline comment).
# Also attach an epoch value so cycle-count comparisons are timezone-safe.
# GitHub returns most timestamps as ISO 8601 UTC ("...Z"), but commit
# committer.date can use "+HH:MM" offsets, which would sort incorrectly as
# raw strings. fromdateiso8601 normalizes everything to epoch seconds.
REVIEWS_WITH_ACTIONABLE_JSON="$(jq -n \
  --argjson reviews "$REVIEWS_JSON" \
  --argjson actionable_ids "$ACTIONABLE_REVIEW_IDS" '
  [$reviews[] | . + {
    submitted_at_epoch: (.submitted_at | fromdateiso8601),
    actionable: (
      .state == "CHANGES_REQUESTED"
      or (.id as $rid | ($actionable_ids | index($rid) != null))
    )
  }]
')" || {
  echo "Error: jq failed annotating reviews for PR #$PR_NUM" >&2
  exit 4
}

# --- fetch commits ---
COMMITS_RAW="$(mktemp)"
if ! gh api "repos/{owner}/{repo}/pulls/$PR_NUM/commits?per_page=100" --paginate >"$COMMITS_RAW" 2>"$GH_CALL_STDERR"; then
  sed 's/^/gh: /' "$GH_CALL_STDERR" >&2
  echo "Error: gh api failed fetching commits for PR #$PR_NUM" >&2
  exit 4
fi

COMMITS_JSON="$(jq -s '
  [.[][] | {
    sha: .sha,
    date: .commit.committer.date,
    date_epoch: (.commit.committer.date | fromdateiso8601)
  }]
  | sort_by(.date_epoch)
' "$COMMITS_RAW" 2>/dev/null)" || {
  echo "Error: jq failed parsing commits for PR #$PR_NUM" >&2
  exit 4
}

# --- compute cycle count ---
# For each review position, take the next review's submitted_at (regardless of
# whether that next review is actionable) as the boundary. Count this position
# only if the review at this position is actionable. This way non-actionable
# reviews correctly serve as boundaries for earlier actionable reviews, but
# they themselves do not contribute to the count.
# All comparisons use epoch seconds so mixed-timezone timestamps sort correctly.
CYCLE_COUNT="$(jq -n \
  --argjson reviews "$REVIEWS_WITH_ACTIONABLE_JSON" \
  --argjson commits "$COMMITS_JSON" \
  --arg end "$END_BOUNDARY" '
  ($end | fromdateiso8601) as $end_epoch
  | ($reviews | length) as $n
  | [range(0; $n) as $i
     | select($reviews[$i].actionable)
     | $reviews[$i].submitted_at_epoch as $rt
     | (if $i + 1 < $n then $reviews[$i+1].submitted_at_epoch else $end_epoch end) as $next
     | ($commits | any(.date_epoch > $rt and .date_epoch < $next))
     | select(.)]
  | length
')" || {
  echo "Error: jq failed computing cycle count for PR #$PR_NUM" >&2
  exit 4
}

printf '%s\n' "$CYCLE_COUNT"
