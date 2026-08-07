<!-- churn-hotspot: .claude/rules/issue-planning.md -->
# Hotspot Decision — issue-planning.md

Reference for Issue #1093 (`.claude/rules/issue-planning.md` churn hotspot). Not auto-loaded.

## Executive summary

### Verdict: **KEEP** (no operative change)

Keep `.claude/rules/issue-planning.md` as the single canonical rule file for the
issue-to-coding flow. The three flagged PRs fall into three distinct churn classes: one corpus
compression sweep, one cross-cutting policy propagation, and one by-design feature
construction. No structural or deduplication change is warranted.

## Trigger and measured evidence

`churn-hotspots.sh` flagged `.claude/rules/issue-planning.md` as touched by 3 distinct merged
PRs since 2026-07-28: PRs #804, #862, #878.

At diagnosis time (`main` `9df6163`), the file is 486 words and 33 lines — well below the
2,000-word per-file warning. No merge conflicts are recorded across the 3 PRs
(`conflict_rounds == 0`).

| PR | Churn class | Sections changed | What changed |
|----|-------------|-----------------|--------------|
| PR #804 | Corpus compression | Capture-only issue threads | Part of repo-wide 12,166 → 10,999 word compression sweep (Issue #790); compressed the "Capture-only" paragraph from 44 words to 19 words; same cross-file pass as `greptile.md` (Issue #1090), `skill-first.md` (Issue #1051), `bugbot.md` (Issue #1036) |
| PR #862 | Policy propagation | Always/Never header | "Cut agent chatter to heartbeat + decision points" (Issue #851); tightened the `Always:` directive — incidental filings now "recorded, not narrated" (previously: "reported in-thread only when filing is the ask… number, title, rationale, link"); removed verbose inline `/issue-maker` convention detail; same propagation that touched `cr-github-review.md` (Issue #953), `monitor-mode.md` (Issue #984), and `CLAUDE.md` (Issue #928) |
| PR #878 | Feature construction | Step 0 (new), Steps 2–6 compress, Step 8, Never header, Capture-only | Claim-at-pick feature (Issue #873): added Step 0 claim gate, added "Start a claimed issue absent an explicit chat override" to Never, compressed the fetch-concatenate-edit bash snippet out of Step 6 (relocated to `/start-issue` Step 5 to pay for corpus headroom), tightened Steps 2, 4, 8, updated Capture-only to include step 0 |

## Decision

**KEEP** `.claude/rules/issue-planning.md` as the single canonical rule file for the
issue-to-coding flow. Make no operative change.

**One corpus-compression sweep (PR #804).** This is a cross-file budget-management pass.
PR #804 was the major 12,166 → 10,999 word sweep; it compressed the "Capture-only" paragraph
incidentally as part of that pass. The same attribution applies to the sibling decisions for
`greptile.md` (Issue #1090), `bugbot.md` (Issue #1036), and `skill-first.md` (Issue #1051).
Future compression passes will continue to touch this file when the corpus approaches budget
thresholds.

**One policy propagation (PR #862).** The heartbeat + decision-points-only output discipline
(Issue #851) required updating the `Always:` directive in files that govern autonomous filing
behavior. `issue-planning.md` is the canonical rule for all issue-opening work, so this
propagation is by design — the same pattern the `cr-github-review.md` and `CLAUDE.md`
hotspot decisions confirm for canonical junction files. The change did not alter the
step-numbered checklist or the issue-body merge gate.

**One by-design feature construction (PR #878).** The claim-at-pick feature (Issue #873)
explicitly added Step 0 to `issue-planning.md` because this file governs every entry path
that starts work on an issue, including freeform "work on #N" threads that bypass
`/start-issue`. The PR description (§Rule-corpus cost) records that the bash snippet moved
from Step 6 to `/start-issue` Step 5 specifically to fund this step-0 addition within the
budget cap. This edit sequence is not avoidable churn — it is the canonical cross-reference
mechanism paying for a new gate.

**No split is warranted.** The file is 486 words — less than a quarter of the 2,000-word
per-file warning. Its two sections (`## Issue Planning Flow — Procedural Checklist` and
`## Capture-only issue threads`) are sequentially coupled: the Capture-only section explicitly
names which steps of the main checklist run at `/start-issue` time versus at
`/issue-maker` capture time. Splitting would scatter the cross-reference target of the
`issue-maker/SKILL.md` and `start-issue/SKILL.md` consumers.

**No deduplication opportunity found.** The step-numbered checklist (`steps 0 and 5–7 run
later at /start-issue time`) is already cross-referenced by the Capture-only section, not
duplicated. The inline pointer style mirrors the existing `/start-issue` Step 5 pointer in
Step 6, which PR #878 established as the canonical snippet-delegation pattern.

## Canonical ownership

| Content | Canonical owner |
|---------|-----------------|
| Always/Ask-first/Never issue-flow policy | `issue-planning.md` (sole binding authority) |
| Claim gate procedure and holder-token protocol | `issue-claim.sh`, `.claude/reference/issue-claim.md` |
| Full fetch-concatenate-edit snippet with duplicate-section strip | `/start-issue` Step 5 |
| CR-plan substantive-plan detection and polling mechanics | `cr-plan.sh` |
| Capture-only issue body shape and step numbering | `issue-planning.md` pointing to `/issue-maker` and `/start-issue` |

## Re-open trigger

Per `.claude/reference/churn-hotspots.md`, `/wrap` must re-file this hotspot only when
`conflict_rounds > 0` — i.e. when churn starts costing measurable merge-conflict rounds.
Rising PR count alone on a canonical rule file is not a re-filing trigger.

## Related

- Issue #873 / PR #878 — claim-at-pick feature; dominant churn driver (Step 0 addition)
- Issue #851 / PR #862 — heartbeat + decision-points-only output discipline; policy-propagation driver
- Issue #790 / PR #804 — repo-wide 12,166 → 10,999 word corpus compression sweep; same class as sibling decisions below
- Issue #1090 / PR #1111 — `greptile.md` rule hotspot; sibling decision (same PR #804 corpus-compression class)
- Issue #1051 / PR #1080 — `skill-first.md` rule hotspot; sibling decision (same PR #804 corpus-compression class)
- Issue #1036 / PR #1037 — `bugbot.md` rule hotspot; sibling decision (same PR #804 corpus-compression class)
- Issue #953 / PR #1055 — `cr-github-review.md` rule hotspot; sibling decision (same PR #862 policy-propagation class)
- Issue #984 / PR #1006 — `monitor-mode.md` rule hotspot; sibling decision (same PR #862 policy-propagation class)
- `.claude/reference/issue-claim.md` — full claim protocol, holder-token design, and cross-entry policy
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic
