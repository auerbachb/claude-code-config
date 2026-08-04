# Scheduling Reliability Hotspot Decision

Reference for Issue #959 (`.claude/rules/scheduling-reliability.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the single rule file and **deduplicate toward it**

Keep `.claude/rules/scheduling-reliability.md` intact as the canonical source for scheduling
primitive selection, PM monitoring boundaries, recurring-scheduler reliability, the polling
pre-exit checklist, stable-state backoff, and dropped-tick recovery. The file is compact, its
sections form one liveness contract, and most of its churn followed changes in the underlying
scheduling primitives rather than unrelated concerns accumulating in one file.

Remove two confirmed downstream restatements: the copied backoff thresholds in
`.claude/reference/scheduling-failure-modes.md` and the copied Stop-hook enforcement sentence in
`.claude/rules/subagent-orchestration.md`. Keep `.claude/rules/monitor-mode.md` unchanged because
the newer Issue #984 decision makes that file the canonical owner of PM recovery and its
scheduler-ownership boundary.

## 1. Trigger and current evidence

When Issue #959 was filed, the hotspot detector recorded 11 merged PRs touching
`scheduling-reliability.md` since 2026-07-19. Current `main` adds PR #982, producing 12 touches:
PRs #660, #717, #774, #787, #804, #807, #820, #825, #867, #919, #922, and #982.

At diagnosis time the rule was 53 lines and 609 words, far below the 2,000-word per-file warning.
The touch history falls into four groups:

| Churn class | PRs | What changed |
|-------------|-----|--------------|
| New liveness mechanisms and posture | PRs #717, #774, #807 | Default babysitting, heartbeat wording, and the background-work ceiling |
| Scheduling correctness and primitive lifecycle | PRs #820, #825, #867, #922, #982 | Backoff reconciliation, corrected CronCreate durability, session reconciliation, observed scheduler failure, and migration to persistent Monitor tasks |
| Corpus compression | PRs #660, #804, #919 | Shortened auto-loaded prose without changing the scheduling contract |
| Incidental corpus hygiene | PR #787 | Removed an unrelated duplicated root-repo safety restriction |

The dominant driver is therefore an unstable or newly understood scheduling substrate. The
sequence from Issue #808 through Issue #827, Issue #914, and Issue #924 successively corrected
what recurrence and durability the available primitives could actually provide. Splitting the
rule cannot remove that driver; it would only spread those corrections across more owners.

## 2. Decision: keep one canonical scheduling rule

**Splitting is rejected.** The current file is small, and its named sections are coupled parts of
one question: how an agent selects a scheduling primitive and proves that recurring work remains
observable. A split would add cross-file navigation and caller migrations without isolating an
independently changing concern.

**Another compression pass is rejected.** The file is already concise. Its remaining mechanism is
operative policy that agents need in auto-loaded context, while detailed rationale and incident
history already live in `.claude/reference/`.

**KEEP + targeted deduplication is chosen.** Downstream documents should point to the canonical
named section instead of copying its exact thresholds or enforcement wording.

## 3. Canonical ownership

| Content | Canonical owner | Non-owner action |
|---------|-----------------|------------------|
| Primitive choice, including recurring Monitor selection | `.claude/rules/scheduling-reliability.md` `## Tool Selection Decision Tree` | Point here; do not recreate the selection table |
| PM's on-demand role and fleet-monitor ownership | `.claude/rules/scheduling-reliability.md` `## PM Monitoring Primitive` | Recovery documents may state their own actions, but do not redefine the primitive boundary |
| Recurring scheduler failure and session-only limitations | `.claude/rules/scheduling-reliability.md` `### Recurring scheduler contract (authoritative)` | Reference docs retain evidence and rationale, not a second operative contract |
| Polling turn liveness proof | `.claude/rules/scheduling-reliability.md` `## Mandatory Pre-Exit Checklist for Polling Turns` | Spawn rules keep the required action and point here for enforcement |
| Digest inputs, widening formula, and stop/resume thresholds | `.claude/rules/scheduling-reliability.md` `## Stable-State Backoff` | Incident docs preserve history and link to this section without copying values |
| Dropped-tick recovery | `.claude/rules/scheduling-reliability.md` `## Failure Recovery` plus the owning skill lifecycle | Consumers record the failure and invoke the owning recovery path |
| PM recovery state and scheduler-ownership behavior | `.claude/rules/monitor-mode.md` `## PM Monitoring Recovery` | Preserve the explicit Issue #984 owner decision; do not trim this rule as part of Issue #959 |

## 4. Targeted remediation

1. In `.claude/reference/scheduling-failure-modes.md` Pattern 5, preserve the PR #359 incident and
   the Issue #794 explanation for choosing a cadence-relative policy, but replace the copied
   formula and thresholds with a direct pointer to `## Stable-State Backoff`.
2. In `.claude/rules/subagent-orchestration.md` spawn Step 8, preserve the same-step action,
   `bgwork-ceiling.sh --arm-command`, persistent `Monitor`, and the pointer to
   `scheduling-reliability.md`; remove only the duplicated Stop-hook sentence.

These changes reduce lockstep edit risk without changing behavior. The authoritative
`.claude/rules/scheduling-reliability.md` and the separately owned `.claude/rules/monitor-mode.md`
remain byte-for-byte unchanged.

## 5. What not to change

- Do not split `scheduling-reliability.md` while it remains a compact, cohesive liveness contract.
- Do not move the decision tree, scheduler contract, pre-exit checklist, backoff formula, or
  failure-recovery action out of the auto-loaded rule.
- Do not duplicate backoff values in incident or skill documentation; cite the named section.
- Do not weaken the requirement to arm the background-work ceiling in the same step as spawning.
- Do not edit `monitor-mode.md` under this decision. Issue #984 records why its PM recovery and
  scheduler-ownership wording belongs there.
- Do not raise `.claude/rules/.budget-soft-cap` for this remediation; the auto-loaded corpus shrinks.

## 6. Future edits

Scheduling-policy changes should update the canonical named section and leave consumers as
pointers. Reconsider this KEEP verdict only if the rule crosses the repository's size/adherence
limits or acquires genuinely independent concerns with disjoint callers—not because another
underlying scheduling primitive changes.

The traceability marker on Issue #959 is:
`<!-- churn-hotspot: .claude/rules/scheduling-reliability.md -->`.

## Related precedent

- `.claude/reference/monitor-mode-hotspot-decision.md` — KEEP + dedup, and the controlling decision
  for PM recovery ownership;
- `.claude/reference/fixpr-hotspot-decision.md` — KEEP + extract deterministic implementation;
- `.claude/reference/churn-hotspots.md` — detector scope and observational-ticket rationale.
