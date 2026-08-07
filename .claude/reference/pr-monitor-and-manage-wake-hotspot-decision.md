<!-- churn-hotspot: .claude/skills/pr-monitor-and-manage-wake/SKILL.md -->

# PR Monitor and Manage Wake Hotspot Decision

Reference for Issue #1056 (`.claude/skills/pr-monitor-and-manage-wake/SKILL.md` churn hotspot).
Not auto-loaded.

## Executive summary

### Verdict: **KEEP** the single self-contained wake skill; make **no operative change**

Keep `.claude/skills/pr-monitor-and-manage-wake/SKILL.md` as the sole runtime definition for the
pause-to-active state machine. Do not split, extract, or deduplicate any section in this
remediation.

The four reported touches are required propagation of scheduling-substrate correctness fixes — not
independent growth or avoidable duplication unique to this file. The unique Step 4a/4b logic is
self-contained and test-pinned by `.claude/scripts/tests/pmm-wake-step-4a.test.sh` through
`<!-- test-anchor: … -->` anchors; any extraction risks re-opening the Issue #871 fail-open bug.
The only confirmed duplication (`resolve_script()` and the atomic teardown idiom) is a repo-wide
copy-paste pattern shared across 7+ skills — out of scope for a single-file hotspot ticket.

This decision is intentionally reference-only. `.claude/skills/pr-monitor-and-manage-wake/SKILL.md`
and every file it depends on remain byte-for-byte unchanged.

## 1. Trigger and measured evidence

The hotspot detector recorded 4 merged PRs touching
`.claude/skills/pr-monitor-and-manage-wake/SKILL.md` since 2026-08-01: PRs #867, #887, #921, #982.
At diagnosis time the file is 272 lines / 1,980 words, just below the 2,000-word per-file warning.

### Per-PR diff analysis (all four PRs verified via `gh pr diff --name-only` and `gh pr view`)

| PR | Title | Touch class | Driver |
|----|-------|-------------|--------|
| #867 | feat(#827): replace CronCreate "durability" with session-start reconciliation | Hub/policy propagation | Persistent-Monitor migration across 20+ files: retired CronCreate/loop-based auto-wake scheduling; updated Steps 1–4b to reflect Monitor-task identity management and exact `TaskStop` teardown |
| #887 | fix(skills): make pmm-wake resume fail-closed and reset table digests | Core business-logic fix | Introduced fail-closed Step 4a fleet-scan guards (Issue #871) and atomic Step 4b digest reset (Issue #872); the primary content author of both steps |
| #921 | test(#888): anchored skill-bash extractor + pmm-wake Step 4a regression suite | Test infrastructure | Added `<!-- test-anchor: pmm-wake-step-4a-scan -->` and `<!-- test-anchor: pmm-wake-step-4a-compare -->` comments plus one blockquote editor note; **zero behavior change** — verified from PR #921 body: "the diff is two comment lines and one blockquote" |
| #982 | fix(#924): move recurring polls to Monitor | Hub/policy propagation | Persistent-Monitor migration cleanup across 20+ files: dynamic `/loop` / recurring `ScheduleWakeup` confirmed negative; updated auto-wake re-scan arm/teardown and `polling_jobs[]` clearing |

**PR #921 attribution note:** The CR implementation plan flagged #921 as unverified. Direct inspection of
the PR #921 body and `gh pr diff 921 --name-only` confirms the following files were touched: the
SKILL.md, `CONTRIBUTING.md`, and three test files. The SKILL.md change is documented in the PR
body as "two comment lines and one blockquote — zero behavior change." This is consistent with the
current SKILL.md's Step 4a content, which carries both anchors and the editor note introduced by
#921.

### Scheduling-substrate context

PRs #867 and #982 are part of a repo-wide corrective sweep documented in:
- `.claude/reference/scheduling-failure-modes.md` — incident Patterns #5 (CronCreate durability),
  #7 (dynamic `/loop` silent drop, including operational evidence from PRs #937 and #944)
