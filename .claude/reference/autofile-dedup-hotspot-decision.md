<!-- churn-hotspot: .claude/reference/autofile-dedup.md -->
# Hotspot Decision — autofile-dedup.md

**Verdict:** KEEP (no operative change)
**Decided:** 2026-08-07
**Issue:** #1076
**Reporter:** `/wrap` post-merge churn report (PR #1075)

## Churn summary

`churn-hotspots.sh` flagged `.claude/reference/autofile-dedup.md` as touched by 3 distinct
merged PRs since 2026-07-28: PRs #766, #775, and #925.

| PR | Title | Churn class | Sections affected |
|----|-------|-------------|-------------------|
| PR #766 | feat(#755): detect multi-PR file churn and auto-file refactor-candidate issues | New filer + contract creation | Filer inventory (new row) + new "Exact-artifact dedup" section |
| PR #775 | feat(#770): add /harness-audit | New filer extension | Filer inventory (new row) + "Exact-artifact dedup" section extended |
| PR #925 | fix(#915): surface closed hotspot issues so /wrap stops re-filing them | Bug fix / contract clarification | "Exact-artifact dedup" section (two new bullet points) |

## Per-section churn attribution (evidence)

### PR #766 — Exact-artifact dedup section creation (Issue #755)

PR #766 introduced the churn-hotspot detector (`churn-hotspots.sh`) and wired
`/wrap` Step 3.10a to file one refactor-candidate issue per run against the
top hotspot. Because this new filer keys on an exact file path rather than
fuzzy prose, the existing `issue-dedup.sh` ladder was the wrong instrument.

PR #766's change to `autofile-dedup.md` was the dedup contract for this new
filer:

- Added a filer inventory row: "`.claude/skills/wrap/SKILL.md` (Phase 3, Step 3.10a
  — churn hotspots) | Autonomous | Exact-match on a path key, not strong/weak/none
  — see 'Exact-artifact dedup' below (issue #755)"
- Added the complete "Exact-artifact dedup (the narrow complement — issue #755)"
  section, defining title convention (`Refactor hotspot: <path>`), body marker
  (`<!-- churn-hotspot: <path> -->`), client-side exact comparison, and the
  failed-lookup-blocks-filing rule

This is authorship of the section, not independent iteration on existing content.
Conflict rounds: 0.

### PR #775 — /harness-audit extension (Issue #770)

PR #775 introduced `/harness-audit`, a second filer that keys on an audited
artifact path rather than a churn file path. The exact-artifact dedup mechanism
in `autofile-dedup.md` was the right contract for it too, requiring the section
to generalize from one filer to two.

PR #775's change to `autofile-dedup.md`:

- Added a filer inventory row: "`.claude/skills/harness-audit/SKILL.md` (Step 7)
  | Autonomous | Exact-artifact on the audited path — see 'Exact-artifact dedup'
  below (issue #770)"
- Added the "A second category joined it in #770" paragraph explaining `/harness-audit`'s
  identical failure modes
- Generalized the three bullet points (title convention, body marker, search command)
  from `/wrap`-only to covering both filers, e.g.:
  - "Title convention — `Refactor hotspot: <path>` (`/wrap`) or `Harness redundancy: <path>`
    (`/harness-audit`), matched with string equality"
  - Search commands for both filers added
  - Grouped-issue marker note added

This is additive extension of one contract to a second instantiation, not a new
concern. Conflict rounds: 0.

### PR #925 — Closed-match / conflict gate clarification (Issue #915)

PR #925 fixed a bug where `churn-hotspots.sh` used `--state open` for the hotspot
issue lookup, making already-reviewed-and-closed hotspot issues invisible. The
caller read `existing_hotspot_issue: null`, treated the path as never-ticketed,
and re-filed it on every subsequent wrap.

PR #925's change to `autofile-dedup.md` added two bullet points to the
"Exact-artifact dedup" section documenting the corrected behavior:

1. "**The churn lookup searches `--state all`, and a closed match is a weak match**
   (issue #915)." — explains the new closed-match semantics, the `existing_hotspot_issue_state`
   field, open-preference when both states match, and the Possibly-duplicates caveat for
   closed matches.

2. "**The churn path gates that re-file on conflict cost — a deliberate exception to the
   generic weak/closed rule above.**" — records that a closed churn hotspot re-files
   only when `conflict_rounds > 0`; rising PR count alone does not override a recorded
   owner decision.

The PR body notes: "/harness-audit has searched `--state all` and branched on open-vs-closed
since #770, so this is the two exact-artifact filers converging, not a new rule."

This is a bug-fix clarification of one section's mechanics, not an independent concern.
Conflict rounds: 0.

## Diagnosis

The churn is single-lineage with no recorded merge conflicts across all 3 PRs.

**PR #766 is the foundational section creation.** The "Exact-artifact dedup" section
did not exist before this PR. The change authored the complete section in response to
the churn-hotspot filer needing an exact-match dedup contract.

**PR #775 is additive generalization.** The new `/harness-audit` filer used the identical
mechanism, so the section was extended from one instantiation to two. The three bullet points
were widened in place; no restructuring occurred. PR #775 touched `autofile-dedup.md` as
one of several filer-inventory and contract documents it updated (also `harness-audit.md`,
`chip-launching.md`, `chip-model-guard-decision.md`).

**PR #925 is a bug-fix contract clarification.** The `--state open` lookup silently
dropped closed hotspot issues, causing re-filings forever. The two new bullet points
document the corrected behavior and the deliberate exception for conflict-gated re-files.

**No split is warranted.** `autofile-dedup.md` is a single-topic contract: the rules
governing when autonomous `gh issue create` calls suppress, weaken, or file a finding.
Both sub-mechanisms — the fuzzy strong/weak/none ladder and the exact-artifact narrow
complement — share one filer inventory, one asymmetry rule, one "never silent" obligation,
and one "Why this exists" rationale. Section names are cited by consumers
(`/wrap`'s Step 3.10a, `/harness-audit`'s Step 7, `churn-hotspots.md`'s dedup-key section,
`issue-dedup.sh --help`). The file is not auto-loaded into the rule corpus, so its
length does not consume the corpus budget.

## Dedup check vs canonical sources

The CR plan suggested verifying for verbatim duplication against canonical owners.

**`issue-dedup.sh --help`** — The script's help text says "It deliberately does NOT
decide whether a candidate is a duplicate — that judgment (strong / weak / none)
belongs to the caller and is specified in `.claude/reference/autofile-dedup.md`."
The script points to `autofile-dedup.md` as canonical; `autofile-dedup.md` does not
restate the script's implementation.

**`churn-hotspots.md`** — The "The dedup key" section in `churn-hotspots.md` says:
"Full rationale and the contract live in `autofile-dedup.md` under 'Exact-artifact dedup'.
In short: ..." followed by a brief summary. The summary is a pointer + one-sentence
restatement for reader orientation, not verbatim duplication. `autofile-dedup.md` is the
canonical source; `churn-hotspots.md` delegates to it.

**`harness-audit-skill-hotspot-decision.md` overlap characterization** — That decision
record (Issue #1054) identified a "Step 7 vs `autofile-dedup.md`" partial overlap,
specifically three generic principles (failed-lookup-blocks-filing, never-silent, same-run
batch self-check) that overlap. It concluded: "Step 7 ALREADY points to `autofile-dedup.md`
as the canonical source... The remaining prose in Step 7 is the harness-audit-specific
implementation layer on top of that contract." This is consistent with the verdict here:
`autofile-dedup.md` owns the generic principles; SKILL.md's Step 7 owns the
harness-audit-specific implementation layer. No dedup applies in either direction.

**Conclusion:** No verbatim duplication found. `autofile-dedup.md` is the canonical owner
of the dedup contract; its canonical sources either point to it or describe their own
implementation layers on top of it.

## Decision

**KEEP** `.claude/reference/autofile-dedup.md` with no operative change.

The 3 reported touches are: 1 foundational section creation (PR #766, exact-artifact
dedup for the churn-hotspot filer) + 1 additive generalization (PR #775, extending to
the `/harness-audit` filer) + 1 bug-fix clarification (PR #925, closed-match semantics
and conflict gate exception). All 3 PRs built on the same section in the same direction.
No merge conflicts across any of the 3 PRs. No independent-owner churn.

The CR plan's KEEP verdict is confirmed. No verbatim duplication warrants a dedup edit.

Per `.claude/reference/churn-hotspots.md`, re-file this hotspot only when
`conflict_rounds > 0` — a rising PR count on a living operational contract is not a
re-filing trigger.

## Expected impact

None. `autofile-dedup.md` is not in the auto-loaded rule corpus. The corpus word count
remains unchanged.

## Related

- `.claude/reference/autofile-dedup.md` — the adjudicated file; canonical contract for autonomous issue dedup
- `.claude/reference/churn-hotspots.md` — mechanism and calibration for `churn-hotspots.sh`; delegates dedup key section to `autofile-dedup.md`
- `.claude/reference/harness-audit-skill-hotspot-decision.md` — sibling decision (Issue #1054); Step 7 vs `autofile-dedup.md` partial overlap identified and left in place (existing pointer covers generic principles; SKILL.md owns implementation layer)
- `.claude/reference/harness-audit.md` — `/harness-audit` design record; second filer using exact-artifact dedup
- `.claude/scripts/issue-dedup.sh` — fuzzy dedup helper; its `--help` points to `autofile-dedup.md` as canonical
- `.claude/scripts/churn-hotspots.sh` — read-only churn detector; exact-artifact lookup documented in `autofile-dedup.md`
- Issue #1076 — this hotspot
- Issue #755 — churn-hotspot filer creation (PR #766)
- Issue #770 — `/harness-audit` creation (PR #775)
- Issue #915 — closed-hotspot re-filing bug (PR #925)
- PR #1075 — reporting merge that triggered this hotspot
