#!/usr/bin/env bash
# Unit test for the canonical `pr-state-classify.jq` program invoked by
# catalog: tests — Tests the canonical `pr-state-classify.jq` program invoked by `pr-state.sh --since`
# `pr-state.sh --since`
# (issues #535, #557, #575, #669, #743, #1207, #1748).
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
#   - #1748: enrich() admitted only three of the five review bots, so CodeAnt and
#     Graphite findings never reached new_since_baseline (PR #1745). Bug11 pins the
#     admission end to end, through pr-state.sh --wait-state-eval, plus a parity check
#     against pr-state.sh's $botlist; Bug12 pins the CodeAnt non-finding shapes that
#     admission exposed. Bug12a's late-placement guard fails if those branches are
#     hoisted into tier 1 — re-run that control too if you touch the ordering.
#
# Strategy: run the canonical jq file used by pr-state.sh with a one-comment
# review fixture. This tests the actual production code rather than a copied
# duplicate, so the two can never drift apart.
#
# Requires: jq, bash 3.2+ (macOS-compatible — no mapfile/readarray, no head -n -N).
# Offline: no gh, no git, no network calls needed (Bug11 runs pr-state.sh's offline
# --wait-state-eval mode on a local bundle file).
set -euo pipefail

# Resolve the production filter relative to this test file — no git required, so the test
# runs from a source archive without .git metadata (matches the "no git" note above).
# This test lives in .claude/scripts/tests/; the filter is in the sibling lib/.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="$TEST_DIR/../lib/pr-state-classify.jq"

PASS=0
FAIL=0

fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

if [[ ! -r "$FILTER" ]] || ! jq -n \
    --argjson reviews '[]' \
    --argjson inline '[]' \
    --argjson conversation '[]' \
    --arg since '2026-01-01T00:00:00Z' \
    -f "$FILTER" >/dev/null 2>&1; then
  echo "ERROR: canonical classifier is missing or invalid: $FILTER" >&2
  exit 1
fi

# Run classify on a single body string and return "class|reason".
classify_body() {
  local body="$1"
  local reviews
  reviews=$(jq -nc --arg body "$body" \
    '[{id: 1, user: {login: "coderabbitai[bot]"}, submitted_at: "2026-01-02T00:00:00Z", html_url: null, url: null, body: $body}]')
  jq -n \
    --argjson reviews "$reviews" \
    --argjson inline '[]' \
    --argjson conversation '[]' \
    --arg since '2026-01-01T00:00:00Z' \
    -f "$FILTER" \
    | jq -r '.reviews[0].classification | .class + "|" + .reason'
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
# Bug4d: CodeRabbit's CURRENT retry-window wording (issue #1364), captured verbatim
# from auerbachb/still-point PR #676 on 2026-08-26 — `included` inserted between
# "Next" and "review", colon dropped, trailing period.
#
# This branch survived the drift where escalate-review.sh's window parser did not,
# and the reason is worth keeping: redundancy. Bug4b names three independent signals
# for exactly this case, so losing the fixed "next review available in" phrase left
# two others still matching. The escalation gate had only the one phrase, read a zero
# window, and escalated PRs to a sticky Greptile assignment mid-allowance. Both are
# now keyed on the same stable anchors (`next` … `review available in`, bounded 0-2
# inserted words); this pins that half of the pair.
# ---------------------------------------------------------------------------
BODY='<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->

> [!WARNING]
> ## Review limit reached
>
> **Next included review available in 27 minutes.**'
result=$(classify_body "$BODY")
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "rate limit notice" ]]; then
  pass "Bug4d: CR 'Next included review available in' wording → acknowledgment"
else
  fail "Bug4d: CR 'Next included review available in' wording — expected acknowledgment/rate limit notice, got $class/$reason"
fi

# The anchor phrase ALONE, with every other rate-limit signal stripped — no marker,
# no "Review limit reached" heading. Bug4d above would still pass on the pre-#1364
# pattern (the marker carries it), so without this case the widened phrase is
# untested. This is the shape that isolates it.
result=$(classify_body 'Next included review available in 27 minutes.')
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "rate limit notice" ]]; then
  pass "Bug4d: bare 'Next included review available in' phrase → acknowledgment (widened phrase isolated)"
else
  fail "Bug4d: bare 'Next included review available in' phrase — expected acknowledgment/rate limit notice, got $class/$reason"