- `.claude/reference/cross-session-durability.md` — rationale for declining the durable
  `mcp__scheduled-tasks__*` scheduler (merge-authority escalation, on-disk state is more reliable)
- `.claude/reference/scheduling-reliability.md` — canonical "use `Monitor`" rule, updated by #982

PR #887's fix closed the Issue #871 fail-open with a discrimination control documented in
`.claude/scripts/tests/pmm-wake-step-4a.test.sh`: 8/10 first-ten scenarios diverge between the
pre-fix and post-fix fenced blocks. The test is self-validating — it fails if fewer than 8 diverge.

## 2. Options considered

### Option 1: Split Step 4a and Step 4b into separate reference files (Rejected)

**Rejected.** The two steps are sequential halves of one fail-closed scan-then-compare loop. Step
4a guards then compares; Step 4b cancels the re-scan and re-arms only when Step 4a's guards all
pass. Separating them would require a new intra-phase handoff while adding no isolation of
independently changing concerns. More concretely: the `<!-- test-anchor: … -->` comments in Step
4a are anchors that `pmm-wake-step-4a.test.sh` uses to extract and run the *live* fenced blocks at
test time. Moving those blocks to a reference file would require the test to reach across file
boundaries — and the PR #887 discrimination control exists precisely to catch the scenario where
a "cleanup" silently re-opens the fail-open by changing or removing the guards.

### Option 2: Extract `resolve_script()` and the atomic teardown idiom (Deferred — repo-wide)

**Deferred.** The `resolve_script()` block in the `## Resolve the state helper` section appears
byte-identical in at least 7 skills (including `babysit-pr-stop`, `pr-monitor-and-manage`,
`pr-monitor-and-manage-stop`, and `pr-monitor-and-manage-wake`). The atomic teardown `--set`
batch in Step 4b is also shared across the PMM family. However:

1. Deduplication would require coordinated edits across all sibling skills, which is a repo-wide
   refactor, not a single-file hotspot remediation.
