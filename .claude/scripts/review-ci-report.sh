#!/usr/bin/env bash
# review-ci-report.sh — Per-repo review timing and CI report: CI duration and failure share, reviewer response time from the review request or from push, refusals, and CodeAnt pre-review approvals kept out of the review count (issue #2196).
# catalog: review-escalation — Measure, per repo, how long CI runs, how often it fails, and how long each AI reviewer takes to respond (from its request when one exists, else from push), with blind spots stated; one GraphQL request per repo
#
# PURPOSE
#   Answers whether a change to WHEN reviews are requested saves reviews, and
#   what it costs in time. Each repo is read with exactly one GraphQL request
#   (no pagination). The classification and arithmetic live in
#   lib/review_ci_report.py, a pure function from response to report.
#
# USAGE
#   review-ci-report.sh [--repo owner/name]... [--since YYYY-MM-DD]
#                       [--limit N] [--wait-minutes N] [--json]
#                       [--fixture FILE]
#   review-ci-report.sh --help | -h
#
#   --repo owner/name   Repeatable. Default: review-repos.sh's list.
#   --since DATE        Keep PRs merged on or after DATE (YYYY-MM-DD).
#   --limit N           Last N PRs by update time per repo, 1-100 (default 25).
#   --wait-minutes N    Configured review wait, 0-1440. Default: the
#                       NO_REVIEW_OVERRIDE_MINUTES environment value when set,
#                       else 10 (no-review-override.md).
#   --json              Emit JSON (schema review-ci-report/v1) instead of Markdown.
#   --fixture FILE      Read per-repo GraphQL responses from FILE instead of
#                       GitHub. FILE is {"repos": {"owner/name": <response>}};
#                       an entry {"gh_error": "..."} simulates a failed query.
#
# REQUEST BUDGET
#   One `gh api graphql` request per repo, nothing paginated. The output states
#   the count and GitHub's reported point cost for each repo.
#
# EXIT CODES
#   0  every repo was read.
#   1  at least one repo is unread (its metrics are never reported as zeros),
#      or the report could not be produced.
#   2  usage error.
#
# BLIND SPOTS (printed in every repo's section)
#   Force-pushed-away commits, sample size per reviewer, no cost data, truncated
#   connections, the PR selection heuristic, re-runs, phrase-based refusal
#   detection, inferred attributions, and undated items.

set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
LIB_PY="$SELF_DIR/lib/review_ci_report.py"

usage_error() {
  echo "ERROR: $1" >&2
  echo "Run review-ci-report.sh --help for usage." >&2
  exit 2
}

show_help() {
  sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
}

REPOS=()
SINCE=""
LIMIT=25
WAIT=""
FORMAT="table"
FIXTURE=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) show_help; exit 0 ;;
    --repo)
      [ $# -ge 2 ] || usage_error "--repo needs owner/name"
      REPOS+=("$2"); shift 2 ;;
    --since)
      [ $# -ge 2 ] || usage_error "--since needs YYYY-MM-DD"
      SINCE="$2"; shift 2 ;;
    --limit)
      [ $# -ge 2 ] || usage_error "--limit needs a number"
      LIMIT="$2"; shift 2 ;;
    --wait-minutes)
      [ $# -ge 2 ] || usage_error "--wait-minutes needs a number"
      WAIT="$2"; shift 2 ;;
    --json) FORMAT="json"; shift ;;
    --fixture)
      [ $# -ge 2 ] || usage_error "--fixture needs a file"
      FIXTURE="$2"; shift 2 ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done

case "$LIMIT" in
  ''|*[!0-9]*) usage_error "--limit must be a whole number from 1 to 100" ;;
esac
if [ "$LIMIT" -lt 1 ] || [ "$LIMIT" -gt 100 ]; then
  usage_error "--limit must be from 1 to 100"
fi

