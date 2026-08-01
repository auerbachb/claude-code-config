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

Probe for the config file via the shared parser. `pm-config-get.sh` returns
rc=2 for two distinct conditions it does not itself distinguish — "file
missing" and "file exists but unreadable" (see its EXIT STATUS contract) —
so disambiguate here with a plain existence check before dispatching.
Skipping this check means a permissions glitch or transient filesystem issue
on an *existing* config would be silently overwritten by Step 2's bootstrap.

```bash
CONFIG_FILE=".claude/pm-config.md"
.claude/scripts/pm-config-get.sh --list >/dev/null 2>&1
CONFIG_RC=$?

if [[ "$CONFIG_RC" -eq 0 || "$CONFIG_RC" -eq 1 ]]; then
  MODE="CONFIG_EXISTS"
elif [[ "$CONFIG_RC" -eq 2 && ! -e "$CONFIG_FILE" ]]; then
  MODE="BOOTSTRAP"
else
  MODE="UNREADABLE"
fi
```

`CONFIG_RC` 0 or 1 both mean the file was read successfully (1 just means
zero sections or an empty section body — see the script's EXIT STATUS
contract), so both map to `CONFIG_EXISTS`. Anything else — rc=2 with the
file present, a usage error (rc=3), or any other unexpected exit code — maps
to `UNREADABLE` rather than being silently treated as a healthy config.

- If `MODE == BOOTSTRAP` (file genuinely absent): proceed to Step 2 (create config from repo scan)
- If `MODE == UNREADABLE` (file exists but `pm-config-get.sh` returned an error for it, or returned an exit code outside the documented contract): **STOP.** Tell the user: "`.claude/pm-config.md` exists but could not be read — check file permissions and encoding before continuing." Do NOT proceed to Step 2 — bootstrapping here would silently overwrite the existing file's content, including any user-customized Role/OKRs/Team/Notes sections and any non-canonical sections.
- Otherwise (**CONFIG_EXISTS**): skip to Step 3 (read existing config)

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
1. Check repo state: `gh issue list --state open --limit 500`, `gh pr list --state open`, `gh pr list --state merged --limit 10`
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

