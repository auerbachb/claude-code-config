# Claude Code + CodeRabbit Workflow

A battle-tested `CLAUDE.md` configuration that teaches [Claude Code](https://docs.anthropic.com/en/docs/claude-code) to collaborate with [CodeRabbit](https://coderabbit.ai) for automated PR planning, code review, and merge workflows — all driven from your terminal.

## What this does

When you drop this `CLAUDE.md` into your project (or `~/.claude/`), Claude Code will automatically:

- **Plan with CodeRabbit** — When starting a GitHub issue, Claude kicks off `@coderabbitai plan` asynchronously, builds its own plan in parallel, then merges the two into a single implementation plan.
- **Review locally first** — After coding, Claude runs CodeRabbit reviews locally via the CLI (`coderabbit review --prompt-only`), fixes all findings, and repeats until clean — all before pushing or creating a PR. No polling, no PR noise, instant feedback.
- **GitHub review as safety net** — After pushing, CodeRabbit still auto-reviews on GitHub. Claude polls for any findings the local review missed and resolves them via the existing GitHub-based loop.
- **Handle rate limits** — Batches fixes into single commits, respects CodeRabbit's 8-reviews/hour and 50-chats/hour Pro tier limits, and backs off when throttled.
- **Verify acceptance criteria** — Before offering to merge, Claude reads every checkbox in the PR's Test Plan section, verifies each against the actual code, and checks them off.
- **Squash and merge** — Clean PRs get squash-merged with branch cleanup, only after user confirmation.

## Why this exists

CodeRabbit and Claude Code are each powerful on their own. Together they catch more bugs, but only if Claude Code knows *how* to interact with CodeRabbit — when to poll, how to parse findings, when to back off on rate limits, and how to properly resolve comment threads.

This config encodes all of that into reusable instructions so you don't have to repeat yourself every session.

## Quick start

### Option 1: Global config (applies to all your projects)

```bash
# Back up your existing CLAUDE.md if you have one
cp ~/.claude/CLAUDE.md ~/.claude/CLAUDE.md.bak 2>/dev/null

# Copy or append
cp CLAUDE.md ~/.claude/CLAUDE.md
```

### Option 2: Per-project config

```bash
# Copy into your project root
cp CLAUDE.md /path/to/your/project/CLAUDE.md
```

Claude Code loads `CLAUDE.md` from the project root first, then `~/.claude/CLAUDE.md` as a fallback. Per-project configs let you customize per repo.

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- [GitHub CLI (`gh`)](https://cli.github.com/) installed and authenticated
- [CodeRabbit](https://coderabbit.ai) installed on your GitHub repo (free or Pro tier)
- [CodeRabbit CLI](https://docs.coderabbit.ai/cli) installed and authenticated:
  ```bash
  curl -fsSL https://cli.coderabbit.ai/install.sh | sh
  coderabbit auth login
  ```

## What's in the config

| Section | What it does |
|---|---|
| **PR & Issue Workflow** | Branch naming, squash-merge policy, issue linking, acceptance criteria rules |
| **Issue Planning Flow** | 7-step flow: read issue, kick off CR plan, build Claude's plan, merge plans, post final plan, start coding |
| **Local CodeRabbit Review Loop** | Primary review workflow — runs CR locally via CLI before pushing, instant feedback, no PR noise |
| **GitHub CodeRabbit Review Loop (Fallback)** | Safety net after PR creation — three-endpoint polling (`issues/` + `pulls/reviews` + `pulls/comments` + commit status checks), rate-limit-aware behavior, feedback processing, comment thread resolution |
| **Completion Flow** | 2 consecutive clean reviews (at least 1 from CR), AC verification, user-confirmed merge |
| **Macroscope Fallback** | When CR is rate-limited, trigger `@macroscope-app review` on the PR as a backup reviewer |
| **Self-Review Fallback** | When both CR and Macroscope are unavailable, Claude reviews the diff itself so the flow doesn't stall |
| **Subagent Context** | Ensures spawned subagents inherit the workflow rules |

## Key design decisions

**Worktrees by default.** Every session starts by creating a git worktree — an isolated working directory with its own branch. This means multiple Claude Code agents can work on the same repo simultaneously without stepping on each other. The root repo stays clean on `main` and is never touched.

**Local first, GitHub as safety net.** The CodeRabbit CLI runs reviews instantly in your terminal — no pushing, no polling, no PR noise. Claude fixes everything locally before the PR is ever created. The GitHub-based review loop stays as a fallback for anything the local review misses (cross-file interactions, CI-only context, etc.).

**Batch fixes, single push.** If the GitHub fallback loop does find issues, every push consumes a CodeRabbit review from your hourly quota. The config instructs Claude to fix all findings from a round in one commit rather than pushing per-finding.

**Verify before merge.** Claude won't offer to merge until it has read the source files and confirmed every acceptance criteria checkbox. This catches regressions introduced during the CR fix loop.

**Two consecutive clean reviews.** Both the local and GitHub loops require two consecutive clean passes before proceeding, with at least one from CodeRabbit. Locally, this means two `coderabbit review --prompt-only` runs with no findings. On GitHub, two `@coderabbitai full review` requests with no findings. When CR is rate-limited, Macroscope can provide one of the two required clean passes.

**Three-tier fallback chain.** CodeRabbit → Macroscope → self-review. CR is always preferred. If rate-limited on GitHub, Macroscope (`@macroscope-app review`) fills in. If both are unavailable, Claude does its own diff review. The flow never stalls.

## Customizing

The config is plain Markdown. Edit it to match your workflow:

- **Change branch naming** — Modify the `issue-N-short-description` pattern in the Branching & Merging section.
- **Adjust polling intervals** — The 60-second interval and 10-minute timeout are in the Polling section.
- **Add autonomy boundaries** — The Autonomy Boundaries section controls which files Claude can fix without asking. Restrict it if you want approval for certain paths.
- **Skip CodeRabbit** — The config auto-detects whether a repo uses CodeRabbit (checks for `.coderabbit.yaml` or past CR comments). If CodeRabbit isn't set up, those sections are skipped automatically.

## How the review loop works

### Phase 1: Local review (primary)

```
Finish coding on feature branch
       |
       v
Run coderabbit review --prompt-only
       |
       v
CR returns findings? ──No──> Run review once more to confirm
       |                              |
      Yes                        Still clean?
       |                              |
       v                             Yes
Fix all valid findings               |
       |                              v
       v                    Local review loop done ✓
Run coderabbit review again          |
       |                              v
       v                    Push branch & create PR
Repeat until clean                    |
                                      v
                            Enter Phase 2 (below)
```

### Phase 2: GitHub review (fallback)

```
PR created, CR auto-reviews on GitHub
       |
       v
Poll for CR comments (60s intervals, 8 min timeout)
       |
       v
CR posts findings? ──No──> CR rate-limited?
       |                       |            |
      Yes                     Yes           No
       |                       |            |
       v                       v            v
Verify each finding    Trigger          Self-review
against code       @macroscope-app       fallback
       |              review               |
       v                |                  |
Fix all findings        v                  v
in one commit,    Poll 10 min for    Review diff for
push              Macroscope         bugs/security/
       |              response       edge cases
       v                |                  |
Reply to every          v                  |
comment thread    Process findings         |
       |          same as CR               |
       v                |                  |
Poll again...           v                  v
repeat until     Wait 15 min, retry  Counts as 1 of 2
clean             @coderabbitai       clean reviews
       |            full review            |
       v                |                  |
2 consecutive clean reviews (≥1 from CR)?<─┘
       |
      Yes
       |
       v
Verify all acceptance criteria checkboxes
       |
       v
Ask user: merge or review diff first?
```

## FAQ

**Why does the config require worktrees?**
Without worktrees, all Claude Code sessions share a single working directory. If two agents are working on the same repo, they see each other's uncommitted changes, overwrite each other's edits, and fight over `git status`. Worktrees give each agent its own isolated directory and branch, backed by the same `.git` database. Push and pull work normally. The only maintenance is occasional cleanup of stale worktrees via `git worktree list` and `git worktree remove`.

**What's the difference between local and GitHub reviews?**
Local reviews run the CodeRabbit CLI in your terminal via `coderabbit review --prompt-only`. They're instant, produce no PR noise, and don't consume your GitHub-based review quota. GitHub reviews happen automatically after you create a PR — CodeRabbit comments directly on the PR, and Claude polls the GitHub API to process findings. The local loop is the primary workflow; GitHub is the safety net.

**Do local reviews count against rate limits?**
Local CLI reviews are separate from GitHub PR reviews. The 8-reviews/hour and 50-chats/hour limits apply to GitHub-based reviews. By catching issues locally first, you'll consume far fewer GitHub reviews.

**Does this work with CodeRabbit's free tier?**
Yes. The CLI and Claude Code plugin work on the free tier. The GitHub-based rate limits in the config are tuned for Pro (8 reviews/hour, 50 chats/hour). Free tier limits are lower — you may want to increase polling timeouts for the GitHub fallback loop.

**What happens when CodeRabbit is slow or down?**
Both the local and GitHub review loops have hard timeouts (2 minutes for CLI, 8 minutes for GitHub polling). When CR is **rate-limited**, Claude falls back to Macroscope (`@macroscope-app review` on the PR) — a backup AI code reviewer that only runs when explicitly triggered. When CR is simply slow or down (not rate-limited), Claude runs a self-review instead. The fallback chain is CR → Macroscope → self-review. If CR responds later (e.g., comments on the PR after the timeout), those findings are processed in the next round.

**Can I use this without CodeRabbit?**
Yes. The config auto-detects CodeRabbit. Without it, Claude falls back to Macroscope (if installed) or self-review, and you still get the PR workflow, branch naming, acceptance criteria verification, and squash-merge flow.

**Does Claude Code actually poll in a loop?**
Only for the GitHub fallback. The `CLAUDE.md` instructions tell Claude to use `gh api` calls in a polling loop for PR-based reviews. The local review loop doesn't need polling — `coderabbit review` returns results directly.

**Why does Claude Code keep polling and never see CR's response?**
This usually happens on clean passes (no findings). When CR has findings, it posts review objects on `pulls/{N}/reviews` which Claude sees. But on clean passes, CR only posts a "✅ Actions performed" ack as an issue comment (`issues/{N}/comments` — a different endpoint) and sets the CI check to green. If you're only polling `pulls/{N}/reviews` and `pulls/{N}/comments`, you'll miss both signals and poll forever. The config instructs Claude to poll all three comment endpoints plus the commit status check (`commits/{SHA}/check-runs` for "CodeRabbit — Review completed") every cycle.

**What if CodeRabbit and Claude disagree?**
During planning, the config tells Claude to pick the best ideas from both plans. During review, Claude verifies every CR finding against the actual code before applying it — it won't blindly apply suggestions that would break things.

## Contributing

Found an edge case or improvement? PRs welcome. This config evolved from real-world usage across multiple repos, but there's always room to handle more scenarios.

## License

MIT
