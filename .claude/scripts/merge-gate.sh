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
#   - BugBot path   : 1 clean BugBot review on current HEAD + zero unresolved BugBot
#                     threads; the review-less "silent pass" shape (issue #844)
#                     additionally requires the success check-run to be published by
#                     the Cursor app, never merely named `Cursor Bugbot` (issue #962).
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
#
# Stale-approval redemption (issue #876): CodeAnt PATCHes its EXISTING review on
#   a re-review — same review id, commit_id advanced to the new HEAD,
#   submitted_at frozen — so a genuinely completed post-push re-review reads as
#   #836-stale forever. A stale approval is therefore REDEEMED when that same
#   reviewer left substantive evidence on the current SHA outside the review
#   object (review-substance.sh `external_evidence_on_head`: HEAD-anchored inline
#   comments, a status comment naming HEAD, a descriptive current-round comment,
#   or a substantive non-APPROVED review on HEAD). Redemption is by EVIDENCE,
#   never by reviewer identity — CodeRabbit
#   is treated identically, and an approval's own body can never redeem its own
#   timestamp. `<P>_APPROVAL_STALE` keeps the unchanged norm_ts meaning;
#   `<P>_APPROVAL_STALE_BLOCKING` (stale AND NOT redeemed) is what the path
#   consumes. Redemption is announced on stderr and never bypasses the substance
#   verdict, so a rubber stamp whose status comment names an older SHA still
#   fails as `self_report_mismatch`.
#
# Pre-run-approval redemption (issue #1432): a SEPARATE axis from the above —
#   #876 asks whether the approval object is fresh, this asks whether anything
#   actually reviewed the commit. review-substance.sh clears `pre_run_approval`
#   when that reviewer"s own run marker for the SAME SHA reached `done` with
#   zero findings on it, which is the only shape a clean pass can take on repos
#   where CodeAnt emits APPROVED solely as a pre-run stub (still-point PR #696,
#   this repo PR #1454). The verdict is computed THERE, not here, so
#   escalate-review.sh — which reads only `.substantive[]` — inherits the same
#   answer and the two cannot drift. This file only ANNOUNCES it
#   (announce_clean_run_redemption), keeping every redemption non-silent. The
#   announcement claims only the substance axis it controls, never merge
#   coverage — the orthogonal axes are still ahead of it (CodeAnt, PR #1476).
# Also enforces the pre-merge CI gate from .claude/rules/cr-merge-gate.md Step 1b
# (incomplete runs OR blocking conclusions = not merge-ready), merge metadata
# (mergeStateStatus including BEHIND, mergeable including CONFLICTING) per
# cr-merge-gate.md Step 1d / issue #273. When CR, Greptile, or CodeAnt is listed
# in CODEOWNERS, also verifies GitHub branch protection's reviewDecision is
# APPROVED so stale/dismissed bot approvals cannot accidentally pass the gate.
# When stderr notes stale bot CHANGES_REQUESTED (issue #426), dismiss via
# dismiss-stale-bot-changes.sh after push — do not treat as a human block.
#
# Review-substance guard (issue #875): a bot APPROVED on HEAD is counted as
#   review coverage only when the reviewer left evidence that it actually read
#   that commit. Delegated to review-substance.sh, which reports (in order of
#   decisiveness) temporal inversion — an APPROVED timestamped before that same
#   reviewer's own "is running the review" marker; a capability-failure notice
#   ("no PR Review subscription", rate limit, "couldn't run") with no later work;
#   self-report mismatch — the reviewer's own status comment naming a different
#   SHA; a pre-run approval (issue #1365) — the reviewer's own machine-readable
#   run record for HEAD shows the approval landed before that analysis started,
#   or while it was still in flight; and finally substance across the reviewer's
#   whole footprint. Body length alone is deliberately NOT the test: a genuine
#   CodeRabbit APPROVED with bodylen=0 whose walkthrough named the exact reviewed
#   range must keep passing.
#   Applied to the CR path only; the full evidence is emitted as `review_evidence`.
#
# Required-context gate (issue #1361): branch protection's required status checks
#   are asserted BY NAME against the current HEAD. Before this, the gate evaluated
#   only the check-runs that happened to exist — so when a required context never
#   reported at all there was nothing to fail and the PR scored clean. Observed
#   during the 2026-08-26 Actions outage: five required contexts absent, four
#   unrelated non-required checks green, `met:true, missing:[]`. The failure mode
#   inverts the gate's purpose — the less CI reports, the cleaner the PR looks.
#   Each required context must now be PRESENT on HEAD (a deduped check-run or a
#   commit status of that exact name) and not incomplete/blocking; absent counts
#   as unsatisfied, never as vacuously passing. No protection, or protection with
#   no required checks, keeps the pre-#1361 behaviour exactly. When the required
#   list cannot be read at all, the gate says so and BLOCKS rather than scoring
#   clean — degraded means degraded (`--allow-unverified-required-checks` is the
#   explicit per-PR user override). Emitted as `required_contexts`.
#
# Usage:
#   merge-gate.sh <pr_number> [--reviewer cr|bugbot|greptile] [--allow-nonauthor]
#                             [--allow-hollow-approval]
#                             [--allow-unverified-required-checks]
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
#     "authorship": "mine"|"not_mine"|"unknown",
#     "review_evidence": { … },  # review-substance.sh output; {} off the cr path
#     "required_contexts": {     # issue #1361
#       "source": "branch_protection"|"branch_object"|"none"|"unavailable"|"unknown",
#       "base": "main",
#       "contexts": ["typecheck", "build", …],
#       "unsatisfied": [{"context": "build", "state": "absent"}, …],
#       "error": ""              # populated only when source == "unavailable"
#     }
#   }
#
# `required_contexts.source` (issue #1361):
#   branch_protection — read from branches/{base}/protection/required_status_checks
#   branch_object     — that endpoint was unreadable, so the list came from the
#                       branch object's own `.protection.required_status_checks`,
#                       which any account with repo read access can see
#   none              — the base branch is unprotected, or is protected with no
#                       required status checks; pre-#1361 behaviour, nothing added
#   unavailable       — neither read succeeded; BLOCKS with its own missing[]
#                       reason (override: --allow-unverified-required-checks)
#   unknown           — emitted by the early-exit error paths, which never got
#                       far enough to look
# `unsatisfied[].state` is `absent` (no check-run and no commit status of that
# name on HEAD), `wrong_app` (runs of that name exist, but protection pins the
# context to an `app_id` and none of them came from that app — GitHub would not
# accept them either), the run's non-`completed` status, its blocking conclusion,
# or a commit status's `pending`/`failure`/`error`.
#
# Reading this output: pipe it with `printf '%s'`, a herestring, or a file —
# NEVER `echo "$GATE_JSON" | jq`. zsh's `echo` expands backslash escapes by
# default, so any escape sequence a free-form field carries is expanded into a
# raw character before jq parses, and jq then rejects the document. Every string
# emitted here is scrubbed of control characters (issue #1219), which removes the
# common trigger, but a body containing a literal backslash still ships as `\\`
# and `echo` would still corrupt it.
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
# `primary_review_met`: true when CodeRabbit OR CodeAnt has a valid
# (non-retracted, fresh, and — since issue #875 — SUBSTANTIVE) APPROVED review
# on current HEAD SHA — i.e. the "1 explicit CodeRabbit or CodeAnt APPROVED
# review" requirement from cr-merge-gate.md Step 1 is satisfied, independent of
# CI/threads/merge-state. On the `cr` path this is the primary gate signal; on
# the `bugbot` path it can also be true when a fresh CR/CodeAnt APPROVED
# satisfies the gate via the #865 bypass (sticky reviewer pointer stays bugbot).
# The field name and type are unchanged; #875 only stopped an approval that
# nothing actually reviewed from setting it — the meaning every consumer of this
# field already assumed. `review_evidence` carries the per-reviewer detail, and
# `review_evidence.hollow[]` names any approver that was discounted.
# `false` on the greptile path. Consumers that only
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
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

# --------------------------------------------------------------------------
# Shared timestamp normaliser (issue #885)
# --------------------------------------------------------------------------
# norm_ts() — the canonical #836 ordering rule — lives in lib/ts-normalizer.sh
# so it has exactly one bash definition, and so the jq mirror in
# escalate-review.sh has a single, testable thing to agree with. See that
# library's header for the rule, the PR #883 failures that motivated it, and why
# review-substance.sh keeps a deliberately different variant.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS_NORMALIZER_LIB="${SCRIPT_DIR}/lib/ts-normalizer.sh"
if [[ ! -f "$TS_NORMALIZER_LIB" || ! -r "$TS_NORMALIZER_LIB" ]]; then
  echo "merge-gate.sh: sibling library missing or unreadable: $TS_NORMALIZER_LIB" >&2
  exit 4
fi
# shellcheck source=./lib/ts-normalizer.sh
if ! source "$TS_NORMALIZER_LIB"; then
  echo "merge-gate.sh: failed to load $TS_NORMALIZER_LIB" >&2
  exit 4
fi

# --------------------------------------------------------------------------
# Arg parsing
# --------------------------------------------------------------------------
PR_NUMBER=""
REVIEWER_OVERRIDE=""
# Authorship guard (issue #733): block a merge on a PR the authenticated user did
# not author. --allow-nonauthor suppresses the block only under an explicit
# per-PR user override. The `authorship` field is emitted regardless.
ALLOW_NONAUTHOR=false
# Review-substance guard (issue #875): --allow-hollow-approval lets an approval
# with no substantive footprint satisfy the primary review requirement anyway.
# Explicit per-PR user override ONLY — an agent must never pass it on its own.
# The evidence is still computed, still emitted in `review_evidence`, and the
# override is announced on stderr, so nothing about the bypass is silent.
# Scope is deliberately narrow: it covers `no_substantive_footprint` and NOTHING
# else. Temporal inversion, capability failure, self-report SHA mismatch and
# pre-run approval (issue #1365) stay blocking even with the flag — those are not
# "the bot said nothing", they are the bot's own record contradicting the claim
# that it reviewed this commit. No code change was needed for #1365 to inherit
# this: override_eligible() subtracts exactly one disqualifier and requires the
# remainder to be empty, so a new one is refused by construction. The issue
# #1432 redemption does not widen this flag either: it removes tags from
# `disqualified_by` upstream, on evidence, so the override still sees exactly
# what it always did — and a stub the redemption refused stays refused here.
ALLOW_HOLLOW=false
# Required-context guard (issue #1361): --allow-unverified-required-checks lets
# the gate proceed when branch protection's required list could not be READ at
# all. Explicit per-PR user override ONLY — an agent must never pass it on its
# own. Deliberately narrow, and narrower than it may look: it covers ONLY the
# unreadable-list case. A list that WAS read and contains a context absent from
# HEAD stays blocking with or without the flag — that is not "we could not
# check", it is "we checked and the check never ran", which is the entire defect
# #1361 exists to close.
ALLOW_UNVERIFIED_REQ=false

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
    --allow-hollow-approval)
      ALLOW_HOLLOW=true
      shift
      ;;
    --allow-unverified-required-checks)
      ALLOW_UNVERIFIED_REQ=true
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
# Build a `missing` array with jq so free-form text can never break the JSON.
# Hand-built literals (`"[\"… $VAR …\"]"`) let an embedded quote or newline make
# jq reject its own --argjson; jq then emitted NOTHING while the script still
# exited non-zero, so a caller reading stdout saw an empty string rather than an
# error (issue #1219). `--` terminates option parsing so a reason starting with
# `-` is still a positional value, and `select(length > 0)` drops the empty
# string that `"${MISSING[@]:-}"` produces for an empty array (bash 3.2 + set -u
# cannot expand a bare `"${MISSING[@]}"`).
missing_json() { # <reason>...
  jq -cn --args '$ARGS.positional | map(select(length > 0))' -- "$@"
}

