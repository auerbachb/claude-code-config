# Claude Code Configuration

A reusable `CLAUDE.md` configuration that teaches [Claude Code](https://docs.anthropic.com/en/docs/claude-code) to collaborate with [CodeRabbit](https://coderabbit.ai) and [Greptile](https://greptile.com) for automated PR planning, code review, and merge workflows — all driven from your terminal.

## What you get

After setup, Claude Code will automatically:

- **Plan before coding** — Kicks off `@coderabbitai plan` on new issues, builds its own plan in parallel, then merges both into one implementation spec.
- **Review locally first** — Runs CodeRabbit reviews via CLI before pushing. No PR noise, instant feedback.
- **GitHub review as safety net** — After pushing, CodeRabbit auto-reviews on GitHub. Claude polls for findings and resolves them. If CodeRabbit is rate-limited or unresponsive, Greptile is triggered as a fallback (budget permitting).
- **Handle rate limits** — Batches fixes into single commits, respects CodeRabbit's hourly limits, falls back to Greptile or self-review when throttled.
- **Verify acceptance criteria** — Before merging, reads every Test Plan checkbox, verifies each against the code, and checks them off.
- **Squash and merge** — Clean PRs get squash-merged with branch cleanup after merge gates pass.

---

## Getting Started

Follow these steps after cloning the repo. All commands assume macOS/Linux.

### Step 1: Clone the repo

```bash
git clone https://github.com/auerbachb/claude-code-config.git
cd claude-code-config
```

Pick a permanent location — the symlinks you create below will point here. If you move the repo later, you'll need to recreate them.

### Step 2: Create the `~/.claude` directory structure

```bash
mkdir -p ~/.claude/skills
```

### Step 3: Symlink `CLAUDE.md` (global instructions)

```bash
ln -sfn "$(pwd)/CLAUDE.md" ~/.claude/CLAUDE.md
```

This gives Claude Code its core instructions in every project. The symlink means pulling updates to this repo automatically updates your config.

### Step 4: Symlink the rule files

```bash
ln -sfn "$(pwd)/.claude/rules" ~/.claude/rules
```

Rule files in `.claude/rules/` auto-load alongside `CLAUDE.md`. They contain the detailed review, planning, safety, and orchestration workflows.

### Step 5: Install global settings (hooks + permissions)

```bash
cp global-settings.json ~/.claude/settings.json
```

> **Why copy instead of symlink?** Unlike the other files, `settings.json` contains absolute paths that must be customized per machine. A symlink would point everyone to the same placeholder paths.

**Then replace all placeholder paths** with the absolute path to your clone:

```bash
# macOS:
sed -i '' 's|/path/to/claude-code-config|'"$(pwd)"'|g' ~/.claude/settings.json

# Linux:
sed -i 's|/path/to/claude-code-config|'"$(pwd)"'|g' ~/.claude/settings.json
```

This file configures:
- **Permissions** — Broad allow rules so Claude operates autonomously without prompting for every tool call.
- **Hooks** — Three shell scripts that run automatically during sessions (see below).
- **Environment variables** — Model preferences and experimental flags.
- **Plugin marketplaces** — Access to official Claude plugins.

> **Important:** All hook paths in `settings.json` must be absolute. Do not use `~/` or relative paths — they are unreliable. If you move the repo, re-run the `sed` command above.

### Step 6: Set up skills worktree

The skills worktree ensures skills are always available regardless of what branch the root repo is on:

```bash
# Run from inside the repo
./setup-skills-worktree.sh
```

This creates a dedicated worktree at `~/.claude/skills-worktree/` pinned to `main` and symlinks all skills to `~/.claude/skills/`. The `post-merge-pull.sh` hook keeps it in sync automatically. If skills ever break, re-run this script.

### Step 7: Install prerequisites

These tools are required for the full workflow:

| Tool | Install | Purpose |
|------|---------|---------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | `npm install -g @anthropic-ai/claude-code` | The CLI / desktop app itself |
| [GitHub CLI (`gh`)](https://cli.github.com/) | `brew install gh && gh auth login` | Issue/PR creation, API calls |
| [CodeRabbit](https://coderabbit.ai) | Install the GitHub App on your repos | AI code review on PRs |
| [CodeRabbit CLI](https://docs.coderabbit.ai/cli) | See below | Local pre-push reviews |

**CodeRabbit CLI install:**

```bash
curl -fsSL https://cli.coderabbit.ai/install.sh | sh
coderabbit auth login
```

The CLI installs to `~/.local/bin/coderabbit`. If it's not in your PATH, the config falls back to the full path.

**Optional: Greptile** — An AI code reviewer used as a fallback when CodeRabbit is rate-limited or unresponsive. Install the [Greptile GitHub App](https://greptile.com) on your repos. Greptile app settings are configured via the Greptile web dashboard (app.greptile.com). The `greptile.md` rule file in this repo tells Claude how to use Greptile as a fallback reviewer.

### Step 8: Set up CodeRabbit for a repo (per-repo)

For each repo where you want the full workflow:

1. Install CodeRabbit on the repo (via GitHub App settings).
2. Optionally add a `.coderabbit.yaml` to the repo root for custom review rules.
3. The config auto-detects whether CodeRabbit is installed. If it's not, those sections are skipped.

### Step 9: Verify your setup

```bash
# Check symlinks point to this repo
ls -la ~/.claude/CLAUDE.md
ls -la ~/.claude/rules
ls -la ~/.claude/skills/

# Check settings file has correct paths (no /path/to/ placeholders)
grep "path/to" ~/.claude/settings.json && echo "ERROR: placeholders remain" || echo "OK: paths look good"

# Check hooks are executable
ls -la "$(pwd)/.claude/hooks/"
```

You should see:
- `~/.claude/CLAUDE.md` → this repo's `CLAUDE.md`
- `~/.claude/rules` → this repo's `.claude/rules`
- Each skill in `~/.claude/skills/` → this repo's `.claude/skills/<name>`
- No `path/to` placeholders in `~/.claude/settings.json`
- Hook scripts with `x` (execute) permission

---

## Per-project override (optional)

The global config applies to all projects. To customize per repo, copy files into the project instead:

```bash
cp CLAUDE.md /path/to/your/project/CLAUDE.md
mkdir -p /path/to/your/project/.claude/rules
cp -R .claude/rules/. /path/to/your/project/.claude/rules/
```

Claude Code loads project-level `CLAUDE.md` first, then falls back to `~/.claude/CLAUDE.md`. Per-project configs let you override specific rules per repo.

---

## What's included

### Config files

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Core instructions — worktree policy, PR workflow, branch naming, acceptance criteria |
| `global-settings.json` | Global user settings — hooks, permissions, env vars, plugin marketplaces |
| `.coderabbit.yaml` | CodeRabbit review configuration |

### Rule files (`.claude/rules/`)

| File | Purpose |
|------|---------|
| `issue-planning.md` | Issue creation flow, CR plan integration, planning flow |
| `cr-local-review.md` | Primary review — runs CR locally via CLI before pushing |
| `cr-github-review.md` | GitHub review — three-endpoint polling, rate limits, thread resolution |
| `greptile.md` | Greptile fallback reviewer + self-review fallback |
| `subagent-orchestration.md` | Multi-agent task decomposition and health monitoring |
| `work-log.md` | Auto-update daily work log on issue create, PR open, PR merge |
| `safety.md` | Destructive command prohibitions, `.env` protection |
| `repo-bootstrap.md` | Auto-provision required GitHub Actions workflows |
| `trust-dialog-fix.md` | Fix trust dialog re-prompting when bypass permissions are enabled |
| `skill-symlinks.md` | Symlink new skills globally after creation |

### Hook scripts (`.claude/hooks/`)

| Script | Trigger | Purpose |
|--------|---------|---------|
| `silence-detector-ack.sh` | Stop (after each response) | Touches a heartbeat file so the detector knows the agent is alive |
| `silence-detector.sh` | PostToolUse (after every tool call) | Checks if the agent has been silent >5 minutes; injects a warning |
| `post-merge-pull.sh` | PostToolUse on Bash | Auto-pulls main after squash merges to keep local main in sync |

### Skills (`.claude/skills/`)

Slash commands you can invoke during a session:

| Command | Purpose |
|---------|---------|
| `/status` | Dashboard of all open PRs with review state and blockers |
| `/continue` | Resume an interrupted review workflow at the first incomplete step |
| `/check-acceptance-criteria` | Verify Test Plan checkboxes against source code |
| `/merge` | Verify merge gate + AC, squash merge, update work log |
| `/lessons` | Extract and save actionable lessons from the current session |
| `/standup` | Generate a standup summary from recent PRs and issues |
| `/prioritize` | Rank backlog issues by business goal impact |
| `/wrap` | End-of-session: verify findings, squash merge, extract lessons, clean up |

### GitHub Actions (`.github/workflows/`)

| Workflow | Purpose |
|----------|---------|
| `cr-plan-on-issue.yml` | Auto-comments `@coderabbitai plan` on new issues for spec refinement |

---

## Key design decisions

**Worktrees by default.** Every session starts by creating a git worktree — an isolated working directory with its own branch. Multiple Claude Code agents can work on the same repo simultaneously without conflicts. The root repo stays clean on `main`.

**Local first, GitHub as safety net.** The CodeRabbit CLI runs reviews instantly in your terminal — no pushing, no polling, no PR noise. Claude fixes everything locally before the PR is ever created. GitHub-based review stays as a fallback.

**Batch fixes, single push.** Every push consumes a CodeRabbit review from your hourly quota. The config instructs Claude to fix all findings in one commit rather than pushing per-finding.

**Three-tier fallback chain.** CodeRabbit → Greptile → self-review. CR is always preferred. If rate-limited or unresponsive, Greptile is used if budget allows. If both are unavailable (or Greptile budget is exhausted), Claude performs self-review for risk reduction and reports a blocker. Self-review does **not** satisfy the merge gate.

**Verify before merge.** Claude won't offer to merge until it has read the source files and confirmed every acceptance criteria checkbox.

**Two consecutive clean reviews (CR path).** When CodeRabbit is the reviewer, both the local and GitHub loops require two consecutive clean passes before proceeding. This catches the edge case where CodeRabbit marks a review complete but posts findings shortly after. The Greptile path uses a severity-gated merge gate instead — no P0 findings means merge-ready after one fix push.

---

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
       v                    Local review loop done
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
Poll for CR comments (60s intervals, 7 min timeout)
       |
       v
CR posts findings? ──No──> CR rate-limited?
       |                       |            |
      Yes                     Yes           No
       |                       |            |
       v                       v            v
Verify each finding    Check Greptile   Wait for CR
against code           daily budget     completion signal
       |                  |                  |
       v                  v                  v
Fix all findings    Budget OK?          2 clean CR passes?
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

---

## FAQ

**Why does the config require worktrees?**
Without worktrees, all Claude Code sessions share a single working directory. If two agents work on the same repo, they overwrite each other's edits. Worktrees give each agent its own isolated directory and branch.

**What's the difference between local and GitHub reviews?**
Local reviews run the CodeRabbit CLI (`coderabbit review --prompt-only`) in your terminal. They're instant and don't consume your GitHub review quota. GitHub reviews happen after PR creation — CodeRabbit comments on the PR, and Claude polls the API to process findings.

**Do local reviews count against rate limits?**
No. Local CLI reviews are separate from GitHub PR reviews. The 8-reviews/hour limit only applies to GitHub-based reviews.

**Does this work with CodeRabbit's free tier?**
Yes. The rate limits in the config are tuned for Pro (8 reviews/hour, 50 chats/hour). Free tier limits are lower — you may want to increase polling timeouts.

**What happens when CodeRabbit is slow or down?**
The local review loop times out after 2 minutes. The GitHub loop times out after 7 minutes and falls back to Greptile (budget permitting). If both are unavailable, Claude runs a self-review and reports a merge-gate blocker.

**Can I use this without CodeRabbit?**
Yes. The config auto-detects CodeRabbit. Without it, Claude uses self-review as a fallback, and you still get the PR workflow, branch naming, acceptance criteria verification, and squash-merge flow. (Greptile is only triggered as a fallback when CodeRabbit is installed but rate-limited or unresponsive.)

**Can I use this without Greptile?**
Yes. Greptile is optional — it's only triggered when CodeRabbit is rate-limited or unresponsive. Without it, the fallback chain is CodeRabbit → self-review.

---

## Customizing

The config is plain Markdown. Edit to match your workflow:

- **Change branch naming** — Modify the `issue-N-short-description` pattern in CLAUDE.md.
- **Adjust polling intervals** — The 60-second interval and 7-minute timeout are in `cr-github-review.md`.
- **Restrict autonomy** — The rules allow Claude to fix all files autonomously. Add restrictions in `CLAUDE.md` if you want approval for certain paths.
- **Skip CodeRabbit** — The config auto-detects. No CodeRabbit = those sections are skipped.

## Troubleshooting

### Claude Code keeps asking for permission even with bypass enabled

This is the most common issue. You've set `"allow": ["*"]` in `~/.claude/settings.json`, but Claude Code still prompts you to approve edits, bash commands, or the trust dialog. There are two independent causes — fix both.

**Cause 1: A project-level `.claude/settings.json` exists in the repo.**

> **Do not use project-level `.claude/settings.json` files for permissions.** This repo previously shipped one and it caused *more* re-prompting, not less.

When a `.claude/settings.json` exists inside a repo (or worktree), Claude Code treats its permissions block as an **override** rather than merging it with `~/.claude/settings.json`. Even with `"allow": ["*"]` in both files, the project-level file's presence interferes with the global wildcard. Four other repos with no project-level settings file work fine on global settings alone — this repo was the only one that re-prompted, and removing the file fixed it.

Related issues: [anthropics/claude-code#17017](https://github.com/anthropics/claude-code/issues/17017), [anthropics/claude-code#13340](https://github.com/anthropics/claude-code/issues/13340), [anthropics/claude-code#27139](https://github.com/anthropics/claude-code/issues/27139).

**Fix:** Delete any `.claude/settings.json` from your repos and rely exclusively on the global settings file (`~/.claude/settings.json`). Use `global-settings.json` from this repo as your template.

```bash
# Find project-level settings files (use . from a repo root, or an absolute path)
find . -name "settings.json" -path "*/.claude/*" -not -path "*/.git/*"

# Inspect each file — if it only contains permissions, it's safe to delete.
# If it has hooks or env vars you want to keep, migrate those to ~/.claude/settings.json first.
find . -name "settings.json" -path "*/.claude/*" -not -path "*/.git/*" \
  -exec sh -c 'echo "== $1 =="; cat "$1"' _ {} \;

# After confirming the files only contain permissions:
find . -name "settings.json" -path "*/.claude/*" -not -path "*/.git/*" -delete
```

**Cause 2: Trust dialog flags reset on new worktrees.**

Every worktree creates a new project entry in `~/.claude.json` with `hasTrustDialogAccepted`, `hasClaudeMdExternalIncludesApproved`, and `hasClaudeMdExternalIncludesWarningShown` all set to `false`. This triggers the trust dialog and external includes approval prompts again.

**Fix:** Run this to set all flags to `true` across all projects:

```bash
python3 -c "
import json, os, sys

path = os.path.expanduser('~/.claude.json')
if not os.path.exists(path):
    print('~/.claude.json not found. Open Claude Code once, then rerun this fix.')
    sys.exit(1)
try:
    with open(path) as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    print(f'Invalid JSON in {path}: {e}')
    print('Repair or restore ~/.claude.json, then re-run this fix.')
    sys.exit(1)

projects = data.get('projects') or {}
if not isinstance(projects, dict):
    print('Invalid ~/.claude.json: \"projects\" must be an object.')
    sys.exit(1)

flags = ['hasTrustDialogAccepted', 'hasClaudeMdExternalIncludesApproved', 'hasClaudeMdExternalIncludesWarningShown']
total = 0
for proj in projects.values():
    if not isinstance(proj, dict): continue
    for flag in flags:
        if not proj.get(flag):
            proj[flag] = True
            total += 1

if total:
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print(f'Fixed {total} flag(s).')
else:
    print('All flags already set.')
"
```

You'll need to re-run this after creating new worktrees. See `.claude/rules/trust-dialog-fix.md` for more details and a single-project variant.

## Contributing

Found an edge case or improvement? PRs welcome. This config evolved from real-world usage across multiple repos.

## License

MIT
