<!-- churn-hotspot: .claude/reference/harness-audit.md -->
# Hotspot Decision — harness-audit.md

**Verdict:** KEEP (no operative change)
**Decided:** 2026-08-07
**Issue:** #1049
**Reporter:** `/wrap` post-merge churn report (PR #1048)

## Churn summary

`churn-hotspots.sh` flagged `.claude/reference/harness-audit.md` as touched by 4 distinct merged
PRs since 2026-07-23: PRs #775, #825, #867, #982.

| PR | Churn class | What changed |
|----|-------------|--------------|
| PR #775 | File creation | Created `harness-audit.md` (230 lines) as the initial design record for the `/harness-audit` skill (Issue #770) |
| PR #825 | Doc-only correction | Added 2-line `CronCreate` session-only caveat blockquote; corrected the durability claim that `durable: true` had any effect (Issue #808) |
| PR #867 | Scheduling redesign propagation | Rewrote the scheduler section (renamed "Why a daily cron for a monthly audit" → "Why a session-start check for a monthly audit"); changed "cron" → "tick" throughout the file (Issue #827) |
| PR #982 | Scheduling refinement propagation | Changed one reference label from "cron/loop selection" to "scheduling primitive selection" in the References section (Issue #924) |

## Diagnosis

The churn is coordinated, single-lineage with no recorded merge conflicts across all 4 PRs.

**PR #775 is the foundational creation.** It established the full design record for Issue #770
(`feat(#770): add /harness-audit`). The file's structure — two-pass split, step-up chip, model
resolver, dual watermarks, out-of-repo default — was all authored in this single PR. No subsequent
PR restructured these sections; all later touches were targeted corrections or terminology updates.

**PR #825 is a doc-only scheduler-durability correction.** Issue #808 established that
`CronCreate`'s `durable: true` flag has no effect — jobs die at session exit regardless. PR #825
added the explicit caveat blockquote documenting this fact. The touch was a 2-line addition to the
scheduler section, not a redesign. It is the same doc-correction class as any factual annotation
added to a design record when an implementation assumption proves wrong.

**PRs #867 and #982 propagate the Issue #827 scheduler redesign.** PR #867 (`feat(#827): replace
CronCreate "durability" with session-start reconciliation`) was the primary redesign: it renamed
the scheduler-section heading, replaced all "cron" references with "tick" language, and rewrote
the rationale for why the harness audit uses a session-start watermark check instead of a daily
job. PR #982 (`fix(#924): move recurring polls to Monitor`) updated one reference label to match
the new scheduling-primitive terminology. Both PRs touched `harness-audit.md` as one file among
many in a coordinated cross-file propagation — the changes visible here are accurate updates to
the design record, not new design decisions.

**The three scheduler-lineage PRs (#825, #867, #982) all touch the same scheduler section.**
None of them introduced an independent concern into the file. The progression is: factual
correction (#825) → terminology redesign (#867) → label alignment (#982). This is the exact
pattern `churn-hotspots.md` classifies as "churn by design" for a living reference document that
tracks a feature under active development.

**No split is warranted.** `harness-audit.md` is a single-skill design record: its sections map
1:1 onto the `/harness-audit` SKILL.md steps (problem statement, two-pass split, model resolver,
session-start cadence, dual watermarks, report destination, dedup mechanism, verdict bar,
self-audit). No section owns a concern that belongs to a different skill or mechanism. The file is
not auto-loaded into the rule corpus, so its length does not consume the corpus budget.

## Decision

**KEEP** `.claude/reference/harness-audit.md` as the single design record for the `/harness-audit`
skill. Make no operative change.

The 4 reported touches are: 1 foundational creation + 1 doc-only correction + 2 coordinated
scheduler-redesign propagations. All three of the non-creation PRs (#825, #867, #982) updated the
same scheduler section in direct response to design decisions recorded in Issues #808, #827, and
#924 respectively. There is no collision of independent concerns and no identified duplication that
warrants action now.

Per `.claude/reference/churn-hotspots.md`, re-file this hotspot only when `conflict_rounds > 0` —
a rising PR count on a design record that tracks an evolving feature is not a re-filing trigger.

## Preserved invariants

- Canonical ownership stays with `harness-audit.md` as the `/harness-audit` design record.
- Dedup mechanics remain in `autofile-dedup.md` (both `/wrap` and `/harness-audit` exact-artifact
  variants are documented there).
- Chip mechanics remain in `chip-launching.md` (emitter classes, literal vs. resolver distinction).
- Scheduler-durability rationale remains in `cross-session-durability.md` (the authoritative
  record of why `CronCreate` and `mcp__scheduled-tasks__*` are both declined for durable work).

## Duplication watch-items (no action now)

Two conceptual overlaps are noted for future awareness — neither rises to a defect:

1. **Verdict-bar section vs. SKILL.md Step 6.** The "verdict bar, and its deliberate asymmetry"
   section in `harness-audit.md` overlaps conceptually (reworded, not verbatim) with Step 6 of
   `/harness-audit/SKILL.md`. This is intentional: the design record explains the reasoning behind
   the asymmetry; the SKILL.md step states the operative rule. No dedup is taken now.

2. **Model-tier section vs. chip-model-guard-decision.md.** The "Why the model tier is resolved,
   not written" section shares one fact with `chip-model-guard-decision.md` (the resolver-class
   designation for `/harness-audit`). The fact is already cross-linked via the References section.
   No dedup is taken now.

## Expected impact

None. No rule corpus files were changed. The corpus word count remains unchanged at the
pre-adjudication baseline.

## Related

- `harness-audit.md` — the adjudicated file; design record for `/harness-audit`
- `harness-model-audit-2026-06.md` — closest prior precedent (harness components vs model fleet, Issue #49)
- `chip-model-guard-decision.md` — the #770 resolver-class amendment; shares one cross-linked fact
- `cross-session-durability.md` — authoritative record of why durable scheduling is declined
- `autofile-dedup.md` — the exact-artifact dedup contract covering both `/wrap` and `/harness-audit`
- `churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic
- Issue #1049 — this hotspot
- Issue #770 — foundational `/harness-audit` design (PR #775)
- Issue #808 — CronCreate session-only correction (PR #825)
- Issue #827 — scheduler redesign (PR #867)
- Issue #924 — polling primitive refinement (PR #982)
- PR #1048 — reporting merge that triggered this hotspot
- Sibling `*-hotspot-decision.md` files in `.claude/reference/`
