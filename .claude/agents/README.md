# Custom Agent Definitions

This directory contains custom agent definitions for the Phase A/B/C subagent workflow and PM task execution. Each agent is a self-contained `.md` file with frontmatter metadata and embedded rules — no external rule-file injection needed at spawn time.

## How It Works

Claude Code's Agent tool supports a `subagent_type` parameter that references agent definition files in `.claude/agents/`. When spawning a subagent with `subagent_type: "phase-a-fixer"`, Claude Code loads `.claude/agents/phase-a-fixer.md` as the agent's system context — including its `allowed-tools` restrictions and embedded instructions.

## Placeholder Syntax

Agent definitions use `{{PLACEHOLDER}}` markers for runtime context that the parent must inject into the agent's `prompt` parameter at spawn time. Placeholders are **not** auto-resolved — the parent agent must string-replace them before spawning.

### Common Placeholders

| Placeholder | Description | Example |
|-------------|-------------|---------|
| `{{PR_NUMBER}}` | GitHub PR number | `618` |
| `{{ISSUE_NUMBER}}` | GitHub issue number | `617` |
| `{{BRANCH_NAME}}` | Feature branch name | `issue-617-add-auth` |
| `{{OWNER}}` | GitHub repo owner | `auerbachb` |
| `{{REPO}}` | GitHub repo name | `claude-code-config` |
| `{{HEAD_SHA}}` | Current HEAD commit SHA | `7b2cfbf` |
| `{{HANDOFF_FILE}}` | Path to handoff JSON | `~/.claude/handoffs/pr-618-handoff.json` |
| `{{REVIEWER}}` | Assigned reviewer (`cr`, `bugbot`, or `greptile`) | `cr` |
| `{{EXISTING_FINDINGS}}` | Pre-fetched review findings (optional) | JSON or summary text |
| `{{RESEARCH_QUESTION}}` | Research/audit question for the `researcher` agent | `"List every skill that uses the `Bash` tool"` |
| `{{SCOPE}}` | Optional scope hints for `researcher` (dirs, files, date ranges) | `".claude/skills/*/SKILL.md"` |

## Agent Inventory

| Agent | Phase | Purpose | Tool Restrictions | Default Model |
|-------|-------|---------|-------------------|---------------|
| `phase-a-fixer` | A | Fix findings, resolve merge conflicts, push, write handoff | Full access | `opus` |
| `phase-b-reviewer` | B | Poll reviews, fix findings, update handoff | Full access | `opus` |
| `phase-c-merger` | C | Verify merge gate and AC, then run `/wrap` when authorized | Read-only + Bash (for `gh`/git) | `sonnet` |
| `pm-worker` | — | Issue management, repo bootstrap | Full access | `sonnet` |
| `researcher` | — | Read-only exploration, audit, investigation — produces a findings report | Read, Glob, Grep, Bash (read-only `gh`/`git`/`cat`/`find`/etc.) | `sonnet` |

### Model Selection

Each agent definition declares a default `model` in frontmatter. The parent must also set `model` explicitly at every Agent tool call site per `.claude/rules/subagent-orchestration.md` "Model Selection" — the call-site parameter overrides the frontmatter default and keeps cost decisions visible at every spawn point.

**Fleet:** Fable, Opus, Sonnet, Haiku. Opus is the default for unattended and heavy-phase spawns; Fable is the strongest model in the fleet but is never a spawn default (see below).

**Aliases:** the Agent tool's `model` parameter accepts exactly four values — `sonnet`, `opus`, `haiku`, `fable` — and each resolves to the newest non-legacy model of that family. Frontmatter intentionally uses these bare aliases, so agent definitions need no editing when Anthropic ships a new version. Write an explicit model ID (e.g. `claude-opus-5`) only where a tool literally consumes the string; if the runtime ever stops resolving bare aliases, switch frontmatter to explicit IDs and update this note.

### Model naming — families, never versions (#791)

**Say "Opus", "Sonnet", "Haiku", "Fable".** Every human-facing mention of a model across `CLAUDE.md`, `.claude/rules/`, `.claude/skills/`, and `.claude/agents/` — plus the living contract docs in `.claude/reference/` those files consume normatively (`chip-launching.md`, `chip-model-guard-decision.md`) — uses the bare family name. The family is the part that carries a decision; the version is maintenance we would be volunteering for. A bare name also stays true on its own: it means the current non-legacy model of that family, so a new release inside an existing family needs no edits anywhere. A genuinely new family gets added when it ships.

Two things are exempt:

- **Tool-consumed strings.** `claude-opus-5` in an `ocr config set` value, `claude-haiku-4-5-20251001` in an API call — the version is load-bearing there, because something parses it.
- **Dated point-in-time records** under `.claude/reference/` — audits, evals, and research snapshots. Rewriting them to today's vocabulary falsifies the history they exist to preserve. Stated durably in `.claude/reference/README.md` under "Audits and research (point-in-time)".

This reverses the version-pinning call made in #749. That change wanted the docs to track the current fleet; naming families reaches the same goal without the sweep, since an alias already resolves forward on its own. `.github/scripts/chip-model-guard-lint.sh` enforces the rule over exactly the scope above.

