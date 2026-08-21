# AI Review Chain — Role Assignment Decision

Issue: [#1199](https://github.com/auerbachb/claude-code-config/issues/1199)
Evidence base: [`ai-review-tool-audit-2026-08.md`](./ai-review-tool-audit-2026-08.md) — 244 merged PRs, 2026-07-22 → 2026-08-21
Supersedes the role recommendations in [`ai-review-tool-audit-2026-06.md`](./ai-review-tool-audit-2026-06.md) §Final review-chain recommendation.

## Decision

Each of the five AI review tools holds exactly one role. **No tool is dropped**, so no rule or
script may gate on, escalate to, or trigger a tool absent from this table.

| Tool | Bot login (REST) | **Role** | Gates the merge? | Cost rationale |
|------|------------------|----------|------------------|----------------|
| CodeRabbit | `coderabbitai[bot]` | **Primary finder** | No — it never issues `APPROVED` | Paid, and *underused*: it reviewed 22% of PRs while its allowance sat behind a retry window nothing waited for. Collecting what we already pay for is cheaper than any other throughput change available. |
| CodeAnt | `codeant-ai[bot]` | **Primary approver** (co-primary on the CR path) | **Yes** — sole source of `APPROVED` | Paid, and load-bearing: 360 approvals on 184 PRs. The gate has no other approver, so a lapse here is a full stop, not a degradation. |
| BugBot (Cursor) | `cursor[bot]` | **First fallback** | Yes, on the BugBot path | Paid per-seat but **spend-metered**: refused 64% of PRs. Worth its seat on yield (29 sole-source PRs); not worth re-nudging once it has refused a given HEAD. |
| Greptile | `greptile-apps[bot]` | **Second fallback — retained, budget-bounded (40/day)** | Yes, on the Greptile path | **Operator-stated as unpaid, yet it carried 53% of PRs and 41 sole-source findings with zero refusals.** Retained because dropping it strands those PRs; the existing 40/day ceiling is reaffirmed as a runaway bound, having been overrun once (46 triggers on 2026-08-07). |
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

1. **A CodeRabbit rate-limit signal is a bounded wait, not a tier failure.** Its banner names a
   retry window ("Next review available in: 12 minutes"). While that window is open the PR keeps
   polling CodeRabbit rather than escalating; once it has elapsed with no review, escalation
   proceeds exactly as before. Enforced in `escalate-review.sh`.
2. **A BugBot spend refusal is terminal for that HEAD.** Once `cursor[bot]` has posted a usage-limit
   refusal postdating the HEAD commit, further `@cursor review` nudges cannot succeed and are
   suppressed until the next push. Enforced in `maybe-trigger-ai-review.sh`.
3. **Greptile's daily budget is a cost circuit-breaker whose trip is a dead end.** It stays at
   **40/day** — deliberately reaffirmed, not lowered. Demand is spiky (134 triggers on 13 active
   days; **46 on 2026-08-07**, which overran the ceiling), and exhaustion drops the PR to
   self-review, which never satisfies the gate. Lowering the number would strand PRs rather than
   bound cost; raising it would remove the only bound on a runaway escalation loop. Hitting it is a
   **signal to the operator**, not a routine fallback. `greptile-budget.sh` is unchanged.

### Repo variance

Roles are **identical across repos**; only the *local CLI* layer varies by visibility.

- **Public repos** (this one): the CodeRabbit CLI free-OSS tier allows roughly 3 reviews before a
  ~40-minute lockout (`feedback_cr_cli_free_oss_tier_cap.md`), and CodeAnt's OSS pricing differs
  from its private-repo pricing.
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

### Why Greptile is retained despite being unpaid

Three facts had to be held together:

- The operator deliberately chose not to pay for Greptile.
- Greptile nonetheless produced the **highest unique yield in the chain** (41 sole-source PRs) and
  never refused a single one of 130 requests.
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
— whichever comes first. Promotion to a gating tier requires **both**: a sole-source contribution
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

## Operator actions this decision depends on

None of these are agent-executable — each requires entering or changing billing/subscription state
in a vendor dashboard. Listed in descending value:

1. **Read the Greptile dashboard.** Determines whether 130 reviews/month is free or an accruing
   balance, and therefore whether Greptile's role next audit is "keep" or "remove first".
2. **Raise the Cursor usage/spend limit**, or accept BugBot covering ~⅓ of PRs.
3. **Fix the CodeAnt subscription identity** — add `ci@example.com` to the PR Review subscription, or
   set a real committer email so the existing seat is recognised.
4. **Review the CodeRabbit plan tier.** Assumption 1 recovers unused allowance, but a 7-day allowance
   that 244 PRs/month exhausts is a plan-size question, not a scheduling one.

## References

- [`ai-review-tool-audit-2026-08.md`](./ai-review-tool-audit-2026-08.md) — the measurements every row above rests on
- [`merge-gate-reviewer-paths.md`](./merge-gate-reviewer-paths.md) — per-path gate semantics (authoritative for gate detail)
- [`codeant-graphite-supplemental.md`](./codeant-graphite-supplemental.md) — CodeAnt + Graphite supplemental protocol and CLI install state
- [`cr-rate-limits.md`](./cr-rate-limits.md) — CodeRabbit cap model and the pacing-proxy caveat
- [`local-review-cli-failure-modes.md`](./local-review-cli-failure-modes.md) — CLI-layer caps, 403 triage, false-clean shapes
- Issue [#261](https://github.com/auerbachb/claude-code-config/issues/261) — Greptile dashboard auto-trigger disabled; confirmed still holding (0 auto-triggers in 130 reviews)
- Issue [#1191](https://github.com/auerbachb/claude-code-config/issues/1191) — active-work ceiling derived from reviewer throughput; consumes the observed numbers in the audit, not the modelled ones
