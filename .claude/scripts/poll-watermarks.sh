#!/usr/bin/env bash
# poll-watermarks.sh — Persist and compare PR poll watermarks (issue #741).
#
# Tracks high-water IDs for all three polled comment endpoints so per-cycle
# trigger #1 in cr-github-review.md ("new bot findings since the last poll
# watermark") has a well-defined basis for inline diff comments.
#
# Watermarks live at .prs["N"].poll_watermarks in session-state.json:
#   last_review_id, last_inline_comment_id, last_issue_comment_id
#
# Usage:
#   poll-watermarks.sh <pr_number> --init [--root-repo <path>]
#   poll-watermarks.sh <pr_number> --reset [--root-repo <path>]
#   poll-watermarks.sh <pr_number> --check [--root-repo <path>]
#   poll-watermarks.sh --help
#
# Modes:
#   --init   Snapshot current max IDs from all three endpoints (first poll tick).
#   --reset  Same as --init — run after any /fixpr push (cr-github-review.md).
#   --check  Compare stored watermarks to live endpoints; stdout lines:
#              NEW_FINDINGS=0|1
#              NEW_REVIEW_FINDINGS=0|1
#              NEW_INLINE_FINDINGS=0|1
#              NEW_ISSUE_COMMENT_FINDINGS=0|1
#            When NEW_FINDINGS=0, advances watermarks to the current max IDs.
#
# Exit codes:
#   0  success
#   2  usage
#   4  state/pr-state/session-state failure
#   5  gh/network error (from pr-state.sh)
#
set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PR_STATE="${SCRIPT_DIR}/pr-state.sh"
STATE_HELPER="${SCRIPT_DIR}/session-state.sh"

PR_NUMBER=""
MODE=""
ROOT_REPO_ARG=""

usage() {
  sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --init|--reset|--check)
      if [[ -n "$MODE" ]]; then
        echo "poll-watermarks.sh: specify only one of --init, --reset, --check" >&2
        exit 2
      fi
      MODE="${1#--}"
      shift
      ;;
    --root-repo)
      ROOT_REPO_ARG="${2:-}"
      if [[ -z "$ROOT_REPO_ARG" ]]; then
        echo "poll-watermarks.sh: --root-repo requires a path" >&2
        exit 2
      fi
      shift 2
      ;;
    -*)
      echo "poll-watermarks.sh: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$PR_NUMBER" ]]; then
        echo "poll-watermarks.sh: unexpected argument: $1" >&2
        exit 2
      fi
      PR_NUMBER="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUMBER" ]] || ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "poll-watermarks.sh: positive integer <pr_number> is required" >&2
  exit 2
fi
if [[ -z "$MODE" ]]; then
  echo "poll-watermarks.sh: one of --init, --reset, --check is required" >&2
  exit 2
fi

for dep in jq; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "poll-watermarks.sh: requires $dep" >&2
    exit 4
  fi
done
if [[ ! -x "$PR_STATE" ]]; then
  echo "poll-watermarks.sh: pr-state.sh not found at $PR_STATE" >&2
  exit 4
fi
if [[ ! -x "$STATE_HELPER" ]]; then
  echo "poll-watermarks.sh: session-state.sh not found at $STATE_HELPER" >&2
  exit 4
fi

run_pr_state() {
  local state_file rc=0
  if [[ -n "$ROOT_REPO_ARG" ]]; then
    state_file="$(cd "$ROOT_REPO_ARG" && "$PR_STATE" --pr "$PR_NUMBER")" || rc=$?
  else
    state_file="$("$PR_STATE" --pr "$PR_NUMBER")" || rc=$?
  fi
  if [[ $rc -ne 0 || -z "$state_file" || ! -f "$state_file" ]]; then
    echo "poll-watermarks.sh: pr-state.sh failed for PR #$PR_NUMBER" >&2
    exit 4
  fi
  printf '%s' "$state_file"
}

read_watermarks() {
  local wm=""
  if [[ -n "$ROOT_REPO_ARG" ]]; then
    wm="$(cd "$ROOT_REPO_ARG" && "$STATE_HELPER" --get ".prs[\"$PR_NUMBER\"].poll_watermarks" 2>/dev/null || true)"
  else
    wm="$("$STATE_HELPER" --get ".prs[\"$PR_NUMBER\"].poll_watermarks" 2>/dev/null || true)"
  fi
  if [[ -z "$wm" || "$wm" == "null" ]]; then
    wm='{"last_review_id":0,"last_inline_comment_id":0,"last_issue_comment_id":0}'
  fi
  printf '%s' "$wm"
}

write_watermarks() {
  local json="$1"
  if [[ -n "$ROOT_REPO_ARG" ]]; then
    ( cd "$ROOT_REPO_ARG" && "$STATE_HELPER" --set ".prs[\"$PR_NUMBER\"].poll_watermarks=$json" ) || return 1
  else
    "$STATE_HELPER" --set ".prs[\"$PR_NUMBER\"].poll_watermarks=$json" || return 1
  fi
}

