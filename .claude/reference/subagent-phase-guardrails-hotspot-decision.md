# Subagent Phase Guardrails Hotspot Decision

Reference for Issue #1033 (`.claude/reference/subagent-phase-guardrails.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the file as the canonical verbatim-block home; make **no operative content change**

`.claude/reference/subagent-phase-guardrails.md` is the single byte-verified home for the
SAFETY, MINDSET, and SKILLS verbatim blocks inserted into Phase A/B/C subagent spawn prompts.
Its churn across 5 PRs is structurally required: every edit originated in the canonical rule
files (`.claude/rules/safety.md`, `.claude/rules/skill-first.md`) and propagated here to keep the
byte-guarded copies current. A structural split or pointer replacement would not remove the churn
source — it would scatter what the CI lint currently holds in one verified location.

This decision is intentionally reference-only. The subject file, the canonical rule files,
`verbatim-block-lint.sh`, and the auto-loaded rule corpus remain byte-for-byte unchanged.

## 1. Trigger and current evidence

Issue #1033 was filed by `/wrap` churn detection after PR #1032 merged. It recorded 5 distinct
merged PRs touching the file since 2026-07-30: PRs #787, #839, #858, #870, #920.

Measured at `main` after PR #1032, the file is 60 lines and ~480 words — single-topic, well
below the 2,000-word per-file warning.

| Churn class | PRs | What changed |
|-------------|-----|--------------|
| File creation — extraction from `subagent/SKILL.md` | PR #839 | New canonical home created; SAFETY/MINDSET/SKILLS blocks moved from duplicated inline positions in Phase A/B/C templates |
| Capability-ladder evolution (MINDSET) | PRs #858, #870 | Browser added as rung 4 (#858); gated on rungs 1–3 actually failing (#870) |
| Untracked-rm permission propagation (SAFETY) | PRs #787, #920 | Non-recursive `rm` permitted on verified-untracked root-repo paths (#787); untracked selector pinned to root-repo scope (#920) |

Git history confirms the shallow checkout covers these 5 commits, consistent with the issue report.

The file has two functional consumers: Phase A and Phase B spawn-prompt templates in
`.claude/skills/subagent/SKILL.md` (which read the full file verbatim via an inline instruction),
and Phase C's SAFETY-only injection from the same skill. A reference note in
`.claude/reference/browser-capability-rung.md` also cites the MINDSET block propagation path.
One CI guard, `.github/scripts/verbatim-block-lint.sh`, byte-compares all three blocks against
their canonical rule-file sources on every PR. Because the lint enforces byte identity, every
change to a canonical block must propagate here or CI fails.

## 2. Options considered

### Option 1: Split into separate SAFETY, MINDSET, and SKILLS files

**Rejected.** The three blocks are injected together in Phase A and Phase B spawn prompts —
splitting them into separate files would require the injection instruction to name three targets
instead of one. Phase C uses SAFETY alone, which already works with the single-file layout via a
specific per-block instruction. A split would add coordination surface without removing a single
upstream edit obligation.

### Option 2: Replace verbatim copies with pointers to the canonical rule files

**Rejected.** Subagents do not auto-load `.claude/rules/` files at spawn time. The spawn-prompt
blocks must be present verbatim at the time the agent is launched. A pointer instruction such as
"read safety.md" requires a file read during prompt construction — the `/subagent` skill already
does exactly this, reading `subagent-phase-guardrails.md` and injecting its full text. Moving back
to per-rule-file reads would undo the consolidation and the CI guard that PR #839 introduced.

### Option 3: Merge into `phase-decomposition.md` or `subagent-orchestration.md`

**Rejected.** The verbatim blocks would still need byte-compare linting against their canonical
sources, but those host files carry a wide range of other content. `verbatim-block-lint.sh` locates
blocks by marker lines; merging would require the lint to search across a larger file with unrelated
content and would couple the block integrity check to a broader edit surface.

### Option 4: KEEP + record the decision (this option)

**Chosen.** The file is the correct and intentional single home for the verbatim spawn-prompt
blocks. Its churn is required propagation from canonical rule files — not an accumulation of
independent concerns. No structural change is warranted.

## 3. Canonical ownership boundaries

| Content | Runtime owner | Canonical source |
|---------|---------------|-----------------|
| SAFETY block text | `.claude/reference/subagent-phase-guardrails.md` (verbatim copy) | `.claude/rules/safety.md` |
| MINDSET block text | `.claude/reference/subagent-phase-guardrails.md` (verbatim copy) | `.claude/rules/safety.md` |
| SKILLS block text | `.claude/reference/subagent-phase-guardrails.md` (verbatim copy) | `.claude/rules/skill-first.md` |
| Byte-identity enforcement | `.github/scripts/verbatim-block-lint.sh` | CI check on every PR |
| Spawn-prompt injection instruction | `.claude/skills/subagent/SKILL.md` Phase A/B (full) and Phase C (SAFETY only) | `subagent-orchestration.md` owns the spawn requirements |

## 4. Preserved invariants

- The three verbatim blocks in this file remain byte-identical to their respective canonical rule
  files on every commit; `verbatim-block-lint.sh` CI-enforces this requirement.
- Phase A and Phase B spawn prompts continue to receive all three blocks (SAFETY, MINDSET, SKILLS)
  via the full-file verbatim injection instruction in `subagent/SKILL.md`.
- Phase C (`phase-c-merger`) continues to receive only the SAFETY block — no MINDSET, no SKILLS —
  per the constraint in `subagent-orchestration.md`.
- The injection instruction in `subagent/SKILL.md` remains the single caller; no additional
  consumers are introduced.
- `verbatim-block-lint.sh`'s `VERBATIM_COPIES` array continues to list this file as a declared
  copy surface for all three blocks.

## 5. Remediation and verification

The remediation adds only this decision record and its catalog entry in
`.claude/reference/README.md`. Verification must confirm:

- no diff in `subagent-phase-guardrails.md`, the canonical rule files (`.claude/rules/safety.md`,
  `.claude/rules/skill-first.md`), or any auto-loaded rule corpus file;
- exactly one catalog entry for this file in `README.md`;
- `reference-catalog-lint.sh` exits clean;
- `verbatim-block-lint.sh` exits clean (the blocks remain byte-identical); and
- the full Bash and Python test suites remain green.

## 6. Future edits and reconsideration

Edit `subagent-phase-guardrails.md` only when one of its canonical rule files changes — the
change must propagate here to keep the CI lint green. No other edit is warranted; all policy
intent lives upstream.

Reconsider the file's role if the harness gains native verbatim-block injection that does not
require a separate reference file, or if `verbatim-block-lint.sh` is extended to support inline
rule-file sources instead of declared copy surfaces. In either case, the change should simplify
the injection path, not add a new one.

## 7. Related precedent

- `.claude/reference/phase-a-fixer-hotspot-decision.md` — KEEP when churn is required propagation
  of safety/capability policy into a self-contained agent contract (Issue #975).
- `.claude/reference/agents-readme-hotspot-decision.md` — KEEP when churn is coordinated policy
  propagation into the authoritative documentation surface; PR #1016 context included (Issue #973).
- `.claude/reference/pm-worker-hotspot-decision.md` — KEEP when dominant driver is safety-block
  propagation, not accumulation of independent concerns (Issue #1023).
- `.claude/reference/phase-b-reviewer-hotspot-decision.md` — KEEP when churn follows the
  embedded safety posture rather than independent runtime concerns (Issue #942).
- `.claude/reference/churn-hotspots.md` — hotspot reports are observational and require
  adjudication before any operative change is made.
