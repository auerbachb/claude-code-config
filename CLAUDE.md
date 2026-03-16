## ALWAYS USE A WORKTREE — READ THIS FIRST

**At the start of every session, before doing anything else, create a worktree.**

Tell the user: "I'll create a worktree for isolated work." Then use the `EnterWorktree` tool (or ask the user to say "use a worktree"). This gives you your own working directory and branch — completely isolated from the root repo and from any other agents.

**Why this is mandatory:**
- The root repo directory stays clean on `main`. You never touch it.
- Multiple agents get separate worktrees — no shared working directory, no overwriting each other's files.
- Each worktree has its own branch, its own staged files, its own uncommitted changes.
- Push and pull work normally — worktrees share the same remote.

**Do not write code, edit files, stage changes, commit, or push while on `main`. Ever.** If for any reason you cannot create a worktree, fall back to creating a feature branch manually (`git checkout -b issue-N-short-description`) before touching any files.

**Worktree cleanup:** After your PR is merged, remove the worktree via `git worktree remove <path>` or let the session exit prompt handle it. Periodically run `git worktree list` to check for stale worktrees.

---

## PR & Issue Workflow

### Issues — MANDATORY before any code work

- **Every PR must link to a GitHub issue. No exceptions.** If no issue exists, create one via `gh issue create` before writing any code, creating a branch, or making any changes.
- **Why this is non-negotiable:** Issues go through a CR planning review (`@coderabbitai plan`) that catches logic errors, identifies edge cases, and produces a refined spec — all before a single coding token is spent. Skipping the issue means skipping this spec refinement, which leads to wasted coding effort on poorly defined tasks.
- **The flow is always:** Create issue -> CR reviews/refines the spec -> plan implementation -> create branch -> write code -> PR. Never jump straight to coding.
- Use `Closes #N` in the PR body to auto-close the issue on merge.
- If the user asks you to make a change and there's no existing issue, **create the issue first**, then proceed with the Issue Planning Flow (see `.claude/rules/issue-planning.md`). Do not treat "quick fixes" or "small changes" as exceptions — the issue is the record of what was done and why.

### Acceptance Criteria
- Every PR must include a **Test plan** section with checkboxes for acceptance criteria.
- Before merging, verify each item against the actual code and **check off** every box in the PR description.
- If an item can't be verified from code alone (e.g. visual/runtime behavior), note that it requires manual testing.

### Testing Approach
- We do **not** use TDD unless the user explicitly requests it.
- Acceptance criteria are verified via code review and manual testing after deploy, not automated test suites.
- When verifying, read the relevant source files and confirm the logic satisfies each criterion.

### Branching & Merging
- **NEVER work on `main` — not editing, not committing, not pushing.** All code changes happen in worktrees on feature branches. If you're not in a worktree, create one first. If `git branch --show-current` returns `main`, do not touch any files.
- **Every change requires: GitHub issue -> feature branch -> PR -> squash merge.** No exceptions.
- Branch naming: `issue-N-short-description` (e.g. `issue-10-nav-welcome-header`).
- Always **squash and merge** via `gh pr merge --squash --delete-branch`, then delete the branch.
- **Never merge immediately after a rebase or force-push.** Even trivial conflict resolutions (e.g. a single import line) trigger a new CR review cycle. Always wait for CR to review the rebased commit and confirm no findings before merging. The safe flow is: resolve conflict -> force-push -> wait for CR -> confirm clean -> merge.

---

## Rule Files (`.claude/rules/`)

Detailed workflow rules are split into topic-specific files in `.claude/rules/`:

| File | Contents |
|------|----------|
| `issue-planning.md` | Issue creation flow, CR plan integration, planning flow |
| `cr-local-review.md` | Local CodeRabbit CLI review loop (primary review workflow) |
| `cr-github-review.md` | GitHub CR polling, rate limits, fast-path detection, thread resolution, completion criteria |
| `macroscope.md` | Macroscope fallback + self-review fallback |
| `subagent-orchestration.md` | Task decomposition (phases A/B/C), health monitoring, timestamps, subagent quick-reference |

These files auto-load for the parent agent session. **Subagents do NOT auto-load these files.** See `subagent-orchestration.md` for how to pass rules to subagents.
