<!-- pm-routing:begin -->
Set up or recover the existing passive tracking after Step 1.
<!-- pm-routing:end -->

After Step 1 presents assignments/suggestions, detect whether any **active cloud threads** exist and configure on-demand tracking. **On the default (non-day) path `/pm` is a strictly on-demand orchestrator** — it does **not** propose or arm any recurring poll (`Monitor`, `CronCreate`, `/loop`, or hand-rolled wake chains). PR fleet monitoring between messages is owned by `/pr-monitor-and-manage`.

Resume mode passes through this step too — restore passive tracking state; do **not** re-arm a poll.

For explicit user-initiated "poll every N" requests that are not PR-fleet-specific, persistent `Monitor` is the canonical primitive per `.claude/rules/scheduling-reliability.md`. `/pm` on this path never sets one up.

> **The one carve-out: `DAY_MODE=true`.** Day mode arms exactly one persistent `Monitor` for the repo (Step 2D) and is **mutually exclusive with `/pr-monitor-and-manage`** — which is what keeps "exactly one owner dispatches against a given PR" true, the invariant the never-arm-a-poll rule was protecting in the first place. When `DAY_MODE=true`, run 2.1 for the `ACTIVE_COUNT` it produces, **skip 2.2's redirect** (day mode *is* the monitoring answer, so pointing at `/pr-monitor-and-manage` would name the one skill that must not run alongside it), record 2.3's passive fields as usual, and continue into 2D. Decision and rationale: `.claude/reference/pm-monitoring-decision.md`, `.claude/reference/pm-day-mode.md`.

### 2.1: Detect active threads

An active cloud thread is an open issue that is yours and in progress, established by ANY of the ownership triggers below — assignment to `$GH_USER` is **not** required when a trigger already proves the issue yours (it is only a weak fallback signal for otherwise-unowned issues):
- A feature branch referencing the issue exists on the remote **and is attributable to you** — it has a matching local worktree (yours) or an open PR you authored. A bare remote branch whose ownership can't be verified does **not** count: a `git branch -r` name carries no author, so a collaborator's pushed branch would otherwise inflate your count.
- A local worktree exists for the issue (inherently yours — you created it)
- An open PR **you authored** (`author.login == $GH_USER` / `@me`) has `Closes #N` / `Fixes #N` referencing the issue

Cross-reference the open-issue list (already fetched in Step 1) against open PRs and `git branch -r` / `git worktree list`. Count the result as `ACTIVE_COUNT`. **`ACTIVE_COUNT` is your own active threads only** — a collaborator's PR or bare remote branch does not make an issue one of yours, and `/pr-monitor-and-manage` (the ≥3 redirect target in 2.2) manages `--author @me` PRs, so the count feeding the redirect must match its scope (issue #732).

### 2.2: Fleet monitoring redirect (≥3 active threads)

When `ACTIVE_COUNT ≥ 3`, surface a one-line redirect (do not offer a scheduler from `/pm`):

> "You have {N} active cloud threads. Run `/pr-monitor-and-manage` to auto-dispatch fixes and merges across the fleet with per-PR state tracking."

For 0–2 active threads, emit no polling offer — proceed with the assignments table and status only.

### 2.3: Passive tracking (default)

`/pm` tracks orchestration state on demand. When the user asks "status", "what's next?", or similar, Step 3 fetches live GitHub state and updates the assignments table. The user may explicitly say "passive" or "just track state" at any time — honor that.

Update `~/.claude/session-state.json` to reflect passive tracking. Preserve unknown fields and record at least:

- `monitoring_active` — true when `/pm` is tracking in-flight work (not a recurring poll)
- `monitoring_mode`: `passive` for `/pm`-owned monitoring
- tracked `prs` and `active_agents` where known

**Do not create, modify, or clear `polling_jobs[]` on `/pm`'s behalf.** That field remains valid for other skills (`/pr-monitor-and-manage`, `/babysit-pr`, etc.); leave entries `/pm` did not create intact.

If orchestration state is stale after context turnover, recover using `.claude/rules/monitor-mode.md` "PM Monitoring Recovery".

### 2.4: Backwards compatibility

Any `/pm`-created `CronCreate` jobs from before this change died with their originating session (`CronCreate` is session-scoped; `durable: true` has no effect). New `/pm` sessions do not create replacement polls, and `session-scheduling-reconcile.sh` clears the dead records at session start (issue #827). Day mode does not change this: it arms a persistent `Monitor`, never a cron job.


On the passive path, mark `2 ran` when tracking setup finishes, or `2 failed`
with its setup error. The day path records setup in `2D`.

After setup, proceed to **Step 2D** when `DAY_MODE=true`, otherwise straight to **Step 3: Orchestration Loop**.

