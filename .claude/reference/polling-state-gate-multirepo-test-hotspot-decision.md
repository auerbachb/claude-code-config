<!-- churn-hotspot: .claude/scripts/tests/polling-state-gate-multirepo.test.sh -->
# Hotspot Decision — polling-state-gate-multirepo.test.sh

**Verdict:** KEEP (no split; mechanical duplication already resolved)
**Decided:** 2026-08-06
**Issue:** #1025
**Reporter:** `/wrap` post-merge churn report (PR #1024)

## Churn summary

`churn-hotspots.sh` flagged `.claude/scripts/tests/polling-state-gate-multirepo.test.sh` as
touched by 3 distinct merged PRs:

| PR | What changed |
|----|-------------|
| PR #856 | Created the multirepo suite — added `--repo` validation, malformed-key rejection, and identity-override tests for issue #854 |
| PR #970 | Stale-inherited-scope (`$CLAUDE_SESSION_REPO`) tests added; `write_handoff` call updated to the unified 3-arg scoped signature |
| PR #1024 | Extracted shared helpers (`mk_repo`, `write_handoff`, `write_polling_gh_stub`) into `tests/lib/polling-state-gate-fixtures.sh`; closed the scoped-path coverage gap (flat-handoff → scoped assertions for `org/a` and `org/b`) |

Only 3 PRs, and one of them (PR #1024) was the restructuring that resolved the
mechanical duplication. The sibling adjudication (Issue #1003,
`polling-state-gate-test-hotspot-decision.md`) diagnosed the same family and
proposed the fixture extraction that PR #1024 completed.

## Diagnosis

This is **coordinated shared-contract churn** on the repo-scoping seam, not
scatter or instability. Every edit traces to a sequential correctness fix in
`.claude/scripts/polling-state-gate.sh`:

- Issue #638 / PR #659 → per-repo scoping in session-state.sh
- Issue #647 → per-PR root_repo outranks the global scalar
- Issue #854 / PR #856 → collision detection, `--repo` / `$CLAUDE_SESSION_REPO` scope selection
- Issue #967 / PR #970 → stale inherited-scope override
- Issue #971 / PR #999 → pr-scope-resolver.sh extracted; then PR #1024 extracted shared test fixtures

Each gate change required a matching test-file update. With only 3 PRs touching
the file and one being the fixture extraction itself, there is no structural
instability here — the file tracks a faithfully evolving gate contract.

## Decision

**KEEP** the file in place. Do not split it.

PR #1024 already resolved the mechanical duplication concern identified in the
sibling adjudication:

- `mk_repo`, `write_handoff`, and `write_polling_gh_stub` were extracted into
  `.claude/scripts/tests/lib/polling-state-gate-fixtures.sh` and sourced from
  there.
- The scoped-path coverage gap (the multirepo suite previously wrote flat
  handoffs that relied on the backward-compat fallback) was closed: the suite
  now asserts path existence for `~/.claude/handoffs/org/a/pr-84-handoff.json`
  and `~/.claude/handoffs/org/b/pr-84-handoff.json`.

The remaining `check_eq` / `check_contains` duplication between suites is
intentional. The fixtures file header explicitly states this in its
`WHAT IS DELIBERATELY EXCLUDED` section: these are kept per-file to preserve
independent isolation guarantees.

## Why not split

Splitting the multirepo suite further would multiply the import surface without
reducing churn. The churn driver is external to the test-file structure — it is
the `polling-state-gate.sh` public interface evolving. A split would require N
edits (one per sub-file) on every subsequent gate change, rather than one
targeted addition to the existing well-scoped suite.

## Future ownership

- New multirepo repo-scoping regressions belong in this file.
- New shared helpers (stub signatures, common builders) belong in
  `.claude/scripts/tests/lib/polling-state-gate-fixtures.sh`.
- See the companion sibling adjudication in
  `polling-state-gate-test-hotspot-decision.md` for the primary suite's
  ownership notes.
