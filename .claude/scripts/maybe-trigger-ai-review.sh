#!/usr/bin/env bash
# maybe-trigger-ai-review.sh — Round-gated complexity trigger for AI reviewers (issue #362).
#
# When gates pass, posts three separate PR comments (never batched):
#   1) @codeant-ai review
#   2) @cursor review
#   3) @graphite-app re-review
# Optional 4th: /pr-review-help (see pm-config.md).
#
# Config: `.claude/pm-config.md` section **Complexity triggers** (see template in repo).
#
# Usage:
#   maybe-trigger-ai-review.sh <pr_number> [--dry-run] [--json]
#
# Exit: 0 always on successful evaluation (posted or skipped); 2 usage; 3 PR; 4 error

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_HELPER="${SCRIPT_DIR}/session-state.sh"
CYCLE_SCRIPT="${SCRIPT_DIR}/cycle-count.sh"
COMPLEXITY_SCRIPT="${SCRIPT_DIR}/complexity-score.sh"

help() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

PR_NUM=""
DRY_RUN=0
JSON_OUT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) help; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --json) JSON_OUT=1; shift ;;
    -*)
      echo "maybe-trigger-ai-review.sh: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$PR_NUM" ]]; then
        echo "maybe-trigger-ai-review.sh: unexpected argument: $1" >&2
        exit 2
      fi
      PR_NUM="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUM" ]] || ! [[ "$PR_NUM" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: maybe-trigger-ai-review.sh <pr_number> [--dry-run] [--json]" >&2
  exit 2
fi

for need in gh jq; do
  if ! command -v "$need" >/dev/null 2>&1; then
    echo "maybe-trigger-ai-review.sh: requires $need" >&2
    exit 4
  fi
done

# Defaults (calibrated on ≥10 merged PRs in claude-code-config; ~53% would trigger at threshold 100)
THRESHOLD_SCORE="${COMPLEXITY_THRESHOLD_SCORE:-100}"
FIRST_CR_ROUND="${COMPLEXITY_FIRST_CR_ROUND:-3}"
CADENCE_ROUNDS="${COMPLEXITY_CADENCE_ROUNDS:-2}"
ENABLE_PR_REVIEW_HELP=0

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
PM_CFG=""
[[ -n "$REPO_ROOT" && -f "$REPO_ROOT/.claude/pm-config.md" ]] && PM_CFG="$REPO_ROOT/.claude/pm-config.md"

parse_pm_kv() {
  local key="$1"
  local section
  section=$(awk '/^## Complexity triggers/,/^## / { if (/^## Complexity triggers/) next; if (/^## /) exit; print }' "$PM_CFG" 2>/dev/null || true)
  [[ -z "$section" ]] && return 0
  local line
  line=$(echo "$section" | grep -E "^[[:space:]]*${key}[[:space:]]*=" | head -1 || true)
  [[ -z "$line" ]] && return 0
  local val="${line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}

if [[ -n "$PM_CFG" ]]; then
  v="$(parse_pm_kv THRESHOLD_SCORE)"
  [[ -n "$v" && "$v" =~ ^[0-9]+$ ]] && THRESHOLD_SCORE="$v"
  v="$(parse_pm_kv FIRST_CR_ROUND)"
  [[ -n "$v" && "$v" =~ ^[0-9]+$ ]] && FIRST_CR_ROUND="$v"
  v="$(parse_pm_kv CADENCE_ROUNDS)"
  [[ -n "$v" && "$v" =~ ^[0-9]+$ ]] && CADENCE_ROUNDS="$v"
  v="$(parse_pm_kv ENABLE_PR_REVIEW_HELP)"
  if [[ "$v" =~ ^(1|true|yes|on)$ ]]; then
    ENABLE_PR_REVIEW_HELP=1
  fi
fi

[[ ! -x "$CYCLE_SCRIPT" ]] && CYCLE_SCRIPT="${SCRIPT_DIR}/cycle-count.sh"
[[ ! -x "$COMPLEXITY_SCRIPT" ]] && COMPLEXITY_SCRIPT="${SCRIPT_DIR}/complexity-score.sh"

CR_ROUNDS="$("$CYCLE_SCRIPT" "$PR_NUM" --cr-only)" || exit 4
SCORE="$("$COMPLEXITY_SCRIPT" "$PR_NUM")" || exit 4

HEAD_SHA="$(gh pr view "$PR_NUM" --json headRefOid -q .headRefOid 2>/dev/null)" || {
  echo "maybe-trigger-ai-review.sh: could not read PR #$PR_NUM" >&2
  exit 3
}

PR_KEY="$PR_NUM"
LAST_FIRED_ROUND=""
LAST_SHA=""
if [[ -f "$HOME/.claude/session-state.json" ]]; then
  LAST_FIRED_ROUND="$(jq -r --arg k "$PR_KEY" '.prs[$k].ai_review_trigger_last_cr_round // empty' "$HOME/.claude/session-state.json" 2>/dev/null || true)"
  LAST_SHA="$(jq -r --arg k "$PR_KEY" '.prs[$k].ai_review_trigger_head_sha // empty' "$HOME/.claude/session-state.json" 2>/dev/null || true)"
fi

SKIP_REASON=""
if (( CR_ROUNDS < 2 )); then
  SKIP_REASON="cr_rounds_lt_2"
elif (( SCORE < THRESHOLD_SCORE )); then
  SKIP_REASON="below_complexity_threshold"
elif (( FIRST_CR_ROUND < 3 )); then
  echo "maybe-trigger-ai-review.sh: FIRST_CR_ROUND must be >= 3 (needs >=2 completed CR rounds before first fire)" >&2
  exit 4
elif (( CR_ROUNDS < FIRST_CR_ROUND )); then
  SKIP_REASON="before_first_trigger_round"
elif (( CADENCE_ROUNDS < 1 )); then
  echo "maybe-trigger-ai-review.sh: CADENCE_ROUNDS must be >= 1" >&2
  exit 4
elif (( (CR_ROUNDS - FIRST_CR_ROUND) % CADENCE_ROUNDS != 0 )); then
  SKIP_REASON="cadence_gate"
elif [[ -n "$LAST_FIRED_ROUND" && "$LAST_FIRED_ROUND" =~ ^[0-9]+$ ]]; then
  if (( CR_ROUNDS < LAST_FIRED_ROUND )); then
    SKIP_REASON="state_behind_current_rounds"
  elif (( CR_ROUNDS == LAST_FIRED_ROUND )); then
    if [[ "$HEAD_SHA" == "$LAST_SHA" ]]; then
      SKIP_REASON="duplicate_poll_tick"
    else
      SKIP_REASON="pending_new_cr_round_after_push"
    fi
  fi
fi

emit_json_skip() {
  jq -n \
    --arg status skipped \
    --arg reason "$SKIP_REASON" \
    --argjson cr_rounds "$CR_ROUNDS" \
    --argjson score "$SCORE" \
    --argjson threshold "$THRESHOLD_SCORE" \
    --arg head "$HEAD_SHA" \
    '{status: $status, reason: $reason, cr_rounds: $cr_rounds, score: $score, threshold: $threshold, head_sha: $head}'
}

if [[ -n "$SKIP_REASON" ]]; then
  if (( JSON_OUT )); then
    emit_json_skip
  else
    echo "skipped: $SKIP_REASON (cr_rounds=$CR_ROUNDS score=$SCORE threshold=$THRESHOLD_SCORE)"
  fi
  exit 0
fi

post_comments() {
  gh pr comment "$PR_NUM" --body "@codeant-ai review"
  gh pr comment "$PR_NUM" --body "@cursor review"
  gh pr comment "$PR_NUM" --body "@graphite-app re-review"
  if (( ENABLE_PR_REVIEW_HELP )); then
    gh pr comment "$PR_NUM" --body "/pr-review-help"
  fi
}

if (( DRY_RUN )); then
  if (( JSON_OUT )); then
    jq -n \
      --arg status dry_run \
      --argjson cr_rounds "$CR_ROUNDS" \
      --argjson score "$SCORE" \
      --argjson threshold "$THRESHOLD_SCORE" \
      --argjson first_round "$FIRST_CR_ROUND" \
      --argjson cadence "$CADENCE_ROUNDS" \
      --argjson pr_help "$ENABLE_PR_REVIEW_HELP" \
      --arg head "$HEAD_SHA" \
      '{
        status: $status,
        cr_rounds: $cr_rounds,
        score: $score,
        threshold: $threshold,
        first_cr_round: $first_round,
        cadence_rounds: $cadence,
        would_post_pr_review_help: ($pr_help == 1),
        head_sha: $head
      }'
  else
    echo "[DRY-RUN] would post 3 separate comments (codeant, cursor, graphite)$(
      if (( ENABLE_PR_REVIEW_HELP )); then echo ' + /pr-review-help'; fi
    ) cr_rounds=$CR_ROUNDS score=$SCORE"
  fi
  exit 0
fi

post_comments

# Persist trigger so we do not re-fire on every 60s poll until rounds advance
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ -x "$STATE_HELPER" ]]; then
  "$STATE_HELPER" \
    --set ".prs[\"${PR_KEY}\"].ai_review_trigger_last_cr_round=$CR_ROUNDS" \
    --set ".prs[\"${PR_KEY}\"].ai_review_trigger_head_sha=$HEAD_SHA" \
    --set ".prs[\"${PR_KEY}\"].ai_review_trigger_last_at=\"$NOW_ISO\""
fi

if (( JSON_OUT )); then
  jq -n \
    --arg status triggered \
    --argjson cr_rounds "$CR_ROUNDS" \
    --argjson score "$SCORE" \
    --arg head "$HEAD_SHA" \
    --argjson pr_help "$ENABLE_PR_REVIEW_HELP" \
    '{status: $status, cr_rounds: $cr_rounds, score: $score, head_sha: $head, posted_pr_review_help: ($pr_help == 1)}'
else
  echo "triggered: posted AI reviewer comments (cr_rounds=$CR_ROUNDS score=$SCORE)"
fi
exit 0
