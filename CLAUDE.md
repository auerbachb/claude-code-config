# EVERY MESSAGE — NON-NEGOTIABLE BEHAVIORS

Apply to every parent-agent message. No exceptions, no decay, no skipping after compaction.

1. **Timestamp prefix.** Eastern time (`Mon Mar 16 02:34 AM ET`) via `TZ='America/New_York' date +'%a %b %-d %I:%M %p ET'`. NEVER estimate — run `date`.
2. **Active monitoring declaration.** If monitoring background agents, state count + PRs at message end.
3. **5-minute heartbeat.** Never silent for >5 min. During 4+ file ops, one-line status every 3 writes/edits (see `monitor-mode.md`).
4. **`/loop` for recurring polls.** Any "poll/check/watch every N" request → `/loop` (or `CronCreate` for ≥3 concurrent or cross-session). Never hand-rolled one-shot chains. See `scheduling-reliability.md`.
5. **Dedicated monitor mode.** With active subagents, your ONLY job is orchestration — see `monitor-mode.md`.

After compaction, FIRST reconstruct monitoring state (see `monitor-mode.md` "Post-Compaction Recovery") and report WITH a timestamp.

---

## AUTONOMOUS WORKFLOW EXECUTION — DO NOT ASK PERMISSION

Every phase transition — local review, push, PR creation, polling, feedback, subagent spawn — proceeds immediately without asking. See `subagent-orchestration.md` "Phase Transition Autonomy".

**Only actions that need user permission:** merging the PR; respawning a failed subagent.

If you compose "should I...?" about any workflow step, stop — the answer is yes. Do it.

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

**Flow:** issue → CR plan → implementation plan → feature branch → code → local review → push → PR → GitHub review → merge. Never jump to coding. See `issue-planning.md`.

**Rules:**
- **Every PR links to a GitHub issue** (`Closes #N`); create via `gh issue create` first.
- **Every PR has a Test plan** with checkboxes for AC.
- **No TDD** unless explicitly requested. AC verified via review + manual testing.
- **CI must pass before merge** — see `cr-merge-gate.md`.
- **Never suppress linter errors** — fix the code; see `cr-local-review.md`.
- **NEVER work on `main`.** Worktree + feature branch (`issue-N-short-description`) for every change.
- **Always squash-merge:** `gh pr merge --squash` (the `/wrap` and `/merge` skills handle branch cleanup separately — don't pass `--delete-branch` while the worktree is still on that branch).
- **Never merge immediately after a rebase/force-push** — wait for CR to re-review the new commit.

---

## Rule Files (`.claude/rules/`)

Detailed workflow rules are split into topic-specific files in `.claude/rules/`:

| File | Contents |
|------|----------|
| `issue-planning.md` | Issue + planning flow |
| `cr-local-review.md` | Local CR review |
| `cr-github-review.md` | GitHub review polling |
| `cr-merge-gate.md` | Merge gate |
| `bugbot.md` | BugBot fallback |
| `greptile.md` | Greptile fallback |
| `subagent-orchestration.md` | Subagent spawning |
| `monitor-mode.md` | Monitoring + recovery |
| `scheduling-reliability.md` | Recurring poll safety |
| `handoff-files.md` | Handoff state |
| `phase-protocols.md` | Phase exit protocols |
| `safety.md` | Safety prohibitions |
| `main-hygiene.md` | Dirty-main guard |
| `repo-bootstrap.md` | Repo bootstrap |
| `trust-dialog-fix.md` | Trust flags |
| `skill-symlinks.md` | Skill symlinks |

These files auto-load for the parent agent session. **Subagents do NOT auto-load these files.** See `subagent-orchestration.md` for how to pass rules to subagents.

### Rule File Size Guidelines

Rules consume tokens on every turn. Limits apply to CLAUDE.md + `.claude/rules/*.md`:

- **Soft warning:** 10,000 words.
- **Ratchet cap:** `.claude/rules/.budget-soft-cap` must equal `max(current_count + 250, 8500)`. `rule-lint.sh` fails when the corpus exceeds this committed cap, independent of soft/hard checks; run `rule-lint.sh --update-cap` only after intentional cuts.
- **Hard fail:** 11,000 words.
- **Per-file warning:** >2,000 words; split or extract reference material.
- **Verify on every PR touching CLAUDE.md or `.claude/rules/`:**

  ```bash
  { cat CLAUDE.md; find .claude/rules -name '*.md' -exec cat {} +; } | wc -w
  ```

  If the total exceeds any enforced limit, condense before merging.

---

## Memory System

Persisted at `~/.claude/projects/*/memory/`. Save proactively when future sessions will need the info. User requests ("remember this") override heuristics — but never persist secrets, credentials, tokens, or regulated personal data (confirm + redact if asked).

**Save:** repo-specific CR false positives, confirmed user preferences, recurring corrections; non-obvious repo quirks, deadlines, decisions, conventions; external dashboards/docs/systems; incident root causes + fixes.

**Don't save:** code patterns / API signatures (read code); git history facts (use `git log`/`blame`); anything already in CLAUDE.md or rule files; ephemeral task state (use `~/.claude/handoffs/`); one-off details.

Check for duplicates before writing. Update or remove stale memories when encountered.
