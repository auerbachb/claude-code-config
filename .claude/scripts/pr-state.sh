#!/usr/bin/env bash
# pr-state.sh — Gather all PR state into a single JSON file.
#
# Shared helper used by /fixpr, /merge, /wrap, /continue, /status, phase-b-reviewer,
# and phase-c-merger. Collapses the 3-endpoint comment scan + GraphQL review threads
# + check-runs + commit statuses into one JSON bundle. Call sites read the bundle
# via jq instead of re-issuing overlapping gh api calls inline.
#
# Usage:
#   pr-state.sh                          # Auto-detect PR from current branch
#   pr-state.sh --pr 123                 # Use explicit PR number (skips branch detect)
#   pr-state.sh --since <iso-8601>       # Pre-classify bot comments posted since baseline
#   pr-state.sh --pr 123 --since <iso>   # Combined
#   pr-state.sh --help                   # Print usage
#
# Output: writes JSON to /tmp/pr-state-<PR>-<epoch>.json and prints the path on stdout.
#
# Exit codes:
#   0  OK
#   2  usage error (unknown flag, --since missing value)
#   3  no git branch AND no --pr given
#   4  PR closed, merged, or not found
#   5  gh/network error

set -euo pipefail

PR_ARG=""
SINCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)
      PR_ARG="${2:-}"
      if [[ -z "$PR_ARG" ]]; then
        echo "ERROR: --pr requires a PR number" >&2
        exit 2
      fi
      # Catch the case where the next arg is another flag (user forgot the value).
      # The integer check below would also catch this, but this error is clearer.
      if [[ "$PR_ARG" == -* ]]; then
        echo "ERROR: --pr requires a PR number; got flag '$PR_ARG'" >&2
        exit 2
      fi
      shift 2
      ;;
    --since)
      SINCE="${2:-}"
      if [[ -z "$SINCE" ]]; then
        echo "ERROR: --since requires an ISO-8601 timestamp" >&2
        exit 2
      fi
      # Catch the case where the next arg is another flag (user forgot the value).
      if [[ "$SINCE" == -* ]]; then
        echo "ERROR: --since requires an ISO-8601 timestamp; got flag '$SINCE'" >&2
        exit 2
      fi
      shift 2
      ;;
    -h|--help)
      # Print the leading `#` comment block (everything after the shebang, up to the first blank line).
      # Delimiter-based extraction survives header edits without needing fixed line numbers.
      awk 'NR == 1 { next } /^$/ { exit } { print }' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# ----------------------------------------------------------------------
