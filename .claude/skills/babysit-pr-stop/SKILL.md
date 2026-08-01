---
name: babysit-pr-stop
description: Cleanly stop an active /babysit-pr watcher for a PR. Sets the watcher's stop flag in session-state so its next tick terminates, cancels the recurring /loop, and confirms. Invoke as `/babysit-pr-stop <PR>`.
triggers:
  - babysit-pr-stop
  - unwatch pr
  - cancel babysit
  - end pr watcher
argument-hint: "<PR>"
---

Stop the `/babysit-pr` watcher for one PR. This is the clean-cancel companion to `/babysit-pr` — it does not merge, fix, or touch the PR itself; it only tears down the watcher loop and its state.

Stopping is **cooperative and idempotent**: it flags the watcher to terminate on its next tick (the watcher's `T0` short-circuit handles the actual clean exit). Running it on a PR with no active watcher is a safe no-op.

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

The watcher always runs on `/loop` (issue #827 removed `--durable`, the only other mode). The session loop stops re-arming once the watcher terminates; if you can cancel the active `/loop` immediately (runtime stop / "stop polling"), do so — otherwise the `stop_requested` flag set in Step 3 guarantees the next tick is the last.

If you cancelled the loop outright rather than letting it tick once more, the watcher's T-END cleanup never runs — so perform the terminal cleanup here, clearing `dispatch_in_flight` as well as `active` so no stale in-flight marker is left behind:

```bash
"$SESSION_STATE_SH" \
  --set ".prs[\"$PR\"].babysit.active=false" \
  --set ".prs[\"$PR\"].babysit.dispatch_in_flight=null"
```

### 5. Confirm

Word the confirmation to match what actually happened:

- **Loop cancelled outright (full cleanup done in Step 4):**

  ```
  Stopped babysitting PR #<PR>. Poll cancelled and watcher state cleared — no next tick will run. No further /fixpr or /wrap dispatches will be made.
  ```

- **Cooperative stop (flag set, one tick remaining):**

  ```
  Stopped babysitting PR #<PR>. The watcher will exit on its next tick (stop_requested set). No further /fixpr or /wrap dispatches will be made.
  ```

If there was no active watcher, the Step 2 message already reported the no-op.
