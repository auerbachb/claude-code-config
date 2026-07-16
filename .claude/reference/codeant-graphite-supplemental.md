# CodeAnt & Graphite — Supplemental Reviewers (CR Path)

Full detail extracted from `.claude/rules/cr-github-review.md`. Parallel supplements to the primary chain CR → BugBot → Greptile → self-review.

> **Always:** When CodeAnt or Graphite is enabled, poll `codeant-ai[bot]` and `graphite-app[bot]` on the same three PR endpoints as CodeRabbit; clear threads and blocking CI like other bots.
> **Ask first:** Merging — always ask the user.
> **Never:** Treat Graphite as a merge-gate tier until it posts reliably; avoid spamming `@codeant-ai` / `@graphite-app`.

**CodeAnt (CR path):** If CodeAnt participated on current HEAD (comments or CodeAnt check-run), `merge-gate.sh` needs a clean signal per `cr-merge-gate.md`. Use `@codeant-ai review` to nudge.

**Graphite:** Poll like other bots; not a merge-gate tier until reliable. If silent: check [Graphite app](https://github.com/apps/graphite-app) access, AI review toggle, workspace link, limits; try `@graphite-app re-review` on a test PR.

CodeAnt and Graphite are parallel supplements; the primary chain stays CR → BugBot → Greptile.

## CodeAnt Local CLI

`codeant-cli` (npm) is a separate local/pre-push capability, distinct from the PR-side `codeant-ai[bot]` role above — it does **not** itself satisfy the GitHub merge gate (`cr-merge-gate.md`, `merge-gate-reviewer-paths.md`); treat it as advisory, same as the rest of CodeAnt's supplemental status in this repo.

- Install: `npm install -g codeant-cli` (Node.js/npm required). Auth: `codeant login` (browser OAuth against `app.codeant.ai`); key persisted to `~/.codeant/config.json`.
- `codeant review` scope flags: `--all` (default), `--uncommitted`, `--staged`, `--committed`, `--base <branch>`, `--base-commit <commit>`.
- `--fail-on <severity>`: `BLOCKER` / `CRITICAL` / `MAJOR` / `MINOR` / `INFO` (default `CRITICAL`) — sets the exit-code threshold.
- `--headless`: JSON results on stdout, progress/status on stderr — for agent/CI parsing.
- An MCP server mode and a Claude Code integration also exist (`docs.codeant.ai/cli/mcp-server`, `docs.codeant.ai/cli/claude-code-integration`) — not wired into this repo's workflow yet.
