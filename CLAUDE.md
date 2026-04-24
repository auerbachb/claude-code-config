# EVERY MESSAGE — NON-NEGOTIABLE BEHAVIORS

These apply to EVERY message the parent agent sends to the user. No exceptions, no degradation over time, no skipping after context compaction.

1. **Timestamp prefix.** Start every message with Eastern time (`Mon Mar 16 02:34 AM ET`). Get via: `TZ='America/New_York' date +'%a %b %-d %I:%M %p ET'`. NEVER estimate timestamps — always run the `date` command.
2. **Active monitoring declaration.** If monitoring background agents, state how many and which PRs at the end of every message.
3. **5-minute heartbeat.** Never go >5 minutes without a status message. During operations touching 4+ files, emit a one-line status after every 3 writes/edits (see `monitor-mode.md` "User Heartbeat" and "File-Write Status Updates" for details).
4. **Dedicated monitor mode.** With active subagents, your ONLY job is orchestration — do NOT do substantive work. See `monitor-mode.md` "Dedicated Monitor Mode" for full rules.

After context compaction, your FIRST action is to reconstruct monitoring state (see "Post-Compaction Recovery" in `monitor-mode.md`) and report it WITH a timestamp.

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

1. **Pull remote main into local main** (quarantine dirty state first):

   ```bash
   ROOT_REPO=$(.claude/scripts/repo-root.sh 2>/dev/null || true)
   if [[ -z "$ROOT_REPO" || ! -d "$ROOT_REPO" ]]; then
     echo "ERROR: could not resolve root repo path" >&2; exit 1
   fi
   if ! .claude/scripts/dirty-main-guard.sh --check >/dev/null; then
     .claude/scripts/dirty-main-guard.sh --quarantine
   fi
   git -C "$ROOT_REPO" pull origin main --ff-only
   ```

   If the guard reports `quarantined: recovery/dirty-main-*`, mention the recovery branch to the user so they know where their prior work lives. If the pull itself fails (e.g., diverged history after quarantine), tell the user — do not force-pull or reset. See `main-hygiene.md` for the full guard contract.
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
- **CI must pass before merge.** See `cr-merge-gate.md` "CI Must Pass Before Merge" for the check-runs verification procedure.
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
| `cr-github-review.md` | GitHub CR polling, rate limits, fast-path detection, thread resolution, feedback processing, autonomy boundaries |
| `cr-merge-gate.md` | Merge gate definition (CR/BugBot/Greptile paths), CI-must-pass gate, AC verification, merge confirmation |
| `bugbot.md` | BugBot (Cursor) second-tier reviewer, auto-trigger, merge gate contribution |
| `greptile.md` | Greptile last-resort reviewer + CR/BugBot fallback + self-review fallback |
| `subagent-orchestration.md` | Subagent spawning, phase transition autonomy table, token exhaustion, phase A/B/C decomposition |
| `monitor-mode.md` | Dedicated monitor mode, monitor loop, heartbeats, health monitoring, post-compaction recovery |
| `handoff-files.md` | Handoff file schema, session-state.json format, lifecycle (create/update/delete) |
| `phase-protocols.md` | Structured exit report format, Phase A/B/C completion protocol checklists |
| `safety.md` | Destructive command prohibitions, .env protection, subagent safety warnings |
| `main-hygiene.md` | Dirty-main guard, recovery branches, session-start integration, Stop hook |
| `repo-bootstrap.md` | Auto-provision required GitHub Actions workflows on first touch |
| `trust-dialog-fix.md` | Fix trust dialog re-prompting when bypass permissions are enabled |
| `skill-symlinks.md` | Symlink new skills to `~/.claude/skills/` after creation; this repo is source of truth |

These files auto-load for the parent agent session. **Subagents do NOT auto-load these files.** See `subagent-orchestration.md` for how to pass rules to subagents.

### Rule File Size Guidelines

Rules consume tokens on every turn — keep them tight. Limits apply to CLAUDE.md and every file in `.claude/rules/`:

- **Per-file soft cap:** ~150 lines / ~1,500 words. Consider splitting if exceeded.
- **Per-file hard cap:** 200 lines / 2,000 words. Must split — extract a sub-topic into a new rule file.
- **Total budget:** ≤14,000 words across CLAUDE.md + all rule files.
- **Verify on every PR that touches CLAUDE.md or `.claude/rules/`:**

  ```bash
  { cat CLAUDE.md; find .claude/rules -name '*.md' -exec cat {} +; } | wc -w
  ```

  If the total exceeds 14,000, condense before merging.

---

## Memory System

The auto-memory system persists insights across sessions at `~/.claude/projects/*/memory/`. Save memories **proactively** (without being asked) when you encounter information future sessions will need. Explicit user requests ("remember this", "save that") normally override these heuristics, but never persist secrets, credentials, tokens, or regulated/sensitive personal data — if the user asks, confirm before saving and redact sensitive values.

**Save proactively:**
- **Feedback patterns:** CR false positives specific to this repo, user-preferred approaches confirmed across sessions, recurring corrections.
- **Project context:** non-obvious repo quirks, deadlines, stakeholder decisions, undocumented conventions that shape future work.
- **External references:** dashboards, docs, or systems where current state lives but isn't in the repo.
- **Incident lessons:** things that went wrong and the fix — so the next session doesn't repeat the mistake.

**Do NOT save:**
- Code patterns or API signatures — read the current code instead.
- Git history facts — `git log`/`git blame` is authoritative.
- Anything already covered in CLAUDE.md or rule files.
- Ephemeral task state — use handoff files (`~/.claude/handoffs/`) instead.
- One-off details with no expected reuse.

Before creating a memory, check for existing ones to avoid duplicates. Update or remove stale memories when you encounter them.
