#!/usr/bin/env bash
# resolve-review-threads.sh — Resolve unresolved PR review threads from bot reviewers.
#
# Fetches all review threads on the given PR via GraphQL, filters to unresolved
# threads whose first-comment author matches --authors, and resolves each via
# resolveReviewThread. On failure, falls back to minimizeComment(classifier: RESOLVED).
#
# Usage:
#   resolve-review-threads.sh <pr_number> [--authors coderabbitai,cursor,greptile-apps,graphite-app,codeant-ai] [--thread-ids id1,id2 | --thread-ids-file path] [--max-attempts 2] [--dry-run]
#   resolve-review-threads.sh <pr_number> --thread-ids-file path --verify-only
#   resolve-review-threads.sh --help
#
# Flags:
#   --authors  Comma-separated list of GitHub logins (without [bot] suffix) whose
#              threads are eligible for resolution. Default:
#              coderabbitai,cursor,greptile-apps,graphite-app,codeant-ai
#   --thread-ids
#              Comma-separated GraphQL review thread node IDs that must be verified
#              resolved after mutation attempts. When provided, these explicit IDs
#              are authoritative and are not filtered by --authors.
#   --thread-ids-file
#              File containing GraphQL review thread node IDs, one per line or
#              comma-separated. Same verification behavior as --thread-ids.
#   --max-attempts
#              Number of resolve/minimize passes before final verification. Default: 2
#   --dry-run  Print thread IDs that would be resolved and exit 0 without mutating.
#   --verify-only
#              Re-fetch threads via GraphQL and verify every ID in --thread-ids /
#              --thread-ids-file reports isResolved=true. Does not mutate. Requires
#              explicit thread IDs. An empty id file is a valid no-op (prints
#              addressed=0 and exits 0). Exit 1 if any expected ID is missing or unresolved.
#
# Exit codes:
#   0  All addressed/matching threads verified resolved (or dry-run OK)
#   1  At least one thread is still dangling after retry/fallback verification
#   2  Usage error
#   3  PR not found
#   4  gh / network error
#
# See .claude/rules/cr-github-review.md "Processing CR Feedback" step 4.

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log"

AUTHORS="coderabbitai,cursor,greptile-apps,graphite-app,codeant-ai"
DRY_RUN=0
VERIFY_ONLY=0
THREAD_IDS=""
THREAD_IDS_FILE=""
EXPLICIT_IDS_MODE=0
MAX_ATTEMPTS=2
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
    --thread-ids)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --thread-ids requires a value" >&2
        exit 2
      fi
      THREAD_IDS="$2"
      EXPLICIT_IDS_MODE=1
      shift 2
      ;;
    --thread-ids-file)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --thread-ids-file requires a value" >&2
        exit 2
      fi
      THREAD_IDS_FILE="$2"
      EXPLICIT_IDS_MODE=1
      shift 2
      ;;
    --max-attempts)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --max-attempts requires a value" >&2
        exit 2
      fi
      MAX_ATTEMPTS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --verify-only)
      VERIFY_ONLY=1
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

if [[ -n "$THREAD_IDS" && -n "$THREAD_IDS_FILE" ]]; then
  echo "ERROR: use only one of --thread-ids or --thread-ids-file" >&2
  exit 2
fi

