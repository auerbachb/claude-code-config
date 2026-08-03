---
name: pr-monitor-and-manage-stop
description: Clean-cancel companion to /pr-monitor-and-manage. Stops the PR-fleet Monitor tasks, clears monitoring state in session-state.json, and prints a final summary. Triggers on "/pr-monitor-and-manage-stop", "/pmm-stop", "stop monitoring PRs".
triggers:
  - pr-monitor-and-manage-stop
  - pmm-stop
  - stop monitoring PRs
  - stop PR fleet
argument-hint: "(no arguments — stops the active PR-fleet Monitor in this thread)"
---

Clean-cancel companion to `/pr-monitor-and-manage`. Use this to stop the PR-fleet manager without leaving a dangling main/auto-wake Monitor, stale monitoring state, or re-scan behind.

A stale pause marker left by a killed session is safely reconciled: the next `/pr-monitor-and-manage` invocation reads it and resumes (or the user runs `/pmm-stop` here to fully tear down), then re-runs discovery from scratch.

## Resolve the state helper

Same three-candidate lookup as `/babysit-pr-stop`:

```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
SESSION_STATE_SH=$(resolve_script session-state.sh) || { echo "ERROR: session-state.sh not found" >&2; exit 1; }
```

## Step 1: Confirm there is something to stop

```bash
ACTIVE=$("$SESSION_STATE_SH" --get '.pmm_active' 2>/dev/null || echo null)
PAUSED_AT=$("$SESSION_STATE_SH" --get '.pmm.paused_at' 2>/dev/null || echo null)
```

- If `$ACTIVE` is `true` → proceed to teardown.
- If `$PAUSED_AT` is set (paused but not active) → proceed to teardown (clear pause marker + any re-scan Monitor).
- If both `false`/`null` → report "No active PR-fleet Monitor found." and stop. (Still inspect the recorded Monitor task IDs.)

## Step 2: Stop the main Monitor

Read `.pmm_monitor_task_id` and stop that exact task with `TaskStop`. Report a missing/failed task
instead of claiming cancellation; set `pmm_active=false` in either case so an already-emitted tick
cannot re-arm without a fresh user invocation. Set `MAIN_MONITOR_STOPPED=true` only after a
successful `TaskStop`; otherwise set it to `false`.

## Step 3: Cancel the auto-wake re-scan

If `--auto-wake` armed a re-scan at pause time, stop `.pmm.auto_wake_monitor_task_id` with `TaskStop`.
Set `AUTO_WAKE_MONITOR_STOPPED=true` only after success; otherwise set it to `false`.

## Step 4: Clear monitoring state (preserve everything else)

Use `session-state.sh` so unrelated fields (other skills' state, PR tracking, budgets) are preserved. Build one atomic call, clearing a task ID only when its `TaskStop` succeeded (a failed stop keeps the ID for diagnosis):

```bash
SET_ARGS=(
  --set '.pmm_active=false'
  --set '.pmm_next_expected_tick_at=null'
  --set '.pmm.paused_at=null'
  --set '.pmm.fleet_at_pause=null'
  --set '.pmm.config_at_pause=null'
)
[[ "$MAIN_MONITOR_STOPPED" == true ]] && SET_ARGS+=(--set '.pmm_monitor_task_id=null')
[[ "$AUTO_WAKE_MONITOR_STOPPED" == true ]] && SET_ARGS+=(--set '.pmm.auto_wake_monitor_task_id=null')
"$SESSION_STATE_SH" "${SET_ARGS[@]}"
```

Leave `pmm_in_flight`, `pmm_digest`, `pmm_digest_streak`, and `pmm_idle_streak` in place as an audit trail — they are harmless once `pmm_active=false`, and a later `/pr-monitor-and-manage` re-invocation re-evaluates them against live PR state on its first tick. Do **not** touch `cr_hourly`, `greptile_daily`, `prs`, `active_agents`, or any non-`pmm_*` field. Note any PMM-owned entries still in `active_agents` (phase-a-fixer fix subagents) in the final summary — they may continue running until they exit on their own.

## Step 5: Final summary

```text
=== PR fleet monitoring stopped ===
Reason:   user /pmm-stop
Monitor:  stopped (no further ticks)
State:    pmm_active=false, pause marker cleared
Auto-wake re-scan: <cancelled | none>
In-flight at stop: <list any pmm_in_flight PR # + skill, or "none">
Active subagents: <list any PMM-owned active_agents entries (match by pr + phase A, or task containing "PMM"), or "none">
```

If any PR had an in-flight `phase-a-fixer` subagent or `/wrap` dispatch when stopped, name it so the user knows that work was mid-flight. Re-run `/pr-monitor-and-manage` anytime to resume — it rediscovers the fleet from scratch and Step 2.5 aggregates any subagents that completed while monitoring was stopped.
