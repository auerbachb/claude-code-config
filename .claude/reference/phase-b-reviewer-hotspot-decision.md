# Phase B Reviewer Hotspot Decision

Reference for Issue #942 (`.claude/agents/phase-b-reviewer.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the single self-contained agent definition; make **no runtime change**

Keep `.claude/agents/phase-b-reviewer.md` as the one Phase B state-machine definition. Do not split
it by reviewer, replace its embedded guardrails with pointers, or move its phase-specific handoff
and exit instructions behind a non-auto-loaded reference in this remediation.

The measured churn is primarily required propagation into a self-contained subagent prompt and
changes to Phase B's core reviewer state machine. The only large command-form addition—the locked,
repository-scoped `handoff-state.sh` update pattern—changed twice while that contract was
introduced and has not demonstrated recurring drift. A structural edit would therefore add load
and routing risk without removing a proven independent churn source.

This decision is intentionally reference-only. `.claude/agents/phase-b-reviewer.md`, its YAML
frontmatter, the other phase-agent definitions, `.claude/agents/README.md`, and the auto-loaded rule
corpus remain byte-for-byte unchanged.

## 1. Trigger and current evidence

Issue #942 recorded 11 merged PRs touching `phase-b-reviewer.md`: PRs #617, #626, #718, #724,
#747, #762, #787, #817, #858, #902, and #920. Current `main` adds PRs #945, #954, and #978,
producing 14 touches since 2026-07-19:

| Churn class | PRs | What changed |
|-------------|-----|--------------|
| Embedded safety and capability posture | PRs #762, #787, #817, #858, #902, #920 | The in-agent safety/capability block followed repository-wide policy changes |
| Reviewer state machine and freshness | PRs #626, #747, #945, #954, #978 | CodeAnt approval, polling watermarks, BugBot invitation/freshness, and grace timing |
| Handoff durability and scoping | PRs #718, #724 | Locked handoff writes and per-repository handoff paths |
| Skill-first delivery | PR #617 | Added the subagent skill-first reminder |

Measured at `main` `ed18fdc470f1f13774e899eb9149a90050d545a9`, the definition is 341 lines and
3,137 words. Its size merits continued review, but size alone does not identify a safe extraction
boundary. Six of the 14 changes updated the intentionally embedded safety/capability posture, five
updated the review loop that Phase B exists to execute, and one delivered the required skill-first
posture. Those 12 touches would still require coordinated behavior changes after a physical split.

The remaining two touches introduced handoff locking and repository scoping. They are consecutive
evolution of one new durability contract, not repeated maintenance of duplicate implementations.
There is no measured conflict-round evidence in the hotspot report, so the current signal is edit
frequency rather than demonstrated merge pain.

## 2. Why CodeRabbit's pointer extraction is not applied

CodeRabbit's plan correctly identified the available design choices, existing canonical references,
the need for a durable decision, and the invariants that must survive. Its proposed replacement of
embedded safety, reviewer-gate, severity, and exit-report instructions with short pointers is not
safe under the current loading model.

`.claude/agents/README.md` defines agent files as self-contained definitions with embedded rules;
subagents do not auto-load `.claude/rules/`. The Phase B definition can cite canonical owners for
procedural detail, but its operative safety posture, path transitions, sticky-reviewer behavior,
push boundary, and exit vocabulary must remain present when the agent is spawned. Moving those
instructions to this non-auto-loaded directory would make correct behavior depend on an extra read
that the harness does not guarantee.

The proposed handoff consolidation would also edit `phase-a-fixer.md`, and potentially
`subagent/SKILL.md`, to remove a short bootstrap loop that is intentionally usable from multiple
installation layouts. That expands an observational Phase B ticket across additional runtime
surfaces without evidence that the loop continues to churn or drift.

The plan's useful ownership and verification requirements are retained below; only the speculative
runtime patch list is superseded by current evidence.

## 3. Options considered

### Option 1: Split Phase B into CR, BugBot, and Greptile agents

**Rejected.** Reviewer assignment can change inside one Phase B cycle through the mandatory
escalation gate, and BugBot/Greptile assignment is sticky for the life of the PR. Separate agent
definitions would duplicate initialization, CI, finding processing, push-boundary, handoff, and
exit behavior, then require a new intra-phase handoff protocol whenever the reviewer changes. That
weakens A → B → C independence rather than isolating it.

### Option 2: Replace operative sections with reference pointers

**Rejected under the current loader.** Canonical references are valuable for rationale and precise
path semantics, but they are not auto-loaded subagent context. Pointer-only safety, failure, or exit
instructions would contradict the repository's self-contained-agent contract.

### Option 3: Extract the handoff command form into another helper or reference

