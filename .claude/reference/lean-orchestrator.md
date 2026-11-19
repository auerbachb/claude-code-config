# Lean Orchestrator — Delegate First (Issue #2435)

Mechanism, permitted-direct-work list and rationale behind the one-line rule in `monitor-mode.md`. Increment 1 (Issue #2434) measured the parent thread's cost; this increment changes the parent's behavior. It is the final increment of the Lean orchestrator work.

## The rule

When the orchestrating (parent) thread runs on a premium model (Fable, Opus), it decides and delegates. Reading, searching, summarizing, checking and formatting go to a script when one exists, else to the cheapest eligible worker chosen with `model-route.sh` (`task-model-routing.md`), without the parent looking first. The rule holds in `/pm` threads with no workers running too. On a cheaper parent model the same habits apply but matter less.

## Parent-permitted direct work (the whole list)

<!-- lean-orchestrator:permitted -->
- `user-conversation` — talking to the operator, including blocker and decision surfaces.
- `launch-decision` — choosing what runs next and making the launch call itself (see "Can a worker launch workers?").
- `phase-transition` — approving and executing A to B to C transitions from a compact exit-report result.
- `gate-outcome` — acting on a gate script's verdict (merge, hold, fix, escalate); never re-deriving it.
- `blocker-judgment` — a failure, crash or conflict that needs judgment, after a worker has summarized it.
- `trivial-lookup` — a single read or command whose answer is one short value, cheaper than a cold worker start (the floor below).
<!-- /lean-orchestrator:permitted -->

Anything else is delegated. When the parent does something substantial itself, it states why in one line.

**Floor.** A worker starts cold and reloads its baseline context, so a two-line lookup can cost more delegated than done. A single read or command whose output is a few lines stays with the parent. Reading a log, diff, review body, report or backlog list does not. The measurement in "Before and after" decides whether the floor moves.

## Who does what

| Work | Goes to |
|---|---|
| Is anything different? (PR, CI, review, claim state) | Script digest at the end of a persistent `Monitor`; no parent turn when unchanged |
| What did a worker report? | `exit-report-extract.sh` (below); never the transcript |
| Why did CI fail, what do these findings say, what does this diff do? | Cheapest eligible worker (`researcher` for read-only), returning a bounded conclusion |
| Backlog gathering, ranking inputs, scope signals, plan detection | Worker or script; the parent chooses from the compact result |
| Drafting issue or PR text, formatting a table | Script or worker |

Full detail stays in the existing records, logs, handoff files and `session-state.json`. Evidence that used to pass through the parent is recorded exactly where it was; only the parent's reading of it is removed. Nothing here weakens a gate, safety rule, authorship check, claim, launch control, state write, or the liveness guarantees of `scheduling-reliability.md` (bgwork ceiling watch, hourly table floor).

## Quiet ticks

`.claude/scripts/tick-digest-gate.sh` sits at the end of a persistent `Monitor` command. It compares the tick's state digest with the last one for that key:

- unchanged: prints nothing (exit 10), so no notification and no parent turn;
- first observation: stores a baseline, prints nothing (exit 11);
- changed: prints one line `EVENT <key> changed: <what> | next: <decision> | record: <pointer>`, capped at 400 bytes (exit 0). The full record is at the pointer.

A record that exists but cannot be read is not a first observation: it prints a bounded event and exits 4. Every printed line, including the baseline-failure event, honors `--max-bytes`. If the digest cannot be stored it still prints the event and exits 4: failure goes toward waking the parent, never toward silence. The Monitor, the ceiling watch and the hourly table floor keep their own output unchanged. Build the digest from the same fields `scheduling-reliability.md` §Stable-State Backoff already hashes. Free text stays out of it.

### Which monitors are quiet today

| Monitor | Status | Evidence |
|---------|--------|----------|
| `/pr-monitor-and-manage` fleet Monitor | Quiet when unchanged (its own shell gate) | `pr-monitor-and-manage/SKILL.md` "Verify or re-arm the Monitor": `pmm-pre-dispatch.sh` prints nothing for unchanged state |
| `bgwork-ceiling.sh --tick`, `table-freshness.sh --tick` | Quiet unless stale | the ceiling and hourly floor, unchanged |
| `/babysit-pr` Monitor | Quiet when unchanged (`monitor-quiet-tick.sh`) | `babysit-pr/SKILL.md` blocks `babysit-pr-monitor-loop`, `babysit-pr-t6a-quiet-record` |
| `/pm day` Monitor | Quiet when unchanged (`monitor-quiet-tick.sh`) | `pm/modules/day-arm.md` block `pm-day-monitor-loop`, `day-tick.md` block `pm-day-tick-quiet-record` |

The last two compute their digest, streak and backoff (widen at 3, stop or pause at 9) and the blocker-tick terminal inside the model turn. Since Issue #2459, a model tick ends by recording a contract: whether a repeat would do nothing new, plus an input digest the shell computed at the start of that tick, before it classified, so an event that lands mid-tick still wakes the model. On an unchanged tick, `monitor-quiet-tick.sh` advances exactly the counters that turn would have advanced (`digest_streak`, `blocker_streak` when counting, `tick_count`, `last_tick_at`) and prints nothing. It emits the tick that would change the cadence tier, reach streak 9 or reach the blocker cap, leaving the counter to the model, so every threshold fires on the same tick as before. A changed digest, a stale contract and any failure emit too. `/subagent`'s Step 8 loop is the parent's in-turn poll, not a Monitor.

## Worker results

`.claude/scripts/exit-report-extract.sh [--phase P] [FILE]` reduces a worker's final output to `KEY=value` lines (phase, PR, head, reviewer, outcome, next phase, handoff path, files count, verdicts, `/fixpr` wait fields), each capped. It reads the last `EXIT_REPORT` block. Exit 3 means no report (`EXTRACT=absent`): the parent then classifies crash versus usage-limit park per `phase-protocols.md` §Limit-parked, never the script. Exit 1 means a malformed report and fails closed. A `RESULT:` line (required for a `pm-worker` `completed` report, optional elsewhere) carries a short task result (for example a `pm-worker`'s created issue number), so the parent need not read prose above the report. For a blocked report, `RESULT` carries the one-line blocker summary. The parent reads a worker's transcript or full log only when a blocker needs more detail. Blocked-before-push and exhaustion reports may carry `PR_NUMBER: none`; every outcome that claims a PR must carry an integer PR and non-blank head, reviewer and handoff (see `exit-report-format.md`).