fi

# Marker present, heading prose absent — the wording-independent half on its own.
result=$(classify_body '<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->

> [!WARNING]
> You have hit a temporary cap under our Fair Usage Limits Policy.')
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "rate limit notice" ]]; then
  pass "Bug4d: marker-only banner (no heading prose) → acknowledgment"
else
  fail "Bug4d: marker-only banner — expected acknowledgment/rate limit notice, got $class/$reason"
fi

# The bound holds: the inserted-word allowance is 0-2 words between the anchors, not
# an open bridge. A finding that happens to contain both anchor words separated by a
# sentence must NOT be absorbed into the rate-limit branch — that is the Bug4c hazard
# arriving through the widened phrase instead of a generic one.
result=$(classify_body 'The next retry helper we ship should make the review available in the summary, but it 404s.')
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Bug4d: anchors separated by >2 words → finding (allowance stays bounded)" \
  || fail "Bug4d: anchors separated by >2 words — expected finding, got $class"

# ---------------------------------------------------------------------------
# Bug4e: LOCKSTEP with escalate-review.sh's window parser (CodeAnt review of PR #1393).
# Drift arrives on both sides of "review": the 0-2 allowance above covers the adjective
# slot ("Next INCLUDED review"), and the future-tense copula ("next review WILL BE
# available in") is the other. This branch has read the copula form since #557 — it is
# the PR #554 body pinned in the Edge block below — but it read it via a hardcoded
# `(will be )?`, which the window parser had no equivalent of. Both files now carry one
# anchor shape; these cases pin this half of it, and only the phrase can carry them
# (the marker and heading signals are stripped from every body here).
# ---------------------------------------------------------------------------
result=$(classify_body 'Next included review will be available in 27 minutes.')
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "rate limit notice" ]]; then
  pass "Bug4e: BOTH slots at once ('next included review will be available in') → acknowledgment"
else
  fail "Bug4e: both slots at once — expected acknowledgment/rate limit notice, got $class/$reason"
fi

# The separators are \s+, not literal spaces, so the shape survives the whitespace its
# sibling parser manufactures for itself (stripping per-word emphasis off
# `**review**  **available in**` leaves a double space). A literal-space pattern would
# read nothing here while escalate-review.sh read the window fine — the two files out
# of lockstep again, in miniature.
result=$(classify_body 'Next  review  will  be  available  in 27 minutes.')
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "rate limit notice" ]]; then
  pass "Bug4e: irregular whitespace between anchors → acknowledgment"
else
  fail "Bug4e: irregular whitespace between anchors — expected acknowledgment/rate limit notice, got $class/$reason"
fi

# The copula slot is a LITERAL `will be`, not a second {0,2} bridge, and this is the
# case that holds it there. This file has no author gate, so a generic slot would let
# an ordinary finding whose prose happens to read "the next review is available in the
# dashboard" classify as a rate-limit ack — a false clean on the review gate, the Bug4c
# failure by another route. An unrecognised copula must reach the default instead.
result=$(classify_body 'The next review is available in the dashboard, but the link 404s.')
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Bug4e: unrecognised copula → finding (copula slot stays literal)" \
  || fail "Bug4e: unrecognised copula — expected finding, got $class"

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
# Bug 8: CodeRabbit auto-reply ack (issue #669)
#
# When you reply to a CR thread, CodeRabbit posts an automated acknowledgment
# comment tagged with the HTML marker:
#   <!-- This is an auto-generated reply by CodeRabbit -->
# followed by "Received — CodeRabbit is reviewing…" prose. Pre-fix, this matched
# no branch and fell through to default → finding, producing 5 phantom findings
# during /wrap Phase 1 on PR #659 (one per replied thread) on a PR whose merge
# gate was fully met.
# Was: default → finding; Should be: CR auto-reply ack → acknowledgment
#
# Fixture: faithful reproduction of the auto-reply body — marker plus prose.
# ---------------------------------------------------------------------------
BODY='<!-- This is an auto-generated reply by CodeRabbit -->

@auerbachb: Received — CodeRabbit is reviewing the changes. I will report back once the analysis is complete.'
result=$(classify_body "$BODY")
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "CR auto-reply ack" ]]; then
  pass "Bug8: CR auto-reply ack marker → acknowledgment"
else
  fail "Bug8: CR auto-reply ack — expected acknowledgment/CR auto-reply ack, got $class/$reason"
