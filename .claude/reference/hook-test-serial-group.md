# Hook-test serial group: per-entry review (issue #2207)

`SERIAL_GROUP` in `.github/scripts/run-hook-tests.sh` lists the suites that run one at a
time after the parallel pool. This note records the decision for each of its 40 entries.

Decision rule (issue #2207 AC 3): an entry either keeps its serial slot with a stated
reason, or returns to the pool because its timing bound was made load-independent or
looser in a justified way. Nothing moves back merely to save time.

Timings are from full CI run 43092089570 (2026-11-11), wall seconds per suite. Only the
30 slowest suites per platform were printed, so `-` means the suite was below that cut
(under 50 s on macOS, under 34 s on Linux). Serial group totals: macOS 884 s, Linux 600 s.

## Decision summary

All 40 entries **keep their serial slot** in this change. No timing bound was edited, so
none qualifies to return to the pool yet. Each row names the property that makes it
load-sensitive and what would have to change before it can return.

| # | Suite | macOS s | Linux s | Decision | Reason | To return to pool |
|---|-------|---------|---------|----------|--------|-------------------|
| 1 | `.claude/hooks/tests/silence-detector-time-dedupe.test.sh` | - | - | Keep serial | Primes and clears fixed `/tmp/claude-*-<session-id>` sentinels that the hook uses by design | Per-run sentinel names in the hook and suite |
| 2 | `.claude/hooks/tests/session-start-sync-publish-bounds.test.sh` | - | - | Keep serial | Wall-clock budget assertions (stall leg and ample-budget control) | Make budgets load-independent |
| 3 | `.github/scripts/tests/scripts-catalog-gen.test.sh` | - | - | Keep serial | Runs the generator `--check` against the live checkout; overlap caused false drift (CI run 42969745313) | Run against a copied tree |
| 4 | `.claude/scripts/tests/pr-state-stdout.test.sh` | - | - | Keep serial | Counts `/tmp/pr-state-7-*` entries that `pr-state.sh` writes under a fixed prefix | Honour `TMPDIR` in `pr-state.sh` |
| 5 | `.claude/scripts/tests/local-review.test.sh` | 72 | 34 | Keep serial | 1-3 s `--timeout` bound is the behaviour under test | Loosen bound only with its assertion intact |
| 6 | `.claude/scripts/tests/worktree-isolation-shapes.test.sh` | - | - | Keep serial | 1-3 s `--timeout`/`--interval` bounds under test | As row 5 |
| 7 | `desk/tests/cli.test.sh` | - | - | Keep serial | Desk offline: finish within 1-2 s, no connection attempt | Load-independent bound |
| 8 | `desk/tests/checkin-offline.test.sh` | - | - | Keep serial | Desk offline 1-2 s bound | As row 7 |
| 9 | `desk/tests/desk-offline.test.sh` | 52 | - | Keep serial | Desk offline 1-2 s bound | As row 7 |
| 10 | `desk/tests/export-offline.test.sh` | - | - | Keep serial | Desk offline 1-2 s bound | As row 7 |
| 11 | `desk/tests/ideas-offline.test.sh` | - | - | Keep serial | Desk offline 1-2 s bound | As row 7 |
| 12 | `desk/tests/interrupts-offline.test.sh` | - | - | Keep serial | Desk offline 1-2 s bound | As row 7 |
| 13 | `desk/tests/items-cli.test.sh` | - | - | Keep serial | Desk CLI 1-2 s bound | As row 7 |
| 14 | `desk/tests/lifecycle-cli.test.sh` | - | - | Keep serial | Desk CLI 1-2 s bound | As row 7 |
| 15 | `desk/tests/longform-offline.test.sh` | - | - | Keep serial | Desk offline 1-2 s bound | As row 7 |
| 16 | `desk/tests/plan-offline.test.sh` | - | - | Keep serial | Desk offline 1-2 s bound | As row 7 |
| 17 | `desk/tests/question-leak-warn.test.sh` | - | - | Keep serial | Desk 1-2 s bound | As row 7 |
| 18 | `desk/tests/report-offline.test.sh` | - | - | Keep serial | Desk offline 1-2 s bound | As row 7 |
| 19 | `desk/tests/reviews-cli.test.sh` | - | - | Keep serial | Desk CLI 1-2 s bound | As row 7 |
| 20 | `desk/tests/reviews-view-offline.test.sh` | - | - | Keep serial | Desk offline 1-2 s bound | As row 7 |
| 21 | `desk/tests/todo-offline.test.sh` | - | - | Keep serial | Desk offline 1-2 s bound | As row 7 |
| 22 | `desk/tests/capture-offline.test.sh` | - | - | Keep serial | Desk 1-5 s deadline | Load-independent deadline |
| 23 | `desk/tests/drilldown-offline.test.sh` | - | - | Keep serial | Desk 1-5 s deadline | As row 22 |
| 24 | `desk/tests/migrate.test.sh` | - | - | Keep serial | Desk 1-5 s deadline | As row 22 |
| 25 | `desk/tests/psql-bindings.test.sh` | - | - | Keep serial | Desk 1-5 s deadline | As row 22 |
| 26 | `desk/tests/psql-discovery.test.sh` | - | - | Keep serial | Desk 1-5 s deadline | As row 22 |
| 27 | `.claude/hooks/tests/pause-lifecycle-hooks.test.sh` | - | - | Keep serial | Lock contention under a 5 s limit | Longer lock timeout in the assertion only |
| 28 | `.claude/hooks/tests/ai-account-session-start.test.sh` | - | - | Keep serial | Hook latency under 1 s | Load-independent latency check |
| 29 | `.claude/hooks/tests/register-hooks.test.sh` | - | - | Keep serial | Subprocess deadline of 10 s or less | Looser deadline |
| 30 | `.claude/hooks/tests/spend-telemetry-maintenance.test.sh` | - | - | Keep serial | Subprocess deadline of 10 s or less | As row 29 |
| 31 | `.claude/hooks/tests/spend-telemetry-tracker.test.sh` | - | - | Keep serial | Subprocess deadline of 10 s or less | As row 29 |
| 32 | `.claude/scripts/tests/bounded-run.test.sh` | - | 40 | Keep serial | A 4 s bound inside a 7 s window | Looser bound with the same assertion |
| 33 | `.claude/scripts/tests/help-output.test.sh` | - | - | Keep serial | `--help` must return inside 10 s | Looser limit |
| 34 | `.claude/scripts/tests/ac-checkboxes.test.sh` | - | - | Keep serial | Subprocess deadlines of 2-10 s | Looser deadlines |
| 35 | `.claude/scripts/tests/ai-account-ledger.test.sh` | - | - | Keep serial | Subprocess deadlines of 2-10 s | As row 34 |
| 36 | `.claude/scripts/tests/estimate-log-locks-bash.test.sh` | - | - | Keep serial | Subprocess deadlines of 2-10 s | As row 34 |
| 37 | `.claude/scripts/tests/estimate-rounds-batch-bash.test.sh` | - | - | Keep serial | Subprocess deadlines of 2-10 s | As row 34 |
| 38 | `.claude/scripts/tests/park-wake-publish.test.sh` | - | - | Keep serial | Subprocess deadlines of 2-10 s | As row 34 |
| 39 | `.claude/scripts/tests/pmm-pre-dispatch.test.sh` | 223 | 237 | Keep serial | Largest serial suite. Subprocess deadlines of 2-10 s, and its own timing assertions | First candidate to return: loosen the deadline assertions, then show 3 stable runs under load |
| 40 | `.claude/scripts/tests/workspace-sweep.test.sh` | - | - | Keep serial | Subprocess deadline of 10 s or less | As row 34 |

## What this means for the targets

- Linux, if every serial suite returned to the pool with no other change:
  `(3076 + 600) / 4 ≈ 919 s ≈ 15.3 min` floor, against the 20 min target. This is the
  cheapest route to the Linux target, but it needs bounds made load-independent first.
- macOS, with every serial suite folded into the pool: `(5039 + 884) / 3 ≈ 1974 s ≈ 33 min`,
  still above the 30 min target. The macOS target therefore needs suite-time reduction
  (the slowest suites) and/or a sharded run. See the PR body for the open items.
