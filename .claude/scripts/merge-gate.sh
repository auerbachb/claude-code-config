#!/usr/bin/env bash
# merge-gate.sh — Verify the merge gate for a PR (CR / BugBot / Greptile / CodeAnt).
#
# Implements the authoritative gate defined in .claude/rules/cr-merge-gate.md:
#   - CR path       : 1 explicit CodeRabbit OR CodeAnt APPROVED on current HEAD SHA
#                     (SHA freshness + same-SHA retraction per bot, same rules as legacy CR-only).
#                     CodeAnt is supplemental: when CodeAnt participated on that SHA,
#                     require CodeAnt APPROVED or a successful CodeAnt check-run;
#                     CodeAnt CHANGES_REQUESTED blocks only if newer than the latest
#                     clean signal (APPROVED or successful check completion).
#   - BugBot path   : 1 clean BugBot review on current HEAD + zero unresolved BugBot threads
#   - Greptile path : severity-gated — clean OR only P1/P2 (fixed) OR P0 fixed + re-review clean
#
# Stale-approval guard (issue #836): GitHub retargets review commit_id to the new
#   HEAD SHA after a force-push, but submitted_at is never updated. An approval
#   whose submitted_at predates the HEAD commit's committer date is rejected even
#   when commit_id matches — distinct missing[] reason so callers know to re-trigger
#   rather than rebase. Applied to: CR/CodeAnt APPROVED reviews, CodeAnt clean
#   check-run completed_at, BugBot reviews. Grace window: none (submitted_at must
#   be >= committer date; equal timestamps are accepted). Guard is disabled when
#   LAST_COMMIT_TS is empty (API failure) to avoid silently blocking clean reviews.
# Also enforces the pre-merge CI gate from .claude/rules/cr-merge-gate.md Step 1b
# (incomplete runs OR blocking conclusions = not merge-ready), merge metadata
# (mergeStateStatus including BEHIND, mergeable including CONFLICTING) per
# cr-merge-gate.md Step 1d / issue #273. When CR, Greptile, or CodeAnt is listed
# in CODEOWNERS, also verifies GitHub branch protection's reviewDecision is
# APPROVED so stale/dismissed bot approvals cannot accidentally pass the gate.
# When stderr notes stale bot CHANGES_REQUESTED (issue #426), dismiss via
# dismiss-stale-bot-changes.sh after push — do not treat as a human block.
#
# Usage:
#   merge-gate.sh <pr_number> [--reviewer cr|bugbot|greptile] [--allow-nonauthor]
#   merge-gate.sh --help
#
# Authorship guard (issue #733): a merge is a write, so the gate BLOCKS a
# confirmed foreign-author PR (adds a `missing` entry; the `authorship` field is
# emitted on every result). "unknown" does not block here — the strict
# fail-closed lives at polling-state-gate --ensure-session and pr-authorship.sh.
# --allow-nonauthor suppresses the block ONLY under an explicit per-PR user override.
#
# Reviewer resolution order (unless --reviewer is passed):
#   1. ~/.claude/session-state.json  .prs["<N>"].reviewer  ("cr"/"bugbot"/"greptile"/"g")
#   2. Live history scan — greptile-apps[bot] present → greptile;
#      cursor[bot] present AND coderabbitai[bot] absent AND codeant-ai[bot] absent
#      → bugbot; else cr (CodeAnt-only reviews use the CR path per #408).
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
#     "merge_state": "CLEAN"|"BEHIND"|"BLOCKED"|...,
#     "mergeable": "MERGEABLE"|"CONFLICTING"|"UNKNOWN"|...,
#     "review_decision": "APPROVED"|"CHANGES_REQUESTED"|"REVIEW_REQUIRED"|...,
#     "code_owner_bots": ["coderabbitai[bot]", "greptile-apps[bot]"],
#     "human_changes_requested": ["login", ...],
#     "stale_bot_changes_requested_count": N,
#     "unresolved_thread_count": N,
#     "primary_review_met": true|false,
#     "authorship": "mine"|"not_mine"|"unknown"
#   }
#
# `authorship` (issue #733): "mine" when the PR author == the authenticated user,
# "not_mine" when it is someone else (a confirmed foreign author blocks the merge
# via a `missing` entry unless --allow-nonauthor is passed), "unknown" when the
# author or viewer login could not be resolved (does not block here — see the
# guard note above). Read-only callers use it to separate collaborator PRs.
#
# `unresolved_thread_count` is the structured count behind the human-readable
# "N unresolved review thread(s)" entry in `missing` — orchestrators (e.g.
# /wrap Step 2.1 Branch B) should key the threads-only decision off this field
# (and `missing | length`) rather than string-matching the prose (#455 / #479).
#
# `primary_review_met` is meaningful only on the `cr` path: true when CodeRabbit
# OR CodeAnt has a valid (non-retracted) APPROVED review on current HEAD SHA —
# i.e. the "1 explicit CodeRabbit or CodeAnt APPROVED review" requirement from
# cr-merge-gate.md Step 1 is satisfied, independent of CI/threads/merge-state.
# `false` on the bugbot/greptile paths (not applicable). Consumers that only
# care "does this PR still need more review" (e.g. escalate-review.sh deciding
# whether to trigger a paid Greptile review) should key off this field rather
# than the overall `met`, which also folds in CI/threads/merge-state.
#
# Exit codes:
#   0 — gate met
#   1 — gate not met (JSON body includes .missing)
#   2 — usage error
#   3 — PR not found (or closed/merged)
#   4 — gh / network / jq error

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

# --------------------------------------------------------------------------
# Arg parsing
# --------------------------------------------------------------------------
PR_NUMBER=""
REVIEWER_OVERRIDE=""
# Authorship guard (issue #733): block a merge on a PR the authenticated user did
# not author. --allow-nonauthor suppresses the block only under an explicit
# per-PR user override. The `authorship` field is emitted regardless.
ALLOW_NONAUTHOR=false

print_usage() {
  awk 'NR == 1 { next } /^$/ { exit } { print }' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    --allow-nonauthor)
      ALLOW_NONAUTHOR=true
      shift
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
  # emit_json <met> <reviewer> <path> <missing_json_array> <head_sha> <ci_status_json> <merge_state> <mergeable> <review_decision> <code_owner_bots_json> <human_changes_json_array> <stale_bot_changes_requested_count_number> [unresolved_thread_count_number] [primary_review_met_bool]
  local met="$1" reviewer="$2" path="$3" missing="$4" head_sha="$5" ci_status="$6" merge_state="$7" mergeable="$8" review_decision="$9" code_owner_bots="${10}" human_changes="${11}" stale_bot_count="${12}" unresolved_thread_count="${13:-0}" primary_review_met="${14:-false}" authorship="${15:-unknown}"
  jq -cn \
    --argjson met "$met" \
    --arg reviewer "$reviewer" \
    --arg path "$path" \
    --argjson missing "$missing" \
    --arg head_sha "$head_sha" \
    --argjson ci_status "$ci_status" \
    --arg merge_state "$merge_state" \
    --arg mergeable "$mergeable" \
    --arg review_decision "$review_decision" \
    --argjson code_owner_bots "$code_owner_bots" \
    --argjson human_changes_requested "$human_changes" \
    --argjson stale_bot_changes_requested_count "$stale_bot_count" \
    --argjson unresolved_thread_count "$unresolved_thread_count" \
    --argjson primary_review_met "$primary_review_met" \
    --arg authorship "$authorship" \
    '{met: $met, reviewer: $reviewer, path: $path, missing: $missing, head_sha: $head_sha, ci_status: $ci_status, merge_state: $merge_state, mergeable: $mergeable, review_decision: $review_decision, code_owner_bots: $code_owner_bots, human_changes_requested: $human_changes_requested, stale_bot_changes_requested_count: $stale_bot_changes_requested_count, unresolved_thread_count: $unresolved_thread_count, primary_review_met: $primary_review_met, authorship: $authorship}'
}

