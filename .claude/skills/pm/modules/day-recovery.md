<!-- pm-routing:begin -->
Route `day:recovery`. Read after monitor-mode recovery and the existing parked snapshot checks. Load day:preconditions only when this path needs the 2D.1(b+) snapshot.
<!-- pm-routing:end -->
### 2D.5: Recovery

A day loop can outlive the context that armed it. After compaction, `monitor-mode.md` "Post-Compaction Recovery" runs first; then execute 2D.1(b+)’s `pm-day-park-snapshot` block exactly once and use its `DAY_SNAPSHOT` for day/park recovery. It is **not** in `--session-view`'s projection — that lifts only `.prs` and `.root_repo` out of the repo block — so a `--session-view` read alone reports an armed day loop as absent, exactly as it would a refill pause (1A.2). Reconcile `active`, the identity pair, and `last_tick_at` against the freshness window from 2D.1(b): fresh → resume ticking and say so in one line; stale → the loop died, so reclaim and re-arm. `/pm` resume (1A.4) reports a paused or interrupted day loop alongside the refill posture for the same reason: a state the user cannot see is one they cannot lift.

**Also check the park record during recovery.** Run 2D.1(b+)'s
`pm-day-park-route` against the same `DAY_SNAPSHOT` before reclaiming or
re-arming any stale day loop. For `normal`, continue the ordinary day
reconciliation. For either `recover:*` route, run **Recover the captured wake**
below and stop ordinary recovery. A restart alone cannot prove a previous
wake stopped. For `manual:*`, retain the park, arm nothing, and name the
reason and `/pause-resume` in one line.

**Recover the captured wake.** Run the shared [captured wake recovery](../../../reference/pm-day-wake-recovery.md) steps. They use the original typed binding and the installed publisher. Keep the park and require manual resume if the wake or its owning session cannot be verified. Only a successful publication permits an automatic-resume promise.

