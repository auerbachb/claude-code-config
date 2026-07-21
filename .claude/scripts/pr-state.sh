#!/usr/bin/env bash
# pr-state.sh — Gather all PR state into a single JSON file.
#
# Shared helper used by /fixpr, /merge, /wrap, /go-on, /status, phase-b-reviewer,
# and phase-c-merger. Collapses the 3-endpoint comment scan + GraphQL review threads
# + check-runs + commit statuses into one JSON bundle. Call sites read the bundle
# via jq instead of re-issuing overlapping gh api calls inline.
#
# Usage:
#   pr-state.sh                          # Auto-detect PR from current branch
#   pr-state.sh --pr 123                 # Use explicit PR number (skips branch detect)
#   pr-state.sh --since <iso-8601>       # Pre-classify bot comments posted since baseline
#   pr-state.sh --pr 123 --since <iso>   # Combined
#   pr-state.sh --infer-candidates       # List session-tracked PR candidates (no GitHub state)
#   pr-state.sh --help                   # Print usage
#
# Output: writes JSON to /tmp/pr-state-<PR>-<epoch>.json and prints the path on stdout.
#         (--infer-candidates prints a JSON array to stdout instead — see below.)
#
# --infer-candidates (shared by /fixpr issue #447 and /wrap issue #448):
#   Reads ~/.claude/session-state.json and prints a JSON array of the PRs this
#   session is actively tracking (those with a non-null .phase), newest activity
#   first (by .last_cron_action.at). No git branch, gh, or network calls are made
#   for the candidate set itself — this is the fast no-argument inference path for
#   /fixpr and /wrap. Each element:
#       { "number": <int>, "phase": <str|null>, "reviewer": <str|null>,
#         "needs": <str|null>, "blocker_kind": <str|null>,
#         "owner_repo": <str|null>, "root_repo": <str|null>,
#         "last_action_at": <iso-8601|"">, "same_repo": <true|false|null> }
#   `same_repo` is true/false when both the current repo (via git remote URL) and
#   the candidate's stored owner_repo are known, else null ("unknown — don't filter
#   it out"). Always exits 0 with `[]` when the state file is missing or tracks no
#   active PRs. Cannot be combined with --pr or --since.
#
# Exit codes:
#   0  OK
#   2  usage error (unknown flag, --since missing value, incompatible flag combo)
#   3  no git branch AND no --pr given
#   4  PR closed, merged, or not found
#   5  gh/network error

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

# Wrap every `gh` invocation so any auth/network/API failure maps to exit code 5
# (the documented "gh/network error" code in the CLI contract). Under `set -e`,
# a bare `gh ...` would exit with whatever code gh returned — typically 1 — and
# callers relying on this script's exit contract would see the wrong code.
#
# Uses `|| status=$?` to capture the exit status without triggering `set -e`
# on failure (the `||` branch makes the whole expression succeed).
run_gh() {
  local output status=0
  output=$(gh "$@" 2>&1) || status=$?
  if [[ $status -ne 0 ]]; then
    echo "ERROR: gh command failed (exit $status): $output" >&2
    exit 5
  fi
  printf '%s' "$output"
}

