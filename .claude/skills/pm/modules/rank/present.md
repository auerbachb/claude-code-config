<!-- pm-routing:begin -->
Route `rank:present`. Present the ranked work and run the existing cleanup, triage and dispatch decisions. Return through the existing ranking-only exit when it applies.
Once the complete ranking result is emitted, use rank:fetch's watermark
publication block if this same attempt has a verified pending receipt.
Do this before an applicable ranking-only return. An early health-only
exit or incomplete ranking leaves the receipt unpublished.
<!-- pm-routing:end -->
### 1B.5: Present recommendations

**First, run Step 1C (Backlog & workspace cleanup, below) — the full inline `/pm-clean` flow — ahead of everything else in this step, with its confirm gates resolved (acted on or declined) before any ranking output** (unless `--no-clean` / `fast` was passed, which prints only the ranking-only health line and skips the gates). Then, when `$GH_USER` is set, lead the output with user-scoped sections before the general backlog ranking. These always take precedence over backlog pickup — they represent work already on the user's plate. **Immediately after `## Your Open PRs`, run Step 1D (Forgotten-PR triage, below) and print its `## Forgotten PRs` block** — like Step 1C it is always-on and informational, and it renders before `## Suggested Next Issues`. If `$GH_USER` is unset so no `## Your Open PRs` section renders, the block still appears — `forgotten-pr-triage.sh` defaults to `@me` — placed after whatever user-scoped sections did render (or on its own if none), still before `## Suggested Next Issues`.

See `.claude/reference/pm-output-templates.md` §User-Scoped Sections for the block format (Your Open PRs, Forgotten PRs, PRs Awaiting Your Review, Issues Assigned to You).

Then display a short list of the top 3–5 backlog issues (unassigned / up for pickup) — see `.claude/reference/pm-output-templates.md` §Suggested Next Issues for the block format.

**Operator order first (1B.4 item 7).** Every eligible override row leads, marked `Operator order (desk) #k`, before filling the remaining display rows from the ranking. The context line carries `PRIORITY_STATUS` (1B.1a); a `Parked (desk):` line names each parked issue with its return date, and a `Not eligible (desk):` line names each ordered issue that was excluded, with its reason. The full ranking below opens with an `## Operator order (desk)` section above the tiers. Formats: `pm-output-templates.md`.

**Full ranking (on request only).** When the user asked to rank the backlog rather than "what's next" — "rank the backlog", "priority list", "full ranking" — replace the top 3-5 list with the tiered view. "Full" means **every tier is covered**, not that every issue is listed: name the issues that earn a decision in each tier and summarize the rest. Omit any tier with no issues. See `.claude/reference/pm-output-templates.md` §Full Ranking / Tiered View for the block format.

Summarize rather than enumerate once a tier stops informing a decision — most often the Low tier: "68 additional issues are Low-priority relative to this goal". The tier still appears with its heading; it just carries a count instead of 68 bullets.

<!-- pm-routing:begin -->
Resolve `shared:ownership` when the initial selection reaches its read-only ownership sweep. Reuse that procedure for the required launch recheck.
<!-- pm-routing:end -->
**Select the initial batch and standing queue from the same ranking.** After
the pause and scope checks below, walk the retained ranking in operator-first order (1B.4c). Apply the
existing 3.1 inline criteria, dependency, park and scope filters, then run the
1B.5 read-only ownership sweep until twice `LIMIT` candidates clear or the
ranking is exhausted.
Build `PM_INLINE_RANKED` as a JSON array of their issue-number strings, best
first. Preserve the prompt/decomposition paths for candidates encountered
before the batch fills. The standing picks are a plan only. They do not enter
the `/subagent` launch set or acquire claims.

<!-- test-anchor: pm-standing-queue-initial -->
```bash
PM_QUEUE_SELECTION=$(jq -ce --argjson limit "$LIMIT" '
  if type != "array" or any(.[]; (type == "string" and test("^[1-9][0-9]*$")) | not) then
    error("invalid inline ranking")
  else
    reduce .[] as $issue ([]; if index($issue) == null then . + [$issue] else . end)
    | .[:($limit * 2)]
    | {batch: .[:$limit], ranked: .}
  end' <<<"$PM_INLINE_RANKED") || exit 1
```

