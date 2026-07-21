#!/usr/bin/env bash
# Unit test for the `classify` jq function inside `pr-state.sh --since`
# (issues #535, #557, #575).
#
# Verifies that comment bodies observed misclassified in the wild are now correctly
# classified as acknowledgments, and that existing patterns are not regressed:
#   - #535: three bodies on auerbachb/inventory PR #2 (Jul 2 2026) — BugBot clean-pass,
#     BugBot zero-issue summary, CR error stub.
#   - #557: two bodies on auerbachb/claude-code-config PR #554 (Jul 16 2026) — CR
#     Fair-Usage rate-limit notice, BugBot usage-limit notice.
#   - #575: CR's auto-generated walkthrough/summary comment (PR #568) — plus two
#     masking guards (Bug6a/Bug6b) pinning the override's load-bearing LATE position.
#     Those guards are not vacuous: they pass pre-fix only because everything defaults
#     to `finding`. Their real job is to fail against a WRONG fix. Verified by hoisting
#     the override into the tier-1 group, which flips both to acknowledgment — the exact
#     false-clean the placement prevents. Re-run that control if you touch the ordering.
#
# Strategy: extract the classify function definition via sed from pr-state.sh and
# exercise it in isolation with jq -n. This tests the actual production code rather
# than a copied duplicate, so the two can never drift apart.
#
# Requires: jq, bash 3.2+ (macOS-compatible — no mapfile/readarray, no head -n -N).
# Offline: no gh, no git, no network calls needed.
set -euo pipefail

# Resolve pr-state.sh relative to this test file — no git required, so the test
# runs from a source archive without .git metadata (matches the "no git" note above).
# This test lives in .claude/scripts/tests/; the script under test is one dir up.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../pr-state.sh"

PASS=0
FAIL=0

fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# Extract the classify function from the production script.
# Pattern: from "def classify:" through the first "end;" that sits at 6-space indent.
# On macOS (BSD) sed -n with ranges works the same as GNU sed here.
CLASSIFY_DEF=$(sed -n '/def classify:/,/^      end;/p' "$SCRIPT")

if [[ -z "$CLASSIFY_DEF" ]]; then
  echo "ERROR: could not extract classify function from $SCRIPT" >&2
  exit 1
fi

# Run classify on a single body string and return "class|reason".
classify_body() {
  local body="$1"
  jq -rn \
    --arg body "$body" \
    "${CLASSIFY_DEF}
    \$body | classify | .class + \"|\" + .reason"
}

# ---------------------------------------------------------------------------
# Bug 1: BugBot clean-pass review body
# Observed body: "✅ Bugbot reviewed your changes and found no new issues!"
# Was: default → finding; Should be: BugBot clean pass → acknowledgment
# ---------------------------------------------------------------------------
BODY="✅ Bugbot reviewed your changes and found no new issues!"
result=$(classify_body "$BODY")
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "BugBot clean pass" ]]; then
  pass "Bug1: BugBot clean-pass ('found no new issues') → acknowledgment"
else
  fail "Bug1: BugBot clean-pass — expected acknowledgment/BugBot clean pass, got $class/$reason"
fi

# ---------------------------------------------------------------------------
# Bug 2a: BugBot BUGBOT_REVIEW summary with 0 issues
# Observed body: "<!-- BUGBOT_REVIEW -->\nCursor Bugbot ... found 0 potential issues."
# Was: 'issues? found' finding phrase → finding; Should be: BugBot zero-issue summary → acknowledgment
# ---------------------------------------------------------------------------
BODY="<!-- BUGBOT_REVIEW -->
Cursor Bugbot has reviewed your changes and found 0 potential issues."
result=$(classify_body "$BODY")
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "BugBot zero-issue summary" ]]; then
  pass "Bug2a: BugBot BUGBOT_REVIEW 0 issues → acknowledgment"
else
  fail "Bug2a: BugBot BUGBOT_REVIEW 0 issues — expected acknowledgment/BugBot zero-issue summary, got $class/$reason"
fi

