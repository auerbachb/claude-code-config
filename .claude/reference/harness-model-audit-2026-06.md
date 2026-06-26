# Harness Model-Capability Audit — June 2026

**Issue:** [#49](https://github.com/auerbachb/claude-code-config/issues/49) (audit harness components against current model capabilities)

**Date:** 2026-06-25

**Related precedent:** [repo-audit-2026-05.md](repo-audit-2026-05.md) (#413–#415, finding #5 "Model string hygiene"), [ai-review-tool-audit-2026-04.md](ai-review-tool-audit-2026-04.md) (#368 / #377)

**Current fleet (assumed authoritative for this audit):** Opus 4.8, Fable 5, Sonnet 4.6, Haiku 4.5 — all 1M-context.

---

## Why this audit, and why now

Issue #49 was filed (inspired by Anthropic's *Harness Design for Long-Running AI Agent Applications*) on the premise that **every harness component encodes an assumption about what the model can't do on its own**, and that as models improve some load-bearing guards become unnecessary overhead. It deferred implementation to "late April 2026" to collect a month of usage data before changing anything.

We are now past that window (June 2026). This document is a **capability-based static audit** of the harness against the current fleet. It is deliberately **audit-only**: it changes no load-bearing rule. Each finding is classified as **Already addressed**, **Stale — needs runtime verification**, or **Still earning its keep**, and the genuinely actionable items are written up as ready-to-file follow-up issues at the end.

### Scope note on the original "collect telemetry" plan

Issue #49's AC assumed a month of runtime telemetry (CR response times, false-clean rates, subagent token usage, Phase A/B/C completion rates, Greptile trigger counts). The repo has **no telemetry pipeline that captures those metrics** — `~/.claude/script-usage.log` and `skill-usage-report.sh` track *invocation counts*, not the outcome metrics #49 needs. Building that pipeline is itself a follow-up (FU-5 below). In its absence, this audit substitutes **static evidence**: what each guard's number/threshold currently is, when it last changed in git history, and whether the failure mode it guards against is plausible on the current fleet.

---

## Headline finding

**Most of the specific guards #49 named have already been recalibrated** in the months since it was filed — the harness has not stood still. Of the five components #49 flagged:

| #49 component | Status today | Evidence |
|---------------|--------------|----------|
| 1. 2-clean-CR-passes requirement | **Already relaxed to 1** | `cr-local-review.md` "Exit criteria: One clean local review"; gate is "1 explicit CodeRabbit (or CodeAnt) APPROVED review on current HEAD SHA" (`cr-merge-gate.md`). No "2 passes" anywhere. |
| 2. Mandatory Phase A/B/C decomposition | **Partially relaxed** | `/subagent` runs Light/Quick issues inline in one thread; full A/B/C is reserved for non-trivial PRs. The *rationale* still cites the 32K limit (see Finding C). |
| 3. 7-minute CR timeout | **Already retuned to 12 min** | `escalate-review.sh` uses `AGE_SECONDS > 720` (12 min), plus a check-run-completion short-circuit. No 7-min/420 s value survives. |
| 4. Full rule blob in every subagent prompt | **Already replaced** | `.claude/agents/*.md` are self-contained; full-rule injection is now an explicit *fallback* "if `.claude/agents/` is unavailable" (`subagent-orchestration.md`). |
| 5. Light path for trivial PRs | **Partially present** | `/prompt` Step 5.5 partitions subagent-eligible issues (file_count 0–1, ac_count ≤3) to `/subagent`; the *review* loop is not yet shortened for trivial PRs (see Finding E). |

So #49 is largely **already satisfied by incremental work**, not an open greenfield audit. The two remaining stale assumptions worth acting on are the **32K output-token limit** (Finding C) and **Fable 5 absence from model selection** (Finding A). Everything else is either done or genuinely needs data.

---

## Component-by-component findings

### Finding A — Model selection: Fable 5 is in the fleet but absent from selection policy *(Stale — low risk to fix)*

`CLAUDE.md` ("Rule File Size Guidelines") describes the "current 1M-token fleet (Opus 4.8, Fable 5, Sonnet 4.6)". But **no model-selection surface mentions Fable 5**:

- `subagent-orchestration.md` "Model Selection": aliases resolve to `opus`→Opus 4.8, `sonnet`→Sonnet 4.6, `haiku`→Haiku 4.5.
- `agents/README.md`: same three aliases; per-phase table is opus/opus/sonnet/sonnet/sonnet.
- `prompt/SKILL.md` "Model Lineup": Sonnet 4.6, Opus 4.8, Opus 4.8 (1M), Haiku 4.5 — Fable 5 not listed.

These surfaces are also **internally inconsistent about Haiku 4.5 vs Fable 5**: `CLAUDE.md`'s fleet parenthetical lists Fable 5 and omits Haiku 4.5; the selection docs list Haiku 4.5 and omit Fable 5.

**Why audit-only, not fixed inline:** correctly *slotting* Fable 5 into the spawn defaults or the `/prompt` decision tree requires knowing its capability/price positioning (is it a faster/cheaper coding tier? a reasoning peer to Opus? a Haiku replacement?). That is a product fact this audit cannot verify, and guessing risks mis-routing every subagent spawn. Tracked as **FU-1** (reconcile the fleet across all selection surfaces and define Fable 5's tier).

### Finding B — 2-clean-CR-passes (#49 component 1): already gone *(Already addressed)*

There is no "two clean passes" requirement anywhere in the current harness. Local review exits on **one** clean `coderabbit review --agent` pass (`cr-local-review.md` "Exit criteria"). The GitHub merge gate requires **one** explicit CodeRabbit (or CodeAnt) `APPROVED` review on the current HEAD SHA, with SHA-freshness re-checking each cycle (`cr-merge-gate.md` / `merge-gate.sh`). The false-clean failure mode #49 worried about is handled structurally by SHA-freshness, not by a redundant second pass. **No action.**

### Finding C — 32K output-token limit (#49 components 2 & 4): the one genuinely stale, load-bearing number *(Stale — needs runtime verification)*

`subagent-orchestration.md` asserts as fact:

> "Subagents have a 32K output token limit." … "The 32K limit is binding. Give each subagent one phase with explicit exit criteria."

and `graphite-stacked-prs-research-2026-05.md` repeats "Each subagent has a 32K output-token limit". This single number is the load-bearing justification for **mandatory Phase A/B/C decomposition** — i.e., #49 component 2. If the current fleet's per-turn output budget is materially larger, then small PRs (<50 lines, <5 findings) could run the full fix→review→merge lifecycle in a single agent without exhaustion, removing a whole class of handoff/respawn overhead.

**Why audit-only, not fixed inline:** the actual per-turn output ceiling for Opus 4.8 / Fable 5 / Sonnet 4.6 in this Claude Code build is a **runtime fact this static audit cannot measure**. Editing the number — or removing the decomposition guard — on a guess would be exactly the unverified change to a load-bearing guard the May audit's "things NOT to change" warns against. The correct move is a measured spike. Tracked as **FU-2** (verify current output budget; if >2× the 32K assumption, relax mandatory decomposition for small PRs and update both files).

### Finding D — 7-minute CR timeout (#49 component 3): already retuned to 12 min *(Already addressed)*

The "7-minute" figure in #49 no longer exists. `escalate-review.sh` escalates off CodeRabbit only when `AGE_SECONDS > 720` (12 minutes) **and** there's no CR review on the current HEAD, with a check-run-`completed` short-circuit that exits the wait early regardless of elapsed time. BugBot grace is a separate 600 s (10 min) window. `go-on/SKILL.md` and `subagent/SKILL.md` describe the same "12-minute timeout, clean completion short-circuits" behavior. The timeout has been calibrated *up* from #49's premise, not left conservative. The remaining open question is empirical (is 12 min well-matched to observed CR p95?), which needs data — tracked as **FU-3**.

### Finding E — Light path for trivial PRs (#49 component 5): selection-side done, review-side open *(Partially addressed)*

The *work-routing* light path exists: `/prompt` Step 5.5 partitions issues with `file_count` 0–1 and `ac_count` ≤3 into subagent candidates, and `/subagent` runs them inline without spinning up a full coding thread. What does **not** yet exist is a shortened *review* path: a single-file, <20-line change still goes through the same CR→BugBot→Greptile gate as a 500-line change. Whether trivial diffs should be allowed to merge on self-review alone is a policy/risk decision (it weakens the merge gate), not a model-capability fact. Tracked as **FU-4** (decide whether a "trivial diff" class may exit on self-review, and if so define the size/line gate).

### Finding F — Scripts & skills: no other model-version calibration found *(Clean)*

A sweep of `.claude/scripts/*` and `.claude/skills/*` for model-version strings, token ceilings, and clean-pass counts found:

- `complexity-score.sh` uses `FILE_WEIGHT=5`, explicitly documented as a **repo calibration** (merged-PR sample), overridable via `pm-config.md`/env — not a model-capability assumption.
- `greptile-budget.sh` enforces a **daily Greptile budget** — a vendor-cost guard, not a model guard.
- Scheduling scripts (`workday.sh`, `off-peak-minute.sh`, the silence-watchdog set) match the model-name grep only on substrings like `min`/`claude` in paths; none encode model capability.
- Skill clean-pass language is uniformly "one clean pass" (`pm`, `go-on`, `subagent`, `prompt`) — consistent with Finding B.

No inline-fixable model-calibration drift in scripts/skills beyond Findings A and C.

---

## Proposed follow-up issues

> `gh` is read-only in the audit environment, so these are written as ready-to-file specs rather than opened directly. Each is independently shippable.

### FU-1 — Reconcile model fleet across all selection surfaces; define Fable 5's tier *(small; touches CLAUDE.md + rules + skill → Heavy)*

- **Problem:** Fable 5 appears in `CLAUDE.md` but in no selection surface; Haiku 4.5 appears in selection surfaces but not the `CLAUDE.md` fleet parenthetical (Finding A).
- **AC:** All of `CLAUDE.md`, `subagent-orchestration.md`, `agents/README.md`, and `prompt/SKILL.md` list the same fleet (Opus 4.8, Fable 5, Sonnet 4.6, Haiku 4.5); Fable 5 has a documented tier and either a spawn default or an explicit "not used for spawns, and why"; alias-resolution note updated.

### FU-2 — Verify current subagent output budget; relax mandatory decomposition if warranted *(spike + rules)*

- **Problem:** The "32K output token limit" justifying mandatory Phase A/B/C may be stale on the current fleet (Finding C).
- **AC:** Measure the real per-turn output ceiling for the spawn-tier models; record the number + method; if it is materially larger than 32K, allow small PRs (<50 lines, <5 findings) to run the lifecycle in a single agent and update `subagent-orchestration.md` + `graphite-stacked-prs-research-2026-05.md`; otherwise annotate both with the verified current number.

### FU-3 — Calibrate the 12-minute CR escalation timeout against observed response times *(data + script)*

- **Problem:** 720 s is currently a guess, not a measured p95 (Finding D).
- **AC:** Capture CR first-response/approval latencies over a usage window; if p95 differs materially from 12 min, retune the `escalate-review.sh` threshold and document the basis.

### FU-4 — Decide on a shortened review path for trivial diffs *(policy + rules)*

- **Problem:** Single-file <20-line changes pay the full review-gate cost (Finding E).
- **AC:** Decision recorded (yes/no) on whether a "trivial diff" class may exit on self-review; if yes, define the line/file gate and update `cr-merge-gate.md`; if no, record the risk rationale so #49 component 5 is closed deliberately.

### FU-5 — Add the outcome-telemetry pipeline #49 originally assumed *(infrastructure)*

- **Problem:** No pipeline captures CR response times, false-clean rates, subagent token usage, or Phase completion rates, so capability audits stay static (Scope note above).
- **AC:** Lightweight capture of those metrics (extend `session-state`/usage logs); a `*-report.sh` that summarizes them; this audit re-runnable against real data.

---

## What NOT to change (carried forward from repo-audit-2026-05)

- **Merge-gate semantics** — explicit CR approval on current HEAD, BugBot/Greptile fallbacks, CI-before-merge. Finding E's trivial-diff path must not erode this without an explicit, recorded decision (FU-4).
- **BugBot trigger strategy** — unreliable auto-trigger is a known production pattern (memory note); do not "simplify".
- **The 32K decomposition guard** until FU-2 measures the real ceiling — relaxing it on a guess risks mid-task exhaustion with no handoff.

---

## Audit coverage vs issue #49 acceptance criteria

| #49 AC | How this audit addresses it |
|--------|-----------------------------|
| Define metrics to track per component | Metrics named per component in Findings B–E; pipeline to capture them specified in FU-5. |
| Collect 1 month of baseline data | Not possible without FU-5 (no telemetry pipeline exists); substituted with static evidence (current thresholds + git-history recency + capability plausibility). Gap recorded, not glossed. |
| Analyze data, identify simplifiable components | Headline-finding table + Findings B–F: components 1, 3, 4 already simplified; component 2 (32K) is the live candidate; component 5 partially done. |
| Propose specific rule changes | FU-1…FU-4 are concrete, scoped change proposals. |
| Implement changes + monitor for regressions | Deferred by design — implementation gated on FU-2's measurement and FU-1's product input; this audit intentionally changes no load-bearing rule. |
