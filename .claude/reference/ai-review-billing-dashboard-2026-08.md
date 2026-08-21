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

**Redactions.** Payment-instrument identifiers present in the source have been removed; they carry
no operational value here. Seat-holder emails are retained because which identity holds a seat is
the actionable fact behind the CodeAnt finding.

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
- Seats (**2 of 2 used, 0 left**): `bretton.auerbach@gmail.com` (Admin) and `faculoyarte@gmail.com` (Member), both with AI Code Review access. An Auto Enroll Team Members toggle exists (state not verified).
- **Which email holds the seat:** `bretton.auerbach@gmail.com`. The CI/commit email our PRs are authored under is **not** in the seat list — consistent with the 84% warning rate. CodeAnt reviews anyway but flags the author as unlicensed.
- Fix options (not executed): **Path A** — buy a seat, then invite the CI email (~$24/mo to license a placeholder identity). **Path B** — set the machine's global git `user.email` to a seat-holding address (**$0**). Path B is the cheaper fix if the CI identity is a convenience alias.
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

## Still open after this session

1. **Which Greptile installation serves `auerbachb/*`, and what does it bill?** The org read here does not cover this repo. Highest-value remaining unknown.
2. **BugBot attribution** — `github_bugbot` line vs. operator's IDE-usage account. Support ticket.
3. **CodeAnt org-defaults page** — hung twice, never read.
4. **CodeRabbit overflow-vs-Pro-Plus decision**, and whether `paulkathat-lmc` should hold a seat.
