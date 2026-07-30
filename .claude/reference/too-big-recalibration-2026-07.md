# Too-Big Fit-Bar Recalibration — July 2026

**Issue(s):** [#776](https://github.com/auerbachb/claude-code-config/issues/776) (bias PM threads harder toward inline subagents; one thread runs all)

**Date:** 2026-07-28

**Related precedent:** [#613](https://github.com/auerbachb/claude-code-config/issues/613) (made inline the default); [pm-routing-audit-2026-07.md](pm-routing-audit-2026-07.md) / [#701](https://github.com/auerbachb/claude-code-config/issues/701) (verified the routing default is *honored*); [harness-model-audit-2026-06.md](harness-model-audit-2026-06.md) (Finding C + FU-2 — the 32K figure is unverified and load-bearing)

**Current fleet:** Fable 5, Opus 5, Sonnet 5, Haiku 4.5.

---

## Why this recalibration, and why now

#613 made inline execution the default and #701 confirmed every surface honors that default. Both moved **routing**. Neither moved the **fit bar** — the `/subagent` Step 4 test that decides what counts as "too big for a subagent" in the first place. That test was written against an older generation of subagents, and #776 observed the consequence: work that would finish fine inline still gets bumped to a standalone thread, handing tracking back to the human.

#776 also put something bigger on the table: if the sequential Phase A → B → C design is itself what forces work out — slot ceilings, per-phase overhead, monitoring load — then rework the flow, not just the bar.

This document does three things:

1. Re-derives each of the three too-big criteria against today's baseline, with a per-criterion justification (AC1).
2. Evaluates the A/B/C flow against the one-PM-thread goal and records the decision with reasoning (AC3).
3. Records the ceiling/queue decision, including a real coherence defect found in the shared chip gate (AC4).

---

## Headline finding

**The phase flow was never what pushed work into separate threads. Criterion 1 was — and it was testing the wrong property.** Criterion 1 asked whether a change was *large*. The property that actually disqualifies inline execution is whether the work is *resumable* across sequential subagent turns, and the repo has had a token-exhaustion handoff protocol for carrying non-fitting work across agents the whole time. Large-but-resumable work — which is most large work — never needed a thread.

| Question (AC) | Verdict | Basis |
|---------------|---------|-------|
| AC1 — Re-derive the too-big test from current capability, justify each surviving criterion | **Done** | All three survive; criterion 1 **narrowed** from "large" to "non-resumable". Per-criterion derivation below. |
| AC2 — A separate-thread verdict must name a concrete disqualifier | **Enforced** | Mandatory named-disqualifier rule in `/subagent` Step 4 + `chip-launching.md`; size/complexity/file-count/AC-count/tier explicitly rejected. |
| AC3 — Evaluate A/B/C against the one-thread goal; confirm or refactor, with rationale | **Confirmed, on re-based rationale** | Confirmed on two grounds independent of the unverified 32K number (below). Phase count is orthogonal to the routing decision. |
| AC4 — Ceiling and queue behavior stay coherent; past-ceiling work queues inline, never becomes a chip | **Defect found and fixed** | `chip-launching.md` routed a **full pipeline** to a separate-thread chip — the exact overflow AC4 forbids. Gate restructured. |
| AC5 — Rule corpus stays within budget | **Held** | Only `subagent-orchestration.md` is budget-counted. Corpus 11,957 → 11,972 (+15); `rule-lint.sh` passes (soft 12,000, hard 13,000, cap 12,310). |

---

## Phase 1 — Today's baseline

**Fleet and context.** Fable 5, Opus 5, Sonnet 5, Haiku 4.5, with a 1M-token context window on the spawn-tier models. These are **input/reasoning** gains. They relieve how much a subagent can *read and hold* — the issue body, the CR plan, the full rule corpus, a large existing codebase — which is real, but it is not the budget criterion 1 was written about.

**The 32K output figure remains unverified — and is deliberately not relaxed here.** `harness-model-audit-2026-06.md` Finding C flagged "Subagents have a 32K output token limit" as the single stale, load-bearing number in the corpus, and filed **FU-2** to measure it. FU-2 is still open. Measuring a per-turn output ceiling is a runtime spike; this is static work and did not perform one. The audit's warning stands and is honored: **the decomposition guard is not relaxed on a guess.**

### Why the measurement turns out not to be blocking

The corpus is ambiguous about what the 32K figure even bounds. `subagent-orchestration.md` states it as a flat "output token limit," while the exhaustion protocol beside it describes a budget that gets *consumed* toward a threshold. Both readings are live in the text. The useful discovery is that **criterion 1 is wrong under either reading**:

- **If 32K bounds a single assistant message (per-turn):** a subagent's implementation is emitted across many turns — every tool call is its own turn. A twelve-file change is twelve-ish turns of output, not one 32K message. File count then says nothing about whether the work fits, and criterion 1's "very large, many-file change" test has no connection to the limit it cites.
- **If 32K is a cumulative lifetime budget:** exhaustion is already a **handled** event, not a terminal one. `subagent-orchestration.md`'s Token/Turn Exhaustion Protocol requires the agent to write a handoff and exit cleanly, and `phase-protocols.md` has the parent auto-launch a replacement for the same phase. Work that overruns one agent continues in the next one, still inline, still in the same PM thread.

So the fit bar does not depend on resolving FU-2. Under both readings the disqualifying property is the same, and it is not size: **it is whether the work can be carried across sequential subagent turns at all.** That is what criterion 1 should have been testing.

**This is not free.** An exhaustion handoff costs a respawn and a re-read of state, and a badly-decomposable task can burn several. That cost is bounded, automatic, and stays inside the PM thread. The alternative it replaces — a separate coding thread — costs the human a tab to open, a conversation to babysit, and a handoff to reconcile. #776 is explicit about which of those two costs it prefers to pay.

---

## Phase 2 — Per-criterion re-derivation (AC1)

### Criterion 1 — "Phase A won't fit one subagent's output budget" → **survives, narrowed**

**Old form.** "The initial implementation is a very large, many-file change that a single Phase A subagent (~32K output-token budget) couldn't produce in one pass — a sweeping migration across many files, or a large new subsystem."

**Why it needed narrowing.** It tests *size* and infers non-fit from it. Per Phase 1, that inference does not hold under either reading of the limit, and it ignores the exhaustion handoff entirely. In practice "many files" is the easiest signal to eyeball, so it became the de facto trigger — which is precisely the leak #776 filed.

**New form.** Route out only when the initial implementation **cannot be carried across sequential subagent turns via the token-exhaustion handoff** — work that resists being cut into resumable pieces, where a replacement agent could not pick up from a handoff and continue.

**What actually qualifies** (the shapes, not a threshold): a single generated artifact that is only valid when emitted in one pass, so a partial write leaves nothing a successor can build on; or work whose intermediate state cannot be written down — where "what I did and what remains" is not expressible in a handoff, so a replacement agent would have to redo it from scratch.

**What does not:** a sweeping migration across many files (the *most* resumable shape there is — file by file, with the file list itself as the progress ledger); a long acceptance-criteria list (each is its own resumable unit); a large new subsystem assembled from separately-writable modules.

**Undecidable cases run inline.** This is a judgment call, and it is deliberately not arithmetic — thresholds are exactly what #613 removed. So it needs a tiebreaker, and the tiebreaker is inline: if you cannot articulate *why* a handoff would fail to carry this work, that is not a close call you should resolve toward a thread. Inline's failure mode is a respawn inside the same thread; a thread's failure mode is a tab the human now owns. The asymmetry is the whole point of #776.

**What this preserves.** The decomposition guard itself is untouched. Phase A still writes a handoff on exhaustion; the parent still respawns. The narrowing changes which issues are *routed to a thread*, not how a subagent behaves when it runs long.

### Criterion 2 — "Needs interactive human judgment mid-build" → **survives unchanged**

Not a capability question, so no model or harness improvement bears on it. It asks whether a decision **only the user can make** must be settled *while* implementing. A subagent that is smarter and has more context still cannot invent a product decision the user has not made; it can only guess, and a wrong guess discovered at review time costs more than the thread would have. The existing qualifier stays load-bearing: an "Open questions" section the issue already answers does **not** count — only genuinely open calls that would block a subagent mid-build.

### Criterion 3 — "Should be split into multiple PRs" → **survives unchanged**

A deliverable-shape question, also independent of capability. One pipeline produces one PR and one review cycle. An issue spanning several independent deliverables that each deserve their own review is not made single-PR by a more capable agent — the constraint is the reviewer's and the repo's, not the agent's. Capability affects how *fast* each PR gets built, never how many PRs the work should be.

### Summary

| Criterion | Nature | Verdict | Driver |
|-----------|--------|---------|--------|
| 1 — output budget | Capability | **Narrowed** — size → non-resumability | Exhaustion handoff already carries large work inline; size never implied non-fit |
| 2 — interactive mid-build judgment | Interactivity | **Unchanged** | No capability gain removes a human from a decision only they can make |
| 3 — multi-PR split | Deliverable shape | **Unchanged** | One pipeline = one PR; a reviewer-side and repo-side constraint |

**What is now explicitly not a disqualifier** (extending the list #613 established): file count, AC count, dependency count, "feels complex," touching `.claude/rules` / `CLAUDE.md` / `.claude/skills`, orchestration keywords, and tier (Quick/Light/Standard/Heavy). None of these may carry a route-to-thread verdict on its own — see AC2 enforcement below.

---

## Phase 3 — The A/B/C flow decision (AC3)

**Decision: confirm the A → B → C split. Do not consolidate phases, and do not revise slot semantics.**

#776 authorized reshaping the pipeline, so the confirmation has to be argued rather than assumed. The prior justification — "the 32K cap forces decomposition" — is not good enough on its own, because that number is unverified (FU-2) and would leave this decision hostage to a measurement nobody has taken. Two grounds hold regardless of what FU-2 eventually finds:

1. **Phase B is an unbounded external wait.** It polls reviewers on a 60-second cadence for however long CodeRabbit, BugBot, or Greptile take — routinely 10 to 60+ minutes, with escalation chains on top. Folding that into Phase A means the agent that wrote the implementation spends its remaining context on polling noise, and if it runs out mid-wait it has no clean resume point: the work is done and pushed, but the review state lives only in that agent's head. Splitting at the push boundary puts the phase break exactly where the natural state handoff already is — the PR itself.
2. **Phase C is independent verification.** The merge decision — merge gate satisfied, every AC checkbox actually true — is made by a fresh agent reading state it did not produce. An agent that spent an hour building something is the worst possible judge of whether its own acceptance criteria are met; it has every reason to read its own work generously. Handing the gate to a separate agent is a structural check, not a token-budget artifact, and it is the same reasoning that makes a self-review never satisfy the merge gate.

**The finding that actually answers #776's question:** the phase count is **orthogonal** to the routing decision. Phases govern *how* an inline pipeline runs once it starts. The fit bar governs *whether* work runs inline at all. No issue was ever routed to a separate thread because there were three phases instead of one — it was routed because criterion 1 called it large. Consolidating phases would therefore not have recovered a single bumped issue, while costing both properties above.

**Consequence for FU-2.** The A/B/C confirmation no longer rests on the 32K number. FU-2 stays open and still worth measuring — it would tell us whether small PRs could skip a phase for latency reasons — but it is no longer blocking a decision, and no longer the sole load-bearing justification for the split.

**Options considered and rejected:**

- **Consolidate phases for small PRs** (the harness audit's conditional FU-2 recommendation). Requires the unmeasured runtime fact. Even with it, ground 1 above still argues against folding an unbounded reviewer wait into the implementing agent.
- **Free a pipeline slot at `merge_ready` instead of `merged`/`blocked`.** Breaks AC4's queue coherence: a pipeline parked at `merge_ready` still has Phase C ahead, so freeing its slot pushes real in-flight work past the ceiling and over the CodeRabbit throughput budget the ceiling exists to protect.

---

## Phase 4 — Ceiling and queue coherence (AC4)

**Decision: keep the 3–4 concurrent-pipeline ceiling unchanged.** It is **CodeRabbit-throughput-bound, not capability-bound** — roughly 8 reviews/hour shared across every open PR (`cr-rate-limits.md`) — and author-scoped per [#732](https://github.com/auerbachb/claude-code-config/issues/732), so a collaborator's PRs never consume a slot. Raising the fit bar puts *more* work inline, which makes reviewer throughput the binding bottleneck sooner. That is an argument for leaving the ceiling alone, not for raising it: the ceiling is what keeps a widened fit bar from simply converting thread sprawl into review-queue starvation.

### Defect found: the shared chip gate overflowed past-ceiling work into threads

`chip-launching.md`'s "PM-context inline gate" listed three conditions — PM context, free slot, subagent-fit — and offered a separate-thread chip when **any** was false, naming "a full pipeline" as one of them. So subagent-fit work arriving when all slots were busy was routed to a **standalone thread**, which is exactly the overflow AC4 forbids. The gate's own "prefer inline (or queued behind the ceiling)" branch was unreachable for that case, since a free slot was a precondition for reaching it.

`/wave` Step 6 already had this right (`SLOTS <= 0` → "stop; do not offer a single chip"), so the shared gate was the outlier, and `/issue-maker` Step 9c and `/start-issue` Step 7 had inherited the defect by repeating "free inline slot" as a chip precondition.

**Fix — split the conditions by what they actually decide:**

- **PM context + subagent-fit** decide *inline vs separate thread*.
- **Free slot** decides only *run now vs queue inline*. It never routes work out.

Past-ceiling subagent-fit work now **queues inline**. Only a named Step 4 disqualifier routes to a thread. Slot semantics are otherwise unchanged: a pipeline frees its slot only on a terminal `merged` or `blocked`, never at `merge_ready`.

### AC2 enforcement

Every separate-thread verdict must **name which of the three criteria fired and why**. The previous rule required a rationale only for offers made *while an inline slot was free*, which left the most common bump — "slots are full" — unexplained and unaudited. It now applies to every offer, on every surface. A verdict that cannot name a criterion is not a valid verdict; the issue queues inline instead.

---

## What NOT to change

- **The 32K decomposition guard and the exhaustion protocol.** Untouched, per the harness audit's warning. This work narrows the *routing criterion* that cited the number; it does not relax the guard, and FU-2 is still the way to settle the number itself.
- **The 3–4 ceiling.** CodeRabbit-throughput-bound and author-scoped. Widening the fit bar is a reason to hold it, not to raise it.
- **`merged`/`blocked`-only slot release.** Freeing at `merge_ready` double-counts a pipeline that still has Phase C ahead.
- **The chip execution boundary.** Offering is never launching; the user's click remains the only launch path (`chip-launching.md`, NON-NEGOTIABLE). Everything here changes which recommendation is surfaced, never who starts it.
- **Standalone (non-PM) chip behavior.** With no PM thread there is no inline pipeline to use, so a chip is still the correct hand-off. Do not suppress it.
- **Tier ≠ routing.** Any tier runs inline. Do not re-couple them.

---

## Follow-ups

- **FU-2 (inherited, still open)** — [harness-model-audit-2026-06.md](harness-model-audit-2026-06.md) FU-2: measure the real per-turn output ceiling. **Downgraded from blocking to informational** by this recalibration: the fit bar and the A/B/C decision no longer depend on the answer. Still worth measuring for latency tuning (could a small PR skip a phase?) and to replace an unverified number in an auto-loaded rule.
- **Telemetry** — [#710](https://github.com/auerbachb/claude-code-config/issues/710) is the measurement that would show whether this change actually worked. The target metric is **threads opened per merged PR**; it should fall. Until #710 lands, that claim is untested, and this document should not be read as evidence the change succeeded — only that the reasoning behind it is sound.

**Next cadence:** re-check once #710 exists, and after enough PM sessions accumulate to see whether the narrowed criterion 1 changed real routing behavior or just the words describing it.

---

## Coverage vs issue #776 acceptance criteria

| #776 AC | How this addresses it |
|---------|----------------------|
| Re-derive the too-big test from current capability; justify each surviving criterion | Phase 2 — all three re-derived with per-criterion reasoning against the Phase 1 baseline; criterion 1 narrowed, 2 and 3 confirmed as non-capability concerns. |
| A separate-thread verdict must name a concrete disqualifier | Phase 4 "AC2 enforcement" — mandatory on every offer, encoded in `/subagent` Step 4 and `chip-launching.md`; the not-a-disqualifier list is explicit. |
| Evaluate A/B/C against the one-thread goal; confirm or refactor, with recorded reasoning | Phase 3 — confirmed on two capability-independent grounds; rejected options recorded; phase count shown to be orthogonal to routing. |
| Ceiling and queue stay coherent; past-ceiling work queues inline, never a chip | Phase 4 — ceiling held with rationale; the overflow defect in `chip-launching.md` found and fixed by splitting what the slot check decides. |
| Rule corpus stays within budget | Only `subagent-orchestration.md` is counted, and all rationale is held here where it is free. Corpus grew 15 words (11,957 → 11,972) against a 12,310 cap: the A/B/C pointer and the queue-not-chip clause cost more than the offsetting trims recovered, and bulleting the dense Orchestration block for scannability added the rest. `rule-lint.sh` passes. |

---

## Live-run outcome — Issue #784 (2026-07-30)

**Issue:** [#784](https://github.com/auerbachb/claude-code-config/issues/784) — smoke-test: run a formerly-too-big issue fully inline from a PM thread.

### The run

**Subject:** [Issue #790](https://github.com/auerbachb/claude-code-config/issues/790) — "Compress the auto-loaded rule corpus" / [PR #804](https://github.com/auerbachb/claude-code-config/pull/804). A 17-file change touching `CLAUDE.md` and every `.claude/rules/*.md` file, compressing the corpus from 12,166 to 10,999 words (−1,167 words).

**Why the old criterion would have rejected it.** Criterion 1's old form asked whether the change was a "very large, many-file change — a sweeping migration across many files." A 17-file pass touching `CLAUDE.md` and all 16 rule files is exactly the shape that phrase was read to cover in practice. The named-disqualifier requirement did not yet exist, so the routing would have been made on size and scope alone, with no obligation to articulate why the work couldn't be carried inline. The corpus edit would have gone to a separate coding thread.

**Why the new criterion admitted it.** Criterion 1 now asks whether the work can be carried across sequential subagent turns via the token-exhaustion handoff — whether a replacement agent could pick up from a handoff and continue. For a corpus compression across 17 files, the answer is straightforwardly yes: the file list is its own progress ledger, each file is an independent, self-contained edit, and a replacement agent can read which files were already compressed and which remain. No named disqualifier fired.

**Phase chain and commit record:**

- **Phase A** — commit `be73ad8`: 17-file corpus compression landed in a single agent pass. The ratchet cap was reset (`rule-lint.sh --update-cap`).
- **Phase B** — commit `2ce3fa67`: BugBot (`cursor[bot]`) caught one finding — a semantic deletion: the word "unresolved" had been dropped from the merge-gate stop-polling definition, making "0 threads right now" read as an exit condition when the rule's intent is that it is not. This was a real defect that all four lint checks missed; BugBot caught it on the phase B review pass. Fixed in the second commit. CodeAnt approved on `2ce3fa67`.
- **Phase C** — `/wrap` auto-merged via squash: commit `609452c` landed at 2026-07-30T15:48:47Z. Issue #790 auto-closed at 15:48:49Z. No human turn between Phase B clean and merge.

**Dispatch source (AC1 attestation).** Dispatched inline from the PM thread session on 2026-07-30. The PM-thread origin is attested by the dispatching session (parent orchestrator — the session that ran this pipeline). No `/pm` dispatch comment appears on Issue #790 or PR #804's public GitHub record; this is expected — the dispatch mechanism invokes `/subagent` inline without posting a GitHub artifact. This doc edit is the record.

**No separate coding thread opened.** Confirmed. No `spawn_task` chip and no fallback paste-block was generated for Issue #790 at any dispatch surface.

**Corroborating runs from the same session.** PRs #806, #811, #812, #820, #821, and #822 were dispatched inline from the same PM thread on 2026-07-30 — several touching files in categories (rules-touching, skill-lifecycle) that the old criterion would have treated as "too big." None were routed to a separate coding thread.

### Exhaustion/respawn findings (AC2)

No token exhaustion occurred. Phase A completed in a single agent pass; the token-exhaustion handoff protocol was not invoked.

This is recorded honestly rather than overclaimed. A zero-exhaustion merge confirms the routing decision — the work was decomposable and ran cleanly inline — but it is weaker evidence for the resumability claim than an observed respawn would be. The stronger claim is that *if* a Phase A agent exhausts, the handoff carries state correctly and a replacement continues without duplicating work. This run does not test that path; it demonstrates that the path was not needed.

The resumability path remains covered by the token-exhaustion protocol as designed (`subagent-orchestration.md`, `handoff-files.md`). FU-2 (measuring the real per-turn output ceiling) and [#710](https://github.com/auerbachb/claude-code-config/issues/710) (threads-per-merged-PR telemetry) remain the right instruments for the stronger empirical claims.

### Verdict

**Recalibration confirmed.** Issue #790 / PR #804 demonstrates end-to-end that a 17-file change across the entire rule corpus — work that old criterion 1 would have bumped to a separate thread on scope alone — runs cleanly through the A→B→C inline pipeline, including a BugBot Phase B round that caught a real finding. The recalibration's central claim holds: the routing decision should be made on resumability, not size, and the three-phase pipeline handles large-but-resumable work without a human-visible coding thread.

**No unanticipated failure occurred.** BugBot's Phase B finding was a legitimate semantic deletion, caught and fixed through normal review mechanics. No correction issue is needed.

### Coverage vs Issue #784 acceptance criteria

| #784 AC | Status | Evidence |
|---------|--------|---------|
| One formerly-too-big issue dispatched from a PM thread and carried to merge entirely inline, no separate coding thread opened | **Met** | Issue #790 / PR #804 — 17-file rules change, dispatched inline, A→B→C to squash merge `609452c`. PM-thread origin attested by dispatching session (this doc is the record); not verifiable from public GitHub artifacts alone. |
| Exhaustion/respawn behavior observed and recorded | **Met (zero exhaustion)** | Single Phase A pass; handoff path not exercised. Recorded honestly as weaker evidence for the resumability claim. Stronger evidence awaits FU-2 and Issue #710. |
| Outcome appended to `.claude/reference/too-big-recalibration-2026-07.md` | **Met** | This section. |
| If a phase failed in a way the recalibration did not anticipate, file the correction as its own issue | **Met (N/A)** | BugBot's finding was a legitimate defect caught in normal Phase B review — within what the recalibration anticipated. No correction issue needed. |