**Effort is not a spawn parameter.** The Agent tool takes `model` but has no `effort` — a subagent inherits the parent session's effort. Effort *is* settable per agent inside a Workflow script, via `agent()`'s `opts.effort`. Never write an effort instruction into a subagent prompt expecting it to change anything.

**Per-phase rationale:**

| Agent | Model | Why |
|-------|-------|-----|
| `phase-a-fixer` | `opus` | Heaviest reasoning: reads findings, edits source files across multiple locations, resolves rule conflicts, designs fixes. Quality regressions here cost a full review cycle. |
| `phase-b-reviewer` | `opus` | Evaluates review findings (many are false positives), decides when to dismiss vs. fix, handles multi-reviewer edge cases, judges severity. Needs strong judgment. |
| `phase-c-merger` | `sonnet` | Lightweight verification plus canonical `/wrap` execution: reads PR body, checks boxes against code, runs `gh`/git commands, and reports blockers. Read-only tool restrictions (no Write/Edit) — the mechanical work does not need Opus-level reasoning. |
| `pm-worker` | `sonnet` | Data gathering and formatting: issue creation, repo bootstrap checks. Each task follows a well-defined template. |
| `researcher` | `sonnet` | Read-only exploration and summarization: reads files, runs `gh`/`git` queries, synthesizes findings. No code edits, no fixes — `sonnet` is sufficient for read-and-report work, and the restricted `allowed-tools` frontmatter prevents any write operations regardless of model. |

**Why Fable is not any agent's default:** Fable is the strongest model in the fleet, but no agent defaults to it — the same cost logic that puts `sonnet` on `phase-c-merger` applies in the other direction. Phase spawns run unattended, often several in parallel, and Opus already clears the reasoning bar for the heaviest phase (A/B) work; paying roughly double per spawn buys headroom these phases do not need. Fable is reserved for interactive hardest-work step-ups, where a human is watching the spend and can judge the trade. `/prompt`'s tier ladder is where it is actively recommended (see `.claude/skills/prompt/SKILL.md` "Model Lineup & Effort Levels"). Escalating a specific spawn to `fable` is a deliberate exception — document why, and do not make it a default.

The global env var `CLAUDE_CODE_SUBAGENT_MODEL=opus` is a legacy safety net for unexpected/undocumented spawns only — **not** a compliant spawn pattern. Compliant calls must still set `model` explicitly at the call site and must not rely on either the frontmatter default or this env var.

## Spawning Pattern

The parent agent spawns subagents like this:

```text
Agent tool call:
  subagent_type: "phase-a-fixer"
  mode: "bypassPermissions"
  model: "opus"
  prompt: "Work on PR #618 for issue #617 on branch issue-617-add-auth.
           Repo: auerbachb/claude-code-config
           Handoff file: ~/.claude/handoffs/pr-618-handoff.json

           SAFETY: Do NOT delete, overwrite, move, or modify .env files — anywhere,
           any repo. Exception: template files matching .env.<example|sample|template
           |dist|tpl> (case-insensitive) are committed, non-secret, and safe to edit.
           Do NOT run git clean in ANY directory. Do NOT run destructive
           commands (rm -rf, rm, git checkout ., git stash, git reset --hard) in the
           root repo directory. Stay in your worktree directory at all times.

           MINDSET: Before handing off, walk the capability ladder for ANY provider
           CLI (gh, git, vercel, neonctl, railway, cloudinary, or one you've never
           used): look at what you already have — MCP tools, skills, and the CLI on
           disk by absolute path (/opt/homebrew/bin/<tool>); if absent, check
           whether the provider ships a CLI; install it yourself when
           non-interactive and the safety rails hold; else hand off an
           /admin-merge-shaped runbook — exact commands + one-line reason. 'I can't'
           is valid only after the ladder dead-ends, and must name the rung and the
           reason.

           SKILLS: Before hand-rolling a multi-step task, check whether an existing
           skill already does this job — invoke it via the Skill tool instead of
           reimplementing from memory. Clear match -> invoke immediately. Borderline
           match -> note it in your exit report, then proceed on your own judgment.
           No match -> stay silent. Never auto-invoke an authorization-carrying skill
           (/merge, /wrap, /pr-monitor-and-manage) on a fuzzy match — and this never
           overrides your own phase's assigned task. Full rules:
           .claude/rules/skill-first.md.

           Existing findings to fix:
           <paste findings here>"
```

The SAFETY, MINDSET, and SKILLS blocks are mandatory in every subagent prompt (see `.claude/rules/safety.md` and `.claude/rules/skill-first.md`). The example above shows where to place them — between the task context and any findings payload.

The agent definition provides the workflow rules. The prompt provides the runtime context. The parent no longer needs to read and embed all rule files manually.

## Adding New Agents

1. Create `<agent-name>.md` in this directory
2. Include frontmatter with `description` and optionally `allowed-tools`
3. Embed only the rules relevant to the agent's responsibilities
4. Document any new placeholders in this README
5. Update the Agent Inventory table above
