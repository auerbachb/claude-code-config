# Start-Issue Hotspot Decision

Reference for Issue #981 (`.claude/skills/start-issue/SKILL.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the seven-step skill; make **no operative change**

Keep `.claude/skills/start-issue/SKILL.md` as the single issue-to-coding entry point. Do not split
the workflow, extract Step 3 or Step 7, or deduplicate its claim and issue-creation gates in this
remediation.

The nine reported touches are not nine rounds of unrelated growth. Seven propagated changes to the
shared chip/handoff contract into the canonical `/start-issue` emitter. The other two introduced
distinct capabilities: repo-wide issue deduplication and claim-at-pick with inherited handoff. None
of the cited PRs changed CR-plan polling. The observed churn is therefore coordinated contract
delivery, not evidence that the seven-step state machine has separable runtime owners.

This decision is intentionally reference-only. The operative skill, its callers, rules, scripts,
tests, and CI enforcement remain byte-for-byte unchanged.

## 1. Trigger and measured evidence

Issue #981 recorded nine merged PRs touching `start-issue/SKILL.md` since 2026-07-20: PRs #615,
#713, #725, #736, #750, #760, #786, #799, and #878.

Measured at `main` `835c60f4f63f8664b2e6585d449e48c4d685d6a3`, the skill is 337 lines and
3,841 words. The changes divide cleanly by responsibility:

| Churn class | PRs | What changed |
|-------------|-----|--------------|
| Step 7 chip and handoff contract | PRs #615, #713, #736, #750, #760, #786, #799 | Model guard, PM-inline routing, model-family vocabulary, effort recommendation, merge authority, and the subagent-fit threshold propagated into this canonical emitter |
| Step 1a issue deduplication | PR #725 | Added human-in-the-loop duplicate surfacing for newly drafted issues |
| Step 2b claim and Step 7 inheritance | PR #878 | Added claim-at-pick before planning/worktree creation and handed the exact holder to the coding thread |
| Step 3 CR-plan polling | None | No cited PR changed the polling paths, workflow-run classification, or manual-trigger fallback |

The Step 7 changes are coordinated by design. `chip-launching.md` defines shared semantics, while
each canonical emitter owns its variable mapping, prompt shape, and delivery behavior. Two CI
checks enforce that boundary directly:

- `chip-model-guard-lint.sh` requires the `spawn_task`, model, effort, guard-placement,
  short-summary, and Fable-warning contracts in each emitter's `SKILL.md`.
- `merge-authority-lint.sh` requires the complete merge-authority sentence verbatim in each
  emitter's `SKILL.md`, because the launched coding thread reads that prompt as its immediate
  instruction surface.

Moving those literals to a sibling reference would not be a documentation-only move. It would
require changing both enforcement programs and their fixtures to redefine what counts as an
operative canonical emitter. The hotspot report records no failed load, drift, or merge-conflict
evidence that justifies that contract change.

## 2. CodeRabbit plan adjudication

CodeRabbit correctly identified the available structural choices, the need to retain the numbered
spine and handoff tokens, the value of a durable decision, and the existing extraction precedent in
`fixpr-hotspot-decision.md`. Its proposed extraction is not applied because the repository history
does not support both proposed boundaries and the current enforcement model makes one of them
non-trivial.

### Proposed Step 3 CR-plan extraction

Rejected for this remediation. None of the nine cited PRs touched Step 3. Extracting its fresh/old
issue paths, workflow-status classification, and manual fallback would reorganize a stable section
without reducing the measured source of churn. The deterministic plan detection already belongs to
`cr-plan.sh`; the skill retains the user-facing branch and failure decisions needed to operate it.

### Proposed Step 7 chip/handoff extraction

Deferred pending behavioral evidence. Step 7 is the dominant edit surface, but those edits are
intentional propagation into a literal prompt emitter rather than independent implementation
changes. The CI checks above deliberately inspect `SKILL.md`, not a transitive include. Repointing
them would broaden this observational ticket into a prompt-loading and enforcement refactor.

### Proposed claim and dedup prose removal

Rejected for this remediation. Step 2b is a correctness gate whose placement and fail-closed
branches must be salient before any planning or worktree operation. Step 1a is the human-facing
branch that distinguishes a strong duplicate from an issue that should still be created. Each was
introduced once in the measured window; neither shows repeat edits or source drift. Their canonical
references own rationale and cross-entry consistency, while the skill owns the concrete action at
this entry point.

## 3. Options considered

### Option 1: Split the skill into planning, worktree, and handoff skills

**Rejected.** The outputs are sequentially dependent: the claim gates planning; the merged plan
determines the handoff; the worktree path and claim holder are inputs to the final prompt. A split
would add routing and state-transfer boundaries while every current caller still needs the complete
issue-to-coding transaction.

### Option 2: Extract Steps 3 and 7 into sibling references

**Rejected for the current evidence.** Step 3 did not churn. Step 7 is a deliberately literal
emitter checked by CI. Extracting both because they are long would optimize file shape rather than
the reported failure mode and would make behavior depend on a new transitive-loading contract.

### Option 3: Deduplicate Step 1a and Step 2b toward canonical references

**Rejected for the current evidence.** The references already own shared definitions; the skill
owns this entry path's executable commands, outcomes, and hard stops. Neither section has shown
repeated maintenance since it landed.

### Option 4: Keep the runtime skill and record the ownership decision

