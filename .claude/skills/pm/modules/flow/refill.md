<!-- pm-routing:begin -->
Evaluate available capacity using the existing persisted pause, scope, and admission gates.
Before promoting a pick, check the current persisted window through
shared:window-fit even on a tick with no window flag.
<!-- pm-routing:end -->

**The trigger is available capacity, not a finish.** On every monitor tick (`monitor-mode.md` per-cycle checklist), count your own running pipelines. Any time that count is below the effective limit (`LIMIT`, Step 0) — a slot that just freed **or one that was never filled**, because the first batch was small or earlier picks got filtered out — refill on that tick, with no completion event and no user message in between. Sitting at 1-of-{LIMIT} with an empty queue is a defect, not a resting state. This is the scoped default granted by `CLAUDE.md` "KEEP THE PIPELINE FULL"; only a live in-chat stop pauses it (Execution Boundary).

**Check the persisted pause first — before either source.** A stop is not a fact about this turn, it is a fact about the thread, so it lives in `session-state.json` and outlives context turnover:

```bash
REPO_KEY=$("$SESSION_STATE_SH" --repo-key)
RC=0
SCOPE_RC=0
PAUSED=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].refill.paused") || RC=$?
SCOPE=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].refill.scope" 2>/dev/null) || SCOPE_RC=$?
```

Read the exit code of **both** reads, not just the values — **an unreadable pause is a pause, and so is an unreadable scope**. Apply the table to `RC` and to `SCOPE_RC` alike:

| `RC` | Value | Refill? |
|------|-------|---------|
| 0 | `true` | **No** — full stop. Report `paused`. |
| 0 | `false` / `null` | Yes — the default (the field only exists once someone paused) |
| 3 | — | Yes — no state file has ever been written, so nothing was ever paused |
| 4, 6, other | — | **No** — the state is unreadable (parse error, lock timeout). Report `paused (state unreadable)` and say so; never treat "we failed to look" as "not paused" |

A failed `refill.scope` read (`SCOPE_RC` of 4, 6, or anything else non-zero but 3) leaves `$SCOPE` empty, which is indistinguishable from "no scope was ever set" — the **permissive** reading. Treat it as paused for the same reason: a narrowing you failed to read is a narrowing you would otherwise launch straight through.

