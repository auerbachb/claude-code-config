# Time Estimate Vocabulary

> This document is the single source of truth for capture-time estimates. All three
> skills — `/issue-maker`, `/prompt`, `/start-issue` — share this table and format.
> The seed table below is replaced by measured actuals as history accumulates —
> see [`estimate-actuals.md`](estimate-actuals.md) for the current recalibrated table
> (regenerated via `estimate-log.sh --rollup`).

## Format

```
Est: {lo}–{hi} min · plan on {bound}
```

- `{lo}` and `{hi}` — expected wall-clock range in whole minutes.
- `plan on {bound}` — the planning bound: the single number a day-planner reserves.
  Always equals `{hi}`.
- Both values are plain integers separated by an en-dash (`–`, U+2013).

**Example:** `Est: 45–90 min · plan on 90`

**Machine-parse pattern:** `^Est:\s+(\d+)–(\d+)\s+min\s+·\s+plan\s+on\s+(\d+)$`

Group 1 = lo, Group 2 = hi, Group 3 = planning bound. A valid estimate requires Group 1 < Group 2 (lower bound < upper bound) and
Group 3 == Group 2 (planning bound must equal upper bound). Reject lines where either
constraint fails — e.g. `Est: 30–15 min · plan on 15` (inverted bounds) or
`Est: 15–30 min · plan on 90` (mismatched planning bound) are both malformed. Later increments
(dispatch makespan, actuals logging) read estimates from issue bodies using this pattern.

## Measurement Window

The estimate measures **wall-clock elapsed time from issue claim to PR merged** in a
single attended pipeline:

- **Start:** the moment the coding thread claims the issue (before any repo reads or
  planning).
- **End:** the GitHub merge timestamp on the squash-merged PR.
- **Scope:** implementation → local review → push → AI-review rounds (CodeRabbit /
  BugBot / Greptile) → CI → merge.
- **Attended** means the session is actively driving — a human is available to
  approve CI, respond to review escalations, and trigger the next phase. Idle wait
  time (CI queue, reviewer latency during a session) is included because it is real
  wall-clock time from a day-planner's perspective.
- **Out of scope:** overnight / unattended queuing, multi-agent parallel dispatch,
  cross-timezone handoffs. The unattended margin is increment 4's concern.

## Tier → Time Seed Table

| Tier | Range | Planning bound | Estimate line |
|------|-------|---------------|---------------|
| **Light** | 15–30 min | 30 min | `Est: 15–30 min · plan on 30` |
| **Standard** | 45–90 min | 90 min | `Est: 45–90 min · plan on 90` |
| **Heavy** | 90–180 min | 180 min | `Est: 90–180 min · plan on 180` |

**Tier vocabulary** is identical to `tier-inference.md` (issue-maker) and `/prompt`
Step 5: Heavy / Standard / Light, evaluated using the same signals.

**Default:** use the table row for the issue's tier. Do not adjust unless scope
clearly warrants it — e.g., a Standard-tier issue touching a single well-understood
file may be closer to Light (15–30 min). State the reason in one sentence when
adjusting; never adjust silently.

## Usage by Skill

| Skill | Behavior |
|-------|----------|
| `/issue-maker` | Infer tier from the issue signals, look up the estimate line, add `## Estimate` section to the issue body before filing. |
| `/prompt` | Surface the estimate in the Tier Recommendation output. If the issue body already has `## Estimate`, echo that line; otherwise derive from tier + this table. |
| `/start-issue` | Surface the estimate in the ready-to-code summary. Same fallback logic as `/prompt`. |
| `/pm` | Show `Est:` line under each suggested issue. Resolved via `estimate-resolve.sh`. |
| `/subagent` | Show `Est:` line in the launch report and completion summary. Resolved via `estimate-resolve.sh`. |
| `/wave` | Show batch makespan after the wave block. Computed via `makespan.sh`. |

Read this file through the standard candidate order (`portable-skill-resolution.md`):
`$HOME/.claude/skills-worktree/.claude/reference/time-estimates.md` first, then
`$HOME/.claude/reference/`, then `.claude/reference/`. If unavailable, print
`DEGRADED: time-estimates.md not found (checked all three paths) — using inline fallback`
and use the inline values from the table above; never silently omit the estimate.

---

## Batch Makespan Model (increment 3)

The batch makespan answers "when will this batch finish?" — a number per-issue estimates alone cannot give because pipelines overlap, chains serialize, and a shared reviewer cap throttles throughput.

**Helper:** `makespan.sh` (same resolution order as other scripts). Input: JSON object `{"issues":[{"num":N,"est_lo":lo,"est_hi":hi,"deps":[...]},...]}` where `est_lo`/`est_hi` are minutes or `null` for unestimated issues. Output: one line — `lo–hi [h|min] · binding: <bound> · plan on ~HH:MM AM/PM ET`.

### Three bounds; makespan = max of all three

| Bound | Formula | When binding |
|-------|---------|--------------|
| **parallel-work** | `max(max(est_hi), sum(est_hi) / ceiling)` | Most batches — implementation time dominates |
| **critical-chain** | Longest `Depends on` path (sum of `est_hi` along that path) | Any batch with a serialized increment chain |
| **reviewer-throughput** | `n_issues × (60 / 5)` = `n × 12 min` | Large batches of fast issues (Light tier or faster) |

The reviewer-throughput floor uses **5 reviews/hour** — the CodeRabbit Pro cap from `cr-github-review.md` "Rate Limits". When this bound is binding, the report says so: adding more parallel agents stops helping because CR is the bottleneck.

**Concurrency ceiling:** 4 (from `subagent-orchestration.md`; configurable via `--ceiling`).

### Unestimated issues

An issue with no `## Estimate` section and no complexity tier label resolves to `unestimated`. `makespan.sh` uses the Standard-tier fallback (45/90 min) for unestimated issues so the batch always has a result; the count of fallbacks is noted in the output line. `estimate-resolve.sh` exits 2 and prints `unestimated` for fully unresolved issues — never a blocker for dispatch.

### Output format

```
45 min–1.5 h · binding: parallel-work · plan on ~10:30 PM ET
2.5 h–4.5 h · binding: critical-chain · plan on ~1:30 AM ET
1.5 h (1 unestimated → Standard fallback) · binding: reviewer-throughput (6 issue(s) × 12 min/review at 5/hr) · plan on ~7:00 PM ET
```

The finish clock time is `now + makespan_hi` in Eastern Time.