# ---------------------------------------------------------------------------
# Bug 2b: BugBot BUGBOT_REVIEW summary with N>0 issues (must remain finding)
# ---------------------------------------------------------------------------
BODY="<!-- BUGBOT_REVIEW -->
Cursor Bugbot has reviewed your changes and found 3 potential issues."
result=$(classify_body "$BODY")
class="${result%%|*}"
if [[ "$class" == "finding" ]]; then
  pass "Bug2b: BugBot BUGBOT_REVIEW 3 issues → finding (unchanged behavior)"
else
  fail "Bug2b: BugBot BUGBOT_REVIEW 3 issues — expected finding, got $class"
fi

# ---------------------------------------------------------------------------
# Bug 2c: BugBot BUGBOT_REVIEW double-digit count (must remain finding)
# ---------------------------------------------------------------------------
BODY="<!-- BUGBOT_REVIEW -->
Cursor Bugbot has reviewed your changes and found 12 potential issues."
result=$(classify_body "$BODY")
class="${result%%|*}"
if [[ "$class" == "finding" ]]; then
  pass "Bug2c: BugBot BUGBOT_REVIEW 12 issues → finding (unchanged behavior)"
else
  fail "Bug2c: BugBot BUGBOT_REVIEW 12 issues — expected finding, got $class"
fi

# ---------------------------------------------------------------------------
# Bug 3: CodeRabbit error stub
# Observed body: "Oops, something went wrong! Please try again later."
# Was: default → finding; Should be: CR error stub / transient noise → acknowledgment
# ---------------------------------------------------------------------------
BODY="Oops, something went wrong! Please try again later."
result=$(classify_body "$BODY")
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "CR error stub / transient noise" ]]; then
  pass "Bug3: CR error stub ('Oops, something went wrong') → acknowledgment"
else
  fail "Bug3: CR error stub — expected acknowledgment/CR error stub / transient noise, got $class/$reason"
fi

# ---------------------------------------------------------------------------
# Regression tests — existing patterns must not be broken
# ---------------------------------------------------------------------------

# Empty body
result=$(classify_body "")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Regression: empty body → acknowledgment" \
  || fail "Regression: empty body — got $class"

# Addressed marker
result=$(classify_body "<!-- <review_comment_addressed> -->")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Regression: addressed marker → acknowledgment" \
  || fail "Regression: addressed marker — got $class"

# Withdrawn marker (issue #611) — CR retracts its own finding; mirrors the addressed marker above.
result=$(classify_body "<!-- <review_comment_withdrawn> -->")
class="${result%%|*}"; reason="${result##*|}"
[[ "$class" == "acknowledgment" && "$reason" == "withdrawn marker" ]] && pass "Regression: withdrawn marker → acknowledgment" \
  || fail "Regression: withdrawn marker — expected acknowledgment/withdrawn marker, got $class/$reason"

# CR zero actionable (old format)
result=$(classify_body "actionable comments posted: 0 — all good!")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Regression: 'actionable comments posted: 0' → acknowledgment" \
  || fail "Regression: 'actionable comments posted: 0' — got $class"

# CR no actionable comments generated (PR #424 fix)
result=$(classify_body "No actionable comments were generated in the recent review. 🎉")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Regression: 'no actionable comments were generated' → acknowledgment" \
  || fail "Regression: 'no actionable comments were generated' — got $class"

# Rate limit notice
result=$(classify_body "Rate limit exceeded — please try again.")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Regression: rate limit notice → acknowledgment" \
  || fail "Regression: rate limit notice — got $class"

# Review-started ack
result=$(classify_body "Actions performed: Full review triggered.")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Regression: 'full review triggered' → acknowledgment" \
  || fail "Regression: 'full review triggered' — got $class"

# Severity keyword — finding
result=$(classify_body "This is a critical security issue in the auth flow.")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Regression: severity keyword 'critical' → finding" \
  || fail "Regression: severity keyword 'critical' — got $class"

# Severity badge — finding
result=$(classify_body "🔴 High severity: SQL injection vulnerability detected.")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Regression: severity badge 🔴 → finding" \
  || fail "Regression: severity badge 🔴 — got $class"

# Actionable phrase (non-zero) — finding
result=$(classify_body "actionable comments posted: 3")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Regression: 'actionable comments posted: 3' → finding" \
  || fail "Regression: 'actionable comments posted: 3' — got $class"

