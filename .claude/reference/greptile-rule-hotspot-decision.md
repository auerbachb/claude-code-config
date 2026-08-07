<!-- churn-hotspot: .claude/rules/greptile.md -->
# Hotspot Decision — greptile.md

Reference for Issue #1090 (`.claude/rules/greptile.md` churn hotspot). Not auto-loaded.

Companion to `cr-github-review-rule-hotspot-decision.md` (Issue #953) and
`cr-merge-gate-rule-hotspot-decision.md` (Issue #940), which cover the adjacent
review-chain and merge-gate rule files.

## Executive summary

### Verdict: **KEEP** (no operative change)

Keep `.claude/rules/greptile.md` as the single canonical rule file for Greptile-specific
behavior. The three flagged PRs fall into two churn classes: two incidental corpus-compression
sweeps and one by-design Greptile policy addition. No structural or deduplication change is
warranted.

## Trigger and measured evidence

`churn-hotspots.sh` flagged `.claude/rules/greptile.md` as touched by 3 distinct merged PRs
since 2026-07-30: PRs #804, #919, #1001.

At diagnosis time, the file is 423 words, 42 lines — well below the 2,000-word per-file
warning. All six cross-references resolve on disk:
`cr-github-review.md`, `cr-merge-gate.md`, `merge-gate-reviewer-paths.md`,
`bugbot.md`, `resolve-review-threads.sh`, `greptile-budget.sh`.

| PR | Churn class | Sections changed | What changed |
|----|-------------|-----------------|--------------|
| PR #804 | Corpus compression | Greptile Basics, Daily Budget, When to Trigger | Part of repo-wide 12,166 → 10,999 word compression sweep (Issue #790); compressed verbose prose in three sections as incidental part of a cross-file pass |
| PR #919 | Corpus compression | When to Trigger, Sticky Assignment, Merge Gate | Part of 430-word budget-freeing sweep (Issue #918); removed `## When to Trigger Greptile` (restated escalation-gate pointer), removed `## Merge Gate` pure-pointer stub, promoted `### Sticky Assignment` to `## Sticky Assignment`; 414 → 377 words (−37) |
| PR #1001 | By-design policy addition | Before EVERY Re-Trigger, Sticky Assignment, Processing Greptile Findings | Added zero-P0 round reuse policy (Issue #1000): reply-with-HEAD provenance requirement, fix-only-push reuse condition, "latest round containing P0 requires a later triggered clean round" constraint |

## Decision

**KEEP** `.claude/rules/greptile.md` as the single canonical rule file for Greptile
behavior. Make no operative change.

**Two corpus-compression sweeps (PRs #804 and #919).** Both are cross-file budget-management
passes. PR #804 was the major 12,166 → 10,999 word sweep; PR #919 was the follow-on 430-word
pass. Neither reflects a structural problem specific to `greptile.md`. The same attribution
applies here as in the sibling `bugbot-rule-hotspot-decision.md` (Issue #1036, same two PRs)
and `skill-first-hotspot-decision.md` (Issue #1051, same two PRs). Future compression passes
will continue to touch this file when the corpus approaches budget thresholds.

**One by-design policy addition (PR #1001).** The zero-P0 round reuse policy is Greptile-
specific behavior. `greptile.md` is the correct canonical owner: the rule governs what the
agent does after `escalate-review.sh` returns `STATUS=trigger_greptile`. The companion
`cr-merge-gate-rule-hotspot-decision.md` §3.2 notes that PR #1001 added this policy by
design; the greptile.md touch was a necessary parallel update to the rule that governs
agent procedure (vs. `merge-gate-reviewer-paths.md`, which holds the full provenance
conditions for the gate). This class matches what `churn-hotspots.md` calls "churn by
design" for canonical junction files.

**No split is warranted.** The file has one clear responsibility: define Greptile-specific
agent behavior after `escalate-review.sh` returns `trigger_greptile`. Its six sections map
to six distinct concerns (policy header, basics, daily budget, pre-re-trigger checklist,
sticky assignment, polling, findings processing). No section has grown beyond its purpose.

**No deduplication opportunity found.** Two apparent restatements were inspected:
1. The `@greptileai` reply prohibition appears in the top `Never:` callout and in the
   `CRITICAL` inline warning inside Processing Greptile Findings. These are role-separated:
   the callout states the invariant; the inline warning reinforces it at the action point
   where an agent is composing a reply — a different reader path.
2. The P0-only re-trigger condition appears in §Before EVERY Re-Trigger step 2 and in
   §Sticky Assignment. These are role-separated: step 2 is the operational per-trigger
   checklist; §Sticky Assignment states the policy contract. Removing either would leave
   the other underpowered for its own reader context.

The restatement pattern matches the one the sibling decisions reached for `bugbot.md` and
`cr-github-review.md`: always-loaded summary context versus detailed procedural section.
No value-free duplication was found that would warrant an edit.

## Re-open trigger

Per `.claude/reference/churn-hotspots.md`, `/wrap` must re-file this hotspot only when
`conflict_rounds > 0` — i.e. when churn starts costing measurable merge-conflict rounds.
Rising PR count alone (the inherent canonical-file convention) is not a re-filing trigger;
the closed decision on record covers that case explicitly.

## Related

- Issue #1000 / PR #1001 — zero-P0 Greptile round reuse (the by-design policy driver)
- Issue #940 / PR #1015 — `cr-merge-gate.md` rule hotspot; companion decision (same PR #804/#919 cross-file sweeps; §3.2 covers PR #1001's parallel merge-gate update)
- Issue #953 / PR #1055 — `cr-github-review.md` rule hotspot; companion decision (same PR #804/#919 cross-file sweeps)
- Issue #1036 / PR #1037 — `bugbot.md` rule hotspot; sibling decision (same PR #804/#919 class attribution)
- Issue #1051 / PR #1080 — `skill-first.md` rule hotspot; sibling decision (same PR #804/#919 class attribution)
- `.claude/reference/merge-gate-reviewer-paths.md` — full Greptile merge-gate path conditions and zero-P0 round reuse provenance rules
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic
