# Review-Stack Pricing Matrix — Priced Upgrade Levers

Issue: [#1202](https://github.com/auerbachb/claude-code-config/issues/1202)
Companion records: [#1199](https://github.com/auerbachb/claude-code-config/issues/1199) assigns each tool a role; [#1204](https://github.com/auerbachb/claude-code-config/issues/1204) reconciled billing state from the vendor dashboards; this document prices the purchasable levers those two cannot recommend without numbers.
Re-verification owner: [#1201](https://github.com/auerbachb/claude-code-config/issues/1201) — the recurring review-stack audit re-checks every price here on each run.

Date reviewed: **2026-08-21**
Demand window: **2026-07-22 → 2026-08-21**, 245 merged PRs

> **Two independent sources, deliberately kept apart.** Rows marked *public* were read from the vendor's pricing page — what anyone can buy. Rows marked *dashboard* were read from the logged-in account during the [#1204](https://github.com/auerbachb/claude-code-config/issues/1204) co-working session — what we are actually billed. They disagree in three places, and each disagreement is a finding rather than an error.
>
> **Prices drift.** Every figure carries a source and a retrieval date. Vendor pricing pages are JS-rendered and several default to the annual price without labelling it, so each row states which billing toggle produced the number.
>
> **No agent executes a purchase.** Everything here is a recommendation. Raising a spend cap, buying credits, changing a plan, adding a seat, or claiming a discount stays with the account owner. Nothing was changed on any dashboard to produce this document.

## Executive summary

**The problem is not that we are under-buying. It is that roughly $1,340 was billed this cycle and the review stack is still blocking.** Every tool that refuses us is refusing for a reason a purchase would not fix — a consumed cap, a misattributed email, an hourly burst limit, a canceled plan still serving traffic.

Current monthly spend, as billed:

| Tool | Plan | Fixed monthly | Metered this cycle | Source |
|---|---|---|---|---|
| Cursor (BugBot's host) | Ultra | **$200** | **$999.87** of a $1,000.00 cap | dashboard |
| CodeRabbit | Pro, 3 seats, monthly billing | **$90** | $0 (usage-based reviews off) | dashboard |
| CodeAnt | Premium, 2 seats | **~$48** | $0 (unlimited) | dashboard |
| Greptile | **Canceled → Free** | **$0** | $0 | dashboard |
| Graphite | Newly paid, tier unread ([#1204](https://github.com/auerbachb/claude-code-config/issues/1204) scoped it out) | unknown | — | — |
| **Total** | | **$338 fixed** | **+$999.87 metered** | **≈$1,337.87 this cycle** |

The single largest line is Cursor on-demand at **$999.87 against a $1,000.00 cap — 100.0% consumed**. Within it, the invoice itemizes **$815.58 as `github_bugbot`** (516 reviews) and **$184.29 as `claude-sonnet-5-thinking-high`** (48 requests, the IDE/agent line). Only the first is in dispute (below), so **$1,153.58 is the attribution-independent floor** and the remaining $184.29 is billed regardless. That dispute must be settled *before* anyone raises the cap.

### Verdicts

| Lever | Verdict | Cost | Billing unit | Why |
|---|---|---|---|---|
| **BugBot — narrow the trigger scope** (Every Push → per PR, Incremental Review → On, Drafts → Off, Effort High → Medium, Autofix → Off) | **DO THIS FIRST — free** | **$0** | settings, not spend | These five settings are the multipliers behind 516 reviews/cycle. Autofix alone ran **299 times with 0 branches ever merged**. |
| **BugBot — raise the $1,000 on-demand cap** | **BLOCKED — do not raise yet** | ~$400–500/mo more | per-user | The invoice itemizes $815.58 as `github_bugbot`; the operator believes it is IDE usage mislabeled. Raising the cap on a misattributed line funds the wrong thing. Settle attribution first. |
| **CodeAnt — set `git user.email` to a seat holder** | **DO THIS — free** | **$0** | — | Ends the "no PR Review subscription" warning on 84% of PRs. The plan is already unlimited; nothing needs buying. |
| **Greptile — add a LICENSE file, then apply to the OSS program** | **PURSUE (free to try)** | **$0 if accepted** | per-repo eligibility | This public repo has **no LICENSE**. Greptile is free for "qualified non-commercial projects with MIT or Apache licenses" — a LICENSE file makes us *eligible to apply*; acceptance is Greptile's call, not automatic. |
| **Greptile — find the second installation** | **URGENT — free** | **$0** | — | The audited org shows 8 reviews this month; this repo took **71 completed Greptile reviews** in the window. A second, unaudited installation is serving us and may be billing. |
| **CodeRabbit — enable usage-based reviews, capped** | **BUY** | $0.25/file ≈ **$1.26/PR** | per-file, one org-wide pool | The only lever that removes rate-limit blocking — **up to the cap you set**; past it, reviews queue again. **196 of 290 reviews were rate-limited and 36% of blocked PRs merged unreviewed** — that is a correctness problem, not just a latency one. |
| **CodeRabbit — Pro → Pro+** | **CONDITIONAL** | 3 seats: **$144/mo annual** or **$180/mo monthly** (vs $72 / $90 on Pro) | per-seat | Genuinely doubles the per-developer hourly allowance (see the corrected Fair Usage reading below). Helps bursts; does not guarantee zero blocking. |
| **CodeAnt — apply the 100% OSS discount** | **BUY (free)** | $48 → **$0** | per-org waiver | Public repo, qualifies on its face. |
| **CodeAnt — buy a third seat for the CI identity** | **DON'T BUY** | +$24/user/mo | per-seat | Path B (fix the email) achieves the same thing for $0. |
| **Graphite — Starter tier** | **DON'T BUY** | $20/user/mo annual | per-seat | Buys org-repo support; **no documented increase in AI review allowance** over free Hobby — both tiers are published only as "Limited AI Reviews", with no number attached to either. |
| **Graphite — Team tier** | **DON'T BUY (revisit)** | $40/user/mo annual | per-seat | Unlimited AI reviews, but Graphite produced findings on 9 of 244 PRs and was sole-source once. Revisit after ≥30 PRs under the paid plan, per #1199's trigger. |
| **CodeAnt CLI daily cap** | **NO PAID LEVER EXISTS** | — | — | The ~10 agent-reviews/day cap is undocumented and unpriced. The App is a separate pool and satisfies the merge gate alone, so the CLI cap is never blocking. |

**The recommended set costs $0 in new recurring spend** — four of the six actions are settings changes or discount applications — plus one capped, opt-in metered budget for CodeRabbit (suggested **$50/month** = 200 files ≈ **67 PRs at the 3-file median, or ≈40 at the 5.04-file mean**). It also plausibly *reduces* spend, since the BugBot scope changes attack a four-figure line.

## Corrected reading: how CodeRabbit's cap actually binds

This deserves its own section because the obvious reading is wrong in both directions, and #1202's premise inherited one of the errors.

**Our rules model `~8` reviews/hour.** The vendor's Pro allowance is **5/hour**, further reduced by a Fair Usage tier keyed to *trailing-7-day volume* **per developer identity**:

| Trailing 7-day reviews | Pro | Pro+ |
|---|---|---|
| 0–29 | 5/hr | 10/hr |
| 30–39 | 4/hr | 8/hr |
| 40–49 | 3/hr | 6/hr |
| 50–59 | 2/hr | 5/hr |
| 60–69 | **1/hr, one at a time** | 4/hr |
| 70–79 | 1/hr | 3/hr |
| 80–89 | 1/hr | 2/hr |
| 90+ | 1/hr | **1/hr, one at a time** |

**The trap: applying org-level volume to a per-developer limit.** 290 reviews/month across the org looks like it lands in the bottom row, which would make Pro+ worthless. It does not. The dashboard splits that volume across seat holders — faculoyarte 170/month (≈40 per 7 days → **Pro 3/hr, Pro+ 6/hr**) and auerbachb 120/month (≈28 per 7 days → **Pro 5/hr, Pro+ 10/hr**). Both sit in bands where **Pro+ roughly doubles the allowance**. An earlier draft of this document concluded "Pro+ buys nothing"; that was the org-level error, and it is recorded here so the next reader does not repeat it.

**But Fair Usage is not the dominant cause either.** At 3–5/hour, 290 reviews spread evenly over a month would never block. The dashboard's own numbers point elsewhere: **196 of 290 reviews rate-limited (68%)**, **average review wait 87.4 hours**, **2 of 3 seat-holders affected**. That is burst concurrency — many PRs opened by one author inside one hour — with a queue that then backs up for days. Doubling 3/hr to 6/hr shortens the queue; only the metered path removes it.

**The number that should drive the decision is neither of those.** It is **36% of blocked PRs merged unreviewed.** At that point the cap has stopped being a throughput cost and become a coverage gap: roughly one in three blocked PRs shipped with no CodeRabbit review at all.

## The pricing and quota matrix

One row per tool × surface. "Pool" answers the question a price alone cannot: *which* ceiling does this money raise.

### CodeRabbit

Sources — *public:* [pricing](https://www.coderabbit.ai/pricing), [plans and rate limits](https://docs.coderabbit.ai/management/plans), [usage-based add-on](https://docs.coderabbit.ai/management/usage-based-addon), retrieved 2026-08-21. *Dashboard:* `app.coderabbit.ai/settings/billing`, same date.

| Surface | Current plan | Included quota / rate limit | Upgrade tiers | Metered? | Marginal cost/review | Billing unit | Pool |
|---|---|---|---|---|---|---|---|
| **GitHub App** | **Pro, 3/3 seats, monthly billing, $90/mo**, renews 2026-08-27 *(dashboard)* | 5 PR reviews/dev/hr, 150 files/review, 50 chats/hr — degraded by Fair Usage | Pro+ $48/dev/mo annual, $60 monthly → 10/hr; Enterprise (contact) → 12/hr | **Yes** — currently **OFF** | **$0.25/file ≈ $1.26/PR** (mean 5.04 files); historical dashboard charges ran **$0.25–$5.75/review** | per-seat for the plan, **per-file** for metered | **Shared with CLI** for metered: "one pay-as-you-go billing path across all PR and CLI reviews" |
| **CLI** (`coderabbit review`) | Same Pro plan | 5 CLI reviews/dev/hr, 150 files/review | Same ladder | **Yes** — `coderabbit review --use-credits` | $0.25/file | per-file | Metered pool **shared** with App; *included* hourly allowances are **independent** per-surface counters |

Public plan ladder (reviews per developer per hour):

| Plan | Price | PR | IDE | CLI | Files/review | Chat |
|---|---|---|---|---|---|---|
| Free | $0 | 1 | 3 | 3 | 150 | N/A |
| **OSS** | **$0** (public repos, Pro+ features) | **1–10**, per repository, scaled by "community and popularity" | 1 | 3 | 100–300 | 25 |
| **Pro** (ours) | $24/dev/mo annual, **$30 month-to-month — we pay monthly** | 5 | 5 | 5 | 150 | 50 |
| Pro+ | $48/dev/mo annual, $60 monthly | 10 | 10 | 10 | 300 | 100 |
| Enterprise | Contact sales | 12 | 12 | 12 | 300 | 100 |

**We are paying the monthly rate.** 3 seats × $30 = $90/mo. Switching the same 3 seats to annual billing is **$24/seat = $72/mo, a $216/year saving at identical capability** — the cheapest untaken lever on this tool, and it is not an upgrade at all.

**Usage-based add-on** (Pro/Pro+ only, admin-only, not during trial, Enterprise excluded from self-serve):

| Metric | Value |
|---|---|
| Price per credit | **$1.00** |
| Files reviewed per credit | **4** |
| Cost per reviewed file | **$0.25** |

Continuation modes: **Automatic** (bill everything), **On demand** (pause; an assigned-seat developer authorizes each review after seeing billable file count and maximum price), **Off**. Monthly cap configurable or Unlimited; over-limit reviews stop at the cap and resume when raised or when the period resets. Postpaid. Reviews over 300 files cannot use the metered path at all.

*Dashboard note:* usage-based reviews are **OFF** today but were **ON about three months ago**, with recorded per-review charges of **$0.25–$5.75**. That range is the best available empirical check on the $1.26/PR estimate — consistent, with a long tail on large PRs.

**Seat coverage gap.** Seats are assigned to `auerbachb`, `faculoyarte`, `zilbermang`. Unassigned: `davidpetersen`, `mirkosalvato1-ctrl`, `paulkathat-lmc`, plus `dependabot` and `cursor`. PRs authored by unassigned humans receive **no CodeRabbit review** — the other reviewers in the chain are unaffected, so the merge gate can still be satisfied by CodeAnt, but CodeRabbit's finding coverage has a hole no rate-limit lever addresses. `paulkathat-lmc` opened a PR 10 days before retrieval.

**Two repo-specific facts:** public repositories under 10 stars require **manual review triggering** (this repo has 3 stars), and a rate-limited push posts a **passing** check named "Review rate limited" — passing by design so it never blocks merging. The comment, not the check, is the authoritative signal that no review ran.

**Volume setting:** review profile is **Assertive**, the noisiest of quiet/chill/assertive. Switching to `chill` is the largest comment-volume lever and **does not change the rate limit** — it trades noise, not throughput.

**The CLI is not drawing on the paid seat.** Observed while producing this document (2026-08-21): after three local reviews the CLI returned `{"type":"error","errorType":"rate_limit",...,"metadata":{"isProUser":false,"waitTime":"47 minutes"}}`. **`isProUser: false`** means this machine's CLI is authenticated as something other than one of the three paid Pro seats, so it receives the **Free tier's 3 CLI reviews/hour** rather than Pro's 5 — the $90/month buys nothing on this surface. Worth checking `coderabbit auth` against the seat list before concluding any CLI cap is a plan limit; it may just be an unattached identity, which is free to fix.

### CodeAnt

Sources — *public:* [pricing, "AI Code Review" tab](https://www.codeant.ai/pricing), retrieved 2026-08-21. *Dashboard:* `app.codeant.ai/auerbachb/subscription`, same date.

| Surface | Current plan | Included quota / rate limit | Upgrade tiers | Metered? | Marginal cost/review | Billing unit | Pool |
|---|---|---|---|---|---|---|---|
| **GitHub App** | **Premium, 2/2 seats, ACTIVE, ~$48/mo** *(dashboard)* | **Unlimited PR Reviews** | Enterprise (contact) adds SSO, on-prem/VPC, SLAs — **not** more reviews | No, and none needed | **$0** | per-user/month | Separate from CLI |
| **CLI** (`codeant review`) | Same Premium plan | **~10 agent reviews/day** — undocumented, observed only. One `review` invocation issues several `agent/turn` calls (5 files/turn), so one run is not one unit. 15-file cap per run. | **None published** | **No** | **No paid lever exists** | — | Separate from App — the App served 234 reviews on a day the CLI was locked out |

Public plans (annual toggle is the page default):

| Plan | Price | Includes |
|---|---|---|
| Free trial | $0, 14 days | 100 PR reviews, unlimited seats, all premium features |
| **Premium** (ours) | **$24/user/mo annual, $30/user/mo monthly** | **Unlimited PR Reviews**, unlimited summaries/chat, unlimited custom prompts, SAST on PRs, CI/CD integration |
| Enterprise | Contact sales | Premium plus on-prem/VPC, SSO/SAML/SCIM, SLAs |
| **Open source** | **100% off** — contact required | — |

**Drift since the 2026-06 audit:** that audit recorded a **$10/user/mo Basic tier with 100 reviews/month**. It is **gone** from the page as of 2026-08-21. Any reasoning that assumed a cheap metered CodeAnt tier is stale — the only paid AI-Code-Review tier is Premium, and it is unlimited.

**Seats are full (2 of 2, 0 left):** `bretton.auerbach@gmail.com` (Admin) and `faculoyarte@gmail.com` (Member). AI credits balance $0.00.

### Cursor BugBot

Sources — *public:* [pricing](https://cursor.com/pricing), [May 2026 billing change](https://cursor.com/blog/may-2026-bugbot-changes), [spend limits](https://cursor.com/help/account-and-billing/spend-limits), retrieved 2026-08-21. *Dashboard:* `cursor.com/dashboard/spending`, `/billing`, `/automations/from-cursor/bugbot`, same date.

| Surface | Current plan | Included quota / rate limit | Upgrade tiers | Metered? | Marginal cost/review | Billing unit | Pool |
|---|---|---|---|---|---|---|---|
| **GitHub App** (only surface — BugBot ships no CLI) | **Ultra, $200/mo** *(dashboard)*, renews 2026-08-28 | Plan "includes at least $400 of Other Models usage" — **100.0% consumed**, of which `github_bugbot` is 96.1%. Then on-demand: **$999.87 of a $1,000.00 fixed cap** | **None — Ultra is the top individual plan.** The only control is the Monthly Limit field (Fixed or Unlimited) | **Yes — metered by default since the seat fee was retired** | **$1.58/review measured** (516 reviews, $815.58); vendor-stated average $1.00–$1.50 | per-user (Individual) / per-team (Teams) | Single pool |

**The seat model is gone.** Cursor's announcement (2026-05-11): Bugbot moved "from a $40 per seat per month subscription to usage-based billing," effective at each customer's first renewal after **2026-06-08**. The $40/seat figure in the 2026-06 audit is retired.

**Public plan ladder:** Hobby free (no Bugbot), Pro $20/mo, Pro+ $60/mo, Ultra $200/mo — each "Bugbot on usage-based billing"; Teams $40/user/mo ("Agentic code reviews with Bugbot"); Enterprise custom with pooled usage. Included third-party-model usage: Pro $20/mo, Pro+ $70, Ultra $400.

**Unresolved attribution — settle before touching the cap.** The Billing & Invoices page itemizes the on-demand cycle as `github_bugbot`: 1.3B tokens, quantity **516**, **$815.58**; plus `claude-sonnet-5-thinking-high`, quantity 48, $184.29. The operator's position ([#1204](https://github.com/auerbachb/claude-code-config/issues/1204)) is that this spend is pay-per-use model usage while coding in the Cursor app, not BugBot. Both readings are recorded because they lead to opposite actions: if the invoice is right, BugBot is a ~$400–815/cycle line and the scope settings below are urgent; if the operator is right, Cursor is mislabelling IDE usage as `github_bugbot` — which also explains the Other-Models bucket reading 100% — and that is a support ticket, not a purchase. **Raising the cap is the wrong first move under either reading.**

**Settings that multiply cost** (`/automations/from-cursor/bugbot`) — every one of these is free to change:

| Setting | Current | Effect |
|---|---|---|
| Trigger Mode | **Every Push** | Re-reviews on every commit rather than once per PR |
| Incremental Review | **Off** | Each re-review is a **full** re-review, not a delta |
| Effort Level | **High** | Vendor: high effort finds 35% more bugs at higher cost; resolution rate stays 80% |
| Review Draft PRs | **On** | Bills work-in-progress |
| Autofix Mode | **Create New Branch**, threshold Low/Med/High | **299 runs, 0 merged** — billed at plan rates for zero realized value |

Coverage: `auerbachb` 64/64 repos, `LocalMovers-dot-com` 23/23, `faculoyarte` 0/1. Analytics: 324 PRs reviewed, 515 issues, 89.8% resolved.

**Spend-limit mechanics:** on-demand "must be enabled to view and set spend limits"; at the limit, "AI features stop working for that specific user" until the next billing cycle. Individual plans set per-user limits; Teams set team-level limits; Enterprise sets both.

### Greptile

Sources — *public:* [pricing](https://www.greptile.com/pricing), retrieved 2026-08-21. *Dashboard:* `app.greptile.com/localmovers-com` settings and analytics, same date.

| Surface | Current plan | Included quota / rate limit | Upgrade tiers | Metered? | Marginal cost/review | Billing unit | Pool |
|---|---|---|---|---|---|---|---|
| **GitHub App** (only surface — no CLI) | **Canceled 2026-06-18 → Free tier, $0** *(dashboard)*. Free plan **not yet explicitly activated** | Free: unlimited repos, **50 credits/month, 1 active developer** | Pro **$30/seat/mo** (50 credits/seat); Enterprise custom | **Yes** — **$1.00 per additional credit** | **$1.00** standard review, **$3.00** TREX | per-seat **and** per-credit | Single pool |

Credit weights, verbatim: "1 credit = 1 standard review", "3 credits = 1 trex review". Last billed period (May 18 – Jun 18, still on Pro): 117 reviews / 117 credits — faculoyarte 116 (+66 flex credits), paulkathat-lmc 1. Final invoice: **0 active developers, $0**.

**A 71-versus-8 discrepancy that needs closing.** The audited Greptile org (LocalMovers.com) reports **8 reviews this month**. This repo saw **132 `@greptileai` triggers** in the window, which produced **71 completed Greptile review objects across 69 PRs** (both counts verified against the GitHub API, 2026-08-21) — all of it *after* the June cancellation. **Credits bill against completed reviews, not triggers**, so 71 is the figure that matters for cost; the 61-trigger gap is retries and no-ops. #1199's census matches at 71 review objects, and recorded **zero refusals**. Those reviews are therefore served by an installation that #1204 did not open. Three consequences:

1. **There may be a second Greptile account with its own billing state**, unaudited. Find it before assuming $0.
2. **If it is on Free**, 71 reviews/month runs about 1.4× the 50-credit allowance — over, but far less dramatically than the trigger count implied. The overage is ~21 credits, and the reviewer we lean on hardest could still stop without warning. Any TREX reviews in that 71 would bill at 3 credits each and push the overage higher; the review objects do not distinguish the two modes, so 71 credits is a **floor**, not an exact figure.
3. The audited org's settings — auto-review **OFF**, label-gated to `greptile`, drafts off, strictness **Low** — do not describe whatever is reviewing this repo. Our agent's explicit `@greptileai` comment triggers bypass label gating, which is consistent with the census's "132 triggers, all posted by the PR author."

**Two discounts not being claimed.** "Greptile is free for qualified non-commercial projects with MIT or Apache licenses" — this repo is public and has **no LICENSE file at all**, so it cannot qualify today. Adding an MIT or Apache LICENSE makes it *eligible to apply*; the page routes through an "Apply for OSS" form, and the "qualified non-commercial" wording means acceptance is Greptile's judgement, not an automatic entitlement. Treat $0 as the outcome to pursue, not one to assume. Separately, pre-Series A companies under $2M trailing revenue get 50% off.

**The 2026-06 "cut the seat" verdict is superseded** — and was already acted on. That audit judged Greptile on 4 firings in 8 weeks and recommended cancellation; the seat was canceled in June. Volume arrived afterwards: #1199 measured Greptile **sole-source on 41 PRs**, the highest of any tool in the window. The live question is no longer "is a dormant fallback worth $30" but "we are depending on a canceled tool — is that dependency safe?"

### Graphite

Source — *public:* [pricing](https://graphite.com/pricing), retrieved 2026-08-21. No dashboard reading: [#1204](https://github.com/auerbachb/claude-code-config/issues/1204) scoped Graphite out because it is newly paid and the audit measured it pre-payment, making its re-measure trigger evidence-based (≥30 PRs under the paid plan) rather than a billing question.

| Surface | Current plan | Included quota / rate limit | Upgrade tiers | Metered? | Marginal cost/review | Billing unit | Pool |
|---|---|---|---|---|---|---|---|
| **GitHub App** | Newly paid, **tier unread** | **"Limited AI Reviews"** on Hobby **and Starter** — the limit is not published anywhere | Starter $20/user/mo annual ($25 monthly); **Team $40/user/mo annual ($50 monthly)** for **Unlimited AI Reviews** | No metered option | **$0** marginal at Team; unpriced below it | per-seat | Single pool |
| **CLI** (`gt`) | Same account | Stacking/PR CLI on every tier including free Hobby — **no AI review quota attached** | — | — | n/a — does not consume AI review quota | per-seat | n/a |

**The $20 tier is a trap for this use case.** Starter buys org-repo support, Slack notifications, and team insights. Its AI review allowance is published as **"Limited"** — the same label free Hobby carries, with **no number attached to either**, so there is **no documented increase** between them. Graphite may in fact grant Starter more reviews than Hobby; nothing on the page says so, and confirming it would take dashboard access or a measured trial. Only **Team at $40/user/mo annual** states Unlimited AI Reviews, plus review customization, automations, and merge queue. Any "spend $20 to get more Graphite reviews" reasoning is buying an undocumented change.

## Reconciling observed limits against documented ones

Each cap incident from #1199, mapped to a matrix row and a verdict.

### 1. BugBot refusing every trigger — "Bugbot couldn't run — usage limit reached" (156 of 224 PRs)

| | |
|---|---|
| **Documented** | Bugbot bills from included usage, then on-demand spend. On-demand must be enabled to set limits. At the limit, "AI features stop working for that specific user" until the next cycle. |
| **Observed (PRs)** | A `Cursor Bugbot` check-run with `conclusion: success` **alongside** a `cursor[bot]` comment carrying a failure phrase. The success check-run makes this a silent pass unless the comment is read; `merge-gate.sh` blocks that path when such a comment postdates the HEAD commit. |
| **Observed (dashboard)** | On-demand **$999.87 / $1,000.00, fixed cap, 100% consumed**; included Other-Models bucket also 100% consumed. |
| **Reconciliation** | Exact agreement — this is the documented spend-cap behavior, reached rather than misconfigured. **The earlier hypothesis that on-demand was simply switched off is wrong**: it is on, funded, and exhausted. |
| **Verdict** | **A priced fix exists but is not the right first move.** Raising the cap costs ~$400–500/month at current run-rate and is blocked on the attribution dispute. **The free fix is the settings**: Every Push → per PR, Incremental Review → On, Drafts → Off, Effort High → Medium, Autofix off (0 of 299 merged). Re-measure a full cycle, then decide on the cap. |

### 2. CodeAnt "not subscribed" on the App, and 403 on the CLI

These look like one problem and are two, with different pools and opposite verdicts.

| | App surface | CLI surface |
|---|---|---|
| **Documented** | Premium is "Unlimited PR Reviews" | Nothing — the daily agent-review cap is undocumented |
| **Observed** | "User ci@example.com does not have a PR Review subscription" on 206 of 244 PRs — **alongside 360 `APPROVED` reviews across 184 PRs**. Non-blocking. Dashboard confirms Premium ACTIVE with 2/2 seats held by `bretton.auerbach@gmail.com` and `faculoyarte@gmail.com`; the CI commit email is not among them. | `403` with `"Either the API key is invalid or the daily limit of 10 for agent review has been reached"`. `codeant scans orgs` succeeds while `review` 403s — the token is fine. |
| **Reconciliation** | Not a billing failure. The plan is Premium and unlimited; the warning is seat attribution against an unrecognized commit-author email, and CodeAnt reviews anyway. | A real, unpublished quota on a pool the dashboard does not surface. "AI Code Reviews: Unlimited" describes the **App**, which kept serving 234 reviews the same day the CLI was locked out. |
| **Verdict** | **No purchase needed.** Set the git `user.email` to a seat holder — **$0**. Buying a third seat for the CI identity (+$24/user/mo) achieves the same result and is strictly worse. | **No paid lever exists.** No published upgrade raises the CLI agent cap. Mitigation is operational: budget a few CLI reviews/day and never re-authenticate to clear a 403 — it cannot fix a quota and nulls the token. The App satisfies the CR-path merge gate alone, so a capped CLI is never blocking. |

### 3. CodeRabbit hourly contention across four competing PRs

| | |
|---|---|
| **Documented (our rules)** | `~8` PR reviews/hour — `cr-rate-limits.md` and `cr-review-hourly.sh`'s default budget |
| **Documented (vendor)** | Pro includes **5** PR reviews/dev/hour as a **rolling** allowance, further reduced by Fair Usage against trailing-7-day volume **per developer** |
| **Observed (PRs)** | "Review limit reached" on **223 of 244 PRs**; CodeRabbit substantively reviewed **53 (22%)** |
| **Observed (dashboard)** | **196 of 290 reviews rate-limited (68%)**; average wait **87.4h**; **36% of blocked PRs merged unreviewed**; faculoyarte 170 reviews / 110 blocked, auerbachb 120 / 86 |
| **Reconciliation** | Our `8/hr` figure is wrong in magnitude (Pro is 5) and in shape (the meter is rolling-window and volume-degraded). But Fair Usage is **not** the dominant cause: per-developer trailing volume puts faculoyarte at 3/hr and auerbachb at 5/hr, which even-paced would never block 68% of reviews. The binding constraint is **burst concurrency** — many PRs opened in one hour by one author — with an 87-hour queue behind it. |
| **Verdict** | **A priced fix exists, and there are two of them.** (a) **Enable usage-based reviews at $0.25/file** — removes rate-limit blocking **up to whatever monthly cap you set**, after which reviews queue again; ~$50–150/month covers the current overflow, and it requires completing the flagged-incomplete billing profile. (b) **Pro+ for 3 seats: $144/month annual or $180/month monthly** (against $72 / $90 on Pro — so **+$72/month** comparing annual to annual, **+$90/month** comparing monthly to monthly) — doubles the per-developer allowance (3→6/hr, 5→10/hr), shortens the queue, does not guarantee zero blocking. Free adjuncts: assign the unassigned authors' seats, and spread PR opens across the hour. **A separate free saving: switch the same 3 seats from monthly to annual billing — $90 → $72/month.** |

## Break-even math

**Demand.** 245 merged PRs in the window (2026-07-22 → 2026-08-21), consistent with #1199's 244-PR census. Size profile, measured for this ticket because the census did not collect it:

| Metric | Files changed |
|---|---|
| Mean | **5.04** |
| Median | 3 |
| p90 | 11 |
| Max | 27 |
| **Total across 245 PRs** | **1,235** |

**Target.** Every merged PR reviewed at least once by a reviewer that can satisfy the merge gate.

| Lever | Monthly cost at full coverage | Cost per PR reviewed |
|---|---|---|
| **CodeAnt Premium** (current, unlimited, 2 seats) | $48 | **$0.196** |
| **CodeAnt via OSS discount** (if accepted) | **$0** | **$0** |
| **Greptile via OSS program** (needs a LICENSE file, then acceptance) | **$0** | **$0** |
| **CodeRabbit Pro, annual instead of monthly** (3 seats) | $72 *(saves $18/mo)* | $0.294 |
| CodeRabbit Pro (current, monthly, 3 seats) | $90 | $0.367 |
| Graphite Team | $40/seat | $0.16/seat — *if* it reviewed everything, which it does not |
| **Greptile Pro + overage** (71 completed reviews: 50 included + 21 × $1) | **~$51** | **$0.72** |
| **CodeRabbit metered overflow only** (~196 blocked reviews) | **$50–150** | **$0.25–0.77** |
| CodeRabbit metered, all 245 PRs (1,235 files × $0.25) | $309 | $1.26 |
| CodeRabbit Pro → Pro+ (3 seats) | $144 annual / $180 monthly | +$72 or +$90 over Pro at the same cadence; doubles allowance, blocking reduced not eliminated |
| **BugBot at measured run-rate** (516 reviews × $1.58) | **$815** | **$1.58** |
| Graphite Hobby → Starter | +$20/seat | **no documented additional reviews** — both tiers publish only "Limited" |

Two rows look like upgrades and are not: **Graphite Starter** costs real money for an AI-review allowance that is not documented to change, and **raising the BugBot cap** funds a line item nobody has yet confirmed is BugBot. Both are the natural instinct when a cap bites.

**Sizing the CodeRabbit lever.** A **$50/month** cap buys 200 reviewed files — **≈67 PRs at the 3-file median, ≈40 at the 5.04-file mean**. That is not full coverage and is not meant to be: with CodeAnt unlimited and Greptile cheap-or-free, CodeRabbit's credits should be reserved for PRs where its finding profile is worth $1.26 — not spent automatically on every incremental push. This is why **On demand** beats **Automatic**, and it is the difference between a $50 bill and a $309 one. The historical dashboard range of **$0.25–$5.75 per review** confirms the tail risk that makes Automatic unattractive. Note the cap is a stop, not a smoother: once it is reached, over-limit reviews queue exactly as they do today until an admin raises it or the month rolls over.

**Putting a number on the Greptile "bad deal" judgment**, as #1202 asks. Bill against **completed reviews, not triggers**: 132 `@greptileai` triggers produced **71 completed reviews**. The free Starter tier covers 50 of those at $0; Pro covers all 71 for $30 + 21 overage credits = **~$51/month**, or **$0.72/review** — and that is a floor, since any TREX reviews among the 71 bill at 3 credits rather than 1. Against its measured output — sole-source on **41** PRs, the highest of any tool — $51/month is roughly **$1.24 per sole-source finding**, comfortably the best value-per-unique-finding in the stack. **The "really bad deal" judgment does not survive contact with the numbers**; it was correct on 2026-06 evidence (4 firings in 8 weeks) and was overtaken by volume that arrived after the cancellation took effect. Pursue the OSS program first because $0 beats $51, but $51/month is a perfectly defensible fallback if the application is refused — not a reason to stay off Greptile.

## Which pool each price buys

#1202 asks this explicitly, because buying one lever may not raise the other.

| Tool | Do CLI and App share a pool? |
|---|---|
| **CodeRabbit** | **Split, then shared.** *Included* allowances are independent per-surface counters (5 PR/hr and 5 CLI/hr are separate budgets). The *metered* add-on is a **single org-wide pay-as-you-go path covering both** — one purchase raises both surfaces. |
| **CodeAnt** | **Separate.** Documented App "Unlimited" and the undocumented ~10/day CLI agent cap are independent; the App served 234 reviews on a day the CLI was locked out. Buying Premium does not raise the CLI cap, and nothing else does either. |
| **Cursor BugBot** | **N/A — no CLI surface.** Single pool, shared with all other Cursor on-demand usage, which is precisely why the attribution dispute matters. |
| **Greptile** | **N/A — no CLI surface.** Single credit pool, per installation — and we appear to have more than one installation. |
| **Graphite** | **N/A for AI reviews.** The `gt` CLI does stacking and does not consume AI review quota. |

## Owner action list

None of these are agent-executable. Ordered by value per unit of effort; the first four cost nothing.

1. **Fix the BugBot scope settings** — Trigger Mode to once-per-PR, Incremental Review on, Draft PRs off, Effort to Medium, Autofix off. Attacks a four-figure line for $0. Autofix has produced 299 branches and zero merges.
2. **Resolve the Cursor attribution dispute** before raising any cap — open a support ticket citing the `github_bugbot` line (1.3B tokens, qty 516, $815.58) against the operator's account of IDE usage. The Other-Models bucket reading 100% with 96.1% tagged `github_bugbot` is the evidence to lead with.
3. **Set git `user.email` to a seat holder** so CodeAnt stops flagging commits as unlicensed. $0; avoids a $24/month third seat.
4. **Switch CodeRabbit from monthly to annual billing** — same 3 seats, $90 → $72/month, $216/year, no capability change.
5. **Attach the CodeRabbit CLI to a paid seat.** The CLI reports `isProUser: false` and is being limited at the Free tier's 3 reviews/hour despite $90/month in seats. Free to fix, and it raises the local-review ceiling by 67%.
6. **Locate the second Greptile installation** serving this repo (**71 completed reviews here vs the audited org's 8**) and record its billing state. We are depending on a tool we believe is canceled.
7. **Add a LICENSE file** (MIT or Apache) to this public repo, then apply to Greptile's OSS program — acceptance is their call, so treat $0 as the goal and ~$51/month on Pro as the fallback. Re-check CodeRabbit OSS-tier eligibility while there.
8. **Apply for CodeAnt's 100% open-source discount.** Public repo, qualifies on its face; $48/month to zero.
9. **Enable CodeRabbit usage-based reviews in On demand mode with a ~$50 monthly cap.** Requires completing the billing profile flagged incomplete (name, phone, address). Do **not** use Automatic.
10. **Assign CodeRabbit seats** to unassigned human authors (`paulkathat-lmc`, `davidpetersen`, `mirkosalvato1-ctrl`) or accept that their PRs go unreviewed.
11. **Do not buy** Graphite Starter, a Greptile Pro seat, or a third CodeAnt seat on current evidence. Treat CodeRabbit Pro+ as a second-line option behind the metered lever.

## Deferred: rule-file pointers

This document is deliberately **not** wired into `.claude/rules/`. PR [#1203](https://github.com/auerbachb/claude-code-config/pull/1203) (Issue #1199) is concurrently rewriting the exact sections in `bugbot.md`, `greptile.md`, `cr-github-review.md`, and `cr-local-review.md` where those pointers belong, and its plan consumes the remaining ratchet headroom. Adding them here would guarantee a four-file rebase collision and risk breaching the word cap after rebase. The pointers are a follow-up once #1203 lands; this PR is word-neutral on the rule corpus.
