# Monitor Mode, Heartbeats & Recovery

> **Always:** Enter monitor mode when subagents are active. Timestamp every message (see CLAUDE.md #1). Heartbeat every ≤5 min (see CLAUDE.md #3). Report subagent failures immediately. Recover state after compaction.
> **Ask first:** Breaking monitor mode for explicit user requests — warn about paused monitoring first.
> **Never:** Do substantive work while subagents are active. Go >5 min without a user-visible message. Let a stalled PR go unreported.

## Dedicated Monitor Mode (MANDATORY for parent agents)

When one or more subagents are active, the parent enters **monitor mode** — sole responsibility is orchestration.

**Entry condition:** `active_agents` in `session-state.json` is non-empty, or any spawned subagent has not yet completed or failed.

**Exit condition:** ALL true: all subagents completed/failed, no pending Phase B/C launches, all phase transitions executed.

**Permitted activities (exhaustive):**
- Subagent status polling, heartbeat messages, next-phase launches
- Output verification (pushes, replies), `session-state.json` read/update
- Post-compaction state reconstruction, user questions

**Prohibited activities (substantive work):**
- Code/file edits, issue/PR creation, non-monitoring source analysis
- Local CR reviews, any multi-step operation displacing the polling loop
- Fixing code yourself instead of delegating to a subagent

> **Core principle:** If it can be delegated to a subagent, it MUST be. The parent orchestrates, not executes.

**Exception: Explicit user request.** The parent MAY do substantive work if the user explicitly asks — but must first warn: "I have N active subagent(s) monitoring PR(s) #X, #Y. Monitoring will pause." After completing the work, immediately re-enter monitor mode: check all statuses, execute pending transitions, send update, resume polling.

**Delegating from monitor mode:** Spawn a subagent with the task, add it to `active_agents`, continue monitoring.

## Monitor Loop — Per-Cycle Checklist (MANDATORY)

**Cycle interval: ~60 seconds.** Execute in **priority order**:

1. **Check for completed subagents.** If any returned results, process immediately (steps 2-3).
2. **Execute pending phase transitions.** Parse exit reports, execute the appropriate Completion Protocol (see `phase-protocols.md`). Highest priority — before heartbeats.
3. **Check for pending transitions from prior cycles.** Read `session-state.json` for stalled transitions. Launch immediately.
4. **Send heartbeat if due.** See CLAUDE.md #3 for the 5-minute rule. Include: active agents, PR phases, pending transitions, blockers.
5. **Check for stale agents.** Thresholds: >15 min Phase A, >10 min Phase B, >5 min Phase C — investigate possible silent failure.

> **Key insight:** Execute transitions (Steps 2-3) before heartbeats (Step 4) — stale heartbeats reporting outdated phase state are misleading.

## Timestamped Status Updates (MANDATORY)

Every message must start with an Eastern time timestamp. NEVER estimate — always run `date`. See CLAUDE.md #1 for format and command. Survives context compaction.

## Subagent Health Monitoring (MANDATORY)

Subagent failures are only visible to the parent.

1. **Poll status every cycle.** Do not fire-and-forget.
2. **Report failures immediately.** Include: which PR/issue, phase (A/B/C), how it failed, what was left undone.
3. **Report success too.** Brief status update on phase completion.
4. **Detect silent failures.** Verify outputs (pushes, replies) before marking complete.
5. **Never assume success.** Verify pushes via `gh pr view`, verify replies exist.

**Failure message template:**
> "Mon Mar 16 02:34 AM ET — Subagent for PR #N (Phase B) failed — ran out of tokens. Last push: `abc1234`. CR review pending. Want me to respawn?"

## User Heartbeat (MANDATORY)

Canonical rule: CLAUDE.md #3 (5-minute max silence, non-negotiable).

**Rules:**
1. **In monitor mode:** heartbeats are part of the core loop — poll → status → wait → repeat.
2. **Outside monitor mode:** send a brief status before entering any multi-step operation.
3. **After completing any multi-step operation:** immediately send a status update.
4. **Never batch status updates.** Report incrementally.

**Heartbeat enforcement:** A PostToolUse hook warns when >5 min have elapsed — on seeing it, stop and send a status message immediately.

## Post-Compaction Recovery (MANDATORY)

Context compaction wipes in-memory state. **Detection:** conversation starts with a summary block referencing prior work you don't remember.

**Immediate recovery protocol (ALL steps, before any other work):**

1. **Timestamp your first message.**
2. **Re-run session-start checklist.** Re-detect work-log path (search from main worktree root — see `work-log.md`). Re-check other session-start obligations.
3. **Reconstruct PR state from GitHub.** For every open PR:

   ```bash
   gh pr view N --json state,title,mergeStateStatus,commits
   gh api "repos/{owner}/{repo}/pulls/N/reviews?per_page=100"
   gh api "repos/{owner}/{repo}/pulls/N/comments?per_page=100"
   gh api "repos/{owner}/{repo}/issues/N/comments?per_page=100"
   ```

   Build a dashboard: PR number, HEAD SHA, last review state, reviewer, pending action.
4. **Check for stale background agents.** Verify expected outputs exist.
5. **Check Phase B coverage.** If no Phase B record for a PR with unprocessed findings, launch Phase B immediately.
6. **Check for pending phase transitions.** Execute any stalled Completion Protocols.
7. **Report to user.** "Resuming after context compaction. Reconstructed state from GitHub."
8. **Resume monitoring loop.**

### Pre-Compaction Checkpointing (Preventive)

Write status checkpoints to `~/.claude/session-state.json` on phase transitions and key state-change events. See `handoff-files.md` for the schema. After compaction, read this file first, then reconcile with live GitHub state and any handoff files in `~/.claude/handoffs/`.