fi

# ---------------------------------------------------------------------------
# Bug8a: MARKER-ONLY GUARD — prose "Received — CodeRabbit is reviewing" WITHOUT
# the HTML marker must NOT reclassify (mirrors Bug4c and Bug7a).
#
# The marker-only decision avoids the #557 generic-phrase false-ack risk: a real
# finding that happens to quote the phrase "Received — CodeRabbit is reviewing"
# (e.g., a PR body or test describing the ack flow) still reaches the finding
# tier. Verified to FAIL if a prose-phrase override for "Received" or "CodeRabbit
# is reviewing" is ever added; re-run this guard if you touch the branch.
# ---------------------------------------------------------------------------
result=$(classify_body "**nitpick:** the error handler logs 'Received — CodeRabbit is reviewing' before the timeout fires, leaking internal state.")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Bug8a: finding quoting 'Received — CodeRabbit is reviewing' without marker → finding (prose not an override)" \
  || fail "Bug8a: finding quoting CR auto-reply prose — expected finding, got $class"

# ---------------------------------------------------------------------------
# Bug 9: Greptile clean-pass summary comment (issue #743)
#
# Greptile posts a "Greptile Summary" issue comment on nearly every PR. Pre-fix,
# it matched no branch and fell through to default → finding, inflating /wrap
# Phase 1 finding_count on PRs where Greptile had a fully clean pass.
# Was: default → finding; Should be: Greptile clean-pass summary → acknowledgment
#
# Fixture: faithful reproduction of PR #742's clean-pass summary shape.
# ---------------------------------------------------------------------------
BODY='<h3>Greptile Summary</h3> This PR condenses the auto-loaded rule corpus.

<h3>Confidence Score: 5/5</h3> Safe to merge — no issues found.'
result=$(classify_body "$BODY")
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "Greptile clean-pass summary" ]]; then
  pass "Bug9: Greptile clean-pass summary → acknowledgment"
else
  fail "Bug9: Greptile clean-pass summary — expected acknowledgment/Greptile clean-pass summary, got $class/$reason"
fi

# ---------------------------------------------------------------------------
# Bug9a: MASKING GUARD — Greptile summary heading + severity keyword stays a finding.
# Same rationale as Bug6a/Bug6b: the summary can mention findings it summarizes.
# ---------------------------------------------------------------------------
BODY='<h3>Greptile Summary</h3>

Summary of changes, including one nitpick raised against the retry loop.'
result=$(classify_body "$BODY")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Bug9a: Greptile summary + severity keyword 'nitpick' → finding (real findings not masked)" \
  || fail "Bug9a: Greptile summary + severity keyword — expected finding, got $class"

# ---------------------------------------------------------------------------
# Bug9b: genuine Greptile inline finding with P0 badge stays a finding (no regression).
# Uses the <img alt="P0"> format Greptile actually emits (issue #729).
# ---------------------------------------------------------------------------
BODY='<img alt="P0" src="badge.svg" /> Critical issue found in auth flow.'
result=$(classify_body "$BODY")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Bug9b: Greptile P0 inline badge → finding (unchanged behavior)" \
  || fail "Bug9b: Greptile P0 inline badge — expected finding, got $class"

# ---------------------------------------------------------------------------
# Bug9c: MASKING GUARD — Greptile summary + non-zero "issues found" stays a finding.
# The #743 override requires either no "issues found" prose or the explicit
# "no issues found" clean-pass wording; a summary reporting N>0 must not ack.
# ---------------------------------------------------------------------------
BODY='<h3>Greptile Summary</h3>

3 issues found in the diff.'
result=$(classify_body "$BODY")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Bug9c: Greptile summary + '3 issues found' → finding (non-clean summary not masked)" \
  || fail "Bug9c: Greptile summary + issue count — expected finding, got $class"

