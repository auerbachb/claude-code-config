<!-- churn-hotspot: .claude/scripts/tests/polling-state-gate.test.sh -->
# Hotspot Decision — polling-state-gate.test.sh

**Verdict:** KEEP + extract shared fixtures  
**Decided:** 2026-08-05  
**Issue:** #1003  
**Reporter:** `/wrap` post-merge churn report (PR #999)

## Churn summary

`churn-hotspots.sh` flagged `.claude/scripts/tests/polling-state-gate.test.sh` as
touched by 7 distinct merged PRs:

| PR | What changed |
|----|-------------|
| PR #653 | Introduced polling-state-gate.sh + primary test suite |
| PR #659 | session-state.sh schema changed (PR-scope layout); test adapted |
| PR #724 | --repo / $CLAUDE_SESSION_REPO scope selection tests added (issue #854) |
| PR #728 | Colliding-PR-number and every-refusal-exits-nonzero tests added |
| PR #739 | Stale-env-scope override tests added (issue #967) |
| PR #747 | pr-authorship.sh gate wired into --ensure-session; tests 11–12 added |
| PR #999 | pr-scope-resolver.sh extracted; stub signature updated |

A companion file, `polling-state-gate-multirepo.test.sh`, was created separately
(PR #856) and evolved in parallel, touching the same shared contracts at each step.

## Diagnosis

This is **coordinated shared-contract churn** on the repo-scoping seam, not
scatter or instability. Every edit traces to a deliberate extension of the
`polling-state-gate.sh` public interface (a new flag, a new exit code, a new
scope-resolution rule). The test file tracks the gate faithfully; its edit
frequency is a direct symptom of the gate itself being actively developed.

Contributing factors:
- Two test files (`*.test.sh` primary + `*-multirepo.test.sh`) both carry the
  same local helper functions (`mk_repo`, `write_handoff`, `gh` stub), so every
  stub-signature change requires two edits instead of one.
- The multirepo suite's `write_handoff` wrote flat-path handoffs that relied on
  the backward-compat fallback in the gate — silently not exercising the scoped
  path introduced by PR #655 / issue #655.

## Decision

**KEEP** both test files in their current locations. The gate is a load-bearing
offline check in the polling workflow; splitting it across more files buys
nothing and multiplies the import surface.

**EXTRACT** shared helpers into `tests/lib/polling-state-gate-fixtures.sh`:
- `mk_repo <dir> <origin-url>` — throwaway git repo builder
- `write_handoff <owner_repo_or_empty> <pr_number> <head_sha>` — scoped handoff
  writer via `handoff-state.sh`; unified 3-arg signature replaces the two
  diverged per-suite forms
- `write_polling_gh_stub <bin_dir>` — env-var-driven `gh` stub; replaces both
  the baked-at-write `write_ensure_session_gh_stub` in the primary suite and the
  inline heredoc in the multirepo suite

**CLOSE COVERAGE GAP**: multirepo suite previously wrote flat handoffs relying on
the fallback. Switch to scoped `write_handoff` and add path-existence assertions
for `~/.claude/handoffs/org/a/pr-84-handoff.json` and
`~/.claude/handoffs/org/b/pr-84-handoff.json`.

## Why not split the test file?

The churn is caused by the gate's evolving interface, not by the test file's own
structure. Splitting the primary suite into per-feature files would:
1. Require N edits (one per sub-file) on every subsequent gate change
2. Destroy the sequential setup context (REPO_A, STATE, HANDOFF) that several
   later tests depend on
3. Not reduce future churn — the driving factor is external

The extraction already removes the main mechanical duplication (helpers). Future
single-PR gate changes now require one helper update instead of two full stub
rewrites.

## Expected impact

After this extraction, a stub-signature change requires one edit in
`tests/lib/polling-state-gate-fixtures.sh` and zero edits in either suite.
Gate-interface extensions still touch both suites (new test cases), but that is
intentional co-evolution, not churn.
