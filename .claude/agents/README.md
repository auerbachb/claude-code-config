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
| `{{REVIEWER}}` | Assigned reviewer (`cr` or `greptile`) | `cr` |
| `{{EXISTING_FINDINGS}}` | Pre-fetched review findings (optional) | JSON or summary text |

## Agent Inventory

| Agent | Phase | Purpose | Tool Restrictions | Default Model |
|-------|-------|---------|-------------------|---------------|
| `phase-a-fixer` | A | Fix findings, push, write handoff | Full access | `opus` |
| `phase-b-reviewer` | B | Poll reviews, fix findings, update handoff | Full access | `opus` |
| `phase-c-merger` | C | Verify merge gate, check AC, report readiness | Read-only + Bash (for `gh`) | `sonnet` |
| `pm-worker` | — | Issue management, work-log, repo bootstrap | Full access | `sonnet` |

### Model Selection

Each agent definition declares a default `model` in frontmatter. The parent must also set `model` explicitly at every Agent tool call site per `.claude/rules/subagent-orchestration.md` "Model Selection" — the call-site parameter overrides the frontmatter default and keeps cost decisions visible at every spawn point.

**Per-phase rationale:**

| Agent | Model | Why |
|-------|-------|-----|
| `phase-a-fixer` | `opus` | Heaviest reasoning: reads findings, edits source files across multiple locations, resolves rule conflicts, designs fixes. Quality regressions here cost a full review cycle. |
| `phase-b-reviewer` | `opus` | Evaluates review findings (many are false positives), decides when to dismiss vs. fix, handles multi-reviewer edge cases, judges severity. Needs strong judgment. |
| `phase-c-merger` | `sonnet` | Lightweight verification: reads PR body, checks boxes against code, runs `gh` commands. Read-only tool restrictions (no Write/Edit) — the mechanical work does not need Opus-level reasoning. |
| `pm-worker` | `sonnet` | Data gathering and formatting: issue creation, work-log updates, repo bootstrap checks. Each task follows a well-defined template. |

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
           any repo. Do NOT run git clean in ANY directory. Do NOT run destructive
           commands (rm -rf, rm, git checkout ., git stash, git reset --hard) in the
           root repo directory. Stay in your worktree directory at all times.

           Existing findings to fix:
           <paste findings here>"
```

The SAFETY block is mandatory in every subagent prompt (see `.claude/rules/safety.md`). The example above shows where to place it — between the task context and any findings payload.

The agent definition provides the workflow rules. The prompt provides the runtime context. The parent no longer needs to read and embed all rule files manually.

## Adding New Agents

1. Create `<agent-name>.md` in this directory
2. Include frontmatter with `description` and optionally `allowed-tools`
3. Embed only the rules relevant to the agent's responsibilities
4. Document any new placeholders in this README
5. Update the Agent Inventory table above
