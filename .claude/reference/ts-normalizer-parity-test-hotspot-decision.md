<!-- churn-hotspot: .claude/scripts/tests/ts-normalizer-parity.test.sh -->
# Hotspot Decision — ts-normalizer-parity.test.sh

**Verdict:** KEEP (no structural change)
**Decided:** 2026-08-08
**Issue:** #1112
**Reporter:** `/wrap` post-merge churn report (PR #1111)

## Churn summary

`churn-hotspots.sh` flagged `.claude/scripts/tests/ts-normalizer-parity.test.sh` as
touched by 3 distinct merged PRs since 2026-08-01:

| PR | What changed | Lines |
|----|-------------|-------|
| PR #891 | Created `lib/ts-normalizer.sh` and `tests/ts-normalizer-parity.test.sh` to fix issue #885; the file is the byte-for-byte parity pin between bash `norm_ts` and the jq `canon_ts` used in `escalate-review.sh` | +439 added |
| PR #893 | Extended the file with structural merge-gate.sh guards (`check_guard_nesting`, `check_blocking_derivation`, `check_redemption_channel`, `external_evidence_ok` body check) to pin the retraction-guard boolean invariants introduced by issue #876 | +188 / −6 |
| PR #979 | Updated a single comment reference on line 167 from `escalate-review.test.sh` to `escalate-review-gate-met.test.sh` because PR #979 split the monolithic `escalate-review.test.sh` into four concern suites; no test logic was changed | +2 / −1 |

### CR plan discrepancy and resolution

The CR plan (retrieved via `cr-plan.sh 1112`) states "PR #979 has no trace anywhere in
the repository." **This is incorrect.** Verified from git evidence:

```
git log --oneline --follow -- .claude/scripts/tests/ts-normalizer-parity.test.sh
beeafe8 refactor: split escalate-review hotspot tests (#966) (#979)
55b3621 fix(#876): redeem a stale bot approval by evidence, not by reviewer identity (#893)
8e4c389 fix(#885): make gate/escalation timestamp drift fail in CI, not in review (#891)
```

And from `gh pr view 979 --json state,title,files,mergedAt`:
- PR #979 exists and was merged 2026-08-03
- Its change to `ts-normalizer-parity.test.sh` is exactly +2/−1: the comment
  block on line 167 that named `escalate-review.test.sh` was updated to
  `escalate-review-gate-met.test.sh` (the post-split filename) and reflowed to
  fit the 80-column limit

The CR plan's stated basis for KEEP ("PR #979 has no trace") is wrong. The correct
basis for KEEP is that PR #979 made an incidental comment update — no test logic,
no assertion, no section was changed — and the two PRs that contain all actual
test content (#891, #893) are coordinated single-root-cause hardening.

## Diagnosis

This is **coordinated, single-root-cause bug-fix-then-CI-hardening churn**, not
feature creep or instability.

Both content PRs originate from the same 2026-08-01 coding session and address
a single root bug (issue #885: timestamp drift between bash and jq normalizers
caused gate/escalation disagreement on PR #883):

- **PR #891** is the primary fix: extract the bash normalizer into
  `lib/ts-normalizer.sh` and create this test to pin byte-for-byte parity
  between the bash and jq implementations.
- **PR #893** is the immediate consequence: the retraction-guard changes to
  `merge-gate.sh` introduced new derived boolean variables (`_STALE_BLOCKING`,
  `_STALE_REDEEMED`) whose derivation from `external_evidence_ok` and their
  guard nesting order are security invariants. The same PR added the structural
  section to this file to pin those invariants.
- **PR #979** made a one-line comment update (no test logic) as an incidental
  follow-on to splitting `escalate-review.test.sh`.

### Structural observations

**1. Three normalizers are intentionally divergent — and the test exists to pin that.**

The file tests three distinct timestamp normalizers:

| Normalizer | Location | Role |
|-----------|---------|------|
| `norm_ts` | `lib/ts-normalizer.sh` (bash) | Gate and escalation freshness ordering |
| `canon_ts` | `escalate-review.sh` (jq) | Same contract as `norm_ts` but in jq; must be byte-identical for every input spelling |
| `canon_ts` | `review-substance.sh` (jq) | **Deliberately different**: drops fractional seconds and folds UTC spellings to "Z"; safe because every timestamp it compares passes through that one function |

The `review-substance.sh` divergence is asserted (`== review-substance.sh canon_ts: divergence is DELIBERATE and pinned ==`), not merely commented. A future "unify all three" refactor would silently change substance ordering, so the divergence is structural.

**2. Structural guards are deliberately colocated — per `merge-gate-hotspot-decision.md`.**

PR #893 added `check_guard_nesting`, `check_blocking_derivation`,
`check_redemption_channel`, and `external_evidence_ok` body checks. These pin the
boolean derivations that were explicitly **kept in the calling scope** (not
extracted into `_fetch_bot_approvals`) because this test watches them:

From `merge-gate-hotspot-decision.md` §"What was explicitly preserved":
> `CR_STALE_REDEEMED` / `CA_STALE_REDEEMED` — `ts-normalizer-parity.test.sh` pins the
> exact `external_evidence_ok` condition that precedes the `=true` assignment.
>
> `CR_APPROVAL_STALE_BLOCKING` / `CA_APPROVAL_STALE_BLOCKING` — Same test pins the
> condition preceding the `=true` assignment.
>
> `CR_APPROVAL_VALID` / `CA_APPROVAL_VALID` / `CR_HOLLOW` / `CA_HOLLOW` — Same test
> extracts the guard block starting at `CR_APPROVAL_VALID=false` and verifies nesting
> order of `_STALE_BLOCKING` and `_SUBSTANTIVE` checks.

The structural guards and the normalizer-parity tests share the same production-code
target (`merge-gate.sh` + its normalizer lib), the same runtime extractor pattern
(read the shipped scripts at runtime), and the same false-clean prevention design
(fatal on extraction failure, not skip). Colocation reflects a single deliberate
design, not an accident.

**3. No overlapping assertions with the black-box test files.**

`merge-gate-codeant-inplace-review.test.sh` and `merge-gate-ci-dedup.test.sh` contain
no structural assertions about guard nesting order, derivation formulas, or normalizer
parity. There is no duplication to remove.

**4. The test file has six internally cohesive sections.**

```
== norm_ts contract (lib/ts-normalizer.sh) ==
== parity: norm_ts (merge-gate) vs canon_ts (escalate-review) ==
== parity at the COMPARISON level (the shape PR #883 actually got wrong) ==
== review-substance.sh canon_ts: divergence is DELIBERATE and pinned ==
== the divergence is one-directional, and merge-gate.sh keeps it safe ==
== structural guards: no re-inlined copy of the rule ==
```

All six sections share a single extraction framework (`build_jq_program`,
`extract_guard_block`) and use the same fatal-on-error pattern. They are not
independent concerns; they are stacked layers of the same invariant (the timestamp
contract is consistent, the divergence is deliberate and bounded, and the gate logic
does not silently relax it).

### Comparison with the escalate-review-test-hotspot-decision.md SPLIT precedent

Issue #966 split `escalate-review.test.sh` because 11 PRs over a 10-week window
introduced four independently evolving concern suites (app-identity, BugBot
classification, gate-met, never-invited) that used distinct runner functions and
exercised disjoint code paths. That file had clear independent seams: the four
suites could be run in any order and isolated without harming each other.

`ts-normalizer-parity.test.sh` does not match that pattern:
- Only 3 PRs in 3 days (vs 11 PRs over 10 weeks)
- Both content PRs are from the same root bug (#885)
- No four-concern taxonomy — six tightly coupled layers of the same invariant
- No distinct runner functions (shared `build_jq_program`/`extract_guard_block`)

## Decision

**KEEP** the file in its current location with no structural change.

The churn is a single coordinated bug-fix-then-hardening episode (PRs #891 and #893,
both from the same 2026-08-01 session, both targeting the #885 timestamp-drift root
cause). The third PR (#979) made a one-line comment update. There is no signal of
ongoing independent iteration that would benefit from a split.

Future changes to the `canon_ts`/`norm_ts` contract and to `merge-gate.sh`
freshness/redemption logic will continue to require updates to this test. That is
correct behavior: the suite exists as a static structural drift-guard, and the
contract it guards is the merge gate's primary security invariant.

## Why not split

Splitting the timestamp-parity sections from the structural-guard sections would
fragment a single cohesive drift-guard mechanism:

1. **The structural guards exist because of the extraction.** The `_fetch_bot_approvals`
   function was introduced in the same PR class (#893) that added the structural guards.
   The variables pinned by `check_guard_nesting` and `check_blocking_derivation` were
   deliberately left in the calling scope so this test could watch them. Splitting
   would separate cause (the normalizer extraction) from its consequence (the calling-
   scope invariants that prevent silent re-inlining).

2. **The shared extraction framework is not incidental overhead.** `build_jq_program`
   and `extract_guard_block` both read the shipped production scripts at runtime. Any
   split would either duplicate this framework or add a sourced-lib dependency — buying
   nothing in correctness and adding maintenance surface.

3. **The divergence pin for `review-substance.sh` ties the two halves together.**
   Section 4 (`== review-substance.sh canon_ts: divergence is DELIBERATE and pinned ==`)
   is a cross-claim: the parity test succeeds only when escalate-review agrees with
   norm_ts, AND the divergence test succeeds only when review-substance deliberately
   differs. These two halves are one joint assertion about the timestamp contract.

## Future-edits guardrail

- New spellings in the timestamp matrix: extend sections 2–3 of this file; do not add a new file.
- New bot reviewer (e.g., a third reviewer with its own jq `canon_ts`): add a new parity section in this file.
- New `merge-gate.sh` freshness derivation variable: add an assertion to `check_blocking_derivation` or `check_guard_nesting`; do not split.
- If a future refactor moves `_STALE_BLOCKING`/`_STALE_REDEEMED` derivations into
  `_fetch_bot_approvals`: revisit at that point — the structural guards would then need
  to follow the production code into the function, and a split from the normalizer
  parity section could be warranted at that time.

## Expected impact

None. No files were changed. The test file and all production scripts remain unchanged.

## Related

- `.claude/scripts/tests/ts-normalizer-parity.test.sh` — the flagged file
- `.claude/scripts/lib/ts-normalizer.sh` — the bash normalizer library created by PR #891
- `.claude/reference/merge-gate-hotspot-decision.md` — explicitly documents the deliberate calling-scope keepout for `_STALE_BLOCKING`, `_STALE_REDEEMED`, `_APPROVAL_VALID`
- `.claude/reference/review-substance-hotspot-decision.md` — KEEP decision for `review-substance.sh`
- `.claude/reference/escalate-review-hotspot-decision.md` — KEEP decision for `escalate-review.sh`
- `.claude/reference/escalate-review-test-hotspot-decision.md` — SPLIT decision for `escalate-review.test.sh` (Issue #966); the contrasting precedent
- `.claude/reference/merge-gate-stale-approval-redemption.md` — documents the #876 redemption channel pinned by `check_redemption_channel`
- Issue #885 — root cause (timestamp drift causing gate/escalation disagreement)
- Issue #876 — stale-approval redemption channel (the invariant pinned by the structural guards)
- PR #979 discrepancy: CR plan claimed "no trace" but the PR exists and made a +2/−1 comment update; git log and `gh pr view 979` confirm attribution
