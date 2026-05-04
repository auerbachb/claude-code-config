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
# Env vars COMPLEXITY_THRESHOLD_SCORE, COMPLEXITY_FIRST_CR_ROUND, COMPLEXITY_CADENCE_ROUNDS
# override file values when set.
#
# Usage:
#   maybe-trigger-ai-review.sh <pr_number> [--dry-run] [--json]
#
# Exit: 0 skipped/dry-run/success; 2 usage; 3 PR; 4 error (incl. session-state missing); 5 gh post failed after persistence

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_HELPER="${SCRIPT_DIR}/session-state.sh"
CYCLE_SCRIPT="${SCRIPT_DIR}/cycle-count.sh"
COMPLEXITY_SCRIPT="${SCRIPT_DIR}/complexity-score.sh"
STATE_FILE="${HOME}/.claude/session-state.json"

help() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
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

# Defaults (calibrated on 25 merged PRs in claude-code-config; 72% would trigger at threshold 100)
THRESHOLD_SCORE=100
FIRST_CR_ROUND=3
CADENCE_ROUNDS=2
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
  if [[ -n "$v" ]]; then
    if [[ "$v" =~ ^(0|[1-9][0-9]*)$ ]]; then THRESHOLD_SCORE="$v"
    else echo "maybe-trigger-ai-review.sh: pm-config THRESHOLD_SCORE='$v' is not a non-negative integer" >&2; exit 4; fi
  fi
  v="$(parse_pm_kv FIRST_CR_ROUND)"
  if [[ -n "$v" ]]; then
    if [[ "$v" =~ ^(0|[1-9][0-9]*)$ ]]; then FIRST_CR_ROUND="$v"
    else echo "maybe-trigger-ai-review.sh: pm-config FIRST_CR_ROUND='$v' is not a non-negative integer" >&2; exit 4; fi
  fi
  v="$(parse_pm_kv CADENCE_ROUNDS)"
  if [[ -n "$v" ]]; then
    if [[ "$v" =~ ^(0|[1-9][0-9]*)$ ]]; then CADENCE_ROUNDS="$v"
    else echo "maybe-trigger-ai-review.sh: pm-config CADENCE_ROUNDS='$v' is not a non-negative integer" >&2; exit 4; fi
  fi
  v="$(parse_pm_kv ENABLE_PR_REVIEW_HELP)"
  if [[ "$v" =~ ^(1|true|yes|on)$ ]]; then
    ENABLE_PR_REVIEW_HELP=1
  fi
fi

# Env overrides repo file when set (explicit tuning / CI).
if [[ "${COMPLEXITY_THRESHOLD_SCORE+set}" == "set" ]]; then
  if [[ "${COMPLEXITY_THRESHOLD_SCORE}" =~ ^(0|[1-9][0-9]*)$ ]]; then
    THRESHOLD_SCORE="$COMPLEXITY_THRESHOLD_SCORE"
  else
    echo "maybe-trigger-ai-review.sh: COMPLEXITY_THRESHOLD_SCORE='$COMPLEXITY_THRESHOLD_SCORE' is not a non-negative integer" >&2
    exit 4
  fi
fi
if [[ "${COMPLEXITY_FIRST_CR_ROUND+set}" == "set" ]]; then
  if [[ "${COMPLEXITY_FIRST_CR_ROUND}" =~ ^(0|[1-9][0-9]*)$ ]]; then
    FIRST_CR_ROUND="$COMPLEXITY_FIRST_CR_ROUND"
  else
    echo "maybe-trigger-ai-review.sh: COMPLEXITY_FIRST_CR_ROUND='$COMPLEXITY_FIRST_CR_ROUND' is not a non-negative integer" >&2
    exit 4
  fi
fi
if [[ "${COMPLEXITY_CADENCE_ROUNDS+set}" == "set" ]]; then
  if [[ "${COMPLEXITY_CADENCE_ROUNDS}" =~ ^(0|[1-9][0-9]*)$ ]]; then
    CADENCE_ROUNDS="$COMPLEXITY_CADENCE_ROUNDS"
  else
    echo "maybe-trigger-ai-review.sh: COMPLEXITY_CADENCE_ROUNDS='$COMPLEXITY_CADENCE_ROUNDS' is not a non-negative integer" >&2
    exit 4
  fi
