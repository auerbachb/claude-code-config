# Scheduling Failure Modes Hotspot Decision

Reference for Issue #1007 (`.claude/reference/scheduling-failure-modes.md` churn hotspot). Not auto-loaded.

<!-- churn-hotspot: .claude/reference/scheduling-failure-modes.md -->

## Executive summary

### Verdict: **KEEP** the single incident-evidence file; **dedup already applied**

Keep `.claude/reference/scheduling-failure-modes.md` as the single append-only catalogue of
observed scheduling failure patterns. Do not extract Pattern 7 into its own file, do not split
by failure category, and do not dedup anything further — the one confirmed downstream
restatement (Pattern 5 backoff thresholds) was already removed by PR #987 and replaced with a
pointer to `.claude/rules/scheduling-reliability.md` `## Stable-State Backoff`.

The 6 flagged PRs plus a 7th touch since the issue was filed (PR #1009) all fall into three
causal classes: new incident patterns appended as evidence, scheduled correctness updates to
existing patterns, and targeted dedup. Growth is non-colliding append-and-refine — consistent
with a log whose scope is "record every new scheduling failure signature so future sessions
recognize it without re-diagnosing it." This matches the verdict and rationale of
`local-review-cli-failure-modes-hotspot-decision.md`, whose subject file has the identical
append-only-evidence-log shape.

The two CI-pinned Pattern 7 evidence-table rows are present and verbatim-preserved in the
current file; no assertion in `scheduling-primitive-alignment.test.sh` is at risk.

## 1. Trigger and current evidence

Issue #1007 was filed by `/wrap` churn detection after PR #1006 merged. The issue body records
6 distinct merged PRs since 2026-07-30: PRs #807, #820, #825, #922, #982, #987. A 7th touch,
PR #1009 (merged 2026-08-05), updated Pattern 6 with the gap-2 watchdog closure; it was
already in main at diagnosis time.

At diagnosis time the file is 209 lines, organized into 7 named Patterns, a Detection
Heuristics section, and a Canonical Incident appendix. The touches map to three causal classes:

| Churn class | PRs | What changed |
|---|---|---|
| New incident pattern appended | PRs #807, #922, #982, #1009 | Pattern 6 (background-work ceiling), Pattern 7 (armed zero-tick cron), Experiment 1 (dynamic `/loop` liveness), Pattern 6 belt-and-braces update |
| Scheduling-contract correctness | PRs #820, #825 | Backoff reconciliation and CronCreate durability corrections to existing patterns |
| Targeted dedup | PR #987 | Pattern 5 copied backoff thresholds replaced with pointer to `scheduling-reliability.md` |

**Pattern 5 dedup status.** The current file reads:
> Apply `.claude/rules/scheduling-reliability.md` `## Stable-State Backoff`, the canonical
> source for digest inputs, cadence widening, stop/resume thresholds, and user-input handling.

The dedup called out in `scheduling-reliability-hotspot-decision.md` §4 is fully applied. No
threshold or formula is copied from the rule file into this reference file.

**CI-pinned Pattern 7 rows.** `scheduling-primitive-alignment.test.sh` asserts two verbatim
rows from the Pattern 7 evidence table. Both are present in the current file unchanged:
- `| persistent \`Monitor\` | The silence ceiling fired out of turn during the #914 controlled probe | **positive** |`
- `| dynamic \`/loop\` / recurring \`ScheduleWakeup\` | PR #937 and PR #944 stopped until a manual turn | **negative** |`

## 2. Options considered

### Option 1: EXTRACT Pattern 7

Move Pattern 7 (roughly half the file, including the controlled probe, two experiments, and
evidence table) into its own reference file, leaving a stub pointer in Pattern 7's position.

**Rejected.** Pattern 7 accumulates evidence for a single contract — the unreliability of
`CronCreate` and both `/loop` modes as recurring poll primitives. Its sections (initial
incident, controlled reproduction, Experiment 1, Experiment 2, evidence table) are tightly
coupled: each experiment answers a question raised by the one before it. Extracting them
relocates the churn without isolating an independently-iterating concern. The extraction
precedent (`fixpr-hotspot-decision.md`) applies only when the extracted content is
deterministic/mechanical command forms with no shared-mechanism dependency — Pattern 7 is
agent-judgment incident prose, not reusable command forms.

### Option 2: SPLIT by failure category

Break the pattern catalogue into per-category files (e.g., one-shot drops vs. armed-but-silent
vs. unscheduled-background-work).

**Rejected.** The patterns share a common diagnostic frame ("the common thread: between-turn
scheduling has no in-turn observer") and cross-reference each other to distinguish symptoms.
Pattern 7's shape-difference paragraph explicitly names Patterns 1, 3, and 6 as the contrast
cases — a split would force readers to hold multiple files in parallel to apply the
disambiguation. The SPLIT precedent (`escalate-review-test-hotspot-decision.md`) applies where
sections had independent authors and no shared-mechanism dependency. These patterns were
authored sequentially as each new failure class was discovered, not by independent concurrent
authors.

### Option 3: KEEP + dedup

Identify remaining downstream restatements and collapse to pointers.

**Already done (no further action).** Pattern 5's dedup was applied in PR #987. No other
section was found to restate operative values owned by `scheduling-reliability.md`. Detection
Heuristics and the Canonical Incident appendix are evidence prose, not copied policy.

### Option 4: KEEP (no runtime change)

Record a by-design KEEP decision and leave the file unchanged.

**Chosen.** The file's scope is append-only incident collection. Each new section records a
scheduling failure class that was not previously recognized, so agents can match symptoms
without re-diagnosing. Growth is expected and non-colliding; a structural intervention would
not prevent the next incident pattern from being appended. The one confirmed dedup is already
applied; no further restatements exist.

## 3. Canonical ownership boundaries

| Concern | Owner | Non-owner action |
|---|---|---|
| Enforced directive: recurring polls use Monitor | `.claude/rules/scheduling-reliability.md` `## Tool Selection Decision Tree` | Point here; do not recreate the selection table |
| Recurring scheduler failure and session-only limitations | `.claude/rules/scheduling-reliability.md` `### Recurring scheduler contract (authoritative)` | Reference doc retains evidence and rationale; canonical policy stays in the rule |
| Stable-state backoff formula and thresholds | `.claude/rules/scheduling-reliability.md` `## Stable-State Backoff` | Pattern 5 already points here; do not copy values |
| Observed failure patterns, incident evidence, and symptom-matching prose | `.claude/reference/scheduling-failure-modes.md` | Append new patterns; leave policy to the rule file |
| Background-work ceiling mechanism and rationale | `.claude/reference/bgwork-ceiling.md` | Pattern 6 references this file; do not absorb its content |

## 4. Preserved invariants

- For this PR: `.claude/reference/scheduling-failure-modes.md` stays byte-for-byte unchanged.
- The two Pattern 7 evidence-table rows pinned by `scheduling-primitive-alignment.test.sh`
  must remain verbatim in any future edit that touches Pattern 7. If Pattern 7 wording changes,
  the test assertions must be updated in the same commit.
- Pattern 5 must not re-copy backoff thresholds or formulas. The pointer to
  `scheduling-reliability.md` `## Stable-State Backoff` is the correct form.
- The `## Failure Recovery` section of `.claude/rules/scheduling-reliability.md` declares this
  file as the target for recording new failures; new scheduling incidents should append a new
  pattern section here, not to the rule file.

## 5. Remediation and verification

The only changes in this PR are:
1. This decision record (`.claude/reference/scheduling-failure-modes-hotspot-decision.md`).
2. One catalog bullet in `.claude/reference/README.md`.

No rule, script, reference doc, or agent file is modified. `reference-catalog-lint.sh` must
pass with exactly one registered bullet for the new decision doc and no phantom entries.

## 6. Future edits and reconsideration

A future PR that discovers a new scheduling failure mode should append a new Pattern section to
`scheduling-failure-modes.md` — that is expected and is not a reason to reopen this decision.

Reconsider if:
- A future PR re-edits an *existing* pattern section to add independently-iterating content
  (not refinement of prior evidence), indicating colliding ownership rather than coordinated growth.
- Pattern 7 acquires a third experiment whose premise contradicts Experiment 2's deferred
  control, at which point the evidence should still land in Pattern 7, not in a new file.
- A downstream file begins restating section content rather than pointing to it, creating a
  confirmed synchronization burden.

## 7. Related precedent

- `.claude/reference/local-review-cli-failure-modes-hotspot-decision.md` — KEEP, no runtime
  change; identical "append-only incident evidence log" shape; the two files are named as
  explicit analogues in that decision.
- `.claude/reference/scheduling-reliability-hotspot-decision.md` — KEEP + dedup on the coupled
  rule file; §4 specifies the Pattern 5 dedup that this file already carries.
- `.claude/reference/monitor-mode-hotspot-decision.md` — KEEP + dedup precedent; contrasting
  case where a confirmed downstream restatement existed to remove.
- `.claude/reference/fixpr-hotspot-decision.md` — KEEP + extract precedent; contrasting case
  where deterministic command forms (not incident prose) justified extraction.
- `.claude/reference/escalate-review-test-hotspot-decision.md` — SPLIT verdict; contrasting
  case where sections had independent authors and no shared-mechanism dependency.
- `.claude/reference/churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger
  logic.
