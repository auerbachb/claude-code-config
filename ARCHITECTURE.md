# Architecture

Deep-dive reference for the claude-code-config system. For setup instructions and a quick overview, see [README.md](README.md).

## Table of Contents

- [Symlink Topology](#symlink-topology)
- [Skills Worktree](#skills-worktree)
- [Hook Lifecycle](#hook-lifecycle)
- [Hook Auto-Registration](#hook-auto-registration)
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

Skills, rules, and `CLAUDE.md` are served from `~/.claude/skills-worktree/`, a git worktree permanently checked out to `main`. This decouples config availability from the root repo's branch state.

**Why this matters:** Without the worktree, switching the root repo to a feature branch would make skills added after that branch invisible — their symlink targets wouldn't exist on that branch. The worktree always tracks `origin/main`, so all skills are always available regardless of what branch the root repo is on.

**Path layout:**

| Symlink | Target |
|---------|--------|
| `~/.claude/CLAUDE.md` | `~/.claude/skills-worktree/CLAUDE.md` |
| `~/.claude/rules` | `~/.claude/skills-worktree/.claude/rules` |
| `~/.claude/skills/<name>` | `~/.claude/skills-worktree/.claude/skills/<name>` |

**Keeping it fresh:** The `session-start-sync.sh` hook runs once per session (on the first tool call) and syncs the skills worktree to `origin/main`. The `post-merge-pull.sh` hook syncs after merges. Both ensure skills, rules, and `CLAUDE.md` stay current across all repos.

**Initial setup:** `setup-skills-worktree.sh` creates the worktree, symlinks all skills, and registers hooks in `~/.claude/settings.json`. `setup.sh` calls it during installation, then separately merges non-hook settings from `global-settings.json` and verifies the final result. Re-run either script to fix broken symlinks or stale hook paths.

---

## Hook Lifecycle

Five hook scripts in `.claude/hooks/` run automatically during Claude Code sessions:

| Script | Event | When it fires | Purpose |
|--------|-------|--------------|---------|
| `session-start-sync.sh` | PostToolUse | First tool call of session | Syncs skills worktree to `origin/main`, auto-registers new hooks |
| `post-merge-pull.sh` | PostToolUse (Bash) | After `gh pr merge` succeeds | Pulls `main` in root repo, syncs skills worktree |
| `silence-detector.sh` | PostToolUse | Every tool call | Checks if agent has been silent >5 min, injects warning |
| `silence-detector-ack.sh` | Stop | After each response | Touches heartbeat file to reset silence timer |
| `trust-flag-repair.sh` | Stop | After each response | Repairs trust flags in `~/.claude.json` for all projects |

All hooks are idempotent and fail-safe — they handle errors gracefully without interrupting the session.

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

## Session Lifecycle

Each Claude Code session follows this sequence:

1. **Session start** — Pull remote `main`, create a worktree, verify skills worktree exists, check for required GitHub Actions workflows
2. **Issue creation** — Draft issue, post via `gh issue create`, wait for CodeRabbit plan, merge plans into issue body
3. **Implementation** — Code on the worktree's feature branch
4. **Local review** — Run `coderabbit review --prompt-only` until one clean pass
5. **Push and PR** — Commit, push, create PR with `Closes #N` and Test Plan checkboxes
6. **GitHub review** — Poll CR (7-min timeout), fall back to Greptile if needed, fix findings, reply to threads
7. **Merge** — Verify merge gate (1 explicit CR APPROVED review on current HEAD, or Greptile severity gate), verify acceptance criteria, squash merge
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
- When Phase B reports clean, parent launches Phase C
- Phase C verifies acceptance criteria and reports ready for merge
- Parent asks user for merge confirmation

---

## Review Loop

### Phase 1: Local review (primary)

```text
Finish coding on feature branch
       |
       v
Run coderabbit review --prompt-only
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
CR posts findings? --No--> CR rate-limited?
       |                       |            |
      Yes                     Yes           No
       |                       |            |
       v                       v            v
Verify each finding    Check Greptile   Wait for CR
against code           daily budget     completion signal
       |                  |                  |
       v                  v                  v
Fix all findings    Budget OK?          CR APPROVED on HEAD?
in one commit,      Yes: @greptileai         |
push                No: self-review         Yes
       |                  |                  |
       v                  v                  v
Reply to every      Report blocker:     Merge gate met
comment thread      self-review only
       |
       v
Poll again...
repeat until
clean
```

### Three-tier fallback chain

CodeRabbit -> Greptile -> self-review. CR is always preferred. If rate-limited or unresponsive (7-min timeout), Greptile is triggered (budget permitting, 40 reviews/day default cap). If both are unavailable, Claude performs self-review for risk reduction and reports a merge-gate blocker. Self-review does **not** satisfy the merge gate.

---

## Key Design Decisions

**Worktrees by default.** Every session starts by creating a git worktree — an isolated working directory with its own branch. Multiple Claude Code agents can work on the same repo simultaneously without conflicts. The root repo stays clean on `main`.

**Local first, GitHub as safety net.** The CodeRabbit CLI runs reviews instantly in your terminal — no pushing, no polling, no PR noise. Claude fixes everything locally before the PR is ever created. GitHub-based review stays as a fallback.

**Batch fixes, single push.** Every push consumes a CodeRabbit review from your hourly quota. The config instructs Claude to fix all findings in one commit rather than pushing per-finding.

**CI must pass before merge.** All CI check-runs are verified before any merge. Linter suppression comments (`eslint-disable`, `@ts-ignore`, etc.) are prohibited — fix the actual code instead.

**Two consecutive clean reviews (CR path).** Both the local and GitHub loops require two consecutive clean passes. This catches the edge case where CodeRabbit marks a review complete but posts findings shortly after. The Greptile path uses a severity-gated merge gate instead.

**Every PR starts with an issue.** Issues go through CodeRabbit planning (`@coderabbitai plan`) that catches gaps before coding begins. The implementation plan is merged into the issue body as the canonical spec.
