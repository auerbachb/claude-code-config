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
#   3. Fetch commits, sorted by committer date.
#   4. For each review i, count one cycle iff there exists a commit c with
#      reviews[i].submitted_at < c.date < boundary, where boundary is
#      reviews[i+1].submitted_at or mergedAt (or now for open PRs).

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

if ! [[ "$PR_NUM" =~ ^[0-9]+$ ]]; then
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
cleanup() {
  rm -f "$PR_META_STDERR" "$REVIEWS_RAW" "$COMMITS_RAW" 2>/dev/null || true
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
if ! gh api "repos/{owner}/{repo}/pulls/$PR_NUM/reviews?per_page=100" --paginate >"$REVIEWS_RAW" 2>/dev/null; then
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

# --- fetch commits ---
COMMITS_RAW="$(mktemp)"
if ! gh api "repos/{owner}/{repo}/pulls/$PR_NUM/commits?per_page=100" --paginate >"$COMMITS_RAW" 2>/dev/null; then
  echo "Error: gh api failed fetching commits for PR #$PR_NUM" >&2
  exit 4
fi

COMMITS_JSON="$(jq -s '
  [.[][] | {sha: .sha, date: .commit.committer.date}]
  | sort_by(.date)
' "$COMMITS_RAW" 2>/dev/null)" || {
  echo "Error: jq failed parsing commits for PR #$PR_NUM" >&2
  exit 4
}

# --- compute cycle count ---
# For each review, check whether at least one commit lies strictly between
# review.submitted_at and the next boundary (next review, else END_BOUNDARY).
CYCLE_COUNT="$(jq -n \
  --argjson reviews "$REVIEWS_JSON" \
  --argjson commits "$COMMITS_JSON" \
  --arg end "$END_BOUNDARY" '
  ($reviews | length) as $n
  | [range(0; $n) as $i
     | $reviews[$i].submitted_at as $rt
     | (if $i + 1 < $n then $reviews[$i+1].submitted_at else $end end) as $next
     | ($commits | any(.date > $rt and .date < $next))
     | select(.)]
  | length
')" || {
  echo "Error: jq failed computing cycle count for PR #$PR_NUM" >&2
  exit 4
}

printf '%s\n' "$CYCLE_COUNT"
