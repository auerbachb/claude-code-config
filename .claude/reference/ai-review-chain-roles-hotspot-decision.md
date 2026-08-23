<!-- churn-hotspot: .claude/reference/ai-review-chain-roles-decision.md -->
# Hotspot Decision — ai-review-chain-roles-decision.md

**Verdict:** KEEP (no operative change)
**Decided:** 2026-08-22
**Issue:** #1223
**Reporter:** `/wrap` post-merge churn report (PR #1221)

Reference for Issue #1223 (`.claude/reference/ai-review-chain-roles-decision.md` churn hotspot). Not auto-loaded — the rule corpus carries none of this.

## Churn summary

`churn-hotspots.sh` flagged `.claude/reference/ai-review-chain-roles-decision.md` as touched by 3 distinct merged PRs in the original report window: PRs #1203, #1216, and #1217. PR #1271 (merged 2026-08-22) added a Graphite reconciliation section — counted as further churn evidence, not in the original window.

| PR | Title | Churn class | Sections affected |
|----|-------|-------------|-------------------|
| PR #1203 | feat(#1199): realign the AI review chain with measured subscription reality | New file creation + dashboard reconciliation | All sections through `## References` (file did not exist before this PR); also merged the PR #1204 dashboard-reconciliation addendum in the same squash |
| PR #1216 | feat(#1213): track the review stack's paid levers with their ordering gates | Decision addendum | §Repo variance (CodeRabbit CLI seat clarification); §Operator actions (paid-levers pointer and item 6 content) |
| PR #1217 | feat(#1212): evaluate CodeRabbit's OSS tier and settle the billing cadence | New decision section | Added `## CodeRabbit OSS tier vs paid Pro (#1212, 2026-08-21)` in its entirety |
| PR #1271 | docs(#1232): record Graphite D1 drift — promote advisory → fallback | New reconciliation section | Added `## Graphite role reconciliation (#1232, 2026-08-22)` in its entirety |

## Per-section churn attribution (evidence)

### PR #1203 — File creation (Issue #1199)

PR #1203 introduced the AI review chain role-assignment decision record. The file did not exist beforehand. The commit squash also included the PR #1204 dashboard-reconciliation additions, so `## Dashboard reconciliation (#1204, 2026-08-21)` was authored in the same squash even though it cites a separate issue. Sections created:

- `## Decision` — role table (5 bots × 4 columns), authoritative chain-order diagram
- `### The three assumptions this decision corrects` — CodeRabbit rate-limit signal shapes, BugBot spend-refusal terminal behavior, `greptile-budget.sh` loop-bound vs cost-bound distinction
- `### Repo variance` — public/private CLI cap difference; original CodeRabbit seat paragraph (partially extended by PR #1216)
- `## Rationale` — four sub-sections: chain order, Greptile retention, Graphite non-promotion, re-measure trigger
- `## Explicitly rejected` — 8 declined options with per-option reasoning
- `## Dashboard reconciliation (#1204, 2026-08-21)` — 6 numbered items recording what the live dashboard reads changed
- `## Operator actions this decision depends on` — framing + 5 action items (item 6 added by PR #1216)
- `## References` — 8 sibling-doc and issue links

This is authorship, not independent iteration on existing content. Merge conflicts: 0.

### PR #1216 — Paid-levers addendum (Issue #1213)

PR #1216 created `ai-review-paid-levers-checklist.md` and added cross-references to it here. Additions:

- **§Repo variance**: Added the "This is not a seat problem, and re-auth cannot fix it" paragraph — recording the CodeRabbit CLI seat status after measuring it, because the opposite reading had reached `pricing-matrix.md` as a pending action.
- **§Operator actions item 6**: Added the tracking pointer to `ai-review-paid-levers-checklist.md` with the rationale for separating `Submitted:` and `Approved:` dates, plus the initial version of item 6 (annual billing / seat count).
- **§Dashboard reconciliation item 6 preamble**: Updated the framing paragraph that connects dashboard reconciliation item 6 to §Operator actions item 6.

These are addenda that capture new decisions made while building the paid-levers tracker. Merge conflicts: 0.

### PR #1217 — CodeRabbit OSS/paid verdict (Issue #1212)

PR #1217 added an entire new decision section for the CodeRabbit OSS-vs-paid evaluation:

- `## CodeRabbit OSS tier vs paid Pro (#1212, 2026-08-21)` — verdict (stay paid, switch to annual), the break-even reasoning (two documented certainties + unknown OSS rate), the displaced-cost calculation, operational change notes, and a finding about bot-authored CodeRabbit triggers.

The section is a decision summary that anchors the verdict inside the role-assignment document; the full side-by-side lives in `cr-oss-vs-paid-decision.md` (linked). Merge conflicts: 0.

### PR #1271 — Graphite re-decision (Issue #1232)

PR #1271 added the Graphite reconciliation section triggered by a D1 drift finding from the first measured post-swap audit run:

- `## Graphite role reconciliation (#1232, 2026-08-22)` — D1 trigger, evidence (two sole-source PRs), decision (promote from `advisory` to `fallback`, non-gating), what it does not change.

This is an in-scope decision update on the same decision record: Graphite's re-measure trigger (§Re-measure trigger (Graphite)) was explicitly stated to fire at ≥30 merged PRs under the paid plan; PR #1271 is that decision firing. Merge conflicts: 0.

## Diagnosis

The churn is single-lineage with `conflict_rounds == 0` across all 4 PRs (no merge conflicts).

**PR #1203 is the foundational file creation.** The decision record did not exist before this PR. It was authored as the canonical role-assignment record following the 244-PR audit, and the dashboard-reconciliation addendum (§Dashboard reconciliation) was merged in the same squash.

**PR #1216 is a decision addendum.** The paid-levers tracker (`ai-review-paid-levers-checklist.md`) was a new artifact that needed cross-referencing from the role-assignment doc; the CodeRabbit CLI seat finding corrected a misread that had propagated elsewhere. Both are factual updates warranted by new information, not rework of existing content.

**PR #1217 adds a new decision section.** The CodeRabbit OSS-vs-paid evaluation was a deliberate gated decision that belongs in the role-assignment record — it directly affects the cost rationale for CodeRabbit's row. Its summary here is a proper decision-record entry, not duplicated detail.

**PR #1271 adds a new reconciliation section.** The Graphite re-decision was explicitly anticipated in the document (§Re-measure trigger) and fires here as designed. This is the intended evolution of a living decision record.

**No structural debt identified.** All four PRs build on the document in the same direction — authoring, then extending with new decisions as audit evidence and vendor billing facts arrived. Sections do not contradict each other; they build on each other. No section was revisited to correct a prior error in structure; corrections (CodeRabbit rate-limit signal shapes, Greptile paid status) updated specific paragraphs within existing sections with new measurements, not reworked the section structure.

**No dedup warranted.** The CR plan (available via `cr-plan.sh`) suggested two targeted-dedup edits:
1. Shrink `## CodeRabbit OSS tier vs paid Pro` to verdict + link, removing repeated numbers.
2. Shrink item 6 of `## Operator actions` to a pointer into `ai-review-paid-levers-checklist.md`.

Both are declined. A decision record's `## CodeRabbit OSS tier vs paid Pro` section exists specifically to provide the executive-level rationale that anchors the cost-row entry in the role table. The "repeated" numbers (break-even reasoning, displaced cost) are not duplicated in the linked companion doc in the same anchored form — they are summary content that belongs in the record. Item 6 of `## Operator actions` similarly carries current corrected seat-count and pricing figures that are load-bearing context for the operator action; reducing them to a pointer would lose the "what to do first and why" substance that records the decision. Neither edit would save rule-corpus words (this file is not in the auto-loaded corpus), and both would reduce the document's value as a self-contained decision record.

## Options considered

| Option | Outcome |
|--------|---------|
| KEEP (no operative change) | **Selected** — organic append-only growth on a living decision record; no structural debt |
| KEEP + targeted-dedup (CR plan) | Declined — proposed removals reduce decision-record substance; no corpus savings since file is not auto-loaded |
| SPLIT — divide into role-decision core and addenda files | Declined — every section is referenced by sibling docs and rule files as part of one canonical source; splitting would fragment the cross-reference graph |

## Decision: KEEP

**KEEP** `.claude/reference/ai-review-chain-roles-decision.md` with no operative change.

The 4 touches are:
1. PR #1203 — foundational file creation + initial dashboard reconciliation (Issue #1199)
2. PR #1216 — paid-levers decision addendum (Issue #1213)
3. PR #1217 — CodeRabbit OSS/paid verdict section (Issue #1212)
4. PR #1271 — Graphite re-decision section (Issue #1232)

All 4 PRs build on the same decision record in the same direction: initial authoring of a canonical role-assignment document, then sequential recording of new decisions as billing facts arrived. No merge conflicts; no independent-owner churn; no contradictory sections. The re-measure trigger for Graphite (§Re-measure trigger) was designed to fire here — PR #1271 is that trigger firing as specified. The growth is the intended evolution of a living decision record.

Per `.claude/reference/churn-hotspots.md`, re-file this hotspot only when `conflict_rounds > 0` — a rising PR count on a living decision record is not a re-filing trigger.

## What was explicitly preserved

- `## Decision` — role table and chain-order diagram unchanged; every bot login and role assignment preserved
- `### The three assumptions this decision corrects` — all three corrected-assumption paragraphs unchanged
- `### Repo variance` — public/private CLI cap split, CodeRabbit seat findings unchanged
- `## Rationale` — all four sub-sections unchanged
- `## Explicitly rejected` — all 8 declined options and their reasoning unchanged
- `## Dashboard reconciliation (#1204, 2026-08-21)` — all 6 items unchanged
- `## CodeRabbit OSS tier vs paid Pro (#1212, 2026-08-21)` — verdict, break-even reasoning, and bot-trigger finding unchanged
- `## Operator actions this decision depends on` — all 6 items unchanged
- `## References` — all 8 cross-references unchanged
- `## Graphite role reconciliation (#1232, 2026-08-22)` — trigger, evidence, decision unchanged
- The `gates_merge`/`approves_via` separation and the review-stack baseline provenance (decision-record-based, swapped by #1214/PR #1221) are both preserved

## Expected impact

None. `ai-review-chain-roles-decision.md` is not in the auto-loaded rule corpus. The corpus word count is unchanged.

## Related

- `.claude/reference/ai-review-chain-roles-decision.md` — the adjudicated file; canonical role-assignment decision record for the AI review chain
- `.claude/reference/ai-review-tool-audit-2026-08.md` — the measurement base every row in the role table rests on
- `.claude/reference/cr-oss-vs-paid-decision.md` — full CodeRabbit OSS/paid side-by-side; this decision record delegates its detailed break-even to that doc
- `.claude/reference/ai-review-paid-levers-checklist.md` — standing tracker for owner-only paid decisions; §Operator actions delegates to it
- `.claude/reference/ai-review-billing-dashboard-2026-08.md` — primary-source dashboard readings that corrected the founding assumptions
- `.claude/reference/merge-gate-reviewer-paths.md` — per-path gate semantics; cross-references the role assignments recorded here
- Issue #1223 — this hotspot
- Issue #1199 — AI review chain realignment (PR #1203)
- Issue #1213 — paid levers tracking (PR #1216)
- Issue #1212 — CodeRabbit OSS evaluation (PR #1217)
- Issue #1232 — Graphite re-decision (PR #1271)
- PR #1221 — reporting merge that triggered this hotspot
