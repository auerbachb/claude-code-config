# Worker routing trials — November 7, 2026

Issue #1875. This is bounded evidence, not a claim of general model quality or
measured token savings. Reproduce the deterministic cases with
`MODEL_ROUTE_TRIAL_REPORT=/tmp/model-route-trials.json bash .claude/scripts/tests/model-route.test.sh`.

## Deterministic routing and persistence

The CLI fixture suite exercises continuing on the cheap tier after twenty failed
attempts that each produced new evidence, followed by completion. Equivalent
failures without evidence require diagnosis; two meaningfully different failed
approaches plus diagnosis select the next suitable tier. Repeated poor patches
with evidenced reviewer/CI churn also require diagnosis. A single rejection
does not upgrade. These are simulated histories, not twenty live model calls.

Negative controls cover unavailable models, unsupported tool/context requirements,
unknown capability, owner pins, explicit owner selection, budget/reserve blocks,
pause/deadline controls, unchanged permissions, unchanged pushes, unknown checks,
partial spend and nonfinite spend. The actual fenced dispatch code runs against
the real locked session/handoff writers: it persists routing before selecting
the model, retains other phases, records blocked decisions, and refuses launch
on missing handoffs or failed state writes. No merge/reviewer gate is substituted. Additional cases verify truthful waiting
and exhaustion, minimum runtime precedence/forced overrides, task-keyed handoff
history and post-edit push guards. The actual literal handoff writer preserves
unknown fields and prior completed tasks while seeding a different goal.

Fixture costs/times are simulated or null. The JSON report separately measures
the router process elapsed time; this is not model inference latency. Full source
and expected outcomes are in the test suite rather than a copied results table.

## Live read-only cheap-worker sample

One restricted Claude CLI worker was invoked explicitly on Haiku, with no tools,
no MCP servers, no project/user settings, no saved session, and a $0.10 maximum
API-budget bound. The existing credit-budget check reported `ok` before launch.
The worker classified five sanitized usage-limit messages under a supplied
precedence rule; no code/repository access or paid reviewer was used.

| Measure | Observed result |
|---|---|
| Effective model | Haiku, matching the request in CLI model-usage telemetry |
| Completion | Successful, exit 0 |
| Quality | 5/5 exact classifications |
| End-to-end elapsed | 4.393 seconds, measured with a monotonic clock |
| CLI `total_cost_usd` | $0.00039695 (CLI-reported accounting, not an independently verified charge) |
| Independently reconciled billed spend | Unknown |
| Retries / reviewer rounds / CI reruns | 0 / 0 / 0 |

The cases were weekly plan cap with credits remaining → `plan_window`; exhausted
paid credits → `credit`; generic rate limit → `unknown`; daily plan cap →
`plan_window`; an active account with $0 billed today → `unknown`. The task prompt
defined these rules before the call. There was no forced wrong answer or invented
retry history. This small sample shows an eligible cheap worker completing a
bounded task; it cannot establish coding/review quality, escalation savings or
the capability of every model for every repository task. Live multi-attempt
coding and comparative cost results remain unmeasured.
