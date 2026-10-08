#!/usr/bin/env bash
# bugbot-tier-excluded.sh — does this PR's review tier exclude BugBot?
# catalog: review-escalation — One shared answer for every `@cursor review` trigger path and the escalation chain: does the PR's review tier exclude BugBot?
#
# PURPOSE
#   A repo may declare review tiers in its `.claude/pm-config.md` (issue #1724).
#   BugBot, the stack's most expensive reviewer, is invited only on the `full`
#   gate and on `legacy` (no policy). This is the one place that turns the
#   sibling review-tier.sh's answer into that yes/no, so every trigger path
#   (maybe-trigger-ai-review.sh, pr-preflight.sh, /fixpr Step 3b, the
#   cursor-review-pr-comment.yml workflow) and escalate-review.sh share one
#   excluded-gate list and one failure direction (issue #1728).
#   A repo can also turn escalation off outright with REVIEW_ESCALATION=off in
#   the same section (issue #1807). review-tier.sh reports it as
#   `"escalation":"off"`, and BugBot is then never invited on any gate.
#
# USAGE
#   bugbot-tier-excluded.sh <pr_number> [--repo <owner/name>] [--base <ref>]
#
#   --repo and --base are forwarded to review-tier.sh unchanged. Pass --base
#   when the PR's base branch is already known; it saves a `gh pr view`.
#
# OUTPUT
#   stdout: the resolved gate (legacy | ci-only | ci+codeant-one-round | full)
#   on exit 0 and exit 1; nothing on exit 2. It stays the gate when escalation
#   is off, so callers' messages and JSON keep their shape.
#   stderr: one line when escalation off is what skips BugBot.
#
# EXIT STATUS
#   0  The gate is ci-only or ci+codeant-one-round, or the repo turned
#      escalation off (`"escalation":"off"`) on any recognised gate, full and
#      legacy included — skip the BugBot invitation.
#   1  The gate is full or legacy and escalation is on — invite BugBot as today.
#   2  Usage error, or the tier could not be resolved: review-tier.sh missing,
#      exiting non-zero, or returning no recognised gate. One stderr line.
#   70  --help header extraction produced no output (internal defect).
#
# FAIL-OPEN BY DESIGN
#   Callers treat 1 and 2 alike: post. `legacy` behaviour is to post, and the
#   refusal guard (bugbot-refused-head.sh) already fails the same way, so an
#   unreadable policy costs at most one BugBot review, never a missing one.
#   The merge gate is unaffected: it resolves the tier itself and fails closed.
#   The escalation switch follows the same rule: only a literal "off" on a
#   resolved answer skips. A missing field (an older resolver) or any other
#   value reads as on. review-tier.sh already turns an unclear value into
#   "off", so that case never reaches here as anything else.

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
  exit 0
fi

warn() { printf 'bugbot-tier-excluded.sh: %s\n' "$1" >&2; }
die_usage() { warn "$1"; exit 2; }

PR_NUMBER=""
REPO=""
BASE_REF=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ -n "${2-}" ]] || die_usage "--repo requires a value"; REPO="$2"; shift 2 ;;
    --base) [[ -n "${2-}" ]] || die_usage "--base requires a value"; BASE_REF="$2"; shift 2 ;;
    -*) die_usage "unknown flag: $1" ;;
    *)
      [[ -z "$PR_NUMBER" ]] || die_usage "unexpected argument: $1"
      PR_NUMBER="$1"
      shift
      ;;
  esac
done

[[ -n "$PR_NUMBER" ]] || die_usage "usage: $(basename "$0") <pr_number> [--repo <owner/name>] [--base <ref>]"
[[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]] || die_usage "<pr_number> must be a positive integer (got: $PR_NUMBER)"
command -v jq >/dev/null 2>&1 || die_usage "'jq' not found on PATH"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$SELF_DIR/review-tier.sh"
# Invoked through bash rather than exec'd, so a checkout that dropped the
# executable bit (a CI workspace, a copied fixture) still resolves.
[[ -f "$RESOLVER" ]] || { warn "review-tier.sh not found beside this script ($RESOLVER) — tier unresolved, BugBot not skipped"; exit 2; }

RC=0
OUT="$(bash "$RESOLVER" "$PR_NUMBER" ${REPO:+--repo "$REPO"} ${BASE_REF:+--base "$BASE_REF"} --json)" || RC=$?
if [[ "$RC" -ne 0 ]]; then
  warn "review-tier.sh exited $RC for PR #$PR_NUMBER — tier unresolved, BugBot not skipped"
  exit 2
fi
GATE="$(printf '%s' "$OUT" | jq -r 'if type == "object" then (.gate // "") else "" end' 2>/dev/null)" || GATE=""
ESCALATION="$(printf '%s' "$OUT" | jq -r 'if type == "object" then (.escalation // "" | tostring) else "" end' 2>/dev/null)" || ESCALATION=""

case "$GATE" in
  ci-only|ci+codeant-one-round|full|legacy)
    if [[ "$ESCALATION" == "off" ]]; then
      warn "escalation off — BugBot not invited (REVIEW_ESCALATION=off in ## Review policy, gate $GATE, issue #1807)"
      printf '%s\n' "$GATE"
      exit 0
    fi
    ;;
esac
case "$GATE" in
  ci-only|ci+codeant-one-round) printf '%s\n' "$GATE"; exit 0 ;;
  full|legacy)                  printf '%s\n' "$GATE"; exit 1 ;;
esac
warn "review-tier.sh returned no recognised gate for PR #$PR_NUMBER (got: '${GATE}') — tier unresolved, BugBot not skipped"
exit 2
