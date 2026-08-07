<!-- churn-hotspot: .claude/reference/script-extraction-audit.md -->
# Hotspot Decision — script-extraction-audit.md

**Verdict:** KEEP + caller-side `--exclude` at the `/wrap` call site
**Decided:** 2026-08-07
**Issue:** #1088
**Reporter:** `/wrap` post-merge churn report (PR #1086)

Reference for Issue #1088 (`.claude/reference/script-extraction-audit.md` churn hotspot). Not auto-loaded — the rule corpus carries none of this.

## Churn summary

`churn-hotspots.sh` flagged `.claude/reference/script-extraction-audit.md` as touched by 3
distinct merged PRs since 2026-07-24: PRs #798, #904, and #1004.

| PR | Title | Churn class | Sections affected |
|----|-------|-------------|-------------------|
| PR #798 | feat(#817): extend reply-thread.sh to support the codeant reviewer | Row update | C-09 row in P1 table — added `codeant` reviewer to the CLI signature and mention-stripping behavior |
| PR #904 | fix(#884): reply-thread.sh fallback exits 0, not 1 | Row update | C-09 row in P1 table — updated exit-code description after fallback exit-code fix |
| PR #1004 | refactor: extract pr-state jq filters | Multiple row updates | C-02 row (P0 table): marked extracted (Issue #275 / PR #302); "Existing Scripts" table: updated `fixpr/audit.sh` row from bypass surface to compatibility-wrapper description; bypass map item 1: struck through and resolved; recommended-extraction-order item 2: struck through; C-15 row: updated to reference canonical `.claude/scripts/lib/pr-state-classify.jq` |

## Per-section churn attribution (evidence)

### PR #798 — C-09 codeant reviewer extension (Issue #817)

PR #798 added `codeant` as a recognized reviewer value to `reply-thread.sh`, which strips
`@codeant-ai` mentions the way the script already strips `@cursor` and `@greptileai`.

The change to `script-extraction-audit.md` updated a single cell in the C-09 row of the P1
table:

- **CLI signature column**: added `codeant` to `--reviewer cr|bugbot|greptile|codeant`
- **Contract column**: added `@codeant-ai` to the strip rule; added plain-text note for
  CodeAnt mode

This is a status update to an existing inventory row — the kind of change the audit doc
explicitly anticipates as ongoing maintenance. Conflict rounds: 0.

### PR #904 — C-09 exit-code correction (Issue #884)

PR #904 fixed a `reply-thread.sh` bug where a successful fallback-path reply exited `1`
instead of `0`, causing `&&`-chains to treat a successfully posted comment as failure. The
exit semantics were clarified: exit `0` covers both inline and fallback paths; exit `1`
is now unused/reserved.

The change to `script-extraction-audit.md` updated the same C-09 contract cell:

- **Contract column**: replaced `0` inline / `1` fallback descriptions with `0` for
  either path, `1` listed as unused/reserved

This is a status correction to an inventory row — one cell changed to reflect the corrected
script behavior. Conflict rounds: 0.

### PR #1004 — C-02 extraction milestone (Issue #980)

PR #1004 was the largest of the three changes. Its primary work was extracting the two
pure jq programs from `pr-state.sh` into `lib/pr-state-classify.jq` and
`lib/pr-state-cr-split.jq` (Issue #980). As part of that work, several already-completed
extractions were recorded in the audit doc:

- **C-02 row (P0 table)**: changed from pending to extracted — marked `C-02 ✅`, updated
  the "Where it lives today" cell to describe the completed migration (Issue #275 / PR #302),
  and updated the CLI-signature cell to note that `--infer-candidates` and
  `--wait-state-eval` are additive later modes.
- **"Existing Scripts" table**: updated the `fixpr/audit.sh` row from "Major bypass
  surface" (describing what needed to be done) to "Backward-compatible wrapper for the
  shared PR-state snapshot" (describing the current state after C-02 completed).
- **Bypass map item 1**: struck through the original bypass description and replaced with
  the "Resolved by C-02" note.
- **Recommended extraction order item 2**: struck through the C-02 TODO and replaced
  with ✅ Done.
- **C-15 row**: updated to reference `.claude/scripts/lib/pr-state-classify.jq` as the
  canonical jq-program home (the program that was extracted in PR #1004 itself).

All five cell changes in PR #1004 are ledger updates — recording the completion of
work that the audit doc tracked as pending. Conflict rounds: 0.

## Diagnosis

The churn is single-lineage with no recorded merge conflicts across all 3 PRs.

**All 3 PRs follow the same pattern:** they make a change to an extraction script or
migrate a call site, then update the audit inventory to reflect the new state. The audit
doc is an ongoing ledger — its explicit scope statement is "Inventory and ranking only.
No code is extracted here — each P0 candidate gets its own follow-up implementation
issue." Every extraction PR that lands must update the inventory row for the extracted
candidate.

This is structurally identical to the pattern `.claude/reference/churn-hotspots.md`
documents as the canonical case for caller-side `--exclude`:

> This repo's `.claude/scripts/README.md` scores 12 PRs purely because every new script
> registers a row there, but that is a fact about this repo, not about lockfiles
> everywhere.

`.claude/reference/script-extraction-audit.md` is the same kind of append/update-only
ledger: every extraction PR that closes a pending candidate must update the audit row. The
PR count reflects the health of the extraction program, not refactoring debt.

**No split is warranted.** The P0/P1/P2 candidate tables, the "Existing Scripts" table,
the bypass map, and the recommended extraction order are all cross-referencing parts of
one inventory. Splitting the file would break the internal references and destroy the
coherence of the ranked-candidate structure.

**No dedup is warranted.** The candidate rows in this file describe the same candidates
that are implemented in `.claude/scripts/*.sh`, but the descriptions are the inventory
narrative — purpose, call sites, token estimates, priority rationale — not verbatim
copies of the scripts' own CLI-doc headers.

## Decision: KEEP + caller-side `--exclude`

**KEEP** `.claude/reference/script-extraction-audit.md` with no operative change.

**Apply** a caller-side `--exclude .claude/reference/script-extraction-audit.md` at the
`/wrap` Step 3.10a call site so the by-design ledger churn stops generating new hotspot
tickets.

The 3 reported touches are:

1. PR #798 — extraction C-09 status update (codeant reviewer extension)
2. PR #904 — extraction C-09 status correction (exit-code fix)
3. PR #1004 — extraction C-02 milestone record (multiple rows updated on C-02 completion)

All 3 builds on the audit doc's role as a living ledger: they record changes to the
extraction inventory as extractions complete. No merge conflicts across any of the 3 PRs.
No independent-owner churn. The per-PR count reflects the pace of the extraction program
(Issue #271), not a refactoring problem in the audit doc itself.

Per `.claude/reference/churn-hotspots.md`, re-file this hotspot only when
`conflict_rounds > 0` — the `--exclude` registered by this PR prevents re-filing
entirely for this path.

## Mechanism verification

Before applying the `--exclude`, the mechanism was verified:

- `churn-hotspots.sh --help` confirms `--exclude <globs>` accepts comma-separated globs
  to ignore in addition to the defaults.
- `.claude/reference/churn-hotspots.md` §Exclusions states: "Repo-specific by-design
  churn belongs in `--exclude`, not baked in: this repo's `.claude/scripts/README.md`
  scores 12 PRs purely because every new script registers a row there."
- The `/wrap` Step 3.10a call site is at line 557–561 of `wrap/SKILL.md`:
  `CHURN_JSON=$("$CHURN_SH" --json 2>/dev/null) || CHURN_RC=$?`
- No precedent exclude existed at that call site before this PR.

## What was explicitly preserved

- `## Audit Coverage` — scope, date, branch, file list, and prose-size note unchanged
- `## Summary` — bucket counts and estimated savings unchanged
- `## Existing Scripts` — all rows unchanged (one row's status-description updated by PR #1004, which this decision post-dates)
- `## Candidates` — all P0/P1/P2 rows unchanged (status cells updated by extraction PRs, not by this adjudication)
- `## Why these rankings` — P0/P1/P2 criteria unchanged
- `## Bypass call sites` — bypass map unchanged
- `## Recommended Extraction Order` — order unchanged
- `## Follow-up issue TODOs` — TODO list unchanged
- `## Audit methodology notes` — determinism/risk definitions unchanged

## Expected impact

None on the rule corpus. `script-extraction-audit.md` is not in the auto-loaded rule
corpus. The corpus word count remains unchanged.

The `/wrap` call-site edit adds `--exclude .claude/reference/script-extraction-audit.md`
to the `churn-hotspots.sh` invocation, which prevents this path from crossing the
threshold on future runs.

## Related

- `.claude/reference/script-extraction-audit.md` — the adjudicated file; living extraction-candidate ledger for Issue #271
- `.claude/scripts/churn-hotspots.sh` — read-only churn detector; `--exclude` is the documented mechanism for caller-side path suppression
- `.claude/reference/churn-hotspots.md` — mechanism reference; §Exclusions documents why repo-specific by-design churn belongs in `--exclude`
- `.claude/skills/wrap/SKILL.md` — call site where `--exclude` is added (Step 3.10a)
- Issue #1088 — this hotspot
- Issue #271 — script extraction audit creation (original inventory PR)
- PR #798 — C-09 codeant extension (first of 3 hotspot PRs)
- PR #904 — C-09 exit-code fix (second of 3 hotspot PRs)
- PR #1004 — C-02 extraction milestone (third of 3 hotspot PRs)
- PR #1086 — reporting merge that triggered this hotspot