**In day mode, `.repos[<key>].day.refill_halted` is a second, independent gate** (set in Step 2D.3's D1) — read it with the same exit-code table, and refill only when **both** it and `refill.paused` are clear. The two are deliberately separate fields: `refill` is contractually human-written-only, so day mode's automatic failure-streak halt gets its own field rather than forging a human stop. Its idle reason is `paused (pipeline failures)`, distinct from a human `paused`, so the user can tell which one is holding the board.

**The credit budget is a third, independent gate — autonomous dispatch only.** Run `credit-budget.sh --check` (resolved per the RESOLVE ladder, not bare). Apply the same exit-code discipline — unreadable is not permission:

| Exit | Status | Dispatch? |
|------|--------|-----------|
| 0 | `ok` | Yes — proceed normally |
| 1 | `reached` | **No** — land near-done work; halt new launches for the rest of this ET day; surface one line: `Budget reached ($N/day) — halting new launches for today. Run credit-budget.sh --reset to override.` Dispatch resumes on the next ET day because `credit-budget.sh --check` returns `ok` when no overage event is found that day; no separate `park_until` state is needed. |
| 2 | `unknown` | **No** — conservative posture: finish in-flight pipelines, start nothing new; one-line surface: `Budget state unknown — starting nothing new until probe succeeds.` |
| other | error | **No** — treat as `unknown`; never treat an error as `ok`. This applies at every autonomous dispatch point, not only in day mode. |

**This gate binds autonomous dispatch only** — day mode and refill. An explicit user request in chat always proceeds regardless of budget state; prepend a one-line note: `[budget spent/unknown today] Proceeding at your request.` Do not block, downgrade, or ask permission for an in-chat request.

**The armed-deadline gate is `/subagent` Step 7's, including its questions (issue #1679).** Step 7
owns the leave-time elicitation before a thread's first new-pipeline launch and the attended overrun
menu; this step delegates to it and adds no second elicitation, no second deadline field, and no
second decline check. **Neither question ever fires from `/pm day` or `/pm --window`**: a day-mode
tick is unattended by construction, and `--window` already armed `.window` in Step 0b, so Step 7's
"already armed" branch skips it.

**Do not add a second budget pause mechanism.** `credit-budget.sh` is the single evaluation point. Re-read it per pick (same pattern as the refill.paused re-read), not once per tick. A budget state change between the tick read and the per-pick read cancels remaining launches for that tick.

**A non-null `$SCOPE` constrains every refill source** — it is a narrowing, not a stop, and it is worthless if it is only recorded. Every candidate, operator-ordered, queued, or from the backlog, must fall inside it; one that doesn't is skipped exactly like a failed re-validation, and if that empties the candidate set the reason is `nothing eligible (scope: <scope>)`. Reading `refill.scope` and then ranking the whole backlog would auto-launch precisely the work the user just excluded.

Write it **only** when a human says stop in chat, and clear it **only** on an explicit human resume — never on an unrelated later message:

```bash
NOW=$(date -u +%FT%TZ)
# Full stop. `reason` is a bounded enum (full_stop | scope_narrowed) — never the
# user's raw words: nothing the user typed is interpolated into this command.
"$SESSION_STATE_SH" \
  --set ".repos[\"$REPO_KEY\"].refill={\"paused\":true,\"reason\":\"full_stop\",\"scope\":null,\"at\":\"$NOW\"}"

# Narrowed scope ("only the auth issues") — NOT a stop: refill stays on and draws
# only from that subset. `scope` is the one field that can carry user text, so
# encode it with `jq --arg`; never interpolate it into the --set string.
SCOPE_JSON=$(jq -cn --arg s "<label>" --arg at "$NOW" \
  '{paused:false, reason:"scope_narrowed", scope:$s, at:$at}')
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].refill=$SCOPE_JSON"
```

`paused: true` is a full stop and nothing else; a narrowed scope is `paused: false` with a non-null `scope`, which still refills — inside that scope only. Schema: `.claude/reference/session-state-schema.json`.

**Counting is author-scoped** (issue #733, `subagent-orchestration.md`): only pipelines you launched and PRs you authored occupy slots. A collaborator's open PR is context — never a slot, and never a reason to hold a launch.

**A slot frees only on a terminal `OUTCOME` — `merged` or `blocked`.** A pipeline parked at `merge_ready` still has Phase C ahead, so it keeps its slot until it actually merges. When every slot is held at `merge_ready` or in Phase C, wait for a terminal outcome before starting anything.

**Re-read the operator priority on every refill** (1B.1a, issue #1767) — once at the top of the tick, so a `/desk` edit takes effect on the next tick without restarting `/pm`. `PRIORITY_UNREADABLE=true` holds every autonomous launch this tick, idle reason `paused (priority unreadable)`; it clears by itself once the file reads cleanly.

Refill in this order:

**(o) Operator order — first.** Re-run 1B.4 item 7 over the latest ranking with this tick's read and take its `override` rows, in the operator's order. An ordered issue that ranking never saw (bumped since it ran) first joins the candidate set as a first-seen issue — full read, scored, excluded or not — exactly as step 2 of "When one or more pipelines or threads finish" below treats one. An issue that is also queued is taken once, here, at its override position, and leaves the queue. When `$SCOPE` is non-null, take only the override rows inside it, still in the operator's order; an out-of-scope ordered issue is deferred, not dropped — it stays in the override for a later, wider refill, the way an out-of-scope queued issue stays queued. **Parked issues are deferred in every source:** a parked queued issue stays queued and is skipped until its date, the way an out-of-scope queued issue is; a parked backlog issue is not a candidate.

**(a) Queue refill — before the backlog.** Start the next eligible successor
in the existing `/subagent` queue, then walk this dispatcher's unclaimed
standing plan in rank order. Apply the same immediate revalidation below.
Consume an issue only on verified launch, adoption or acceptance into the
existing claimed successor queue. Evict definitive rejections, such as a
closed issue or an existing PR. Keep out-of-scope, parked and deadline-deferred
picks, and keep picks whose validation or launch evidence is unreadable.
Deduplicate the operator overlay and both queues on the issue number.

Read the saved plan once before the first pick, including before the initial
selection or an explicit re-plan. Use the same actual dispatcher identity as the round record
(`CLAUDE_SESSION_ID`) and the
verified `REPO_KEY`. Carry the exact record across shell calls for this
evaluation. Another session's plan is display evidence only. Set
`PM_QUEUE_RUNNING_ISSUES` to the issue-number strings for this dispatcher's
verified live pipelines, including launches that have yet to open a PR.
Use the current Active Work evidence and pass `[]` for a verified empty
set. Exclude those IDs before picking or counting queue depth, even if
an earlier launch succeeded while publication failed. Recheck the same
live-pipeline condition immediately before each launch and add a pick
that is already running to `PM_QUEUE_REMOVED`. If the running evidence
is unavailable, preserve the plan and use only fallback sources whose
existing capacity and live-work checks pass.

<!-- test-anchor: pm-standing-queue-read -->
```bash
PM_QUEUE_SESSION="${CLAUDE_SESSION_ID:-}"
PM_QUEUE_STATE=''
if [[ -n "${PM_STANDING_QUEUE_SH:-}" ]]; then
  if ! PM_QUEUE_STATE=$("$PM_STANDING_QUEUE_SH" read "$REPO_KEY" "$PM_QUEUE_SESSION" 2>/dev/null); then
    PM_QUEUE_STATE=''
    printf '%s\n' 'DEGRADED: standing queue unavailable; using the existing refill sources' >&2
  fi
fi
PM_QUEUE_PICKS='[]'
if [[ -n "$PM_QUEUE_STATE" ]]; then
  if ! PM_QUEUE_PICKS=$(jq -ce --argjson running "${PM_QUEUE_RUNNING_ISSUES:-null}" '
    if ($running | type) != "array" or
       any($running[]; (type == "string" and test("^[1-9][0-9]*$")) | not) then
      error("invalid running issue evidence")
    else (.issues // []) - $running end' <<<"$PM_QUEUE_STATE"); then
    PM_QUEUE_PICKS='[]'
    PM_QUEUE_STATE=''
    printf '%s\n' 'DEGRADED: running issue evidence unavailable; standing queue preserved' >&2
  fi
fi
```

**(b) Backlog top-up — after queue dispatch.** Pass the issue numbers consumed
or definitively evicted across all sources as `PM_QUEUE_REMOVED` (a JSON array
of strings). Count actual remaining capacity after the queue attempt in
`PM_QUEUE_VACANCIES` (the smaller of free thread slots and verified repo-wide
`FREE`). Run this block only after the refill gates have cleared and the
queue sources have had their turn. It requests a scan below half of `LIMIT`.
If eligible queue picks ran out while a slot remains, use the existing backlog
fallback even when deferred picks still occupy the plan.

<!-- test-anchor: pm-standing-queue-refill -->
```bash
PM_QUEUE_REMAINING=$(jq -ce --argjson removed "$PM_QUEUE_REMOVED" --argjson limit "$LIMIT" \
  '(. - $removed)[:$limit]' <<<"$PM_QUEUE_PICKS") || exit 1
PM_QUEUE_DEPTH=$(jq -r 'length' <<<"$PM_QUEUE_REMAINING") || exit 1
PM_QUEUE_TOP_UP=false
if (( LIMIT > 0 )); then
  if (( PM_QUEUE_VACANCIES > 0 )) || { [[ -n "$PM_QUEUE_STATE" ]] && (( 2 * PM_QUEUE_DEPTH < LIMIT )); }; then
    PM_QUEUE_TOP_UP=true
  fi
fi
```

Only on `PM_QUEUE_TOP_UP=true`, run the incremental re-scan and total re-score
in the finish housekeeping below. Reuse 1B.2's `pm-1b2-new-issues` block and
retain the `New since the last scan: #N (Tier)` line when it finds new issues.
Apply scope before ranking and all existing gates per pick. Fill verified
remaining vacancies through 3.1 before extending the plan. Set
`PM_QUEUE_ADDITIONS` to the remaining ranked, inline-eligible issue numbers,
excluding running work, accepted successors and definitive rejections. Use
an empty array when no scan ran. Carry over deferred picks in their saved
order and append at most enough new picks to restore `LIMIT`.

<!-- test-anchor: pm-standing-queue-top-up -->
```bash
PM_QUEUE_NEXT=$(jq -ce --argjson additions "$PM_QUEUE_ADDITIONS" --argjson limit "$LIMIT" '
  reduce $additions[] as $issue (.;
    if index($issue) == null then . + [$issue] else . end)
  | .[:$limit]' <<<"$PM_QUEUE_REMAINING") || exit 1
```

**Publish the verified plan.** Use `PM_QUEUE_NEXT` from the initial dispatch
or the top-up block. Skip publication if the plan or its prior record could
not be read or computed. A stale write
does not undo a launch or acquire a claim. Surface the failure and re-read
at the next evaluation rather than overwriting the winning plan. On a
verified empty backlog, use `[]` to retire this dispatcher's own plan. Preserve
plans across pauses and during recovery.

<!-- test-anchor: pm-standing-queue-publish -->
```bash
if [[ -n "$PM_QUEUE_STATE" && -n "${PM_QUEUE_NEXT:-}" ]]; then
  if PM_QUEUE_SAVED=$(jq -cn --argjson expect "$PM_QUEUE_STATE" --argjson issues "$PM_QUEUE_NEXT" \
      '{expect:$expect,issues:$issues}' | \
      "$PM_STANDING_QUEUE_SH" save "$REPO_KEY" "$PM_QUEUE_SESSION" "$LIMIT" 2>/dev/null); then
    PM_QUEUE_STATE="$PM_QUEUE_SAVED"
  else
    printf '%s\n' 'DEGRADED: standing queue was not updated; re-read it on the next evaluation' >&2
  fi
fi
```

Count the deduplicated claimed successors plus the persisted standing plan
for the board, report, day digest and slot census. Keep the existing
`active-work-cap.sh` inputs. An unclaimed plan carries neither an active slot
nor a launch record.

**Re-validate every pick, from any source, immediately before launching it** — the quick current-state + too-big check from 3.1 / `/subagent` Steps 4–5, **plus the 1B.5 ownership sweep** (`candidate-ownership.sh`, issue #1431). Closed, already has its own PR, now too big, or `action: skip` → skip it and take the next candidate (a failing queued pick leaves the queue; a failing backlog pick is passed over). `action: adopt` launches from the surviving state instead of a fresh start. Backlog refill reuses this validation rather than defining its own.

**Recheck the active window for refill picks.** When 3.4 would promote a queued or newly ranked issue under an active window, run 1B.5's estimate and `makespan.sh` fit check for the candidate against the current deadline and stall margin. Skip a pick that does not fit or cannot be measured. Keep the existing Step 7 prelaunch check. Before handing a fitting issue to 3.1, append it to the same window's `batch_issues` so Step 8 monitors its overrun. Persist only after the existing ownership and eligibility checks. If the guarded write fails, leave the issue queued and recheck the current window before retrying.

The following block runs only after a fit under `DEADLINE_EPOCH`, with the numeric `ISSUE_NUM` and the verified `REPO_KEY` from the current run:

<!-- test-anchor: pm-refill-window-batch -->
```bash
WINDOW_BATCH_PATH=".repos[\"$REPO_KEY\"].window.batch_issues"
WINDOW_DEADLINE_PATH=".repos[\"$REPO_KEY\"].window.deadline_epoch"
WINDOW_BATCH_BEFORE=$("$SESSION_STATE_SH" --get-json "$WINDOW_BATCH_PATH") || exit 1
WINDOW_BATCH_AFTER=$(jq -ce --arg issue "$ISSUE_NUM" '
  if . == null then [] else . end
  | if type != "array" then error("window batch invalid")
  elif index($issue) != null then .
  else . + [$issue] end
' <<< "$WINDOW_BATCH_BEFORE") || exit 1
"$SESSION_STATE_SH" --cas "$WINDOW_BATCH_PATH=$WINDOW_BATCH_AFTER" \
  --expect "$WINDOW_BATCH_BEFORE" --expect-at "$WINDOW_DEADLINE_PATH" "$DEADLINE_EPOCH"
```

**Read ownership per pick, not once per tick** — the same discipline as the per-pick pause re-read below, and for the same reason: another thread can park or die inside the window between a re-scan and a launch. An owned pick never stalls the refill: skip it, print its one-line surface, and take the next unowned candidate until the free slots are filled or the candidate set is exhausted.

**Refresh the session listing on the tick that sweeps, not once per session (issue #1459).** The sweep here runs 1B.5's blocks unchanged — the `list_sessions` call, the temp-file write that sets `SESSION_LISTING_PATH`, then the sweep block — because a listing captured hours ago is exactly the stale input that turns a thread which died since into `live` (no adoption, work stranded) or a thread that started since into `dead` (adoption underneath a running pipeline). Re-call the tool on any tick that sweeps and rebuild the file; the tool's schema stays loaded, so only the call repeats. When it is unavailable the same `DEGRADED:` line applies and the tick falls back to surface-and-skip.

**Re-read the pause in that same pre-launch check**, per pick, not once per tick. A re-scan plus a re-score is not instantaneous, and the user may have said stop inside that window — a pick validated before the stop must not launch after it. `paused: true`, or a read that fails per the table above, cancels every remaining launch this tick.

**Overlap chains still serialize.** A free slot is permission to launch *some* issue, never one whose file is contested — `/subagent` Step 6.0b picks the chain head. A candidate chained behind a running pipeline is not eligible on this tick; take the next unchained one.

**Too-big picks are never auto-launched.** Backlog refill launches inline-eligible issues only. A **criterion-1/2** candidate goes down 3.1's thread-prompt path — chip or printed block — and waits for the user's click, exactly as before.

**A criterion-3 pick is decomposed on the tick, not chipped (#1193).** Run 3.1's decomposition bullet (`/subagent` Step 5.1) right here: file the children, queue the chain, and launch its head into the free slot that triggered this refill. Only the head consumes a slot — the successors queue behind it and are not additional picks, so a refill needing two slots takes this chain plus one other candidate, not this chain plus two. The parent gets a `Tracking` row and no slot. Filing issues during a monitor tick is permitted for exactly this path (`/subagent` Step 8's prohibited-activities carve-out); if Step 5.1 cannot file — its dependencies unresolved, more than 5 children needed, or no clean split — it routes the parent out and the pick reverts to the thread-prompt path above, saying which.

**Refill replenishes only up to the repo-wide cap.** The too-big picks reaching 3.1's chip path are bounded by `FREE` there, so a refill tick offers at most `FREE` new chips and defers the rest with the count and scope named. This is the term that makes refill *replenishment* rather than accumulation: as PRs merge and chips clear, `FREE` grows and previously deferred issues become offerable again on a later tick. A tick where `FREE == 0` is a legitimate resting state for the chip path — report `nothing eligible (repo-wide active-work cap)` rather than offering past it. Inline refill is unaffected while under both limits; `min(CEILING, ACTIVE_WORK_CAP)` governs, per `chip-launching.md`.

**Report the picks; never ask for them.** Every auto-refill prints one prose line per issue started, each with a one-line rationale — the existing prose-line style used alongside the Active Work table, not a new column:

> Refilled 2 open slots — started #61 (unblocks #70, top of Critical) and #55 (smallest Standard-tier win against the current OKR). Say "adjust" to redirect.

Redirecting after the fact is the correction mechanism that replaces the removed selection turn.

**When a slot stays empty, keep one `IDLE_REASON` for the existing day digest and heartbeat.** The Slot census below owns the changed-only notice. Use the applicable reason:

| Reason | Meaning |
|--------|---------|
| `nothing eligible` | No inline-eligible candidate left — backlog empty, everything closed, or every remaining issue already has a PR. Append `(scope: <scope>)` when a non-null `$SCOPE` is what emptied the set, so a narrowing never looks like an exhausted backlog |
| `chained` | Every remaining candidate is serialized behind a contested file (`/subagent` Step 6.0b) |
| `paused` | The user said stop, or the pause state is unreadable (Execution Boundary) — refilling stays off until a human explicitly resumes it |
| `paused (pipeline failures)` | **Day mode only** — `day.refill_halted` is set after `max_pipeline_failures` consecutive `blocked` outcomes (2D.3 D1). Distinct from `paused` on purpose: the board is held by a detected failure pattern, not by the user, and the fix is to look at the surfaced blockers |
| `paused (budget reached)` | `credit-budget.sh --check` returned `reached` (exit 1) — an authoritative overage signal for today was found. Near-done work lands; then the loop exits for the rest of this ET day. Resume: `credit-budget.sh --reset` (manual override) or start a new session the next ET day (`credit-budget.sh --check` returns `ok` when no overage event is found for the new day) |
| `paused (budget unknown)` | `credit-budget.sh --check` returned `unknown` (exit 2) — no authoritative source was reachable. Conservative posture: in-flight work finishes, no new dispatches. Clears automatically on the next tick when the probe succeeds |
| `paused (priority unreadable)` | The operator-priority file exists but does not read (1B.1a) — it may be hiding a park, so nothing new starts. In-flight work finishes. Clears automatically on the first tick it reads cleanly (fixed with `/desk`, or removed) |

A full board is `ceiling reached` and needs no explanation. The heartbeat carries the same reason in its `· slots {used}/{cap}` suffix (`monitor-mode.md`), where `{cap}` is the Step 0 `LIMIT` — `slots 3/4` on a default repo.

#### Slot census

Finish each refill evaluation with this record, including a full board and a pause, budget, priority, deadline, or horizon hold. The census observes the existing checks and launch results. Keep `IDLE_REASON` for the existing day digest. Emit the helper’s `Board below limit` line once when its slot counts or reasons change. A full-board evaluation resets that comparison quietly. A `refill_missed` line is a fault notice, and the next evaluation follows the existing refill rules.

Start each evaluation with an empty ledger and no carried `CENSUS_GATE` or `CENSUS_HORIZON`. Set the horizon from this evaluation’s observation when available. Keep one `{issue, outcome}` entry per issue in effective pick order across override, queue, and backlog. Update the same entry after revalidation and dispatch.

| Observed outcome | Ledger value |
|---|---|
| Closed, already has a PR, ownership skip, parked, outside scope, or otherwise ineligible for this refill | `ineligible` |
| Chain successor or a footprint still undeclared after [area resolution](../../../wave/SKILL.md#step-3-extract-each-candidates-file-footprint), held by 6.0b | `chained` or `undeclared` |
| Window fit or Step 7 holds this candidate, or repo-wide capacity holds its chip | `deadline` or `repo_wide_cap` |
| Current checks cleared and this candidate could launch on this evaluation | `eligible` |
| Live handle or recorded launch | `launched` |
| Spawn happened but its record failed | `launch_unconfirmed` |
| Missing or interrupted launch evidence | `launch_unknown` |

Read `running` after the dispatch attempt from the same author-scoped pipeline count. Include merge-ready and Phase C work and observed launches with unconfirmed registration. Count the merge-ready/Phase C subset and the actual remaining queue separately. Queue or board membership alone is insufficient evidence of a launch.

Pass the actual whole-evaluation hold when the gate prevented all remaining launches. Map the existing human pause, unreadable pause or scope, pipeline failure halt, budget reached or unknown, and unreadable priority to `paused`, `paused_state_unreadable`, `paused_pipeline_failures`, `paused_budget_reached`, `paused_budget_unknown`, and `paused_priority_unreadable`. Use `horizon`, `deadline`, or `repo_wide_cap` only when that gate held the whole evaluation. If a gate interrupted the evaluation after some launches, keep the completed outcomes and count the actual occupied slots before attributing the remaining capacity to that gate. Use `null` when there is no whole-evaluation gate. The helper bounds slot attribution by vacant capacity and records a missed refill only with affirmative eligibility and conclusive evidence that nothing launched. Unreadable counts or an incomplete evaluation must not be replaced with zeroes or a fabricated eligible row.

Populate `CENSUS_RUNNING`, `CENSUS_PHASE_C`, `CENSUS_QUEUED`, and `CENSUS_CANDIDATES` from this evaluation. Run the following once for the exact dispatcher session, including before any early return that completed a refill evaluation. A failure reports that the census could not be persisted and leaves the launch decision with its existing gates.

<!-- test-anchor: pm-refill-slot-census -->
```bash
CENSUS_RC=0
CENSUS_TOOL="${SESSION_STATE_SH%/*}/lib/pm-slot-census.py"
if [ -z "${CLAUDE_SESSION_ID:-}" ] || [ ! -r "$CENSUS_TOOL" ]; then
  printf '%s\n' 'DEGRADED: slot census unavailable (dispatcher session or helper missing)' >&2
elif CENSUS_JSON=$(jq -cn --argjson limit "$LIMIT" --argjson running "$CENSUS_RUNNING" \
    --argjson phase_c "$CENSUS_PHASE_C" --argjson queued "$CENSUS_QUEUED" \
    --arg gate "${CENSUS_GATE:-}" --arg horizon "${CENSUS_HORIZON:-}" \
    --argjson candidates "$CENSUS_CANDIDATES" \
    '{limit:$limit,running:$running,merge_ready_or_phase_c:$phase_c,queued:$queued,
      global_gate:($gate|select(length>0) // null),horizon_status:($horizon|select(length>0) // null),candidates:$candidates}'); then
  python3 "$CENSUS_TOOL" --record --repo "$REPO_KEY" --session "$CLAUDE_SESSION_ID" \
    --state-helper "$SESSION_STATE_SH" <<< "$CENSUS_JSON" || CENSUS_RC=$?
  if [ "$CENSUS_RC" -ne 0 ]; then
    printf '%s\n' 'DEGRADED: slot census was not recorded' >&2
  fi
else
  printf '%s\n' 'DEGRADED: slot census inputs could not be read' >&2
fi
```

When one or more pipelines or threads finish (PRs merged, issues closed) — housekeeping that runs on a *finish*, separate from the capacity trigger above:

1. **Dismiss the chips of finished issues, then remove their rows.** Order matters: a row carries its chip's `task_id`, and once the row is gone the chip can no longer be withdrawn. So for every completed issue still at `Chip offered`, `dismiss_task` first — its work is done, the offer is dead — and only then drop it from the assignments table.
2. **Scan only when the queue-first top-up above requests it.** Re-scan open issues (reuse 1B.2-1B.4b logic but lighter — only re-read bodies **and comments** for issues whose `updatedAt` moved since the last scan's baseline, or that have no recorded baseline yet (first seen this pass — always gets a full read, same as a changed issue); track/update that baseline per issue as you go). **`updatedAt` bumps on a new comment just like a body edit**, so a dependency reference added in a comment on an otherwise-untouched issue (e.g. "blocked by #99") is still caught on the next pass — re-reading is scoped by *any* change, not just body/title edits, which is what keeps this from being a real completeness gap. **Re-score the whole retained candidate set, not just the changed issues:** tiers depend on the dependency map, so a closed or merged issue can change an *unchanged* issue's tier — #42 loses its leverage boost the moment the issues it unblocked are done. Refresh the map with what closed **and** what changed, then re-run 1B.4/1B.4b across every remaining candidate — the operator-order overlay (1B.4 item 7) last, against the file as it reads now. Re-reading bodies and comments stays scoped to issues whose `updatedAt` moved or that are new — that's the expensive part and it stays incremental; re-scoring the dependency map and tiers is cheap and must be total. Then persist the new order (1B.4c), so the desk's derived impact reads this re-scan's ranks.
3. Report the picks from the queue-first refill and any backlog fallback. Do not dispatch a second batch from this housekeeping path.
4. Too-big candidates surfaced by an executed re-scan still go down Step 3.1's chip-or-fallback path and wait for the user's click.
5. **Dismiss superseded and re-planned chips.** Beyond the finished issues handled in step 1, withdraw a `Chip offered` chip only when its offer is genuinely dead:
   - **Superseded** — the issue was explicitly replaced by a newer suggestion.
   - **Re-planned** — the issue's scope or plan changed, so the chip's prompt is stale.

   An offered chip that simply isn't in the new batch is **not** superseded — a suggestion the user hasn't acted on yet stays valid and keeps its chip. Only dismiss on an explicit signal.

   Re-planning is spawn-then-dismiss, in this order:

   1. Spawn the replacement chip.
   2. **Record the replacement's `task_id` immediately** — before touching the old chip. An unrecorded chip cannot be withdrawn, so if the next step fails you would otherwise be left with a live chip you have no handle for.
   3. Dismiss the old chip, then reconcile the table: replacement row keeps its `task_id`, old row is cleared.

   **Read the dismiss outcome — "gone" is not "failed".** If `dismiss_task` reports the chip was already clicked or already dismissed, the offer is withdrawn or acted on and the goal is met: treat it as a successful no-op, clear the old `task_id`, and move on. Only a genuine failure (the chip is still live and was not withdrawn) needs recovery: withdraw the replacement to restore a single offer, and if that also fails, keep both `task_id`s tracked and tell the user which one is stale rather than silently dropping either. Update the Active Work table only after the outcome is known.


Mark `3.4 ran` when the invocation completes its refill evaluation. If a gate
explicitly held the evaluation, mark `3.4 skipped` with that gate's reason. A
failed evaluation is `3.4 failed`. Leave an unreached, unexplained evaluation
unrecorded.

