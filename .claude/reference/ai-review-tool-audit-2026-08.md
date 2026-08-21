# AI Review Tool Audit — 2026-08 (subscription + cap reconciliation)

Issue: [#1199](https://github.com/auerbachb/claude-code-config/issues/1199)
Prior audits: [`ai-review-tool-audit-2026-06.md`](./ai-review-tool-audit-2026-06.md) (#376) · [`ai-review-tool-audit-2026-04.md`](./ai-review-tool-audit-2026-04.md) (#368 / #377)
Role assignments derived from this audit: [`ai-review-chain-roles-decision.md`](./ai-review-chain-roles-decision.md)

Date reviewed: 2026-08-21
Measurement window: **2026-07-22 → 2026-08-21** (30 days)
Sample: **244 merged PRs** — every PR merged in the window, no sampling
Repo under measurement: `auerbachb/claude-code-config` (**public**)

## Executive summary

The prior audits asked *which tools find things*. This one asks *which tools still answer*, because
the answer changed: **three of the five paid tools now refuse most of the work we send them**, and the
chain quietly routes past all three to the one tool we deliberately do not pay for.

- **CodeRabbit reviewed 53 of 244 PRs (22%).** On **183 PRs it posted its rate-limit banner and
  nothing else.** The cap is a **7-day rolling Fair Usage allowance**, not the `~8 reviews/hour`
  our rules model.
- **BugBot refused 156 of 244 PRs (64%)** with `Bugbot couldn't run — usage limit reached`, a
  Cursor spend limit.
- **CodeAnt warned `User ci@example.com does not have a PR Review subscription` on 206 PRs (84%)**
  — and approved anyway. It is the only bot that issues `APPROVED` at all.
- **Greptile absorbed the overflow: 130 PRs (53%), 41 of them sole-source — the highest unique
  contribution of any tool in the window — and it never refused once.** It is the tool the
  operator states is deliberately unpaid.
- **Graphite ran on every PR and found something on 9.** Its paid plan is new, so this window
  measures its pre-payment behaviour.

**The money and the workflow have not merely drifted apart — they have inverted.** The chain spends
its unpaid last resort on more than half of all PRs while the paid primary's allowance goes partly
unused behind a 12-minute retry window nothing waits for.

### Methodology & caveats

- Every merged PR in the window was fetched via one GraphQL sweep over `reviews`, `comments`, and
  `reviewThreads` (`first: 100` per collection), then aggregated by `author.login`. Bot logins in
  GraphQL carry **no** `[bot]` suffix (`coderabbitai`, `codeant-ai`, `cursor`, `greptile-apps`,
  `graphite-app`); the REST endpoints the rules use do carry it.
- **"Inline findings"** = comments inside review threads, the same proxy the June audit used.
  Summary reviews, status chatter, and ack/tip comments are excluded.
- **"Sole-source"** = the PR received inline findings from exactly one tool. It is the cleanest
  available signal of unique coverage; it is not an adjudication of whether each finding was
  correct.
- Refusal counts are phrase matches against each vendor's own refusal text, quoted verbatim below,
  not inference from silence.
- **Billing state is operator-reported, not observable from here.** GitHub exposes what each app
  *did*, never what it costs. Every "as billed" cell traces to the issue #1199 statement of what is
  paid for; the reconciliation items in the next section are exactly the places where that statement
  and the observed behaviour disagree.
- Check-run participation (`Graphite / AI Reviews`, `Greptile Review`, `Cursor Bugbot`) was
  spot-checked on five recent PRs rather than swept across all 244; those spot checks are labelled
  as such where used.

## Billed vs observed — the three reconciliation items

| # | Tool | As billed (operator-stated) | As observed | Reconciliation |
|---|------|------------------------------|-------------|----------------|
| 1 | CodeAnt | Paid | `User ci@example.com does not have a PR Review subscription` on 206/244 PRs — **while still approving 360 times** | The subscription is keyed to the **commit-author email**, and this repo's automation commits as the placeholder `ci@example.com`. The seat is almost certainly provisioned for a different address. Add `ci@example.com` to the PR Review subscription, or set a real committer identity. |
| 2 | BugBot | Paid (per-seat) | `Bugbot couldn't run — usage limit reached … this run hit a usage or spend limit` on 156/244 PRs | Per-seat billing does **not** make BugBot uncapped: Cursor meters it against a usage/spend limit that our PR volume exhausts. Raise the limit in the Cursor dashboard, or accept that BugBot covers roughly a third of PRs. |
| 3 | Greptile | **Not paid** (deliberately — pricing judged a bad deal) | 130 reviews in 30 days, **zero** refusals, quota notices, or billing warnings | Either Greptile is serving this volume on an allowance that costs nothing, or an unbilled/overage balance is accruing invisibly. Nothing inside the repo can tell these apart. **Check the Greptile dashboard before the next audit** — this is the single highest-value unknown in the chain. |

Items 1 and 2 are **dashboard actions for the operator**; the agent cannot enter payment or
subscription details. Item 3 is a dashboard *reading*, and it determines whether Greptile's role in
the next audit is "best value in the chain" or "the thing to remove first".

## Findings volume — all five tools

| Tool | GraphQL login | PRs touched | Review objects | APPROVED | Inline findings | PRs w/ findings | **Sole-source PRs** |
|------|---------------|-------------|----------------|----------|-----------------|-----------------|---------------------|
| CodeRabbit | `coderabbitai` | 244 / 244 | 146 | **0** | 281 | 53 | 22 |
| CodeAnt | `codeant-ai` | 244 / 244 | 426 | **360** (on 184 PRs) | 106 | 28 | 16 |
| BugBot (Cursor) | `cursor` | 224 / 244 | 153 | 0 | 150 | 45 | 29 |
| Greptile | `greptile-apps` | 130 / 244 | 71 | 0 | 90 | 69 | **41** |
| Graphite | `graphite-app` | 9 / 244 | 9 | 0 | 9 | 9 | 1 |

153 of 244 PRs received at least one inline finding. Of those: **109 had findings from exactly one
tool**, 37 from two, 7 from three. Redundancy has *fallen* sharply since June (72% of finding-PRs
had ≥2 tools then; 29% now) — not because the tools converged, but because on most PRs only one of
them was still answering.

`APPROVED` remains a CodeAnt monopoly. CodeRabbit issued **zero** approvals in 244 PRs, exactly as
in the June window: it is a finder, never an approver. Every other tool is likewise finder-only.

## Per-tool audit

### CodeRabbit — primary finder, throughput-capped

- **Caps actually hit:** the `Review limit reached` banner appeared on **223 PRs**. Its text:
  *"You've reached a temporary PR review limit under our Fair Usage Limits Policy. Your current
  included review allowance is based on your included PR review attempts over the past 7 days.
  Next review available in: 12 minutes."*
- **The cap is the wrong shape in our rules.** `cr-rate-limits.md` and `cr-review-hourly.sh` model
  `~8 reviews/hour`. CodeRabbit meters a **rolling 7-day included-attempt allowance** and answers
  with a *specific retry window*. An hourly counter cannot predict a 7-day allowance, and it has no
  concept of "come back in 12 minutes".
- **Consequence:** on **183 PRs the banner was CodeRabbit's only output** — it never returned after
  the stated window, because nothing in the chain waits for it. `escalate-review.sh` treats a
  rate-limit signal as a fast-path *failure* for CodeRabbit and escalates immediately. Allowance we
  have paid for expires unused while the chain spends a different tool.
- **Value when it runs:** 281 inline findings across 53 PRs (5.3/PR — the densest of any tool),
  sole-source on 22.
- **Local CLI layer:** a public repo caps the free-OSS CLI tier at roughly 3 reviews before a ~40
  minute lockout (`feedback_cr_cli_free_oss_tier_cap.md`). The CLI's quota is **independent** of the
  GitHub App's; neither substitutes for the other.

### CodeAnt — the gate, running on an unrecognised subscription

- **Caps actually hit:** none on the App side. The subscription *warning* on 206 PRs never blocked a
  review — 360 `APPROVED` reviews landed across 184 PRs while it displayed. This matches the
  standing lesson that the CodeAnt subscription message is not a real block
  (`feedback_codeant_subscription_message_not_blocking.md`).
- **Role reality:** CodeAnt is not supplemental in practice, it is *the merge gate*. It participated
  on 244/244 PRs and is the sole source of `APPROVED` on the CR path. If its subscription is ever
  enforced rather than warned about, the CR path loses its only approver overnight.
- **Value:** 106 inline findings on 28 PRs, sole-source on 16.
- **Known weakness carried forward from June:** approvals can arrive before substantive review, so a
  clean CodeAnt pass may not satisfy the #875 substance guard
  (`feedback_codeant_approves_before_reviewing.md`). That guard is working as intended; it is also
  the mechanism that pushes PRs down the chain.
- **Local CLI layer:** `codeant` 0.5.1 is installed but unauthenticated on this machine (rung-5 wall,
  `codeant-graphite-supplemental.md` §Install state), so local coverage baseline stays `cr-only`.
  Separately the CLI carries an undocumented ~10 agent-reviews/day cap surfacing as a 403, and a
  15-file cap — both independent of the App (`local-review-cli-failure-modes.md`).

### BugBot (Cursor) — first fallback, refusing two PRs in three

- **Caps actually hit:** `Bugbot couldn't run - usage limit reached` on **156 PRs**, 306 comments in
  total. Verbatim: *"Bugbot is counted against Cursor usage for this user or team, and this run hit a
  usage or spend limit."*
- **`bugbot.md`'s "Cost: Per-seat — safe to always-trigger" is now false.** We posted **469**
  `@cursor review` comments in the window — roughly two per PR — at a tool that refused 64% of them.
  Re-nudging a spend-refused BugBot on the same HEAD cannot succeed and only adds PR noise.
- **Value when it runs:** 150 inline findings on 45 PRs, **sole-source on 29** — second only to
  Greptile. BugBot's precision reputation from the June audit holds; the problem is availability,
  not quality.
- **Detection note:** the spend-limit failure and a genuine clean pass are distinguishable only by
  comment text, which is why `merge-gate.sh` and `escalate-review.sh` both content-classify rather
  than trusting the check-run conclusion alone (issue #552).

### Greptile — unpaid, and carrying the chain

- **Volume:** 130 of 244 PRs (53%), 71 review objects, 90 inline findings on 69 PRs.
- **Trigger provenance:** **132 `@greptileai` comments, all posted by the PR author** (the agent
  account `auerbachb`) plus 2 quoted by CodeRabbit. Not one Greptile review in the window was
  dashboard-auto-triggered — issue #261's fix is holding. Every one of these was the escalation
  chain deliberately reaching its last resort.
- **Caps actually hit:** **none.** Zero refusals, zero quota notices, zero billing warnings across
  130 reviews. (A phrase sweep for limit/quota/subscription language returned 21 hits, every one a
  false positive from the word "limits" inside Greptile's own PR summaries.)
- **Value:** **41 sole-source PRs, the highest of any tool in the window.** Severity mix across its
  inline findings: **3 P0 / 26 P1 / 63 P2**.
- **Demand is spiky, and it has already overrun the budget.** The 134 triggers landed on just 13
  distinct days — mean 10.3 per active day, but **46 on 2026-08-07 alone**, against a
  `greptile-budget.sh` default of **40/day**. That day's demand exceeded the ceiling. Exhaustion is
  therefore an observed event, not a theoretical one, and its consequence is severe: `--consume`
  refuses, `escalate-review.sh` emits `budget_exhausted`, and the PR falls to self-review, which
  never satisfies the gate. **The budget is a cost circuit-breaker whose trip is a dead end** —
  hitting it should be read as a signal to the operator, not as a routine fallback.
- **Why this is not simply "keep it":** it is the tool the operator chose not to buy. The audit's
  job is to report that the workflow has been quietly overruling that choice for a month, and that
  we cannot see the bill. See reconciliation item 3.
- **Structural note:** `reviewer-of.sh` and `merge-gate.sh` both route a PR to the sticky Greptile
  path on the mere *presence* of `greptile-apps[bot]` in its history. 130 PRs' worth of history now
  carries that marker. Dropping Greptile is therefore not a one-line change — it would strand every
  PR whose only reviewer signal is Greptile's.

### Graphite — newly paid, measured before the payment

- **Participation:** posts a `Graphite / AI Reviews` check-run reaching `conclusion: success` on
  every PR spot-checked (#1183, #1185, #1186, #1188, #1196). The app is unambiguously alive — the
  June-era outage (#610/#614) is over and stays over.
- **Output:** findings on **9 of 244 PRs**, 9 inline comments, **sole-source on 1**. That is 0.037
  findings/PR against BugBot's 0.67 — roughly one-eighteenth the yield.
- **Why its check-run cannot gate.** A tool that concludes `success` on every PR and comments on 4%
  of them offers a signal that is `success` almost independently of the code. Accepting it as a
  merge-gate pass would manufacture approvals — precisely the hollow-approval shape issue #875 added
  the substance guard to reject. BugBot's silent pass (#844) is accepted because BugBot demonstrably
  reviews; Graphite has not yet earned the same inference.
- **The measurement is out of date by construction.** The paid plan is new; nearly all 244 PRs in
  this window predate it. **This audit cannot say what paid Graphite does** — only what free
  Graphite did. Re-measure once ≥30 PRs have merged under the paid plan.
- **Not in scope:** Graphite the stacked-PR CLI (`gt`, `graphite-repo-init.sh`,
  `graphite-stacked-prs-research-2026-05.md`) is a different product from `graphite-app[bot]` the
  reviewer. Nothing here applies to it.

## Cost vs unique value

| Tool | Cost posture (operator-stated) | Sole-source PRs | Refusal rate | Verdict |
|------|-------------------------------|-----------------|--------------|---------|
| CodeRabbit | Paid | 22 | 91% banner-only on 183/223 banner PRs | **Underused.** Paying for allowance the chain does not wait to collect. |
| CodeAnt | Paid | 16 | 0% (warning only) | **Load-bearing.** The only approver; its warning is a misconfiguration, not a lapse. |
| BugBot | Paid (per-seat) | 29 | **64%** | **Capped, not cheap.** Good yield when it runs; the "always-trigger" assumption is wrong. |
| Greptile | **Not paid** | **41** | **0%** | **Highest unique yield, unknown bill.** Cannot be judged until the dashboard is read. |
| Graphite | Newly paid | 1 | 0% | **Unmeasured at its new price.** Keep supplemental; re-measure. |

## Recommended posture (formalised in the decision record)

The chain order that the evidence supports is the one already encoded —
`CodeRabbit + CodeAnt (parallel primary) → BugBot → Greptile → self-review`, with Graphite as a
parallel supplement. **What changes is not the order; it is the three assumptions underneath it**:

1. A CodeRabbit rate-limit signal is a **bounded, self-healing wait**, not a tier failure. The chain
   should honour the stated retry window before spending a lower tier.
2. A BugBot spend refusal on the current HEAD is **terminal for that HEAD**. Re-nudging it is waste.
3. Greptile's budget is a **deliberate cost decision**, not an inherited default, and its billing
   state is an open question rather than a settled one.

Role assignments, the cost rationale behind each, and the options rejected on this evidence are in
[`ai-review-chain-roles-decision.md`](./ai-review-chain-roles-decision.md).

## Next follow-up

Re-run after the next ~60 PRs, or immediately upon any of: the Greptile dashboard being read
(item 3), the Cursor spend limit being raised (item 2), the CodeAnt subscription email being fixed
(item 1), or ≥30 PRs merging under paid Graphite. Index the next sibling as
`ai-review-tool-audit-2026-10.md`.
