#!/usr/bin/env bash
# fixpr-reviewer-triggers.sh — /fixpr Step 3b: invite missing AI reviewers after a push.
# catalog: review-escalation — `/fixpr` Step 3b's post-push reviewer triggers — the legacy order verbatim, or the review tier's allowed set through review-triggers-allowed.sh
#
# PURPOSE
#   /fixpr Step 3b used to be inline bash in fixpr/SKILL.md, which no harness
#   could run against a fixture policy (issue #1749). It lives here now, so a
#   test can prove what it posts. SKILL.md waits its 120 s, then runs this once
#   with the SHA it just pushed.
#
# USAGE
#   fixpr-reviewer-triggers.sh <pr> --repo <owner/name> --pushed-sha <sha> --pushed-at <iso-8601>
#   fixpr-reviewer-triggers.sh --help | -h
#
#   --pushed-sha  The SHA Step 3 pushed (`git rev-parse HEAD` after the push).
#                 Every check below is asked about THIS commit, never the
#                 pre-push audit HEAD (issue #1517).
#   --pushed-at   The timestamp Step 3 captured just BEFORE `git push`, so a
#                 fast bot that starts during the push still counts as active.
#
# WHAT IT POSTS
#   The sibling review-triggers-allowed.sh is asked first, with --head
#   <pushed-sha>.
#
#   mode legacy (no `## Review policy`), or that helper missing — exactly the
#   pre-#1749 Step 3b, in this order:
#     1. reviewer-activity.sh decides which of coderabbit / graphite / codeant
#        already auto-triggered on the pushed SHA since --pushed-at.
#     2. coderabbit missing → `@coderabbitai full review`, unless 2 were posted
#        on the PR in the trailing hour; a successful post records the slot
#        with cr-review-hourly.sh --record-explicit.
#     3. graphite missing → `@graphite-app re-review`.
#     4. codeant missing → `@codeant-ai review`.
#     5. `@cursor review` once per push, skipped when bugbot-tier-excluded.sh
#        excludes BugBot, then when bugbot-refused-head.sh says BugBot already
#        refused the pushed SHA, then — LAST — when review-daily-cap.sh answers
#        a validated `over`, which also appends `BugBot skipped: daily cap ($X
#        of $Y today)` once per HEAD under the PR body's `## Review notes`
#        (pr-body-review-note.sh). An `unknown` cap or a missing helper posts.
#
#   mode tiered / fail_closed — only what the review tier allows on the pushed
#   SHA, same order: a reviewer that already auto-triggered is skipped; an
#   allowed one is claimed (`--claim`), then posted, and released if the post
#   fails; CodeRabbit keeps its 2-per-hour check. Excluded and deferred
#   reviewers are named and skipped. Right after a push CI is usually still
#   running, so this often posts NOTHING — by design: pr-preflight.sh and
#   maybe-trigger-ai-review.sh ask again once CI is green. BugBot's refusal
#   and daily-cap guards run inside the helper; a daily-cap skip still writes
#   the PR-body note above.
#
# OUTPUT
#   `[REVIEWERS] …` lines on stdout, one per decision, then
#   `TRIGGER_MODE=<legacy|tiered|fail_closed>`.
#
# EXIT STATUS
#   0  Done (a failed post is reported, not fatal — as Step 3b always was).
#   2  Usage error.
#   70 --help header extraction produced no output (internal defect).

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
  exit 0
fi

die_usage() { printf 'fixpr-reviewer-triggers.sh: %s\n' "$1" >&2; exit 2; }
PR_NUMBER=""
REPO_FULL=""
PUSHED_SHA=""
PUSHED_AT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ -n "${2-}" ]] || die_usage "--repo requires a value"; REPO_FULL="$2"; shift 2 ;;
    --pushed-sha) [[ -n "${2-}" ]] || die_usage "--pushed-sha requires a value"; PUSHED_SHA="$2"; shift 2 ;;
    --pushed-at) [[ -n "${2-}" ]] || die_usage "--pushed-at requires a value"; PUSHED_AT="$2"; shift 2 ;;
    -*) die_usage "unknown flag: $1" ;;
    *) [[ -z "$PR_NUMBER" ]] || die_usage "unexpected argument: $1"; PR_NUMBER="$1"; shift ;;
  esac