emit_empty_ci() {
  echo '{"total":0,"passing":0,"failing":0,"in_progress":0,"blocking":[],"incomplete":[]}'
}

emit_empty_code_owner_bots() {
  echo '[]'
}

# --------------------------------------------------------------------------
# Fetch PR context
# --------------------------------------------------------------------------
OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
if [[ -z "$OWNER_REPO" ]]; then
  emit_json false unknown cr '["gh repo view failed — not in a git repo or no remote"]' "" "$(emit_empty_ci)" "" "" "" "$(emit_empty_code_owner_bots)" '[]' 0
  exit 4
fi
OWNER="${OWNER_REPO%/*}"
REPO="${OWNER_REPO#*/}"

PR_JSON=$(gh pr view "$PR_NUMBER" --json number,state,headRefOid,baseRefName,mergeStateStatus,mergeable,reviewDecision,author 2>/dev/null || true)
if [[ -z "$PR_JSON" ]]; then
  emit_json false unknown cr "[\"PR #$PR_NUMBER not found\"]" "" "$(emit_empty_ci)" "" "" "" "$(emit_empty_code_owner_bots)" '[]' 0
  exit 3
fi

PR_STATE=$(echo "$PR_JSON" | jq -r '.state // "UNKNOWN"')
HEAD_SHA=$(echo "$PR_JSON" | jq -r '.headRefOid // ""')
BASE_REF=$(echo "$PR_JSON" | jq -r '.baseRefName // ""')
MERGE_STATE=$(echo "$PR_JSON" | jq -r '.mergeStateStatus // ""')
MERGEABLE=$(echo "$PR_JSON" | jq -r '.mergeable // ""')
REVIEW_DECISION=$(echo "$PR_JSON" | jq -r '.reviewDecision // ""')
PR_AUTHOR=$(echo "$PR_JSON" | jq -r '.author.login // ""')

if [[ "$PR_STATE" != "OPEN" ]]; then
  emit_json false unknown cr "[\"PR #$PR_NUMBER is $PR_STATE — not open\"]" "$HEAD_SHA" "$(emit_empty_ci)" "$MERGE_STATE" "$MERGEABLE" "$REVIEW_DECISION" "$(emit_empty_code_owner_bots)" '[]' 0
  exit 3
fi

if [[ -z "$HEAD_SHA" ]]; then
  emit_json false unknown cr '["could not determine HEAD SHA"]' "" "$(emit_empty_ci)" "$MERGE_STATE" "$MERGEABLE" "$REVIEW_DECISION" "$(emit_empty_code_owner_bots)" '[]' 0
  exit 4
fi

# Fetch last commit timestamp for Greptile freshness gate (issue #723) and the
# stale-approval guard (issue #836). Used in greptile) to confirm a 👍 issue
# comment is post-push; used in cr) and bugbot) to reject approvals whose
# submitted_at predates this committer date (force-push retargeting).
# Non-fatal: an empty result disables both filters (comments/approvals accepted
# regardless of age), which is preferable to silently blocking a clean review.
LAST_COMMIT_TS=$(gh api "repos/$OWNER/$REPO/git/commits/$HEAD_SHA" 2>/dev/null | jq -r '.committer.date // ""' 2>/dev/null || echo "")

# --------------------------------------------------------------------------
# Fetch data once, reuse everywhere
# --------------------------------------------------------------------------
# Fail closed on gh api errors — inline checks in the MAIN script context, not
# inside a helper function called via $(), because exit inside $() only kills
# the subshell and the main script continues with garbage data.
die_api() {
  emit_json false "${REVIEWER_OVERRIDE:-unknown}" "unknown" "[\"gh api failed: $1\"]" "$HEAD_SHA" "$(emit_empty_ci)" "$MERGE_STATE" "$MERGEABLE" "$REVIEW_DECISION" "$(emit_empty_code_owner_bots)" '[]' 0
  exit 4
}

# Same fail-closed shape as die_api, for failures that are ours rather than
# GitHub's — blaming "gh api failed" for a missing local helper sends whoever
# reads `missing` after the wrong problem.
die_local() {
  emit_json false "${REVIEWER_OVERRIDE:-unknown}" "unknown" "[\"$1\"]" "$HEAD_SHA" "$(emit_empty_ci)" "$MERGE_STATE" "$MERGEABLE" "$REVIEW_DECISION" "$(emit_empty_code_owner_bots)" '[]' 0
  exit 4
}

if ! CHECK_RUNS_RAW=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs?per_page=100" 2>/dev/null); then
  die_api "check-runs"
fi
# `gh --paginate` concatenates per-page objects; flatten AND dedup (newest check
# suite wins per (app, check name) — see check-runs-dedup.sh), then re-wrap as a
# single {check_runs: [...]} object so downstream `.check_runs[]` jq queries work.
#
# The CI pass/fail verdict is NOT classified here — that stays delegated to
# ci-status.sh below, which dedups its own input too (the transform is idempotent,
# so feeding it an already-deduped list changes nothing). Deduping at the fetch is
# for this script's OTHER reader of the raw list: the CodeAnt supplemental gate
# further down scans for a *successful* CodeAnt check-run. Given a stale success
# and a newer failure of the same check on one SHA, the undeduped list would hand
# it the superseded success and pass the gate — the same bug as issue #675, but
# failing toward merge instead of away from it.
CHECK_RUNS_DEDUP="$(dirname "$0")/check-runs-dedup.sh"
if [[ ! -x "$CHECK_RUNS_DEDUP" ]]; then
  die_local "check-runs-dedup.sh not found or not executable at $CHECK_RUNS_DEDUP"
fi
CHECK_RUNS_JSON=$(printf '%s\n' "$CHECK_RUNS_RAW" | "$CHECK_RUNS_DEDUP" 2>/dev/null | jq -c '{check_runs: .}' 2>/dev/null || true)
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

if ! REVIEWS_RAW=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews?per_page=100" 2>/dev/null); then
  die_api "reviews"
