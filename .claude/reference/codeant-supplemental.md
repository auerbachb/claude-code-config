# CodeAnt — Supplemental Reviewer (CR Path)

Full detail extracted from `.claude/rules/cr-github-review.md`. CodeAnt is the parallel supplement on the CR path; the primary chain is in that rule.

> **Always:** When CodeAnt is enabled, poll `codeant-ai[bot]` on the same three PR endpoints as CodeRabbit; clear its threads and blocking CI like other bots.
> **Ask first:** Merging — always ask the user.
> **Never:** Spam `@codeant-ai`.

**CodeAnt (CR path):** If CodeAnt participated on current HEAD (comments or CodeAnt check-run), `merge-gate.sh` needs a clean signal per `cr-merge-gate.md`. To nudge, let `maybe-trigger-ai-review.sh <PR>` post `@codeant-ai review`. On a repo with a review policy the script claims the CodeAnt slot itself (`review-triggers-allowed.sh --claim codeant`) before it posts — never claim separately first: the one-invitation cap would then read the slot as spent and the script would skip the post (`cr-github-review.md` §Per-cycle check).

**Graphite (retired).** The app’s checks, reviews, and comments are excluded from reviewer tracking. An unresolved thread still goes through the same merge gate as any other thread. Read the finding and source, reply with `reply-thread.sh --reviewer graphite` to avoid a trigger mention, then resolve the exact thread ID. The default resolver excludes retired-app threads. The manual `dismiss-stale-bot-changes.sh --include-retired-graphite` path can dismiss stale bot change requests. [Retirement record](ai-review-chain-roles-decision.md#graphite-retirement-1889-2026-11-03)

## CodeAnt Local CLI

`codeant-cli` (npm) is a separate local/pre-push capability, distinct from the PR-side `codeant-ai[bot]` role above — it does **not** itself satisfy the GitHub merge gate (`cr-merge-gate.md`, `merge-gate-reviewer-paths.md`); treat it as advisory, same as the rest of CodeAnt's supplemental status in this repo.

- Install: `npm install -g codeant-cli` (Node.js/npm required). Auth: `codeant login` (browser OAuth against `app.codeant.ai`); key persisted to `~/.codeant/config.json`.
- `codeant review` scope flags: `--all` (default), `--uncommitted`, `--staged`, `--committed`, `--base <branch>`, `--base-commit <commit>`.
- `--fail-on <severity>`: `BLOCKER` / `CRITICAL` / `MAJOR` / `MINOR` / `INFO` (default `CRITICAL`) — sets the exit-code threshold.
- `--headless`: JSON results on stdout, progress/status on stderr — for agent/CI parsing.
- An MCP server mode and a Claude Code integration also exist (`docs.codeant.ai/cli/mcp-server`, `docs.codeant.ai/cli/claude-code-integration`) — not wired into this repo's workflow yet.

### Install state on this machine (updated 2026-07-30, issue #819)

**Binary:** `npm install -g codeant-cli` was run successfully 2026-07-30. `codeant --version` = 0.5.1 at `/opt/homebrew/bin/codeant`.

**Auth:** a rung-5 wall. `codeant login` is a CLI-initiated browser OAuth flow (`app.codeant.ai`) that opens the system browser — no non-interactive path exists, and no MCP browser surface can drive it, so rung 4 does not apply. The CLI also reads an API key from the `CODEANT_API_TOKEN` environment variable (checked before `~/.codeant/config.json`; CLI 0.5.1 source), but no key was stored in shell config, env vars, or `~/.codeant/config.json` (which did not yet exist). Never pass a key as a command-line argument: `codeant set-codeant-api-key <key>` takes it positionally, which leaks it into shell history and process listings.

**Baseline then (historical, 2026-07-30):** `cr-only` — every local review ran CodeRabbit only until auth completed. Auth was later restored; never read this as today's coverage — classify coverage per push from each CLI's verified run (`cr-local-review.md`). The CodeAnt **GitHub App** is independent and unaffected; it continues to satisfy the CR-path merge gate on its own.

**Rung-5 restore runbook (user must run interactively):**

```bash
# Option A — browser OAuth (standard):
codeant login
# Opens app.codeant.ai in your browser; key saved to ~/.codeant/config.json.
# A set CODEANT_API_TOKEN (even a stale one) overrides that saved login, so
# `unset CODEANT_API_TOKEN` in any shell that should use Option A.

# Option B — API key from the CodeAnt dashboard, read silently from the
# terminal into the environment (never typed as an argument, so it stays out
# of shell history and `ps`). Scope it to the shell that runs reviews:
read -rs CODEANT_API_TOKEN && export CODEANT_API_TOKEN
# The export reaches only processes started from this shell. A Claude Code
# session that is already running keeps the environment it started with, so
# exporting or unsetting the token elsewhere changes nothing for it: quit it and
# start Claude Code again from this shell. Same for Option A — a session that
# inherited a stale CODEANT_API_TOKEN must be restarted from a shell where the
# token is unset before it reads the saved login.

# Verify auth (safe — reads org membership, no write):
codeant scans orgs

# Run a proof review. Use the wrapper — it applies every false-clean check
# (stderr error, 403, noFiles, 15-file cap, idle hang) and prints one line:
.claude/scripts/local-review.sh --tool codeant
# exit 0 clean · 1 findings · 3 failed run · 4 timeout · 5 not installed
```

Failure modes once installed: false-clean on API failure and 403 daily-cap — see `local-review-cli-failure-modes.md`.
