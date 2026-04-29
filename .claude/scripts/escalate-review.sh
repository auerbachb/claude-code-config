#!/usr/bin/env bash
# escalate-review.sh — Deterministic CR→BugBot→Greptile escalation verdict.
#
# PURPOSE
#   Implements the per-cycle reviewer escalation gate documented in
#   .claude/rules/cr-github-review.md. The script gathers the current PR state,
#   checks whether CodeRabbit is still a viable active reviewer, caches whether
#   BugBot appears installed for this PR, and prints exactly one STATUS verdict.
#
# USAGE
#   escalate-review.sh <pr_number>
#   escalate-review.sh --help | -h
#
# OUTPUT
#   stdout: one line, exactly one of:
#     STATUS=polling_cr       keep polling CodeRabbit/BugBot grace window
#     STATUS=switch_bugbot    BugBot has responded; make BugBot sticky reviewer
#     STATUS=trigger_greptile CR failed and BugBot is absent/timed out; trigger Greptile
#     STATUS=budget_exhausted Greptile budget is exhausted; do not trigger Greptile
#     STATUS=self_review      PR is already marked for self-review fallback
#
# EXIT STATUS
#   0  A STATUS verdict was printed
#   2  Usage/dependency error
#   4  GitHub/API/state read error

set -euo pipefail

PR_NUMBER=""

print_usage() {
  awk 'NR == 1 { next } /^$/ { exit } { print }' "$0"
}

die_usage() {
  echo "escalate-review.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

emit() {
  printf 'STATUS=%s\n' "$1"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    -*)
      die_usage "unknown flag: $1"
      ;;
    *)
      if [[ -n "$PR_NUMBER" ]]; then
        die_usage "unexpected argument: $1 (PR number already set to $PR_NUMBER)"
      fi
      PR_NUMBER="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUMBER" ]]; then
  die_usage "<pr_number> is required"
fi

if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  die_usage "<pr_number> must be a positive integer (got: $PR_NUMBER)"
fi

for dep in gh jq python3; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "escalate-review.sh: '$dep' not found on PATH" >&2
    exit 2
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_STATE="$SCRIPT_DIR/session-state.sh"
PR_STATE="$SCRIPT_DIR/pr-state.sh"
GREPTILE_BUDGET="$SCRIPT_DIR/greptile-budget.sh"

if [[ ! -x "$SESSION_STATE" || ! -x "$PR_STATE" || ! -x "$GREPTILE_BUDGET" ]]; then
  echo "escalate-review.sh: required sibling scripts are missing or not executable" >&2
  exit 2
fi

CURRENT_REVIEWER="$("$SESSION_STATE" --get ".prs[\"$PR_NUMBER\"].reviewer // \"\"" 2>/dev/null || true)"
if [[ "$CURRENT_REVIEWER" == "self_review" ]]; then
  emit "self_review"
fi

STATE_PATH="$("$PR_STATE" --pr "$PR_NUMBER" 2>/dev/null)"
if [[ -z "$STATE_PATH" || ! -f "$STATE_PATH" ]]; then
  echo "escalate-review.sh: failed to gather PR state for #$PR_NUMBER" >&2
  exit 4
fi

read -r OWNER REPO HEAD_SHA < <(jq -r '[.pr.owner, .pr.repo, .pr.head_sha] | @tsv' "$STATE_PATH") || {
  echo "escalate-review.sh: failed to read PR state JSON" >&2
  exit 4
}

if [[ -z "$OWNER" || -z "$REPO" || -z "$HEAD_SHA" ]]; then
  echo "escalate-review.sh: PR state missing owner/repo/head_sha" >&2
  exit 4
fi

COMMITS_JSON="$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/commits?per_page=100" 2>/dev/null | jq -s 'add // []')" || {
  echo "escalate-review.sh: failed to fetch PR commits" >&2
  exit 4
}

