# Setup Test Suite

Automated tests for `setup.sh` and `setup-skills-worktree.sh` running in a clean Linux Docker container.

## Quick Start

From the **repo root** (not the `tests/` directory):

```bash
docker build -f tests/Dockerfile -t claude-config-test .
docker run --rm claude-config-test
```

Exit code 0 = all tests passed. Exit code 1 = at least one failure.

## What It Tests

| # | Scenario | Description |
|---|----------|-------------|
| 1 | Fresh install | Empty `~/.claude/` → all symlinks, settings, hooks created |
| 2 | Idempotent re-run | Second run produces no changes or errors |
| 3 | Settings preserved + re-seeded | Custom keys survive; removed template keys are re-seeded |
| 4 | Hook path migration | Stale root-repo paths updated to skills-worktree |
| 5 | Broken symlink recovery | Deleted symlinks recreated on re-run |
| 6 | Hook resolution | Every hook path in settings.json exists and is executable |
| 7 | No settings.json | File created from scratch with correct content |

## What It Doesn't Test

These require a running Claude Code session with an API key:

- Session-start hook sync (`session-start-sync.sh` firing on first tool call)
- New hook propagation (adding to `global-settings.json` → auto-registered next session)
- Runtime hook execution (hooks actually firing at Stop/PostToolUse events)

## Debugging

Run with an interactive shell to inspect state:

```bash
docker run --rm -it --entrypoint bash claude-config-test
# Then run tests manually:
bash tests/test-setup.sh
# Or run setup.sh directly:
bash setup.sh
```
