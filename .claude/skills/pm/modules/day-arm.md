<!-- pm-routing:begin -->
Route `day:arm`. Read after Step 2 when arming. Read on D3 cadence change when the tick needs the Monitor template.
<!-- pm-routing:end -->
### 2D.2: Arm

By the time this runs, 2D.1 has settled ownership and **Steps 1 and 2 have already run in full and unchanged** — the entry mode (1A resume or 1B cold start), Step 1C's cleanup gates, Step 1D's triage, and the ranking and first dispatch. Day mode does not skip the first turn's work; it keeps going after it. Initialize state and arm one `Monitor`:

**Resolve the goal first — the init write below replaces the whole `day` object, so anything read after it reads what was just written, not what was there.** `/pm day resume` with no goal text must carry the interrupted run's goal forward rather than wiping it:

<!-- test-anchor: pm-day-arm-prior-goal -->
```bash
DAY_STATE_PATH=".repos[\"$REPO_KEY\"].day"
PRIOR_GOAL_RC=0
PRIOR_DAY_JSON=$("$SESSION_STATE_SH" --get-json "$DAY_STATE_PATH") || PRIOR_GOAL_RC=$?
if [ "$PRIOR_GOAL_RC" -eq 6 ]; then
  PRIOR_GOAL_RC=0
  PRIOR_DAY_JSON=$("$SESSION_STATE_SH" --get-json "$DAY_STATE_PATH") || PRIOR_GOAL_RC=$?
fi
case "$PRIOR_GOAL_RC" in
  0)
    PRIOR_GOAL_JSON=$(jq -cs '
      if length != 1 then error("invalid day snapshot")
      else .[0] |
        if . == null then null
        elif type == "object" and (.goal | type == "string" or type == "null") then .goal
        else error("invalid saved day goal") end
      end' <<< "$PRIOR_DAY_JSON") || PRIOR_GOAL_RC=4
    ;;
  3) PRIOR_DAY_JSON=null; PRIOR_GOAL_JSON=null ;;
esac
```

If `PRIOR_GOAL_RC` is neither `0` nor `3`, report that the saved goal could not be read and stop before initialization. Exit `3` means no state file. Initialization still requires the active reservation. A stored JSON `null` means no saved goal. Retry a lock timeout (exit `6`) once, as documented in `handoff-files.md`. The saved JSON stays encoded so even a trailing newline or the literal word `null` survives.

Also read `PRIOR_HITS` before the init write so the thrash-guard counter can be carried forward across re-arms (2D.6). Use a lenient default on failure — an unreadable counter resets to 0 rather than blocking the arm:

```bash
PRIOR_HITS_RC=0
PRIOR_HITS=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.consecutive_limit_hits") || PRIOR_HITS_RC=$?
[ "$PRIOR_HITS_RC" -eq 3 ] && PRIOR_HITS=0
# Unreadable or non-integer: start clean — each new limit hit will still increment from 0
[[ "$PRIOR_HITS" =~ ^[0-9]+$ ]] || PRIOR_HITS=0
```

Take `BUSINESS_GOAL` when supplied, otherwise the saved JSON. Build the whole day object in one call. Compare it against the same day snapshot that supplied the saved goal, so a newer arm or park keeps its state.

