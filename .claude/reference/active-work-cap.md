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
- That allowance is degraded further by a **Fair Usage table keyed to trailing-7-day volume, per developer identity**: 0–29 → 5/hr, 30–39 → 4/hr, 40–49 → 3/hr, 50–59 → 2/hr, 60–69 → 1/hr one-at-a-time, 70–79 → 1/hr, 80–89 → 1/hr, 90+ → 1/hr one-at-a-time.
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

The original test — "beyond ~8 active PRs a PR cannot even get one review round per hour" — is just `k > reviews/hour`. Run against the measured 5/hr it fires at **k = 6**: at k = 5 a PR still gets exactly one round per hour, and k = 6 is the first value where it gets less.

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

Two independent tests land one step apart, and they bracket the answer:

- **k = 5** is where rebase re-review reaches parity with productive review — half the budget spent standing still (Term 2). At k = 5 a PR still gets exactly one review round per hour.
- **k = 6** is the first value where a PR gets *less* than one round per hour (Term 1) — 0.83, a round every 72 minutes.

The **working set stays 3–4**, unchanged and still CodeRabbit-throughput-bound — that is the target concurrency, not the limit.

So the cap belongs at 5 or 6, and the tie is broken by what a cap is *for*. A hard cap of 5 leaves a single slot above a 4-pipeline working set, so ordinary operation would sit against it constantly — and a backstop that fires during normal work is a nuisance rather than a backstop, which is how caps get raised for the wrong reason. 6 leaves two slots of transient headroom while staying within one step of parity.

> **Default `ACTIVE_WORK_CAP=6`** — one step past the rebase-parity point, at 56% churn and 0.83 review rounds/hour/PR. **Configurable range [1, 10]**, the upper bound being the operator's stated tolerance from the 2026-08-18 session.

**6 is a ceiling, not a target.** It deliberately sits one step into the degraded band: at k = 6 a PR waits 72 minutes between review rounds and a majority of the review budget goes to rebases. That is the *worst* acceptable state, not the intended one. The intended state is the 3–4 working set, where a PR gets a round every 36–48 minutes and churn is still a minority of the budget.

**Why 8 is not carried forward.** The originally proposed 8 had exactly one derivation: `8 reviews/hour ÷ 1 round per PR`. The 8 has been retracted. Re-running that same test on the measured 5/hr puts the starvation threshold at 6, not 8 — and at 8 a PR would wait 96 minutes per round with 64% of the budget going to rebases. Keeping 8 would mean keeping a number whose sole justification no longer exists.

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

Four author-scoped, durable sources, summed by `active-work-cap.sh`:

| Source | Read | Why |
|--------|------|-----|
| Open PRs you authored | `gh pr list --state open --author @me` | Work already consuming reviewer budget. Author-scoped per #732/#733 — a collaborator's PR is context, never a gate. |
| Registry chip offers | `chip-offer-registry.sh --list` (snapshot filtered to `offered`/`running`, non-expired entries; supplies both the entry count and the issue list for dedup) | One registry entry = one chip = one capacity slot. Batch reservations store multiple issues per entry; the entry count is used for capacity, not the issue count. |
| Live offered issue-maker chips (legacy) | `~/.claude/handoffs/issue-maker-*-log.json`, **distinct** `chip_task_id`s among entries with `status: "open"` and non-null `chip_task_id` | Backward-compatible source for emitters not yet using the registry. Deduplicated against registry by issue number so no chip is counted twice. |
| Running inline pipelines not yet at PR | `session-state.sh --session-view`, `active_agents` entries with no `.pr` | Work in motion that has not yet become a PR, so it is invisible to the first source. |

**Offered-but-not-yet-accepted work counts.** A pending inline-run offer or an unclicked chip both invite an execution start — that was the observed 2026-08-18 failure mode, so an offer is treated as committed work regardless of delivery mode. Deferred issues are re-offered as active work drains; nothing is dropped.

**Sources 1 and 4 are disjoint by construction**, and need no reconciliation: an `active_agents` entry acquires a `.pr` the moment its pipeline opens a PR, at which point the first source counts it and the fourth stops.

**Sources 1 and 3 are not**, and the script performs two explicit narrowings to keep them from double-counting or over-reaching. Do not remove either on the assumption that the sources are independent:

1. **Subtract entries an open OR recently-merged PR already covers.** A chip's log entry survives the click, and its issue stays open until the PR merges, so a clicked chip would be counted once as a chip and again as a PR — halving the effective cap. Entries whose issue appears in any `closingIssuesReferences` of either (a) an open PR or (b) a recently-merged PR authored by `@me` are excluded. The merged-PR path (#1285 fix) covers the case where the PR finishes and leaves the open list — previously the exclusion lapsed and the chip re-entered the count while the issue remained open. The `CLAUDE_ACTIVE_WORK_MERGED_PR_LIMIT` tunable (default 50) sets how many recently-merged PRs are fetched.
2. **Keep only entries whose issue is still open.** `chip_task_id` is cleared on acceptance (after `/subagent` starts), on decline, and on explicit retract — so without this filter the count would still be a monotonic high-water mark for any log entries whose issue closed before the offer resolved.

Both narrowings apply **only to entries attributed to this repo**. An entry carrying no usable URL is counted unconditionally and skips both: its number is meaningless outside a repo, so matching it against this repo's PR-closed or open issues would drop it on a coincidence and turn a deliberate over-count into an under-count.

