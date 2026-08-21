# CodeRabbit — OSS Tier vs Paid Pro

Issue: [#1212](https://github.com/auerbachb/claude-code-config/issues/1212)
Evidence base: [`ai-review-tool-audit-2026-08.md`](./ai-review-tool-audit-2026-08.md) — 244 merged PRs, 2026-07-22 → 2026-08-21
Companion records: [#1202](https://github.com/auerbachb/claude-code-config/issues/1202) prices every purchasable lever ([`pricing-matrix.md`](./pricing-matrix.md)); [#1204](https://github.com/auerbachb/claude-code-config/issues/1204) read the billed state ([`ai-review-billing-dashboard-2026-08.md`](./ai-review-billing-dashboard-2026-08.md)); [#1209](https://github.com/auerbachb/claude-code-config/issues/1209) turns incremental review off; [#1213](https://github.com/auerbachb/claude-code-config/issues/1213) holds the billing-cadence lever this verdict gates.
Verdict recorded in: [`ai-review-chain-roles-decision.md`](./ai-review-chain-roles-decision.md) §CodeRabbit OSS tier vs paid Pro.

Date reviewed: **2026-08-21**
Repo under evaluation: `auerbachb/claude-code-config` — **public, 3 stars, no LICENSE** (`gh repo view`, 2026-08-21)

## Verdict

**Stay paid, and switch to annual billing.** $90/mo → $72/mo, **$216/year, no capability change.**

The OSS tier is not a cheaper version of what we have — it is a *differently-constrained* version, and
every constraint it adds lands on throughput, which is the only thing currently failing. Two of those
constraints are documented outright: under 10 stars **reviews stop being automatic** and must be
triggered by a comment, and OSS **cannot buy the metered add-on** that
[`pricing-matrix.md`](./pricing-matrix.md) rates the only lever that removes rate-limit blocking at all.
A third is documented only as a range: the per-developer rate becomes a **1–10/hr band that varies by
star count**, replacing a known 5/hr with an unknown one. It saves $90/month on a tool whose measured
problem is that it already answers too rarely.

**And the $90 would not actually be saved — it would be displaced onto the one uncapped line in the
stack.** Every CodeRabbit review that does not happen falls down the escalation chain, and the chain's
terminus is Greptile: paid Pro on the `auerbachb` org with **flex overage explicitly uncapped** at
$1/credit, already 42 credits into flex 15 days into a cycle (#1204 round 2). CodeRabbit is a fixed
$90; Greptile is an unbounded $1 per additional review. Trading the first for more of the second is the
wrong direction regardless of the sticker prices.

## Sources

Every limit below is pinned to its own citation rather than a shared preamble, per the
[`pricing-matrix.md`](./pricing-matrix.md) convention.

- *public:* [plans and rate limits](https://docs.coderabbit.ai/management/plans), retrieved **2026-08-21** — the plan ladder, the per-developer unit statement, the OSS star-scaling sentences, and the 10-star manual-trigger threshold.
- *public:* [usage-based add-on](https://docs.coderabbit.ai/management/usage-based-addon), retrieved **2026-08-21** — add-on plan eligibility, credit price, continuation modes.
- *public:* [pricing](https://www.coderabbit.ai/pricing), retrieved **2026-08-21** — OSS eligibility wording, Pro and Pro+ per-seat prices.
- *dashboard* (authenticated, not publicly linkable): `app.coderabbit.ai` → Settings ▸ Billing, read 2026-08-21 during [#1204](https://github.com/auerbachb/claude-code-config/issues/1204) — plan, seat count, renewal date, and the rate-limited/wait/unreviewed figures.
- *repo state:* `gh repo view auerbachb/claude-code-config`, 2026-08-21 — visibility, star count, licence.

## Side-by-side

Surfaces match [`pricing-matrix.md`](./pricing-matrix.md) §CodeRabbit. Every rate is **per developer,
per hour** — the docs state it explicitly: *"Unless otherwise noted, PR, IDE, and CLI review limits are
shown per developer, per hour"* ([plans], retrieved 2026-08-21). What differs on OSS is not the unit but
the **number**, which the vendor scales per repository.

| Surface | Paid Pro (today, monthly) | Paid Pro (annual) | **OSS tier** |
|---|---|---|---|
| Cost, 3 seats | **$90/mo** ($30/dev) | **$72/mo** ($24/dev) | **$0** |
| PR reviews / dev / hr | **5**, degraded by Fair Usage | 5, same | **1–10, scaled by repository star count** |
| Effective rate here | 3/hr heavy author, 5/hr light (Fair Usage band placement, #1202) | same | **unknown — the docs publish no star→rate mapping; 3 stars establishes only that we are under the 10-star threshold** |
| Auto-review on open/push | **Yes** — measured at 8–20s (below) | Yes | **No** — manual trigger required under 10 stars |
| Metered overflow | **Available** ($0.25/file), currently OFF | Available | **Not available — Pro/Pro+ only** |
| Files / review | 150 | 150 | 100–300, scaled by "community and popularity" |
| IDE / hr | 5 | 5 | 1 |
| CLI / hr | 5 published — **3 in practice on a public repo** (see below) | same | 3 |
| Chat / hr | 50 | 50 | 25 |
| Feature set | Pro | Pro | **Pro+ features, free** |

Three rows carry the decision — the **PR rate**, **auto-review**, and **metered overflow**. Auto-review is
treated in its own section below, since it is the row our own machinery has to answer for. The remaining
rows are noise at our volume, and two of them are worth a line to say why.

**PR rate — documented as a range, and it stays a range here.** The docs give the OSS band and its
driver — *"OSS PR review limits vary by repository star count"* — but publish **no star→rate mapping**
([plans], retrieved 2026-08-21). Three stars establishes exactly one thing: that this repo is **below the
10-star manual-trigger threshold**. It does **not** establish a position within the 1–10 band, and this
document deliberately draws no such placement — an earlier draft asserted "the bottom of the scale" and
that inference is not supported by anything the vendor publishes.

What the range *does* establish is the shape of the trade: OSS replaces a **known** 5/hr with an
**unknown** rate spanning a 10× spread, on the one axis that is already the binding failure (68% of
reviews rate-limited). Substituting an unknown for a known is a bad trade when the known is the thing
under strain — and unlike the two constraints below, it cannot be checked without actually switching.
The decision therefore rests on the documented constraints, with the unknown rate as a reason for
caution rather than a load-bearing number.

**Metered overflow.** *"The add-on is available on the Pro and Pro+ plans and is not visible during a
trial"* ([usage-based add-on], retrieved 2026-08-21). Free and OSS are not eligible. This answers the
open question the issue raised: **an OSS-tier repo cannot buy metered overflow.** It is also the single
most consequential row, because #1202 rated that add-on **BUY** — the only lever that removes rate-limit
blocking rather than merely widening it.

**Files/review** is the one row where OSS can exceed Pro (up to 300 vs 150), but it is scaled by the
same popularity signal, so a 3-star repo lands near 100 — *below* Pro. It rarely binds either way: the
median PR here is 3 files and the mean 5.04 (#1202).

**The CLI row is not a differentiator at all, and the reason matters.** The local CLI throttles at the
free tier's 3/hr here, but **not because of a seat** — `coderabbit auth status` reports `Plan: Pro` /
`Seat: assigned`, and the CLI names the routing itself: *"This looks like a public open-source
repository… no organization will be billed. Free OSS limits apply."* The `isProUser: false` in the
rate-limit payload names **the pool the review was billed against**, not the account's tier, and that
pool is chosen by **repository visibility** (§Repo variance in
[`ai-review-chain-roles-decision.md`](./ai-review-chain-roles-decision.md), measured 2026-08-21 under
#1213). So on this public repo we get OSS-grade CLI throughput under Pro **and** would get it under
OSS — the row cancels out, and no re-auth changes it. The table's Pro CLI figures below are the
published plan numbers; the effective figure on a public repo is 3/hr on either plan.

## Mapped onto the measured census

The 30-day window (244 merged PRs) says CodeRabbit's problem is availability, not capability:

| Measure | Value | What it implies for OSS |
|---|---|---|
| PRs CodeRabbit produced findings on | **53 of 244 (22%)** | The tool already answers on fewer than one PR in four. A lower rate lowers this further. |
| Inline findings when it did run | **281 across 53 PRs (5.3/PR — densest of any tool)** | Quality is not the problem, so a free tier with *better* features (Pro+) buys nothing we lack. |
| Sole-source PRs | **22** | Real unique coverage that a throughput cut would erode. |
| Reviews attempted / rate-limited | **290 / 196 (68%)** | Two reviews in three are already refused **at 5/hr**. |
| Reviews actually delivered | **94** | The denominator for any cost-per-review figure. |
| Average review wait | **87.4 hours** | The queue backs up for days at the current ceiling. |
| Blocked PRs that merged unreviewed | **36%** | Already a coverage gap, not just latency. This is the figure a rate cut makes worse. |
| Rate-limit banner appeared on | **223 PRs**, sole output on **183** | The failure mode is the banner, and OSS does not change the banner — it lowers the threshold that produces it. |
| Per-author split | 170 reviews / 110 limited, and 120 / 86 | Both seat-holding authors are affected; this is not one outlier. |

**Cost per unit of delivered work.** At $90/mo the paid plan costs **$1.70 per PR it produced findings
on** (53 PRs) or **$0.96 per review delivered** (94 = 290 attempted − 196 rate-limited). At the annual
rate those become **$1.36** and **$0.77**. Treat the two as indicative rather than one ratio: the 53 is
the GitHub census's 30-day window and the 94 is the dashboard's billing period, which overlap but are
not the same window.

For context, one Greptile flex credit — the thing that absorbs the overflow when CodeRabbit refuses — is
**$1.00 per review, uncapped**. So paid CodeRabbit already delivers a review for about what the fallback
charges for one — and for roughly a quarter less on annual billing — before counting the 22 PRs where
CodeRabbit was the only finder at all.

## The manual-trigger requirement, verified against the actual machinery

The requirement, verbatim: *"For public repositories with less than 10 stars, CodeRabbit requires
reviews to be triggered manually"* ([plans], retrieved 2026-08-21). Accepted triggers are the **Trigger
review** button, `@coderabbitai review`, or `@coderabbitai full review`.

**What the repo actually does today** — read from the files, not inferred:

| File | Posts | When | Identity |
|---|---|---|---|
| [`maybe-trigger-ai-review.sh`](../scripts/maybe-trigger-ai-review.sh) | `@codeant-ai review`, `@cursor review`, `@graphite-app re-review` — **never `@coderabbitai`** | agent poll cycle, complexity/round gated | authenticated `gh` session |
| [`cursor-review-pr-comment.yml`](../../.github/workflows/cursor-review-pr-comment.yml) | `@cursor review` | `pull_request: [opened, synchronize, reopened]` | `CURSOR_REVIEW_PAT` (repo owner, **not** `github-actions[bot]`) |
| [`cr-plan-on-issue.yml`](../../.github/workflows/cr-plan-on-issue.yml) | `@coderabbitai plan` | `issues: [opened]` | `github-actions[bot]` via `GITHUB_TOKEN` |
| [`pr-preflight.sh`](../scripts/pr-preflight.sh) | `@coderabbitai full review` | agent-invoked only, gated on `cr-review-hourly.sh`, capped 2/PR/hr | authenticated `gh` session |

**Finding: no unconditional, push-triggered CI workflow posts a CodeRabbit PR-review trigger.** Nothing
needs to today, because auto-review is on. The only `@coderabbitai` PR trigger we emit is
`full review` as an *escalation* after silence — deliberately rate-capped, and fired only while an agent
session is actively driving the PR.

**So OSS adoption would require building that workflow.** Two measurements settle how hard that is, and
they point in opposite directions from the BugBot precedent:

1. **CodeRabbit honours bot-authored triggers — measured.** `github-actions[bot]` posted
   `@coderabbitai plan` on issues [#1209](https://github.com/auerbachb/claude-code-config/issues/1209),
   [#1210](https://github.com/auerbachb/claude-code-config/issues/1210) and
   [#1211](https://github.com/auerbachb/claude-code-config/issues/1211); CodeRabbit answered each with a
   Coding Plan (8.5 min, 3 min, 4 min respectively, all 2026-08-21). This is the **opposite** of BugBot,
   which ignores bot-authored triggers — measured in
   [#892](https://github.com/auerbachb/claude-code-config/issues/892) and the entire reason
   `cursor-review-pr-comment.yml` carries a PAT. A CodeRabbit trigger workflow would therefore not need
   one.
   > **Residual risk, stated rather than buried:** that measurement is on the **issue** surface
   > (`@coderabbitai plan`). No bot-authored trigger has been observed on the **PR** surface, because
   > every `@coderabbitai full review` we post comes from the authenticated session. If bot identity
   > turned out to be rejected there, the mitigation is already built and proven — reuse the
   > `CURSOR_REVIEW_PAT` pattern.

2. **Auto-review is live under Pro and is exactly what would be lost.** PR
   [#1208](https://github.com/auerbachb/claude-code-config/pull/1208) opened 19:26:36Z; CodeRabbit's
   summary landed 19:26:56Z — **20 seconds later, with no trigger comment anywhere on the PR**. PR
   [#1206](https://github.com/auerbachb/claude-code-config/pull/1206): **8 seconds**. Under OSS every one
   of those starts only after a comment we would have to post first.

**Verdict on compatibility:** the requirement is *satisfiable* — the workflow shape exists, the identity
question is answered, and the change is perhaps thirty lines cloned from the Cursor trigger. It is
therefore **not** the reason to decline OSS. The reason is the rate and the lost metered escape hatch;
the trigger work is simply an additional cost that buys nothing.

## The post-#1209 world

[#1209](https://github.com/auerbachb/claude-code-config/issues/1209) turns **Incremental Review off**, so
CodeRabbit reviews once per PR rather than once per push. Demand falls, and the size of the fall is
whatever the average number of review rounds per PR is — a repo where PRs land on the first push saves
nothing, and this one is not that repo (the window's **469 `@cursor review` nudges across 244 PRs**, ≈1.9
per PR, is an indicator of the round count, not a measurement of CodeRabbit's own). **No post-change
number is invented here** — only the direction, and it is down.

**The limit matters more than the direction.** #1202's reading is that at 3–5/hr, this volume spread
evenly would never block; what blocks is **burst concurrency** — several PRs opened by one author inside
one hour. Cutting total volume relieves the **Fair Usage banding**, which keys on trailing-7-day review
count per developer: the heavy author's ≈40/7d sits in the 3/hr band, and any material cut moves them
toward the 4–5/hr bands above it. But it does **not** raise the per-hour ceiling during a burst, and the
burst is what the census blames.

That cuts both ways, and it is why #1209 does not change this verdict: it relieves the volume term on
**either** plan, from a starting ceiling of 5/hr on Pro and from somewhere in 1–10/hr on OSS. It improves
both and reorders neither. One asymmetry does survive: whether the Fair Usage cliff applies to OSS at all
is **not documented**, so #1209's banding relief is a *known* gain on Pro and an *unknown* one on OSS.

## Break-even

**On throughput.** OSS reaches parity only if its popularity-scaled rate lands at **≥5/hr** — the Pro
number — or at ≥3/hr to match the heavy author's Fair-Usage-degraded rate. **Whether it does is not
knowable from the published docs**, which give the band (1–10) and its driver (star count) but no
mapping between them. So this break-even cannot be evaluated in advance, and the only way to resolve it
would be to switch and observe.

**That unresolvability is the finding, not a gap in the research.** A lever whose central number can only
be discovered by pulling it is a bad lever to pull when the two things it *definitely* changes both cut
against us — auto-review stops, and the metered overflow that exists to absorb rate-limit blocking
becomes unbuyable. **The break-even is therefore decided on the documented constraints; the rate is
simply not a reason to move.**

**On money.** The saving is $90/month gross. Against it:

- The metered add-on becomes permanently unavailable, removing #1202's **BUY**-rated lever (a ~$50/mo
  capped budget covering ≈40–67 PRs of overflow).
- Refused CodeRabbit reviews escalate. The chain's last resort is Greptile at **$1/credit with flex
  overage uncapped** (#1204 round 2), which already absorbed **53% of PRs and was sole-source on 41**.
  Displacing even a modest share of CodeRabbit's 94 delivered reviews onto that line consumes the saving
  and keeps consuming past it, because nothing bounds it.
- Trigger-workflow work has to be built and maintained for a capability we get free today.

**Annual vs monthly.** Independent of OSS, and the actual money on the table: **$24/dev/mo annual vs
$30 monthly** ([pricing], retrieved 2026-08-21) — $72 vs $90 for 3 seats, **$216/year at identical
capability**. The trade is 12 months of commitment for 20% off. The commitment is safe here because the
two exits it could block are both remote: OSS is rejected above on throughput, and Pro+ is an *upgrade*
rather than an escape. **Renewal is 2026-08-27** — six days out — so the cadence decision is live, not
hypothetical.

The one condition that would have argued for staying monthly: a near-term expectation of crossing 10
stars **and** evidence that the OSS rate at that popularity meets or beats 5/hr. Neither holds, and the
second is unknowable from the published docs.

## What changes operationally

**If we stay paid (recommended):** nothing. No workflow, script, or rule changes. The billing cadence is
a dashboard action by the owner; the agent side is untouched.

**If OSS were adopted anyway,** for the record:

1. Add a `pull_request: [opened, synchronize, reopened]` workflow posting `@coderabbitai review`, cloned
   from `cursor-review-pr-comment.yml` and carrying its three guards (drafts excluded, owner-authored
   only, never bot-authored). It can use `GITHUB_TOKEN`/`github-actions[bot]` per the measurement above.
2. Fix the trigger rate-cap accounting, which would otherwise go blind. `cr-review-hourly.sh` and
   `/fixpr` Step 3b both count the **literal string `@coderabbitai full review`** — `/fixpr` greps for
   exactly that body — and surface at 2 per PR per hour on the assumption that an explicit trigger means
   escalation. The vendor meters `@coderabbitai review` as a PR review run just the same, so a workflow
   posting the shorter form would consume the allowance while our counter recorded nothing. Either post
   `full review` from the workflow so the existing accounting covers it, or extend the counter to match
   both commands. Beyond the string, the threshold itself changes meaning: under OSS an explicit trigger
   is the routine path rather than an escalation signal, so 2/PR/hour would mis-warn on normal traffic.
3. Accept that #1202's action item 9 (metered reviews, On demand, ~$50 cap) is off the table for good.
4. Expect more escalation to BugBot (spend-capped, refusing 64%) and Greptile (uncapped flex), and budget
   accordingly — see the break-even above.
5. Lose the Pro billing dashboard's usage analytics, which is where #1204 and
   [`/review-stack-audit`](../skills/review-stack-audit/SKILL.md) read the rate-limited, wait-time, and
   merged-unreviewed figures this document is built on.

## Rejected

| Rejected verdict | Why |
|---|---|
| **Move to the OSS tier** | Two documented certainties decide it: under 10 stars auto-review stops (measured today at 8–20s after PR open), and the metered add-on is Pro/Pro+ only, so the one lever that *removes* rate-limit blocking becomes unbuyable. A third consideration is that it swaps a known 5/hr per-developer rate for a star-scaled 1–10/hr band whose value here is undocumented — an unknown substituted for a known on the axis already failing. Saves $90/mo nominally while displacing demand onto Greptile's uncapped $1/credit flex. |
| **Stay paid on monthly billing** | Identical capability to annual at $18/mo more — $216/year for flexibility whose only use would be an exit to OSS (rejected) or to Pro+ (an upgrade, not an exit). |
| **Jump to Pro+ instead of deciding cadence** | Out of scope here and already second-line behind the metered lever in #1202. Doubling the hourly rate shortens the queue; only the metered path removes it. Revisit after #1209 is re-measured. |
| **Defer the cadence decision again** | Renewal is 2026-08-27. Deferring past it costs another month at the monthly rate for no new information — this document is the information the deferral was waiting on. |

## References

- [`ai-review-chain-roles-decision.md`](./ai-review-chain-roles-decision.md) — where this verdict is recorded and the roles it feeds
- [`ai-review-tool-audit-2026-08.md`](./ai-review-tool-audit-2026-08.md) — the 244-PR census every measured figure above comes from
- [`pricing-matrix.md`](./pricing-matrix.md) — the plan ladder, Fair Usage banding, and the owner action list item this verdict gates
- [`ai-review-billing-dashboard-2026-08.md`](./ai-review-billing-dashboard-2026-08.md) — the dashboard readings behind the rate-limited/wait/unreviewed figures
- [`cr-rate-limits.md`](./cr-rate-limits.md) — the cap model our rules carry, and the pacing-proxy caveat
- Issue [#1213](https://github.com/auerbachb/claude-code-config/issues/1213) — the owner paid-levers checklist whose billing-cadence item this verdict unblocks

<!-- Link definitions for the inline citation shorthand used above. -->

[plans]: https://docs.coderabbit.ai/management/plans
[usage-based add-on]: https://docs.coderabbit.ai/management/usage-based-addon
[pricing]: https://www.coderabbit.ai/pricing