# Finding phrase: issues found
result=$(classify_body "2 issues found in the diff.")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Regression: 'issues found' phrase → finding" \
  || fail "Regression: 'issues found' phrase — got $class"

# CR fix prompt
result=$(classify_body "Prompt for AI Agent: refactor this function.")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Regression: 'Prompt for AI Agent' → finding" \
  || fail "Regression: 'Prompt for AI Agent' — got $class"

# Suggestion block
result=$(classify_body $'```suggestion\nconst x = 1;\n```')
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Regression: suggestion block → finding" \
  || fail "Regression: suggestion block — got $class"

# LGTM variant
result=$(classify_body "LGTM! Great work on this PR.")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Regression: LGTM → acknowledgment" \
  || fail "Regression: LGTM — got $class"

# Default — unknown body → finding
result=$(classify_body "Some random comment that matches no pattern at all.")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Regression: default unknown body → finding" \
  || fail "Regression: default unknown body — got $class"

# ---------------------------------------------------------------------------
# Bug 4: CodeRabbit Fair-Usage rate-limit notice (issue #557)
# Verbatim body of auerbachb/claude-code-config PR #554 comment 4993611774
# (Jul 16 2026). The pre-#557 patterns ("rate limit exceeded" / "rate-limited by
# coderabbit") do not match this wording, and CR wraps it in a "Full review
# finished" ack — so "full review triggered" misses it too.
# Was: default → finding; Should be: rate limit notice → acknowledgment
# ---------------------------------------------------------------------------
BODY='<!-- This is an auto-generated reply by CodeRabbit -->
<details>
<summary>✅ Action performed</summary>

Full review finished.

---

You'"'"'re currently rate limited under our [Fair Usage Limits Policy](https://docs.coderabbit.ai/management/plans#fair-usage-limits-policy). Your recent PR review activity is in the 95th percentile or higher among CodeRabbit users, so adaptive limits apply. Your next review will be available in 22 minutes.

</details>'
result=$(classify_body "$BODY")
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "rate limit notice" ]]; then
  pass "Bug4: CR Fair-Usage rate-limit notice → acknowledgment"
else
  fail "Bug4: CR Fair-Usage rate-limit notice — expected acknowledgment/rate limit notice, got $class/$reason"
fi

# ---------------------------------------------------------------------------
# Bug 5: BugBot usage-limit notice (issue #557)
# Verbatim body of auerbachb/claude-code-config PR #554 comment 4993610715
# (Jul 16 2026). BugBot did not run at all, so this is not a finding.
# Was: default → finding; Should be: BugBot usage limit notice → acknowledgment
# ---------------------------------------------------------------------------
BODY='<h3>Bugbot couldn'"'"'t run - usage limit reached</h3>

Bugbot is counted against Cursor usage for this user or team, and this run hit a usage or spend limit.

A user or team admin can review and increase usage limits in the [Cursor dashboard](https://www.cursor.com/dashboard/spending).'
result=$(classify_body "$BODY")
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "BugBot usage limit notice" ]]; then
  pass "Bug5: BugBot usage-limit notice → acknowledgment"
else
  fail "Bug5: BugBot usage-limit notice — expected acknowledgment/BugBot usage limit notice, got $class/$reason"
fi

# ---------------------------------------------------------------------------
# Bug 4b: CodeRabbit "Review limit reached" variant (issue #557)
# Excerpt of auerbachb/claude-code-config PR #565 (Jul 16 2026) — a THIRD distinct
# CR rate-limit wording, observed while this very fix was in review.
#
# It pins the phrasing spread: this variant shares no wording with the Bug4 body except
# the policy link. It is caught by "rate limited by coderabbit.ai" (the auto-generated
# marker), "Review limit reached", and "Next review available in:" — three independent
# CR-specific signals, none of them a generic phrase. See Bug4c for why that matters.
# ---------------------------------------------------------------------------
BODY='<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->

> [!WARNING]
> ## Review limit reached
>
> You'"'"'ve reached a temporary PR review limit under our [Fair Usage Limits Policy](https://docs.coderabbit.ai/management/plans#fair-usage-limits-policy).<br>
> Your recent review volume is higher than typical usage, so adaptive limits are currently applied.
>
> **Next review available in:** **11 minutes**'
result=$(classify_body "$BODY")
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "rate limit notice" ]]; then
  pass "Bug4b: CR 'Review limit reached' variant → acknowledgment"
