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
3. Send heartbeat if due (≤5 min; include active agents, PR phases, pending transitions, blockers).
4. Investigate stale agents: >15 min Phase A, >10 min Phase B, >5 min Phase C.

## Timestamped Status Updates (MANDATORY)

Every message must start with an Eastern time timestamp. NEVER estimate — always run `date`. See CLAUDE.md #1 for format and command. Survives context compaction.

## Subagent Health Monitoring (MANDATORY)

Poll every cycle; never fire-and-forget. Report successes and failures immediately, naming PR/issue, phase, failure mode, and remaining work. Verify outputs before marking complete (`gh pr view` for pushes, comments/replies for feedback handling).

Crash/no handoff requires user permission to respawn. Token exhaustion with valid handoff auto-respawns.

## User Heartbeat (MANDATORY)

CLAUDE.md #3 is canonical: timestamped status at least every 5 min. In monitor mode, heartbeat is part of each loop; outside it, send status before/after multi-step operations. If the silence hook warns, stop and message immediately. For between-turn polling reliability, use `scheduling-reliability.md`.

## File-Write Status Updates (MANDATORY)

For operations touching 4+ files, emit one-line status after every 3 writes/edits. Batches of 1-3 need no extra message. Applies to parent agents and subagents.

## Post-Compaction Recovery (MANDATORY)

If a summary block references prior work you do not remember, recover before all other work:
1. Timestamp first message and rerun session-start checks.
2. Read `session-state.json` and handoff files, then reconcile every open PR via GitHub (`pr view`, reviews, inline comments, issue comments; use `per_page=100`).
3. Build a dashboard: PR, HEAD SHA, reviewer, last review state, pending action.
4. Verify stale agent outputs, Phase B coverage, and pending transitions; launch anything stalled.
5. Report "Resuming after context compaction. Reconstructed state from GitHub." and resume monitoring.

## PM Monitoring Recovery

PM manager monitoring uses the same recovery path. If `session-state.json` has `monitoring_active=true`, rebuild active work from `prs`, `active_agents`, handoff files, and live GitHub state before deciding whether to re-arm a poll.

- No active workers/PRs remain: set `monitoring_active=false` and report completion.
- Prior `monitoring_mode=loop`: restart the recorded `/loop` cadence unless the user explicitly chose passive mode.
- Prior `monitoring_mode=cron`: verify durable jobs with `CronList`; recreate only missing durable jobs or expired session-only jobs.
- Prior `monitoring_mode=passive`: keep passive but report that active work remains user-triggered.

Append a `polling_failures[]` entry for any dropped tick and include the recovered PRs/workers in the next heartbeat. Full state contract: `.claude/reference/pm-monitoring-decision.md`.

### Pre-Compaction Checkpointing (Preventive)

Write status checkpoints to `~/.claude/session-state.json` on phase transitions and key state-change events. See `handoff-files.md` for the schema. After compaction, read this file first, then reconcile with live GitHub state and any handoff files in `~/.claude/handoffs/`.