fi

# Validate config constraints before reading PR state (fail fast on misconfiguration).
if (( FIRST_CR_ROUND < 3 )); then
  echo "maybe-trigger-ai-review.sh: FIRST_CR_ROUND must be >= 3 (needs >=2 completed CR rounds before first fire)" >&2
  exit 4
fi
if (( CADENCE_ROUNDS < 1 )); then
  echo "maybe-trigger-ai-review.sh: CADENCE_ROUNDS must be >= 1" >&2
  exit 4
fi

for helper in "$CYCLE_SCRIPT" "$COMPLEXITY_SCRIPT"; do
  if [[ ! -x "$helper" ]]; then
    echo "maybe-trigger-ai-review.sh: required helper missing or not executable: $helper" >&2
    exit 4
  fi
done

RC=0; CR_ROUNDS="$("$CYCLE_SCRIPT" "$PR_NUM" --cr-only)" || RC=$?
if (( RC != 0 )); then exit $RC; fi
RC=0; SCORE="$("$COMPLEXITY_SCRIPT" "$PR_NUM")" || RC=$?
if (( RC != 0 )); then exit $RC; fi

STDERR_TMP="$(mktemp)"
RC=0; HEAD_SHA="$(gh pr view "$PR_NUM" --json headRefOid -q .headRefOid 2>"$STDERR_TMP")" || RC=$?
if (( RC != 0 )); then
  if grep -qiE 'not.?found|could not resolve|no pull requests? found' "$STDERR_TMP"; then
    rm -f "$STDERR_TMP"
    echo "maybe-trigger-ai-review.sh: PR #$PR_NUM not found" >&2
    exit 3
  fi
  cat "$STDERR_TMP" >&2
  rm -f "$STDERR_TMP"
  exit 4
fi
rm -f "$STDERR_TMP"

PR_KEY="$PR_NUM"
LAST_FIRED_ROUND=""
LAST_SHA=""
if [[ -f "$STATE_FILE" ]]; then
  LAST_FIRED_ROUND="$(jq -r --arg k "$PR_KEY" '.prs[$k].ai_review_trigger_last_cr_round // empty' "$STATE_FILE" 2>/dev/null || true)"
  LAST_SHA="$(jq -r --arg k "$PR_KEY" '.prs[$k].ai_review_trigger_head_sha // empty' "$STATE_FILE" 2>/dev/null || true)"
fi

# Incomplete multi-step post from a prior run (resume without re-firing completed mentions).
steps_incomplete() {
  [[ ! -f "$STATE_FILE" ]] && return 1
  jq -e --arg k "$PR_KEY" --arg h "$HEAD_SHA" --argjson r "$CR_ROUNDS" --argjson need_help "$ENABLE_PR_REVIEW_HELP" '
    .prs[$k].ai_review_trigger_steps? as $st
    | $st != null
      and ($st.head_sha == $h)
      and ($st.cr_rounds == $r)
      and (
        ($st.codeant | not)
        or ($st.cursor | not)
        or ($st.graphite | not)
        or ($need_help == 1 and ($st.pr_help | not))
      )
  ' "$STATE_FILE" >/dev/null 2>&1
}

SKIP_REASON=""
if (( CR_ROUNDS < 2 )); then
  SKIP_REASON="cr_rounds_lt_2"
elif (( SCORE < THRESHOLD_SCORE )); then
  SKIP_REASON="below_complexity_threshold"
elif (( CR_ROUNDS < FIRST_CR_ROUND )); then
  SKIP_REASON="before_first_trigger_round"
elif (( (CR_ROUNDS - FIRST_CR_ROUND) % CADENCE_ROUNDS != 0 )); then
  SKIP_REASON="cadence_gate"
elif [[ -n "$LAST_FIRED_ROUND" && "$LAST_FIRED_ROUND" =~ ^[0-9]+$ ]]; then
  if (( CR_ROUNDS < LAST_FIRED_ROUND )); then
    SKIP_REASON="state_behind_current_rounds"
  elif (( CR_ROUNDS == LAST_FIRED_ROUND )); then
    if [[ "$HEAD_SHA" == "$LAST_SHA" ]] && ! steps_incomplete; then
      SKIP_REASON="duplicate_poll_tick"
    elif [[ "$HEAD_SHA" != "$LAST_SHA" ]]; then
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

