# Monitor Mode, Heartbeats & Recovery

> **Always:** Enter monitor mode when subagents are active. Timestamp every user-visible message (CLAUDE.md #1; exception: the clean auto-merge line `merged PR #N` omits the timestamp per CLAUDE.md #3). Arm the silence ceiling when background work starts (`scheduling-reliability.md`). Report subagent failures immediately. Recover state after compaction.
> **Ask first:** Breaking monitor mode for explicit user requests — warn about paused monitoring first.
> **Never:** Do substantive work while subagents are active. Let a stalled PR go unreported. Ask permission to monitor — babysitting an in-flight PR is the default (`CLAUDE.md`).

## Dedicated Monitor Mode (MANDATORY for parent agents)

**Entry:** any active subagent or non-empty `active_agents` in `session-state.json`. **Exit:** all subagents complete/failed, pending B/C launches executed, state updated.

While active: poll subagents, verify outputs, execute phase transitions, refill free capacity, update state. No code edits, issue/PR creation, or source analysis — delegate fix work to subagents. Message only on blockers, decisions, failures, or defined exceptions — never routine status.

If the user explicitly requests substantive work, warn that monitoring N active PR(s) will pause, do the work, then immediately re-enter monitor mode.

## Monitor Loop — Per-Cycle Checklist (MANDATORY)

Every ~60s, in order:
0. **Usage horizon.** Feed the harness-printed `<total_tokens>` figure to `usage-horizon.sh --observe`, then `--check`: `approaching`/`unknown` → start nothing new; `critical` → park per `subagent-thread-limit-park.md` §7.
1. Process completed subagents and parse exit reports.
2. Execute phase transitions via `phase-protocols.md`; also launch transitions stalled in `session-state.json`.
3. For every session PR still on `reviewer == cr`, run `.claude/scripts/escalate-review.sh <PR_NUMBER>` and act on its `STATUS=` verdict before sleeping.
4. Below the pipeline ceiling? Refill: queued chain heads, then `/pm` Step 3.4's backlog pass (under `/pm` only). Chains, re-validation, pause still bind.
5. Follow `scheduling-reliability.md` §Mandatory Pre-Exit Checklist item 2 for what to emit (canonical output rule).
6. Investigate stale agents: >15 min Phase A, >10 min Phase B, >5 min Phase C.
7. Before ending the turn, confirm the ceiling is still armed: `bgwork-ceiling.sh --check`.

## Subagent Health Monitoring (MANDATORY)

Poll every cycle; never fire-and-forget. Report failures and blockers immediately — PR/issue, phase, failure mode, remaining work; successes stay silent. Verify outputs before marking complete (`gh pr view` for pushes, comments/replies for feedback handling).

Respawn permissions: crash asks, exhaustion auto, limit-parked neither — it parks the board and arms a wake (`phase-protocols.md` §Limit-parked).

## Liveness

Routine per-tick heartbeats are removed; liveness and output rules: `scheduling-reliability.md` §Mandatory Pre-Exit Checklist.

## File-Write Status Updates (MANDATORY)

Operations touching 4+ files: one-line status every 3 writes/edits; batches of 1–3 need none. Applies to parents and subagents.

## Post-Compaction Recovery (MANDATORY)

If a summary block references prior work you do not remember, recover before all other work:
1. Rerun session-start checks.
2. Read `session-state.json` + handoffs; reconcile each open PR on GitHub (all 3 endpoints per `cr-github-review.md`).
   Also re-read any usage-limit park; re-arm its wake only when it is an unexpired `rolling_window` one — a weekly cap never gets an in-session wake (`subagent-thread-limit-park.md` §6).
3. Per polled PR: `polling-state-gate.sh <N> --verify-state` (optional `--root-repo`), then resume with `polling-state-gate.sh <N>` (shells `merge-gate.sh`).
4. Reconcile state (PR, HEAD, reviewer, pending); verify stale agents and stalled transitions; launch as needed.
5. Resume monitoring silently — message if recovery reveals a blocker, failure, or decision needing input, or if a defined exception occurs.

## PM Monitoring Recovery

If `monitoring_active=true` or passive mode with non-empty `prs`/`active_agents`, rebuild from `prs`, `active_agents`, handoffs, and GitHub before continuing.

- No workers left → `monitoring_active=false`.
- `/pm`-owned monitoring is always passive — never restart a Monitor or scheduler on `/pm`'s behalf; point fleet monitoring at `/pr-monitor-and-manage`.
- Jobs in `polling_jobs[]` → recover per that skill's contract (`pm-monitoring-decision.md`); log drops in `polling_failures[]`.

### Pre-Compaction Checkpointing (Preventive)

Checkpoint `session-state.json` on phase transitions. After compaction read it first, then GitHub + `~/.claude/handoffs/`.