**Deferred pending evidence.** `handoff-state.sh` already owns locking, repository scoping,
deduplication, and forward-compatible writes. The agent's remaining block resolves the installed
script and supplies Phase B-specific fields. Its two historical changes established those
contracts; no recurring duplicate-maintenance pattern is present after PR #724.

### Option 4: Keep the runtime definition and record the ownership decision

**Chosen.** This closes the observational ticket with an explicit boundary while avoiding a
behavioral refactor whose principal effect would be hiding required prompt context behind files
the subagent does not automatically receive.

## 4. Canonical ownership boundaries

| Content | Runtime owner | Detailed/canonical owner |
|---------|---------------|--------------------------|
| Phase B initialization, reviewer transitions, polling loop, finding processing, and exit decision | `.claude/agents/phase-b-reviewer.md` | `.claude/rules/cr-github-review.md` and path-specific references define shared review semantics |
| Merge readiness and current-HEAD approval | `polling-state-gate.sh` / `merge-gate.sh` invoked by Phase B | `.claude/rules/cr-merge-gate.md` and `.claude/reference/merge-gate-reviewer-paths.md` document the gate |
| Sticky reviewer assignment and escalation | `escalate-review.sh` and `reviewer-of.sh` invoked by Phase B | `.claude/rules/bugbot.md` and `.claude/rules/greptile.md` own reviewer policy |
| Handoff locking, scoping, deduplication, and schema | `handoff-state.sh` invoked with Phase B-specific fields | `.claude/rules/handoff-files.md`, `state-file-contracts.md`, and `handoff-file-schema.json` own the contract |
| Structured report fields and outcome meanings | The Phase B definition must emit the report | `.claude/rules/phase-protocols.md` and `.claude/reference/exit-report-format.md` own the cross-phase format |
| Destructive-action, secret, capability, and skill-first posture | Embedded in the agent definition for spawn-time availability | `.claude/rules/safety.md` and `.claude/rules/skill-first.md` remain canonical for repository-wide changes |
| Agent catalog, model, frontmatter, and load behavior | `.claude/agents/README.md` | `.claude/rules/subagent-orchestration.md` owns spawn requirements |

References explain or specialize these contracts; they do not replace the minimum operative text
that must be present in the spawned Phase B agent.

## 5. Preserved invariants

- Phase A → B → C remains three independent agents joined only by the scoped handoff and verified
  HEAD SHA.
- Phase B retains one reviewer state machine with CR → BugBot → Greptile escalation and sticky
  BugBot/Greptile assignment.
- Every push remains a review boundary: the pushed HEAD must receive the required response before
  Phase B may report `merge_ready`.
- `polling-state-gate.sh` / `merge-gate.sh` remains the only merge-ready exit gate; empty threads or
  a completed review check alone do not satisfy it.
- CI failures, human `CHANGES_REQUESTED`, unresolved threads, stale approvals, and reviewer-specific
  freshness rules retain their existing owners and failure behavior.
- Handoff writes remain locked, repository-scoped, forward-compatible, and performed through
  `handoff-state.sh`; unknown fields remain preserved.
- The structured exit report and `merge_ready`, `clean`, `fixes_pushed`, and `exhaustion` meanings
  remain unchanged.
- YAML frontmatter, agent catalog entries, explicit model selection, and full-tool load behavior
  remain unchanged.

## 6. Remediation and verification

The remediation adds only this decision record and its reference-catalog entry. Verification must
prove:

- no diff in `phase-b-reviewer.md`, its frontmatter, the other phase-agent definitions,
  `.claude/agents/README.md`, or the auto-loaded rule corpus;
- exactly one catalog entry for this file;
- reference, rule, skill-catalog, and verbatim-block lints pass; and
- hotspot-focused plus full Bash and Python test suites remain green.

## 7. Future edits and reconsideration

Edit `phase-b-reviewer.md` when the spawned Phase B runtime contract changes. Keep rationale,
compatibility history, and detailed reviewer-path semantics in references; keep deterministic
behavior in the existing scripts. Avoid copying a script's implementation back into the agent.

Reconsider splitting only if the harness gains an explicit include/composition mechanism or the
reviewer paths become independently spawned terminal phases with no intra-phase transition.
Reconsider extraction when the same deterministic command form changes repeatedly in two or more
runtime owners, or when conflict evidence—not touch count alone—shows a shared edit surface causing
delivery failures.

## Related precedent

- `.claude/reference/claude-md-hotspot-decision.md` — KEEP/no-runtime-change when churn reflects
  deliberate propagation into one always-loaded executive contract.
- `.claude/reference/monitor-mode-hotspot-decision.md` — KEEP + dedup when a concrete downstream
  restatement exists.
- `.claude/reference/fixpr-hotspot-decision.md` — KEEP + extract when repeated deterministic command
  forms, rather than required runtime policy, drive churn.
- `.claude/reference/churn-hotspots.md` — hotspot reports are observational and require adjudication.
