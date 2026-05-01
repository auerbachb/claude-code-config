# Repo Audit — May 2026 (Org + Efficiency + Best-Practices)

**Issues:** [#413](https://github.com/auerbachb/claude-code-config/issues/413) (organization + docs), [#414](https://github.com/auerbachb/claude-code-config/issues/414) (efficiency), [#415](https://github.com/auerbachb/claude-code-config/issues/415) (Claude Code alignment)

**Date:** 2026-05-01

**Related precedent:** [ai-review-tool-audit-2026-04.md](ai-review-tool-audit-2026-04.md) (#377), [script-extraction-audit.md](script-extraction-audit.md) (#271), [graphite-stacked-prs-research-2026-05.md](graphite-stacked-prs-research-2026-05.md) (#418 / #433)

---

## Executive Summary

### Top 5 actionable findings (across all sections)

1. **Index the reference + diagram layer** — `.claude/reference/` has grown beyond the README index; add the audit/research docs and `diagrams/` to [README.md](README.md) so contributors know what is auto-loaded vs on-demand (Section A).
2. **One bundled “corpus compression” issue when ready** — `CLAUDE.md` + `.claude/rules/*.md` sit at **~10,970 words** (under the committed ratchet cap **11,166** in `.claude/rules/.budget-soft-cap`). Further cuts should be a **single** follow-up PR/issue, not many micro-PRs, to respect CodeRabbit rate-limit economics (Section B + prior #433 research).
3. **Optional hook upgrades are discovery-only** — Upstream Claude Code documents many more hook events (`SessionStart`, `PostToolBatch`, `InstructionsLoaded`, etc.). Adopt only where there is clear ROI; avoid churn for parity alone (Section C).
4. **Keep BugBot reliability invariant** — Do not revert “post `@cursor review` on every push” patterns documented in memory [.claude/memory/feedback_bugbot_auto_trigger_unreliable.md](../memory/feedback_bugbot_auto_trigger_unreliable.md) for small token wins (Section B “things NOT to change”).
5. **Model string hygiene** — `global-settings.json` uses `"model": "opus"` while skills/prompt use human-readable tier strings (e.g. `Opus 4.7 (1M context)`). Periodically reconcile with current Claude Code model IDs / UI names and document the mapping in one place (Section C).

### Recommended ordering for follow-up issues

1. **Docs/index pass** (low risk, improves navigation) — reference README + root README documentation map + fill in mermaid stubs.
2. **Rule corpus single-pass** (if product owner wants more headroom under 10k soft budget) — one issue, one PR, with `rule-lint.sh --update-cap` only after measured cuts.
3. **Hook ROI evaluation** (optional) — pick 1–2 events (`SessionStart` sync? `InstructionsLoaded` telemetry?) after reading upstream docs; ship behind a flag or doc-only recommendation first.

### Major risks / things NOT to change

- **Merge gate semantics** — explicit CR approval on current HEAD, BugBot/Greptile fallbacks, CI before merge: do not “simplify” without a full pass on `cr-merge-gate.md` and `merge-gate.sh`.
- **BugBot trigger strategy** — see memory note above; unreliable auto-trigger is a known production pattern.
- **Skills worktree architecture** — symlinks + dedicated worktree are intentional; they interact with trust flags and `session-start-sync.sh`; do not collapse to “symlink directly to root repo” without re-reading `trust-dialog-fix.md` and `skill-symlinks.md`.
- **Anti–stacked-PR-for-throughput** — #433 / #418 research concluded deferring stacked PRs while CR hourly budget is binding; efficiency work must not assume Graphite stacks as the default path.

---

## Section A — Organization (#413)

### Repo structure findings

| Area | Role | Notes |
|------|------|------|
| Repo root | User-facing entry | `README.md`, `SETUP.md`, `ARCHITECTURE.md`, `CONTRIBUTING.md`, `CLAUDE.md`, `global-settings.json`, `setup.sh`, `setup-skills-worktree.sh`, `.coderabbit.yaml` |
| `.claude/rules/` | Auto-loaded with `CLAUDE.md` | Primary workflow source of truth |
| `.claude/skills/*/SKILL.md` | Slash commands | Large; not auto-loaded as rules but heavy when invoked |
| `.claude/agents/*.md` | Subagent definitions | Loaded on Agent tool use |
| `.claude/hooks/` | Lifecycle automation | Manifest in `global-settings.json` |
| `.claude/scripts/` | Shared CLI helpers | Invoked by skills, hooks, agents |
| `.claude/reference/` | On-demand deep material | Schemas, long `gh api` recipes, audits — **should stay out of rules** to save tokens |
| `.claude/reference/diagrams/` | Visual stubs (this audit) | Mermaid skeletons for future docs |
| `.claude/memory/` | Durable feedback | Small; indexed by `MEMORY.md` |
| `.claude/data/` | Telemetry JSON | Runtime-adjacent; not prose docs |
| `.github/workflows/` | Automation | Thin in this repo |

**Structural improvement:** treat `.claude/reference/` as a **typed library** (audits, schemas, runbooks, diagrams) with a single index file and stable naming: `*-audit-YYYY-MM.md`, `*-research-*.md`, `diagrams/*.md`.

### Docs to create / update / delete

| Action | Doc | Rationale |
|--------|-----|-----------|
| **Create** | [repo-audit-2026-05.md](repo-audit-2026-05.md) (this file) | Bundled #413–#415 deliverable |
| **Create** | [diagrams/README.md](diagrams/README.md) + three stubs | Satisfies “diagrams identified + skeleton” without bloating rules |
| **Update** | [.claude/reference/README.md](README.md) | List all `reference/*.md` files not yet indexed (greptile, scheduling, pm-*, graphite research, this audit) |
| **Update** | [README.md](../../README.md) | Add a **Documentation map** subsection (outline below) |
| **Update** | [SETUP.md](../../SETUP.md) (optional) | Cross-link new diagram folder for installers who skip `ARCHITECTURE.md` |
| **Delete** | None identified | No redundant obsolete doc found; `script-extraction-audit.md` remains historical truth for extractions |

### Major docs — proposed structure (outline)

| Document | Proposed top-level sections |
|----------|----------------------------|
| **README.md** | What you get; Getting started; Slash commands; Rules; Hooks; Scripts; **Documentation map** (→ SETUP, ARCHITECTURE, CONTRIBUTING, `.claude/reference/`, audits); FAQ; Troubleshooting |
| **ARCHITECTURE.md** | (existing) + short “Diagrams” pointer to `.claude/reference/diagrams/` |
| **SETUP.md** | Prerequisites; one-command install; verification; **“Where diagrams live”** one-liner |
| **CONTRIBUTING.md** | How to change rules vs reference; word budget; **“One issue per theme”** PR guidance |
| **CLAUDE.md** | Keep as minimal always-loaded index; defer detail to `.claude/rules/` |
| **`.claude/scripts/README.md`** | (existing tables) + “When to add a script vs inline in skill” decision line |
| **`.claude/hooks/README.md`** | Split “operator setup” vs “maintainer manifest” (same file, two headings) to reduce duplicate JSON examples over time |

### Diagrams (mermaid stubs)

Stub files live under [.claude/reference/diagrams/](diagrams/):

- [diagrams/skills-worktree-symlinks.md](diagrams/skills-worktree-symlinks.md) — root repo ↔ skills worktree ↔ `~/.claude` symlinks
- [diagrams/review-merge-pipeline.md](diagrams/review-merge-pipeline.md) — local CR → PR → reviewer chain → merge gate
- [diagrams/hook-lifecycle.md](diagrams/hook-lifecycle.md) — sequence chart for hooks used in this repo

### README overhaul outline (concrete bullets to add)

1. **Documentation map** — One table: doc path | audience | auto-loaded?  
2. **Onboarding paths** — “I only want review workflow” vs “I want full PM” with links to skills list and `pm-config.md` bootstrap.  
3. **Reference vs rules** — Explain token budget and why long GraphQL lives in `reference/`.  
4. **Audits** — Link this file + AI review tool audit + Graphite research as examples of “reference class” docs.

### Naming and layout inconsistencies

| Observation | Recommendation |
|---------------|----------------|
| Branch naming in `CLAUDE.md` uses `issue-N-*` while cloud agent instructions sometimes use `cursor/*-suffix` | Document both as **allowed patterns** (human workflow vs agent remotes) in CONTRIBUTING or README “Branch naming” |
| `skill-usage.csv` at `.claude/` root vs `data/skill-usage.json` | Grep before adding a third path; consider documenting “source of truth” for skill telemetry in one reference paragraph |
| Mixed doc anchors: some reference files use `YYYY-MM` suffix, others use issue id | Prefer `*-YYYY-MM.md` for time-stamped audits; keep issue link in header |
| Hooks README still shows manual JSON merge examples while `register-hooks.py` + session sync exist | Add a banner: “prefer automated registration via `global-settings.json` + setup” |

---

## Section B — Efficiency (#414)

**Constraint:** Prefer **fewer, larger** implementation issues so CodeRabbit review budget stays tractable (#418 / #433). Do not file one issue per bullet below; cluster by tag.

### Ideas table

| # | Title | Tag(s) | Effort | Impact | Priority |
|---|-------|--------|--------|--------|----------|
| 1 | **Single “reference index + diagram fill-in” PR** | cleanup, token-reduction | Low | Medium — faster human navigation; marginal token save | **P1** |
| 2 | **Corpus compression pass** (rules only, one PR) | token-reduction | Medium | High — every parent turn loads `CLAUDE.md` + rules | **P1** (when soft-cap pressure returns) |
| 3 | **Deduplicate long “why” paragraphs** between rules and reference audits | token-reduction, cleanup | Low–Med | Medium — fewer contradictions + shorter rules | **P2** |
| 4 | **Skill-side “progressive disclosure”** — move repeated merge-gate paragraphs to a single “read cr-merge-gate.md” line where safe | token-reduction | High (touch many skills) | High if done safely | **P2** (risk: skill behavior drift) |
| 5 | **More `if` matchers on PostToolUse hooks** (upstream supports narrowing) | script-extraction, parallelization | Low | Low–Med — fewer spawns for irrelevant tools | **P3** |
| 6 | **Cache `gh` results inside a single skill step** (document pattern: write to `/tmp`, reuse) — not a new daemon | caching | Low | Med for PM skills that hit many issues | **P2** |
| 7 | **Parallel read-only subagents** already in rules; enforce “2+ independent greps → Task tool” in monitor doc only if measured win | parallelization | Low (doc) | Low | **P3** |
| 8 | **Retire or archive superseded reference sections** after each extraction wave | cleanup | Low | Low | **P3** |
| 9 | **Hook: `InstructionsLoaded` logging** (dev-only) to see which rules actually load per project | script-extraction, token-reduction | Med | Med for data-driven cuts | **P3** (experimental) |
|10 | **Consolidate trust JSON repair** (hook + scripts) behind one Python module | script-extraction, cleanup | Med | Low token save; higher maintainability | **P3** |

**Effort scale:** Low ≈ 1 file / few hours agent time; Med ≈ cross-cutting 3–10 files; High ≈ many skills + validation.

**Impact scale:** High = affects default context or hot paths; Medium = operator clarity or repeat savings; Low = niche.

### Script-extraction candidates (remaining / hygiene)

`script-extraction-audit.md` shows most P0/P1 items **extracted**. Remaining hygiene from that doc and this pass:

- Trust-flag logic duplication across `trust-flag-repair.sh`, `repair-trust-*.sh` — **maintainability**, not urgent tokens.
- Any **new** repeated `gh api` blocks introduced after #288 should route through `pr-state.sh` / purpose-built helpers (enforce via CR path + occasional grep audit).

### Token-reduction candidates

- **Rules table compression** — repeated “always/never” tables are high-signal but long; consider moving examples to reference-only appendices when stable.
- **README** — large FAQ is user-friendly but duplicates `ARCHITECTURE.md`; keep FAQ, move deep architecture sentences behind one link.

### Parallelization candidates

- Portfolio skills (`pr-review-help`, multi-issue `prompt`) already assume parallel subagents — **no change** unless profiling shows parent bottlenecks.
- CI / local scripts: `fixpr/audit.sh` is already a consolidation win; avoid parallel `gh` fan-out without backoff (rate limits).

### Caching candidates

- Session-state reads via `session-state.sh --get` (already extracted) — skills should prefer over raw `cat`.
- Greptile budget already atomic — **do not** add cross-process caching.

### Cleanup candidates

- Align `.claude/reference/README.md` with filesystem reality.
- Remove duplicate JSON in hooks README over time (operator vs maintainer sections).

---

## Section C — Best-Practices Alignment (#415)

**Method:** Compared repo conventions to current public Claude Code documentation (hooks reference fetched 2026-05-01: [Hooks reference](https://docs.anthropic.com/en/docs/claude-code/hooks)) and in-repo patterns. **`claude` CLI was not available** in the audit environment — recommend re-running `claude --help` locally when upgrading.

### CLAUDE.md alignment with Claude Code defaults

| Topic | Repo pattern | Claude Code default / docs | Recommendation |
|-------|--------------|---------------------------|----------------|
| Always-loaded instructions | `CLAUDE.md` + `.claude/rules/*.md` | Supported first-class | **Keep** — intentional split for token control |
| Worktrees | Mandatory for agents | Optional in general | **Keep** — documented divergence for multi-agent safety |
| Permissions | `bypassPermissions` + broad `allow` in `global-settings.json` | Stricter out of the box | **Intentional** — reduces friction for trusted automation; document security tradeoff in README |
| Subagents | Custom `.claude/agents/*.md` via Agent tool | Also supports built-in types | **Keep** — clearer for phase workflow |

### Settings alignment

| Setting | Observation |
|---------|----------------|
| `model: "opus"` | Short slug; verify against product’s current catalog when upgrading Claude Code |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | Experimental flag — treat as volatile; re-validate on each CC upgrade |
| `CLAUDE_CODE_SUBAGENT_MODEL=opus` | Documented as **legacy safety net** only in `agents/README.md` — aligned with explicit per-spawn `model` policy |
| Plugin marketplaces | Matches Anthropic marketplace discovery pattern (README cites team marketplace docs) |

### Hooks alignment

| Observation | Detail |
|---------------|--------|
| **Events in use** | `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop` — valid per upstream |
| **Not yet used (upstream examples)** | Examples include `SessionStart`, `PostToolBatch`, `PreCompact` and `PostCompact`, `InstructionsLoaded`, and HTTP, MCP, prompt, and agent hook handler types. **Optional adoption** — evaluate per-feature; avoid default-on HTTP hooks (operational security). |
| **`if` field on handlers** | Upstream documents `if` for tool events to reduce spawns — repo uses matchers but could add `if` for hot paths. Low priority perf polish. |
| **`$CLAUDE_PROJECT_DIR` vs absolute paths** | Repo uses resolved absolute paths from setup (portable after install). Docs recommend `$CLAUDE_PROJECT_DIR` for project-local hooks. **Acceptable divergence**; optional future: hybrid approach. |

### Agent SDK / Agent tool alignment

- Agents are markdown with YAML frontmatter (`description`, `model`, `allowed-tools`) — matches Claude Code subagent docs pattern.
- **Placeholder injection** (`{{PR_NUMBER}}`, etc.) is explicitly manual — acceptable; document in `agents/README.md` already warns this is not auto-resolved.

### Skill structure alignment

- Skills use `SKILL.md` with frontmatter (`name`, `description`, optional `model`) — consistent with skills documentation.
- **Divergence:** some skills omit `model` when parent always passes it — acceptable if call sites are audited; `subagent-orchestration.md` already mandates explicit `model` at spawn.

### Deprecated patterns and replacements

| Pattern | Status | Replacement |
|---------|--------|-------------|
| Inline `gh api` for full PR state in skills | **Deprecated** for new edits | `merge-gate.sh`, `pr-state.sh`, `ac-checkboxes.sh`, etc. |
| Summarizing all rules into subagent prompts | **Deprecated** | Spawn with `subagent_type` + safety block |
| Hand-rolled recurring `ScheduleWakeup` chains for polls | **Forbidden** | `/loop` or `CronCreate` per `scheduling-reliability.md` |
| Relying on `CLAUDE_CODE_SUBAGENT_MODEL` alone | **Deprecated** | Explicit `model` on Agent calls |

### New Claude Code features not yet adopted (notes only)

| Feature | Adoption note |
|---------|---------------|
| Additional hook events (`SessionStart`, `InstructionsLoaded`, …) | Use for observability or pre-flight sync **after** cost/benefit review |
| HTTP / MCP / prompt / agent hook types | Powerful but increases attack surface and debug complexity — defer |
| `PostToolBatch` | Could replace N× PostToolUse noise for batch-heavy sessions — experimental |
| `/hooks` menu | Operational win for humans verifying merged settings — document in README “Troubleshooting hooks” |
| Agent teams (`TeammateIdle` in upstream table) | Env `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` already on — monitor upstream changelog for stabilization |

### Model ID audit and recommendations

| Location | Value observed | Recommendation |
|----------|----------------|----------------|
| `global-settings.json` | `"model": "opus"` | When Anthropic renames tiers, update here **and** in `prompt/SKILL.md` tier table the same release cycle |
| `global-settings.json` | `CLAUDE_CODE_SUBAGENT_MODEL` env | Keep until all spawn sites verified; grep occasionally for bare `Agent` calls |
| `.claude/agents/*.md` | `opus` / `sonnet` | Matches internal short names |
| `.claude/skills/prompt/SKILL.md` | `Opus 4.7 (1M context)`, `Sonnet 4.6`, etc. | **Human-facing strings for prompts** — OK; add a one-line comment that CLI/API may use different slugs |
| Cursor cloud agent instructions | `composer-2-fast` etc. | Out of repo — do not conflate with Claude Code model keys |

**Action:** add a short “Model names” subsection to `CONTRIBUTING.md` or `agents/README.md` listing **three namespaces**: UI/marketing strings, Claude Code settings slugs, Cursor task routing models.

### Settings / hooks audit checklist (completed)

- [x] `global-settings.json` — permissions, model, env, hooks tree reviewed  
- [x] Hook manifest vs `.claude/hooks/*` on disk — 13 executable hooks + `register-hooks.py` align with README narrative  
- [x] Experimental flags noted  
- [x] Upstream hook doc diff — events and handler types cataloged above  

---

## Proposed Follow-up Issues (NOT opened — for PM / user triage)

Bundle aggressively to limit CR review cycles.

1. **Docs + diagrams completion (single PR)** — Update `.claude/reference/README.md`, add README “Documentation map”, flesh out the three mermaid stubs from real content in `ARCHITECTURE.md` / `skill-sync-hooks.md`.  
2. **Optional hook modernization (single PR)** — Pick ≤2 new hook events or `if` matchers with tests; document rollback.  
3. **Rule corpus compression vNext (single PR)** — Only if stakeholders want margin under 10k soft cap; include `rule-lint.sh --update-cap` after net decrease; respect merge gate / BugBot / worktree invariants.  
4. **Model naming doc (single PR)** — One table linking UI strings ↔ `settings.json` ↔ Agent spawn examples.  
5. **Trust repair deduplication (single PR)** — Shared library for JSON atomic write + callers in hook + scripts.

---

## Acceptance Criteria Mapping

### #413

- [x] Full repo audit with structural improvements — Section A tables  
- [x] README skeleton / outline — Section A “README overhaul outline” + proposed follow-up #1  
- [x] Major docs proposed structure — table in Section A  
- [x] Diagrams identified + stubs — `diagrams/*.md`  
- [x] Naming / layout inconsistencies — Section A subsection  

### #414

- [x] Efficiency ideas enumerated — Section B table + subsections  
- [x] Tags per idea — column `Tag(s)`  
- [x] Rough effort / impact — columns + scales explained  
- [x] Priority order — P1–P3 in table and narrative  

### #415

- [x] CLAUDE.md / settings / hooks / agents / skills audited — Section C  
- [x] Deprecated patterns + replacements — table  
- [x] New features not adopted — table  
- [x] Model ID references + recommendations — subsection  
- [x] Settings / hooks audit — checklist  

---

## Verification notes (this PR)

- **Corpus word count** ( `CLAUDE.md` + `.claude/rules/*.md` ): **10970** words — under `.claude/rules/.budget-soft-cap` (**11166**). This PR adds reference-only markdown and does not raise the corpus.  
- **CodeRabbit CLI** was not present in the audit CI environment; human/agent with CLI should run `coderabbit review --prompt-only` before merge per workflow rules.
