# AI Review Chain — Role Assignment Decision

Issue: [#1199](https://github.com/auerbachb/claude-code-config/issues/1199)
Evidence base: [`ai-review-tool-audit-2026-08.md`](./ai-review-tool-audit-2026-08.md) — 244 merged PRs, 2026-07-22 → 2026-08-21
Supersedes the role recommendations in [`ai-review-tool-audit-2026-06.md`](./ai-review-tool-audit-2026-06.md) §Final review-chain recommendation.

## Decision

Each of the five AI review tools holds exactly one role. **No tool is dropped**, so no rule or
script may gate on, escalate to, or trigger a tool absent from this table.

| Tool | Bot login (REST) | **Role** | Gates the merge? | Cost rationale |
|------|------------------|----------|------------------|----------------|
| CodeRabbit | `coderabbitai[bot]` | **Primary finder** | No — it never issues `APPROVED` | Pro, 3/3 seats, $90/mo (#1204), and *underused*: 22% of PRs reviewed, 68% of reviews blocked by a **5/hr per-developer** burst limit, 87.4h average wait. Two priced fixes exist; collecting what we already pay for is the cheapest lever. |
| CodeAnt | `codeant-ai[bot]` | **Primary approver** (co-primary on the CR path) | **Yes** — sole source of `APPROVED` | Premium, 2/2 seats, ~$48/mo (#1204). Load-bearing: 360 approvals on 184 PRs, and the gate has no other approver, so a lapse here is a full stop. The commit-author identity holds no seat — a **$0** fix. |
| BugBot (Cursor) | `cursor[bot]` | **First fallback** | Yes, on the BugBot path | **The stack's largest cost line** (#1204): ~$1.58/review on-demand, $815.58 in one cycle against a $1,000 cap it has exhausted — which is why it refused 64% of PRs. Strong yield (29 sole-source PRs), but the spend is a scope problem before it is a cap problem. |
| Greptile | `greptile-apps[bot]` | **Second fallback — retained, spend-capped at the vendor** | Yes, on the Greptile path | **Paid Pro on the `auerbachb` org, with flex overage UNCAPPED** (#1204 round 2): ~$36–72/mo billed, 42 of 92 credits already on flex 15 days in, and this repo is the org's largest lifetime consumer (212 reviews). Earns its keep on yield — 41 sole-source PRs, more than any other tool — but the spend is real and currently unbounded. |
| Graphite | `graphite-app[bot]` | **Supplemental — paid, under re-measurement** | **No** | Newly paid, and measured almost entirely *before* the payment: 1 sole-source PR in 244. Promotion is deferred to evidence, not price. |

**Authoritative chain order** — unchanged in shape, corrected in its assumptions:

```
Local:   CodeRabbit CLI + CodeAnt CLI before push (advisory; never gates)
GitHub:  CodeRabbit  ─┐
         CodeAnt     ─┼─ parallel primary (CodeAnt = approver)
                      │
         BugBot       ── first fallback (sticky)
                      │
         Greptile     ── second fallback (sticky, budget-bounded)
                      │
         self-review  ── terminal; never satisfies the gate

         Graphite     ── parallel supplemental (never gating)
```

### The three assumptions this decision corrects

1. **A CodeRabbit rate-limit signal that *names a retry window* is a bounded wait, not a tier
   failure.** The qualifier is load-bearing: CodeRabbit emits two shapes, and only the
   issue-comment banner carries a window ("Next review available in: 12 minutes"). The bare commit
   status `CodeRabbit / success / "Review rate limited"` names none and escalates immediately, as
   does a banner whose wording changes such that no window can be read. While a window is open the
   PR keeps polling CodeRabbit; once elapsed with no review, escalation proceeds exactly as before.
   Enforced in `escalate-review.sh`, which selects the **newest** banner before reading its window
   so a stale readable one cannot outrank an unreadable fresh one.
2. **A BugBot spend refusal is terminal for that HEAD.** Once `cursor[bot]` has posted a usage-limit
   refusal postdating the HEAD commit, further `@cursor review` nudges cannot succeed and are
   suppressed until the next push. Enforced in `maybe-trigger-ai-review.sh`.
3. **`greptile-budget.sh` bounds triggers, not dollars — the cost control belongs at the vendor.**
   This was previously called a "cost circuit-breaker." It is not one. Its 40/day default permits
   **1,200 reviews/month against an uncapped flex account ≈ $1,150** at $1/credit, so it can only
   ever stop a runaway *loop*, never bound *spend*. It stays at 40/day for exactly that job:
   demand is spiky (134 triggers on 13 active days, **46 on 2026-08-07**), and lowering it would
   strand PRs on self-review — which never satisfies the gate — rather than save money.

   Two mechanics worth stating once, since neither is obvious from the rule file:
   the budget's day boundary is **`America/New_York`**, not UTC (`greptile-budget.sh`
   `TODAY`), and `--budget N` **persists** into the stored state rather than applying
   for one call. Also note the 46-trigger spike is a count of `@greptileai` comments
   observed on GitHub, not of `--consume` calls — the two are different measurements
   and only the latter moves this budget.

   **The real control is the vendor-side Flex Usage Limit, currently unset.** A cap there fails at
   the vendor, where the consequence is a refused review; a cap here fails mid-workflow, where the
   consequence is a PR that can never merge. Set the vendor cap; keep this one as a loop bound and
   stop describing it as a budget.

### Repo variance

Roles are **identical across repos**; only the *local CLI* layer varies by visibility.

- **Public repos** (this one): the CodeRabbit CLI free-OSS tier allows roughly 3 reviews before a
  ~40-minute lockout (`feedback_cr_cli_free_oss_tier_cap.md`), and CodeAnt's OSS pricing differs
  from its private-repo pricing.
  **This is not a seat problem, and re-auth cannot fix it** (#1213, measured 2026-08-21):
  `coderabbit auth status` reports `Plan: Pro` / `Seat: assigned`, and the CLI states the routing
  itself — *"This looks like a public open-source repository… no organization will be billed. Free
  OSS limits apply."* The `isProUser: false` in the rate-limit payload names **the pool the review
  was billed against**, not the account's tier, and the pool is selected by repository visibility.
  Recorded here because the opposite reading reached `pricing-matrix.md` as an owner action.
- **Private repos**: CLI caps follow the paid plan instead.
- **Neither affects the merge gate.** The CLIs are advisory and the GitHub Apps hold quotas that are
  entirely independent of them (`feedback_review_clis_down_app_independent.md`). A dead CLI never
  blocks a merge, and a healthy CLI never satisfies one.

## Rationale

### Why the chain order does not change

The June audit already recommended this order and it was already implemented. The 30-day evidence
does not fault the order — it faults the belief that the upper tiers were *healthy*. CodeRabbit,
CodeAnt, and BugBot each answer far less often than the rules assume, and the chain behaved
correctly by falling through. Reordering tiers cannot fix a cap; only collecting more of what we
already pay for, or raising a cap, can.

### Why Greptile is retained — and what it actually costs

Three facts had to be held together:

- The operator believed Greptile was unpaid. **It is not** (#1204 round 2): the org serving this
  repo is on paid Pro with **uncapped flex overage**, and this repo is its largest consumer.
- Greptile produced the **highest unique yield in the chain** (41 sole-source PRs) and never refused
  a single one of 130 requests — and those 130 were billed, roughly 80 as $1 flex credits.
- `reviewer-of.sh` and `merge-gate.sh` both make the Greptile path **sticky on history**: any PR
  where `greptile-apps[bot]` has ever posted resolves to the Greptile path for life.

Dropping Greptile therefore does not remove a cost — it removes the only reviewer that answered on
~130 PRs/month and leaves their gate unsatisfiable, since self-review never satisfies it. The honest
posture is to keep the tier, bound its budget, and escalate the *billing question* to the operator
rather than resolve it by guessing. Reconciliation item 3 in the audit is that question.

### Why Graphite is not promoted

Graphite concludes `success` on essentially every PR and comments on 4% of them. A signal that is
positive almost independently of the code under review is not a review; treating it as a gate
manufactures approvals, which is exactly the hollow-approval shape issue #875 added the substance
guard to reject. BugBot's silent-pass shape (#844) is accepted because BugBot demonstrably reviews
— 150 findings on 45 PRs — so an absence of findings from it is informative. Graphite has not
earned that inference.

The payment is real and recent, and it may change the behaviour. That is a reason to **re-measure**,
not to promote on price. Price is not evidence of yield.

### Re-measure trigger (Graphite)

Revisit Graphite's role at the next audit, or as soon as **≥30 PRs have merged under the paid plan**
— whichever comes first. **Both conditions are now satisfied** (88 merged PRs, 7–21 Aug 2026), so
this is due rather than pending. Promotion to a gating tier requires **both**: a sole-source contribution
comparable to BugBot's, and a demonstrated ability to distinguish a clean PR from an unreviewed one
(i.e. its `conclusion` must vary with the code). Until then it stays supplemental, polled and
nudged like any other bot, never gating.

## Explicitly rejected

Recorded so the next audit does not re-litigate them from scratch. The first two were the
CodeRabbit plan's recommendations on this issue; both are declined **on measured evidence**, not
preference.

| Rejected option | Why |
|-----------------|-----|
| **Promote Graphite to a gating fallback tier**, filling a slot vacated by Greptile | 0.037 findings/PR vs BugBot's 0.67; sole-source on 1 PR in 244; an unconditional `success` check-run. Gating on it manufactures approvals (#875). Its paid plan postdates the measurement window, so there is no paid-Graphite evidence either way — hence *defer and re-measure*, not *promote*. |
| **Set the Greptile budget to 0 ("dormant, one-line re-enable")** | Would strand the ~130 PRs/month for which Greptile is the only responding reviewer. Their gate would be unsatisfiable, since self-review never satisfies it, and the sticky-by-history routing means the block is permanent for each affected PR. A "dormant" tier is only safe when something else answers; nothing else does. |
| **Remove the Greptile integration outright** | Strictly worse than budget-zero for the same reason, and irreversible in a day. Revisit only after reconciliation item 3 is answered. |
| **Lower the modelled CodeRabbit cap to the observed rate (~5/hr)** | The observed cap is not a smaller hourly number, it is a **7-day rolling allowance** with a per-response retry window. Substituting a smaller wrong-shaped number would still not predict a lockout, and would tighten our own pacing against a limit that is not hourly. The hourly counter is retained as an explicitly-labelled *local pacing proxy*. |
| **Treat the CodeAnt subscription warning as a gate failure** | It warns on 84% of PRs while approving 360 times. Treating it as a block would disable the chain's only approver over a misconfigured email. Confirmed non-blocking (`feedback_codeant_subscription_message_not_blocking.md`). |
| **Stop triggering BugBot entirely while it is spend-capped** | It is sole-source on 29 PRs when it runs, and the cap is per-usage, not permanent — the first nudge after each push may well succeed. Only *repeat* nudges after a refusal on the same HEAD are suppressed. |

## Dashboard reconciliation (#1204, 2026-08-21)

A logged-in browser session read all four dashboards and changed nothing. Readings:
[`ai-review-billing-dashboard-2026-08.md`](./ai-review-billing-dashboard-2026-08.md); interpretation
in the audit's §Dashboard reconciliation. Three things it changed here:

1. **BugBot's cost rationale is rewritten.** "Per-seat but spend-metered" understated it — it is the
   largest line in the stack, and it is configured for maximum spend (Every Push, Effort High, drafts
   on, incremental off, autofix on with **299 runs and 0 merged**). Scope tuning precedes any cap
   raise, and the attribution dispute between the `github_bugbot` billing line and the operator's
   IDE-usage account must be settled first.
2. **CodeRabbit's cap model is corrected.** Not a rolling 7-day allowance: **5 reviews/hour per
   developer** on Pro. Monthly volume was never the constraint. The figure that matters most is not
   a cost one — **36% of blocked PRs merged unreviewed**, meaning something satisfied the gate in
   CodeRabbit's absence on a third of them. On the CR path the only other approver is CodeAnt, whose
   approvals frequently carry no substantive footprint at all.
3. **Greptile is resolved, and the founding premise of this audit was wrong.** Round 2 found a
   second Greptile org on the `auerbachb` account: **paid Pro, flex overage uncapped**, with
   `claude-code-config` as its largest lifetime consumer (212 reviews). "Deliberately unpaid" was
   never true for the account that serves this repo. The role is unchanged — it still earns its keep
   on 41 sole-source PRs — but its rationale is now *cost-aware* rather than *cost-unknown*, and the
   uncapped flex is the exposure to close.

4. **CodeAnt's hollow approvals have a cause: `Auto Approve PR` is ON at the org level.** That is why
   PR #1203 collected `APPROVED` on four consecutive SHAs with no substantive footprint, each one
   correctly discarded by the #875 guard. Turning it off removes the noise at the source rather than
   filtering it at the gate.

5. **Graphite's re-measure trigger is met — by merged-PR count, not by review volume.** The paid
   Team plan started 7 Aug 2026, and `gh pr list --state merged --search
   "merged:2026-08-07..2026-08-21"` returns **88 merged PRs** in the paid period (measured
   2026-08-21) against a threshold of 30. Its role can be re-decided on paid evidence. Note its billing shape: AI review
   volume is unmetered, but **committers who receive only AI reviews are billed as seats**, so the
   "All committers in selected repositories" setting is the cost lever, not the review count.

6. **The paid levers are now tracked, and one of them was a misdiagnosis (#1213, 2026-08-21).**
   The owner-only paid decisions behind this table's cost rationale — the Greptile OSS application,
   the CodeAnt open-source discount, CodeRabbit's billing cadence, its metered add-on, and seat
   coverage for the three unassigned human authors — live in
   [`ai-review-paid-levers-checklist.md`](./ai-review-paid-levers-checklist.md), each carrying its
   ordering gate and separate `Submitted:`/`Approved:` dates. **No cost rationale above changes
   yet**: as of 2026-08-21 nothing has been submitted, #1209/#1210/#1212 are all open, and a budget
   line moves only on a landed approval. The sixth item closed on measurement rather than action —
   the CodeRabbit CLI is already seated (§Repo variance), so "attach the CLI to a paid seat" was
   never available to do.

## Operator actions this decision depends on

None of these are agent-executable — each requires entering or changing billing/subscription state
in a vendor dashboard. Listed in descending value.

**Scope of this list: the free settings and cap changes**, tracked in
[#1209](https://github.com/auerbachb/claude-code-config/issues/1209). The **paid** decisions this
role table's cost rationale depends on — OSS applications, billing cadence, metered caps, seat
coverage — are tracked separately in
[`ai-review-paid-levers-checklist.md`](./ai-review-paid-levers-checklist.md) (#1213), which encodes
each item's ordering gate and keeps `Submitted:` and `Approved:` as separate dates so an in-flight
application never moves a budget line.

1. **Set Greptile's Flex Usage Limit — it is still unset.** Round 2 answered "is it billed" (yes,
   uncapped at $1/credit past 50/month), so what remains is closing the exposure. This is the only
   true spend control on that account: a cap there fails as a refused review, whereas the
   agent-side budget fails as a PR that can never merge.
2. **Turn CodeAnt's org `Auto Approve PR` off** — free, and it stops the manufactured approvals the
   #875 gate has to discard.
3. **Cut BugBot's scope** — Every Push → per PR, Incremental → On, Drafts → Off, Effort → Medium,
   Autofix → Off (0 of 299 merged) — before considering a Cursor cap raise. Scope costs nothing.
4. **Fix the CodeAnt subscription identity** — either license a dedicated CI identity on a seat, or
   set the committer email to the operator's own seat-holding address. Never point it at a
   collaborator's address.
5. **Turn CodeRabbit's Incremental review off** — free, and the largest single reducer of slot
   consumption (one review per PR instead of one per push). The paid levers ($0.25/file overflow,
   Pro Plus) only matter after that lands, and extra seats cannot help while one identity authors
   every PR.

## References

- [`ai-review-tool-audit-2026-08.md`](./ai-review-tool-audit-2026-08.md) — the measurements every row above rests on
- [`merge-gate-reviewer-paths.md`](./merge-gate-reviewer-paths.md) — per-path gate semantics (authoritative for gate detail)
- [`codeant-graphite-supplemental.md`](./codeant-graphite-supplemental.md) — CodeAnt + Graphite supplemental protocol and CLI install state
- [`cr-rate-limits.md`](./cr-rate-limits.md) — CodeRabbit cap model and the pacing-proxy caveat
- [`local-review-cli-failure-modes.md`](./local-review-cli-failure-modes.md) — CLI-layer caps, 403 triage, false-clean shapes
- Issue [#261](https://github.com/auerbachb/claude-code-config/issues/261) — Greptile dashboard auto-trigger disabled; confirmed still holding (0 auto-triggers in 130 reviews)
- Issue [#1191](https://github.com/auerbachb/claude-code-config/issues/1191) — active-work ceiling derived from reviewer throughput; consumes the observed numbers in the audit, not the modelled ones
