---
name: pm-handoff
description: Generate a PM handoff prompt for context-window turnover. Captures static config, live GitHub state, in-flight thread state, and memory summary into a self-contained prompt for a fresh PM thread. Bootstraps and re-scans `.claude/pm-config.md`, preserving user-edited sections. Triggers on "pm-handoff", "handoff", "context turnover", "new pm thread", "refresh pm config", "rescan repo".
argument-hint: "[copy] (optional — copies output to clipboard via pbcopy)"
---

Generate a PM handoff prompt for starting or continuing a PM orchestration thread. This prompt is self-contained — paste it into a new Claude Code session (web or CLI) and the new thread becomes the project manager for this repo, with full awareness of what the previous PM thread was doing.

Resolve the config parser before Step 1:

```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
PM_CONFIG_GET_SH=$(resolve_script pm-config-get.sh || true)
[[ -n "$PM_CONFIG_GET_SH" ]] || { echo "ERROR: pm-config-get.sh not found (checked all three paths) — PM handoff config capture unavailable" >&2; exit 1; }
```

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
"$PM_CONFIG_GET_SH" --list >/dev/null 2>&1
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
{Leave empty with a placeholder: "No OKRs set. Edit this section by hand to define objectives."}

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

## Active work

```ini
# ACTIVE_WORK_CAP=6
```

> Emit the key **commented out**, exactly as above. `active-work-cap.sh` owns the default and every skill file is supposed to avoid restating the number — but a written value wins over the built-in one, so bootstrapping a live `ACTIVE_WORK_CAP=6` into every repo would freeze today's default there forever and a later change to `CAP_DEFAULT` would never reach them. Commented, the knob stays discoverable in the file an operator actually opens, while the script keeps ownership until someone deliberately uncomments it.

- **ACTIVE_WORK_CAP** — repo-wide cap on simultaneously active coding work: your open PRs + live offered chips + running inline pipelines not yet at PR. Positive integer in **[1, 10]**. Absent falls back to the built-in default silently; only a present-but-unparseable or out-of-range value warns on stderr. **`CLAUDE_ACTIVE_WORK_CAP` env overrides** when set. Read via `active-work-cap.sh`.
- **Default 6** — CodeRabbit allows 5 reviews/hour/developer, so past 5 concurrent PRs a PR cannot get one review round per hour and rebase re-review overtakes productive review. Derivation: `.claude/reference/active-work-cap.md`.
- Governing limit is `min(3–4 pipeline ceiling, ACTIVE_WORK_CAP)` — this never raises a thread's own pipeline band.

## Budget

```ini
# daily_credit_budget_usd = 25
```

> Emit the key **commented out**, exactly as above. `credit-budget.sh` owns the default — a written value wins, so bootstrapping a live value would freeze it for the repo. Commented, the knob stays discoverable while the script keeps ownership until someone deliberately uncomments it.

- **daily_credit_budget_usd** — owner's stated daily Anthropic credit overage tolerance (USD). ET calendar day window. **`CLAUDE_DAILY_CREDIT_BUDGET_USD` env overrides** when set. Read via `credit-budget.sh`. Governs Anthropic credit spend only; third-party reviewer-tool costs are tracked separately.
- **Default 25** — $25/day authorized overage. Evaluated against authoritative harness signals only; local token/cost estimation is never used. Gates autonomous dispatch (day mode, refill) only — explicit user chat requests always proceed with a one-line note.

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

