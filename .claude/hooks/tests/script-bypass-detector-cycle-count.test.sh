#!/usr/bin/env bash
# Tests for the cycle-count.sh sentinel in script-bypass-detector.sh (issue #490).
#
# Verifies that:
#   1. False-positive lines from the old broad regex NO LONGER match
#   2. Genuine cycle-count bypasses (manual round counting) STILL match
#
# Run: bash .claude/hooks/tests/script-bypass-detector-cycle-count.test.sh

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/script-bypass-detector.sh"

PASS=0
FAIL=0

# ── test the sentinel regex directly in Python ──
run_sentinel_test() {
  local description="$1"
  local command="$2"
  local expect_match="$3"   # "yes" or "no"

  local result
  result=$(python3 - "$command" "$expect_match" <<'PY'
import sys, re

cmd = sys.argv[1]
expect = sys.argv[2]

def _sentinel(cmd):
    segments = re.split(r"&&|\|\||\n", cmd)
    p1 = re.compile(
        r"gh\s+api.*pulls/[0-9]+/reviews.*(?:\|\s*length\b|python3.*len\()",
        re.S,
    )
    for seg in segments:
        if p1.search(seg) and not re.search(r'select\(', seg):
            return True
    temporal = re.compile(
        r"(?:"
        r"gh\s+api.*pulls/[0-9]+/reviews.*submitted_at.*gh\s+api.*pulls/[0-9]+/commits"
        r"|"
        r"gh\s+api.*pulls/[0-9]+/commits.*gh\s+api.*pulls/[0-9]+/reviews.*submitted_at"
        r")",
        re.S,
    )
    return bool(temporal.search(cmd))

matched = _sentinel(cmd)
if (matched and expect == "yes") or (not matched and expect == "no"):
    print("PASS")
else:
    print(f"FAIL: expected={'match' if expect=='yes' else 'no-match'} got={'match' if matched else 'no-match'}")
PY
)

  if [[ "$result" == "PASS" ]]; then
    echo "  PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description  ($result)"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "=== cycle-count.sh sentinel: false-positive regression tests (should NOT match) ==="

# These were all incorrectly flagged by the old sentinel.

run_sentinel_test \
  "greptile bot review count with select(.user.login)" \
  'gh api --paginate "repos/auerbachb/claude-code-config/pulls/391/reviews?per_page=100" --jq '"'"'[.[] | select(.user.login == "greptile-apps[bot]")] | length'"'"'' \
  "no"

run_sentinel_test \
  "coderabbitai bot review count with select(.user.login)" \
  'gh api "repos/auerbachb/skingod/pulls/413/reviews?per_page=100" --jq '"'"'[.[] | select(.user.login == "coderabbitai[bot]")] | length'"'"'' \
  "no"

run_sentinel_test \
  "cursor bot review count with select(.user.login)" \
  'gh api "repos/auerbachb/claude-code-config/pulls/419/reviews?per_page=100" --jq '"'"'[.[] | select(.user.login == "cursor[bot]")] | {count: length, reviews: [.[] | {state}]}'"'"'' \
  "no"

run_sentinel_test \
  "CI check-runs polling (not reviews)" \
  'gh api "repos/auerbachb/skingod/commits/abc123/check-runs?per_page=100" --jq '"'"'[.check_runs[] | select(.status != "completed")] | length'"'"'' \
  "no"

run_sentinel_test \
  "multi-bot review presence check with select(.user.login)" \
  'until gh api "repos/auerbachb/skingod/pulls/1332/reviews?per_page=100" --jq '"'"'[.[] | select(.user.login | test("coderabbitai\\[bot\\]|codeant-ai\\[bot\\]"))] | length > 0'"'"' 2>/dev/null | grep -q true; do sleep 60; done' \
  "no"

run_sentinel_test \
  "APPROVED state check on specific bot with select(.user.login)" \
  'gh api "repos/auerbachb/skingod/pulls/423/reviews?per_page=100" --jq '"'"'[.[] | select(.user.login == "coderabbitai[bot]" and .state == "APPROVED")] | length'"'"'' \
  "no"

run_sentinel_test \
  "commits endpoint only (no reviews)" \
  'gh api "repos/auerbachb/skingod/pulls/428/commits?per_page=100" --jq '"'"'[.[]] | length'"'"'' \
  "no"

run_sentinel_test \
  "PR reviews listing without length (tabular output)" \
  'gh api "repos/auerbachb/claude-code-config/pulls/433/reviews?per_page=100" --jq '"'"'.[] | "\(.user.login)\t\(.state)\t\(.submitted_at)"'"'"'' \
  "no"

echo ""
echo "=== cycle-count.sh sentinel: true-positive tests (SHOULD match) ==="

run_sentinel_test \
  "raw review count as cycle proxy (python len, no bot filter)" \
  'gh api "repos/auerbachb/cursor-code-config/pulls/36/reviews?per_page=100" | python3 -c "import json,sys; data=json.load(sys.stdin); print(f'"'"'Review rounds: {len(data)}'"'"')"' \
  "yes"

run_sentinel_test \
  "raw review jq length with no user.login filter" \
  'gh api "repos/owner/repo/pulls/123/reviews?per_page=100" --jq '"'"'. | length'"'"'' \
  "yes"

run_sentinel_test \
  "manual cycle count: reviews + submitted_at + commits in same command" \
  'REVIEWS=$(gh api "repos/owner/repo/pulls/123/reviews?per_page=100"); COMMITS=$(gh api "repos/owner/repo/pulls/123/commits?per_page=100"); echo "$REVIEWS" | jq --argjson c "$COMMITS" '"'"'[.[] | .submitted_at as $rt | ($c[] | .commit.committer.date) > $rt] | length'"'"'' \
  "yes"

run_sentinel_test \
  "reviews submitted_at compared to commits (temporal cycle reconstruction)" \
  'gh api repos/owner/repo/pulls/99/reviews --jq '"'"'.[].submitted_at'"'"' && gh api repos/owner/repo/pulls/99/commits --jq '"'"'.[].commit.committer.date'"'"'' \
  "yes"

run_sentinel_test \
  "chained: raw count segment then bot-filtered segment (BugBot finding)" \
  'gh api repos/owner/repo/pulls/123/reviews | jq '"'"'. | length'"'"' && gh api repos/owner/repo/pulls/123/reviews?per_page=100 --jq '"'"'[.[] | select(.user.login == "coderabbitai[bot]")] | length'"'"'' \
  "yes"

run_sentinel_test \
  "until-prefixed cycle-count command still matches (fix 1: search not match)" \
  'until gh api "repos/owner/repo/pulls/123/reviews?per_page=100" | jq '"'"'. | length'"'"' > 0; do sleep 60; done' \
  "yes"

run_sentinel_test \
  "whitespace-variant select( .user.login ) is still excluded (fix 2: tolerant regex)" \
  'gh api "repos/owner/repo/pulls/123/reviews?per_page=100" --jq '"'"'[.[] | select( .user.login == "coderabbitai[bot]")] | length'"'"'' \
  "no"

run_sentinel_test \
  "multiline: | length on line 1, select(.user.login on line 2 — should still match (fix 3: newline split)" \
  'gh api repos/owner/repo/pulls/123/reviews?per_page=100 | jq '"'"'. | length'"'"'
select(.user.login == "coderabbitai[bot]")' \
  "yes"

run_sentinel_test \
  "state-filtered review count is NOT flagged — any select() is a sufficient exclusion (fix 4)" \
  'gh api "repos/owner/repo/pulls/123/reviews?per_page=100" --jq '"'"'[.[] | select(.state == "APPROVED")] | length'"'"'' \
  "no"

echo ""
echo "=== Summary ==="
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
