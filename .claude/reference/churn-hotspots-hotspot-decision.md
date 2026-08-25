<!-- churn-hotspot: .claude/reference/churn-hotspots.md -->
# Hotspot Decision — churn-hotspots.md

**Verdict:** KEEP (no operative change)
**Decided:** 2026-08-07
**Issue:** #1081
**Reporter:** `/wrap` post-merge churn report (PR #1080)

Reference for Issue #1081 (`.claude/reference/churn-hotspots.md` churn hotspot). Not auto-loaded — the rule corpus carries none of this.

## Churn summary

`churn-hotspots.sh` flagged `.claude/reference/churn-hotspots.md` as touched by 3 distinct
merged PRs since 2026-07-24: PRs #766, #882, and #925.

| PR | Title | Churn class | Sections affected |
|----|-------|-------------|-------------------|
| PR #766 | feat(#755): detect multi-PR file churn and auto-file refactor-candidate issues | New file creation | All sections (file did not exist before this PR) |
| PR #882 | fix(#861): scope churn scan to the default branch, not the invoking HEAD | Bug-fix documentation | "Enumeration: git first, gh as fallback" — added `--ref`/HEAD scoping narrative |
| PR #925 | fix(#915): surface closed hotspot issues so /wrap stops re-filing them | Bug-fix documentation | "Why `/wrap` files at most one per run" + "The dedup key" — added closed-match eligibility/conflict-gate narrative |

## Per-section churn attribution (evidence)

### PR #766 — File creation (Issue #755)

PR #766 introduced the churn-hotspot detector (`churn-hotspots.sh`) and wired `/wrap`
Step 3.10a to file one refactor-candidate issue per run against the top hotspot. The
reference doc `churn-hotspots.md` was authored in the same PR as the canonical narrative
companion — it did not exist beforehand.

PR #766 created the complete file (94 lines) covering:

- "The problem being read" — motivation and the hook-scripts.yml/issue #671 precedents
- "Division of responsibility" — script is read-only; mutations live in `/wrap`
- "The score" — formula, conflict-weight rationale, `distinct_pr_count >= 2` floor
- "Calibration" — threshold table (63/33/16/9 files at thresholds 3/5/8/10)
- "Why `/wrap` files at most one per run" — original single-condition eligibility
- "Enumeration: git first, gh as fallback" — git-path primary, gh-path fallback
- "Exclusions" — universal lockfile/CHANGELOG default list
- "The dedup key" — delegates to `autofile-dedup.md` as canonical, with one-paragraph summary
- "Implementation notes" — ASCII-sentinel parser, `grep -c` counter pitfall

This is authorship, not independent iteration on existing content. Conflict rounds: 0.

### PR #882 — Scan-ref scoping documentation (Issue #861)

PR #882 fixed a bug in `churn-hotspots.sh` where `git log` ran against the invoking
worktree's `HEAD` rather than the default branch. From a feature-branch worktree, that
`HEAD` was wrong in both directions: it missed squash commits merged to main since the
branch forked, and it included unsquashed local commits that would never exist on main.
Measured on two live worktrees: one scan missed 7 merged PRs and 5 hotspots; the other
invented a phantom PR inflating 13 files.

PR #882's change to `churn-hotspots.md` extended the "Enumeration: git first, gh as
fallback" section with narrative documenting the fix:

- Added the `--ref`/HEAD bug rationale paragraph (why invoking worktree's HEAD is wrong
  in both directions, with measured evidence)
- Added the ref resolution order (`--ref` → `origin/HEAD` → `origin/main` → `origin/master`
  → `main` → `master`) and the exit-3 / stderr-fallback behavior
- Added the `--fetch` opt-in rationale (read-only by default; blocking fetch inside
  `/wrap` is a hazard)
- Added the "trailing `(#N)` marker only" clarification (a leading `type(#N):` prefix is
  an issue reference, not a PR reference; this was the root cause the stricter rule fixed)
- Added the `--source auto` fallback-to-gh explanation for a history the stricter rule
  empties out

This is the canonical prose rationale for the script change — the kind of "why" content
that cannot live in the script's terse CLI-doc header. Conflict rounds: 0.

### PR #925 — Closed-match and conflict-gate documentation (Issue #915)

PR #925 fixed a bug where `churn-hotspots.sh` used `--state open` for the hotspot issue
lookup, making already-reviewed-and-closed hotspot issues invisible. `/wrap` read
`existing_hotspot_issue: null`, treated the path as never-ticketed, and re-filed it on
every subsequent wrap — indefinitely. The fix had already produced one duplicate in this
repo (Issue #815 closed, Issue #881 open for the same file) and had two more queued in a
sibling repo before the pattern was noticed.

PR #925's change to `churn-hotspots.md` updated two sections:

**"Why `/wrap` files at most one per run"** — rewrote the eligibility paragraph from
the original single-condition form ("the highest-scoring hotspot with no existing issue")
to the two-condition form (no existing issue OR closed match with `conflict_rounds > 0`).
Added the "Why the conflict gate, specifically" paragraph explaining why a closed hotspot
re-files only on conflict cost: closing an observational churn report is a recorded owner
decision, and rising PR count alone does not override it. Added the "Comment idempotency"
clarification that the comment set is open-only.

**"The dedup key"** — added three paragraphs documenting the corrected lookup behavior:
(1) `--state all` replaces `--state open` and why; (2) `existing_hotspot_issue_state`
field semantics (`open`/`closed`/`unknown`/null); (3) open-beats-closed preference; (4)
the capped-lookup still fails safe.

This is bug-fix documentation recording corrected behavior for a reader of the reference
doc. Conflict rounds: 0.

## Diagnosis

The churn is single-lineage with no recorded merge conflicts across all 3 PRs.

**PR #766 is the foundational file creation.** The reference doc did not exist before this
PR. The file was authored as the narrative companion to the new `churn-hotspots.sh` script
and `/wrap` Step 3.10a, carrying the "why" rationale that the script's terse CLI-doc
header cannot hold.

**PR #882 is bug-fix documentation.** The `--ref`/HEAD scoping fix in the script was
non-obvious enough (the bug was in both directions simultaneously, measurably different
across worktrees) that the reference doc needed prose explaining the mechanism and the
evidence for the fix. The script header summarizes the resolution order; the reference
doc records why each step in the order matters and what happens at each failure mode.

**PR #925 is bug-fix documentation.** The closed-match/conflict-gate change is similarly
non-obvious (a closed issue is now a weak-match candidate rather than a blank slate, with
a deliberate exception: a closed hotspot only re-files when it has accrued conflict cost,
not on PR count alone). Both the "eligibility" section and the "dedup key" section needed
updating because both described the old single-condition behavior.

**No dedup is warranted.**

The CR plan suggested verifying two candidate dedup targets:

1. **`churn-hotspots.sh` inline header (lines 1–184)** — the script header uses terse
   CLI-doc style (imperative bullets, abbreviated rationale). The reference doc's score,
   calibration, and enumeration sections carry substantial "why" prose that does not appear
   in the script header at all: why conflict rounds are weighted at 2, why the
   `distinct_pr_count >= 2` floor exists, why conflict rounds cannot manufacture a hotspot
   alone, the worktree measurement evidence for the HEAD bug, why `--fetch` is opt-in. The
   calibration table numbers appear in both (63/33/16/9 at thresholds 3/5/8/10), but the
   reference doc's table includes headers and context; the script comment is a
   parenthetical. No verbatim duplication; the reference doc expands on the script header
   rather than restating it.

2. **`.claude/reference/autofile-dedup.md`** — `churn-hotspots.md`'s "The dedup key"
   section explicitly delegates to `autofile-dedup.md` as canonical: "Full rationale and
   the contract live in `autofile-dedup.md` under 'Exact-artifact dedup'. In short: ..."
   followed by a one-paragraph orientation summary. The `autofile-dedup.md` record
   (`autofile-dedup-hotspot-decision.md`, Issue #1076) confirms this: "The 'The dedup key'
   section in `churn-hotspots.md` says: 'Full rationale and the contract live in
   `autofile-dedup.md`...' The summary is a pointer + one-sentence restatement for reader
   orientation, not verbatim duplication. `autofile-dedup.md` is the canonical source;
   `churn-hotspots.md` delegates to it." No dedup needed — the delegation pointer is the
   correct pattern.

## Cross-reference with autofile-dedup-hotspot-decision.md (Issue #1076)

PRs #766 and #925 appear in both hotspot windows (this file and `autofile-dedup.md`). The
attribution in both decision records is consistent:

| PR | In this record | In Issue #1076 record |
|----|---------------|----------------------|
| PR #766 | Created `churn-hotspots.md` entirely | Created "Exact-artifact dedup" section in `autofile-dedup.md` |
| PR #925 | Updated eligibility + dedup-key sections in `churn-hotspots.md` | Added 2 clarifying bullet points to "Exact-artifact dedup" in `autofile-dedup.md` |

The same PR touching both files is expected: a bug fix to the lookup behavior must update
both the mechanism's reference doc and the dedup contract that governs the lookup. The two
files are related but distinct: `churn-hotspots.md` is the narrative reference for the
churn-hotspot *detector*; `autofile-dedup.md` is the contract governing *all* autonomous
exact-artifact dedup across multiple filers. No inconsistency in attribution.

## Decision: KEEP

**KEEP** `.claude/reference/churn-hotspots.md` with no operative change.

The 3 reported touches are:
1. PR #766 — foundational file creation (new reference doc for the churn-hotspot detector)
2. PR #882 — bug-fix documentation (HEAD scoping fix, Issue #861)
3. PR #925 — bug-fix documentation (closed-match semantics, Issue #915)

All 3 PRs build on the same reference doc in the same direction: authoring and then
maintaining the canonical narrative rationale for a system whose behavior changed twice
after initial release. No merge conflicts across any of the 3 PRs. No independent-owner
churn. The content that appears similar to the script header is the "why" prose the
script header cannot carry; the content that overlaps with `autofile-dedup.md` is already
delegated via an explicit pointer.

The KEEP verdict is consistent with the CR plan's fallback option and the autofile-dedup
record's conclusion that `churn-hotspots.md` already delegates correctly to `autofile-dedup.md`.

Per `.claude/reference/churn-hotspots.md`, re-file this hotspot only when
`conflict_rounds > 0` — a rising PR count on a living operational reference doc is not a
re-filing trigger.

## What was explicitly preserved

- `## The problem being read` — motivation section unchanged; foundational context
- `## Division of responsibility` — read-only detector / mutating `/wrap` split unchanged
- `## The score` — formula, conflict-weight rationale, `>= 2` floor rationale unchanged
- `## Calibration` — threshold table and active-repo tuning guidance unchanged
- `## Why /wrap files at most one per run` — eligibility, conflict gate, comment idempotency unchanged
- `## Enumeration: git first, gh as fallback` — all ref-resolution, fetch, marker, fallback prose unchanged
- `## Exclusions` — universal lockfile/CHANGELOG list and rationale unchanged
- `## The dedup key` — delegation pointer to `autofile-dedup.md` + orientation summary unchanged
- `## Implementation notes` — ASCII-sentinel, `grep -c` counter pitfalls unchanged
- `## Related` — issue cross-references unchanged

## Expected impact

None. `churn-hotspots.md` is not in the auto-loaded rule corpus. The corpus word count
remains unchanged.

## Related

- `.claude/reference/churn-hotspots.md` — the adjudicated file; canonical narrative reference for `churn-hotspots.sh`
- `.claude/scripts/churn-hotspots.sh` — read-only churn detector; terse CLI-doc header is the script-audience companion to this reference doc
- `.claude/reference/autofile-dedup.md` — canonical contract for autonomous issue dedup; "The dedup key" section in `churn-hotspots.md` delegates to it
- `.claude/reference/autofile-dedup-hotspot-decision.md` — sibling decision (Issue #1076); confirms PRs #766 and #925 attribution in both windows is consistent
- `.claude/reference/fixpr-hotspot-decision.md` — structural precedent for the extract-not-split direction (extraction removes per-PR edit surface; junction contracts stay intact)
- `.claude/reference/session-state-schema-hotspot-decision.md` — precedent for KEEP on a living operational contract
- Issue #1081 — this hotspot
- Issue #755 — churn-hotspot detector creation (PR #766)
- Issue #861 — `--ref`/HEAD scoping bug (PR #882)
- Issue #915 — closed-hotspot re-filing bug (PR #925)
- PR #1080 — reporting merge that triggered this hotspot

## Issue #1307 addendum — aggregate closed/no-cost findings

Issue #1307 does not change this file's KEEP verdict or the detector. It changes the
`/wrap` consumer so a closed hotspot with zero conflict cost no longer becomes the same
pending decision on every session. Those findings are now counted in one verbose
aggregate and remain individually inspectable in `churn-hotspot-wrap-plan.sh` output.

The recorded verdict returns for review only after measurable new evidence: any positive
`conflict_rounds`, or a current score at least 2× the score captured in
`churn-hotspot-baselines.json`. The latter is a material centrality change, not ordinary
linear growth. This preserves Issue #915's closed-match visibility while respecting the
owner's no-action decision instead of repeatedly asking for it.
