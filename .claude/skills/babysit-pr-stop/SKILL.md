---
name: babysit-pr-stop
description: Cleanly stop an active /babysit-pr watcher for a PR. Sets the watcher's stop flag in session-state so its next tick terminates, cancels the recurring poll (CronDelete in durable mode), and confirms. Invoke as `/babysit-pr-stop <PR>`.
triggers:
  - stop babysit
  - stop watching pr
  - stop babysitting pr
argument-hint: "<PR>"
---

Stop the `/babysit-pr` watcher for one PR. This is the clean-cancel companion to `/babysit-pr` — it does not merge, fix, or touch the PR itself; it only tears down the watcher loop and its state.

Stopping is **cooperative and idempotent**: it flags the watcher to terminate on its next tick (the watcher's `T0` short-circuit handles the actual clean exit) and cancels the durable poll job when one exists. Running it on a PR with no active watcher is a safe no-op.

## Resolve the state helper

Same three-candidate lookup as `/babysit-pr` (`fixpr/SKILL.md` pattern):

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

## Steps

### 1. Parse the PR number

The first bare integer in `$ARGUMENTS` is `<PR>`. If none is given, stop: "Usage: /babysit-pr-stop <PR>".

### 2. Check for an active watcher

```bash
ACTIVE=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].babysit.active" 2>/dev/null || echo "null")
if [[ "$ACTIVE" != "true" ]]; then
  echo "No active babysit watcher for PR #$PR — nothing to stop."
  exit 0
fi
```

`null`/`false`/missing all mean "not watching" → warn and exit cleanly (no error).

### 3. Request the stop (cooperative shutdown)

Set the stop flag so the next `/babysit-pr … --tick` cycle's `T0` short-circuit terminates the watcher cleanly (clearing `active`, `dispatch_in_flight`, and emitting the final summary). Write atomically via the helper — never raw `jq` (`handoff-files.md`):

```bash
"$SESSION_STATE_SH" --set ".prs[\"$PR\"].babysit.stop_requested=true"
```

Do **not** clear `active` here — let the watcher's terminate path own that so its final summary fires exactly once. (If no further tick will run — e.g. the loop was already torn down — set `active=false` here too so state stays consistent.)

### 4. Cancel the recurring poll

- **`/loop` mode (default):** the session loop stops re-arming once the watcher terminates; if you can cancel the active `/loop` immediately (runtime stop / "stop polling"), do so — otherwise the `stop_requested` flag guarantees the next tick is the last.
- **Durable mode (`CronCreate`):** look up the job id and remove it so it stops firing across sessions:
  ```bash
  CRON_ID=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].babysit.cron_job_id" 2>/dev/null || echo "null")
  ```
  If non-null, call `CronDelete <CRON_ID>`, then remove that entry from top-level `polling_jobs[]` and clear `.prs["<PR>"].babysit.cron_job_id` (so `session-state.json` stays authoritative — `pm/SKILL.md` mode-switch cleanup contract). Since no further tick will fire after `CronDelete`, also set `.prs["<PR>"].babysit.active=false` here.

### 5. Confirm

```
Stopped babysitting PR #<PR>. The watcher will exit on its next tick (durable poll cancelled). No further /fixpr or /wrap dispatches will be made.
```

If durable cancellation happened, note the deleted `cron_job_id`. If there was no active watcher, the Step 2 message already reported the no-op.
