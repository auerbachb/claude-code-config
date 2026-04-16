#!/usr/bin/env bash
# resolve-review-threads.sh — Resolve unresolved PR review threads from bot reviewers.
#
# Fetches all review threads on the given PR via GraphQL, filters to unresolved
# threads whose first-comment author matches --authors, and resolves each via
# resolveReviewThread. On failure, falls back to minimizeComment(classifier: RESOLVED).
#
# Usage:
#   resolve-review-threads.sh <pr_number> [--authors coderabbitai,cursor,greptile-apps] [--dry-run]
#   resolve-review-threads.sh --help
#
# Flags:
#   --authors  Comma-separated list of GitHub logins (without [bot] suffix) whose
#              threads are eligible for resolution. Default:
#              coderabbitai,cursor,greptile-apps
#   --dry-run  Print thread IDs that would be resolved and exit 0 without mutating.
#
# Exit codes:
#   0  All matching threads resolved (or dry-run OK)
#   1  At least one thread failed BOTH mutations (resolveReviewThread + minimizeComment)
#   2  Usage error
#   3  PR not found
#   4  gh / network error
#
# See .claude/rules/cr-github-review.md "Processing CR Feedback" step 4.

set -euo pipefail

AUTHORS="coderabbitai,cursor,greptile-apps"
DRY_RUN=0
PR_NUMBER=""

print_help() {
  awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --authors)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --authors requires a value" >&2
        exit 2
      fi
      AUTHORS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --*)
      echo "ERROR: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$PR_NUMBER" ]]; then
        echo "ERROR: unexpected argument: $1" >&2
        exit 2
      fi
      PR_NUMBER="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUMBER" ]]; then
  echo "ERROR: <pr_number> is required" >&2
  echo "Usage: $(basename "$0") <pr_number> [--authors a,b,c] [--dry-run]" >&2
  exit 2
fi

