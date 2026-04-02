---
name: pm-handoff
description: Generate a PM handoff prompt for context-window turnover. Captures static config, live GitHub state, in-flight thread state, and memory summary into a self-contained prompt for a fresh PM thread. Bootstraps `.claude/pm-config.md` on first run. Triggers on "pm-handoff", "handoff", "context turnover", "new pm thread", "thread turnover".
argument-hint: "[copy] (optional — copies output to clipboard via pbcopy)"
---

Generate a PM handoff prompt for starting or continuing a PM orchestration thread. This prompt is self-contained — paste it into a new Claude Code session (web or CLI) and the new thread becomes the project manager for this repo, with full awareness of what the previous PM thread was doing.

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
6. **Do NOT spawn subagents or use the Agent tool to execute work.** Your job is to write prompts and present them to the user. The user will paste them into new Claude Code threads (web or CLI). Only use subagents if the user explicitly asks (e.g., "go ahead and run those", "spin up agents for those").

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

# Recent merges (last 20)
gh pr list --state merged --limit 20 --json number,title,mergedAt,author
```

If any command returns empty results, note that gracefully (e.g., "No open issues" rather than failing).

## Step 5: Assemble the handoff prompt

Combine static config with dynamic state into a single prompt. Structure:

```
You are the project manager for {repo URL} — {description}.

You are continuing from a previous PM session. The state below reflects where the previous thread left off. **Verify GitHub state is current before acting on it** — issues may have been closed, PRs merged, or new work started since this handoff was generated.

Use `/pm` to enter active orchestration mode once you've reviewed the state below.

## Your Role
{Role section from config}

## OKRs
{OKRs section from config, or "None set" if empty/placeholder}

## Workflow
{Workflow Rules section from config}

## Execution Boundary
Do NOT spawn subagents or use the Agent tool to execute work yourself. Write the prompt and present it to the user — they will paste it into a new Claude Code thread. Only use subagents if the user explicitly asks (e.g., "go ahead and run those", "spin up agents for those").

## What's Been Built
{Infrastructure section from config}
{Architecture section from config}

## Dependency Rules
{Dependency Rules section from config}

## Team
{Team section from config, or omit if empty/placeholder}

## In-Flight Work
{From Step 5b — or "No in-flight work detected" if empty}

## Lessons & Context
{From Step 5c — or omit if no memory index found}

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

### Step 5b: Capture in-flight thread state

Scan for orchestration state files:

```bash
# Session state (high-level orchestration)
test -f ~/.claude/session-state.json && cat ~/.claude/session-state.json || echo "NO_SESSION_STATE"

# Per-PR handoff files (emit valid JSON content per file)
found_handoffs=false
for f in ~/.claude/handoffs/pr-*-handoff.json; do
  [ -f "$f" ] || continue
  found_handoffs=true
  echo "--- $f ---"
  cat "$f"
done
$found_handoffs || echo "NO_HANDOFF_FILES"
```

If `session-state.json` exists, extract and summarize:
- Which PRs are tracked and in which phase (A/B/C)
- Which reviewer owns each PR (CR or Greptile)
- Any `needs` or `remaining_work` fields
- Active agents (may be stale — note they need verification)

If handoff files exist, for each one extract:
- PR number, phase completed, reviewer, HEAD SHA
- Files changed, findings fixed count
- Notes field

Format as a readable summary:

```
### In-Flight Work

| PR | Issue | Phase | Reviewer | Status | Last SHA |
|----|-------|-------|----------|--------|----------|
| #88 | #42 | B (Review) | CR | Awaiting review | abc1234 |
| #90 | #55 | A (Fix+Push) | — | Fixes pushed | def5678 |

**Note:** Thread state may be stale. Verify PR status on GitHub before acting.
```

If no state files exist, output: "No in-flight work detected. Starting fresh."

### Step 5c: Memory summary

Locate and read the memory index file:

```bash
# Derive the project memory path from the repo root
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -z "$REPO_ROOT" ]; then
  echo "NO_MEMORY_INDEX"
else
  # The memory path uses the absolute path with slashes replaced by dashes
  REPO_SLUG="$(echo "$REPO_ROOT" | sed 's|^/||; s|/|-|g')"
  MEMORY_PATH="$HOME/.claude/projects/-${REPO_SLUG}/memory/MEMORY.md"
  test -f "$MEMORY_PATH" && cat "$MEMORY_PATH" || echo "NO_MEMORY_INDEX"
fi
```

If the memory index exists, include its entries as a "Lessons & Context" section:

```
## Lessons & Context
These are key learnings from previous sessions (from memory index — not full details):

{Each non-empty line from MEMORY.md as a bullet}
```

If no memory index exists, omit this section entirely.

### Step 5d: Continuation header

The assembled prompt (Step 5 above) already includes the continuation instructions at the top: "You are continuing from a previous PM session..." This tells the receiving thread to verify state before acting.

## Step 6: Output

1. Print the assembled prompt to stdout.
2. If the `copy` argument was provided:
   ```bash
   echo "$PROMPT" | pbcopy 2>/dev/null && echo "--- Copied to clipboard ---" || echo "--- pbcopy not available — copy from above ---"
   ```
3. After the prompt, print a brief summary: "Generated PM handoff prompt for {repo}. {N} open issues, {M} open PRs, {K} recent merges, {J} in-flight PRs included."