fi
REVIEWS_JSON=$(echo "$REVIEWS_RAW" | jq -s 'add // []')
if [[ -z "$REVIEWS_JSON" ]] || ! echo "$REVIEWS_JSON" | jq -e . >/dev/null 2>&1; then
  die_api "reviews parse"
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

# Runtime CODEOWNERS detection. Branch protection is repo-specific, so only
# enforce reviewDecision against bot code-owner approvals when this repo actually
# names CR or Greptile as a code owner.
CODEOWNERS_TEXT=""
for codeowners_path in CODEOWNERS .github/CODEOWNERS docs/CODEOWNERS; do
  if [[ -n "$BASE_REF" ]]; then
    CODEOWNERS_JSON=$(gh api --method GET "repos/$OWNER/$REPO/contents/$codeowners_path" -f ref="$BASE_REF" 2>/dev/null || true)
  else
    CODEOWNERS_JSON=$(gh api --method GET "repos/$OWNER/$REPO/contents/$codeowners_path" 2>/dev/null || true)
  fi
  if [[ -n "$CODEOWNERS_JSON" ]]; then
    CODEOWNERS_TEXT=$(echo "$CODEOWNERS_JSON" | jq -r '.content // ""' | base64 --decode 2>/dev/null || true)
    if [[ -n "$CODEOWNERS_TEXT" ]]; then
      break
    fi
  fi
done

CODE_OWNER_BOTS=$(printf '%s\n' "$CODEOWNERS_TEXT" | jq -R -s -c '
  split("\n")
  | map(select(test("^\\s*#") | not))
  | join("\n")
  | ascii_downcase as $text
  | [
      if ($text | test("(^|[^a-z0-9_-])@?coderabbitai([^a-z0-9_-]|$)")) then "coderabbitai[bot]" else empty end,
      if ($text | test("(^|[^a-z0-9_-])@?greptile-apps([^a-z0-9_-]|$)")) then "greptile-apps[bot]" else empty end,
      if ($text | test("(^|[^a-z0-9_-])@?codeant-ai([^a-z0-9_-]|$)")) then "codeant-ai[bot]" else empty end
    ]')

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
    # Scoped to the active repo (issue #638) — reading the flat `.prs[$pr]`
    # here would pick up a same-numbered PR from whichever other repo last
    # wrote, and hand this gate the wrong reviewer.
    from_state=$("$(cd "$(dirname "$0")" && pwd)/session-state.sh" \
      --get ".prs[\"$PR_NUMBER\"].reviewer // \"\"" 2>/dev/null || echo "")
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
  # Only return bugbot when cursor[bot] is the sole AI reviewer — if coderabbitai[bot]
  # or codeant-ai[bot] is present, use the CR path (BugBot auto-triggers on every push).
  # CR→BugBot escalation is tracked via session-state, not the live scan.
  if echo "$authors" | grep -q '^cursor\[bot\]$' \
    && ! echo "$authors" | grep -q '^coderabbitai\[bot\]$' \
    && ! echo "$authors" | grep -q '^codeant-ai\[bot\]$'; then
    echo "bugbot"; return
  fi
  echo "cr"
}

REVIEWER=$(resolve_reviewer)

# --------------------------------------------------------------------------
# Gate evaluation — collect MISSING reasons; determinism comes from jq data paths.
# --------------------------------------------------------------------------
MISSING=()

# Authorship guard (issue #733) — the `authorship` field is emitted on every
# result so read-only callers (/status) can display and separate collaborator
# PRs. A merge is a write, and /wrap + /merge run this gate before `gh pr merge`,
# so a merge is BLOCKED on a CONFIRMED foreign author. "unknown" (author or
# viewer unresolvable) does NOT block here — the strict fail-closed lives at the
# enrolment gate (polling-state-gate --ensure-session) and pr-authorship.sh, so
# a transient `gh api user` blip cannot wedge merges on the user's own PRs.
VIEWER_LOGIN="$(gh api user --jq '.login' 2>/dev/null || true)"
AUTHORSHIP="unknown"
if [[ -n "$VIEWER_LOGIN" && -n "$PR_AUTHOR" ]]; then
  if [[ "$PR_AUTHOR" == "$VIEWER_LOGIN" ]]; then AUTHORSHIP="mine"; else AUTHORSHIP="not_mine"; fi
fi
if [[ "$ALLOW_NONAUTHOR" != true && "$AUTHORSHIP" == "not_mine" ]]; then
  MISSING+=("PR #$PR_NUMBER is authored by $PR_AUTHOR (not you, $VIEWER_LOGIN) — automated merge is blocked by the authorship guard (.claude/rules/safety.md); pass --allow-nonauthor only under an explicit per-PR user override")
fi

# BEHIND / merge metadata (#273, Step 1d in cr-merge-gate.md) — applies to all paths.
if [[ "$MERGE_STATE" == "BEHIND" ]]; then
  MISSING+=("branch is BEHIND base — rebase + force-push before merging")
fi
if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
  MISSING+=("mergeable is CONFLICTING — resolve merge conflicts (rebase/repair) before merging")
fi
if [[ "$MERGE_STATE" == "DIRTY" ]]; then
  MISSING+=("mergeStateStatus is DIRTY — merge commit cannot be computed; investigate or rebase via /fixpr")
fi
if [[ "$MERGE_STATE" == "UNKNOWN" ]]; then
  MISSING+=("mergeStateStatus is UNKNOWN — GitHub still computing mergeability; wait and re-check")
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

