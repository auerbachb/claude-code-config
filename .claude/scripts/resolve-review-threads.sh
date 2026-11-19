#!/usr/bin/env bash
# resolve-review-threads.sh — Resolve unresolved PR review threads from bot reviewers.
# catalog: review-threads-diffs — Fetch PR review threads via GraphQL, resolve them, and verify `isResolved`
#
# Fetches all review threads on the given PR via GraphQL, filters to unresolved
# threads whose first-comment author matches --authors, and resolves each via
# resolveReviewThread. On failure, minimizeComment(classifier: RESOLVED) is
# available only for a first comment whose GraphQL author type is Bot.
#
# Usage:
#   resolve-review-threads.sh <pr_number> [--authors coderabbitai,cursor,greptile-apps,codeant-ai] [--thread-ids id1,id2 | --thread-ids-file path] [--max-attempts 2] [--dry-run]
#   resolve-review-threads.sh <pr_number> --thread-ids-file path --verify-only
#   resolve-review-threads.sh --help
#
# Flags:
#   --authors  Comma-separated list of GitHub logins (without [bot] suffix) whose
#              threads are eligible for resolution. Default:
#              coderabbitai,cursor,greptile-apps,codeant-ai
#              Retired Graphite threads require an explicit reviewed thread ID.
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
# Explicit IDs (issue #2431):
#   Thread IDs come from reviewThreads.nodes[].id — usually `PRRT_…`, but IDs are
#   opaque (legacy Base64 IDs are valid), so there is no prefix check. Before any
#   mutation (and in --dry-run / --verify-only) every explicit ID is classified:
#   an exact inventory thread ID is valid; an inventory opener-comment ID, a
#   purely numeric databaseId, or any other non-thread node type (read-only
#   node(id:) lookup) is refused with one `ERROR:` line per ID and exit 2 — no
#   mutation runs for any ID in the set. A thread on another PR or a node that is
#   not found stays in the set and is reported dangling with a precise reason.
#   An explicit ID already resolved in the first fetch prints
#   `[ALREADY-RESOLVED] <id> <url> (no mutation)` and counts as success when the
#   final verification still reads isResolved == true.
#
# Exit codes:
#   0  All addressed/matching threads verified resolved (or dry-run OK)
#   1  At least one thread is still dangling after retry/fallback verification
#      (unresolved, isResolved not true, not on this PR, or not found)
#   2  Usage error, including an explicit ID that is not a review-thread ID
#   3  PR not found
#   4  gh / network error (including a failed node-type lookup)
#
# See .claude/rules/cr-github-review.md "Processing CR Feedback" step 4.

set -euo pipefail
mkdir -p "${HOME}/.claude" 2>/dev/null || true
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

AUTHORS="coderabbitai,cursor,greptile-apps,codeant-ai"
DRY_RUN=0
VERIFY_ONLY=0
THREAD_IDS=""
THREAD_IDS_FILE=""
EXPLICIT_IDS_MODE=0
MAX_ATTEMPTS=2
PR_NUMBER=""

