# Subagent-Orchestration Churn Audit — July 2026

**Issue:** [#814](https://github.com/auerbachb/claude-code-config/issues/814) (churn hotspot report from /wrap after PR #811 merged)

**Date:** 2026-07-30

**Related precedent:** [instruction-set-audit-2026-07.md](instruction-set-audit-2026-07.md), [too-big-recalibration-2026-07.md](too-big-recalibration-2026-07.md)

---

## Executive summary

### Verdict: **KEEP** (single file) + **Dedup in place**

Keep `.claude/rules/subagent-orchestration.md` as a single rule file. Rejected: split into topic-scoped files. Remediation: remove content duplicated by canonical owners — specifically the Phase A/B/C bullet descriptions restated in `.claude/agents/phase-{a,b,c}-*.md` and `.claude/reference/phase-decomposition.md`.

---

## 1. Churn analysis

**Observation:** `.claude/rules/subagent-orchestration.md` was touched by 13 distinct merged PRs since 2026-07-16: PRs #617, #621, #660, #724, #737, #738, #742, #750, #775, #786, #799, #804, #807.

**Root-cause drivers (in order of frequency):**

| Driver | Why it keeps landing here |
|--------|--------------------------|
| Model-fleet/table churn | Phase model defaults (Opus/Sonnet/Haiku/Fable) change as the fleet updates. Each change edits the Model Selection table in this file. |
| Cross-file delegation notes | When a new rule is established in another file, this file often gets a cross-reference or behavioral note added. |
| A/B/C decomposition prose | Phase descriptions restated here and in the agent definition files — every phase behavior change needed to update both places. |
| Orchestration ceiling/scope | Concrete policy numbers (3-4 PRs, @me scope) pinned here; changes needed as policy evolved. |

---

## 2. Split-vs-dedup decision

### Option 1: Split into topic-scoped rule files

Would create files like `subagent-model-selection.md`, `subagent-ceiling.md`, etc., and re-point all consumers.

**Rejected.** The file is only 783 words — well under the 2,000-word per-file warning. Splitting would blast ~50 cross-references across skills, agents, and reference docs, plus require a CLAUDE.md rule-index rewrite. The adherence risk of re-pointing that many consumers outweighs the churn benefit.

### Option 2: Keep single file; dedup toward canonical owners

Remove content that duplicates canonical owners, replacing with pointers. The file already uses this pattern in "Subagent Review Protocol" (`do NOT duplicate them`).

**Chosen.** Small blast radius (one rule file), retains all headings that downstream consumers cite, no CLAUDE.md index changes.

### Option 3: No change (KEEP verdict only)

Would still leave the duplication in place. Rejected: the duplication is the churn driver — a KEEP-only verdict doesn't fix the problem.

---

## 3. Ownership decisions

These decisions tell future editors where content belongs:

| Content | Canonical owner | Non-owner action |
|---------|----------------|------------------|
| Per-phase default model table (Opus/Sonnet/etc.) | `.claude/rules/subagent-orchestration.md` "Model Selection" | All other files point here; do not restate the table |
| Phase A/B/C step-by-step procedures | `.claude/agents/phase-{a,b,c}-*.md` + `.claude/reference/phase-decomposition.md` | `subagent-orchestration.md` points to those, does not restate |
| A/B/C orchestration policy (ceiling, scope, transitions, overflow) | `.claude/rules/subagent-orchestration.md` "Task Decomposition / Orchestration" | Canonical here; other files quote or reference |
| Phase C advisory-only qualifier | `.claude/rules/subagent-orchestration.md` | Behavioral rule; stays in the rule file |

---

## 4. Remediation applied (PR #814)

**`.claude/rules/subagent-orchestration.md` — Task Decomposition section:**

Removed the three Phase A/B/C bullet descriptions (which restated the canonical procedures in agent files). Added explicit pointer to `.claude/reference/phase-decomposition.md`. Retained:
- The intro line ("Give each subagent one phase with explicit exit criteria")
- Phase C advisory-only qualifier
- All four Orchestration bullets (Transitions, Ceiling, Scope, Overflow) — these are canonical here

**Word count:** 11,579 → 11,510 words (approx; exact in PR description).

**Cap:** `.claude/rules/.budget-soft-cap` updated via `rule-lint.sh --update-cap`.

---

## 5. Future churn mitigation

- **Model-fleet changes:** edit only the Model Selection table in `subagent-orchestration.md`; `agents/README.md` now points there instead of restating.
- **Phase behavior changes:** edit `agents/phase-{a,b,c}-*.md` and `phase-decomposition.md`; `subagent-orchestration.md` has no step descriptions to update.
- **Ceiling/scope policy:** still lives in the Orchestration bullets here (canonical); single place to update.
