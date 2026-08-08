<!-- churn-hotspot: .claude/scripts/tests/pmm-wake-step-4a.test.sh -->

# pmm-wake-step-4a.test.sh Hotspot Decision

Reference for Issue #1108 (`.claude/scripts/tests/pmm-wake-step-4a.test.sh` churn hotspot).
Not auto-loaded.

**Verdict:** KEEP — no split, no extraction
**Decided:** 2026-08-08
**Issue:** #1108
**Reporter:** /wrap post-merge churn report, PR #1107

## Executive summary

Keep `.claude/scripts/tests/pmm-wake-step-4a.test.sh` as the single regression suite for
`/pr-monitor-and-manage-wake` Step 4a. Do not split, extract, or modify the file.

All three PRs flagged by the detector are substantiated by the full repository history. The
verdict is KEEP: PR #921 is the sole creation event, PR #929 aligned extractor-contract test
cases to the shared `lib/skill-bash.sh` contract after a documented doc-vs-behavior gap was
found, and PR #1004 updated a header comment cross-reference. No PR edited two independent
internal concerns simultaneously after creation.

The file is 617 lines / 3,343 words, single-purpose, and directly coupled to one shared
library (`lib/skill-bash.sh`) with one consumer. There are no independent evolving seams.

## 1. Trigger and measured evidence

The hotspot detector recorded 3 merged PRs touching
`.claude/scripts/tests/pmm-wake-step-4a.test.sh` since 2026-07-24: PRs #921, #929, #1004.

At adjudication, the file is **617 lines / 3,343 words**. No conflict rounds recorded.

### Per-PR diff analysis (all three PRs verified via `git log --follow` and `git show`)

| PR | Title | Touch class | Driver |
|----|-------|-------------|--------|
| #921 | test(#888): anchored skill-bash extractor + pmm-wake Step 4a regression suite | File creation | Created the 617-line suite (Issue #888): 12 fail-closed Step 4a regression scenarios, discrimination control against pre-#887 fixture, and extractor-contract tests for `lib/skill-bash.sh` — all three concerns created together as one atomic unit |
| #929 | docs(#926): align skill-bash.sh anchoring-rule header with its actual blank-line tolerance | Extractor-contract test update | Updated adrift.md test needle from "not immediately followed" to "first non-blank line after the anchor"; added tolerant.md test case showing multi-blank-line tolerance is rc 0; **zero scenario or discrimination-control change** |
| #1004 | refactor: extract pr-state jq filters | Incidental header comment update | Updated cross-reference in file header (lines 11-13): "sed-extracts the live `classify` jq function" → "executes the canonical `lib/pr-state-classify.jq` file directly"; **zero test case changes** — update reflects the jq extraction that was the primary work of PR #1004 |

**PR #921 — creation attribution confirmed.** `git show 527c10d --stat` shows `591 lines (+)`,
`new file mode`. All three concerns exist from the creation commit.

**PR #929 — extractor-contract-only confirmed.** `git show e8da8d6 --` on this file shows
only the adrift.md needle update and the new tolerant.md test case. Scenarios 1-12
(fail-closed Step 4a) and the discrimination control are untouched.

**PR #1004 — header-comment-only confirmed.** `git show 835c60f --` on this file shows a
2-line change in the header comment cross-reference. No test cases were added, modified, or
removed.

### The three internal concerns

