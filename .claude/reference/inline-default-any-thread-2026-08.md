# Inline by Default in Any Thread — 2026-08 Routing Flip

> Decision record for issue [#1229](https://github.com/auerbachb/claude-code-config/issues/1229). Not auto-loaded. The live wording lives in `chip-launching.md` "PM-context inline gate" and in the four surfaces that consume it; this file records *why*, so the next person to move the gate moves it against the reasoning rather than around it.
>
> Lineage: `pm-routing-audit-2026-07.md` (#701, the gate's first shape) → `too-big-recalibration-2026-07.md` (#776, slot state stopped routing) → **this** (#1229, PM context stopped routing). Companion: `active-work-cap.md` (#1191, the cross-thread bound this flip leans on).

## What changed

The gate's first condition used to be **"is a `## Active Work` table present?"** Absence answered "there is no inline pipeline here, so a separate thread is the only execution path," and the chip followed. That reading is now retired. The first condition is **"can this thread execute a pipeline?"**, and a missing table is a **bootstrap instruction** rather than a verdict.

| | Before (#701 + #776) | After (#1229) |
|---|---|---|
| First check | PM context — is a table present? | Execution capability — can this thread run a pipeline? |
| Table absent | route to a chip | bootstrap the table, run inline |
| Structural chip reasons | 2 — no PM context, or a named Step 4 disqualifier | **1** — a named Step 4 disqualifier |
| Capture session of N issues | up to `FREE` chips, remainder deferred | **one** batch hand-off covering all N |
| Ceiling-full precedence | 3 cases | 2 — execution-capable queues; capture defers its one hand-off |

## Why absence of PM context was never evidence

A routing condition should measure the thing it routes on. "Has this thread already announced itself as a PM thread?" measures a *label*, and the label is a side effect of history: the same thread, with the same tools and the same capability, routes differently depending on whether someone happened to type `/pm` in it earlier. Almost any thread can run a pipeline — `/subagent` needs no PM machinery, only issue numbers — so the old check was reading a proxy that did not track the property.

The cost landed on the user twice, and both are worth naming because they are what "sprawl" actually means in practice:

- **They became the work tracker.** Five chips are five tabs, five things to remember, five places to check. One thread running five pipelines is one status line.
- **They became the model setter.** A chip presets neither picker control, so every chip hands over a `**Model:**` and `**Effort:**` recommendation the user must apply *before* clicking, and any mismatch is theirs to notice. An inline pipeline picks its model at spawn time; the picker never enters it.

## The execution-capability test, and why it is one named exception

The test is deliberately not a heuristic: **every thread is execution-capable except one under an explicit capture-mode invariant** (`/issue-maker` Step 2). Two properties make that the right shape:

- **It is checkable.** Capture mode is a declared, persisted session state with a refusal behavior already written down — not a vibe about what a thread "is for."
- **It cannot quietly grow.** A heuristic ("this thread looks conversational", "this one was for planning") would re-accumulate exactly the case-by-case exceptions that turned into one-chip-per-issue in the first place. The gate names the non-exceptions outright so a future reader has to add one on purpose.

Rejected alternative: a per-thread capability probe or marker each surface sets. It buys nothing the invariant does not already give, and every new marker is another thing to forget to set — a fresh way for a thread to read as incapable when it is not.

## Bootstrapping is not becoming `/pm`

A thread that adopts work emits a `## Active Work` table in `/pm` 3.2's schema and runs the work. It does **not** run `/pm`'s ranking pass, backlog scan, or OKR machinery. Stated explicitly in the gate because the implicit reading — "bootstrap the table" meaning "cold-start `/pm`" — turns a one-issue adoption into a full orchestration detour.

`/wave` keeps a second, different bootstrap for a different thing: its Step 1.2 cold-starts `/pm` when the thread has no **ranking**, and a table falls out of that incidentally. One table-bootstrap route, one ranking route; they are not alternatives.

## The guardrail this flip depends on

Bootstrapping sets `IN_FLIGHT = 0` **for the bootstrapping thread**. Taken alone that is the twenty-thread failure in slow motion: every fresh tab reads an empty table as full headroom and starts four pipelines. What makes the flip safe is that the binding term is `min(pipeline_ceiling, active_work_cap)` — the repo-wide census from `active-work-cap.sh` (#1191) counts work in *other* threads, which a table this thread just created cannot see. #1229 is only landable because #1191 landed first; the gate says so where `IN_FLIGHT` is defined.

## The capture-session batch hand-off

A capture thread cannot adopt, so its work leaves the thread — but it leaves **once, for the session**, not once per issue. One hand-off opens one execution-capable thread that bootstraps its own table and runs every filed issue **through the inline-vs-thread gate** — inline for the ordinary case, and out to its own thread for the rare issue that thread judges too big. "Runs them all inline" would overstate it: consequence 1 below is precisely that the routing decision moves to that thread, so a criterion 1/2 issue can still leave it.

Three consequences worth recording:

1. **Per-issue too-big routing moves to the launched thread.** Capture does no tier classification, so deciding there was guesswork; `/subagent` Step 4 decides it with the code in front of it. This is also why the hand-off carries no Step 4 criterion — its reason is the capture-mode invariant, which is session-level.
2. **Increment chains stop splitting their outcome.** The head used to get a chip and each successor a queued note. One hand-off names the chain and its order; `/subagent` Step 6.0b serializes the overlap, which is the mechanism that was always doing the real work.
3. **With the registry (#1238), a batch chip occupies one `ACTIVE` slot regardless of N.** `chip-offer-registry.sh --reserve` creates a single registry entry for the batch, and `active-work-cap.sh` counts registry entries, not issues. The hand-off's `task_id` is still stamped on every issue it covers in the legacy log so that `/wave` and `/pm` do not offer a second launch for covered work; `active-work-cap.sh` excludes registry-covered issues from the legacy count so no issue is double-counted from either source. Concurrency is bounded by the same `min(pipeline_ceiling, active_work_cap)` as before — the launched thread adopts all N issues through the inline gate.

**Two defects this shape introduces, and how each is handled.** Both come from one `task_id` spanning several issues, and both were found in review rather than in design — worth recording, because the next person to widen a chip's scope inherits the same two:

1. **Retract must not blindly withdraw the hand-off.** Withdrawing on a single issue's retract would strand every other issue the hand-off still covers. `/issue-maker` Step 12 counts the other open issues sharing the id first — withdraw only when this was the last one, otherwise refresh over the remaining set (replace, then withdraw).
2. **"Already clicked" is not a successful withdrawal.** The generic stale-chip rule treats `already clicked` and `already dismissed` alike, because for a *single-issue* chip both mean the offer is gone. For a batch hand-off they diverge: a clicked hand-off is a **running thread** that has already claimed its issue set, so replacing it launches a second thread over the same work — and since the claim contract stops on an already-claimed issue, that thread can halt on the first name in its list and never reach the newly added ones. Step 9c therefore branches on clicked-vs-unclicked: an unclicked offer is replaced, a clicked one is left alone and the new issues get a **second** hand-off covering only them. "At most one" is scoped to live offers, not to lifetime totals.

**Admission is now reserved atomically** (#1238, landed after this document was written). `chip-offer-registry.sh --reserve` takes the reservation under the state lock so two concurrent sessions cannot both admit against the same free slot. A batch hand-off calls `--reserve` once (not per issue), so `ACTIVE` is incremented by one for the batch chip, not by N for its N issues. The known limitation from the original version of this paragraph has been resolved; see `active-work-cap.md` §Known limits for the remaining limits (offer-side only; `/pm`/`/prompt` undercount window).

## `/start-issue` adopts in two shapes, on purpose

CodeRabbit's plan routed `/start-issue` inline via `/subagent #N` unconditionally. That is right when the thread is already orchestrating — monitor mode forbids substantive work in the parent, and a pipeline is the correct shape there. It is wrong at the front door: `/start-issue` Step 6 has just created a worktree and branch for this issue, and `/subagent`'s phases spawn with `isolation: "worktree"`, so they would provision a second worktree and orphan the branch. So the front-door case codes the issue in the worktree it just prepared. Both are inline; the shape follows what the thread is already doing.

## Relationship to #735 — sidestepped, not fixed

`spawn_task` still has no `model` or `effort` parameter ([#735](https://github.com/auerbachb/claude-code-config/issues/735)), so a chip can only *recommend* and rely on the user setting the picker before clicking. Routing inline removes the picker from the path entirely — an inline pipeline picks its model at spawn time — which **eliminates the exposure for inline work without closing the gap**. Chips that survive (too-big routing, the capture hand-off) still depend on the user setting the picker, and still carry the model-guard preamble for exactly that reason. Do not read this flip as resolving #735, and do not close #735 against it.

## Scope calls left deliberately unmade

- **`/prompt` Path A is unchanged.** `/prompt #N` with explicit issue numbers emits a thread prompt with no Step 4 criterion, which looks like a violation of "every chip names its criterion" and is not: the user asked for a prompt block. That is a user instruction, not a routing default, and the gate names it as one of two non-routing separate-thread cases. Path B (PM auto-detect) already partitions through Step 5.5.
- **The gate's section name stays `PM-context inline gate`.** It is cited by name from six surfaces and appears inside four `ERROR: … PM-context inline gate unavailable` strings. Renaming would touch every one of them for no behavioral gain; the section now opens by saying the name is historical and the check is execution capability.
- **`active-work-cap.sh` is untouched.** Deduping the census by `task_id` (counting one hand-off as one unit rather than N) is a defensible future change, but it alters a counting contract that landed in #1224 and is not needed for this flip to be safe — the overshoot direction is the conservative one.

## Related

- [#1193](https://github.com/auerbachb/claude-code-config/issues/1193) — the PM-thread half of the same problem, **landed 2026-08-22, hours before this one**. The two compose cleanly because they change **different checks** in the same gate: #1193 changed the *second* check's remedy (criterion 3 decomposes into an inline increment chain rather than routing out, so only criteria 1 and 2 still make an issue non-subagent-fit), and this one changed the *first* check (PM context → execution capability). Neither subsumes the other, and landing both is what makes chips genuinely rare: after #1193 almost nothing is non-subagent-fit, and after #1229 nothing routes out merely for lacking PM context — so the surviving chip is a criterion 1/2 verdict, or a criterion 3 whose decomposition was unavailable.

  One consequence worth naming, because it is easy to get wrong when editing this gate: **"names a Step 4 criterion" is no longer satisfied by naming criterion 3 alone.** Every surface that emits a chip must carry #1193's pairing rule, not the older three-criteria phrasing. Rebasing #1229 over #1193 required fixing exactly that in `/start-issue` Step 7 and `/wave` 7.0 + Step 9, in text that merged without a conflict.
- [#1225](https://github.com/auerbachb/claude-code-config/issues/1225) — chip visibility in the repo-wide active-work count.
