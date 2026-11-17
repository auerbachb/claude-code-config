# Orchestrator cost baseline — 2026-11 (Issue #2434)

Point-in-time measurement of the parent thread's share of `/pm` session tokens, taken with `.claude/scripts/orchestrator-cost-report.sh --json`. Figures are tokens. Every figure below is a derived aggregate. No session IDs, prompts, tool arguments, paths or account identifiers are recorded here.

## Method

- Two completed `/pm` sessions from 2026-11-16 were selected from the local skill-usage log. Both ran on the `claude-fable-5-2` parent model, confirmed from the main transcript's per-message model field, not from frontmatter defaults.
- Parent figures come from the main transcript's assistant usage (sidechains excluded). Worker figures come from spend-telemetry rows with a worker `agent_id`, deduplicated by message identity.
- Each figure carries a label. `known_subtotal` means at least one limitation applied. `complete_total` would mean no limitation applied. `unknown` means the field was not measured.
- Turn classes use the precedence in `spend-telemetry-pipeline.md` §Orchestrator session report.

## Results

| Measure | Session A (2026-11-16) | Session B (2026-11-16) |
|---|---|---|
| Parent model | claude-fable-5-2 | claude-fable-5-2 |
| Parent messages | 509 | 535 |
| Parent sum (4 fields) | 265,711,131 (known_subtotal) | 275,551,601 (known_subtotal) |
| Parent input / cache read / cache write / output | 1,032 / 264,000,122 / 1,285,981 / 423,996 | 1,076 / 271,209,497 / 3,771,244 / 569,784 |
| Workers observed | 48 | 26 |
| Worker sum (4 fields) | 698,069,979 (known_subtotal) | 227,781,862 (known_subtotal) |
| Parent share | unknown: `partial_data:unmatched_agent_calls,unsupported_worker_row` | unknown: `partial_data:unsupported_worker_row` |
| Parent turns | 189 | 144 |
| Ambiguous turns (more than one class matched) | 4 | 2 |

Top parent cost drivers by four-field sum (class, turns, sum, cache-read share):

| Session | Rank | Class | Turns | Sum | Cache reads |
|---|---|---|---|---|---|
| A | 1 | worker_result_handling | 121 | 176,656,493 | 175,884,030 |
| A | 2 | other | 43 | 74,531,929 | 73,856,399 |
| A | 3 | changed_nothing_checkin | 22 | 11,579,728 | 11,526,545 |
| B | 1 | worker_result_handling | 88 | 160,462,109 | 159,902,516 |
| B | 2 | other | 25 | 93,689,485 | 90,945,872 |
| B | 3 | changed_nothing_checkin | 23 | 16,813,846 | 16,764,814 |

Turn counts by class, session A: worker_result_handling 121, other 43, changed_nothing_checkin 22, user_reply 1, instruction_skill_load 2, data_gathering 0. Session B: worker_result_handling 88, other 25, changed_nothing_checkin 23, user_reply 5, instruction_skill_load 3, data_gathering 0.

The figures above come from the final report code. An earlier pass on the same sessions, before the read-only command and turn-grouping review fixes, gave different class counts and an ambiguity count of 8 and 15. Those earlier figures are superseded.

## What could not be measured (recorded as unknown)

- **Parent share.** Both sessions carry an `unsupported_worker_row` limitation, because the spend log holds `unsupported:*` usage rows for this session. Session A also has an `unmatched_agent_calls` limitation: some `Agent` calls have no matching worker usage row. The share is therefore `null` with those reasons. It is not computed from partial sums.
- **Provider usage-page comparison.** Not performed. The provider usage page shows account totals for a window, and other activity in that window prevents attribution to one session. The comparison needs an operator on the authorized machine, and it is not recorded here.
- **Per-session Fable allowance.** Not visible from local data. Unknown.
- **Classification reliability beyond the ambiguity count.** Not separately measured. The ambiguous-turn counts above (4 and 2) are the only evidence recorded.
- **Session-level wall-clock and model switching.** Not measured.

## Scope of this baseline

Two sessions are the minimum the acceptance criterion asks for. They do not establish a typical share. The parent share remains unknown for both sessions, so this baseline records the measurable cost drivers and the coverage gaps. It does not claim how much of the total spend the orchestrator causes.

The ranked drivers are the to-do list for the next increment (Issue #2435). Changing orchestrator behavior is out of scope here.
