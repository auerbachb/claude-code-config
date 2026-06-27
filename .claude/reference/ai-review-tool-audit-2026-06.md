# AI Review Tool Audit — 2026-06 (30-day value follow-up)

Issue: [#376](https://github.com/auerbachb/claude-code-config/issues/376)
Baseline (source of truth): [`ai-review-tool-audit-2026-04.md`](./ai-review-tool-audit-2026-04.md) (#368 / #377)

Date reviewed: 2026-06-27
Measurement window: **2026-04-29 → 2026-06-27** (PRs merged after #368 closed)
Sample: **63 merged PRs** (`gh pr list --state merged --search "merged:>=2026-04-29"`)

## Executive summary

After ~60 days of real usage, the productive review core is **three tools — CodeRabbit, CodeAnt, and BugBot.** They generated 99% of all findings and were the only tools to ever be the *sole* finding-provider on a PR. The remaining three (Greptile, Graphite, Vercel Agent) added **zero sole-source value** in the window.

Key verdicts:

- **CodeRabbit — KEEP (no change).** Primary findings engine: 198 inline findings, sole provider on 8 PRs. Never posts `APPROVED` (0 in the window) — confirms it is a *finder*, not an *approver*.
- **CodeAnt — KEEP + RECONFIGURE.** The de-facto **approver** (179 `APPROVED` reviews; present on all 63 PRs) and a strong finder (128 inline). But: (a) its **100-PR free trial is exhausted** — it now posts "trial limit reached / no PR Review subscription" warnings on 19 PRs (all recent), so continued reliance requires a paid plan; (b) **severity inflation** — 26 "Critical" + 72 "Major" badges in a markdown/shell/config repo.
- **BugBot — KEEP (no change).** Highest-precision tool: 99 inline findings, concrete bugs, reliable completion signal. Sole provider on 2 PRs.
- **Greptile — CUT the paid seat.** Fired on **4 PRs in the first 2 days, then 0 in ~8 weeks.** Never the sole finding-provider. $30/seat/month cannot be justified for a routine fallback that never fires. Keep the dormant last-resort *rule wiring* (cost is $0 until triggered, $1/review thereafter) **or** remove entirely — but cancel the recurring seat.
- **Graphite — KEEP as free advisory.** Now functioning (it was non-functional at the April audit): 15 precise inline findings across 9 PRs at **$0** (Hobby). Never sole-source → keep advisory, **do not** add to the merge gate.
- **Vercel Agent — KEEP DISABLED / Vercel-only (no change).** Never participated (0 activity under any login). Not applicable to this non-Vercel repo.

**Recommended chain (next period):** `CodeRabbit + CodeAnt (parallel primary; CodeAnt = approver) → BugBot (fallback) → self-review`, with **Graphite as free parallel advisory** and **Greptile demoted to dormant emergency-only / paid seat cancelled.** Vercel Agent stays off for this repo.

### Methodology & caveats

- Findings volume is measured from the three GitHub PR endpoints (`pulls/{n}/reviews`, `pulls/{n}/comments`, `issues/{n}/comments`, `per_page=100`) filtered by bot login: `coderabbitai[bot]`, `codeant-ai[bot]`, `cursor[bot]` (BugBot), `greptile-apps[bot]`, `graphite-app[bot]`, and `vercel[bot]`.
- **Inline review comments** are used as the cleanest proxy for "findings"; review summaries, status chatter ("running/finished"), and ack/tip comments are excluded from the findings count.
- **TP/FP rates are *estimates* from qualitative sampling**, not exhaustive per-finding adjudication. They reflect finding precision observed across a sampled set plus severity composition and the fact that all 63 PRs merged. Treat them as directional.
- The `~/.claude/session-state.json` consumption counters (`cr_hourly`, `greptile_daily`) referenced in the issue were **not present in this execution environment** (fresh cloud VM; counters live on the operator machine). All counts here are GitHub-derived, which is the authoritative record of what each tool actually posted.

## Findings volume — all 6 tools

| Tool | Bot login | PRs touched | Review objects | APPROVED | Inline findings | Issue comments | Sole provider on |
|------|-----------|-------------|----------------|----------|-----------------|----------------|------------------|
| CodeRabbit | `coderabbitai[bot]` | 63 / 63 | 127 (all COMMENTED) | **0** | **198** | 194 (mostly acks/tips) | **8 PRs** |
| CodeAnt | `codeant-ai[bot]` | 63 / 63 | 269 (179 APPROVED + 90 COMMENTED) | **179** | **128** | 861 (status/summaries; trial-limit on 19 PRs) | **6 PRs** |
| BugBot (Cursor) | `cursor[bot]` | 45 / 63 | 93 (COMMENTED) | 0 | **99** | 0 | **2 PRs** |
| Graphite | `graphite-app[bot]` | 9 / 63 | 15 (COMMENTED) | 0 | **15** | 0 | 0 |
| Greptile | `greptile-apps[bot]` | 4 / 63 | 3 (COMMENTED) | 0 | **7** | 4 | 0 |
| Vercel Agent | `vercel[bot]` | 0 / 63 | 0 | 0 | **0** | 0 | 0 |

Total inline findings in window: **347** (CR 57% / CodeAnt 37% / BugBot 29% by count — overlapping, so >100% of unique PRs).

### Overlap / redundancy

Of the 57 PRs that received any inline finding:

| Distinct tools posting inline findings on the PR | PR count |
|---|---|
| 1 tool | 16 |
| 2 tools | 22 |
| 3 tools | 10 |
| 4 tools | 8 |
| 5 tools | 1 (#393) |

**41 of 57 finding-PRs (72%) had ≥2 tools posting findings** — substantial redundancy among CR / CodeAnt / BugBot. Example: PR #441's "persist-before-post / non-idempotent state update" bug was independently flagged by **CodeAnt, BugBot, and Graphite**.

Sole-finding-provider tally (the clearest "unique value" signal): **CodeRabbit 8, CodeAnt 6, BugBot 2, Greptile 0, Graphite 0.** Greptile and Graphite were *never* the only tool to find something on a PR.

## True-positive / false-positive estimates (sampled)

| Tool | Severity composition (sampled) | Est. TP rate | FP / low-value character |
|------|-------------------------------|--------------|--------------------------|
| BugBot | 99 findings, each severity-tagged (High/Medium/Low); concrete bugs (e.g. "default loop never cancelled", "wrong digest variable persisted") | **~80%** (highest precision) | Occasional low-severity redundant-cleanup notes |
| Graphite | Precise crashes/logic bugs (ValueError tuple-unpack, idempotency, timeout mismatch) | **~75%** (small n=15) | Small sample; one config-contradiction note |
| CodeRabbit | 113 "potential issue/warning" + 31 nitpick (of 198) | **~65–70%** | ~16% nitpicks are style/low-value under the `assertive` profile |
| Greptile | 7 findings (P1/P2), all on 4 early PRs; looked reasonable | **~70%** (n too small to trust) | Sample too small for a reliable rate |
| CodeAnt | 108 severity-badged of 128 → 26 Critical, 72 Major, 18 Minor; finding bodies are substantive | **~60–65%** | **Severity inflation** (98/108 flagged Critical/Major in a config repo) + heavy status-comment noise (511 "running/finished" + 209 summary comments) |
| Vercel Agent | n/a — never ran | n/a | n/a |

Finding *bodies* across CR, CodeAnt, BugBot, and Graphite were generally high-quality and code-specific. CodeAnt's weakness is **severity calibration and conversational noise**, not finding correctness; CodeRabbit's is nitpick volume from the `assertive` profile.

## Cost vs unique value-add

| Tool | Monthly cost (current) | Findings | Sole-source PRs | Cost-vs-value verdict |
|------|------------------------|----------|-----------------|-----------------------|
| CodeRabbit | $24/dev/mo (annual Pro) | 198 | 8 | **Strong** — primary engine; clearly worth it |
| CodeAnt | Free trial **exhausted** (100 PRs); now **$10 Basic (100 reviews)** or **$24 Premium (unlimited)** | 128 + 179 approvals | 6 | **Strong but now paid** — also the approver; needs a plan decision |
| BugBot | $40/mo individual (per-seat for teams) | 99 | 2 | **Good** — highest precision; reliable second tier |
| Graphite | **$0** (Hobby) | 15 | 0 | **Free upside** — keep advisory; no cost to retain |
| Greptile | **$30/seat/mo** + $1/overage (50 incl.) | 7 | 0 | **Poor** — 0 firings in ~8 weeks, never sole; cut the seat |
| Vercel Agent | $0.30/review (usage) | 0 | 0 | **N/A** — never ran; keep off for this repo |

Pricing re-verified 2026-06-27: Greptile [pricing](https://www.greptile.com/pricing) unchanged ($30/seat, 50 reviews, $1 overage). CodeAnt [pricing](https://www.codeant.ai/pricing) now exposes a **$10/user/mo Basic tier (100 reviews/mo)** alongside Premium ($24/user/mo, unlimited); the 14-day free trial includes **100 PR reviews** — matching the "trial limit reached" warnings observed.

## Greptile keep/cut recommendation

**CUT the paid Greptile seat.** Evidence:

- Greptile fired on exactly **4 PRs (#380, #388, #391, #393), all on 2026-04-29/30** — the first two days of the window, during the period the escalation logic itself was being built. It has **not fired once in the ~8 weeks since.**
- It produced **7 inline findings**, all P1/P2, **none unique** — every Greptile finding co-occurred with CR/CodeAnt/BugBot on the same PR.
- At **$30/seat/month**, a fallback that never fires and never adds sole value is the worst cost-per-unique-finding in the chain.

**Recommended action (billing/dashboard, not a repo behavior change):** cancel the recurring Greptile seat. Two acceptable repo postures:

1. **Preferred:** keep the dormant last-resort *rule wiring* (`greptile.md`, `escalate-review.sh`). It costs $0 until triggered and only $1/review on the rare overage if it ever fires as genuine CR+BugBot-down insurance.
2. **Alternative:** fully remove Greptile from the chain (`cr-merge-gate.md` Greptile path, `greptile.md`, escalation wiring). This is more invasive and should be a separate, user-approved PR.

This audit recommends **option 1** (cancel seat, keep dormant wiring) as the lowest-risk move that eliminates the recurring cost.

## codeant.ai & Graphite — enter the formal chain?

- **CodeAnt: already on the CR path (keep), with a guard.** Since #367/#420, a CodeAnt `APPROVED` on HEAD satisfies the CR merge-gate path (`cr-merge-gate.md` Step 1). The 30-day data validates this — CodeAnt is the only tool reliably issuing `APPROVED`. **Risk to manage:** the merge gate now leans on a tool whose free trial is exhausted. If the subscription lapses, the CR path loses its approver and silently weakens. **Reconfigure:** (a) decide on the $10 Basic vs $24 Premium plan; (b) when a CodeAnt comment on HEAD contains a trial-limit/no-subscription warning, do **not** treat a CodeAnt-only approval as authoritative — require CodeRabbit completion or BugBot clean as well.
- **Graphite: keep advisory, do NOT gate.** It now posts reliably and precisely, but was **never** the sole finding-provider, so it adds confirmation rather than coverage. Keep it as a free parallel reviewer (`cr-github-review.md` supplemental). Revisit gate-eligibility only if a future window shows sole-source findings.

## Vercel Agent — remain Vercel-only?

**Yes.** Vercel Agent posted **zero** activity in the window under any login. This repo is agent configuration, not a Vercel app. Keep it disabled/Vercel-only; no change.

## Final review-chain recommendation

```
Local:   CodeRabbit CLI (coderabbit --agent) before push
GitHub:  CodeRabbit  ─┐
         CodeAnt     ─┼─ parallel primary (CodeAnt = approver on CR path)
                      │
         BugBot       ── fallback when CR/CodeAnt fail (highest precision)
                      │
         self-review  ── terminal fallback (does NOT satisfy the gate)

         Graphite     ── free parallel advisory (not gating)
         Greptile     ── DORMANT emergency-only; paid seat cancelled
         Vercel Agent ── OFF for this repo (Vercel-only)
```

Changes vs the April baseline chain (`CR → BugBot → Greptile → self-review`, CodeAnt/Graphite supplemental):

1. **CodeAnt promoted** from "advisory observer" to acknowledged **parallel-primary approver** (already encoded in `merge-gate.sh`; this audit confirms + adds the subscription guard).
2. **Greptile demoted** from active paid fallback to **dormant emergency-only**; cancel the seat.
3. **Graphite confirmed** as a working **free advisory** reviewer (was non-functional at baseline).
4. CodeRabbit, BugBot, Vercel Agent unchanged.

## Config-change decisions

| Change | Status | Reason |
|--------|--------|--------|
| Cancel recurring Greptile seat | **Recommended (user/billing action)** | 0 firings in ~8 weeks, 0 sole-source findings, $30/seat/mo — unjustifiable as routine. Keep dormant wiring at $0/$1-per-use. |
| Keep Greptile last-resort rule wiring | **Keep** | Cheap insurance ($0 until triggered); low risk vs ripping out the merge-gate fallback path. |
| Fully remove Greptile from chain/rules | **User review** | More invasive; separate user-approved PR if desired. |
| Choose CodeAnt plan ($10 Basic vs $24 Premium) | **User review (billing)** | Free trial (100 PRs) exhausted; CodeAnt is now the merge-gate approver and needs a paid plan to keep functioning. Basic's 100 reviews/mo likely suffices at current PR volume. |
| Add CodeAnt subscription-warning guard to merge gate | **Recommended (follow-up PR)** | Don't accept a CodeAnt-only approval when its HEAD comment shows a trial-limit/no-subscription warning; require CR/BugBot too. |
| Tune CodeAnt severity calibration / custom rules | **User review (dashboard)** | 98/108 findings flagged Critical/Major in a config repo — inflated; down-weight to reduce noise. |
| Add Graphite to the merge gate | **Rejected for now** | Functioning and precise, but never a sole-source provider — confirmation, not coverage. Keep advisory. |
| Broaden Vercel Agent | **Rejected** | Never ran; not a Vercel app. Keep off. |
| CodeRabbit `assertive` profile / nitpick volume | **Keep (monitor)** | ~16% nitpicks, but the substantive findings justify the profile; revisit only if noise rises. |

## Next follow-up

Suggested cadence: re-run this audit after the next ~60 PRs or if any tool's billing status changes (especially a CodeAnt plan decision or a Greptile seat cancellation). Index the next sibling as `ai-review-tool-audit-2026-08.md`.
