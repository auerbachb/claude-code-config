# Cross-Session Durability Hotspot Decision

Reference for Issue #1085 (`.claude/reference/cross-session-durability.md` churn hotspot). Not auto-loaded.

<!-- churn-hotspot: .claude/reference/cross-session-durability.md -->

## Executive summary

### Verdict: **KEEP** the file unchanged

Keep `.claude/reference/cross-session-durability.md` as the single reference document
explaining why the harness declines `mcp__scheduled-tasks__*` (the genuinely durable scheduler)
and why `CronCreate durable: true` is a no-op. The 3 churn PRs are all from the same
scheduling-substrate evolution cohort (Issues #827 → #914 → #924). Each touch was non-colliding:
initial file creation, a new subsection added by a review finding, and two line-level terminology
updates after the primitive migration. No section duplicates content owned elsewhere, the file is
well within size limits, and no structural intervention is warranted.

No edits to `.claude/reference/cross-session-durability.md` are made by this PR.

## 1. Trigger and current evidence

Issue #1085 was filed by `/wrap` churn detection after PR #1084 merged. The detector recorded
3 distinct merged PRs touching `cross-session-durability.md` since 2026-07-24: #867, #922, #982.

At diagnosis time the file is 175 lines, organized into:
- The two-primitive comparison table
- "Why all three features declined it" (3 numbered objections)
- "What replaced them" (the session-start reconciliation mechanism)
- Freshness window (canonical definition)
- Early-warning window (distinct from the reap window)
- "When to revisit"

## 2. Per-section churn attribution

Diff evidence from `gh pr diff 867 / 922 / 982`.

### PR #867 — File creation (Issue #827)

**Section(s):** All — this PR created the file from scratch.

**Driver:** Scheduling-substrate redesign (Issue #827). Three features had been built on the
false assumption that `CronCreate durable: true` survives session exit. PR #867 replaced all
three with on-disk state reconciled at session start and created this reference doc to explain
(a) that `mcp__scheduled-tasks__*` genuinely persists, (b) why all three features declined it
despite persistence, and (c) what replaced them.

This is foundational authoring, not incremental churn. The file was needed because the decision
had architectural implications (merge authority scoped to live sessions, not standing jobs) and
required a place to record the "When to revisit" bar so future sessions do not re-propose the
durable scheduler without first reading the load-bearing objection.

**Classification:** scheduling-substrate founding touch.

### PR #922 — Early-warning window subsection (Issue #914 + CodeAnt review)

**Section(s):** "Early-warning window (distinct from the reap window)" — new subsection added
between the existing Freshness window definition and the per-feature summary.

**Driver:** Two-part. First, Issue #914 (babysit-tick-watchdog.sh addition) established a new
"early-warning" window (`2 × cadence`) distinct from the existing "reap" window
(`max(3 × cadence, TTL)`). This created a documentation gap: the file defined the reap window
canonically but had no parallel definition for the new warning window. Second, a CodeAnt review
finding on PR #922 required that the warning advisory name the two-step recovery explicitly
(`/babysit-pr-stop` before `/babysit-pr`) — because between WARN_MIN and the reap window the
watcher is warned-about but not yet reclaimable, so a bare "re-arm it" instruction silently
fails. The subsection documents both the window design and the pinned test (test 12 in
`babysit-tick-watchdog.test.sh`) that enforces the recovery sequence order.

**Classification:** scheduling-substrate append — new subsection, non-colliding with prior content.

### PR #982 — Terminology migration (Issue #924)

**Section(s):** Two inline references only.

1. Code block in the Early-warning window subsection: `/babysit-pr <PR>` comment changed from
   `# re-arms (dynamic /loop, no leading interval)` → `# re-arms a persistent Monitor task`.
2. Per-feature summary line: `--auto-wake was **reframed** to a `/loop` re-scan` →
   `--auto-wake was **reframed** to a persistent Monitor re-scan`.

**Driver:** Issue #924 confirmed that dynamic `/loop` (ScheduleWakeup-backed) is also an
unreliable recurring primitive. The harness migrated to persistent `Monitor` tasks as the
standard. PR #982 updated the two places in this file that described the replacement mechanism
using the now-deprecated `/loop` language, keeping the description accurate after the migration.

**Classification:** scheduling-substrate terminology update — two line-level changes, no content
added or removed.

## 3. Churn class summary

| Churn class | PRs | Section |
|---|---|---|
| File creation (scheduling-substrate founding) | #867 | All |
| New subsection — scheduling substrate evolution | #922 | Early-warning window |
| Terminology update — primitive migration | #982 | 2 inline references |

All three PRs are from the same scheduling-substrate cohort that drove churn in
`scheduling-reliability.md` (Issue #959, `scheduling-reliability-hotspot-decision.md`) and
`pmm-lifecycle.md` (Issue #1017, `pmm-lifecycle-hotspot-decision.md`). The consistent attribution
across those sibling records is: changes were coordinated and sequential, tracking the
evolution from CronCreate → /loop → persistent Monitor as the harness learned which primitives
actually fire out of turn.

## 4. CronCreate claims and PR #1102 (Experiment 2)

The issue prompt asks whether PR #1102 (Issue #983, merged 2026-08-07) — which ran the deferred
Experiment 2 control (CronCreate without a concurrent Monitor, human-observed) and found 15/15
ticks fired — affects any claims in this file.

**It does not.** The claims in `cross-session-durability.md` about CronCreate are:

1. "`durable: true` is a documented no-op" — still true; Experiment 2 tested in-session firing,
   not session-boundary survival.
2. "CronCreate jobs are in-memory and die with the session that armed them" — still true;
   unaffected by any in-session liveness result.
3. `scheduling-reliability.md` is referenced as "the authoritative CronCreate contract" — that
   rule file was updated by PR #1102 to note the Experiment 2 result (plausible Monitor-
   suppression hypothesis, operational guidance unchanged: "Use Monitor"). The pointer in this
   file remains correct.

The file's final line — "do not reintroduce the claim that CronCreate is durable. It is not, in
any configuration." — refers to cross-session durability (surviving session exit), not in-session
reliability. Experiment 2 found CronCreate fires in-session when no Monitor is concurrently
armed; it found nothing about what happens at session exit. That sentence stands.

No correction to `cross-session-durability.md` is needed or applied.

## 5. Options considered

### Option 1: SPLIT — separate "what exists" from "why we declined it"

Move the comparison table and "When to revisit" into a standalone reference; keep the
"declined" reasoning as its own doc.

**Rejected.** The two halves are a single argument: the comparison table establishes that the
durable primitive genuinely exists, which is the premise required for the "why declined" section
to make sense. A reader who does not first understand that `mcp__scheduled-tasks__*` actually
persists cannot evaluate whether the objections are about the scheduler's capability or about
authorization scope. Splitting would force readers to hold both files in parallel for a
175-line document with a single audience question.

### Option 2: KEEP + dedup toward scheduling-reliability.md

Move the CronCreate no-op claim out of this file and into `scheduling-reliability.md`.

**Rejected.** The claim in this file serves a different purpose than the rule-file contract: it
explains *why* the scheduling decision was made (cross-session durability is available but
deliberately declined), while `scheduling-reliability.md` governs *which primitive to use*.
Moving it would break the file's argument by removing its necessary premise.

No confirmed downstream restatements of this file's content were found.

### Option 3: KEEP (no runtime change)

**Chosen.** Three scheduling-substrate touches on a purpose-built 175-line reference doc is
consistent with the cohort's pattern across sibling files. The churn has a single identifiable
driver (the scheduling primitive evolution from CronCreate → /loop → Monitor), the file has one
coherent scope, and no structural intervention is warranted.

## 6. Preserved invariants

- For this PR: `.claude/reference/cross-session-durability.md` stays byte-for-byte unchanged.
- The file's "When to revisit" criteria are the correct bar for future proposals to adopt
  `mcp__scheduled-tasks__*`; do not lower that bar without addressing the load-bearing objection
  (what the fresh session would be *permitted* to do, not just *intended* to do).
- The Freshness window definition in this file must remain identical to `/babysit-pr`'s A2
  check and `session-scheduling-reconcile.sh` — those two implement the reap window; this file
  defines it canonically.
- The Early-warning window's two-step recovery sequence (stop before re-arm) is pinned by test
  12 in `babysit-tick-watchdog.test.sh`; any future retuning of WARN_MIN must re-verify that
  test's premise is still reachable at the new numbers.

## 7. Related precedent

- `scheduling-failure-modes-hotspot-decision.md` — KEEP, no runtime change; same scheduling
  cohort; the Experiment 2 result (PR #1102) landed in Pattern 7 of that file, consistent with
  the KEEP verdict for both files in this cohort.
- `scheduling-reliability-hotspot-decision.md` — KEEP + dedup on the coupled rule file; 12
  PRs in the same cohort; confirms the scheduling-substrate evolution driver.
- `pmm-lifecycle-hotspot-decision.md` — KEEP + dedup; same scheduling-substrate cohort; 6 PRs
  driven by the same CronCreate → Monitor migration.
- `churn-hotspots.md` — hotspot mechanism, calibration, and re-open trigger logic.