## Worker conduct

A worker that ends its turn with interim status, or waits through a `Monitor` or background command, wakes the parent on every event. So:

- A worker waits in a single foreground command and ends every outcome with the structured `EXIT_REPORT`. For a terminal blocker the reason goes in prose directly above the report and a one-line summary goes in `RESULT`.
- The parent passes a brief by file path and the verbatim blocks the verbatim-block rules require, rather than re-printing long guardrail text into each prompt. Where a rule demands a verbatim block in the prompt, the block stays in the prompt.

## Can a worker launch workers? (answered)

Checked in this repo's agent definitions and in a live worker session. `phase-a-fixer`, `phase-b-reviewer` and `pm-worker` declare no `tools:` line, so they inherit all tools, and a worker of that kind was observed holding the `Agent` tool. `phase-c-merger`, `researcher` and `silent-failure-hunter` do not. What is not established is that a nested launch passes the parent-owned controls: the launch hooks, the pause and deadline gates, ceiling and `active_agents` accounting, claim inheritance, and the routing record (`orchestrator-cost-baseline-2026-11.md` §Known checks notes that a nested worker can mask a missing one). Decision: **launch calls stay with the parent**, and "delegate" means everything around the launch. No foreman agent is designed on this unverified capability. A foreman that runs the pipeline procedure for the parent deserves its own issue, to be opened only with evidence that nested launches keep every control above.

## Step ownership in `/pm` and `/subagent`

The two skills carry the same two lines. `lean-orchestrator-lists.test.sh` keeps them in step. No parent-run step's main cost is reading: reading steps are in the handed-off line, and the parent acts on their compact result.

### /pm

<!-- lean-orchestrator:pm -->
Parent-run: 0c, 0d, 2, 3.1, 3.4, 3.5
Handed off: 0, 0a, 0b, 1, 1A, 1B, 1C, 1D, 2D, 3.2, 3.3
<!-- /lean-orchestrator:pm -->

### /subagent

<!-- lean-orchestrator:subagent -->
Parent-run: 5, 7, 8, 9, 10, 11
Handed off: 0, 1, 2, 3, 4, 5.1, 6
<!-- /lean-orchestrator:subagent -->

"Handed off" includes steps a script already does; the parent runs the script and reads its compact output.

## Before and after

The baseline is `orchestrator-cost-baseline-2026-11.md` (two Fable `/pm` sessions: parent share 27.6% and 54.7% of observed tokens, 22 and 23 changed-nothing parent turns). The acceptance criterion needs two later premium-model `/pm` sessions of at least five pipelines, re-measured with `orchestrator-cost-report.sh`. That cannot be run from the isolated worktree that implemented this change, so no after-numbers are recorded and none are invented. They are measured after merge, tracked on the follow-up issue linked from the PR, and added to the baseline file whichever way they come out.

## Rationale

Each small parent turn pays the full context on the dearest model, draws the premium allowance, and grows the thread toward compaction. The baseline's top drivers were worker-result handling and changed-nothing check-ins. Delegating the reading, and not waking the parent for an unchanged tick, remove those turns without touching any record or gate.
