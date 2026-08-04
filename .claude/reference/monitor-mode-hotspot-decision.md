# Monitor Mode Hotspot Decision

Reference for Issue #984 (`.claude/rules/monitor-mode.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the single rule file and **deduplicate toward it**

Keep `.claude/rules/monitor-mode.md` intact as the canonical behavioral hub for in-turn
monitoring, recovery, and orchestration-only posture. It applies the user-visible heartbeat
contract owned solely by `CLAUDE.md`; it does not define a competing variant. Remove the concrete
PM recovery restatement from `.claude/reference/pm-monitoring-decision.md` and replace it with a
pointer to `## Post-Compaction Recovery` for session-start reconciliation and the recovery
heartbeat, then `## PM Monitoring Recovery` for PM-specific recovery behavior. `CLAUDE.md`
remains the sole owner of the user-visible heartbeat contract that the rule applies.

This is a documentation-ownership remedy, not a behavior change. Splitting the rule would make its
many callers migrate together, while script extraction does not fit agent-judgment policy.

## 1. Trigger and diagnosis

The hotspot detector recorded nine merged PRs touching `monitor-mode.md` since 2026-07-20:
PRs #660, #717, #742, #774, #804, #807, #828, #862, and #982. At diagnosis time the file was 65 lines
and 583 words, far below the 2,000-word per-file warning.

The file is an intentionally cross-referenced hub. `CLAUDE.md`, `subagent-orchestration.md`,
`scheduling-reliability.md`, `phase-protocols.md`, `pm-monitoring-decision.md`, and orchestration
skills cite its named sections. Changes land here because monitoring policy is shared, not because
the file has accumulated unrelated implementation blocks. Its churn is edit-count-heavy rather
than size-growth-heavy.

One avoidable driver did exist: `.claude/reference/pm-monitoring-decision.md` repeated the PM
recovery sources, terminal condition, and scheduler-ownership behavior already owned by
`monitor-mode.md`. That duplication made one recovery-policy change require two coordinated edits.

## 2. Options considered

### Option 1: Split the rule into concern-scoped files

A split could create separate files for monitor loops, heartbeats, and recovery.

**Rejected.** The current file is small and its named sections are cited throughout the operating
corpus. Splitting would turn one edit surface into a caller-migration surface without isolating
independent behavior.

### Option 2: Extract deterministic behavior into a script

The `fixpr` hotspot used script extraction for repeatable `jq` and review-state operations.

**Rejected.** Monitor posture, heartbeat timing, stale-agent investigation, and recovery decisions
are agent policy and judgment. There is no deterministic command block here whose extraction would
remove the churn source. `.claude/reference/script-extraction-audit.md` therefore remains out of
scope.

### Option 3: Keep the rule and deduplicate non-owners

Retain the hub and replace downstream behavioral restatements with section pointers.

**Chosen.** This preserves established callers while removing the one confirmed lockstep edit. It
matches the KEEP + dedup precedent in
`.claude/reference/subagent-orchestration-churn-audit-2026-07.md`.

### Option 4: Record the hotspot without a remedy

The ticket is observational, so a no-op could be defensible if all churn were necessary.

**Rejected.** The PM recovery restatement is concrete, removable duplication. Leaving it would
preserve a known drift risk.

## 3. Ownership boundaries

| Content | Canonical owner | Non-owner action |
|---------|-----------------|------------------|
| Dedicated in-turn monitoring posture and per-cycle orchestration | `.claude/rules/monitor-mode.md` | Point to the named sections; do not restate the checklist |
| User-visible heartbeat output and silence discipline | `CLAUDE.md` | `monitor-mode.md` applies that contract in orchestration context; skills do not define variants |
| Post-compaction session reconciliation and recovery heartbeat application | `.claude/rules/monitor-mode.md` `## Post-Compaction Recovery` | `pm-monitoring-decision.md` points to the named section; `CLAUDE.md` continues to own the heartbeat contract |
| PM orchestration rebuild, terminal-state, and scheduler-ownership boundaries | `.claude/rules/monitor-mode.md` `## PM Monitoring Recovery` | `pm-monitoring-decision.md` retains rationale/state framing and points to the named section |
| Persistent Monitor recovery and dropped-tick handling | `.claude/rules/scheduling-reliability.md` plus the owning `/pr-monitor-and-manage` or `/babysit-pr` lifecycle | `monitor-mode.md` and `pm-monitoring-decision.md` point outward; `polling_jobs[]` is not used for current Monitor tasks |
| Between-turn primitive selection and liveness | `.claude/rules/scheduling-reliability.md` | `monitor-mode.md` references it; it does not redefine scheduler semantics |
| Phase transitions and completion protocols | `.claude/rules/phase-protocols.md` | The Monitor Loop invokes that owner rather than duplicating phase procedures |
| Subagent spawn policy, model selection, and pipeline ceiling | `.claude/rules/subagent-orchestration.md` | `monitor-mode.md` owns only monitoring while those agents are active |

## 4. Remediation applied

- Kept `.claude/rules/monitor-mode.md` byte-for-byte unchanged.
- Replaced the numbered PM recovery procedure in
  `.claude/reference/pm-monitoring-decision.md` with direct pointers to `monitor-mode.md`
  `## Post-Compaction Recovery` and `## PM Monitoring Recovery`, while preserving `CLAUDE.md` as
  the sole owner of the user-visible heartbeat contract and routing current Monitor recovery to
  `scheduling-reliability.md` plus the owning skill lifecycle.
- Retained the PM reference's unique rationale, state-field contract, and ownership framing.
- Registered this decision in `.claude/reference/README.md` so the reference catalog remains
  complete.

## 5. Preserved invariants

- `monitor-mode.md` remains the canonical behavioral owner of Dedicated Monitor Mode, the Monitor
  Loop, subagent health monitoring, application of `CLAUDE.md`'s heartbeat contract,
  post-compaction recovery, PM monitoring recovery, and pre-compaction checkpointing.
- Its `Always / Ask first / Never` triage header and every named section remain intact.
- The ownership boundaries with `subagent-orchestration.md`, `scheduling-reliability.md`, and
  `phase-protocols.md` do not change.
- PM state remains a cache reconciled against GitHub and handoffs; current Monitor recovery remains
  owned by `scheduling-reliability.md` and the skill that created the task. Legacy `polling_jobs[]`
  state remains session-start reconciliation input, not a current Monitor recovery path.
- No recovery behavior moves to a script, and no second recovery path is introduced.

## 6. Verification and future edits

Verification for this remedy checks the exact catalog entry, the PM reference's canonical pointer,
the unchanged rule file, rule-corpus lint, and the repository's full Bash and Python suites. The
auto-loaded corpus does not change, so `.claude/rules/.budget-soft-cap` must remain untouched.

Future monitoring-policy changes should edit the canonical named section in `monitor-mode.md` and
leave callers as pointers. Reconsider splitting only if independent concerns grow beyond the file's
size/adherence limits or acquire callers that no longer need the shared hub. Reconsider extraction
only when a repeatable deterministic operation—not agent judgment—appears.

## Related precedent

- `.claude/reference/subagent-orchestration-churn-audit-2026-07.md` — KEEP + dedup for a small,
  heavily referenced orchestration rule.
- `.claude/reference/fixpr-hotspot-decision.md` — KEEP + extract for deterministic command forms;
  useful as the contrasting extraction case.
- `.claude/reference/script-extraction-audit.md` — extraction registry; explicitly not applicable
  to this policy-only hotspot.