2. These patterns have not shown repeated independent drift in this file — both blocks were
   introduced once (by #867 and #887 respectively) and have not changed since.

Recorded as a deferred, cross-skill observation. The appropriate vehicle is a dedicated
repo-wide ticket once the full set of callers and any test implications are assessed.

### Option 3: Keep the runtime definition and record the ownership decision (Chosen)

**Chosen.** Closes the observational hotspot ticket with an explicit boundary while avoiding a
refactor whose principal effect would be moving test-pinned fenced blocks away from the anchors
that target them, or expanding a single-file ticket into a multi-skill coordination task.

## 3. Canonical ownership boundaries

| Content | Operative owner | Shared/detailed owner |
|---------|-----------------|----------------------|
| Mode parsing (`--auto-check`, `--monitor-generation`) and generation gate | `SKILL.md` Step 1 | `scheduling-reliability.md` owns the persistent-Monitor policy |
| Pause-marker and stop-pending reads, routing by mode | `SKILL.md` Step 2 | `pr-monitor-and-manage/references/pmm-lifecycle.md` documents the full state machine |
| Exact `TaskStop` teardown of auto-wake and main task IDs | `SKILL.md` Step 3 | `pmm-lifecycle.md` owns the teardown semantics and fail-abort contract |
| Fail-closed fleet-scan guards and comparison (Step 4a) | `SKILL.md` Step 4a, anchored and test-extracted | `pmm-wake-step-4a.test.sh` owns regression coverage; `scheduling-failure-modes.md` records Issue #871 context |
| Monitor re-arm, digest nulling, atomic marker clear (Step 4b) | `SKILL.md` Step 4b | `pmm-lifecycle.md` and `session-state-schema.json` own the state fields |
| `resolve_script()` scaffolding | `SKILL.md` `## Resolve the state helper` | No canonical owner yet — repo-wide copy-paste pattern (see deferred note above) |
| Safety invariants (non-modification guard, scan-not-change rule, digest atomicity) | `SKILL.md` `## Safety` | Derived from `scheduling-reliability.md` obligations and Issue #871/#872 post-mortems |

## 4. Preserved invariants

- Step 4a `<!-- test-anchor: pmm-wake-step-4a-scan -->` and
  `<!-- test-anchor: pmm-wake-step-4a-compare -->` anchors remain in place immediately above their
  respective `bash` fences. Removing or moving them makes `pmm-wake-step-4a.test.sh` hard-fail
  with a non-zero anchor-not-found exit.
- Step 4a fail-closed contract: a scan that cannot *prove* the fleet changed keeps the pause. The
  `scan_failed()` function, the `SCAN_RC` capture, and both JSON-array guards must remain before
  any comparison.
- Step 4b digest atomicity: `.pmm_digest` and `.pmm_row_digest` must be nulled in the same
  `session-state.sh` call that clears `.pmm.paused_at`, so the main skill's Step 4 prints the
  full table on the first post-resume tick. `.pmm_digest_streak` is deliberately preserved,
  mirroring Step 0a.
- `resolve_script()` naming and three-candidate lookup path remain stable — `pmm-wake-step-4a.test.sh`
  uses a matching lookup to find `session-state.sh` for its stub.
- All auto-loaded rule corpus files, `.claude/agents/`, `.claude/scripts/`, CI enforcement, and
  the `.budget-soft-cap` remain byte-for-byte unchanged.

## 5. Remediation and verification

The remediation adds only this decision record and its reference-catalog entry. Verification:

- `git diff origin/main...HEAD --stat` shows only the decision record and README entry — no diff
  in `SKILL.md` or any other runtime file.
- `bash .github/scripts/reference-catalog-lint.sh` exits 0 with exactly one new catalog entry and
  no phantom entries.
- `bash .github/scripts/rule-lint.sh` and `bash .github/scripts/verbatim-block-lint.sh` pass.

## 6. Future edits and reconsideration

When the scheduling substrate changes again, updates to this skill are expected — they will be
hub/policy propagation, not evidence of a structural problem. Record each update in the next
churn-hotspot adjudication rather than pre-emptively splitting the file.

Reconsider the KEEP verdict and open a dedicated repo-wide ticket if:

- The file crosses the 2,000-word per-file warning threshold (currently at 1,980 words, just below it).
- Conflict-round evidence appears — two independent contributors editing the same section in the
  same window, causing merge conflicts (touch count alone is insufficient).
- An independent caller of the Step 4a or Step 4b logic emerges that is not the existing
  `--auto-check` path.
- The repo-wide `resolve_script()` deduplication is undertaken, at which point this file should
  participate in that coordinated sweep.

## Related precedent

- `.claude/reference/pmm-lifecycle-hotspot-decision.md` — sibling PMM state-machine file; KEEP +
  dedup verdict for the same class of scheduling-substrate churn; confirms hub edits are the
  expected driver for files in the PMM pause/resume/stop cluster.
- `.claude/reference/harness-audit-skill-hotspot-decision.md` — KEEP for a 4-PR hotspot where all
  PRs are foundational creation, chip-contract propagation, or scheduler-redesign propagation;
  close precedent for a small-PR-count observational ticket.
- `.claude/reference/babysit-pr-hotspot-decision.md` — KEEP for a skill with CI constraints
  (`require_text` guards) that pin invariants directly in `SKILL.md`; analogous to the test-anchor
  constraint in this file.
- `.claude/reference/phase-b-reviewer-hotspot-decision.md` — KEEP/no-runtime-change when churn
  reflects required propagation into a self-contained operative definition.
- `.claude/reference/churn-hotspots.md` — hotspot reports are observational and require an
  evidence-based structural verdict.