# ---------------------------------------------------------------------------
# Bug 10: CodeAnt review-status table comment (issue #1207)
#
# During /wrap Phase 1 on PR #1200, poll-watermarks.sh reported
# NEW_ISSUE_COMMENT_FINDINGS=1 for a single CodeAnt status comment of the form:
#   ✅ Reviewed your PR | <commit> | <time> | <time>
#   <!-- codeant-review-status:[{"label":"Reviewed your PR","commit":"...","done":true}] -->
# The merge gate was simultaneously met (0 unresolved threads, no inline findings).
# The status comment matched no branch and fell through to default → finding,
# which would have dispatched a spurious /fixpr sweep on an already-clean PR.
# Was: default → finding; Should be: CodeAnt review-status table → acknowledgment
#
# Fixture: faithful reproduction of the issue body's example shape.
# ---------------------------------------------------------------------------
BODY='✅ Reviewed your PR | 8646511 | 18:36 | 18:36
<!-- codeant-review-status:[{"label":"Reviewed your PR","commit":"8646511abc","done":true}] -->'
result=$(classify_body "$BODY")
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "CodeAnt review-status table" ]]; then
  pass "Bug10: CodeAnt review-status table → acknowledgment"
else
  fail "Bug10: CodeAnt review-status table — expected acknowledgment/CodeAnt review-status table, got $class/$reason"
fi

# Variant: marker-only (no prose before it) — still acknowledgment
BODY='<!-- codeant-review-status:[{"label":"Reviewed your PR","commit":"abc","done":true}] -->'
result=$(classify_body "$BODY")
class="${result%%|*}"; reason="${result##*|}"
if [[ "$class" == "acknowledgment" && "$reason" == "CodeAnt review-status table" ]]; then
  pass "Bug10: CodeAnt review-status marker-only → acknowledgment"
else
  fail "Bug10: CodeAnt review-status marker-only — expected acknowledgment/CodeAnt review-status table, got $class/$reason"
fi

# ---------------------------------------------------------------------------
# Bug10a: REGRESSION — real CodeAnt finding WITHOUT the marker stays a finding.
#
# Verifies the fix does not over-classify genuine CodeAnt findings. A real
# CodeAnt inline finding carries severity language but NOT the codeant-review-status
# HTML comment. This fixture pins the two-way requirement: status → acknowledgment
# AND finding → finding.
# ---------------------------------------------------------------------------
result=$(classify_body "🔴 Critical: this function doesn't validate the input before calling exec().")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Bug10a: real CodeAnt finding (severity badge, no marker) → finding" \
  || fail "Bug10a: real CodeAnt finding — expected finding, got $class"

result=$(classify_body "minor: the variable name 'x' is not descriptive enough.")
class="${result%%|*}"
[[ "$class" == "finding" ]] && pass "Bug10a: real CodeAnt finding (severity keyword, no marker) → finding" \
  || fail "Bug10a: real CodeAnt finding (severity keyword) — expected finding, got $class"

# ---------------------------------------------------------------------------
# Bug 11: every review bot reaches new_since_baseline (issue #1748)
#
# enrich() admitted only coderabbitai/greptile-apps/cursor, so a CodeAnt or
# Graphite finding never reached new_since_baseline: finding_count stayed 0, so
# did --wait-state-eval's new_findings, and /fixpr's Step 4d wait loop and Step 5b
# verify reported clean early. Observed on PR #1745 at HEAD d5884e6: baseline
# 15:40:41Z, CodeAnt inline finding 4157391754 at 15:42:16Z, wait loop printing
# new_findings: 0 on every tick.
#
# Every positive check below asserts the item is ADMITTED as well as how it is
# classified, so none of them can pass by the item silently dropping out — each
# fails against the old three-bot filter (the PR for #1748 records that run). The Bug11d
# controls are expected to pass both ways; they pin what must stay excluded.
# ---------------------------------------------------------------------------
PR_STATE="$TEST_DIR/../pr-state.sh"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
BUNDLE_SEQ=0

BASELINE='2026-10-01T15:40:41Z'
HEAD_SHA='d5884e6f93e5446faf984e374ce4e473186e1195'

# since_bundle <reviews> <inline> <conversation> <since> — the null-input mode
# pr-state.sh --since runs, on the given endpoint arrays.
since_bundle() {
  jq -n \
    --argjson reviews "$1" \
    --argjson inline "$2" \
    --argjson conversation "$3" \
    --arg since "$4" \
    -f "$FILTER"
}

