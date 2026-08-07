<!-- churn-hotspot: .claude/skills/prompt/SKILL.md -->
# Hotspot Decision — prompt/SKILL.md

**Verdict:** KEEP as canonical chip-emitter skill (no operative change)
**Decided:** 2026-08-06
**Issue:** #949
**Reporter:** `/wrap` post-merge churn report (PR #945); updated to 12 PRs after PR #946

## Executive summary

### Verdict: **KEEP** the skill; make **no operative change**

Keep `.claude/skills/prompt/SKILL.md` as the single canonical `/prompt` entry point. Do not extract
the complexity-classification table, output templates, or edge cases into a `references/` subfolder.

The 12 reported touches span from the initial model-guard addition (#615) through PR #946. Seven of
those 12 PRs (#615, #736, #738, #760, #786, #799, #878) are the same PRs that touched
`chip-launching.md` over its reported 14-PR window — the chip contract changes land in
`chip-launching.md` and then propagate verbatim to each of the six canonical emitters, including
`/prompt`, by design. The remaining five PRs (#621, #734, #750, #812, #946) introduced
skill-specific capabilities or fixes: PM inline subagent partitioning, Heavy effort recalibration,
model-family vocabulary enforcement, a lint-placement statement fix, and compact result contracts.

None of the 12 PRs shows the independently-churning concern pattern that justified extraction in
`fixpr-hotspot-decision.md`. The chip-contract half is required propagation; the skill-specific half
is new-capability authoring that added content once and did not recurse back for repeated fixes.

This decision is intentionally reference-only. `prompt/SKILL.md`, its callers, rules, scripts,
tests, and CI enforcement remain byte-for-byte unchanged.

## 1. Trigger and measured evidence

Issue #949 recorded 11 merged PRs touching `prompt/SKILL.md` since 2026-07-19: PRs #615, #621,
#734, #736, #738, #750, #760, #786, #799, #812, and #878. PR #946 was appended as a 12th touch
after the initial report.

Measured at `main` `7bbccb0`, the skill is 460 lines and approximately 6,100 words across ten
logical sections (Steps 0–6, Subagent Candidates Template, Output Template including the per-issue
prompt block skeleton, Edge Cases, and Usage Examples).

| Churn class | PRs | What changed |
|-------------|-----|--------------|
| Chip-contract propagation — shared with chip-launching.md | #615, #736, #750, #760, #799, #812 | MODEL GUARD preamble added; guard propagated to all six emitters; model-family vocabulary enforced; merge-authority bullet added; effort picker labels and versionless names; lint-placement statement fix |
| Skill-specific feature authoring | #621, #738, #786, #878, #946 | PM inline subagent partitioning (Step 5.5 + Step 6 delivery mode); author-scoping for ceiling counts; too-big fit bar recalibrated from size to resumability; claim-at-pick added to Constraints; compact result contracts |
| Classification rule update | #734 | Heavy effort default changed from Max to Extra with a documented Max step-up |

The chip-contract class (6 PRs) is required by `/prompt`'s role as one of the six canonical chip
emitters. Two CI lint scripts anchor directly to the inline literals they establish:

- `.github/scripts/chip-model-guard-lint.sh` — requires `spawn_task`, `**Model:**`, `**Effort:**`,
  `model-guard preamble`/`MODEL GUARD`, first-line and no-blank-line placement, short-summary
  repetition, and `parent thread is on Fable` — all must stay inline in `SKILL.md`.
- `.github/scripts/merge-authority-lint.sh` — requires the verbatim `CANONICAL_BULLET` (the
  `/wrap`-auto-merge sentence) to appear in `SKILL.md` exactly as it does in `chip-launching.md`.

Moving any of those strings to a reference file without updating both lints and their fixtures would
break CI. The extraction is therefore not a documentation move; it is an enforcement-contract change.

## 2. Overlap with chip-launching.md churn

The companion adjudication for `chip-launching.md` (Issue #916, PR #1045) recorded 14 PRs touching
that file, with the following list: #615, #645, #702, #713, #736, #738, #760, #775, #786, #799,
#842, #857, #878, #1008.

Comparing lists:

| PR | In chip-launching.md | In prompt/SKILL.md | Churn class |
|----|---------------------|-------------------|-------------|
| #615 | Yes | Yes | Chip contract — MODEL GUARD add |
| #621 | No | Yes | Skill-specific — PM inline subagent |
| #734 | No | Yes | Classification — effort default |
| #736 | Yes | Yes | Chip contract — guard propagation |
| #738 | Yes | Yes | Chip contract / skill — author-scoping |
| #750 | No | Yes | Propagation — model-fleet vocabulary |
| #760 | Yes | Yes | Chip contract — merge-authority |
| #786 | Yes | Yes | Chip contract / skill — too-big recalibration |
| #799 | Yes | Yes | Chip contract — effort lines |
| #812 | No | Yes | Fix — lint-placement statement |
| #878 | Yes | Yes | Chip contract / skill — claim-at-pick |
| #946 | No | Yes | Skill-specific — compact result contracts |

Seven of twelve PRs are shared. The `/prompt` skill touches more file surface per chip-contract PR
than `chip-launching.md` does (it is an emitter that must copy the contract forward, not the
source), but the churn cause is the same event. Future chip-contract additions will continue to land
in both files by design.

## 3. CodeRabbit plan adjudication

CodeRabbit's plan recommended extracting three concerns:
1. Complexity signals table and tier decision tree → `references/prompt-complexity-classification.md`
2. Output templates and sample renderings → `references/prompt-output-templates.md`
3. Edge cases and usage examples → `references/prompt-edge-cases.md`

The extraction is not applied for the following reasons.

### Constraint A — lint anchors block safe extraction

The lint scripts enforce specific literal strings in `SKILL.md`. Moving the MODEL GUARD preamble
requirement, the merge-authority bullet, the effort-label teaching paragraph, or the no-blank-line
placement rule to a reference file would require updating both lint scripts and their fixture suites.
That scope exceeds an observational churn remediation.

The `prompt/SKILL.md` content that the lints check is not incidental prose — it is the literal
instruction surface that a launched thread reads as its immediate directive. A launched thread cannot
read a transitive include from a `references/` subfolder unless the delivery model is explicitly
changed. The lints enforce that the instruction is present at the emitter level precisely because
of this.

### Constraint B — extractable concerns show no independent-churn pattern

A justified extraction requires sections that iterate by different owners on independent timelines.
The three proposed extraction targets do not meet this bar:

- **Complexity signals table and decision tree** (Steps 4–5): Touched by #734 (effort default) and
  #786 (too-big recalibration). Both are single-PR capability additions that did not recurse. The
  effort default change (1 PR) and fit-bar change (1 PR) are one-time additions, not ongoing
  maintenance from a distinct owner.
- **Output templates** (Step 6 and the per-issue block skeleton): The Step 6 content is the primary
  site of chip-contract propagation (#615, #736, #750, #760, #799, #812). The lint-enforced strings
  are concentrated here. Extracting the templates means either extracting the lint-guarded strings
  (requiring lint changes) or splitting the template into two fragments (a guarded inline section
  and a referenced skeleton), which adds delivery complexity without reducing churn.
- **Edge cases and usage examples**: Touched by #878 (claim-at-pick Constraints addition). The edge
  cases section itself has not churned repeatedly; #878 added a new constraint bullet, not a
  repeated edit to an existing one.

### Constraint C — size is not churn

The `prompt/SKILL.md` file is long (460 lines) because it is the canonical teaching surface for
complexity classification and prompt-block assembly. Length is a reading concern, not a churn
concern. The hotspot report measures edit frequency, not file size. Extracting long-but-stable
sections would optimize file shape rather than the measured failure mode.

## 4. Options considered

### Option 1: Extract complexity classification, output templates, and edge cases

**Rejected.** Constraint A (lint anchors) makes the template extraction non-trivial. Constraints B
and C establish that none of the proposed sections shows the independent-churn pattern that would
justify the extraction overhead. This option addresses size; it does not address churn.

### Option 2: Keep the skill and record the ownership decision

**Chosen.** This records how to classify future touches, preserves the lint-enforced instruction
surface, and avoids changing a working emitter's delivery contract to address an observational
report.

## 5. Canonical ownership

| Content | Operative owner | Shared/detailed owner |
|---------|-----------------|-----------------------|
| PM auto-detect context, inclusion/exclusion logic | `prompt/SKILL.md` Steps 0, 5.5 | `/pm`'s `## Active Work` table is the canonical active-work state |
| Issue-data fetch and CR-plan extraction | `prompt/SKILL.md` Steps 1–2 | `cr-plan.sh` owns substantive-plan detection |
| Complexity signals table | `prompt/SKILL.md` Step 4 | No shared consumer; fully owned here |
| Tier decision tree including effort and model step-ups | `prompt/SKILL.md` Step 5 | `chip-launching.md` "Model Lineup" owns the fleet vocabulary |
| Subagent partitioning and too-big classification | `prompt/SKILL.md` Step 5.5 | `too-big-recalibration-2026-07.md` owns the rationale |
| Delivery mode, chip vs fallback, chip lifecycle | `prompt/SKILL.md` Step 6 | `chip-launching.md` owns shared chip semantics; emitter lints enforce required literals |
| Per-issue prompt block, Constraints bullet, Exit Criteria | `prompt/SKILL.md` Step 6 Output Template | `chip-launching.md` "Merge-authority line" owns the CANONICAL_BULLET; `merge-authority-lint.sh` enforces it |
| Edge cases and usage examples | `prompt/SKILL.md` Edge Cases, Usage Examples | No shared consumer; fully owned here |

Every content area is either exclusively owned by this skill or references a named upstream with its
own enforcement. None is owned by a subconcern with an independent maintenance lifecycle that would
be decoupled by extraction.

## 6. Preserved invariants

- `prompt/SKILL.md` remains the single canonical `/prompt` entry point, unchanged.
- The chip-model-guard lint strings — `spawn_task`, `**Model:**`, `**Effort:**`, `MODEL GUARD` /
  `model-guard preamble`, first-line and no-blank-line placement, short-summary, `parent thread is
  on Fable` — stay inline in `SKILL.md`.
- The verbatim merge-authority `CANONICAL_BULLET` stays inline in the `## Constraints` block.
- The effort-label teaching paragraph (Low/Medium/High/Extra/Max mapping) stays inline in the Model
  Lineup section — the file is the single teaching point for that mapping.
- `chip-model-guard-lint.sh` and `merge-authority-lint.sh` pass without modification.
- Six canonical emitters, two CI lint scripts, `chip-spawn.md`, and all six emitter SKILL.md files
  remain byte-for-byte unchanged.

## 7. Future edits and reconsideration

Future chip-contract changes (a new guard preamble clause, a new effort-label entry, a merge-
authority reword) should update `prompt/SKILL.md` in the same PR as the other five canonical
emitters. That fanout is intentional until the repository adopts and tests a composite
emitter-loading contract with CI enforcement.

Future classification changes (a new complexity signal, a tier boundary shift) should update Steps
4–5 directly. If classification rules show repeated independent iteration from a distinct owner, a
`references/prompt-complexity-classification.md` extraction becomes more justified — that would
require no lint changes and would not fragment the lint-enforced emitter contract.

Reconsider output-template extraction if CI gains explicit support for validating a prompt assembled
from `SKILL.md` plus referenced fragments (the current lints require the strings to be in `SKILL.md`,
not a transitive include).

## Related precedent and references

- `.claude/reference/chip-launching-hotspot-decision.md` — companion KEEP decision (Issue #916);
  `chip-launching.md` is the canonical chip contract source; `/prompt` is one of six canonical
  emitters consuming it; 7 of 12 prompt-SKILL.md churn PRs are shared with chip-launching.md
- `.claude/reference/start-issue-hotspot-decision.md` — KEEP/no-operative-change for another
  canonical emitter (`start-issue/SKILL.md`, Issue #981, 9 PRs); same chip-contract propagation
  pattern and same extraction rejection reasoning
- `.claude/reference/fixpr-hotspot-decision.md` — the extraction precedent: justified when three
  independently-changing deterministic blocks each had a distinct owner and no lint anchors
- `.claude/reference/claude-md-hotspot-decision.md` — KEEP when a cohesive loaded contract is
  frequently updated by cross-cutting policy
- `.github/scripts/chip-model-guard-lint.sh` — enforces model-guard contracts in each emitter skill
- `.github/scripts/merge-authority-lint.sh` — enforces merge-authority contract in each emitter skill
- Issue [#949](https://github.com/auerbachb/claude-code-config/issues/949) — this adjudication
- Issue [#916](https://github.com/auerbachb/claude-code-config/issues/916) — chip-launching.md adjudication
- Issue [#981](https://github.com/auerbachb/claude-code-config/issues/981) — start-issue/SKILL.md adjudication
- Issue [#601](https://github.com/auerbachb/claude-code-config/issues/601) — model guard origin
- Issue [#788](https://github.com/auerbachb/claude-code-config/issues/788) — fixpr extraction precedent (the bar extraction must clear)
