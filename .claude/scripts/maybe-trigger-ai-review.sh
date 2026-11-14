#!/usr/bin/env bash
# maybe-trigger-ai-review.sh — Round-gated complexity trigger for AI reviewers (issue #362).
# catalog: review-escalation — Post supplemental AI reviewer triggers when complexity and CR-round gates pass
#
# When gates pass, posts separate PR comments (never batched):
#   1) @codeant-ai review
#   2) @cursor review — NEVER autonomously (issue #1897): BugBot is a paid
#      review and needs the owner's explicit approval in chat, so this step
#      ends in a `bugbot_skipped: {"reason":"approval_required"}` skip unless
#      an earlier skip below (tier, refused HEAD, daily cap) already applied.
#      The one exception is an owner grant for this PR and HEAD (issue #1898):
#      paid-review-grant.sh --trigger spends it once and posts @cursor review.
#   (Graphite was a third step until its retirement on 2026-11-03, #1889.)
#
# BugBot spend-refusal suppression (issue #1199): the `@cursor review` nudge is
# SKIPPED when cursor[bot] has already refused THIS HEAD for a Cursor usage/spend
# limit. Fails open — see bugbot_refused_head() below.
#
# Review-tier suppression (issue #1728): the `@cursor review` nudge is also
# SKIPPED when the PR's review tier excludes BugBot (gate ci-only or
# ci+codeant-one-round). --json reports it as `bugbot_skipped`. Fails open.
#
# Account daily cap (issue #1812): the `@cursor review` nudge is also SKIPPED when
# review-daily-cap.sh says today's (ET) BugBot spend across every registered repo,
# plus one review, would pass the account's daily cap. The tier and refused-HEAD
# skips are checked first and still win. Only a validated `over` skips: an
# `unknown` tally or a missing helper posts, with a stderr line. --json reports
# the skip as `bugbot_skipped: {"reason":"daily_cap","gate":null,"tally":{...}}`
# and the tally itself as `bugbot_daily_cap` whenever the cap was consulted.
#
# Tier-aware repos (issue #1749): once the round gates pass, the sibling
# review-triggers-allowed.sh decides every post. A repo with no `## Review
# policy` (mode `legacy`), or a missing helper, takes the unchanged path above.
# Otherwise each step posts only when the helper allows it, and
# only after `--claim` records it (a failed post `--release`s it): CodeAnt once, BugBot on a settled green HEAD at most twice, with the
# refused-HEAD guard and the daily cap applied inside the helper, the cap last.
# A deferred step (CI pending, HEAD not settled, daily cap) leaves the step
# record open so the next tick re-asks instead of stopping at
# duplicate_poll_tick. --json adds `trigger_mode`, `trigger_skips` (reviewer ->
# {kind, reason}) and `deferred`; status is `triggered` when something posted,
# else `skipped` with reason `tier_deferred` or `tier_excluded`.
#
# Config: `.claude/pm-config.md` section **Complexity triggers** (see template in repo).
# Env vars COMPLEXITY_THRESHOLD_SCORE, COMPLEXITY_FIRST_CR_ROUND, COMPLEXITY_CADENCE_ROUNDS
# override file values when set.
#
# Usage:
#   maybe-trigger-ai-review.sh <pr_number> [--dry-run] [--json]
#
# Exit: 0 skipped/dry-run/success; 2 usage; 3 PR; 4 error (incl. session-state missing); 5 gh post failed after persistence; 70 --help extraction empty

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_HELPER="${SCRIPT_DIR}/session-state.sh"
CYCLE_SCRIPT="${SCRIPT_DIR}/cycle-count.sh"
COMPLEXITY_SCRIPT="${SCRIPT_DIR}/complexity-score.sh"
STATE_FILE="${HOME}/.claude/session-state.json"

