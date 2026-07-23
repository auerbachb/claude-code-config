# PR MERGE AUTHORIZATION

Do not merge a PR or commit to `main` unless the issue author approved on the PR/issue **or** the user confirmed that approval in chat. If unclear, ask.

**Exception:** `/wrap` / `/merge` / `/pr-monitor-and-manage` = merge auth for that run; no extra merge prompt after gate+AC (see those skills).

---

# EVERY MESSAGE — NON-NEGOTIABLE BEHAVIORS

These apply to EVERY message the parent agent sends to the user. No exceptions, no degradation over time, no skipping after context compaction.

1. **Timestamp prefix.** Start every message with Eastern time (`Mon Mar 16 02:34 AM ET`). **Windows (Git Bash):** `TZ=America/New_York` is often wrong — use PowerShell `TimeZoneInfo` for ET first; **Linux/macOS:** `TZ='America/New_York' date +'%a %b %-d %I:%M %p ET'`. Never estimate — run a command; for elapsed time, compare two outputs.
2. **Active monitoring declaration.** If monitoring background agents, state how many and which PRs at the end of every message.
3. **5-minute heartbeat.** Never go >5 minutes without a status message. During operations touching 4+ files, emit a one-line status after every 3 writes/edits (see `monitor-mode.md` "User Heartbeat" and "File-Write Status Updates" for details).
4. **`/loop` for recurring polls.** Back any "poll/check/watch every N" request with `/loop` (or `CronCreate` for ≥3 concurrent polls / cross-session durability) — never a hand-rolled chain of one-shot wake-ups. Decision tree + pre-exit checklist: `scheduling-reliability.md`.
5. **Dedicated monitor mode.** With active subagents, your ONLY job is orchestration — do NOT do substantive work. See `monitor-mode.md` "Dedicated Monitor Mode" for full rules.

After context compaction, your FIRST action is to reconstruct monitoring state (see "Post-Compaction Recovery" in `monitor-mode.md`) and report it WITH a timestamp.

## Thread title — `[#issue]` prefix

Best-effort: lead the first user message with `[#N]` (or `[#339, #341]`) so tab titles may pick up issue numbers.

## GitHub reference prefix

Whenever referencing a GitHub number in human-facing prose, you **must** prefix it with its type: `PR #1234` or `Issue #1234`. Example: "Blocked on PR #1930: Issue #1931, Issue #1934" — not "Blocked on #1930: #1931, #1934".

**Exceptions** (bare `#N` is correct): GitHub closing keywords (`Closes #123`), commit messages/code, bulk shorthand for 5+ same-type items (`PRs #1234, #1235, #1236, #1237, #1238`), and the thread-title prefix above. Markdown link text still needs the type: `[PR #1234](url)`, not `[#1234](url)`.

---

## AUTONOMOUS WORKFLOW EXECUTION — DO NOT ASK PERMISSION

The workflow is fully autonomous. At every phase transition — local review, push, PR creation, polling, feedback processing, subagent spawning — **proceed immediately without asking the user.** See `subagent-orchestration.md` "Phase Transition Autonomy" for the complete table.

**The ONLY actions that require user permission:**
- Merging (except `/wrap` / `/merge` / `/pr-monitor-and-manage` — see above)
- Respawning a failed subagent

