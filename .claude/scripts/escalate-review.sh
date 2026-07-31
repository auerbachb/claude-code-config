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
#     STATUS=gate_met         CR-path primary review already satisfied (CodeRabbit or
#                             CodeAnt has a valid APPROVED review on current HEAD) —
#                             do not escalate; the merge gate will pick this up
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
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

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

# Gate-already-met short-circuit (issue reported on PR #619, 2026-07-21): before
# evaluating ANY CR->BugBot->Greptile escalation, check whether the CR-path
# primary review requirement is already satisfied by CodeRabbit OR CodeAnt.
# Per cr-merge-gate.md Step 1, "at least one of: CodeRabbit or CodeAnt with
# state: APPROVED ... Either bot satisfies the primary review; you do not need
# both when only one reviewed." If so, the merge gate (merge-gate.sh) is
# already on track regardless of whether CR is rate-limited or BugBot failed —
# escalating to a paid Greptile review would be unwarranted. This mirrors
# merge-gate.sh's CR_APPROVAL_VALID / CA_APPROVAL_VALID retraction-aware logic
# (see merge-gate.sh's `primary_review_met` field) against the PR state already
# fetched above, so no extra gh API calls are needed.
PRIMARY_REVIEW_MET="$(jq -r --arg sha "$HEAD_SHA" '
  def approval_valid(login):
    ([.comments.reviews[]?
      | select(.user.login == login and (.commit_id // "") == $sha and .state == "APPROVED")
      | .submitted_at] | sort | last // "") as $approved_at
    | ([.comments.reviews[]?
      | select(.user.login == login and (.commit_id // "") == $sha and .state == "CHANGES_REQUESTED")
      | .submitted_at] | sort | last // "") as $changes_at
    | ($approved_at != "") and (($changes_at == "") or ($changes_at <= $approved_at));
  approval_valid("coderabbitai[bot]") or approval_valid("codeant-ai[bot]")
' "$STATE_PATH")" || {
  echo "escalate-review.sh: failed to evaluate primary-review-met check" >&2
  exit 4
}

if [[ "$PRIMARY_REVIEW_MET" == "true" ]]; then
  emit "gate_met"
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
     | select((text | test("rate limit"; "i")))]
    | length
  ) > 0
  or
  (
    [.commit_statuses[]
     | select((.context // "") | test("CodeRabbit"; "i"))
     | select((text | test("rate limit"; "i")))]
    | length
  ) > 0
' "$STATE_PATH")"

CR_REVIEW_ON_HEAD="$(jq -r --arg sha "$HEAD_SHA" '
  [.comments.reviews[]
   | select(.user.login == "coderabbitai[bot]" and ((.commit_id // "") == $sha))]
  | length > 0
' "$STATE_PATH")"

if [[ "$CR_RATE_LIMITED" != "true" && ! ( "$AGE_SECONDS" -gt 720 && "$CR_REVIEW_ON_HEAD" != "true" ) ]]; then
  emit "polling_cr"
fi

# Content-aware BugBot classification (issue #552): a completed `Cursor Bugbot`
# check-run alone does not mean BugBot actually reviewed the PR — a usage/spend
# limit failure produces the same status=completed/conclusion=neutral tuple as
# a genuine clean pass, and a genuinely blocking conclusion (failure/timed_out/
# etc.) is a different kind of non-review that also isn't a real pass. The
# check-run is already scoped to the current HEAD SHA (pr-state.sh fetches it
# per-commit), so it anchors "what happened on this commit"; when its
# conclusion is ambiguous (completed/neutral, non-blocking, non-failure title)
# the LATEST cursor[bot] comment (by timestamp, not "any historical match")
# disambiguates a usage-limit failure from a genuine clean pass/findings.
read -r BUGBOT_FAILED BUGBOT_GENUINE < <(jq -r '
  def is_failure_text: test("couldn.t run|could not run|usage limit|usage or spend limit"; "i");
  def is_blocking_conclusion: . == "failure" or . == "timed_out" or . == "action_required" or . == "startup_failure" or . == "stale";
  def cursor_comments: [.comments.reviews[], .comments.inline[], .comments.conversation[]
    | select(.user.login == "cursor[bot]")];
  def comment_ts: (.submitted_at // .created_at // "");

  (cursor_comments | sort_by(comment_ts) | last) as $latest_comment
  | ([.check_runs.all[] | select((.name // "") == "Cursor Bugbot")] | last) as $run
  | ($latest_comment != null and (($latest_comment.body // "") | is_failure_text)) as $latest_comment_failed
  | ($run != null and ((($run.conclusion // "") | is_blocking_conclusion) or (($run.title // "") | is_failure_text))) as $run_definitive_failure
  | ($run != null and ($run.status // "") == "completed" and ($run_definitive_failure | not)) as $run_completed_ambiguous
  | (
      $run_definitive_failure
      or ($run_completed_ambiguous and $latest_comment_failed)
      or ($run == null and $latest_comment_failed)
    ) as $failed
  | (
      ($run_completed_ambiguous and ($latest_comment_failed | not))
      or ($run == null and $latest_comment != null and ($latest_comment_failed | not))
    ) as $genuine
  | [$failed, $genuine] | @tsv
' "$STATE_PATH") || {
  echo "escalate-review.sh: failed to classify BugBot activity" >&2
  exit 4
}

BUGBOT_CHECK_PRESENT="$(jq -r '
  [.check_runs.all[] | select((.name // "") == "Cursor Bugbot")] | length > 0
' "$STATE_PATH")"

CACHED_BUGBOT_INSTALLED="$("$SESSION_STATE" --get ".prs[\"$PR_NUMBER\"].bugbot_installed // \"\"" 2>/dev/null || true)"
case "$CACHED_BUGBOT_INSTALLED" in
  true|false)
    BUGBOT_INSTALLED="$CACHED_BUGBOT_INSTALLED"
    ;;
  *)
    if [[ "$BUGBOT_CHECK_PRESENT" == "true" || "$BUGBOT_FAILED" == "true" || "$BUGBOT_GENUINE" == "true" ]]; then
      BUGBOT_INSTALLED="true"
      "$SESSION_STATE" --set ".prs[\"$PR_NUMBER\"].bugbot_installed=true" 2>/dev/null || {
        echo "escalate-review.sh: failed to cache bugbot_installed=true" >&2
        exit 4
      }
    elif [[ "$AGE_SECONDS" -ge 600 ]]; then
      BUGBOT_INSTALLED="false"
      "$SESSION_STATE" --set ".prs[\"$PR_NUMBER\"].bugbot_installed=false" 2>/dev/null || {
        echo "escalate-review.sh: failed to cache bugbot_installed=false" >&2
        exit 4
      }
    else
      BUGBOT_INSTALLED="false"
      emit "polling_cr"
    fi
    ;;
esac

# Design note (issue #844): after the merge-gate.sh fix, switch_bugbot leads to a
# satisfiable gate for BOTH BugBot shapes that BUGBOT_GENUINE covers:
#   - conclusion:success check-run (no review object) — accepted by merge-gate.sh's
#     new check-run path (BB_CHECK_CLEAN); freshness + failure-phrase check there.
#   - conclusion:neutral check-run + review object — accepted by the original review-
#     object path in merge-gate.sh.
# This script derives everything from the pre-built STATE_PATH bundle — no new gh api
# fetch added here (meta-guard test L). The gate-satisfiable evaluation lives in
# merge-gate.sh where CHECK_RUNS_JSON and LAST_COMMIT_TS are already available.
if [[ "$BUGBOT_GENUINE" == "true" ]]; then
  emit "switch_bugbot"
fi

# A usage-limit/couldn't-run failure is not a reason to keep waiting out the
# grace window — BugBot has already failed, so fall through to the Greptile
# budget check below (mirrors the CodeRabbit "rate limit" fast-path).
if [[ "$BUGBOT_FAILED" != "true" && "$BUGBOT_INSTALLED" == "true" && "$AGE_SECONDS" -lt 600 ]]; then
  emit "polling_cr"
fi

BUDGET_CHECK_RC=0
BUDGET_JSON="$("$GREPTILE_BUDGET" --check 2>/dev/null)" || BUDGET_CHECK_RC=$?
if [[ $BUDGET_CHECK_RC -ge 2 ]]; then
  echo "escalate-review.sh: failed to check Greptile budget" >&2
  exit 4
fi

BUDGET_EXHAUSTED="$(jq -r '.exhausted == true' <<<"$BUDGET_JSON")"
if [[ "$BUDGET_EXHAUSTED" == "true" ]]; then
  emit "budget_exhausted"
fi

emit "trigger_greptile"
