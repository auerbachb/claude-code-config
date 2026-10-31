# Spend Telemetry Pipeline

**Issues:** [#710](https://github.com/auerbachb/claude-code-config/issues/710) introduced the recorder; [#1877](https://github.com/auerbachb/claude-code-config/issues/1877) repairs model attribution and usage coverage. This is read-only audit infrastructure.

**Safety:** Telemetry is observational only. It never gates work, estimates quota, or adds estimated cost to an authoritative budget control. No transcript text, prompts, code, task descriptions, credentials, or tool arguments are persisted.

## Current schema and sources

The single writer is `.claude/hooks/lib/spend-telemetry-recorder.sh`; it appends to `~/.claude/spend-telemetry.log`. The reader supports legacy 8-column rows and schema-v2/v3 rows in the same append-only TSV file.

| Hook | Supported metadata used | What it records |
| --- | --- | --- |
| `SessionStart` | `session_id`, optional active `model`, `cwd`, optional `agent_type` | Actual session model with `session_start.model` provenance; missing model remains unknown. Resume/clear/compact do not add a new session-start event. |
| `SessionEnd` | `session_id`, `transcript_path`, `cwd`, `reason` | Assistant-message identifiers, timestamps, actual model, and usage components from the main transcript. |
| `SubagentStop` | `session_id`, `cwd`, `agent_id`, `agent_type`, `agent_transcript_path` | The same assistant-message metadata from the subagent's own transcript. The parent transcript is not reread here. |
| `TaskCreated` / `TaskCompleted` | task ID, session ID, optional actor agent ID, cwd | Lifecycle rows only. The actor creates/completes the task; it is not proof of assignment to that worker. Subject and description are discarded. Completion is not verified acceptance. |

Claude Code's [Hooks reference](https://code.claude.com/docs/en/hooks) defines these hook fields. The locally installed CLI during the #1877 repair was `2.1.312`. Hooks do not expose token totals or billed cost directly. Transcript parsing accepts only assistant metadata: `id`/`uuid`, `timestamp` (including its original fractional precision), `sessionId`, `requestedModel`, `model`, and nested `usage` fields. A metadata-only inspection of installed-runtime transcripts confirmed these fields and repeated provider message IDs; message content was neither emitted nor retained. Session identity resolves from the payload, then `CLAUDE_CODE_SESSION_ID`, then `CLAUDE_SESSION_ID`; unresolved placeholders and literal default/unknown values never establish a join. Transcript `sessionId` is a supported fallback when both hook and environment lack a real ID.

The installed CLI's event catalog includes both `TaskCreated` and `TaskCompleted`. Compatibility also depends on the actual registrar: `register-hooks.py` now retains every canonical event for a shared hook script, rather than pruning all but one. An isolated temp-HOME CLI test installs the real repository manifest twice and verifies that `spend-task-tracker.sh` remains registered exactly once under each lifecycle event and `spend-session-tracker.sh` under both `SessionStart` and `SessionEnd`, with no second-run rewrite. Synthetic update tests also verify stale-event cleanup, legacy path migration, and preservation of custom timeouts, arguments, and unmanaged hooks. This establishes declaration and installer compatibility; it is not evidence of live event capture or deployment to the user's settings.

### Schema v3 columns

The first eight fields retain the legacy contract:

```text
timestamp  event_type  exec_type  model_tier  agent_type  session_id  agent_id  tokens
```

Schema-v2 adds these trailing fields:

```text
schema_version  event_key  repo_root  phase  requested_model  requested_source
actual_model  actual_source  input_tokens  output_tokens  cache_read_input_tokens
cache_creation_input_tokens  cost_usd  cost_source  task_id  lifecycle
transcript_scope  usage_source
```

Schema v3 adds a metadata-only `evidence_json` field. Transcript and task rows store a GitHub repository slug when it is available from the local `origin` remote. Explicit correlation rows store the supplied issue/PR/task identifiers, capture source, merge-gate head SHA, PR head SHA, squash merge SHA, and the bounded GitHub PR state/review/check snapshot. The field never contains descriptions, review text, code, or transcript content.

`requested_model` from the transcript envelope uses `transcript.requestedModel` provenance and takes precedence over a frontmatter fallback. `requested_model` from agent frontmatter means **definition default only**, tagged `agent_frontmatter_default`; it is not proof of the model requested for a particular spawn. `actual_model` comes only from the runtime payload or assistant transcript metadata. A runtime override therefore remains visible as a different actual model. General-purpose workers and custom agents without model frontmatter can still have an actual transcript model; their requested default stays unavailable.

`event_key` is the provider message ID (`message.id`) or transcript UUID when present; otherwise it is a source-scoped metadata hash used only for replay deduplication. Rows without a stable ID/UUID remain in raw telemetry, but the report excludes them from unique provider-message totals and labels their usage unallocated because it cannot prove whether a parent/child mirror is the same response. `requestId` is not treated as a unique message identity. A hashed cursor under `~/.claude/spend-telemetry-cursors/` stores byte offset, device/inode, and a hash of the last complete record's metadata. Private cursor files also retain the trusted transcript path and source identifiers, including session and repository identity, with directory/file permissions `0700`/`0600`; this metadata never enters the TSV log or report. An explicit child resume reuses that saved identity and does not substitute the reporting process session or working directory. Replacement, truncation, or changed boundary metadata resets the scan. Incomplete final records are retried. Scans checkpoint every 128 records under a cursor lock and append through the shared log lock; lock waits are bounded. The parser budgets 20 seconds for a main transcript and 2 seconds for a child transcript inside the hook timeout. A `transcript_scan` status marks complete vs pending/partial observed coverage.

A crash after append but before cursor advancement can replay source rows. If the shared log lock remains busy for 250 ms, hooks atomically spool each metadata row to private `~/.claude/spend-telemetry-pending/` files before advancing a transcript cursor. Spool files are flushed before the cursor moves. An explicit refresh selects a fixed batch of at most 256 queued rows and scans at most 4 MiB / 2 seconds of the log per invocation. A private `0600` checkpoint persists the byte offset, file identity, boundary fingerprint, and matched row fingerprints, so a large log makes progress across refreshes. Rotation, truncation, and boundary changes invalidate the scan; partial log tails remain pending until complete. The checkpoint remains at the pre-append EOF until rows are fsynced and spool files removed, so a crash after append can recognize the appended tail on replay. Queued rows are never removed before a durable log write or exact-row match has been fsynced.

The ordinary report is read-only and exposes pending write/child-source counts; `spend-telemetry-report.sh --resume-pending` explicitly drains writes and resumes child cursors with one shared 20-second work budget. Child selection rotates through at most 128 cursor paths per refresh using a private durable queue position, including invalid/completed/unavailable entries, so an incomplete prefix cannot starve later children. A queue lock prevents concurrent refreshes from regressing that position. Status inspection is bounded to 4,096 cursors / 2 seconds; an incomplete count is reported as unknown. Directory discovery/sorting and filesystem sync latency are outside the parser/subprocess budget.

The report deduplicates within session/repository/worker/transcript scope and counts a parent/child mirror with the same stable message ID/UUID once in usage totals. Each usage field retains its own original observation timestamp and source revision/byte position through both merge stages; later original timestamps win across sources, and source file modification time plus byte position orders equal/missing timestamps within the same source. This permits sparse enrichment and downward corrections, including zero, without treating numeric maxima or log append order as provider truth. Conflicting values with no provable newest observation remain unavailable, reduce the field denominator, and are explicitly labeled partial usage. Both raw sources remain in the log; an explicit child source supplies worker attribution. Rows lacking a stable ID/UUID are excluded from usage sums and reported as unidentified observations, never silently counted as separate provider messages. Unknown sessions cannot establish cross-transcript identity. Cursor filenames and boundary hashes expose neither IDs nor transcript content.

### Explicit issue/PR correlation

`spend-telemetry-link.sh` is called best-effort by `/start-issue` after a real runtime session claims an issue and by `/wrap` after its merge gate and acceptance checks pass. The issue-only event binds supplied session ID, repo slug, and issue ID. The post-merge event makes one `gh pr view` call with a 10-second subprocess timeout and a 64-KiB metadata response cap (CLI projection excludes commit messages and review bodies), validates the PR's explicit closing-issue reference, and records merged state, review decision, current check rollup, and commit count. `/wrap` passes the structured successful merge-gate result (`met:true`, no missing blockers, zero failing/in-progress CI, zero blocking review threads) and full `head_sha`; verification requires that SHA to match GitHub's merged PR `headRefOid`. The squash `mergeCommit.oid` is stored separately and is not treated as a reviewed head. This binds review/check evidence to the exact pre-merge code while handling squash merge SHA differences. Hooks never make network calls. A missing session ID remains `unknown`; the report can connect an issue-only session row to PR evidence only when exact repo+issue identifies one PR. Multiple PRs for the same repo+issue remain ambiguous.

The report joins transcript usage by exact session+repository slug. Task-level usage additionally requires an explicitly supplied task and worker ID plus a matching session/repository/task `TaskCompleted` row. A lifecycle hook actor alone never implies assignment. Multi-PR sessions without a unique worker allocation, workers reused across PRs, or workers linked to multiple tasks retain unknown usage allocation rather than assigning all their messages to each task. Verified completed tasks show available/observed denominators and sums for input/output/cache, with cost unavailable. A task counts as verified only when that task completion joins to explicit PR evidence recorded after the wrap merge gate and acceptance check, the recorded gate head matches the merged PR head, the PR is merged and closes the same issue, the structured gate result is valid, and its non-empty current check rollup is complete with nonblocking conclusions. `NEUTRAL`, `SKIPPED`, and `CANCELLED` follow the gate CI policy; the generic GitHub review-decision aggregate is recorded, not substituted for the actual gate policy. Missing gate SHA, stale/mismatched PR head, absent issue linkage, or incomplete checks leave the outcome unverified. Merge state alone is not a verified completion.

Existing `~/.claude/estimate-log.jsonl` records PR, issue, merge time, actual elapsed minutes, and `rounds`; it has no session/task key, so it can join usage only through an explicit repo+PR correlation row. Its `rounds` value counts PR commits, including pre-open commits; it is a commit-count proxy, not paid reviewer rounds or CI retries. `session-state.json` PR state has no session join key. GitHub review/check records are PR-scoped; the captured check rollup is a current snapshot, not historical rerun evidence. Exact paid review rounds, CI retries, and escalation reasons remain unavailable and unknown.

## Coverage and limitations

- Each usage component has its own available-record denominator. A missing field is blank and counts as unavailable; it never becomes zero. The legacy aggregate `tokens` field is populated only when all four usage components are present in the v3 record.
- Main-session usage is scanned by `SessionEnd`, with a 20-second parser budget inside its 30-second hook timeout. Child scans start at `SubagentStop`, with a 2-second parser budget inside its 5-second hook timeout; if the child scan is partial, the explicit `--resume-pending` report refresh can continue it from the private cursor. Refresh is bounded to 20 seconds total, so any remaining child cursor is still reported as pending/partial. A killed hook can leave the latest scan status stale. The transcript reader checkpoints incremental progress; if an append fails during lock contention, its rows are durably spooled before the cursor advances.
- No supported per-event billed-cost field is present in the hook or transcript fields used here. `cost_usd` stays blank and `cost_source` records the limitation. No price table or proxy cost is introduced.
- Task lifecycle IDs and actor IDs can be counted; only explicit correlation records associate an assigned worker with a task. The generic `TaskCompleted` event does not certify passing tests or issue acceptance. Issue/PR identity, retries, reviewer rounds, paid reviewer cost, CI reruns, and escalation reasons are not exposed by these hooks. They remain unknown in the report; no claim of cost per verified completed task is made without an explicit stable join and a verified outcome source.
- Elapsed time is the sum of observed spans between timestamped assistant messages, grouped by the same session/worker/phase/model. It is not total wall time for a task.
- Historical v1 rows are not reconstructed or backfilled. They preserve the model-tier values that were collected at the time, including `unknown`; their token totals remain `n/a` when absent.
- `/context` startup-floor capture and deferred-MCP schema measurement are tracked separately by open Issues [#1158](https://github.com/auerbachb/claude-code-config/issues/1158) and [#1160](https://github.com/auerbachb/claude-code-config/issues/1160). This telemetry repair does not replace either measurement, and their pending baseline rows are not superseded.

## Before/after coverage evidence

The production row is a 2026-10-31 UTC metadata-only log re-run; the issue snapshot differs slightly because the append-only log continues to grow. The schema-v3 row is a sanitized test fixture, not deployed production coverage; its raw cases include unknown model, partial usage, replay, incomplete JSONL, parent/child overlap, and task IDs reused across sessions.

| Evidence | Raw records | Model coverage | Legacy token rows | Input | Output | Cache read | Cache write | Billed cost |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Production legacy log, last 30 days | 5,593 events | 1,652 known / 3,941 unknown | 0/5,593 | unavailable in v1 | unavailable in v1 | unavailable in v1 | unavailable in v1 | unavailable |
| Sanitized v3 fixture | 7 source records; 6 unique provider messages | 5/6 known | 3/6 | 6/6 | 4/6 | 3/6 | 3/6 | 0/6 |

The production known-model denominator is `5,593 - 3,941 = 1,652`; v1 rows provide only an aggregate token field, not input/output/cache columns, so those component values are unavailable rather than zero. The fixture retains a parent/child source mirror but counts its provider response once. Tests assert raw columns and actual workflow fences, then report sums and denominators; they also cover sparse snapshots, runtime ID fallback, cursor replacement/truncation/partial tails, concurrent scans, malformed payloads, gate freshness, and ambiguous allocation. No production hooks were deployed or historical unknown rows reconstructed during this repair.

Run the local checks:

```bash
bash .claude/scripts/spend-telemetry-report.sh --days 30
bash .claude/hooks/tests/register-hooks.test.sh
bash .claude/hooks/tests/spend-telemetry-tracker.test.sh
bash .claude/hooks/tests/spend-telemetry-maintenance.test.sh
bash .claude/scripts/tests/spend-telemetry-report.test.sh
```

The report keeps legacy and v2 coverage separate, shows per-field denominators and usage by phase/actual model, and labels unsupported sources. In particular, `n/a` means no available data, not zero spend.

## History

Issue #710 originally added one `SessionStart` event and one `SubagentStop` event, with inline model tier inferred from agent frontmatter and a best-effort flat token field. That v1 schema remains readable for historical comparisons. Issue #1877 adds runtime/transcript model provenance, distinct usage components, end-of-session transcript capture, metadata-only task lifecycle IDs, replay deduplication in reports, and explicit coverage limitations.
