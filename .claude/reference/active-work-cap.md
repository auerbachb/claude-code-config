# Repo-Wide Active-Work Cap — Derivation & Mechanism

> Reference material for `.claude/rules/subagent-orchestration.md` ("Ceiling") and `.claude/reference/chip-launching.md` ("Repo-wide active-work cap"). Not auto-loaded. Issue #1191.
>
> Resolver: `.claude/scripts/active-work-cap.sh` — sole owner of the default and the counting rules. Full contract: `active-work-cap.sh --help`.

## The hole this closes

Inside one orchestration thread, concurrency was already bounded: 3–4 active pipelines (`subagent-orchestration.md`). That ceiling is **per thread**. Once work fans out across separate coding threads nothing counted the total, and a chip emitter with no PM context had, in `chip-launching.md`'s own words, no in-flight figure to gate on — so it offered one chip per issue with nothing to count against.

The 2026-08-18 consulting-websites session ended with roughly twenty threads simultaneously active on one repo. Twenty was observably too many; ten was tolerable; **no number existed anywhere in the system**.

This document derives that number and records why it is what it is, so the next person to move the knob moves it against evidence rather than instinct.

## The input everyone had was wrong

Every prior statement of the ceiling — this repo's rules, `/wave` Step 6's comment, and the original #1191 issue body — rests on **~8 CodeRabbit reviews/hour**. The 2026-08-21 review-stack realignment retracted it. Per `pricing-matrix.md` §CodeRabbit and `cr-rate-limits.md`, dashboard-confirmed in #1204:

- CodeRabbit Pro is **5 PR reviews per developer per hour** — not ~8, and not account-wide.
- That allowance is degraded further by a **Fair Usage table keyed to trailing-7-day volume, per developer identity**: 0–29 → 5/hr, 30–39 → 4/hr, 40–49 → 3/hr, 50–59 → 2/hr, 60–69 → 1/hr one-at-a-time, 90+ → 1/hr one-at-a-time.
- The `~8` that survives in `cr-review-hourly.sh` is **our local pacing proxy and nothing else** — deliberately kept, explicitly not CodeRabbit's meter.

Measured over 2026-07-22 → 2026-08-21 (244 PRs): **196 of 290 reviews rate-limited (68%)**, average wait **87.4 hours**, **36% of blocked PRs merged unreviewed**, and CodeRabbit substantively reviewed **53 of 244 PRs (22%)**.

The matrix names the cause, and it is exactly the failure this cap exists to prevent: **burst concurrency** — many PRs opened by one author inside one hour, with a queue that then backs up for days. The measurement invalidates the old number while endorsing the premise.

