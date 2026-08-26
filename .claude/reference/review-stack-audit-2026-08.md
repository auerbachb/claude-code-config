# Review stack audit — 2026-08 (CodeRabbit cap reconciliation)

**Issue:** [#1303](https://github.com/auerbachb/claude-code-config/issues/1303) — drift finding `coderabbit/D3`, filed by `/review-stack-audit` (built under [#1201](https://github.com/auerbachb/claude-code-config/issues/1201))
**Date:** 2026-08-26 ET
**Window:** 2026-07-25 → 2026-08-26 (32 days, **268 merged PRs, not truncated** — `window.truncated: false` at `--limit 300`)
**Baseline:** `.claude/reference/review-stack-baseline.json` (decision-record provenance, as of 2026-08-23)

> **Filename note.** `/review-stack-audit` SKILL.md Step 7 maps `--report-to-repo` onto
> `ai-review-tool-audit-YYYY-MM.md`, but that slot is already occupied by
> [`ai-review-tool-audit-2026-08.md`](./ai-review-tool-audit-2026-08.md) — the manual #1199
> subscription audit from 2026-08-21. Two audits landed in one month and the monthly naming has no
> room for the second. This report therefore takes the skill's own series name rather than
> overwriting a prior record. The collision is a real gap in Step 7 and is listed under Follow-ups.

## Executive summary

CodeRabbit's limits are now measured rather than inferred, and the baseline records both of them.
The tool is running into **two different mechanisms** that the old single `rate_limit` cap kind
collapsed into one: a **per-developer per-hour burst allowance** (Pro base: 5/hr) and the **Fair
Usage adaptive band**, which *sets* what that hourly number currently is based on trailing 7-day
attempt volume. Measured on this repo, the band has pushed the allowance to **1 review per hour**.

The starker figure is unchanged by re-measurement: **CodeRabbit posted zero `APPROVED` reviews**
across the window. It satisfied **no merge gate here** — not because it is degraded, but because it
is not an approver at all: the same zero appears in every window this repo has measured, including
the 2026-06 audit and the 244-PR 2026-08 one. Every gate in this window was carried by CodeAnt.

Nothing here changes routing. This audit is advisory: it records what was measured, records the
chain-position decision, and leaves any demotion or cut to its own reviewed PR.

### What the two mechanisms are

| Mechanism | Cap kind | What sets it | Signal phrase |
|---|---|---|---|
| Per-developer hourly burst allowance | `rate_limit` | The plan tier. Pro = **5 reviews/hour per developer** (dashboard, [#1204](https://github.com/auerbachb/claude-code-config/issues/1204), 2026-08-21) | `Review limit reached`; `<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->` |
| Fair Usage adaptive band | `fair_usage` | Trailing **7-day** included-attempt volume, which *lowers* the hourly allowance below the plan base | `under our [Fair Usage Limits Policy]` |

They are not independent, and they are not disjoint populations. The Fair Usage band is the thing
that decides what number the hourly burst allowance holds right now; one banner comment routinely
carries **both** signals, so a PR can be counted under both kinds. Reading either count as the whole
story is the mistake the split exists to prevent — the classifier test suite pins the co-occurrence
so a future reader cannot re-learn it the expensive way.

### The band, measured

CodeRabbit states the band's arithmetic in its own banner. Each row below is quoted from the
`Review limit reached` comment on that PR:

| PR | Merged | Trailing 7-day attempts | Resulting allowance |
|---|---|---|---|
| [#1240](https://github.com/auerbachb/claude-code-config/pull/1240) | 2026-08-22 | 57 | **2 reviews/hour** |
| [#1250](https://github.com/auerbachb/claude-code-config/pull/1250) | 2026-08-22 | 60 | **1 review/hour** |
| [#1295](https://github.com/auerbachb/claude-code-config/pull/1295) | 2026-08-24 | 68 | **1 review/hour** |
| [#1320](https://github.com/auerbachb/claude-code-config/pull/1320) | 2026-08-25 | 77 | **1 review/hour** |
| [#1330](https://github.com/auerbachb/claude-code-config/pull/1330) | 2026-08-26 | 76 | **1 review/hour** |

Verbatim, from PR #1295: *"You've used the included review currently available. Your 68 included PR
review attempts over the past 7 days set your current allowance at 1 review per hour."* The same
comment states *"**Plan**: Pro"*.

The 57 → 2/hr and 60 → 1/hr pair brackets the **60-attempts-per-week cliff** the #1199 audit read off
the dashboard, and is the first time this repo has measured that cliff from the vendor's own
per-PR arithmetic rather than from a dashboard summary.

**The banner wording changed mid-window**, which matters for anyone re-deriving these numbers. Early
in the window the text was qualitative — PR [#774](https://github.com/auerbachb/claude-code-config/pull/774)
(2026-07-28): *"Your recent review volume is higher than typical usage, so adaptive limits are
currently applied."* From roughly 2026-08-22 it became quantitative, naming the attempt count and the
resulting hourly figure. Same mechanism, better instrumentation. A phrase table keyed on the numeric
sentence would have matched nothing for the first four weeks of the window, so the classifier keys on
the clause both generations share.

**That clause is the refusal, not the policy name.** The first cut of this classifier matched the bare
noun phrase `fair usage limits policy`, and CodeAnt caught the flaw on this PR: CodeRabbit also
*explains* the policy in ordinary prose, and quotes this repo's own cap documentation back at us, so
the bare phrase counted a tool that was answering a pricing question as a tool that had been
throttled. PR [#1292](https://github.com/auerbachb/claude-code-config/pull/1292) carries a live
instance — a 7.3 kB CodeRabbit answer reading *"CodeRabbit also maintains a Fair Usage Limits Policy,
which may adjust review availability…"*. The classifier now matches `under our [Fair Usage Limits
Policy]` (and its unlinked form), the clause CodeRabbit writes only when actually declining a review;
explanatory prose says *"maintains a"*, never *"under our"*. It covers all three refusal verbs seen in
the window — *"You've reached a temporary PR review limit under our…"* (banner), *"Your included
review limit is currently reached under our…"* (ack), *"You're currently rate limited under our…"*.

**The correction is count-preserving**, which is why every figure below still stands. The window was
re-measured end to end against the tightened classifier: `fair_usage` holds at 222 PRs on an
*identical* PR set — none lost, none gained — and `rate_limit` (224), the overlap (213) and the union
(233) are unchanged. The only movement is `unclassified_hits` 27 → 28: the #1292 prose comment now
surfaces for a human instead of being silently counted as a cap, which is the behaviour the
`unclassified[]` probe exists to provide. A future reworded refusal lands there too rather than being
dropped.

### A third signal, newly present and not yet a cap kind

Some banners also carry: *"Your organization has reached its usage spending cap. Adjust your spending
cap in the billing tab."* Present on PRs #1295 (2026-08-23) and #1330 (2026-08-26); **absent** from
PR #1240 (2026-08-22). That is three banners checked by hand for this phrase, not a sweep — it points
at an onset in that 24-hour window without establishing one.

This is a third, distinct mechanism — the metered usage-based overflow add-on, which
[`cr-oss-vs-paid-decision.md`](./cr-oss-vs-paid-decision.md) recorded as **off** on 2026-08-21. It is
evidently now on *and* exhausted. It is **not** recorded as a cap kind in this PR, because:

- in every instance checked here it sat inside a comment that already matched a declared classifier,
  and `classify_body` short-circuits on the first declared match — so it never reaches the
  `unclassified[]` probe, and the audit's own blind-spot mechanism cannot surface it; and
- adding a third kind is a scope expansion past what this finding asked for.

Both halves of that are recorded as follow-ups rather than left implicit.

## Per-tool measurements

268 merged PRs, 2026-07-25 → 2026-08-26. `Sole` = PRs where this tool was the only one to post an
inline finding.

| Tool | State | Plan | PRs | Reviews | Approved | Inline | Sole-source | Caps |
|---|---|---|---|---|---|---|---|---|
| CodeRabbit | capped | pro | 268 | 254 | **0** | 514 | 32 | `rate_limit` (224 PRs), `fair_usage` (222 PRs) |
| CodeAnt | capped | — | 268 | 669 | **530** | 241 | 15 | `not_subscribed` (189 PRs) |
| BugBot (Cursor) | capped | — | 248 | 153 | 0 | 150 | 29 | `spend_limit` (176 PRs) |
| Greptile | active | — | 135 | 80 | 0 | 101 | **37** | none |
| Graphite | active | — | 14 | 15 | 0 | 16 | 2 | none |
| Vercel | silent | — | 0 | 0 | 0 | 0 | 0 | none |

`APPROVED` remains a CodeAnt monopoly, as in every prior audit in this series. Greptile is again the
highest sole-source contributor (37 PRs) despite touching only half the window.

### CodeRabbit cap incidence, by kind

| | PRs |
|---|---|
| `rate_limit` (burst-allowance signals) | 224 |
| `fair_usage` (Fair Usage band named explicitly) | 222 |
| **Both kinds on the same PR** | **213** |
| `rate_limit` only | 11 |
| `fair_usage` only | 9 |
| **Union — PRs hitting at least one cap** | **233 of 268 (87%)** |

The 213-PR overlap is the number to keep in view: the two counts describe one banner seen through
two lenses, so **224 + 222 is not a total**. Of the three declared CodeRabbit patterns, `review limit
reached` contributed exactly **1** PR that the machine marker had not already claimed — it is a
redundant heading in practice, kept because it is the human-readable half and could outlive the
marker.

## Drift findings

Run against this snapshot with the updated baseline:

| Code | Tool | Severity | Divergence | Observed | Expected |
|---|---|---|---|---|---|
| D3 | BugBot (Cursor) | high | Hit a limit the baseline does not record: `spend_limit` | `spend_limit` on 176 PRs | `expected_caps: []` |

`coderabbit/D3` **no longer fires.** The remaining `bugbot/D3` is pre-existing and deliberate: the
baseline's BugBot entry states that `expected_caps` is left empty so the current spend exhaustion
surfaces as genuine drift. It is out of scope for this finding and is not touched here.

**Before/after control**, both runs against the identical snapshot:

| Baseline | Findings |
|---|---|
| `origin/main` (before) | `coderabbit/D3`, `bugbot/D3` |
| this branch (after) | `bugbot/D3` |

Exactly one finding was removed, and it is the target one. No other tool's verdict changed.

## Throughput

268 merged PRs over 32 days — **8.4 PRs/day**. Across all six tools the window carried 1,171 review
objects, **36.6 reviews/day**. CodeRabbit posted 254 of those while being capped on 233 of the 268
PRs, which is the shape of the problem: at this volume the Fair Usage band sat at 1 review/hour on
every banner sampled from 2026-08-22 onward, and the band is driven by our own PR rate rather than by
any setting someone can change.

## Is CodeRabbit satisfying any merge gate?

**No — and it is not supposed to.** This is the plainest statement the finding asked for, and it has
two parts that must not be merged:

1. **Measured fact.** **0 `APPROVED` reviews across all 268 PRs** in the non-truncated window — from
   254 review objects and 514 inline findings. The finding's truncated run said 0 of 60; the full
   window says 0 of 268. Meanwhile CodeAnt posted **530** approvals. On the two PRs the finding
   named: PR [#1265](https://github.com/auerbachb/claude-code-config/pull/1265) drew 4 CodeRabbit
   review objects, all `COMMENTED`, 0 `APPROVED`, against 5 CodeAnt approvals; PR
   [#1295](https://github.com/auerbachb/claude-code-config/pull/1295) drew 6 CodeRabbit review
   objects, all `COMMENTED`, 0 `APPROVED`, against 6 CodeAnt approvals, and escalated to Greptile.
2. **Design fact.** `gates_merge: false` and `approves_via: "none"` in the baseline are *correct*, not
   drift. CodeRabbit is a finder. `cr-merge-gate.md` Step 1 lets a CodeRabbit `APPROVED` satisfy the
   CR path if one ever arrives, but the gate does not depend on it: CodeAnt carries that path. Were
   the baseline to record CodeRabbit as an approver, `drift.sh` would fire a permanent, false `D4`
   every single run.

So "0 approvals" is a fact about what CodeRabbit is, not a regression. What the rate limiting costs
us is **finding coverage**, not gate coverage — and that is the axis on which any future
chain-position change should be argued.

## App versus CLI — do they share a limit?

**No. They are billed and limited independently, and #1286's OSS routing explains the CLI only.**
The decisive evidence is that the two surfaces report *opposite billing attribution for the same
repository within the same 24 hours*:

| | GitHub App (this audit) | CLI ([#1286](https://github.com/auerbachb/claude-code-config/issues/1286), 2026-08-23) |
|---|---|---|
| Plan reported | `**Plan**: Pro` (PR #1295 banner, 2026-08-23) | `Plan: Pro / Seat: assigned` (`coderabbit auth status`) |
| Billing attribution | **Org-billed** — *"Your organization has reached its usage spending cap"*, with an `orgId` | **Not org-billed** — `orgAttributed: false`, *"no organization will be billed. Free OSS limits apply."* |
| Pro entitlement as reported at the limit | Pro plan named in the same comment as the limit | `isProUser: false` in the rate-limit payload |
| Effective rate | Pro 5/hr base, Fair-Usage-banded down to 1/hr | **3 reviews per ~55-minute reset window** |
| What sets the rate | Plan tier + trailing 7-day attempt volume | Repository **visibility** — public repo routes to the free OSS pool |

The App is drawing on the paid org plan and has run that plan's metered overflow to its spending cap.
The CLI, on the same public repository, is not touching the org plan at all. `isProUser: false` names
*the pool the review was billed against*, not the account's tier — so the OSS tiering found in #1286
is a statement about the CLI's routing and **does not explain the App-side rate limiting**.

Two further notes so this is not over-read:

- `pricing-matrix.md` records that the 2026-08-21 `isProUser: false` observation **no longer held**
  as an entitlement claim on 2026-08-23 (`auth status` reads a Pro seat assigned). What persists is
  the *routing*: entitlement ≠ effective rate.
- The 1–10/hr star-scaled OSS band in the vendor docs applies to **App** PR reviews. The CLI is
  separately capped at 3 per reset window. Neither figure substitutes for the other, and a remedy on
  one surface does not fix the other.

## What NOT to change

- **`gates_merge: false` / `approves_via: "none"` for CodeRabbit.** Both stay. See §Is CodeRabbit
  satisfying any merge gate — flipping either manufactures a permanent false `D4`.
- **CodeRabbit's chain position.** Unchanged by this PR; see the reconciliation appended to
  [`ai-review-chain-roles-decision.md`](./ai-review-chain-roles-decision.md).
- **`cr-merge-gate.md` and `merge-gate-reviewer-paths.md`.** Untouched. This audit is advisory; a
  routing change lands as its own reviewed PR.
- **The `rate_limit` kind.** Kept for the burst signals rather than renamed to something tidier. The
  kind string is what prior snapshots recorded, so renaming it would make this window
  incomparable with earlier ones for no gain — the new information is the *second* kind, not a
  better name for the first.

## Follow-ups

1. **Report-filename collision in `/review-stack-audit` SKILL.md Step 7.** `--report-to-repo` derives
   one path per calendar month and will overwrite a prior month-mate. Not fixed here (skill change,
   out of this finding's scope).
2. **Recognizer blind spot: first-match short-circuit.** `classify_body` stops probing once any
   declared pattern matches, so a second, unrecognized cap phrase riding in the same comment is
   invisible to `unclassified[]`. The org spending-cap phrase is a live example. The audit's
   "never silently healthy" guarantee holds only for comments that match *nothing*.
3. **Usage-based overflow is on and exhausted.** `cr-oss-vs-paid-decision.md` records the metered
   add-on as off (2026-08-21); the App banner says the org spending cap is reached (2026-08-23
   onward). Someone should reconcile what is enabled and at what cap.
4. **Stale seat/billing sentence in the baseline's CodeRabbit `notes`.** It still reads "3/3 seats,
   $90/mo … has not yet made the change", while `ai-review-chain-roles-decision.md` records the
   2-seat cut as landed (#1228, 2026-08-23). Left untouched here on purpose: seat count is not
   measurable from GitHub, and this audit records measured values only.

## Caveats

- **The finding's own window was truncated.** The `coderabbit/D3` run measured 60 PRs against a
  `--limit` of 60 over 2026-07-25 → 2026-08-24, so its "41 of 60 rate-limited" was a **floor**. This
  report re-measures without truncation. The floor held: **233 of 268 (87%)** hit at least one cap,
  against the truncated run's 41 of 60 (68%). The 0-approvals figure the finding most wanted
  re-checked did not move at all — 0 of 60 became **0 of 268**.
- **The re-measured window is a superset, not the same window.** It runs to 2026-08-26 rather than
  2026-08-24, so it includes PRs (#1320, #1330) the original run could not have seen. Counts are
  therefore not directly subtractable from the original run's.
- **CodeRabbit edits its status comment in place.** The PR #1295 banner was created 2026-08-23 and
  last updated 2026-08-24; quoted figures reflect the comment's current content, not necessarily its
  content at creation. Live comment bodies are not stable fixtures.
- **`plan_observed` is a proxy.** It reads a tier the vendor volunteers in its own comment body. No
  vendor here exposes a billing API this measurement can read; the authoritative billed state is the
  human-maintained `billed` field in the baseline.
- **Unclassified cap candidates: 8 distinct `(tool, token)` pairs across 28 limit-shaped comments —
  and every one is a false positive.** The finding reported 6. Entries are deduped per
  `(tool, token)`, and this window is a superset in time, so the finding's six pairs are among these
  eight — though the PR cited for a given pair can differ between runs, since the dedupe keeps
  whichever PR it met first. All 8 are bots *discussing this repo's own documentation about caps*,
  not vendors announcing one:

  | Tool | PR | Token | What it actually is |
  |---|---|---|---|
  | CodeRabbit | #1306 | `quota` | Reviewing `CLAUDE.md`'s quota-authority section |
  | CodeAnt | #1299 | `billing` | Reviewing the `billing` field in this baseline file |
  | CodeRabbit | #1294 | `billing` | Reviewing `ai-review-billing-dashboard-2026-08.md` |
  | Graphite | #1216 | `billing` | Quoting a link to that same dashboard doc |
  | CodeRabbit | #1203 | `usage limit` | Discussing the Greptile Flex Usage Limit operator action |
  | CodeRabbit | #1186 | `rate limit` | Discussing error handling for a rate limit in our code |
  | CodeAnt | #910 | `usage limit` | A Mermaid diagram participant named "Usage Limit Hook" |
  | BugBot | #883 | `rate limit` | Discussing capability-failure-notice logic in `review-substance.sh` |

  **No phrase-table entry is warranted.** `CAP_SIGNALS` is not missing a vendor cap. This is the
  audit reading its own subject matter: a repo whose documentation is largely *about* review-tool
  caps will always generate limit-shaped prose for the generic probe to catch. That is the probe
  working — it surfaces candidates for a human, and it explicitly does not count them as caps.

## Cadence

Monthly, via `/review-stack-audit`. The recurrence is a session-start watermark check, not a
scheduled job — see SKILL.md Step 1. Next run should confirm `coderabbit/D3` stays clear and should
re-read the Fair Usage band, which moves with review volume rather than with any setting.