print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
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
                  author { login __typename }
                }
              }
            }
          }
        }
      }
    }"
    local resp
    if ! resp=$(gh api graphql -f query="$query" 2>&1); then
      if grep -qi "could not resolve to a pullrequest" <<<"$resp"; then
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
CLASS_FILE=$(mktemp -t resolve-class.XXXXXX)
trap 'rm -f "$MATCHES_FILE" "$EXPECTED_FILE" "$DANGLING_FILE" "$CLASS_FILE"' EXIT

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
          | select(.isResolved != true)
          | [.id,
             (.comments.nodes[0] | if .author.__typename == "Bot" then (.id // "-") else "-" end),
             (.comments.nodes[0].author.login // "-"), (.comments.nodes[0].url // "")]
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
          | [.id,
             (.comments.nodes[0] | if .author.__typename == "Bot" then (.id // "-") else "-" end),
             (.comments.nodes[0].author.login // "-"), (.comments.nodes[0].url // "")]
          | @tsv
        ' > "$MATCHES_FILE"
  fi
}

write_dangling_threads() {
  local threads_json="$1"
  if [[ -s "$EXPECTED_FILE" ]]; then
    local expected classes
    expected=$(expected_json)
    classes=$(jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries' "$CLASS_FILE")
    # Empty fields become "-" so tab-splitting `read` never collapses them and
    # shifts the reason into another column. Only isResolved == true counts.
    printf '%s' "$threads_json" \
      | jq -r --argjson expected "$expected" --argjson classes "$classes" --arg pr "$PR_NUMBER" '
          def nz: if . == null or . == "" then "-" else tostring end;
          def row($id; $comment_id; $author; $url; $reason):
            [$id, ($comment_id | nz), ($author | nz), ($url | nz), $reason] | @tsv;
          ([.[] | {key: .id, value: .}] | from_entries) as $by_id
          | $expected[]
          | . as $id
          | ($by_id[$id] // null) as $thread
          | if $thread == null then
              row($id; ""; ""; "";
                (if $classes[$id] == "other_pr" then "thread is not on PR #\($pr)"
                 elif $classes[$id] == "not_found" then "node not found or inaccessible"
                 else "thread not returned by GraphQL" end))
            elif $thread.isResolved != true then
              row($id; $thread.comments.nodes[0].id; $thread.comments.nodes[0].author.login; $thread.comments.nodes[0].url;
                "isResolved=\($thread.isResolved | if . == null then "null" else tostring end)")
            else empty
            end
        ' > "$DANGLING_FILE"
  fi
}

print_stuck_rows() {
  local thread_id _comment_id author url reason
  while IFS=$'\t' read -r thread_id _comment_id author url reason; do
    [[ -z "$thread_id" ]] && continue
    if [[ -n "$url" && "$url" != "-" ]]; then
      echo "[STUCK] $thread_id  ($author) — $reason — $url" >&2
    else
      echo "[STUCK] $thread_id  ($author) — $reason" >&2
    fi
  done < "$DANGLING_FILE"
}

# Read-only node-type lookup for an explicit ID absent from the PR inventory.
# Sets LOOKUP_KIND to a GraphQL __typename or "not_found". Exits 4 on transport
# failure, malformed JSON, or any GraphQL error other than NOT_FOUND — an
# inconclusive lookup is never evidence of the ID's type. Must run in the main
# shell (not inside $(...)) so the exit stops the script.
LOOKUP_KIND=""
lookup_node_type() {
  local id="$1" resp rc=0 err_file verdict
  err_file=$(mktemp -t resolve-lookup.XXXXXX)
  resp=$(gh api graphql -f id="$id" -f query='query($id: ID!) { node(id: $id) { __typename id } }' \
    </dev/null 2>"$err_file") || rc=$?
  verdict=$(printf '%s' "$resp" | jq -r '
      if type != "object" then "invalid"
      elif ((.errors // []) | length) > 0 then
        (if all(.errors[]; .type == "NOT_FOUND") then "not_found" else "error" end)
      elif (.data | type) != "object" then "invalid"
      elif .data.node == null then "not_found"
      else (.data.node.__typename // "invalid") end' 2>/dev/null) || verdict="invalid"
  [[ -n "$verdict" ]] || verdict="invalid"
  if [[ "$verdict" == "invalid" || "$verdict" == "error" ]] ||
     [[ "$rc" -ne 0 && "$verdict" != "not_found" ]]; then
    echo "ERROR: node-type lookup for $id failed (gh exit $rc): $(tr '\n' ' ' < "$err_file")${resp:+ response: $resp}" >&2
    rm -f "$err_file"
    exit 4
  fi
  rm -f "$err_file"
  LOOKUP_KIND="$verdict"
}

refuse_id() {
  local id="$1" kind="$2" hint="${3:-}"
  local msg="ERROR: $id is a $kind, not a review thread ID — expected a PullRequestReviewThread node id (usually PRRT_…) from reviewThreads.nodes[].id"
  if [[ -n "$hint" && "$hint" != "-" ]]; then
    msg="$msg; thread for this comment: $hint"
  fi
  echo "$msg" >&2
}

# Classify every explicit ID before any mutation. Refuses comment / numeric /
# other non-thread IDs (exit 2); records other-PR and not-found IDs in
# CLASS_FILE for precise dangling reasons.
validate_explicit_ids() {
  local threads_json="$1"
  : > "$CLASS_FILE"
  [[ -s "$EXPECTED_FILE" ]] || return 0
  local classified
  classified=$(printf '%s' "$threads_json" | jq -r --argjson expected "$(expected_json)" '
      . as $threads
      | ([$threads[] | select(.comments.nodes[0].id != null) | {key: .comments.nodes[0].id, value: .id}] | from_entries) as $openers
      | $expected[] | . as $id
      | if any($threads[]; .id == $id) then [$id, "thread", "-"]
        elif $openers[$id] != null then [$id, "comment", $openers[$id]]
        elif test("^[0-9]+$") then [$id, "numeric", "-"]
        else [$id, "lookup", "-"] end
      | @tsv')
  local refused=0 id kind hint
  while IFS=$'\t' read -r id kind hint; do
    [[ -z "$id" ]] && continue
    case "$kind" in
      thread) ;;
      comment)
        refuse_id "$id" "PullRequestReviewComment (opener of a thread on PR #$PR_NUMBER)" "$hint"
        refused=$((refused + 1)) ;;
      numeric)
        refuse_id "$id" "numeric databaseId"
        refused=$((refused + 1)) ;;
      *)
        lookup_node_type "$id"
        case "$LOOKUP_KIND" in
          PullRequestReviewThread) printf '%s\t%s\n' "$id" "other_pr" >> "$CLASS_FILE" ;;
          not_found) printf '%s\t%s\n' "$id" "not_found" >> "$CLASS_FILE" ;;
          *)
            refuse_id "$id" "$LOOKUP_KIND"
            refused=$((refused + 1)) ;;
        esac ;;
    esac
  done <<< "$classified"
  if [[ "$refused" -gt 0 ]]; then
    echo "ERROR: refused $refused non-thread ID(s); no thread was mutated. Pass the thread IDs and re-run." >&2
    exit 2
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
  validate_explicit_ids "$VERIFY_THREADS"
  write_dangling_threads "$VERIFY_THREADS"
  DANGLING_COUNT=$(wc -l < "$DANGLING_FILE" | tr -d ' ')
  RESOLVED_COUNT=$((ADDRESSED_COUNT - DANGLING_COUNT))
  if [[ "$RESOLVED_COUNT" -lt 0 ]]; then
    RESOLVED_COUNT=0
  fi
  echo "[VERIFY] addressed=$ADDRESSED_COUNT resolved=$RESOLVED_COUNT dangling=$DANGLING_COUNT"
  if [[ "$DANGLING_COUNT" -gt 0 ]]; then
    print_stuck_rows
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

  if [[ -n "$comment_id" && "$comment_id" != "-" ]]; then
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

  echo "[FAILED] attempt=$attempt $thread_id  ($author) — resolveReviewThread: $resp | no verified bot comment for fallback" >&2
  return 1
}

ALL_THREADS=$(collect_threads)
validate_explicit_ids "$ALL_THREADS"
write_unresolved_matches "$ALL_THREADS"

# Explicit IDs already resolved in the first fetch: idempotent success, no
# mutation. Final verification below stays the authority.
print_already_resolved() {
  [[ -s "$EXPECTED_FILE" ]] || return 0
  local prefix="$1" tid url
  printf '%s' "$ALL_THREADS" \
    | jq -r --argjson expected "$(expected_json)" '
        .[] | select(.isResolved == true) | select(.id as $id | $expected | index($id))
        | [.id, (.comments.nodes[0].url // "-" | if . == "" then "-" else . end)] | @tsv' \
    | while IFS=$'\t' read -r tid url; do
        [[ -z "$tid" ]] && continue
        echo "${prefix}$tid ${url} (no mutation)"
      done
}

if [[ -s "$EXPECTED_FILE" ]]; then
  ADDRESSED_COUNT=$(wc -l < "$EXPECTED_FILE" | tr -d ' ')
else
  ADDRESSED_COUNT=$(wc -l < "$MATCHES_FILE" | tr -d ' ')
  cut -f1 "$MATCHES_FILE" > "$EXPECTED_FILE"
fi

MATCH_COUNT=$(wc -l < "$MATCHES_FILE" | tr -d ' ')

if [[ "$DRY_RUN" -eq 1 ]]; then
  print_already_resolved "[DRY-RUN] [ALREADY-RESOLVED] "
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

print_already_resolved "[ALREADY-RESOLVED] "

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
  print_stuck_rows
  echo "ERROR: $DANGLING_COUNT thread(s) remain dangling after retry/fallback verification" >&2
  exit 1
fi

exit 0