**Chosen.** This records how to classify future touches, preserves the high-salience gates, and
avoids changing user-visible CLI/handoff behavior to address an observational counter.

## 4. Canonical ownership boundaries

| Content | Operative owner | Shared/detailed owner |
|---------|-----------------|-----------------------|
| Argument parsing and new-vs-existing issue routing | `start-issue/SKILL.md` Steps 1-2 | `issue-planning.md` owns the repository-wide issue-flow requirement |
| Duplicate surfacing for a newly drafted issue | `start-issue/SKILL.md` Step 1a | `autofile-dedup.md` owns match classification and cross-filer policy |
| Claim check, acquisition, fail-closed outcomes, and exact holder capture | `start-issue/SKILL.md` Step 2b | `issue-claim.md` and `issue-claim.sh` own the cross-entry contract and mechanism |
| CR plan age paths and workflow fallback decisions | `start-issue/SKILL.md` Step 3 | `cr-plan.sh` owns substantive-plan detection and polling mechanics |
| Claude analysis plus canonical issue-body upsert | `start-issue/SKILL.md` Steps 4-5 | `issue-planning.md` owns the before-code planning gate |
| Root-main sync and isolated branch/worktree creation | `start-issue/SKILL.md` Step 6 | `main-hygiene.md` owns repository-wide hygiene and recovery behavior |
| Skill-specific chip/fallback prompt, variable mapping, and execution boundary | `start-issue/SKILL.md` Step 7 | `chip-launching.md` owns shared chip semantics; emitter lints enforce required local literals |

Detailed references explain common policy and rationale. They do not replace this skill's concrete
ordering, branch outcomes, or prompt payload unless a dedicated loader/enforcement change first
makes that indirection explicit and testable.

## 5. Preserved invariants

- An issue is claimed at pick time before CR-plan polling, issue-body planning, or worktree
  creation; `claimed` and `unknown` remain hard stops unless the live user explicitly overrides the
  named issue.
- A substantive CodeRabbit plan is incorporated when available, Claude's repository analysis is
  always performed, and one `## Implementation Plan` is present in the issue body before coding.
- Existing issue text survives the plan upsert, repeated runs do not duplicate the plan section,
  and the confirmation comment identifies whether CodeRabbit contributed.
- Work happens only in an issue-specific worktree and branch after a fast-forward main sync; pull,
  checkout, or worktree failures stop rather than discard user state.
- Step 7 still emits exactly one delivery: inline recommendation, task chip, or fallback block. A
  failed chip offer still falls back once rather than retrying or losing the handoff.
- The chip and fallback content remain byte-identical where required. Model and effort lines,
  model-guard placement, Fable pre-click warning, short summary, claim-holder inheritance, and the
  verbatim merge-authority line remain intact.
- The launched thread re-affirms the exact inherited claim holder, stays out of `main` and `.env`
  files, runs local review before push, and auto-runs `/wrap` only after the merge gate and every
  Test Plan or acceptance-criteria checkbox verify.
- Offering a chip remains distinct from launching it; `/start-issue` stops at the handoff boundary
  and never clicks or performs the coding thread's work itself.
- The frontmatter, seven numbered steps, CLI examples, edge-case stops, callers, scripts, and CI
  enforcement remain unchanged.

## 6. Remediation and verification

The remediation adds only this decision record and its reference-catalog entry. Verification must
prove:

- no diff in `start-issue/SKILL.md`, its callers, `.claude/rules/`, `.claude/scripts/`, or
  `.github/scripts/`;
- exactly one catalog entry for this decision record;
- reference, rule, skill-convention, chip-model-guard, and merge-authority lints pass;
- all Bash and Python suites remain green; and
- the PR Test Plan maps each Issue #981 acceptance criterion to fresh evidence.

## 7. Future edits and reconsideration

Future shared chip-policy changes should continue updating Step 7 and its direct lints in the same
PR. That fanout is intentional until the repository adopts and tests a composite emitter-loading
contract. Future claim, dedup, or planning changes should update the concrete step only when this
entry path's behavior changes; rationale and cross-entry policy stay in their canonical references.

Reconsider Step 7 extraction if repeated merge conflicts or real prompt drift appear, or if CI gains
an explicit way to validate an emitter assembled from `SKILL.md` plus referenced fragments.
Reconsider Step 3 extraction only if its two paths begin changing independently or duplicate
command forms recur elsewhere. Reconsider a physical split only if callers consume independently
terminal parts of the workflow rather than the current issue-to-handoff transaction.

## Related precedent

- `.claude/reference/phase-a-fixer-hotspot-decision.md` and
  `.claude/reference/phase-b-reviewer-hotspot-decision.md` — KEEP/no-runtime-change when churn is
  required propagation into an operative instruction surface.
- `.claude/reference/claude-md-hotspot-decision.md` — KEEP/no-content-change when a cohesive loaded
  contract is frequently updated by cross-cutting policy.
- `.claude/reference/fixpr-hotspot-decision.md` — extraction is justified when independently
  changing deterministic blocks, rather than required literal policy, drive the churn.
- `.claude/reference/subagent-orchestration-churn-audit-2026-07.md` — deduplication is justified
  when the same phase descriptions demonstrably change in lockstep with canonical owners.
- `.claude/reference/churn-hotspots.md` — hotspot reports are observational and require an
  evidence-based structural verdict.
