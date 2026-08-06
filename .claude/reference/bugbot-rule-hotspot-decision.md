<!-- churn-hotspot: .claude/rules/bugbot.md -->
# Hotspot Decision — bugbot.md

**Verdict:** KEEP (no operative change)
**Decided:** 2026-08-06
**Issue:** #1036
**Reporter:** `/wrap` post-merge churn report (PR #1035)

## Churn summary

`churn-hotspots.sh` flagged `.claude/rules/bugbot.md` as touched by 5 distinct merged PRs
since 2026-07-30: PRs #804, #849, #903, #919, #1013.

| PR | Churn class | What changed |
|----|-------------|--------------|
| PR #804 | Corpus compression | Repo-wide 12,166 → 10,999 word compression sweep; bugbot.md touched incidentally |
| PR #849 | Policy add — reviewer path | Accept `Cursor Bugbot` success check-run as a clean merge-gate pass for the silent-pass shape (Issue #844) |
| PR #903 | Policy add — trigger mechanism | Add PAT requirement to Always-trigger note; document that BugBot ignores bot-authored triggers; update Re-Reviews to state BugBot does not auto-review pushes (Issue #892) |
| PR #919 | Corpus compression | Repo-wide 430-word budget-freeing compression sweep; bugbot.md touched incidentally |
| PR #1013 | Dedup cleanup | Compressed `bugbot.md` §Merge Gate to a pointer-only assertion after the cr-merge-gate targeted-dedup decision (Issue #940); "two accepted shapes" detail moved to `.claude/reference/merge-gate-reviewer-paths.md` |

## Diagnosis

The churn is mixed-cause with no recorded merge conflicts across all 5 PRs.

**Two corpus-compression sweeps (PRs #804 and #919).** These are cross-file passes that
inherently touch the largest active rule files. They are not a structural problem specific to
`bugbot.md`. Future compression passes will continue to touch it when the corpus approaches
budget limits.

**Two genuine policy additions (PRs #849 and #903).** Both added substantive BugBot behavior
that was previously undocumented: the silent-pass check-run shape (#849) and the PAT trigger
requirement with the bot-author-filter explanation (#903). `bugbot.md` is the canonical rule
file for BugBot behavior — these are by-design touches on the canonical source. The pattern
matches what `churn-hotspots.md` calls "churn by design" for canonical junction files.

**One dedup cleanup (PR #1013).** This was a structural fix, not new churn: the cr-merge-gate
hotspot decision (Issue #940) identified that `bugbot.md` §Merge Gate was a synchronized-edit
risk — it restated the "two accepted shapes" detail already covered in full by
`.claude/reference/merge-gate-reviewer-paths.md`. The cleanup was applied in PR #1013 and
already removes the only identified duplication. No further deduplication opportunity remains.

**No split is warranted.** The file has one clear responsibility: define BugBot-specific
behavior after `escalate-review.sh` returns `STATUS=switch_bugbot`. It is already narrow. Its
6 sections map to 6 distinct concerns (basics, polling, completion-signal, findings-processing,
merge-gate, re-reviews), and no section has grown beyond its purpose. The 5 touches map to 2
by-design additions, 2 cross-file sweeps, and 1 already-completed cleanup — none of these
motivate a split.

## Decision

**KEEP** `.claude/rules/bugbot.md` as the single canonical rule file for BugBot
behavior. Make no operative change.

The one identified duplication (§Merge Gate verbosity) was resolved by PR #1013. The two
genuine policy adds are the correct place for new BugBot behavior. The two compression sweeps
reflect corpus budget management, not a structural problem with this file.

Per `.claude/reference/churn-hotspots.md`, re-file this hotspot only when
`conflict_rounds > 0` — rising PR count alone on a canonical file is not a re-filing trigger.

## Expected impact

None. No rule corpus files were changed. The corpus word count remains unchanged at the
pre-adjudication baseline.

## Related

- Issue #940 / PR #1013 — `cr-merge-gate.md` rule hotspot; closest sibling (same review seam); PR #1013 applied the one dedup that bugbot.md needed
- Issue #844 / PR #849 — BugBot silent-pass check-run shape (the rule PR #849 added)
- Issue #892 / PR #903 — PAT authentication for BugBot trigger (the rule PR #903 added)
- `.claude/reference/merge-gate-reviewer-paths.md` — full BugBot merge-gate path conditions (the pointer target after PR #1013's dedup)
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic
