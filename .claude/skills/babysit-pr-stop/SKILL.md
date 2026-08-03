---
name: babysit-pr-stop
description: Cleanly stop an active /babysit-pr watcher for a PR. Sets the watcher's stop flag in session-state, stops its persistent Monitor task, and confirms. Invoke as `/babysit-pr-stop <PR>`.
triggers:
  - babysit-pr-stop
  - unwatch pr
  - cancel babysit
  - end pr watcher
argument-hint: "<PR>"
---

Stop the `/babysit-pr` watcher for one PR. This is the clean-cancel companion to `/babysit-pr` — it does not merge, fix, or touch the PR itself; it only tears down the watcher Monitor and its state.

Stopping is **exact and idempotent**: it records the stop request, stops the recorded Monitor task with `TaskStop`, and leaves the watcher's `T0` short-circuit armed for any tick that was already emitted. Running it on a PR with no active watcher is a safe no-op.

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

Distinguish "no watcher" from "the state helper failed" — do **not** collapse every error into a clean no-op (that would silently skip a real stop request):

```bash
ACTIVE=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].babysit.active"); GET_RC=$?
case "$GET_RC" in
  0) ;;                                   # value read OK (may be true/false/null)
  3) echo "No babysit state on file — nothing to stop."; exit 0 ;;  # state file missing
  *) echo "ERROR: session-state.sh --get failed (exit $GET_RC) — not assuming inactive; investigate before retrying." >&2; exit "$GET_RC" ;;
esac
if [[ "$ACTIVE" != "true" ]]; then       # only a genuine null/false means inactive
  echo "No active babysit watcher for PR #$PR — nothing to stop."
  exit 0
fi
```

Exit `3` (state file absent) is the legitimate "nothing to watch" case. Any other non-zero exit is a real helper/parse failure — surface it and stop rather than masking it as inactive.

### 3. Request the stop (race-safe shutdown)

Set the stop flag so any already-emitted `/babysit-pr … --tick` event's `T0` short-circuit terminates the watcher cleanly. Write atomically via the helper — never raw `jq` (`handoff-files.md`):

```bash
"$SESSION_STATE_SH" --set ".prs[\"$PR\"].babysit.stop_requested=true"
```

Do **not** clear `active` until the Monitor stop result is known.

### 4. Stop the recurring Monitor

The watcher always runs on a persistent `Monitor` (issues #914 and #924 retired both `/loop` modes). Read `.prs["$PR"].babysit.monitor_task_id` and call `TaskStop` for that exact task. A missing ID is a degraded stale watcher, not permission to assume a live poll was cancelled. If the ID is missing or `TaskStop` fails, keep `active=true`, retain the recorded task ID and `monitor_generation`, and report incomplete teardown; never report a successful stop. `stop_requested=true` makes already-emitted ticks no-ops, while A2 now refuses every re-arm of this incomplete state regardless of tick age. Clearing `active` here would let stale-watcher reclaim reset the stop flag and turn the old Monitor's later events back into live ticks beside a replacement.

After `TaskStop` succeeds, perform terminal cleanup here. **Clear `dispatch_in_flight` only when nothing is actually in flight:** a `/fixpr` or `/wrap` started by an earlier tick keeps running after the Monitor stops, and clearing its marker lets a later `/babysit-pr` arm dispatch a second one on the same PR — while the original, on completion, overwrites whatever state that new dispatch had written.

```bash
IN_FLIGHT=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].babysit.dispatch_in_flight" 2>/dev/null || echo "null")
if [[ "$IN_FLIGHT" == "null" || -z "$IN_FLIGHT" ]]; then
  "$SESSION_STATE_SH" \
    --set ".prs[\"$PR\"].babysit.active=false" \
    --set ".prs[\"$PR\"].babysit.monitor_task_id=null" \
    --set ".prs[\"$PR\"].babysit.monitor_generation=null" \
    --set ".prs[\"$PR\"].babysit.dispatch_in_flight=null" \
    --set ".prs[\"$PR\"].last_cron_action={\"type\":\"delete\",\"interval\":\"paused\",\"at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
else
  # Leave the marker: T0's TTL reclaim owns it, so it can never wedge forever.
  "$SESSION_STATE_SH" \
    --set ".prs[\"$PR\"].babysit.active=false" \
    --set ".prs[\"$PR\"].babysit.monitor_task_id=null" \
    --set ".prs[\"$PR\"].babysit.monitor_generation=null" \
    --set ".prs[\"$PR\"].last_cron_action={\"type\":\"delete\",\"interval\":\"paused\",\"at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
fi
```

The `last_cron_action` write is part of the same post-`TaskStop` transaction. Its historical name
records that this poll was deleted, so `polling-backoff-warn.sh` cannot emit stale STOP/WIDEN
instructions after a successful manual stop.

Say which happened — a stop that leaves a dispatch running is not the same promise as a stop that does not.

### 5. Confirm

Word the confirmation to match what actually happened:

- **Monitor stopped, nothing in flight:**

  ```
  Stopped babysitting PR #<PR>. Monitor stopped and watcher state cleared — no next tick will run. No further /fixpr or /wrap dispatches will be made.
  ```

- **Monitor stopped with a dispatch still running:**

  ```
  Stopped babysitting PR #<PR>. Monitor stopped — no new dispatch will start, but the in-flight <skill> may still complete and finish its own work.
  ```

- **Monitor task missing or TaskStop failed (cooperative guard only):**

  ```
  Babysit stop requested for PR #<PR>, but no Monitor task was stopped. Watcher state remains active with stop_requested=true so duplicate arming is blocked and already-emitted ticks terminate at T0. Retry exact teardown or repair the runtime task before re-arming.
  ```

If there was no active watcher, the Step 2 message already reported the no-op.
