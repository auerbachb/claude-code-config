---
name: pm
description: Generate a self-contained project manager handoff prompt for starting a new thread. Bootstraps a `.claude/pm-config.md` on first run, then combines static config with live GitHub state. Use this whenever you need to start a fresh PM thread, hand off project context to a new session, or generate an orchestration prompt for parallel cloud threads. Triggers on "pm", "project manager", "handoff prompt", "new thread", "thread turnover".
argument-hint: "[copy] (optional — copies output to clipboard via pbcopy)"
---

Generate a PM handoff prompt for starting a new orchestration thread. This prompt is self-contained — paste it into a new Claude Code session (web or CLI) and the new thread becomes the project manager for this repo.

Parse `$ARGUMENTS`:
- If `$ARGUMENTS` contains "copy" or "clipboard", copy the final output to clipboard via `pbcopy` in addition to stdout.
- If empty, output to stdout only.

## Step 1: Detect mode (bootstrap vs. standard)

Check if `.claude/pm-config.md` exists in the current repo:

```bash
test -f .claude/pm-config.md && echo "CONFIG_EXISTS" || echo "BOOTSTRAP"
```

- If **BOOTSTRAP**: proceed to Step 2 (create config from repo scan)
- If **CONFIG_EXISTS**: skip to Step 3 (read existing config)

## Step 2: Bootstrap — create pm-config.md from repo discovery

Only runs on first invocation for a repo. Scan the repo to auto-generate `.claude/pm-config.md`.

### 2a: Get repo identity

```bash
gh repo view --json nameWithOwner,description,url --jq '{name: .nameWithOwner, description: .description, url: .url}'
```

### 2b: Detect infrastructure

Check for infrastructure signals by testing file/directory existence:

| Signal file | Service |
|-------------|---------|
| `railway.toml` or `railway.json` | Railway |
| `vercel.json` or `.vercel/` | Vercel |
| `fly.toml` | Fly.io |
| `render.yaml` | Render |
| `docker-compose.yml` or `Dockerfile` | Docker |
| `supabase/` or `supabase.json` | Supabase |
| `.neon` or references to `neon.tech` in config | Neon DB |
| `netlify.toml` | Netlify |
| `package.json` | Node.js (extract key deps like Next.js, Express, React) |
| `requirements.txt` or `pyproject.toml` or `Pipfile` | Python (extract key deps) |
| `.env.example` | Environment variables (list key names, not values) |

For each detected service, record it with a brief note on its role.

### 2c: Map architecture

Scan the directory structure (depth 2) and identify patterns:

- **Entry points:** `main.py`, `app.py`, `index.ts`, `server.js`, etc.
- **Standard directories:** `src/`, `lib/`, `app/`, `tests/`, `migrations/`, `.github/workflows/`, `frontend/`, `backend/`, `api/`, `web/`, `utils/`
- **Database patterns:** `prisma/`, `drizzle/`, `alembic/`, `migrations/` (numbered SQL files)
- **Test patterns:** `tests/`, `__tests__/`, `cypress/`, `playwright/`, `*.test.*`
- **CI patterns:** `.github/workflows/` (list workflow names)
- **Config files:** `.coderabbit.yaml`, `tsconfig.json`, `pyproject.toml`, etc.

Record the directory layout and notable patterns.

### 2d: Generate pm-config.md

Write `.claude/pm-config.md` with this structure:

```markdown
# PM Config — {repo name}

## Role
You are the project manager for {repo URL} — {repo description}.

You manage the backlog, track progress, write GitHub issues, and generate prompts for parallel cloud threads (Claude Code on the Web) to do the actual coding work. You do NOT write code yourself — you orchestrate.

## OKRs
{Leave empty with a placeholder: "No OKRs set. Use `/pm-okr set` to define objectives."}

## Workflow Rules
1. Check repo state: `gh issue list --state open`, `gh pr list --state open`, `gh pr list --state merged --limit 10`
2. Identify what can run in parallel (no dependency conflicts)
3. Write detailed prompts for each thread — each prompt should:
   - Reference the GitHub issue URL
   - Describe what exists in the codebase (relevant files, tables, patterns to reuse)
   - State dependencies that are already met
   - Include: "Follow the full issue planning flow: check issue comments for @coderabbitai plan, merge plans into issue body, then implement. Create a worktree, run local CR review before pushing, create the PR with `Closes #N`."
4. When threads finish, verify PRs merged, then identify next batch
5. Create new GitHub issues when gaps are identified

## Infrastructure
{Auto-detected infrastructure from 2b}

## Architecture
{Auto-detected architecture from 2c}

## Dependency Rules
- Always check what's open before suggesting parallel work
- Never suggest threads that depend on each other
- Prompts must be self-contained (the receiving thread has no prior context)

## Team
{Leave empty with placeholder: "No team members configured. Add GitHub usernames and roles here."}

## Notes
{Leave empty with placeholder: "Add repo-specific context the PM should always know."}
```

Tell the user the config was bootstrapped and they should review/customize the Role, OKRs, Team, and Notes sections.

## Step 3: Read existing config

Parse `.claude/pm-config.md` using line-anchored level-2 headers (`^## ` at column 1). For each header, capture content verbatim until the next `^## ` header (or EOF), then store by header name. Do not split on `## ` appearing mid-line in section bodies.

## Step 4: Fetch live GitHub state

Query current repo state:

```bash
# Repo identity
gh repo view --json nameWithOwner,description,url

# Open issues
gh issue list --state open --json number,title,labels,assignees,createdAt --limit 100

# Open PRs
gh pr list --state open --json number,title,headRefName,author,updatedAt,additions,deletions

# Recent merges (last 10)
gh pr list --state merged --limit 10 --json number,title,mergedAt,author
```

If any command returns empty results, note that gracefully (e.g., "No open issues" rather than failing).

## Step 5: Assemble the handoff prompt

Combine static config with dynamic state into a single prompt. Structure:

```
You are the project manager for {repo URL} — {description}.

## Your Role
{Role section from config}

## OKRs
{OKRs section from config, or "None set" if empty/placeholder}

## Workflow
{Workflow Rules section from config}

## What's Been Built
{Infrastructure section from config}
{Architecture section from config}

## Dependency Rules
{Dependency Rules section from config}

## Team
{Team section from config, or omit if empty/placeholder}

## Current State
{Format as actionable lists:}

### Open Issues ({count})
{List each: "- #N — Title [labels] (assigned: @user or unassigned)"}

### Open PRs ({count})
{List each: "- PR #N — Title (by @author, +adds/-dels)"}

### Recently Merged ({count})
{List each: "- PR #N — Title (merged {date} by @author)"}

## Notes
{Notes section from config, or omit if empty/placeholder}
```

## Step 6: Output

1. Print the assembled prompt to stdout.
2. If the `copy` argument was provided:
   ```bash
   echo "$PROMPT" | pbcopy 2>/dev/null && echo "--- Copied to clipboard ---" || echo "--- pbcopy not available — copy from above ---"
   ```
3. After the prompt, print a brief summary: "Generated PM handoff prompt for {repo}. {N} open issues, {M} open PRs, {K} recent merges included."
