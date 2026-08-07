<!-- churn-hotspot: .claude/skills/harness-audit/SKILL.md -->
# Hotspot Decision — harness-audit/SKILL.md

**Verdict:** KEEP (no operative change)
**Decided:** 2026-08-07
**Issue:** #1054
**Reporter:** `/wrap` post-merge churn report (PR #1053)

## Disambiguation

This record covers `.claude/skills/harness-audit/SKILL.md` — the operational skill procedure.
A sibling record `.claude/reference/harness-audit-hotspot-decision.md` (Issue #1049) covers
`.claude/reference/harness-audit.md` — the design rationale document.
The two files are related (SKILL.md points to harness-audit.md for rationale) but are separate
artifacts with different churn histories. Cross-reference that record for the watch item noted
in the "Duplication watch-items" section below.

## Churn summary

`churn-hotspots.sh` flagged `.claude/skills/harness-audit/SKILL.md` as touched by 4 distinct
merged PRs since 2026-07-28: PRs #775, #799, #825, and #867.

| PR | Title | Churn class | Steps affected |
|----|-------|-------------|----------------|
| PR #775 | feat(#770): add /harness-audit | File creation | All steps (0–9, Exit criteria): 683-line initial file |
| PR #799 | feat(#791): versionless model names + effort on every surface | Chip-contract propagation | Step 5 only |
| PR #825 | fix(#808): correct CronCreate durability claims | Bug-fix annotation | Step 1 only (warning blockquote) |
| PR #867 | feat(#827): replace CronCreate "durability" with session-start reconciliation | Scheduling redesign | Steps 0, 1, 2 (major rewrite) |

## Per-step churn attribution (evidence)

### PR #775 — File creation (Issue #770)

All steps were authored in a single PR. The 683-line file introduced:
- Steps 0–9 and Exit criteria, establishing the two-pass shape, CronCreate daily cadence,
  model-fleet resolver, exact-artifact dedup for Step 7, and advisory-only constraint.
- The chip contract in Step 5 referenced `model-fleet.sh` as a resolver emitter class
  (rather than a literal model name), enforced by `chip-model-guard-lint.sh`.
- `inventory.sh` also created in this PR as the Step 3 script.

No rebase conflicts. Single-authorship creation.

### PR #799 — Step 5 chip effort extension (Issue #791)

Changed only the "Chip model + effort contract" subsection within Step 5:
- Section heading: "Chip model contract" → "Chip model + effort contract"
- Added `**Effort:** Max — correctness-over-cost: a wrong "the harness covers this" verdict
  silently deletes a working guard` line to the chip template
- Added prose explaining why effort is a literal while model is resolved
- Updated summary description: `**Model:**` only → both `**Model:**` and `**Effort:**` lines

This is chip-contract propagation shared across 8+ skill files in PR #799. The change
is not specific to harness-audit; it is a fleet-wide effort-line extension to the chip
template. Steps 0–4, 6–9, and Exit criteria were untouched.

### PR #825 — Step 1 CronCreate warning annotation (Issue #808)

Added a single warning blockquote inside Step 1's `--arm` section:
```
> **Warning:** `CronCreate` is **session-only** — the job is held in memory and dies
> when Claude exits, regardless of `durable: true`. The daily registration design assumes
> the job survives long enough within a session to re-register itself; it does **not**
> persist across session boundaries. The current scheduling design therefore relies on a
> guarantee the harness does not provide. Redesign of the audit's scheduling cadence is
> tracked as a follow-up ticket.
```

This is a doc-only correction: the original CronCreate-based design assumption was wrong,
and PR #825 annotated that before the redesign arrived in PR #867. 2-line addition to an
existing step; no step restructuring.

### PR #867 — Steps 0, 1, 2 scheduling redesign (Issue #827)

Major rewrite of the scheduling mechanism. This PR replaced the CronCreate daily-job
approach with a session-start watermark check. Evidence:

**Step 0 mode table** — terminology propagation:
- "Neither creates nor disturbs the recurring job." → "Neither enables nor disturbs the recurring nudge."
- "The cron body." → "The tick body."
- "Register the recurring job." → "Enable the session-start nudge."
- "Cancel the recurring job." → "Disable the session-start nudge."
- "A cron never runs the judgment pass" → "A tick never runs the judgment pass"
- `--arm` description: "waiting a day, then exits" → "waiting for the next session, then exits"

**Step 1 complete rewrite** — CronCreate → session-start:
- Removed: the CronCreate daily-cadence rationale (multiple paragraphs about 7-day expiry,
  daily-tick gate on monthly watermark, seven chances to notice expiry)
- Removed: the PR #825 warning blockquote (no longer relevant after redesign)
- Removed: the `off-peak-minute.sh` bash block and CronCreate session-state persistence
- Added: explanation of why CronCreate cannot be used (session-only, dies at exit)
- Added: why `mcp__scheduled-tasks__*` is declined (see `cross-session-durability.md`)
- Added: watermark-file durability argument — session-start hook reads it reliably
- Added: `state-lock.sh` locked block for atomic watermark write (both `--arm` and `--stop`)

**Step 2 simplification** — pure watermark arithmetic:
- Removed: job-survival confirmation (no job to confirm)
- Kept: watermark read and gating table (logic unchanged, job references removed)

Steps 3–9 and Exit criteria were untouched by PR #867.

## Diagnosis

The churn is single-lineage with no recorded merge conflicts across all 4 PRs.

**PR #775 is the foundational creation.** It established the full operational procedure
across all 9 steps plus exit criteria. Every subsequent PR touched a proper subset of steps
in response to a specific change driver; none restructured the overall step sequence.

**PR #799 is chip-contract propagation.** Step 5 was the target; it propagated the
effort-line addition from `chip-launching.md` across all 8 chip emitter skills. The change
is byte-identical in structure to the same effort-line extension in `prompt/SKILL.md`,
`wave/SKILL.md`, and others. Not specific to harness-audit.

**PR #825 is a doc-only bug-fix annotation.** Issue #808 established that CronCreate's
`durable: true` has no effect — jobs die at session exit regardless. PR #825 annotated
the existing CronCreate design with a warning before the redesign landed. The annotation
was then removed by PR #867 as part of replacing the CronCreate design entirely.

**PR #867 propagates the Issue #827 scheduler redesign.** The redesign moved the recurring
tick from a CronCreate job to a session-start watermark check. This required updating
Steps 0, 1, and 2, which described the old scheduling primitives. PR #867 touched
SKILL.md as one of several scheduling-primitive consumers alongside `babysit-pr/SKILL.md`,
`pr-monitor-and-manage/SKILL.md`, `pm-handoff/SKILL.md`, `pm/SKILL.md`, and others.

**No split is warranted.** The 9-step skill covers a tightly coupled operational
procedure: parse mode (Step 0), lifecycle control (Step 1), tick gating (Step 2),
inventory (Step 3), harness research (Step 4), model gating + chip offer (Step 5),
verdict (Step 6), issue filing (Step 7), report (Step 8), and user output (Step 9).
These steps are sequentially dependent — Step 5 consumes Step 3's inventory, Step 7
consumes Step 6's verdicts, etc. No section owns a concern that belongs to a different
skill or mechanism. The file is not auto-loaded into the rule corpus, so its length
does not consume the corpus budget.

## CR plan verification: proposed dedup analysis

The CR plan (retrieved via `.claude/scripts/cr-plan.sh 1054`) proposed KEEP + dedup,
specifically: reduce Step 3 category descriptions to a pointer to `inventory.sh --help`
and reduce Step 7 dedup mechanics to a pointer to `autofile-dedup.md`.

Both proposals were verified against their claimed canonical sources:

### Step 3 vs `inventory.sh --help` — VERIFIED MINOR, NOT APPLIED

**What overlaps:** Step 3 lines ~204–215 describe the four artifact categories — `rule`,
`skill`, `script`, `hook` — and the cross-checked union for hooks. This is a minor
restatement of `inventory.sh`'s CATEGORIES section in its header comment.

**What does NOT overlap:** The operative instruction "quote [exclusions] in the report
rather than letting a skipped path be invisible" is unique to SKILL.md and not in
`inventory.sh --help`.

**Why not applied:** The reduction would replace ~2 sentences with ~2 sentences (a
pointer + the preserved instruction). The category descriptions serve as operator
orientation — a reader of SKILL.md should not need to interrupt the procedure to
read `inventory.sh --help` for orientation on what the script produces. SKILL.md is
not in the auto-loaded rule corpus, so there is no budget pressure. Given that
`chip-model-guard-lint.sh` enforces Step 5 content and any SKILL.md edit risks
touching lint-governed content, the zero-edit path is preferred for a 2-sentence gain.

### Step 7 vs `autofile-dedup.md` — PARTIAL OVERLAP, NOT APPLIED

**What overlaps (generic principles):**
- "Failed lookup BLOCKS filing" general principle — in `autofile-dedup.md`
- "Never silent" obligation — in `autofile-dedup.md` "Never silent (shared obligation)"
- General "same-run batch self-check" concept — in `autofile-dedup.md`

**What does NOT overlap (harness-audit-specific):**
- Title convention: `Harness redundancy: <artifact path>` — unique to harness-audit
- Body marker: `<!-- harness-audit: <artifact path> -->` — unique to harness-audit
- Specific bash: `gh issue list --search "Harness redundancy in:title"` — unique
- `DEDUP_LIMIT=200` constant and saturation-check bash — unique to SKILL.md
- Template text in issue #770 caveat (the `<!-- harness-audit: <artifact path> -->` in a template) — unique
- Body shape (6-section `/issue-maker` body) — unique to harness-audit
- Open/closed match implementation actions — unique to harness-audit

**Critically:** Step 7 ALREADY points to `autofile-dedup.md` as the canonical source:
"Every finding names one unambiguous artifact path, so this uses the **exact-artifact**
variant from `autofile-dedup.md`." The overlapping generic principles are already
cross-referenced by this existing pointer. The remaining prose in Step 7 is the
harness-audit-specific implementation layer on top of that contract.

**Why not applied:** Step 7's dedup section is predominantly implementation-specific
content that cannot live in `autofile-dedup.md`. The overlapping generic-principle
prose is already minimized by the existing pointer. Further reduction would produce
a section that says "see `autofile-dedup.md`" followed by six paragraphs of
harness-audit-specific implementation — not a meaningful improvement in navigability.
The zero-edit path is preferred.

## Decision

**KEEP** `.claude/skills/harness-audit/SKILL.md` with no operative change.

The 4 reported touches are: 1 foundational creation (PR #775) + 1 chip-contract
propagation (PR #799, Step 5 only) + 1 doc-only bug-fix annotation (PR #825, Step 1 only)
+ 1 scheduler redesign (PR #867, Steps 0/1/2). No PR introduced an independent concern
fighting over the same step content as another PR. No merge conflicts across any of the
4 PRs. The churn is by-design: each PR was a deliberate targeted change to the subset
of steps that needed updating.

The CR plan's KEEP + dedup proposal was verified: both claimed duplications were found to
be minor overlaps with non-zero harness-audit-specific context in the adjacent lines,
and SKILL.md is not corpus-budgeted. The zero-edit record is preferred.

Per `.claude/reference/churn-hotspots.md`, re-file this hotspot only when
`conflict_rounds > 0` — a rising PR count on a living operational procedure is not a
re-filing trigger.

## Duplication watch-items (no action now)

**Verdict-bar overlap with SKILL.md Step 6:** The #1049 decision record for
`harness-audit.md` identified a conceptual overlap between the "verdict bar, and its
deliberate asymmetry" section in `harness-audit.md` and Step 6 of this SKILL.md.
This is noted as intentional (design record explains reasoning; SKILL.md states the
operative rule) and is not a defect. No dedup taken here; the watch item remains open
at the same status as recorded in #1049.

## Expected impact

None. SKILL.md is not in the auto-loaded rule corpus. The corpus word count remains
unchanged.

## Related

- `.claude/skills/harness-audit/SKILL.md` — the adjudicated file; operational procedure for `/harness-audit`
- `.claude/reference/harness-audit-hotspot-decision.md` — sibling decision covering `harness-audit.md` (Issue #1049); includes the verdict-bar watch item cross-referenced above
- `.claude/reference/harness-audit.md` — design rationale for `/harness-audit` (#770)
- `.claude/reference/autofile-dedup.md` — canonical exact-artifact dedup contract (Step 7 canonical source)
- `.claude/skills/harness-audit/inventory.sh` — canonical artifact-category definitions (Step 3 canonical source)
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic
- Issue #1054 — this hotspot
- Issue #770 — foundational `/harness-audit` creation (PR #775)
- Issue #791 — versionless model names + effort extension (PR #799)
- Issue #808 — CronCreate session-only correction (PR #825)
- Issue #827 — scheduler redesign (PR #867)
- PR #1053 — reporting merge that triggered this hotspot
- Sibling `*-hotspot-decision.md` files in `.claude/reference/`
