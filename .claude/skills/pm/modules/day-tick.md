<!-- pm-routing:begin -->
Route `day:tick`. Read for a typed day tick and for the immediate inline tick after arming. D3 can load day:arm to recover its Monitor template.
<!-- pm-routing:end -->
### 2D.3: The tick

Six sub-steps, in order. This is the entry point for `DAY_TICK=true`.

**D0 — Tick gate.** Three reads; any mismatch is a silent `exit 0` with no output, because a stale Monitor's tick must not narrate:
1. `TICK_GENERATION` equals the recorded `day.monitor_generation` (a tick from a superseded Monitor is stale).
2. `day.active == true`.
3. `day.stop_requested != true`.

After D0 accepts the tick, reconcile tracked merged deliveries through [issue completion](../../../reference/issue-completion.md) before refill. Never relaunch code for an already-merged delivery because closure is pending.

After D0 accepts the tick, run the [finished-only cadence](../../../reference/workspace-sweep-cadence.md); ticks still skip Step 1 and `/pm-clean`:

<!-- test-anchor: workspace-sweep-pm-day -->
```bash
# workspace-sweep-pm-day
SWEEP_SH=$(resolve_script workspace-sweep.sh || true)
if [[ -n "$SWEEP_SH" ]]; then
  "$SWEEP_SH" --trigger pm-day --repo-dir "$(git rev-parse --show-toplevel)" --min-interval "${CLAUDE_WORKSPACE_SWEEP_INTERVAL_S:-3600}" || true
fi
```

**D1 — Reconcile and transition.** Run items 1–3 of `monitor-mode.md`'s per-cycle checklist verbatim: process completed subagents and parse exit reports, execute phase transitions per `phase-protocols.md` (including any stalled in `session-state.json`), and run the reviewer-escalation gate for every session PR still on `reviewer == cr`. That checklist owns each step's exact invocation; day mode adds nothing here — this is the same in-turn loop the on-demand path already runs.

Then update the failure streak from this tick's terminal outcomes, in completion order: `merged` resets `failure_streak` to `0`; `blocked` increments it. Only terminal outcomes count — a pipeline still in Phase B is neither.

**Evaluate the halt threshold here, not in D4.** If the updated `failure_streak >= max_pipeline_failures`, persist `day.refill_halted=true` with `halt_reason="failure_streak"` and surface the pattern **now**, before D2 runs:

> Refill halted — 3 consecutive pipelines blocked: #61 (CI failing on main), #55 (CI failing on main), #48 (CodeRabbit budget exhausted). Say "resume" to restart refilling.

Name each blocked pipeline's issue and its blocker, so the user can see at a glance whether this is one broken thing or three unrelated ones — that distinction is the entire value of halting on a streak rather than on a count.

The placement is the point: D2 reads `refill_halted` to decide whether to launch, so evaluating the threshold in D4 would let the very tick that crossed it refill first and halt afterwards, pushing one more pipeline into a board already known to be failing. A halt that takes effect one tick late is a halt that fired after the damage.

**D2 — Refill.** Run **Step 3.4 unchanged** — the pause read with its exit-code table, `$SCOPE` narrowing, operator order, claimed successors and standing picks, then backlog top-up (with the operator-priority re-read), per-pick re-validation, overlap chains, `FREE` from `active-work-cap.sh`, and the reported-not-proposed launch lines. Day-mode conditions sit **on top of** it, none replacing any part:

