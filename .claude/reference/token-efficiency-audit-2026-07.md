# Token-Efficiency Audit & Playbook — July 2026

**Issue:** [#773](https://github.com/auerbachb/claude-code-config/issues/773) (stretch Claude sessions toward the 5h limit)

**Date:** 2026-07-28

**Related precedent:** [instruction-set-audit-2026-07.md](instruction-set-audit-2026-07.md) (#462, size caps), [harness-model-audit-2026-06.md](harness-model-audit-2026-06.md) (#49), [skill-repo-diff.md](skill-repo-diff.md) (#417 pattern mining), [pm-routing-audit-2026-07.md](pm-routing-audit-2026-07.md) (#710 telemetry gap)

**Method:** Four independent deep-research reports (two general syntheses, one evidence-tiered field guide, one harness-specific decision memo) consolidated into one playbook, then audited against this harness. Each pattern gets an explicit **adopt / skip / adapt** call. This doc is the durable record; the shipped changes are in the PR closing #773.

---

## Verdict (read this first)

**The dominant token costs are structural, not stylistic.** Output verbosity — what most "token efficiency" advice targets — is a minority cost (independent A/B: concise-output styles measured ~8.5%, not the advertised ~65%). The four bigger taxes for this harness:

1. **Fixed-context:** ~12K *words* of always-loaded CLAUDE.md + 18 unscoped rules, reprocessed every turn.
2. **Repetition:** rituals accumulating in the transcript — per-tool-call time injection, every-tick full fleet tables, multi-line heartbeats. Every API call re-transmits history, so per-turn junk compounds ~quadratically (20 turns × 2K/turn ≈ 420K cumulative processed).
3. **Fan-out:** subagents reloading the instruction hierarchy (multi-agent ≈ 15× chat tokens, Anthropic-measured), everything defaulting to Opus.
4. **Workflow payload:** giant invoked skills (`pr-monitor-and-manage` ≈ 1,100 lines; post-compaction re-injection caps at 5K tokens/skill, so most of it doesn't even survive).

Right objective: **tokens to verified outcome**, not tokens per response. Trim noise (helps cost *and* quality); never trim signal (rules that prevent retries, reasoning on hard problems, hard-stop visibility).

**Shipped for #773 (v1):** one-line-by-default status/heartbeat contract (CLAUDE.md #2/#3 + `monitor-mode.md`), delta-aware PMM fleet table (full table only when something changed or an action fires), and a "repeat less" cut — `silence-detector.sh` stops injecting `Current system time` on every tool call (≥1/min max in steady state). Everything else is ranked below and deferred to follow-ups.

---

## The five cost surfaces (mental model)

| Surface | What it is | This harness today |
|---|---|---|
| 1. Fixed startup context | CLAUDE.md, unscoped rules, skill descriptions, MCP schemas loaded before the first task | ~12K-word rule corpus (budgeted, ratchet-capped); dozens of MCP servers/skills in some sessions; documented community floor 20–30K tokens before "hi" |
| 2. Per-turn accumulation | Full history re-sent every call; cache discounts price (~10% reads) but not window share | Per-tool-call hook injections, every-tick tables, heartbeat prose |
| 3. Retained/re-injected | What survives compaction: root CLAUDE.md + unscoped rules reload; invoked skills capped 5K/skill, 25K total; MEMORY.md truncates 200 lines/25KB; path-scoped rules vanish until re-touched | 951+-line skills assume their procedure survives compaction — it doesn't |
| 4. Fan-out | Each subagent reloads baseline context | Custom agents embed rule copies *and* (per research — verify, FU-1) also inherit the hierarchy → double-pay; Opus default everywhere |
| 5. Generated output | Narration, recaps, thinking tokens | The minority cost; already partially addressed by terse skill outputs |

Overlay: **context rot** — accuracy degrades well before the technical window limit (verified across 18 models, Chroma eval). Anthropic's framing: *smallest set of high-signal tokens that maximizes the likelihood of the desired outcome* — not minimum tokens.

---

## Adopt / skip / adapt — pattern verdicts

Evidence tiers: **A** = Anthropic primary/measured · **B** = community, reproducible mechanism · **C** = folklore.

### Monitoring & status chatter (this issue's core)

| Pattern | Tier | Call | This-harness note |
|---|---|---|---|
| One-line routine heartbeats; full detail only on change/blocker/failure | B | **ADOPT — shipped** | CLAUDE.md #2/#3 + `monitor-mode.md` now define the one-line format; monitor declaration folds into the line |
| Delta-only fleet reporting (no unchanged-table reprints) | B | **ADOPT — shipped** | PMM Step 4 reuses the Step 6 fleet digest; table prints only on change/action/first tick |
| Unchanged tick ⇒ no model-visible prose *at all* (event-driven wake) | B | **ADAPT — partial** | Full version needs a script-side poller that skips the model call entirely; v1 keeps the 5-min non-silence guarantee (one line). Poller-pattern rewrite = FU-2 |
| Kill per-tool-call hook injections that repeat static/near-static values | A (Anthropic warns hook-injected timestamps go stale) | **ADOPT — shipped** | `silence-detector.sh` steady-state time injection now ≥60s apart (`SILENCE_TIME_INJECT_S`), warning path untouched |
| Move time/monitor state to statusline (renders outside context, zero tokens) | A/B | **ADAPT — FU-3 shipped (#779), terminal-only** | `.claude/scripts/statusline.sh` renders ET time · branch · agents · watchers. The timestamp *prefix* rule and `timestamp-injector.sh` stay (the model still needs the time in context to write the prefix) — what shrinks is the human's reliance on reading it back out of the transcript. **Caveat found while implementing:** the status line only renders in the interactive terminal TUI; a headless desktop-app session never invokes it (`usage-limit-signal-audit-2026-07.md` §1), so the saving lands only in terminal sessions |
| Heartbeat exists to prove liveness ⇒ delete it | C | **SKIP** | The 5-min heartbeat is a deliberate UX contract here; we shorten it, never drop it |

### Fixed context (rules, CLAUDE.md, MCP, skills)

| Pattern | Tier | Call | This-harness note |
|---|---|---|---|
| Tiny universal kernel; procedures live in invoked skills | B | **ADAPT — FU-5** | Direction already house style ("keep growth out of the corpus", reference/ offload); a kernel rewrite is #768/#770 territory, not this PR |
| Magic CLAUDE.md token target (e.g. <500) | C | **SKIP** | "Minimal ≠ short" (Anthropic). We keep the word-budget ratchet instead — remove *inferable* content, keep load-bearing constraints |
| Path-scope rules via `paths:` frontmatter (−41% one case) | B | **ADAPT — FU-5** | Most of our 18 rules are genuinely global workflow rules; audit which are branch-phase-specific. Caveat: path-scoped rules vanish post-compaction until a matching file is touched |
| Splitting one file into many files = lazy loading | C (misconception) | **SKIP** | All unscoped rules load at startup regardless of file count; only `paths:` gates loading |
| `disable-model-invocation: true` on operator-only skills | B | **SKIP for now** | Repo memory `feedback_skill_frontmatter.md`: it also hides the skill from user autocomplete — unacceptable UX cost until upstream fixes it |
| Giant skill → dispatcher (50–150 lines) + `references/` + `scripts/` | A/B (5K/skill re-injection cap makes >5K skills partially dead weight) | **ADAPT — FU-2** | PMM (~1,100 lines) is the target; its scripts already exist (`pr-state.sh`, `merge-gate.sh`, `merge-sequence.sh`) — the prose around them is what needs the split |
| MCP per-repo pruning; Tool Search Tool for schema deferral (~85% cut, accuracy ↑) | A | **ADOPT — FU-6** | Session-dependent (many idle MCP servers observed in desktop sessions); needs `/context` baseline first (#710) |
| Prefer CLI over MCP where equivalent | B | **ADOPT (already house style)** | `gh`, scripts, absolute-path CLIs are the norm here |
| `permissions.deny` for junk dirs (`.claudeignore` is advisory-only) | A (docs) | **ADOPT — FU-6** | Cheap; bundle with the measurement pass |
| HTML comments in rules are stripped before injection (free maintainer notes) | B | **ADOPT — use as needed** | Zero-cost documentation channel |

### Fan-out & models

| Pattern | Tier | Call | This-harness note |
|---|---|---|---|
| Fix the subagent-inheritance assumption ("subagents do NOT auto-load rules" may be wrong on current harness → embedded rule copies double-pay) | B | **VERIFY then adapt — FU-1** | Contradicts `subagent-orchestration.md`; `skill-first.md` already documents snapshot-at-spawn (PR #585). Verify on current version, then de-duplicate `.claude/agents/*` embedded copies. Ties into #770 |
| Model routing: Haiku for polling/formatting, Sonnet for implementation, Opus by escalation | A/B (pricing: Haiku $1/$5, Sonnet $3/$15, Opus $5/$25 per MTok) | **ADAPT — FU-4** | We already route A/B=opus, C/pm-worker=sonnet (`subagent-orchestration.md`); the candidate cut is Haiku for pure poll/classify ticks. Needs an eval — misrouting a hard bug to Haiku is false economy |
| Never switch models/effort/MCP set mid-session (per-model caches; cold re-read often costs more) | A | **ADOPT (already policy-adjacent)** | Set at session/spawn start; document in FU-4 |
| Explore/Plan agents for read-only recon (skip global instructions) | A | **ADOPT (already available)** | Use Explore for repo sweeps instead of custom agents |
| Parallel-agent fan-out as free savings | C | **SKIP** | Multi-agent ≈ 15× tokens (Anthropic); fan out for quality/wall-clock, on purpose, never "to save tokens" |

### Tool results, compaction, state

| Pattern | Tier | Call | This-harness note |
|---|---|---|---|
| Filter at source (grep/head/jq projections; counts not dumps) | A/B (tool I/O >60% of context; reads 76% of tokens on SWE-bench mini) | **ADOPT (mostly house style)** | Scripts already emit compact summaries; FU-7 wrapped the noisiest remainder (#782) |
| Offload bulky output to disk; pass path + summary | A | **ADOPT (house style)** | Also built-in now: >50K-char tool results auto-spill to disk |
| Universal lossy tool-output interception (RTK/Headroom-style) | B/C | **SKIP** | Fragile: subagent hook bypass, over-minified errors, blind spots; selective wrappers only |
| External state as primary memory (session-state.json, handoffs, issues/PR bodies) | A | **ADOPT (already built)** | This harness's strongest asset; keep building on it |
| `/clear` at phase boundaries; compact only mid-task with a preservation contract; never reactively at the limit | A/B | **ADOPT — practice** | Preservation list: issue/PR numbers, branch/SHA, AC status, reviewed SHA, gate state, next command |
| Arbitrary compaction thresholds ("compact at 50%") | C | **SKIP** | Task-boundary discipline instead |
| Concise-output styles / "no preamble" / fragments-only | C→B (measured down to 4–12%) | **SKIP beyond the one contract** | One paragraph shipped in CLAUDE.md #3; stripping reasoning measurably increases retries |

---

## Ranked recommendations (savings × risk)

| # | Change | Expected savings | Correctness risk | Status |
|---|---|---|---|---|
| 1 | Silence-detector steady-state dedupe (per-tool-call → ≥60s) | High — fires on *every* tool call in *every* session; each injection also re-transmits with all later turns | **Very low** — warning path untouched; turn-start injector untouched | **Shipped (#773)** |
| 2 | Delta-aware PMM table + one-line heartbeats | High in monitor-heavy sessions (the #773 complaint) | **Low** — table still prints before any action; critical states always full | **Shipped (#773)** |
| 3 | Subagent inheritance verify + de-dup embedded rules | Very high if confirmed (every spawn pays the corpus twice) | Medium — changes agent definitions; needs verification first | **FU-1** (ties #770) |
| 4 | PMM dispatcher/references/scripts split | High (invocation + selection + compaction-survival) | Medium — big refactor of a load-bearing skill | **FU-2** |
| 5 | Statusline for time/branch/agents | Medium in terminal sessions, **zero in headless ones** — see the caveat above | Low | **Shipped (#779)** |
| 6 | Haiku routing for pure poll/classify ticks | Medium ($ more than tokens) | Medium — needs eval; escalation path must stay | **FU-4** |
| 7 | Rule-corpus kernel shrink + path-scoping audit | High per-turn | Medium-high — literal-following models misfire on botched cuts; #768/#770 own it | **FU-5** |
| 8 | MCP pruning + `/context`/`ccusage` measurement baseline | High in MCP-heavy sessions | Low | **FU-6** (ties #710) |
| 9 | Tool-result JSON contracts for remaining noisy pipelines | Medium on long sessions | Low | **Shipped (#782)** |
| — | Concise-output styling beyond the shipped contract | Low (4–12% measured) | Medium (retry inflation) | **Rejected** |
| — | `disable-model-invocation` on operator skills | Medium | High (autocomplete gotcha) | **Blocked** — revisit on harness fix |
| — | Universal output interception layer | Medium | High | **Rejected** |

## What NOT to change (guardrails for every future cut)

- **Hard stops and merge-gate failures print in full, always:** failing/incomplete CI, human `CHANGES_REQUESTED`, unresolved threads, unchecked AC, branch-protection blocks, authorship refusals. Never summarized into a status line.
- **`safety.md` prohibitions and their subagent blocks:** verbatim, never compressed.
- **The 5-minute non-silence guarantee and timestamp prefix:** cadence and prefix stay; only the *body* got shorter. The silence-detector *warning* path is untouched.
- **Structured exit reports, handoff files, session-state writes:** these are the external memory that makes context cheap — cutting them is anti-efficiency.
- **Reviewer-chain and polling exit criteria:** "0 unresolved right now" is still not an exit; brevity never relaxes the gate.

---

## Cargo-cult list (measured down or wrong — do not ship)

Magic CLAUDE.md token numbers · "no preamble" as a saver (redundant with the system prompt) · mid-session CLAUDE.md edits (no effect until restart, cache-neutral but pure downside) · mid-session model downgrades (per-model caches → often costs more) · worktrees/subagents as free savings (each reloads baseline) · believing `.claudeignore` blocks reads (advisory; use `permissions.deny`) · fearing statuslines eat context (they render outside it) · many-files-as-lazy-loading (only `paths:` gates) · `@imports`-as-progressive-disclosure (fully expand at launch) · everything-pack skill installs (SWE-Skills-Bench: 39/49 skills no gain, overhead to +451%, 3 harmful) · arbitrary compaction percentages · heartbeats that exist to prove liveness · answering every incident with a permanent rule instead of a test/guard/script · trusting pre-2026 guides (no `/context`, MCP toggling, Tool Search, or context-editing = stale).

## Key measured numbers (for future arguments)

| Claim | Number | Tier |
|---|---|---|
| Context editing (tool-result clearing) | +29% benchmark alone; +39% with memory tool; −84% tokens on 100-turn eval | A |
| Multi-agent overhead | ~4× chat per agent; ~15× multi-agent; token usage explains ~80% of perf variance | A |
| Tool Search Tool | ~85% schema-overhead cut (77K→8.7K); Opus tool-selection 49→74% | A |
| MCP schema cost | ~1K+/tool; 10–20K/server; 55K observed for 5 servers | B |
| Tool I/O share | >60% of used context; file reads 76.1% of tokens (SWE-bench Verified, mini-agent) | B |
| Session floor | 20–30K tokens before first message | B |
| Concise-output styles | ~65% claimed → 8.5% independent A/B; 4–12% repo-reported | C→B |
| Cache pricing | reads ≈10% of input price; writes 1.25× (5-min TTL) / 2× (1-hr) | A |
| Skill re-injection post-compaction | 5K/skill, 25K total; MEMORY.md 200 lines/25KB | A |

Headline "60–91% savings" figures across the ecosystem come from deliberately bad baselines — treat as ceilings, measure our own delta (FU-6).

---

## Sources

**Anthropic (Tier A):** [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) · [Managing context on the Claude Developer Platform](https://www.anthropic.com/news/context-management) · [How we built our multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system) · [Introducing advanced tool use (Tool Search)](https://www.anthropic.com/engineering/advanced-tool-use) · [Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) · [Code execution with MCP](https://www.anthropic.com/engineering/code-execution-with-mcp) · [Claude Code docs](https://code.claude.com/docs) (memory, costs, sub-agents, skills, hooks).

**Research:** AGENTS.md runtime study ([arXiv 2601.20404](https://arxiv.org/abs/2601.20404): −28.6% runtime, −16.6% output tokens) · context-file eval ([arXiv 2602.11988](https://arxiv.org/abs/2602.11988): generic context files add >20% cost, no success gain) · SWE-Skills-Bench ([arXiv 2603.15401](https://arxiv.org/abs/2603.15401)) · [Chroma context-rot eval](https://research.trychroma.com/context-rot).

**Community (Tier B/C, mechanisms sound, multipliers marketing):** [ccusage](https://github.com/ryoppippi/ccusage) (longitudinal token telemetry) · [drona23/claude-token-efficient](https://github.com/drona23/claude-token-efficient) (candid own-benchmark: 4–12%, full file sometimes net-negative) · [agentskills.io](https://agentskills.io) (progressive-disclosure standard) · Caveman-style concise output + independent A/B (~8.5%) · RTK / Headroom / Context-Mode interception teardowns (why universal interception is fragile) · compaction-cascade reverse-engineering (openedclaude, y-agent, finisky, decodeclaude).

---

## Follow-ups (deferred cuts — file as issues at wrap)

- **FU-1:** Verify subagent instruction inheritance on the current harness version; if the hierarchy loads into custom agents, strip duplicated rule blocks from `.claude/agents/*` (keep role-specific prompts + safety blocks). Ties #770.
- **FU-2:** Split `pr-monitor-and-manage` into dispatcher (≤150 lines) + `references/` + existing scripts; add script-side no-change short-circuit so an unchanged tick costs ~no model tokens.
- ~~**FU-3:** Statusline (ET time · branch · active agents · watchers) to replace injection reliance for time display.~~ **Shipped in #779** — `.claude/scripts/statusline.sh` + a `statusLine` entry in `global-settings.json`, deployed through the same placeholder-resolution path as hooks. The timestamp-prefix rule and its injector hook are untouched by design. Renders in terminal TUI sessions only (see the caveat in the monitoring table above), so it is additive rather than a replacement for the injection.
- **FU-4:** Poller model-routing eval (Haiku for classify-only ticks) + "set model/effort at spawn, never mid-session" note in `subagent-orchestration.md`.
- **FU-5:** Rule-corpus kernel/path-scoping audit (with #768/#770).
- **FU-6:** Measurement baseline: `/context` + `ccusage` per repo, MCP prune list, `permissions.deny` junk-dir blocks (ties #710).
- ~~**FU-7:** Compact-JSON output contracts for the remaining noisy `gh`/log pipelines.~~ **Shipped in #782** — the `ok`/`failed_tests`/`relevant_error`/`log_path` contract is defined once in `compact-result-contract.md` and adopted by three selective wrappers: `--json` on both test runners (`run-hook-tests.sh`, `run-python-tests.sh`, surfaced in CI via `summarize-test-run.sh` → step summary + `::error::`) and the new `local-review.sh` around the CodeRabbit/CodeAnt CLIs, which also replaces the capture-and-grep that was copy-pasted across `cr-local-review.md` and four skills. Measured: the Python runner's green output 13,489 B → 165 B (99%); `pr-state.sh`'s comment arrays field-projected 294 KB → 99 KB (66%, bodies kept in full). Deliberately **not** universal — the interception layer stays rejected, and the already-compact `--json` scripts were left alone.

## AC coverage (#773)

| AC | Where |
|---|---|
| Research note, ≥5 sources, adopt/skip/adapt | This doc (Sources + verdict tables) |
| Ranked recommendations, savings vs risk | "Ranked recommendations" table |
| Status/progress rules tightened | CLAUDE.md #2/#3, `monitor-mode.md` User Heartbeat, PMM Step 4, babysit T7 |
| ≥1 cut beyond verbosity | `silence-detector.sh` steady-state time-injection dedupe (+ tests) |
| Word budget respected | `rule-lint.sh` run in PR; edits net-negative |
| No hidden hard stops | "What NOT to change" section; critical signals carved out as always-full |

---

## FU-1 Verification — Subagent Instruction Inheritance (Issue #777, 2026-08-05)

**Claim verified:** Custom `subagent_type` agents inherit the full project CLAUDE.md hierarchy + `.claude/rules/*.md` files automatically. The previous assertion "Subagents do NOT auto-load these files" was incorrect.

**Primary evidence — live runtime probe:** The agent implementing Issue #777 ran as a general-purpose subagent with no `subagent_type`. Its task prompt deliberately pasted only the SAFETY/MINDSET/SKILLS guardrail blocks and no other rule text. The agent's context at runtime included the complete project CLAUDE.md (from the skills-worktree symlink path) and all 18 `.claude/rules/*.md` files — verified by inspecting the system-reminder blocks present at session start. These were not in the task prompt; they arrived via harness injection. This constitutes direct first-person observation of injection behavior on the current harness.

**Supporting evidence:** CodeRabbit's plan for Issue #777 (posted on the issue) independently cites the current official Claude Code sub-agents documentation confirming that custom `subagent_type` spawns receive the CLAUDE.md hierarchy and project rules automatically; only built-in Explore/Plan agents omit them.

**Harness version caveat:** No Claude Code version is pinned in this repo. The observation reflects behavior as of 2026-08-05. This supersedes the stale "PR #585 snapshot-at-spawn" citation in `skill-first.md`.

**What was changed (PR #1016):**
- `CLAUDE.md` §Rule Files: corrected "Subagents do NOT auto-load these files" → confirmed inheritance model with Explore/Plan exception noted.
- `.claude/rules/subagent-orchestration.md`: removed the premise that manual full-corpus injection is the normal path; the "Fallback" section now covers only Explore/Plan and rare non-custom spawns.
- `.claude/rules/skill-first.md` §Reaching Subagents: removed the "snapshot at spawn, never re-read" claim; custom subagents inherit the corpus (including `skill-first.md`) directly.
- `.claude/agents/*.md`: removed duplicated Skill-First Reflex and Autonomy Rules sections (already inherited); kept SAFETY/MINDSET blocks as deliberate safety-critical restatements.
- `.claude/skills/subagent/SKILL.md` Step 6.3: removed the full-corpus `cat ./CLAUDE.md; cat ./.claude/rules/*.md` injection from Phase A/B/C spawn templates — these were the largest double-pay.

**Outcome:** FU-1 resolved. Inheritance confirmed → de-duplication performed. Every future spawn that uses a `subagent_type` from `.claude/agents/` no longer double-pays the rule corpus.
