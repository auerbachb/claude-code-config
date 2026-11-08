# Terminal human-output enforcement decision

Issue #1665; evaluated against the policy landed for Issue #1873 and the runtime integration for Issue #1977.

## Decision

Keep human reply deduplication governed by `decision-only-output.md` and `final-wrapup-format.md`. Do not add a checked emitter, per-task emission ledger, transcript-scanning Stop hook, or template-count lint for this purpose. This is a documentation-only decision, not an exactly-once delivery guarantee.

At the terminal state of the requested work, provide the minimal useful outcome. A clean merge line can already be the complete outcome; do not require another recap. A required host terminal reply, explicit summary request, new actionable blocker or safety event still receives its appropriate response. A merged PR within an ongoing backlog does not itself terminate the entire user request.

## Evidence and rationale

Issue #1665 followed a review of PR #1662 and its older fixed-slot wrap-up format. Issue #1873 replaced that template and ceremony-only timestamp with decision-only output. The current end-of-task reference already delegates to that policy and permits a host-required terminal reply. The historical12603-word corpus count is context for the earlier deferral, not a current measurement or a reason to restore the old format.

Existing machine state is useful evidence, but no single existing field establishes delivery of one human terminal reply for an arbitrarily scoped user request. A request may span multiple issues, survive compaction or resume after a blocked state. PR/pipeline terminal states do not by themselves identify that larger boundary or record whether the host displayed a reply. Marking an emission before delivery can suppress a missing outcome; marking it afterward can still permit duplicates after interruption.

The configured Stop hooks in `global-settings.json` cover silence acknowledgment, background-work ceilings, trust repair, dirty-main warnings, skill-usage capture and question-leak warnings. They do not supply a transaction combining human-message delivery and a task completion marker. The runtime integration for Issue #1977 preserves liveness/ownership evidence and actionable notices; it is not a human-reply delivery protocol.

`verify-exit-report-block.sh` validates required EXIT_REPORT fields and block shape from stdin. It does not establish once-only emission across a task lifecycle. Machine report shape is a separate contract from free-form human output. An extra recap is usually presentation noise; a missed blocker, premature completion claim or incorrect issue closure is a correctness problem and must retain its existing checks and recovery.

## Options evaluated

| Option | Assessment | Verdict |
|---|---|---|
| Checked human-output emitter | Would need adoption at every emitting host/agent boundary, explicit request identity and delivery acknowledgment. Rendering a template alone cannot prove one delivered reply. | Do not build now. |
| Per-task emission ledger | Existing PR/pipeline records do not define the complete user-request boundary. New state would require ownership, retries, reset/resume semantics and a delivery protocol. | Do not add an emission marker. |
| Stop hook scanning transcript tails | Text cannot reliably distinguish a requested summary, useful merge line, required host reply, quoted example or premature recap. Tail truncation and compaction add ambiguity; blocking could hide useful outcomes. | Reject transcript-pattern enforcement. |
| Static template-count lint | Counts definitions, not messages delivered at runtime; the current policy intentionally has no mandatory fixed-slot template. | Reject as an answer to once-per-task delivery. |
| Documentation-only reply discipline | Matches the current flexible policy without new startup text or a false delivery guarantee. Depends on agent compliance and allows occasional redundant prose. | Adopt with the limitations below. |

## Limits and reconsideration triggers

This decision neither proves duplicate replies impossible nor excuses a false completion claim. Preserve CI/review/AC gates, native merged/closed verification, issue ownership, session/handoff state, Stop/ceiling behavior and parser-required EXIT_REPORT/FIXPR footers. Human-output deduplication must never turn a failed check into success or hide an unresolved required action. Issue-closure defects need investigation at their actual completion/closure boundary, independently of recap wording.

Reconsider machinery if recorded incidents show material harm attributable to duplicate or missing terminal human messages, or if the host exposes a stable request identity, terminal-event signal and acknowledged delivery/idempotency interface. A new proposal should specify resume/retry and multi-PR behavior, distinguish explicit summaries and actionable notices, and demonstrate negative controls for suppressed required output as well as duplicate output. Review the current corpus budget only if that proposal adds auto-loaded text; this decision adds none.

## Explicitly rejected

Restoring the old fixed-slot recap; treating each PR merge as completion of a continuing backlog; treating transcript wording as proof of task completion; weakening issue-closure or machine-report gates to obtain quieter output; and claiming a static lint or an emission flag guarantees exactly-once delivery.

## References

- `decision-only-output.md` — canonical presentation policy and evidence/monitoring boundary.
- `final-wrapup-format.md` — current end-of-task behavior.
- `bgwork-ceiling.md` and `../hooks/bgwork-ceiling-guard.sh` — liveness evidence and coverage.
- `session-state-schema.json` — existing orchestration state, not human-delivery acknowledgment.
- `exit-report-format.md` and `../scripts/verify-exit-report-block.sh` — machine-report contract and verifier.
- [Issue #1665](https://github.com/auerbachb/claude-code-config/issues/1665), [PR #1662](https://github.com/auerbachb/claude-code-config/pull/1662), [Issue #1873](https://github.com/auerbachb/claude-code-config/issues/1873), [Issue #1977](https://github.com/auerbachb/claude-code-config/issues/1977).