**Non-canonical sections (e.g. `Complexity triggers`).** Step 1 now only dispatches here (`MODE == BOOTSTRAP`) when the config file is genuinely absent — an existing-but-unreadable file instead stops with an error (`MODE == UNREADABLE`, see #606) rather than reaching this bootstrap. So this path never has parseable prior sections to work from, and there is nothing to preserve here. If this path is ever extended to regenerate over an existing, successfully-parsed config (rather than only creating a fresh one), it must apply the identical rule `pm-update` uses in its Step 6: Infrastructure and Architecture are always emitted (regenerated unconditionally); the other six canonical sections (Role, OKRs, Workflow Rules, Dependency Rules, Team, Notes) are emitted only if they were actually present in the original config — never fabricate an empty one; and any other section name is re-inserted verbatim, anchored immediately after the nearest canonical section that preceded it in the original file (or at the top if none did). Never silently drop a section absent from the canonical list — see `pm-update/SKILL.md` Step 6 for the full algorithm and worked example.

## Step 3: Read existing config

Parse `.claude/pm-config.md` via the shared parser:

```bash
# Enumerate headers, then fetch each body verbatim.
mapfile -t SECTIONS < <(.claude/scripts/pm-config-get.sh --list 2>/dev/null)
for name in "${SECTIONS[@]}"; do
  body="$(.claude/scripts/pm-config-get.sh --section "$name" 2>/dev/null)"
  # store (name, body) for use in later steps
done
```

`pm-config-get.sh` handles line-anchored `^## ` matching (no mid-line matches), the next-header/EOF boundary, and preserves body content verbatim.

## Step 4: Fetch live GitHub state

Query current repo state:

```bash
# Repo identity
gh repo view --json nameWithOwner,description,url

# Open issues
gh issue list --state open --json number,title,labels,assignees,createdAt --limit 500

# Open PRs
gh pr list --state open --json number,title,headRefName,author,updatedAt,additions,deletions

# Recent merges (last 20)
gh pr list --state merged --limit 20 --json number,title,mergedAt,author
```

**Truncation check:** If the returned issue count equals 500, warn: "Showing 500 issues — repo may have more. Results may be incomplete."

If any command returns empty results, note that gracefully (e.g., "No open issues" rather than failing).

## Step 5: Assemble the handoff prompt

Combine static config with dynamic state into a single prompt. Structure:

```
You are the project manager for {repo URL} — {description}.

You are continuing from a previous PM session. The state below reflects where the previous thread left off. **Verify GitHub state is current before acting on it** — issues may have been closed, PRs merged, or new work started since this handoff was generated.

## Bootstrap steps for this new thread
1. Run `/pm` (without `resume`) to load config and re-scan GitHub state.
2. **Restore orchestration state.** Review the in-flight work table and verify each PR's state before taking action. PR fleet polling is handled separately via `/pr-monitor-and-manage` if needed — `/pm` does not re-arm polls on resume.

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

## Active Polling Jobs
{From Step 5b2 — or "No active polling jobs from other skills. For PR fleet monitoring, run `/pr-monitor-and-manage`." if empty}

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
# Session state (high-level orchestration) — SCOPED to the invoking repo (issue
# #687). A handoff for repo X must not carry repo Y's PRs, so read the repo-scoped
# session view, not `--get .` (which dumps every repo). Resolution reuses
# session-state.sh's precedence (--repo / $CLAUDE_SESSION_REPO / cwd origin).
SESSION_VIEW=$(.claude/scripts/session-state.sh --session-view 2>/dev/null || echo "NO_SESSION_STATE")
echo "$SESSION_VIEW"

# Per-PR handoff files — read ONLY the ones for PRs in this repo's scope. The
# handoff filename is still global (issue #655), so two repos at one PR number
# share a file; gate on the scoped PR set AND verify each payload's repo.
if [ "$SESSION_VIEW" != "NO_SESSION_STATE" ]; then
  SCOPED_PRS=$(jq -r '(.prs // {}) | keys[]' <<<"$SESSION_VIEW" 2>/dev/null)
  CUR_REPO=$(jq -r '.repo // ""' <<<"$SESSION_VIEW" 2>/dev/null)
else
  SCOPED_PRS=""
  CUR_REPO=""
fi
found_handoffs=false
# Read-safe iteration: quoted, one key per line, numeric PR keys only.
while IFS= read -r n; do
  [ -n "$n" ] || continue
  case "$n" in *[!0-9]*) continue ;; esac
  # Resolve handoff path: scoped layout takes priority (issue #655); flat fallback for legacy files.
  or=$([ -f "$HOME/.claude/session-state.json" ] && \
    jq -r --arg n "$n" '(.repos // {}) | to_entries[] | select(.value.prs[$n].owner_repo?) | .value.prs[$n].owner_repo' \
    "$HOME/.claude/session-state.json" 2>/dev/null | head -1 || true)
  if [ -n "$or" ] && [ "$or" != "null" ]; then
    f="$HOME/.claude/handoffs/${or}/pr-${n}-handoff.json"
    [ -f "$f" ] || f="$HOME/.claude/handoffs/pr-${n}-handoff.json"
  else
    f="$HOME/.claude/handoffs/pr-${n}-handoff.json"
  fi
  [ -f "$f" ] || continue
  # A payload naming a different repo than this one is the other repo's handoff
  # colliding on this PR number (#655) — skip it. Null/absent owner_repo is
  # unknown, not a mismatch, so fall back to the PR-number scope.
  ho_repo=$(jq -r '.owner_repo // ""' "$f" 2>/dev/null)
  if [ -n "$ho_repo" ] && [ -n "$CUR_REPO" ] && [ "$ho_repo" != "$CUR_REPO" ]; then
    continue
  fi
  found_handoffs=true
  echo "--- $f ---"
  cat "$f"
done < <(printf '%s\n' "$SCOPED_PRS")
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

### Step 5b2: Capture active polling jobs (informational)

Snapshot any live scheduled jobs owned by **other skills** (`/pr-monitor-and-manage`, `/babysit-pr`, etc.) for informational continuity. `/pm` no longer arms its own polls — do not instruct the new thread to recreate `/pm` polls.

Since issue #827 no skill in this repo registers a cron job, so this section is normally a single line. Still call `CronList` — a job from an older session build, or one a user armed by hand, should be reported rather than assumed away. For each job record `id`, `cron`, `prompt`, and `recurring`.

Format as:

```
### Active Polling Jobs

| Job ID | Schedule | Prompt | Recurring |
|--------|----------|--------|-----------|
| abc123 | 17 * * * * | /some-skill --tick | true |

**On resume:** All `CronCreate` jobs are **session-scoped** and do not survive session turnover — `durable: true` has no effect. Any job listed here died with the previous session; do not use `CronList` to check for survivors, there will be none. Re-arm via the owning skill if needed. For PR fleet monitoring, run `/pr-monitor-and-manage` — a paused fleet resumes from its on-disk marker, not from a job.
```

If `CronList` returns no jobs (the expected case), output: "No active polling jobs from other skills. For PR fleet monitoring, run `/pr-monitor-and-manage`."

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
