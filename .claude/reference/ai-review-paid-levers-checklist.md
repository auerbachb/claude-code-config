# AI Review Stack — Paid Levers Checklist

Issue: [#1213](https://github.com/auerbachb/claude-code-config/issues/1213)
Dashboard readings every figure rests on: [`ai-review-billing-dashboard-2026-08.md`](./ai-review-billing-dashboard-2026-08.md) (#1204)
Roles the spend buys: [`ai-review-chain-roles-decision.md`](./ai-review-chain-roles-decision.md) (#1199)
Price derivations and break-even math: [`pricing-matrix.md`](./pricing-matrix.md) (#1202)

**Every item here is an owner decision made in a vendor dashboard. None of them are code**, and none
are agent-executable. This file exists because the decisions previously lived only in an archived
thread's exit report: several carry ordering constraints that are easy to lose, and untracked they
get re-derived badly or forgotten.

**This is a standing tracker, not a snapshot.** Unlike its point-in-time siblings
(`ai-review-billing-dashboard-2026-08.md`, `pricing-matrix.md`, the dated audits), this file is
**updated in place** as levers land — status fields change, items close. It is not exempt from
rewrites.

## How this gets worked

A browser co-working session, the way #1204 and #1209 were run: **the agent drives navigation inside
the owner's already-logged-in session and reads state; the owner confirms every account-settings
change live in chat before the click, and the owner performs every click for billing, payments, and
application submissions.** The agent never executes a purchase, a plan change, or a form submission.

**`Submitted:` is not `Approved:`.** Each entry carries both, separately, because an application in
flight must never move a budget line. Change a budget figure only when the owner confirms the
approval landed, and record the date it landed.

Field contract, per entry:

| Field | Meaning |
|---|---|
| `Depends on:` | The gate that must close first. `—` means nothing blocks it. |
| `Submitted:` | Date the owner sent the application / made the request. Empty until then. |
| `Approved:` | Date the vendor confirmed. Empty until then. **Budget lines move here, not above.** |

## Gate state

Measured 2026-08-21, when this file was written. Re-check before working any gated item.

| Gate | Issue | State on 2026-08-21 | Blocks |
|---|---|---|---|
| Free settings applied + re-measured | [#1209](https://github.com/auerbachb/claude-code-config/issues/1209) | **Open** | Item 4 (metered add-on) |
| `LICENSE` file exists | [#1210](https://github.com/auerbachb/claude-code-config/issues/1210) | **Open** — no `LICENSE` in the repo | Item 1 (Greptile OSS) |
| CodeRabbit OSS-tier verdict | [#1212](https://github.com/auerbachb/claude-code-config/issues/1212) | **Open** | Item 3 (billing cadence) |

## The levers

Ordered by annualized dollars at stake, largest first. The order is a priority hint, not an execution
sequence — the `Depends on:` field is what decides when an item may be worked.

### 1. Greptile — apply to the OSS program

- **Depends on:** [#1210](https://github.com/auerbachb/claude-code-config/issues/1210) — the `LICENSE` must land first; the program requires an OSS licence.
- **Submitted:**
- **Approved:**

Largest exposure in the stack after BugBot. The `auerbachb` Greptile org is on paid Pro with **flex
overage uncapped** at $1/credit; at the observed run-rate (~180 credits/month) that is roughly $30
seat + ~$130 flex ≈ **$160/mo** before #1209's cap lands. This repo is the org's largest lifetime
consumer (212 reviews).

Worth keeping either way: Greptile is the **top sole-source finder in the chain** (41 sole-source PRs
in 244) and refused none of 130 requests. So the goal is $0 via the OSS program, and the priced
fallback is **Pro at ~$51/mo** — recommended, not merely tolerated, if the application is refused.

Acceptance is the vendor's call. Record the submission date here and leave the budget line alone
until an approval actually lands.

### 2. CodeAnt — apply for the 100% open-source discount

- **Depends on:** —
- **Submitted:**
- **Approved:**

$48/mo (Premium, 2/2 seats) → $0 if granted. **$576/yr, and nothing gates it** — the highest-value
item that can be worked today. Public repo, qualifies on its face, but the route is
**contact-required** rather than self-serve, so it is a request with a waiting period, not a toggle.

Keep budgeting **$48/mo until approval lands.** CodeAnt is the chain's *sole source of `APPROVED`* on
the CR path, so this account lapsing is a full stop on merges — never let a discount application put
the subscription itself at risk.

### 3. CodeRabbit — decide the billing cadence

- **Depends on:** [#1212](https://github.com/auerbachb/claude-code-config/issues/1212) — the OSS-tier verdict. Deciding cadence first would commit 12 months to a plan #1212 might replace.
- **Submitted:**
- **Approved:**

Annual is $24/seat vs $30/seat monthly: on 3 seats, $72/mo vs $90/mo — **$216/yr**, no capability
change. The catch is only that it is worth doing **if we stay paid at all**. Answer #1212 first; a
successful OSS-tier move makes the saving moot, and an annual commitment taken early would strand it.

### 4. CodeRabbit — decide the usage-based add-on

- **Depends on:** [#1209](https://github.com/auerbachb/claude-code-config/issues/1209) — its free changes must land **and be re-measured**. The overflow is sized against blocked-review volume, and #1209 is expected to cut that volume materially.
- **Submitted:**
- **Approved:**

This is a **spend** that buys back throughput, not a saving. Pre-#1209 the problem was large: 196 of
290 reviews rate-limited (68%), 87.4h average wait, and **36% of blocked PRs merged unreviewed**.

If enabled: **On-demand mode, never Automatic**, with a deliberate monthly cap — **~$50** was the
investigated figure, against **$147–247/mo** to cover the whole pre-#1209 overflow at $0.25/file.
**Completing the billing profile is a prerequisite** (name, phone, and billing address are flagged
missing); the add-on cannot be enabled without it.

Re-measure before sizing the cap. Buying overflow against a number #1209 has already reduced would
overpay for headroom we no longer need.

### 5. CodeRabbit — decide seat coverage for the three unassigned authors

- **Depends on:** —
- **Submitted:**
- **Approved:**

Three human authors hold no seat: `paulkathat-lmc`, `davidpetersen`, `mirkosalvato1-ctrl`. Their PRs
get no CodeRabbit review at all. Two outcomes are acceptable, and **the gap is only acceptable if it
is recorded here as a decision** rather than left as an oversight:

- **Assign seats** — $30/seat/mo monthly, $24/seat/mo annual.
- **Accept the no-review gap explicitly** — write the acceptance and its date into this entry.

**Seat math that pools org volume is wrong.** CodeRabbit's fair usage binds **per developer**, not
per org: Pro is 5 reviews/hour per author, and Pro drops that author to 1/hour after 60+ reviews in a
week. Adding a seat therefore does nothing for an author who already holds one — it only buys
coverage for an author who holds none. That is exactly the case here, which is what makes this a real
choice rather than a throughput lever.

### 6. CodeRabbit CLI — attach to a paid seat *(closed: no action available)*

- **Depends on:** —
- **Submitted:** n/a
- **Approved:** n/a — **closed 2026-08-21 on measured evidence; nothing to submit.**

**The premise behind this item was wrong, and the prescribed fix would not have worked.** It was
recorded (issue #1213 AC 1, `pricing-matrix.md` owner-action item 5) as "the CLI reports
`isProUser: false` and throttles at the free tier's 3 reviews/hour despite the paid seats — re-auth
as one of the three seat holders."

Measured 2026-08-21 with CLI 0.7.5:

1. `coderabbit auth status` reports `Account: auerbachb`, **`Plan: Pro`**, **`Seat: assigned`**. The
   CLI is *already* attached to a paid seat.
2. The CLI states the routing itself: *"This looks like a public open-source repository. CodeRabbit
   will review it for free, and no organization will be billed. Free OSS limits apply."*
3. [`ai-review-chain-roles-decision.md`](./ai-review-chain-roles-decision.md) §Repo variance already
   records the ~3-reviews-then-~40-minute lockout as that free-OSS tier
   (`feedback_cr_cli_free_oss_tier_cap.md`).

So `isProUser: false` describes **the billing route chosen for that review** — free-OSS, no org
billed — not the account's tier. It is a property of the **repository's visibility**, not of the
authenticated identity, so re-authing as a different seat holder cannot lift it. The only lever that
would is making the repo private, which forfeits the CodeAnt and Greptile OSS discounts items 1 and 2
are trying to win.

Cost of leaving it: **visibility, not merge throughput.** The CLIs are advisory and never gate a
merge; the GitHub Apps hold quotas entirely independent of them
(`feedback_review_clis_down_app_independent.md`). Whether CodeRabbit's OSS tier changes any of this
is [#1212](https://github.com/auerbachb/claude-code-config/issues/1212)'s question, and that is where
the thread continues.

## Don't buy

Carried from the #1202 / #1204 investigation so they are not re-litigated from scratch.

| Rejected purchase | Why |
|---|---|
| **Graphite Starter ($20/user/mo annual, $25 monthly)** | Buys org repositories, not more AI reviews — the AI-review allowance stays "Limited," exactly as on Hobby. Graphite is also still *under re-measurement* (1 sole-source PR in 244) and is not promoted on price. |
| **A third CodeAnt seat (+$24/mo)** | Superseded: #1209's commit-identity fix achieves the same result for **$0**. Buying the seat solves a problem a free settings change already closes. |
| **Greptile Pro, before the OSS application is answered** | ~$51/mo for something the OSS program may grant free. It is the *recommended fallback* on refusal (item 1), not a pre-emptive purchase. |
| **CodeRabbit Pro+ ($144/mo annual)** | Stays **second-line behind the metered lever** (item 4). It doubles the per-developer hourly cap and raises the weekly fair-use threshold, but the overflow add-on addresses the same blockage incrementally and is sized to actual overflow rather than to a doubled ceiling. |

## Superseded

Recorded so nobody resurrects them.

- **The Cursor attribution dispute — settled.** The on-demand spend is real BugBot usage:
  **763 runs across 324 PRs**, with per-PR rows and a 1–3 minute event cadence matching a bot
  re-reviewing every push. **No support ticket is needed** (#1204 round 2). This closes
  `pricing-matrix.md` owner-action item 2.
- **"Locate the second Greptile installation" — found.** It is the **`auerbachb` org on paid Pro**,
  with `claude-code-config` as its largest lifetime consumer. Capping its uncapped flex spend is
  #1209 item 1. This closes `pricing-matrix.md` owner-action item 6.
- **"Attach the CodeRabbit CLI to a paid seat" — closed, premise corrected.** See item 6 above. This
  supersedes `pricing-matrix.md` owner-action item 5.

`pricing-matrix.md` is **not edited** to reflect any of these. It is a point-in-time record exempt
from corpus-wide rewrites (`README.md` §"Audits and research"); rewriting it to match today would
falsify the history it exists to preserve. Its now-settled items are superseded **here** instead.

## References

- [`ai-review-billing-dashboard-2026-08.md`](./ai-review-billing-dashboard-2026-08.md) — primary-source dashboard readings (#1204)
- [`ai-review-chain-roles-decision.md`](./ai-review-chain-roles-decision.md) — what each tool's spend buys, and the operator actions the role decision depends on (#1199)
- [`pricing-matrix.md`](./pricing-matrix.md) — priced levers with derivation math (#1202)
- [`review-stack-audit.md`](./review-stack-audit.md) — `/review-stack-audit`, which re-measures billed state against `review-stack-baseline.json` once these levers land
