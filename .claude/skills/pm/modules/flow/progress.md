<!-- pm-routing:begin -->
Check progress on a requested or due observation.
<!-- pm-routing:end -->

When the user asks "status", "what's next", or "update" — or periodically when it makes sense:

```bash
# Check for new/merged PRs (ALL authors — progress/dedup detection only, not a
# ceiling count; author-scoped counts/offers use the user-scoped re-check below)
gh pr list --state open --json number,title,headRefName,body
gh pr list --state merged --limit 10 --json number,title,mergedAt,body

# Check for closed issues
gh issue list --state closed --limit 20 --json number,title,closedAt

# User-scoped re-check (only if $GH_USER is set from Step 0a)
if [ -n "$GH_USER" ]; then
  gh pr list --state open --search "author:$GH_USER" --json number,title,updatedAt
  gh pr list --state open --search "review-requested:$GH_USER" --json number,title,author,updatedAt
fi
```

When answering "what's next", always check the user-scoped results first (your open PRs with unresolved findings, then review requests against you) before suggesting new backlog pickup.

A mid-session "re-prioritize" or "rank the backlog" request runs the same ranking as a cold start — re-read the operator priority (1B.1a), re-score through 1B.4 (its operator-order overlay included), and apply the 1B.4b judgment check before presenting, then persist the new order (1B.4c).

Cross-reference with the assignments table:
- Detect PRs that reference tracked issues (search PR body for `Closes #N`, `Fixes #N`)
- Record PR state separately from issue completion. For merged tracked work, run [completion reconciliation](../../../../reference/issue-completion.md); accept verified CLOSED issues, a verified no-issue delivery, or an explicitly justified retained disposition. Pending closure remains retryable and does not relaunch code.
- Flag stale threads: if an issue was assigned > 30 minutes ago with no PR, note it
- **Dismiss stale chips:** any issue sitting at `Chip offered` that now has an open PR is being worked already — withdraw its chip via `dismiss_task` (see `.claude/reference/chip-launching.md`). Reuse the open-PR result already fetched above and the same closing-keyword predicate — no extra API call. Only clear the tracked `task_id` after the dismiss succeeds.

Also accept user input: "thread for #42 is done", "PR #88 merged", "#55 is blocked".

<!-- pm-routing:begin -->
Use the progress module's board section at its explicit or due gate.
The normal /board path uses its own Step 5 freshness record. Only the
inline fallback uses the local record below. Before each fallback render,
clear any count or drain evidence carried from an earlier render.

<!-- test-anchor: pm-fallback-board-reset -->
```bash
unset ACTIVE_COUNT PM_FALLBACK_PROVEN_COUNT PM_FALLBACK_DRAINED
```

After a table reaches the user, set `PM_FALLBACK_PROVEN_COUNT` to the sum of
confirmed running and queued rows from this render. Set `PM_FALLBACK_DRAINED`
to `true` only when the round is independently known to be drained. If the
only rows are unconfirmed, leave the previous freshness record in place and
report that liveness is unknown. Run this block before the fallback recorder.

<!-- test-anchor: pm-fallback-board-count -->
```bash
unset ACTIVE_COUNT
if [[ "${PM_FALLBACK_PROVEN_COUNT:-}" =~ ^[1-9][0-9]{0,8}$ ]]; then
  ACTIVE_COUNT=$PM_FALLBACK_PROVEN_COUNT
elif [[ "${PM_FALLBACK_PROVEN_COUNT:-}" == 0 && "${PM_FALLBACK_DRAINED:-false}" == true ]]; then
  ACTIVE_COUNT=0
fi
```
<!-- pm-routing:end -->

**When a progress render is requested or due, use the canonical "Running now" table** — the column set and cell semantics in `.claude/reference/time-estimates.md` §"Running now Table", covering the whole round in execution order with queued rows carrying `—` in all three clock columns. Never a bulleted list, never a per-pipeline prose readout, and never a second table shape of `/pm`'s own.