**The usage-horizon gate runs first, before any pick is dispatched** (#1428, #2147). Use the counter (`<total_tokens>N tokens left</total_tokens>`) only if this turn's harness actually prints it. Never use a transcript-derived count or local estimate. Use §7.3 of `subagent-thread-limit-park.md` for the continuous first-hand absence attestation and launch policy.

<!-- test-anchor: pm-day-d2-horizon-branch -->

```bash
# HORIZON_REMAINING / HORIZON_LIMIT: the numbers the HARNESS printed this turn.
# Leave both empty when the counter is not in context — never substitute a
# remembered figure. An absent reading is never `clear`, but it is not inert
# either: with nothing to observe, the gate falls through to `--check`, which
# answers `unknown` unless THIS session already recorded a reading inside its
# TTL. A live same-session `critical` does still park, and should — the counter
# only falls within a session, so the reading a fresh figure would have
# corrected is stale only in the safe direction.
HORIZON_STATUS=unknown
HORIZON_REASON=helper-unavailable
HORIZON_OBSERVE_RC=0
if [ -n "${USAGE_HORIZON_SH:-}" ] && [ -n "${HORIZON_REMAINING:-}" ]; then
  if [ -n "${HORIZON_LIMIT:-}" ]; then
    "$USAGE_HORIZON_SH" --observe "$HORIZON_REMAINING" --limit "$HORIZON_LIMIT" \
      >/dev/null 2>&1 || HORIZON_OBSERVE_RC=$?
  else
    "$USAGE_HORIZON_SH" --observe "$HORIZON_REMAINING" >/dev/null 2>&1 || HORIZON_OBSERVE_RC=$?
  fi
fi
if [ "$HORIZON_OBSERVE_RC" -ne 0 ]; then
  HORIZON_REASON=observe-failed
elif [ -n "${USAGE_HORIZON_SH:-}" ]; then
  # Set HORIZON_COUNTER_NEVER_SEEN=true only on §7.3's first-hand attestation.
  HORIZON_CHECK_RC=0
  if [ "${HORIZON_COUNTER_NEVER_SEEN:-}" = true ] && [ -z "${HORIZON_REMAINING:-}" ] &&
     [ -z "${HORIZON_LIMIT:-}" ]; then
    HORIZON_OUT=$("$USAGE_HORIZON_SH" --check --counter-never-seen 2>/dev/null) || HORIZON_CHECK_RC=$?
  else
    HORIZON_OUT=$("$USAGE_HORIZON_SH" --check 2>/dev/null) || HORIZON_CHECK_RC=$?
  fi
  _HS=$(printf '%s\n' "$HORIZON_OUT" | sed -n 's/^STATUS=//p' | head -1)
  case "$_HS" in clear|approaching|critical) HORIZON_STATUS="$_HS" ;; *) HORIZON_STATUS=unknown ;; esac
  HORIZON_REASON=$(printf '%s\n' "$HORIZON_OUT" | sed -n 's/^REASON=//p' | head -1)
  HORIZON_REASON=${HORIZON_REASON:-helper-unavailable}
  if [ "$HORIZON_REASON" = counter-never-seen ] &&
     { [ "$HORIZON_CHECK_RC" -ne 3 ] || [ "$_HS" != unknown ] ||
       [ "${HORIZON_COUNTER_NEVER_SEEN:-}" != true ] || [ -n "${HORIZON_REMAINING:-}${HORIZON_LIMIT:-}" ]; }; then
    HORIZON_REASON=helper-unavailable
  fi
fi
case "$HORIZON_STATUS" in
  clear)       HORIZON_REFILL_OK=true;  HORIZON_PARK=false; HORIZON_IDLE_REASON="" ;;
  approaching) HORIZON_REFILL_OK=false; HORIZON_PARK=false; HORIZON_IDLE_REASON="paused (horizon approaching)" ;;
  critical)    HORIZON_REFILL_OK=false; HORIZON_PARK=true;  HORIZON_IDLE_REASON="paused (horizon critical)" ;;
  *)           HORIZON_REFILL_OK=false; HORIZON_PARK=false; HORIZON_IDLE_REASON="paused (horizon unknown)" ;;
esac
printf 'HORIZON_STATUS=%s\nHORIZON_REFILL_OK=%s\nHORIZON_PARK=%s\nHORIZON_IDLE_REASON=%s\nHORIZON_REASON=%s\n' \
  "$HORIZON_STATUS" "$HORIZON_REFILL_OK" "$HORIZON_PARK" "$HORIZON_IDLE_REASON" "${HORIZON_REASON:-}"
```

`--observe` exits `0` on a successful record **whatever the verdict** — only `--check` maps verdicts to exit codes — so a non-zero `HORIZON_OBSERVE_RC` is a real write/usage/lock failure, not a bad verdict, and the gate **skips `--check` entirely** and holds `unknown`. That clamp is the one place this gate second-guesses the script, and it earns it: a failed observe means this turn's reading did not land, so any stored verdict is knowably older than what we just tried to record — and because the counter only falls during a session, a stale reading is *optimistic*, the one direction that matters. Skipping the read costs at most a tick of refill and can never park (`unknown` never parks). Never substitute a remembered number for a failed observe.

**A tick with no counter in context still reads `--check`.** The absent-reading case is deliberately *not* clamped: a reading recorded by an earlier tick of this same session is legitimate evidence, and the script's own TTL and session-ownership gates are what decide whether it is still good. Requiring a fresh reading every tick would force `unknown` on every turn where the counter did not surface, which stops refill on a healthy board — turning a wind-down feature into a board-stopper. Then:

| Verdict | Refill | Park | Chat |
|---------|--------|------|------|
| `clear` | normal | no | nothing — the tick proceeds unchanged |
| `approaching` | **stop for this run** — start no new chip and dispatch no new pipeline | no | one always-emit heartbeat line naming the runway (`horizon approaching — ~N tokens left; starting nothing new`) |
| `critical` | stop | **yes — run 2D.7 before this tick ends**, then stop the tick | 2D.7's ≤2-line park surface |
| `unknown` | no automatic refill | **never** | reason on the idle line; §7.3 message on first requested dispatch |

`unknown` never starts automatic work or triggers a park. An explicit live chat request to launch a current set of picks may proceed only on `counter-never-seen`, with §7.3's note and the remaining dispatch checks. This applies on the arming turn if the user actually requested those launches; periodic ticks and a request to keep the board full cannot inherit the exception. Use §7.3's hold line for the first requested dispatch when the horizon holds it.

- **Automatic refill runs only when `HORIZON_REFILL_OK=true`.** Report the horizon reason on the idle line (`paused (horizon approaching)` / `paused (horizon critical)` / `paused (horizon unknown)`). On `unknown`, append ` — {HORIZON_REASON}` to chat only. Keep the bare `IDLE_REASON` for the digest so the annotation never perturbs the stable-state hash.
- **Record every horizon-held refill evaluation.** For `approaching`, `unknown`, or `critical`, use 3.4’s Slot census with `CENSUS_GATE=horizon`, the observed `HORIZON_STATUS` as `CENSUS_HORIZON`, and an empty candidate ledger. Take the same author-scoped counts without running any selection or launch. Record `critical` before 2D.7 parks the tick. D0 rejections and standalone probes do not evaluate refill.
- **Refill runs only when `day.refill_halted` is `false`.** This is day mode's own automatic halt, set in D1 the moment the streak crosses the threshold so it binds on the same tick, and it is deliberately a *separate* field from `.repos[<key>].refill`: that one is contractually human-written-only, and a machine writing it would blur the very distinction that keeps issue text from being able to halt a pipeline. Read both; refill needs both clear. Report a halt as `paused (pipeline failures)` on the idle line.
- **Refill runs only when `credit-budget.sh --check` exits 0 (`ok`).** Read it once per D2 tick (same moment as the refill.paused read, not in a separate phase). Apply 3.4's exit-code table: exit 1 (`reached`) → land near-done work and park (3.4's budget gate above); exit 2 (`unknown`) → conservative posture — finish in-flight, start nothing new, report `paused (budget unknown)`. The budget check is re-read per pick exactly as refill.paused is.
- **Record a census on other D2 holds too.** If failure halt, pause, priority, budget, or deadline prevents the normal 3.4 dispatch path, take the same counts and use 3.4’s gate mapping once before leaving the evaluation.
- **At most one new chip per turn — counting the arming turn as tick 0.** Day mode runs for hours, so a thread-prompt issue deferred now is offered on the next tick, minutes later — spreading costs nothing, and a wall of chips is the exact failure day mode exists to end (#1190). `FREE` still bounds it from above; this is a second, tighter bound that applies only in day mode. **The bound covers Step 1's dispatch too, not just later ticks:** Step 1 runs inside the arming turn and reaches 3.1's chip path bounded only by `FREE`, so without this it would be the *first* turn of a run that emits six chips at once — the failure, on the turn most likely to be watched. Report the rest as deferred exactly as 3.1 already does, with `Deferred (cap)` rows so nothing is forgotten; they are re-offered one per tick as the run proceeds. Inline dispatch is **not** rate-limited — it fills to the ceiling on the turn it can.

For the immediate tick of an arming invocation, a gate that prevents Step
3.4 records `3.4 skipped` with the observed hold reason before any early
return. When Step 3.4 runs, use its own outcome.

**D3 — Backoff and bookkeeping.** Hash the board, then apply `scheduling-reliability.md`'s stable-state backoff.

**Assign all four tuple fields here, from what D1 and D2 just produced** — none of them exists as a variable until this step creates it, and an unset one silently degrades the digest to `|||`, which is identical on every tick and would widen the cadence straight to `stable-frozen` on a board that was in fact working:

| Variable | Derived from |
|----------|--------------|
| `PIPELINES_SORTED` | The Active Work table (3.2) after D1's transitions: `issue:phase:head_sha` per row whose Thread is `Inline` and whose status is non-terminal, joined and **sorted by issue number** so row order never changes the hash. Empty string when no pipeline is running. |
| `QUEUE_LEN` | Deduplicated count of claimed successors and the dispatcher’s standing plan (3.4). `0` when both are known empty. |
| `BACKLOG_HEAD` | The top-ranked eligible candidate D2's refill considered, or the literal `-` when it found none. |
| `IDLE_REASON` | The reason D2 reported on its idle line — one of `ceiling reached`, `nothing eligible`, `chained`, `paused`, `paused (pipeline failures)`, `paused (budget reached)`, `paused (budget unknown)`, `paused (priority unreadable)` (3.4), `paused (horizon approaching)`, `paused (horizon unknown)` (D2's horizon gate; `paused (horizon critical)` never reaches the digest — that tick parks in 2D.7 and ends). |

```bash
DAY_DIGEST=$(printf '%s|%s|%s|%s' "$PIPELINES_SORTED" "$QUEUE_LEN" "$BACKLOG_HEAD" "$IDLE_REASON" \
  | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } \
  | awk '{print "sha256:"$1}')
```

Use that `sha256sum`-or-`shasum` form rather than a bare `sha256sum`: `/pm` is symlinked into repos on machines that may have no GNU coreutils, and AC6 (#1189) is that day mode works there.

Compare against the stored digest and hold the result in `DAY_STREAK`, which the tier computation below reads:

<!-- test-anchor: pm-day-tick-digest-streak -->
```bash
PREV_DIGEST=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.digest")
PREV_STREAK=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.digest_streak")
[ "$PREV_STREAK" = null ] && PREV_STREAK=0
if [ "$DAY_DIGEST" = "$PREV_DIGEST" ]; then DAY_STREAK=$(( PREV_STREAK + 1 )); else DAY_STREAK=0; fi
```

**Reset to `0`, not `1`** — day mode's streak is fleet-shaped like `/pr-monitor-and-manage`'s, and unlike `/babysit-pr` it writes nothing `polling-backoff-warn.sh` reads (that hook watches `.prs[N].*`), so PMM's convention is the one to match. Then:

| `digest_streak` | Cadence |
|-----------------|---------|
| `< 3` | base (`cadence_base_minutes`) |
| `>= 3` | `max(15, 3 × base)` minutes |
| `>= 9` | pause — `stable-frozen` (D4) |

Compute the tier into an explicit variable, because the re-arm below must sleep for the **effective** cadence and 2D.2's arming template names only the base one:

<!-- test-anchor: pm-day-tick-effective-cadence -->
```bash
DAY_BASE_MIN=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.cadence_base_minutes")
DAY_EFF_MIN=$DAY_BASE_MIN
if [ "$DAY_STREAK" -ge 3 ]; then
  DAY_EFF_MIN=$(( DAY_BASE_MIN * 3 ))
  [ "$DAY_EFF_MIN" -lt 15 ] && DAY_EFF_MIN=15
fi
```

Persist `digest`, `digest_streak`, `failure_streak`, `tick_count`, and `last_tick_at` in one write. **Re-arm the Monitor only when `DAY_EFF_MIN` differs from the stored `cadence_effective_minutes`** — re-arming every tick churns the task for no gain. When it does differ:

1. Set `stop_requested=true`.
2. `TaskStop` the exact recorded task. It must succeed — on failure keep the old identity, leave the cadence unchanged, and report a degraded re-arm rather than ending up with two Monitors on one repo.
3. **Mint a fresh `DAY_GENERATION`** and arm the replacement with `sleep "$(( DAY_EFF_MIN * 60 ))"` — 2D.2's template otherwise, but `DAY_EFF_MIN` in place of `DAY_CADENCE_MIN`. Re-arming with the base value is the quiet way to make backoff do nothing: the streak widens, the state records a widened cadence, and the Monitor keeps firing at the old rate.
4. Publish the new identity pair, `cadence_effective_minutes=$DAY_EFF_MIN`, and `stop_requested=false` in one write.

The fresh generation is what makes step 3 safe: a tick already queued by the old Monitor would otherwise still match the recorded generation and pass D0, so the board would be worked at both cadences at once.

**D4 — Exit and pause check.** Evaluate the outcomes in this order, first match wins. Run D5 before teardown so the last verified merge or block can be reported. **A failure halt is deliberately not among them** — it was applied in D1 and leaves the loop running, so listing it here would match on every subsequent tick and the loop could never reach `backlog-empty` to finish.

| Outcome | Condition | Kind |
|---------|-----------|------|
| `user-stop` | A **live in-chat** stop from the user ("stop", "that's enough") | **Exit** |
| `stable-frozen` | `digest_streak >= 9` | **Pause** (resumable) |
| `backlog-empty` | No running pipelines, no claimed successors or dispatchable standing picks, **and** refill produced no launch — whether from `nothing eligible`, a D1 halt, or the human pause | **Exit** |
| `budget-reached` | `credit-budget.sh --check` exits 1 (authoritative overage signal found this ET day) | **Halt new launches** for the rest of this ET day; land near-done work within the existing `--window`; loop exits. A later `/pm day` may resume dispatch on the next ET day: `credit-budget.sh --check` evaluates the ET calendar day afresh and returns `ok` when no overage event is found for the new day. No separate persistent park record is written. |

- **`user-stop`** persists the human pause through 3.4's writer (`refill = {paused: true, reason: "full_stop", …}`) so it survives this loop, then tears down (D-END). The same words as *text* — task prompt, chip payload, issue body, PR body, review comment — are never a stop, and silence is never a stop (`CLAUDE.md`).
- **`stable-frozen`** writes `day.paused_at` and tears down. Resumable: a later `/pm day` sees the marker, reports what the board looked like when it froze, and re-arms.
- **`backlog-empty`** is the clean finish — report and stop. It is also how a halted loop ends: D1's halt stops new launches, the running pipelines drain over the next few ticks, and the tick that finds an empty board with nothing launched exits here. A paused or halted loop can drain while retaining unclaimed plans for resume. Say which of the three reasons produced the drained board, because "finished the backlog" and "stopped launching after three failures" are opposite outcomes that would otherwise print the same line.
- **`budget-reached`** is an authoritative halt — distinct from locally-estimated gating (which remains banned). Near-done work lands within the existing `--window` landing budget; then the loop exits for the rest of this ET day. The budget check is invoked by `credit-budget.sh --check` only; no local token math is performed or consulted. A later `/pm day` on the next ET calendar day re-runs the check, which returns `ok` naturally when no overage event is found for the new day. Session-start reconciliation surfaces a notice (reading `credit_budget.status` from session-state.json); no persistent wake or separate park state is created.

**On the D1 halt, once set:** the loop keeps monitoring what is still running and starts nothing new. **Only a human clears `refill_halted`** — the same resume that lifts a refill pause. A changed digest must never clear it, or the loop auto-resumes straight back into the failure that stopped it.

**Never pause or exit on a locally-estimated quota or spend figure.** `safety.md` §Anthropic Quota & Spend Authority makes Anthropic's in-app UI the sole authority, and a day loop that throttled itself on a local estimate would be exactly the invisible second stop condition that rule forbids. Usage-limit wind-down is #824's, and it lands through the handoff seam below rather than as a heuristic here.

<!-- pm-routing:begin -->
When this tick meets the existing successful-resume condition, resolve `day:park-reactive` before D5 and use only its **On a successful resume** cleanup and outcome branches. That subsection owns the identity-checked retirement and counter reset. Do not enter the reactive park procedure for this route.
<!-- pm-routing:end -->
**D5 — Persist status and evaluate scheduled reporting.** Record the tick, next cadence, slots, queue, digests and recovery outcomes in existing state. Run the 3.3a report gate on this tick's board and observed terminal outcomes before teardown. Follow `decision-only-output.md` for all other output, including immediate owner-action blockers, safety events and exhausted recovery. An explicit status/board request runs `/board` immediately.

**Before the tick ends, run `scheduling-reliability.md`'s pre-exit checklist:** (1) the recorded Monitor task is active and this tick fired, (2) required owner-action notices were delivered, (3) `last_tick_at`, digests, streaks and cadence are written.