The test suite covers three distinct concerns, each present from creation (PR #921):

- **(a) Twelve fail-closed Step 4a scenarios** — regression coverage for the fail-closed
  scan logic that Issue #871 / PR #887 introduced; asserts that scan failures, empty output,
  and malformed snapshots keep the pause marker and re-scan rather than triggering a resume.
- **(b) Discrimination control** — frozen pre-#887 SKILL.md fixture (`.fixtures/pmm-wake-step-4a-pre887.md`) run against the same 12 scenarios; asserts at least 8/12 overall and 8/10 first-ten diverge from the current behavior, so a prose cleanup that re-opens the Issue #871 fail-open cannot pass unnoticed.
- **(c) Extractor-contract tests** — unit tests for `lib/skill-bash.sh`'s `extract_skill_bash`
  function: confirm fail-loud behavior, exit-code semantics (rc 0/3/4/5/6/7), and the
  specific diagnostic messages emitted on error.

No PR after creation edited two of these concerns simultaneously:
- PR #929 touched only concern (c) — extractor-contract.
- PR #1004 touched only the header comment prose — not a test concern at all.

## 2. Options considered

### Option 1: Keep the file; no content change (Chosen)

**Chosen.** Three PRs, one creation event, one extractor-contract follow-up (PR #929), one
incidental header update (PR #1004). The file is cohesive, the churn is coordinated
shared-contract evolution coupled to `lib/skill-bash.sh`, and there are no independent
evolving seams. A record-only adjudication closes the observational ticket.

### Option 2: Split by concern (Rejected)

**Rejected.** Precedent (`usage-limit-record-test-hotspot-decision.md`, Issue #1071) requires
proof that a single PR touches one concern without touching another and that the concerns are
truly independently evolving seams with distinct callers. The evidence does not meet this bar:

- PR #929 touched concern (c) because the extractor-contract's documented blank-line behavior
  was corrected — a coordinated library update, not independent growth.
- PR #1004 touched only prose. No PR demonstrated that concern (a) or (b) changed
  independently of concern (c) or each other.

The three concerns share the same setup infrastructure (temp HOME, stubbed `gh`, copied
`session-state.sh`). Splitting them into separate files would multiply that setup rather than
isolating independent logic.

### Option 3: Extract `lib/skill-bash.sh` tests into a companion suite (Rejected)

**Rejected.** Precedent (`polling-state-gate-test-hotspot-decision.md`, Issue #1003) extracts
shared test infrastructure only when 2 or more test suites consume it. `lib/skill-bash.sh`
currently has exactly one consumer (`pmm-wake-step-4a.test.sh`). Preemptive extraction for a
single caller creates indirection without value.

## 3. Structural protections that predict low future churn

- **Anchored live extraction:** The suite extracts the real `SKILL.md` fenced blocks at
  run time via `<!-- test-anchor: … -->` anchors. Every future behavior change in Step 4a
  is automatically reflected — no transcription drift is possible.
- **Discrimination control:** The pre-#887 fixture freezes the old behavior. A prose edit
  that silently re-opens the Issue #871 fail-open will flip ≥8 divergence cases to red,
  making silent regression structurally impossible.
- **Single library consumer:** Only this suite sources `lib/skill-bash.sh`. Extractor-contract
  changes require updating only this one file.
- **Convention-protected library:** `lib/skill-bash.sh` lacks a `.test.sh` suffix and lives
  in `tests/lib/` — the CI harness glob does not execute it as a suite.

## 4. Remediation applied

None. `.claude/scripts/tests/pmm-wake-step-4a.test.sh` is unchanged.

## 5. Preserved invariants

- The `<!-- test-anchor: pmm-wake-step-4a-scan -->` and
  `<!-- test-anchor: pmm-wake-step-4a-compare -->` anchors in `SKILL.md` must remain. The
  suite hard-fails (rc 3 from `extract_skill_bash`) if either anchor is missing.
- The pre-#887 fixture at `.fixtures/pmm-wake-step-4a-pre887.md` must remain frozen and
  unmodified — it is the reference point for the discrimination control.
- The exit-5 diagnostic text `"first non-blank line after the anchor"` pinned in the
  adrift.md assertion must stay stable across `lib/skill-bash.sh` changes (PR #929
  confirmed: the test now pins the wording, not just the exit code).
- 23 passing assertions (22 original + 1 added by PR #929). Any future PR that removes or
  rewrites an assertion should justify the count change explicitly.

## 6. Future reconsideration

Reopen this decision only if:

- A second test suite emerges that sources `lib/skill-bash.sh` — this would satisfy the
  ≥2-consumer bar for extracting a companion fixture suite, matching the precedent in
  `polling-state-gate-test-hotspot-decision.md`.
- `conflict_rounds > 0` — two contributors editing the same concern in the same window,
  causing merge conflicts (touch count alone is insufficient).
- The file grows past the 2,000-word per-file warning threshold (currently 3,343 words total
  but most of that is test scenario bash, not rule prose — this file is not rule corpus).

## 7. Related

- `.claude/reference/skill-bash-lib-hotspot-decision.md` — companion KEEP decision for
  `lib/skill-bash.sh`; the same three PRs (#921, #929, #1004) are the hotspot for that
  file; confirms the shared-contract-evolution classification from the library side
- `.claude/reference/pr-monitor-and-manage-wake-hotspot-decision.md` — companion KEEP
  decision for the `SKILL.md` file that this suite test-pins via `<!-- test-anchor -->` anchors
- `.claude/reference/usage-limit-record-test-hotspot-decision.md` — SPLIT precedent for
  comparison: requires a proven independent seam with single-PR isolated concern changes
- `.claude/reference/polling-state-gate-test-hotspot-decision.md` — KEEP + extract precedent:
  extraction justified when 2 or more suites consume the shared helper; single consumer
  does not meet this bar
- `.claude/reference/churn-hotspots.md` — hotspot reports are observational; adjudication
  decides whether a structural remedy exists