Put the first `LIMIT` inline-eligible issues in `BATCH_ISSUES` from `.batch`
for ordinary and windowed runs. Window and launch checks decide what starts.
Carry the bounded ranked pool through the dispatch evaluation.

<!-- pm-routing:begin -->
When `WINDOW_STR` is set and Step 0b parsed it successfully, read `shared:window-fit` and apply the existing batch fit.
<!-- pm-routing:end -->
<!-- pm-routing:begin -->
At this gate, read `shared:ownership` and apply its existing instructions.
<!-- pm-routing:end -->
**Dispatch the selected batch by default.** Hand the surviving `BATCH_ISSUES` to **Step 3.1** for immediate inline dispatch, with the standing plan kept outside the dispatch set. Keep window exclusions and ownership skips out of the launch set. Step 3.1 claims the launch picks and runs them through the `/subagent` A→B→C flow up to the **`LIMIT` concurrent-pipeline** limit (Step 0 — `min(CEILING, ACTIVE_WORK_CAP)`). Do not ask "should I start these?" — free capacity is a trigger, not a question (`CLAUDE.md` "KEEP THE PIPELINE FULL"), and the launches are **reported, never proposed**, exactly as 3.4 reports a refill. Step 3.1 owns the mechanics — issue claims (`/subagent` 6.0), overlap chains (6.0b), the ceiling and the inline queue (Step 7) — and this step restates none of them. **Prompts and chips are the exception, not the act:** an issue produces one only when it carries a named `/subagent` Step 4 disqualifier (quoted in the offer) or the user explicitly asks for prompts — see 3.1.

**This read gates the batch; it does not replace the per-launch check.** Ranking, Step 1C's confirm gates, and Step 1D's triage can span several turns, so the pause is re-read immediately before each launch by the gate that already owns that — `/subagent` Step 7's pre-launch check, the same one 3.4's refill relies on. A stop the user says while those steps are still running cancels the remaining launches, and a candidate outside a scope set in that window is skipped at dispatch time. Delegate to it; do not add a second pause mechanism here.

After the dispatch evaluation, build `PM_QUEUE_REMOVED` from verified launches,
adoptions, accepted claimed successors and definitive rejections in this
turn. Use `[]` when none occurred. Keep window-trimmed and other deferred
picks in their original rank order, subject to the existing refill checks.
A ranking-only run, pause or launch horizon hold preserves the previous plan.
On the publishing path, compute the prospective picks from the retained
ranking and save them with Step 3.4's queue publication block.

<!-- test-anchor: pm-standing-queue-initial-plan -->
```bash
if ! PM_QUEUE_NEXT=$(jq -ce --argjson removed "${PM_QUEUE_REMOVED:-null}" --argjson limit "$LIMIT" '
  if ($removed | type) != "array" or
     any($removed[]; (type == "string" and test("^[1-9][0-9]*$")) | not) then
    error("invalid initial dispatch outcomes")
  else (.ranked - $removed)[:$limit] end' <<<"$PM_QUEUE_SELECTION"); then
  PM_QUEUE_NEXT=''
  printf '%s\n' 'DEGRADED: initial standing queue outcomes unavailable; previous plan retained' >&2
fi
```

State, **when the read cleared**: "Starting the top {N} inline — #{a}, #{b}, #{c}; {M} queued. Say 'adjust' to change the selection, or 'give me prompts instead' for prompt blocks rather than inline runs." Record each launch through 3.1 and the Active Work table (3.2). Apply the decision-only policy to the human-facing output and use 3.3a when a report is requested or due. **When it did not clear** — paused, or unreadable and therefore read as paused — emit the ranking-only message instead: the ranking, the pause, and how to lift it. Never announce launches that did not happen.


Mark `1B ran` once ranking and its dispatch decision are complete. A ranking-only
decision records `3.1 skipped` with the actual hold reason. If ranking ends
early with a failure, mark `1B failed` with the reason and finish the invocation.

Then proceed to **Step 2: Active Monitoring Setup**.

