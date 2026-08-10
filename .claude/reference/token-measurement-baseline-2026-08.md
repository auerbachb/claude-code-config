# Per-Repo Token Measurement Baseline — August 2026

**Issue:** [#781](https://github.com/auerbachb/claude-code-config/issues/781) (FU-6: `/context` + ccusage baseline, MCP prune list, `permissions.deny`)

**Date:** 2026-08-10

**Related precedent:** [`token-efficiency-audit-2026-07.md`](token-efficiency-audit-2026-07.md) (FU-6 source, MCP schema cost figures, `permissions.deny` rationale), [Issue #710](https://github.com/auerbachb/claude-code-config/issues/710) (spend/thread-type telemetry pipeline — in-flight; data from there will supersede the manual figures here once available), [`harness-model-audit-2026-06.md`](harness-model-audit-2026-06.md) (static-evidence convention this doc follows)

**Scope guard:** This document covers per-repo context-floor measurement, MCP prune inventory, and junk-dir read-denial. It is NOT Issue #710's spend/thread-type telemetry pipeline and does NOT build a new per-session settings-sync mechanism.

---

## Living-Tracker Instructions

**Re-run and append each measurement cycle** (à la `skill-repo-diff.md`):
1. Run the ccusage wrapper: `.claude/scripts/ccusage-baseline.sh --json`
2. Capture `/context` output manually (see MANUAL CAPTURE below)
3. Append a dated row to the [Baseline Table](#baseline-table)
4. Re-classify MCP servers if the installed set changes

**Gap acknowledgment:** Until Issue #710's telemetry pipeline ships, context-floor figures come from the manual `/context` procedure below. The `ccusage` figures are accurate at run time; the `/context` figures depend on the session configuration at capture time.

---

## Reproducible Measurement

### MANUAL CAPTURE — `/context` Context Floor

> **This section requires interactive capture.** `/context` is a Claude Code slash command that prints the current session's context breakdown. It cannot be scripted.

**Procedure (run during an active Claude Code session):**

1. Open a Claude Code session in this repo.
2. Run `/context` in the chat.
3. Record the following sections from the output:

| Section | What to record |
|---------|---------------|
| **System prompt** | Token count shown |
| **System tools** | Token count shown |
| **MCP tools** | Token count per server + total |
| **Memory / CLAUDE.md** | Token count shown |
| **Agents** | Count and token footprint if shown |
| **Messages (context window used)** | Token count + percentage |

4. Paste the captured numbers into the [Baseline Table](#baseline-table) under a dated row.

**Reference values from token-efficiency-audit-2026-07.md:**
- Rule corpus: ~12K words (always-loaded CLAUDE.md + 18 unscoped rules)
- Community-documented floor before "hi": 20–30K tokens
- MCP schema cost estimate: ~1K+/tool; 10–20K tokens/server; 55K observed for 5 servers
  (source: token-efficiency-audit-2026-07.md §Quantitative benchmarks, tier B)

### Scripted Capture — ccusage Spend Baseline

```bash
# Human-readable summary (active block + window total)
bash .claude/scripts/ccusage-baseline.sh

# Machine-readable JSON (for the table below)
bash .claude/scripts/ccusage-baseline.sh --json

# Last 3 days only
bash .claude/scripts/ccusage-baseline.sh --recent

# Filter from a specific date
bash .claude/scripts/ccusage-baseline.sh --since 20260801
```

Exit codes: `0` data found, `1` no blocks in window, `2` usage error, `3` ccusage not found, `4` invocation error.

**Tip:** If `ccusage` is not installed, the script exits 3 with install instructions. Install via:
```bash
npm install -g ccusage
# or: npx ccusage@latest --help
```

---

## Baseline Table

> **Dates are measurement timestamps, not averages.** Each row captures a snapshot at a specific session. Context floor varies by active MCP servers and loaded skills.

| Date | Context floor (tokens) | MCP schema share (tokens) | Active block cost (USD) | Window cost (USD) | Window tokens | Notes |
|------|----------------------|--------------------------|------------------------|-------------------|---------------|-------|
| 2026-08-10 | PENDING MANUAL CAPTURE | See MCP Inventory below | run `ccusage-baseline.sh` | run `ccusage-baseline.sh` | run `ccusage-baseline.sh` | Initial baseline; Issue #710 telemetry not yet available |

**How to fill in the context floor:** Run `/context` during a session in this repo, copy the token counts from the System prompt + System tools + MCP tools + Memory sections, sum them, and enter here.

---

## MCP Server Inventory and Prune List

> **Classification method:** each server is checked against references in `.claude/rules/*.md` and `.claude/skills/*/SKILL.md` for actual tool invocations (`mcp__<server>__*`). Servers with no harness references are prune candidates for this repo.

### Installed MCP Servers

**Plugin-based servers** (global scope — configured in `~/.claude/settings.json` via `enabledPlugins`):

| Server key | Plugin | Referenced in harness | Classification |
|-----------|--------|----------------------|----------------|
| `graphite@claude-code-graphite` | graphite CLI plugin | Graphite CLI (`graphite-app[bot]`) as supplemental reviewer in `cr-github-review.md` and `codeant-graphite-supplemental.md` | **KEEP** — used in review chain |
| `graphite-mcp@claude-code-graphite` | graphite MCP plugin | No `mcp__graphite*` tool calls found in rules/skills | **PRUNE CANDIDATE** — MCP schema loaded but no tool calls; CLI path is sufficient |

**User-configured MCP servers** (in `~/.claude.json`):

| Server key | Referenced in harness | Classification |
|-----------|----------------------|----------------|
| `Neon` | No `mcp__Neon__*` calls in this repo's rules/skills | **PRUNE CANDIDATE for this repo** — may be used in other repos; project-level opt-out is the right mechanism |

**Built-in / platform MCP servers** (loaded automatically by Claude Code):

| Server | Tool prefix | Referenced in harness | Classification |
|--------|------------|----------------------|----------------|
| Claude Browser | `mcp__Claude_Browser__*` | `safety.md` capability-discovery rung 4; `cr-github-review.md` fallback | **KEEP** — used in browser capability ladder |
| CCD Session | `mcp__ccd_session__*` | `monitor-mode.md`, `subagent-orchestration.md` (spawn_task, dismiss_task) | **KEEP** — orchestration primitive |
| Claude-in-Chrome | `mcp__claude-in-chrome__*` | `safety.md` (logged-in-session browser rung) | **KEEP** — alternate browser rung |
| Scheduled Tasks | `mcp__scheduled-tasks__*` | `scheduling-reliability.md` (not used — explicitly declined per #827) | **KEEP LISTED, NOT USED** — harness intentionally uses Monitor instead |

### MCP Disable Paths

**Path A — Global plugin opt-out** (for plugin-based servers like `graphite-mcp@claude-code-graphite`):

Edit `~/.claude/settings.json` and set the plugin's `enabledPlugins` entry to `false`:
```json
"enabledPlugins": {
  "graphite-mcp@claude-code-graphite": false
}
```
This disables the plugin globally. `setup.sh` seeds the initial value from `global-settings.json`; changes to `enabledPlugins` persist in `~/.claude/settings.json`.

**Path B — Project-scoped `.mcp.json`** (for future repo-defined MCP servers):

For MCP servers defined at the project level (not plugin-based), use the project `.mcp.json` approval mechanism:
- `disabledMcpjsonServers` — list of server names to disable for this project
- `enabledMcpjsonServers` — allowlist (if set, only listed servers are enabled)

No `.mcp.json` file exists in this repo currently. Current MCP servers are all plugin-based (global) and require Path A for per-server opt-out.

**Recommendation:** Disable `graphite-mcp@claude-code-graphite` globally if the Graphite MCP adds no active tooling to sessions in this repo. The Graphite CLI (`graphite@claude-code-graphite`) is independent and should remain enabled.

### MCP Schema Cost Estimate

From `token-efficiency-audit-2026-07.md` §Quantitative benchmarks (tier B evidence):
- ~1K+ tokens per tool definition
- ~10–20K tokens per MCP server (all its tools combined)
- ~55K tokens observed for a 5-server session

**Tool Search Tool** (Claude Code built-in): defers MCP schemas until needed, cutting schema overhead by ~85% (77K→8.7K tokens observed). Already available in this harness — no additional setup required.

---

## `permissions.deny` Junk-Dir Blocks

> **Note on syntax:** `permissions.deny` follows the same `"Tool(pattern)"` format as `permissions.allow` in `global-settings.json`, inferred from the existing allow array. The `A`-tier citation in `token-efficiency-audit-2026-07.md` points to Claude Code docs; the deny array below is consistent with that format. If Claude Code's actual runtime behaviour differs, adjust the patterns and update this doc.

### Rationale

`.claudeignore` is **advisory-only** — Claude Code respects it for file suggestions but does not enforce read boundaries. `permissions.deny` adds enforceable read restrictions that prevent reads from high-noise directories (node_modules, build outputs, caches) that bloat tool results and context window without adding useful content.

### Propagation

The `deny` array is added as a new sub-key under `permissions` in `global-settings.json`. Since `setup.sh` uses a seed-missing-only merge (one level deep), this brand-new sub-key seeds into `~/.claude/settings.json` on the next `bash ./setup.sh` re-run — without disturbing existing `allow` or `defaultMode` values.

**SETUP CAVEAT:** The `deny` block does NOT propagate automatically. It reaches `~/.claude/settings.json` only on a manual `bash ./setup.sh` re-run. There is no per-session auto-sync for non-hook settings.

### Deny Array (in `global-settings.json`)

```json
"deny": [
  "Read(**/node_modules/**)",
  "Glob(**/node_modules/**)",
  "Grep(**/node_modules/**)",
  "Read(**/.git/objects/**)",
  "Glob(**/.git/objects/**)",
  "Read(**/dist/**)",
  "Glob(**/dist/**)",
  "Read(**/build/**)",
  "Glob(**/build/**)",
  "Read(**/.venv/**)",
  "Glob(**/.venv/**)",
  "Read(**/__pycache__/**)",
  "Glob(**/__pycache__/**)",
  "Read(**/.tox/**)",
  "Read(**/.mypy_cache/**)",
  "Read(**/.pytest_cache/**)",
  "Read(**/.ruff_cache/**)",
  "Read(**/.next/**)",
  "Glob(**/.next/**)"
]
```

**Adjusting the deny list:** Users can remove entries from `~/.claude/settings.json` directly. To re-seed after removing, run `bash ./setup.sh` again — it will not re-add entries already present, but a removed entry will not reappear automatically.

---

## Follow-Up Items

- [ ] **FU-6a (this issue):** Capture first manual `/context` reading and fill in the Baseline Table
- [ ] **FU-6b:** Re-measure after disabling `graphite-mcp@claude-code-graphite` to quantify the schema savings
- [ ] **FU-6c:** Once Issue #710 telemetry is live, replace manual context-floor rows with automated data and retire the manual procedure
- [ ] **FU-6d:** Re-evaluate Tool Search Tool opt-in — check if the harness currently enables deferred MCP schemas and measure impact
