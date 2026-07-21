# CodeAnt & Graphite — Supplemental Reviewers (CR Path)

Full detail extracted from `.claude/rules/cr-github-review.md`. Parallel supplements to the primary chain CR → BugBot → Greptile → self-review.

> **Always:** When CodeAnt or Graphite is enabled, poll `codeant-ai[bot]` and `graphite-app[bot]` on the same three PR endpoints as CodeRabbit; clear threads and blocking CI like other bots.
> **Ask first:** Merging — always ask the user.
> **Never:** Treat Graphite as a merge-gate tier until it posts reliably; avoid spamming `@codeant-ai` / `@graphite-app`.

**CodeAnt (CR path):** If CodeAnt participated on current HEAD (comments or CodeAnt check-run), `merge-gate.sh` needs a clean signal per `cr-merge-gate.md`. Use `@codeant-ai review` to nudge.

**Graphite:** Poll like other bots; not a merge-gate tier until reliable. If silent: check [Graphite app](https://github.com/apps/graphite-app) access, AI review toggle, workspace link, limits; try `@graphite-app re-review` on a test PR.

CodeAnt and Graphite are parallel supplements; the primary chain stays CR → BugBot → Greptile.

## Graphite — Known Outage (issue #610, confirmed 2026-07-21)

**Status: confirmed non-functional repo-wide, not a per-PR or docs-only-skip pattern.** Graphite (`graphite-app[bot]`) engaged normally — real review comments plus a completed `Graphite / AI Reviews` check-run — on 11 PRs between 2026-04-28 and 2026-05-08 (last: PR #453). Every PR opened since (85 PRs total, #463 through #612, spanning 2026-06-11 to 2026-07-21 — 82 merged, 3 still open as of this writing) shows **zero** Graphite activity of any kind: no comments, no reviews, and critically **no check-run at all**. This was verified across PRs touching pure docs (#463, #480) and PRs touching actual scripts (#500 `escalate-review.sh`, #604 `pr-preflight.sh`), so file type is not the variable.

**Why this rules out "intentional docs-only skip":** a functioning Graphite install posts a completed `Graphite / AI Reviews` check-run even when it has no findings to comment on (see PR #453). Total absence of that check-run means the GitHub App isn't running against this repo at all — most likely uninstalled, suspended, or a billing/plan lapse on the `auerbachb` org — not a content-based filtering decision. This is an external-service state we have no API access to (installation/billing endpoints 404/401 for a non-admin token), so diagnosis and re-enablement is a **user action**: check the [Graphite app](https://github.com/apps/graphite-app) installation for this org/repo and the AI-review toggle/billing status at `app.graphite.com`. Tracked in [issue #614](https://github.com/auerbachb/claude-code-config/issues/614).

**Decision: kept in the active trigger set, not removed.** `pr-preflight.sh`, `fixpr` Step 3b, `/monitor`, and `maybe-trigger-ai-review.sh` still post `@graphite-app re-review` for a missing Graphite. Rationale: the trigger is a single uncapped PR comment (cheap, self-healing — it'll start working again the moment the app is fixed) versus the cost of ripping Graphite out of four call sites and rewriting ~20 existing `pr-preflight.test.sh` cases for what is very likely a fixable external-service issue rather than a design flaw. Re-open the "drop from trigger set" option only if Graphite is still silent well after the user confirms the GitHub App is reinstalled/enabled.

**Diagnostic method for future re-checks:** don't rely on comment/review absence alone — a silent-but-installed app and a fully-uninstalled app both show zero comments. Check for the `Graphite / AI Reviews` check-run on the PR's HEAD commit (`gh api repos/{owner}/{repo}/commits/{sha}/check-runs --jq '.check_runs[] | select(.app.slug=="graphite-app")'`); its presence (even with a "nothing to report" conclusion) means the app is alive, and its total absence across several consecutive triggered PRs is the reliable signal of an outage.

## CodeAnt Local CLI

`codeant-cli` (npm) is a separate local/pre-push capability, distinct from the PR-side `codeant-ai[bot]` role above — it does **not** itself satisfy the GitHub merge gate (`cr-merge-gate.md`, `merge-gate-reviewer-paths.md`); treat it as advisory, same as the rest of CodeAnt's supplemental status in this repo.

- Install: `npm install -g codeant-cli` (Node.js/npm required). Auth: `codeant login` (browser OAuth against `app.codeant.ai`); key persisted to `~/.codeant/config.json`.
- `codeant review` scope flags: `--all` (default), `--uncommitted`, `--staged`, `--committed`, `--base <branch>`, `--base-commit <commit>`.
- `--fail-on <severity>`: `BLOCKER` / `CRITICAL` / `MAJOR` / `MINOR` / `INFO` (default `CRITICAL`) — sets the exit-code threshold.
- `--headless`: JSON results on stdout, progress/status on stderr — for agent/CI parsing.
- An MCP server mode and a Claude Code integration also exist (`docs.codeant.ai/cli/mcp-server`, `docs.codeant.ai/cli/claude-code-integration`) — not wired into this repo's workflow yet.