# 1. PR context
# ----------------------------------------------------------------------
# Resolve PR context. Two paths:
#   (a) --pr N: use explicit PR number, branch is informational (read from PR metadata)
#   (b) default: auto-detect from current branch (today's fixpr/audit.sh behavior)
if [[ -n "$PR_ARG" ]]; then
  # Validate --pr is a positive integer
  if ! [[ "$PR_ARG" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --pr value must be a positive integer (got: $PR_ARG)" >&2
    exit 2
  fi
  if ! PR_JSON=$(gh pr view "$PR_ARG" --json number,headRefName,headRefOid,state,url,mergeStateStatus,mergeable,reviewDecision 2>&1); then
    # Distinguish "not found" (404) from other gh errors
    if echo "$PR_JSON" | grep -qiE 'not found|could not resolve|no pull request'; then
      echo "ERROR: PR #$PR_ARG not found" >&2
      exit 4
    fi
    echo "ERROR: gh pr view failed: $PR_JSON" >&2
    exit 5
  fi
  BRANCH=$(echo "$PR_JSON" | jq -r '.headRefName // ""')
else
  BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  if [[ -z "$BRANCH" ]]; then
    echo "ERROR: not on a git branch and no --pr given (detached HEAD?)" >&2
    exit 3
  fi
  if ! PR_JSON=$(gh pr view --json number,headRefName,headRefOid,state,url,mergeStateStatus,mergeable,reviewDecision 2>&1); then
    if echo "$PR_JSON" | grep -qiE 'no pull requests|not found|could not resolve'; then
      echo "ERROR: no PR found for branch $BRANCH" >&2
      exit 4
    fi
    echo "ERROR: gh pr view failed: $PR_JSON" >&2
    exit 5
  fi
fi

# One jq pass extracts every field we need from PR_JSON.
# Uses a `read` block rather than `mapfile` — macOS ships bash 3.2, which has no mapfile/readarray.
# headRefOid is the authoritative current HEAD SHA — do NOT use .commits[-1].oid (depends on array order).
{ IFS= read -r PR_NUMBER
  IFS= read -r PR_STATE
  IFS= read -r HEAD_SHA
  IFS= read -r PR_URL
  IFS= read -r MERGE_STATE
  IFS= read -r MERGEABLE
  IFS= read -r REVIEW_DECISION
} < <(echo "$PR_JSON" | jq -r '
  .number,
  .state,
  (.headRefOid // ""),
  (.url // ""),
  (.mergeStateStatus // ""),
  (.mergeable // ""),
  (.reviewDecision // "")')

if [[ "$PR_STATE" != "OPEN" ]]; then
  echo "ERROR: PR #$PR_NUMBER is $PR_STATE — nothing to audit" >&2
  exit 4
fi

if ! OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>&1); then
  echo "ERROR: gh repo view failed: $OWNER_REPO" >&2
  exit 5
fi
OWNER="${OWNER_REPO%/*}"
REPO="${OWNER_REPO#*/}"

RUN_STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OUT="/tmp/pr-state-${PR_NUMBER}-$(date -u +%s).json"

# ----------------------------------------------------------------------
# 2. Review threads (GraphQL, paginated — authoritative for resolution)
# Use -F cursor (not -f) so "null" is typed as GraphQL null on the first page.
# ----------------------------------------------------------------------
ALL_THREADS="[]"
CURSOR="null"
while :; do
  RESP=$(gh api graphql -f query='query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            isResolved
            isOutdated
            comments(first: 10) {
              nodes {
                id
                databaseId
                body
                author { login }
                path
                line
                originalLine
                url
                createdAt
              }
            }
          }
        }
      }
    }
  }' -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER" -F cursor="$CURSOR")
  ALL_THREADS=$(jq -n --argjson acc "$ALL_THREADS" --argjson page "$RESP" \
    '$acc + $page.data.repository.pullRequest.reviewThreads.nodes')
  HAS_NEXT=$(echo "$RESP" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
  [[ "$HAS_NEXT" == "true" ]] || break
  CURSOR=$(echo "$RESP" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
done

UNRESOLVED=$(echo "$ALL_THREADS" | jq '[.[] | select(.isResolved == false)]')

# ----------------------------------------------------------------------
# 3. CI check-runs (paginated)
# ----------------------------------------------------------------------
CHECK_RUNS=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs?per_page=100" \
  --jq '.check_runs[]' | jq -s '.')

CR_SPLIT=$(echo "$CHECK_RUNS" | jq '
  def is_blocking: . == "failure" or . == "timed_out" or . == "action_required" or . == "startup_failure" or . == "stale";
  def is_passing: . == "success" or . == "neutral" or . == "skipped";
  {
    total: length,
    passing: ([.[] | select(.conclusion | is_passing)] | length),
    failing: ([.[] | select(.conclusion | is_blocking)] | length),
    in_progress: ([.[] | select(.status != "completed")] | length),
    failing_runs: [.[] | select(.conclusion | is_blocking) | {id, name, conclusion, title: .output.title, details_url, html_url}],
    in_progress_runs: [.[] | select(.status != "completed") | {id, name, status}],
    all: [.[] | {id, name, status, conclusion, title: .output.title}]
  }
')

# ----------------------------------------------------------------------
# 4. Commit statuses — latest per context, plus CR/Greptile bot rollup
# ----------------------------------------------------------------------
STATUSES=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/statuses?per_page=100" | jq -s 'add // []')

BOT_STATUSES=$(echo "$STATUSES" | jq '
  [.[] | select(.context == "CodeRabbit" or .context == "Greptile")]
  | group_by(.context)
  | map({
      key: .[0].context,
      value: (sort_by(.updated_at) | last | {state, description, updated_at, target_url})
    })
  | from_entries
')

# ----------------------------------------------------------------------
# 5. REST comment endpoints (paginated)
# ----------------------------------------------------------------------
REVIEWS=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews?per_page=100" | jq -s 'add // []')
INLINE=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments?per_page=100" | jq -s 'add // []')
CONVO=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR_NUMBER/comments?per_page=100" | jq -s 'add // []')

# ----------------------------------------------------------------------
# 6. New-since-baseline classification (only when --since given)
#    Classification rules are documented in fixpr/SKILL.md Step 5b and must stay
#    in sync with the regex branches below.
#
#    Branch ordering in classify is deliberate — do NOT reorder without reading this:
#      1. Explicit-resolution overrides (addressed marker, "actionable comments posted: 0")
#         are checked FIRST. They mean CR has marked the thread resolved regardless of
#         any quoted earlier finding language still in the body.
#      2. The specific "actionable comments posted: 0" check MUST precede the general
#         "actionable comments posted" finding check — otherwise the general pattern
#         swallows the zero case and a clean CR summary gets misclassified as a finding.
#      3. Finding patterns (severity/badges/phrases/suggestions) come next.
#      4. Weak-ack fallback (lgtm variants) last, so it can't hide a real finding.
#      5. Default is finding — under-classifying is the failure mode this skill prevents.
# ----------------------------------------------------------------------
NEW_SINCE="null"
if [[ -n "$SINCE" ]]; then
  NEW_SINCE=$(jq -n \
    --argjson reviews "$REVIEWS" \
    --argjson inline "$INLINE" \
    --argjson conversation "$CONVO" \
    --arg since "$SINCE" \
    '
    def classify:
      if . == null or . == "" then {class: "acknowledgment", reason: "empty body"}
      elif test("<!--\\s*<review_comment_addressed>\\s*-->"; "") then {class: "acknowledgment", reason: "addressed marker"}
      elif test("actionable comments posted:\\s*0\\b"; "i") then {class: "acknowledgment", reason: "CR reports zero actionable"}
      elif test("\\b(critical|major|minor|nitpick|p[0-2])\\b"; "i") then {class: "finding", reason: "severity keyword"}
      elif test("🔴|🟠|🟡"; "") then {class: "finding", reason: "severity badge"}
      elif test("actionable comments posted"; "i") then {class: "finding", reason: "actionable phrase"}
      elif test("potential[_ ]issue|issues? found|findings?:"; "i") then {class: "finding", reason: "finding phrase"}
      elif test("Prompt for AI Agent"; "i") then {class: "finding", reason: "CR fix prompt"}
      elif test("```suggestion"; "m") then {class: "finding", reason: "suggestion block"}
      elif test("\\b(lgtm|looks good|approved|confirmed|resolved)\\b"; "i") then {class: "acknowledgment", reason: "lgtm variant"}
      else {class: "finding", reason: "default — no pattern matched"}
      end;
    def enrich($since; $tsfield):
      [.[]
       | select((.user.login == "coderabbitai[bot]" or .user.login == "greptile-apps[bot]")
                and ((.[$tsfield] // "") > $since))
       | {
           id,
           user: .user.login,
           ts: .[$tsfield],
           url: (.html_url // .url),
           body,
           classification: (.body | classify)
         }];
    {
      reviews: ($reviews | enrich($since; "submitted_at")),
      inline: ($inline | enrich($since; "created_at")),
      conversation: ($conversation | enrich($since; "created_at"))
    }
    | . + {
        finding_count: ([.reviews[], .inline[], .conversation[]] | map(select(.classification.class == "finding")) | length),
        acknowledgment_count: ([.reviews[], .inline[], .conversation[]] | map(select(.classification.class == "acknowledgment")) | length)
      }
    ')
fi

# ----------------------------------------------------------------------
# 7. Assemble final JSON
# ----------------------------------------------------------------------
jq -n \
  --arg schema "1.0" \
  --argjson pr_number "$PR_NUMBER" \
  --arg branch "$BRANCH" \
  --arg owner "$OWNER" \
  --arg repo "$REPO" \
  --arg head_sha "$HEAD_SHA" \
  --arg pr_state "$PR_STATE" \
  --arg pr_url "$PR_URL" \
  --arg merge_state "$MERGE_STATE" \
  --arg mergeable "$MERGEABLE" \
  --arg review_decision "$REVIEW_DECISION" \
  --arg run_started_at "$RUN_STARTED_AT" \
  --arg since "$SINCE" \
  --argjson threads_all "$ALL_THREADS" \
  --argjson threads_unresolved "$UNRESOLVED" \
  --argjson cr_split "$CR_SPLIT" \
  --argjson statuses "$STATUSES" \
  --argjson bot_statuses "$BOT_STATUSES" \
  --argjson reviews "$REVIEWS" \
  --argjson inline "$INLINE" \
  --argjson conversation "$CONVO" \
  --argjson new_since "$NEW_SINCE" \
  '{
    schema_version: $schema,
    pr: {
      number: $pr_number,
      branch: $branch,
      owner: $owner,
      repo: $repo,
      state: $pr_state,
      url: $pr_url,
      head_sha: $head_sha
    },
    run_started_at: $run_started_at,
    since: (if $since == "" then null else $since end),
    threads: {
      total: ($threads_all | length),
      resolved_count: ([$threads_all[] | select(.isResolved)] | length),
      unresolved_count: ($threads_unresolved | length),
      unresolved: $threads_unresolved,
      all: $threads_all
    },
    check_runs: $cr_split,
    commit_statuses: $statuses,
    bot_statuses: $bot_statuses,
    comments: {
      reviews: $reviews,
      inline: $inline,
      conversation: $conversation
    },
    new_since_baseline: $new_since,
    merge_state: {
      mergeable: $mergeable,
      mergeStateStatus: $merge_state,
      reviewDecision: $review_decision
    }
  }' > "$OUT"

echo "$OUT"
