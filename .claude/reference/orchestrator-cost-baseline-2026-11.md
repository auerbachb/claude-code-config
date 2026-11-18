# Orchestrator cost baseline — 2026-11 (Issue #2434)

Point-in-time measurement of the parent thread's share of `/pm` session tokens, taken with `.claude/scripts/orchestrator-cost-report.sh --json`. Figures are tokens. Every figure below is a derived aggregate. No session IDs, prompts, tool arguments, paths, repository names or account identifiers are recorded here.

## Method

- Two completed `/pm` sessions from 2026-11-16 were selected from the local skill-usage log. Both ran on the `claude-fable-5-2` parent model, confirmed from the main transcript's per-message model field.
- Parent figures come from the main transcript's assistant usage (sidechains excluded). Worker figures come from spend-telemetry rows with a worker `agent_id`, deduplicated by message identity.
- Labels: `known_subtotal` means at least one limitation applied. `complete_total` means no limitation applied. `unknown` means the field was not measured.
- The complete parent share needs both sides complete. The partial parent share is the parent's measured subtotal over the worker's measured subtotal. It is labelled `known_subtotal` and is never presented as complete. It is not an estimate of the missing part. Missing worker rows can only add to the denominator, so the partial share is an upper bound on the complete share.
- Turn classes use the precedence in `spend-telemetry-pipeline.md` §Orchestrator session report.

## Headline figures per session

| Measure | Session A | Session B |
|---|---|---|
| Parent model | claude-fable-5-2 | claude-fable-5-2 |
| Parent assistant messages | 509 | 535 |
| Parent tokens (4 fields, known_subtotal) | 265,711,131 | 275,551,601 |
| Worker tokens (4 fields, known_subtotal) | 698,069,979 | 227,781,862 |
| Workers observed | 48 | 26 |
| Partial parent share (`parent_share_known_subtotal`, label known_subtotal) | 27.6% | 54.7% |
| Complete parent share | unknown (`partial_data:unsupported_worker_row`) | unknown (`partial_data:unsupported_worker_row`) |
| Unsupported worker rows counted | 90 | 13 |
| Parent turns | 189 | 144 |
| Changed-nothing turns | 22 | 23 |
| Ambiguous turns | 4 | 2 |

Partial share reason, both sessions: `unsupported_worker_row`. Those rows are `SubagentStop` events with `unsupported:agent_transcript_file_missing`. Each names an agent ID that matches no worker transcript file and no worker usage row, so the worker side cannot be shown complete.

## Top cost drivers per session

Each driver shows its four-field sum, then fresh input, cached read and output. Cache write is in the sum but not in the split, so the three shown do not add to the sum.

Session A (parent 265,711,131; worker 698,069,979):

| Rank | Class | Turns | Sum | Fresh input | Cached read | Output |
|---|---|---|---|---|---|---|
| 1 | worker_result_handling | 121 | 176,656,493 | 648 | 175,884,030 | 270,030 |
| 2 | other | 43 | 74,531,929 | 312 | 73,856,399 | 139,707 |
| 3 | changed_nothing_checkin | 22 | 11,579,728 | 44 | 11,526,545 | 3,185 |

Session B (parent 275,551,601; worker 227,781,862):

| Rank | Class | Turns | Sum | Fresh input | Cached read | Output |
|---|---|---|---|---|---|---|
| 1 | worker_result_handling | 88 | 160,462,109 | 492 | 159,902,516 | 185,940 |
| 2 | other | 25 | 93,689,485 | 520 | 90,945,872 | 373,749 |
| 3 | changed_nothing_checkin | 23 | 16,813,846 | 46 | 16,764,814 | 2,077 |

Turn counts by class, session A: worker_result_handling 121, other 43, changed_nothing_checkin 22, user_reply 1, instruction_skill_load 2, data_gathering 0. Session B: worker_result_handling 88, other 25, changed_nothing_checkin 23, user_reply 5, instruction_skill_load 3, data_gathering 0.

## Cross-check: worker transcripts versus telemetry

- Session A: the 48 worker transcripts sum to the same 698,069,979 that the telemetry worker total gives.
- Session B: 21 top-level worker transcripts plus 5 workflow-subagent transcripts (26 workers, 1,102 distinct messages) sum to 229,704,463. Telemetry gives 227,781,862 over 1,089 messages, 13 messages short, a gap of 1,922,601 tokens. The report keeps telemetry as its worker source, so the session B worker figure is a lower bound on the transcript total.

## Cause of the earlier unmatched-call reading (session A, fixed)

Session A's transcript holds 67 distinct `Agent` tool calls. A pre-tool-use hook refused 19 of them (pause state lock-contended) before any worker started. The remaining 48 match the 48 worker transcripts and the 48 telemetry worker IDs. The report leaves refused calls out of the launch count, so `unmatched_agent_calls` no longer applies to either session.

## Known checks and limitations

- The launched-agent check compares counts of distinct Agent calls against distinct worker IDs. A nested worker could mask a missing one. Both sessions reconcile exactly. A per-call link is a follow-up.
- Session B's telemetry worker total is 13 messages short of its transcripts (see cross-check).

## What could not be measured (recorded as unknown)

- **Complete parent share.** Blocked by `unsupported_worker_row` in both sessions. Only the partial share above is reported.
- **Provider usage-page comparison.** Not performed here. It needs the account owner at the provider's page. Tracked in Issue #2439.
- **Dollar cost.** Not measured. The report reports tokens only.
- **Per-session Fable allowance.** Not visible from local data. Unknown.
- **Classification reliability beyond the ambiguity count.** Not separately measured.
- **Session-level wall-clock and model switching.** Not measured.

## Scope of this baseline

Two sessions are the minimum the acceptance criterion asks for. They do not establish a typical share. The ranked drivers are the to-do list for the next increment (Issue #2435). Changing orchestrator behavior is out of scope here.

## After-change measurement (Issue #2435)

The lean-orchestrator change (`lean-orchestrator.md`) is merged, but no after-numbers are recorded here yet: the two premium-model `/pm` sessions of five or more pipelines that the comparison needs could not be run from the isolated worktree that implemented it. They are measured after merge with the same report and added to this file, whichever way they come out.