done
[[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]] || die_usage "usage: fixpr-reviewer-triggers.sh <pr> --repo <owner/name> --pushed-sha <sha> --pushed-at <iso>"
[[ "$REPO_FULL" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die_usage "--repo must be owner/name"
[[ "$PUSHED_SHA" =~ ^[0-9a-fA-F]{7,40}$ ]] || die_usage "--pushed-sha must be a commit SHA"
[[ -n "$PUSHED_AT" ]] || die_usage "--pushed-at is required"
command -v jq >/dev/null 2>&1 || die_usage "'jq' not found on PATH"
OWNER="${REPO_FULL%%/*}"
REPO="${REPO_FULL##*/}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sibling first, then the standard three paths (portable-skill-resolution.md).
resolve() {
  local name="$1" c
  for c in "$SELF_DIR/$name" \
           "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
           "$HOME/.claude/scripts/$name" \
           ".claude/scripts/$name"; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}
CR_HOURLY_SCRIPT="$(resolve cr-review-hourly.sh || true)"
REVIEWER_ACTIVITY_SH="$(resolve reviewer-activity.sh || true)"
BUGBOT_REFUSED_SH="$(resolve bugbot-refused-head.sh || true)"
BUGBOT_TIER_SH="$(resolve bugbot-tier-excluded.sh || true)"
REVIEW_DAILY_CAP_SH="$(resolve review-daily-cap.sh || true)"
PR_BODY_NOTE_SH="$(resolve pr-body-review-note.sh || true)"
TRIGGERS_SH="$(resolve review-triggers-allowed.sh || true)"

# ---------------------------------------------------------------------------
# Which reviewers already auto-triggered on the pushed SHA (shared by both paths).
# ---------------------------------------------------------------------------
REVIEWER_ACTIVITY=""
if [[ -n "$REVIEWER_ACTIVITY_SH" ]]; then
  REVIEWER_ACTIVITY=$(GH_REPO="$REPO_FULL" "$REVIEWER_ACTIVITY_SH" "$PR_NUMBER" "$PUSHED_SHA" "$PUSHED_AT") || REVIEWER_ACTIVITY=""
else
  echo "[REVIEWERS] reviewer-activity.sh not found — re-run after .claude/scripts/ is synced from main" >&2
fi
jq -e 'type == "object"' <<<"$REVIEWER_ACTIVITY" >/dev/null 2>&1 \
  || REVIEWER_ACTIVITY='{"coderabbit":false,"graphite":false,"codeant":false}'
jq -r 'to_entries[] | "[REVIEWERS] \(.key): \(if .value then "auto-triggered" else "missing" end)"' <<<"$REVIEWER_ACTIVITY"
active() { [[ "$(jq -r --arg k "$1" '.[$k] // false' <<<"$REVIEWER_ACTIVITY")" == "true" ]]; }

# CodeRabbit's per-PR cap: 2 manual `@coderabbitai full review` in the trailing hour.
CR_TRIGGER_COUNT_LAST_HOUR=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR_NUMBER/comments?per_page=100" | jq -s '
  (add // [])
  | map(select(
      (.body // "") == "@coderabbitai full review"
      and ((.created_at // "") >= (now - 3600 | strftime("%Y-%m-%dT%H:%M:%SZ")))
    ))
  | length
' 2>/dev/null) || CR_TRIGGER_COUNT_LAST_HOUR=""
[[ "$CR_TRIGGER_COUNT_LAST_HOUR" =~ ^[0-9]+$ ]] || CR_TRIGGER_COUNT_LAST_HOUR=0

post_cr() { # posts @coderabbitai full review under the per-PR cap; 0 posted, 1 not
  if [[ "$CR_TRIGGER_COUNT_LAST_HOUR" -lt 2 ]]; then
    if gh pr comment "$PR_NUMBER" --repo "$REPO_FULL" --body "@coderabbitai full review"; then
      # Persist explicit trigger only when the comment actually posted (avoid ghost timestamps on gh failure)
      if [[ -n "$CR_HOURLY_SCRIPT" ]]; then
        "$CR_HOURLY_SCRIPT" --record-explicit "$PR_NUMBER" || true
      fi
      return 0
    fi
    echo "[REVIEWERS] FAILED to post @coderabbitai full review — check gh auth scopes; not recording explicit trigger" >&2
    return 1
  fi
  echo "[REVIEWERS] coderabbit trigger budget exhausted (>=2 in the last hour); skipping manual trigger"
  if [[ -n "$CR_HOURLY_SCRIPT" ]]; then
    echo "[REVIEWERS] Surface to user: this PR has hit 2 explicit @coderabbitai full review posts in the last hour — CodeRabbit may be rate-limited; wait for reviews or use local CR (cr-local-review.md)."
  fi
  return 2
}

# The daily-cap skip note: once per pushed HEAD, under the PR body's ## Review notes.
note_cap_skip() { # <tally json>
  local note
  note=$(LC_ALL=C printf 'BugBot skipped: daily cap ($%.2f of $%.2f today)' \
    "$(jq -r '.spent_usd' <<<"$1")" "$(jq -r '.cap_usd' <<<"$1")")
  echo "[REVIEWERS] skipping @cursor review — $note (#1812)"
  if [[ -z "$PR_BODY_NOTE_SH" ]] || ! "$PR_BODY_NOTE_SH" "$PR_NUMBER" --repo "$REPO_FULL" \
      --head "$PUSHED_SHA" --key bugbot-daily-cap --line "$note" >/dev/null; then
    echo "[REVIEWERS] could not record the daily-cap skip in the PR body's ## Review notes" >&2
  fi
}

# ---------------------------------------------------------------------------
# Mode.
# ---------------------------------------------------------------------------
TRIGGER_MODE="legacy"
TRIGGER_JSON=""
if [[ -n "$TRIGGERS_SH" ]]; then
  T_RC=0
  TRIGGER_JSON="$("$TRIGGERS_SH" "$PR_NUMBER" --repo "$REPO_FULL" --head "$PUSHED_SHA")" || T_RC=$?
  if (( T_RC == 0 )) && jq -e '.mode == "legacy" or .mode == "tiered" or .mode == "fail_closed"' <<<"$TRIGGER_JSON" >/dev/null 2>&1; then
    TRIGGER_MODE="$(jq -r '.mode' <<<"$TRIGGER_JSON")"
  else
    echo "[REVIEWERS] review-triggers-allowed.sh gave no usable answer (rc=$T_RC) — posting no reviewer trigger (fail closed); pr-preflight.sh asks again" >&2
    TRIGGER_MODE="fail_closed"
    TRIGGER_JSON='{"mode":"fail_closed","gate":null,"reviewers":null}'
  fi
else
  echo "[REVIEWERS] DEGRADED: review-triggers-allowed.sh not found (checked beside this script and the three standard paths) — tier-aware triggers unavailable, using the legacy order"
fi

if [[ "$TRIGGER_MODE" == "legacy" ]]; then
  # ---- the pre-#1749 Step 3b, unchanged in order and conditions ----
  if ! active coderabbit; then post_cr || true; fi
  if ! active graphite; then
    gh pr comment "$PR_NUMBER" --repo "$REPO_FULL" --body "@graphite-app re-review" \
      || echo "[REVIEWERS] FAILED to post @graphite-app re-review" >&2
  fi
  if ! active codeant; then
    gh pr comment "$PR_NUMBER" --repo "$REPO_FULL" --body "@codeant-ai review" \
      || echo "[REVIEWERS] FAILED to post @codeant-ai review" >&2
  fi
  # BugBot may ALREADY have refused this fresh HEAD: it auto-runs on push, so by
  # the time Step 3b executes a usage-limit refusal can be sitting on the very
  # commit we just created (observed on PR #1203 — refusal, CI nudge, second
  # refusal, all within seven seconds). One shared check answers it; it fails
  # open, so an unreadable or unattributable state still posts. The review tier
  # (#1728) is asked first and the account daily cap (#1812) LAST, so the tier
  # and refused-HEAD skips keep their precedence.
  BUGBOT_CAP_JSON=""
  bugbot_cap_over() {   # exit 0 only on a validated `over`
    local rate rc=0
    if [[ -z "$REVIEW_DAILY_CAP_SH" ]]; then
      echo "[REVIEWERS] DEGRADED: review-daily-cap.sh not found (checked all three paths) — BugBot daily cap unknown, posting"
      return 1
    fi
    rate=$("$REVIEW_DAILY_CAP_SH" bugbot --rate 2>/dev/null) || rate=0
    [[ "$rate" =~ ^[0-9]+(\.[0-9]+)?$ ]] || rate=0
    BUGBOT_CAP_JSON=$("$REVIEW_DAILY_CAP_SH" bugbot --add-usd "$rate") || rc=$?
    if [[ "$rc" -eq 1 && "$(jq -r '.status // ""' <<<"$BUGBOT_CAP_JSON" 2>/dev/null)" == "over" ]]; then
      return 0
    fi
    [[ "$(jq -r '.status // ""' <<<"$BUGBOT_CAP_JSON" 2>/dev/null)" == "ok" ]] \
      || echo "[REVIEWERS] BugBot daily cap unknown (rc=$rc) — posting; the vendor cap stays the hard stop"
    return 1
  }
  if [[ -n "$BUGBOT_TIER_SH" ]] && TIER_GATE=$("$BUGBOT_TIER_SH" "$PR_NUMBER" --repo "$REPO_FULL" 2>/dev/null); then
    echo "[REVIEWERS] skipping @cursor review — review tier $TIER_GATE excludes BugBot (#1728)"
  elif [[ -n "$BUGBOT_REFUSED_SH" ]] && GH_REPO="$REPO_FULL" "$BUGBOT_REFUSED_SH" "$PR_NUMBER" "$PUSHED_SHA" >/dev/null 2>&1; then
    echo "[REVIEWERS] skipping @cursor review — BugBot already refused this HEAD for a Cursor usage/spend limit (#1204)"
  elif bugbot_cap_over; then
    note_cap_skip "$BUGBOT_CAP_JSON"
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO_FULL" --body "@cursor review" \
      || echo "[REVIEWERS] FAILED to post @cursor review" >&2
  fi
  echo "TRIGGER_MODE=legacy"
  exit 0
fi

# ---- tier-aware: only what the review tier allows on the pushed SHA ----
GATE_TXT="$(jq -r '.gate // "unresolved"' <<<"$TRIGGER_JSON")"
echo "[REVIEWERS] review tier $GATE_TXT ($TRIGGER_MODE): posting only what it allows on ${PUSHED_SHA:0:7} (#1749)"
for key in coderabbit graphite codeant cursor; do
  case "$key" in
    coderabbit) body="@coderabbitai full review" ;;
    graphite) body="@graphite-app re-review" ;;
    codeant) body="@codeant-ai review" ;;
    cursor) body="@cursor review" ;;
  esac
  if [[ "$key" != "cursor" ]] && active "$key"; then
    continue
  fi
  decision="$(jq -r --arg k "$key" '.reviewers[$k] | select(type == "object") | "\(.kind) \(.reason)"' <<<"$TRIGGER_JSON" 2>/dev/null)" || decision=""
  kind="${decision%% *}"; reason="${decision#* }"
  case "$kind" in allowed|excluded|deferred) ;; *) kind="deferred"; reason="tier_unresolved" ;; esac
  if [[ "$kind" == "allowed" && "$key" == "coderabbit" && "$CR_TRIGGER_COUNT_LAST_HOUR" -ge 2 ]]; then
    echo "[REVIEWERS] coderabbit trigger budget exhausted (>=2 in the last hour); skipping manual trigger"
    continue
  fi
  if [[ "$kind" == "allowed" ]]; then
    C_RC=0
    CLAIM_JSON="$("$TRIGGERS_SH" "$PR_NUMBER" --repo "$REPO_FULL" --head "$PUSHED_SHA" --claim "$key")" || C_RC=$?
    if (( C_RC != 0 )); then
      kind="deferred"
      reason="$(jq -r --arg k "$key" '.reviewers[$k].reason // "claim_failed"' <<<"$CLAIM_JSON" 2>/dev/null)" || reason=""
      [[ -n "$reason" ]] || reason="claim_failed"
    fi
  fi
  if [[ "$kind" == "allowed" ]]; then
    if gh pr comment "$PR_NUMBER" --repo "$REPO_FULL" --body "$body"; then
      echo "[REVIEWERS] posted $body — review tier $GATE_TXT allows it"
      if [[ "$key" == "coderabbit" && -n "$CR_HOURLY_SCRIPT" ]]; then
        "$CR_HOURLY_SCRIPT" --record-explicit "$PR_NUMBER" || true
      fi
    else
      echo "[REVIEWERS] FAILED to post $body — releasing its claim" >&2
      "$TRIGGERS_SH" "$PR_NUMBER" --repo "$REPO_FULL" --release "$key" >/dev/null 2>&1 \
        || echo "[REVIEWERS] could not release the $key claim — its lifetime count may over-read by one" >&2
    fi
    continue
  fi
  if [[ "$key" == "cursor" && "$reason" == "daily_cap" ]]; then
    TALLY="$(jq -c '.reviewers.cursor.daily_cap // empty' <<<"$TRIGGER_JSON")"
    if [[ -n "$TALLY" ]]; then note_cap_skip "$TALLY"; continue; fi
  fi
  if [[ "$kind" == "excluded" ]]; then
    echo "[REVIEWERS] skipping $body — review tier $GATE_TXT: $reason"
  else
    echo "[REVIEWERS] deferring $body — review tier $GATE_TXT: $reason (pr-preflight.sh asks again)"
  fi
done
echo "TRIGGER_MODE=$TRIGGER_MODE"
exit 0
