<!-- pm-routing:begin -->
Route `day:arm`. Read after Step 2 when arming. Read on D3 cadence change when the tick needs the Monitor template.
<!-- pm-routing:end -->
### 2D.2: Arm

By the time this runs, 2D.1 has settled ownership and **Steps 1 and 2 have already run in full and unchanged** — the entry mode (1A resume or 1B cold start), Step 1C's cleanup gates, Step 1D's triage, and the ranking and first dispatch. Day mode does not skip the first turn's work; it keeps going after it. Initialize state and arm one `Monitor`:

**Resolve the goal first — the init write below replaces the whole `day` object, so anything read after it reads what was just written, not what was there.** `/pm day resume` with no goal text must carry the interrupted run's goal forward rather than wiping it:

<!-- test-anchor: pm-day-arm-prior-goal -->
```bash
PRIOR_GOAL_PATH=".repos[\"$REPO_KEY\"].day.goal"
PRIOR_GOAL_RC=0
PRIOR_GOAL_JSON=$("$SESSION_STATE_SH" --get-json "$PRIOR_GOAL_PATH") || PRIOR_GOAL_RC=$?
if [ "$PRIOR_GOAL_RC" -eq 6 ]; then
  PRIOR_GOAL_RC=0
  PRIOR_GOAL_JSON=$("$SESSION_STATE_SH" --get-json "$PRIOR_GOAL_PATH") || PRIOR_GOAL_RC=$?
fi
case "$PRIOR_GOAL_RC" in
  0) jq -e 'type == "string" or type == "null"' >/dev/null <<< "$PRIOR_GOAL_JSON" || PRIOR_GOAL_RC=4 ;;
  3) PRIOR_GOAL_JSON=null ;;
esac
```

If `PRIOR_GOAL_RC` is neither `0` nor `3`, report that the saved goal could not be read and stop before initialization. Exit `3` means no state file. A stored JSON `null` means no saved goal. Retry a lock timeout (exit `6`) once, as documented in `handoff-files.md`. The saved JSON stays encoded so even a trailing newline or the literal word `null` survives.

Also read `PRIOR_HITS` before the init write so the thrash-guard counter can be carried forward across re-arms (2D.6). Use a lenient default on failure — an unreadable counter resets to 0 rather than blocking the arm:

```bash
PRIOR_HITS_RC=0
PRIOR_HITS=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.consecutive_limit_hits") || PRIOR_HITS_RC=$?
[ "$PRIOR_HITS_RC" -eq 3 ] && PRIOR_HITS=0
# Unreadable or non-integer: start clean — each new limit hit will still increment from 0
[[ "$PRIOR_HITS" =~ ^[0-9]+$ ]] || PRIOR_HITS=0
```

Take `BUSINESS_GOAL` when supplied, otherwise the saved JSON. Build the whole day object in one call so a second write cannot fail after initialization.

<!-- test-anchor: pm-day-arm-init -->
```bash
INIT_RC=$PRIOR_GOAL_RC
if [ "$INIT_RC" -eq 3 ]; then INIT_RC=0; fi
if [ "$INIT_RC" -eq 0 ]; then
  DAY_GENERATION="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
  DAY_JSON=$(jq -cn \
    --arg now "$NOW" --arg new_goal "${BUSINESS_GOAL:-}" \
    --argjson prior_goal "$PRIOR_GOAL_JSON" \
    --argjson base "$DAY_CADENCE_MIN" --argjson maxfail "$MAX_PIPELINE_FAILURES" \
    --argjson phits "$PRIOR_HITS" \
    '{active:true, started_at:$now, last_tick_at:$now,
      cadence_base_minutes:$base, cadence_effective_minutes:$base,
      tick_count:0, digest:null, digest_streak:0,
      failure_streak:0, max_pipeline_failures:$maxfail,
      refill_halted:false, halt_reason:null, stop_requested:false,
      monitor_task_id:null, monitor_generation:null, paused_at:null,
      parked_until:null, limit_kind:null, park_generation:null,
      limit_resume_task_id:null, limit_resume_generation:null,
      consecutive_limit_hits:$phits,
      goal:(if $new_goal == "" then $prior_goal else $new_goal end)}') || INIT_RC=$?

  if [ "$INIT_RC" -eq 0 ]; then
    "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day=$DAY_JSON" || INIT_RC=$?
  fi
fi
```

The numeric `--argjson` arguments are why the preamble validates those flags as unsigned integers: `--argjson base 2.5` or a non-numeric value makes `jq` fail here and the whole object never gets written.

**This write must succeed before anything is armed.** A non-zero `INIT_RC` means the ownership claim 2D.1(c) depends on was never published *and* there is no `day` object for the loop to tick against — so arm nothing, report that day mode did not start, and stop. Arming on an unwritten claim is the worst available order: the race protection is gone (the other side re-reads and sees nothing) and the Monitor would tick into state that does not exist.

Use the goal in `DAY_JSON` for the first heartbeat, and say when it was carried forward from a previous run rather than given this time — a resumed goal the user cannot see is one they cannot correct.

Then arm the `Monitor` with `persistent: true` and description `PM day mode`, sleep-first so the loop's own first tick is the one run inline below:

```bash
while sleep "$(( DAY_CADENCE_MIN * 60 ))"; do
  printf '%s\n' "/pm day --tick --day-generation $DAY_GENERATION --cadence ${DAY_CADENCE_MIN}m"
done
```

Record the returned task ID **immediately** — an unrecorded Monitor cannot be stopped, so a day loop with no recorded ID is one nothing can turn off:

```bash
PUBLISH_RC=0
"$SESSION_STATE_SH" \
  --set ".repos[\"$REPO_KEY\"].day.monitor_task_id=$MONITOR_TASK_ID" \
  --set ".repos[\"$REPO_KEY\"].day.monitor_generation=\"$DAY_GENERATION\"" || PUBLISH_RC=$?
```

**Check that write's exit code — do not assume it landed.** The two failures need opposite handling and both end with day mode reported as not running:

- **Arming failed** (no task ID): roll the state back — `active=false`, `last_tick_at=null`, both identity fields `null`.
- **Arming succeeded but the publish failed** (`PUBLISH_RC` non-zero): a Monitor is now running that state does not know about, so **`TaskStop` it using the ID you hold in hand right now**, then roll back the same fields. That ID exists only in this shell; letting the turn end without using it strands a live Monitor re-invoking `/pm day --tick` on a repo with no `day` state, forever, with nothing left that can name it to `TaskStop`. If the `TaskStop` also fails, say so explicitly and name the task ID in the message so a human can stop it — a stranded loop the user cannot see is strictly worse than one they can.

Either way, tell the user day mode is not running: a thread that believes it armed and did not is the silent-watcher failure `scheduling-reliability.md` exists to prevent. The pipelines Step 1 already started keep running; they just have no between-turn loop.

<!-- pm-routing:begin -->
Only after successful Monitor publication, bind the immediate tick to the exact generation published by this arming invocation. Pass it into the normal D0 gate. Preserve the user invocation's receipt.

<!-- test-anchor: pm-day-arm-immediate-generation -->
```bash
TICK_GENERATION="$DAY_GENERATION"
```
<!-- pm-routing:end -->
Then **run one tick immediately** (2D.3) — the `sleep` fires first, so without this the board sits idle for a full cadence.

