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

Clean-cancel companion to `/pr-monitor-and-manage`. Use this to stop the PR-fleet-manager loop without leaving a dangling `/loop` or stale monitoring state behind.

## Step 1: Confirm there is something to stop

```bash
ACTIVE=$(.claude/scripts/session-state.sh --get '.pmm_active' 2>/dev/null || echo null)
```

- If `$ACTIVE` is `true` → proceed to teardown.
- If `false`/`null` → report "No active PR-fleet-manager loop found." and stop. (Still run Step 2's loop cancel best-effort in case a loop is armed without state.)

## Step 2: Tear down the loop

Cancel the recurring `/loop` that `/pr-monitor-and-manage` established:

- If the runtime exposes a loop id / cancel handle, cancel it explicitly.
- Otherwise interrupt the active loop (Ctrl+C in CLI, stop in web). Invoking `/pmm-stop` is itself the signal — the next tick must not re-arm.

## Step 3: Clear monitoring state (preserve everything else)

Use `session-state.sh` so unrelated fields (other skills' state, PR tracking, budgets) are preserved:

```bash
.claude/scripts/session-state.sh \
  --set '.pmm_active=false' \
  --set '.pmm_next_expected_tick_at=null'
```

Leave `pmm_in_flight`, `pmm_digest`, and `pmm_digest_streak` in place as an audit trail — they are harmless once `pmm_active=false`, and a later `/pr-monitor-and-manage` re-invocation re-evaluates them against live PR state on its first tick. Do **not** touch `cr_hourly`, `greptile_daily`, `prs`, or any non-`pmm_*` field.

## Step 4: Final summary

```text
=== PR fleet monitoring stopped ===
Reason:   user /pmm-stop
Loop:     cancelled (no further ticks)
State:    pmm_active=false
In-flight at stop: <list any pmm_in_flight PR # + skill, or "none">
```

If any PR had an in-flight `/fixpr`/`/wrap` dispatch when stopped, name it so the user knows that dispatch was mid-flight. Re-run `/pr-monitor-and-manage` anytime to resume — it rediscovers the fleet from scratch.
