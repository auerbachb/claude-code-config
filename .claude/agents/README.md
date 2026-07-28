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

**Current fleet (verified 2026-07-28):** Fable 5, Opus 5, Sonnet 5, Haiku 4.5. Opus 5 is the top-of-fleet default.

**Current alias resolution (verified 2026-07-28):** `opus` → Opus 5, `sonnet` → Sonnet 5, `haiku` → Haiku 4.5. Fable 5 has no bare alias — spawning it requires the explicit model ID `claude-fable-5` at the call site. Frontmatter intentionally uses bare aliases — Claude Code resolves them to the latest non-legacy model of each family, so agent definitions don't need editing when Anthropic ships a new version. If the runtime ever stops resolving bare aliases, switch frontmatter to explicit versioned IDs (e.g., `claude-opus-5`, `claude-sonnet-5`) and update this note.

**Per-phase rationale:**

| Agent | Model | Why |
|-------|-------|-----|
| `phase-a-fixer` | `opus` | Heaviest reasoning: reads findings, edits source files across multiple locations, resolves rule conflicts, designs fixes. Quality regressions here cost a full review cycle. |
| `phase-b-reviewer` | `opus` | Evaluates review findings (many are false positives), decides when to dismiss vs. fix, handles multi-reviewer edge cases, judges severity. Needs strong judgment. |
| `phase-c-merger` | `sonnet` | Lightweight verification plus canonical `/wrap` execution: reads PR body, checks boxes against code, runs `gh`/git commands, and reports blockers. Read-only tool restrictions (no Write/Edit) — the mechanical work does not need Opus-level reasoning. |
| `pm-worker` | `sonnet` | Data gathering and formatting: issue creation, repo bootstrap checks. Each task follows a well-defined template. |
| `researcher` | `sonnet` | Read-only exploration and summarization: reads files, runs `gh`/`git` queries, synthesizes findings. No code edits, no fixes — `sonnet` is sufficient for read-and-report work, and the restricted `allowed-tools` frontmatter prevents any write operations regardless of model. |

**Why Fable 5 is not any agent's default:** Fable 5 is the strongest model in the fleet, but no agent defaults to it — the same cost logic that puts `sonnet` on `phase-c-merger` applies in the other direction. Phase spawns run unattended, often several in parallel, and Opus 5 already clears the reasoning bar for the heaviest phase (A/B) work; paying roughly double per spawn buys headroom these phases do not need. Fable 5 is reserved for interactive hardest-work step-ups, where a human is watching the spend and can judge the trade. `/prompt`'s tier ladder is where it is actively recommended (see `.claude/skills/prompt/SKILL.md` "Model Lineup & Effort Levels"). Escalating a specific spawn to `claude-fable-5` is a deliberate exception — document why, and do not make it a default.

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

           MINDSET: Before handing off, enumerate your actual tools (gh/git/curl/gh
           api, MCP, skills) — don't trust inherited 'agents can't' prose. Try the
           CLI-accessible path first. Only hand off for real walls (token-scope 403,
           branch protection, .env, or a safety.md 'Never' item), structured like
           /admin-merge: exact command + one-line reason.

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
