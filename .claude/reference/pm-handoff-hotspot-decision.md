<!-- churn-hotspot: .claude/skills/pm-handoff/SKILL.md -->

# pm-handoff Hotspot Decision

Reference for Issue #1122 (`.claude/skills/pm-handoff/SKILL.md` churn hotspot). Not auto-loaded.

**Verdict:** KEEP — no split, targeted dedup only
**Hotspot issue:** #1122
**Reporter:** `/wrap` (filed after PR #1119 merged)
**Measured window:** 2026-07-24 to filing; 3 distinct merged PRs, 0 conflict rounds

## 1. Churn summary

`.claude/skills/pm-handoff/SKILL.md` was touched by 3 merged PRs in the window — the minimum threshold to file a hotspot — with no recorded merge-conflict rounds. The three PRs belong to two lineages that converged sequentially on one section.

## 2. Per-PR attribution (verified via `git show`)

| PR | Issue | Lineage | What changed in pm-handoff/SKILL.md |
|----|-------|---------|--------------------------------------|
| #825 | #808 | Scheduling-substrate correction | Step 5b2 on-resume text: replaced false "durable jobs survive session turnover" claim with accurate session-scoped warning |
| #867 | #827 | Scheduling-substrate redesign | Step 5b2 table shape: removed `durable`/`last heartbeat` columns; refined on-resume wording; added paused-fleet resume note |
| #910 | #901 | Shared-collector delegation | Steps 4, 5b, 5b2, 5c: replaced inline code blocks with delegation pointers to `session-state-collector.md` |

**PRs #825 and #867** are part of the scheduling-substrate correction and redesign wave initiated by Issues #808 and #827. PR #825 corrected a false durability claim that existed in many consumer files; PR #867 replaced the CronCreate scheduling infrastructure entirely, simplifying the table schema and vocabulary in every consumer. Both were forced corrections applied uniformly across the repo — not driven by pm-handoff's own concerns.

**PR #910** introduced the portable-handoff skill (then named `/pause`, now
`/stop` after Issue #1310) and extracted the shared state-collection logic into
`session-state-collector.md` (Issue #901). The primary goal was eliminating
code drift between `/pm-handoff` and `/stop` — one collector, two renderers.
Steps 4, 5b, 5b2, and 5c each lost their inline code blocks and gained
delegation pointers to the collector sections. This was a net reduction in
pm-handoff's footprint.

**Classification:** Coordinated two-lineage churn. The three PRs belong to two coordinated wave operations, not to independently-iterating concerns. None of the cited PRs changed Step 5's template structure, the config-bootstrap detection (Steps 1–3), or the prompt-assembly logic.

## 3. Concern inventory and dedup check

The file mixes five separable concerns:

| Concern | Steps | Canonical data source |
|---------|-------|-----------------------|
| Config bootstrap and mode detection | Steps 1–3 | `pm-config-get.sh` |
| Live GitHub state collection | Step 4 | `session-state-collector.md` §1 |
| In-flight per-PR handoff state | Step 5b | `session-state-collector.md` §2 |
| Active polling jobs status | Step 5b2 | `session-state-collector.md` §3 |
| Memory index | Step 5c | `session-state-collector.md` §4 |
| Prompt-template assembly and output | Steps 5, 5d, 6 | (this skill owns rendering) |

Data-gathering for Steps 4, 5b, 5b2, and 5c is already centralized in `session-state-collector.md`. The skill owns only **rendering** for those steps — and that rendering is this skill's core deliverable.

**One real duplication identified (before this change):** Step 5b2's on-resume block restated the canonical CronCreate durability sentence from `session-state-collector.md` §3 near-verbatim. This duplication was confirmed before this PR:

- Step 5b2 (before this change): *"All `CronCreate` jobs are **session-scoped** and do not survive session turnover — `durable: true` has no effect. Any job listed here died with the previous session; do not use `CronList` to check for survivors, there will be none."*
- `session-state-collector.md` §3 (canonical): *"Every `CronCreate` job is session-scoped and dies with its session (`durable: true` has no effect — `scheduling-reliability.md`). Anything listed here is therefore already dead from the next session's point of view. Consumers must not tell a reader to check for survivors."*

`session-state-collector.md` §3 exists and carries the canonical statement. This PR replaces the duplicated prose with a pointer; the final skill now uses the deduplicated form.

**Important:** No verbatim-block lint (`.github/scripts/verbatim-block-lint.sh` or similar) pins this prose. The dedup is safe to apply.

**Downstream ledger:** `.claude/reference/pm-monitoring-decision.md` (§ Skill integration decision) names `/pm-handoff` and its expected polling behavior. `scheduling-reliability.md` and `cross-session-durability.md` do not name this file directly.

## 4. Decision

**Keep the file whole.** The concerns already delegate data-gathering to shared collectors; the remaining rendering and template-assembly logic is the skill's core purpose. A physical split would fragment one prompt-assembly procedure without removing duplication.

**Apply one targeted dedup:** Replace Step 5b2's duplicated durability prose with a pointer to `session-state-collector.md` §3, while retaining the operative qualifiers inline so an executing agent that does not follow the link still has the actionable behavior:

- Retain inline: "`CronCreate` jobs are session-scoped — `durable: true` has no effect"
- Retain inline: all actionable instructions (`do not use CronList`, `Re-arm via the owning skill`, `/pr-monitor-and-manage` note)
- Replace with pointer: the full sentence restating §3's canonical fact

This follows the same pattern as `scheduling-reliability-hotspot-decision.md` and `pmm-lifecycle-hotspot-decision.md`: canonical prose lives in one place; consumers carry only a pointer and their unique actionable content.

## 5. Split rejected

A physical split into separate skills (e.g., config-bootstrap vs. state-rendering vs. prompt-assembly) is rejected:

- The three sections are sequentially dependent: config detection sets `MODE`, state rendering populates variables, prompt assembly formats and emits them. A split adds routing overhead without isolating independently-changing concerns.
- The data-gathering delegation (PRs #910) already performs the logical extraction that a split would attempt. The skill now owns only rendering, which is by definition cohesive.
- No PR in the measured window produced a merge conflict. The hotspot threshold (3 PRs) is the minimum; this is low-severity.

## 6. What was explicitly preserved

- Config-bootstrap detection tables (Steps 1–3), including `MODE` dispatch and `UNREADABLE` guard
- `pm-config.md` template (Step 2d) and full section-preservation algorithm
- In-flight state rendering table shape and `needs`/`remaining_work` bullet rule (Step 5b)
- `/pr-monitor-and-manage` resume guidance in Step 5b2 (a paused fleet resumes from its on-disk marker, not from a job)
- Empty-case output lines throughout
- Frontmatter, all numbered steps, CLI examples, and the `copy` argument handling

## 7. Re-filing rule

Per `.claude/reference/churn-hotspots.md`: re-file this hotspot only when `conflict_rounds > 0` or when the same section is touched by 3+ PRs in a future window driven by a new, unrelated lineage. The current KEEP verdict does not increase the rule corpus.

## Related

- Issue #808 — CronCreate durability correction wave (→ PR #825)
- Issue #827 — CronCreate substrate redesign (→ PR #867)
- Issue #901 — portable handoff (now `/stop`) + shared-collector extraction (→ PR #910)
- `.claude/reference/session-state-collector.md` — shared collector; §3 is the canonical CronCreate durability statement
- `.claude/reference/pm-monitoring-decision.md` — downstream ledger naming `/pm-handoff`'s polling behavior
- `.claude/reference/pm-handoff-chips-decision.md` — why `/pm-handoff` does not offer task chips
- `.claude/reference/scheduling-reliability-hotspot-decision.md` — KEEP + dedup precedent for scheduling-substrate churn
- `.claude/reference/pmm-lifecycle-hotspot-decision.md` — KEEP + dedup precedent, canonical-source marker pattern
- `.claude/reference/fixpr-hotspot-decision.md` — extract-not-split precedent for comparison
