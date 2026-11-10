#!/usr/bin/env bash
# Static guard: /fixpr Step 3b asks about the SHA it just PUSHED (issue #1517).
# catalog: tests — Static guard that `/fixpr` Step 3b hands the post-push `PUSHED_SHA` to `fixpr-reviewer-triggers.sh`, which passes it to `bugbot-refused-head.sh` and the review-tier helper, never the pre-push `HEAD_SHA`
#
# WHAT IS UNDER TEST
#   Step 3b runs AFTER Step 3's push. Its BugBot refusal check skips an
#   `@cursor review` that BugBot has already refused for a Cursor usage/spend
#   limit on that HEAD — BugBot auto-runs on push, so the refusal can land
#   before Step 3b even executes (observed on PR #1203: refusal, CI nudge,
#   second refusal, all inside seven seconds).
#
#   It was passing `$HEAD_SHA`, which Step 1 collects from the pre-push audit
#   bundle. `$PUSHED_SHA` is defined immediately after the push and is what the
#   rest of the step already uses. Asking about the OLD SHA misses a refusal on
#   the fresh HEAD and posts a duplicate nudge — spending one on a usage limit no
#   nudge can clear, which is the exact waste the check exists to prevent.
#
#   Since issue #1749 the step's bash lives in fixpr-reviewer-triggers.sh, so
#   the claim is two links long: SKILL.md hands `$PUSHED_SHA` to the script,
#   and the script hands its pushed SHA to the refusal guard and to
#   review-triggers-allowed.sh (`--head`). Both links are asserted.
#
# WHY A STATIC TEST
#   SKILL.md is a procedure Claude executes, not a script a harness can run, so
#   the variable reference is the only thing there is to assert. The assertions
#   below are written to fail when the check is MISSING as well as when it is
#   wrong: a guard that passes because it found nothing to look at is worse than
#   no guard (issue #1517 was itself a review finding nobody triaged). The
#   script's behaviour is run for real in fixpr-step3b-daily-cap.test.sh.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL="$REPO_ROOT/.claude/skills/fixpr/SKILL.md"
TRIG="$REPO_ROOT/.claude/scripts/fixpr-reviewer-triggers.sh"

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

echo "== premise: the files and the Step 3b invocation exist =="
# Every assertion below reads these files. If one moved or the block was
# rewritten, the greps would find nothing and the "no \$HEAD_SHA here" checks
# would pass vacuously — so the premise is asserted first and explicitly.
for f in "$SKILL" "$TRIG"; do
  if [[ -r "$f" ]]; then
    check_eq "$(basename "$f") is readable" "yes" "yes"
  else
    check_eq "$(basename "$f") is readable" "yes" "no"
    echo "== summary: $PASS passed, $FAIL failed =="
    exit 1
  fi
done

INVOKE_COUNT="$(grep -cF '"$FIXPR_TRIGGERS_SH" "$PR_NUMBER"' "$SKILL" || true)"
check_eq "exactly one fixpr-reviewer-triggers.sh invocation in the skill" "1" "$INVOKE_COUNT"

echo
echo "== link 1: the skill hands the script the PUSHED SHA =="
INVOKE_LINE="$(grep -F '"$FIXPR_TRIGGERS_SH" "$PR_NUMBER"' "$SKILL" | head -1)"
check_eq "Step 3b passes --pushed-sha \$PUSHED_SHA" "yes" \
  "$( [[ "$INVOKE_LINE" == *'--pushed-sha "$PUSHED_SHA"'* ]] && echo yes || echo no )"
check_eq "Step 3b does not pass the pre-push \$HEAD_SHA" "no" \
  "$( [[ "$INVOKE_LINE" == *'$HEAD_SHA'* ]] && echo yes || echo no )"

echo
echo "== link 2: the script asks about the SHA it was handed =="
check_eq "exactly one refusal-guard invocation in the script" "1" \
  "$(grep -cF '"$BUGBOT_REFUSED_SH" "$PR_NUMBER"' "$TRIG" || true)"
check_eq "the refusal guard gets the pushed SHA" "1" \
  "$(grep -cF '"$BUGBOT_REFUSED_SH" "$PR_NUMBER" "$PUSHED_SHA"' "$TRIG" || true)"
HELPER_CALLS="$(grep -F '"$TRIGGERS_SH" "$PR_NUMBER" --repo "$REPO_FULL" --head' "$TRIG" || true)"
check_eq "the review-tier helper is asked with --head (decision + claim)" "2" "$(grep -c . <<<"$HELPER_CALLS" | tr -d ' ')"
check_eq "  always about the pushed SHA" "0" "$(grep -cvF -- '--head "$PUSHED_SHA"' <<<"$HELPER_CALLS" | tr -d ' ')"
check_eq "the script never names \$HEAD_SHA" "0" "$(grep -cF '$HEAD_SHA' "$TRIG" || true)"
check_eq "PUSHED_SHA comes from --pushed-sha" "1" \
  "$(grep -cF -- '--pushed-sha) [[ -n "${2-}" ]] || die_usage "--pushed-sha requires a value"; PUSHED_SHA="$2"' "$TRIG" || true)"

echo
echo "== ordering: the SHA it asks about is defined by the push it follows =="
# The substantive claim, not just the spelling. \$PUSHED_SHA is only the right
# answer because it is captured after Step 3's push and Step 3b runs later; a
# reference that appeared BEFORE that capture would be an empty string.
PUSHED_DEF_LN="$(grep -nF 'PUSHED_SHA=$(git rev-parse HEAD)' "$SKILL" | head -1 | cut -d: -f1)"
INVOKE_LN="$(grep -nF '"$FIXPR_TRIGGERS_SH" "$PR_NUMBER"' "$SKILL" | head -1 | cut -d: -f1)"
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