**Render it by running `/board`** — execute the complete `.claude/skills/board/SKILL.md` workflow inline, the same "run the full SKILL.md, no shortcuts" idiom Steps 1C and 2D.4 use for `/pm-clean` and `/pm-handoff`. `/board` is the canonical renderer of this table (#1581); re-implementing its Est lookup, clock cells, start resolution or freshness record here would be a second copy free to drift from the first. If `/board` does not resolve, print `DEGRADED: /board not available — rendering the "Running now" table inline per time-estimates.md §"Running now Table"`, render it from that spec directly, and **record it yourself** — `/board` Step 5 is not there to do it, and an unrecorded render leaves the floor firing against a board the user is looking at. Resolve the pair here rather than assuming a caller left them set, and skip the call rather than passing a blank flag: an empty `--repo`/`--session` is a usage error that costs the record, and an unresolved helper would run a bare `--note-rendered`.

```bash
REPO_KEY=$("$SESSION_STATE_SH" --repo-key 2>/dev/null) || REPO_KEY=""
[[ "$REPO_KEY" == "_unknown" ]] && REPO_KEY=""   # never empty; normalise the sentinel
TF_SESSION="${CLAUDE_SESSION_ID:-default}"
# ACTIVE_COUNT = pipelines running OR queued right now, counted from the table
# just printed. Gate on a table having ACTUALLY been emitted: stamping the clock
# without one restarts the hour and hides a board that has already gone stale.
# TABLE_RENDERED carries that fact explicitly. Set it to 1 ONLY on the path where
# a table actually reached the user — whether /board printed it or the DEGRADED
# inline fallback did — and re-initialise it to 0 here every time, plainly, never
# as a `${TABLE_RENDERED:-0}` default: a 1 left over from an earlier render is
# exactly how the clock gets stamped for a board this pass never printed.
# A render that FAILED — /board did not resolve AND the inline fallback did not
# print either — leaves the flag at 0 and falls through to the DEGRADED
# else-branch below, which is the correct outcome: no table, no clock stamp.
# So the assignment is never a straight-line statement after the render. An
# unconditional 1 makes the guard vacuous on exactly the failure it was added to
# catch, the same way a carried-over 1 does.
TABLE_RENDERED=0
# … render the table (via /board, or the inline fallback above) …
# … then, on the success path ONLY — a table was emitted:
TABLE_RENDERED=1
if [[ -n "$TABLE_FRESHNESS_SH" && -n "$REPO_KEY" && "$TABLE_RENDERED" -eq 1 \
      && "${ACTIVE_COUNT:-}" =~ ^[0-9]+$ ]]; then
  "$TABLE_FRESHNESS_SH" --note-rendered --active "$ACTIVE_COUNT" \
    --repo "$REPO_KEY" --session "$TF_SESSION" --surface pm-board \
    || echo 'DEGRADED: table-freshness clock not recorded — the floor may fire again shortly'
else
  echo 'DEGRADED: this render is not recorded against the table-freshness floor'
fi
```

Render only for an explicit status request or a scheduled report when due. Keep the complete machine-readable launch and queue records at every dispatch.

**`/pm` is the dispatching thread, so the board renders complete.** `/board` Step 3 draws queued rows from the dispatching thread's own queue and confirms a pre-PR row from a live agent handle — both of which `/pm` holds (3.1's queued-behind-the-ceiling list, and the handles for pipelines `/subagent` launched for this round). Supply them: a board rendered from `/pm` carries its queued rows, shows no `Phase A (unconfirmed)` row for a pipeline it is holding, and qualifies neither its running nor its delivered count. Those qualifications exist for threads that did *not* dispatch the round; adopting them here would understate a round `/pm` can account for exactly.

**Rendering is read-only.** `/board`'s only write is the shared table-render timestamp, which is not a change to any pipeline: it never dispatches, merges, or moves a phase. Looking at the board is never a substitute for D2 / 3.4 refill, and never advances one.

**Start is read back, never re-derived.** `/board` Step 2 owns the order — `.prs["<pr>"].pipeline_started_at`, then `.repos["<key>"].pipelines["<issue>"].started_at`, then `gh pr view <pr> --json createdAt` as a last resort for pipelines that predate the record. `/pm` only ever **reads** that timestamp; the write happens once in `/subagent` Step 7.1, reached transitively through 3.1's inline dispatch. So a pipeline's Start is constant across every tick and every rebuild after a compaction — only Status, Projected end and Remaining recompute. A Start that moves between two renders is a bug, not a refresh.

**When to render:**

| Trigger | Render |
|---------|--------|
| Dispatch or refill | Preserve the complete launch and queue records. Render when an explicit request or a scheduled report calls for it. |
| Existing day or PM-owned inline monitor tick | Evaluate the scheduled report gate below |
| A progress question — "how far along?", "where is everything?", "status" | This table, recomputed, whatever the count: one shape whether one pipeline is running or five |
| Observed `merged` or `blocked` outcome in this PM run | Evaluate the scheduled report gate immediately, even when the round just drained |

**The Active Work table (3.2) is a different table and neither replaces the other.** Active Work is the **assignment ledger**: every issue `/pm` is responsible for, including rows that are not pipelines at all — `Chip offered` and `Prompt generated` (awaiting a click or a paste), `Active` (a separate thread's work), `Tracking` parents, `Deferred (cap)` — each keyed by thread and, where one exists, by `task_id`. The canonical Status vocabulary is `queued` / `Phase A|B|C` / `merged`, which has no cell for "awaiting a click" and no column for a chip handle, so the ledger cannot be folded into it. "Running now" is the **round's progress view**: pipelines only, with clocks. Keep both, and keep the boundary — one answers *who is doing what*, the other *when will it land*.

**Scheduled reports.** By default, `/pm` reports a changed board every
30 minutes. Read `report_every_min` in `## Reporting` through
`PM_CONFIG_GET`. Zero opts out, and a positive value sets a different
interval. Follow
[PM progress report](../../../../reference/pm-output-templates.md#pm-progress-report)
for the script gate, delivery receipt and exact groups. Evaluate it on D5,
on the existing PM-owned inline monitor tick after processing outcomes and
refills, and when a verified terminal outcome reaches the PM parent outside
those ticks. Evaluate once per turn after consolidating its outcomes. Keep the
gate and delivery in this PM thread. Do not arm a reporting-only monitor or
invoke a separate model to check for changes.

**Project page.** Refresh the same current-repo page on a verified dispatch,
each observed merged or blocked outcome, and every due report, including
D5 and the PM-owned inline monitor. Follow the
[persistent project board](../../../../reference/pm-output-templates.md#persistent-project-board)
projection and publication steps. Gather the turn's evidence before the
single publish, even when chat reporting is disabled. Add the verified
page link to each scheduled report.

