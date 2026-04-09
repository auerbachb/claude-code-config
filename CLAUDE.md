# EVERY MESSAGE — NON-NEGOTIABLE BEHAVIORS

These apply to EVERY message the parent agent sends to the user. No exceptions, no degradation over time, no skipping after context compaction.

1. **Timestamp prefix.** Start every message with Eastern time (`Mon Mar 16 02:34 AM ET`). Get via: `TZ='America/New_York' date +'%a %b %-d %I:%M %p ET'`. NEVER estimate timestamps — always run the `date` command.
2. **Active monitoring declaration.** If monitoring background agents, state how many and which PRs at the end of every message.
3. **5-minute heartbeat.** Never go >5 minutes without a status message. See `subagent-orchestration.md` "User Heartbeat" for detailed rules.
4. **Dedicated monitor mode.** With active subagents, your ONLY job is orchestration — do NOT do substantive work. See `subagent-orchestration.md` "Dedicated Monitor Mode" for full rules.

After context compaction, your FIRST action is to reconstruct monitoring state (see "Post-Compaction Recovery" in `subagent-orchestration.md`) and report it WITH a timestamp.

---

## AUTONOMOUS WORKFLOW EXECUTION — DO NOT ASK PERMISSION

The workflow is fully autonomous. At every phase transition — local review, push, PR creation, polling, feedback processing, subagent spawning — **proceed immediately without asking the user.** See `subagent-orchestration.md` "Phase Transition Autonomy" for the complete table.

**The ONLY actions that require user permission:**
- Merging the PR
- Respawning a failed subagent

If you catch yourself composing a "should I...?" question about any workflow step, stop — the answer is always yes. Just do it.

---

## ALWAYS USE A WORKTREE

**At the start of every session, before doing anything else, sync local `main` and then create a worktree.**

1. **Pull remote main into local main:**

   ```bash
   ROOT_REPO=$(git worktree list | head -1 | awk '{print $1}')
   git -C "$ROOT_REPO" pull origin main --ff-only
   ```

   If the pull fails (e.g., diverged history), tell the user — do not force-pull or reset.
2. **Create a worktree** via the `EnterWorktree` tool for isolated work.

**Do not write code, edit files, stage changes, commit, or push while on `main`. Ever.** If you cannot create a worktree, fall back to `git checkout -b issue-N-short-description`.

**Worktree cleanup:** After merge, remove via `git worktree remove <path>` or let the session exit prompt handle it.

---

## PR & ISSUE WORKFLOW

**The flow is always:** GitHub issue → CR plan → implementation plan → feature branch → code → local review → push → PR → GitHub review → merge. Never jump straight to coding. See `issue-planning.md` for the full issue creation and planning flow.

**Key rules:**
- **Every PR must link to a GitHub issue.** No exceptions — create one via `gh issue create` first. Use `Closes #N` in the PR body.
- **Every PR must include a Test plan section** with checkboxes for acceptance criteria.
- **We do not use TDD** unless the user explicitly requests it. AC is verified via code review and manual testing.
- **CI must pass before merge.** See `cr-github-review.md` "CI Must Pass Before Merge" for the check-runs verification procedure.
- **Never suppress linter errors.** See `cr-local-review.md` "Never Suppress Linter Errors" — fix the actual code, never add suppression comments.

**Branching & merging:**
- **NEVER work on `main`.** All code changes happen in worktrees on feature branches. Every change requires: issue → feature branch → PR → squash merge.
- Branch naming: `issue-N-short-description`.
- Always **squash and merge** via `gh pr merge --squash --delete-branch`.
- **Never merge immediately after a rebase or force-push.** Wait for CR to review the rebased commit and confirm clean before merging.

---

## Rule Files (`.claude/rules/`)

Detailed workflow rules are split into topic-specific files in `.claude/rules/`:

| File | Contents |
|------|----------|
| `issue-planning.md` | Issue creation flow, CR plan integration, planning flow |
| `cr-local-review.md` | Local CodeRabbit CLI review loop (primary review workflow), linter suppression prohibition |
| `cr-github-review.md` | GitHub CR polling, rate limits, fast-path detection, thread resolution, CI-must-pass gate, completion criteria |
| `greptile.md` | Greptile peer reviewer + CR fallback + self-review fallback |
| `subagent-orchestration.md` | Task decomposition (phases A/B/C), dedicated monitor mode, health monitoring, timestamps, subagent quick-reference |
| `work-log.md` | Auto-update daily work log on issue create, PR open, PR merge |
| `safety.md` | Destructive command prohibitions, .env protection, subagent safety warnings |
| `repo-bootstrap.md` | Auto-provision required GitHub Actions workflows on first touch |
| `trust-dialog-fix.md` | Fix trust dialog re-prompting when bypass permissions are enabled |
| `skill-symlinks.md` | Symlink new skills to `~/.claude/skills/` after creation; this repo is source of truth |

These files auto-load for the parent agent session. **Subagents do NOT auto-load these files.** See `subagent-orchestration.md` for how to pass rules to subagents.
