# PM Routing Audit — Thread vs Inline Subagents — July 2026

**Issue(s):** [#701](https://github.com/auerbachb/claude-code-config/issues/701) (investigate why PM still routes work to threads over inline subagents)

**Date:** 2026-07-22

**Related precedent:** [#613](https://github.com/auerbachb/claude-code-config/issues/613) (inline-by-default landed here — this audits why practice still skews to threads and closes the residual gaps); [harness-model-audit-2026-06.md](harness-model-audit-2026-06.md) (the FU-5 outcome-telemetry gap this audit inherits verbatim)

**Current fleet (for model-line context):** Fable 5, Opus 4.8, Sonnet 5, Haiku 4.5.

> **Point-in-time record — one behavior below has since changed.** This audit describes each surface as it stood on 2026-07-22, and is kept as the verification record for #701. Since [#1193](https://github.com/auerbachb/claude-code-config/issues/1193) (2026-08-22), **criterion 3 ("should be split into multiple PRs") no longer routes an issue to a thread** — it is decomposed into an inline increment chain by `/subagent` Step 5.1. Read every "too-big → thread chip" row below as covering criteria 1 and 2 only. Current behavior: `too-big-recalibration-2026-07.md` "Amendment — criterion 3 decomposes".

---

## Why this audit, and why now

[#613](https://github.com/auerbachb/claude-code-config/issues/613) (merged **2026-07-21**) flipped the PM default: issues a PM thread picks up should run **inline** as `A→B→C` subagents the thread manages itself, with a separate coding thread reserved only for work genuinely **too big for a subagent**. The intended payoff was fewer tabs to babysit — one PM thread coordinating everything.

The observed behavior hadn't caught up: a large share of recent Sonnet-tier work looked like it was still being handed out as standalone coding threads. #701 asked for an **effectiveness audit** of the inline-first change before tightening anything: establish ground truth (is the spend actually thread sprawl?), verify #613 is live, then walk every surface that decides "thread vs inline" and make inline the aggressive default everywhere it fits.

This document is **audit-first**. Its tightening changes are deliberately small and are confined to the three non-conforming surfaces; it changes **no** load-bearing rule and does **not** raise the concurrency ceiling.

---

## Headline finding

**The "too many threads" diagnosis is confirmed for the pre-#613 period — and #613 is already working where it is exercised. The residual sprawl is not `/pm` misrouting; it is that most coding work never enters a PM thread at all.** It starts thread-first through `/start-issue` (often from an `/issue-maker` chip), so inline-first routing never gets consulted.

| Question (AC) | Verdict | Basis |
|---------------|---------|-------|
| AC1 — Is recent spend thread sprawl or healthy inline work? | **Sprawl confirmed pre-#613; improving post-#613** | Pre-#613: 118 coding-thread-lifecycle skill calls vs **1** inline (`/subagent`) call. Post-#613: inline share rose to ~16% (31 vs 6), and **5 of 6** post-merge PM sessions ran issues inline. |
| AC2 — Is #613's inline-first routing actually live? | **Yes — deployed and encoded** | `~/.claude/skills-worktree` HEAD == `origin/main` (`ebef5cb`); deployed `pm`/`subagent` copies carry the inline-first + three-criterion too-big + 3–4 queue language. |
| AC3 — Per-surface audit of every thread-vs-inline decision | **Done** (table below) | `/pm`, `/prompt`, `/subagent` conform; `/wave`, `/issue-maker`, `/start-issue` offered chips with no PM-context/slot check. |
| AC4 — Inline the default on every surface; thread offers carry a "too big because X" rationale | **Closed** | New shared **PM-context inline gate** in `chip-launching.md`, referenced by the three gap surfaces. |
| AC5 — Queue-over-spawn when the 3–4 slots are full | **Already satisfied** | `/pm` 3.1/3.4, `/subagent` Step 7, `subagent-orchestration.md` line 66 — no rule-corpus edit needed. |
| AC6 — Follow-ups filed for anything too big to land here | **Done** | FU-1 [#710](https://github.com/auerbachb/claude-code-config/issues/710) (telemetry pipeline / the inherited FU-5 gap); FU-2 [#711](https://github.com/auerbachb/claude-code-config/issues/711) (`/wave` global symlink). |

---

## Phase 1 — Ground truth

### Task 1: Rough spend attribution (threads vs inline)

**Method.** There is **no** spend/thread-type telemetry in this repo (the FU-5 gap from `harness-model-audit-2026-06.md` is still unbuilt). `~/.claude/skill-usage.log` records only `timestamp · skill · session_id` — invocation counts, **not** model tier or token spend. So this is a **proxy for thread count, not Sonnet spend**. Sessions were clustered by `session_id` and classified: a session containing `/pm` or `/wave` is a *PM-orchestration* session; one containing a coding-lifecycle skill (`start-issue`, `fixpr`, `wrap`, `go-on`, `merge`, `babysit-pr`, `merge-conflict`, `admin-merge`) or a standalone `/subagent` is a *coding thread*. Data window: 2026-05-01 → 2026-07-22 (287 entries, 132 sessions), bucketed at the #613 merge date (2026-07-21).

**Findings.**

| Metric | Pre-#613 (≤07-20) | Post-#613 (07-21→) |
|--------|-------------------|--------------------|
| Coding-thread-lifecycle skill calls | **118** | 31 |
| Inline `/subagent` calls | **1** | **6** |
| Inline share of execution calls | ~0.8% | ~16% |
| `/subagent` calls co-located with `/pm`/`/wave` | 0 | 5 of 6 |
| `/start-issue` (new coding thread) | 17 | 8 |
| PM-orchestration sessions | 0 | 6 |

**Reading.** Pre-#613, coding was executed through threads essentially 100% of the time — inline was ~1% of the picture. Post-#613 the inline path is genuinely being used: 5 of the 6 PM sessions since the merge ran their issues inline (`[pm,subagent]`, one also `[pm,pm-clean,subagent,wave]`), and inline rose to ~16% of execution calls. **The mechanism works when PM is the entry point.** But `/start-issue` still fired 8 times post-merge and 18 of 35 post-merge sessions are coding threads — most work still starts thread-first, bypassing PM entirely.

**Caveats (do not over-read):**
- **Proxy, not spend.** The log has no model/token data; inline `pm-worker`/Phase C also run on Sonnet, so raw Sonnet spend cannot separate sprawl from health even in principle. Only FU-1's telemetry pipeline can turn this proxy into a real spend attribution.
- **Invisible inline workers.** Agent-tool subagents spawned by `/subagent` do **not** write their own `skill-usage.log` lines (only Skill-tool calls are logged), so inline phase workers appear only via the parent `/subagent` invocation — the inline share is if anything *understated*.
- **Small post window.** #613 is ~1.5 days old in this data (72 of 287 entries). Post-#613 numbers are **directional**; part of the honest answer is "give the new default more sessions."

### Task 2: #613 deployment liveness

- **Deployed copies match main.** `~/.claude/skills-worktree` is at `ebef5cb`, identical to `origin/main`. Deployed `pm`, `subagent`, `issue-maker`, `start-issue`, `prompt` SKILL.md files are byte-identical to the repo's `main`.
- **Inline-first is encoded.** Deployed `pm/SKILL.md` carries "inline by default" / "too big for any subagent" / "Inline-eligible"; deployed `subagent/SKILL.md` carries the three-criterion "Too Big for Any Subagent" test and the 3–4 queue mechanic.
- **Deployment anomaly (minor, tangential):** `~/.claude/skills/wave` has **no global symlink** — `/wave` resolves only project-locally inside this repo, so it is unavailable from other repos/sessions. This does not affect routing (its one logged use worked in-repo) and is not a code fix (the symlink is a local post-merge op per `skill-symlinks.md`); tracked as **FU-2** so it isn't lost.

---

## Phase 2 — Per-surface routing audit

Each surface's current thread-vs-inline criterion, whether it honors #613, and the gap.

| Surface | Current thread-vs-inline criterion | Honors #613? | Gap |
|---------|-----------------------------------|--------------|-----|
| **`/pm`** (Step 3.1/3.4) | Partitions selected issues with `/subagent` Step 4's three-criterion too-big test; runs inline-eligible issues via `A→B→C`; thread chip **only** for too-big, each with a one-line reason; queues beyond the 3–4 ceiling. | **Yes** | None. Canonical implementation of #613. |
| **`/subagent`** (Steps 4–7) | Three-criterion too-big test decides inline vs route-to-thread; inline is default of any tier; 3–4 concurrent pipelines, queue the rest. | **Yes** | None. Owns the too-big test the others reuse. |
| **`/prompt`** (Step 5.5, Path B) | In PM auto-detect, partitions subagent-eligible (inline) vs too-big (thread prompt) via the same three criteria; one-line too-big reason. Path A (explicit args) always prints full blocks — but that is a user *asking for a prompt*, not a routing default. | **Yes** | None (Path A is user-directed, not a routing decision). |
| **`/wave`** (Step 7) | Offers the whole independent set as chips; caps by `IN_FLIGHT` vs the 3–4 ceiling; surfaces `/subagent` as an inline alternative only as a trailing aside. | **Partial** | Chips are the default framing even inside a PM thread with free inline slots; inline is buried. |
| **`/issue-maker`** (Step 9c) | Offers a coding chip **unconditionally** on every created issue (points at `/start-issue`). No PM-context/slot check. | **No** | Fresh subagent-fit issue in an active PM context is offered a standalone thread rather than flowed into the inline queue. (Rarely fires — capture mode refuses in-thread orchestration — but the leak is real.) |
| **`/start-issue`** (Step 7) | Offers a coding chip (or prints a ready-to-code block) **unconditionally** after worktree setup. No PM-context/slot check. | **No** | Same leak as `/issue-maker`: within a PM session with a free slot, subagent-fit work still gets a separate-thread chip. |

**Why the three gap surfaces predate the fix:** `/pm`, `/prompt`, `/subagent` all run the too-big *partition* before deciding thread-vs-inline. The three chip surfaces were written before #613 and offer a chip as an unconditional hand-off — they never consult PM context or inline-slot availability, so even a user sitting in a PM thread with three free slots gets a new-tab chip.

---

## Phase 3 — What changed

### The shared PM-context inline gate (`chip-launching.md`)

A single canonical gate, defined once in the shared chip contract and referenced by the three gap surfaces (DRY — no divergent per-skill copies). **As shipped by #701** — partly superseded, see the note at the end of this section. Before offering a **standalone thread** chip for subagent-fit work, a surface checks for **live PM context with a free inline slot**:

- **PM context** — a `## Active Work` table is present (the canonical home, `/pm` 3.2); its non-terminal rows are `IN_FLIGHT`.
- **Free slot** — `IN_FLIGHT` is below the 3–4 concurrent-pipeline ceiling (`subagent-orchestration.md`, derived from CR throughput in `cr-rate-limits.md`).
- **Subagent-fit** — the issue is not too big by `/subagent` Step 4's three criteria.

When all three hold → **prefer inline**: recommend `/subagent #N` in the PM thread (or queue behind the ceiling) rather than a chip. When any is false — no PM context (the common standalone case), pipeline full, or too big — offer the chip as before, and **any separate-thread offer made while an inline slot was free carries a one-line "too big because X" rationale**.

> **Superseded in part by [#776](https://github.com/auerbachb/claude-code-config/issues/776) (2026-07-28).** Treating "pipeline full" as a reason to offer a chip was a defect: it pushed past-ceiling *subagent-fit* work into a separate thread. The gate is now **two** routing conditions (PM context + subagent-fit); slot availability decides only run-now vs **queue inline**, never inline-vs-thread. Every separate-thread offer must state its reason, and the too-big case must name which Step 4 criterion fired — not just offers made while a slot was free. The standalone (no-PM-context) case names *that* as its reason and needs no too-big criterion, since no inline path exists to prefer. The rest of this section stands as the #701 record. See [too-big-recalibration-2026-07.md](too-big-recalibration-2026-07.md); `chip-launching.md` carries the live wording.

**The execution boundary is untouched.** The gate never launches anything — it only chooses which *recommendation* to surface. The user's action (running `/subagent`, or clicking a chip) remains the only execution path (`chip-launching.md` "execution boundary", NON-NEGOTIABLE).

**Honest scope of the fix.** The gate closes the in-PM-session leak, which is correct and necessary. It is **not** sufficient to end sprawl on its own: the data shows most work enters thread-first via `/start-issue` with *no* PM session, where a chip is the right hand-off (there is no inline pipeline to use). Ending that residual is a workflow-adoption matter (make PM-first the habit) plus **FU-1** telemetry to actually measure spend rather than proxy it.

### Queue-over-spawn (AC5) — verified, no change needed

`/pm` (3.1 "queue the rest… starting a queued pipeline as each running one merges or blocks"; 3.4 "Refill inline slots first"), `/subagent` (Step 7 parallel-execution rules), and `subagent-orchestration.md` line 66 ("The same 3-4 ceiling is the inline A→B→C pipeline cap for `/pm` and `/subagent` — queue issues beyond it") already encode queue-over-spawn with the ceiling's CR-throughput basis ("at 7+ CR reviews/hour expect Greptile fallback"); `/wave` Step 6 carries the explicit `cr-rate-limits.md` citation. **No rule-corpus edit was made** — adding a redundant cross-reference to the auto-loaded corpus (11,373 words against an 11,671 ratchet cap) would duplicate text that already exists.

---

## What NOT to change

- **The 3–4 concurrent-pipeline ceiling.** Its binding constraint is CodeRabbit review throughput (~8 reviews/hour shared across all open PRs, `cr-rate-limits.md`), **not** subagent slots — chip-launched threads and inline pipelines draw from the same budget. Raising it is a reviewed rule edit in `subagent-orchestration.md`, explicitly out of scope for #701.
- **The chip execution boundary.** "Skills never auto-launch; the user's click is the only launch path" is non-negotiable (`chip-launching.md`). The gate re-frames the *recommendation*; it must never be read as license to spawn.
- **Model tier ≠ routing.** Tier (Heavy/Standard/Light) does not gate inline vs thread — `/subagent` Step 4 is explicit that any tier runs inline. Do not re-couple them.
- **Standalone chip behavior.** Outside PM context, `/start-issue` and `/issue-maker` chips are the correct hand-off and stay unchanged — do not suppress them.

---

## Follow-up issues

### FU-1 — Real spend/thread-type telemetry pipeline — [#710](https://github.com/auerbachb/claude-code-config/issues/710) *(infrastructure; inherits the FU-5 gap from harness-model-audit-2026-06.md)*

- **Problem:** No pipeline attributes token/Sonnet spend to threads vs inline subagents. `skill-usage.log` records invocation counts only, so every attribution here is a *thread-count proxy*, not a spend measurement (AC1 could only be answered "even roughly").
- **AC:** Lightweight capture of per-session model tier and (where available) token spend, tagged thread vs inline; a `*-report.sh` that summarizes the thread-vs-inline split; this audit's AC1 re-runnable against real spend rather than a proxy.
- **Status (2026-08-12):** **PARTIAL** — infrastructure closed by PR implementing Issue #710. Two hooks installed: `spend-session-tracker.sh` (SessionStart — tags new standalone threads) and `spend-subagent-tracker.sh` (SubagentStop — tags each inline Agent-tool subagent). Append-only TSV log at `~/.claude/spend-telemetry.log`; report via `bash .claude/scripts/spend-telemetry-report.sh`. Provides execution-type attribution and model-tier distribution; comparative thread-vs-inline token spend requires a thread token source (SessionStart does not expose usage data). Full schema, reliability caveats, and AC1 re-run methodology: `.claude/reference/spend-telemetry-pipeline.md`.

#### Re-running AC1 against real spend (post-FU-1)

To replace the proxy-based AC1 table with real execution-type attribution:

```bash
bash .claude/scripts/spend-telemetry-report.sh --days 30
```

Read the `inline`/`thread` row split in the "All-time thread-vs-inline breakdown" table. In a healthy post-#613 regime the inline row should grow over time and `pm-worker`/`phase-*` agent types should dominate the inline inventory. Cross-validate with `skill-usage-report.sh` for the same window (which shows `/pm`, `/subagent`, `/start-issue` invocation counts). Full methodology: `.claude/reference/spend-telemetry-pipeline.md` §"Re-running AC1 from pm-routing-audit-2026-07.md against real spend".

### FU-2 — `/wave` missing its global skill symlink — [#711](https://github.com/auerbachb/claude-code-config/issues/711) *(local deploy hygiene)*

- **Problem:** `~/.claude/skills/wave` is absent, so `/wave` is unavailable outside this repo (Task 2 anomaly). Per `skill-symlinks.md` every skill should be symlinked through the skills-worktree.
- **AC:** `~/.claude/skills/wave -> ~/.claude/skills-worktree/.claude/skills/wave` exists and resolves; `ls -la ~/.claude/skills/` shows it alongside the others. (Local op, not a repo code change — filed so it isn't dropped.)

**Next cadence:** re-run this audit once FU-1's telemetry exists (real spend attribution) and after ~2–4 weeks of post-#613 PM sessions accumulate, to confirm the inline share keeps climbing and the gate measurably cut chip-launched threads within PM sessions.

---

## Audit coverage vs issue #701 acceptance criteria

| #701 AC | How this audit addresses it |
|---------|-----------------------------|
| Ground truth: attribute recent spend to threads vs inline | Phase 1 Task 1 — thread-count proxy over `skill-usage.log`, bucketed at the #613 merge, with explicit "proxy not spend" caveats. Diagnosis confirmed pre-#613, improving post. |
| Verify #613 is actually live | Phase 1 Task 2 — deployed copies == `origin/main`; inline-first language encoded; `/wave` symlink anomaly noted. |
| Audit every thread-vs-inline surface | Phase 2 per-surface table for `/pm`, `/prompt`, `/subagent`, `/wave`, `/issue-maker`, `/start-issue`. |
| Tighten routing; inline default; "too big because X" on thread offers | Phase 3 — shared PM-context inline gate in `chip-launching.md`, referenced by the three gap surfaces; one-line rationale required on slot-available thread offers. *(#776 later extended the rationale to every thread offer and removed slot state from the routing decision entirely.)* |
| Queue-over-spawn when slots full | AC5 — verified already satisfied in `/pm`, `/subagent`, `subagent-orchestration.md`; no rule change needed. |
| Follow-ups filed for out-of-scope work | FU-1 [#710](https://github.com/auerbachb/claude-code-config/issues/710) (telemetry), FU-2 [#711](https://github.com/auerbachb/claude-code-config/issues/711) (`/wave` symlink). |
