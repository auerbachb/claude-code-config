#!/usr/bin/env bash
# post-merge-bookkeeping.sh — Log pickup-to-merge actuals before releasing claims.
# catalog: backlog-pm — Retry confirmed-merge estimate logging and issue-claim cleanup in evidence-preserving order
# Usage: post-merge-bookkeeping.sh PR [--repo owner/repo]
# Exit: 0 completed/best-effort warning; 2 usage; 3 not confirmed merged.
# Only a confirmed merge permits writes. Operational bookkeeping failures never
# turn an already successful merge into failure. Historical rows are untouched.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR=""; REPO=""; REPO_EXPLICIT=0
usage() { echo 'Usage: post-merge-bookkeeping.sh PR [--repo owner/repo]'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --repo) [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }; REPO="$2"; REPO_EXPLICIT=1; shift 2 ;;
    *) [[ -z "$PR" && "$1" =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 2; }; PR="$1"; shift ;;
  esac
done
[[ -n "$PR" ]] || { usage >&2; exit 2; }
if [[ -z "$REPO" ]]; then
  REMOTE=$(git remote get-url origin 2>/dev/null || true)
  case "$REMOTE" in
    git@github.com:*|https://github.com/*|ssh://git@github.com/*)
      REPO="${REMOTE#*github.com}"; REPO="${REPO#[:/]}"; REPO="${REPO%.git}" ;;
  esac
fi
if [[ ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  if [[ "$REPO_EXPLICIT" -eq 1 ]]; then usage >&2; exit 2; fi
  echo 'WARN: post-merge-bookkeeping: repository unresolved; no writes attempted' >&2
  exit 0
fi
if ! command -v jq >/dev/null 2>&1 || ! command -v gh >/dev/null 2>&1; then
  echo 'WARN: post-merge-bookkeeping: jq or gh missing; no writes attempted' >&2
  exit 0
fi
META=$(gh pr view "$PR" --repo "$REPO" --json state,mergedAt 2>/dev/null) || META=""
if ! printf '%s' "$META" | jq -e 'type == "object" and .state == "MERGED" and (.mergedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and ((try fromdateiso8601 catch null) | type == "number"))' >/dev/null 2>&1; then
  jq -cn --arg repo "$REPO" --argjson pr "$PR" '{repo:$repo,pr:$pr,status:"not_confirmed_merged",issues:[]}'
  exit 3
fi
MERGED_AT=$(printf '%s' "$META" | jq -r ' .mergedAt')
ISSUES=""; PRIMARY=""; PICKUP="unknown"
if [[ -x "$SCRIPT_DIR/pr-issue-ref.sh" ]]; then
  REF_RC=0
  ISSUES=$(GH_REPO="$REPO" "$SCRIPT_DIR/pr-issue-ref.sh" "$PR" 2>/dev/null) || REF_RC=$?
  if [[ "$REF_RC" -gt 1 ]]; then
    echo "WARN: post-merge-bookkeeping: PR #$PR issue lookup failed (exit $REF_RC); no claim cleanup set available" >&2
    ISSUES=""
  fi
  PRIMARY=$(GH_REPO="$REPO" "$SCRIPT_DIR/pr-issue-ref.sh" --first "$PR" 2>/dev/null) || PRIMARY=""
else
  echo "WARN: post-merge-bookkeeping: PR #$PR issue resolver missing" >&2
fi
# Capture every linked issue before the logger can wait. Unknown ownership
# is never permission to release; check receipts carry the exact observed ID.
OBSERVED='[]'
if [[ -x "$SCRIPT_DIR/issue-claim.sh" ]]; then
  while IFS= read -r ISSUE; do
    [[ "$ISSUE" =~ ^[1-9][0-9]*$ ]] || continue
    CLAIM=$("$SCRIPT_DIR/issue-claim.sh" "$ISSUE" --check --repo "$REPO" --json 2>/dev/null) || true
    if printf '%s' "$CLAIM" | jq -e --arg repo "$REPO" --argjson issue "$ISSUE" --arg merged "$MERGED_AT" '
      type == "object" and .repo == $repo and .issue == $issue and has("claim_comment_id")
      and (.verdict as $v | ["unclaimed","mine","claimed","stale"] | index($v) != null)
      and (.claim_comment_id | . == null or (type == "number" and . > 0 and floor == .))
      and (if .claim_comment_id == null then true else
        (.claimed_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
        and (try ((.claimed_at | fromdateiso8601) < ($merged | fromdateiso8601)) catch false)
      end)
    ' >/dev/null 2>&1; then
      OBSERVED_ID=$(printf '%s' "$CLAIM" | jq -c '.claim_comment_id // "none"')
      OBSERVED=$(printf '%s' "$OBSERVED" | jq -c --argjson issue "$ISSUE" --argjson id "$OBSERVED_ID" '. + [{issue:$issue,id:$id}]')
      if [[ "$ISSUE" == "$PRIMARY" ]]; then
        PICKUP=$(printf '%s' "$CLAIM" | jq -er '.claimed_since // .claimed_at // "unknown" | select(type == "string" and length > 0)' 2>/dev/null) || PICKUP="unknown"
      fi
    fi
  done <<< "$ISSUES"
fi
APPEND=missing; LOG_RC=0; LOG_OUT=""
if [[ -x "$SCRIPT_DIR/estimate-log.sh" ]]; then
  APPEND=completed
  LOG_OUT=$("$SCRIPT_DIR/estimate-log.sh" --append "$PR" --repo "$REPO" 2>&1) || LOG_RC=$?
  if [[ "$LOG_RC" -ne 0 || -n "$LOG_OUT" ]]; then APPEND=warning; fi
fi
if [[ "$APPEND" != completed ]]; then
  echo "WARN: post-merge-bookkeeping: repo=$REPO PR #$PR issue=${PRIMARY:-unknown} pickup=$PICKUP append=$APPEND exit=$LOG_RC ${LOG_OUT}" >&2
fi
# Release AFTER the append attempt, including warning paths. The real claim
# helper preserves foreign-account ownership and its partial-cleanup fencing.
FAILED='[]'
while IFS= read -r ISSUE; do
  [[ -n "$ISSUE" ]] || continue
  if [[ ! "$ISSUE" =~ ^[1-9][0-9]*$ ]]; then
    echo "WARN: post-merge-bookkeeping: invalid linked issue; skipped" >&2
    continue
  fi
  if ! OBSERVED_ID=$(printf '%s' "$OBSERVED" | jq -er --argjson issue "$ISSUE" '.[] | select(.issue == $issue) | .id'); then
    FAILED=$(printf '%s' "$FAILED" | jq -c --argjson issue "$ISSUE" '. + [$issue]')
    echo "WARNING: claim ownership unreadable or not proven before this merge for issue #$ISSUE; cleanup skipped" >&2
    continue
  fi
  if [[ ! -x "$SCRIPT_DIR/issue-claim.sh" ]] || ! "$SCRIPT_DIR/issue-claim.sh" "$ISSUE" --release --repo "$REPO" --expect-claim-id "$OBSERVED_ID" >/dev/null 2>&1; then
    FAILED=$(printf '%s' "$FAILED" | jq -c --argjson issue "$ISSUE" '. + [$issue]')
    echo "WARNING: could not release the claim on issue #$ISSUE — it will expire on its own. Clear it early with: $SCRIPT_DIR/issue-claim.sh $ISSUE --release --repo $REPO" >&2
  fi
done <<< "$ISSUES"
jq -cn --arg repo "$REPO" --argjson pr "$PR" --arg append "$APPEND" --arg issues "$ISSUES" --argjson failed "$FAILED" \
  '{repo:$repo,pr:$pr,status:"merged",append:$append,issues:($issues | split("\n") | map(select(test("^[1-9][0-9]*$")) | tonumber)),release_failed:$failed}'