else
  fail "Bug4b: CR 'Review limit reached' variant — expected acknowledgment/rate limit notice, got $class/$reason"
fi

# ---------------------------------------------------------------------------
# Bug4c: a real finding that merely QUOTES the Fair Usage policy stays a finding
# (issue #557, raised by codeant-ai on PR #565).
#
# An earlier cut of this fix matched a bare `fair usage limits policy`. That phrase is
# generic: because overrides are checked before the finding tier, any genuine bot finding
# discussing the policy would classify as an acknowledgment and vanish from finding_count,
# silently skipping remediation. Not hypothetical — this repo's own test file and PR bodies
# contain that literal string. The phrase was dropped in favour of CR-specific wording.
# ---------------------------------------------------------------------------
result=$(classify_body "**Critical:** the docs cite our [Fair Usage Limits Policy](https://docs.coderabbit.ai/management/plans#fair-usage-limits-policy) but the retry loop ignores it.")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Bug4c: finding quoting Fair Usage policy → finding (generic phrase not an override)" \
  || fail "Bug4c: finding quoting Fair Usage policy — expected finding, got $class"

# Same guard, no severity keyword — must reach the default→finding tier on its own.
result=$(classify_body "The helper links to the Fair Usage Limits Policy page, but the URL is stale and 404s.")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Bug4c: bare prose quoting Fair Usage policy → finding (via default)" \
  || fail "Bug4c: bare prose quoting Fair Usage policy — expected finding, got $class"

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

# Case-insensitivity: BugBot clean pass with different casing
result=$(classify_body "✅ BUGBOT REVIEWED YOUR CHANGES AND FOUND NO NEW ISSUES!")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Edge: BugBot clean-pass case-insensitive → acknowledgment" \
  || fail "Edge: BugBot clean-pass case-insensitive — got $class"

# Case-insensitivity: CR error stub lowercase
result=$(classify_body "oops, something went wrong! please try again later.")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Edge: CR error stub lowercase → acknowledgment" \
  || fail "Edge: CR error stub lowercase — got $class"

# BUGBOT_REVIEW with 1 potential issue — must be finding ([1-9][0-9]* matches 1)
BODY="<!-- BUGBOT_REVIEW -->
Cursor Bugbot has reviewed your changes and found 1 potential issues."
result=$(classify_body "$BODY")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Edge: BugBot BUGBOT_REVIEW 1 issue → finding" \
  || fail "Edge: BugBot BUGBOT_REVIEW 1 issue — got $class"

# Legacy CR rate-limit phrasings must keep matching after the #557 pattern widening
result=$(classify_body "Rate limit exceeded")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Edge: legacy 'rate limit exceeded' → acknowledgment" \
  || fail "Edge: legacy 'rate limit exceeded' — got $class"

result=$(classify_body "You are rate-limited by CodeRabbit")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Edge: legacy 'rate-limited by coderabbit' → acknowledgment" \
  || fail "Edge: legacy 'rate-limited by coderabbit' — got $class"

# Each #557 CR rate-limit phrase must match on its own, not only in the full body
result=$(classify_body "Your next review will be available in 22 minutes.")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Edge: CR 'next review will be available in' → acknowledgment" \
  || fail "Edge: CR 'next review will be available in' — got $class"

# BugBot usage-limit: curly apostrophe + em dash (GitHub renders both variants)
result=$(classify_body "Bugbot couldn’t run — usage limit reached")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Edge: BugBot usage-limit curly apostrophe + em dash → acknowledgment" \
  || fail "Edge: BugBot usage-limit curly apostrophe + em dash — got $class"

# BugBot spend-limit phrasing alone (no "couldn't run" header)
result=$(classify_body "this run hit a usage or spend limit")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Edge: BugBot 'this run hit a usage or spend limit' → acknowledgment" \
  || fail "Edge: BugBot 'this run hit a usage or spend limit' — got $class"