**Non-canonical sections (e.g. `Complexity triggers`).** Step 1 now only dispatches here (`MODE == BOOTSTRAP`) when the config file is genuinely absent — an existing-but-unreadable file instead stops with an error (`MODE == UNREADABLE`, see #606) rather than reaching this bootstrap. So this path never has parseable prior sections to work from, and there is nothing to preserve here. If this path is ever extended to regenerate over an existing, successfully-parsed config (rather than only creating a fresh one), it must apply the identical rule the config-refresh path uses in its Step 3f: Infrastructure and Architecture are always emitted (regenerated unconditionally); the other six canonical sections (Role, OKRs, Workflow Rules, Dependency Rules, Team, Notes) are emitted only if they were actually present in the original config — never fabricate an empty one; and any other section name is re-inserted verbatim, anchored immediately after the nearest canonical section that preceded it in the original file (or at the top if none did). Never silently drop a section absent from the canonical list — see Step 3f below for the full algorithm and worked example.

## Step 3: Read and refresh the existing config

This skill is the one place `.claude/pm-config.md` is created (Step 2) or refreshed (this step). The auto-generated sections (Infrastructure, Architecture) are regenerated from the repo's current state; every user-edited section is preserved verbatim. Refreshing here means a handoff prompt is never assembled from stale infrastructure or architecture detection.

**Stale worktree and branch cleanup is not part of this flow.** `/pm-clean` is the sole documented caller of `stale-cleanup.sh` — never invoke it from this skill. Config staleness and workspace staleness are independent concerns with independent skills.

### Section classification

| Section | Type | Behavior on refresh |
|---------|------|---------------------|
| Role | User-edited | Preserved verbatim |
| OKRs | User-edited | Preserved verbatim |
| Workflow Rules | User-edited | Preserved verbatim |
| Dependency Rules | User-edited | Preserved verbatim |
| Team | User-edited | Preserved verbatim |
| Notes | User-edited | Preserved verbatim |
| Infrastructure | Auto-generated | Regenerated from repo scan |
| Architecture | Auto-generated | Regenerated from repo scan |
| Any other section name | Non-canonical | Preserved verbatim, repositioned next to its nearest canonical neighbor (see Step 3f) |

> **"Verbatim" means body content is never rewritten, not that the file round-trips byte-for-byte.** `pm-config-get.sh` trims trailing whitespace from every body it extracts (its documented contract), so a preserved section can come back with trailing blank lines collapsed. That normalization applies uniformly to canonical and non-canonical sections alike and is the only permitted difference — no other edit to a preserved body is ever acceptable.

### Step 3a: Parse existing config into sections

Enumerate section names via the shared parser, then extract each body by name:

**Capture every parser exit code.** This step now feeds a path that can *overwrite* `pm-config.md` (Step 3f), so a read error must never be mistaken for "that section is empty." Process substitution hides `--list`'s status and a bare `2>/dev/null` discards the reason, so read both explicitly:

```bash
# Enumerate headers, then fetch each body verbatim.
SECTION_LIST=$("$PM_CONFIG_GET_SH" --list 2>/tmp/pm-config-list.err); LIST_RC=$?
if (( LIST_RC != 0 && LIST_RC != 1 )); then
  echo "ERROR: pm-config-get.sh --list exited ${LIST_RC} — $(cat /tmp/pm-config-list.err)" >&2
  REFRESH_OK=false            # skip Steps 3b-3g; never write on an unexplained read failure
else
  # `while read` rather than `mapfile` — macOS ships Bash 3.2, which has no mapfile.
  SECTIONS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && SECTIONS+=("$line")
  done <<<"$SECTION_LIST"
  REFRESH_OK=true
  for name in "${SECTIONS[@]}"; do
    [[ -n "$name" ]] || continue
    body="$("$PM_CONFIG_GET_SH" --section "$name" 2>/tmp/pm-config-section.err)"; SEC_RC=$?
    if (( SEC_RC != 0 && SEC_RC != 1 )); then
      echo "ERROR: pm-config-get.sh --section '${name}' exited ${SEC_RC} — $(cat /tmp/pm-config-section.err)" >&2
      REFRESH_OK=false; break   # abort the refresh before anything is written
    fi
    # store (name, body) — reused by Steps 3b-3g and by Steps 4-6
  done
fi
```

Only **0** (section present, non-empty body) and **1** (section missing or body empty) are documented non-error statuses — those two continue. Anything else (2 = config file missing, 3 = usage, or any unexpected code) sets `REFRESH_OK=false`: report the error, **skip Steps 3b-3g entirely so `pm-config.md` is never rewritten from a partial parse**, and continue to Step 4 with whatever sections were read. A failed read degrades the handoff's config capture; it must never corrupt the config itself.

`pm-config-get.sh` handles line-anchored `^## ` matching (no mid-line matches), the next-header/EOF boundary, and preserves body content verbatim. Preserve the file's title line (`# PM Config — ...`) separately — it sits above all `## ` sections.

**Classify each section and record non-canonical anchors.** Compare every name in `SECTIONS` against the canonical list (Role, OKRs, Workflow Rules, Infrastructure, Architecture, Dependency Rules, Team, Notes — the fixed schema in Step 3f):

- **Canonical** — one of the eight names above. Handled by Step 3b (preserved) or Steps 3c-3d (regenerated).
- **Non-canonical** — any other name (e.g. `Complexity triggers`). Store its body verbatim, and record its **anchor**: the nearest canonical section name that precedes it in `SECTIONS`' original order. If no canonical section precedes it (it appears before the first canonical section in the file), anchor it to `TOP` (immediately below the title line, before Role).

The `Active work` and `Budget` sections that Step 2d's bootstrap template emits are **non-canonical by this definition** — neither name is in the eight-name list, so both take the non-canonical path here and are preserved verbatim at their recorded anchors like any other. A config this skill bootstrapped therefore round-trips through a refresh unchanged apart from Infrastructure and Architecture.

Non-canonical sections are never dropped — Step 3f re-inserts each one immediately after its recorded anchor. Sections sharing the same anchor keep their original relative order. Order is **not** guaranteed across different anchors: Step 3f emits canonical sections in the fixed schema order regardless of how they appeared in the original file, so two non-canonical sections anchored to canonical sections that were themselves out of fixed order will follow their anchors' fixed-schema order, not their original file order.

**Duplicate section names are a malformed-config case, not a reassembly case.** `pm-config-get.sh --section "$name"` returns only the *first* occurrence's body — if `SECTIONS` (from `--list`) contains the same name twice (any name, canonical or non-canonical), extracting "by name" cannot recover the second occurrence's actual content; blindly reassembling would silently duplicate the first occurrence's body into both slots and lose the second one. Check for duplicates in `SECTIONS` before proceeding: if found, **skip the refresh entirely** (Steps 3b-3g) and tell the user which header name repeats, so they can fix the file manually — do not guess which occurrence is "correct" or attempt an automatic merge. Then continue to Step 4 with the sections as parsed; a malformed config blocks the *write*, not the handoff.

### Step 3b: Preserve user-edited sections

Store the content of these sections verbatim — do not modify them:
- Role
- OKRs
- Workflow Rules
- Dependency Rules
- Team
- Notes

**Non-canonical sections are preserved the same way.** Any section name not in the canonical list above (see Step 3f) is treated exactly like a user-edited section: store its body content unmodified and never rewrite it. Do not ask the user to re-add it — Step 3f automatically re-inserts it at the anchor recorded in Step 3a. (`pm-config-get.sh` trims trailing whitespace from every extracted body per its documented contract — this applies uniformly to canonical and non-canonical sections and isn't specific to this preservation rule.)

### Step 3c: Re-scan infrastructure

Run the same infrastructure detection as Step 2b:

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
| `package.json` | Node.js (extract key deps) |
| `requirements.txt` or `pyproject.toml` or `Pipfile` | Python (extract key deps) |
| `.env.example` | Environment variables (list key names, not values) |

Generate a new Infrastructure section from the scan results.

### Step 3d: Re-scan architecture

Scan the directory structure (depth 2) and detect:
- Entry points, standard directories, database patterns, test patterns, CI workflows, config files

Same detection logic as Step 2c. Generate a new Architecture section.

### Step 3e: Display diff for review

Before writing, show the user what will change:

1. Compare the current Infrastructure section against the newly scanned version
2. Compare the current Architecture section against the newly scanned version
3. Display changes in a clear format:
   ```
   ### Infrastructure changes
   - Added: Fly.io (detected fly.toml)
   - Removed: Heroku (heroku.yml no longer present)
   - Unchanged: Railway, Vercel, Docker

   ### Architecture changes
   - Added: api/ directory (new)
   - Updated: CI workflows (added deploy.yml)
   ```
4. **Preview the whole reconstructed file, not just those two sections.** Step 3f rewrites `pm-config.md` end to end, so the write can also reorder canonical sections into the fixed schema order, move a non-canonical section to its recorded anchor, and collapse trailing whitespace (Step 3a's note). Build the Step 3f output in memory and `diff` it against the file on disk, then show that diff alongside the summaries above — a confirmation gate that previews only Infrastructure and Architecture is asking the user to approve edits they were never shown.
5. If the reconstructed file is byte-identical to the one on disk: skip Step 3f with the message "Infrastructure and Architecture are unchanged — config is up to date." Do not write the file; continue to Step 3g.
6. If the diff is non-empty, ask the user: "Apply these updates to `.claude/pm-config.md`?" Wait for confirmation before writing — via `AskUserQuestion` when available, prose fallback in headless runs (`ask-menu.md`).
7. If the user declines, do not write. Report "Config refresh declined — no changes written," and continue to Step 4 using the sections as parsed in Step 3a.
8. If the user confirms, proceed to Step 3f to apply them.

### Step 3f: Reassemble and write config

**Gate:** only run this step when `REFRESH_OK` is true (Step 3a), no duplicate header was found (Step 3a), and the user confirmed (Step 3e). Any of those failing means no write happens at all.

**Re-check the file has not changed under you.** Step 3e pauses for a human answer, and the natural thing to do while deciding is to open `pm-config.md` — so the parse this write is built from can be stale by the time the answer arrives. Record the file's hash in Step 3a, immediately before parsing, and compare it again here:

```bash
CONFIG_HASH_BEFORE=$(git hash-object "$CONFIG_FILE")   # Step 3a, before parsing
# ... Steps 3a-3e ...
if [[ "$(git hash-object "$CONFIG_FILE")" != "$CONFIG_HASH_BEFORE" ]]; then
  echo "pm-config.md changed while the refresh was awaiting confirmation — nothing written." >&2
  # Re-run Steps 3a-3e against the new content, or continue to Step 4 without refreshing.
fi
```

On a mismatch, **abort the pending write** and either rebuild the preview from the current file or skip the refresh entirely — never replace content the user edited after seeing the diff. This flow's whole contract is that user edits survive it.

Reconstruct `.claude/pm-config.md` using the fixed schema order below for the eight canonical sections (regardless of the order they appeared in the existing file):

1. Title line (preserved from original)
2. Role (preserved)
3. OKRs (preserved)
4. Workflow Rules (preserved)
5. Infrastructure (regenerated)
6. Architecture (regenerated)
7. Dependency Rules (preserved)
8. Team (preserved)
9. Notes (preserved)

Infrastructure and Architecture are always written — Steps 3c-3d regenerate them unconditionally, regardless of whether they existed in the original file. For the six *preserved* canonical sections (Role, OKRs, Workflow Rules, Dependency Rules, Team, Notes), skip any that wasn't present in the original file — do not fabricate an empty one.

**Re-insert each non-canonical section at its recorded anchor** (from Step 3a):
- A section anchored to `TOP` goes immediately after the title line, before Role.
- A section anchored to a canonical name goes immediately after that canonical section's body in the output — ahead of whatever canonical section is next in the fixed-order list, even if that next section is absent from the file entirely (e.g. `Workflow Rules` not existing doesn't push the anchored section past `Infrastructure`).
- Sections sharing the same anchor keep their original relative order (Step 3a).
- An anchor can only ever be a canonical section that itself appeared in `SECTIONS`, so the "anchor absent from output" case should not occur; if it somehow does, fall back to `TOP`.

*Worked example — this repo's own `pm-config.md`:* the original order is Role, OKRs, **Complexity triggers**, Infrastructure, Architecture, Team, Notes. `Complexity triggers` is non-canonical and anchored to OKRs (its nearest preceding canonical section). `Workflow Rules` and `Dependency Rules` are both absent and skipped. Reassembly emits Role, OKRs, **Complexity triggers**, Infrastructure, Architecture, Team, Notes, in the same content and order as the original — `Complexity triggers` stays pinned immediately after OKRs regardless of which canonical sections around it are present.

Write back to `.claude/pm-config.md`.

### Step 3g: Report config changes

Output a summary showing what changed in the config:

```
## PM Config Refreshed

**Preserved (unchanged):**
- Role, OKRs, Workflow Rules, Dependency Rules, Team, Notes
- Non-canonical sections (if any), kept verbatim and reinserted at their recorded anchor — e.g. "Complexity triggers", "Active work", "Budget"

**Regenerated:**
- Infrastructure: {brief diff — e.g., "added Fly.io, removed Heroku"}
- Architecture: {brief diff — e.g., "detected new api/ directory"}
```

If nothing changed in the auto-generated sections, say so: "Infrastructure and Architecture are unchanged — config is up to date." Either way, continue to Step 4 — the handoff prompt is assembled whether or not the config needed a refresh.

## Step 4: Fetch live GitHub state

Run **§1 Live GitHub state** of `.claude/reference/session-state-collector.md` — the shared collector this skill and `/end` both read from, so the two cannot drift apart on what a handoff sees. It carries the queries and the empty-result handling.

**Surface both truncation warnings it can raise** — one when open issues come back at exactly 500, one when open pull requests do. A handoff that omits the 501st item while reading as complete is the failure those warnings exist to prevent, and it is the receiving thread that pays for it.

Rendering stays here: Step 5's `## Current State` lists are this skill's own shape.

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

Run **§2 Tracked pull requests and their per-PR handoff files** of `.claude/reference/session-state-collector.md`. It carries the repo-scoped `--session-view` read, the per-PR handoff resolution (scoped layout first, flat fallback), the cross-repo PR-number collision guard, and the field list to extract from each source — including the reminder that the `active_agents` map entries (keyed by agent id) are candidates to verify, not current fact.

Render what it returns in this skill's own shape. The table below has a column for the common fields; **`needs` and `remaining_work` do not have one and must not be folded into the `Status` column** — emit each as its own bullet under that PR's row, omitted only when that specific field is empty. They are the only record of what the previous thread knew was still outstanding, and a receiving thread cannot re-derive them from GitHub.

```
### In-Flight Work

| PR | Issue | Phase | Reviewer | Status | Last SHA |
|----|-------|-------|----------|--------|----------|
| #88 | #42 | B (Review) | CR | Awaiting review | abc1234 |
| #90 | #55 | A (Fix+Push) | — | Fixes pushed | def5678 |

- **#88 needs:** {the `needs` field from that PR's handoff — omit this bullet only when `needs` itself is empty}
- **#88 remaining work:** {the `remaining_work` field — its own bullet, omitted independently of `needs`}
- **Active agents (verify — may be stale):** {active_agents entries, or "none recorded"}

**Note:** Thread state may be stale. Verify PR status on GitHub before acting.
```

If no state files exist, output: "No in-flight work detected. Starting fresh."

### Step 5b2: Capture active polling jobs (informational)

Run **§3 Active polling jobs** of `.claude/reference/session-state-collector.md` — jobs owned by **other skills** (`/pr-monitor-and-manage`, `/babysit-pr`, etc.), snapshotted for informational continuity. `/pm` no longer arms its own polls, so do not instruct the new thread to recreate `/pm` polls.

Format as:

```
### Active Polling Jobs

| Job ID | Schedule | Prompt | Recurring |
|--------|----------|--------|-----------|
| abc123 | 17 * * * * | /some-skill --tick | true |

**On resume:** `CronCreate` jobs are **session-scoped** — `durable: true` has no effect (canonical statement: `session-state-collector.md` §3). Do not use `CronList` to check for survivors, there will be none. Re-arm via the owning skill if needed. For PR fleet monitoring, run `/pr-monitor-and-manage` — a paused fleet resumes from its on-disk marker, not from a job.
```

If `CronList` returns no jobs (the expected case), output: "No active polling jobs from other skills. For PR fleet monitoring, run `/pr-monitor-and-manage`."

### Step 5c: Memory summary

Run **§4 Memory index** of `.claude/reference/session-state-collector.md` — it derives the per-project memory path from the repo root and reads the index, emitting `NO_MEMORY_INDEX` when there is none.

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
