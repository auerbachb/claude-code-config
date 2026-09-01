#!/usr/bin/env bash
# Static guard: /fixpr Step 3b asks about the SHA it just PUSHED (issue #1517).
#
# WHAT IS UNDER TEST
#   Step 3b runs AFTER Step 3's push. It consults bugbot-refused-head.sh to skip
#   an `@cursor review` that BugBot has already refused for a Cursor usage/spend
#   limit on that HEAD — BugBot auto-runs on push, so the refusal can land before
#   Step 3b even executes (observed on PR #1203: refusal, CI nudge, second
#   refusal, all inside seven seconds).
#
#   It was passing `$HEAD_SHA`, which Step 1 collects from the pre-push audit
#   bundle. `$PUSHED_SHA` is defined immediately after the push and is what the
#   rest of the step already uses. Asking about the OLD SHA misses a refusal on
#   the fresh HEAD and posts a duplicate nudge — spending one on a usage limit no
#   nudge can clear, which is the exact waste the check exists to prevent.
#
# WHY A STATIC TEST
#   SKILL.md is a procedure Claude executes, not a script a harness can run, so
#   the variable reference is the only thing there is to assert. The assertions
#   below are written to fail when the check is MISSING as well as when it is
#   wrong: a guard that passes because it found nothing to look at is worse than
#   no guard (issue #1517 was itself a review finding nobody triaged).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL="$REPO_ROOT/.claude/skills/fixpr/SKILL.md"

PASS=0
FAIL=0
check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected '$expected', got '$actual')"
  fi
}

echo "== premise: the file and the Step 3b invocation exist =="
# Every assertion below reads this one line. If the file moved or the block was
# rewritten, the greps would find nothing and the "no \$HEAD_SHA here" checks
# would pass vacuously — so the premise is asserted first and explicitly.
if [[ -r "$SKILL" ]]; then
  check_eq "fixpr/SKILL.md is readable" "yes" "yes"
else
  check_eq "fixpr/SKILL.md is readable" "yes" "no"
  echo "== summary: $PASS passed, $FAIL failed =="
  exit 1
fi

INVOKE_COUNT="$(grep -cF '"$BUGBOT_REFUSED_SH" "$PR_NUMBER"' "$SKILL" || true)"
check_eq "exactly one bugbot-refused-head.sh invocation in the skill" "1" "$INVOKE_COUNT"

echo
echo "== the invocation passes the PUSHED SHA =="
GOOD="$(grep -cF '"$BUGBOT_REFUSED_SH" "$PR_NUMBER" "$PUSHED_SHA"' "$SKILL" || true)"
check_eq "Step 3b passes \$PUSHED_SHA" "1" "$GOOD"
BAD="$(grep -cF '"$BUGBOT_REFUSED_SH" "$PR_NUMBER" "$HEAD_SHA"' "$SKILL" || true)"
check_eq "Step 3b does not pass the pre-push \$HEAD_SHA" "0" "$BAD"

echo
echo "== ordering: the SHA it asks about is defined by the push it follows =="
# The substantive claim, not just the spelling. \$PUSHED_SHA is only the right
# answer because it is captured after Step 3's push and Step 3b runs later; a
# reference that appeared BEFORE that capture would be an empty string under
# `set -u`-less shell semantics and would silently suppress nothing.
PUSHED_DEF_LN="$(grep -nF 'PUSHED_SHA=$(git rev-parse HEAD)' "$SKILL" | head -1 | cut -d: -f1)"
INVOKE_LN="$(grep -nF '"$BUGBOT_REFUSED_SH" "$PR_NUMBER"' "$SKILL" | head -1 | cut -d: -f1)"
if [[ -n "$PUSHED_DEF_LN" && -n "$INVOKE_LN" ]]; then
  check_eq "PUSHED_SHA is captured before Step 3b consults it" "yes" \
    "$( [[ "$PUSHED_DEF_LN" -lt "$INVOKE_LN" ]] && echo yes || echo no )"
else
  check_eq "both the PUSHED_SHA capture and the invocation were located" "yes" "no"
fi

echo
echo "== NEGATIVE CONTROL: HEAD_SHA is still a live variable elsewhere =="
# Guards against the lazy fix. Renaming or deleting HEAD_SHA across the file
# would satisfy every assertion above while breaking Step 1's audit bundle and
# the DID_PUSH=0 wait-loop path, which legitimately watch the pre-push SHA. This
# check keeps the assertions above meaning "the right variable at this call site"
# rather than "HEAD_SHA is gone".
HEAD_DEF="$(grep -cF 'HEAD_SHA=$(jq -r ' "$SKILL" || true)"
check_eq "HEAD_SHA is still defined from the audit bundle" "1" "$HEAD_DEF"
HEAD_USES="$(grep -cF 'WATCH_SHA=$HEAD_SHA' "$SKILL" || true)"
if [[ "$HEAD_USES" -ge 1 ]]; then
  check_eq "HEAD_SHA is still used where the pre-push SHA is correct" "yes" "yes"
else
  check_eq "HEAD_SHA is still used where the pre-push SHA is correct" "yes" "no"
fi

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: fixpr Step 3b PUSHED_SHA tests passed"
