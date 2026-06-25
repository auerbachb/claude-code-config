---
name: babysit-pr-stop
description: Cleanly stop an active /babysit-pr watcher for a PR. Sets the watcher's stop flag in session-state so its next tick terminates, cancels the recurring poll (CronDelete in durable mode), and confirms. Invoke as `/babysit-pr-stop <PR>`.
triggers:
  - babysit-pr-stop
  - unwatch pr
  - cancel babysit
  - end pr watcher
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

### 3. Request the stop (cooperative shutdown)

Set the stop flag so the next `/babysit-pr … --tick` cycle's `T0` short-circuit terminates the watcher cleanly (clearing `active`, `dispatch_in_flight`, and emitting the final summary). Write atomically via the helper — never raw `jq` (`handoff-files.md`):

```bash
"$SESSION_STATE_SH" --set ".prs[\"$PR\"].babysit.stop_requested=true"
```

Do **not** clear `active` here — let the watcher's terminate path own that so its final summary fires exactly once. (If no further tick will run — e.g. the loop was already torn down — set `active=false` here too so state stays consistent.)

### 4. Cancel the recurring poll

- **`/loop` mode (default):** the session loop stops re-arming once the watcher terminates; if you can cancel the active `/loop` immediately (runtime stop / "stop polling"), do so — otherwise the `stop_requested` flag guarantees the next tick is the last.
- **Durable mode (`CronCreate`):** look up the job id and remove it so it stops firing across sessions:

  **Fail closed** — do not report "stopped", prune `polling_jobs[]`, or clear `active` unless **both** the id lookup **and** `CronDelete` succeed. If either fails, exit early with the cron still recorded so a retry can finish the teardown (a falsely-reported stop while the cron keeps firing is the failure mode to avoid):

  ```bash
  CRON_ID=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].babysit.cron_job_id") || {
    echo "ERROR: could not read cron_job_id — aborting stop; cron still active, retry /babysit-pr-stop $PR." >&2; exit 1; }
  if [[ -n "$CRON_ID" && "$CRON_ID" != "null" ]]; then
    CronDelete "$CRON_ID" || {
      echo "ERROR: CronDelete failed for $CRON_ID — NOT clearing state; cron may still fire, retry /babysit-pr-stop $PR." >&2; exit 1; }
  fi
  ```

  Only **after** `CronDelete` succeeds, prune `polling_jobs[]` and clear the per-PR state. `session-state.sh --set` only **assigns** a path — it cannot splice an array element — so read the array, filter it locally with `jq` (a read/transform, not a state write), and write the whole new array back via `--set` (the only writer, keeping the atomic guarantee and the "no raw `jq` writes" rule):

  ```bash
  JOBS=$("$SESSION_STATE_SH" --get '.polling_jobs')              # JSON array (or "null")
  if [[ "$JOBS" != "null" && -n "$JOBS" ]]; then
    NEW_JOBS=$(jq -c --arg id "$CRON_ID" 'map(select(.id != $id))' <<<"$JOBS")
  else
    NEW_JOBS='[]'
  fi
  "$SESSION_STATE_SH" \
    --set ".polling_jobs=$NEW_JOBS" \
    --set ".prs[\"$PR\"].babysit.cron_job_id=null" \
    --set ".prs[\"$PR\"].babysit.active=false" \
    --set ".prs[\"$PR\"].babysit.dispatch_in_flight=null"
  ```

  After a successful `CronDelete` **no further tick will fire**, so the watcher's normal T-END cleanup never runs — this branch therefore performs the **full** terminal cleanup itself: it clears `active` **and** `dispatch_in_flight` (not just `active`), mirroring T-END so no stale in-flight marker is left behind (`pm/SKILL.md` mode-switch cleanup contract: `polling_jobs[]` stays authoritative).

### 5. Confirm

Word the confirmation to match what actually happened — do **not** promise a "next tick" in durable mode, where `CronDelete` already terminated the watcher and this skill performed the full cleanup:

- **Durable mode (cron deleted in Step 4):**

  ```
  Stopped babysitting PR #<PR>. Durable poll cancelled (cron_job_id <ID> deleted) and watcher state fully cleared — no next tick will run. No further /fixpr or /wrap dispatches will be made.
  ```

- **`/loop` mode (cooperative stop via the flag):**

  ```
  Stopped babysitting PR #<PR>. The watcher will exit on its next tick (stop_requested set). No further /fixpr or /wrap dispatches will be made.
  ```

If there was no active watcher, the Step 2 message already reported the no-op.
