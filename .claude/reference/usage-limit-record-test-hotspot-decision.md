# `usage-limit-record.test.sh` Hotspot Decision — Concern-Based Split

Reference for Issue #1071. Not auto-loaded.

<!-- churn-hotspot: .claude/hooks/tests/usage-limit-record.test.sh -->

**Verdict:** SPLIT
**Decided:** 2026-08-07
**Issue:** #1071
**Reporter:** `/wrap` post-merge churn report (PR #1070)

## The problem being read

`churn-hotspots.sh` flagged `.claude/hooks/tests/usage-limit-record.test.sh` as
touched by 3 distinct merged PRs since 2026-07-24: PRs #829, #910, and #1027.

## Churn classification

| PR | Merged | Driver | Sections touched |
|----|--------|--------|-----------------|
| PR #829 | 2026-07-30 | Feature introduction — initial recorder (issue #824) | Created entire file: cases 1-14 |
| PR #910 | 2026-08-01 | Feature addition — portable handoff pointer (issue #901) | Added `CLAUDE_HANDOFF_DIR` to `run_hook`; updated direct invocations in cases 12-14; added entire case 15 (15a-15k) |
| PR #1027 | 2026-08-06 | Contract update — HOOKS_MANIFEST retirement (issue #1019) | Modified case 7 only (inverted the check from presence-required to absence-required) |

**Attribution verified** by `gh pr diff` on each PR, tracing which test
sections each diff added, modified, or removed. The case structure at split
time is:

- **Cases 1-5** (core recorder behavior): executable bit, happy-path firing,
  non-rate-limit guard, malformed-input guard, field truncation. Added by PR
  #829; untouched by #910 and #1027 (except `run_hook` isolation tweak in #910).
- **Cases 6-10** (repo invariants): `global-settings.json` registration check,
  `setup-skills-worktree.sh` HOOKS_MANIFEST absence guard, static no-spend-
  estimation grep, `safety.md` quota-prohibition wording, audit-doc existence.
  Added by PR #829; case 7 alone modified by PR #1027.
- **Cases 11-14** (operational properties): file-permission enforcement,
  concurrency losslessness, non-string truncation, log rotation. Added by PR
  #829; direct invocations updated by PR #910 to pass `CLAUDE_HANDOFF_DIR`.
- **Case 15** (handoff-pointer feature, sub-cases 15a-15k): the entire portable-
  handoff-pointer feature added wholesale by PR #910 under issue #901.

## Decision: SPLIT

The file contains two independently evolving seams, each clearing the repo's
"natural split boundary with independent callers" bar.

### Seam 1 — Handoff-pointer feature (case 15 / 15a-15k)

Case 15 was added wholesale by a single PR (#910), under a separate issue
(#901), as a distinct product feature (the `/stop` portable-handoff
breadcrumb). It is independent of the core recorder behavior:

- **Own helper functions:** `stamp_ago` and `touch_ago` are defined only for
  case 15 and unused by any other case.
- **Own per-scenario fixtures:** each sub-case (15a-15k) uses its own fully
  isolated directory; no sub-case shares mutable state with the core test
  suite except `TMP_DIR` (which only provides a namespace, not shared data).
- **Orthogonal concern:** case 15 tests `CLAUDE_HANDOFF_DIR` lookup — a
  filesystem enrichment layer applied after the durable event is written. The
  core recorder tests (1-5, 11-14) do not exercise the handoff-pointer path.
- **Independent callers:** the handoff-pointer feature is driven by `/stop`;
  the recorder is driven by `StopFailure`. Neither changes force the other.

### Seam 2 — Repo invariant checks (cases 6-10)

Cases 6-10 test repo-wide contracts rather than hook runtime behavior:

- **Case 6:** `global-settings.json` registration completeness.
- **Case 7:** `setup-skills-worktree.sh` absence of the retired `HOOKS_MANIFEST`.
- **Case 8:** static grep confirming no spend/quota estimation in hook code.
- **Case 9:** `safety.md` quota-prohibition wording.
- **Case 10:** `usage-limit-signal-audit-2026-07.md` existence and verdict.

These checks pass or fail without invoking the hook at runtime (cases 6-7 call
no hook; cases 8-10 also do not invoke the hook). They evolved under the
separate HOOKS_MANIFEST retirement story (PR #1027 / issue #1019) — case 7
was the sole change target of PR #1027, confirming independent evolution.

### Concrete remedy

Three files after the split:

1. `.claude/hooks/tests/usage-limit-record.test.sh` — core recorder behavior
   (cases 1-5) and operational properties (cases 11-14, renumbered 6-9).
2. `.claude/hooks/tests/usage-limit-record-registration.test.sh` — repo
   invariant checks (cases 6-10, renumbered 1-5).
3. `.claude/hooks/tests/usage-limit-record-handoff-pointer.test.sh` — portable
   handoff pointer (case 15 / 15a-15k, sub-case labels preserved for
   searchability).

`run-hook-tests.sh` auto-discovers every `*.test.sh` in `.claude/hooks/tests/`
— no CI workflow change is needed.

## What was explicitly preserved

- All 69 assertions (as counted by `grep -c 'fail "'` on the pre-split file)
  are represented across the three post-split files. No assertion was deleted
  or rewritten.
- Sub-case labels `15a`-`15k` are preserved verbatim in the handoff-pointer
  file so that issue and review history remain searchable.
- The `run_hook` helper's `CLAUDE_HANDOFF_DIR` isolation (added by PR #910)
  is retained in the core recorder file so that cases 1-5 never read the
  developer's real `~/.claude/handoffs/`.

## Why not KEEP

A documented no-op was rejected. The two seams are truly independent: PR #1027
touched only case 7 (a repo-invariant check) without needing to touch anything
in case 15 (the handoff-pointer feature). Future changes to the handoff-pointer
logic will require only edits to `usage-limit-record-handoff-pointer.test.sh`;
future changes to hook-registration contracts will require only edits to
`usage-limit-record-registration.test.sh`. The split reduces the blast radius
of each future PR.

## Related

- `escalate-review-test-hotspot-decision.md` — SPLIT precedent for a
  single-file test suite with independent concern blocks.
- `merge-gate-review-substance-test-hotspot-decision.md` — KEEP precedent for
  comparison: no independent seam, purposeful accumulation.
- `global-settings-hotspot-decision.md` — the issue that drove PR #1027's
  case 7 modification (HOOKS_MANIFEST retirement).
- `churn-hotspots.md` — observational detector semantics and threshold
  rationale.
