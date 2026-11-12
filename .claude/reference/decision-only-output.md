# Decision-only human output

Canonical human-facing output policy (Issue #1873). CLAUDE.md gives this policy precedence over older rule/skill/reference prose and embedded echo/report examples. A required host progress update still follows the host's instructions. This policy governs presentation, never authorization, safety gates, or machine interfaces.

## Notification decisions

| Situation | Human-facing default | Required record/action |
|---|---|---|
| Routine progress, successful check, launch or dispatch | Silent | Update existing issue/PR/session records and continue |
| Unchanged monitoring, first/resume tick, backoff, table age | Silent | Persist tick, digest, watermarks, cadence; retain script-side filtering |
| Board below limit after a refill evaluation | One line when occupied slots or reason counts change, including a verified `refill_missed` fault | Persist every census and keep unchanged notices and full boards quiet |
| Ordinary recoverable failure | Silent during authorized recovery | Preserve full failure capture and nonzero exit; repair/retry within existing bounds |
| Owner-only blocker, ambiguity, safety event, exhausted recovery or genuine stall | Immediate concise notice | State action, practical options/consequence, evidence; persist stop and resume state |
| Explicit status, summary, board or verbose request | Answer the requested scope | Render from existing records; tables are available on request |
| `/pm` standing status request | Report a changed active board every 30 minutes by default and immediately on a terminal outcome | Set `report_every_min: 0` to opt out or a positive value to change cadence. Use the existing PM turn, canonical board and exact report receipt |
| Completion of a user `/pm` invocation | One step receipt, after the immediate tick on a day arming invocation | Render recorded outcomes and flag missing ones. Internal ticks and probes stay silent. |
| Terminal completion | Minimal outcome; useful artifact link only | Preserve full verification in PR/issue/logs; emit clean merge line once |

A stopped pipeline must never disappear: when recovery ends, surface why and how it can resume even if the owner cannot fix the underlying service. Do not repeat an unchanged notice every tick. A materially changed blocker, failed notification, or a new required decision may notify again. Never silence a safety event merely because recovery is possible.

Use one or two concise sentences for an ask: “Choose A (effect) or B (effect) so work can resume. Evidence: [PR/issue/log].” Include time only when it affects that choice, such as a real deadline or reset time. No timestamp prefixes for ceremony. Scheduled PM reports cover the invoking repository. Ordinary recap tables, hourly board floors, file-write counters, refill announcements, and skill banners remain silent. Explicit requests for status remain immediate.

## Evidence and recovery

This policy does not alter stdout/stderr schemas, parser-required EXIT_REPORT/FIXPR footers, exit codes, CI artifacts, merge-gate missing sets, AC checkboxes, review findings, claim ownership, or monitor lifecycle. Machine reports remain complete between agents; only their redundant human-facing rendering is suppressed. Never redirect a failed gate to success or drop raw diagnostics to achieve silence.

Use existing structured results first: `ok`, `failed_tests`, `relevant_error`, `log_path`, gate missing sets, HEAD, and state paths. Keep full CI/review output in raw logs and structured AC/safety/resume records. A missing/unreadable/corrupt record is unknown, never success; refetch or stop under the existing gate contract. Preserve evidence paths across handoff; if an ephemeral path expires, refetch the named CI job/review or rerun the bounded check and record its new path. Do not claim an expired log is recoverable.

Read a cached PR bundle with a bounded `jq` projection for the immediate decision (HEAD, gate verdict, counts, IDs, URLs). Select finding bodies by specific ID/path only when fixing or replying. Do not `cat` an entire bundle or raw log merely to report success or discover a status already in JSON. On failure, use `relevant_error` then a targeted line range in `log_path`; expand when diagnosis requires it. Full logs remain available without entering every model context. Failure stderr retained by existing wrappers is machine evidence, not mandatory chat narration.

## Monitoring boundary and caller audit

Issue #1878 owns avoiding unchanged-tick model invocation. Keep its script-side digest/filter path and scheduling intact; do not add a summarizer model to decide to say nothing. Silencing text alone claims no inference or token savings.

- `/wrap`: persist the complete current-run recovery audit and last gate JSON in `.prs["<PR>"].wrap_sweep.recovery_audit` after each action, before continuing or exiting; failed writes stop recovery. Retain `pr-state.sh` bundle caching, gate JSON and per-iteration missing sets. Read selected fields before specific findings; preserve all post-merge sweep/AC state.
- `/fixpr`: save the latest snapshot in handoff `.fixpr_wait` before classification (HEAD, baseline, bundle path, observation time and complete wait verdict); a failed write cannot return clean. Retain bounded wait-state fields (`bots_pending`, `ci_pending`, `ci_failing`, `new_findings`, `head_moved`) and parser footers. Wait-loop diagnostic echoes go to evidence, not routine chat.
- `/babysit-pr`: retain fetch error handling (skip classification on empty state), gate exit codes, digest/cadence persistence, dispatch locks and exact teardown. T7 is an optional status rendering, not a per-tick notification.
- `/pr-monitor-and-manage`: persist `.pmm.watch_posture` (status, hold reason, launch/finish flags and observation time) before dispatch; clear ticks overwrite previous holds, and failed writes stop the tick. Compute/persist state and row digests even with no table; retain complete dispatch inputs. Status tables/reviewer engagement matrices render only on explicit request; owner asks need only relevant rows.
- `/pm` and `/subagent`: retain launch/queue/claim and handoff records. Keep explicit `/board` access. The scheduled PM report gate uses existing turns and never starts a model or watch for routine board freshness. Do not stamp a board render that did not occur.

No new proxy, universal interception, or optional compression tooling is introduced. Existing compact-result and PR-state contracts remain the foundation.


Runtime integration (Issue #1977): the silence detector, parent ceiling, PostCompact recovery and PMM Step5e apply this policy. The ceiling independently observes Agent artifacts; parent heartbeat freshness cannot hide unchanged child evidence. Investigate suspect/unknown notices; preserve ownership, generation, acknowledgment and watch lifecycle. Coverage and limitations: `bgwork-ceiling.md` §Child progress and coverage. Instruction-contract tests verify the emitted policy cases; they do not claim the hooks classify user intent or recovery state themselves.