# wait_new_findings <classifier-output> <reviews> <inline> <conversation> — embed
# the real classifier output in a pr-state-shaped bundle and run the real
# pr-state.sh --wait-state-eval predicate on it; print its new_findings.
wait_new_findings() {
  local bundle
  BUNDLE_SEQ=$((BUNDLE_SEQ + 1))
  bundle="$TMP/wait-bundle-$BUNDLE_SEQ.json"
  jq -n \
    --argjson nsb "$1" \
    --argjson reviews "$2" \
    --argjson inline "$3" \
    --argjson conversation "$4" \
    --arg sha "$HEAD_SHA" \
    '{pr: {head_sha: $sha},
      comments: {reviews: $reviews, inline: $inline, conversation: $conversation},
      check_runs: {all: []}, bot_statuses: {}, new_since_baseline: $nsb}' >"$bundle"
  "$PR_STATE" --wait-state-eval "$HEAD_SHA" "$bundle" | jq -r '.new_findings'
}

# classify_as <login> <body> — classify one review authored by <login>, posted
# after the baseline. Prints "class|reason", or "|" when enrich() drops it.
classify_as() {
  local reviews
  reviews=$(jq -nc --arg login "$1" --arg body "$2" \
    '[{id: 1, user: {login: $login}, submitted_at: "2026-10-01T16:00:00Z", html_url: null, url: null, body: $body}]')
  since_bundle "$reviews" '[]' '[]' "$BASELINE" \
    | jq -r '.reviews[0].classification | (.class // "") + "|" + (.reason // "")'
}

# Abbreviated verbatim body of CodeAnt inline finding 4157391754 (PR #1745).
CODEANT_FINDING_BODY='**Suggestion:** The catalog claims `/pm-forgotten-pr` is covered, but the test never verifies its actual `--ceiling` read; leaving explanatory text intact could let dispatch regressions pass.

**Assessment:** 🟠 `Major` · 🔁 `Occurrence: Rarely` · 🏷️ `Incomplete implementation`

<details>
<summary><b>Prompt for AI Agent 🤖 </b></summary>

This is a comment left during a code review.

**Path:** .claude/scripts/tests/pipeline-ceiling-consumers.test.sh
**Line:** 3:3
</details>'

CODEANT_STATUS_BODY='## 🤖 CodeAnt AI — Review Status

| Status | Commit | Started (UTC) | Finished (UTC) |
| --- | --- | --- | --- |
| ✅ Reviewed your PR | `d5884e6` | Oct 01, 2026 · 15:40 | 15:42 |

<!-- codeant-review-status:[{"label":"Reviewed your PR","commit":"d5884e6f93e5446faf984e374ce4e473186e1195","done":true}] -->'

# Bug11a: the PR #1745 replay. The CodeAnt finding and its empty COMMENTED review
# land after the baseline; the status table and promo footer predate it.
REVIEWS=$(jq -nc --arg sha "$HEAD_SHA" \
  '[{id: 5381758756, user: {login: "codeant-ai[bot]"}, state: "COMMENTED", commit_id: $sha,
     submitted_at: "2026-10-01T15:42:16Z", body: ""}]')
INLINE=$(jq -nc --arg body "$CODEANT_FINDING_BODY" \
  '[{id: 4157391754, user: {login: "codeant-ai[bot]"}, created_at: "2026-10-01T15:42:16Z",
     html_url: "https://github.com/auerbachb/claude-code-config/pull/1745#discussion_r4157391754", body: $body}]')
CONVO=$(jq -nc --arg status "$CODEANT_STATUS_BODY" \
  '[{id: 5934555428, user: {login: "codeant-ai[bot]"}, created_at: "2026-10-01T15:23:36Z", body: $status},
    {id: 5934555738, user: {login: "codeant-ai[bot]"}, created_at: "2026-10-01T15:23:37Z",
     body: "---\n\n### Thanks for using CodeAnt! 🎉\n\nWe are free for open-source projects."}]')
NSB=$(since_bundle "$REVIEWS" "$INLINE" "$CONVO" "$BASELINE")
got=$(jq -r '[.inline[0].user, .inline[0].classification.class, .finding_count, .acknowledgment_count,
              (.conversation | length)] | map(tostring) | join(" ")' <<<"$NSB")
if [[ "$got" == "codeant-ai[bot] finding 1 1 0" ]]; then
  pass "Bug11a: PR #1745 replay — CodeAnt inline finding after --since counted (finding_count 1)"
else
  fail "Bug11a: PR #1745 replay — expected 'codeant-ai[bot] finding 1 1 0' (user class findings acks convo), got '$got'"