Because the count is author-scoped (#732) and CodeRabbit's limit is per-developer, **one developer's 5/hr is the budget the cap is sized against**.

## Three cost terms

Let `k` be the number of simultaneously active units of work on one repo.

### Term 1 — each PR's share of the hourly allowance

At `k` concurrent PRs each receives `5/k` reviews per hour.

| k | 3 | 4 | **5** | 6 | 8 | 10 | 20 |
|---|---|---|---|---|---|---|---|
| review rounds/hour/PR | 1.67 | 1.25 | **1.00** | 0.83 | 0.63 | 0.50 | 0.25 |
| interval between rounds | 36m | 48m | **60m** | 72m | 96m | 2h | 4h |

The original test — "beyond ~8 active PRs a PR cannot even get one review round per hour" — is just `k > reviews/hour`. Run against the measured 5/hr it fires at **k = 5**.

### Term 2 — rebase churn grows with k²

Under branch protection requiring up-to-date branches, every squash-merge flips the other `k−1` PRs to `BEHIND`. Turning over all `k` costs `k(k−1)/2` rebases worst case:

| k | 4 | 5 | 6 | 8 | 10 | 20 |
|---|---|---|---|---|---|---|
| worst-case rebases per full turnover | 6 | 10 | 15 | 28 | 45 | **190** |

The churn is not merely wall-clock. **Each rebase force-push consumes a CodeRabbit review of its own**, so churn competes directly with productive review for the same scarce budget. At `r = 2` productive rounds per PR, total consumption to turn over `k` PRs is `2k + k(k−1)/2`, of which rebases are `(k−1)/(k+3)`:

| k | 4 | **5** | 6 | 8 | 10 | 20 |
|---|---|---|---|---|---|---|
| share of CR budget spent re-reviewing rebases | 43% | **50%** | 56% | 64% | 69% | 83% |

**k = 5 is parity** — half the budget goes to re-reviewing rebases rather than reviewing new work. The k=20 figure of 83% sits close to the 68% block rate measured at roughly that concurrency; the two are independent, so the agreement is corroboration rather than coincidence.

### Term 3 — Fair Usage turns the cost into a feedback loop

This term did not exist in the old derivation, because the old derivation modelled a flat 8/hr with no volume degradation. It is the decisive one.

Reviews consumed per PR is `2 + (k−1)/2`. Concurrency therefore inflates *total weekly volume*, and the Fair Usage table responds by **cutting the hourly allowance itself**. Staying inside the top band (under 30 reviews per trailing 7 days, where the allowance is a full 5/hr):

| k | 3 | 4 | 5 | 6 | 8 | 10 | 20 |
|---|---|---|---|---|---|---|---|
| CR reviews consumed per PR | 3.0 | 3.5 | 4.0 | 4.5 | 5.5 | 6.5 | 11.5 |
| **sustainable PRs/week at full allowance** | 10.0 | 8.6 | 7.5 | 6.7 | 5.5 | 4.6 | **2.6** |

**Past the working set, concurrency lowers sustainable throughput monotonically.** k=4 sustains 8.6 PRs/week; k=20 sustains 2.6 — roughly a third. Raising `k` does not buy parallelism. It buys rebases, which consume the budget that would have reviewed new work, after which the Fair Usage table cuts the budget in response.

This is the arithmetic behind the posture that throughput comes from **refill**, not simultaneity (`continuous-work-posture.md`, #823): a full board that replenishes as PRs merge reaches twenty issues a day; twenty parallel threads do not. Overlap-aware anchor/follower batching (`merge-sequencing.md`, #756) attacks the same k² term from the other side, by removing rebases rather than by removing concurrency — the two are complements.

### Term 4 — monitoring load

Not quantified as precisely, and it does not need to be. Every active pipeline emits a user-visible message at least every 5 minutes (`CLAUDE.md` #3). At k=20 that is a message every 15 seconds, across twenty tabs. The 2026-08-18 session is the evidence: twenty was observably too many, ten tolerable.

## Landing the number

Two independent tests fire at the same place:

- **k = 5** is where each PR stops getting one review round per hour (Term 1).
- **k = 5** is where rebase re-review reaches parity with productive review (Term 2).

The **working set stays 3–4**, unchanged and still CodeRabbit-throughput-bound — that is the target concurrency, not the limit.

A hard cap of exactly 5 would leave a single slot above a 4-pipeline working set, so it would bind during ordinary operation. A backstop that fires constantly is a nuisance rather than a backstop, and one that is routinely in the way gets raised for the wrong reason.

> **Default `ACTIVE_WORK_CAP=6`** — the k=5 answer plus one slot of transient headroom, at 56% churn and 0.83 review rounds/hour/PR. **Configurable range [1, 10]**, the upper bound being the operator's stated tolerance from the 2026-08-18 session.

**Why 8 is not carried forward.** The originally proposed 8 had exactly one derivation: `8 reviews/hour ÷ 1 round per PR`. The 8 has been retracted. Re-running that same test on the measured 5/hr yields 5, and 6 is that answer plus operating headroom. Keeping 8 would mean keeping a number whose sole justification no longer exists.

## What the cap protects — coverage, not liveness

Exceeding the cap does **not** deadlock merges. `CodeAnt` is on an unlimited plan and satisfies the CR-path merge gate alone (`cr-merge-gate.md` Step 1), so work keeps landing at any `k`.

What degrades is **review coverage**: CodeRabbit blocks, BugBot is cap-exhausted and refusing a majority of PRs, and PRs merge with progressively thinner review. The measured end state is the one number that matters here — **36% of blocked PRs merged unreviewed**. The cap exists to keep the reviewers that find things actually participating, which is why it is worth enforcing even though nothing visibly stalls without it.

## Subordination — `min()`, never `max()`

The repo-wide cap and the per-thread pipeline ceiling are separate limits and the tighter one governs:

```
effective limit = min(pipeline_ceiling, active_work_cap)
```

**The cap never raises the per-thread ceiling.** A repo configured `ACTIVE_WORK_CAP=10` still runs 3–4 pipelines per thread; the 10 bounds the cross-thread total, nothing else. Raising the per-thread ceiling means editing `subagent-orchestration.md`, which is a reviewed rule change — the same asymmetry `/wave` already applies to `MAX_WAVE` (may lower, may never raise).

## What counts as active

Three author-scoped, durable sources, summed by `active-work-cap.sh`:

| Source | Read | Why |
|--------|------|-----|
| Open PRs you authored | `gh pr list --state open --author @me` | Work already consuming reviewer budget. Author-scoped per #732/#733 — a collaborator's PR is context, never a gate. |
| Live offered issue-maker chips | `~/.claude/handoffs/issue-maker-*-log.json`, entries with `status: "open"` and non-null `chip_task_id` | The only cross-thread-visible chip record (`chip-launching.md` "Cross-skill chip visibility"). |
| Running inline pipelines not yet at PR | `session-state.sh --session-view`, `active_agents` entries with no `.pr` | Work in motion that has not yet become a PR, so it is invisible to the first source. |

**Offered-but-unclicked chips count.** Twenty offered chips invite twenty clicks — that was the observed 2026-08-18 failure mode, so an offer is treated as committed work. Deferred issues are re-offered as active work drains; nothing is dropped.

The three sources are disjoint by construction. An `active_agents` entry acquires a `.pr` the moment its pipeline opens a PR, at which point the first source counts it and the third stops — so no reconciliation between them is needed, and none is attempted.

## Portability

The cap and the count resolve from the **target** repo, not the orchestrator's checkout (#1189): `repo-root.sh` resolves the root, and the cap is read with `pm-config-get.sh --section "Active work" --file <resolved-path>`. A `/pm` thread running in one repo and a chip-spawned thread running in another therefore see that repo's own cap. The `/pm-handoff` bootstrap emits the `## Active work` section, so a newly bootstrapped repo has the knob without anyone adding it.

Repos whose primary reviewer is BugBot or Greptile have a different budget — BugBot's is a monthly spend cap and Greptile's a monthly credit pool, neither of which is an hourly burst limit. The knob is per-repo for exactly this reason; the default derived here is a CodeRabbit-primary default.

## Resolution order and failure behavior

`CLAUDE_ACTIVE_WORK_CAP` (env) → `ACTIVE_WORK_CAP` in `pm-config.md` → built-in default 6.

An absent value is normal and silent. An **unparseable or out-of-range** value warns on stderr and falls back to the default rather than erroring — the `MAX_WAVE` and `CLAUDE_BGWORK_CEILING_S` precedent. A count source that *fails* is different from one that is *empty*: a `gh` failure or a malformed chip log is reported and exits non-zero rather than being counted as zero, because a fabricated zero reads as "nothing active" and would silently uncap the gate (`feedback_fabricated_sentinel_stable_signature.md`, `feedback_guard_must_fail_closed.md`).

## Known limits

- **Offer-side only.** The cap binds where work is *created* — batch chip emission and wave sizing. A freshly launched coding thread does not self-check the cap at start, and does not pause pre-push when over. #1191 deferred that deliberately: offer-side capping may be sufficient, and the evidence to decide is a future over-cap incident that offer-side capping failed to prevent.
- **A count, not a scheduler.** The helper reports `CAP`/`ACTIVE`/`FREE`. It does not queue, prioritize, or re-offer; deferral and re-offer are the emitters' behavior, defined once in `chip-launching.md`.
- **The per-developer assumption.** Term 1 divides one developer's 5/hr allowance. A repo where several seat-holders open PRs concurrently has a larger aggregate budget, and this default is conservative there. The knob is the escape hatch.
- **`r = 2` productive rounds is an estimate.** The rebase term `k(k−1)/2` is exact arithmetic; the `2k` it is added to is a modelling assumption. Changing `r` moves the churn-share percentages but not the parity point, which depends only on `k` relative to the allowance.