if [[ "$VERIFY_ONLY" -eq 1 ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "ERROR: --verify-only cannot be combined with --dry-run" >&2
    exit 2
  fi
  if [[ "$EXPLICIT_IDS_MODE" -ne 1 ]]; then
    echo "ERROR: --verify-only requires --thread-ids or --thread-ids-file" >&2
    exit 2
  fi
fi

if [[ ! "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --max-attempts must be a positive integer (got: $MAX_ATTEMPTS)" >&2
  exit 2
fi

if [[ -n "$THREAD_IDS_FILE" && ! -f "$THREAD_IDS_FILE" ]]; then
  echo "ERROR: --thread-ids-file does not exist: $THREAD_IDS_FILE" >&2
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
                  url
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
      if printf '%s' "$resp" | grep -qi "could not resolve to a pullrequest"; then
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

MATCHES_FILE=$(mktemp -t resolve-threads.XXXXXX)
EXPECTED_FILE=$(mktemp -t resolve-expected.XXXXXX)
DANGLING_FILE=$(mktemp -t resolve-dangling.XXXXXX)
trap 'rm -f "$MATCHES_FILE" "$EXPECTED_FILE" "$DANGLING_FILE"' EXIT

append_thread_ids() {
  local raw="$1"
  printf '%s\n' "$raw" | tr ',' '\n' | while IFS= read -r id; do
    id="${id//[[:space:]]/}"
    [[ -n "$id" ]] && printf '%s\n' "$id" || true
  done
}

if [[ -n "$THREAD_IDS" ]]; then
  append_thread_ids "$THREAD_IDS" > "$EXPECTED_FILE"
elif [[ -n "$THREAD_IDS_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    append_thread_ids "$line"
  done < "$THREAD_IDS_FILE" > "$EXPECTED_FILE"
fi

if [[ -s "$EXPECTED_FILE" ]]; then
  sort -u "$EXPECTED_FILE" -o "$EXPECTED_FILE"
fi

expected_json() {
  jq -R -s 'split("\n") | map(select(length > 0))' "$EXPECTED_FILE"
}

write_unresolved_matches() {
  local threads_json="$1"
  if [[ -s "$EXPECTED_FILE" ]]; then
    local expected
    expected=$(expected_json)
    printf '%s' "$threads_json" \
      | jq -r --argjson expected "$expected" '
          .[]
          | select(.id as $id | $expected | index($id))
          | select(.isResolved == false)
          | [.id, (.comments.nodes[0].id // ""), (.comments.nodes[0].author.login // ""), (.comments.nodes[0].url // "")]
          | @tsv
        ' > "$MATCHES_FILE"
  elif [[ "$EXPLICIT_IDS_MODE" -eq 1 ]]; then
    # IDs were requested but all parsed to empty — resolve nothing rather than
    # silently falling back to author mode and resolving unrelated threads.
    : > "$MATCHES_FILE"
  else
    printf '%s' "$threads_json" \
      | jq -r --arg re "$AUTHOR_REGEX" '
          .[]
          | select(.isResolved == false)
          | select((.comments.nodes[0].author.login // "") | test($re))
          | [.id, (.comments.nodes[0].id // ""), (.comments.nodes[0].author.login // ""), (.comments.nodes[0].url // "")]
          | @tsv
        ' > "$MATCHES_FILE"
  fi
}

write_dangling_threads() {
  local threads_json="$1"
  if [[ -s "$EXPECTED_FILE" ]]; then
    local expected
    expected=$(expected_json)
    printf '%s' "$threads_json" \
      | jq -r --argjson expected "$expected" '
          def row($id; $comment_id; $author; $url; $reason):
            [$id, $comment_id, $author, $url, $reason] | @tsv;
          ([.[] | {key: .id, value: .}] | from_entries) as $by_id
          | $expected[]
          | . as $id
          | ($by_id[$id] // null) as $thread
          | if $thread == null then
              row($id; ""; ""; ""; "thread not returned by GraphQL")
            elif $thread.isResolved == false then
              row($id; ($thread.comments.nodes[0].id // ""); ($thread.comments.nodes[0].author.login // ""); ($thread.comments.nodes[0].url // ""); "isResolved=false")
            else empty
            end
        ' > "$DANGLING_FILE"
  fi
}

# ----------------------------------------------------------------------
# --verify-only: no mutations; confirm every expected thread id is resolved.
# ----------------------------------------------------------------------
if [[ "$VERIFY_ONLY" -eq 1 ]]; then
  if [[ ! -s "$EXPECTED_FILE" ]]; then
    # CI-only / no-thread runs: empty explicit set means nothing to verify (not an error).
    echo "[VERIFY] addressed=0 resolved=0 dangling=0"
    exit 0
  fi
  ADDRESSED_COUNT=$(wc -l < "$EXPECTED_FILE" | tr -d ' ')
  VERIFY_THREADS=$(collect_threads)
  write_dangling_threads "$VERIFY_THREADS"
  DANGLING_COUNT=$(wc -l < "$DANGLING_FILE" | tr -d ' ')
  RESOLVED_COUNT=$((ADDRESSED_COUNT - DANGLING_COUNT))
  if [[ "$RESOLVED_COUNT" -lt 0 ]]; then
    RESOLVED_COUNT=0
  fi
  echo "[VERIFY] addressed=$ADDRESSED_COUNT resolved=$RESOLVED_COUNT dangling=$DANGLING_COUNT"
  if [[ "$DANGLING_COUNT" -gt 0 ]]; then
    while IFS=$'\t' read -r THREAD_ID _COMMENT_ID AUTHOR URL REASON; do
      [[ -z "$THREAD_ID" ]] && continue
      if [[ -n "$URL" ]]; then
        echo "[STUCK] $THREAD_ID  ($AUTHOR) — $REASON — $URL" >&2
      else
        echo "[STUCK] $THREAD_ID  ($AUTHOR) — $REASON" >&2
      fi
    done < "$DANGLING_FILE"
    echo "ERROR: $DANGLING_COUNT thread(s) not verified resolved" >&2
    exit 1
  fi
  exit 0
fi

resolve_or_minimize() {
  local thread_id="$1"
  local comment_id="$2"
  local author="$3"
  local attempt="$4"
  local resp resp2

  if resp=$(gh api graphql -F threadId="$thread_id" -f query='
    mutation($threadId: ID!) {
      resolveReviewThread(input: {threadId: $threadId}) { thread { isResolved } }
    }' 2>&1); then
    echo "[RESOLVED] attempt=$attempt $thread_id  ($author)"
    return 0
  fi

  if [[ -n "$comment_id" ]]; then
    if resp2=$(gh api graphql -F subjectId="$comment_id" -f query='
      mutation($subjectId: ID!) {
        minimizeComment(input: {subjectId: $subjectId, classifier: RESOLVED}) { minimizedComment { isMinimized } }
      }' 2>&1); then
      echo "[MINIMIZED] attempt=$attempt $thread_id  ($author) — resolveReviewThread failed, minimizeComment fallback succeeded"
      return 0
    fi
    echo "[FAILED] attempt=$attempt $thread_id  ($author) — resolveReviewThread: $resp | minimizeComment: $resp2" >&2
    return 1
  fi

  echo "[FAILED] attempt=$attempt $thread_id  ($author) — resolveReviewThread: $resp | no comment node id for fallback" >&2
  return 1
}

ALL_THREADS=$(collect_threads)
write_unresolved_matches "$ALL_THREADS"

if [[ -s "$EXPECTED_FILE" ]]; then
  ADDRESSED_COUNT=$(wc -l < "$EXPECTED_FILE" | tr -d ' ')
else
  ADDRESSED_COUNT=$(wc -l < "$MATCHES_FILE" | tr -d ' ')
  cut -f1 "$MATCHES_FILE" > "$EXPECTED_FILE"
fi

MATCH_COUNT=$(wc -l < "$MATCHES_FILE" | tr -d ' ')

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$MATCH_COUNT" -eq 0 ]]; then
    echo "[DRY-RUN] no unresolved addressed/matching threads"
  else
    echo "[DRY-RUN] $MATCH_COUNT thread(s) would be resolved:"
    while IFS=$'\t' read -r tid _cid author url; do
      [[ -z "$tid" ]] && continue
      echo "  $tid  ($author) ${url}"
    done < "$MATCHES_FILE"
  fi
  exit 0
fi

if [[ "$ADDRESSED_COUNT" -eq 0 ]]; then
  if [[ -n "$THREAD_IDS" || -n "$THREAD_IDS_FILE" ]]; then
    echo "No unresolved threads in the provided thread-ids set"
  else
    echo "No unresolved threads matching authors: $AUTHORS"
  fi
  exit 0
fi

attempt=1
while [[ "$attempt" -le "$MAX_ATTEMPTS" ]]; do
  write_unresolved_matches "$ALL_THREADS"
  MATCH_COUNT=$(wc -l < "$MATCHES_FILE" | tr -d ' ')
  [[ "$MATCH_COUNT" -gt 0 ]] || break

  while IFS=$'\t' read -r THREAD_ID COMMENT_ID AUTHOR _URL; do
    [[ -z "$THREAD_ID" ]] && continue
    resolve_or_minimize "$THREAD_ID" "$COMMENT_ID" "$AUTHOR" "$attempt" || true
  done < "$MATCHES_FILE"

  ALL_THREADS=$(collect_threads)
  attempt=$((attempt + 1))
done

VERIFY_THREADS=$(collect_threads)
write_dangling_threads "$VERIFY_THREADS"
DANGLING_COUNT=$(wc -l < "$DANGLING_FILE" | tr -d ' ')
RESOLVED_COUNT=$((ADDRESSED_COUNT - DANGLING_COUNT))
if [[ "$RESOLVED_COUNT" -lt 0 ]]; then
  RESOLVED_COUNT=0
fi

echo "[VERIFY] addressed=$ADDRESSED_COUNT resolved=$RESOLVED_COUNT dangling=$DANGLING_COUNT"

if [[ "$DANGLING_COUNT" -gt 0 ]]; then
  while IFS=$'\t' read -r THREAD_ID _COMMENT_ID AUTHOR URL REASON; do
    [[ -z "$THREAD_ID" ]] && continue
    if [[ -n "$URL" ]]; then
      echo "[STUCK] $THREAD_ID  ($AUTHOR) — $REASON — $URL" >&2
    else
      echo "[STUCK] $THREAD_ID  ($AUTHOR) — $REASON" >&2
    fi
  done < "$DANGLING_FILE"
  echo "ERROR: $DANGLING_COUNT thread(s) remain dangling after retry/fallback verification" >&2
  exit 1
fi

exit 0