fi
got=$(wait_new_findings "$NSB" "$REVIEWS" "$INLINE" "$CONVO")
if [[ "$got" =~ ^[0-9]+$ ]] && [[ "$got" -ge 1 ]]; then
  pass "Bug11a: --wait-state-eval on the real classifier output reports new_findings $got (>= 1)"
else
  fail "Bug11a: --wait-state-eval — expected new_findings >= 1, got '$got'"
fi

# Bug11b: the same for Graphite. Abbreviated from a graphite-app[bot] inline finding (PR #1589).
GRAPHITE_FINDING_BODY='The `marker_path()` test helper does not match the actual marker filename pattern when `cksum` is unavailable.

```suggestion
  [[ "$sum" =~ ^[0-9]+$ ]] || sum=""
```

*Spotted by [Graphite](https://app.graphite.com/diamond/?org=auerbachb&ref=ai-review-comment)*'
INLINE=$(jq -nc --arg body "$GRAPHITE_FINDING_BODY" \
  '[{id: 3001, user: {login: "graphite-app[bot]"}, created_at: "2026-10-01T15:45:00Z", body: $body}]')
NSB=$(since_bundle '[]' "$INLINE" '[]' "$BASELINE")
got=$(jq -r '[.inline[0].user, .inline[0].classification.class, .finding_count] | map(tostring) | join(" ")' <<<"$NSB")
if [[ "$got" == "graphite-app[bot] finding 1" ]]; then
  pass "Bug11b: Graphite inline finding after --since counted (finding_count 1)"
else
  fail "Bug11b: Graphite finding — expected 'graphite-app[bot] finding 1', got '$got'"
fi
got=$(wait_new_findings "$NSB" '[]' "$INLINE" '[]')
if [[ "$got" =~ ^[0-9]+$ ]] && [[ "$got" -ge 1 ]]; then
  pass "Bug11b: --wait-state-eval on the Graphite classifier output reports new_findings $got (>= 1)"
else
  fail "Bug11b: --wait-state-eval (Graphite) — expected new_findings >= 1, got '$got'"
fi

# Bug11c: CodeAnt non-finding items posted AFTER the baseline are admitted and stay
# acknowledgments — the status table and an empty-body review, plus the thread
# replies CodeAnt posts when /fixpr answers its findings. Without Bug 12's branches
# those replies would be phantom findings that keep /fixpr's wait loop re-sweeping.
REVIEWS=$(jq -nc '[{id: 7001, user: {login: "codeant-ai[bot]"}, state: "APPROVED", submitted_at: "2026-10-01T16:05:40Z", body: ""}]')
INLINE=$(jq -nc '[
  {id: 7002, user: {login: "codeant-ai[bot]"}, created_at: "2026-10-01T16:06:00Z",
   body: "✅ **CodeAnt verified this suggestion was addressed in subsequent commits and marked this thread resolved** as of `2c0c71b`.\n\nAdded an explicit guard.\n\n<!-- codeant-auto-resolve-reply -->"},
  {id: 7003, user: {login: "codeant-ai[bot]"}, created_at: "2026-10-01T16:06:30Z",
   body: "✅ **Customized review instruction saved!**\n\n**Instruction:**\n> Keep per-source degradation.\n\n**Applied to:**\n  - `.claude/scripts/candidate-ownership.sh`"}]')
CONVO=$(jq -nc --arg status "$CODEANT_STATUS_BODY" \
  '[{id: 7004, user: {login: "codeant-ai[bot]"}, created_at: "2026-10-01T16:05:16Z", body: $status}]')
NSB=$(since_bundle "$REVIEWS" "$INLINE" "$CONVO" "$BASELINE")
got=$(jq -r '[([.reviews[], .inline[], .conversation[]] | length), .finding_count, .acknowledgment_count]
             | map(tostring) | join(" ")' <<<"$NSB")
if [[ "$got" == "4 0 4" ]]; then
  pass "Bug11c: CodeAnt status table, empty review and thread replies after --since — admitted, all acknowledgments"
else
  fail "Bug11c: CodeAnt acknowledgments — expected '4 0 4' (admitted findings acks), got '$got'"
fi
got=$(wait_new_findings "$NSB" "$REVIEWS" "$INLINE" "$CONVO")
if [[ "$got" == "0" ]]; then
  pass "Bug11c: --wait-state-eval reports new_findings 0 for CodeAnt acknowledgments"
else
  fail "Bug11c: --wait-state-eval (CodeAnt acks) — expected new_findings 0, got '$got'"
fi

# Bug11d: controls — a CodeAnt finding BEFORE the baseline and a human comment
# after it both stay out of new_since_baseline.
INLINE=$(jq -nc --arg body "$CODEANT_FINDING_BODY" '[
  {id: 8001, user: {login: "codeant-ai[bot]"}, created_at: "2026-10-01T15:30:00Z", body: $body},
  {id: 8002, user: {login: "auerbachb"}, created_at: "2026-10-01T15:50:00Z", body: "Major: I think this needs a retry too."}]')
NSB=$(since_bundle '[]' "$INLINE" '[]' "$BASELINE")
got=$(jq -r '[(.inline | length), .finding_count] | map(tostring) | join(" ")' <<<"$NSB")
if [[ "$got" == "0 0" ]]; then
  pass "Bug11d: CodeAnt finding before --since and human comment after it — both excluded"
else
  fail "Bug11d: controls — expected '0 0' (admitted findings), got '$got'"
fi

# Bug11e: PARITY — the classifier's review_bots must equal pr-state.sh's
# --wait-state-eval $botlist. Both are parsed out of the files themselves, so a
# bot added to one list alone fails here. An unparseable list fails too: an empty
# parse never counts as agreement.
REVIEW_BOTS=$(tr '\n' ' ' <"$FILTER" \
  | grep -oE 'def review_bots:[[:space:]]*\[("[^"]*"[[:space:]]*,?[[:space:]]*)+\]' \
  | sed -E 's/^def review_bots:[[:space:]]*//' || true)
BOTLIST=$(tr '\n' ' ' <"$PR_STATE" \
  | grep -oE '\[("[^"]*"[[:space:]]*,?[[:space:]]*)+\][[:space:]]+as[[:space:]]+\$botlist' \
  | sed -E 's/[[:space:]]+as[[:space:]]+\$botlist$//' || true)
if [[ -z "$REVIEW_BOTS" || -z "$BOTLIST" ]]; then
  fail "Bug11e: parity — could not parse review_bots ('$REVIEW_BOTS') or \$botlist ('$BOTLIST')"
else
  # Prints "true" only when the two lists hold the same logins and both bots this
  # issue added are among them; any other output, a jq error included, fails.
  parity=$(jq -nr --argjson a "$REVIEW_BOTS" --argjson b "$BOTLIST" \
    '(($a | sort) == ($b | sort))
     and any($a[]; . == "codeant-ai[bot]")
     and any($a[]; . == "graphite-app[bot]")' 2>&1 || true)
  if [[ "$parity" == "true" ]]; then
    pass "Bug11e: parity — classifier review_bots equals pr-state.sh \$botlist"
  else
    fail "Bug11e: parity — review_bots $REVIEW_BOTS vs \$botlist $BOTLIST ($parity)"
  fi
fi

# Bug11f: behavioural half of the parity check — a finding from EVERY login in
# pr-state.sh's $botlist reaches new_since_baseline.
if [[ -n "$BOTLIST" ]]; then
  REVIEWS=$(jq -nc --argjson bots "$BOTLIST" \
    '[$bots | to_entries[] | {id: (.key + 1), user: {login: .value},
      submitted_at: "2026-10-01T16:00:00Z", body: "🟠 Major: missing retry on lock timeout."}]')
  NSB=$(since_bundle "$REVIEWS" '[]' '[]' "$BASELINE")
  got=$(jq -r --argjson bots "$BOTLIST" \
    '([.reviews[].user] == $bots) and (.finding_count == ($bots | length))' <<<"$NSB")
  if [[ "$got" == "true" ]]; then
    pass "Bug11f: a finding from every \$botlist login is admitted and counted"
  else
    fail "Bug11f: expected every \$botlist login admitted — got users $(jq -c '[.reviews[].user]' <<<"$NSB")"
  fi
else
  fail "Bug11f: \$botlist could not be parsed from pr-state.sh"
fi

# ---------------------------------------------------------------------------
# Bug 12: CodeAnt non-finding shapes stay acknowledgments (issue #1748)
#
# Admitting codeant-ai[bot] exposed every CodeAnt body to classify. These shapes,
# sampled from the 160 most recent PRs, matched no branch and fell through to
# default → finding. The fixtures are abbreviated copies of the observed bodies.
# ---------------------------------------------------------------------------
check_codeant_ack() {
  local label="$1" body="$2" want_reason="$3" result
  result=$(classify_as "codeant-ai[bot]" "$body")
  if [[ "$result" == "acknowledgment|$want_reason" ]]; then
    pass "Bug12: $label → acknowledgment ($want_reason)"
  else
    fail "Bug12: $label — expected acknowledgment|$want_reason, got $result"
  fi
}

check_codeant_ack "CodeAnt review-status table" "$CODEANT_STATUS_BODY" "CodeAnt review-status table"
check_codeant_ack "CodeAnt empty-body review" "" "empty body"
check_codeant_ack "CodeAnt auto-resolve reply" \
  '✅ **CodeAnt verified this suggestion was addressed in subsequent commits** as of `7892928`.

The fence opener regex now allows at most three leading spaces.

<!-- codeant-auto-resolve-reply -->' "CodeAnt auto-resolve reply"
# Tier-1 placement: the reply restates the fix and may carry finding vocabulary.
check_codeant_ack "CodeAnt auto-resolve reply restating a critical fix" \
  '✅ **CodeAnt verified this suggestion was addressed in subsequent commits and marked this thread resolved** as of `cf592ea`.

The critical path now fails closed on a malformed table.

<!-- codeant-auto-resolve-reply -->' "CodeAnt auto-resolve reply"
check_codeant_ack "CodeAnt saved-instruction reply" \
  '✅ **Customized review instruction saved!**

**Instruction:**
> Do not flag newline-delimited filename handling in scripts-catalog linting.

---
💡 *To manage or update this instruction, visit: [CodeAnt AI Settings](https://app.codeant.ai/org/settings/learnings)*' \
  "CodeAnt saved-instruction reply"
check_codeant_ack "CodeAnt promotional footer" \
  '---

### Thanks for using CodeAnt! 🎉

We'"'"'re free for open-source projects. if you'"'"'re enjoying it, help us grow by sharing.' \
  "CodeAnt promotional footer"
check_codeant_ack "CodeAnt empty Nitpicks summary" \
  '## CodeAnt Nitpicks

_No threshold-suppressed suggestions found in the latest review._' "CodeAnt empty nitpicks summary"
check_codeant_ack "CodeAnt review-skipped notice" \
  '**Skipping CodeAnt AI review** — this PR changes more than 100 files, which usually means a migration, codemod, or vendored drop.

If you still want a review, comment `@codeant-ai : review`.' "CodeAnt review-skipped notice"
check_codeant_ack "CodeAnt subscription notice" \
  'User dev@example.com does not have a PR Review subscription.

Go to [Team management](https://app.codeant.ai/org/settings/team-management) and add this email to the PR Review subscription.' \
  "CodeAnt subscription notice"

# Bug12a: guards — what must stay a finding.
check_codeant_finding() {
  local label="$1" body="$2" result
  result=$(classify_as "codeant-ai[bot]" "$body")
  if [[ "${result%%|*}" == "finding" ]]; then
    pass "Bug12a: $label → finding"
  else
    fail "Bug12a: $label — expected finding, got $result"
  fi
}

# A Nitpicks summary that LISTS suggestions is real review output (PR #1550 shape).
check_codeant_finding "CodeAnt Nitpicks summary listing a suggestion" '## CodeAnt Nitpicks

<!-- codeant-nitpicks:pr_code_suggestions:start -->
<details>
<summary><strong>1 code suggestion</strong></summary>

#### 1. If this new `mktemp` fails, the earlier temporary files remain because the cleanup trap is installed only afterward.

</details>
<!-- codeant-nitpicks:pr_code_suggestions:end -->'
# Marker-only: the auto-resolve PROSE without its HTML marker reaches the finding tiers.
check_codeant_finding "auto-resolve prose without the marker (marker-only)" \
  'CodeAnt verified this suggestion was addressed in subsequent commits, but a major gap remains.'
# Late placement: CodeAnt boilerplate beside finding language stays a finding.
# Fails if the boilerplate branches are hoisted above the finding patterns.
check_codeant_finding "CodeAnt promo footer + severity badge (late placement)" '### Thanks for using CodeAnt! 🎉

🟠 Major: the retry loop never re-reads the lock.'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: pr-state.sh classify — all fixtures and regressions passed (issues #535, #557, #575, #669, #743, #1207, #1748)"