**Monitoring is never permission-gated — babysitting an in-flight PR is the default, never a question.** When a PR is open and not merge-ready, arm the watch yourself and report it; never offer a "watch it / babysit / review it yourself?" menu, and never wait to be told. A CodeRabbit timeout or rate-limit is not a stop-and-ask — it routes autonomously into the escalation chain (BugBot → Greptile → self-review, `cr-github-review.md`). Keep it token-safe: `/loop` (or `CronCreate` for durable/fleet), pausing between ticks and widening on stable-state backoff — never a continuous poll (`scheduling-reliability.md`). Use the existing skills (`/babysit-pr`, `/pr-monitor-and-manage`); add no new machinery. The only authorization left in the babysit→merge loop is the **merge** itself (above; Issue #674).

If you catch yourself composing a "should I...?" question about any workflow step, stop — the answer is always yes. Just do it.

---

## ALWAYS USE A WORKTREE

**At the start of every session, before doing anything else, sync local `main` and enter the correct worktree. The `stale-worktree-warn.sh` hook warns when the branch doesn't match the task issue.**

1. **Pull remote main into local main** (quarantine dirty state first):

   ```bash
   ROOT_REPO=$(.claude/scripts/repo-root.sh) && [[ -d "$ROOT_REPO" ]] || { echo "ERROR: cannot resolve root repo" >&2; exit 1; }
   .claude/scripts/dirty-main-guard.sh --check >/dev/null || .claude/scripts/dirty-main-guard.sh --quarantine
   git -C "$ROOT_REPO" pull origin main --ff-only
   ```

   If the guard reports `quarantined: recovery/dirty-main-*`, name the recovery branch to the user so they know where their prior work lives. If the pull itself fails (e.g. diverged history after quarantine), tell the user — do not force-pull or reset. Full guard contract: `main-hygiene.md`.
2. **Create a worktree** via the `EnterWorktree` tool for isolated work. The branch must include the issue number (`issue-N-*`).

**Do not write code, edit files, stage changes, commit, or push while on `main`. Ever.** If you cannot create a worktree, fall back to `git checkout -b issue-N-short-description`.

**Worktree cleanup:** After merge, remove via `git worktree remove <path>` or let the session exit prompt handle it.

---

## PR & ISSUE WORKFLOW

**The flow is always:** GitHub issue → CR plan (when available) → implementation plan → feature branch → code → local review → push → PR → GitHub review → merge. Never jump straight to coding (full flow: `issue-planning.md`).

**Key rules:**
- **Every PR must link to a GitHub issue.** No exceptions — create one via `gh issue create` first. Use `Closes #N` in the PR body.
- **Every PR must include a Test plan section** with checkboxes for acceptance criteria.
- **We do not use TDD** unless the user explicitly requests it. AC is verified via code review and manual testing.
- **CI must pass before merge** — check-runs procedure: `cr-merge-gate.md` Step 1b.
- **Never suppress linter errors** — fix the actual code, never add suppression comments (`cr-local-review.md`).

**Branching & merging:**
- **NEVER work on `main`.** All code changes happen in worktrees on feature branches. Every change requires: issue → feature branch → PR → squash merge.
- Branch naming: `issue-N-short-description`.
- Always **squash and merge** via `gh pr merge --squash`.
- **Never merge immediately after a rebase or force-push.** Wait for CR to review the rebased commit and confirm clean before merging.

---

## Rule Files (`.claude/rules/`)

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
| `skill-first.md` | Proactive skill matching |

These files auto-load for the parent agent session. **Subagents do NOT auto-load these files.** See `subagent-orchestration.md` for how to pass rules to subagents.

### Rule File Size Guidelines

Rules load every turn. The budget exists for **instruction adherence and maintainability** — redundant or contradictory rules misfire on literal-following models. Limits apply to CLAUDE.md + `.claude/rules/*.md`:

- **Soft warning:** 12,000 words. **Hard fail:** 13,000. **Per-file warning:** >2,000 words; split or extract reference material.
- **Ratchet cap:** `.claude/rules/.budget-soft-cap` must equal `max(current_count + 750, 8500)`. `rule-lint.sh` fails when the corpus exceeds this committed cap, independent of soft/hard checks; run `rule-lint.sh --update-cap` only after intentional cuts.
- **Verify on every PR touching CLAUDE.md or `.claude/rules/`** — condense before merging if it exceeds any enforced limit:

  ```bash
  { cat CLAUDE.md; find .claude/rules -name '*.md' -exec cat {} +; } | wc -w
  ```

**Keep growth out of the corpus.** A fix documents its *rule* here and its mechanism, rationale, and backward-compat notes in `.claude/reference/` — not auto-loaded, so free.

---

## Memory System

Persist durable insights at `~/.claude/projects/*/memory/` (never secrets/tokens/PII). Prefer: repo-specific CR false positives, stakeholder decisions, incident lessons, external dashboards. Skip: code/API details (read code), git facts, content already in rules, ephemeral work (use `~/.claude/handoffs/`). Dedupe and prune stale entries.
