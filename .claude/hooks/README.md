# Claude Code Hooks

This directory contains Claude Code [PostToolUse hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) that automate workflow tasks.

## post-merge-pull.sh

Automatically pulls `main` in the root repo after every successful `gh pr merge`. This keeps hardlinked rule files in `~/.claude/rules/` up to date without manual intervention.

**How it works:** When Claude Code runs a Bash command matching `gh pr merge`, this hook detects success and runs `git pull origin main --ff-only` in the root repo (not the worktree).

### Setup

Add the following to your **global** `~/.claude/settings.json` (create the file if it doesn't exist):

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/absolute/path/to/claude-code-coderabbit/.claude/hooks/post-merge-pull.sh",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

Replace `/absolute/path/to/claude-code-coderabbit` with the actual path to your clone of this repo.

### Prerequisites

- `jq` must be installed (`brew install jq` on macOS)
- The repo must have a git remote named `origin` with a `main` branch
- The hook script must be executable: `chmod +x .claude/hooks/post-merge-pull.sh` (the repo tracks it as executable, but some systems may strip the bit on checkout)
