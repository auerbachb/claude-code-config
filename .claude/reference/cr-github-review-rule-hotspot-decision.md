# cr-github-review Rule Hotspot Decision

Reference for Issue #953 (`.claude/rules/cr-github-review.md` churn hotspot). Not auto-loaded.

Companion to `cr-merge-gate-rule-hotspot-decision.md` (Issue #940, PR #1013) and
`bugbot-rule-hotspot-decision.md` (Issue #1036, PR #1041), which cover the adjacent files
in the same review-chain seam.

## Executive summary

### Verdict: **KEEP** the single rule file; **no operative change**

Keep `.claude/rules/cr-github-review.md` as the canonical owner of the CodeRabbit polling
loop, reviewer escalation gate, rate-limit policy, and the three-tier review chain. Do not
split it into topic-scoped rule files. Do not extract mechanism into new scripts.

The file is already at 927 words — far below the 2,000-word per-file lint warning — and
already defers all mechanism to scripts (`escalate-review.sh`, `poll-watermarks.sh`,
`cr-review-hourly.sh`) and six reference docs. Its churn is dominated by cross-file
corpus-compression sweeps (4 of 11 PRs) and by-design policy evolution on the review-chain
seam (3 of 11 PRs). No avoidable duplication exists that justifies synchronized edits.

One low-priority deferred candidate is recorded in §4.

## 1. Trigger and measured evidence

Issue #953 was filed after 11 merged PRs touched the rule file since 2026-07-19:
PRs #626, #650, #653, #660, #737, #742, #747, #787, #804, #862, #919.

At diagnosis time (`main` `22df5d6`), the file is 927 words and 92 lines — below both the
2,000-word per-file warning and the 12,000-word soft gate for the entire auto-loaded corpus.

The touch history falls into four groups:

| Churn class | PRs | What changed |
|-------------|-----|--------------|
| Corpus compression sweeps | #660, #742, #804, #919 | Cross-file word-budget passes; cr-github-review.md absorbed compression incidentally as one of the larger rule files |
| Review-chain policy changes | #626, #737, #862 | Escalation gate (CodeAnt satisfies CR-path); auto-merge gate addition; heartbeat + decision-points-only output discipline |
| Polling mechanism additions | #653, #747 | Polling-state-gate repo-scoping fix; poll watermark persistence via `poll-watermarks.sh` |
| Other / incidental | #650, #787 | Local-review CLI failure-mode handling; untracked-file rm safety |

## 2. Decision: keep, no operative change

**Splitting is rejected.** Named anchors in `cr-github-review.md` — §Polling, §Reviewer
escalation gate, §Three-Tier, §Processing CR Feedback — are cited verbatim by two direct
anchor callers (`bugbot.md`, `greptile.md`). Three additional files (`cr-merge-gate.md`,
`cr-local-review.md`, `subagent-orchestration.md`) reference the file or its workflow
more generally without §-prefix anchor citations. Splitting into topic-scoped files would
scatter those callers across multiple read paths without isolating genuinely independent
behavior.

**Script extraction does not apply.** The `fixpr` hotspot used extraction for repeatable
`jq` / review-state operations. Every section of `cr-github-review.md` is agent policy and
judgment — "enter the polling loop immediately after push", "batch fixes into one commit",
"reply to every thread". No deterministic command block is present whose extraction would
reduce churn. `.claude/reference/script-extraction-audit.md` is therefore out of scope.

**Churn by design (dominant driver).** Three of the eleven PRs changed actual review-chain
policy: #626 added the CodeAnt short-circuit to the escalation gate; #737 added the
auto-merge policy reference; #862 tightened output discipline. These must touch the canonical
polling-loop file by convention — the same pattern that `churn-hotspots.md` §churn-by-design
documents for canonical junction files.

**Corpus compression passes (four PRs) are cross-file** and inherently touch the largest
rule files. They are not a structural problem specific to this file.

**No avoidable synchronized-edit risk.** Unlike the BugBot §Merge Gate restatement removed
by PR #1013, or the Greptile path expansion compressed by the same PR in `cr-merge-gate.md`,
`cr-github-review.md` carries no section that restates detail already owned in full by a
reference doc. Its existing six reference pointers (to `cr-rate-limits.md`,
`cr-polling-commands.md`, `codeant-graphite-supplemental.md`, `graphql-thread-resolution.md`,
`session-state-schema.json`, and `bugbot.md` / `greptile.md` / `cr-merge-gate.md`) already
follow the pointer-not-prose pattern. No new duplication was found.

This follows the same no-operative-change precedent as:
- `bugbot-rule-hotspot-decision.md` (Issue #1036, PR #1041) — KEEP, one duplication already
  removed by sibling PR #1013, no further change warranted.
- `monitor-mode-hotspot-decision.md` (Issue #984) — KEEP, one PM recovery restatement
  deduplicated toward the canonical section.

## 3. Current scope boundaries (preserved)

The file footer already states "This file owns polling/feedback only." The ownership
boundaries in effect at decision time:

| Content | Canonical owner |
|---------|-----------------|
| Pre-merge gate policy (Steps 1–3) | `.claude/rules/cr-merge-gate.md` |
| BugBot behavior after escalation | `.claude/rules/bugbot.md` |
| Greptile behavior after escalation | `.claude/rules/greptile.md` |
| Escalation logic and verdicts | `.claude/scripts/escalate-review.sh` |
| Poll watermark persistence | `.claude/scripts/poll-watermarks.sh` |
| Rate-limit state and hourly cap | `.claude/scripts/cr-review-hourly.sh` + `cr-rate-limits.md` |
| Full CI check-run commands | `.claude/reference/cr-polling-commands.md` |
| CodeAnt + Graphite supplemental | `.claude/reference/codeant-graphite-supplemental.md` |
| GraphQL thread-resolution mutations | `.claude/reference/graphql-thread-resolution.md` |

No boundary changes are required.

## 4. Deferred candidate

The blocking-conclusion enum (`failure`, `timed_out`, `action_required`, `startup_failure`,
`stale`) appears in `cr-github-review.md` §Per-cycle check, `cr-merge-gate.md` Step 1b,
and `cr-polling-commands.md` as prose/inline usage; it is also defined independently as
a jq function in `ci-status.sh` (`is_blocking`) and `escalate-review.sh`
(`is_blocking_conclusion`). The scripts are independent definitions rather than callers of
a shared function. The prose instances in the rule files are inline reminders rather than
executable definitions. The enum is stable and a five-token constant, so a shared reference
snippet or unified script function would add cross-file edit coordination for minimal gain.
**Record as a low-priority deferred candidate; do not change now.**

## 5. Re-open trigger

Per `.claude/reference/churn-hotspots.md`, `/wrap` must re-file this hotspot only when
`conflict_rounds > 0` — i.e. when churn starts costing measurable conflict rounds. Rising
PR count alone on a canonical junction file is not a re-filing trigger; the closed decision
on record covers that case explicitly.

## 6. Related

- Issue #940 / PR #1013 — `cr-merge-gate.md` rule hotspot; closest sibling (same review
  seam); removed two downstream restatements and clarified policy-vs-runtime authority
- Issue #1036 / PR #1041 — `bugbot.md` rule hotspot; same seam; KEEP + no operative change
- Issue #788 / PR #789 — `fixpr/SKILL.md` hotspot; structural extract-not-split precedent
- `.claude/reference/subagent-orchestration-churn-audit-2026-07.md` — KEEP + dedup
  precedent for a small, heavily referenced rule file (#814)
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open
  trigger logic