emit_json() {
  # emit_json <met> <reviewer> <path> <missing_json_array> <head_sha> <ci_status_json> <merge_state> <mergeable> <review_decision> <code_owner_bots_json> <human_changes_json_array> <stale_bot_changes_requested_count_number> [unresolved_thread_count_number] [primary_review_met_bool] [authorship] [review_evidence_json]
  local met="$1" reviewer="$2" path="$3" missing="$4" head_sha="$5" ci_status="$6" merge_state="$7" mergeable="$8" review_decision="$9" code_owner_bots="${10}" human_changes="${11}" stale_bot_count="${12}" unresolved_thread_count="${13:-0}" primary_review_met="${14:-false}" authorship="${15:-unknown}"
  # review_evidence (issue #875) — arg 16. Defaulted separately rather than with
  # ${16:-{}} because a literal `{}` inside brace-default expansion is ambiguous.
  local review_evidence="${16:-}"
  if [[ -z "$review_evidence" ]]; then review_evidence='{}'; fi
  # required_contexts (issue #1361) — arg 17, defaulted the same way. The early
  # error paths (die_api / die_local / PR-not-open) never reach the protection
  # read, so they emit source "unknown" rather than claiming "none": "we never
  # looked" and "there is nothing to look at" are different answers, and only one
  # of them is safe to read as a pass.
  local required_contexts="${17:-}"
  if [[ -z "$required_contexts" ]]; then
    required_contexts='{"source":"unknown","base":"","contexts":[],"unsatisfied":[],"error":""}'
  fi
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
    --argjson review_evidence "$review_evidence" \
    --argjson required_contexts "$required_contexts" \
    'def scrub: walk(if type == "string" then gsub("[[:cntrl:]]"; " ") else . end);
     {met: $met, reviewer: $reviewer, path: $path, missing: $missing, head_sha: $head_sha, ci_status: $ci_status, merge_state: $merge_state, mergeable: $mergeable, review_decision: $review_decision, code_owner_bots: $code_owner_bots, human_changes_requested: $human_changes_requested, stale_bot_changes_requested_count: $stale_bot_changes_requested_count, unresolved_thread_count: $unresolved_thread_count, primary_review_met: $primary_review_met, authorship: $authorship, review_evidence: $review_evidence, required_contexts: $required_contexts}
     | scrub'
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
  emit_json false unknown cr "$(missing_json "gh repo view failed — not in a git repo or no remote")" "" "$(emit_empty_ci)" "" "" "" "$(emit_empty_code_owner_bots)" '[]' 0
  exit 4
fi
OWNER="${OWNER_REPO%/*}"
REPO="${OWNER_REPO#*/}"

PR_JSON=$(gh pr view "$PR_NUMBER" --json number,state,headRefOid,baseRefName,mergeStateStatus,mergeable,reviewDecision,author 2>/dev/null || true)
if [[ -z "$PR_JSON" ]]; then
  emit_json false unknown cr "$(missing_json "PR #$PR_NUMBER not found")" "" "$(emit_empty_ci)" "" "" "" "$(emit_empty_code_owner_bots)" '[]' 0
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
  emit_json false unknown cr "$(missing_json "PR #$PR_NUMBER is $PR_STATE — not open")" "$HEAD_SHA" "$(emit_empty_ci)" "$MERGE_STATE" "$MERGEABLE" "$REVIEW_DECISION" "$(emit_empty_code_owner_bots)" '[]' 0
  exit 3
fi

if [[ -z "$HEAD_SHA" ]]; then
  emit_json false unknown cr "$(missing_json "could not determine HEAD SHA")" "" "$(emit_empty_ci)" "$MERGE_STATE" "$MERGEABLE" "$REVIEW_DECISION" "$(emit_empty_code_owner_bots)" '[]' 0
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
  emit_json false "${REVIEWER_OVERRIDE:-unknown}" "unknown" "$(missing_json "gh api failed: $1")" "$HEAD_SHA" "$(emit_empty_ci)" "$MERGE_STATE" "$MERGEABLE" "$REVIEW_DECISION" "$(emit_empty_code_owner_bots)" '[]' 0
  exit 4
}

