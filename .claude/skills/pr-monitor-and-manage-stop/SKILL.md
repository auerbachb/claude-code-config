---
name: pr-monitor-and-manage-stop
description: Clean-cancel companion to /pr-monitor-and-manage. Stops the PR-fleet-manager loop, tears down its /loop, clears monitoring state in session-state.json, and prints a final summary. Triggers on "/pr-monitor-and-manage-stop", "/pmm-stop", "stop monitoring PRs".
triggers:
  - pr-monitor-and-manage-stop
  - pmm-stop
  - stop monitoring PRs
  - stop PR fleet
argument-hint: "(no arguments — stops the active PR-fleet-manager loop in this thread)"
---

Clean-cancel companion to `/pr-monitor-and-manage`. Use this to stop the PR-fleet-manager loop without leaving a dangling `/loop`, stale monitoring state, or auto-wake re-scan behind.

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
- If `$PAUSED_AT` is set (paused but not active) → proceed to teardown (clear pause marker + any re-scan loop).
- If both `false`/`null` → report "No active PR-fleet-manager loop found." and stop. (Still run Step 2's loop cancel best-effort in case a loop is armed without state.)

## Step 2: Tear down the loop

Cancel the recurring `/loop` that `/pr-monitor-and-manage` established:

- If the runtime exposes a loop id / cancel handle, cancel it explicitly.
- Otherwise interrupt the active loop (Ctrl+C in CLI, stop in web). Invoking `/pmm-stop` is itself the signal — the next tick must not re-arm.

## Step 3: Cancel the auto-wake re-scan

If `--auto-wake` armed a re-scan at pause time, cancel that `/loop` the same way as Step 2. Since issue #827 it is a plain `/loop` with no recorded job id, so there is nothing to reconcile in state and nothing that can outlive this turn.

## Step 4: Clear monitoring state (preserve everything else)

Use `session-state.sh` so unrelated fields (other skills' state, PR tracking, budgets) are preserved:

```bash
"$SESSION_STATE_SH" \
  --set '.pmm_active=false' \
  --set '.pmm_next_expected_tick_at=null' \
  --set '.pmm.paused_at=null' \
  --set '.pmm.fleet_at_pause=null' \
  --set '.pmm.config_at_pause=null'
```

Leave `pmm_in_flight`, `pmm_digest`, `pmm_digest_streak`, and `pmm_idle_streak` in place as an audit trail — they are harmless once `pmm_active=false`, and a later `/pr-monitor-and-manage` re-invocation re-evaluates them against live PR state on its first tick. Do **not** touch `cr_hourly`, `greptile_daily`, `prs`, `active_agents`, or any non-`pmm_*` field. Note any PMM-owned entries still in `active_agents` (phase-a-fixer fix subagents) in the final summary — they may continue running until they exit on their own.

## Step 5: Final summary

```text
=== PR fleet monitoring stopped ===
Reason:   user /pmm-stop
Loop:     cancelled (no further ticks)
State:    pmm_active=false, pause marker cleared
Auto-wake re-scan: <cancelled | none>
In-flight at stop: <list any pmm_in_flight PR # + skill, or "none">
Active subagents: <list any PMM-owned active_agents entries (match by pr + phase A, or task containing "PMM"), or "none">
```

If any PR had an in-flight `phase-a-fixer` subagent or `/wrap` dispatch when stopped, name it so the user knows that work was mid-flight. Re-run `/pr-monitor-and-manage` anytime to resume — it rediscovers the fleet from scratch and Step 2.5 aggregates any subagents that completed while monitoring was stopped.
