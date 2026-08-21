# Architecture

Deep-dive reference for the claude-code-config system. For setup instructions and a quick overview, see [README.md](README.md).

## Table of Contents

- [Symlink Topology](#symlink-topology)
- [Skills Worktree](#skills-worktree)
- [Hook Lifecycle](#hook-lifecycle)
- [Hook Auto-Registration](#hook-auto-registration)
- [Status Line](#status-line)
- [Session Lifecycle](#session-lifecycle)
- [Multi-Agent Orchestration](#multi-agent-orchestration)
- [Review Loop](#review-loop)
- [Key Design Decisions](#key-design-decisions)

---

## Symlink Topology

Most user-facing config in `~/.claude/` is symlinked into a dedicated skills worktree (e.g., `CLAUDE.md`, `rules/`, `skills/`) — never directly to the root repo.

```text
~/.claude/
  CLAUDE.md          ->  ~/.claude/skills-worktree/CLAUDE.md
  rules/             ->  ~/.claude/skills-worktree/.claude/rules/
  agents/
    phase-a-fixer.md ->  ~/.claude/skills-worktree/.claude/agents/phase-a-fixer.md
    ...              ->  ~/.claude/skills-worktree/.claude/agents/....md
  settings.json         (merged from <repo>/global-settings.json)
  skills/
    pm/              ->  ~/.claude/skills-worktree/.claude/skills/pm/
    standup/         ->  ~/.claude/skills-worktree/.claude/skills/standup/
    ...              ->  ~/.claude/skills-worktree/.claude/skills/.../
  skills-worktree/      (git worktree pinned to main)
```

`settings.json` is the only non-symlink — it's created by `setup.sh` via a merge of `global-settings.json` into any existing settings.

---

## Skills Worktree

Skills, agents, rules, and `CLAUDE.md` are served from `~/.claude/skills-worktree/`, a git worktree permanently checked out to `main`. This decouples config availability from the root repo's branch state.

Note the two shapes. `rules` is a single **directory** symlink; `skills` and `agents` are **real directories holding per-entry symlinks**. That is deliberate: the Claude Code docs state that `.claude/rules/` resolves symlinks but say nothing about symlink-following for `agents/`, so the agents leg mirrors the empirically-proven skills topology rather than betting on undocumented parity (issue #1189, `.claude/reference/portable-skill-resolution.md`).

**Why this matters:** Without the worktree, switching the root repo to a feature branch would make skills added after that branch invisible — their symlink targets wouldn't exist on that branch. The worktree always tracks `origin/main`, so all skills are always available regardless of what branch the root repo is on.

**Path layout:**

| Symlink | Target |
|---------|--------|
| `~/.claude/CLAUDE.md` | `~/.claude/skills-worktree/CLAUDE.md` |
| `~/.claude/rules` | `~/.claude/skills-worktree/.claude/rules` |
| `~/.claude/skills/<name>` | `~/.claude/skills-worktree/.claude/skills/<name>` |
| `~/.claude/agents/<name>.md` | `~/.claude/skills-worktree/.claude/agents/<name>.md` |

**Keeping it fresh:** The `session-start-sync.sh` hook runs once per session (on the first tool call) and syncs the skills worktree to `origin/main`. The `post-merge-pull.sh` hook syncs after merges. Both ensure skills, rules, and `CLAUDE.md` stay current across all repos.

**Initial setup:** `setup-skills-worktree.sh` creates the worktree, symlinks all skills and agent definitions, and registers hooks in `~/.claude/settings.json`. `setup.sh` calls it during installation, then separately merges non-hook settings from `global-settings.json` and verifies the final result. Re-run either script to fix broken symlinks or stale hook paths.

---

## Hook Lifecycle

Multiple hook scripts in `.claude/hooks/` run automatically during Claude Code sessions, covering events from `SessionStart` through `StopFailure`. All hooks are idempotent and fail-safe — they handle errors gracefully without interrupting the session.

For the full per-event roster (canonical, kept in sync with `global-settings.json`), see [`.claude/reference/diagrams/hook-lifecycle.md`](.claude/reference/diagrams/hook-lifecycle.md).

---

## Hook Auto-Registration

Hooks are defined in `global-settings.json` with placeholder paths (e.g., `/path/to/claude-code-config/.claude/hooks/session-start-sync.sh`). Two mechanisms resolve these to real paths:

1. **At install time:** `setup-skills-worktree.sh` resolves placeholders to the skills worktree hooks directory and writes them into `~/.claude/settings.json`.
2. **At session start:** `session-start-sync.sh` reads `global-settings.json` from the skills worktree, compares against `~/.claude/settings.json` by script basename per event, and adds any missing hooks. Existing hooks (including user-customized timeouts) are preserved.

This means new hooks added to the repo are automatically picked up after merging to `main` — no manual re-run of setup needed.

**To add a new hook:**
1. Create the script in `.claude/hooks/`
2. Add the hook entry to `global-settings.json`
3. Merge to `main` — the next session start auto-registers it

---

## Status Line

`statusLine` is a settings surface, not a hook event — a command Claude Code runs on a timer whose stdout is rendered in the footer. Its output goes to the **terminal, never the model's context window**, so what it displays costs zero tokens. That is the point: it shows the facts the agent would otherwise repeat in prose, without paying for them on every subsequent turn (issue #779, FU-3 of [`token-efficiency-audit-2026-07.md`](.claude/reference/token-efficiency-audit-2026-07.md)).

`.claude/scripts/statusline.sh` renders one line:

```text
Sat Aug 1 09:37 PM ET · issue-779-statusline · 2 agents · 1 watcher
```

Counts come from `~/.claude/session-state.json` through `session-state.sh --session-view`, so they are scoped to the invoking repo. There is no network call and no `gh` — it renders on a timer, so it only reads local state, and it always exits 0 so a transient read failure shortens the line instead of breaking the render.

**Deployment mirrors hooks.** The entry lives in `global-settings.json` with the same `/path/to/claude-code-config/...` placeholder, and `register-hooks.py` resolves it to the skills worktree — at install time via `setup-skills-worktree.sh` Step 6b (`--statusline-only`), and at session start via `session-start-sync.sh`, so it lands without a `setup.sh` re-run. A `statusLine` pointing at your own script is never touched, and `padding` / `refreshInterval` survive path repairs. `refreshInterval` is in **seconds** (the harness clamps it to ≥ 1).

**It only renders in a terminal TUI.** The status-line executor lives in Claude Code's interactive render path; a headless session — which is how the Claude desktop app runs the agent — has no footer to draw and never invokes the command. Registering it is still correct (it costs nothing where it is unused), but the token saving only lands in terminal sessions. Evidence: [`usage-limit-signal-audit-2026-07.md`](.claude/reference/usage-limit-signal-audit-2026-07.md) §1.

The status line **supplements** CLAUDE.md's timestamp-prefix rule rather than replacing it — the model still needs the time injected into context to write that prefix, so `timestamp-injector.sh` stays.

---

## Session Lifecycle

Each Claude Code session follows this sequence:

1. **Session start** — Pull remote `main`, create a worktree, verify skills worktree exists, check for required GitHub Actions workflows
2. **Issue creation** — Draft issue, post via `gh issue create`, wait for CodeRabbit plan, merge plans into issue body
3. **Implementation** — Code on the worktree's feature branch
4. **Local review** — Run `coderabbit review --agent` until one clean pass
5. **Push and PR** — Commit, push, create PR with `Closes #N` and Test Plan checkboxes
6. **GitHub review** — Poll CR (7-min timeout), fall back to Greptile if needed, fix findings, reply to threads
7. **Merge** — Verify merge gate (1 explicit CR APPROVED review on current HEAD, 1 clean BugBot pass on current HEAD, or Greptile severity gate), verify acceptance criteria, squash merge
8. **Cleanup** — Delete branch, optionally remove worktree

---

## Multi-Agent Orchestration

For large tasks, work is decomposed into three sequential phases per PR:

| Phase | Scope | Token budget |
|-------|-------|-------------|
| **A: Fix + Push** | Read findings, fix code, commit, push, reply to threads, write handoff file | Heaviest |
| **B: Review Loop** | Poll for reviews, fix new findings, confirm merge gate | Medium |
| **C: Merge Prep** | Verify acceptance criteria checkboxes, report ready for merge | Lightest |

The parent agent stays in **monitor mode** while subagents are active — polling status every ~60 seconds, sending heartbeats, and launching next-phase agents. Structured handoff files (`~/.claude/handoffs/pr-{N}-handoff.json`) transfer detailed state between phases.

**Why three phases?** Subagents have a 32K output token limit. A single agent that reads findings, fixes code, pushes, replies to threads, AND polls for reviews will exhaust its token budget mid-work. Phase decomposition ensures each agent has a focused task it can complete within budget.

**Orchestration flow:**
- Parent launches Phase A subagents (can run in parallel across different PRs)
- When Phase A completes, parent launches Phase B within 60 seconds
- When Phase B reports clean, parent launches Phase C within 60s
- Phase C verifies acceptance criteria and runs `/wrap` (silent auto-merge)
- Post-merge report is the user's first signal — no pre-merge approval pause

---

## Review Loop

### Phase 1: Local review (primary)

```text
Finish coding on feature branch
       |
       v
Run coderabbit review --agent
       |
       v
CR returns findings? --No--> Local review loop done
       |                              |
      Yes                              v
       |                    Push branch & create PR
       v                              |
Fix all valid findings                v
       |                    Enter Phase 2 (below)
       v
Run coderabbit review again
       |
       v
Repeat until clean
```

### Phase 2: GitHub review (fallback)

```text
PR created, CR auto-reviews on GitHub
       |
       v
Poll for CR comments (60s intervals, 7 min timeout)
       |
       v
CR posts findings? --No--> CR rate-limited or 7-min timeout?
       |                       |                   |
      Yes                     Yes                  No
       |                       |                   |
       v                       v                   v
Verify each finding    Check BugBot (5 min)   Wait for CR
against code           on current HEAD        completion + APPROVED
       |                  |                  |
       v                  v                  v
Fix all findings    BugBot clean?       CR APPROVED on HEAD?
in one commit,      Yes: merge gate met      |
push                No: stay on BugBot,     Yes
                    fix findings on it       |
       |                  |                  |
       v                  v                  v
Reply to every      Process findings;   Merge gate met
comment thread      escalate to
       |            Greptile only on
       v            BugBot timeout
Poll again...       (sticky assignment)
repeat until
clean
```

### Three-tier fallback chain

CodeRabbit -> BugBot -> Greptile -> self-review. CR is always preferred. If CR is rate-limited or unresponsive (7-min timeout), check BugBot (auto-runs on every push, 5-min window from push time) first — BugBot is free and its completion signals are reliable. **Once BugBot is the active reviewer it is sticky:** stay on BugBot and process its findings normally, even if it returns issues. Escalate to Greptile only when BugBot itself fails to deliver (5-min timeout from push time), not when BugBot has findings to fix (budget permitting, 40 reviews/day default cap). If all three are unavailable, Claude performs self-review for risk reduction and reports a merge-gate blocker. Self-review does **not** satisfy the merge gate.

---

## Key Design Decisions

**Worktrees by default.** Every session starts by creating a git worktree — an isolated working directory with its own branch. Multiple Claude Code agents can work on the same repo simultaneously without conflicts. The root repo stays clean on `main`.

**Local first, GitHub as safety net.** The CodeRabbit CLI runs reviews instantly in your terminal — no pushing, no polling, no PR noise. Claude fixes everything locally before the PR is ever created. GitHub-based review stays as a fallback.

**Batch fixes, single push.** Every push consumes a CodeRabbit review from your hourly quota. The config instructs Claude to fix all findings in one commit rather than pushing per-finding.

**CI must pass before merge.** All CI check-runs are verified before any merge. Linter suppression comments (`eslint-disable`, `@ts-ignore`, etc.) are prohibited — fix the actual code instead.

**Single explicit CR approval on current HEAD (CR path).** The GitHub CR gate requires one explicit `APPROVED` review whose `commit_id` matches the current HEAD SHA — stale approvals (those on a pre-push SHA) and approvals retracted by a later `CHANGES_REQUESTED` on the same SHA do not count. SHA freshness and explicit-approval-only replace the older 2-pass reliability check. The Greptile path uses a severity-gated merge gate instead.

**Every PR starts with an issue.** Issues go through CodeRabbit planning (`@coderabbitai plan`) that catches gaps before coding begins. The implementation plan is merged into the issue body as the canonical spec.
