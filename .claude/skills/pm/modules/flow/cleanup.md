<!-- pm-routing:begin -->
Resolve the existing cleanup gates when a resume or ranking presentation reaches Step 1C.
<!-- pm-routing:end -->

Runs on **every** `/pm` invocation — both the resume path (1A.4) and the cold-start path (1B.5) call this before printing any ranking/orchestration output, so cleanup is reviewed and acted on (or declined) *before* the ranking appears. This step never scores or ranks: it runs after state load/scoring, must complete before the ranking presentation, and must not alter 1B.3 candidate narrowing, 1B.4 scoring, or the 1B.4b judgment-check contract.

**Unless `NO_CLEAN=true`** (the `--no-clean` / `fast` escape hatch parsed in the preamble — see "Escape hatch" below), **execute the complete `.claude/skills/pm-clean/SKILL.md` workflow inline** — its Step 0 (argument parse) through Step 4 (confirm-and-act), using default thresholds (no `[days]` argument → 30-day issue inactivity and 30-day workspace age). This is the same "invoke the full SKILL.md workflow inline, no shortcuts" idiom `/babysit-pr` uses for `/wrap` and `/fixpr`: **do not shortcut, and do not duplicate `/pm-clean`'s logic here.** `/pm-clean` stays the single source of the cleanup flow, so its gates, tables, and detection can never drift from a re-implementation in `/pm`.

Running the full flow means both of `/pm-clean`'s scans and both of its independent confirm gates run inline:

- **Issue-staleness scan** — `backlog-staleness.sh` (`/pm-clean` Step 1), presented then gated by its **Step 4.1 close gate** before any `gh issue close`.
- **Workspace sweep** — `stale-cleanup.sh --check` (`/pm-clean` Step 2), then `--apply` only after its **Step 4.2 delete gate**.

The two scans are independent — one finding nothing never suppresses the other — and each keeps its **own** confirmation. For age/staleness cleanup, `/pm` still **never auto-closes an issue or auto-deletes an old workspace**: each action waits on `/pm-clean`'s explicit confirmation gates. [Verified completion reconciliation](../../../../reference/issue-completion.md) is separate: an individually verified finished issue may close after merge; partial/parent/ambiguous scope stays open. The finished-only workspace exception is defined by its own cadence contract.

**No double-scan.** Because only `/pm-clean`'s single pass runs, `backlog-staleness.sh` and `stale-cleanup.sh` each execute **exactly once** per `/pm` invocation. `/pm` no longer calls `backlog-health.sh` on this default path — the count-only "Backlog health" summary it used to print (issue #598) is now subsumed by `/pm-clean`'s fuller, actionable report.

**Clean repo → no friction.** When both scans come back clean, `/pm-clean` emits its one-line status — `Backlog is clean · No stale worktrees or branches.` — with no confirm prompts, and `/pm` proceeds straight into ranking.

Once the cleanup is done (gates acted on or declined, or the clean-status line printed), return here and continue with the rest of the calling step (1A.4 or 1B.5), then Step 2.

**Reconcile the cleanup's effect before ranking.** If the inline cleanup closed any issues, remove those now-closed issues from the candidate set, the assignments table, and the ranking before the calling step (1A.4 / 1B.5) presents them — `/pm` must never suggest or list an issue the user just closed. This is a filter on the already-computed results, not a re-score, so the non-scoring contract above still holds (the dependency map and tiers are not recomputed). On the cold-start path, when a closed issue was in the order 1B.4c already persisted, drop it from `FINAL_ORDER` and run the 1B.4c block again, so the ranks the desk reads match the order 1B.5 shows (each later issue moves up one place per closed issue above it). Workspace deletions do not affect the issue ranking and need no reconciliation.


Mark `1C ran` when the cleanup gates are resolved or both scans are clear.
Mark a scan or cleanup error `1C failed` with its reason. Wait for any pending
confirmation before recording a completed cleanup.

### Escape hatch: `--no-clean` / `fast`

When `NO_CLEAN=true`, mark `1C skipped (--no-clean)` and **skip the inline `/pm-clean` flow entirely** — none of its cleanup scans or confirm gates run, so there is no friction. For a lightweight, non-interactive health signal, still print the count-only Backlog-health line from the shared aggregator (`backlog-health.sh`, which wraps the same detector without any interactive gate), then proceed directly to ranking:

```bash
"$BACKLOG_HEALTH" --json
```

This wraps the same `backlog-staleness.sh` detection (issue #598); see `"$BACKLOG_HEALTH" --help` for the full field reference. Render a compact bullet block — a heading plus short one-line stats, not a table:

```
## Backlog health (ranking-only run — cleanup skipped)

- **{total_open} open issues** — {opened_last_N_days} opened in the last 30 days, {older_than_N_days} older
- **{candidate_count} defer/close candidates** among the older issues — run `/pm-clean` (or `/pm` without `--no-clean`) to review and act on them
- **{actionable_backlog} actionable issues** — {closed_last_recent_days} closed in the past 7 days
- **Estimated time to clear:** {estimate.value} {estimate.unit}
```

When `estimate_message` is set instead of `estimate` (the 30-day closure rate is zero), replace the last line with:

```
- **Estimated time to clear:** cadence too low to estimate
```

If `candidate_count` is 0, drop the "defer/close candidates" line rather than showing a zero. This fallback stays purely informational — it never enumerates the flagged issues and never prompts for action; the full interactive cleanup is the default (no flag).