# The spend-limit override requires BugBot's full "this run hit ..." boilerplate, so
# prose merely discussing usage limits still reaches the finding tier. This matters in a
# repo whose PRs routinely edit the reviewer rate-limit paths.
#
# Note the limit of this guard: like every override (see #535's "found no new issues"),
# the usage-limit patterns are checked BEFORE the finding tier by design, so a finding
# quoting BugBot's boilerplate verbatim would still classify as an acknowledgment. That
# tradeoff is accepted repo-wide; the tight patterns keep the exposure to verbatim quotes.
result=$(classify_body "🔴 Critical: this retry path silently succeeds when the caller has hit a usage or spend limit.")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Edge: finding discussing usage/spend limits → finding (override not over-broad)" \
  || fail "Edge: finding discussing usage/spend limits — got $class"

# ---------------------------------------------------------------------------
# Bug 6: CodeRabbit auto-generated walkthrough / summary comment (issue #575)
#
# The boilerplate CR posts on nearly every PR. It matched NO branch, so it fell
# through to default → finding and produced phantom findings during /wrap Phase 1
# on PRs where CR had posted zero reviews and zero inline comments.
# Was: default → finding; Should be: CR walkthrough summary → acknowledgment
#
# Fixture note (why this is not the verbatim live body of comment 4994462241):
# CR edits its walkthrough comment IN PLACE. Since #575 was filed, that comment has
# had a rate-limit notice merged into the same body, so it now classifies as
# acknowledgment via #557's "rate limit notice" override — i.e. it would pass this
# test even with the walkthrough override deleted, asserting nothing. The body below
# is the walkthrough WITHOUT the rate-limit block: the normal, uncovered case that
# CR posts whenever it is not throttled. Bug6c pins the observed composite separately.
# ---------------------------------------------------------------------------
BODY='<!-- This is an auto-generated comment: summarize by coderabbit.ai -->
<!-- review_stack_entry_start -->

[![Review Change Stack](https://storage.googleapis.com/coderabbit_public_assets/review-stack-in-coderabbit-ui.svg)](https://app.coderabbit.ai/change-stack/auerbachb/claude-code-config/pull/568)

<!-- review_stack_entry_end -->

## Walkthrough

The start-issue skill now offers a handoff chip.

<details>
<summary>📒 Files selected for processing (1)</summary>

* `.claude/skills/start-issue/SKILL.md`

</details>

<sub>Comment `@coderabbitai help` to get the list of available commands.</sub>'
result=$(classify_body "$BODY")
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "CR walkthrough summary" ]]; then
  pass "Bug6: CR walkthrough/summary comment → acknowledgment"
else
  fail "Bug6: CR walkthrough/summary — expected acknowledgment/CR walkthrough summary, got $class/$reason"
fi

# ---------------------------------------------------------------------------
# Bug6a: MASKING GUARD — walkthrough marker + non-zero actionable count stays a finding.
#
# This is the reason the #575 override sits immediately above the default fallback
# instead of joining the tier-1 overrides. CR's walkthrough carries the actionable
# count for the findings it summarizes; an early marker override would classify this
# as an acknowledgment and drop the findings out of finding_count — a false clean on
# the review gate, strictly worse than the phantom-finding noise #575 fixes.
# Verified to FAIL if the override is hoisted above the finding branches.
# ---------------------------------------------------------------------------
BODY='<!-- This is an auto-generated comment: summarize by coderabbit.ai -->

## Walkthrough

Actionable comments posted: 3

<details>
<summary>📒 Files selected for processing (1)</summary>

* `.claude/scripts/pr-state.sh`

</details>'
result=$(classify_body "$BODY")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Bug6a: walkthrough marker + 'Actionable comments posted: 3' → finding (real findings not masked)" \
  || fail "Bug6a: walkthrough marker + actionable count — expected finding, got $class"

# ---------------------------------------------------------------------------
# Bug6b: MASKING GUARD — walkthrough marker + severity keyword stays a finding.
# Same rationale as Bug6a, via the severity-keyword branch rather than the count.
# ---------------------------------------------------------------------------
BODY='<!-- This is an auto-generated comment: summarize by coderabbit.ai -->

## Walkthrough

Summary of changes, including one nitpick raised against the retry loop.'
result=$(classify_body "$BODY")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Bug6b: walkthrough marker + severity keyword 'nitpick' → finding (real findings not masked)" \
  || fail "Bug6b: walkthrough marker + severity keyword — expected finding, got $class"