**Self-referential double-count fix (#1285).** Once a thread accepts an offer, it appears in `active_agents` (source 4). Until a PR is opened, the same work is visible in both the chip sources (2a/2b) and the pipeline source (4). The script resolves this by subtracting pipeline issue numbers from both registry and legacy log chip counts: a chip whose issue is already tracked by a live pipeline is not counted a second time. This prevents the observed state where `ACTIVE` was 6 with only 4 units genuinely live.

### Entries are not offers (#1247)

`/issue-maker` emits **one** inline-run offer (or on-request chip) per capture session covering every issue it filed (`issue-maker/SKILL.md` Step 9c), so an N-issue session writes N log entries carrying a single `chip_task_id` value (offer token or spawn_task id). Counting entries let one 24-issue capture session report `ACTIVE=24` against a `CAP=6` board on `auerbachb/inventory` with no open PRs and no running pipelines — a false `FREE=0` that silently stalled every chip emitter on an idle repo.

The count is therefore over **distinct `chip_task_id`s**, and the de-duplication runs **after** both narrowings above, never before. Applying it earlier would let one absorbed issue speak for its whole chip and weaken both filters.

**Partial absorption.** A chip whose issues are some absorbed and some not is still one live offer and counts 1; it reaches 0 only when *every* issue it covers is absorbed. Clicking it opens one thread, and while any of its issues is still open that thread has real work to do — releasing the slot sooner hands back capacity that is still in use.

**The issue-level rule still binds alongside it.** One issue offered by two capture sessions is one slot, not two, because the unit of work is the issue. Each surviving issue therefore names a single representative chip before the distinct count, so the two rules compose to "one unit of work, one slot" from either direction: N issues under one chip count 1, and one issue under N chips also counts 1.

This is a narrowing *within* the sources the script already reads. The one remaining known gap is that the count is not a reservation — two concurrent emitters can both observe the same `FREE` value before either stamps. The chip-offer registry's `--reserve` closes that race for chip-mode emitters; the legacy log path has no lock.

## Portability

The cap and the count resolve from the **target** repo, not the orchestrator's checkout (#1189): `repo-root.sh` resolves the root, and the cap is read with `pm-config-get.sh --section "Active work" --file <resolved-path>`. A `/pm` thread running in one repo and a chip-spawned thread running in another therefore see that repo's own cap. The `/pm-handoff` bootstrap emits the `## Active work` section, so a newly bootstrapped repo has the knob without anyone adding it.

Repos whose primary reviewer is BugBot or Greptile have a different budget — BugBot's is a monthly spend cap and Greptile's a monthly credit pool, neither of which is an hourly burst limit. The knob is per-repo for exactly this reason; the default derived here is a CodeRabbit-primary default.

## Resolution order and failure behavior

`CLAUDE_ACTIVE_WORK_CAP` (env) → `ACTIVE_WORK_CAP` in `pm-config.md` → built-in default 6.

`CLAUDE_ACTIVE_WORK_MERGED_PR_LIMIT` (env, default 50) — how many recently-merged PRs authored by `@me` to fetch when checking whether a chip's issue is already done. A non-integer value warns and falls back to 50. Set to 0 to disable the merged-PR check entirely (not recommended — reverts to the pre-#1285 bug).

An absent value is normal and silent. An **unparseable or out-of-range** value warns on stderr and falls back to the default rather than erroring — the `MAX_WAVE` and `CLAUDE_BGWORK_CEILING_S` precedent. A count source that *fails* is different from one that is *empty*: a `gh` failure or a malformed chip log is reported and exits non-zero rather than being counted as zero, because a fabricated zero reads as "nothing active" and would silently uncap the gate (`feedback_fabricated_sentinel_stable_signature.md`, `feedback_guard_must_fail_closed.md`).

## `--json` output

`active-work-cap.sh --json` emits a single-line JSON object. Relevant fields for diagnosing a `FREE=0` reading:

| Field | Description |
|-------|-------------|
| `cap`, `active`, `free` | Top-level figures |
| `open_prs` | Source 1 count |
| `live_chips` | Source 2 count (registry + legacy, after dedup and narrowings) |
| `inline_pipelines` | Source 4 count |
| `offered_issue_nums` | Sorted array of issue numbers that make up the offered-work term (sources 2a + 2b after all narrowings, AC#3 — #1285). Use this to identify which specific issues are holding capacity. |
| `registry_baseline` | Raw count from the registry before dedup against legacy log |
| `cap_source` | Which config level resolved the cap |

## Known limits

- **Offer-side only.** The cap binds where work is *created* — batch chip emission and wave sizing. A freshly launched coding thread does not self-check the cap at start, and does not pause pre-push when over. #1191 deferred that deliberately: offer-side capping may be sufficient, and the evidence to decide is a future over-cap incident that offer-side capping failed to prevent.
- **A count, not a scheduler.** The helper reports `CAP`/`ACTIVE`/`FREE`. It does not queue, prioritize, or re-offer; deferral and re-offer are the emitters' behavior, defined once in `chip-launching.md`.
- **The per-developer assumption.** Term 1 divides one developer's 5/hr allowance. A repo where several seat-holders open PRs concurrently has a larger aggregate budget, and this default is conservative there. The knob is the escape hatch.
- **`r = 2` productive rounds is an estimate.** The rebase term `k(k−1)/2` is exact arithmetic; the `2k` it is added to is a modelling assumption. Changing `r` moves the churn-share percentages but not the parity point, which depends only on `k` relative to the allowance.
- **`/pm` and `/prompt` undercount.** These emitters create chips without writing to the issue-maker legacy log. They use the registry (source 2), so their offers are visible to the cap. Work claimed before a PR opens but after the chip is dismissed may transiently not appear in any source; this window is short and bounded by the pipeline ceiling.
- **Cross-session task-id stability.** Registry `task_id`s generated automatically use timestamp + PID + random; they are unique with high probability but not guaranteed globally. A caller-supplied `--task-id` should be stable and unique if used for durable cross-session tracking (#1238 §Deferral 3).