if [[ ! -x "$STATE_HELPER" ]]; then
  echo "maybe-trigger-ai-review.sh: session-state.sh missing or not executable: $STATE_HELPER (required to dedupe triggers)" >&2
  exit 4
fi

# Persist step tracking before any gh comment (fail-closed); resume partial progress on retry.
INIT_STEPS="$(jq -cn \
  --arg h "$HEAD_SHA" \
  --argjson r "$CR_ROUNDS" \
  --argjson need_help "$ENABLE_PR_REVIEW_HELP" \
  '{
    head_sha: $h,
    cr_rounds: $r,
    needs_pr_help: ($need_help == 1),
    codeant: false,
    cursor: false,
    graphite: false,
    pr_help: false
  }')"

if [[ -f "$STATE_FILE" ]]; then
  EXISTING="$(jq -c --arg k "$PR_KEY" '.prs[$k].ai_review_trigger_steps // empty' "$STATE_FILE" 2>/dev/null || true)"
  if [[ -n "$EXISTING" && "$EXISTING" != "null" && "$EXISTING" != "" ]]; then
    MATCH="$(jq -n --argjson ex "$EXISTING" --arg h "$HEAD_SHA" --argjson r "$CR_ROUNDS" '$ex | select(.head_sha == $h and .cr_rounds == $r)' 2>/dev/null || true)"
    if [[ -n "$MATCH" && "$MATCH" != "null" ]]; then
      INIT_STEPS="$(jq -cn --argjson ex "$EXISTING" --argjson need_help "$ENABLE_PR_REVIEW_HELP" '$ex | .needs_pr_help = ($need_help == 1)')"
    fi
  fi
fi

if ! "$STATE_HELPER" --set ".prs[\"${PR_KEY}\"].ai_review_trigger_steps=$INIT_STEPS"; then
  echo "maybe-trigger-ai-review.sh: failed to persist trigger step state — aborting without posting comments" >&2
  exit 4
fi

post_one() {
  local step_key="$1"
  local body="$2"
  local posted
  posted="$(jq -r --arg k "$PR_KEY" --arg s "$step_key" '.prs[$k].ai_review_trigger_steps[$s] // empty' "$STATE_FILE" 2>/dev/null || true)"
  if [[ "$posted" == "true" ]]; then
    return 0
  fi
  gh pr comment "$PR_NUM" --body "$body" || return 1
  local merged
  merged="$(jq -cn --argjson cur "$INIT_STEPS" --arg s "$step_key" '$cur | .[$s] = true')"
  INIT_STEPS="$merged"
  if ! "$STATE_HELPER" --set ".prs[\"${PR_KEY}\"].ai_review_trigger_steps=$merged"; then
    echo "maybe-trigger-ai-review.sh: comment posted but state update failed — may re-post on retry" >&2
  fi
}

if ! post_one codeant "@codeant-ai review"; then echo "maybe-trigger-ai-review.sh: failed posting @codeant-ai review" >&2; exit 5; fi
if ! post_one cursor "@cursor review"; then echo "maybe-trigger-ai-review.sh: failed posting @cursor review" >&2; exit 5; fi
if ! post_one graphite "@graphite-app re-review"; then echo "maybe-trigger-ai-review.sh: failed posting @graphite-app re-review" >&2; exit 5; fi
if (( ENABLE_PR_REVIEW_HELP )); then
  if ! post_one pr_help "/pr-review-help #$PR_NUM"; then echo "maybe-trigger-ai-review.sh: failed posting /pr-review-help" >&2; exit 5; fi
fi

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if ! "$STATE_HELPER" \
  --set ".prs[\"${PR_KEY}\"].ai_review_trigger_last_cr_round=$CR_ROUNDS" \
  --set ".prs[\"${PR_KEY}\"].ai_review_trigger_head_sha=$HEAD_SHA" \
  --set ".prs[\"${PR_KEY}\"].ai_review_trigger_last_at=\"$NOW_ISO\"" \
  --set ".prs[\"${PR_KEY}\"].ai_review_trigger_steps=null"; then
  echo "maybe-trigger-ai-review.sh: failed to persist completion markers" >&2
  exit 4
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