help() {
  # The whole leading comment block, so a new header paragraph can never be cut
  # off mid-sentence by a hardcoded line range. An empty extraction is a defect,
  # not a help page, so it fails loudly instead of exiting 0 (#1528).
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
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
if [[ -f "$STATE_FILE" ]] && ! jq empty "$STATE_FILE" >/dev/null 2>&1; then
  echo "maybe-trigger-ai-review.sh: session state at $STATE_FILE is not valid JSON; aborting to avoid duplicate AI-review comments" >&2
  exit 4
fi
if [[ -f "$STATE_FILE" ]]; then
  LAST_FIRED_ROUND="$("$STATE_HELPER" --get ".prs[\"$PR_KEY\"].ai_review_trigger_last_cr_round // empty" 2>/dev/null || true)"
  LAST_SHA="$("$STATE_HELPER" --get ".prs[\"$PR_KEY\"].ai_review_trigger_head_sha // empty" 2>/dev/null || true)"
fi

# Incomplete multi-step post from a prior run (resume without re-firing completed mentions).
steps_incomplete() {
  [[ ! -f "$STATE_FILE" ]] && return 1
  # Read the scoped step record through the helper (issue #638), then test it
  # locally — the dedupe key is per PR per repo, so a same-numbered PR in
  # another repo must not satisfy "already posted" here.
  local st
  st="$("$STATE_HELPER" --get ".prs[\"$PR_KEY\"].ai_review_trigger_steps // null" 2>/dev/null || echo null)"
  [[ -n "$st" && "$st" != "null" ]] || return 1
  jq -e --arg h "$HEAD_SHA" --argjson r "$CR_ROUNDS" '
    . as $st
    | $st != null
      and ($st.head_sha == $h)
      and ($st.cr_rounds == $r)
      and (
        ($st.codeant | not)
        or ($st.cursor | not)
      )
  ' <<<"$st" >/dev/null 2>&1
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

# When the agent asks (issue #2195). The tier's REVIEW_REQUEST setting and this
# HEAD's checks decide the CodeAnt request; review-request-gate.sh owns the
# rules. A held request is not a skip of the tick: a tiered run defers the
# CodeAnt step, a legacy run skips before any state write. The first request
# for a HEAD (REQ_FIRST=1) may post in the legacy path even while the complexity
# cadence (#362) is below its gate; a tiered run keeps the complexity skip. Once
# a HEAD is recorded, this block asks nothing more for it.
REVIEW_TIER_SH="${SCRIPT_DIR}/review-tier.sh"
REQUEST_SH="${SCRIPT_DIR}/review-request-gate.sh"
REQ_BLOCK=""
# The availability skip decided by availability_gate, recorded only by settle_pending_skip
# on a path that would otherwise have posted the request (CodeAnt #4546742951).
REQ_PENDING_SKIP=""
REQ_FIRST=0
# Which free reviewer this HEAD's request asks (issue #2257): CodeAnt unless
# review-availability.sh choose picks CodeRabbit. REQ_BODY is the exact comment posted.
REQ_REVIEWER="codeant"
REQ_BODY="@codeant-ai review"
REQ_CHOICE_JSON="{}"
REQ_CHOICE_REASON=""
REQ_WINDOW_S=""
REQ_CAN_SKIP=0
REQ_POSTED_REVIEWER=""
REQ_SETTING="after-ci"
REQ_CHECKS=""
REQ_HEAD_DONE="$("$STATE_HELPER" --get ".prs[\"$PR_KEY\"].review_request_head_sha // empty" 2>/dev/null || true)"
record_request_head() {
  "$STATE_HELPER" --set ".prs[\"${PR_KEY}\"].review_request_head_sha=\"$HEAD_SHA\"" >/dev/null 2>&1 \
    || echo "maybe-trigger-ai-review.sh: posted the review request but could not record its HEAD — it may be requested again" >&2
}
# Claim this HEAD before posting, so two concurrent ticks cannot both post (#2195).
# session-state --cas: exactly one winner (exit 0); a loser (exit 7) posts nothing.
claim_request_head() { # expects the value this tick read (an older HEAD, or null)
  local expect="null"
  [[ -n "$REQ_HEAD_DONE" ]] && expect="\"$REQ_HEAD_DONE\""
  "$STATE_HELPER" --cas ".prs[\"${PR_KEY}\"].review_request_head_sha=\"$HEAD_SHA\"" --expect "$expect" >/dev/null 2>&1
}
# A post that failed gives the claim back, so the next tick asks again. Compare-and-set:
# only this HEAD's own claim is cleared, never a newer push's claim (#2274 review).
release_request_head() {
  "$STATE_HELPER" --cas ".prs[\"${PR_KEY}\"].review_request_head_sha=null" --expect "\"$HEAD_SHA\"" >/dev/null 2>&1 || true
}
# First-request guard (safety.md authorship; the same open, non-draft PR the
# other paths require). Runs only when a first request would post.
first_request_guard() {
  local auth="${SCRIPT_DIR}/pr-authorship.sh" pr_state
  if [[ ! -x "$auth" ]]; then REQ_BLOCK="authorship_unverified"; return 0; fi
  if ! "$auth" "$PR_NUM" >/dev/null 2>&1; then REQ_BLOCK="not_author"; return 0; fi
  pr_state="$(gh pr view "$PR_NUM" --json state,isDraft 2>/dev/null)" || { REQ_BLOCK="pr_unreadable"; return 0; }
  jq -e '.state == "OPEN" and ((.isDraft // false) == false)' <<<"$pr_state" >/dev/null 2>&1 \
    || REQ_BLOCK="pr_not_open_or_draft"
}
# Request skip when no free reviewer can answer inside the no-review window (issue
# #2256). review-availability.sh decides from the account-wide record. Any unusable
# answer, or a missing helper or window, keeps the request (fail toward asking). A skip
# is recorded on the PR so the no-review override can apply at once for this HEAD.
availability_gate() {
  local av="${SCRIPT_DIR}/review-availability.sh" nro_min win dec
  [[ -x "$av" ]] || return 0
  nro_min="$(jq -r '.no_review_override_minutes // empty' <<<"$REQ_TIER_JSON" 2>/dev/null)" || nro_min=""
  # Override off (no window): still pick the free reviewer, judged against the default
  # 10-minute window, but never skip, since no override would follow a skip.
  local can_skip=1
  if [[ "$nro_min" =~ ^[0-9]+$ ]]; then win=$(( nro_min * 60 )); else win=600; can_skip=0; fi
  REQ_CAN_SKIP="$can_skip"
  REQ_WINDOW_S="$win"
  # choose (issue #2257) answers both questions: skip when no free reviewer can answer in
  # the window (the same verdict decide gives), else the reviewer to ask for this HEAD.
  dec="$("$av" choose --window-s "$win" 2>/dev/null)" || return 0
  jq -e 'type == "object"' <<<"$dec" >/dev/null 2>&1 || return 0
  if [[ "$(jq -r '.skip // false' <<<"$dec" 2>/dev/null)" != true ]]; then
    REQ_CHOICE_JSON="$dec"
    REQ_CHOICE_REASON="$(jq -r '.choice_reason // "request"' <<<"$dec")"
    REQ_REVIEWER="$(jq -r '.reviewer // "codeant"' <<<"$dec")"
    # on-push keeps today's request: only the after-ci request takes the choice.
    if [[ "$REQ_SETTING" != "after-ci" ]]; then REQ_REVIEWER="codeant"; fi
    REQ_BODY="@${REQ_REVIEWER}-ai review"
    [[ "$REQ_REVIEWER" == coderabbit ]] && REQ_BODY="@coderabbitai review"
    return 0
  fi
  # No window, no override: keep today's CodeAnt request instead of skipping.
  [[ "$can_skip" == 1 ]] || return 0
  # Held, not yet recorded: settle_pending_skip writes it only where this tick would post.
  REQ_PENDING_SKIP="$(jq -r '.reason' <<<"$dec")"
  REQ_BLOCK="$REQ_PENDING_SKIP"
  REQ_FIRST=0
}

# Checks the chosen reviewer just before posting (issue #2257). CodeRabbit's hourly budget is
# read here (cr-review-hourly.sh --check, exit 1 = spent) and counted only AFTER a request is
# actually posted (record_request_choice), so a failed post or a lost claim spends nothing.
# When the budget is spent, the other free reviewer is re-judged (choose --no-coderabbit).
# Returns 1 when no free reviewer can answer any more, so the caller releases its claim.
reserve_request_reviewer() {
  local av="${SCRIPT_DIR}/review-availability.sh" ch="${SCRIPT_DIR}/cr-review-hourly.sh" dec rc=0
  if [[ "$REQ_REVIEWER" == coderabbit ]]; then
    if [[ -x "$ch" ]]; then "$ch" --check >/dev/null 2>&1 || rc=$?; fi
    if (( rc != 1 )); then
      REQ_BODY="@coderabbitai review"
      return 0
    fi
    # CodeRabbit is out: CodeAnt is the only other free reviewer. Hold the request only on
    # a real skip verdict while a no-review override can follow it; any unusable answer, or
    # the override off, still asks CodeAnt (fail toward asking).
    dec=""
    [[ -x "$av" ]] && dec="$("$av" choose --window-s "${REQ_WINDOW_S:-600}" --no-coderabbit 2>/dev/null)" || dec=""
    # Test the value itself: jq `//` treats false like null, so `.skip // true` reads a
    # successful `skip: false` as true and the fallback to CodeAnt could never happen.
    if jq -e '.skip == true' <<<"$dec" >/dev/null 2>&1 && [[ "$REQ_CAN_SKIP" == 1 ]]; then
      # Record the skip for this HEAD now, so the no-review override applies at once (#2274
      # review). A failed record asks CodeAnt instead (settle_pending_skip clears REQ_BLOCK).
      REQ_PENDING_SKIP="$(jq -r '.reason' <<<"$dec")"
      REQ_BLOCK="$REQ_PENDING_SKIP"
      settle_pending_skip
      [[ -n "$REQ_BLOCK" ]] && return 1
    fi
    if jq -e '.skip == false' <<<"$dec" >/dev/null 2>&1; then REQ_CHOICE_JSON="$dec"; fi
    REQ_CHOICE_REASON="coderabbit_budget_refused_$(jq -r '.choice_reason // "request"' <<<"$dec" 2>/dev/null || echo request)"
    REQ_REVIEWER="codeant"
  fi
  if [[ "$REQ_REVIEWER" == coderabbit ]]; then REQ_BODY="@coderabbitai review"; else REQ_BODY="@codeant-ai review"; fi
  return 0
}
# Records the request just posted: the account-wide log and the PR's choice (issue #2257).
# Called only after the post succeeded; a failed record never re-posts (warning only).
record_request_choice() {
  local av="${SCRIPT_DIR}/review-availability.sh" ch="${SCRIPT_DIR}/cr-review-hourly.sh" repo_name detail
  (( DRY_RUN )) && return 0
  REQ_POSTED_REVIEWER="$REQ_REVIEWER"
  # The CodeRabbit hourly budget counts the request now that it is posted (#2257).
  if [[ "$REQ_REVIEWER" == coderabbit && -x "$ch" ]]; then
    "$ch" --consume >/dev/null 2>&1 \
      || echo "maybe-trigger-ai-review.sh: posted $REQ_BODY over the CodeRabbit hourly budget (a race with another tick) (#2257)" >&2
  fi
  [[ -x "$av" ]] || return 0
  [[ -n "$REQ_CHOICE_JSON" ]] || REQ_CHOICE_JSON="{}"
  detail="$(jq -c '{expected_s: (.expected_s // null), reviewers: (.reviewers // null)}' <<<"$REQ_CHOICE_JSON" 2>/dev/null)" || detail="{}"
  [[ -n "$detail" ]] || detail="{}"
  repo_name="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || repo_name=""
  if [[ "$repo_name" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
    rr_err="$("$av" record-request --repo "$repo_name" --pr "$PR_NUM" --head "$HEAD_SHA" --reviewer "$REQ_REVIEWER" \
      --reason "${REQ_CHOICE_REASON:-request}" --detail "$detail" 2>&1 >/dev/null)" \
      || echo "maybe-trigger-ai-review.sh: posted $REQ_BODY but could not record the reviewer choice (#2257): $rr_err" >&2
  else
    echo "maybe-trigger-ai-review.sh: posted $REQ_BODY but could not resolve the repo to record the reviewer choice (#2257)" >&2
  fi
}

# Writes the pending availability skip for this HEAD, but only on a path that would
# otherwise have posted the request (CodeAnt #4546742951). A tiered PR whose cadence or
# tier posts nothing records nothing, so no override can be waived by it. The skip is
# written under the PR's own owner/name, the scope check-skip reads back. An unresolved
# repo or a failed write restores the request path (fail toward asking).
settle_pending_skip() {
  local av="${SCRIPT_DIR}/review-availability.sh" repo_name
  [[ -n "$REQ_PENDING_SKIP" && "$REQ_BLOCK" == "$REQ_PENDING_SKIP" ]] || return 0
  if (( DRY_RUN )); then return 0; fi
  repo_name="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || repo_name=""
  if [[ ! "$repo_name" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] \
      || ! "$av" mark-skip --repo "$repo_name" --pr "$PR_NUM" --head "$HEAD_SHA" --reason "$REQ_PENDING_SKIP" >/dev/null 2>&1; then
    echo "maybe-trigger-ai-review.sh: could not record the skipped review request (issue #2256) — requesting review as before" >&2
    REQ_BLOCK=""
    REQ_FIRST=1
  fi
  REQ_PENDING_SKIP=""
}
REQ_TIER_JSON="$("$REVIEW_TIER_SH" "$PR_NUM" --json 2>/dev/null)" || REQ_TIER_JSON=""
REQ_GATE_NAME="$(jq -r '.gate // ""' <<<"$REQ_TIER_JSON" 2>/dev/null)" || REQ_GATE_NAME=""
# An unreadable tier keeps the default setting (after-ci), so the CI gate
# still applies; the tier path's own fail-closed rules are unchanged.
if [[ -n "$REQ_TIER_JSON" && -n "$REQ_GATE_NAME" ]]; then
  REQ_SETTING="$(jq -r '.review_request // "after-ci"' <<<"$REQ_TIER_JSON")"
  REQ_CHECKS="$(jq -r '(.review_request_checks // []) | join(",")' <<<"$REQ_TIER_JSON")"
fi
if [[ "$REQ_HEAD_DONE" != "$HEAD_SHA" && "$REQ_GATE_NAME" != "ci-only" ]]; then
  if [[ "$REQ_SETTING" == "never" ]]; then
    REQ_BLOCK="never"
  elif [[ "$REQ_SETTING" == "after-ci" ]]; then
    REQ_HEAD_EPOCH=""
    REQ_COMMIT_DATE="$(gh api "repos/{owner}/{repo}/commits/$HEAD_SHA" --jq '.commit.committer.date' 2>/dev/null)" || REQ_COMMIT_DATE=""
    if [[ -n "$REQ_COMMIT_DATE" ]]; then
      REQ_HEAD_EPOCH="$(jq -rn --arg d "$REQ_COMMIT_DATE" '$d | fromdateiso8601' 2>/dev/null)" || REQ_HEAD_EPOCH=""
    fi
    # The grace runs from the later of the commit time and the first poll that
    # saw this HEAD: an old commit pushed now still gets its full wait for CI.
    REQ_SEEN_SHA="$("$STATE_HELPER" --get ".prs[\"$PR_KEY\"].review_request_seen_sha // empty" 2>/dev/null || true)"
    REQ_SEEN_EPOCH="$("$STATE_HELPER" --get ".prs[\"$PR_KEY\"].review_request_seen_epoch // empty" 2>/dev/null || true)"
    if [[ "$REQ_SEEN_SHA" != "$HEAD_SHA" || ! "$REQ_SEEN_EPOCH" =~ ^[0-9]+$ ]]; then
      REQ_SEEN_EPOCH="$(date +%s)"
      # A dry run evaluates with this clock but never persists it.
      if (( DRY_RUN == 0 )); then
        "$STATE_HELPER" --set ".prs[\"${PR_KEY}\"].review_request_seen_sha=\"$HEAD_SHA\"" \
          --set ".prs[\"${PR_KEY}\"].review_request_seen_epoch=$REQ_SEEN_EPOCH" >/dev/null 2>&1 \
          || { REQ_BLOCK="ci_unreadable"; REQ_SEEN_EPOCH=""; }
      fi
    fi
    if [[ -n "$REQ_SEEN_EPOCH" && ( -z "$REQ_HEAD_EPOCH" || "$REQ_SEEN_EPOCH" -gt "$REQ_HEAD_EPOCH" ) ]]; then
      REQ_HEAD_EPOCH="$REQ_SEEN_EPOCH"
    fi
    # Every page and exact-HEAD workflow scope, shared with the merge gate (#2316).
    REQ_RUNS="$("${SCRIPT_DIR}/check-runs-snapshot.sh" --head "$HEAD_SHA" 2>/dev/null)" || REQ_RUNS=""
    # Required aggregate gates may not exist yet. Unlike optional named review
    # checks, a missing required context never expires into a green decision.
    if [[ -n "$REQ_RUNS" && -z "$REQ_BLOCK" ]]; then
      REQ_BASE="$(gh pr view "$PR_NUM" --json baseRefName --jq '.baseRefName' 2>/dev/null)" || REQ_BASE=""
      REQ_REQUIRED="$("${SCRIPT_DIR}/required-checks.sh" --base "$REQ_BASE" 2>/dev/null)" || REQ_REQUIRED=""
      if [[ -z "$REQ_REQUIRED" ]] || ! jq -e '.source != "unavailable" and (.contexts | type == "array") and (.apps | type == "object")' >/dev/null 2>&1 <<<"$REQ_REQUIRED"; then
        REQ_BLOCK="required_checks_unreadable"
      elif [[ "$(jq '.contexts | length' <<<"$REQ_REQUIRED")" -gt 0 ]]; then
        REQ_STATUSES="$(gh api --paginate "repos/{owner}/{repo}/commits/$HEAD_SHA/statuses?per_page=100" 2>/dev/null | jq -sec 'if length > 0 and all(.[]; type == "array" and all(.[]; type == "object" and (.context | type) == "string")) then add else error("invalid status pages") end')" || REQ_STATUSES=""
        if [[ -z "$REQ_STATUSES" ]]; then
          REQ_BLOCK="required_checks_unreadable"
        else
          REQ_REQUIRED_STATE="$(jq -cen -L "${SCRIPT_DIR}/lib" \
            --argjson req "$(jq -c '.contexts' <<<"$REQ_REQUIRED")" \
            --argjson apps "$(jq -c '.apps' <<<"$REQ_REQUIRED")" \
            --argjson runs "$(jq -c '{check_runs:.}' <<<"$REQ_RUNS")" \
            --argjson statuses "$REQ_STATUSES" -f "${SCRIPT_DIR}/lib/required-context-state.jq")" || REQ_REQUIRED_STATE=""
          if [[ -z "$REQ_REQUIRED_STATE" ]] || ! jq -e --argjson contexts "$(jq -c '.contexts' <<<"$REQ_REQUIRED")" 'type == "array" and ((map(.context) | sort) == ($contexts | sort)) and all(.[]; .satisfied == true)' >/dev/null 2>&1 <<<"$REQ_REQUIRED_STATE"; then
            REQ_BLOCK="required_checks_unsatisfied"
          fi
        fi
      fi
    fi
    if [[ ! -x "$REQUEST_SH" ]]; then
      echo "maybe-trigger-ai-review.sh: ERROR: review-request-gate.sh not found — the CodeAnt request is held this tick" >&2
      REQ_BLOCK="gate_missing"
    elif [[ -z "$REQ_RUNS" ]]; then
      REQ_BLOCK="ci_unreadable"
    elif [[ -z "$REQ_BLOCK" ]]; then
      REQ_OUT="$(printf '%s' "$REQ_RUNS" | "$REQUEST_SH" --setting "$REQ_SETTING" --head "$HEAD_SHA" \
        --checks "$REQ_CHECKS" --requested-head "$REQ_HEAD_DONE" --head-epoch "$REQ_HEAD_EPOCH")" || REQ_OUT=""
      if [[ -z "$REQ_OUT" ]]; then
        REQ_BLOCK="ci_unreadable"
      elif [[ "$(jq -r '.decision' <<<"$REQ_OUT")" == "request" ]]; then
        REQ_FIRST=1
        first_request_guard
        if [[ -z "$REQ_BLOCK" ]]; then
          availability_gate
        fi
      else
        REQ_BLOCK="$(jq -r '.reason' <<<"$REQ_OUT")"
      fi
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

# The first request only overrides the not-due complexity skips. A completed or
# superseded cadence for this HEAD (duplicate/state reasons) still stops the tick.
if [[ -n "$SKIP_REASON" ]] && { [[ "$REQ_FIRST" != 1 ]] || [[ "$SKIP_REASON" == "duplicate_poll_tick" || "$SKIP_REASON" == "state_behind_current_rounds" ]]; }; then
  if (( JSON_OUT )); then
    emit_json_skip
  else
    echo "skipped: $SKIP_REASON (cr_rounds=$CR_ROUNDS score=$SCORE threshold=$THRESHOLD_SCORE)"
  fi
  exit 0
fi

# Tier-aware triggers (issue #1749). One shared helper decides which reviewers
# a repo with a `## Review policy` may invite on this HEAD; the block below acts
# on its answer and exits. A repo with no policy gets mode `legacy`, and the
# code after this block — the pre-#1749 path, BugBot tier/refusal/cap guards
# included — runs unchanged. A missing helper (a partial install) also takes
# that path and says so; an unusable answer from a present helper posts
# nothing this tick (fail closed), and the next tick asks again.
TRIGGERS_SH="${SCRIPT_DIR}/review-triggers-allowed.sh"

# The one exception (issue #1898): an owner grant for THIS PR, HEAD and vendor,
# written only after the owner said yes in chat. paid-review-grant.sh spends it
# (single use, compare-and-set) and posts `@cursor review` itself; anything but
# `triggered` — no grant, a used one, another HEAD, unreadable state, a missing
# helper — leaves the approval skip in place (fail closed).
paid_grant_post_cursor() {
  local g="${SCRIPT_DIR}/paid-review-grant.sh" st
  if [[ ! -x "$g" ]]; then
    echo "maybe-trigger-ai-review.sh: paid-review-grant.sh missing — no owner grant can be spent (fail closed, #1898)" >&2
    return 1
  fi
  # Every refusal exits non-zero, so keep the STATUS line whatever the exit
  # code: a failed post (grant released) must not read as approval_required.
  st="$("$g" --trigger "$PR_NUM" --vendor cursor --head "$HEAD_SHA" | sed -n 's/^STATUS=//p')" || true
  if [[ "$st" == "trigger_failed" ]]; then
    echo "maybe-trigger-ai-review.sh: failed posting @cursor review under the owner's grant (trigger_failed; the grant was released)" >&2
    exit 5
  fi
  [[ "$st" == "triggered" ]]
}

TRIGGER_MODE="legacy"
TRIGGER_JSON=""
if [[ -x "$TRIGGERS_SH" ]]; then
  RC=0; TRIGGER_JSON="$("$TRIGGERS_SH" "$PR_NUM" --head "$HEAD_SHA")" || RC=$?
  if (( RC == 0 )) && jq -e '.mode == "legacy" or .mode == "tiered" or .mode == "fail_closed"' <<<"$TRIGGER_JSON" >/dev/null 2>&1; then
    TRIGGER_MODE="$(jq -r '.mode' <<<"$TRIGGER_JSON")"
  else
    echo "maybe-trigger-ai-review.sh: review-triggers-allowed.sh gave no usable answer (rc=$RC) — posting no reviewer trigger this tick (fail closed)" >&2
    TRIGGER_MODE="fail_closed"
    TRIGGER_JSON="$(jq -cn '{mode: "fail_closed", gate: null, allowed: [],
      reviewers: ({codeant: 0, cursor: 0}
        | with_entries(.value = {allowed: false, kind: "deferred", reason: "helper_unusable"})),
      deferred: ["codeant", "cursor"]}')"
  fi
else
  echo "maybe-trigger-ai-review.sh: DEGRADED: review-triggers-allowed.sh not found beside this script — tier-aware triggers unavailable, continuing with the legacy path" >&2
fi

# First review request for this HEAD while the complexity cadence is not due (#2195).
# Legacy only: the post is the request itself, guarded above, and it is recorded
# so the cadence never asks again for this HEAD. Tiered runs keep the complexity skip.
legacy_first_request() {
  if (( DRY_RUN )); then
    if (( JSON_OUT )); then
      jq -n --arg h "$HEAD_SHA" --arg rr "$REQ_REVIEWER" '{status: "dry_run", reason: "review_request_first", head_sha: $h, request_reviewer: $rr}'
    else
      echo "[DRY-RUN] would post 1 comment ($REQ_REVIEWER; first review request for this HEAD, complexity cadence not due)"
    fi
    exit 0
  fi
  if ! claim_request_head; then
    echo "maybe-trigger-ai-review.sh: this HEAD is already claimed by another tick (#2195) — not posting" >&2
    exit 0
  fi
  if ! reserve_request_reviewer; then
    release_request_head
    echo "maybe-trigger-ai-review.sh: no free reviewer can answer inside the window — not posting a request (#2257)" >&2
    exit 0
  fi
  if ! gh pr comment "$PR_NUM" --body "$REQ_BODY"; then
    release_request_head
    echo "maybe-trigger-ai-review.sh: failed posting $REQ_BODY" >&2
    exit 5
  fi
  record_request_choice
  if (( JSON_OUT )); then
    jq -n --arg h "$HEAD_SHA" --arg rr "$REQ_POSTED_REVIEWER" '{status: "triggered", reason: "review_request_first", head_sha: $h, trigger_mode: "legacy", request_reviewer: $rr}'
  else
    echo "triggered: posted the first review request for this HEAD (complexity cadence not due)"
  fi
  exit 0
}
if [[ "$REQ_FIRST" == 1 && -n "$SKIP_REASON" ]]; then
  if [[ "$TRIGGER_MODE" == "legacy" ]]; then
    settle_pending_skip
    if [[ -n "$REQ_BLOCK" ]]; then
      SKIP_REASON="review_request_${REQ_BLOCK}"
    else
      legacy_first_request
    fi
  fi
  # Tiered, or a held legacy request: the complexity skip still governs the tick.
  if (( JSON_OUT )); then
    emit_json_skip
  else
    echo "skipped: $SKIP_REASON (cr_rounds=$CR_ROUNDS score=$SCORE threshold=$THRESHOLD_SCORE)"
  fi
  exit 0
fi

# Legacy: a held request ends the tick before any state write, so the next tick
# asks again (issue #2195). The tiered path defers its CodeAnt step below.
if [[ "$TRIGGER_MODE" == "legacy" ]]; then settle_pending_skip; fi
if [[ "$TRIGGER_MODE" == "legacy" && -n "$REQ_BLOCK" ]]; then
  SKIP_REASON="review_request_${REQ_BLOCK}"
  if (( JSON_OUT )); then
    emit_json_skip
  else
    echo "skipped: $SKIP_REASON (review request held this tick)"
  fi
  exit 0
fi

if [[ "$TRIGGER_MODE" != "legacy" ]]; then
  TIER_GATE_TXT="$(jq -r '.gate // "unresolved"' <<<"$TRIGGER_JSON")"
  # The reviewers this script invites; CodeRabbit is never one of them.
  TRIGGER_SKIPS_JSON="$(jq -c '[ .reviewers | to_entries[]
      | select(.key == "codeant" or .key == "cursor")
      | select(.value.allowed | not) | {key, value: {kind: .value.kind, reason: .value.reason}} ] | from_entries' <<<"$TRIGGER_JSON")"
  DEFERRED_JSON="$(jq -c '[ .deferred[]? | select(. == "codeant" or . == "cursor") ]' <<<"$TRIGGER_JSON")"
  # bugbot_skipped keeps its pre-#1749 shape for the reasons it already had.
  # <helper json> [reason]: a denied claim passes its own reason, so the report
  # follows the claim's re-evaluation, not the earlier answer.
  bugbot_report() {
    BUGBOT_CAP_JSON="$(jq -c '.reviewers.cursor.daily_cap // null' <<<"$1" 2>/dev/null)"
    BUGBOT_SKIPPED_JSON="$(jq -c --arg why "${2-}" '
      .gate as $g | .reviewers.cursor as $c
      | (if $why != "" then $why elif ($c.allowed // false) then "" else ($c.reason // "") end) as $r
      | if $r == "" then null
        elif $r == "refused_head" then {reason: "refused_head", gate: null}
        elif $r == "daily_cap" then {reason: "daily_cap", gate: null, tally: ($c.daily_cap // null)}
        elif $r == "tier_excluded" then {reason: "review_tier", gate: $g}
        elif $r == "escalation_off" then {reason: "escalation_off", gate: $g}
        else {reason: $r, gate: $g} end' <<<"$1" 2>/dev/null)"
    [[ -n "$BUGBOT_CAP_JSON" ]] || BUGBOT_CAP_JSON="null"
    if [[ -z "$BUGBOT_SKIPPED_JSON" ]]; then
      BUGBOT_SKIPPED_JSON="$(jq -cn --arg r "${2-}" '(if $r == "" then null else {reason: $r, gate: null} end)')"
    fi
  }
  bugbot_report "$TRIGGER_JSON"
  ALLOWED_LIST="$(jq -r '[ .allowed[]? | select(. == "codeant" or . == "cursor") ] | join(", ")' <<<"$TRIGGER_JSON")"
  step_allowed() { [[ "$(jq -r --arg r "$1" '.reviewers[$r].allowed' <<<"$TRIGGER_JSON")" == "true" ]]; }
  skips_text() { jq -r 'to_entries | map("\(.key)=\(.value.reason)") | join(", ") | if . == "" then "none" else . end' <<<"$TRIGGER_SKIPS_JSON"; }

  emit_tiered_json() { # <status> <reason or "">
    jq -n \
      --arg status "$1" --arg reason "$2" \
      --argjson cr_rounds "$CR_ROUNDS" --argjson score "$SCORE" --arg head "$HEAD_SHA" \
      --arg mode "$TRIGGER_MODE" --argjson skips "$TRIGGER_SKIPS_JSON" --argjson deferred "$DEFERRED_JSON" \
      --argjson bugbot_skipped "$BUGBOT_SKIPPED_JSON" --argjson bugbot_daily_cap "$BUGBOT_CAP_JSON" \
      --arg rr "$REQ_POSTED_REVIEWER" \
      '{status: $status} + (if $reason == "" then {} else {reason: $reason} end) + {request_reviewer: ($rr | if . == "" then null else . end)}
       + {cr_rounds: $cr_rounds, score: $score, head_sha: $head, trigger_mode: $mode,
          trigger_skips: $skips, deferred: $deferred,
          bugbot_skipped: $bugbot_skipped, bugbot_daily_cap: $bugbot_daily_cap}'
  }

  # A held request shows in the dry run as deferred, not as a planned post (#2195).
  if [[ -n "$REQ_BLOCK" ]] && step_allowed codeant; then
    TRIGGER_SKIPS_JSON="$(jq -c --arg why "review_request_${REQ_BLOCK}" '.codeant = {kind: "deferred", reason: $why}' <<<"$TRIGGER_SKIPS_JSON")"
    DEFERRED_JSON="$(jq -c '. + ["codeant"] | unique' <<<"$DEFERRED_JSON")"
    ALLOWED_LIST="$(jq -r '[ .allowed[]? | select(. == "cursor") ] | join(", ")' <<<"$TRIGGER_JSON")"
  fi

  if (( DRY_RUN )); then
    # Evaluated, never claimed: a dry run posts nothing and records nothing.
    if (( JSON_OUT )); then
      emit_tiered_json dry_run ""
    else
      echo "[DRY-RUN] review tier $TIER_GATE_TXT ($TRIGGER_MODE): would post ${ALLOWED_LIST:-nothing}; skipped $(skips_text) cr_rounds=$CR_ROUNDS score=$SCORE"
    fi
    exit 0
  fi

  if [[ ! -x "$STATE_HELPER" ]]; then
    echo "maybe-trigger-ai-review.sh: session-state.sh missing or not executable: $STATE_HELPER (required to dedupe triggers)" >&2
    exit 4
  fi
  T_STEPS="$(jq -cn --arg h "$HEAD_SHA" --argjson r "$CR_ROUNDS" '{head_sha: $h, cr_rounds: $r, codeant: false, cursor: false}')"
  if [[ -f "$STATE_FILE" ]]; then
    EXISTING="$("$STATE_HELPER" --get ".prs[\"$PR_KEY\"].ai_review_trigger_steps // empty" 2>/dev/null || true)"
    if [[ -n "$EXISTING" && "$EXISTING" != "null" ]]; then
      MATCH="$(jq -cn --argjson ex "$EXISTING" --arg h "$HEAD_SHA" --argjson r "$CR_ROUNDS" '$ex | select(.head_sha == $h and .cr_rounds == $r)' 2>/dev/null || true)"
      [[ -n "$MATCH" && "$MATCH" != "null" ]] && T_STEPS="$MATCH"
    fi
  fi
  if ! "$STATE_HELPER" --set ".prs[\"${PR_KEY}\"].ai_review_trigger_steps=$T_STEPS"; then
    echo "maybe-trigger-ai-review.sh: failed to persist trigger step state — aborting without posting comments" >&2
    exit 4
  fi

  T_POSTED=0
  ANY_DEFERRED=0
  [[ "$DEFERRED_JSON" != "[]" ]] && ANY_DEFERRED=1
  # A review tier decides which reviewers this PR gets, and its codeant step is CodeAnt's
  # own claim and lifetime cap, so the tiered path always asks CodeAnt. The free-reviewer
  # choice (issue #2257) applies to the legacy path only.
  if [[ "$REQ_REVIEWER" != codeant ]]; then
    REQ_REVIEWER="codeant"; REQ_BODY="@codeant-ai review"; REQ_CHOICE_REASON="tier_requests_codeant"
  fi
  for step in codeant cursor; do
    case "$step" in
      codeant) body="$REQ_BODY" ;;
      cursor) body="@cursor review" ;;
    esac
    done_already="$("$STATE_HELPER" --get ".prs[\"$PR_KEY\"].ai_review_trigger_steps[\"$step\"] // empty" 2>/dev/null || true)"
    [[ "$done_already" == "true" ]] && continue
    if ! step_allowed "$step"; then
      reason="$(jq -r --arg r "$step" '.reviewers[$r].reason' <<<"$TRIGGER_JSON")"
      if [[ "$step" == "cursor" && "$reason" == "approval_required" ]] && paid_grant_post_cursor; then
        # Posted under the owner's grant (issue #1898): every earlier guard
        # already passed — approval_required is the last step of the chain.
        "$STATE_HELPER" --set ".prs[\"${PR_KEY}\"].ai_review_trigger_steps[\"cursor\"]=true" >/dev/null 2>&1 \
          || echo "maybe-trigger-ai-review.sh: comment posted but state update failed — the grant is used, so no re-post" >&2
        TRIGGER_SKIPS_JSON="$(jq -c 'del(.cursor)' <<<"$TRIGGER_SKIPS_JSON")"
        BUGBOT_SKIPPED_JSON="null"
        T_POSTED=$((T_POSTED + 1))
        continue
      fi
      echo "maybe-trigger-ai-review.sh: skipping $body — review tier $TIER_GATE_TXT: $reason (#1749)" >&2
      # A refusal is a fact about THIS HEAD: handled, as the legacy path records
      # it. Every other skip stays open, so a resumed run asks again.
      if [[ "$reason" == "refused_head" ]]; then
        "$STATE_HELPER" --set ".prs[\"${PR_KEY}\"].ai_review_trigger_steps[\"$step\"]=true" >/dev/null 2>&1 \
          || echo "maybe-trigger-ai-review.sh: failed to record the suppressed $step step — may re-check on retry" >&2
      fi
      continue
    fi
    # The CodeAnt request waits for CI (issue #2195). Held = deferred: the step
    # stays open, so the next tick asks again. Not claimed, so no cap is spent.
    if [[ "$step" == "codeant" && -n "$REQ_BLOCK" ]]; then
      # This step would post the request: only now does an availability skip get recorded.
      settle_pending_skip
    fi
    if [[ "$step" == "codeant" && -n "$REQ_BLOCK" ]]; then
      echo "maybe-trigger-ai-review.sh: holding $body — review request $REQ_BLOCK (#2195)" >&2
      TRIGGER_SKIPS_JSON="$(jq -c --arg why "review_request_${REQ_BLOCK}" '.codeant = {kind: "deferred", reason: $why}' <<<"$TRIGGER_SKIPS_JSON")"
      ANY_DEFERRED=1
      DEFERRED_JSON="$(jq -c '. + ["codeant"] | unique' <<<"$DEFERRED_JSON")"
      continue
    fi
    # A first request for this HEAD is claimed on the HEAD before anything posts (#2257), so
    # the CAS covers CodeRabbit and CodeAnt alike; the chosen reviewer is reserved after it.
    if [[ "$step" == "codeant" && "$REQ_FIRST" == 1 ]]; then
      if ! claim_request_head; then
        echo "maybe-trigger-ai-review.sh: $body already claimed by another tick for this HEAD (#2195/#2257) — not posting" >&2
        ANY_DEFERRED=1
        DEFERRED_JSON="$(jq -c '. + ["codeant"] | unique' <<<"$DEFERRED_JSON")"
        continue
      fi
      if ! reserve_request_reviewer; then
        release_request_head
        echo "maybe-trigger-ai-review.sh: no free reviewer can answer inside the window — holding the request (#2257)" >&2
        ANY_DEFERRED=1
        DEFERRED_JSON="$(jq -c '. + ["codeant"] | unique' <<<"$DEFERRED_JSON")"
        continue
      fi
      body="$REQ_BODY"
    fi
    # Claim BEFORE posting: the ledger bounds the lifetime caps across racing
    # runs and the seconds before GitHub lists the new comment.
    CLAIM_RC=0
    CLAIM_JSON="$("$TRIGGERS_SH" "$PR_NUM" --head "$HEAD_SHA" --claim "$step")" || CLAIM_RC=$?
    if (( CLAIM_RC != 0 )); then
      creason="$(jq -r --arg r "$step" '.reviewers[$r].reason // "claim_failed"' <<<"$CLAIM_JSON" 2>/dev/null)" || creason=""
      ckind="$(jq -r --arg r "$step" '.reviewers[$r].kind // "deferred"' <<<"$CLAIM_JSON" 2>/dev/null)" || ckind=""
      [[ -n "$creason" ]] || creason="claim_failed"
      [[ "$ckind" == "excluded" ]] || ckind="deferred"
      echo "maybe-trigger-ai-review.sh: skipping $body — claim denied ($creason, rc=$CLAIM_RC)" >&2
      if [[ "$step" == "codeant" && "$REQ_FIRST" == 1 ]]; then release_request_head; fi
      TRIGGER_SKIPS_JSON="$(jq -c --arg r "$step" --arg k "$ckind" --arg why "$creason" '.[$r] = {kind: $k, reason: $why}' <<<"$TRIGGER_SKIPS_JSON")"
      if [[ "$step" == "cursor" ]]; then
        PRIOR_CAP_JSON="$BUGBOT_CAP_JSON"
        bugbot_report "$CLAIM_JSON" "$creason"
        # A claim that never reached the cap keeps this run's earlier tally.
        [[ "$BUGBOT_CAP_JSON" != "null" ]] || BUGBOT_CAP_JSON="$PRIOR_CAP_JSON"
      fi
      if [[ "$ckind" == "deferred" ]]; then
        ANY_DEFERRED=1
        DEFERRED_JSON="$(jq -c --arg r "$step" '. + [$r] | unique' <<<"$DEFERRED_JSON")"
      fi
      continue
    fi
    if ! gh pr comment "$PR_NUM" --body "$body"; then
      "$TRIGGERS_SH" "$PR_NUM" --release "$step" >/dev/null 2>&1 \
        || echo "maybe-trigger-ai-review.sh: could not release the $step claim — its lifetime count may over-read by one" >&2
      if [[ "$step" == "codeant" && "$REQ_FIRST" == 1 ]]; then release_request_head; fi
      echo "maybe-trigger-ai-review.sh: failed posting $body" >&2
      exit 5
    fi
    "$STATE_HELPER" --set ".prs[\"${PR_KEY}\"].ai_review_trigger_steps[\"$step\"]=true" >/dev/null 2>&1 \
      || echo "maybe-trigger-ai-review.sh: comment posted but state update failed — the claim ledger still bounds a re-post" >&2
    if [[ "$step" == "codeant" ]]; then record_request_head; record_request_choice; fi
    T_POSTED=$((T_POSTED + 1))
  done

  if (( ANY_DEFERRED )); then
    # Leave the step record open: steps_incomplete() then lets the next tick
    # past duplicate_poll_tick, and that tick asks the helper again.
    STATUS="skipped"; REASON="tier_deferred"
  else
    NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ! "$STATE_HELPER" \
      --set ".prs[\"${PR_KEY}\"].ai_review_trigger_last_cr_round=$CR_ROUNDS" \
      --set ".prs[\"${PR_KEY}\"].ai_review_trigger_head_sha=$HEAD_SHA" \
      --set ".prs[\"${PR_KEY}\"].ai_review_trigger_last_at=\"$NOW_ISO\"" \
      --set ".prs[\"${PR_KEY}\"].ai_review_trigger_steps=null"; then
      echo "maybe-trigger-ai-review.sh: failed to persist completion markers" >&2
      exit 4
    fi
    STATUS="skipped"; REASON="tier_excluded"
  fi
  if (( T_POSTED > 0 )); then STATUS="triggered"; REASON=""; fi
  if (( JSON_OUT )); then
    emit_tiered_json "$STATUS" "$REASON"
  elif [[ "$STATUS" == "triggered" ]]; then
    echo "triggered: posted $T_POSTED AI reviewer comment(s) under review tier $TIER_GATE_TXT (cr_rounds=$CR_ROUNDS score=$SCORE; skipped: $(skips_text))"
  else
    echo "skipped: $REASON under review tier $TIER_GATE_TXT (cr_rounds=$CR_ROUNDS score=$SCORE; skipped: $(skips_text))"
  fi
  exit 0
fi

# Review-tier suppression (issue #1728). BugBot is invited only on the `full`
# gate and on `legacy` (no `## Review policy`); a ci-only or ci+codeant-one-round
# PR never needs it, so its nudge is skipped while CodeAnt still
# posts. The shared helper owns the excluded-gate list.
#
# FAILS OPEN like the refusal guard below: a missing helper, an unresolvable
# tier, or any exit but 0 posts the nudge — `legacy` behaviour is to post.
# Asked once, here, so a dry run reports the same answer a real run acts on.
BUGBOT_TIER_GATE=""
BUGBOT_TIER_REASON="review_tier"
bugbot_tier_excluded() {
  local helper="${SCRIPT_DIR}/bugbot-tier-excluded.sh" gate
  [[ -x "$helper" ]] || return 1
  gate="$("$helper" "$PR_NUM" --why)" || return 1
  BUGBOT_TIER_GATE="${gate%%$'\t'*}"
  if [[ "$gate" == *$'\t'escalation_off ]]; then BUGBOT_TIER_REASON="escalation_off"; fi
}
BUGBOT_SKIPPED_JSON="null"
if bugbot_tier_excluded; then
  BUGBOT_SKIPPED_JSON="$(jq -cn --arg g "$BUGBOT_TIER_GATE" --arg r "$BUGBOT_TIER_REASON" '{reason: $r, gate: $g}')"
fi

# Account-level daily cap (issue #1812). One BugBot review at the ledger's
# per-review rate is the trigger about to be spent; review-daily-cap.sh sums
# today's ET spend across every registered repo and answers ok, over, or
# unknown. Asked here, before --dry-run, so a dry run reports the answer a real
# run acts on — but only when the tier has not already ruled BugBot out, since
# a skipped trigger spends nothing. The real run applies it AFTER the
# refused-HEAD guard below, so both earlier skips keep their precedence.
#
# FAILS OPEN: a missing helper, an `unknown` tally, an unexpected exit, or
# output that is not the helper's JSON all post. Only a validated `over` skips.
BUGBOT_CAP_JSON="null"
BUGBOT_CAP_STATUS=""
bugbot_daily_cap() {
  local helper="${SCRIPT_DIR}/review-daily-cap.sh" rate out rc=0
  if [[ ! -x "$helper" ]]; then
    echo "DEGRADED: review-daily-cap.sh not found beside this script — account daily cap unavailable, continuing without it" >&2
    return 0
  fi
  rate="$("$helper" bugbot --rate)" || rate=""
  [[ "$rate" =~ ^[0-9]+(\.[0-9]+)?$ ]] || rate=0
  out="$("$helper" bugbot --add-usd "$rate")" || rc=$?
  if (( rc > 1 )) || ! jq -e 'type == "object" and (.status == "ok" or .status == "over" or .status == "unknown")' <<<"$out" >/dev/null 2>&1; then
    echo "maybe-trigger-ai-review.sh: review-daily-cap.sh gave no usable answer (rc=$rc) — daily cap unknown, posting" >&2
    return 0
  fi
  BUGBOT_CAP_JSON="$(jq -c . <<<"$out")"
  BUGBOT_CAP_STATUS="$(jq -r '.status' <<<"$out")"
  # The exit code and the status must agree before a skip is believed.
  if [[ "$BUGBOT_CAP_STATUS" == "over" && "$rc" -ne 1 ]] || [[ "$BUGBOT_CAP_STATUS" != "over" && "$rc" -ne 0 ]]; then
    echo "maybe-trigger-ai-review.sh: review-daily-cap.sh status '$BUGBOT_CAP_STATUS' disagrees with its exit $rc — treating the cap as unknown, posting" >&2
    BUGBOT_CAP_STATUS="unknown"
    # Report what was acted on, so --json never shows `over` beside a post.
    BUGBOT_CAP_JSON="$(jq -c '.status = "unknown"' <<<"$BUGBOT_CAP_JSON")"
  fi
  if [[ "$BUGBOT_CAP_STATUS" == "unknown" ]]; then
    echo "maybe-trigger-ai-review.sh: BugBot daily cap is unknown today — posting (the vendor cap stays the hard stop)" >&2
  fi
}
cap_skip_json() {
  jq -cn --argjson t "$BUGBOT_CAP_JSON" '{reason: "daily_cap", gate: null, tally: $t}'
}
cap_text() {
  LC_ALL=C printf 'daily cap: $%.2f of $%.2f spent today, one more review ($%.2f) would pass it' \
    "$(jq -r '.spent_usd' <<<"$BUGBOT_CAP_JSON")" \
    "$(jq -r '.cap_usd' <<<"$BUGBOT_CAP_JSON")" \
    "$(jq -r '.add_usd' <<<"$BUGBOT_CAP_JSON")"
}
if [[ -z "$BUGBOT_TIER_GATE" ]]; then
  bugbot_daily_cap
fi

# Owner approval (issue #1897): BugBot is paid per review, and no paid review
# starts without the owner's explicit approval in chat. When none of the
# earlier skips (tier, refused HEAD, daily cap) applies, this is the skip — the
# last step of the chain, so those reasons keep their precedence.
APPROVAL_SKIP_JSON='{"reason":"approval_required","gate":null}'

# BugBot spend-refusal suppression (issue #1199). BugBot is metered against a
# Cursor usage/spend limit, and it refused 64% of PRs in the 2026-08 audit window
# while this script kept nudging: 469 `@cursor review` comments across 244 PRs.
# A nudge cannot clear a usage limit. Once cursor[bot] has refused on THIS HEAD,
# every later nudge on the same HEAD is PR noise, so skip it — the next push is a
# new HEAD and starts clean, so this suppresses repetition, never the tool.
#
# FAILS OPEN in every uncertain case (unreadable comments, missing HEAD
# timestamp, malformed JSON): post the nudge. bugbot.md calls a duplicate
# `@cursor review` harmless, whereas a wrongly-suppressed nudge costs a whole
# review — the same cost asymmetry escalate-review.sh applies to this tool
# (issue #956). Returns 0 ONLY on a positively-identified refusal.
# Declining refusal suppression never bypasses tier, cap or paid approval.
#
# Timestamps are ordered with norm_ts() from lib/ts-normalizer.sh — the one
# canonical bash form of the #836/#885 rule — rather than a new jq mirror, so
# this file adds no second definition to keep in step.
bugbot_refused_head() {
  # Delegates to the shared implementation so this file and /fixpr Step 3b ask
  # one question with one answer (CodeRabbit review, PR #1203). A missing helper
  # declines to suppress — the same fail-open direction the helper itself takes.
  local helper="${SCRIPT_DIR}/bugbot-refused-head.sh"
  [[ -x "$helper" ]] || return 1
  "$helper" "$PR_NUM" "$HEAD_SHA" >/dev/null 2>&1
}


if (( DRY_RUN )); then
  # Match live skip precedence without posting, spending a grant or writing
  # trigger state. A non-refusal never bypasses the paid-approval boundary.
  DRY_SKIPPED_JSON="$BUGBOT_SKIPPED_JSON"
  DRY_BUGBOT_REFUSED=0
  if [[ -z "$BUGBOT_TIER_GATE" ]]; then
    if bugbot_refused_head; then
      DRY_SKIPPED_JSON='{"reason":"refused_head","gate":null}'
      DRY_BUGBOT_REFUSED=1
    elif [[ "$BUGBOT_CAP_STATUS" == "over" ]]; then
      DRY_SKIPPED_JSON="$(cap_skip_json)"
    else
      DRY_SKIPPED_JSON="$APPROVAL_SKIP_JSON"
    fi
  fi
  if (( JSON_OUT )); then
    jq -n \
      --arg status dry_run \
      --argjson cr_rounds "$CR_ROUNDS" \
      --argjson score "$SCORE" \
      --argjson threshold "$THRESHOLD_SCORE" \
      --argjson first_round "$FIRST_CR_ROUND" \
      --argjson cadence "$CADENCE_ROUNDS" \
      --arg head "$HEAD_SHA" \
      --argjson bugbot_skipped "$DRY_SKIPPED_JSON" \
      --argjson bugbot_daily_cap "$BUGBOT_CAP_JSON" \
      '{
        status: $status,
        cr_rounds: $cr_rounds,
        score: $score,
        threshold: $threshold,
        first_cr_round: $first_round,
        cadence_rounds: $cadence,
        head_sha: $head,
        bugbot_skipped: $bugbot_skipped,
        bugbot_daily_cap: $bugbot_daily_cap
      }'
  elif [[ "$BUGBOT_TIER_REASON" == "escalation_off" && -n "$BUGBOT_TIER_GATE" ]]; then
    echo "[DRY-RUN] would post 1 comment (codeant; @cursor review skipped — REVIEW_ESCALATION=off; gate $BUGBOT_TIER_GATE) cr_rounds=$CR_ROUNDS score=$SCORE"
  elif [[ -n "$BUGBOT_TIER_GATE" ]]; then
    echo "[DRY-RUN] would post 1 comment (codeant; @cursor review skipped — review tier $BUGBOT_TIER_GATE excludes BugBot) cr_rounds=$CR_ROUNDS score=$SCORE"
  elif (( DRY_BUGBOT_REFUSED )); then
    echo "[DRY-RUN] would post 1 comment (codeant; @cursor review skipped — BugBot already refused this HEAD for a Cursor usage/spend limit) cr_rounds=$CR_ROUNDS score=$SCORE"
  elif [[ "$BUGBOT_CAP_STATUS" == "over" ]]; then
    echo "[DRY-RUN] would post 1 comment (codeant; @cursor review skipped — $(cap_text)) cr_rounds=$CR_ROUNDS score=$SCORE"
  else
    echo "[DRY-RUN] would post 1 comment (codeant; @cursor review skipped — paid review requires owner approval) cr_rounds=$CR_ROUNDS score=$SCORE"
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
  '{
    head_sha: $h,
    cr_rounds: $r,
    codeant: false,
    cursor: false
  }')"

if [[ -f "$STATE_FILE" ]]; then
  EXISTING="$("$STATE_HELPER" --get ".prs[\"$PR_KEY\"].ai_review_trigger_steps // empty" 2>/dev/null || true)"
  if [[ -n "$EXISTING" && "$EXISTING" != "null" && "$EXISTING" != "" ]]; then
    # -c so the reused record stays single-line: INIT_STEPS is interpolated into
    # a jq path assignment below, which a pretty-printed value would break.
    MATCH="$(jq -cn --argjson ex "$EXISTING" --arg h "$HEAD_SHA" --argjson r "$CR_ROUNDS" '$ex | select(.head_sha == $h and .cr_rounds == $r)' 2>/dev/null || true)"
    if [[ -n "$MATCH" && "$MATCH" != "null" ]]; then
      # Resume the in-flight record as-is. A record written before #1583 may
      # still carry the retired `needs_pr_help`/`pr_help` keys; no reader
      # consults them any more, and rewriting a partially-posted record to drop
      # them would buy nothing.
      INIT_STEPS="$MATCH"
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
  POST_ONE_POSTED=0
  posted="$("$STATE_HELPER" --get ".prs[\"$PR_KEY\"].ai_review_trigger_steps[\"$step_key\"] // empty" 2>/dev/null || true)"
  if [[ "$posted" == "true" ]]; then
    return 0
  fi
  gh pr comment "$PR_NUM" --body "$body" || return 1
  POST_ONE_POSTED=1
  if ! "$STATE_HELPER" --set ".prs[\"${PR_KEY}\"].ai_review_trigger_steps[\"$step_key\"]=true"; then
    echo "maybe-trigger-ai-review.sh: comment posted but state update failed — may re-post on retry" >&2
  fi
}


# Once this HEAD carries a recorded request, the cadence posts no second one (#2195).
# on-push keeps the complexity cadence as it was.
if [[ "$REQ_SETTING" == "after-ci" && "$REQ_HEAD_DONE" == "$HEAD_SHA" ]]; then
  echo "maybe-trigger-ai-review.sh: @codeant-ai review already requested for this HEAD (#2195) — not posting it again" >&2
elif [[ "$REQ_FIRST" == 1 ]] && ! claim_request_head; then
  echo "maybe-trigger-ai-review.sh: this HEAD is already claimed by another tick (#2195) — not posting" >&2
else
  if [[ "$REQ_FIRST" == 1 ]] && ! reserve_request_reviewer; then
    release_request_head
    echo "maybe-trigger-ai-review.sh: no free reviewer can answer inside the window — not posting a request (#2257)" >&2
    exit 0
  fi
  if ! post_one codeant "$REQ_BODY"; then
    [[ "$REQ_FIRST" == 1 ]] && release_request_head
    echo "maybe-trigger-ai-review.sh: failed posting $REQ_BODY" >&2
    exit 5
  fi
  record_request_head
  # Log the choice only for a request this run actually posted: a resumed run whose step
  # was already done posts nothing and must not count as another request (#2257).
  if [[ "${POST_ONE_POSTED:-0}" == 1 ]]; then record_request_choice; fi
fi
if [[ -n "$BUGBOT_TIER_GATE" ]]; then
  # Deliberately NOT recorded as handled, unlike the refusal branch below. A
  # refusal is fixed for this HEAD, but a tier can change without a push (a
  # label flip, a base-branch policy edit). A resumed run re-asks the tier
  # above, so it skips again while the tier still excludes BugBot and posts
  # once the tier invites it. A completed run clears the record either way.
  if [[ "$BUGBOT_TIER_REASON" == "escalation_off" ]]; then
    echo "maybe-trigger-ai-review.sh: skipping @cursor review — REVIEW_ESCALATION=off (repo turned escalation off; gate $BUGBOT_TIER_GATE)" >&2
  else
    echo "maybe-trigger-ai-review.sh: skipping @cursor review — review tier gate '$BUGBOT_TIER_GATE' excludes BugBot (#1728)" >&2
  fi
elif bugbot_refused_head; then
  # Mark the step handled rather than leaving it false. A run that completes
  # clears the whole record (`ai_review_trigger_steps=null` below), but a run
  # that fails at a LATER step leaves it in place — and steps_incomplete() reads
  # a false `cursor` as "resume this trigger", so the retry would post the very
  # nudge we just decided cannot succeed. Suppressed IS complete for this HEAD.
  echo "maybe-trigger-ai-review.sh: skipping @cursor review — BugBot already refused this HEAD for a Cursor usage/spend limit (#1199)" >&2
  BUGBOT_SKIPPED_JSON='{"reason":"refused_head","gate":null}'
  if ! "$STATE_HELPER" --set ".prs[\"${PR_KEY}\"].ai_review_trigger_steps[\"cursor\"]=true"; then
    echo "maybe-trigger-ai-review.sh: failed to record the suppressed cursor step — may re-check on retry" >&2
  fi
elif [[ "$BUGBOT_CAP_STATUS" == "over" ]]; then
  # Deliberately NOT recorded as handled, like the tier skip: the cap is a
  # daily tally, not a fact about this HEAD, so a resumed run asks it again.
  echo "maybe-trigger-ai-review.sh: skipping @cursor review — account $(cap_text) (#1812)" >&2
  BUGBOT_SKIPPED_JSON="$(cap_skip_json)"
elif [[ "$("$STATE_HELPER" --get ".prs[\"$PR_KEY\"].ai_review_trigger_steps[\"cursor\"] // empty" 2>/dev/null || true)" == "true" ]]; then
  : # already posted for this round (a resumed run)
elif paid_grant_post_cursor; then
  # The owner approved this one review in chat (issue #1898); the grant is now used.
  "$STATE_HELPER" --set ".prs[\"${PR_KEY}\"].ai_review_trigger_steps[\"cursor\"]=true" >/dev/null 2>&1 \
    || echo "maybe-trigger-ai-review.sh: comment posted but state update failed — the grant is used, so no re-post" >&2
else
  # Left open (cursor stays false), like the tier and cap skips: approval is
  # not a fact about this HEAD. A completed run clears the record anyway.
  echo "maybe-trigger-ai-review.sh: skipping @cursor review — BugBot is a paid review and needs the owner's explicit approval (#1897)" >&2
  BUGBOT_SKIPPED_JSON="$APPROVAL_SKIP_JSON"
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
    --argjson bugbot_skipped "$BUGBOT_SKIPPED_JSON" \
    --argjson bugbot_daily_cap "$BUGBOT_CAP_JSON" \
    --arg rr "$REQ_POSTED_REVIEWER" \
    '{status: $status, cr_rounds: $cr_rounds, score: $score, head_sha: $head, bugbot_skipped: $bugbot_skipped, bugbot_daily_cap: $bugbot_daily_cap, request_reviewer: ($rr | if . == "" then null else . end)}'
elif [[ "$BUGBOT_TIER_REASON" == "escalation_off" && -n "$BUGBOT_TIER_GATE" ]]; then
  echo "triggered: posted AI reviewer comments (cr_rounds=$CR_ROUNDS score=$SCORE; @cursor review skipped — REVIEW_ESCALATION=off; gate $BUGBOT_TIER_GATE)"
elif [[ -n "$BUGBOT_TIER_GATE" ]]; then
  echo "triggered: posted AI reviewer comments (cr_rounds=$CR_ROUNDS score=$SCORE; @cursor review skipped — review tier $BUGBOT_TIER_GATE)"
elif [[ "$(jq -r '.reason // ""' <<<"$BUGBOT_SKIPPED_JSON")" == "daily_cap" ]]; then
  echo "triggered: posted AI reviewer comments (cr_rounds=$CR_ROUNDS score=$SCORE; @cursor review skipped — $(cap_text))"
elif [[ "$(jq -r '.reason // ""' <<<"$BUGBOT_SKIPPED_JSON")" == "approval_required" ]]; then
  echo "triggered: posted AI reviewer comments (cr_rounds=$CR_ROUNDS score=$SCORE; @cursor review skipped — paid review requires owner approval)"
else
  echo "triggered: posted AI reviewer comments (cr_rounds=$CR_ROUNDS score=$SCORE)"
fi
exit 0