PUSH_TIMESTAMP="$(jq -r --arg sha "$HEAD_SHA" '
  (map(select(.sha == $sha)) | last // {})
  | .commit.committer.date // .commit.author.date // empty
' <<<"$COMMITS_JSON")"

if [[ -z "$PUSH_TIMESTAMP" ]]; then
  echo "escalate-review.sh: could not determine push timestamp for #$PR_NUMBER" >&2
  exit 4
fi

AGE_SECONDS="$(python3 - "$PUSH_TIMESTAMP" <<'PY'
from datetime import datetime, timezone
import sys

raw = sys.argv[1]
if raw.endswith("Z"):
    raw = raw[:-1] + "+00:00"
try:
    ts = datetime.fromisoformat(raw)
except ValueError:
    print(f"warning: could not parse timestamp: {raw}", file=sys.stderr)
    print(0)
    sys.exit(0)
if ts.tzinfo is None:
    ts = ts.replace(tzinfo=timezone.utc)
print(max(0, int((datetime.now(timezone.utc) - ts).total_seconds())))
PY
)"

CR_RATE_LIMITED="$(jq -r '
  def text: [(.title // ""), (.description // ""), (.state // ""), (.conclusion // "")] | join(" ");
  (
    [.check_runs.all[]
     | select((.name // "") == "CodeRabbit")
     | select((.conclusion // "") == "failure")
     | select(((.title // "") | test("rate limit"; "i")))]
    | length
  ) > 0
  or
  (
    [.commit_statuses[]
     | select(((.context // "") | test("CodeRabbit"; "i")) and (((.state // "") == "failure") or ((.state // "") == "error")))
     | select((text | test("rate limit"; "i")))]
    | length
  ) > 0
' "$STATE_PATH")"

CR_REVIEW_ON_HEAD="$(jq -r --arg sha "$HEAD_SHA" '
  [.comments.reviews[]
   | select(.user.login == "coderabbitai[bot]" and ((.commit_id // "") == $sha))]
  | length > 0
' "$STATE_PATH")"

if [[ "$CR_RATE_LIMITED" != "true" && ! ( "$AGE_SECONDS" -gt 420 && "$CR_REVIEW_ON_HEAD" != "true" ) ]]; then
  emit "polling_cr"
fi

BUGBOT_POSTED="$(jq -r '
  (
    [.comments.reviews[], .comments.inline[], .comments.conversation[]
     | select(.user.login == "cursor[bot]")]
    | length
  ) > 0
  or
  (
    [.check_runs.all[]
     | select((.name // "") == "Cursor Bugbot" and (.status // "") == "completed")]
    | length
  ) > 0
' "$STATE_PATH")"

BUGBOT_CHECK_PRESENT="$(jq -r '
  [.check_runs.all[] | select((.name // "") == "Cursor Bugbot")] | length > 0
' "$STATE_PATH")"

CACHED_BUGBOT_INSTALLED="$("$SESSION_STATE" --get ".prs[\"$PR_NUMBER\"].bugbot_installed // \"\"" 2>/dev/null || true)"
case "$CACHED_BUGBOT_INSTALLED" in
  true|false)
    BUGBOT_INSTALLED="$CACHED_BUGBOT_INSTALLED"
    ;;
  *)
    if [[ "$BUGBOT_CHECK_PRESENT" == "true" || "$BUGBOT_POSTED" == "true" ]]; then
      BUGBOT_INSTALLED="true"
    else
      BUGBOT_INSTALLED="false"
    fi
    "$SESSION_STATE" --set ".prs[\"$PR_NUMBER\"].bugbot_installed=$BUGBOT_INSTALLED" 2>/dev/null || {
      echo "escalate-review.sh: failed to cache bugbot_installed=$BUGBOT_INSTALLED" >&2
      exit 4
    }
    ;;
esac

if [[ "$BUGBOT_POSTED" == "true" ]]; then
  emit "switch_bugbot"
fi

if [[ "$BUGBOT_INSTALLED" == "true" && "$AGE_SECONDS" -lt 300 ]]; then
  emit "polling_cr"
fi

BUDGET_JSON="$("$GREPTILE_BUDGET" --check 2>/dev/null)"
BUDGET_CHECK_RC=$?
if [[ $BUDGET_CHECK_RC -ge 2 ]]; then
  echo "escalate-review.sh: failed to check Greptile budget" >&2
  exit 4
fi

BUDGET_EXHAUSTED="$(jq -r '.exhausted == true' <<<"$BUDGET_JSON")"
if [[ "$BUDGET_EXHAUSTED" == "true" ]]; then
  emit "budget_exhausted"
fi

emit "trigger_greptile"
