# Catalog doc row order — per-doc opt-in decision

Reference for Issue #1544, follow-up to Issue #1535 / PR #1539. Not auto-loaded.

**Verdict:** row order in `.claude/scripts/docs/` is an **opt-in** convention. A
category doc that carries `<!-- catalog-lint: ordered -->` must list its rows in
`LC_ALL=C sort` order, enforced by check 6 in
`.github/scripts/scripts-catalog-lint.sh`. `tests.md` carries the marker. The
other 12 category docs do not, and are not read for order at all.

## Context

PR #1539 restored `candidate-ownership.test.sh` to its alphabetical slot in
`.claude/scripts/docs/tests.md` — the table's only displaced row at the time.
Both that issue and that PR deliberately stopped short of enforcing the order,
because a repo-wide ordering lint would have been wrong against the sibling
docs and a `tests.md`-only lint would have declared a new convention on the way
past. The question went to the backlog as Issue #1544.

Displacement from `LC_ALL=C sort` order across all 13 category docs, measured
when PR #1539 merged:

| doc | rows displaced |
|-----|----------------|
| `tests.md` | 0 of 98 (0%) |
| `token-measurement.md` | 1 of 4 (25%) |
| `pr-state-polling.md` | 3 of 9 (33%) |
| `release-cadence.md` | 1 of 3 (33%) |
| `backlog-pm.md` | 6 of 14 (42%) |
| `trust-worktree-repo.md` | 4 of 9 (44%) |
| `utilities.md` | 5 of 11 (45%) |
| `scheduling-monitoring.md` | 6 of 11 (54%) |
| `session-state-locking.md` | 4 of 7 (57%) |
| `merge-gate-sequencing.md` | 6 of 10 (60%) |
| `review-escalation.md` | 6 of 9 (66%) |
| `review-threads-diffs.md` | 2 of 3 (66%) |
| `skills-telemetry.md` | 4 of 6 (66%) |

The siblings are not sloppy — they are grouped by workflow role on purpose.
`pr-state-polling.md` leads with the primary `pr-state.sh` before its helpers;
`utilities.md` keeps the `portable-handoff-*` family together. Sorting them
would destroy information a reader uses.

## Options considered

1. **Do nothing.** The invariant stays unwritten and drifts again, caught only
   by eye — which is how the PR #1539 row surfaced in the first place.
2. **Declare and lint `tests.md` only.** Cheap, but it hard-codes one doc's
   name into the lint and makes a convention official for 1 doc of 13, with no
   way for another doc to adopt or drop it.
3. **Per-doc opt-in marker.** A marker the lint honors, so role-grouped
   siblings stay legal and any doc can adopt ordering when it wants it.

**Option 3**, recorded 2026-09-02. It encodes the invariant exactly where it
exists, without legislating for docs that deliberately differ, and without the
lint knowing any doc by name.

Option 1 was refuted within a day of the decision: `overrun-check-tzdata.test.sh`
(added by PR #1579) landed in `tests.md` immediately *after*
`overrun-check.test.sh`, which reads correctly but is not `LC_ALL=C` order —
`-` is 0x2D, `.` is 0x2E, so the longer name sorts first. Nothing caught it.
Issue #1544's PR restores that pair.

## How the check works

- **Opt-in marker:** `<!-- catalog-lint: ordered -->`, anywhere in the doc
  outside a fenced code block. A doc without it is never read for order.
- **Fence skip:** the marker is detected with the same `AWK_DOC_PRELUDE` fence
  skip the back-link check uses. A marker shown inside a fence documents the
  format; it must not quietly opt that doc in.
- **Position is not constrained.** A marker written below the table still opts
  the doc in — the alternative, silently doing nothing, is the worse failure.
- **Key is the link text**, not the normalized path that checks 1 and 3 key on.
  The order the lint enforces is the order a reader scans down the table. The
  consequence is that the top-level/`tests/` namesake pair of Issue #1452 —
  two rows with identical link text — compares equal and may appear in either
  order, because nothing in the rendered doc distinguishes them. Both orders
  are pinned by tests.
- **Detection is by adjacent pair.** A list is in sort order exactly when no
  adjacent pair is inverted, so the error names the row that has to move and
  the row it follows, rather than printing a diff against a sorted copy.
- **No early `exit` in the awk.** Under `set -o pipefail` an early exit closes
  the pipe, `entry_rows` takes SIGPIPE, and a clean read reports as a failed
  pipeline.

## Adopting or dropping the convention

Adding the marker to another category doc is the whole adoption step; sort its
rows first or CI will name the rows that need moving. Removing the marker drops
the doc back to unchecked, with no other edit required.

## Related

- Issue #1535, PR #1539 — the displaced row that raised the question.
- Issue #1452, PR #1570 — `normalize_relpath` path keying in the same script.
  Landed first, so check 6 builds on it; the namesake-pair tie above is the
  one place the two checks deliberately disagree on the key.
- PR #1579 — added the row that drifted before this lint existed.
