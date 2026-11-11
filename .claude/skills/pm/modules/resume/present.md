<!-- pm-routing:begin -->
Route `resume:present`. Present and continue the recovered work after its verification. Use Steps 1C and 1D at the existing calls.
<!-- pm-routing:end -->
### 1A.4: Present recovered state

**First, run Step 1C (Backlog & workspace cleanup, below) — the full inline `/pm-clean` flow, with its confirm gates resolved (acted on or declined) before anything below** — it runs on every invocation, resume included (unless `--no-clean` / `fast` was passed, which prints only the ranking-only health line and skips the gates). Then show the user:
1. Verified assignments table (corrected for merges/closures since handoff)
2. Any issues that were in-progress but whose PRs are now missing or stale
3. Remaining open issues not yet assigned
4. **The refill posture recovered in 1A.2** — say it out loud whenever it is not the default: "Refill is paused (you stopped it earlier) — say resume to restart it", or for a narrowed scope, name the scope. A pause the user can't see is one they can't lift, and silence would read as an idle board with no explanation.
5. **Any day-mode state recovered from `.repos[<key>].day`** — same reason, same one-line treatment. A live loop (fresh `last_tick_at`) says it is still ticking and at what cadence; a `paused_at` marker says the board froze and how to resume; `refill_halted` says a failure pattern is holding refill and names it. Read it explicitly — `--session-view` does not project it (2D.5). Apply 3.4's exit-code table to `DAY_RC` here too: `3` means no day loop has ever run in this repo and is reported as nothing; anything else non-zero means the state was **unreadable**, which is reported as such rather than as an absent loop, since the difference is whether a Monitor may still be ticking.

**Then run Step 1D (Forgotten-PR triage, below) and print its `## Forgotten PRs` block** — always-on on the resume path too, rendered after the recovered-PR context above.

Proceed with current assignments by default — the recovered pipelines keep running, and this step starts nothing new on its own. **Anything this thread does launch from here — a refill into free capacity (3.4), or a batch you re-prioritize into — follows the same inline-first default as the cold-start path:** claim and dispatch the inline-eligible issues via Step 3.1 up to the **`LIMIT` concurrent-pipeline** limit (Step 0 — `min(CEILING, ACTIVE_WORK_CAP)`), queue the remainder, and report the launches rather than proposing them. Prompts and chips only for a named `/subagent` Step 4 disqualifier or an explicit ask (3.1). The refill posture recovered in 1A.2 — reported in item 4 above — decides whether the **automatic** side of that happens: paused means no refill launches until a human resumes, and a non-null scope narrows every candidate before ranking picks one. As in 1B.5, the pause binds autonomous launches only — a live in-chat `re-prioritize` or a request naming issues is the human acting, so it proceeds, and it does not on its own lift the pause for future refills.

State: "Continuing with current assignments. Say 're-prioritize' to change strategy, or 'give me prompts instead' for prompt blocks rather than inline runs."


Mark `1A ran` after recovering assignments and deciding how to continue. If the
invocation carries on with existing work and starts nothing, mark
`3.1 skipped (resume existing work)`. An actual launch records 3.1 in that step.

Then proceed to **Step 2: Active Monitoring Setup** (resume mode restores passive tracking — see Step 2).

