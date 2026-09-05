# Verbosity Decisions — Issue #1253

Records the two open-question decisions from Issue #1253 so they are not re-litigated.

## Decision 1: Heartbeat reconciliation

**Removed** routine per-tick chat heartbeats. Rationale: 90% of status messages go unread; the heartbeat communicates liveness but not actionable information.

**Liveness signal:** the bgwork-ceiling backstop (`scheduling-reliability.md`, `bgwork-ceiling.md`) warns on genuine stall/silence. This is the only liveness surface. Healthy silent threads produce no chat output.

Context: the 5-minute heartbeat was the floor set by Issue #851. Issue #1253 removes it in favor of strict silence-by-default. The bgwork-ceiling backstop remains as the stall detector.

## Decision 2: `merged PR #N` exception

**Kept.** The one-line `merged PR #N` emission (Issue #869) survives under the silence-by-default rule. Classification: action-relevant — it signals that main moved, which may affect other in-flight work. It is the minimum useful signal after a merge and requires no scrolling or decoding.

## What "silence by default" means operationally

- Print nothing unless the message requires user action or input.
- When a message is needed: ≤2 lines, required action or decision first.
- Suppressed surfaces: progress narration, per-tick heartbeats, file lists, per-phase status, interim completion reports.
- **Amended by Issue #1396:** "end-of-run summaries" is no longer a blanket suppression. One end-of-task wrap-up per task is an always-emit exception, in the shape defined by `final-wrapup-format.md`. Interim and per-phase completion reports stay suppressed exactly as decided here; the amendment sanctions the single terminal message a task already had to carry, not a new reporting surface.
- Opt-in surfaces (unchanged): `/recap`, `/standup`, `--verbose`, "summarize".
- Decision points always surface: blockers, ambiguous calls, permission requests, subagent failures.