# ---------------------------------------------------------------------------
# Bug6c: the as-observed composite — walkthrough marker AND a rate-limit notice in
# one body (comment 4994462241 on PR #568, after CR edited it in place).
# Satisfied by EITHER the #557 rate-limit override or the #575 walkthrough override;
# asserting only the class keeps it robust to which one fires first. Kept so the
# real-world body stays covered without becoming a vacuous proxy for Bug6.
# ---------------------------------------------------------------------------
BODY='<!-- This is an auto-generated comment: summarize by coderabbit.ai -->
<!-- review_stack_entry_start -->
<!-- review_stack_entry_end -->
<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->

> [!WARNING]
> ## Review limit reached
>
> **Next review available in:** **16 minutes**

<!-- end of auto-generated comment: rate limited by coderabbit.ai -->'
result=$(classify_body "$BODY")
class="${result%%|*}"
[[ "$class" == "acknowledgment" ]] && pass "Bug6c: walkthrough marker + rate-limit notice composite → acknowledgment" \
  || fail "Bug6c: walkthrough + rate-limit composite — expected acknowledgment, got $class"

# ---------------------------------------------------------------------------
# Bug 7: CodeRabbit finding-withdrawal reply (issue #611)
#
# When you push back on a CR finding and CR agrees, it posts a reply retracting
# its own earlier finding ("Withdrawing the finding. 🐇") tagged with the machine
# marker <!-- <review_comment_withdrawn> -->. Seen live on still-point PR #601
# (comment 5034433530). The withdrawal body carries the analysis-chain script
# output; pre-fix it matched no branch and fell through to default → finding,
# inflating /fixpr's post-sweep new-findings count.
# Was: default → finding; Should be: withdrawn marker → acknowledgment.
#
# Fixture is a faithful, abbreviated copy of that reply: the auto-generated
# header, an analysis-chain <details> block, the "Withdrawing the finding" line,
# and the marker. The tier-1 marker override must win despite the analysis-chain
# body carrying no finding language of its own.
# ---------------------------------------------------------------------------
BODY='<!-- This is an auto-generated reply by CodeRabbit -->
<details>
<summary>🧩 Analysis chain</summary>

🏁 Script executed:

```shell
rg -n CURRENT_PROJECT_VERSION ios/project.yml
```

Length of output: 3362

</details>

`@auerbachb` You'"'"'re right — verified. With no label there is no path to an automatic build bump.

Withdrawing the finding. 🐇

<!-- <review_comment_withdrawn> -->'
result=$(classify_body "$BODY")
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "withdrawn marker" ]]; then
  pass "Bug7: CR finding-withdrawal reply → acknowledgment"
else
  fail "Bug7: CR finding-withdrawal reply — expected acknowledgment/withdrawn marker, got $class/$reason"
fi

# ---------------------------------------------------------------------------
# Bug7a: MARKER-ONLY GUARD — prose "withdrawing the finding" WITHOUT the HTML
# marker must NOT reclassify (mirrors Bug4c). The marker-only decision avoids the
# #557 generic-phrase false-ack risk: a real finding discussing a withdrawal, or a
# human quoting the phrase, still reaches the finding tier. The bare-prose variant
# is the load-bearing guard — it FAILS if a future edit adds any prose-phrase
# override for "withdrawing the finding"; re-run it if you touch the branch.
# ---------------------------------------------------------------------------
# With a severity keyword: even a genuine finding mentioning withdrawal stays a finding.
result=$(classify_body "**Critical:** the bot keeps withdrawing the finding before the fix is verified.")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Bug7a: finding quoting 'withdrawing the finding' → finding (prose is not an override)" \
  || fail "Bug7a: finding quoting 'withdrawing the finding' — expected finding, got $class"

# Bare prose, no marker, no severity — must reach the default → finding tier on its own.
result=$(classify_body "The reviewer mentioned withdrawing the finding but never posted the marker.")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Bug7a: bare prose 'withdrawing the finding' → finding (via default)" \
  || fail "Bug7a: bare prose 'withdrawing the finding' — expected finding, got $class"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: pr-state.sh classify — all fixtures and regressions passed (issues #535, #557, #575)"
