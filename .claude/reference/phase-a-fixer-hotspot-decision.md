# Phase A Fixer Hotspot Decision

Reference for Issue #975 (`.claude/agents/phase-a-fixer.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the self-contained agent definition; make **no runtime change**

Keep `.claude/agents/phase-a-fixer.md` as the single runtime contract for fixing review findings or
resolving merge conflicts. Do not split it by task type, replace operative instructions with
reference pointers, or introduce another script resolver in this remediation.

The nine reported touches are required propagation into a self-contained subagent prompt or the
adjacent introduction and scoping of one handoff contract. None demonstrates repeated churn in the
merge-conflict workflow, exit-report template, or script-location loop. A structural change would
therefore enlarge the runtime surface without removing a measured source of churn.

This decision is intentionally reference-only. `.claude/agents/phase-a-fixer.md`, its YAML
frontmatter, the other phase-agent definitions, `.claude/agents/README.md`, and the auto-loaded rule
corpus remain byte-for-byte unchanged.

## 1. Trigger and current evidence

Issue #975 recorded nine merged PRs touching `phase-a-fixer.md` since 2026-07-20: PRs #617, #718,
#724, #762, #787, #817, #858, #902, and #920.

| Churn class | PRs | What changed |
|-------------|-----|--------------|
| Embedded safety and capability posture | PRs #762, #787, #817, #858, #902, #920 | The in-agent safety/capability block followed repository-wide policy changes |
| Handoff durability and scoping | PRs #718, #724 | Added locked handoff writes, then repository-scoped paths |
| Skill-first delivery | PR #617 | Added the required spawned-agent skill-first reminder |

Measured at `main` `dec7dcf86bc929f19089bb92008a2231a822bfe6`, the definition is 216 lines and
1,740 words. Six of nine touches changed the deliberately embedded safety/capability posture. Two
consecutive touches established one new handoff contract. The remaining touch delivered required
skill-first behavior. A physical split would not eliminate any of those coordinated updates.

No touch in the reported window changed the merge-conflict workflow or the structure and semantics
of the exit-report block. The handoff work introduced the `handoff-state.sh` location loop and updated
the report's handoff path, but the hotspot report contains no conflict-round or failed-delivery
evidence, so the current signal is edit frequency rather than proven structural friction.

## 2. CodeRabbit plan adjudication

CodeRabbit correctly identified the available design choices, the existing canonical sources, the
need to keep the literal report the parent parses, and the value of a durable hotspot decision. Its
proposed runtime changes are not applied because repository history does not connect them to the
measured churn.

Delegating the merge-conflict section wholesale would also change its effective contract. The
canonical skill is report-first for complex hunks and says not to edit them without a user request;
Phase A is an autonomous fixer that resolves complex hunks when judgment is sufficient and reports
`blocked` only for genuinely unresolvable semantic conflicts. Reconciliation could be designed,
but an observational churn ticket is not evidence for changing that behavior.

The proposed generic script resolver would edit Phase B and the script-extraction registry to
replace a short bootstrap loop that has not changed since repository scoping landed in PR #724.
`handoff-state.sh` already owns the deterministic locking, scoping, validation, and write behavior;
the inline loop only makes that owner reachable across supported installation layouts.

The exit-report template likewise did not drive this churn window. The literal Phase A vocabulary
must remain available in the spawned prompt because the parent parses it strictly. A reference may
document field semantics, but it cannot replace the operative output block under the current load
model.

## 3. Options considered

### Option 1: Split fix work and merge-conflict work into separate agents

**Rejected.** Both task types require the same safety posture, isolated branch handling, single-push
boundary, scoped handoff, strict exit report, and parent transition. Splitting would duplicate those
contracts and add task-routing/catalog surface while leaving all nine measured changes coordinated.

### Option 2: Replace operative sections with canonical-source pointers

**Rejected under the current loader.** Subagents do not auto-load `.claude/rules/` or reference
files. The agent definition must remain self-contained for safety, escalation, failure handling,
handoff, and exit behavior. The merge-conflict skill also has a different complex-hunk interaction
boundary, so a pointer is not behavior-neutral.

### Option 3: Extract the script-location loop to a generic resolver

**Deferred pending evidence.** The loop changed only while the handoff contract was introduced and
repository-scoped. It has shown neither recurring drift nor independent complexity. A generic helper
would need its own bootstrap path and would expand this ticket into Phase B without reducing the
dominant safety-policy churn.

### Option 4: Keep the runtime definition and record the ownership decision

**Chosen.** A reference-only decision makes the next hotspot report evidence-aware while preserving
the complete prompt that every Phase A launch receives.

