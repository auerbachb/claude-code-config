<!-- churn-hotspot: .github/scripts/verbatim-block-lint.sh -->
# Hotspot Decision — verbatim-block-lint.sh

**Verdict:** KEEP (no operative change)
**Decided:** 2026-08-08
**Issue:** #1136
**Reporter:** `/wrap` post-merge churn report (PR #1135)

## Churn summary

`churn-hotspots.sh` flagged `.github/scripts/verbatim-block-lint.sh` as touched by
3 distinct merged PRs since 2026-07-25: PR #801, PR #839, PR #1072.

| PR | Issue | Date | Section touched | What changed |
|----|-------|------|-----------------|--------------|
| PR #801 | #767 | 2026-07-30 | Full script creation | Created the file: VERBATIM_COPIES array, CANONICAL_FILES array, `require_file()` helper, `extract_block()` function, `canonical_src()` helper, main comparison loop, `usage()` — 187 lines |
| PR #839 | #805 | 2026-07-30 | `VERBATIM_COPIES` array + header comment | Retargeted copy surface from `.claude/skills/subagent/SKILL.md` to `.claude/reference/subagent-phase-guardrails.md` (+4/−4 lines); same 6 block entries, new path |
| PR #1072 | #1042 | 2026-08-07 | `require_file()` helper | Extracted `require_file()`/`require_pattern()` to `.github/scripts/lib/lint-common.sh`; replaced inline function with `source "$SCRIPT_DIR/lib/lint-common.sh"` (+4/−10 lines) |

**conflict_rounds == 0** across all three PRs. Each was a clean squash merge with no
conflict resolution.

## Per-section churn attribution (evidence)

Commits from `git log --oneline --follow -- .github/scripts/verbatim-block-lint.sh`:

```
1e52e6a  refactor(#1042): extract shared lint helpers to lib/lint-common.sh (#1072)
0de20b8  refactor(#805): extract SAFETY/MINDSET/SKILLS blocks to subagent-phase-guardrails.md (#839)
6023b6f  feat(#767): lint verbatim SAFETY/MINDSET/SKILLS blocks for cross-surface drift (#801)
```

**PR #801 (Issue #767) — initial creation:**
Created `.github/scripts/verbatim-block-lint.sh` as a new CI lint. The script
byte-compares the SAFETY, MINDSET, and SKILLS verbatim blocks across all declared
copy surfaces against their canonical sources in `.claude/rules/safety.md` and
`.claude/rules/skill-first.md`. Initial VERBATIM_COPIES pointed at
`.claude/skills/subagent/SKILL.md` and `.claude/skills/pr-monitor-and-manage/SKILL.md`
(6 block entries). Confirmed by `gh pr view 801 --json files`: `verbatim-block-lint.sh`
changeType `ADDED`.

**PR #839 (Issue #805) — copy-surface retarget:**
Issue #805 moved the verbatim-block home from `.claude/skills/subagent/SKILL.md` to
the new `.claude/reference/subagent-phase-guardrails.md`. The VERBATIM_COPIES array
had to follow: three `subagent/SKILL.md` entries were replaced with three
`subagent-phase-guardrails.md` entries. The header comment was updated to record the
new path. Zero behavior change — same 6 copy surfaces, same block count.
Confirmed by `gh pr view 839 --json files`: `verbatim-block-lint.sh` changeType
`MODIFIED` (+4/−4).

**Attribution note (CR plan discrepancy resolved):** The CR plan flagged a
`#805-versus-#839` discrepancy between the header comment in `verbatim-block-lint.sh`
(which reads `extracted from SKILL.md #805`) and `subagent-phase-guardrails-hotspot-decision.md`
(which credits PR #839). Investigation confirms no genuine conflict: `#805` in the
script comment is the issue number; `#839` in the hotspot doc is the PR number. Both
correctly identify the same change. The script header uses issue numbers throughout;
the hotspot doc uses PR numbers. No correction needed.

**PR #1072 (Issue #1042) — shared boilerplate extraction:**
Adjudicated the `chip-model-guard-lint.sh` churn hotspot (Issue #1042). As the
operative remedy, shared `require_file()`/`require_pattern()` boilerplate was
extracted from all four lint siblings (`chip-model-guard-lint.sh`,
`merge-authority-lint.sh`, `verbatim-block-lint.sh`, `env-template-allowlist-lint.sh`)
into `.github/scripts/lib/lint-common.sh`. For this script: the inline `require_file()`
function (~10 lines) was removed and replaced with `source "$SCRIPT_DIR/lib/lint-common.sh"`
(+4/−10 lines). Zero behavior change; `require_file()` return semantics were
standardized explicitly to `return 0` on success, but this was already the effective
behavior. Confirmed by `gh pr view 1072 --json files`: `lib/lint-common.sh` changeType
`ADDED`, `verbatim-block-lint.sh` changeType `MODIFIED`. Current script sources
`lib/lint-common.sh` at line 38.

## Diagnosis

This is **orthogonal-concern churn** across three non-competing edit surfaces:

1. **PR #801** created the script. This single burst accounts for the only significant
   line growth (187 lines). No subsequent PR altered the primary logic sections
   (`extract_block()`, `canonical_src()`, the main comparison loop).

2. **PR #839** touched only the `VERBATIM_COPIES` array — a table that is explicitly
   designed for one-line additions and removals (the script's own comment reads
   "One-line change to add or remove a copy surface"). This is the expected change
   pattern for adding or moving a copy surface.

3. **PR #1072** touched only the `require_file()` helper — an extraction that was
   the operative remedy for a sibling hotspot. The extraction was a cross-cutting
   concern affecting four scripts simultaneously; touching this script was required
   by the remedy, not by any defect in this script's design.

The three PRs had no contested edit surfaces: none stepped on another's change, and
no merge conflict arose. The file is 181 lines, single-concern, and in its final
structural form after PR #1072's extraction closed the one shared-boilerplate
concern.

## Decision: KEEP (no operative change)

**KEEP** `.github/scripts/verbatim-block-lint.sh` unchanged. Make no operative change.

The shared-boilerplate concern (the one structural issue that multiple PRs had in
common across the lint family) was already extracted to `.github/scripts/lib/lint-common.sh`
by PR #1072. That extraction closes the only remediation identified for this file.

The remaining unique logic consists of three cohesive parts that must co-exist in
one script:

- **`VERBATIM_COPIES` array** — the authoritative registry of which (block, file)
  pairs are byte-compared. One-line changes are expected when copy surfaces are
  added or moved; this is by design.
- **`extract_block()`** — the awk-based block extractor shared by both canonical
  and copy paths. Moving it to `lib/lint-common.sh` would add it to the shared API
  even though no sibling script needs it.
- **`canonical_src()`** — the SAFETY/MINDSET/SKILLS → rule-file router. Extracting
  this would require parameterizing a script-specific mapping that has no value
  outside this script.

All three parts form one linear pipeline: look up canonical source → extract
canonical block → for each declared copy, extract copy block → byte-compare.
A physical split would fragment this pipeline without reducing any change pressure.

## Rejected alternatives

**Split by pipeline stage** (canonical-source resolution, extraction, comparison):
Rejected. The three stages are tightly coupled — `canonical_src()` returns a path
consumed directly by `extract_block()`, which feeds directly into the byte comparison.
Splitting them would require a coordination file or shared state that adds more
complexity than the current co-location costs. The same reasoning rejected a split
of `chip-model-guard-lint.sh` (Issue #1042, `chip-model-guard-lint-hotspot-decision.md`).

**Extract `extract_block()`/`canonical_src()` to `lib/lint-common.sh`**: Rejected.
Neither function is shared by any sibling lint script. The `chip-model-guard-lint-hotspot-decision.md`
decision record explicitly called out `extract_block()` as unique to `verbatim-block-lint.sh`
and not warranting extraction. That assessment holds — the function signature and awk
implementation are specific to the SAFETY/MINDSET/SKILLS block format.

**Plain documented no-op (no extraction at all)**: Not applicable. PR #1072
already applied the correct extraction (shared boilerplate). There is nothing left
to extract.

## What was explicitly preserved

- **`SAFETY:`/`MINDSET:`/`SKILLS:` canonical-source map** — `canonical_src()` routes
  block names to their source rule files; this routing is script-unique and unchanged.
- **`VERBATIM_COPIES` surfaces** — the declared registry of byte-verified copy
  surfaces; currently `.claude/reference/subagent-phase-guardrails.md` and
  `.claude/skills/pr-monitor-and-manage/SKILL.md` (6 entries).
- **`::error file=…::` annotation format** — GitHub Actions error annotations
  emitted by `require_file()` (via `lib/lint-common.sh`) and inline in the main loop;
  format unchanged.
- **Exit-1-on-error behavior** — the script exits with `exit "$errors"` after the
  comparison loop; non-zero exits fail the CI step.
- **`rule-lint` job-id status-check name** — the script runs as a step in
  `rule-lint.yml` and its pass/fail contributes to the `rule-lint` required status
  check; the job-id is unchanged.
- **`lib/lint-common.sh` sourcing** — the `source "$SCRIPT_DIR/lib/lint-common.sh"`
  line added by PR #1072 is the ongoing connection to the shared helper library.

## Future reconsideration

Per `.claude/reference/churn-hotspots.md`, re-file this hotspot only when
`conflict_rounds > 0`. A rising PR count tracking new copy surfaces or canonical
rule file updates is not a re-filing trigger; only a conflict (two PRs stepping on
each other's VERBATIM_COPIES entries or on `extract_block()`) would indicate a
structural problem worth revisiting.

## Related

- Issue #1136 — this hotspot ticket
- Issue #767 — initial creation (PR #801)
- Issue #805 — copy-surface retarget to subagent-phase-guardrails.md (PR #839)
- Issue #1042 — shared lint boilerplate extraction into `lint-common.sh` (PR #1072); CLOSED
- Issue #1134 — sibling test-file hotspot ticket (PR #1145, `verbatim-block-lint-test-hotspot-decision.md`)
- `.github/scripts/verbatim-block-lint.sh` — the adjudicated file
- `.github/scripts/lib/lint-common.sh` — shared helper library (added by PR #1072)
- `.claude/reference/subagent-phase-guardrails.md` — current verbatim-block copy surface
- `verbatim-block-lint-test-hotspot-decision.md` — sibling test-file adjudication (KEEP, Issue #1134); same PR family (PR #801, PR #839); consistent verdict
- `chip-model-guard-lint-hotspot-decision.md` — sibling lint script adjudication; extract-not-split precedent; explicitly called out `extract_block()` as not warranting extraction
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic
