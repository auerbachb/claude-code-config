<!-- churn-hotspot: .github/scripts/tests/verbatim-block-lint.test.sh -->
# Hotspot Decision — verbatim-block-lint (test)

**Verdict:** KEEP (no operative change)
**Decided:** 2026-08-08
**Issue:** #1134
**Reporter:** `/wrap` post-merge churn report (PR #1133)

## Churn summary

`churn-hotspots.sh` flagged `.github/scripts/tests/verbatim-block-lint.test.sh` as
touched by 3 distinct merged PRs since 2026-07-25: PR #801, PR #817, PR #839.

All three PRs landed on the same day (2026-07-30) during a coordinated construction
burst that created the verbatim-block-lint subsystem and then hardened it twice within
hours.

| PR | Issue | Date | What changed |
|----|-------|------|--------------|
| PR #801 | #767 | 2026-07-30 | Created the file: 99-line initial suite with `make_fixture()`, `expect()`/`noop()` harness, and 4 fixture cases (clean pass, drifted copy, missing file, missing block) plus a real-repo conformance check |
| PR #817 | #810 | 2026-07-30 | Fixed the drift fixture: introduced `DRIFT_TOKEN` with a uniqueness guard; the prior `sed` targeted "capability ladder" which was removed from the MINDSET block by that same PR, so the negative test was silently passing for the wrong reason (#810) |
| PR #839 | #805 | 2026-07-30 | Retargeted fixtures from `.claude/skills/subagent/SKILL.md` to `.claude/reference/subagent-phase-guardrails.md` after that PR moved the verbatim-block home; updated `make_fixture()`, the `DRIFT_TOKEN` guard loop, and the `expect` description |

**Attribution verified from full git history** (`git log --oneline --follow`) and confirmed
against each PR's `Closes #N` keyword. The `#817` reference in the corpus is the PR number;
the closed issue is #810.

## Per-section churn attribution (evidence)

Commits from `git log --oneline --follow -- .github/scripts/tests/verbatim-block-lint.test.sh`:

```
0de20b8  refactor(#805): extract SAFETY/MINDSET/SKILLS blocks to subagent-phase-guardrails.md (#839)
94be40a  fix(#810): fire the capability ladder on deferral, not on "impossible" (#817)
6023b6f  feat(#767): lint verbatim SAFETY/MINDSET/SKILLS blocks for cross-surface drift (#801)
```

**PR #801 (Issue #767) — initial creation:**
Created `.github/scripts/tests/verbatim-block-lint.test.sh` as the test companion
to `verbatim-block-lint.sh`. The suite covered: (a) clean repo passes, (b) drifted
MINDSET copy fails naming file/block, (c) missing copy file fails, (d) missing block
within copy file fails. Also included a real-repo conformance check as case (e). The
drift fixture used `sed` targeting the literal string "capability ladder" in the copy
file (`subagent/SKILL.md`).

**PR #817 (Issue #810) — drift fixture correctness fix:**
The MINDSET block rewrite in Issue #810 removed "capability ladder" from the block,
making the `sed` in the drift fixture a no-op — the negative test was passing for the
wrong reason. PR #817 replaced the hard-coded string with `DRIFT_TOKEN='ANY provider'`
and added a uniqueness guard (`grep -o -F` count check) to ensure the token appears
exactly once in the copy file, so any future reword that removes uniqueness causes the
guard to fail loudly rather than silently. This added ~27 lines to the test.

**PR #839 (Issue #805) — copy-surface retargeting:**
Issue #805 moved the verbatim-block home from `.claude/skills/subagent/SKILL.md` to
`.claude/reference/subagent-phase-guardrails.md`. The test had to follow: `make_fixture()`
directory creation (`subagent/` → `reference/`), the `cp` source path, the `DRIFT_TOKEN`
guard loop target, and the `expect` description string were all updated. Zero behavior
change — the same 4 fixture cases exercise the same code paths against the new path.

**conflict_rounds == 0 across all 3 PRs.** All three landed the same day in commit order
(creation → fix → retarget); no PR required a merge-conflict resolution.

## Diagnosis

This is **construction-burst churn** — three coordinated PRs that built and immediately
hardened the same subsystem in a single day. The pattern matches the
"create, then extend contract coverage twice" shape of other KEEP-verdict test hotspots
in this family.

**Why not split:** The file is the smallest in its test family (126 lines vs 137, 174,
and 182 for siblings). It has one cohesive responsibility: extract declared verbatim
block/file pairs, compare byte-for-byte, and report drift. The 4 fixture cases cover
orthogonal failure modes of the same contract. No independently evolving seam exists
that would motivate a split.

**Why not extract `make_fixture()`/`expect()` into a shared library:** The same duplicated
fixture idiom (`make_fixture()`, `expect()`, `noop()`) exists across sibling lint tests
(`merge-authority-lint.test.sh`, `env-template-allowlist-lint.test.sh`,
`skill-catalog-lint.test.sh`, `chip-model-guard-lint.test.sh`). None of those have been
extracted. The companion `chip-model-guard-lint-test-hotspot-decision.md` (Issue #1044)
reached the same conclusion for the same family: the `mutate()`/`expect()` API surface
differs across siblings, and the `chip-model-guard-lint.test.sh` holds a `mutate()` no-op
guard absent from this file. Extraction would require API reconciliation adding more
complexity than the current per-file duplication costs. Note: the shared production-side
boilerplate (`require_file()`/`require_pattern()`) was already extracted into
`.github/scripts/lib/lint-common.sh` by Issue #1042 (PR #1072); no further
extraction applies here.

**Coverage observation (not a churn cause):** The `pr-monitor-and-manage/SKILL.md` copy
surface in `VERBATIM_COPIES` (added by original creation) has no dedicated negative-test
fixture, unlike the `subagent-phase-guardrails.md` surface. The real-repo conformance
check exercises it passively but no drift-injection test targets it specifically. This
is a future coverage gap to address, not a structural defect driving churn.

## Decision: KEEP (no operative change)

**KEEP** `.github/scripts/tests/verbatim-block-lint.test.sh` unchanged. Make no
operative change to the test file.

The 3-PR churn is construction-burst churn on a newly created subsystem. All three PRs
landed the same day; the test file grew from creation (PR #801) to a correctness fix
(PR #817) to a retarget following its companion script (PR #839). No structural defect
is present: the file is small, single-responsibility, and conflict-free across all
three touches.

Per `.claude/reference/churn-hotspots.md`, re-file this hotspot only when
`conflict_rounds > 0`. A rising PR count tracking contract evolution or copy-surface
changes is not a re-filing trigger; only a conflict (two PRs stepping on each other's
fixtures) would indicate a structural problem.

## Expected impact

None; this file is not in the auto-loaded rule corpus. It runs only under the
`hook-scripts.yml` CI auto-discovery glob and is transparent to production behavior.

## Related

- Issue #1134 — this hotspot ticket
- Issue #767 — initial creation of verbatim-block-lint (PR #801)
- Issue #810 — drift fixture correctness fix (PR #817)
- Issue #805 — copy-surface retarget to subagent-phase-guardrails.md (PR #839)
- Issue #1042 — shared lint boilerplate extraction into `lint-common.sh` (PR #1072); CLOSED
- `chip-model-guard-lint-test-hotspot-decision.md` — sibling test adjudication (KEEP, Issue #1044); identical extract-not-split conclusion for the same test family
- `chip-model-guard-lint-hotspot-decision.md` — sibling lint script adjudication; extract-not-split precedent
- `.github/scripts/tests/verbatim-block-lint.test.sh` — the adjudicated file
- `.github/scripts/verbatim-block-lint.sh` — the lint script this file tests
- `.claude/reference/subagent-phase-guardrails.md` — current verbatim-block copy surface
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic
