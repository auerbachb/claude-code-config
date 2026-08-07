<!-- churn-hotspot: .claude/hooks/tests/polling-backoff-warn.test.sh -->
# Hotspot Decision — polling-backoff-warn.test.sh

**Verdict:** KEEP (no structural change)
**Decided:** 2026-08-07
**Issue:** #1069
**Reporter:** `/wrap` post-merge churn report (PR #1068)

## Churn summary

`churn-hotspots.sh` flagged `.claude/hooks/tests/polling-backoff-warn.test.sh` as
touched by 3 distinct merged PRs since 2026-07-30:

| PR | What changed |
|----|-------------|
| PR #820 | Created the file (150 lines, 14 cases); initial backoff-ladder coverage using CronDelete terminology for the streak>=9 stop branch |
| PR #867 | Updated CronDelete → "stop the poll" in header comment; added cases 10b (/loop path no-cron-record STOP) and 10c (widen-vs-stop semantic distinction); updated cases 11 and 12 assertions to check for "Stop the poll" instead of "CronDelete" |
| PR #982 | Renamed case 10b comment from "/loop path" to "Monitor path"; added assertions for TaskStop, monitor_task_id, monitor_generation, and "atomically clear" in case 10b; added four new assertions in case 10c (TaskStop, "replacement at 15m", "fresh monitor_generation", "atomically persist"); updated case 11 to check TaskStop instead of CronDelete |

## Diagnosis

This is **external-contract-driven churn**, not instability or internal duplication.
Each edit tracks a change in the scheduling substrate used by `polling-backoff-warn.sh`:

- **PR #820** introduced the file as the initial regression suite for the backoff
  ladder rule (issue #794). Terminology matched the then-current `CronDelete`
  scheduling primitive.
- **PR #867** (issue #827) replaced `CronCreate` durability with session-start
  reconciliation and moved from `CronDelete` to explicit poll-stop language. The
  test file updated its assertions to match the new hook output phrasing.
- **PR #982** (issue #924) moved recurring polls from dynamic `/loop` to persistent
  `Monitor` with `TaskStop`/`monitor_generation` teardown. The test file updated its
  assertions to pin the Monitor-specific teardown contract now emitted by the hook.

Every change traces to a deliberate substrate migration, not to scatter in the test
file's own structure.

Two structural observations confirm the KEEP verdict:

**1. No extractable duplication within or across files.**
A companion file `babysit-tick-watchdog.test.sh` exists in `.claude/hooks/tests/`
and carries a `context_of` one-liner with an identical body, plus `write_state`
and `run_hook` functions. However, the multi-line implementations are diverged:
the companion's `write_state` omits local variable declarations and uses inline
`--argjson` passing; its `run_hook` takes no PR argument and emits a different
JSON schema (`session_id`/`tool_name` vs `tool_input.command`). No `lib/`
subdirectory exists. The only identical function is the trivial `context_of`
one-liner; sharing it would add a sourced-lib dependency in exchange for saving
one line.

**2. The 16 labeled sections are homogeneous boundary coverage of one algorithm.**
The hook (`polling-backoff-warn.sh`) is a single linear decision procedure with two
branches: WIDEN (streak 3–8) and STOP (streak>=9 or `blocker_kind==user_input`).
Every test case exercises a distinct boundary or guard of this two-branch ladder:
below-threshold (case 1), WIDE_MIN floor and 3×base variants (cases 2–4), mid-tier
no-op (case 5), absent-base default (case 6), already-applied guards (cases 7–10),
Monitor teardown semantics (cases 10b–10c), stop-branch cases (cases 11–13), and
non-polling command passthrough (case 14). The set is internally cohesive — splitting
it would produce fragments, not independent concerns.

### Comparison with the polling-state-gate precedent (Issue #1003)

The Issue #1003 adjudication extracted shared helpers from two companion files
(`polling-state-gate.test.sh` + `polling-state-gate-multirepo.test.sh`) that each
carried their own copy of `mk_repo`, `write_handoff`, and `write_polling_gh_stub`
with diverged implementations. This file has no companion. There is no cross-file
duplication to extract and no coverage gap to close.

The `merge-gate-review-substance-test-hotspot-decision.md` (Issue #1014) precedent
is the closer analogue: a single self-contained suite tracking external contract
evolution, with no companion file and no internal duplication — KEEP verdict.

## Decision

**KEEP** the file in its current location with no structural change.

Future substrate changes to `polling-backoff-warn.sh` (e.g., further Monitor
lifecycle field additions) will continue to require assertion updates in this file.
That is correct behavior: the test suite exists to pin the exact teardown contract
the hook emits, and that contract evolves with the scheduling substrate.

## Why not split / Why not extract

**Why not split into per-concern files:**
The 16 labeled sections share a single `write_state`/`run_hook` harness and a single PR
number fixture. The two branches (WIDEN and STOP) are tested in sequence, with
the already-applied guards exercised for both. Splitting into per-branch files
would multiply per-change edit sites: a future substrate change would require
updating N files instead of one. The driving factor is the hook's external
contracts, not the test file's internal structure.

**Why not extract helpers into `tests/lib/`:**
`babysit-tick-watchdog.test.sh` carries `write_state` and `run_hook` with diverged
implementations (different signatures and JSON schemas — see structural observation 1
above). A shared `tests/lib/` extraction would need to unify or adapt incompatible
interfaces to buy one saved line (`context_of`).
An extraction would move five helper functions (`fail` and `ok` are single-line;
`context_of` is a 3-line function; `write_state` spans 9 lines; `run_hook` spans
5 lines) into a sourced file with zero correctness benefit. The `merge-gate-review-substance-test-hotspot-decision.md`
record (Issue #1014, "declined extraction" finding) documents the same reasoning:
no companion, no diverged copy, no coverage gap — extraction adds maintenance
surface without buying anything.

## Future-edits guardrail

When `polling-backoff-warn.sh` is updated to emit new fields or change teardown
semantics, update the assertions in the corresponding case(s) in this test file.
A change to the widen branch (cases 2–10c) or the stop branch (cases 10b, 11–13)
is expected. Do not split the file or move helpers to `tests/lib/` — the
adjudication above explains why both are the wrong direction.
