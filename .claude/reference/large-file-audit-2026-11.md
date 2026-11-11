# Large-file audit, November 2026

**Issue:** [#2174](https://github.com/auerbachb/claude-code-config/issues/2174), measured 2026-11-10 on `origin/main` at 93d75e2b. Nothing was split or trimmed here; this report ranks and decides, and the work is filed as follow-ups.

## Method

- **Population.** Every tracked text file over 8,000 words (`git ls-files`, `wc -w`): 49 files. Counts are whitespace-delimited words, not tokens. Two numbers in the issue's note have moved since it was written (`/subagent` is now 23,224 words, up from 22,902; the test files were not in that list).
- **PRs touched, 60 days.** Commits reaching the file since 2026-09-11. The repo squash-merges, so one commit is one PR. (`git log --since=2026-09-11 -- <file>`.)
- **Read frequency.** Skills load in full on every invocation of that skill, so the column gives the number of other tracked files that name the skill. For everything else it is the number of other tracked files that mention the file's name (callers, docs, tests). It is a proxy: a name match is not proof of a call.
- **Removable share.** Two measures per file: words on lines that cite an issue or PR number (provenance and history), and words on lines repeated verbatim in the same file. Comment share was counted for shell scripts.
- **How the verdicts were judged.** Instruction files (skills, rules, references, READMEs): what does one run need in view, and do separate runs need separate parts? Code (scripts, jq, JSON schema): do the parts change independently, and does splitting preserve the single entry point its callers use? Tests default to `leave` unless they block parallel work.

## Findings that shape the verdicts

- **Embedded shell dominates the big skills.** `/pm`'s largest "sections" are comment lines inside fenced bash; the same holds in `/pause-resume` (one 2,829-word block), `/leave-by`, `/wrap`, `/fixpr` and `/babysit-pr`. The seam for them is moving code into scripts, which is a different change from trimming prose.
- **Scripts are mostly comments.** `ai-quotas.sh` is 58% comment words, `merge-gate.sh` 61%, `review-substance.sh` 84%. In `review-substance.sh` they are the decision table the code implements, so they stay; in `ai-quotas.sh` many restate `.claude/reference/ai-quotas.md`.
- **Churn is concentrated.** Four files take 18 to 56 PRs each in 60 days: `.claude/reference/README.md` (56), `desk/README.md` (25), `/subagent` (21), `/fixpr` (18). A file touched this often is a queue regardless of its size.
- **Precedent exists.** `.claude/scripts/README.md` was split the same way this audit recommends for the reference index (`.claude/reference/scripts-readme-split-decision.md`).

## Ranked list

Verdict values are exactly one of `split`, `trim`, `leave`. "Follow-up" names the filed issue or the existing plan that already covers it.

| # | File | Kind | Words | PRs, 60 days | Read frequency | Verdict | Follow-up |
|--:|---|---|--:|--:|---|---|---|
| 1 | `.claude/skills/pm/SKILL.md` | skill | 35288 | 17 | loaded on each /pm run; 221 files name it | split | covered: Issues #2170-#2173 |
| 2 | `.claude/scripts/ai-quotas.sh` | code | 26580 | 12 | 21 files name it | split | Issue #2179 |
| 3 | `.claude/skills/subagent/SKILL.md` | skill | 23224 | 21 | loaded on each /subagent run; 131 files name it | split | planned: incremental-skill-loading.md slice 2 |
| 4 | `.claude/scripts/tests/review-stack-audit.test.sh` | test | 19842 | 8 | 2 files name it | leave | none |
| 5 | `.claude/scripts/merge-gate.sh` | code | 19378 | 10 | 145 files name it | leave | none |
| 6 | `.claude/reference/ai-quotas.md` | reference | 19073 | 17 | 13 files name it | split | Issue #2180 |
| 7 | `.claude/scripts/ai-quotas-setup.sh` | code | 18201 | 8 | 16 files name it | leave | none |
| 8 | `.claude/scripts/stale-cleanup.sh` | code | 17639 | 1 | 27 files name it | leave | none |
| 9 | `.claude/scripts/tests/churn-hotspots.test.sh` | test | 16253 | 4 | 6 files name it | leave | none |
| 10 | `.claude/scripts/session-state.sh` | code | 16116 | 2 | 170 files name it | leave | none |
| 11 | `.claude/scripts/tests/ai-quotas-setup.test.sh` | test | 15471 | 2 | 3 files name it | leave | none |
| 12 | `desk/README.md` | doc | 15199 | 25 | 130 files name it | split | Issue #2178 |
| 13 | `.claude/skills/leave-by/SKILL.md` | skill | 14844 | 2 | loaded on each /leave-by run; 19 files name it | leave | none |
| 14 | `.claude/scripts/churn-hotspots.sh` | code | 14244 | 4 | 47 files name it | leave | none |
| 15 | `.claude/scripts/tests/active-work-cap.test.sh` | test | 13423 | 3 | 3 files name it | leave | none |
| 16 | `.claude/scripts/tests/stale-cleanup.test.sh` | test | 13369 | 2 | 4 files name it | leave | none |
| 17 | `.claude/skills/pause-resume/SKILL.md` | skill | 13089 | 3 | loaded on each /pause-resume run; 37 files name it | leave | none |
| 18 | `.claude/scripts/review-substance.sh` | code | 13064 | 4 | 38 files name it | leave | none |
| 19 | `.claude/skills/go-on/SKILL.md` | skill | 12979 | 13 | loaded on each /go-on run; 42 files name it | split | Issue #2181 |
| 20 | `.claude/skills/wrap/SKILL.md` | skill | 12060 | 14 | loaded on each /wrap run; 210 files name it | split | planned: incremental-skill-loading.md slice 3 |
| 21 | `.claude/scripts/tests/leave-time.test.sh` | test | 11990 | 1 | 3 files name it | leave | none |
| 22 | `.claude/skills/pr-monitor-and-manage/SKILL.md` | skill | 11822 | 4 | loaded on each /pr-monitor-and-manage run; 72 files name it | split | planned: incremental-skill-loading.md slice 4 |
| 23 | `.claude/scripts/active-work-cap.sh` | code | 11456 | 3 | 34 files name it | leave | none |
| 24 | `.claude/scripts/tests/merge-gate-review-substance.test.sh` | test | 11431 | 2 | 6 files name it | leave | none |
| 25 | `.claude/scripts/escalate-review.sh` | code | 11163 | 7 | 67 files name it | leave | none |
| 26 | `.claude/scripts/tests/subagent-limit-park.test.sh` | test | 11102 | 5 | 5 files name it | leave | none |
| 27 | `.claude/scripts/tests/pm-day-horizon.test.sh` | test | 10802 | 4 | 5 files name it | leave | none |
| 28 | `.claude/skills/fixpr/SKILL.md` | skill | 10672 | 18 | loaded on each /fixpr run; 122 files name it | trim | Issue #2182 |
| 29 | `.claude/skills/babysit-pr/SKILL.md` | skill | 10412 | 6 | loaded on each /babysit-pr run; 51 files name it | leave | none |
| 30 | `.claude/reference/subagent-thread-limit-park.md` | reference | 10151 | 4 | 24 files name it | leave | none |
| 31 | `.claude/scripts/tests/claude-config-sync.test.sh` | test | 9942 | 1 | 5 files name it | leave | none |
| 32 | `.claude/reference/README.md` | reference | 9856 | 56 | 130 files name it | split | Issue #2188 (overlaps open Issue #1996) |
| 33 | `.claude/scripts/tests/issue-claim.test.sh` | test | 9320 | 7 | 5 files name it | leave | none |
| 34 | `.claude/hooks/session-start-sync.sh` | code | 9228 | 6 | 42 files name it | leave | none |
| 35 | `.claude/scripts/tests/table-freshness.test.sh` | test | 9193 | 0 | 3 files name it | leave | none |
| 36 | `.claude/reference/ai-review-billing-dashboard-2026-08.md` | reference | 9186 | 1 | 9 files name it | leave | none |
| 37 | `.claude/skills/review-stack-audit/measure.sh` | code | 9147 | 7 | 15 files name it | leave | none |
| 38 | `.claude/reference/chip-launching.md` | reference | 9111 | 5 | 50 files name it | leave | none |
| 39 | `desk/skill/desk.jq` | code | 9071 | 8 | 17 files name it | leave | none |
| 40 | `.claude/scripts/tests/merge-gate-codeant-run-marker.test.sh` | test | 8853 | 1 | 4 files name it | leave | none |
| 41 | `.claude/skills/pause/SKILL.md` | skill | 8755 | 2 | loaded on each /pause run; 53 files name it | leave | none |
| 42 | `.claude/scripts/issue-claim.sh` | code | 8685 | 7 | 42 files name it | leave | none |
| 43 | `.claude/skills/wave/SKILL.md` | skill | 8518 | 5 | loaded on each /wave run; 54 files name it | leave | none |
| 44 | `.claude/scripts/tests/pr-state-classify.test.sh` | test | 8503 | 3 | 6 files name it | leave | none |
| 45 | `.claude/skills/board/SKILL.md` | skill | 8475 | 2 | loaded on each /board run; 17 files name it | leave | none |
| 46 | `.claude/scripts/claude-config-sync.sh` | code | 8353 | 1 | 17 files name it | leave | none |
| 47 | `.claude/scripts/candidate-ownership.sh` | code | 8334 | 0 | 21 files name it | leave | none |
| 48 | `.claude/reference/pricing-matrix.md` | reference | 8015 | 2 | 29 files name it | leave | none |
| 49 | `.claude/reference/session-state-schema.json` | schema | 8009 | 11 | 50 files name it | leave | none |

## Verdicts: instruction files

**`.claude/skills/pm/SKILL.md` (35,288 words) — split.** A `/pm` run is one of a few intents (rank, launch, day mode, report) and needs only that intent's procedure, yet reads all of it (198 heading-level lines, many of them comments inside fenced bash); 18% of its words are on lines citing issue numbers. Seam: entry plus ranking, launch (Step 3.1 alone is about 1,870 words), recommendation output, and day-mode wake recovery. Already covered by the /pm modules chain, Issues #2170 to #2173; no new issue.

**`.claude/skills/subagent/SKILL.md` (23,224) — split.** Step 7 (spawn Phase A) is about 5,690 words, a quarter of the file, and a prompt-only or fit-assessment run never needs it. Seam: assessment (Steps 1 to 6), spawn, monitor loop, Phase B instructions. Already planned as slice 2 in `.claude/reference/incremental-skill-loading.md`; no new issue.

**`.claude/skills/wrap/SKILL.md` (12,060) — split.** A status-only or blocked-gate run does not need Step 2.4 (squash merge, about 1,715 words) or the full-session sweep. Seam: discovery, gate and recovery, merge and sync, follow-ups and lessons. Planned as slice 3 in `incremental-skill-loading.md`; it already has a `references/` directory to build on.

**`.claude/skills/pr-monitor-and-manage/SKILL.md` (11,822) — split.** One polling tick needs its monitor phase, not the stop and re-arm procedure (Step 7) or the persistence step. Planned as slice 4 in `incremental-skill-loading.md`; five `pmm-*.md` reference files already exist.

**`.claude/skills/go-on/SKILL.md` (12,979) — split.** Step 0 (probe the evidence, precedence, dispatch, about 2,200 words) is needed on every resume; the per-stoppage procedures (unresolved findings, clean-BEHIND follow-through, and others) are each needed only when the classifier picks them. 13 PRs in 60 days and not in the existing plan. Seam: classifier entry plus one module per stoppage kind. Filed as Issue #2181.

**`.claude/skills/fixpr/SKILL.md` (10,672) — trim.** 2,280 words (21%) sit on lines that cite an issue number, the highest share of any large skill. The structure is already sound (it has a "How this skill is structured" section), so a split buys little; the saving is history next to rules. Removable share about 15 to 20%. Two examples: the step table's "(no-arg inference, issue #447)" and the reviewer list's "(#1897, #1898)" after "BugBot only by spending an owner grant". The trim needs a reviewer reading for meaning, since a dropped qualifier changes a rule. Filed as Issue #2182.

**`.claude/skills/leave-by/SKILL.md` (14,844) — leave.** Large, but 2 PRs in 60 days means it does not queue work. Invocation frequency was not measured (the 19 files that name it say nothing about how often it runs), so its read cost is unknown and ranked below files with measured churn. One seam exists if it ever matters: Step 0e's elicit mode (about 1,030 words) is not needed to arm a deadline. Not worth a slice now; revisit if it starts changing weekly.

**`.claude/skills/pause-resume/SKILL.md` (13,089) — leave.** A single linear restore procedure in which each step is needed on a resume; 3 PRs. Its bulk is one 2,829-word embedded bash block, which is a script-extraction question, not a split.

**`.claude/skills/pause/SKILL.md` (8,755), `.claude/skills/board/SKILL.md` (8,475), `.claude/skills/wave/SKILL.md` (8,518), `.claude/skills/babysit-pr/SKILL.md` (10,412) — leave.** Each is one linear procedure whose steps a run needs, with 2 to 6 PRs in 60 days. `wave` carries 25% of its words on issue-citing lines and `babysit-pr` 11%; both are candidates for a later trim if churn rises, but neither is worth a slot today.

**`desk/README.md` (15,199) — split.** 25 PRs in 60 days, almost all adding or editing one feature's own section (export to paper, derived impact, to-do layer, day plan, interrupts and policy, PR drill-down). Those sections share little, so concurrent desk issues queue on one file. Seam: overview and index plus one file per feature under `desk/docs/`. Filed as Issue #2178.

**`.claude/reference/README.md` (9,856) — split.** 56 PRs in 60 days, the highest of any file: every new reference doc adds a line, and 94% of its words are index entries citing issues. Seam: thin index plus one file per category, as `.claude/scripts/README.md` already does. The split needs `reference-catalog-lint.sh` changed first, because it requires every root-level reference file to have one bullet in this README's `## Contents` section; it must check the category files instead, and Issue #2188 already lists that change. Open Issue #1996 is only the owner's keep-or-change question and prescribes no split, and Issue #816 chose an append-only catalog, so this is pending an owner decision. Filed as Issue #2188, whose first criterion is that decision.

**`.claude/reference/ai-quotas.md` (19,073) — split.** 17 PRs in 60 days; sections serve different readers (provider readers, token renewal and re-login, the history file and daily job, label/path repair). Seam: overview plus provider readers, renewal/re-login, and operations. Filed as Issue #2180; sequence it with the `ai-quotas.sh` split.

**`.claude/reference/subagent-thread-limit-park.md` (10,151) — leave.** Read on demand and addressed by numbered section (`§8`, `§8.1`), which is itself the loading discipline; 4 PRs.

**`.claude/reference/chip-launching.md` (9,111) — leave.** Read only when emitting a chip, which the rules now bar by default; 27% of words cite issues, but 5 PRs and a narrow reader. A trim candidate if chip work returns.

**`.claude/reference/ai-review-billing-dashboard-2026-08.md` (9,186) — leave.** A point-in-time record with 1 PR; nothing reads it during a run.

**`.claude/reference/pricing-matrix.md` (8,015) — leave.** A lookup table with machine-readable rates; the 35% citation share is the provenance of each price, which is the content.

**`.claude/reference/session-state-schema.json` (8,009) — leave.** A single JSON schema consumed whole by validators; 11 PRs, but splitting it would add `$ref` plumbing to every consumer for a file whose entries are independent fields.

## Verdicts: code files

**`.claude/scripts/ai-quotas.sh` (26,580; 3,579 lines, 59 functions) — split.** The parts change independently: the Cursor reader was rebuilt twice (Issues #1668, #1703) with nothing else moving, while the Codex app-server probe and the table footer are unrelated to it; 12 PRs in 60 days, about 58% of the words are comments, and many restate `.claude/reference/ai-quotas.md`. Seam: entry point and CLI, then per-provider reader files (claude, codex, cursor), forecast, and snapshot rendering, sourced by the entry point. Filed as Issue #2179; do it after Issue #1917 lands, since that work is editing the file now.

**`.claude/scripts/merge-gate.sh` (19,378) — leave.** 10 PRs and 145 files name it, but it is a linear pipeline (fetch, resolve reviewer, evaluate, emit) with only 15 functions, so the parts do not change independently and a split would add sourcing to the most-called gate in the repo. History is about 13% of words. Revisit as a comment trim if churn continues.

**`.claude/scripts/ai-quotas-setup.sh` (18,201) — leave.** 63 functions and 8 PRs, but history is 1% and it is one setup flow that changes alongside the reader split; decide again after Issue #2179.

**`.claude/scripts/stale-cleanup.sh` (17,639) — leave.** 1 PR in 60 days; a stable, single-purpose cleaner.

**`.claude/scripts/session-state.sh` (16,116) — leave.** 2 PRs and 170 files name it. It is the one write path to session state, and callers depend on that single entry point.

**`.claude/scripts/churn-hotspots.sh` (14,244), `.claude/scripts/active-work-cap.sh` (11,456), `.claude/scripts/candidate-ownership.sh` (8,334), `.claude/scripts/issue-claim.sh` (8,685), `.claude/scripts/claude-config-sync.sh` (8,353), `.claude/hooks/session-start-sync.sh` (9,228), `.claude/skills/review-stack-audit/measure.sh` (9,147) — leave.** Each does one job with 0 to 7 PRs in 60 days and low history share (0% to 4%); none queues work.

**`.claude/scripts/review-substance.sh` (13,064) — leave.** One function and 84% comment words, but the comments are the numbered decision table the code implements; only about 9% (history lines) is removable, too little to justify touching a gate evaluator.

**`.claude/scripts/escalate-review.sh` (11,163) — leave.** 7 PRs and 13% history, one escalation flow; not worth a trim pass on its own.

**`desk/skill/desk.jq` (9,071) — leave.** 8 PRs across classify, feedback, render and review sections, but it is one file jq loads by path, and splitting means `include` plumbing for every caller; the sections share one pipeline.

## Verdicts: test files

All 14 test files are listed in the ranked table and default to `leave`. No test file shows churn that queues work: the largest, `review-stack-audit.test.sh` (19,842), had 8 PRs in 60 days, and none of the 14 is a split candidate on that evidence. File-mention counts measure references, not concurrent edits, so they are not used here, and this audit does not claim that no test blocks parallel work. The slow-suite concern is a separate issue (Issue #2176, parallel hook-test runs), not a size one.

## Follow-up work

Ranked by churn and by how much a run or a PR queue pays:

1. [Issue #2188](https://github.com/auerbachb/claude-code-config/issues/2188) split `reference/README.md` (56 PRs; first needs the owner decision in Issue #1996)
2. [Issue #2178](https://github.com/auerbachb/claude-code-config/issues/2178) split `desk/README.md` (25 PRs)
3. [Issue #2182](https://github.com/auerbachb/claude-code-config/issues/2182) trim `/fixpr` (18 PRs, 21% history)
4. [Issue #2181](https://github.com/auerbachb/claude-code-config/issues/2181) load `/go-on` incrementally (13 PRs)
5. [Issue #2180](https://github.com/auerbachb/claude-code-config/issues/2180) split `reference/ai-quotas.md` (17 PRs)
6. [Issue #2179](https://github.com/auerbachb/claude-code-config/issues/2179) split `ai-quotas.sh` (12 PRs; after Issue #1917)

Already covered, no new issue: `/pm` by Issues #2170 to #2173; `/subagent`, `/wrap` and `/pr-monitor-and-manage` by the slices in `.claude/reference/incremental-skill-loading.md`.

Related but separate: Issue #573 (prune unused skills) is about usage; this audit is about size.
