#!/usr/bin/env bash
# /fixpr Step 5c buckets the retired Graphite check by app slug; Step 5d awaits BugBot only when invited (issue #1953).
# catalog: tests — Runs `/fixpr` Step 5c's real check-bucket block and Step 5d's real BugBot-invited block on fixtures — a check another app names after Graphite stays CI while graphite-app's check is review and never awaited; BugBot silence is awaited only after a `@cursor review` posted since the push or under an unused owner grant, and an unreadable comment list fails closed
#
# WHAT IS UNDER TEST
#   The fenced bash under `<!-- test-anchor: fixpr-step-5c-check-buckets -->`
#   and `<!-- test-anchor: fixpr-step-5d-bugbot-invited -->` in
#   `.claude/skills/fixpr/SKILL.md`, extracted at run time by lib/skill-bash.sh.
#   5c runs on a VERIFY bundle file; 5d runs with `gh` and paid-review-grant.sh
#   stubbed (no network).
#
# WHY (issue #1953, deferred from PR #1951)
#   5c matched Graphite by a name containing "graphite", so another app's pending
#   "Graphite integration" check left both CI and review-pending counts and
#   /fixpr could report clean while it ran. 5d read Step 3b's wording: a BugBot
#   `deferring …` (CI pending) counted as awaited although BugBot is paid and no
#   one would invite it, so /fixpr reported REVIEW_PENDING forever.
#
# Requires: bash 3.2+, jq. Offline.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
FIXPR="$REPO_ROOT/.claude/skills/fixpr/SKILL.md"
# shellcheck source=lib/skill-bash.sh
source "$TEST_DIR/lib/skill-bash.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

PASS=0
FAIL=0
check_eq() {
  if [[ "$3" == "$2" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $1 (expected '$2', got '$3')"
  fi
}

BLOCK_5C="$(extract_skill_bash "$FIXPR" fixpr-step-5c-check-buckets)" || exit 1
BLOCK_5D="$(extract_skill_bash "$FIXPR" fixpr-step-5d-bugbot-invited)" || exit 1

############################################################################
echo "== Step 5c: Graphite by publishing-app slug =="
# run_5c <check_runs.all JSON> — prints "IN_PROGRESS FAILING REVIEW_IN_PROGRESS"
run_5c() {
  printf '%s\n' "{\"check_runs\":{\"all\":$1}}" >"$TMP/verify.json"
  VERIFY="$TMP/verify.json" bash -c "$BLOCK_5C"'
echo "COUNTS $IN_PROGRESS $FAILING $REVIEW_IN_PROGRESS"' 2>/dev/null | sed -n 's/^COUNTS //p'
}
check_eq "premise: the 5c block runs and prints its counts on an empty run list" "0 0 0" "$(run_5c '[]')"
check_eq "other app's pending 'Graphite integration' check is CI pending" "1 0 0" \
  "$(run_5c '[{"name":"Graphite integration","status":"in_progress","conclusion":null,"app":{"slug":"github-actions"}}]')"
check_eq "graphite-app's pending check is review, never awaited" "0 0 0" \
  "$(run_5c '[{"name":"r","status":"queued","conclusion":null,"app":{"slug":"graphite-app"}}]')"
check_eq "graphite-app's failed check is not CI failing" "0 0 0" \
  "$(run_5c '[{"name":"Graphite / mergeability_check","status":"completed","conclusion":"failure","app":{"slug":"graphite-app"}}]')"
check_eq "a live reviewer's pending check is still review-pending" "0 0 1" \
  "$(run_5c '[{"name":"Cursor Bugbot","status":"in_progress","conclusion":null,"app":{"slug":"cursor"}}]')"
check_eq "a GitHub Actions job named after a reviewer is CI pending" "1 0 0" \
  "$(run_5c '[{"name":"post-cursor-review","status":"in_progress","conclusion":null,"app":{"slug":"github-actions"}}]')"
check_eq "no app slug: the name still identifies a reviewer check" "0 0 1" \
  "$(run_5c '[{"name":"CodeRabbit","status":"in_progress","conclusion":null}]')"

############################################################################
echo
echo "== Step 5d: BugBot awaited only when invited =="
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
[[ "${GH_STUB_RC:-0}" -eq 0 ]] || exit "$GH_STUB_RC"
cat "$GH_STUB_FILE"
STUB
cat >"$TMP/grant" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GRANT_LOG"
exit "${GRANT_RC:-1}"
STUB
chmod +x "$TMP/bin/gh" "$TMP/grant"

PUSHED='2026-11-06T15:00:00Z'
# run_5d <comments JSON> [gh rc] [grant rc] [grant script path] — prints the verdict
run_5d() {
  printf '%s' "$1" >"$TMP/comments.json"
  : >"$TMP/grant.log"
  PATH="$TMP/bin:$PATH" GH_STUB_FILE="$TMP/comments.json" GH_STUB_RC="${2:-0}" GRANT_RC="${3:-1}" \
    GRANT_LOG="$TMP/grant.log" PAID_GRANT_SH="${4-$TMP/grant}" \
    OWNER=o REPO=r PR_NUMBER=7 PUSHED_AT="$PUSHED" PUSHED_SHA=abc123 HEAD_SHA=abc123 \
    bash -c "$BLOCK_5D" 2>/dev/null | sed -n 's/^BUGBOT_AWAITED=//p'
}
c() { jq -nc --arg at "$1" --arg b "$2" '{created_at: $at, body: $b}'; }

check_eq "trigger posted after the push: awaited" 1 \
  "$(run_5d "[$(c 2026-11-06T15:02:00Z '@cursor review')]")"
check_eq "no trigger, no grant (Step 3b deferred/skipped): not awaited" 0 \
  "$(run_5d "[$(c 2026-11-06T15:02:00Z 'LGTM')]")"
check_eq "  ...and the grant was asked about the pushed HEAD" "--check 7 --vendor cursor --head abc123 --repo o/r" \
  "$(cat "$TMP/grant.log")"
check_eq "trigger posted before the push only: not awaited" 0 \
  "$(run_5d "[$(c 2026-11-06T14:00:00Z '@cursor review')]")"
check_eq "trigger mentioned mid-sentence is not a trigger" 0 \
  "$(run_5d "[$(c 2026-11-06T15:02:00Z 'do not post @cursor review here')]")"
check_eq "no trigger but an unused owner grant for this HEAD: awaited" 1 \
  "$(run_5d "[$(c 2026-11-06T15:02:00Z 'LGTM')]" 0 0)"
check_eq "no trigger and grant state unreadable (exit 3): fails closed, awaited" 1 \
  "$(run_5d "[$(c 2026-11-06T15:02:00Z 'LGTM')]" 0 3)"
check_eq "paginated pages are all read" 1 \
  "$(run_5d "[$(c 2026-11-06T14:00:00Z x)][$(c 2026-11-06T15:05:00Z '@cursor review')]")"
check_eq "gh failure fails closed: awaited" 1 "$(run_5d '[]' 1)"
check_eq "unparseable comment list fails closed: awaited" 1 "$(run_5d 'not json' 0)"
check_eq "grant helper missing: not awaited, reported degraded" 0 \
  "$(run_5d "[$(c 2026-11-06T15:02:00Z 'LGTM')]" 0 0 '')"
degraded=$(printf '[]' >"$TMP/comments.json"; PATH="$TMP/bin:$PATH" GH_STUB_FILE="$TMP/comments.json" PAID_GRANT_SH='' \
  OWNER=o REPO=r PR_NUMBER=7 PUSHED_AT="$PUSHED" bash -c "$BLOCK_5D" 2>/dev/null | grep -c '^DEGRADED: paid-review-grant.sh not found')
check_eq "  ...with the DEGRADED line" 1 "$degraded"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
