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

Re-checked 2026-08-22. **All three original gates are closed, and so is the fourth.** Item 1 briefly
acquired a separate blocker — the contested Greptile billing reading, kept as the fourth row below
because it gated item 1 exactly as a gate would — and **that was settled the same day** by reading the
billing page (#1228). **Nothing on this list is blocked.**

| Gate | Issue | State on 2026-08-22 | Blocks |
|---|---|---|---|
| Free settings applied + re-measured | [#1209](https://github.com/auerbachb/claude-code-config/issues/1209) | **Closed** — 3 of its 5 items were **declined** by the owner (see §Declined below), so the re-measurement baseline is *not* the one this gate assumed | Item 4 (metered add-on) — **unblocked, but re-scope it first** |
| `LICENSE` file exists | [#1210](https://github.com/auerbachb/claude-code-config/issues/1210) | **Cleared** — MIT `LICENSE` landed (PR [#1215](https://github.com/auerbachb/claude-code-config/pull/1215)) | Item 1 (Greptile OSS) — **no longer gated by this** |
| CodeRabbit OSS-tier verdict | [#1212](https://github.com/auerbachb/claude-code-config/issues/1212) | **Cleared 2026-08-21 — OSS declined, stay paid** ([`cr-oss-vs-paid-decision.md`](./cr-oss-vs-paid-decision.md)) | Item 3 (billing cadence) — **unblocked** |
| ~~**New blocker, raised 2026-08-21** — Greptile free-vs-paid, from the billing page~~ | [#1228](https://github.com/auerbachb/claude-code-config/issues/1228) | **RESOLVED 2026-08-22 — the org is PAID.** Billing page read live: Active, 6 Aug – 6 Sep invoice $72 → **$36**, **"No cap on flex usage"**. The owner's free-tier account described `localmovers-com`. | Item 1 — **unblocked**; see item 1 for what the answer changed |

| ~~**New blocker, found 2026-08-22 evening** — CodeRabbit billing profile incomplete~~ | [#1228](https://github.com/auerbachb/claude-code-config/issues/1228) | **CLEARED 2026-08-22** — the owner completed the Chargebee billing-details form and applied the seat downgrade. The org now reads `Bretton Auerbach` with the account-incomplete banner gone. | nothing — retained only as the record of what the form gated |

**No gate remains.** Every original gate, the Greptile-billing gate, and the billing-profile gate are
all closed. Nothing on this list is waiting on a prerequisite: what is left is either **decided**
(items 1, 3, 4, 5) or **an outbound request** (item 2).

## The levers

Numbered as originally written; **the numbering is stable, the priority is not.** Work order as of
2026-08-22 close of session: **only item 2 remains open**, and it is an outbound request rather than a
click — a single-repo CodeAnt OSS enquiry with an unknown saving. It is no longer "the best ungated
move" the 2026-08-21 ordering called it, because the $576/yr that ranked it there was an account-wide
figure that is now declined.
**Item 5 is applied** — the owner completed the billing profile and downgraded 3 → 2 seats; the
change is scheduled for the next cycle, so the bill reads `$90` until 27 Aug and `$60` after.
**Item 3 is closed by decision, not deferred** — staying monthly, permanently (see item 3). Nothing on
this list is time-boxed any more: the 27 Aug deadline existed only for the annual switch.
**Item 1 is closed, not first** — its self-serve enrolment was exercised on 2026-08-22 and **refused**
(50-star minimum). It is off the work order entirely until the repo passes 50 stars. **Item 4 is also
closed** — the add-on was already enabled. What is left is item 2 re-scoped to a single repo, and the
**item 5 → item 3** pair, which now share one prerequisite: **completing the CodeRabbit billing
profile.** The `Depends on:` field, not the number, is what decides when an item may be worked.

### 1. Greptile — enrol the repo in the OSS program *(CLOSED 2026-08-22: INELIGIBLE — 50-star minimum)*

- **Depends on:** — nothing gates it; the vendor simply refuses it.
- **Submitted:** 2026-08-22 — the repo was selected in the picker.
- **Approved:** **never — REJECTED.** *"This repository doesn't qualify yet. The program requires at least 50 stars and this repository has 3."*

> **CLOSED — do not re-plan this item at the current star count.** Everything below the rejection
> notice is the 2026-08-22 *morning* reasoning, kept because it explains how a listed-but-ineligible
> repo was mistaken for an available $0 route. **`Submitted:`/`Approved:` did not collapse to one
> date**, as that reasoning predicted; selection triggered an eligibility check that failed.
> Re-open only via the picker's **"Check again"** button if the repo passes 50 stars (it has **3**).

**The correction, in one line: listing is not eligibility.** The picker enumerates every public repo
on the account and validates only on selection. Round 4 of
[`ai-review-billing-dashboard-2026-08.md`](./ai-review-billing-dashboard-2026-08.md) recorded
"present and selectable" after opening the picker and closing it without selecting; Round 5 selected
it and got the refusal. Any future "free tier / OSS route is available" claim on this list must say
whether anyone exercised it.

**What was done instead (2026-08-22, owner-confirmed): keep the subscription, and cap the flex line.**
The `Toggle flex usage cap` switch is now **on** at **$100** — page reads `Stop flex usage after $100
≈ 200 credits · $0.50 each`, `$22 of $100`, verified across a reload. It defaults to $500, which at
~$21/cycle observed burn would never bind. This retires the "flex uncapped" finding that Rounds 1–4
all carried. Keeping was decided on the audit evidence below (top sole-source finder, no cap hit).

**SETTLED 2026-08-22 (#1228): the org is PAID.** The billing page was read live at
`app.greptile.com/auerbachb/-/settings/billing`. The contest above is closed, and the entry that
follows records what the answer changed. Kept rather than deleted so the next reader sees which
account was right and why.

| Source | Reading | Verdict |
|---|---|---|
| The owner (2026-08-21, #1213) | Greptile is on the free tier and not being paid for | **wrong org** — true of `localmovers-com`, which is canceled |
| The #1204 round-2 dashboard reading (2026-08-21) | `auerbachb` is Pro, Active, $72 → $36, flex uncapped, 92/92 credits | **confirmed** — re-read unchanged a day later |

Measured 2026-08-22: subscription **Active**; invoice 6 Aug – 6 Sep — seat $30 → **$15**, flex 42
credits $42 → **$21**, total **$72 → $36**; **"No cap on flex usage."** Usage **92 reviews / 92
credits**, *identical* to the previous day — a full day of zero consumption. **Disuse is real, and it
is not a price:** the org bills $36 this cycle either way. That is the third time a Greptile figure
has been quoted against the wrong org; check the org in the URL before quoting one.

~~**The route was also wrong, and this is the part that changes the decision. The OSS program is
self-serve, not an application.** That same billing page carries a **"Greptile for Open Source — Free
code reviews for public open-source repositories on github.com and gitlab.com"** section with a
**repository picker**, and `auerbachb/claude-code-config` is present and selectable in it. So there is
no vendor acceptance to wait on and no refusal to plan a fallback around — `Submitted:` and
`Approved:` collapse to one date when the owner clicks. (The picker was opened to read and closed
without selecting.)~~

> **↑ STRUCK — this paragraph is wrong, and it is the error this item exists to warn about.** It was
> written after *opening* the picker; selecting the repo the same evening returned **"The program
> requires at least 50 stars and this repository has 3."** There *is* a vendor gate, `Submitted:` and
> `Approved:` did **not** collapse to one date, and no $0 route exists at 3 stars. Retained struck
> rather than deleted so the reasoning error stays visible.

**Do not cancel.** The audit's first measured pass (2026-08-22, non-truncated 240-PR window) makes
this the clearest call on the list: Greptile is the **top sole-source finder in the whole stack — 40
PRs**, ahead of BugBot (29), CodeRabbit (25), CodeAnt (13), Graphite (2) — and it **hit no cap at
all**. No `D2` (paid-but-unused) finding fired against it or anything else. The zero-consumption day
is one day old, not a pattern. Cancelling would remove the chain's most unique finder to save $36/mo.

*(As written on 2026-08-22 morning this paragraph ended "…when enrolment gets the same coverage to
**$0**." That clause is struck: enrolment was refused. The keep verdict stands on the sole-source
evidence alone, which is what the owner decided on.)*

**The flex cap was the decision that survived.** The subscription serves six repos —
`claude-code-config` plus `skingod`, `inventory`, `still-point`, `meeting_insights_and_actions`,
`longlove` — and with OSS closed, *all six* draw billable flex. The cap is now set at **$100**
(applied 2026-08-22); a second consecutive day of **92/92** zero consumption means it is unlikely to
bind soon, but the exposure is bounded either way.

### 2. CodeAnt — the 100% open-source discount *(RE-SCOPED 2026-08-22: account-wide DECLINED; per-repo request only)*

- **Depends on:** —
- **Submitted:** — *not submitted. Re-scoped first; see below.*
- **Approved:**

> **The account-wide framing is declined on principle (owner, 2026-08-22).** A 100%-off
> "open source" discount applied to the *account* is a claim about the account, and **five of the six
> active repos are not open source**. Only `auerbachb/claude-code-config` is public and MIT-licensed
> (`LICENSE` at `origin/main`; GitHub reports `spdx_id: MIT`). Applying on the broader basis would
> misrepresent us, so the $576/yr figure below **is not a saving that was ever available on those
> terms** and must not be budgeted.
>
> **What remains live is a per-repo request** for that one repo. Two routes exist, neither documented
> as equivalent:
> - **Self-serve app** — `github.com/apps/codeant-ai-for-open-source` ("CodeAnt AI - For open
>   source") presents a working **Install** button. **Not installed:** nothing published says
>   installing it makes a repo free, the repo is already covered by the paid Premium installation, and
>   a second CodeAnt app risks duplicate reviews and unclear billing attribution.
> - **Documented route** — `codeant.ai/pricing` carries *"100% OFF FOR OPEN SOURCE"* with an email
>   contact and **publishes no eligibility criteria at all** (no star count, no licence requirement).
>
> Item 1 is the cautionary precedent: an OSS gate can be invisible until exercised, and CodeAnt
> publishes *no* gate to inspect. The defensible next step is the **email, scoped to the one repo,
> sent by the owner** — not a blind install.

**Budget $48/mo unchanged.** Premium, 2/2 seats, ACTIVE — reconfirmed 2026-08-22 — with **no
self-serve open-source control anywhere on the subscription page**, which is why this stays a
contact-required request rather than a toggle.

**The saving is now unknown, not $576/yr.** That figure assumed an account-wide discount, which is
declined above. A per-repo grant covers **one of six** active repos, and CodeAnt does not publish how
(or whether) per-repo OSS coverage is priced — it may reduce the bill partially, or not at all if the
seat count is what is billed. **Keep budgeting the full $48/mo** until a vendor reply says otherwise;
record any reduction under `Approved:` with the amount the vendor actually confirms.

*(The struck original read: "$48/mo → $0 if granted. **$576/yr, and nothing gates it** … the largest
annual saving on the list — though **item 1 is now unparked and is the faster $0**." Item 1 was
refused, and the account-wide framing is declined, so neither half stands.)* Work this;
expect item 1 to close first. Reconfirmed by the owner 2026-08-21 (#1213) and carried into
[#1228](https://github.com/auerbachb/claude-code-config/issues/1228). Public repo, qualifies on its
face, but the route is **contact-required** rather than self-serve, so it is a request with a waiting
period, not a toggle. Its position at the top of the working order is why the list below is a
priority hint rather than a numbering.

Keep budgeting **$48/mo until approval lands.** CodeAnt is the chain's *sole source of `APPROVED`* on
the CR path, so this account lapsing is a full stop on merges — never let a discount application put
the subscription itself at risk.

### 3. CodeRabbit — billing cadence *(CLOSED 2026-08-22: stay MONTHLY — owner decision)*

- **Depends on:** — nothing. Closed by decision, not by a gate.
- **Submitted:** n/a
- **Approved:** **n/a — DECLINED.** Staying monthly.

> **Stay monthly. Do not re-propose the annual switch.** Owner decision, 2026-08-22
> ([#1228](https://github.com/auerbachb/claude-code-config/issues/1228)), in chat: *"I want to keep it
> monthly, not annually, because this billing flows through company P&L. I don't want to hit with a
> $1,000 bill all at once in one month."*
>
> **This supersedes the annual half of #1212's verdict.** That analysis was purely unit-price and never
> costed the constraint that actually binds: this spend runs through **company P&L**, so a year's
> prepay is a cash-flow event, not merely a cheaper rate. The **stay paid** half of #1212 stands
> unchanged; only **stay paid *annual*** is overturned.
>
> **The concern is aggregate, not this vendor.** CodeAnt Premium (2 seats × $24/mo billed annually
> ≈ $576/yr) and Graphite Team are *already* annual, so several annual renewals landing in one month
> is the ~$1,000 being guarded against. Treat "switch to annual" as **declined by default across the
> whole review stack**, and treat any prepay/credit-pack offer (CodeAnt AI credits, Greptile credit
> bundles) the same way.
>
> **If the trade-off is ever raised again**, state the per-month delta *and* the upfront charge —
> never present the discount as a straight saving. The existing annual subscriptions are not urgent
> to unwind; flag them at their renewal dates rather than proposing an early switch.

The pricing below is retained as reference for that future conversation, **not as a recommendation**.
Annual is $24/seat vs $30/seat monthly, and the seat count it would apply to changed (item 5):

| Order | Seats | Monthly | Annual |
|---|---|---|---|
| Today | 3 | $90/mo | $72/mo |
| **After the item-5 cut** | **2** | **$60/mo** | **$48/mo** |

**Cadence unchanged and staying that way.** Read from the `auerbachb` billing page 2026-08-22:
Pro, Active, **Billing cycle Monthly**, **Next renewal 27 Aug 2026** — corroborated by the app's own
plan record, `CRB_PRO_MONTHLY_SUBSCRIPTION_PER_SEAT-USD-Monthly`. **There is no longer a deadline on
this item**: the 27 Aug urgency existed only to catch the annual switch before renewal, and the
annual switch is declined. Item 5 is now the only item that was time-boxed, and it is applied.

So the realised sequence is **$90/mo → $60/mo** on the seat cut alone. The further **$60 → $48/mo**
that annual would have bought is **forgone deliberately** — worth $144/yr at 2 seats, traded for
smooth monthly P&L. No capability difference either way; the only question was ever price and
timing, and timing won. [#1212](https://github.com/auerbachb/claude-code-config/issues/1212) declined the OSS
tier on two documented constraints — under 10 stars (this repo has 3) reviews stop being automatic and
must be triggered by comment, and the metered add-on in item 4 is Pro/Pro+ only, so it becomes
permanently unavailable — with the star-scaled 1–10/hr rate band, whose value here the vendor does not
publish, as a third reason for caution rather than a number to rely on. The $90/mo would be displaced
onto Greptile's flex rather than saved — a line that was uncapped when that verdict was reached and is
**capped at $100 since 2026-08-22** (item 1), which bounds the displacement without eliminating it
([`cr-oss-vs-paid-decision.md`](./cr-oss-vs-paid-decision.md)). Nothing now strands the commitment —
the remaining move on this tool is Pro+, which sits second-line behind item 4's metered lever, and
that is an *upgrade* rather than an escape. **Renewal is 2026-08-27**; past that the saving waits a
cycle.

### 4. CodeRabbit — the usage-based add-on *(RESOLVED 2026-08-22: it is already ON, capped at $10)*

- **Depends on:** — nothing, for the *decision*. Changing the cap is gated by the billing profile (see item 3).
- **Submitted:** n/a — no purchase was needed.
- **Approved:** **already in effect.** Read from `Billing → Edit` on 2026-08-22: **Usage-based reviews ON**, spend cap **$10**; AI Deep Scan usage **Off**; Agent usage **Off**.

> **This item was recorded as blocked and undecided; it is neither.** Round 4 of the dashboard doc
> listed the metered add-on as *"still blocked — billing profile incomplete"*. In fact the add-on is
> enabled with an explicit cap. #1228's AC asked for "On-demand with an explicit cap, never
> Automatic" — **that is the configuration already in place**, so the acceptance criterion is
> satisfied by existing state rather than by any change.
>
> The dialog is trustworthy on this point: opened fresh after a cancelled edit, its seat field read
> back the *saved* value (3), and plan/cycle matched the billing overview — so it reflects saved
> state, not unsaved defaults.
>
> **The open question is the cap's size, not its existence.** At 25¢/file, **$10** buys ~40 files of
> overflow per cycle against a measured problem of 196 of 290 reviews rate-limited and **"3 developers
> (100%) hit review rate limits in the last 30 days"** (CodeRabbit's own Explore page, 2026-08-22) —
> corroborated by the audit's `rate_limit` D3 on 217 PRs. The investigated sizing was **~$50** against
> **$147–247/mo** to cover the whole overflow. Revisit once the seat cut lands and the demand picture
> settles; raising it is an add-on change and therefore sits behind the same billing form.

This is a **spend** that buys back throughput, not a saving. The problem measured large: 196 of
290 reviews rate-limited (68%), 87.4h average wait, and **36% of blocked PRs merged unreviewed**.

**The original sizing logic is void.** It read: wait for #1209 to cut the overflow, then buy the
smaller remainder. But the owner declined turning Incremental review off — deliberately, because it
catches real errors on nearly every push of an AI-authored PR (§Declined). One review per *push*
therefore remains the consumption pattern, so **the overflow this add-on would be sized against does
not fall the way the plan assumed.** Size it against post-decline reality, and expect a larger number
than the "wait for #1209" framing implied. #1228 additionally sequences this **after** the BugBot and
Greptile changes settle the demand picture.

*(The paragraph that stood here read: "If enabled: **On-demand mode, never Automatic**, with a
deliberate monthly cap… **Completing the billing profile is a prerequisite**; the add-on cannot be
enabled without it." Both halves are superseded by the 2026-08-22 reading — the add-on **is** enabled,
capped at $10, despite the profile still being incomplete. The profile blocks *changes* to the plan,
not this add-on's existing state. Sizing figures are retained in the block above.)*

### 5. CodeRabbit — cut the third seat *(DECIDED 2026-08-21 — this is a saving, not a purchase)*

- **Depends on:** the **incomplete CodeRabbit billing profile** (see item 3) — for the *billed* half only.
- **Submitted:** 2026-08-22 — **seat unassigned.** `zilbermang` moved to `Unassigned`; roster now reads **`2 of 3 assigned`**.
- **Approved:** — *not yet. The bill has not moved: still **`Billing amount $90`**, **Monthly**.*

> **This is two changes, not one — and the checklist previously treated it as one.** Unassigning a
> seat frees it from a person; it does **not** reduce the purchased seat count or the invoice.
> Cutting the billed count is a separate edit at `Billing → Edit → Developer seats`, and that path
> hits the Chargebee billing-details form.
>
> The editor was taken to the confirmation step on 2026-08-22 and produced a correct order summary —
> *Pro, `$30`/Seat/month, **Seats 2**, Monthly, Subtotal `$60`, Total `$60`, Renews August 27, 2026,
> Secured by Chargebee* — then **cancelled** rather than entering the owner's personal and payment
> details. State re-verified unchanged afterwards.
>
> So the **$30/mo** this item is worth is still outstanding, and it is **time-boxed to 27 Aug 2026**
> alongside item 3.

**This item used to read "assign seats to the three unassigned authors." That was wrong, and the
owner's answer is the opposite: remove a seat.** The original framing pooled two GitHub orgs
(§Scope boundary); re-scoped to `auerbachb` alone, the seat ledger is:

| Handle | PRs in scope | Decision |
|---|---|---|
| `auerbachb` | 427 | **keep seat** |
| `faculoyarte` | 195 | **keep seat** |
| **`zilbermang`** | **0 in scope; last CodeRabbit-reviewed PR 2 months ago** (see correction below) | **REMOVE — the seat buys nothing in scope** |
| `davidpetersen`, `mirkosalvato1-ctrl` | 0 authored | no seat |
| `farwabraza`, `paulkathat-lmc`, `memibar` | out of scope | no seat on this account — separate org, separate CodeRabbit account |

**Result: 3 seats → 2 — APPLIED 2026-08-22 by the owner.** $90/mo → **$60/mo**, and that is the final
figure: item 3's annual switch is declined, so the $48/mo it would have stacked on top is forgone by
choice. The dashboard shows *"1 change taking effect with the next billing cycle — Seat downgrade:
Reduction from 3 → 2 seats"*, so the invoice reads **$90 until 27 Aug 2026** and **$60 after**.

Two steps were needed, and only the first is an agent action: the agent unassigned `zilbermang`'s seat
(roster → `2 of 3 assigned`), which frees the seat but **does not** change the bill; reducing the
*purchased* count runs through `Billing → Edit → Developer seats` and its Chargebee billing-details
form, which the owner completed.

**Correction to the justification, which does not change the decision (#1228, 2026-08-22).** The
"0 across every repo swept, both orgs" claim is **false as written**. CodeRabbit's own team-management
page for `auerbachb` reports `zilbermang`'s latest CodeRabbit-reviewed PR as **2 months ago** — stale,
but not never. The cut still stands on the comparison that actually matters: against `auerbachb`
(minutes) and `faculoyarte` (hours), and nothing in scope since. **Do not repeat the "authored
literally nothing" line** — a decision defended with a checkable falsehood invites being reopened on
the falsehood rather than the merits.

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

## Free levers still outstanding

Not paid levers, tracked here because [#1209](https://github.com/auerbachb/claude-code-config/issues/1209)
closed with these un-applied and nothing else now holds them. Both are BugBot settings, sized from the
per-repo run split read 2026-08-22 (#1228, recorded in
[`ai-review-billing-dashboard-2026-08.md`](./ai-review-billing-dashboard-2026-08.md) §Round 4).

**Autofix → Off — the only BugBot lever with money behind it.** 299 autofix runs, **0 ever merged**,
at the ~$1.58/run rate ≈ **$470 of runs nobody used**, roughly 27% of lifetime run volume. It touches
none of the aggressive settings the owner deliberately kept (Every Push, Effort High, Drafts On,
Incremental Off), so it is separable from that decision rather than a re-litigation of it.

**Dropping the 23 `LocalMovers-dot-com` repos — worth $0 today, and must not be budgeted as a saving.**
Six repositories out of 87 enabled (64 + 0 + 23 across the three connected orgs) account for **100%**
of BugBot's lifetime runs — 1,097 runs / 382 PRs — and **all six are in `auerbachb`**: skingod 502,
inventory 247, claude-code-config 179, still-point 83, meeting_insights_and_actions 55, longlove 31.
Not one run has come from any LocalMovers repo or from `faculoyarte`. The trim is a **blast-radius
cap** — it forecloses spend if that team starts opening PRs against an account the owner does not want
billed for them — and is worth doing on that basis alone. Recording it as a cost reduction would
overstate the session's savings and poison the next audit's baseline.

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
