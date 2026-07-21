# Monitor Mode, Heartbeats & Recovery

> **Always:** Enter monitor mode when subagents are active. Timestamp every message (see CLAUDE.md #1). Heartbeat every ≤5 min (see CLAUDE.md #3). Report subagent failures immediately. Recover state after compaction.
> **Ask first:** Breaking monitor mode for explicit user requests — warn about paused monitoring first.
> **Never:** Do substantive work while subagents are active. Go >5 min without a user-visible message. Let a stalled PR go unreported.

## Dedicated Monitor Mode (MANDATORY for parent agents)

**Entry:** any active subagent or non-empty `active_agents` in `session-state.json`. **Exit:** all subagents complete/failed, pending B/C launches executed, and state updated.

While active, the parent only orchestrates: poll subagents, verify outputs, execute phase transitions, update state, report heartbeats, recover after compaction, and answer user questions. No code edits, issue/PR creation, local CR review, or source analysis; delegate fix work to subagents.

If the user explicitly requests substantive work, warn that monitoring N active PR(s) will pause, do the work, then immediately re-enter monitor mode.

## Monitor Loop — Per-Cycle Checklist (MANDATORY)

Every ~60s, in order:
1. Process completed subagents and parse exit reports.
2. Execute phase transitions via `phase-protocols.md`; also launch transitions stalled in `session-state.json`.
3. For every session PR still on `reviewer == cr`, run `.claude/scripts/escalate-review.sh <PR_NUMBER>` and act on its `STATUS=` verdict before sleeping.
4. Send heartbeat if due (≤5 min; include active agents, PR phases, pending transitions, blockers).
5. Investigate stale agents: >15 min Phase A, >10 min Phase B, >5 min Phase C.

## Subagent Health Monitoring (MANDATORY)

Poll every cycle; never fire-and-forget. Report successes and failures immediately, naming PR/issue, phase, failure mode, and remaining work. Verify outputs before marking complete (`gh pr view` for pushes, comments/replies for feedback handling).

Respawn permissions: crash asks, exhaustion auto (`phase-protocols.md`).

## User Heartbeat (MANDATORY)

CLAUDE.md #3 is canonical (timestamped status ≤5 min). In monitor mode it is part of each loop; outside it, send status before/after multi-step operations; if the silence hook warns, message immediately. Between-turn polling: `scheduling-reliability.md`.

## File-Write Status Updates (MANDATORY)

For operations touching 4+ files, emit one-line status after every 3 writes/edits. Batches of 1-3 need no extra message. Applies to parent agents and subagents.

## Post-Compaction Recovery (MANDATORY)

If a summary block references prior work you do not remember, recover before all other work:
1. Timestamp; rerun session-start checks.
2. Read `session-state.json` + handoffs; reconcile each open PR on GitHub (all 3 endpoints per `cr-github-review.md`).
3. Per polled PR: `polling-state-gate.sh <N> --verify-state` (optional `--root-repo`), then resume with `polling-state-gate.sh <N>` (shells `merge-gate.sh`).
4. Dashboard (PR, HEAD, reviewer, pending); verify stale agents and stalled transitions; launch as needed.
5. Report: "Resuming after context compaction. Reconstructed state from GitHub." then resume monitoring.

## PM Monitoring Recovery

If `monitoring_active=true` or passive mode with non-empty `prs`/`active_agents`, rebuild from `prs`, `active_agents`, handoffs, and GitHub before continuing.

- No workers left → `monitoring_active=false`, report done.
- `/pm`-owned monitoring is always passive — never restart a `/loop`/`CronCreate` on `/pm`'s behalf; point fleet monitoring at `/pr-monitor-and-manage`.
- Jobs in `polling_jobs[]` owned by other skills → recover per that skill's contract; log drops in `polling_failures[]`. Contract: `pm-monitoring-decision.md`.

### Pre-Compaction Checkpointing (Preventive)

Checkpoint `session-state.json` on phase transitions. After compaction read it first, then GitHub + `~/.claude/handoffs/`.
