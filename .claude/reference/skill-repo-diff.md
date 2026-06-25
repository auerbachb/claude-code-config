# Skill-Repo Diff — Cross-Repo Pattern Harvest (living document)

Tracking artifact for issue [#417](https://github.com/auerbachb/claude-code-config/issues/417):
periodically diff this repo against popular Claude Code skill/config repos and
progressively pull in patterns that fit our way of working.

**This is an ongoing process, not a one-time import.** Each adopted pattern ships
as its own PR with a clear rationale, gets logged in the Import Log below, and is
recorded in a comment on #417. Deferred patterns stay in the backlog for future
cycles.

## Reference Repos Surveyed

| Repo | Shape | Relevance to us |
|------|-------|-----------------|
| [obra/superpowers](https://github.com/obra/superpowers) | 14 focused, workflow-agnostic discipline skills (TDD, debugging, planning, code review, worktrees) | **High** — overlaps our worktree + plan + review workflow; already installed as a Cursor plugin, so its skills are available at runtime but are **not** in our repo |
| [affaan-m/everything-claude-code](https://github.com/affaan-m/everything-claude-code) | ~270 skills (mostly polyglot/domain: per-language TDD, framework patterns, video/design), a large Node hook graph, MCP configs, multi-runtime scaffolds | **Selective** — most skills are language/domain-specific and out of scope; the hook graph and a few meta-skills have transferable ideas |

Survey date: 2026-06 (Opus 4.8 run). Re-survey each cycle; both repos move fast.

## How We Differ (adaptation constraints)

Our repo is **not** a general skill marketplace. It is a workflow-specific config
for a GitHub issue → CR plan → worktree → PR → review → squash-merge pipeline,
with phase A/B/C subagent orchestration. That shapes what fits:

- **Skills are mostly slash-commands** (`/fixpr`, `/wrap`, `/pm`) — operational
  procedures, not generic techniques. Descriptions double as command help.
- **Rules auto-load every turn** and live under a hard word budget (`rule-lint`).
  Generic discipline content competes for that budget, so it usually belongs in
  `.claude/reference/` (on-demand) or in CONTRIBUTING.md, not in a rule file.
- **Bash + Markdown**, not JS/TS. ECC's `stop:format-typecheck` /
  `console.log` / Biome hooks don't map onto our stack.
- **Superpowers is already a plugin.** Re-importing its skills verbatim would
  duplicate runtime-available content. We harvest the *judgment patterns* inside
  them and adapt, rather than copy the skills.

## Gap Analysis by Dimension

Fit labels: **direct fit** · **needs adaptation** · **doesn't fit our workflow**.

### 1. Skill library coverage

| Pattern (source) | We have? | Delta | Fit |
|---|---|---|---|
| `writing-skills` meta-skill — authoring discipline: description-as-trigger, match-form-to-failure, bulletproofing (superpowers) | Partial — CONTRIBUTING.md "Adding a New Skill" is purely mechanical (file paths, frontmatter fields) | We lack authoring *judgment* guidance | **needs adaptation** → harvested this cycle (see Import Log) |
| `systematic-debugging` / `root-cause-tracing` (superpowers) | No dedicated skill; available via plugin | Root-cause-before-fix discipline | doesn't fit (plugin covers it; not a workflow command) |
| `brainstorming` HARD-GATE before creative work (superpowers) | Partial — `issue-planning.md` + CR plan flow | Overlaps our planning flow; gate framing is novel | needs adaptation (P2 — evaluate vs issue-planning) |
| `verification-before-completion` (superpowers) | Partial — phase protocols + exit reports enforce evidence | Mostly covered by phase A/B/C | doesn't fit (duplicate) |
| Per-language TDD/verification skills, framework patterns, video/design (ECC) | No | Out of scope — we're a meta-config repo, not an app | doesn't fit our workflow |
| `skill-scout` / `skill-stocktake` / `skill-comply` — skill-library hygiene (ECC) | Partial — `audit-skill-usage.sh`, `skill-usage-report.sh` | We track usage but have no "does this skill still comply with our conventions" audit | needs adaptation (P2) |

### 2. Hook patterns

| Hook (source) | We have? | Delta | Fit |
|---|---|---|---|
| `pre:config-protection` — block edits to linter/formatter/CR config, steering agent to fix code not weaken config (ECC) | We have the **rule** "Never suppress linter errors" (`cr-local-review.md`) but **no enforcing hook** | Rule is advisory; a PreToolUse hook makes it mechanical | **needs adaptation** (P1 — strong candidate, next cycle) |
| `post:quality-gate` — run checks after edits (ECC) | No structured post-edit gate | Could lint shell/markdown after edits | needs adaptation (P2 — our CI + `coderabbit review` already cover much of this) |
| `session:start` bootstrap — load prior context + detect package manager (ECC) | `session-start-sync.sh` (worktree sync + hook registration) | Different scope; ECC also loads bounded prior context | doesn't fit (our scope is config sync, not context restore) |
| `pre:edit-write:gateguard-fact-force` — block first edit per file until investigation done (ECC) | No | Forces "read importers/schema before editing" | doesn't fit (heavy; friction-prohibitive for our doc-heavy edits) |
| `PreCompact` state save / `Stop` session metrics / cost tracker (ECC) | We have silence-detector + handoff files | ECC's are JS/metrics-oriented | doesn't fit (stack mismatch) |
| `stop:format-typecheck`, `console.log` warn, Biome (ECC) | No | JS/TS-specific | doesn't fit our workflow |

### 3. CLAUDE.md conventions

| Pattern (source) | We have? | Delta | Fit |
|---|---|---|---|
| Executive-summary CLAUDE.md + detail in rule files | **Yes** — already our model (CLAUDE.md ≤1,300 words, rules split out) | Parity | n/a (we lead here) |
| `using-superpowers` "1% chance a skill applies → you MUST invoke it" gate (superpowers) | Partial — skills auto-trigger by description | Aggressive skill-invocation framing | doesn't fit (our slash-command model differs) |
| Multi-runtime config mirrors (`.codex`, `.gemini`, `.cursor`, `.opencode`…) (both) | No — we target Claude Code + Cursor | Broad runtime portability | doesn't fit (scope/maintenance cost) |

### 4. Prompt-engineering patterns

| Pattern (source) | We have? | Delta | Fit |
|---|---|---|---|
| Description = *when to use*, NOT *what it does* (SDO research, superpowers) | **No** — most of our skill descriptions summarize the full workflow (e.g. `fixpr`, `start-issue`) | Workflow-summary descriptions can make agents follow the summary instead of reading the skill | **needs adaptation** → captured this cycle (see authoring patterns doc) |
| "Match the form to the failure" — prohibition+rationalization-table vs positive recipe vs structural slot vs conditional (superpowers) | No | Sophisticated guidance-design model we lacked | **needs adaptation** → harvested this cycle |
| Rationalization tables + red-flags lists for discipline rules (superpowers) | Partial — some rules use "Always/Ask first/Never" headers | We have prohibition headers but no rationalization-table convention | needs adaptation → captured this cycle |

### 5. MCP integrations

| Pattern (source) | We have? | Delta | Fit |
|---|---|---|---|
| `.mcp.json` with playwright / sequential-thinking / memory / github (ECC) | We have `mcp__*` permission wildcards but no documented server set | Our workflow is `gh`-CLI-driven, not MCP-driven | doesn't fit (low value for our PR workflow; revisit if we add E2E or browser testing) |

### 6. Utility scripts / tooling

| Pattern (source) | We have? | Delta | Fit |
|---|---|---|---|
| Consolidated pre/post Bash dispatcher (one hook fans out to many checks) (ECC) | We register hooks individually in `global-settings.json` | A dispatcher reduces per-tool hook overhead | needs adaptation (P2 — only worth it if our hook count grows) |
| Continuous-learning / pattern-extraction at Stop (ECC `stop:evaluate-session`) | Partial — `/lessons` skill + memory system | Ours is manual/on-demand; theirs is automatic | needs adaptation (P2) |
| Plugin-root resolver inlined in every hook command (ECC) | Our hooks resolve via `repo-root.sh` + worktree | Parity (different mechanism) | n/a |

## Prioritized Import Backlog

Criteria: (1) fills a genuine workflow gap, not a duplicate; (2) aligns with our
conventions; (3) low adaptation/maintenance cost; (4) high daily-use value.

- **P0 — done this cycle:** Skill/rule **authoring-judgment patterns** (SDO
  description rule, match-form-to-failure, bulletproofing) → distilled into
  `.claude/reference/skill-authoring-patterns.md`, linked from CONTRIBUTING.md.
  Doc-only, zero code risk, directly improves a repo whose whole job is authoring
  skills/rules. Source: superpowers `skills/writing-skills`.
- **P1 — next cycle (separate PR):** `config-protection` PreToolUse hook —
  mechanically warn/block edits to linter/formatter/`.coderabbit.yaml` severity
  config, reinforcing our existing "never suppress linter errors" rule. Source:
  ECC `pre:config-protection`. Needs a hook script + `global-settings.json`
  registration + a local payload test (per CONTRIBUTING "Adding a New Hook").
- **P2 — deferred (revisit, see below).**

## Deferred Patterns (P2 — revisit in future cycles)

- `post:quality-gate` post-edit lint hook for shell/markdown (overlaps CI + CR).
- Consolidated Bash hook dispatcher (only worth it if hook count grows).
- Automatic Stop-time lesson extraction (vs our manual `/lessons`).
- `skill-comply` / `skill-stocktake` — audit skills against our own conventions.
- `brainstorming` HARD-GATE framing — evaluate against `issue-planning.md`.
- MCP catalog (playwright/sequential-thinking) — revisit if we add browser/E2E.

## Explicitly Rejected (does not fit our workflow)

- Per-language TDD/verification/framework skills (ECC) — we're a meta-config repo.
- JS/TS-specific hooks: `stop:format-typecheck`, Biome, `console.log` warn (ECC).
- Multi-runtime config mirrors (`.codex`, `.gemini`, `.opencode`) — scope/cost.
- Re-importing superpowers skills verbatim — already runtime-available as a plugin.

## Import Log

| Date | Source repo | Pattern | PR | Adaptation notes |
|------|-------------|---------|-----|------------------|
| 2026-06 | obra/superpowers (`skills/writing-skills`) | Skill/rule authoring-judgment patterns (SDO, match-form-to-failure, bulletproofing) | #417 first pass | Distilled into `skill-authoring-patterns.md` (reference, on-demand) + CONTRIBUTING pointers. Did **not** copy the TDD-for-skills methodology (heavyweight + plugin already provides it); referenced it instead. |

## Re-Survey Checklist (each cycle)

1. Re-clone both reference repos; note new skills/hooks since last survey date.
2. Update the dimension tables with anything new; re-label fit.
3. Move any newly-viable backlog item up; ship it as its own PR.
4. Append to the Import Log and comment on #417 with what was pulled and why.
5. Keep this document current — it is the canonical state of the harvest.