<!-- test-anchor: pm-day-arm-init -->
```bash
INIT_RC=$PRIOR_GOAL_RC
if [ "$INIT_RC" -eq 0 ] &&
    ! jq -e --arg gen "${DAY_ARM_GENERATION:-}" --argjson reserved "${DAY_RESERVATION:-null}" '
      $gen != "" and . == $reserved and .active == true and
      .stop_requested == false and .monitor_generation == $gen and .monitor_task_id == null
    ' >/dev/null <<< "$PRIOR_DAY_JSON"; then
  INIT_RC=7
fi
if [ "$INIT_RC" -eq 0 ]; then
  ARM_NOW=$(date -u +%FT%TZ) || INIT_RC=4
fi
if [ "$INIT_RC" -eq 0 ]; then
  DAY_GENERATION="$DAY_ARM_GENERATION"
  DAY_JSON=$(jq -cn \
    --arg now "$NOW" --arg heartbeat "$ARM_NOW" --arg generation "$DAY_GENERATION" --arg new_goal "${BUSINESS_GOAL:-}" \
    --argjson prior_goal "$PRIOR_GOAL_JSON" \
    --argjson base "$DAY_CADENCE_MIN" --argjson maxfail "$MAX_PIPELINE_FAILURES" \
    --argjson phits "$PRIOR_HITS" \
    '{active:true, started_at:$now, last_tick_at:$heartbeat,
      cadence_base_minutes:$base, cadence_effective_minutes:$base,
      tick_count:0, digest:null, digest_streak:0,
      failure_streak:0, max_pipeline_failures:$maxfail,
      refill_halted:false, halt_reason:null, stop_requested:false,
      monitor_task_id:null, monitor_generation:$generation, paused_at:null,
      parked_until:null, limit_kind:null, park_generation:null,
      limit_resume_task_id:null, limit_resume_generation:null,
      consecutive_limit_hits:$phits,
      goal:(if $new_goal == "" then $prior_goal else $new_goal end)}') || INIT_RC=$?

  if [ "$INIT_RC" -eq 0 ]; then
    "$SESSION_STATE_SH" --cas "$DAY_STATE_PATH=$DAY_JSON" --expect "$PRIOR_DAY_JSON" \
      --expect-at '.pmm_active' "$PMM_EXPECTED" || INIT_RC=$?
  fi
fi
if [ "$INIT_RC" -eq 0 ]; then DAY_RESERVATION="$DAY_JSON"; fi
```

The preamble validates the numeric arguments as unsigned integers before jq builds the state.

**This write must succeed before anything is armed.** A changed reservation,
a newer day update, a fleet conflict, or a failed read or write stops this
attempt. Release only this invocation's unpublished reservation with
`pm_day_release_start`, if it still matches. Report the failure and stop.

Use the goal in `DAY_JSON` for the first heartbeat, and say when it was carried forward from a previous run rather than given this time — a resumed goal the user cannot see is one they cannot correct.

Then arm the `Monitor` with `persistent: true` and description `PM day mode`, sleep-first so the loop's own first tick is the one run inline below:

```bash
while sleep "$(( DAY_CADENCE_MIN * 60 ))"; do
  printf '%s\n' "/pm day --tick --day-generation $DAY_GENERATION --cadence ${DAY_CADENCE_MIN}m"
done
```

Record the returned task ID immediately under the same active reservation.

<!-- test-anchor: pm-day-start-publish -->

```bash
pm_day_publish_start() {
  local published
  [[ -n "${MONITOR_TASK_ID:-}" && "$MONITOR_TASK_ID" != null ]] || return 4
  published=$(jq -c --arg task "$MONITOR_TASK_ID" '.monitor_task_id=$task' \
    <<< "$DAY_RESERVATION") || return 4
  "$SESSION_STATE_SH" --cas "$DAY_STATE_PATH=$published" --expect "$DAY_RESERVATION" \
    --expect-at '.pmm_active' "$PMM_EXPECTED"
}
PUBLISH_RC=0
pm_day_publish_start || PUBLISH_RC=$?
```

Check that write's exit code before entering the immediate tick. A nonzero
`PUBLISH_RC` takes the publication failure path.

- If arming failed, release only this invocation's unpublished reservation.
- If publication failed, stop only the native task returned by this attempt,
  then release only the unpublished reservation still owned by this attempt.
  Leave a replacement record untouched. Name the task ID if the stop failed.

Either way, tell the user day mode is not running: a thread that believes it armed and did not is the silent-watcher failure `scheduling-reliability.md` exists to prevent. The pipelines Step 1 already started keep running; they just have no between-turn loop.

<!-- pm-routing:begin -->
Only after successful Monitor publication, bind the immediate tick to the exact generation published by this arming invocation. Pass it into the normal D0 gate. Preserve the user invocation's receipt.

<!-- test-anchor: pm-day-arm-immediate-generation -->
```bash
TICK_GENERATION="$DAY_GENERATION"
```
<!-- pm-routing:end -->
Then **run one tick immediately** (2D.3) — the `sleep` fires first, so without this the board sits idle for a full cadence.

