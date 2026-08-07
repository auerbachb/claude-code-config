<!-- churn-hotspot: .claude/rules/skill-first.md -->
# Hotspot Decision — skill-first.md

**Verdict:** KEEP (no operative change)
**Decided:** 2026-08-07
**Issue:** #1051
**Reporter:** `/wrap` post-merge churn report (PR #1050)

## Churn summary

`churn-hotspots.sh` flagged `.claude/rules/skill-first.md` as touched by 4 distinct merged PRs
since 2026-07-23: PRs #787, #804, #919, #1016.

| PR | Churn class | Section changed | What changed |
|----|-------------|-----------------|--------------|
| PR #787 | Budget-cut trim | Removed `## Why` section | Deleted 4-line "Why" section to fund `safety.md` `rm`-exception addition (Issue #785); cuts paid the corpus budget per the retroactive note in `budget-cap-raise-decision.md` |
| PR #804 | Corpus compression | `## Why` prose + `## Reaching Subagents` intro | Part of repo-wide 12,166 → 10,999 word compression sweep; compressed verbose `## Why` sentence and trimmed the `## Reaching Subagents` intro clause |
| PR #919 | Corpus compression | `## Reaching Subagents` | Part of 430-word budget-freeing sweep (Issue #918); collapsed numbered-list delivery description into inline prose; added `.claude/reference/skill-first-subagent-delivery.md` pointer |
| PR #1016 | By-design policy correction | `## Reaching Subagents` | Updated delivery model to reflect harness-native rule inheritance for custom `subagent_type` agents (Issue #777); narrowed paste-verbatim guidance to Explore/Plan built-ins and general-purpose spawns; cross-referenced `token-efficiency-audit-2026-07.md` §FU-1 |

## Diagnosis

The churn is mixed-cause with no recorded merge conflicts across all 4 PRs.

**Two corpus-compression sweeps (PRs #804 and #919).** These are cross-file passes that
inherently touch the largest active rule files. PR #804 was the major 12,166 → 10,999 word
compression that touched multiple rule files; PR #919 was a 430-word targeted pass. Neither
reflects a structural problem specific to `skill-first.md`.

**One budget-cut trim (PR #787).** The `## Why` section (4 lines) was removed to fund a
`safety.md` addition for the `rm`-of-verified-untracked-files exception. This was a deliberate
prose cut on a non-essential explanatory section — the mechanism it described was already
covered by `skill-first-subagent-delivery.md`. The cut is consistent with the
`budget-cap-raise-decision.md` retroactive note: paying with cuts is a legitimate path, and
the section's content is not operationally binding.

**One by-design policy correction (PR #1016).** The `## Reaching Subagents` section was
updated to reflect a confirmed architectural fact: the harness auto-injects the project
CLAUDE.md and `rules/*.md` into every custom `subagent_type` agent spawn. This made the
prior "paste-verbatim block into all spawns" guidance overcorrect — the block only needs to
go into Explore/Plan built-ins and ad-hoc general-purpose spawns where harness injection is
uncertain. The change is by-design and non-conflicting; it is a narrowing correction to a
propagation rule, not a new concern.

**No split is warranted.** The file has one clear responsibility: define the skill-first
reflex and explain how to deliver it to subagents. Its three sections map to three distinct
concerns (policy header + confidence ladder, "Reaching Subagents" delivery mechanics, verbatim
`SKILLS:` block). The verbatim `SKILLS:` block is already lint-governed by
`.github/scripts/verbatim-block-lint.sh` (byte-identical copies in
`.claude/reference/subagent-phase-guardrails.md` and
`.claude/skills/pr-monitor-and-manage/SKILL.md`), so its propagation surface is managed
independently of the rule file structure. No section has grown beyond its purpose.

The 4 touches map to 2 cross-file sweeps, 1 budget-paying cut, and 1 policy correction —
none of these reflect independent concerns colliding in one file, and no conflict rounds are
recorded.

## Decision

**KEEP** `.claude/rules/skill-first.md` as the single canonical rule file for the skill-first
reflex. Make no operative change.

The two genuine churn drivers (compression sweeps) reflect corpus budget management, not a
structural problem with this file. The budget-cut trim (PR #787) removed only non-binding
explanatory prose whose mechanism is covered by the companion reference doc. The policy
correction (PR #1016) was a necessary narrowing once harness-native inheritance was confirmed
by PR #1016's audit.

Per `.claude/reference/churn-hotspots.md`, re-file this hotspot only when
`conflict_rounds > 0` — rising PR count alone on a canonical file is not a re-filing trigger.
If future churn on `skill-first.md` shows `conflict_rounds > 0`, the embedded `SKILLS:` block
is the one real multi-file propagation surface to reconsider — an extract-not-split option
would move it to a dedicated template location while keeping the prose policy in place.

## Expected impact

None. No rule corpus files were changed. The corpus word count remains unchanged at the
pre-adjudication baseline.

## Related

- PR #787 / Issue #785 — `rm`-of-verified-untracked-files exception; budget-cut trim that removed `## Why` section
- PR #804 / Issue #790 — repo-wide 12,166 → 10,999 word corpus compression sweep
- PR #919 / Issue #918 — 430-word budget-freeing corpus compression sweep
- PR #1016 / Issue #777 — harness-native rule inheritance verification; by-design `## Reaching Subagents` policy correction
- `.claude/reference/skill-first-subagent-delivery.md` — expanded delivery mechanism and per-agent-type matrix
- `.github/scripts/verbatim-block-lint.sh` — byte-identical enforcement of the `SKILLS:` block propagation surface
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic
- `.claude/reference/budget-cap-raise-decision.md` §Retroactive: PR #787 — confirms the budget-cut classification for PR #787
