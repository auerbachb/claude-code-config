# CodeAnt — Supplemental Reviewer (CR Path)

Full detail extracted from `.claude/rules/cr-github-review.md`. CodeAnt is the parallel supplement on the CR path; the primary chain is in that rule.

> **Always:** When CodeAnt is enabled, poll `codeant-ai[bot]` on the same three PR endpoints as CodeRabbit; clear its threads and blocking CI like other bots.
> **Ask first:** Merging — always ask the user.
> **Never:** Spam `@codeant-ai`.

**CodeAnt (CR path):** If CodeAnt participated on current HEAD (comments or CodeAnt check-run), `merge-gate.sh` needs a clean signal per `cr-merge-gate.md`. Use `@codeant-ai review` to nudge.

**Graphite (retired 2026-11-03):** Graphite was a second supplemental reviewer until its Team plan was cancelled and refunded; agents no longer poll, trigger, reply to, or wait for it. History: `ai-review-chain-roles-decision.md` §Graphite retirement and `codeant-supplemental-hotspot-decision.md`.

## CodeAnt Local CLI

`codeant-cli` (npm) is a separate local/pre-push capability, distinct from the PR-side `codeant-ai[bot]` role above — it does **not** itself satisfy the GitHub merge gate (`cr-merge-gate.md`, `merge-gate-reviewer-paths.md`); treat it as advisory, same as the rest of CodeAnt's supplemental status in this repo.

- Install: `npm install -g codeant-cli` (Node.js/npm required). Auth: `codeant login` (browser OAuth against `app.codeant.ai`); key persisted to `~/.codeant/config.json`.
- `codeant review` scope flags: `--all` (default), `--uncommitted`, `--staged`, `--committed`, `--base <branch>`, `--base-commit <commit>`.
- `--fail-on <severity>`: `BLOCKER` / `CRITICAL` / `MAJOR` / `MINOR` / `INFO` (default `CRITICAL`) — sets the exit-code threshold.
- `--headless`: JSON results on stdout, progress/status on stderr — for agent/CI parsing.
- An MCP server mode and a Claude Code integration also exist (`docs.codeant.ai/cli/mcp-server`, `docs.codeant.ai/cli/claude-code-integration`) — not wired into this repo's workflow yet.

### Install state on this machine (updated 2026-07-30, issue #819)

**Binary:** `npm install -g codeant-cli` was run successfully 2026-07-30. `codeant --version` = 0.5.1 at `/opt/homebrew/bin/codeant`.

**Auth:** a rung-5 wall. `codeant login` is a CLI-initiated browser OAuth flow (`app.codeant.ai`) that opens the system browser — no non-interactive path exists, and no MCP browser surface can drive it, so rung 4 does not apply. The CLI also accepts `codeant set-codeant-api-key <key>` (no browser), but no API key is stored in shell config, env vars, or `~/.codeant/config.json` (which does not yet exist).

**Current baseline:** `cr-only` — every local review runs CodeRabbit only until auth completes. The CodeAnt **GitHub App** is independent and unaffected; it continues to satisfy the CR-path merge gate on its own.

**Rung-5 restore runbook (user must run interactively):**

```bash
# Option A — browser OAuth (standard):
codeant login
# Opens app.codeant.ai in your browser; key saved to ~/.codeant/config.json.

# Option B — API key (non-interactive, if you have a key from the CodeAnt dashboard):
codeant set-codeant-api-key <your-api-key>

# Verify auth (safe — reads org membership, no write):
codeant scans orgs

# Run a proof review. Use the wrapper — it applies every false-clean check
# (stderr error, 403, noFiles, 15-file cap, idle hang) and prints one line:
.claude/scripts/local-review.sh --tool codeant
# exit 0 clean · 1 findings · 3 failed run · 4 timeout · 5 not installed
```

Failure modes once installed: false-clean on API failure and 403 daily-cap — see `local-review-cli-failure-modes.md`.