if [ -n "$SINCE" ]; then
  case "$SINCE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) usage_error "--since must be YYYY-MM-DD" ;;
  esac
  # Shape alone lets 2026-02-31 through; the calendar must accept the date too.
  if ! python3 -c 'import datetime, sys; datetime.date.fromisoformat(sys.argv[1])' "$SINCE" 2>/dev/null; then
    usage_error "--since is not a real calendar date: $SINCE"
  fi
fi

if [ -n "$WAIT" ]; then
  WAIT_SOURCE="flag"
elif [ -n "${NO_REVIEW_OVERRIDE_MINUTES:-}" ]; then
  WAIT="$NO_REVIEW_OVERRIDE_MINUTES"
  WAIT_SOURCE="env NO_REVIEW_OVERRIDE_MINUTES"
else
  WAIT=10
  WAIT_SOURCE="built-in default, see no-review-override.md"
fi
case "$WAIT" in
  ''|*[!0-9]*) usage_error "--wait-minutes must be a whole number of minutes" ;;
esac
if [ "$WAIT" -gt 1440 ]; then
  usage_error "--wait-minutes must be at most 1440"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found — review-ci-report unavailable" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found — review-ci-report unavailable" >&2
  exit 1
fi
if [ ! -f "$LIB_PY" ]; then
  echo "ERROR: lib/review_ci_report.py not found next to this script — review-ci-report unavailable" >&2
  exit 1
fi

