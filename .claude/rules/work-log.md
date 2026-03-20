# Work Log Auto-Update

> **Always:** Log issue creates, PR opens, and PR merges to the daily work log file. Check for `work-logs/` directory at session start. Sync worktree log edits back to the root repo.
> **Ask first:** At session start, confirm the work log directory with the user (once only — skip if already known from context).
> **Never:** Skip logging events. Overwrite existing narrative content in the log file. Log to a directory that doesn't exist. Create a `work-logs/` directory. Leave log updates stranded in a worktree.

## Session Start: Detect Work Log Directory

At the start of every session, before any code work:

1. **Find existing `work-logs/` directories** by searching the **main worktree root** (not the current worktree, which may lack shared directories). Get the main worktree path via:

   ```bash
   ROOT_REPO=$(git worktree list --porcelain | awk '/^worktree /{sub(/^worktree /, ""); print; exit}')
   find "$ROOT_REPO" -type d -name "work-logs" -not -path "*/.git/*" -not -path "*/.claude/*"
   ```

   If you are not in a worktree (i.e., working directly in the repo), `$ROOT_REPO` is just the repo root and the find command works the same way.
   **NEVER create a `work-logs/` directory.** Only use directories that already exist. If the find command returns nothing, this rule is a no-op — skip all logging for the session.
2. **If one match is found:** Ask the user once to confirm: "I found a work log directory at `{path}`. I'll log issues, PRs, and merges there — sound good?" If the user already mentioned the work log or it's clear from context, skip the ask and just use it.
3. **If multiple matches are found:** Prefer paths under `docs/` (e.g., `docs/work-logs/` over `work-logs/` at repo root) — a `docs/` location indicates intentional placement. If still ambiguous, ask the user to choose.
4. **If not found:** Do nothing — this rule is a no-op for repos without work logs.
5. **Before writing any log file**, verify the directory exists: `test -d "$WORK_LOG_PATH"`. If it fails, stop — do not create the directory or write to a nonexistent path.

Once confirmed (or inferred), remember the path for the rest of the session. Do not ask again.

## Daily Log File

- **Naming convention:** `session-log-YYYY-MM-DD.md` (e.g., `session-log-2026-03-16.md`)
- **If today's file doesn't exist**, create it with this header:

```markdown
# Session Log — March 16, 2026
```

Generate the date via: `TZ='America/New_York' date +'%B %-d, %Y'`

The file should also include an `## Activity Log` section (added on first event, or included in the header).

- **If today's file already exists**, append to the `## Activity Log` section at the bottom. If the section doesn't exist yet, add it at the end of the file.

## What to Log

Append a timestamped line to `## Activity Log` on each of these events:

| Event | Format |
|-------|--------|
| Issue created | `- {time} ET — Issue #{N} created: {title}` |
| PR opened | `- {time} ET — PR #{N} opened (Issue #{M}): {title} [opened: {open_time}, merged: -, cycles: 0]` |
| PR merged | `- {time} ET — PR #{N} merged (Issue #{M}): {summary} [opened: {open_time}, merged: {merge_time}, cycles: {N}]` |

**Time format:** `2:34 PM` (12-hour, no leading zero). Get via: `TZ='America/New_York' date +'%l:%M %p' | sed 's/^ //'`.

### PR lifecycle fields

Every PR log entry (both opened and merged) must include these fields in a bracketed suffix. At PR open time, use placeholder values for fields not yet known (`merged: -`, `cycles: 0`). At merge time, write the final values in the PR merged entry (do not edit prior Activity Log lines):

1. **`opened`** (`pr_opened_at`) — timestamp when the PR was created (recorded at PR open time)
2. **`merged`** (`pr_merged_at`) — timestamp when the PR was merged or closed (recorded at merge time)
3. **`cycles`** (`review_cycles`) — count of review-then-revise rounds before approval. Each review (bot or human) that triggers a new commit counts as one cycle. A PR that passes review on the first push has `cycles: 0`.

> **Note:** The short names (`opened`, `merged`, `cycles`) are used in Activity Log entries for readability. The parenthesized names are the canonical field identifiers for reference.

This data measures PR throughput, average cycle time, and review friction — informing how many simultaneous PRs can be effectively managed in parallel.

**How to count cycles:** Increment the cycle counter each time any reviewer (bot or human) posts findings that result in a new fix commit. Clean passes and confirmation reviews do not count.

**Determining the count at merge time:** If the cycle count wasn't tracked during the session (e.g., after context compaction or session handoff), reconstruct it from the PR's history: fetch all review objects on `pulls/{N}/reviews` and all commits on `pulls/{N}/commits`. Count each review that is actionable (has inline comments, a body with specific fix requests, or `state: "CHANGES_REQUESTED"`) and is followed by at least one new commit before the next review or merge. Each such review-then-fix pair = 1 cycle. Reviews with no findings (clean passes) do not count.

### PR merge summaries

On PR merge, write a brief 1-line summary of what the PR accomplished in context of the project — not just the PR title. Examples:

```text
- 3:15 PM ET — PR #635 merged (Issue #634): Adds global rule for automatic work log entries so every issue/PR/merge event is captured in real time [opened: 2:30 PM, merged: 3:15 PM, cycles: 2]
```

## Worktree Log Sync

When working in a worktree, any edits to shared docs (session logs, work logs, changelogs, etc.) are local to that worktree. These edits will **not** automatically appear in the root repo after merge unless the file is part of the PR's diff.

**Before pushing any PR or closing the work session, the agent must ensure one of the following:**

1. **Commit the shared doc in the PR branch** — stage and commit the affected shared doc(s) alongside the code changes so they merge with the PR.
2. **Manually sync the log to the root repo** — if the log edits should not be part of the PR (e.g., the log lives in a different repo or on main), append only the missing Activity Log entries to the root repo's copy (do not replace the entire file), then commit separately.

**Never assume a worktree-local edit to a shared doc will "make it back" on its own.** At task completion, verify the root repo's copy is current:

```bash
# ROOT_REPO = first entry from: git worktree list (the main worktree)
# WORKTREE = current working directory (pwd)
# WORK_LOG_PATH = confirmed canonical path from session start (e.g., docs/work-logs)
# Replace YYYY-MM-DD with today's date: $(TZ='America/New_York' date +'%Y-%m-%d')
diff "$WORKTREE/$WORK_LOG_PATH/session-log-YYYY-MM-DD.md" "$ROOT_REPO/$WORK_LOG_PATH/session-log-YYYY-MM-DD.md"
```

If the root repo's copy is missing Activity Log entries, reconcile without overwriting:

- **Preferred:** Include the log file in the PR branch (option 1 above) so Git handles the merge.
- **If manual sync is needed:** Append only the missing Activity Log entries to the root repo's copy — never replace the entire file, as the root copy may have diverged with its own narrative content or entries from other agents.

## Coexistence with Narrative Content

Work log files may contain hand-written narrative sections (project context, design decisions, results). The `## Activity Log` section is **append-only** and lives at the bottom of the file. Never modify or reorder existing content above it.