# Human-authored CHANGES_REQUESTED on current HEAD (#452 / cr-merge-gate.md) — never auto-dismissable.
# Include DISMISSED so a dismissed CHANGES_REQUESTED is superseded by the newer DISMISSED state.
HUMAN_CHANGES_ON_HEAD_JSON=$(echo "$REVIEWS_JSON" | jq -c --arg sha "$HEAD_SHA" '
  [.[]?
    | select((.user.type // "") != "Bot")
    | select(.commit_id == $sha)
    | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")
  ]
  | group_by(.user.login)
  | map(
      (sort_by(.submitted_at) | last) as $latest
      | select($latest.state == "CHANGES_REQUESTED")
      | $latest.user.login
    )
') || HUMAN_CHANGES_ON_HEAD_JSON='[]'
if [[ -z "$HUMAN_CHANGES_ON_HEAD_JSON" ]]; then HUMAN_CHANGES_ON_HEAD_JSON='[]'; fi
if [[ "$(echo "$HUMAN_CHANGES_ON_HEAD_JSON" | jq 'length')" -gt 0 ]]; then
  HUMAN_LIST=$(echo "$HUMAN_CHANGES_ON_HEAD_JSON" | jq -r 'join(", ")')
  MISSING+=("human reviewer(s) requested changes on HEAD ${HEAD_SHA:0:7}: $HUMAN_LIST — cannot auto-dismiss; withdraw or supersede before merge")
fi

# Also catch human CHANGES_REQUESTED on an older SHA that still drives reviewDecision.
# GitHub does NOT auto-dismiss human reviews on push; a stale human review on an old
# SHA keeps reviewDecision == "CHANGES_REQUESTED" even when no human review is on HEAD.
if [[ "$(echo "$HUMAN_CHANGES_ON_HEAD_JSON" | jq 'length')" -eq 0 && \
      -n "$REVIEW_DECISION" && "$REVIEW_DECISION" == "CHANGES_REQUESTED" ]]; then
  STALE_HUMAN_JSON=$(echo "$REVIEWS_JSON" | jq -c --arg sha "$HEAD_SHA" '
    # Exclude reviewers whose latest HEAD review is a decisive state (APPROVED/CHANGES_REQUESTED/
    # DISMISSED) — those are handled by the HEAD block. COMMENTED on HEAD does not supersede
    # an older CHANGES_REQUESTED, so COMMENTED-only HEAD reviewers remain eligible here.
    ([.[]? | select((.user.type // "") != "Bot") | select(.commit_id == $sha)
      | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")
      | .user.login] | unique) as $head_reviewers
    | [.[]?
      | select((.user.type // "") != "Bot")
      | select(.commit_id != $sha)
      | select(.user.login | IN($head_reviewers[]) | not)
      | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")
    ]
    | group_by(.user.login)
    | map(
        (sort_by(.submitted_at) | last) as $latest
        | select($latest.state == "CHANGES_REQUESTED")
        | {login: $latest.user.login, sha: $latest.commit_id[0:7]}
      )
  ') || STALE_HUMAN_JSON='[]'
  if [[ -z "$STALE_HUMAN_JSON" ]]; then STALE_HUMAN_JSON='[]'; fi
  if [[ "$(echo "$STALE_HUMAN_JSON" | jq 'length')" -gt 0 ]]; then
    STALE_HUMAN_LIST=$(echo "$STALE_HUMAN_JSON" | jq -r 'map("\(.login) (on \(.sha))") | join(", ")')
    MISSING+=("reviewDecision is CHANGES_REQUESTED from a human review on an older SHA: $STALE_HUMAN_LIST — ask the reviewer to re-review or dismiss their old review before merge")
    HUMAN_CHANGES_ON_HEAD_JSON=$(echo "$STALE_HUMAN_JSON" | jq -c '[.[].login]')
  fi
fi

CR_IS_CODE_OWNER=$(echo "$CODE_OWNER_BOTS" | jq -e 'index("coderabbitai[bot]") != null' >/dev/null 2>&1 && echo true || echo false)
GREPTILE_IS_CODE_OWNER=$(echo "$CODE_OWNER_BOTS" | jq -e 'index("greptile-apps[bot]") != null' >/dev/null 2>&1 && echo true || echo false)
CODEANT_IS_CODE_OWNER=$(echo "$CODE_OWNER_BOTS" | jq -e 'index("codeant-ai[bot]") != null' >/dev/null 2>&1 && echo true || echo false)

if [[ -n "$REVIEW_DECISION" && "$REVIEW_DECISION" != "APPROVED" ]]; then
  if [[ "$CR_IS_CODE_OWNER" == true ]]; then
    MISSING+=("branch protection reviewDecision is $REVIEW_DECISION, not APPROVED, with CodeRabbit in CODEOWNERS — if the prior CR approval was dismissed as stale, trigger @coderabbitai full review")
  fi
  if [[ "$GREPTILE_IS_CODE_OWNER" == true ]]; then
    MISSING+=("branch protection reviewDecision is $REVIEW_DECISION, not APPROVED, with Greptile in CODEOWNERS — if the prior Greptile approval was dismissed as stale, trigger @greptileai")
  fi
  if [[ "$CODEANT_IS_CODE_OWNER" == true ]]; then
    MISSING+=("branch protection reviewDecision is $REVIEW_DECISION, not APPROVED, with CodeAnt in CODEOWNERS — if the prior CodeAnt approval was dismissed as stale, trigger @codeant-ai review")
  fi
fi

# Timestamp normaliser — used by all reviewer paths below (issue #836, BugBot round 5).
# GitHub can return mixed ISO-8601 UTC forms ("…Z" and "…+00:00"). Bash [[ < ]] is
# purely lexicographic; Z (ASCII 90) > + (ASCII 43), so "…Z" > "…+00:00" even for
# equal instants, breaking stale-approval comparisons. Strip the timezone suffix to
# produce a bare "YYYY-MM-DDTHH:MM:SS" string that sorts correctly for UTC timestamps.
norm_ts() {
  local t="${1%Z}"       # strip trailing Z
  echo "${t%+00:00}"     # strip trailing +00:00 (all GitHub timestamps are UTC)
}

# Path-specific checks.
# Default false — only the cr) branch below computes a meaningful value.
PRIMARY_REVIEW_MET=false
case "$REVIEWER" in
  cr)

    # Require 1 explicit CodeRabbit APPROVED on HEAD (SHA freshness in the jq filter).
    # Retraction: CHANGES_REQUESTED newer than APPROVED on same SHA invalidates approval.
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

    LATEST_CA_APPROVED_AT=$(echo "$REVIEWS_JSON" | jq -r --arg sha "$HEAD_SHA" '
      [.[]?
        | select(.user.login == "codeant-ai[bot]" and .commit_id == $sha and .state == "APPROVED")
        | .submitted_at]
      | sort | last // ""')
    LATEST_CA_CHANGES_REQUESTED_AT=$(echo "$REVIEWS_JSON" | jq -r --arg sha "$HEAD_SHA" '
      [.[]?
        | select(.user.login == "codeant-ai[bot]" and .commit_id == $sha and .state == "CHANGES_REQUESTED")
        | .submitted_at]
      | sort | last // ""')
    APPROVED_CA_ON_HEAD=$(echo "$REVIEWS_JSON" | jq --arg sha "$HEAD_SHA" '
      [.[]? | select(.user.login == "codeant-ai[bot]" and .commit_id == $sha and .state == "APPROVED")]
      | length')
    TOTAL_CA_ON_HEAD=$(echo "$REVIEWS_JSON" | jq --arg sha "$HEAD_SHA" '
      [.[]? | select(.user.login == "codeant-ai[bot]" and .commit_id == $sha)]
      | length')

    # Retraction: later CHANGES_REQUESTED on same SHA invalidates APPROVED (ISO timestamps).
    CR_RETRACTED=false
    if [[ "$APPROVED_CR_ON_HEAD" -ge 1 && -n "$LATEST_CR_CHANGES_REQUESTED_AT" && -n "$LATEST_CR_APPROVED_AT" ]]; then
      if [[ "$(norm_ts "$LATEST_CR_CHANGES_REQUESTED_AT")" > "$(norm_ts "$LATEST_CR_APPROVED_AT")" ]]; then
        CR_RETRACTED=true
      fi
    fi
    CA_RETRACTED=false
    if [[ "$APPROVED_CA_ON_HEAD" -ge 1 && -n "$LATEST_CA_CHANGES_REQUESTED_AT" && -n "$LATEST_CA_APPROVED_AT" ]]; then
      if [[ "$(norm_ts "$LATEST_CA_CHANGES_REQUESTED_AT")" > "$(norm_ts "$LATEST_CA_APPROVED_AT")" ]]; then
        CA_RETRACTED=true
      fi
    fi

    # Stale-approval guard (issue #836): GitHub retargets commit_id on force-push
    # but does NOT update submitted_at. An approval whose submitted_at predates
    # the HEAD commit's committer date was submitted before the current commit
    # and must not count even when commit_id matches. Equal timestamps are
    # accepted (submitted_at >= LAST_COMMIT_TS). Use norm_ts for comparisons
    # to handle mixed Z/+00:00 UTC suffixes (issue #836, BugBot round 5).
    #
    # Fail-closed (issue #836): when LAST_COMMIT_TS is empty (HEAD timestamp API
    # failure) we CANNOT verify freshness, so qualifying approvals do NOT satisfy
    # the gate. Callers poll every ~60 s, so a transient API failure self-heals
    # on the next cycle without wedging a merge indefinitely.
    CR_APPROVAL_STALE=false
    CR_APPROVAL_FRESHNESS_UNKNOWN=false
    # Separate flag for missing submitted_at (distinct from LAST_COMMIT_TS missing):
    # the approval's timestamp is absent — different cause, different user message.
    CR_APPROVAL_SUBMITTED_AT_MISSING=false
    if [[ "$APPROVED_CR_ON_HEAD" -ge 1 && "$CR_RETRACTED" == false ]]; then
      if [[ -z "$LAST_COMMIT_TS" ]]; then
        CR_APPROVAL_FRESHNESS_UNKNOWN=true
      elif [[ -z "$LATEST_CR_APPROVED_AT" ]]; then
        # submitted_at is missing from the approval itself (not a transient API
        # failure) — cannot verify freshness (fail-closed, issue #836).
        CR_APPROVAL_SUBMITTED_AT_MISSING=true
      elif [[ "$(norm_ts "$LATEST_CR_APPROVED_AT")" < "$(norm_ts "$LAST_COMMIT_TS")" ]]; then
        CR_APPROVAL_STALE=true
      fi
    fi
    CA_APPROVAL_STALE=false
    CA_APPROVAL_FRESHNESS_UNKNOWN=false
    CA_APPROVAL_SUBMITTED_AT_MISSING=false
    if [[ "$APPROVED_CA_ON_HEAD" -ge 1 && "$CA_RETRACTED" == false ]]; then
      if [[ -z "$LAST_COMMIT_TS" ]]; then
        CA_APPROVAL_FRESHNESS_UNKNOWN=true
      elif [[ -z "$LATEST_CA_APPROVED_AT" ]]; then
        CA_APPROVAL_SUBMITTED_AT_MISSING=true
      elif [[ "$(norm_ts "$LATEST_CA_APPROVED_AT")" < "$(norm_ts "$LAST_COMMIT_TS")" ]]; then
        CA_APPROVAL_STALE=true
      fi
    fi

    CR_APPROVAL_VALID=false
    if [[ "$APPROVED_CR_ON_HEAD" -ge 1 && "$CR_RETRACTED" == false \
          && "$CR_APPROVAL_STALE" == false && "$CR_APPROVAL_FRESHNESS_UNKNOWN" == false \
          && "$CR_APPROVAL_SUBMITTED_AT_MISSING" == false ]]; then
      CR_APPROVAL_VALID=true
    fi
    CA_APPROVAL_VALID=false
    if [[ "$APPROVED_CA_ON_HEAD" -ge 1 && "$CA_RETRACTED" == false \
          && "$CA_APPROVAL_STALE" == false && "$CA_APPROVAL_FRESHNESS_UNKNOWN" == false \
          && "$CA_APPROVAL_SUBMITTED_AT_MISSING" == false ]]; then
      CA_APPROVAL_VALID=true
    fi

    PRIMARY_REVIEW_MET=false
    if [[ "$CR_APPROVAL_VALID" == true || "$CA_APPROVAL_VALID" == true ]]; then
      PRIMARY_REVIEW_MET=true
    fi

    # Track whether the CA stale message was emitted here, to prevent the
    # supplemental CodeAnt gate below from adding a duplicate entry.
    CA_STALE_MISSING_EMITTED=false
    if [[ "$PRIMARY_REVIEW_MET" != true ]]; then
      if [[ "$CR_RETRACTED" == true && "$CA_APPROVAL_VALID" != true ]]; then
        MISSING+=("CodeRabbit approval on HEAD ${HEAD_SHA:0:7} retracted by later CHANGES_REQUESTED — fix and re-trigger @coderabbitai full review")
      fi
      if [[ "$CA_RETRACTED" == true && "$CR_APPROVAL_VALID" != true ]]; then
        MISSING+=("CodeAnt approval on HEAD ${HEAD_SHA:0:7} retracted by later CHANGES_REQUESTED — fix and re-trigger @codeant-ai review")
      fi
      if [[ "$CR_APPROVAL_STALE" == true && "$CA_APPROVAL_VALID" != true ]]; then
        MISSING+=("CodeRabbit approval on HEAD ${HEAD_SHA:0:7} predates the HEAD commit (force-push retargeting) — re-review required; trigger @coderabbitai full review")
      fi
      if [[ "$CA_APPROVAL_STALE" == true && "$CR_APPROVAL_VALID" != true ]]; then
        MISSING+=("CodeAnt approval on HEAD ${HEAD_SHA:0:7} predates the HEAD commit (force-push retargeting) — re-review required; trigger @codeant-ai review")
        CA_STALE_MISSING_EMITTED=true
      fi
      if [[ "$CR_APPROVAL_FRESHNESS_UNKNOWN" == true || "$CA_APPROVAL_FRESHNESS_UNKNOWN" == true ]]; then
        # Fail-closed (issue #836): HEAD commit timestamp unavailable — cannot
        # verify whether the approval predates the current commit. Callers retry
        # every ~60 s so this self-heals on the next cycle.
        MISSING+=("cannot verify approval freshness — HEAD commit timestamp unavailable; retrying next cycle")
      fi
      if [[ "$CR_APPROVAL_SUBMITTED_AT_MISSING" == true || "$CA_APPROVAL_SUBMITTED_AT_MISSING" == true ]]; then
        # submitted_at is absent from the approval itself (not a transient API
        # failure) — distinct message from the LAST_COMMIT_TS-unavailable case above.
        MISSING+=("cannot verify approval freshness — submitted_at missing from approval (fail-closed, issue #836)")
      fi
      if [[ "$CR_RETRACTED" != true && "$CA_RETRACTED" != true \
            && "$CR_APPROVAL_STALE" != true && "$CA_APPROVAL_STALE" != true \
            && "$CR_APPROVAL_FRESHNESS_UNKNOWN" != true && "$CA_APPROVAL_FRESHNESS_UNKNOWN" != true \
            && "$CR_APPROVAL_SUBMITTED_AT_MISSING" != true && "$CA_APPROVAL_SUBMITTED_AT_MISSING" != true ]]; then
        MISSING+=("need 1 explicit CodeRabbit or CodeAnt APPROVED review on HEAD ${HEAD_SHA:0:7} (have $TOTAL_CR_ON_HEAD CodeRabbit, $TOTAL_CA_ON_HEAD CodeAnt review(s) on this SHA)")
      fi
    fi

    # CodeAnt supplemental gate (#367 / CodeRabbit review): only when CodeAnt left
    # artifacts on this SHA — require APPROVED or successful CodeAnt check-run, and
    # treat CHANGES_REQUESTED as blocking only if it is newer than the latest clean signal.
    CODEANT_INLINE_ON_HEAD=$(echo "$PR_COMMENTS_JSON" | jq --arg sha "$HEAD_SHA" '
      [.[]? | select(.user.login == "codeant-ai[bot]" and ((.commit_id // .original_commit_id // "") == $sha))] | length')
    CODEANT_CONVO_ON_HEAD=$(echo "$ISSUE_COMMENTS_JSON" | jq -r --arg sha "$HEAD_SHA" '
      def short: $sha[0:7];
      [.[]?
        | select(.user.login == "codeant-ai[bot]")
        | .body // ""
        | select((contains($sha)) or (contains(short)))]
      | length')
    CODEANT_CHECK_PRESENT=false
    if echo "$CHECK_RUNS_JSON" | jq -e '
      .check_runs[]?
      | select(
          ((.name // "") | test("codeant"; "i"))
          or ((.app.slug // "") | test("codeant"; "i"))
          or ((.app.name // "") | test("codeant"; "i"))
        )
      ' >/dev/null 2>&1; then
      CODEANT_CHECK_PRESENT=true
    fi

    CODEANT_PARTICIPATED=false
    if [[ "$TOTAL_CA_ON_HEAD" -gt 0 || "$CODEANT_INLINE_ON_HEAD" -gt 0 || "$CODEANT_CONVO_ON_HEAD" -gt 0 || "$CODEANT_CHECK_PRESENT" == true ]]; then
      CODEANT_PARTICIPATED=true
    fi

    if [[ "$CODEANT_PARTICIPATED" == true ]]; then
      LATEST_CA_CHECK_OK_AT=$(echo "$CHECK_RUNS_JSON" | jq -r '
        [.check_runs[]?
          | select((.status // "") == "completed" and (.conclusion // "") == "success")
          | select(
              ((.name // "") | test("codeant"; "i"))
              or ((.app.slug // "") | test("codeant"; "i"))
              or ((.app.name // "") | test("codeant"; "i"))
            )
          | (.completed_at // .started_at // "")]
        | sort | last // ""')
      # Stale-approval guard (issue #836): check-run completed_at must postdate
      # the HEAD committer date, mirroring the APPROVED review guard above.
      # Fail-closed: when LAST_COMMIT_TS is empty we cannot verify freshness,
      # so the check-run does not satisfy the supplemental gate.
      CODEANT_CHECK_OK=false
      CODEANT_CHECK_FRESHNESS_UNKNOWN=false
      CODEANT_CHECK_STALE=false
      if [[ -n "$LATEST_CA_CHECK_OK_AT" ]]; then
        if [[ -z "$LAST_COMMIT_TS" ]]; then
          # Cannot verify whether the check-run predates the current commit.
          CODEANT_CHECK_FRESHNESS_UNKNOWN=true
        elif [[ ! "$(norm_ts "$LATEST_CA_CHECK_OK_AT")" < "$(norm_ts "$LAST_COMMIT_TS")" ]]; then
          CODEANT_CHECK_OK=true
        else
          # check-run completed before the HEAD commit — stale via force-push
          # retargeting. A stale check-run must not satisfy the gate, and the
          # error message must say "stale", not "no successful check-run".
          CODEANT_CHECK_STALE=true
        fi
      fi

      # LATEST_CA_CLEAN_AT: most-recent FRESH clean signal — only signals that have
      # passed the freshness guard (issue #836) qualify. Stale or unverifiable signals
      # must not suppress a CHANGES_REQUESTED that postdates the last genuine clean pass.
      LATEST_CA_CLEAN_AT=""
      if [[ "$CA_APPROVAL_VALID" == true ]]; then
        LATEST_CA_CLEAN_AT="$LATEST_CA_APPROVED_AT"
      fi
      if [[ "$CODEANT_CHECK_OK" == true ]]; then
        if [[ -z "$LATEST_CA_CLEAN_AT" || "$(norm_ts "$LATEST_CA_CHECK_OK_AT")" > "$(norm_ts "$LATEST_CA_CLEAN_AT")" ]]; then
          LATEST_CA_CLEAN_AT="$LATEST_CA_CHECK_OK_AT"
        fi
      fi

      # Stale CHANGES_REQUESTED guard (issue #836): GitHub retargets commit_id on
      # force-push, so a pre-push CHANGES_REQUESTED can have commit_id==HEAD while
      # its submitted_at predates the current commit. dismiss-stale-bot-changes.sh
      # only handles wrong commit_id, not retargeted timestamps; this freshness
      # check is needed. If LAST_COMMIT_TS is unavailable, treat as blocking (fail-closed).
      CA_CHANGES_BLOCKING=false
      if [[ -n "$LATEST_CA_CHANGES_REQUESTED_AT" ]]; then
        if [[ -z "$LAST_COMMIT_TS" || ! "$(norm_ts "$LATEST_CA_CHANGES_REQUESTED_AT")" < "$(norm_ts "$LAST_COMMIT_TS")" ]]; then
          CA_CHANGES_BLOCKING=true
        fi
      fi

      if [[ "$CA_CHANGES_BLOCKING" == true && ( -z "$LATEST_CA_CLEAN_AT" || "$(norm_ts "$LATEST_CA_CHANGES_REQUESTED_AT")" > "$(norm_ts "$LATEST_CA_CLEAN_AT")" ) ]]; then
        MISSING+=("CodeAnt CHANGES_REQUESTED on HEAD ${HEAD_SHA:0:7} is newer than the latest CodeAnt clean signal — address findings or wait for APPROVED / successful CodeAnt check-run")
      elif [[ "$CA_APPROVAL_VALID" != true && "$CODEANT_CHECK_OK" != true ]]; then
        if [[ "$CA_APPROVAL_STALE" == true && "$CA_STALE_MISSING_EMITTED" != true ]]; then
          # Stale-approval guard (issue #836): CodeAnt's approval is retargeted;
          # emit a stale-specific message so callers know to re-trigger rather than
          # interpret this as a complete absence of CodeAnt review.
          # Guard: CA_STALE_MISSING_EMITTED prevents a duplicate entry when the
          # primary review block already reported this condition above.
          MISSING+=("CodeAnt approval on HEAD ${HEAD_SHA:0:7} predates the HEAD commit (force-push retargeting) — trigger @codeant-ai review")
        elif [[ "$CA_APPROVAL_FRESHNESS_UNKNOWN" == true ]]; then
          if [[ "$PRIMARY_REVIEW_MET" == true ]]; then
            # CR already satisfies the primary gate, so the primary block was skipped
            # (it only runs when PRIMARY_REVIEW_MET=false) and did NOT emit the
            # freshness-unknown message. The supplemental gate still requires a
            # verified CodeAnt clean signal when CodeAnt participated — emit here.
            MISSING+=("cannot verify CodeAnt approval freshness — HEAD commit timestamp unavailable; retrying next cycle")
          fi
          # else: PRIMARY_REVIEW_MET=false — primary block already emitted the message.
        elif [[ "$CA_APPROVAL_SUBMITTED_AT_MISSING" == true ]]; then
          if [[ "$PRIMARY_REVIEW_MET" == true ]]; then
            # Same rationale as FRESHNESS_UNKNOWN case above — primary block skipped.
            # Distinct message: the missing timestamp is on the approval, not LAST_COMMIT_TS.
            MISSING+=("cannot verify CodeAnt approval freshness — submitted_at missing from approval (fail-closed, issue #836)")
          fi
          # else: PRIMARY_REVIEW_MET=false — primary block already emitted the message.
        elif [[ "$CODEANT_CHECK_FRESHNESS_UNKNOWN" == true ]]; then
          # A successful CodeAnt check-run exists but its freshness cannot be verified
          # because LAST_COMMIT_TS is unavailable. Emit a distinct message so callers
          # know a check-run IS present — the blocker is freshness, not absence of review.
          MISSING+=("cannot verify CodeAnt check-run freshness — HEAD commit timestamp unavailable; retrying next cycle")
        elif [[ "$CODEANT_CHECK_STALE" == true ]]; then
          # A successful CodeAnt check-run exists but it predates the HEAD commit —
          # report stale, not absent, so callers know to wait for a re-check.
          MISSING+=("CodeAnt check-run on HEAD ${HEAD_SHA:0:7} predates the HEAD commit (force-push retargeting) — wait for CodeAnt re-check or trigger @codeant-ai review")
        elif [[ "$CA_APPROVAL_STALE" != true ]]; then
          # None of the freshness/stale conditions apply — emit the generic "no review"
          # message. The CA_APPROVAL_STALE guard prevents emitting this alongside the
          # stale message when CA_STALE_MISSING_EMITTED was already set by the primary block.
          MISSING+=("CodeAnt participated on HEAD ${HEAD_SHA:0:7} but no explicit APPROVED review and no successful CodeAnt check-run (have $TOTAL_CA_ON_HEAD CodeAnt review(s) on this SHA) — wait or comment @codeant-ai review")
        fi
      fi
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
        BB_SUBMITTED_AT=$(echo "$LATEST_BB" | jq -r '.submitted_at // ""')
        # Stale-approval guard (issue #836): same retargeting risk as CR/CodeAnt —
        # BugBot review commit_id can be advanced by GitHub on force-push while
        # submitted_at stays at the pre-push time.
        # Fail-closed: when LAST_COMMIT_TS is empty we cannot verify freshness,
        # so the review does not satisfy the gate (callers poll every ~60 s).
        if [[ -z "$LAST_COMMIT_TS" ]]; then
          MISSING+=("cannot verify BugBot review freshness — HEAD commit timestamp unavailable; retrying next cycle")
        elif [[ -z "$BB_SUBMITTED_AT" ]]; then
          # submitted_at is missing — cannot verify freshness without a timestamp
          # to compare against; treat as unknown (fail-closed, issue #836).
          MISSING+=("cannot verify BugBot review freshness — submitted_at unavailable; retrying next cycle")
        elif [[ "$(norm_ts "$BB_SUBMITTED_AT")" < "$(norm_ts "$LAST_COMMIT_TS")" ]]; then
          MISSING+=("BugBot review on HEAD ${HEAD_SHA:0:7} predates the HEAD commit (force-push retargeting) — re-review required; post @cursor review")
        else
          BB_STATE=$(echo "$LATEST_BB" | jq -r '.state // ""')
          # Always check for inline findings — BugBot can post inline diff comments
          # without a review body, so gating on body length would miss them.
          # Filter by original_commit_id == sha to exclude stale comments GitHub
          # "moves" to the new HEAD when commit_id advances but the diff line persists.
          INLINE_BB=$(echo "$PR_COMMENTS_JSON" | jq --arg sha "$HEAD_SHA" '
            [.[]? | select(.user.login == "cursor[bot]" and .commit_id == $sha and (.original_commit_id // .commit_id) == $sha)] | length')
          if [[ "$BB_STATE" == "CHANGES_REQUESTED" ]] || [[ "$INLINE_BB" -gt 0 ]]; then
            MISSING+=("latest BugBot review on HEAD has findings ($INLINE_BB inline)")
          fi
        fi
      fi
    fi
    ;;

  greptile)
    # Severity-gated. Greptile-specific count handling is intentionally NOT here —
    # the universal unresolved-thread gate above already reports the count for any
    # unresolved thread. This path adds severity context (P0 vs P1/P2) only.
    #
    # Greptile posts via issue comments (not formal PR review objects). Detection
    # (issue #723 — observed live on PR #721):
    #   Clean pass: latest fresh greptile-apps[bot] issue comment with 👍 (+1)
    #     reaction AND zero greptile-apps[bot] inline diff comments on the PR.
    #   Freshness: comment.created_at > LAST_COMMIT_TS (mirrors the BugBot
    #     push-timestamp lesson — repo memory feedback_bugbot_commit_id_stale).
    #   Formal review objects (pulls/{N}/reviews) are kept as supplemental signal.

    # Fresh Greptile inline diff comments (post-push only — mirrors the BugBot
    # push-timestamp lesson, feedback_bugbot_commit_id_stale). Stale inline comments
    # from a prior push must NOT count: without this freshness gate, the "no review
    # yet" guard would skip when stale inline comments exist, and Path B would then
    # pass cleanly on an empty review body (no fresh Greptile signal on the new HEAD).
    # G_INLINE_BODIES in Path B is anchored separately to G_ANCHOR_TS.
    G_INLINE_COUNT=$(echo "$PR_COMMENTS_JSON" | jq --arg after "${LAST_COMMIT_TS:-}" \
      '[.[]? | select(.user.login == "greptile-apps[bot]")
              | select(if $after == "" then true else .created_at > $after end)] | length')

    # Latest FRESH Greptile issue comment (created OR updated after the last push).
    # Greptile edits its summary comment in-place on re-review rather than posting a
    # new one (observed on PR #734 — rebased + force-pushed; re-review updated the
    # existing summary comment at updated_at 03:05:28Z after the 02:50:10Z push while
    # created_at stayed at the original post time). Accept the comment as fresh when
    # either timestamp is post-push (issue #748).
    LATEST_G_COMMENT=$(echo "$ISSUE_COMMENTS_JSON" | jq -c --arg after "${LAST_COMMIT_TS:-}" '
      [.[]?
        | select(.user.login == "greptile-apps[bot]")
        | select(if $after == "" then true else (.created_at > $after or .updated_at > $after) end)]
      | sort_by(.created_at) | last // empty')

    # Latest Greptile formal review (belt-and-suspenders supplemental signal).
    LATEST_G=$(echo "$REVIEWS_JSON" | jq -c '
      [.[]? | select(.user.login == "greptile-apps[bot]")]
      | sort_by(.submitted_at) | last // empty')

    if [[ -z "$LATEST_G" && -z "$LATEST_G_COMMENT" && "$G_INLINE_COUNT" -eq 0 ]]; then
      # No formal review, no fresh issue comment, no inline findings — nothing to evaluate.
      # A stale issue comment (created before the last push) does NOT count here;
      # LATEST_G_COMMENT is already empty when the only comments are pre-push.
      MISSING+=("no Greptile review yet")
    else
      # --- Path A: comment-based clean pass (primary Greptile channel) ---
      G_COMMENT_CLEAN=false
      if [[ -n "$LATEST_G_COMMENT" ]]; then
        G_THUMBSUP=$(echo "$LATEST_G_COMMENT" | jq -r '.reactions["+1"] // 0')
        # Clean = 👍 present AND no inline findings posted at all.
        if [[ "$G_THUMBSUP" -gt 0 && "$G_INLINE_COUNT" -eq 0 ]]; then
          G_COMMENT_CLEAN=true
        fi
      fi

      if [[ "$G_COMMENT_CLEAN" != true ]]; then
        # --- Path B: severity gate ---
        # Build a review body from the most-recent Greptile signal (issue comment
        # or formal review), then check inline bodies anchored at that timestamp.
        G_ANCHOR_TS=""
        G_BODY=""
        if [[ -n "$LATEST_G" ]]; then
          G_BODY=$(echo "$LATEST_G" | jq -r '.body // ""')
          G_ANCHOR_TS=$(echo "$LATEST_G" | jq -r '.submitted_at // ""')
        fi
        if [[ -n "$LATEST_G_COMMENT" ]]; then
          # Prefer updated_at over created_at: Greptile edits its summary in-place
          # (issue #748), so updated_at is the effective review timestamp after a
          # re-review. Falls back to created_at for comments without updated_at.
          G_COMMENT_TS=$(echo "$LATEST_G_COMMENT" | jq -r '(.updated_at // .created_at) // ""')
          # Issue comment supersedes formal review when it is more recent.
          if [[ -z "$G_ANCHOR_TS" || "$G_COMMENT_TS" > "$G_ANCHOR_TS" ]]; then
            G_BODY=$(echo "$LATEST_G_COMMENT" | jq -r '.body // ""')
            G_ANCHOR_TS="$G_COMMENT_TS"
          fi
        fi

        # Inline bodies associated with the latest Greptile review (fresh post-push).
        # Use LAST_COMMIT_TS (push time) rather than G_ANCHOR_TS (summary updated_at):
        # when Greptile posts inlines before editing its summary in-place (issue #748),
        # G_ANCHOR_TS > inline.created_at and those inlines would be excluded from P0
        # scanning — identical asymmetry to the BugBot commit_id lesson. Using the push
        # timestamp keeps G_INLINE_BODIES consistent with G_INLINE_COUNT (same filter).
        G_INLINE_BODIES=$(echo "$PR_COMMENTS_JSON" | jq -r --arg ts "${LAST_COMMIT_TS:-}" '
          [.[]? | select(.user.login == "greptile-apps[bot]")
                | select(if $ts == "" then true else .created_at > $ts end) | .body]
          | join("\n---\n")')

        # Count P0 severity badges across the review body and inline comments.
        # Match only formal Greptile badges (<img alt="P0">) — not bare-word prose
        # mentions like "no P0" which inflate the count (issue #729).
        P0_COUNT=$( { echo "$G_BODY"; echo "$G_INLINE_BODIES"; } | grep -oF 'alt="P0"' | wc -l | tr -d ' ')

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
          # Threads are resolved but P0 in latest review body / inline bodies.
          # A clean re-review would supersede this — require one.
          MISSING+=("latest Greptile review had P0 findings — need clean re-review after fix (trigger @greptileai)")
        fi
        # Unresolved G > 0 && P0 == 0: universal thread gate already covered.
        # Unresolved G == 0 && P0 == 0: only P1/P2 all resolved — gate met.
      fi
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

# Stale bot CHANGES_REQUESTED (wrong SHA) — dismiss via dismiss-stale-bot-changes.sh
# or /wrap recovery; emitted as JSON for orchestration (#452 / issue #426).
STALE_BOT_CHANGES_COUNT=$(echo "$REVIEWS_JSON" | jq -r --arg sha "$HEAD_SHA" '
  def allow: ["coderabbitai[bot]","cursor[bot]","greptile-apps[bot]","codeant-ai[bot]","graphite-app[bot]"];
  [.[]?
    | select(.state == "CHANGES_REQUESTED")
    | select((.commit_id // "") != "" and .commit_id != $sha)
    | select((.user.type // "") == "Bot")
    | select((.user.login // "") as $l | allow | index($l))]
  | length')
if [[ "$REVIEW_DECISION" == "CHANGES_REQUESTED" ]] && [[ "${STALE_BOT_CHANGES_COUNT:-0}" -gt 0 ]]; then
  echo "[merge-gate] reviewDecision is CHANGES_REQUESTED with ${STALE_BOT_CHANGES_COUNT} stale bot CHANGES_REQUESTED review(s) (commit_id != HEAD ${HEAD_SHA:0:7}). Dismiss via .claude/scripts/dismiss-stale-bot-changes.sh after push (see fixpr Step 3a, cr-merge-gate.md) — not human escalation." >&2
fi

STALE_JSON=$(jq -n --argjson c "${STALE_BOT_CHANGES_COUNT:-0}" '$c')

MISSING_JSON=$(printf '%s\n' "${MISSING[@]:-}" | jq -R . | jq -cs 'map(select(length > 0))')

emit_json "$MET" "$REVIEWER" "$REVIEWER" "$MISSING_JSON" "$HEAD_SHA" "$CI_STATUS" "$MERGE_STATE" "$MERGEABLE" "$REVIEW_DECISION" "$CODE_OWNER_BOTS" "$HUMAN_CHANGES_ON_HEAD_JSON" "$STALE_JSON" "${UNRESOLVED_TOTAL:-0}" "$PRIMARY_REVIEW_MET" "$AUTHORSHIP"

if [[ "$MET" == true ]]; then
  exit 0
else
  exit 1
fi