# Validate every explicit repo before any request is made.
for R in ${REPOS[@]+"${REPOS[@]}"}; do
  OWNER="${R%%/*}"
  NAME="${R#*/}"
  if [ -z "$OWNER" ] || [ -z "$NAME" ] || [ "$NAME" = "$R" ]; then
    usage_error "--repo must be owner/name: $R"
  fi
  case "$OWNER$NAME" in
    *[!A-Za-z0-9_.-]*) usage_error "--repo has characters outside owner/name rules: $R" ;;
  esac
  case "$NAME" in */*) usage_error "--repo must be owner/name: $R" ;; esac
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/review-ci-report.XXXXXX") || { echo "ERROR: cannot create a temporary directory" >&2; exit 1; }
cleanup() {
  rm -f "$TMP"/*.out "$TMP"/*.err "$TMP"/manifest.jsonl "$TMP"/rr.err 2>/dev/null
  rmdir "$TMP" 2>/dev/null
}
trap cleanup EXIT

# Resolve the repo list: explicit --repo, else the fixture keys, else review-repos.sh.
if [ ${#REPOS[@]} -eq 0 ]; then
  if [ -n "$FIXTURE" ]; then
    if [ ! -r "$FIXTURE" ]; then usage_error "--fixture not readable: $FIXTURE"; fi
    REPO_LIST=$(jq -r '.repos | keys[]' "$FIXTURE" 2>/dev/null) || usage_error "--fixture is not valid JSON with a repos object"
    while IFS= read -r R; do [ -n "$R" ] && REPOS+=("$R"); done <<EOF
$REPO_LIST
EOF
  else
    RR_SH=""
    for CAND in "$SELF_DIR/review-repos.sh" "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/review-repos.sh}" "${HOME:+$HOME/.claude/scripts/review-repos.sh}" ".claude/scripts/review-repos.sh"; do
      [ -n "$CAND" ] && [ -x "$CAND" ] && { RR_SH="$CAND"; break; }
    done
    [ -n "$RR_SH" ] || { echo "ERROR: review-repos.sh not found (checked all candidate paths) — no default repo list; pass --repo" >&2; exit 1; }
    REPO_LIST=$("$RR_SH" 2>"$TMP/rr.err") || { echo "ERROR: review-repos.sh failed — pass --repo explicitly; no partial list is used" >&2; exit 1; }
    while IFS= read -r R; do [ -n "$R" ] && REPOS+=("$R"); done <<EOF
$REPO_LIST
EOF
  fi
fi
[ ${#REPOS[@]} -gt 0 ] || { echo "ERROR: no repos to read" >&2; exit 1; }

# The one GraphQL query per repo. Bounds are named here and printed by the
# classifier's input contract; @@…@@ placeholders are filled below.
COMMITS_N=10
CONTEXTS_N=50
REVIEWS_N=100
COMMENTS_N=100
TIMELINE_N=100
QUERY=$(cat <<'EOF'
query($owner: String!, $name: String!, $limit: Int!) {
  rateLimit { cost remaining resetAt }
  repository(owner: $owner, name: $name) {
    pullRequests(states: MERGED, first: $limit, orderBy: {field: UPDATED_AT, direction: DESC}) {
      totalCount
      nodes {
        number mergedAt createdAt headRefOid
        commits(last: @@COMMITS@@) {
          totalCount
          nodes {
            commit {
              oid committedDate
              statusCheckRollup {
                contexts(first: @@CONTEXTS@@) {
                  totalCount
                  nodes {
                    __typename
                    ... on CheckRun { name status conclusion startedAt completedAt checkSuite { app { slug } } }
                    ... on StatusContext { context state createdAt }
                  }
                }
              }
            }
          }
        }
        reviews(first: @@REVIEWS@@) {
          totalCount
          nodes { author { __typename login } state submittedAt body commit { oid } }
        }
        comments(last: @@COMMENTS@@) {
          totalCount
          nodes { author { __typename login } createdAt body }
        }
        timelineItems(first: @@TIMELINE@@, itemTypes: [REVIEW_REQUESTED_EVENT, HEAD_REF_FORCE_PUSHED_EVENT]) {
          totalCount
          nodes {
            __typename
            ... on ReviewRequestedEvent { createdAt requestedReviewer { __typename ... on Bot { login } ... on User { login } } }
            ... on HeadRefForcePushedEvent { createdAt beforeCommit { oid } afterCommit { oid } }
          }
        }
      }
    }
  }
}
EOF
)
QUERY="${QUERY//@@COMMITS@@/$COMMITS_N}"
QUERY="${QUERY//@@CONTEXTS@@/$CONTEXTS_N}"
QUERY="${QUERY//@@REVIEWS@@/$REVIEWS_N}"
QUERY="${QUERY//@@COMMENTS@@/$COMMENTS_N}"
QUERY="${QUERY//@@TIMELINE@@/$TIMELINE_N}"

MANIFEST="$TMP/manifest.jsonl"
: >"$MANIFEST"
IDX=0
for R in "${REPOS[@]}"; do
  IDX=$((IDX + 1))
  OUT="$TMP/$IDX.out"
  ERR="$TMP/$IDX.err"
  : >"$OUT"; : >"$ERR"
  if [ -n "$FIXTURE" ]; then
    FIX_ENTRY=$(jq -c --arg r "$R" '.repos[$r] // {"gh_error": "no fixture entry for repo"}' "$FIXTURE" 2>/dev/null) || FIX_ENTRY='{"gh_error":"fixture unreadable"}'
    GH_ERROR=$(printf '%s' "$FIX_ENTRY" | jq -r '.gh_error // empty' 2>/dev/null)
    if [ -n "$GH_ERROR" ]; then
      RC=1
      printf '%s\n' "$GH_ERROR" >"$ERR"
    else
      RC=0
      printf '%s' "$FIX_ENTRY" >"$OUT"
    fi
  else
    OWNER="${R%%/*}"
    NAME="${R#*/}"
    gh api graphql -f query="$QUERY" -F owner="$OWNER" -F name="$NAME" -F limit="$LIMIT" >"$OUT" 2>"$ERR"
    RC=$?
  fi
  jq -cn --arg repo "$R" --argjson rc "$RC" --arg out "$OUT" --arg err "$(head -c 400 "$ERR" 2>/dev/null)" \
    '{repo: $repo, rc: $rc, out_file: $out, err: $err}' >>"$MANIFEST" || { echo "ERROR: could not record $R" >&2; exit 1; }
done

python3 "$LIB_PY" --manifest "$MANIFEST" --wait-minutes "$WAIT" --wait-source "$WAIT_SOURCE" \
  --limit "$LIMIT" --since "$SINCE" --format "$FORMAT"
exit $?
