<!-- pm-routing:begin -->
Update the assignment ledger when observing work or recording a dispatch.
<!-- pm-routing:end -->

Maintain a state table in the conversation. Update it as work progresses:

```
## Active Work

| Issue | Thread | Task ID | PR | Status | Last Update |
|-------|--------|---------|----|--------|-------------|
| #40 | Inline | — | PR #87 | Phase B (in review) | {timestamp} |
| #42 | Chip offered | `task_abc123` | — | Awaiting thread start | {timestamp} |
| #61 | Prompt generated | — | — | Awaiting thread start | {timestamp} |
| #38 | Active | — | PR #88 | In review | {timestamp} |
| #55 | Active | — | PR #90 | Merged | {timestamp} |
| #412 | Tracking | — | — | Parent of #413–#415 (0/3 merged) | {timestamp} |
| #413 ↳ #412 | Inline | — | PR #91 | Phase A | {timestamp} |
| #414 ↳ #412 | Inline | — | — | Queued behind #413 | {timestamp} |
```

**Thread column values:**

- `Inline` — **this thread** is doing the work, not a separate one: usually via the `/subagent` A→B→C flow (its phase shows in the Status column), and equally when a thread codes an adopted issue directly in a prepared worktree (`/start-issue` Step 7's front-door case, #1229). Carries no chip and no Task ID; this is the default for inline-eligible issues. The table is not `/pm`-only — any execution-capable thread bootstraps one in this schema when it adopts work (`chip-launching.md` "PM-context inline gate"), without thereby becoming a `/pm` thread.
- `Chip offered` — a chip was spawned for this thread-prompt issue (criterion 1/2 too-big, or explicitly requested) and is waiting on a click (chip mode).
- `Prompt generated` — a full prompt block was printed for the user to paste (thread-prompt issue: fallback mode, a failed spawn, or an explicit prompt request).
- `Active` — a separate thread is running for this issue.
- `Tracking` — a decomposed criterion-3 **parent** (#1193). It runs nothing itself and is never claimed, launched, or offered; its Status carries the child range and the merged count. It leaves the table once its last child merges and `/subagent`'s Phase C Completion closes it.

**`Tracking` is the one non-terminal row that is not in-flight work.** `chip-launching.md` reads this table's non-terminal rows as `IN_FLIGHT`; a parent holds no pipeline and no slot, so **exclude `Tracking` rows from that count** — its children are already counted individually, and counting the parent too would bill one chain twice against both the `CEILING` pipeline ceiling and the repo-wide cap.

**Decomposition children carry their parent** in the Issue column as `#{child} ↳ #{parent}`, so a chain reads as a group without a new column. Each child is an ordinary `Inline` row with its own issue number, its own claim, and its own lifecycle — one of them running while the rest wait on the chain (`/subagent` Step 6.0b), which the Status column says in words.

**Task ID column:** every `Chip offered` row MUST carry the `task_id` returned by its `spawn_task` call — it is the only handle for dismissing that chip later, and a chip whose `task_id` was not recorded cannot be withdrawn. `Prompt generated` and `Active` rows leave it empty (`—`).

`Chip offered` and `Prompt generated` are the same state from the pipeline's view — offered, not yet started — and both pair with the `Awaiting thread start` status. Both are excluded from re-offering: `/prompt`'s Path B scan treats an offered-but-unstarted chip exactly as it treats `Prompt generated`, so a re-run never double-offers the same issue.


Mark `3.2 ran` when the invocation records or reconciles its assignment ledger.
Mark `3.2 skipped` when it had no assignment work, or `3.2 failed` with the
ledger error.