if [[ ! "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: <pr_number> must be a positive integer (got: $PR_NUMBER)" >&2
  exit 2
fi

# Build a jq-compatible regex from the author list: ^(a|b|c)$
IFS=',' read -ra _author_arr <<< "$AUTHORS"
if [[ ${#_author_arr[@]} -eq 0 ]]; then
  echo "ERROR: --authors must contain at least one login" >&2
  exit 2
fi
# Escape jq regex metacharacters in each author token.
_author_regex=""
for _a in "${_author_arr[@]}"; do
  _a_trimmed="${_a// /}"
  if [[ -z "$_a_trimmed" ]]; then continue; fi
  # Escape characters meaningful in jq regex (PCRE subset): . * + ? ^ $ | \ [ ] ( ) { }
  _a_escaped=$(printf '%s' "$_a_trimmed" | sed 's/[.+*?^$|\\[\](){}]/\\&/g')
  if [[ -z "$_author_regex" ]]; then
    _author_regex="$_a_escaped"
  else
    _author_regex="$_author_regex|$_a_escaped"
  fi
done
if [[ -z "$_author_regex" ]]; then
  echo "ERROR: --authors list was empty after parsing" >&2
  exit 2
fi
AUTHOR_REGEX="^($_author_regex)$"

# ----------------------------------------------------------------------
# Resolve owner/repo from the current checkout.
# ----------------------------------------------------------------------
if ! REPO_JSON=$(gh repo view --json owner,name 2>&1); then
  echo "ERROR: gh repo view failed: $REPO_JSON" >&2
  exit 4
fi
OWNER=$(printf '%s' "$REPO_JSON" | jq -r '.owner.login')
REPO=$(printf '%s' "$REPO_JSON" | jq -r '.name')
if [[ -z "$OWNER" || -z "$REPO" || "$OWNER" == "null" || "$REPO" == "null" ]]; then
  echo "ERROR: could not determine owner/repo from current checkout" >&2
  exit 4
fi

# ----------------------------------------------------------------------
# Fetch review threads. Paginate via endCursor in case a PR has >100 threads.
# ----------------------------------------------------------------------
collect_threads() {
  local cursor="null"
  local all='[]'
  while :; do
    local after_arg=""
    if [[ "$cursor" != "null" ]]; then
      after_arg=", after: \"$cursor\""
    fi
    local query
    query="query {
      repository(owner: \"$OWNER\", name: \"$REPO\") {
        pullRequest(number: $PR_NUMBER) {
          reviewThreads(first: 100${after_arg}) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              isResolved
              comments(first: 1) {
                nodes {
                  id
                  author { login }
                }
              }
            }
          }
        }
      }
    }"
    local resp
    if ! resp=$(gh api graphql -f query="$query" 2>&1); then
      if printf '%s' "$resp" | grep -qi "could not resolve to a pullrequest\|not found"; then
        echo "ERROR: PR #$PR_NUMBER not found in $OWNER/$REPO" >&2
        exit 3
      fi
      echo "ERROR: gh api graphql failed: $resp" >&2
      exit 4
    fi

    # Guard: if pullRequest is null, the PR was not found.
    local pr_present
    pr_present=$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest // empty')
    if [[ -z "$pr_present" ]]; then
      echo "ERROR: PR #$PR_NUMBER not found in $OWNER/$REPO" >&2
      exit 3
    fi

    local page_nodes
    page_nodes=$(printf '%s' "$resp" | jq '.data.repository.pullRequest.reviewThreads.nodes')
    all=$(jq -n --argjson a "$all" --argjson b "$page_nodes" '$a + $b')

    local has_next
    has_next=$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
    if [[ "$has_next" != "true" ]]; then
      break
    fi
    cursor=$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
  done
  printf '%s' "$all"
}

ALL_THREADS=$(collect_threads)

# Filter to unresolved threads whose first-comment author matches the regex.
# Emit tab-separated: <thread_id>\t<first_comment_node_id>\t<author>
# Use a temp file instead of mapfile (unavailable in macOS bash 3.2).
MATCHES_FILE=$(mktemp -t resolve-threads.XXXXXX)
trap 'rm -f "$MATCHES_FILE"' EXIT

printf '%s' "$ALL_THREADS" \
  | jq -r --arg re "$AUTHOR_REGEX" '
      .[]
      | select(.isResolved == false)
      | select((.comments.nodes[0].author.login // "") | test($re))
      | [.id, (.comments.nodes[0].id // ""), (.comments.nodes[0].author.login // "")]
      | @tsv
    ' > "$MATCHES_FILE"

MATCH_COUNT=$(wc -l < "$MATCHES_FILE" | tr -d ' ')

if [[ "$MATCH_COUNT" -eq 0 ]]; then
  echo "No unresolved threads matching authors: $AUTHORS"
  exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] $MATCH_COUNT thread(s) would be resolved:"
  while IFS=$'\t' read -r tid _cid author; do
    [[ -z "$tid" ]] && continue
    echo "  $tid  ($author)"
  done < "$MATCHES_FILE"
  exit 0
fi

FAILURES=0
while IFS=$'\t' read -r THREAD_ID COMMENT_ID AUTHOR; do
  [[ -z "$THREAD_ID" ]] && continue

  # Primary: resolveReviewThread
  if resp=$(gh api graphql -F threadId="$THREAD_ID" -f query='
    mutation($threadId: ID!) {
      resolveReviewThread(input: {threadId: $threadId}) { thread { isResolved } }
    }' 2>&1); then
    echo "[RESOLVED] $THREAD_ID  ($AUTHOR)"
    continue
  fi

  # Fallback: minimizeComment on the first comment's node id.
  if [[ -n "$COMMENT_ID" ]]; then
    if resp2=$(gh api graphql -F subjectId="$COMMENT_ID" -f query='
      mutation($subjectId: ID!) {
        minimizeComment(input: {subjectId: $subjectId, classifier: RESOLVED}) { minimizedComment { isMinimized } }
      }' 2>&1); then
      echo "[MINIMIZED] $THREAD_ID  ($AUTHOR) — resolveReviewThread failed, minimizeComment succeeded"
      continue
    fi
    echo "[FAILED] $THREAD_ID  ($AUTHOR) — resolveReviewThread: $resp | minimizeComment: $resp2" >&2
  else
    echo "[FAILED] $THREAD_ID  ($AUTHOR) — resolveReviewThread: $resp | no comment node id for fallback" >&2
  fi
  FAILURES=$((FAILURES + 1))
done < "$MATCHES_FILE"

if [[ "$FAILURES" -gt 0 ]]; then
  echo "ERROR: $FAILURES thread(s) could not be resolved" >&2
  exit 1
fi

exit 0
