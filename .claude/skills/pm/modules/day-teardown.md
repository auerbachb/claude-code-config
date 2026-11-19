<!-- pm-routing:begin -->
Route `day:teardown`. Read on a verified D4 exit or a user stop of day mode. Keep the current generation and ownership checks.
<!-- pm-routing:end -->
### 2D.4: Teardown (D-END)

On any exit or pause, in this order — the order matters, because the stop flag is what makes an already-queued tick a no-op if `TaskStop` is slow:

1. `"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.stop_requested=true"`
2. `TaskStop` the exact recorded `day.monitor_task_id`. Missing ID, or a failed stop → **keep `active=true`, retain the ID**, and report a degraded teardown naming the task; do not pretend it stopped.
3. Only after the stop succeeds: `active=false`, `monitor_task_id=null`, `monitor_generation=null`, and for `stable-frozen` also `paused_at="$NOW"`.
4. **Print the resume pointer.** Name the command that picks the work up: `/pm day resume` in day mode, or `/pm resume` for a plain round. Session state and handoff files already hold the in-flight work, so nothing else is generated. A day that ends without the pointer leaves the next thread guessing where to start, which is the cost this whole mode exists to remove.
5. Print the final block: outcome and reason, ticks run, issues merged this run, issues still open with their state, and anything left halted or paused.