# Same fail-closed shape as die_api, for failures that are ours rather than
# GitHub's — blaming "gh api failed" for a missing local helper sends whoever
# reads `missing` after the wrong problem.
die_local() {
  emit_json false "${REVIEWER_OVERRIDE:-unknown}" "unknown" "$(missing_json "$1")" "$HEAD_SHA" "$(emit_empty_ci)" "$MERGE_STATE" "$MERGEABLE" "$REVIEW_DECISION" "$(emit_empty_code_owner_bots)" '[]' 0
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
# Both comment endpoints are paginated like reviews above (issue #875, BugBot
# review). These used to be a single page each, which was survivable while they
# only fed thread bookkeeping — but they are now the substance evaluator's
# evidence payload, and a busy PR pushes the walkthrough or the inline findings
# past comment 100. Losing them there does not merely under-report: it turns a
# genuine approval hollow and blocks the merge.
if ! PR_COMMENTS_RAW=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments?per_page=100" 2>/dev/null); then
  die_api "pull-comments"
fi
PR_COMMENTS_JSON=$(echo "$PR_COMMENTS_RAW" | jq -s 'add // []')
if [[ -z "$PR_COMMENTS_JSON" ]] || ! echo "$PR_COMMENTS_JSON" | jq -e . >/dev/null 2>&1; then
  die_api "pull-comments parse"
fi
if ! ISSUE_COMMENTS_RAW=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR_NUMBER/comments?per_page=100" 2>/dev/null); then
  die_api "issue-comments"
fi
ISSUE_COMMENTS_JSON=$(echo "$ISSUE_COMMENTS_RAW" | jq -s 'add // []')
if [[ -z "$ISSUE_COMMENTS_JSON" ]] || ! echo "$ISSUE_COMMENTS_JSON" | jq -e . >/dev/null 2>&1; then
  die_api "issue-comments parse"
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
# Branch-protection required contexts (issue #1361)
# --------------------------------------------------------------------------
# The gate used to aggregate whatever check-runs existed on HEAD and call the
# absence of failures a pass. Nothing ever asked which checks were SUPPOSED to
# report. During the 2026-08-26 Actions outage two required workflows ended in
# `startup_failure` with zero jobs, so they created no check-runs at all; the
# four surviving non-required checks were green, and every layer above this one
# (ci-status.sh, merge-gate.sh, escalate-review.sh, polling-state-gate.sh) said
# merge. GitHub's own `mergeStateStatus: BLOCKED` was the only dissenting voice.
#
# Reading the required list is therefore not optional, and neither is failing
# when it cannot be read: "no required contexts reported" and "no required
# contexts exist" produce identical check-run payloads, and only one of them is
# a pass.
#
# TWO reads, in this order, because they fail differently:
#   1. branches/{base}/protection/required_status_checks — authoritative, but
#      the protection endpoints need admin access, so a collaborator token gets
#      403 (and sometimes a permission-shaped 404 that is indistinguishable from
#      "unprotected" by status code alone).
#   2. the branch object's own `.protection.required_status_checks` — the legacy
#      v3 shape, visible to any account that can read the repo. It carries the
#      same `contexts` list (verified live on this repo and on auerbachb/
#      still-point), so it answers the question read 1 could not.
# `.protected` from that same object is what separates "unprotected" from
# "unreadable" — a distinction no HTTP status makes reliably. Only when BOTH
# reads fail do we report `unavailable`, which blocks.
REQUIRED_CONTEXTS_JSON='[]'
REQUIRED_APPS_JSON='{}'
REQUIRED_SOURCE="none"
REQUIRED_ERROR=""

# Extract the context list from either shape. Both carry `contexts`; the
# protection endpoint additionally carries `checks[].context` (the newer
# app-scoped form, which is what the UI writes today), so union them. `contexts`
# alone would miss nothing observed so far, but the union costs one line and
# fails toward listing MORE required checks, never fewer.
REQ_CTX_FILTER='
  if type == "object"
  then ((( .contexts // [] ) + [ ( .checks // [] )[]? | .context // empty ])
        | map(select(type == "string" and length > 0)) | unique)
  else [] end'

# The publisher half of the same answer (issue #1383 review). `checks[]` entries
# carry an `app_id` alongside the context, and GitHub itself will only accept a
# check from THAT app for that context — this repo pins `rule-lint` to app_id
# 15368. Matching on name alone would let a same-named check from any other
# publisher satisfy a required context, so the gate could report a pass that
# GitHub would refuse: the required app never verified HEAD. That is the same
# vacuous pass #1361 exists to close, one axis over.
#
# Kept as a SEPARATE {context: app_id} map rather than folded into the context
# list so the emitted `required_contexts.contexts` stays a plain string array.
# A null `app_id` means "any app" in GitHub's own semantics, and a context that
# arrives only via the legacy `contexts` array has no publisher to pin, so both
# are simply absent from this map and stay name-only.
REQ_APPS_FILTER='
  if type == "object"
  then ([ ( .checks // [] )[]?
          | select((.context | type) == "string" and (.context | length) > 0)
          | select(.app_id != null)
          | {key: .context, value: .app_id} ] | from_entries)
  else {} end'

BRANCH_READABLE=false
BRANCH_PROTECTED=""
BRANCH_CONTEXTS='[]'
BRANCH_APPS='{}'
if [[ -n "$BASE_REF" ]]; then
  BRANCH_JSON=$(gh api "repos/$OWNER/$REPO/branches/$BASE_REF" 2>/dev/null || true)
  # `has("name")` is the readability sentinel: a 404/403 body is a `{message:…}`
  # object that would otherwise parse fine and read as an unprotected branch.
  if [[ -n "$BRANCH_JSON" ]] && echo "$BRANCH_JSON" | jq -e 'type == "object" and has("name")' >/dev/null 2>&1; then
    BRANCH_READABLE=true
    BRANCH_PROTECTED=$(echo "$BRANCH_JSON" | jq -r '(.protected // false) | tostring' 2>/dev/null || echo "")
    BRANCH_CONTEXTS=$(echo "$BRANCH_JSON" | jq -c ".protection.required_status_checks | $REQ_CTX_FILTER" 2>/dev/null || echo '[]')
    if [[ -z "$BRANCH_CONTEXTS" ]]; then BRANCH_CONTEXTS='[]'; fi
    BRANCH_APPS=$(echo "$BRANCH_JSON" | jq -c ".protection.required_status_checks | $REQ_APPS_FILTER" 2>/dev/null || echo '{}')
    if [[ -z "$BRANCH_APPS" ]]; then BRANCH_APPS='{}'; fi
  fi
fi

if [[ -z "$BASE_REF" ]]; then
  # No base branch name means no protection to look up. Report it rather than
  # silently skipping — this is the same class of gap #1361 is about.
  REQUIRED_SOURCE="unavailable"
  REQUIRED_ERROR="PR base branch name unavailable"
elif [[ "$BRANCH_READABLE" == true && "$BRANCH_PROTECTED" == "false" ]]; then
  # Unprotected base — there is nothing to require. Pre-#1361 behaviour, and the
  # cheap path: no protection call at all.
  REQUIRED_SOURCE="none"
else
  # stdout and stderr are captured together deliberately: on success gh writes
  # only JSON, on failure only a message, so one capture plus the exit code
  # classifies both without a temp file.
  if RSC_RAW=$(gh api "repos/$OWNER/$REPO/branches/$BASE_REF/protection/required_status_checks" 2>&1); then
    RSC_CONTEXTS=$(printf '%s' "$RSC_RAW" | jq -c "$REQ_CTX_FILTER" 2>/dev/null || true)
    RSC_APPS=$(printf '%s' "$RSC_RAW" | jq -c "$REQ_APPS_FILTER" 2>/dev/null || true)
  else
    RSC_CONTEXTS=""
    RSC_APPS=""
  fi
  if [[ -n "$RSC_CONTEXTS" ]]; then
    REQUIRED_CONTEXTS_JSON="$RSC_CONTEXTS"
    if [[ -n "$RSC_APPS" ]]; then REQUIRED_APPS_JSON="$RSC_APPS"; else REQUIRED_APPS_JSON='{}'; fi
    REQUIRED_SOURCE="branch_protection"
  elif [[ "$BRANCH_READABLE" == true ]]; then
    # The protection endpoint refused (403, or a 404 meaning "required status
    # checks not enabled"), but the branch object answered. An empty list here
    # is a real answer, not a shrug: the branch is protected by rules that do
    # not require any status check, which is a common configuration (review-only
    # protection) and must not wedge every merge in such a repo.
    REQUIRED_CONTEXTS_JSON="$BRANCH_CONTEXTS"
    REQUIRED_APPS_JSON="$BRANCH_APPS"
    if [[ "$(echo "$REQUIRED_CONTEXTS_JSON" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]]; then
      REQUIRED_SOURCE="branch_object"
    else
      REQUIRED_SOURCE="none"
      # Protected branch + refused protection endpoint + an empty fallback list.
      # Almost always review-only protection, which genuinely requires no status
      # check — but it is the one shape where "no requirement" and "the
      # requirement is hidden from this token" look identical, so say so rather
      # than resolve it silently. Not a blocker: treating it as one would wedge
      # every merge in a review-only-protected repo, a far larger and more
      # common cost than the narrow ambiguity it would close.
      if [[ "$BRANCH_PROTECTED" == "true" ]]; then
        echo "[merge-gate] base $BASE_REF is protected but exposes no required status checks to this token (protection endpoint refused; branch object lists none). Proceeding as 'no required checks' — if this repo does require checks, the token lacks administration:read and required-context verification is not actually running (issue #1361)." >&2
      fi
    fi
  else
    REQUIRED_SOURCE="unavailable"
    REQUIRED_ERROR=$(printf '%s' "${RSC_RAW:-no response}" | tr '\n\r\t' '   ' | cut -c1-200)
  fi
fi

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

# Review substance (issue #875) — delegated to review-substance.sh so merge-gate
# and escalate-review.sh share one definition of "this approval actually read the
# commit". Pure evaluator over payloads already fetched above: no extra API calls.
#
# Runs on both cr and bugbot paths (issue #865): the bugbot path uses the evidence
# to verify a fresh CR/CodeAnt APPROVED before the #865 bypass fires. Graceful
# degradation on the bugbot path: if the evaluator is absent or returns bad JSON,
# REVIEW_EVIDENCE stays '{}' and CR_PATH_APPROVED_ON_HEAD remains false — the
# normal BugBot gate runs unchanged. Only the cr path is hard-fatal on failure.
REVIEW_EVIDENCE='{}'
if [[ "$REVIEWER" == "cr" || "$REVIEWER" == "bugbot" ]]; then
  REVIEW_SUBSTANCE_SH="$(dirname "$0")/review-substance.sh"
  if [[ ! -x "$REVIEW_SUBSTANCE_SH" ]]; then
    if [[ "$REVIEWER" == "cr" ]]; then
      die_local "review-substance.sh not found or not executable at $REVIEW_SUBSTANCE_SH"
    fi
    # On the bugbot path: evaluator absent — REVIEW_EVIDENCE stays '{}'.
  else
    # The three payloads are piped in, NOT passed as --argjson: a busy PR's comment
    # JSON runs to ~1 MB and three of those on one command line can exceed ARG_MAX.
    # printf is a shell builtin writing to a pipe, so no exec limit applies; `jq -s`
    # then slurps the three values in order.
    REVIEW_EVIDENCE=$(printf '%s\n%s\n%s\n' "$REVIEWS_JSON" "$PR_COMMENTS_JSON" "$ISSUE_COMMENTS_JSON" \
      | jq -cs --arg sha "$HEAD_SHA" --arg push "${LAST_COMMIT_TS:-}" \
          '{head_sha: $sha, push_ts: $push, reviews: .[0], pr_comments: .[1], issue_comments: .[2]}' \
          2>/dev/null \
      | "$REVIEW_SUBSTANCE_SH" 2>/dev/null || true)
    # Structure, not just parseability: substance_ok reads .reviewers[<login>], and
    # a well-formed-but-wrong shape (say a bare string) would silently read as
    # "not substantive" and block every approval.
    if [[ -z "$REVIEW_EVIDENCE" ]] || ! echo "$REVIEW_EVIDENCE" \
        | jq -e 'type == "object" and (.reviewers | type == "object")' >/dev/null 2>&1; then
      if [[ "$REVIEWER" == "cr" ]]; then
        die_local "review-substance.sh produced no usable JSON (expected an object with a .reviewers object)"
      fi
      # On the bugbot path: bad evidence — REVIEW_EVIDENCE stays '{}'.
      REVIEW_EVIDENCE='{}'
    fi
  fi
fi

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

# Required-context gate (#1361) — applies to all paths; branch protection is a
# property of the base branch, not of whichever bot happens to own the review.
#
# Deliberately NOT folded into the CI gate above. That gate answers "did
# everything that ran, pass"; this one answers "did everything that was supposed
# to run, run". The outage that motivated #1361 is precisely the case where the
# first question returns a confident yes and the second has never been asked.
REQUIRED_UNSATISFIED_JSON='[]'
REQUIRED_COUNT=$(echo "$REQUIRED_CONTEXTS_JSON" | jq 'length' 2>/dev/null || echo 0)
if [[ "$REQUIRED_SOURCE" == "unavailable" ]]; then
  if [[ "$ALLOW_UNVERIFIED_REQ" == true ]]; then
    echo "[merge-gate] --allow-unverified-required-checks: proceeding without verifying branch-protection required contexts on ${BASE_REF:-<unknown base>} (${REQUIRED_ERROR}) — an absent required check cannot be distinguished from an absent requirement (issue #1361)." >&2
  else
    MISSING+=("cannot read branch-protection required status checks for base ${BASE_REF:-<unknown>} — required-context verification unavailable ($REQUIRED_ERROR); a required check that never reported is indistinguishable from no requirement, so this fails closed (issue #1361). Pass --allow-unverified-required-checks only under an explicit per-PR user override")
  fi
elif [[ "$REQUIRED_COUNT" -gt 0 ]]; then
  # Legacy commit statuses can satisfy a required context just as check-runs can
  # (Vercel, CircleCI and friends still post them), so a context absent from the
  # check-run list is not yet absent. Fetched only when there is something to
  # check, and non-fatal: an unreadable status list simply contributes nothing,
  # which can withhold a merge but never grant one. Newest-first per the API, so
  # `first` per context is that context's current state.
  COMMIT_STATUSES_JSON='[]'
  if _CS_RAW=$(gh api --paginate "repos/$OWNER/$REPO/commits/$HEAD_SHA/statuses?per_page=100" 2>/dev/null); then
    COMMIT_STATUSES_JSON=$(printf '%s' "$_CS_RAW" | jq -sc 'add // []' 2>/dev/null || echo '[]')
    if [[ -z "$COMMIT_STATUSES_JSON" ]]; then COMMIT_STATUSES_JSON='[]'; fi
  fi

  # CHECK_RUNS_JSON is already deduped to the newest suite per (app, name), so a
  # re-run's superseded record cannot mark a required context failed or pending.
  # ALL runs of the newest suite are retained, which is what makes the two-jobs-
  # one-name shape work: still-point publishes a `build` from the TestFlight
  # workflow and a `build` from Web Build, both GitHub Actions, both in the same
  # suite. They are matched together here, and the context is satisfied because
  # neither is blocking — `skipped` is non-blocking by the same rule ci-status.sh
  # uses, so the skipped leg does not veto its successful sibling.
  # Publisher scoping (issue #1383 review): when protection pins a context to an
  # `app_id`, only that app's check-runs count. $named is every run carrying the
  # name; $r narrows to the ones GitHub would actually accept. Runs present under
  # the name but all from other apps is its own state — `wrong_app`, not `absent`
  # — because the two have different fixes and "degraded means say so".
  # Commit statuses stay name-only on purpose: they carry no app_id, and the
  # app-scoped `checks[]` shape governs check-runs.
  REQUIRED_STATE_JSON=$(jq -cn \
    --argjson req "$REQUIRED_CONTEXTS_JSON" \
    --argjson apps "$REQUIRED_APPS_JSON" \
    --argjson runs "$CHECK_RUNS_JSON" \
    --argjson statuses "$COMMIT_STATUSES_JSON" '
      def is_blocking: . == "failure" or . == "timed_out" or . == "action_required"
                       or . == "startup_failure" or . == "stale";
      $req | map(
        . as $c
        | ($apps[$c] // null)                                          as $app
        | [ $runs.check_runs[]? | select((.name // "") == $c) ]        as $named
        | (if $app == null then $named
           else [ $named[] | select((.app.id // null) == $app) ] end)  as $r
        | ( [ $statuses[]? | select((.context // "") == $c) ] | first ) as $s
        | (if (($r | length) == 0 and $s == null and ($named | length) > 0) then
             {context: $c, state: "wrong_app", satisfied: false}
           elif (($r | length) == 0 and $s == null) then
             {context: $c, state: "absent", satisfied: false}
           elif any($r[]; (.status // "") != "completed") then
             {context: $c,
              state: ([ $r[] | select((.status // "") != "completed")
                        | ((.status // "") | if . == "" then "incomplete" else . end) ] | first),
              satisfied: false}
           elif any($r[]; ((.conclusion // "") | is_blocking)) then
             {context: $c,
              state: ([ $r[] | select(((.conclusion // "") | is_blocking)) | .conclusion ] | first),
              satisfied: false}
           elif ($r | length) == 0 and (($s.state // "") != "success") then
             {context: $c,
              state: (($s.state // "") | if . == "" then "unknown" else . end),
              satisfied: false}
           else
             {context: $c, state: "passing", satisfied: true}
           end))' 2>/dev/null || echo '[]')
  if [[ -z "$REQUIRED_STATE_JSON" ]]; then REQUIRED_STATE_JSON='[]'; fi
  REQUIRED_UNSATISFIED_JSON=$(echo "$REQUIRED_STATE_JSON" | jq -c '[.[] | select(.satisfied | not)]' 2>/dev/null || echo '[]')
  if [[ -z "$REQUIRED_UNSATISFIED_JSON" ]]; then REQUIRED_UNSATISFIED_JSON='[]'; fi
  if [[ "$(echo "$REQUIRED_UNSATISFIED_JSON" | jq 'length')" -gt 0 ]]; then
    REQUIRED_UNSATISFIED_LIST=$(echo "$REQUIRED_UNSATISFIED_JSON" | jq -r 'map("\(.context) (\(.state))") | join(", ")')
    MISSING+=("branch protection requires status check(s) not satisfied on HEAD ${HEAD_SHA:0:7}: $REQUIRED_UNSATISFIED_LIST — a required context that never reported is not a pass (issue #1361)")
  fi
fi

REQUIRED_CONTEXTS_OUT=$(jq -cn \
  --arg source "$REQUIRED_SOURCE" \
  --arg base "$BASE_REF" \
  --arg error "$REQUIRED_ERROR" \
  --argjson contexts "$REQUIRED_CONTEXTS_JSON" \
  --argjson unsatisfied "$REQUIRED_UNSATISFIED_JSON" \
  '{source: $source, base: $base, contexts: $contexts, unsatisfied: $unsatisfied, error: $error}')

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

# Timestamp normaliser — used by all reviewer paths below (issue #836).
# norm_ts() is sourced from lib/ts-normalizer.sh near the top of this file
# (issue #885): strip one trailing UTC suffix (Z / +00:00 / +0000), KEEP
# fractional seconds. escalate-review.sh mirrors the rule in jq and must match it
# byte for byte — that parity is enforced by tests/ts-normalizer-parity.test.sh,
# not by a hand-maintained note. Rationale and the PR #883 failures it prevents
# are in the library header.

# Helper functions for CR-path approval checks (issue #875). Defined here —
# outside the case statement — so both the cr) path (primary) and the bugbot)
# path's #865 bypass can call them without duplication.
substance_ok() { # <login>
  echo "$REVIEW_EVIDENCE" | jq -e --arg l "$1" \
    '.reviewers[$l].counts_as_coverage // false' >/dev/null 2>&1 && echo true || echo false
}
substance_reasons() { # <login> — human-readable, comma-joined
  echo "$REVIEW_EVIDENCE" | jq -r --arg l "$1" '
    (.reviewers[$l] // {}) as $r
    | [ ($r.disqualified_by // [])[]
        | if . == "temporal_inversion" then
            "approved before \($l) announced it had started reviewing"
          elif . == "pre_run_approval" then
            # Issue #1365. Sourced from the machine-readable run record the
            # reviewer itself published, so the message quotes the timestamps
            # rather than paraphrasing them: a reader can check the claim against
            # the payload on the PR. Two distinct shapes — still in flight, or
            # approved before the run began.
            # (No apostrophes in this block: the whole jq program is one
            # single-quoted bash string, and one stray quote ends it.)
            ( if ($r.run_done == false) then
                "\($l) approved at \($r.approval_submitted_at // "?") while its own recorded analysis of this commit was still in flight (started \($r.run_started_at // "?"), not finished)"
              else
                "\($l) approved at \($r.approval_submitted_at // "?") before its own recorded analysis of this commit started (\($r.run_started_at // "?")) — the approval cannot be a verdict from that run"
              end )
          elif . == "capability_failure" then
            "\($l) reported it could not review this commit"
          elif . == "self_report_mismatch" then
            ( ($r.status_comment_shas // []) as $toks
            | "\($l)'"'"'s own status comment names \($toks | join(", ")) — not this SHA"
              + ( if ($toks | map(select(length == 8 or length == 12)) | length) > 0
                  then " (token lengths 8 or 12 may be GUID segments from an unhandled invocation comment shape)"
                  else "" end ) )
          else
            "no substantive review footprint (body \($r.body_len // 0) chars, \($r.inline_comments_on_head // 0) inline comment(s), no status comment naming this SHA)"
          end ]
    | join("; ")' 2>/dev/null || echo "no substantive review footprint"
}
# --allow-hollow-approval covers exactly ONE disqualifier: the approval left
# no substantive footprint, and a human is saying they read the diff instead.
# It must NOT wave through an integrity failure — an approval that names a
# different SHA, predates the bot's own start marker, or follows that bot
# saying it could not review is not "unevidenced", it is evidence AGAINST a
# review having happened, and no per-PR override should launder it.
# Fail-closed: any jq failure (missing/unparseable evidence) yields false.
override_eligible() { # <login>
  echo "$REVIEW_EVIDENCE" | jq -e --arg l "$1" \
    '((.reviewers[$l].disqualified_by // []) - ["no_substantive_footprint"]) | length == 0' \
    >/dev/null 2>&1 && echo true || echo false
}
# Stale-approval redemption (issue #876). CodeAnt PATCHes its EXISTING review
# object on a re-review — same review id, commit_id correctly advanced to the
# new HEAD, submitted_at frozen at the original submission — and GitHub treats
# submitted_at as immutable creation time. So a genuinely completed post-push
# re-review reads as #836-stale and the gate wedges (auerbachb/skingod PR
# #2596: 8 poll ticks, 15+ minutes, on a review that had demonstrably run).
#
# The redemption term is external_evidence_on_head, NOT the reviewer's
# identity. "CodeAnt's submitted_at is unreliable, so skip staleness for
# CodeAnt" would re-open exactly the hole #875 closed the same night — that
# bot also emits genuinely hollow approvals (bodylen=0, four in one second,
# one approving a commit that did not exist for another 16 minutes). A stale
# timestamp may be redeemed by evidence on the current SHA; it is never
# waived by who submitted it. CodeRabbit gets the identical treatment.
#
# Nor is CodeAnt's own "finished running the review" notice the redeemer: it
# is a fixed, content-free string, so accepting it would let a bot certify
# its own freshness with a constant. external_evidence_on_head requires a
# SUBSTANTIVE footprint anchored to HEAD and produced OUTSIDE the review
# object whose timestamp is in doubt (review-substance.sh):
#   - inline diff comments with commit_id AND original_commit_id == HEAD, or
#   - a >= min_chars conversation comment naming HEAD's SHA that is not a
#     capability-failure notice, or a descriptive comment tied to a post-push
#     run-start marker, or
#   - a substantive non-APPROVED review on HEAD with submitted_at >= push.
# Each is anchored to the post-push commit, and the approval's own body is
# excluded by construction — an approval can never redeem its own timestamp.
#
# Fail-closed: any jq failure (missing/unparseable evidence) yields false, so
# a broken evaluator can only withhold redemption, never grant it.
external_evidence_ok() { # <login>
  echo "$REVIEW_EVIDENCE" | jq -e --arg l "$1" \
    '.reviewers[$l].external_evidence_on_head // false' >/dev/null 2>&1 && echo true || echo false
}
# Pre-run-approval redemption (issue #1432). Reported, never recomputed here:
# review-substance.sh owns the verdict so escalate-review.sh — which reads only
# .substantive[] — can never disagree with the gate about the same payload.
# Announcing it keeps the "redemption is never silent" convention the #876
# STALE_REDEEMED messages established.
clean_run_redeemed() { # <login>
  echo "$REVIEW_EVIDENCE" | jq -e --arg l "$1" \
    '.reviewers[$l].redeemed_by_clean_run // false' >/dev/null 2>&1 && echo true || echo false
}
# The wording is deliberately scoped to the ONE term redemption controls — the
# #875 substance axis (`pre_run_approval` / `no_substantive_footprint`) — and
# says so, because this fires before the caller derives <P>_APPROVAL_VALID.
# A redeemed approval can still be rejected on an orthogonal axis it never
# touches: stale `submitted_at` (#836 <P>_APPROVAL_STALE_BLOCKING, reachable
# when a rebase re-points a carried-over approval's commit_id onto a HEAD that
# then gets its own clean run), a newer same-SHA CHANGES_REQUESTED, a missing
# `submitted_at`, failing CI, or an unresolved thread. Claiming "review
# coverage" here would announce a merge verdict this function does not decide
# (CodeAnt, PR #1476). Sibling convention: the #876 STALE_REDEEMED lines below
# likewise claim only their own axis ("counting it as fresh"), never the gate.
announce_clean_run_redemption() { # <label> <login>
  [[ "$(clean_run_redeemed "$2")" == true ]] || return 0
  local started finished
  started=$(echo "$REVIEW_EVIDENCE" | jq -r --arg l "$2" '.reviewers[$l].run_started_at // "?"' 2>/dev/null || echo "?")
  finished=$(echo "$REVIEW_EVIDENCE" | jq -r --arg l "$2" '.reviewers[$l].run_finished_at // "?"' 2>/dev/null || echo "?")
  echo "[merge-gate] $1 APPROVED on ${HEAD_SHA:0:7} was posted before its own recorded analysis started, but that analysis then COMPLETED on this same SHA (started $started, finished $finished) with zero findings — counting it as substantive review evidence rather than a hollow approval (issue #1432). Freshness, retraction, CI and thread state are separate checks; this line is not a merge verdict." >&2
}

# Fetch and compute per-bot approval state. Called once per bot for the shared
# CR/CodeAnt approval block (issue #865 / Issue #936 hotspot extraction).
#
# Sets the following global variables (examples shown for P="CR"):
#   LATEST_<P>_APPROVED_AT            - newest APPROVED submitted_at on HEAD, or ""
#   LATEST_<P>_CHANGES_REQUESTED_AT   - newest CHANGES_REQUESTED submitted_at on HEAD, or ""
#   APPROVED_<P>_ON_HEAD              - count of APPROVED reviews on HEAD SHA
#   TOTAL_<P>_ON_HEAD                 - count of all reviews on HEAD SHA
#   <P>_RETRACTED                     - true when fresh CHANGES_REQUESTED beats APPROVED
#   <P>_APPROVAL_STALE                - true when approval predates HEAD commit (issue #836)
#   <P>_APPROVAL_FRESHNESS_UNKNOWN    - true when LAST_COMMIT_TS is unavailable
#   <P>_APPROVAL_SUBMITTED_AT_MISSING - true when APPROVED has no submitted_at
#   <P>_SUBSTANTIVE                   - true when bot left substantive evidence (issue #875)
#
# The following derivations are kept in the calling scope so their exact formulas
# remain grep-findable for structural tests (ts-normalizer-parity.test.sh):
#   <P>_STALE_REDEEMED, <P>_APPROVAL_STALE_BLOCKING, <P>_APPROVAL_VALID, <P>_HOLLOW
#
# Reads globals: REVIEWS_JSON, HEAD_SHA, LAST_COMMIT_TS, REVIEW_EVIDENCE.
# Compatible with bash 3.2: uses eval for dynamic variable names, no namerefs.
_fetch_bot_approvals() { # <PREFIX> <login>
  local _p="$1" _login="$2"
  local _approved_at _changes_at _approved_count _total_count

  # Fetch review timestamps and counts on HEAD SHA.
  _approved_at=$(echo "$REVIEWS_JSON" | jq -r --arg sha "$HEAD_SHA" --arg login "$_login" '
    [.[]?
      | select(.user.login == $login and .commit_id == $sha and .state == "APPROVED")
      | .submitted_at]
    | sort | last // ""')
  _changes_at=$(echo "$REVIEWS_JSON" | jq -r --arg sha "$HEAD_SHA" --arg login "$_login" '
    [.[]?
      | select(.user.login == $login and .commit_id == $sha and .state == "CHANGES_REQUESTED")
      | .submitted_at]
    | sort | last // ""')
  _approved_count=$(echo "$REVIEWS_JSON" | jq --arg sha "$HEAD_SHA" --arg login "$_login" '
    [.[]? | select(.user.login == $login and .commit_id == $sha and .state == "APPROVED")]
    | length')
  _total_count=$(echo "$REVIEWS_JSON" | jq --arg sha "$HEAD_SHA" --arg login "$_login" '
    [.[]? | select(.user.login == $login and .commit_id == $sha)]
    | length')

  eval "LATEST_${_p}_APPROVED_AT=\$_approved_at"
  eval "LATEST_${_p}_CHANGES_REQUESTED_AT=\$_changes_at"
  eval "APPROVED_${_p}_ON_HEAD=\$_approved_count"
  eval "TOTAL_${_p}_ON_HEAD=\$_total_count"

  # Retraction: later CHANGES_REQUESTED on same SHA invalidates APPROVED (ISO timestamps).
  # Freshness guard (issue #836): GitHub retargets commit_id on force-push, so a
  # pre-push CHANGES_REQUESTED can appear on HEAD while predating the commit.
  # Only treat as retraction if the CHANGES_REQUESTED is itself fresh
  # (submitted_at >= LAST_COMMIT_TS). When LAST_COMMIT_TS is unknown, skip
  # retraction — the approval's own freshness check will block via
  # <P>_APPROVAL_FRESHNESS_UNKNOWN.
  eval "${_p}_RETRACTED=false"
  if [[ "$_approved_count" -ge 1 && -n "$_changes_at" && -n "$_approved_at" ]]; then
    if [[ "$(norm_ts "$_changes_at")" > "$(norm_ts "$_approved_at")" ]]; then
      if [[ -n "$LAST_COMMIT_TS" && ! "$(norm_ts "$_changes_at")" < "$(norm_ts "$LAST_COMMIT_TS")" ]]; then
        eval "${_p}_RETRACTED=true"
      fi
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
  eval "${_p}_APPROVAL_STALE=false"
  eval "${_p}_APPROVAL_FRESHNESS_UNKNOWN=false"
  # Separate flag for missing submitted_at (distinct from LAST_COMMIT_TS missing):
  # the approval's timestamp is absent — different cause, different user message.
  eval "${_p}_APPROVAL_SUBMITTED_AT_MISSING=false"
  local _p_retracted_var="${_p}_RETRACTED"
  if [[ "$_approved_count" -ge 1 && "${!_p_retracted_var}" == false ]]; then
    if [[ -z "$LAST_COMMIT_TS" ]]; then
      eval "${_p}_APPROVAL_FRESHNESS_UNKNOWN=true"
    elif [[ -z "$_approved_at" ]]; then
      # submitted_at is missing from the approval itself (not a transient API
      # failure) — cannot verify freshness (fail-closed, issue #836).
      eval "${_p}_APPROVAL_SUBMITTED_AT_MISSING=true"
    elif [[ "$(norm_ts "$_approved_at")" < "$(norm_ts "$LAST_COMMIT_TS")" ]]; then
      eval "${_p}_APPROVAL_STALE=true"
    fi
  fi

  # Review-substance verdict (issue #875). `counts_as_coverage` folds temporal
  # inversion, capability failure, self-report SHA mismatch and footprint
  # substance into one boolean; `disqualified_by` carries the reasons so the
  # missing[] entry can say WHY rather than "need 1 approval".
  local _substantive
  _substantive=$(substance_ok "$_login")
  eval "${_p}_SUBSTANTIVE=\$_substantive"
}

# CR-path approval detection — shared by the cr) and bugbot) cases (issue #865).
# On the cr) path these variables are also consumed by the MISSING-entry section
# and the supplemental CodeAnt gate below. On the bugbot) path only
# CR_PATH_APPROVED_ON_HEAD is used (for the bypass). Guard ensures the jq
# computations only run when relevant; all variables are zero-valued here so
# the cr) MISSING section works correctly even when the guard does not fire.
CR_PATH_APPROVED_ON_HEAD=false
LATEST_CR_APPROVED_AT=""
LATEST_CR_CHANGES_REQUESTED_AT=""
APPROVED_CR_ON_HEAD=0
TOTAL_CR_ON_HEAD=0
LATEST_CA_APPROVED_AT=""
LATEST_CA_CHANGES_REQUESTED_AT=""
APPROVED_CA_ON_HEAD=0
TOTAL_CA_ON_HEAD=0
CR_RETRACTED=false
CA_RETRACTED=false
CR_APPROVAL_STALE=false
CR_APPROVAL_FRESHNESS_UNKNOWN=false
CR_APPROVAL_SUBMITTED_AT_MISSING=false
CA_APPROVAL_STALE=false
CA_APPROVAL_FRESHNESS_UNKNOWN=false
CA_APPROVAL_SUBMITTED_AT_MISSING=false
CR_APPROVAL_STALE_BLOCKING=false
CA_APPROVAL_STALE_BLOCKING=false
if [[ "$REVIEWER" == "cr" || "$REVIEWER" == "bugbot" ]]; then
  # Fetch review stats, retraction, stale-approval, and substance checks for each
  # bot (issue #936 extraction). Redemption (<P>_STALE_REDEEMED), blocking
  # (<P>_APPROVAL_STALE_BLOCKING), and validity (<P>_APPROVAL_VALID/<P>_HOLLOW)
  # are derived in the main scope so their formulas remain grep-findable for
  # structural tests (ts-normalizer-parity.test.sh).
  _fetch_bot_approvals CR "coderabbitai[bot]"
  _fetch_bot_approvals CA "codeant-ai[bot]"

  # <P>_APPROVAL_STALE (set by _fetch_bot_approvals) is the unchanged #836
  # norm_ts verdict — redemption is a SEPARATE, separately-named term rather
  # than a loosening of the ordering rule, so the timestamp comparison keeps
  # exactly one meaning. <P>_APPROVAL_STALE_BLOCKING is what the rest of the
  # path consumes. Redemption cannot fire unless the approval is stale in the
  # first place, so the fresh path is byte-for-byte unaffected.
  CR_STALE_REDEEMED=false
  CA_STALE_REDEEMED=false
  if [[ "$CR_APPROVAL_STALE" == true && "$(external_evidence_ok "coderabbitai[bot]")" == true ]]; then
    CR_STALE_REDEEMED=true
    echo "[merge-gate] CodeRabbit APPROVED on ${HEAD_SHA:0:7} has a stale submitted_at ($LATEST_CR_APPROVED_AT < $LAST_COMMIT_TS) but left substantive evidence on this SHA outside the review object — counting it as fresh (issue #876)." >&2
  fi
  if [[ "$CA_APPROVAL_STALE" == true && "$(external_evidence_ok "codeant-ai[bot]")" == true ]]; then
    CA_STALE_REDEEMED=true
    echo "[merge-gate] CodeAnt APPROVED on ${HEAD_SHA:0:7} has a stale submitted_at ($LATEST_CA_APPROVED_AT < $LAST_COMMIT_TS) but left substantive evidence on this SHA outside the review object — in-place re-review edit, counting it as fresh (issue #876)." >&2
  fi
  CR_APPROVAL_STALE_BLOCKING=false
  CA_APPROVAL_STALE_BLOCKING=false
  if [[ "$CR_APPROVAL_STALE" == true && "$CR_STALE_REDEEMED" == false ]]; then
    CR_APPROVAL_STALE_BLOCKING=true
  fi
  if [[ "$CA_APPROVAL_STALE" == true && "$CA_STALE_REDEEMED" == false ]]; then
    CA_APPROVAL_STALE_BLOCKING=true
  fi

  # Separate axis from the #876 staleness redemption above: that one asks
  # whether the approval object is FRESH, this one whether anything actually
  # reviewed the commit. Both are announced; neither substitutes for the other.
  announce_clean_run_redemption "CodeRabbit" "coderabbitai[bot]"
  announce_clean_run_redemption "CodeAnt" "codeant-ai[bot]"

  # CR_HOLLOW / CA_HOLLOW: the approval cleared every pre-#875 check (present,
  # fresh, not retracted) but nothing evidences that a review happened. Kept
  # distinct from "absent" so callers know to wait for the reviewer's real pass
  # rather than conclude no approval exists.
  CR_APPROVAL_VALID=false
  CR_HOLLOW=false
  if [[ "$APPROVED_CR_ON_HEAD" -ge 1 && "$CR_RETRACTED" == false \
        && "$CR_APPROVAL_STALE_BLOCKING" == false && "$CR_APPROVAL_FRESHNESS_UNKNOWN" == false \
        && "$CR_APPROVAL_SUBMITTED_AT_MISSING" == false ]]; then
    if [[ "$CR_SUBSTANTIVE" == true ]]; then
      CR_APPROVAL_VALID=true
    elif [[ "$ALLOW_HOLLOW" == true && "$(override_eligible "coderabbitai[bot]")" == true ]]; then
      CR_APPROVAL_VALID=true
      echo "[merge-gate] --allow-hollow-approval: counting CodeRabbit APPROVED on ${HEAD_SHA:0:7} despite no substantive review evidence ($(substance_reasons "coderabbitai[bot]"))." >&2
    else
      CR_HOLLOW=true
    fi
  fi
  CA_APPROVAL_VALID=false
  CA_HOLLOW=false
  if [[ "$APPROVED_CA_ON_HEAD" -ge 1 && "$CA_RETRACTED" == false \
        && "$CA_APPROVAL_STALE_BLOCKING" == false && "$CA_APPROVAL_FRESHNESS_UNKNOWN" == false \
        && "$CA_APPROVAL_SUBMITTED_AT_MISSING" == false ]]; then
    if [[ "$CA_SUBSTANTIVE" == true ]]; then
      CA_APPROVAL_VALID=true
    elif [[ "$ALLOW_HOLLOW" == true && "$(override_eligible "codeant-ai[bot]")" == true ]]; then
      CA_APPROVAL_VALID=true
      echo "[merge-gate] --allow-hollow-approval: counting CodeAnt APPROVED on ${HEAD_SHA:0:7} despite no substantive review evidence ($(substance_reasons "codeant-ai[bot]"))." >&2
    else
      CA_HOLLOW=true
    fi
  fi

  if [[ "$CR_APPROVAL_VALID" == true || "$CA_APPROVAL_VALID" == true ]]; then
    CR_PATH_APPROVED_ON_HEAD=true
  fi
fi

# Path-specific checks.
# Default false — the cr) and bugbot) paths set a meaningful value.
PRIMARY_REVIEW_MET=false
case "$REVIEWER" in
  cr)

    # Set PRIMARY_REVIEW_MET from the shared pre-case detection block (issue #865).
    # All CR/CA approval variables (CR_APPROVAL_VALID, CA_APPROVAL_VALID, etc.)
    # were computed there for both the cr and bugbot paths.
    PRIMARY_REVIEW_MET=$CR_PATH_APPROVED_ON_HEAD

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
      if [[ "$CR_APPROVAL_STALE_BLOCKING" == true && "$CA_APPROVAL_VALID" != true ]]; then
        MISSING+=("CodeRabbit approval on HEAD ${HEAD_SHA:0:7} predates the HEAD commit (force-push retargeting) — re-review required; trigger @coderabbitai full review")
      fi
      if [[ "$CA_APPROVAL_STALE_BLOCKING" == true && "$CR_APPROVAL_VALID" != true ]]; then
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
      # Hollow approvals (issue #875) — an APPROVED exists and is fresh, but
      # nothing evidences a review of this commit. Distinct message per bot so
      # the reader sees which reviewer rubber-stamped and on what basis.
      if [[ "$CR_HOLLOW" == true ]]; then
        MISSING+=("CodeRabbit APPROVED on HEAD ${HEAD_SHA:0:7} is not review coverage: $(substance_reasons "coderabbitai[bot]") — wait for a real review pass or trigger @coderabbitai full review (issue #875)")
      fi
      if [[ "$CA_HOLLOW" == true ]]; then
        MISSING+=("CodeAnt APPROVED on HEAD ${HEAD_SHA:0:7} is not review coverage: $(substance_reasons "codeant-ai[bot]") — wait for a real review pass or comment @codeant-ai review (issue #875)")
      fi
      if [[ "$CR_RETRACTED" != true && "$CA_RETRACTED" != true \
            && "$CR_APPROVAL_STALE_BLOCKING" != true && "$CA_APPROVAL_STALE_BLOCKING" != true \
            && "$CR_APPROVAL_FRESHNESS_UNKNOWN" != true && "$CA_APPROVAL_FRESHNESS_UNKNOWN" != true \
            && "$CR_APPROVAL_SUBMITTED_AT_MISSING" != true && "$CA_APPROVAL_SUBMITTED_AT_MISSING" != true \
            && "$CR_HOLLOW" != true && "$CA_HOLLOW" != true ]]; then
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
        if [[ "$CA_APPROVAL_STALE_BLOCKING" == true && "$CA_STALE_MISSING_EMITTED" != true ]]; then
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
        elif [[ "$CA_APPROVAL_STALE_BLOCKING" != true && "$CA_HOLLOW" != true ]]; then
          # None of the freshness/stale conditions apply — emit the generic "no review"
          # message. The CA_APPROVAL_STALE_BLOCKING guard prevents emitting this alongside the
          # stale message when CA_STALE_MISSING_EMITTED was already set by the primary block.
          # CA_HOLLOW (issue #875) is excluded for the same reason: an approval DOES
          # exist, it just is not coverage, and the primary block already said so —
          # claiming "no explicit APPROVED review" here would contradict it.
          #
          # A hollow CodeAnt deliberately does NOT block when CodeRabbit's approval is
          # genuine (BugBot review, PR #883). cr-merge-gate.md's CR path is "either bot
          # alone suffices", and coverage demonstrably exists. Blocking here would make
          # every PR hostage to a bot that is currently rubber-stamping — the
          # false-negative cost this evaluator is explicitly written to avoid. The
          # rubber stamp is not absorbed silently either way: it stays in
          # review_evidence.hollow[] and is announced on stderr below.
          MISSING+=("CodeAnt participated on HEAD ${HEAD_SHA:0:7} but no explicit APPROVED review and no successful CodeAnt check-run (have $TOTAL_CA_ON_HEAD CodeAnt review(s) on this SHA) — wait or comment @codeant-ai review")
        fi
      fi
    fi

    ;;

  bugbot)
    # Issue #865: a fresh CR-path APPROVED on the current HEAD SHA satisfies the
    # gate even when the reviewer is sticky-bugbot. The sticky pointer in
    # session-state.json remains unchanged; only the gate outcome changes.
    # All freshness, retraction, and substance guards (#836, #875, #876, #893)
    # apply — set in the shared pre-case block above.
    if [[ "$CR_PATH_APPROVED_ON_HEAD" == true ]]; then
      PRIMARY_REVIEW_MET=true
    else
      # BugBot clean pass (issue #844 — aligned with bugbot.md "Completion signal"):
      # either a cursor[bot] review object on current HEAD (original path), OR a
      # completed Cursor Bugbot check-run with conclusion:success on HEAD (the
      # "silent pass" shape — BugBot passes cleanly but posts no review object).
      # Only conclusion:success counts; conclusion:neutral means BugBot posted findings
      # and still requires a review object. Unresolved BugBot threads are caught by
      # the universal unresolved-thread gate above.
      BB_REVIEWS_ON_HEAD=$(echo "$REVIEWS_JSON" | jq --arg sha "$HEAD_SHA" '
        [.[]? | select(.user.login == "cursor[bot]" and .commit_id == $sha)] | length')

      # Failure-phrase scan across all cursor[bot] comment endpoints (mirrors the
      # is_failure_text regex in escalate-review.sh). A success check-run accompanied
      # by a failure-phrase comment is NOT a clean pass (bugbot.md "BugBot failure
      # detection"). Scan PR comments + issue/conversation comments; review bodies
      # are handled inside the review-object path below.
      # Freshness filter (issue #844 fix): only comments posted AFTER the HEAD commit
      # count as blocking. Stale failure-phrase comments from a prior push must not
      # strand the gate after a fresh success check-run arrives. Fail-open when
      # LAST_COMMIT_TS is unknown; fail-closed when the comment has no created_at.
      BB_HAS_FAILURE_COMMENT=$(
        { printf '%s\n' "$PR_COMMENTS_JSON"; printf '%s\n' "$ISSUE_COMMENTS_JSON"; } | jq -rs --arg after "${LAST_COMMIT_TS:-}" '
          def is_failure_text: test("couldn'"'"'t run|could not run|usage limit|usage or spend limit"; "i");
          add // [] | [.[]? | select(.user.login == "cursor[bot]")
              | select((.body // "") | is_failure_text)
              | select(if $after == "" then true
                       elif (.created_at // "") == "" then true
                       else .created_at > $after end)]
          | length > 0')

      # Check-run-based clean pass (issue #844): Cursor Bugbot check-run with
      # conclusion:success on HEAD, published by the Cursor app, no failure-phrase
      # cursor[bot] comment, and freshness (completed_at/started_at >=
      # LAST_COMMIT_TS). Read from the already-deduped HEAD-scoped
      # CHECK_RUNS_JSON — no new gh api fetch.
      # Only evaluated when no review object exists; if a review object is present,
      # the review-object path below applies (and may add its own MISSING entries).
      #
      # Publisher scoping (issue #962): GitHub lets ANY app publish a check-run
      # under ANY name, so the name `Cursor Bugbot` identifies a check, never a
      # publisher — check-runs-dedup.sh has grouped by [.app.slug, .app.id, .name]
      # since issue #675 for exactly this reason. escalate-review.sh scoped its two
      # name-only selectors to the app in issue #956; this is the same defect on the
      # gate-SATISFYING half, where the cost is strictly higher: there an
      # unattributable run misroutes an escalation, here it would merge the PR.
      #
      # The failure DIRECTION is therefore the opposite of escalate-review.sh's.
      # There, unverifiable identity fails toward "not a BugBot footprint" and the
      # worst case is one duplicate `@cursor review` (harmless per bugbot.md). Here
      # it fails CLOSED: a foreign, absent, or empty app slug never satisfies the
      # gate, and the worst case is the gate waiting for a genuine review object.
      #
      # The candidate is still selected by NAME ALONE — deliberately the same
      # selector as before this change. Two reasons: (1) a same-named run from
      # another publisher stays visible as a candidate, so the block gets its own
      # legible MISSING[] reason instead of collapsing into the generic "no BugBot
      # review on HEAD"; (2) selecting identically to the pre-change code makes this
      # a pure subtraction — every shape that satisfied the path before either still
      # does (slug `cursor`) or now blocks. Preferring a cursor-published run over an
      # equally-named foreign one would be a widening, and could newly satisfy the
      # gate on a payload where the old `last` picked the non-success foreign run.
      #
      # Slug `cursor` is the publisher confirmed live on this repo (app id 1210556,
      # app name "Cursor") — same identity escalate-review.sh matches.
      BB_CHECK_CLEAN=false
      BB_CHECK_FRESHNESS_ERR=false
      BB_CHECK_APP_MISMATCH=false
      if [[ "$BB_REVIEWS_ON_HEAD" -lt 1 && "$BB_HAS_FAILURE_COMMENT" != "true" ]]; then
        BB_CHECK_RUN=$(echo "$CHECK_RUNS_JSON" | jq -c '
          [.check_runs[]? | select((.name // "") == "Cursor Bugbot")] | last // empty')
        if [[ -n "$BB_CHECK_RUN" ]]; then
          BB_CHECK_CONCLUSION=$(echo "$BB_CHECK_RUN" | jq -r '.conclusion // ""')
          BB_CHECK_STATUS=$(echo "$BB_CHECK_RUN" | jq -r '.status // ""')
          BB_CHECK_TS=$(echo "$BB_CHECK_RUN" | jq -r '(.completed_at // .started_at // "")')
          BB_CHECK_APP_SLUG=$(echo "$BB_CHECK_RUN" | jq -r '.app.slug // ""')
          if [[ "$BB_CHECK_STATUS" == "completed" && "$BB_CHECK_CONCLUSION" == "success" ]]; then
            if [[ "$BB_CHECK_APP_SLUG" != "cursor" ]]; then
              # Fail-closed (issue #962): the run cannot be attributed to the Cursor
              # app, so it is not BugBot's silent pass no matter what it is named.
              # Checked ahead of freshness because an unattributable run's timestamp
              # is not worth dating. Distinct reason so the block is legible rather
              # than reading as "BugBot never ran".
              MISSING+=("BugBot check-run on HEAD ${HEAD_SHA:0:7} was not published by the Cursor app (app slug \"${BB_CHECK_APP_SLUG:-<none>}\", expected \"cursor\") — cannot verify publisher; wait for a Cursor-published run or post @cursor review")
              BB_CHECK_APP_MISMATCH=true
            elif [[ -z "$LAST_COMMIT_TS" ]]; then
              # Fail-closed: cannot verify freshness without HEAD committer date.
              # Callers poll every ~60 s, so a transient API failure self-heals.
              MISSING+=("cannot verify BugBot check-run freshness — HEAD commit timestamp unavailable; retrying next cycle")
              BB_CHECK_FRESHNESS_ERR=true
            elif [[ -z "$BB_CHECK_TS" ]]; then
              # Fail-closed: cannot verify freshness without check-run timestamp
              # (mirrors CodeAnt supplemental gate — empty completed_at/started_at
              # never counts as clean when LAST_COMMIT_TS is known).
              MISSING+=("cannot verify BugBot check-run freshness — completed_at/started_at unavailable; retrying next cycle")
              BB_CHECK_FRESHNESS_ERR=true
            elif [[ "$(norm_ts "$BB_CHECK_TS")" < "$(norm_ts "$LAST_COMMIT_TS")" ]]; then
              # check-run completed before the HEAD commit — stale (force-push retargeting
              # or a prior push's run). Report explicitly so callers know to wait for a
              # new run rather than interpret as absent.
              MISSING+=("BugBot check-run on HEAD ${HEAD_SHA:0:7} predates the HEAD commit (stale) — wait for re-run or post @cursor review")
              BB_CHECK_FRESHNESS_ERR=true
            else
              # Fresh success check-run, no failure comments — clean silent pass.
              BB_CHECK_CLEAN=true
            fi
          fi
        fi
      fi

      if [[ "$BB_REVIEWS_ON_HEAD" -lt 1 ]]; then
        if [[ "$BB_CHECK_CLEAN" != true && "$BB_CHECK_FRESHNESS_ERR" != true \
              && "$BB_CHECK_APP_MISMATCH" != true ]]; then
          # No review object, no clean check-run, no freshness or publisher error
          # already reported.
          MISSING+=("no BugBot review on HEAD ${HEAD_SHA:0:7}")
        fi
        # BB_CHECK_CLEAN=true  → silent-pass check-run satisfies the gate (issue #844)
        # BB_CHECK_FRESHNESS_ERR=true → freshness error already added to MISSING above
        # BB_CHECK_APP_MISMATCH=true  → publisher error already added to MISSING above (issue #962)
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
    fi
    ;;

  greptile)
    # Severity-gated. Greptile-specific count handling is intentionally NOT here —
    # the universal unresolved-thread gate above already reports the count for any
    # unresolved thread. This path adds severity context (P0 vs P1/P2) only.
    #
    # Greptile posts via issue comments (not formal PR review objects). Detection
    # (issue #723 — observed live on PR #721; corrected by issue #1390):
    #   Clean pass: latest fresh greptile-apps[bot] summary comment whose
    #     "Last reviewed commit" footer names the current HEAD SHA, AND zero
    #     greptile-apps[bot] inline diff comments on the PR, AND zero formal P0
    #     badges in the current review round.
    #   Why the footer and not the 👍: issue #723 keyed the clean pass on a 👍
    #     (+1) reaction carried by the bot's own comment, but Greptile reacts to
    #     the comment it is REPLYING TO — the @greptileai trigger, authored by
    #     whoever asked for the review — so the bot comment sits at +1 == 0 on a
    #     genuinely clean pass (measured on PR #1379). The footer SHA is also
    #     strictly better evidence: it is checkable against HEAD rather than
    #     merely present, and survives another vendor change to reactions.
    #   The bot-comment 👍 is retained only as a SUPPLEMENTAL alternative, so a
    #     reaction that does land on the bot comment still counts.
    #   Freshness: comment.created_at > LAST_COMMIT_TS (mirrors the BugBot
    #     push-timestamp lesson — repo memory feedback_bugbot_commit_id_stale).
    #   Formal review objects (pulls/{N}/reviews) are kept as supplemental signal.

    # Only an exact trigger command from the PR author establishes a trusted
    # paid-review round boundary. If GitHub cannot resolve the author, degrade
    # conservatively: the latest exact command from any account is a boundary,
    # but is not treated as authenticated. Otherwise an unanswered author
    # trigger could disappear with PR_AUTHOR and stale clean evidence could pass.
    if [[ -n "$PR_AUTHOR" ]]; then
      G_LATEST_TRIGGER_TS=$(echo "$ISSUE_COMMENTS_JSON" | jq -r --arg author "$PR_AUTHOR" '
        def canon_ts: sub("(Z|\\+00:00|\\+0000)$"; "");
        [.[]?
          | select(.user.login == $author)
          | select(((.body // "")
              | gsub("^[[:space:]]+|[[:space:]]+$"; "")
              | ascii_downcase) == "@greptileai")
          | {raw:(((.updated_at // .created_at) // "")),
             canon:((((.updated_at // .created_at) // "") | canon_ts))}]
        | sort_by(.canon) | last.raw // ""')
    else
      G_LATEST_TRIGGER_TS=$(echo "$ISSUE_COMMENTS_JSON" | jq -r '
        def canon_ts: sub("(Z|\\+00:00|\\+0000)$"; "");
        [.[]?
          | select(((.body // "")
              | gsub("^[[:space:]]+|[[:space:]]+$"; "")
              | ascii_downcase) == "@greptileai")
          | {raw:(((.updated_at // .created_at) // "")),
             canon:((((.updated_at // .created_at) // "") | canon_ts))}]
        | sort_by(.canon) | last.raw // ""')
    fi
    G_LATEST_TRIGGER_NORM=$(norm_ts "$G_LATEST_TRIGGER_TS")

    # A post-push trigger starts a newer round than the push itself. Anchor all
    # fresh-path evidence after the newer boundary so evidence from an earlier
    # round cannot satisfy (or poison) a still-unanswered latest trigger.
    G_FRESH_AFTER="${LAST_COMMIT_TS:-}"
    if [[ -n "$G_LATEST_TRIGGER_TS" ]] \
        && [[ -z "$G_FRESH_AFTER" || "$G_LATEST_TRIGGER_NORM" > "$(norm_ts "$G_FRESH_AFTER")" ]]; then
      G_FRESH_AFTER="$G_LATEST_TRIGGER_TS"
    fi
    G_FRESH_AFTER_NORM=$(norm_ts "$G_FRESH_AFTER")

    # Fresh Greptile inline diff comments (post-push/current-round only —
    # mirrors the BugBot push-timestamp lesson,
    # feedback_bugbot_commit_id_stale). Stale inline comments
    # from a prior push must NOT count: without this freshness gate, the "no review
    # yet" guard would skip when stale inline comments exist, and Path B would then
    # pass cleanly on an empty review body (no fresh Greptile signal on the new HEAD).
    # G_INLINE_BODIES in Path B uses the same push-or-latest-trigger boundary.
    G_INLINE_COUNT=$(echo "$PR_COMMENTS_JSON" | jq --arg after "$G_FRESH_AFTER_NORM" '
      def canon_ts: sub("(Z|\\+00:00|\\+0000)$"; "");
      [.[]? | select(.user.login == "greptile-apps[bot]")
              | select(if $after == "" then true
                  else ((.created_at // "") | canon_ts) > $after end)] | length')

    # Latest FRESH Greptile issue comment (created OR updated after the last push).
    # Greptile edits its summary comment in-place on re-review rather than posting a
    # new one (observed on PR #734 — rebased + force-pushed; re-review updated the
    # existing summary comment at updated_at 03:05:28Z after the 02:50:10Z push while
    # created_at stayed at the original post time). Accept the comment as fresh when
    # either timestamp is post-push (issue #748).
    LATEST_G_COMMENT=$(echo "$ISSUE_COMMENTS_JSON" | jq -c --arg after "$G_FRESH_AFTER_NORM" '
      def canon_ts: sub("(Z|\\+00:00|\\+0000)$"; "");
      [.[]?
        | select(.user.login == "greptile-apps[bot]")
        | . as $comment
        | ([($comment.created_at // ""), ($comment.updated_at // "")]
            | map(canon_ts) | max) as $signal_at
        | select(if $after == "" then true else $signal_at > $after end)
        | {comment:$comment, signal_at:$signal_at}]
      | sort_by(.signal_at) | last.comment // empty')

    # Latest FRESH Greptile formal review (belt-and-suspenders supplemental
    # signal). Formal reviews need the same post-push boundary as comments;
    # otherwise a stale formal review can bypass the durable-round fallback.
    LATEST_G=$(echo "$REVIEWS_JSON" | jq -c --arg after "$G_FRESH_AFTER_NORM" '
      def canon_ts: sub("(Z|\\+00:00|\\+0000)$"; "");
      [.[]?
        | select(.user.login == "greptile-apps[bot]")
        | select(if $after == "" then true
            else ((.submitted_at // "") | canon_ts) > $after end)
        | {review:., signal_at:((.submitted_at // "") | canon_ts)}]
      | sort_by(.signal_at) | last.review // empty')

    if [[ -z "$LATEST_G" && -z "$LATEST_G_COMMENT" && "$G_INLINE_COUNT" -eq 0 ]]; then
      # No current-HEAD signal. Reuse the latest completed Greptile review
      # round only when that round contains zero formal P0 badges (issue #1000).
      # The durable round boundary is the latest @greptileai trigger recorded in
      # GitHub issue-comment history. This prevents an older clean review from
      # satisfying the gate while a newer paid re-review is still unanswered,
      # and lets a later clean re-review supersede an older P0 round.
      # Greptile may edit its summary in place, so updated_at is its effective
      # signal time. Inline comments and formal reviews retain creation/submission
      # timestamps. The latest timestamp across all three channels proves that
      # Greptile produced evidence after the latest trigger.
      G_LATEST_HISTORY_COMMENT_TS=$(echo "$ISSUE_COMMENTS_JSON" | jq -r '
        def canon_ts: sub("(Z|\\+00:00|\\+0000)$"; "");
        [.[]? | select(.user.login == "greptile-apps[bot]")
          | ((.updated_at // .created_at) // "") | canon_ts]
        | sort | last // ""')
      G_LATEST_HISTORY_REVIEW_TS=$(echo "$REVIEWS_JSON" | jq -r '
        def canon_ts: sub("(Z|\\+00:00|\\+0000)$"; "");
        [.[]? | select(.user.login == "greptile-apps[bot]")
          | (.submitted_at // "") | canon_ts]
        | sort | last // ""')
      G_LATEST_HISTORY_INLINE_TS=$(echo "$PR_COMMENTS_JSON" | jq -r '
        def canon_ts: sub("(Z|\\+00:00|\\+0000)$"; "");
        [.[]? | select(.user.login == "greptile-apps[bot]")
          | (.created_at // "") | canon_ts]
        | sort | last // ""')
      G_LATEST_EVIDENCE_TS=$(printf '%s\n%s\n%s\n' \
        "$G_LATEST_HISTORY_COMMENT_TS" "$G_LATEST_HISTORY_REVIEW_TS" \
        "$G_LATEST_HISTORY_INLINE_TS" | awk 'NF' | sort | tail -1)

      G_ROUND_COMPLETE=false
      if [[ -n "$G_LATEST_EVIDENCE_TS" ]]; then
        if [[ -z "$G_LATEST_TRIGGER_NORM" || "$G_LATEST_EVIDENCE_TS" > "$G_LATEST_TRIGGER_NORM" ]]; then
          G_ROUND_COMPLETE=true
        fi
      fi

      if [[ "$G_ROUND_COMPLETE" != true ]]; then
        # Complete absence of history and an unanswered newest trigger both fail
        # closed. Callers already know whether to poll or trigger from sticky
        # reviewer state, so keep the stable public missing reason.
        MISSING+=("no Greptile review yet")
      else
        # Scope severity evidence to the latest trigger-delimited review round.
        # If legacy history has no trigger marker, conservatively scan all
        # Greptile evidence so an old P0 cannot be silently ignored.
        G_ROUND_BODIES=$(printf '%s\n%s\n%s\n' \
          "$ISSUE_COMMENTS_JSON" "$REVIEWS_JSON" "$PR_COMMENTS_JSON" \
          | jq -rs --arg trigger "$G_LATEST_TRIGGER_NORM" '
              def canon_ts: sub("(Z|\\+00:00|\\+0000)$"; "");
              [.[0][]?
                | select(.user.login == "greptile-apps[bot]")
                | select($trigger == "" or (((.updated_at // .created_at) // "") | canon_ts) > $trigger)
                | .body // ""]
              + [.[1][]?
                | select(.user.login == "greptile-apps[bot]")
                | select($trigger == "" or ((.submitted_at // "") | canon_ts) > $trigger)
                | .body // ""]
              + [.[2][]?
                | select(.user.login == "greptile-apps[bot]")
                | select($trigger == "" or ((.created_at // "") | canon_ts) > $trigger)
                | .body // ""]
              | join("\n---\n")')
        G_ROUND_P0_COUNT=$(echo "$G_ROUND_BODIES" | grep -oF 'alt="P0"' | wc -l | tr -d ' ')

        if [[ "$G_ROUND_P0_COUNT" -gt 0 ]]; then
          MISSING+=("prior Greptile review had P0 findings — need clean re-review after fix (trigger @greptileai)")
        else
          # A stale zero-P0 verdict is reusable only for a demonstrable fix-only
          # push. Every Greptile inline finding in the retained round must have a
          # PR-author reply that names the current HEAD. This creates auditable
          # provenance between reviewed findings and the otherwise-unreviewed
          # post-round commit while the universal thread gate proves resolution.
          G_FIX_PROVENANCE=$(printf '%s\n%s\n' "$PR_COMMENTS_JSON" "$ISSUE_COMMENTS_JSON" | jq -cs \
            --arg trigger "$G_LATEST_TRIGGER_NORM" \
            --arg author "$PR_AUTHOR" \
            --arg sha "$HEAD_SHA" \
            --arg short "${HEAD_SHA:0:7}" '
              def canon_ts: sub("(Z|\\+00:00|\\+0000)$"; "");
              .[0] as $inline_comments
              | .[1] as $issue_comments
              | [$inline_comments[]?
                  | select(.user.login == "greptile-apps[bot]")
                  | select((.in_reply_to_id // null) == null)
                  | select($trigger == "" or ((.created_at // "") | canon_ts) > $trigger)
                  | .id] as $finding_ids
              | [$finding_ids[] as $finding_id
                  | select(
                      any($inline_comments[]?;
                        (.in_reply_to_id // null) == $finding_id
                        and .user.login == $author
                        and (((.body // "") | ascii_downcase) as $body
                          | ($body | contains($sha)) or ($body | contains($short))))
                      or any($issue_comments[]?;
                        .user.login == $author
                        and (((.body // "") | ascii_downcase) as $body
                          | (($body | contains($sha)) or ($body | contains($short)))
                          and ($body | test(
                            "(^|\\n)<!--[[:space:]]*review-comment-id:"
                            + ($finding_id | tostring)
                            + "[[:space:]]*-->($|\\r?\\n)")))))]
                as $proven
              | {ok:($author != ""
                    and ($proven | length) == ($finding_ids | length)),
                 finding_count:($finding_ids | length),
                 proven_count:($proven | length)}')
          if [[ "$(echo "$G_FIX_PROVENANCE" | jq -r '.ok')" != true ]]; then
            G_FINDING_COUNT=$(echo "$G_FIX_PROVENANCE" | jq -r '.finding_count')
            G_PROVEN_COUNT=$(echo "$G_FIX_PROVENANCE" | jq -r '.proven_count')
            MISSING+=("cannot verify fix-only Greptile reuse on HEAD ${HEAD_SHA:0:7} — $G_PROVEN_COUNT/$G_FINDING_COUNT latest-round finding(s) have a PR-author fix reply naming this HEAD")
          else
            echo "merge-gate: reusing latest completed zero-P0 Greptile review round with current-HEAD fix provenance (issue #1000)" >&2
          fi
        fi
      fi
    else
      # Count formal P0 badges across every signal in the current
      # trigger-delimited round. A 👍 issue comment proves completion, but it
      # must not hide a P0 that Greptile reported in that comment, a formal
      # review, or an earlier inline from the same round. Only a later trusted
      # trigger starts a round that can supersede those findings.
      P0_COUNT=$(printf '%s\n%s\n%s\n' \
        "$ISSUE_COMMENTS_JSON" "$REVIEWS_JSON" "$PR_COMMENTS_JSON" \
        | jq -rs --arg after "$G_FRESH_AFTER_NORM" '
            def canon_ts: sub("(Z|\\+00:00|\\+0000)$"; "");
            ([.[0][]?
              | select(.user.login == "greptile-apps[bot]")
              | select(if $after == "" then true
                  else ((.created_at // "") | canon_ts) > $after
                    or ((.updated_at // "") | canon_ts) > $after
                end)
              | .body // ""]
            + [.[1][]?
              | select(.user.login == "greptile-apps[bot]")
              | select(if $after == "" then true
                  else ((.submitted_at // "") | canon_ts) > $after end)
              | .body // ""]
            + [.[2][]?
              | select(.user.login == "greptile-apps[bot]")
              | select(if $after == "" then true
                  else ((.created_at // "") | canon_ts) > $after end)
              | .body // ""])
            | map([scan("alt=\\\"P0\\\"")] | length)
            | add // 0')

      # --- Path A: comment-based clean pass (primary Greptile channel) ---
      G_COMMENT_CLEAN=false
      # Empty when there is no fresh summary comment, or when that comment
      # carries no "Last reviewed commit" footer — both mean "no claim about
      # which commit was reviewed", never "reviewed a different commit".
      G_FOOTER_SHA=""
      # True only when the footer positively names some commit other than HEAD.
      # Declared out here beside G_FOOTER_SHA because Path B reads it whether or
      # not a summary comment exists, and the script runs under `set -u`.
      G_FOOTER_CONTRADICTS=false
      G_HEAD_SHA_LC=$(printf '%s' "$HEAD_SHA" | tr "[:upper:]" "[:lower:]")
      if [[ -n "$LATEST_G_COMMENT" ]]; then
        G_THUMBSUP=$(echo "$LATEST_G_COMMENT" | jq -r '.reactions["+1"] // 0')

        # Primary signal (issue #1390): Greptile closes its summary comment with
        #   Reviews (N): Last reviewed commit: [<title>](<repo-url>/commit/<sha>)
        # Extract that SHA. The link carries the full 40 characters, so it is
        # compared against the full HEAD_SHA — never the short form, which any
        # commit sharing the prefix would satisfy. The pattern is anchored on the
        # marker and confined to the marker line, so an unrelated commit link
        # elsewhere in the body cannot be read as the footer. Extraction happens
        # inside jq against .body, the same idiom as CODEANT_CONVO_ON_HEAD and
        # G_FIX_PROVENANCE. A body with no footer yields "" and is treated as
        # having made no claim (older comments, and any future format change).
        G_FOOTER_SHA=$(echo "$LATEST_G_COMMENT" | jq -r '
          ((.body // "") | ascii_downcase)
          | [scan("last reviewed commit:[^\n]*/commit/([0-9a-f]{40})")]
          | (last // []) | (.[0] // "")')
        G_FOOTER_ON_HEAD=false
        if [[ -n "$G_FOOTER_SHA" ]]; then
          if [[ "$G_FOOTER_SHA" == "$G_HEAD_SHA_LC" ]]; then
            G_FOOTER_ON_HEAD=true
          else
            G_FOOTER_CONTRADICTS=true
          fi
        fi

        # Clean = the footer names HEAD (or the supplemental bot-comment 👍),
        # no inline findings, and no formal P0 badge in any channel of the
        # current review round.
        #
        # A contradicting footer vetoes the whole branch, 👍 included. The
        # reaction is a weaker signal than the footer and cannot overrule it:
        # 👍 on a Greptile comment is a routine workflow artifact — greptile.md
        # makes 👍/👎 the bot's only learning channel — so without this veto a
        # single feedback reaction on a stale summary would mark the comment
        # clean, skip Path B entirely, and silently defeat the contradiction
        # guard below (the guard runs only when G_COMMENT_CLEAN is false).
        if [[ "$G_FOOTER_CONTRADICTS" != true ]] \
           && [[ "$G_FOOTER_ON_HEAD" == true || "$G_THUMBSUP" -gt 0 ]] \
           && [[ "$G_INLINE_COUNT" -eq 0 && "$P0_COUNT" -eq 0 ]]; then
          G_COMMENT_CLEAN=true
        fi
      fi

      if [[ "$G_COMMENT_CLEAN" != true ]]; then
        # --- Path B: severity gate ---
        # Footer that positively contradicts HEAD (issue #1390). A summary
        # comment can be fresh by timestamp and still report on an older commit:
        # Greptile edits its summary in place (#748), so updated_at moves before
        # the new round finishes. Timestamp freshness is therefore not evidence
        # about HEAD — the same lesson #836/#876 taught on the CR path — while
        # the footer states outright which commit was read. When it names some
        # commit other than HEAD, the fresh path has no verdict on HEAD to give,
        # so block and keep polling for the re-review. Only a footer that
        # disagrees blocks; a missing footer changes nothing.
        #
        # Same G_FOOTER_CONTRADICTS the Path A veto reads, so the two sites
        # cannot drift: whatever Path A refuses to call clean is exactly what
        # gets reported here.
        if [[ "$G_FOOTER_CONTRADICTS" == true ]]; then
          MISSING+=("latest Greptile summary reviewed ${G_FOOTER_SHA:0:7}, not HEAD ${HEAD_SHA:0:7} — re-review required (trigger @greptileai)")
        fi

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

# Discounted approvals (issue #875) — say so on stderr even when the gate passes
# on another reviewer, so a hollow rubber stamp is never silently absorbed.
HOLLOW_LOGINS=$(echo "$REVIEW_EVIDENCE" | jq -r '(.hollow // []) | join(", ")' 2>/dev/null || echo "")
if [[ -n "$HOLLOW_LOGINS" && "$REVIEWER" == "cr" ]]; then
  echo "[merge-gate] discounted APPROVED review(s) with no substantive review evidence on HEAD ${HEAD_SHA:0:7}: ${HOLLOW_LOGINS}. See .review_evidence for the per-reviewer detail (issue #875)." >&2
fi

STALE_JSON=$(jq -n --argjson c "${STALE_BOT_CHANGES_COUNT:-0}" '$c')

# `jq -R .` read line-by-line, so a reason containing a newline (a check-run name,
# a reviewer login) silently split into two array elements. Build the array from
# the shell array instead — one element in, one element out (issue #1219).
MISSING_JSON=$(missing_json "${MISSING[@]:-}")

# review_evidence is scoped to the cr path in the output (comment at line ~99).
# The evaluator runs on the bugbot path for bypass computation but must not
# surface its results in the JSON — a failed evaluator must never block a PR
# over a guard the bugbot path never consults.
[[ "$REVIEWER" != "cr" ]] && REVIEW_EVIDENCE='{}'

emit_json "$MET" "$REVIEWER" "$REVIEWER" "$MISSING_JSON" "$HEAD_SHA" "$CI_STATUS" "$MERGE_STATE" "$MERGEABLE" "$REVIEW_DECISION" "$CODE_OWNER_BOTS" "$HUMAN_CHANGES_ON_HEAD_JSON" "$STALE_JSON" "${UNRESOLVED_TOTAL:-0}" "$PRIMARY_REVIEW_MET" "$AUTHORSHIP" "$REVIEW_EVIDENCE" "$REQUIRED_CONTEXTS_OUT"

if [[ "$MET" == true ]]; then
  exit 0
else
  exit 1
fi
