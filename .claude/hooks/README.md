# Claude Code Hooks

This directory contains Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) that automate workflow tasks.

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

## silence-detector.sh + silence-detector-ack.sh

Enforces the 5-minute heartbeat rule. If the agent goes >5 minutes without sending a visible message to the user, a warning is injected into the agent's context after every tool call until a message is sent.

**How it works:** Two hooks work together:
- **`silence-detector-ack.sh`** (Stop hook): Fires when Claude finishes a response. Touches a heartbeat file in `/tmp` to record the timestamp.
- **`silence-detector.sh`** (PostToolUse hook, all tools): After every tool call, checks the heartbeat file's mtime. If >5 min elapsed, injects a warning via `additionalContext` that the agent sees.

The heartbeat file is session-scoped (`/tmp/claude-heartbeat-$CLAUDE_SESSION_ID`) and cleaned up automatically by the OS.

### Setup

Add the following entries to your **global** `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/absolute/path/to/claude-code-coderabbit/.claude/hooks/silence-detector-ack.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/absolute/path/to/claude-code-coderabbit/.claude/hooks/silence-detector.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

Replace `/absolute/path/to/claude-code-coderabbit` with the actual path to your clone of this repo.

### Prerequisites

- All hook scripts must be executable: `chmod +x .claude/hooks/silence-detector*.sh`
