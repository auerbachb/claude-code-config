# Phase C Merger Hotspot Decision — August 2026

**Issue:** [Issue #976](https://github.com/auerbachb/claude-code-config/issues/976)

**Date:** 2026-08-04

## Decision

**KEEP single file + dedup toward canonical owners, not split.**

`.claude/agents/phase-c-merger.md` remains the standalone definition for the
independent verification-and-merge phase. The remedy removes selected policy
restatements while retaining every instruction that makes Phase C operational
and safe on its own.

## Churn evidence

The hotspot window contained nine merged PRs. The file history shows two kinds
of change:

| Change class | PRs | Why the agent changed |
|---|---|---|
| Shared guardrail propagation | PRs #617, #762, #787, #817, #858, #902, #920 | Skill-first, capability-discovery, browser-boundary, and destructive-command or environment-template safety contracts changed across all spawned agents. |
| Phase C behavior | PRs #724, #737 | Per-repo handoff paths and standing merge authorization changed the merger's own orchestration. |

Seven of the nine changes were required copies of shared spawn-time guardrails.
Custom agent definitions need those protections in their own prompts because
project rule files are not guaranteed to auto-load for the spawned agent. That
is propagation churn, not evidence of independently evolving Phase C
subsystems, so extracting or splitting those blocks would weaken the standalone
contract without removing their update requirement.

The remaining two changes are cohesive Phase C concerns. The file is therefore
a single state machine with no useful split boundary.

## Options considered

### Split by merge gate, acceptance criteria, and wrap execution

Rejected. These are consecutive gates in one short-lived agent state machine.
A split would add dispatch and context-transfer boundaries immediately before a
high-impact merge without making the observed shared-guardrail churn cheaper.

### KEEP with no content change

Rejected. The file still repeated details already owned by executable helpers
and canonical contracts. Those copies can drift even though they did not drive
most changes in this measurement window.

### KEEP and deduplicate non-decision detail

Chosen. Phase C retains the branch decisions it must make and points to the
sources that define the underlying schemas and gates.

## Concrete remedy

- `.claude/rules/cr-merge-gate.md` and `.claude/scripts/merge-gate.sh` own the
  exact-current-HEAD review, terminal CI, unresolved-thread, and merge-metadata
  requirements. The agent retains exit-code branching and its exit-`1`
  classification block (clean-`BEHIND` candidate, `ac-gate`-only candidate,
  otherwise stop-and-report).
- `.claude/scripts/ac-checkboxes.sh --help` owns helper modes and exit-code
  details. The agent retains source-based verification, the missing-criteria
  stop, update-failure stop, and no-tick-on-failure judgment.
- `.claude/reference/exit-report-format.md` owns field semantics and valid
  outcomes. The agent retains the exact Phase C report skeleton because the
  parent parses it at the phase boundary.
- `.claude/rules/phase-protocols.md` owns handoff deletion timing. The agent
  retains scoped path resolution, migration fallback, and handoff-first
  reviewer precedence.

## What was explicitly preserved

- Phase C remains independent from the implementation and review phases and
  remains read-only with respect to code fixes.
- Review approval must match the current HEAD, CI must be terminal and
  non-blocking, all review threads must be resolved, and merge metadata must be
  acceptable before `/wrap`.
- A `BEHIND` result that is not verified clean routes rebase/re-review recovery
  back to the parent; the merger never self-heals or merges around it. (Issue
  #1563 later admitted the *verified clean* `BEHIND`, and issue #1588 the
  non-`BEHIND` PR whose only unmet reason is a pre-tick `ac-gate` failure — both
  proceed to AC verification rather than stopping, and neither bypasses a real
  blocker.)
- Every unchecked acceptance criterion is verified against relevant source
  files before it is ticked. Missing criteria, failed verification, and helper
  or PR-body update errors block the merge.
- Standing merge authorization remains active: after the gate and acceptance
  criteria pass, Phase C runs the canonical `/wrap` flow without a permission
  pause. `/wrap` remains the only merge path and continues to own squash merge,
  main sync, issue closure, and follow-up detection.
- The parent still owns post-merge handoff deletion and session-state cleanup.
- The exact `EXIT_REPORT` block remains in the agent, including the Phase C
  marker, `OUTCOME: <merged|blocked>`, `NEXT_PHASE: none`, and the repo-scoped
  handoff path.
- Safety, capability-discovery, unavailable-browser, tool-restriction, and
  skill-first guardrails remain inline for the standalone spawned agent.

## Related

- [fixpr hotspot decision](fixpr-hotspot-decision.md)
- [subagent orchestration churn audit](subagent-orchestration-churn-audit-2026-07.md)
- [merge gate contract](../rules/cr-merge-gate.md)
- [structured exit report format](exit-report-format.md)
- [phase completion protocols](../rules/phase-protocols.md)