## 4. Canonical ownership boundaries

| Content | Runtime owner | Detailed/canonical owner |
|---------|---------------|--------------------------|
| Task dispatch, finding verification, fix loop, commit/push boundary, replies, and thread resolution | `.claude/agents/phase-a-fixer.md` | Review rules and shared scripts define cross-workflow semantics |
| Merge-conflict classification and diff-survival mechanics | Phase A's task-specific wrapper | `.claude/skills/merge-conflict/SKILL.md` and its scripts own reusable mechanics; Phase A retains its autonomous complex-hunk policy |
| Handoff locking, repository scoping, validation, and schema | `handoff-state.sh` invoked with Phase A fields | `.claude/rules/handoff-files.md`, `state-file-contracts.md`, and `handoff-file-schema.json` own the shared contract |
| Structured report fields and outcome meanings | The Phase A definition emits the literal report | `.claude/rules/phase-protocols.md` and `.claude/reference/exit-report-format.md` own the cross-phase format |
| Destructive-action, secret, capability, and skill-first posture | Embedded in the agent definition for spawn-time availability | `.claude/rules/safety.md` and `.claude/rules/skill-first.md` own repository-wide changes |
| Agent catalog, model, frontmatter, and load behavior | `.claude/agents/README.md` | `.claude/rules/subagent-orchestration.md` owns spawn requirements |

References explain or specialize these contracts; they do not replace the minimum operative text
that must be present in the spawned Phase A agent.

## 5. Preserved invariants

- The upstream implementation flow still begins with claim verification and a
  CodeRabbit-plus-Claude plan merged into the issue body before coding.
- Initial implementation and later review fixes still run in isolated issue worktrees; `main` is
  never a writing surface.
- The upstream pre-PR local review still runs both available CLIs to a verified clean pass, records
  coverage, and fixes valid findings without suppressions before its push boundary.
- The Phase A fixer still stages named files, commits findings in one batch, and pushes once against
  the already-linked PR; PR creation and its acceptance-criteria Test Plan remain owned by the
  initial implementation flow.
- GitHub findings and CI failures still receive evidence-based fixes; bot threads are replied to and
  resolved through the shared helpers, while reviewer polling and escalation remain owned by the
  parent and Phase B.
- Handoff writes remain locked, repository-scoped, forward-compatible, and performed through
  `handoff-state.sh`; unknown fields remain preserved.
- The literal `EXIT_REPORT`, Phase A outcome vocabulary, HEAD SHA evidence, and `NEXT_PHASE` values
  remain unchanged.
- The parent still verifies the pushed SHA and handoff, removes the Phase A worktree, and launches an
  independent Phase B agent before any merge phase.
- YAML frontmatter, the agent catalog, explicit model selection, and full-tool loading remain
  unchanged.

## 6. Remediation and verification

The remediation adds only this decision record and its reference-catalog entry. Verification must
prove:

- no diff in `phase-a-fixer.md`, its frontmatter, the other phase-agent definitions,
  `.claude/agents/README.md`, or the auto-loaded rule corpus;
- exactly one catalog entry for this file;
- reference, rule, skill-catalog, and verbatim-block lints pass; and
- hotspot-focused plus full Bash and Python test suites remain green.

## 7. Future edits and reconsideration

Edit `phase-a-fixer.md` when the spawned Phase A runtime contract changes. Keep rationale,
compatibility history, and detailed shared semantics in references; keep deterministic operations in
the existing scripts. Do not hide required safety or exit behavior behind a non-auto-loaded pointer.

Reconsider splitting only if the harness gains explicit include/composition support, the task types
become independently spawned terminal phases, or measured conflicts isolate them as separate edit
surfaces. Reconsider helper extraction when the same command form changes repeatedly in two or more
runtime owners. Reconcile merge-conflict delegation in a dedicated behavior issue if Phase A should
adopt the skill's report-first complex-hunk boundary.

## Related precedent

- `.claude/reference/phase-b-reviewer-hotspot-decision.md` — KEEP/no-runtime-change for the adjacent
  self-contained phase-agent contract.
- `.claude/reference/claude-md-hotspot-decision.md` — KEEP/no-runtime-change when churn reflects
  deliberate propagation into one always-loaded executive contract.
- `.claude/reference/monitor-mode-hotspot-decision.md` — KEEP + dedup when a concrete downstream
  restatement exists.
- `.claude/reference/fixpr-hotspot-decision.md` — KEEP + extract when repeated deterministic command
  forms, rather than required runtime policy, drive churn.
- `.claude/reference/churn-hotspots.md` — hotspot reports are observational and require adjudication.
