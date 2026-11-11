<!-- pm-routing:begin -->
Route `shared:window-fit`. In 1B.5 apply the ranked-batch fit. In Step 3.4 use the existing single-candidate estimate and fit without applying the batch presentation or recording a batch plan.
<!-- pm-routing:end -->
**Window-fit gate (when `WINDOW_STR` is set and Step 0b parsed it successfully).** After ranking and before dispatch, trim the ranked batch to fit inside the remaining window using `makespan.sh`. This is a pure trim gate — it never reorders the batch.

Recompute the remaining window immediately before dispatch. Run the same
clock check for the initial batch and every candidate refill under an active
window.

<!-- test-anchor: pm-window-fit-clock -->
```bash
WINDOW_FIT_CLOCK=unverified
if [[ "${DEADLINE_EPOCH:-}" =~ ^[1-9][0-9]{0,15}$ ]] &&
    NOW_EPOCH=$(date +%s 2>/dev/null) &&
    [[ "$NOW_EPOCH" =~ ^[1-9][0-9]{0,15}$ ]]; then
  WINDOW_FIT_CLOCK=ready
  RAW_REMAINING_MIN=$(( (DEADLINE_EPOCH - NOW_EPOCH) / 60 ))
  REMAINING_MIN=$(( RAW_REMAINING_MIN - STALL_MARGIN_MIN ))
  if [[ "$REMAINING_MIN" -lt 0 ]]; then REMAINING_MIN=0; fi
  if [[ "$REMAINING_MIN" -lt "$EFFECTIVE_WINDOW_MIN" ]]; then
    EFFECTIVE_WINDOW_MIN="$REMAINING_MIN"
  fi
fi
```

Only `WINDOW_FIT_CLOCK=ready` allows fitting or dispatch. If the clock or
deadline is unverified, hold new launches, leave the stored batch and queued
picks intact, and report that the remaining window could not be verified.
Running pipelines continue. Retry the read on the next eligible turn.

1. For each ranked candidate, call `estimate-resolve.sh <N>` to get `est_lo`/`est_hi`, and **branch on its exit code — the stdout line is only meaningful for `0` and `1`**: `0` (from the issue body) and `1` (tier-table fallback) are both real estimates, so parse `est_lo`/`est_hi` from the `Est:` line. `2` (`unestimated`) means send `null`/`null` and let `makespan.sh` apply the Standard fallback (120/180 min — the canonical value, `time-estimates.md` §Unestimated issues); never parse the literal `unestimated` string into the batch JSON. `3` (usage) and `4` (gh/jq error) are **read failures, not estimates** — do not feed their output to `makespan.sh`, which would silently miscalculate the window fit. Treat the issue as unestimated for fitting, and name the failing issue and exit code in one line so the plan is not read as fully measured.
2. Build the JSON from `BATCH_ISSUES` and pipe to `makespan.sh --ceiling "$LIMIT"` (Step 0 — the batch cannot run wider than `min(CEILING, ACTIVE_WORK_CAP)`). If `makespan_hi <= EFFECTIVE_WINDOW_MIN` (freshly recomputed above), the full batch fits — proceed to dispatch.
3. If `makespan_hi > effective_window_min`, drop the **lowest-ranked** candidate and recompute. Repeat until the remaining batch fits or only one issue remains. If that single remaining issue **still** exceeds the window, do **not** dispatch anything — emit a no-fit message instead: `No batch fits in the remaining window ({EFFECTIVE_WINDOW_MIN} min). Suggest a longer window or a narrower selection.` and list all exclusions.
4. Each dropped issue is an **exclusion** — name it with the math:
   `#N (90 min plan) — excluded: batch would overshoot window by {delta} min`
5. Present the **Window Plan** block before `## Suggested Next Issues`:
   ```
   ## Window Plan (until ~HH:MM ET · effective N h after M min stall margin)
   Batch: #42, #38 — plan-bound makespan 3 h · finish ~4:30 PM ET ✓
   Excluded (window):
   - #61 (180 min plan) — excluded: adding it overshoots by 90 min
   ```
   Also persist the final batch issue numbers to session-state so the Step 8 monitor loop can scope overrun alerts to the window batch:
   ```bash
   BATCH_NUMS="[$(printf '"%s",' "${BATCH_ISSUES[@]}" | sed 's/,$//')]"
   "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].window.batch_issues=${BATCH_NUMS}" 2>/dev/null || true
   ```
   When `MAKESPAN_SH` or `ESTIMATE_RESOLVE_SH` is unavailable, follow Step 0's dispatch pause for the active window.