PR_ARG=""
SINCE=""
INFER_CANDIDATES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --infer-candidates)
      INFER_CANDIDATES=1
      shift
      ;;
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
# 0. --infer-candidates: list session-tracked PR candidates and exit.
#    Shared by /fixpr (#447) and /wrap (#448) for no-argument PR inference.
#    Pure read of ~/.claude/session-state.json — no GitHub state is gathered.
# ----------------------------------------------------------------------
if [[ "$INFER_CANDIDATES" -eq 1 ]]; then
  if [[ -n "$PR_ARG" || -n "$SINCE" ]]; then
    echo "ERROR: --infer-candidates cannot be combined with --pr or --since" >&2
    exit 2
  fi
  STATE_FILE="$HOME/.claude/session-state.json"
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "[]"
    exit 0
  fi
  # Best-effort current repo detection so candidates can be flagged same_repo.
  # Derived offline from the git remote URL to avoid any network/auth dependency.
  # Falls back to "" so same_repo is reported as null ("unknown — don't filter").
  _remote_url=$(git remote get-url origin 2>/dev/null || echo "")
  if [[ -n "$_remote_url" ]]; then
    # Handle both HTTPS (https://github.com/owner/repo.git) and SSH (git@github.com:owner/repo.git)
    _remote_url="${_remote_url%.git}"
    CUR_OWNER_REPO="${_remote_url##*github.com[:/]}"
  else
    CUR_OWNER_REPO=""
  fi
  # `(.prs // {})` tolerates a state file with no `prs` key. tonumber? keeps
  # non-numeric keys from aborting the whole pass (defensive — keys are always
  # numeric PR strings in practice).
  # Only the missing-file / empty-prs cases return []; parse/runtime errors are
  # surfaced on stderr so state corruption is visible rather than silently masked.
  # Read the PR map through session-state.sh so it comes back scoped to this
  # repo (issue #638) and a legacy flat file is migrated in memory. Reading
  # the raw top-level `.prs` here used to mix in other repos' PRs, which is
  # exactly what `same_repo` below was invented to paper over.
  #
  # Two buckets are read, not one:
  #   - this repo's scope — PRs known to belong here
  #   - the reserved "_unknown" scope — legacy entries that carried no
  #     owner_repo and whose recorded checkout path no longer resolves, so
  #     their repo genuinely cannot be determined
  # Including the second preserves this helper's original promise (entries
  # with an unknown repo are kept, because dropping them would hide
  # legitimately-tracked PRs) while still excluding every PR known to belong
  # to a DIFFERENT repo — which is the collision the scoping exists to end.
  # On key conflict the scoped entry wins: it is attributed, the other is not.
  _state_sh="$(cd "$(dirname "$0")" && pwd)/session-state.sh"
  if ! _prs_scoped=$("$_state_sh" --get '.prs // {}' 2>/dev/null); then
    _prs_scoped="{}"
  fi
  [[ -z "$_prs_scoped" || "$_prs_scoped" == "null" ]] && _prs_scoped="{}"
  if ! _prs_unknown=$("$_state_sh" --raw-path --get '.repos["_unknown"].prs // {}' 2>/dev/null); then
    _prs_unknown="{}"
  fi
  [[ -z "$_prs_unknown" || "$_prs_unknown" == "null" ]] && _prs_unknown="{}"
  _jq_out=$(jq -c --arg cur "$CUR_OWNER_REPO" \
      --argjson scoped "$_prs_scoped" --argjson unknown "$_prs_unknown" '
    [ ( ($unknown | map_values(. + {_scope: "unknown"}))
        + ($scoped  | map_values(. + {_scope: "repo"})) )
      | to_entries[]
      | select(.value.phase != null)
      | {
          number: (.key | tonumber? // .key),
          phase: (.value.phase // null),
          reviewer: (.value.reviewer // null),
          needs: (.value.needs // null),
          blocker_kind: (.value.blocker_kind // null),
          owner_repo: (.value.owner_repo // null),
          root_repo: (.value.root_repo // null),
          # `?` (issue #640, CodeAnt finding on PR #654) suppresses the
          # "Cannot index string with \"at\"" error a pre-existing malformed
          # (non-object) last_cron_action would otherwise raise — without it,
          # ONE corrupted entry aborts this whole array comprehension and the
          # caller falls back to printing "[]" for every candidate, not just
          # the bad one.
          last_action_at: (.value.last_cron_action.at? // ""),
          same_repo: (
            # Membership is now structural: an entry read from the scope of
            # this repo belongs here. Entries from the "_unknown" bucket
            # keep the original "unknown - do not filter" meaning of null.
            # owner_repo is still consulted when present so a mismatch left
            # behind by pre-#638 state stays visible rather than asserted away.
            if .value._scope == "unknown" then null
            elif (.value.owner_repo // "") == "" then true
            elif $cur == "" then null
            else (.value.owner_repo == $cur) end
          )
        }
    ]
    | sort_by(.last_action_at) | reverse
  ' <<<'{}' 2>&1)
  _jq_rc=$?
  if [[ $_jq_rc -ne 0 ]]; then
    echo "WARNING: pr-state.sh --infer-candidates: failed to parse $STATE_FILE (jq exit $_jq_rc): $_jq_out" >&2
    echo "[]"
  else
    echo "$_jq_out"
  fi
  exit 0
fi

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
# Use mktemp so concurrent invocations for the same PR in the same second
# (realistic now that multiple skills share this helper) don't collide.
# macOS mktemp only expands XXXXXX at the END of the template, so create the
# temp file without the .json suffix, then rename. Both the base tempfile and
# the renamed target are unique per-invocation, so the rename cannot clobber
# another concurrent run's output.
OUT_BASE=$(mktemp "/tmp/pr-state-${PR_NUMBER}-$(date -u +%s)-XXXXXX")
OUT="${OUT_BASE}.json"
mv "$OUT_BASE" "$OUT"

# ----------------------------------------------------------------------
# 2. Review threads (GraphQL, paginated — authoritative for resolution)
# Use -F cursor (not -f) so "null" is typed as GraphQL null on the first page.
# ----------------------------------------------------------------------
ALL_THREADS="[]"
CURSOR="null"
while :; do
  RESP=$(run_gh api graphql -f query='query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
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
CHECK_RUNS=$(run_gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs?per_page=100" \
  --jq '.check_runs[]' | jq -s '.')

CR_SPLIT=$(echo "$CHECK_RUNS" | jq '
  def is_blocking: . == "failure" or . == "timed_out" or . == "action_required" or . == "startup_failure" or . == "stale";
  def is_passing: . == "success" or . == "neutral" or . == "skipped" or . == "cancelled";
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
STATUSES=$(run_gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/statuses?per_page=100" | jq -s 'add // []')

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
REVIEWS=$(run_gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews?per_page=100" | jq -s 'add // []')
INLINE=$(run_gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments?per_page=100" | jq -s 'add // []')
CONVO=$(run_gh api --paginate "repos/$OWNER/$REPO/issues/$PR_NUMBER/comments?per_page=100" | jq -s 'add // []')

# ----------------------------------------------------------------------
# 6. New-since-baseline classification (only when --since given)
#    Classification rules are documented in fixpr/SKILL.md Step 5b and must stay
#    in sync with the regex branches below.
#
#    Branch ordering in classify is deliberate — do NOT reorder without reading this:
#      1. Explicit-resolution / clean-pass overrides (addressed marker, withdrawn marker, "actionable comments posted: 0",
#         "no actionable comments were generated"; CR rate-limit notices — "rate limit exceeded" /
#         "rate[- ]limited by coderabbit" / "currently rate limited" / "review limit reached" /
#         "next review (will be) available in"; BugBot usage-limit notices — "couldn't run - usage limit
#         reached" / "this run hit a usage or spend limit"; "full review triggered", BugBot clean-pass
#         "found no new issues", BugBot BUGBOT_REVIEW zero-issue summary, CR error stub
#         "Oops, something went wrong")
#         are checked FIRST. They mean CR/BugBot has issued a clean pass, reported a rate/usage limit
#         instead of reviewing, posted a review-started ack, or emitted a transient error — regardless
#         of any quoted earlier finding language. CR wraps its Fair-Usage notice in a "Full review
#         finished" ack, so the "full review triggered" branch does NOT cover it — the rate-limit
#         phrases must.
#         Every CR rate-limit phrase names CR's own notice wording. A bare "fair usage limits policy"
#         was tried and rejected (#557): it is generic enough that a real finding *quoting* the policy
#         would classify as an ack. Each observed CR variant is caught by >=2 of the phrases above,
#         so no single generic phrase has to carry it.
#         The withdrawn marker (#611) is safe in this tier-1 group even though the walkthrough marker
#         (override #6 below) is deliberately not: a withdrawal retracts the single finding in its own
#         thread — there is no *other* active finding for an early override to mask — so hoisting it
#         here cannot produce a false clean. Marker-only, mirroring the addressed marker: the prose
#         "Withdrawing the finding" is NOT matched, avoiding the #557 generic-phrase false-ack risk.
#      2. The specific "actionable comments posted: 0" and "no actionable comments were
#         generated" checks MUST precede the general "actionable comments posted" finding
#         check — otherwise the general pattern swallows clean CR summaries as findings.
#      3. BugBot BUGBOT_REVIEW zero-issue check MUST precede the generic "issues? found"
#         finding pattern — otherwise the finding pattern swallows BugBot clean summaries.
#      4. Finding patterns (severity/badges/phrases/suggestions) come next.
#      5. Weak-ack fallback (lgtm variants) next, so it can't hide a real finding.
#      6. CR walkthrough/summary marker ("<!-- ... summarize by coderabbit.ai -->") is the LAST
#         override, immediately above the default — deliberately NOT in the tier-1 group above (#575).
#         This is a different trigger from #557's rate-limit/usage-limit family: the walkthrough is
#         the boilerplate CR posts on nearly every PR, and it matched no branch at all, so it fell
#         through to default → finding and produced phantom findings.
#         Its late placement is load-bearing: the walkthrough can carry "actionable comments posted: N"
#         (N > 0) and severity keywords for the findings it is summarizing. Hoisting this branch up
#         with the other overrides would mask those real findings — a false clean on the review gate,
#         which is strictly worse than the phantom-finding noise it fixes. Every finding pattern must
#         be evaluated first and win. Ordering alone supplies that guard, so no AND-not guard (of the
#         BugBot zero-issue kind) is needed here.
#      7. Default is finding — under-classifying is the failure mode this skill prevents.
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
      elif test("<!--\\s*<review_comment_withdrawn>\\s*-->"; "") then {class: "acknowledgment", reason: "withdrawn marker"}
      elif test("actionable comments posted:\\s*0\\b"; "i") then {class: "acknowledgment", reason: "CR reports zero actionable"}
      elif test("no actionable comments were generated"; "i") then {class: "acknowledgment", reason: "CR no actionable comments generated"}
      elif test("rate limit exceeded|rate.limited by coderabbit|currently rate limited|review limit reached|next review (will be )?available in"; "i") then {class: "acknowledgment", reason: "rate limit notice"}
      # Apostrophe is escaped as \u0027 — a raw one would close this single-quoted jq program.
      elif test("couldn[\u0027’]t run\\s*[-–—]\\s*usage limit reached|this run hit a usage or spend limit"; "i") then {class: "acknowledgment", reason: "BugBot usage limit notice"}
      elif test("full review triggered"; "i") then {class: "acknowledgment", reason: "review-started ack"}
      elif test("found no new issues"; "i") then {class: "acknowledgment", reason: "BugBot clean pass"}
      elif (test("<!--\\s*BUGBOT_REVIEW\\s*-->"; "") and (test("found [1-9][0-9]* potential issue"; "i") | not)) then {class: "acknowledgment", reason: "BugBot zero-issue summary"}
      elif test("Oops, something went wrong"; "i") then {class: "acknowledgment", reason: "CR error stub / transient noise"}
      elif test("\\b(critical|major|minor|nitpick|p[0-2])\\b"; "i") then {class: "finding", reason: "severity keyword"}
      elif test("🔴|🟠|🟡"; "") then {class: "finding", reason: "severity badge"}
      elif test("actionable comments posted"; "i") then {class: "finding", reason: "actionable phrase"}
      elif test("potential[_ ]issue|issues? found|findings?:"; "i") then {class: "finding", reason: "finding phrase"}
      elif test("Prompt for AI Agent"; "i") then {class: "finding", reason: "CR fix prompt"}
      elif test("```suggestion"; "m") then {class: "finding", reason: "suggestion block"}
      elif test("\\b(lgtm|looks good|approved|confirmed|resolved)\\b"; "i") then {class: "acknowledgment", reason: "lgtm variant"}
      elif test("<!--\\s*This is an auto-generated comment:\\s*summarize by coderabbit\\.ai\\s*-->"; "i") then {class: "acknowledgment", reason: "CR walkthrough summary"}
      else {class: "finding", reason: "default — no pattern matched"}
      end;
    def enrich($since; $tsfield):
      [.[]
       | select((.user.login == "coderabbitai[bot]" or .user.login == "greptile-apps[bot]" or .user.login == "cursor[bot]")
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
