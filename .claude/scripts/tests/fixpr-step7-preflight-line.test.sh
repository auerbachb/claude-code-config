#!/usr/bin/env bash
# /fixpr Step 7 renders the Pre-flight line from per-reviewer statuses, not `.clean` (issue #1839).
# catalog: tests — Runs `/fixpr` Step 7's real Pre-flight-line block on `pr-preflight.sh` summaries — "all N reviewers engaged" only when every reviewer is already-present, a ci-only PR names the tier-excluded reviewers, BugBot awaiting owner approval is named, and an empty or unreadable summary never renders as clean
#
# WHAT IS UNDER TEST
#   The fenced bash under `<!-- test-anchor: fixpr-step-7-preflight-line -->`
#   in `.claude/skills/fixpr/SKILL.md`, extracted at run time by
#   lib/skill-bash.sh and run against fixture summaries shaped like
#   `pr-preflight.sh`'s PREFLIGHT_SUMMARY line.
#
# WHY (issue #1839)
#   `.clean` is true when a reviewer is `skipped-tier-excluded` (PR #1838) or
#   `skipped-approval-required` (#1897), so a label keyed on `.clean` said
#   "all 4 reviewers engaged" on a ci-only PR where nothing was invited — and
#   "4" went stale when PR #1951 retired Graphite.
#
# Requires: bash 3.2+, jq. Offline.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
FIXPR="$REPO_ROOT/.claude/skills/fixpr/SKILL.md"
# shellcheck source=lib/skill-bash.sh
source "$TEST_DIR/lib/skill-bash.sh"

PASS=0
FAIL=0
check_eq() {
  if [[ "$3" == "$2" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $1 (expected '$2', got '$3')"
  fi
}

BLOCK="$(extract_skill_bash "$FIXPR" fixpr-step-7-preflight-line)" || exit 1

# render <summary-json> — prints the block's PREFLIGHT_LINE
render() {
  PREFLIGHT_SUMMARY_JSON="$1" bash -c "$BLOCK"'
printf "LINE %s\n" "$PREFLIGHT_LINE"' 2>/dev/null | sed -n 's/^LINE //p'
}

# summary <clean> <draft_action> <codeant> <coderabbit> <cursor>
summary() {
  jq -cn --argjson clean "$1" --arg d "$2" --arg ca "$3" --arg cr "$4" --arg cu "$5" '{
    pr: 1, is_draft: false, draft_action: $d, actions: 0, clean: $clean,
    reviewers: {
      codeant:    {trigger: "@codeant-ai review",        status: $ca},
      coderabbit: {trigger: "@coderabbitai full review", status: $cr},
      cursor:     {trigger: "@cursor review",            status: $cu}
    }}'
}

echo "== clean summaries =="
check_eq "every reviewer already-present → all 3 engaged" \
  "clean — already ready, all 3 reviewers engaged" \
  "$(render "$(summary true not-draft already-present already-present already-present)")"
check_eq "ci-only (all tier-excluded) names the excluded reviewers, claims none engaged" \
  "clean — already ready, 0 of 3 reviewers engaged; review tier excludes codeant, coderabbit, cursor" \
  "$(render "$(summary true not-draft skipped-tier-excluded skipped-tier-excluded skipped-tier-excluded)")"
check_eq "legacy repo, BugBot without a grant → awaiting owner approval named" \
  "clean — already ready, 2 of 3 reviewers engaged; awaiting owner approval: cursor" \
  "$(render "$(summary true not-draft already-present already-present skipped-approval-required)")"
check_eq "ci+codeant-one-round: two excluded, BugBot awaiting approval" \
  "clean — already ready, 1 of 3 reviewers engaged; awaiting owner approval: cursor; review tier excludes coderabbit" \
  "$(render "$(summary true not-draft already-present skipped-tier-excluded skipped-approval-required)")"

echo
echo "== summaries with work done or pending =="
check_eq "draft flipped, two triggered, CR rate-capped" \
  "marked ready, 0 of 3 reviewers engaged; rate-capped: coderabbit; triggered: codeant, cursor" \
  "$(render "$(summary false marked-ready triggered skipped-rate-cap triggered)")"
check_eq "tier-deferred and a failed trigger are both named" \
  "already ready, 1 of 3 reviewers engaged; tier-deferred: cursor; trigger failed: coderabbit" \
  "$(render "$(summary false not-draft already-present trigger-failed skipped-tier-deferred)")"
check_eq "an unknown status is printed raw, not dropped" \
  "already ready, 2 of 3 reviewers engaged; some-new-status: cursor" \
  "$(render "$(summary false not-draft already-present already-present some-new-status)")"
check_eq "unknown draft action is printed raw" \
  "weird-draft, all 3 reviewers engaged" \
  "$(render "$(summary false weird-draft already-present already-present already-present)")"

echo
echo "== skipped and unreadable =="
UNREADABLE="unreadable — pr-preflight.sh summary did not parse; see the Step 0c output"
check_eq "empty summary → skipped" "skipped" "$(render "")"
check_eq "garbage summary → unreadable, never clean" "$UNREADABLE" "$(render "not json")"
check_eq "summary without reviewers → unreadable" "$UNREADABLE" \
  "$(render '{"clean":true,"draft_action":"not-draft"}')"
check_eq "empty reviewers object → unreadable (no vacuous 'all 0 engaged')" "$UNREADABLE" \
  "$(render '{"clean":true,"draft_action":"not-draft","reviewers":{}}')"
check_eq "a reviewer with no status → unreadable" "$UNREADABLE" \
  "$(render '{"clean":true,"draft_action":"not-draft","reviewers":{"codeant":{}}}')"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]]
