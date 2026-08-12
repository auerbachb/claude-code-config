# Spend / Thread-Type Telemetry Pipeline (issue #710)

**Issue:** [#710](https://github.com/auerbachb/claude-code-config/issues/710) (spend/thread-type telemetry pipeline — thread vs inline subagents)

**Date:** 2026-08-12

**Related:**
- [`pm-routing-audit-2026-07.md`](pm-routing-audit-2026-07.md) — FU-1 that motivated this pipeline; §"Re-running AC1 against real spend" for audit methodology
- [`harness-model-audit-2026-06.md`](harness-model-audit-2026-06.md) — FU-5 that this work closes
- [`skill-usage-durability.md`](skill-usage-durability.md) — storage-model precedent
- [`token-measurement-baseline-2026-08.md`](token-measurement-baseline-2026-08.md) — complementary per-repo ccusage baseline (Issue #781)

**Observational-only notice:** Per `safety.md` §"Anthropic Quota & Spend Authority", all data produced by this pipeline MUST NOT gate any agent decision, spending estimate, or quota check. The pipeline is read-only audit infrastructure.

---

## What this pipeline does

Adds lightweight automatic telemetry that tags each agent execution as **thread** (a new session / standalone coding thread) vs **inline** (an inline `Agent`-tool subagent), capturing model tier and best-effort token counts. This enables routing audits to work from real execution-type data instead of the invocation-count proxy that `pm-routing-audit-2026-07.md` had to use.

## Log Schema

**File:** `~/.claude/spend-telemetry.log`

**Format:** append-only, one tab-separated line per event.

```
ISO8601Z  event_type  exec_type  model_tier  agent_type  session_id  agent_id  tokens
```

| Field | Values | Notes |
|-------|--------|-------|
| `ISO8601Z` | e.g. `2026-08-12T19:30:00Z` | UTC, written by `date -u +%FT%TZ` |
| `event_type` | `session_start` \| `subagent_stop` | Source event |
| `exec_type` | `thread` \| `inline` | `thread` = standalone session; `inline` = Agent-tool subagent |
| `model_tier` | `opus` \| `sonnet` \| `haiku` \| `fable` \| `unknown` | Lowercase family name |
| `agent_type` | e.g. `phase-a-fixer`, `pm-worker`, `session` | For `session_start`: always `session` |
| `session_id` | session UUID or `unknown` | Payload → `$CLAUDE_SESSION_ID` → `unknown` |
| `agent_id` | agent UUID or empty | For `session_start`: always empty |
| `tokens` | integer or empty | Empty = runtime did not expose token data (common case) |

**Forward-compatibility:** consumers should tolerate additional trailing fields.

## Two Capture Paths

| Hook | Event | exec_type | Captures |
|------|-------|-----------|---------|
| `spend-session-tracker.sh` | `SessionStart` | `thread` | New standalone sessions (startup only; compact/resume/clear skipped) |
| `spend-subagent-tracker.sh` | `SubagentStop` | `inline` | Each inline Agent-tool subagent completion |

Both hooks source `lib/spend-telemetry-recorder.sh` and call `record_spend_telemetry()`, which is the sole writer of `spend-telemetry.log`.

## Reliability Caveats

### Token spend: best-effort only

Token/cost data are **not exposed to hooks**. The runtime does not surface per-turn token counts to `SessionStart`, `SubagentStop`, or any other hook event. The `tokens` field is populated by a best-effort parse of the agent transcript file (`agent_transcript_path` in the `SubagentStop` payload); this parse is optional and returns empty on any failure. **Do not interpret an empty `tokens` field as zero spend.**

The `spend-telemetry-report.sh` report renders token columns as `n/a` precisely when no token data was recorded, to prevent "no data" from being misread as "no cost."

### Model tier: derived, not measured

For inline runs (`subagent_stop`), model tier is derived from the `agent_type` frontmatter (`model:` field in `.claude/agents/<agent_type>.md`). It is not measured from the runtime. If an agent definition changes its `model:` field without an immediate hook restart, the logged tier will be stale until the next session.

For thread runs (`session_start`), model tier is read directly from the `model` field in the `SessionStart` payload — this is the actual session model, so it reflects the true runtime value.

### Thread classification: approximation

`SessionStart` fires on `startup`, `resume`, `clear`, and `compact`. The hook skips all sources except `startup` (treating an absent `source` as startup for backward compatibility). This means:

- A `startup` source is a genuinely new session, which may be a standalone coding thread, a PM orchestration session, or the main interactive session.
- The pipeline cannot distinguish a `/subagent`-launched Phase A session from the user's main interactive session — both appear as `thread`.
- Use the `agent_type` column (which reads `session` for all thread records) alongside `skill-usage.log` (which captures `/pm`, `/subagent` skill invocations) to refine attribution.

### Pre-install history: proxy only

Records only exist from the point this pipeline was installed. Pre-install history remains proxy-only, exactly as described in `pm-routing-audit-2026-07.md` §Phase 1 Task 1. The audit's pre-#613 numbers cannot be reconstructed from this log.

### Agent-tool subagents before this pipeline

Inline `Agent`-tool subagents previously wrote no telemetry line at all (`skill-usage.log` captures only Skill-tool invocations). The `SubagentStop` hook now closes that gap going forward; the pre-install inline share is still understated.

## Reporting

```bash
# All-time summary
bash .claude/scripts/spend-telemetry-report.sh

# Last 30 days only
bash .claude/scripts/spend-telemetry-report.sh --days 30

# Help
bash .claude/scripts/spend-telemetry-report.sh --help
```

The report emits:
- All-time thread-vs-inline breakdown (event counts, per-model-tier distribution, token sums where present)
- Optional windowed table (`--days N`)
- Inline agent-type inventory

## Re-running AC1 from pm-routing-audit-2026-07.md — execution-type attribution

*This section partially fulfils FU-1 AC: it provides execution-type attribution and model-tier distribution, replacing the invocation-count proxy. Full comparative token spend (thread vs inline) requires a thread token source; see the caveat below.*

**Old method (proxy):** Count sessions with coding-lifecycle skill calls (`start-issue`, `fixpr`, `wrap`, …) in `skill-usage.log` and compare to sessions with `/subagent` calls. Tells you *invocation counts*, not model tier or token spend.

**New method (execution-type attribution):**

```bash
# 1. Collect telemetry (automatic — no action needed)
# 2. Run the report
bash .claude/scripts/spend-telemetry-report.sh --days 30

# 3. Read the "All-time thread-vs-inline breakdown" table:
#    - thread row = standalone coding sessions
#    - inline row = Agent-tool subagent executions (pm-worker, phase-a/b/c)
#    - model_tier columns show distribution across opus/sonnet/haiku
#    - tokens column shows inline spend where the runtime exposed token data
```

**What to compare:** In a healthy inline-first routing regime (post-#613), the `inline` row should grow relative to the `thread` row over time, and the `pm-worker`/`phase-*` agent types should dominate the inline inventory. A `thread`-heavy split in the report flags that work is still entering the standalone-thread path rather than flowing through PM's inline pipeline.

**Token spend caveat:** `SessionStart` does not expose token data to hooks (the runtime provides no usage in that event). Only `SubagentStop` attempts transcript token extraction. The `tokens` column therefore shows inline subagent spend (where available) but is always empty for thread events. Comparative thread-vs-inline token spend requires a thread token source (e.g. a SessionStop hook with transcript access) before AC1's spend comparison can be answered with real numbers rather than event counts.

**Limitation:** Because thread classification cannot distinguish a `/subagent`-launched Phase A session from the main interactive session, combine the report with `skill-usage-report.sh` (which shows `/pm`, `/subagent`, `/start-issue` counts) for the same window to cross-validate the split.
