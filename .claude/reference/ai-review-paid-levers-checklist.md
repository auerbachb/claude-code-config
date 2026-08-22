# AI Review Stack — Paid Levers Checklist

Issue: [#1213](https://github.com/auerbachb/claude-code-config/issues/1213) — **closed 2026-08-22.** Its recorded decisions stand and are carried below; the still-live owner actions moved to [#1228](https://github.com/auerbachb/claude-code-config/issues/1228). This file was synced to those decisions by [#1227](https://github.com/auerbachb/claude-code-config/issues/1227).

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

## Scope boundary — the `auerbachb` org only

Recorded by the owner 2026-08-21 (#1213), and it is load-bearing: **it changed the answer to the seat
question outright.**

Only the **`auerbachb`** GitHub org and its repos are in scope here. Its only active authors are
**`auerbachb`** and **`faculoyarte`**. The rest of the team — **`farwabraza`, `paulkathat-lmc`,
`memibar`** — works in a **separate GitHub org billed to a separate CodeRabbit account**, explicitly
out of scope.

**Any seat or volume math that pools both orgs is wrong.** The earlier reading did exactly that, which
is how item 5 came to say "assign three seats" when the in-scope answer was to *remove* one. Their
no-review gap is not accepted-and-recorded here; it is simply not this account's concern, and belongs
to the other CodeRabbit account.

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

Re-checked 2026-08-22. **All three original gates are now closed.** Nothing from the original set
blocks anything — but item 1 acquired a **new, separate blocker** in their place: the contested
Greptile billing reading, listed as the fourth row below and distinguished from the three by its date
and origin. It gates item 1 exactly as a gate would; it simply is not one of the gates this file was
written around.

| Gate | Issue | State on 2026-08-22 | Blocks |
|---|---|---|---|
| Free settings applied + re-measured | [#1209](https://github.com/auerbachb/claude-code-config/issues/1209) | **Closed** — 3 of its 5 items were **declined** by the owner (see §Declined below), so the re-measurement baseline is *not* the one this gate assumed | Item 4 (metered add-on) — **unblocked, but re-scope it first** |
| `LICENSE` file exists | [#1210](https://github.com/auerbachb/claude-code-config/issues/1210) | **Cleared** — MIT `LICENSE` landed (PR [#1215](https://github.com/auerbachb/claude-code-config/pull/1215)) | Item 1 (Greptile OSS) — **no longer gated by this** |
| CodeRabbit OSS-tier verdict | [#1212](https://github.com/auerbachb/claude-code-config/issues/1212) | **Cleared 2026-08-21 — OSS declined, stay paid** ([`cr-oss-vs-paid-decision.md`](./cr-oss-vs-paid-decision.md)) | Item 3 (billing cadence) — **unblocked** |
| **New blocker, raised 2026-08-21** — Greptile free-vs-paid, from the billing page | [#1228](https://github.com/auerbachb/claude-code-config/issues/1228) | **Open — contested** (see item 1) | Item 1 (Greptile OSS) — **this is what actually blocks it now**, having replaced the cleared `LICENSE` gate |

## The levers

Numbered as originally written; **the numbering is stable, the priority is not.** Work order after the
2026-08-21 decisions: **item 2 (CodeAnt discount) first** — the best ungated move — then **item 5
(cut the seat) before item 3 (annual switch)**, since the cadence applies to the post-cut seat count.
Item 1 is parked until the Greptile billing page is read. The `Depends on:` field, not the number, is
what decides when an item may be worked.

### 1. Greptile — apply to the OSS program *(CONTESTED — settle the billing state first)*

- **Depends on:** an owner check of `app.greptile.com/auerbachb/-/settings/billing` ([#1228](https://github.com/auerbachb/claude-code-config/issues/1228)). The `LICENSE` gate is **cleared** (MIT landed in PR [#1215](https://github.com/auerbachb/claude-code-config/pull/1215)) and no longer blocks this.
- **Submitted:**
- **Approved:**

**Do not apply for anything until the billing page is read.** Two accounts of the same org, on the
same day, disagree:

| Source | Reading |
|---|---|
| The owner (2026-08-21, #1213) | Greptile is **on the free tier and not being paid for** |
| The #1204 round-2 dashboard reading (2026-08-21) | The **`auerbachb`** org is **Pro, Active**, invoice 6 Aug – 6 Sep at $72 ($36 after discount), **flex uncapped**, **92 reviews / 92 credits** logged 15 days into the cycle |

Both cannot be true for one org, and this is **the same shape as the original error**: there are two
Greptile orgs and only one is canceled — `localmovers-com` is canceled/Free, **`auerbachb` is the paid
one, and `auerbachb` is the org that serves the in-scope repos.** A first pass that read the wrong org
is exactly how "$0" was concluded before.

**Either answer kills a branch of work, which is why it is worth ten seconds:**

- **If free/canceled** — the OSS application is **moot**, the LICENSE stops mattering for this item,
  and this entry closes with the reading recorded.
- **If paid** — the exposure is real: roughly $30 seat + ~$130 flex ≈ **$160/mo** at the observed
  ~180 credits/month, uncapped. Then decide cancel vs. keep-deliberately, and cap the flex only if
  keeping.

The case for keeping it, if paid: Greptile measured as the **top sole-source finder in the chain**
(41 sole-source PRs in 244) and refused none of 130 requests. So $0 via the OSS program is the goal
and **Pro at ~$51/mo** is a defensible fallback rather than merely a tolerated one. Weigh that against
disuse — **zero Greptile reviews since PR [#1203](https://github.com/auerbachb/claude-code-config/pull/1203)**,
which proves the tool is idle but says nothing about its price.

Acceptance is the vendor's call. Record the submission date here and leave the budget line alone
until an approval actually lands.

### 2. CodeAnt — apply for the 100% open-source discount *(BEST UNGATED MOVE — do this first)*

- **Depends on:** —
- **Submitted:**
- **Approved:**

$48/mo (Premium, 2/2 seats) → $0 if granted. **$576/yr, and nothing gates it.** With item 1 now
parked behind a contested billing reading, this is **the highest-value action available today** —
reconfirmed by the owner 2026-08-21 (#1213) and carried into
[#1228](https://github.com/auerbachb/claude-code-config/issues/1228). Public repo, qualifies on its
face, but the route is **contact-required** rather than self-serve, so it is a request with a waiting
period, not a toggle. Its position at the top of the working order is why the list below is a
priority hint rather than a numbering.

Keep budgeting **$48/mo until approval lands.** CodeAnt is the chain's *sole source of `APPROVED`* on
the CR path, so this account lapsing is a full stop on merges — never let a discount application put
the subscription itself at risk.

### 3. CodeRabbit — decide the billing cadence

- **Depends on:** [#1212](https://github.com/auerbachb/claude-code-config/issues/1212) — the OSS-tier verdict. **Cleared 2026-08-21: OSS was evaluated and declined, so "stay paid" is settled and this item is unblocked.** Take the annual switch — but **cut the seat in item 5 first**, or you prepay a year for a seat that authors nothing.
- **Submitted:**
- **Approved:**

Annual is $24/seat vs $30/seat monthly, and **the seat count it applies to changed** (item 5). Do the
cut first, then switch:

| Order | Seats | Monthly | Annual |
|---|---|---|---|
| Today | 3 | $90/mo | $72/mo |
| **After the item-5 cut** | **2** | **$60/mo** | **$48/mo** |

So the sequence **$90/mo → $48/mo** is the two levers together, and annual alone is worth **$144/yr**
at 2 seats (not the $216/yr it was worth at 3). No capability change either way. The catch was only
that it is worth doing **if we stay paid at all** — and that question is now answered. [#1212](https://github.com/auerbachb/claude-code-config/issues/1212) declined the OSS
tier on two documented constraints — under 10 stars (this repo has 3) reviews stop being automatic and
must be triggered by comment, and the metered add-on in item 4 is Pro/Pro+ only, so it becomes
permanently unavailable — with the star-scaled 1–10/hr rate band, whose value here the vendor does not
publish, as a third reason for caution rather than a number to rely on. The $90/mo would be displaced
onto Greptile's uncapped flex rather than saved
([`cr-oss-vs-paid-decision.md`](./cr-oss-vs-paid-decision.md)). Nothing now strands the commitment —
the remaining move on this tool is Pro+, which sits second-line behind item 4's metered lever, and
that is an *upgrade* rather than an escape. **Renewal is 2026-08-27**; past that the saving waits a
cycle.

### 4. CodeRabbit — decide the usage-based add-on

- **Depends on:** a re-measurement — but **not the one this item originally assumed.** #1209 is closed with its CodeRabbit item **declined** (Incremental review stays **ON**), so the volume reduction this gate was waiting for **is not coming**. Re-measure against the settings that actually shipped.
- **Submitted:**
- **Approved:**

This is a **spend** that buys back throughput, not a saving. The problem measured large: 196 of
290 reviews rate-limited (68%), 87.4h average wait, and **36% of blocked PRs merged unreviewed**.

**The original sizing logic is void.** It read: wait for #1209 to cut the overflow, then buy the
smaller remainder. But the owner declined turning Incremental review off — deliberately, because it
catches real errors on nearly every push of an AI-authored PR (§Declined). One review per *push*
therefore remains the consumption pattern, so **the overflow this add-on would be sized against does
not fall the way the plan assumed.** Size it against post-decline reality, and expect a larger number
than the "wait for #1209" framing implied. #1228 additionally sequences this **after** the BugBot and
Greptile changes settle the demand picture.

If enabled: **On-demand mode, never Automatic**, with a deliberate monthly cap — **~$50** was the
investigated figure, against **$147–247/mo** to cover the whole overflow at $0.25/file.
**Completing the billing profile is a prerequisite** (name, phone, and billing address are flagged
missing on the account); the add-on cannot be enabled without it.

### 5. CodeRabbit — cut the third seat *(DECIDED 2026-08-21 — this is a saving, not a purchase)*

- **Depends on:** —
- **Submitted:**
- **Approved:** — *decided, not yet clicked. The verdict is settled; the dashboard change is an owner action tracked in [#1228](https://github.com/auerbachb/claude-code-config/issues/1228).*

**This item used to read "assign seats to the three unassigned authors." That was wrong, and the
owner's answer is the opposite: remove a seat.** The original framing pooled two GitHub orgs
(§Scope boundary); re-scoped to `auerbachb` alone, the seat ledger is:

| Handle | PRs in scope | Decision |
|---|---|---|
| `auerbachb` | 427 | **keep seat** |
| `faculoyarte` | 195 | **keep seat** |
| **`zilbermang`** | **0 across every repo swept, both orgs** | **REMOVE — paying for a seat that authors nothing** |
| `davidpetersen`, `mirkosalvato1-ctrl` | 0 authored | no seat |
| `farwabraza`, `paulkathat-lmc`, `memibar` | out of scope | no seat on this account — separate org, separate CodeRabbit account |

**Result: 3 seats → 2.** $90/mo → **$60/mo** monthly, or **$48/mo** once item 3's annual switch is
applied on top. Take this one **before** item 3, so the annual commitment is not prepaid on a dead
seat.

The no-review gap for the out-of-scope authors is **not** "accepted and recorded" here — it is not
this account's concern at all, and belongs to the other CodeRabbit account. Nothing about that is an
oversight to be signed off.

**Seat math that pools org volume is wrong** — the error that produced the original framing, kept
here so it is not repeated. CodeRabbit's fair usage binds **per developer**, not per org: Pro is 5
reviews/hour per author, dropping to 1/hour after 60+ reviews in a week. A seat therefore does
nothing for an author who already holds one, and nothing at all for an author who ships nothing —
which is precisely why `zilbermang`'s seat buys no coverage and no throughput.

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
(`feedback_review_clis_down_app_independent.md`). [#1212](https://github.com/auerbachb/claude-code-config/issues/1212)
answered whether the OSS tier changes any of this: **it does not.** The CLI pool is selected by
repository visibility, not by plan, so a public repo draws free-OSS CLI limits on Pro **and** on OSS —
the surface cancels out of that comparison entirely ([`cr-oss-vs-paid-decision.md`](./cr-oss-vs-paid-decision.md)).

## Don't buy

Carried from the #1202 / #1204 investigation so they are not re-litigated from scratch.

| Rejected purchase | Why |
|---|---|
| **Graphite Starter ($20/user/mo annual, $25 monthly)** | Buys org repositories, not more AI reviews — the AI-review allowance stays "Limited," exactly as on Hobby. Graphite is also still *under re-measurement* (1 sole-source PR in 244) and is not promoted on price. |
| **A third CodeAnt seat (+$24/mo)** | Superseded: #1209's commit-identity fix achieves the same result for **$0**. Buying the seat solves a problem a free settings change already closes. |
| **Greptile Pro, before the OSS application is answered** | ~$51/mo for something the OSS program may grant free. It is the *recommended fallback* on refusal (item 1), not a pre-emptive purchase. |
| **CodeRabbit Pro+ ($144/mo annual)** | Stays **second-line behind the metered lever** (item 4). It doubles the per-developer hourly cap and raises the weekly fair-use threshold, but the overflow add-on addresses the same blockage incrementally and is sized to actual overflow rather than to a doubled ceiling. |

## Declined — owner decisions, 2026-08-21 (#1209)

These were live recommendations in #1209 and were **declined on operator judgment**. They are not
open todos, not deferred, and not pending re-litigation. **A doc that lists them as recommended
settings changes is stale** — the canonical rejection record is
[`ai-review-chain-roles-decision.md`](./ai-review-chain-roles-decision.md) §"Explicitly rejected".

| Recommendation | Decision | Owner's reason |
|---|---|---|
| CodeAnt org **`Auto Approve PR` → Off** | **DECLINED — leave ON** | CodeAnt is the chain's *only* source of `APPROVED`; turning it off strands the merge gate. Not worth changing on current evidence. |
| CodeRabbit **Incremental review → Off** | **DECLINED — leave ON** | It catches real errors on nearly every push of an AI-authored PR. The rate-limit saving does not outweigh losing that. (This is what voids item 4's sizing.) |
| BugBot **Effort High → Medium**, **Trigger Mode Every Push → once per PR** | **DECLINED — the aggressive core stays** | The owner wants the spend down but the review aggressive. These two are deliberately not on the table. |

**BugBot cost reduction is still wanted** — just not by softening the review. The accepted levers, in
descending value, are carried to [#1228](https://github.com/auerbachb/claude-code-config/issues/1228):

1. **Autofix → Off** — 299 runs, **0 ever merged**. Pure waste, and it costs zero review coverage.
2. **Drop the 23 out-of-scope org repos** from BugBot coverage — spend with no value to this account
   under §Scope boundary. Pull the per-repo run split from the analytics page to size it first.
3. **Incremental Review → On** and **Draft PRs → Off** — both cut re-review volume without lowering
   effort on the review that matters.

**Also settled, not declined:** the **commit-identity fix is DONE.** The global git identity was the
placeholder `CI <ci@example.com>` — the actual cause of CodeAnt's "no PR Review subscription" warning
on 84% of PRs — and is now set to the seat-holding address. #1228 verifies it landed on a live PR.

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
- **"Assign CodeRabbit seats to the three unassigned authors" — superseded by the opposite decision.**
  Re-scoped to the `auerbachb` org alone, the answer is to **remove** `zilbermang`'s seat, not add
  three (item 5). This supersedes `pricing-matrix.md` owner-action item 10 and its §CodeRabbit "seat
  coverage gap" paragraph, both of which read three orgs' authors as one pool.

`pricing-matrix.md` is **not edited** to reflect any of these. It is a point-in-time record exempt
from corpus-wide rewrites (`README.md` §"Audits and research"); rewriting it to match today would
falsify the history it exists to preserve. Its now-settled items are superseded **here** instead.

## References

- [`ai-review-billing-dashboard-2026-08.md`](./ai-review-billing-dashboard-2026-08.md) — primary-source dashboard readings (#1204)
- [`ai-review-chain-roles-decision.md`](./ai-review-chain-roles-decision.md) — what each tool's spend buys, and the operator actions the role decision depends on (#1199)
- [`pricing-matrix.md`](./pricing-matrix.md) — priced levers with derivation math (#1202)
- [`review-stack-audit.md`](./review-stack-audit.md) — `/review-stack-audit`, which re-measures billed state against `review-stack-baseline.json` once these levers land