# This ID-watermark classifier must stay behaviorally aligned with the canonical
# rules in lib/pr-state-classify.jq (fixpr Step 5b). It additionally watches
# CodeAnt and Graphite, which are outside pr-state.sh --since's three-bot scope.
eval_watermarks() {
  local state_file="$1" stored_wm="$2"
  jq -n \
    --argjson state "$(<"$state_file")" \
    --argjson stored "$stored_wm" \
    '
    def classify:
      if . == null or . == "" then {class: "acknowledgment", reason: "empty body"}
      elif test("<!--\\s*<review_comment_addressed>\\s*-->"; "") then {class: "acknowledgment", reason: "addressed marker"}
      elif test("<!--\\s*<review_comment_withdrawn>\\s*-->"; "") then {class: "acknowledgment", reason: "withdrawn marker"}
      elif test("actionable comments posted:\\s*0\\b"; "i") then {class: "acknowledgment", reason: "CR reports zero actionable"}
      elif test("no actionable comments were generated"; "i") then {class: "acknowledgment", reason: "CR no actionable comments generated"}
      elif test("rate limit exceeded|rate.limited by coderabbit|currently rate limited|review limit reached|next review (will be )?available in"; "i") then {class: "acknowledgment", reason: "rate limit notice"}
      elif test("couldn[\u0027\u2019]t run\\s*[-–—]\\s*usage limit reached|this run hit a usage or spend limit"; "i") then {class: "acknowledgment", reason: "BugBot usage limit notice"}
      elif test("full review triggered"; "i") then {class: "acknowledgment", reason: "review-started ack"}
      elif test("found no new issues"; "i") then {class: "acknowledgment", reason: "BugBot clean pass"}
      elif (test("<!--\\s*BUGBOT_REVIEW\\s*-->"; "") and (test("found [1-9][0-9]* potential issue"; "i") | not)) then {class: "acknowledgment", reason: "BugBot zero-issue summary"}
      elif test("Oops, something went wrong"; "i") then {class: "acknowledgment", reason: "CR error stub / transient noise"}
      elif test("<!--\\s*This is an auto-generated reply by CodeRabbit\\s*-->"; "i") then {class: "acknowledgment", reason: "CR auto-reply ack"}
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
    def is_bot:
      .user.login == "coderabbitai[bot]"
      or .user.login == "cursor[bot]"
      or .user.login == "greptile-apps[bot]"
      or .user.login == "codeant-ai[bot]"
      or .user.login == "graphite-app[bot]";
    def max_id($items):
      ([$items[]? | .id // empty] | max // 0);
    def new_finding_count($items; $wm):
      [$items[]
       | select(is_bot)
       | select((.id // 0) > ($wm // 0))
       | select((.body | classify).class == "finding")
      ] | length;
    ($state.comments.reviews // []) as $reviews
    | ($state.comments.inline // []) as $inline
    | ($state.comments.conversation // []) as $conversation
    | ($stored.last_review_id // 0) as $wm_review
    | ($stored.last_inline_comment_id // 0) as $wm_inline
    | ($stored.last_issue_comment_id // 0) as $wm_issue
    | {
        current: {
          last_review_id: max_id($reviews),
          last_inline_comment_id: max_id($inline),
          last_issue_comment_id: max_id($conversation)
        },
        new_review_findings: new_finding_count($reviews; $wm_review),
        new_inline_findings: new_finding_count($inline; $wm_inline),
        new_issue_comment_findings: new_finding_count($conversation; $wm_issue)
      }
    | . + {
        new_findings: (
          (.new_review_findings + .new_inline_findings + .new_issue_comment_findings) > 0
        )
      }
    '
}

STATE_FILE="$(run_pr_state)"
STORED_WM="$(read_watermarks)"
EVAL="$(eval_watermarks "$STATE_FILE" "$STORED_WM")"

CURRENT_WM="$(jq -c '.current' <<<"$EVAL")"
NEW_FINDINGS="$(jq -r '.new_findings | if . then 1 else 0 end' <<<"$EVAL")"
NEW_REVIEW="$(jq -r '.new_review_findings | if . > 0 then 1 else 0 end' <<<"$EVAL")"
NEW_INLINE="$(jq -r '.new_inline_findings | if . > 0 then 1 else 0 end' <<<"$EVAL")"
NEW_ISSUE="$(jq -r '.new_issue_comment_findings | if . > 0 then 1 else 0 end' <<<"$EVAL")"

case "$MODE" in
  init|reset)
    if ! write_watermarks "$CURRENT_WM"; then
      echo "poll-watermarks.sh: failed to write poll_watermarks to session-state" >&2
      exit 4
    fi
    jq -c '. + {mode: "'"$MODE"'"}' <<<"$CURRENT_WM"
    exit 0
    ;;
  check)
    if [[ "$NEW_FINDINGS" == "0" ]]; then
      if ! write_watermarks "$CURRENT_WM"; then
        echo "poll-watermarks.sh: failed to advance poll_watermarks" >&2
        exit 4
      fi
    fi
    printf 'NEW_FINDINGS=%s\n' "$NEW_FINDINGS"
    printf 'NEW_REVIEW_FINDINGS=%s\n' "$NEW_REVIEW"
    printf 'NEW_INLINE_FINDINGS=%s\n' "$NEW_INLINE"
    printf 'NEW_ISSUE_COMMENT_FINDINGS=%s\n' "$NEW_ISSUE"
    exit 0
    ;;
esac

echo "poll-watermarks.sh: internal error — unhandled mode $MODE" >&2
exit 4
