<!-- churn-hotspot: .claude/rules/main-hygiene.md -->
# Hotspot Decision — main-hygiene.md

**Verdict:** KEEP (no operative change)
**Decided:** 2026-08-10
**Issue:** #1154
**Reporter:** `/wrap` post-merge churn report (PR #1153)

Reference for Issue #1154 (`.claude/rules/main-hygiene.md` churn hotspot). Not auto-loaded.

## Churn summary

`churn-hotspots.sh` flagged `.claude/rules/main-hygiene.md` as touched by 3 distinct merged PRs
since 2026-07-27: PRs #804, #919, #1153.

| PR | Churn class | What changed |
|----|-------------|--------------|
| PR #804 | Corpus compression (Week 0) | Repo-wide 12,166 → 10,999 word compression sweep; one prose sentence shortened |
| PR #919 | Corpus compression (Week 1) | Repo-wide 430-word budget-freeing sweep; dirty-definition multi-line block compressed to one line; mechanism detail moved to `dirty-main-guard.md` |
| PR #1153 | Corpus compression (Week 2) | Repo-wide 110-word restoration of margin; one phrase removed from recovery-workflow sentence |

All three are confirmed corpus-slimming passes. Each is part of the recurring weekly cadence
established by Issue #796. Diffs verified via `git show` on commits 609452c, a6ebc39, efb5943.

## Diagnosis

The churn is single-cause with no recorded merge conflicts across all 3 PRs.

**All three touches are coordinated corpus-slimming passes (Issue #796 cadence).** PRs #804, #919,
and #1153 are the Week 0, Week 1, and Week 2 passes respectively of the standing weekly rule-corpus
compression effort. Each swept the full auto-loaded corpus and touched `main-hygiene.md` incidentally
because it held compressible prose at the time. None added semantic content; all reduced word count.

**The file is already minimal and correctly split.** At adjudication time the file is 24 lines and
292 words — well below the 2,000-word per-file warning. The policy/mechanism split is already in
place: `main-hygiene.md` holds the binding directives (when to run, what to do on dirty, recovery
rules), and `.claude/reference/dirty-main-guard.md` holds the mechanism detail (dirty-detection
logic, exit codes, output format, recovery-branch listing commands). There is no value-free
duplication with `safety.md` or `repo-bootstrap.md`.

**No split is warranted.** The file has a single topic: the dirty-main guard and its session-start
sequence. Its three sections (header/directives, Using the guard, Recovery workflow) map to one
coherent concern. The three touches are cross-file compression sweeps, not independent concern
growth.

**This churn class is expected to recur weekly.** Issue #796 is a recurring cadence (do-not-close).
Future weekly passes will continue to touch `main-hygiene.md` whenever it holds reclaimable prose.
That is by design. This cadence-class churn is not a re-filing trigger.

## Decision

**KEEP** `.claude/rules/main-hygiene.md` as the single canonical rule for the dirty-main guard.
Make no operative change.

All 3 PRs are confirmed corpus-slimming sweeps on the Issue #796 weekly cadence. The file is
already split correctly into rule (this file) plus mechanism (`dirty-main-guard.md`). No
duplication, no merge conflicts, and no independent concern growth was found.

Per `.claude/reference/churn-hotspots.md`, re-file this hotspot only when `conflict_rounds > 0`
or when 3+ non-cadence PRs touch the file — rising PR count from weekly compression passes alone
is not a re-filing trigger.

## Expected impact

None. No rule corpus files were changed. The corpus word count remains unchanged at the
pre-adjudication baseline.

## Related

- Issue #1154 — this hotspot filing (triggering issue)
- PR #804 — Week 0 corpus compression sweep (12,166 → 10,999 words)
- PR #919 — Week 1 corpus compression sweep (11,735 → 11,305 words; introduced `dirty-main-guard.md`)
- PR #1153 — Week 2 corpus compression sweep (11,459 → 11,349 words; triggering PR)
- Issue #796 — recurring weekly corpus-slimming cadence (do-not-close)
- `.claude/reference/dirty-main-guard.md` — mechanism doc: dirty-detection logic, exit codes, output format, recovery-branch commands
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic
