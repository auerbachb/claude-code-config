# AI Review Billing — Dashboard Readings (2026-08-21)

Issue: [#1204](https://github.com/auerbachb/claude-code-config/issues/1204)
Interpretation and reconciliation against the GitHub-derived census: [`ai-review-tool-audit-2026-08.md`](./ai-review-tool-audit-2026-08.md) §Dashboard reconciliation
Roles derived from both: [`ai-review-chain-roles-decision.md`](./ai-review-chain-roles-decision.md)

**Provenance.** Read directly from each vendor's dashboard during a browser co-working session on
2026-08-21 while logged in. **Nothing was changed on any dashboard** — no purchases, no limit
changes, no seat changes. This file is the **primary source record**, kept separate from the audit
that interprets it so the raw readings survive independently of any conclusion drawn from them.

**Point-in-time.** Every figure is true as of 2026-08-21 and will rot. Per
[`README.md`](./README.md) §"Audits and research", this file is **exempt from corpus-wide rewrites**
— do not update it to match later reality; write a new dated sibling instead.

**Redactions.** This repository is **public**. Payment-instrument identifiers and personal email
addresses from the source have been removed. An earlier revision retained seat-holder emails on the
grounds that they were the actionable fact — that was wrong for a public record, and the finding
survives without them: what matters is *that* the commit-author identity holds no seat, not which
addresses do. Where a seat holder must be referred to, they are named by role ("the account owner")
or by GitHub handle.

**Known scope error, preserved deliberately.** The Greptile section reads the **`localmovers-com`**
org, which does **not** serve `auerbachb/claude-code-config` — that repo is absent from its 24-repo
list, our PRs carry no `greptile` label, and our reviews came from explicit `@greptileai` commands
that bypass both gates. The reading is accurate for the org it describes and is kept as-is; it does
not answer the question this repo asked. See the audit's §Item 3.

---

## Task 1 — Greptile (org: LocalMovers.com, `app.greptile.com/localmovers-com`)

Source pages: `/-/settings/billing`, `/-/settings/usage`, `/-/settings/review`, `/-/settings/manage-repos`, `/-/settings/people`, `/-/analytics`.

- Plan status: **Canceled / subscription ended.** Banner on every page: "Your subscription has ended — Upgrade to Pro / Continue on Free." Billing page: "Your subscription has been canceled… Scheduled to cancel on Jun 18, 2026." Last invoice 18 May – 18 Jun 2026: Seats 0 active developers, **Total $0**.
- Current effective tier: Free ("Up to 50 credits per month for one author"). The Free plan has **not been explicitly activated** — the page shows an "Activate free plan" button with `faculoyarte` pre-selected as the one author.
- Is it costing money? **No.** No active subscription and no invoice since the $0 June invoice. The "free" behavior is real, not an unbilled overrun.
- Usage page (last billed period May 18 – Jun 18): Code Review 117 reviews / 117 credits; faculoyarte 116 credits (+66 flex), paulkathat-lmc 1. (Flex credits are the $1/credit overage mechanism on Pro — that period was still on Pro.)
- Analytics "This month" (Aug): Total PRs 6, Total Reviews 8 — only moving-marketplace (6) and lm-crm (2). Lifetime review counts on manage-repos: license_manager 588, moving-marketplace 307, triple 50, vapi-config 10, lm-crm 2, marketing 1; 24 repos listed, all "Enabled".
- Auto-trigger check: **Auto-review on new commits = OFF**, Review draft PRs = OFF, file change limit 100. Filters: Labels include `greptile` (Greptile only reviews PRs labelled `greptile`), Authors exclude dependabot[bot] and renovate[bot]. Status checks OFF, status comments OFF, auto-approve OFF, "Prompt to Fix with AI" OFF. **Confirmed disabled** (issue #261 holds).
- Comment-volume settings: **Strictness Level = Low** ("comment on all issues" — the noisiest setting). PR summary sections all enabled. Auto-approve max risk = Low (auto-approve off). No custom instructions.
- Org members: the account owner (Admin) only.
- Public pricing (greptile.com/pricing, 2026-08-21): Starter Free = 50 credits/mo, 1 active developer. Pro = $30/seat/mo, 50 credits per seat, $1 per additional credit; 1 credit = 1 standard review, 3 credits = TREX review. Covering ~130 reviews/mo on Pro with 1 seat ≈ $30 + 80 × $1 = **~$110/mo**; with 3 seats (150 credits) = $90/mo.

## Task 2 — Cursor / BugBot (plan: Ultra)

Source pages: `cursor.com/dashboard/spending`, `/dashboard/billing`, `/dashboard/usage`, `cursor.com/automations/from-cursor/bugbot`.

- Plan: **Ultra, $200/mo**, auto-renews Aug 28, 2026. Usage limits reset Aug 28.
- Included usage (Jul 28 – Aug 28): Cursor Models 267.6M tokens, 16.8% used. **Other Models 874.5M tokens, 100.0% used** — of which `github_bugbot` = 848.3M (96.1%). Plan "includes at least $400 of Other Models usage."
- On-demand: **$999.87 / $1,000.00 monthly limit** (spending page shows $1,000.08 / $1000). Limit type: Fixed. This is why BugBot reports "usage limit reached."
- On-demand breakdown for the cycle: `github_bugbot` 1.3B tokens, **516 reviews, $815.58 (~$1.58/review)**; claude-sonnet-5-thinking-high 48 × $3.84 = $184.29; mid-cycle payment already made −$908.23; subtotal outstanding $91.64.
- Implication as read: ~250 PRs/mo ≈ **$395/mo in on-demand**, on top of the $400 included Other-Models bucket.
- **Attribution dispute (operator, 2026-08-21):** the operator attributes the on-demand spend to pay-per-use model usage while coding in the Cursor app, **not** to BugBot. **Dashboard caveat:** the Billing & Invoices page itemizes the cycle as `github_bugbot` — 1.3B tokens, qty 516, $815.58 — alongside `claude-sonnet-5-thinking-high` qty 48, $184.29 (the IDE/agent line). Both readings are recorded. If the operator attribution is right, Cursor is mislabelling IDE usage as `github_bugbot`, which also drives the Other-Models 100% figure — worth a support ticket. **Resolve before deciding on the cap.**
- **BugBot settings** (the usage multipliers): Enable Bugbot = ON; **Trigger Mode = Every Push** (re-reviews on every commit, not once per PR); **Effort Level = High**; **Review Draft PRs = On**; PR Summaries Off; Risk score Off; **Autofix Mode = Create New Branch**, severity threshold Low/Medium/High (autofix runs billed at plan rates — **299 autofix runs, 0 merged**); **Incremental Review = Off** (full re-review each push). Analytics: 324 PRs reviewed, 515 issues, 89.8% resolved. Org coverage: `auerbachb` 64/64 repos, `LocalMovers-dot-com` 23/23, `faculoyarte` 0/1.
- Cheapest levers if BugBot spend is real: Every Push → once per PR; Incremental Review → On; Draft PRs → Off; Effort High → Medium; Autofix off (0 of 299 autofix branches were ever merged).
- Upgrade path: the only lever is the "Monthly Limit" field (Fixed or Unlimited). No higher tier — Ultra is the top individual plan. **Not changed.** At the August run-rate the cap would need to be ~**$1,400–1,500** to avoid the wall; narrowing BugBot's trigger scope is the cheaper fix.
- Usage tab (Aug 15–21) showed 0 tokens / "No events found" — that view appears scoped to IDE usage only, not BugBot.

## Task 3 — CodeAnt (org: `auerbachb`, `app.codeant.ai/auerbachb`)

Source pages: `/subscription`, `/settings/team-management`, `/settings/prconfsettings`.

- Plan: **Premium, 2 seats, ACTIVE.** Public price $24/user/mo billed annually ("Unlimited AI reviews"). AI credits balance $0.00.
- Seats (**2 of 2 used, 0 left**): the account owner (Admin) and one collaborator (Member), both with AI Code Review access. An Auto Enroll Team Members toggle exists (state not verified).
- **Which identity holds the seat:** the account owner's. The CI/commit identity our PRs are authored under is **not** in the seat list — consistent with the 84% warning rate. CodeAnt reviews anyway but flags the author as unlicensed.
- Fix options (not executed): **Path A** — buy a seat and license a dedicated CI identity (~$24/mo). **Path B** — set the machine's global git `user.email` to **the operator's own** seat-holding address (**$0**). Path B is cheaper where the CI identity is just a convenience alias for the operator; it must **never** point at a collaborator's address, which would misattribute authorship.
- Org scope note: the CodeAnt org is `auerbachb` (personal GitHub), listing repos such as skingod, still-point, longlove, inventory, meeting_insights_and_actions.
- Review settings (repo view for consulting-websites): Process PR Review, PR Size Labels, Ticket Compliance, Draft PR Analysis, Sequence Diagram, Auto Approve PR, Auto Resolve Suggestions all = **Inherit** from org; Live Secret Validation and Fix in IDE **overridden** at repo level; Incremental PR Review Threshold = inherit; Suggestion Threshold inherited. **The org-defaults page hung on load twice and could not be read** — the org-level values (especially Draft PR Analysis, Incremental threshold, Suggestion Threshold, which drive volume) remain unread. CodeAnt is unlimited on Premium, so these affect noise, not cost.

## Task 4 — CodeRabbit (org: `auerbachb`, `app.coderabbit.ai`)

Source pages: `/settings/billing` (Overview + Usage), `/settings/team-management`, "View all plans" modal, `/organization/settings/review/behavior`.

- Plan: **Pro, Active, monthly, 3 of 3 seats assigned, $90/mo** ($30/seat monthly; $24/seat annual). Next renewal **27 Aug 2026**. Billing profile flagged "Account information incomplete: name, phone number, billing address missing."
- Seats assigned: **auerbachb**, **faculoyarte**, **zilbermang**. Unassigned (no seat): davidpetersen, dependabot, cursor, mirkosalvato1-ctrl, **paulkathat-lmc** (last PR 10 days ago → their PRs get no review).
- Usage, current billing period: **196 of 290 reviews rate-limited (68%)**; 2 of 3 seat-holders rate-limited; average review wait **87.4h**; **36% of blocked PRs merged unreviewed**. Per user: faculoyarte 170 reviews / 110 rate-limited / 54.7h wait; auerbachb 120 / 86 / 32.7h.
- Why it refuses: limits are **per developer per hour** — Pro = 5/hr, Pro Plus = 10/hr, Enterprise = 12/hr (public pricing, 2026-08-21). 290 reviews/month across two authors is far under any monthly cap; the blocking is **burst concurrency** (many PRs opened in the same hour by one author), after which the queue backs up for days.
- Review settings: **Profile = Assertive** (the noisiest of quiet/chill/assertive). Request-changes workflow OFF, auto-assign reviewers OFF, no path filters, no path instructions, no label gating, no extra base branches. High-level summary ON. Language en-US, early access OFF. The Concise view hides some fields (auto-review enabled / drafts / incremental); the page also showed a spurious "unsaved changes" banner on load — **nothing was applied**. Switching Profile to `chill` is the single biggest comment-volume lever; it does **not** change the hourly rate limit.
- "Usage-based reviews" is **OFF** ("Continue reviewing beyond your plan limits… billed at **$0.25/file**. Add billing details"). Usage history shows it was on ~3 months ago (charges $0.25–$5.75 per review). **Not changed.**
- Sizing for ~244–290 PRs/mo:
  - **Option A — Pro Plus:** $48/seat annual ≈ **+$54–72/mo** for 3 seats. Doubles the hourly rate; likely clears most but not all bursts.
  - **Option B — usage-based overflow:** **$0.25/file** on the overflow only. At ~196 blocked reviews/mo × a few files each, roughly **$50–150/mo**, and nothing gets blocked. Requires completing billing details.
  - **Option C —** spread PR opens across the hour, and/or add seats for unassigned authors at $30/seat.

## Graphite

Deliberately out of scope per issue #1204 — newly paid, and the audit measured it pre-payment, so its re-measure trigger is evidence-based (≥30 PRs under the paid plan), not a billing question. No Graphite dashboard was opened.

## Settings that drive volume/cost (all tools, 2026-08-21)

| Tool | Trigger | Verbosity/effort | Drafts | Re-review on push | Autofix |
|---|---|---|---|---|---|
| Greptile | Label `greptile` only; auto-review OFF | Strictness **Low** (comments on everything) | OFF | OFF | n/a |
| BugBot | **Every Push**, all 87 repos | Effort **High** | **ON** | Full (incremental OFF) | **ON**, new branch, L/M/H (0/299 merged) |
| CodeAnt | Org default (unread) | Suggestion threshold (unread) | Inherit (unread) | Incremental threshold (unread) | Auto-resolve inherit |
| CodeRabbit | Auto review, no label gate | Profile **Assertive** | hidden in Concise view | default | PR auto fix (not read) |

## Summary

| Tool | Dashboard status (2026-08-21) | Actually paying? | Why it refuses/warns | Cheapest fix |
|---|---|---|---|---|
| Greptile (`localmovers-com`) | Canceled; Free (50 credits/1 author), not yet activated | No ($0) | Doesn't refuse; label-gated, auto-review off | n/a — **wrong org for this repo** |
| Cursor BugBot | Ultra $200/mo; on-demand $999.87/$1,000 | Yes — $815.58/cycle attributed to `github_bugbot` (disputed) | On-demand cap hit | Narrow trigger scope; settle attribution before raising the cap |
| CodeAnt | Premium, 2/2 seats active | Yes (~$48/mo) | Commit-author email holds no seat | Fix global git `user.email` (Path B, $0) |
| CodeRabbit | Pro, 3/3 seats, $90/mo, renews 27 Aug | Yes ($90/mo) | Per-developer hourly limit (5/hr); 196 of 290 blocked | $0.25/file overflow, or Pro Plus (+~$54–72/mo) |

## Round 2 — the five follow-ups, answered (2026-08-21 afternoon)

Same session posture: read-only, nothing changed on any dashboard. **All five open items resolved.**
The Greptile answer overturns Round 1 rather than extending it.

### 1. Greptile — the installation serving `auerbachb/*` is a SECOND org, and it is PAID

Sources: `github.com/settings/installations/117638123`; `app.greptile.com/auerbachb/-/settings/{billing,usage,review,manage-repos}`.

- "Greptile Apps" is installed on the **`auerbachb` personal account** with access to **All
  repositories**. LocalMovers has a separate installation. Round 1 read the wrong org.
- The `auerbachb` Greptile org is **Pro, Active**. Invoice 6 Aug – 6 Sep 2026: 1 seat $30 (**$15**
  after discount), **Flex Usage 42 credits $42 (**$21** after discount)**, total **$72 → $36**.
- **Flex Usage Limit: "No cap on flex usage."** Overage is $1/credit and **unbounded by default**.
- Usage 15 days into the cycle: **92 reviews / 92 credits**, all by `auerbachb` — **50 included +
  42 flex**. Run-rate ~6/day → ~180 credits/month ≈ $30 seat + ~$130 flex at list.
- Lifetime reviews by repo (64 repos enabled): **claude-code-config 212** — the top consumer —
  then skingod 172, inventory 30, longlove 6, still-point 5, cursor-code-config 2.
- Settings: auto-review on new commits **OFF**, drafts OFF, file limit 100, label filter includes
  `greptile`, **Use Status Checks ON** (differs from localmovers), status comments OFF, auto-approve
  OFF. Consistent with the audit's "0 auto-triggers": every review came from an explicit
  `@greptileai` mention, which bypasses the label gate and costs 1 credit.

**Bottom line: the 130 reviews/month are real and are being billed**, on an org with no spend cap.
`$0/canceled/Free` described localmovers-com only.

### 2. CodeAnt `Auto Approve PR` — **ON** at the org level

Source: `app.codeant.ai/auerbachb/settings/prconfsettings` → organization defaults (loaded on the third attempt).

Org defaults every repo inherits: Process PR Review On · PR Size Labels On · Ticket Compliance On ·
Live Secret Validation On · Incremental PR Review Threshold Default · PR Description "Update
Description" · PR Feedback "As a Comment" · **Draft PR Analysis Off** · Sequence Diagram On · Fix in
IDE Off · **Auto Approve PR ON** · Auto Resolve Suggestions Off · **Suggestion Threshold Minor**
(the chattiest setting) · AI Code Suggestions Committable · Exclude Bot Comments from DORA Off.

**This confirms the hypothesis exactly.** CodeAnt approves org-wide by default, which is why PR
#1203 collected `APPROVED` on four consecutive SHAs with no substantive findings. Turning **Auto
Approve PR → Off** stops the manufactured approvals, and the #875 guard then has nothing to discard.

The "AI credits $0.00" block is a prepaid balance for metered features; reviews are unlimited on
Premium, so there is no overage exposure.

### 3. Graphite — Team annual, started **7 Aug 2026**

Sources: `app.graphite.com/settings/billing?org=auerbachb`, usage-history modal, `/ai-reviews?org=auerbachb`.

- **Team plan, Active, annual.** "Annual subscription renews: August 7, 2027" → the paid plan
  **started 7 Aug 2026**. List price **$40/user/month billed annually** ($480/yr). **1 billable
  user** this cycle; seat true-up 7 Sep 2026.
- Billing shape: AI review volume is **not metered** (Team = unlimited AI reviews), but
  "**committers with only AI reviews are billed separately**" — anyone whose PRs get reviewed
  becomes a billable seat. With PR authors set to **All committers in selected repositories** across
  **13 repos** and no PR filter, each additional committer is a potential $40/mo seat. Draft PRs ON.
- Last 4 weeks: **112 PRs reviewed, 18 issues found, 9 accepted (50% acceptance), 0% downvote.**
- **The re-measure trigger is met on merged-PR count, not inferred from review volume:**
  `gh pr list --state merged --search "merged:2026-08-07..2026-08-21"` returns **88 merged PRs** in
  the paid period (measured 2026-08-21) against a threshold of 30. Graphite's role can be re-decided
  on paid-plan evidence now.
- Other orgs: LocalMovers-dot-com — "subscription has expired"; faculoyarte; rakibulislam.

### 4. BugBot attribution — **it really is BugBot**; no support ticket needed

Sources: `cursor.com/automations/from-cursor/bugbot/analytics` (23 Jul – 21 Aug); `/dashboard/usage` 30-day event log.

- Analytics: **763 runs across 324 PRs**, 1 user, 488 issues evaluated, 89.8% resolved, **299 autofix
  runs / 0 merged**. The table lists repo + PR per run — e.g. `claude-code-config #883` (16/18),
  `inventory #271` (30/36), `skingod #2529` — 152 rows over 31 pages.
- On-demand event log for model `github_bugbot`: discrete events 1–3 minutes apart (e.g. 3 Aug
  21:55–22:26 UTC: $0.48, $3.68, $1.94, $0.53, $0.62, $0.60, $0.90, $0.54, $0.79, $0.59, $1.47,
  $0.68) — the cadence of a bot re-reviewing every push. IDE usage appears under different models
  (`cursor-grok-4.5-high-fast`, `composer-2.5-fast`, and `claude-sonnet-5-thinking-high` at $184.29).
- Reconciliation: 516 billed on-demand events ≤ 763 total runs; the remainder were absorbed by the
  $400 included Other-Models bucket before it hit 100%. ~$1.58/run, range $0.48–$3.68.
- **The $815.58 is BugBot.** Drivers: Every Push × Effort High × Draft PRs On × Incremental Off ×
  Autofix On (0 of 299 merged).

### 5. CodeRabbit — per-developer limits, plus a weekly fair-use cliff

Sources: `app.coderabbit.ai/organization/settings/review/auto-review` (All Settings view), `/general`; `docs.coderabbit.ai/management/plans`.

Auto review at org level: **Automatic review ON** · **Incremental review ON** ("re-run the review on
each push") · Auto pause after 5 reviewed commits · **Drafts OFF** · no title-keyword ignore, no
label gate, no extra base branches, no description keyword · **Profile Assertive** · free tier ON ·
early access OFF.

- **Scope: enforced per developer** — the PR author — on rolling windows. Not per repo, not per org.
  Pro 5 reviews/hour, Pro+ 10, Enterprise 12. Files per review: 150 (Pro), 300 (Pro+).
- **Fair Usage cliff:** at the 95th percentile of recent usage, reviews are "gradually spaced out";
  **Pro drops to 1 review/hour after 60+ reviews in a week** (Pro+ after 90+). faculoyarte (~40/wk)
  and auerbachb (~28/wk) sit under it on average, but a stacked-PR week crosses 60 and throttles
  that author to 1/hr — which is what the 87.4h average wait and 68% blocked rate look like.
- **Adding seats does nothing unless PRs are authored by different GitHub users.** Every PR in this
  repo is authored by one identity, so all demand funnels through one developer's 5/hr limit.
- Levers, cheapest first: Incremental review **OFF** (one review per PR instead of per push) ·
  Profile → `chill` · enable the $0.25/file overflow · Pro+ (+$24/seat/mo; doubles the hourly cap and
  raises the weekly threshold to 90).

### What round 2 changed

| Item | Round 1 | Round 2 |
|---|---|---|
| Greptile cost | $0, canceled (wrong org) | **Pro, Active, ~$36–72/mo, uncapped $1/credit flex; this repo is its top consumer (212 lifetime)** |
| CodeAnt approvals | cause unknown | **Org default `Auto Approve PR` = ON** |
| Graphite | out of scope | **Team annual from 7 Aug 2026, $40/user/mo, 1 billable user; re-measure threshold already met** |
| BugBot $815.58 | attribution disputed | **Confirmed BugBot** — 763 runs, 324 PRs, per-PR rows |
| CodeRabbit limits | partially read | **Per-developer; Incremental ON; fair-use cliff 60/wk → 1/hr** |

## Still open after both rounds

All five factual questions are answered. What remains are **decisions**, not readings:

1. **Set Greptile's Flex Usage Limit.** It is currently "no cap," and this is the only true spend
   control on that account — the agent-side `greptile-budget.sh` bounds triggers, not dollars.
2. **Turn CodeAnt's org `Auto Approve PR` off**, ending the manufactured approvals.
3. **Cut BugBot's scope** — Every Push → per PR, Incremental → On, Drafts → Off, Effort → Medium,
   Autofix → Off (0 of 299 merged). No purchase required.
4. **Choose a CodeRabbit lever** — Incremental review Off is free and the largest single reducer;
   $0.25/file overflow and Pro+ both cost money.
5. **Re-decide Graphite's role** on paid-plan evidence, now that the ≥30-PR threshold is met.

## Round 3 — CodeRabbit CLI seat state, measured locally (2026-08-21 evening)

Issue: [#1213](https://github.com/auerbachb/claude-code-config/issues/1213). **No dashboard was
opened and nothing was changed anywhere** — this round is a local CLI measurement, recorded here
because it corrects a billing-state claim the earlier rounds fed into `pricing-matrix.md`.

### The CLI is already on a paid seat; the throttle is repo visibility

Rounds 1–2 and `pricing-matrix.md` owner-action item 5 recorded the CodeRabbit CLI as unattached to a
seat — `isProUser: false`, limited to the free tier's 3 reviews/hour "despite $90/month in seats" —
and prescribed re-auth as one of the three seat holders. **That reading was wrong.** Measured with
CLI 0.7.5:

- `coderabbit auth status` → `Account: auerbachb`, `Provider: GitHub`, **`Plan: Pro`**,
  **`Seat: assigned`**. The CLI holds a paid seat right now.
- The CLI announces the routing itself on this repo: *"This looks like a public open-source
  repository. CodeRabbit will review it for free, and no organization will be billed. Free OSS limits
  apply."*
- The observed ceiling — ~3 `coderabbit review --agent` runs, then
  `{"errorType":"rate_limit","metadata":{"isProUser":false,"waitTime":"40 minutes"}}` — matches the
  free-OSS tier already documented in `ai-review-chain-roles-decision.md` §Repo variance and
  `feedback_cr_cli_free_oss_tier_cap.md`.

So `isProUser: false` is a statement about **which pool this review was billed against** — free-OSS,
no organization billed — not about the account's tier. The route is selected by the **repository's
visibility**, so no re-auth as any seat holder can change it. The only lever that would is making the
repo private, which would forfeit the CodeAnt and Greptile OSS discounts that are the two
highest-value items on the paid-lever list.

**Nothing is owed and nothing is lost in dollars**: the seat is already paid for and already
assigned, and the CLI is advisory — the GitHub Apps hold independent quotas and are what gate the
merge (`feedback_review_clis_down_app_independent.md`). The cost is local pre-push visibility only.

`pricing-matrix.md` keeps its item 5 as written, per its point-in-time exemption. The correction is
recorded in
[`ai-review-paid-levers-checklist.md`](./ai-review-paid-levers-checklist.md) item 6, which supersedes
it. Whether CodeRabbit's OSS tier changes the picture is
[#1212](https://github.com/auerbachb/claude-code-config/issues/1212)'s question.

### Where the remaining decisions now live

The five items under "Still open after both rounds" are settings and spend-cap changes, tracked in
[#1209](https://github.com/auerbachb/claude-code-config/issues/1209). The **paid** decisions —
seats, OSS applications, billing cadence, metered caps — are now tracked in
[`ai-review-paid-levers-checklist.md`](./ai-review-paid-levers-checklist.md), each with its ordering
gate and separate submitted/approved dates. Gate state as measured 2026-08-21: **#1209, #1210, and
#1212 are all open**, and the repo has **no `LICENSE` file**, so the Greptile OSS application, the
CodeRabbit billing cadence, and the metered add-on are all blocked. Budget lines in this file stay as
Rounds 1–2 recorded them until an approval actually lands.

## Round 4 — owner-session readings (2026-08-22)

Issue: [#1228](https://github.com/auerbachb/claude-code-config/issues/1228). Same posture as Rounds
1–2: **read-only, nothing was changed on any dashboard** — no purchases, no plan changes, no seat
changes, no toggles, no application submissions. Every action that would alter an account is listed
under §Pending an owner click and is recorded as **pending**, never as done.

**Screenshots were unavailable** on this session's browser connection (CDP capture failed on every
attempt), so each figure below is recorded as an exact quoted string with the URL it came from. #1228's
test plan accepts "screenshot-**or**-quote"; this is the quote half.

**Two of the issue's premises did not survive measurement.** Greptile is paid, not free — and its OSS
route is self-serve rather than an application. BugBot's 23-repo trim saves nothing today. Both are
detailed below, because both change what the remaining decisions are worth.

### Gate state has moved since Round 3

Round 3 recorded #1209, #1210, and #1212 as open with no `LICENSE` in the repo. As of 2026-08-22 all
four tracked issues are **closed** (#1209, #1210, #1212, #1213) and **`LICENSE` is present** (MIT, PR
#1215). Nothing on the paid-levers list is gate-blocked any more.

### 1. Greptile — settled: the `auerbachb` org is PAID, and the owner's free-tier recollection is wrong for it

Source: `app.greptile.com/auerbachb/-/settings/billing` and `/-/settings/usage`, read 2026-08-22.

- Subscription **Active**. Billing page: *"Your subscription is active. Manage your plan, update
  payment methods, or view billing history."*
- Invoice **6th Aug – 6th Sep, 2026**: Code Review Seats *"1 active developer"* $30 → **$15**; Flex
  Usage *"42 credits"* $42 → **$21**; **Total $72 → $36**.
- **Flex Usage Limit: "No cap on flex usage."** *"$21 in flex charges this period."* Unchanged from
  Round 2 — the only true spend control on the account is still unset.
- Usage page, same cycle: Code Review **92 reviews / 92 credits**; TREX 0; CLI 0. Developer usage:
  the account owner, 92 credits, **+42 flex**.
- **The 92/92 figure is byte-identical to the 2026-08-21 reading.** A full day passed with **zero
  additional Greptile consumption**, which corroborates the disuse #1228 inferred from "no Greptile
  reviews since PR #1203" — but disuse is not a price. The org is still billing $36 this cycle.
- The free/canceled reading remains true of **`localmovers-com` only** (Round 1). This is the third
  time a Greptile figure has been quoted against the wrong org; verify the org in the URL before
  quoting any number from this vendor.

**New, and not costed anywhere before: Greptile's OSS program is self-serve, not an application.**
The billing page carries a **"Greptile for Open Source — Free code reviews for public open-source
repositories on github.com and gitlab.com"** section with a repository picker, and
**`auerbachb/claude-code-config` is present and selectable in it.** `LICENSE` landed in PR #1215, so
the #1210 gate is clear. The picker was opened to read its contents and **closed without selecting**.

This gives the cancel-vs-keep question in #1228 a third answer neither closed issue considered: enrol
the repo in the OSS program and keep Greptile at **$0** for this repo, without cancelling the
subscription that also serves five private repos.

### 2. CodeAnt commit identity — the fix landed; this item is closed on evidence

Sources: GitHub PR comment history and `git config --global`.

Global identity is now `Bretton Auerbach <the owner's seat-holding address>` — no longer the
`CI <ci@example.com>` placeholder. The before/after is clean and carries its own control:

| PR | Commit author | CodeAnt "no subscription" comment |
|---|---|---|
| #1215 | `ci@example.com` | **yes** — *"User ci@example.com does not have a PR Review subscription."* |
| #1217 | `ci@example.com` | **yes** |
| #1221 | `ci@example.com` | **yes** (2026-08-21 23:02) |
| **#1222** | **the owner's address** (all 3 commits) | **none** — only *"✅ Reviewed your PR"* |

The fix was applied 2026-08-21 ~23:11; #1222 is the first PR authored after it and is clean. The
84%-of-PRs warning rate recorded in Round 1 is closed.

### 3. CodeRabbit — still 3 seats, still monthly, renewal in 5 days

Source: `app.coderabbit.ai` → org **`auerbachb`** → `/settings/billing` and `/settings/team-management`,
read 2026-08-22.

- Plan **Pro, Active**. **Seats "3 of 3 assigned"**. **Billing amount $90.** Invoice credits $0.
  **Billing cycle Monthly. Next renewal 27 Aug 2026.**
- Still flagged: *"Account information incomplete: name, phone number, billing address missing"* —
  the same prerequisite that blocks the metered add-on (levers item 4).
- Seat holders and their last CodeRabbit-reviewed PR: **auerbachb** (4 minutes ago) · **faculoyarte**
  (20 hours ago) · **zilbermang** (2 months ago). Unassigned: davidpetersen (4 months),
  mirkosalvato1-ctrl (a month), paulkathat-lmc (11 days), dependabot (never), cursor (16 days).
- The org's plan record, read from the app's own org list, is
  `CRB_PRO_MONTHLY_SUBSCRIPTION_PER_SEAT-USD-Monthly` — confirming monthly cadence independently of
  the billing page.

**One correction to #1213's seat finding.** #1213 justified cutting `zilbermang` on "**0** across
every repo swept, both orgs." CodeRabbit's own team-management page reports zilbermang's latest
CodeRabbit-reviewed PR as **2 months ago**, not never. The *decision* still holds on the numbers that
matter — 2 months stale against 4 minutes and 20 hours for the other two seats, and nothing in scope
since — but the "authored literally nothing" justification is overstated and should not be repeated.

**Scope trap, again.** `app.coderabbit.ai` opens on **LocalMovers-dot-com** by default, and its
team-management page lists a different seven-person roster. The account holds three orgs —
`auerbachb` (66 repos), `rankgeniuscorp` (0 repos), `LocalMovers-dot-com` (23 repos). Every figure
above is from `auerbachb`. Reaching it needs `/organizations` → row menu → "Switch organization"; the
sidebar org dropdown does not commit a selection.

### 4. BugBot — settings unchanged, and the per-repo split kills half of #1228's trim

Sources: `cursor.com/automations/from-cursor/bugbot` and `/bugbot/analytics`, read 2026-08-22.

Settings, all identical to Round 1 — the aggressive core the owner chose to keep:

| Setting | Value |
|---|---|
| Trigger Mode | **Every Push** |
| Effort Level | **High** |
| Review Draft PRs | **On** |
| Incremental Review | **Off** |
| Autofix Mode | **Create New Branch**, severity Low/Medium/High |
| PR Summaries / risk score | Off / Off |

Analytics (Jul 24 – Aug 22): **PRs Reviewed 324 (763 runs)** · Issues Resolved 89.8% of 488 evaluated
· Users **1** · **Autofixes Merged 0 of 299 runs.**

Org coverage: **`auerbachb` 64/64 enabled (100%)** · `faculoyarte` 0/1 (0%) · **`LocalMovers-dot-com`
23/23 enabled (100%)**.

**The per-repo run split — every repo that has ever produced a BugBot run.** Aggregated over the full
(undated) analytics record, 382 PRs / 1,097 runs:

| Repository | Runs | PRs | Bugs found |
|---|---|---|---|
| `auerbachb/skingod` | 502 | 173 | 475 |
| `auerbachb/inventory` | 247 | 60 | 271 |
| `auerbachb/claude-code-config` | 179 | 70 | 247 |
| `auerbachb/still-point` | 83 | 45 | 83 |
| `auerbachb/meeting_insights_and_actions` | 55 | 15 | 57 |
| `auerbachb/longlove` | 31 | 19 | 34 |
| **Total** | **1,097** | **382** | **1,167** |

**Six repositories out of 87 enabled — 64 + 0 + 23 across the three connected orgs — account for
100% of BugBot's lifetime runs, and all six are in the `auerbachb` org.** Not one run has come from
any of the 23 `LocalMovers-dot-com` repos, or from `faculoyarte`.

Two consequences for #1228's BugBot item:

1. **Dropping the 23 out-of-scope repos saves $0 today.** They are enabled but have never fired. The
   trim is worth doing as a **blast-radius cap** — it forecloses spend if that team starts opening
   PRs on an account the owner does not want billed for them — but it must not be recorded or
   budgeted as a cost reduction. #1228 asked for the split *"to size the repo trim before the click"*;
   this is that sizing, and it sizes to zero.
2. **Autofix → Off is the only BugBot lever with money behind it.** 299 runs, **0 ever merged**, at
   the ~$1.58/run rate Round 1 derived — roughly **$470 of runs that produced nothing anyone used.**
   It is 27% of lifetime run volume and touches none of the aggressive settings the owner kept.

### 5. CodeAnt — Premium, 2 seats, active; the OSS discount is still contact-only

Source: `app.codeant.ai/auerbachb/subscription`, read 2026-08-22.

- **Premium Plan, 2 seats, ACTIVE.** $24 / user / mo billed annually; the page offers a
  Monthly/Annually toggle marked −20% for annual. AI credits available balance **$0.00**.
- **No self-serve open-source control exists on the subscription page.** The only discounts surfaced
  are a Gartner-review offer (20% off) and "Book a call" for Enterprise. This **confirms** the paid-levers
  checklist's read that the 100% OSS discount is contact-required, and it is why that item cannot be
  closed by an agent: it is an outbound request, not a toggle.

### Pending an owner click — nothing below has been done

Every item here is an account or billing change. Each needs a live confirmation in chat before the
click, and the owner performs anything involving payment.

| # | Action | Page / control | Worth |
|---|---|---|---|
| 1 | Greptile: enrol `claude-code-config` in **Greptile for Open Source** | Greptile billing → OSS repo picker | this repo's reviews → **$0**; keeps the tool |
| 2 | Greptile: set a **Flex Usage Limit** (or cancel outright) | Greptile billing → "Toggle flex usage cap" / "Cancel subscription" | caps an uncapped $1/credit exposure |
| 3 | CodeRabbit: seats **3 → 2** (drop `zilbermang`) | `auerbachb` → Team Management → seat manage | −$30/mo |
| 4 | CodeRabbit: **monthly → annual** at 2 seats | `auerbachb` → Billing → "View all plans" | $60 → **$48**/mo; **must land before 27 Aug** |
| 5 | BugBot: **Autofix → Off** | Bugbot settings → Autofix Mode | ~$470/cycle of never-merged runs |
| 6 | BugBot: drop the 23 `LocalMovers-dot-com` repos | Bugbot → Organizations → Manage | **$0 today** — blast-radius cap only |
| 7 | CodeAnt: submit the **100% open-source discount** request | contact route; no self-serve control | $48/mo → $0 if granted |
| 8 | CodeRabbit: metered add-on — **still blocked** | billing profile incomplete | decide after 1–6 settle |

Items 3 and 4 are the only time-boxed ones: CodeRabbit renews **27 Aug 2026**, and past that the
annual saving waits a full cycle.

### 6. The audit's first measured pass — run 2026-08-22

`/review-stack-audit --report-only` ran against a **non-truncated** 30-day window (2026-07-23 →
2026-08-22, **240 PRs**). Report at `~/.claude/review-stack-audit/review-stack-audit-2026-08.md`;
snapshot and drift JSON alongside it. Advisory only — it changed no rule, script, or subscription.

**Run it twice or do not trust it.** The first pass truncated at 60 PRs, and `drift.sh` **skips the
D2 (paid-but-unused) check entirely on a truncated window** — on a partial sample a tool active only
in the unsampled PRs is indistinguishable from one that did nothing. D2 is exactly the check this
issue needed for Greptile, so the pass was repeated at `--limit 400`. The truncated pass also
reported BugBot with **0 review objects** where the full window shows **153** — a sampling artifact
of the most recent PRs, where BugBot is spend-capped. Treat any truncated run's absence-findings as
unusable.

| Tool | State | PRs | Reviews | Approved | Inline | Sole-source | Caps |
|---|---|---|---|---|---|---|---|
| CodeRabbit | capped | 240 | 185 | 0 | 369 | 25 | `rate_limit` |
| CodeAnt | capped | 240 | 444 | **376** | 119 | 13 | `not_subscribed` |
| BugBot | capped | 220 | 153 | 0 | 150 | 29 | `spend_limit` |
| Greptile | **active** | 130 | 72 | 0 | 92 | **40** | none |
| Graphite | active | 10 | 10 | 0 | 10 | 2 | none |
| Vercel | silent | 0 | 0 | 0 | 0 | 0 | none |

**Three drift findings, and no D2 against anything.** That last part is the decisive answer to this
issue's Greptile question: the org is paid, but over 30 days Greptile is **not** unused — it is the
**top sole-source finder in the stack at 40 PRs**, ahead of BugBot (29), CodeRabbit (25), CodeAnt
(13) and Graphite (2), and it hit no cap at all. The zero-consumption day observed in §1 is one day
old, not a pattern. **Cancelling would remove the chain's most unique finder to save $36/mo, when
self-serve OSS enrolment gets the same coverage to $0.**

| Code | Tool | Severity | Divergence | Disposition |
|---|---|---|---|---|
| D3 | BugBot | **high** | `spend_limit` on 148 PRs, baseline expects none | deferred to this issue (dedup coverage 1.0) |
| D3 | CodeRabbit | medium | `rate_limit` on 217 PRs, baseline expects none | deferred to this issue (dedup coverage 1.0) |
| D1 | Graphite | medium | advisory role, yet sole finder on 2 PRs | **filed as #1232** — no open issue covered it |

Both D3s fired **by design**: the baseline's own note records that the degraded-stack caps were
"intentionally left out of `expected_caps` so the first post-swap audit run reports them as genuine
drift rather than suppressing it."

**No compared field in `review-stack-baseline.json` was changed** — `role`, `billed`, `gates_merge`,
`approves_via`, and `expected_caps` are byte-identical, so this run's drift result is reproducible.
Folding those two caps into `expected_caps` would stop them firing — and would pre-suppress the exact
signal that shows whether the pending owner changes (BugBot Autofix → Off, the CodeRabbit seat cut and
cadence switch) worked. Apply the changes, re-measure, *then* decide whether a surviving cap belongs
in the baseline.

The one edit made there is to Greptile's **`notes`** prose, which `drift.sh` does not read: PR #1230
had recorded that entry as `CONTESTED … Settle it from app.greptile.com/... before treating either
state as fact`, and this session settled it. Leaving that instruction standing would send the next
reader to re-run a check already answered here. Re-running `drift.sh` against the edited baseline
returns the same three findings.

**Throughput: 8.0 PRs/day, 28.8 review objects/day** across the window — the full-window figure
Issue #1191's concurrent-work cap derives from, not a floor.

**Caveats.** No truncation on the reported pass. Seven unclassified limit-shaped comments were
checked individually and **all seven are false positives** — bot comments discussing billing, quota,
or rate-limit wording inside this investigation's own PRs (#1216, #1208, #1203, #1186, #910, #883),
not cap notices. No unmatched baseline tools. `billed` remains a human-declared field; no vendor here
exposes a billing API these scripts can read.

## Round 5 — owner-session clicks (2026-08-22 evening)

Issue: [#1228](https://github.com/auerbachb/claude-code-config/issues/1228). **This is the first round
that changed anything.** Rounds 1–4 were read-only; this one carried out the owner-confirmed actions
from Round 4's §Pending. Every change below was confirmed live in chat before the click, was performed
by the agent only where no payment or personal data was involved, and is recorded with the
post-change string read back from the dashboard.

Two of Round 4's conclusions did not survive contact with the actual controls. Both are corrected
below; Round 4 is left standing as the dated record of what was believed then.

### 1. Greptile OSS enrolment — **REJECTED by the vendor: a 50-star minimum**

Source: `app.greptile.com/auerbachb/-/settings/billing`, OSS picker, 2026-08-22.

Selecting `auerbachb/claude-code-config` in the *"Greptile for Open Source"* picker returns, verbatim:

> **"This repository doesn't qualify yet. The program requires at least 50 stars and this repository
> has 3."**

The picker renders the repo with `★ 3  MIT` and a **"Check again"** button.

**This supersedes Round 4 §1's central conclusion.** Round 4 opened the picker, saw the repo listed,
and closed without selecting — recording it as "present and selectable" and concluding that
*"self-serve OSS enrolment gets the same coverage to $0"* (also asserted in §6's Greptile paragraph).
It does not. **Listing is not eligibility**: the picker enumerates every public repo on the account and
runs the eligibility check only on selection. The $0 third option Round 4 introduced against #1228's
cancel-vs-keep framing **does not exist for this repo at 3 stars**.

Generalised lesson, and the reason this cost a round: *a vendor program's eligibility gate may be
invisible until you commit the action.* Reading a control is not the same as exercising it. Where a
later reader sees an OSS/free-tier route recorded as "available", check whether anyone actually
selected it.

### 2. Greptile — kept, and the uncapped flex line is now bounded at $100

With OSS closed, the question reverted to #1228's original binary. The owner chose **keep**, on §6's
evidence that Greptile is the stack's top sole-source finder (40 PRs/30 days, no cap hit) — and added
the flex cap that Rounds 1–4 all recorded as unset.

- Before: **"No cap on flex usage"**, `$21 in flex charges this period`.
- The `Toggle flex usage cap` switch defaults the field to **$500**. That is ~24× the observed burn
  (42 credits ≈ $21/cycle) and would never bind, so it was set to **$100** — ~5× headroom, but an
  actual bound on a runaway.
- After, and surviving a reload: **`Stop flex usage after $100  ≈ 200 credits · $0.50 each`**,
  **`$22 of $100`**, switch `aria-checked="true"`.

This closes the only genuinely unbounded spend line on any of the four accounts.

Usage was **92 reviews / 92 credits** for a second consecutive day — byte-identical to both the
2026-08-21 and the 2026-08-22 morning readings. Two days of zero consumption is now on the record;
it still does not outweigh the 30-day sole-source figure, but a third and fourth such day would.

### 3. BugBot Autofix — **Off**

Source: `cursor.com/automations/from-cursor/bugbot`, 2026-08-22.

`Autofix Mode` moved from **Create New Branch (Recommended)** to **Off**. Confirmed two ways: the
setting reads `Off`, and the dependent **`Autofix Severity Threshold`** row (previously `Low, Medium,
High`) **disappeared from the page** — it only renders while autofix is enabled.

The aggressive core the owner chose to keep is untouched and was re-read after the change: Trigger
Mode **Every Push**, Effort **High**, Review Draft PRs **On**, Incremental Review **Off**, PR
Summaries **Off**, risk score **Off**.

Worth ~**$470/cycle** on Round 4's arithmetic (299 autofix runs, **0 ever merged**, ~$1.58/run). This
was the single largest realisable saving in the whole issue and it is now taken.

### 4. BugBot 23-repo drop — **declined, and the route is not what #1228 assumed**

#1228 asked to "drop the 23 out-of-scope org repos from coverage." **There is no such control.**
`Bugbot → Organizations → Manage` does not open a BugBot repo list; it navigates to
`cursor.com/dashboard/integrations`, whose only relevant control is the **GitHub App installation** —
*"Connected as auerbachb to repositories accessible in organizations: LocalMovers-dot-com, auerbachb,
faculoyarte."*

Editing there changes Cursor's GitHub App access for that org, which also governs Cloud Agents and
codebase context — a materially wider blast radius than a coverage toggle, on an org #1228 scopes out.
Combined with Round 4's sizing (**$0** — not one run has ever come from those 23 repos), the owner
declined it. **Recorded as a deliberate decline, not as pending.**

### 5. CodeRabbit — seat unassigned; the billed seat count is gated behind a billing-details form

Source: `app.coderabbit.ai` → org **`auerbachb`**, 2026-08-22.

Confirmed unchanged before acting: Pro/Active, **3 of 3 assigned**, **$90**, **Monthly**, next renewal
**27 Aug 2026**, support code `CR-966E0F`. Seat holders' latest CodeRabbit-reviewed PR: auerbachb *2
minutes ago*, faculoyarte *a day ago*, **zilbermang *2 months ago***.

**Done:** zilbermang's seat was unassigned (Team Management → select row → **Unassign**). Roster now
reads **`2 of 3 assigned`**.

**Not done, and it is a two-step change nobody had separated:** unassigning frees a seat but does
**not** reduce the purchased count or the bill — the page still reads **`Seats 2 of 3 assigned`** /
**`Billing amount $90`**. Cutting the billed count needs `Billing → Edit → Developer seats`. That
editor accepted 3 → 2 and produced a correct order summary — *Pro, `$30`/Seat/month, Seats 2, Monthly,
Subtotal `$60`, Total `$60`, Renews August 27, 2026, Secured by Chargebee* — but **Continue** then
opens a **Chargebee billing-details form**: name, company, phone number, billing email, tax ID,
billing address, with the Visa ····2990 attached.

That is personal and payment data, so the agent **cancelled out**; state re-verified afterwards as
unchanged (`2 of 3 assigned`, `$90`, Monthly). This is the same gate behind the standing banner
*"Account information incomplete: name, phone number, billing address missing"* — and it blocks
**three** items at once: the seat reduction, the monthly→annual switch, and any add-on change.

Sequencing still matters: **seat cut before cadence switch**, or the annual price locks against a seat
about to be removed. Both must land before **27 Aug 2026** or the saving waits a cycle.

Plan pricing re-confirmed from `View all plans`: Pro **$24**/developer/month billed annually (`Save
20%`), Pro Plus $48. At 2 seats that is **$48/mo annual vs $60/mo monthly vs $90/mo today**.

### 6. CodeRabbit usage-based reviews — **already ON, with a $10 cap**

Read from `Billing → Edit`, which reflects saved state (its seat field read back the saved `3` after
the cancelled edit, and its plan/cycle matched the overview):

| Addon | State |
|---|---|
| **Usage-based reviews** (25¢ / file reviewed) | **ON**, spend cap **$10** |
| AI Deep Scan usage | Off |
| Agent usage | Off (requires Slack/Discord connected) |

**This corrects Round 4 §Pending item 8**, which recorded the metered add-on as *"still blocked —
billing profile incomplete"* and deferred the decision. It is not blocked and not undecided; it is
enabled and bounded. #1228's AC 6 asked for "On-demand with an explicit cap, never Automatic" — that
is the configuration already in place, so the AC is **satisfied by the existing state**, not by a
change. The demand signal is real: CodeRabbit's own Explore page reports **"3 developers (100%) hit
review rate limits in the last 30 days"**, matching §6's `rate_limit` D3 on 217 PRs.

The $10 cap is worth a deliberate look once the seat change lands — at 25¢/file it buys ~40 files of
overflow per cycle — but raising it is an add-on change and therefore sits behind the same billing
form.

### 7. CodeAnt — the account-wide discount is declined on principle; the per-repo route is undocumented

The owner rejected the framing behind #1228's AC 5, and the objection was correct: **an account-wide
"100% off for open source" application would be a claim about the whole account**, and five of the six
active repos are not open source. Applying on that basis would misrepresent us. **Declined on
principle — recorded as declined, not deferred.**

The narrower question the owner did endorse is per-repo: `auerbachb/claude-code-config` alone is
public and MIT (`LICENSE` at `origin/main`; GitHub reports `spdx_id: MIT`). Two routes exist and
neither is clean:

- A **self-serve GitHub App**, `github.com/apps/codeant-ai-for-open-source` ("CodeAnt AI - For open
  source"), which does present a working **Install** button.
- The **documented** route, which is still contact-only: `codeant.ai/pricing` carries *"100% OFF FOR
  OPEN SOURCE"* with an email contact and **publishes no eligibility criteria at all** — no star
  count, no licence requirement.

**Not installed.** Nothing published states that installing that app makes a repo free, and the repo
is already covered by the paid Premium installation, so a second CodeAnt app risks duplicate reviews
and unclear billing attribution without necessarily removing a dollar from the $48/mo. Given Greptile
just demonstrated that an OSS gate can be invisible until exercised — and CodeAnt publishes *no* gate
to inspect — the defensible next step is the email, scoped to the one repo, sent by the owner.

CodeAnt subscription state re-confirmed unchanged: **Premium, 2 seats, ACTIVE**, $24/user/mo billed
annually, AI credits balance $0.00, AMEX ····1007.

### Net effect of this round

| Change | State | Worth |
|---|---|---|
| BugBot Autofix → Off | **applied** | ~$470/cycle of never-merged runs |
| Greptile flex cap → $100 | **applied** | bounds a previously uncapped line |
| zilbermang seat unassigned | **applied** | $0 until the billed count drops |
| BugBot 23-repo drop | **declined** | $0 — blast radius exceeded the benefit |
| CodeAnt account-wide OSS discount | **declined** | not a claim we can honestly make |
| Greptile OSS enrolment | **ineligible** | 50-star gate; revisit via "Check again" |
| CodeRabbit usage add-on | **already configured** | on, capped $10 — AC satisfied as-is |

### Still pending an owner click

Both remaining items need the Chargebee billing-details form completed first — that single form
unblocks all of them.

| # | Action | Page / control | Worth |
|---|---|---|---|
| 1 | Complete the billing profile | CodeRabbit `Billing → Edit` → Chargebee form (name, phone, address) | unblocks 2 and 3 |
| 2 | Developer seats **3 → 2** | `Billing → Edit → Developer seats` → Continue | $90 → **$60**/mo |
| 3 | Billing cycle **Monthly → Annual** (after 2) | same editor, `Billing cycle` | $60 → **$48**/mo |
| 4 | CodeAnt OSS request for this repo only | email `amartya@codeant.ai` | **unknown — keep budgeting $48/mo** |

On item 4's worth: a per-repo grant covers **one of six** active repos, and CodeAnt publishes no
per-repo OSS pricing, so the reduction may be partial or nil (the plan bills by seat, not by repo).
The **$48/mo → $0** figure carried in earlier rounds assumed the *account-wide* discount, which is
declined. Budget the full $48/mo until a vendor reply states an amount.

Items 1–3 are time-boxed to **27 Aug 2026**.

### Method note — the browser surface was unreliable, and one near-miss came of it

Recorded because it cost most of this session and will recur.

- **Screenshots remain unavailable** (CDP capture fails), as in Round 4. Every figure here is a quoted
  string read from the DOM.
- **A backgrounded tab silently swallows input.** Every click "succeeded" while landing nowhere; the
  tab read `visibilityState: "hidden"`. Diagnosed by installing a capture-phase `click` listener and
  firing at a known coordinate — **zero events arrived**. Only the visible tab receives synthetic
  input. Confirm `document.hidden === false` before trusting any click.
- **Element refs can resolve one row off.** A ref-based click on zilbermang's checkbox selected
  `cursor`'s row instead (52 px lower). Caught only because the selection was re-read before acting.
  **Verify the selection, not the click's return value**, before any destructive or billing action.
- **CodeRabbit's app never fires `document_idle`**, so `read_page`/`find` time out against it; DOM
  reads via injected JS work fine. Its `/organizations` table also reports `auerbachb` as **"Total
  seats: 1"**, which contradicts the billing page's authoritative `3 of 3 assigned` — do not quote the
  org table for seat counts.
- **The org scope trap held**: `app.coderabbit.ai` again opened on **LocalMovers-dot-com**. Switching
  is done by clicking the org's **row** in `/organizations`, not the row menu (which offers only
  "Archive User") and not the sidebar dropdown.

## Round 6 — close-out (2026-08-23)

Issue: [#1228](https://github.com/auerbachb/claude-code-config/issues/1228), **closed 2026-08-23.**
This round records the terminal state and ends the effort. **Appended, not merged into earlier
rounds** — this file is point-in-time (see the header) and Rounds 1–5 stay exactly as they were
written, including the parts later rounds overturned.

Unlike Round 5, no agent touched a dashboard here. The two remaining changes sat behind the Chargebee
billing-details form — owner-only personal and payment data — so **the owner performed them directly**
and reported the outcome. What follows is that report, not a read.

### The one form cleared, and the two items behind it went opposite ways

Round 5 ended with a single blocker gating three things: an incomplete CodeRabbit billing profile.
**The owner completed it.** Then:

| # | Round 5 pending item | Outcome 2026-08-23 |
|---|---|---|
| 1 | Complete the billing profile | **DONE** — the Chargebee form (name, phone, billing address) is filled |
| 2 | Developer seats **3 → 2** | **DONE** — billed count cut; **$90/mo → $60/mo** |
| 3 | Billing cycle **Monthly → Annual** | **DECLINED by the owner** — CodeRabbit **stays monthly** |
| 4 | CodeAnt per-repo OSS email | **WAIVED** — not sent; keep budgeting $48/mo |

**§Still pending an owner click is therefore fully resolved** — two done, one declined, one waived.
Nothing from Rounds 1–5 is left awaiting anyone.

### The declined annual switch — read this before re-proposing it

The cadence decline **overrides a written recommendation**, which is why it is recorded here rather
than left implicit. [#1212](https://github.com/auerbachb/claude-code-config/issues/1212) concluded
*"stay paid, and switch to annual billing"*, and
[`ai-review-paid-levers-checklist.md`](./ai-review-paid-levers-checklist.md) item 3 carried the annual
step as the last untaken lever. The **stay-paid half stands.** The cadence half does not.

What the owner declined is the **12-month commitment**, not the arithmetic. Annual really is
$24/dev/mo against $30 monthly — at 2 seats, **$48 vs $60/month, $144/year** — and none of that is in
dispute. Recomputing the 20% discount is not new information and is not grounds to reopen it. The
terminal billed state is:

| Field | Value |
|---|---|
| Plan | Pro, Active |
| Seats | **2** |
| Billing cycle | **Monthly** |
| Amount | **$60/mo** |

A `/review-stack-audit` run that notices a monthly cadence where annual is cheaper is reading
**expected state, not drift.**

### What the whole effort landed

Across Rounds 4–6, against the state Rounds 1–3 measured:

| Change | State | Worth |
|---|---|---|
| BugBot Autofix → Off | applied 2026-08-22 | stops ~$470 of never-merged runs — a **lifetime** figure; per-cycle worth unmeasured |
| Greptile flex cap → $100 | applied 2026-08-22 | bounds the only previously uncapped line |
| CodeRabbit seats 3 → 2 | **applied 2026-08-23** | **$30/mo** |
| CodeRabbit monthly → annual | **declined 2026-08-23** | $144/yr not taken, deliberately |
| CodeRabbit metered add-on | already on, capped $10 | no change needed |
| Greptile OSS enrolment | ineligible (50-star gate) | $0 route does not exist at 3 stars |
| BugBot 23-repo drop | declined 2026-08-22 | $0 — blast radius exceeded the benefit |
| CodeAnt account-wide OSS discount | declined on principle | not a claim we can honestly make |
| CodeAnt per-repo OSS email | waived 2026-08-23 | unknown — keep budgeting $48/mo |
| BugBot Incremental → On, Drafts → Off | **waived 2026-08-23 — never applied** | unquantified; dashboard last read them `Off`/`On` |

**Recorded as waived, not done, on purpose.** The last row was accepted in principle at #1209 and
carried into #1228, but Round 5 re-read the BugBot settings after the Autofix change and found
Incremental Review still `Off` and Review Draft PRs still `On`. Nobody clicked them, and the close
waived the remaining optional items rather than completing them. A lever nobody took must not appear
in a savings column.

**One figure is restated more carefully here than in earlier rounds: the Autofix saving.** Rounds 4
and 5 and §Pending both write it as **"~$470/cycle"**. The underlying measurement is **299 autofix
runs, 0 ever merged, at ~$1.58/run** — and those 299 are the **lifetime** total (Round 4 calls them
"27% of lifetime run volume"), not one cycle's. So ~$470 sizes **spend already incurred**, and no
per-cycle rate for it has been measured. Turning autofix off stops that waste; **what it saves per
month is an open number** until a full cycle runs without it. Earlier rounds keep their wording —
they are point-in-time records and are not rewritten — so treat this paragraph as the correction and
do not carry "$470/cycle" forward into a budget.

### Deliberately not recorded: Greptile's payment provenance

**Which card the `auerbachb` Greptile org charges is still being verified by the billing admin,
out-of-band.** It is left blank here on purpose — this file's redaction rule keeps payment-instrument
identifiers out of a public repo, and beyond that we simply do not yet have a verified answer. **Its
absence is a decision, not a gap.** Add a line when the answer lands, redacted to the same standard as
the rest of this file.

Everything else about Greptile is settled and recorded above: **paid** on the `auerbachb` org (not
free — that was `localmovers-com`), **kept** on the sole-source evidence, **flex capped at $100**, and
**OSS-ineligible** at 3 stars with a "Check again" button if it ever passes 50.

### Where the standing record lives now

This file stops here. It is a dated snapshot and does not track forward.

- **Standing decision record** — [`ai-review-chain-roles-decision.md`](./ai-review-chain-roles-decision.md):
  roles, cost rationale, and §Operator actions item 6, which carries the declined cadence.
- **Standing tracker** — [`ai-review-paid-levers-checklist.md`](./ai-review-paid-levers-checklist.md):
  every lever at its terminal state, marked done, declined, or waived.
- **Re-measurement** — [`review-stack-audit.md`](./review-stack-audit.md) runs monthly against
  `review-stack-baseline.json`. It now runs against a quiet record: no item on the checklist is
  waiting on anyone, so anything it surfaces is genuinely new.

**Point-in-time siblings that still recommend annual are correct as history and must not be edited:**
`pricing-matrix.md` owner-action item 4 and
[`cr-oss-vs-paid-decision.md`](./cr-oss-vs-paid-decision.md)'s headline verdict both predate the
decline. They are superseded in the checklist's §Superseded, not rewritten in place.
