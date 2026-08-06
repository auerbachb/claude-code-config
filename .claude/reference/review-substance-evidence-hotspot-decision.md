<!-- churn-hotspot: .claude/reference/review-substance-evidence.md -->
# Hotspot Decision — review-substance-evidence.md

**Verdict:** KEEP (no structural change)
**Decided:** 2026-08-05
**Issue:** #1029
**Reporter:** `/wrap` post-merge churn report (PR #1028)

## Churn summary

`churn-hotspots.sh` flagged `.claude/reference/review-substance-evidence.md`
as touched by 5 distinct merged PRs since 2026-07-22:

| PR | What changed |
|----|-------------|
| PR #883 | Introduced the file: original failure narrative, observed traces (mia#171–172, ccc#867, ccc#883), signal ordering, the `counts_as_coverage` formula, and the pagination note for issue #875 |
| PR #896 | Added "Three admission rules for SHA-like tokens" for issue #894: all-decimal short-SHA admission, the form/identity/code-span split, and the rejected alternatives |
| PR #911 | Extended rule 3 with the four Markdown code-block stripping shapes for issue #897: tilde fences, indented blocks, unclosed openers, and the `m` vs `s` flag trap |
| PR #951 | Added "Quoted and echoed text is excluded first" for issue #933: the PR #929 echo trace, the blockquote-stripping rejection, ordered/edit-aware index semantics, and the fence-delimiter exception |
| PR #972 | Added "Descriptive evidence without a SHA" for issue #927: the ccc#923 trace, the conditions for `descriptive_evidence_on_head`, run-start marker definition, substance pooling across a bot's approvals, and two anti-false-positive choices |

## Diagnosis

This is **purposeful evidence accumulation**, not instability or scatter. The
file is a living trace log for the hollow-approval detection contract in
`review-substance.sh`. The churn pattern is identical to the companion test
file `merge-gate-review-substance.test.sh` (adjudicated in Issue #1014, PR #1026):
a real-world bypass trace is discovered → `review-substance.sh` is patched →
the evidence file gains a new section documenting the real-world shape that
motivated the fix and the guard that protects against over-correction.

Three observations support the KEEP verdict:

**1. Each section documents a distinct bypass shape.**
The five PR groups added independent content:
- PR #883 records the original four signal types and why body-length alone was
  rejected (the `396ced5` genuine walkthrough with `bodylen=0`).
- PR #896 records the all-decimal SHA wedge (15/431 commits on main, 3.5%)
  and exactly why each of the three admission rules moves coverage in only one
  direction.
- PR #911 adds the fence-stripping shapes and the `m`/`s` jq flag distinction,
  which is a correctness note for maintainers of rule 3 rather than a repeat
  of the rule's purpose.
- PR #951 documents the PR #929 echo trace, which required a different mechanism
  (identity-indexed filtering) from the obvious first cut (strip all blockquotes),
  along with the bidirectional effects of the echo filter on `counts_as_coverage`.
- PR #972 adds the ccc#923 trace, the conditions distinguishing a descriptive
  comment from a run-start or completion marker, and the proof that
  `descriptive_evidence_on_head` is one-directional (grants coverage removal,
  cannot manufacture a mismatch or a false self-report).

There is no mechanical duplication between sections. Each addresses a different
bypass pattern with a different evaluator extension, and the "What was rejected"
subsection in the SHA-admission section records alternatives that were evaluated
and declined — content that is not present elsewhere.

**2. Splitting would destroy the cumulative argument.**
The sections are not independent descriptions of independent features. They
compose into a single argument: body length alone is insufficient (section 1),
SHA-like tokens need three admission rules in sequence (sections 2-3), echo
filtering has bidirectional effects on the same formula (section 4), and
descriptive evidence is one-directional by construction (section 5). The file
explicitly cross-references earlier sections (rule 3 builds on rule 1-2;
`self_report_mismatch` in section 4 refers to section 1's formula; section 5's
safety property is stated relative to section 4's `self_report_mismatch` channel).
Splitting into per-issue files would break those references and require
cross-file navigation for readers trying to understand a single evaluator.

**3. No duplication with the companion test file.**
The companion `merge-gate-review-substance.test.sh` accumulates test cases;
this file accumulates the live traces and the design reasoning that those tests
pin. The test file contains `HEAD_SHA`, `COMMIT_TS`, and stub payloads; this
file contains the real observed timestamps, the counter-examples that drove
rejection decisions, and the prose argument for why each rule is safe. Neither
duplicates the other.

### Comparison with the companion test file adjudication (Issue #1014, PR #1026)

The Issue #1014 KEEP verdict rested on three structural points: no mechanical
duplication within the file, no coverage gap, and splitting would cost context.
This verdict rests on the same three points applied to the evidence file rather
than the test file. The two adjudications are consistent: both files accumulate
per-fix content for the same evolving contract, neither has a companion doing
overlapping work, and the accumulated content is denser because it is absent.

The only difference from the test file is PR #923 (issue #917, UUID-embedded hex
fragment exclusion). That PR added test cases `(ee-917)` to the test file but did
not touch this evidence file, because the ccc#923 trace that motivated issue #927
(descriptive non-SHA evidence, PR #972) was not yet written at the time PR #923
landed. The ccc#923 trace appears in PR #972's additions, when the complete
narrative became available.

## Decision

**KEEP** the file in its current location with no structural change.

The file is 481 lines / 4,749 words at adjudication time. That size reflects
the density of the reasoning, not scope creep: each section documents one bypass
shape, one rejected alternative, and one safety property. Future PRs that patch
new bypass shapes in `review-substance.sh` will continue to append new sections
in the same trace-then-reasoning style. That is the correct behavior for a
companion evidence log at the center of the hollow-approval detection seam.

## Expected impact

None. No operative files were changed. The churn pattern will continue as
`review-substance.sh` evolves — each new real-world trace adds an evidence
section. The file size is not a concern: the companion test file (967 lines /
175 assertions at Issue #1014 adjudication time) benchmarks the expected scale
for this seam.
