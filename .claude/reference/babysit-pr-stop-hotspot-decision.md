<!-- churn-hotspot: .claude/skills/babysit-pr-stop/SKILL.md -->
# Hotspot Decision — babysit-pr-stop/SKILL.md

**Verdict:** KEEP (no operative change)
**Decided:** 2026-08-07
**Issue:** #1114
**Reporter:** `/wrap` post-merge churn report (PR #1113)

## Churn summary

`churn-hotspots.sh` flagged `.claude/skills/babysit-pr-stop/SKILL.md` as touched by 3 distinct
merged PRs since 2026-07-28: PRs #825, #867, #982.

At diagnosis time the file is ~122 lines with one clear purpose: tear down the watcher Monitor and
state for a single PR that was previously armed with `/babysit-pr`. It is the clean-cancel
companion to `babysit-pr/SKILL.md` and reads and writes the same `.prs["<N>"].babysit` session-
state fields.

### Per-PR attribution (section-level, with evidence from `gh pr diff`)

| PR | Title | Sections changed | Churn driver |
|----|-------|-----------------|--------------|
| PR #825 | fix(#808): correct CronCreate durability claims — session-only, 7-day expiry | Intro paragraph (added CronDelete note for durable mode); Step 4 arm prose (added warning that CronCreate is session-only and `durable: true` has no effect) | Doc correction: clarify that `--durable` / CronCreate does not provide cross-session continuity; no structural or behavioral change to the stop path itself |
| PR #867 | feat(#827): replace CronCreate "durability" with session-start reconciliation | Frontmatter description (CronDelete reference removed); intro paragraph (cooperative stop simplified — no more CronDelete branch); Step 4 rewritten to drop the entire durable/CronDelete branch and replace it with `/loop` cooperative stop + dispatch-in-flight guard | Scheduling-primitive migration: `--durable` flag removed (issue #827), `/loop` becomes the only watcher mode; `babysit-pr-stop` removes CronDelete path and gains dispatch guard for loop-cancel case |
| PR #982 | fix(#924): move recurring polls to Monitor | Frontmatter description (updated to "persistent Monitor task"); intro paragraph ("loop" → "Monitor", "cooperative" → "exact and idempotent"); Step 3 renamed to "race-safe shutdown" (updated prose); Step 4 title changed to "Stop the recurring Monitor" and fully rewritten to TaskStop contract: read `monitor_task_id`, call `TaskStop` for that exact task, fail closed if ID is missing or TaskStop fails, defer `active` clear until after TaskStop succeeds, and write `last_cron_action={type:delete,interval:paused}` in the same transaction; confirmation messages updated to name Monitor teardown | Scheduling-primitive migration: `/loop` → persistent Monitor with `TaskStop`/`monitor_generation` teardown (issue #924); `babysit-pr-stop` updates its stop path to match the new Monitor lifecycle defined in `babysit-pr/SKILL.md` |

### Churn cluster analysis

All three PRs trace to a single coordinated cause: as the underlying scheduling primitive
migrated (`CronCreate` → `/loop` → persistent `Monitor`), `babysit-pr-stop/SKILL.md` updated
its stop/teardown path in lock-step with `babysit-pr/SKILL.md`. This is the same scheduling-
substrate cohort that drove churn in:

- `babysit-pr/SKILL.md` — PRs #825, #867, #922, #982 (sibling record: `babysit-pr-hotspot-decision.md`)
- `polling-backoff-warn.sh` — PRs #820, #867, #982 (record: `polling-backoff-warn-hotspot-decision.md`)
- `scheduling-reliability.md` — 12 PRs including #825, #867, #982 (record: `scheduling-reliability-hotspot-decision.md`)

The three PRs in the `babysit-pr-stop` window are a strict subset of the PRs in the
`babysit-pr` window, confirming that the stop skill is a downstream contract-consumer that
updates exactly when the parent skill's scheduling contract changes. No merge conflicts were
recorded across the three PRs.

## Options considered

### Option 1: SPLIT into multiple skill files

Create separate skills for stop-request, Monitor teardown, and confirmation.

**Rejected.** The file is ~122 lines with one coherent purpose. No `SKILL.md` split precedent
exists in the repo. A split would force synchronized updates across more files without isolating
any independently evolving concern — the three churn events all affected the same functional unit
(how to stop the watcher), not three separate concerns.

### Option 2: KEEP + extract `resolve_script()`

Extract the duplicated `resolve_script()` three-candidate lookup into a shared helper, reducing
replication across `babysit-pr`, `babysit-pr-stop`, and the `pr-monitor-and-manage` companions.

**Deferred.** See "Deferred items" below. The sibling `babysit-pr-hotspot-decision.md` (§4
"Preserved invariants") explicitly treats `resolve_script()` as an accepted inline pattern in
the babysit family and defers shared-script extraction. This record does not contradict it.

### Option 3: KEEP unchanged (chosen)

Record the diagnosis and verdict; make no operative changes to `babysit-pr-stop/SKILL.md`.

**Chosen.** The file is correct and self-contained. The churn was driven entirely by upstream
scheduling-primitive changes — not by internal bloat, cross-concern accumulation, or independently
evolving sub-concerns. The Monitor migration is complete after PR #982; future edits are expected
to be rare and similarly coupled to any future primitive changes in `babysit-pr/SKILL.md`.

## Preserved invariants

Three strings in "### 4. Stop the recurring Monitor" are pinned by `require_text` guards in
`.claude/scripts/tests/scheduling-primitive-alignment.test.sh` and must not change without
simultaneously updating the test:

- `call \`TaskStop\` for that exact task` — guards that babysit-pr-stop targets the recorded Monitor
- `keep \`active=true\`` — guards that babysit-pr-stop blocks duplicate arming until exact teardown
- `last_cron_action={"type":"delete","interval":"paused"` — guards that the lifecycle write suppresses stale backoff guidance

These guards were added by PR #982 to enforce the Monitor-teardown contract. They also appear in
the verbatim-block check `scheduling-primitive-alignment.test.sh` alongside the guards on the
`babysit-pr/SKILL.md` arm/tick sections.

## Deferred items

**Shared-script extraction of `resolve_script()`:** The three-candidate session-state-helper
lookup (`$HOME/.claude/skills-worktree/...`, `$HOME/.claude/scripts/...`, `.claude/scripts/...`)
appears verbatim in `babysit-pr-stop/SKILL.md`, `babysit-pr/SKILL.md`,
`pr-monitor-and-manage-stop/SKILL.md`, and `pr-monitor-and-manage-wake/SKILL.md`. A shared
canonical location would prevent drift, but touching all four companion skills is a coordinated
change out of scope for this single-file hotspot ticket. Already tracked in
`.claude/skills/pr-monitor-and-manage/references/pmm-lifecycle.md` §"Deferred items" as:
"Tracked for a future PR." This record inherits that deferral.

## Related

- `babysit-pr-stop/SKILL.md` — subject of this record
- `.claude/reference/babysit-pr-hotspot-decision.md` — sibling record for `babysit-pr/SKILL.md`
  (Issue #986); treatment of `resolve_script()` inline pattern + scheduling-cohort attribution
- `.claude/reference/scheduling-reliability-hotspot-decision.md` — broader scheduling-substrate
  churn record (Issue #959, 12 PRs including #825/#867/#982)
- `.claude/reference/polling-backoff-warn-hotspot-decision.md` — hook record for the same three PRs
- `.claude/scripts/tests/scheduling-primitive-alignment.test.sh` — CI suite that pins Monitor-
  identity invariants in `babysit-pr/SKILL.md` and `babysit-pr-stop/SKILL.md`
- `.claude/reference/churn-hotspots.md` — mechanism, calibration, and threshold rationale
- Issue #1113 (triggering PR), Issue #824 (#825 source), Issue #827 (#867 source), Issue #924 (#982 source)

## Corpus impact

`babysit-pr-stop/SKILL.md` is not in the auto-loaded rule corpus (`CLAUDE.md` + `.claude/rules/`).
No auto-loaded word count change. The decision record itself lives in `.claude/reference/` (not
auto-loaded), so `.claude/rules/.budget-soft-cap` is untouched.
