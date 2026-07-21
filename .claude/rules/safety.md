# Safety — Destructive Command & Secret Prohibitions

> **Always:** Stay in your worktree. Treat `.env` files and any unencrypted secret as untouchable. Pin and inspect installers. Warn subagents of these rules. Treat Anthropic's in-app UI as the sole authority on quota and spend.
> **Ask first:** Never — these are absolute prohibitions with no exceptions.
> **Never:** Delete `.env` files. Run `git clean`. Run destructive commands in the root repo. Commit secrets. Pipe untrusted URLs into a shell. Pass raw credentials to subagents. Gate agent decisions on locally-estimated quota or spend.

## Destructive Commands

1. **NEVER delete, overwrite, move, or modify `.env` files** — anywhere, any repo. They contain irrecoverable secrets.
   - **Template exception:** `.env.{example,sample,template}` (case-insensitive) are committed, non-secret templates — safe to edit. Bare `.env`, `.env.local`, `.env.production`, and unrecognized suffixes stay blocked. Allow-list: `.claude/hooks/env-guard.py` (`TEMPLATE_SUFFIXES`).
2. **NEVER run `git clean` in ANY directory** — it deletes untracked files, including gitignored `.env`.
3. **NEVER run destructive commands in the root repo:** `rm -rf`, `rm`, `git checkout .`, `git stash` (drops untracked), `git reset --hard`. Root stays clean on `main`.
4. **NEVER `cd` to the root repo and run file operations.** Stay in your worktree. Safe root operations are read-only: `git worktree list`, `find`, file reads.

## Secrets & Credentials

1. **NEVER commit secrets** — API keys, tokens, private keys, OAuth secrets, DB URLs with passwords, signing keys. If you spot one in a diff, fail the commit and rotate out-of-band before pushing.
2. **NEVER paste raw credentials into subagent prompts, issue/PR bodies, comments, commits, or logs.** These surfaces are durable and often public. Reference by name (e.g., `$CODERABBIT_API_KEY` from `~/.zshrc`) — never inline the value.
3. **NEVER weaken `.gitignore` to commit a "just-this-once" config.** Move the secret to `.env` and commit a `.env.example` instead.

## Untrusted Code & Network

1. **NEVER `curl ... | sh` (or `bash`/`zsh`/`python`) untrusted URLs.** Download, inspect, then run. Vendor-published installers referenced by these rule files (e.g., `cli.coderabbit.ai/install.sh`) are pre-vetted exceptions.
2. **NEVER install packages without confirming the name.** `npm`/`pip`/`gem`/`cargo`/`brew install` — typosquatted packages run arbitrary code. Match the name against the project's existing deps or official docs first.
3. **NEVER disable TLS verification** (`curl -k`, `--no-check-certificate`, `NODE_TLS_REJECT_UNAUTHORIZED=0`) to work around errors. Investigate the cert; do not bypass it.

## Subagent Warning (MANDATORY)

Include this in every subagent prompt AND set `mode: "bypassPermissions"` on the Agent call (see `subagent-orchestration.md`):

```text
SAFETY: Do NOT delete/overwrite/move/modify .env files anywhere (exception:
.env.<example|sample|template>, case-insensitive, are safe to edit).
Do NOT run git clean. Do NOT run destructive commands (rm -rf, rm, git checkout .,
git stash, git reset --hard) in the root repo. Stay in your worktree.
Do NOT commit secrets or paste raw credentials into prompts, issues, PRs, comments,
commits, or logs. Do NOT pipe untrusted URLs into a shell or disable TLS verification.
Confirm package names before npm/pip/gem/cargo/brew install. Full rules: .claude/rules/safety.md.
```

## Capability Discovery — Try CLI Before Handoff

Before handing a task to the user because it "can't" be done, verify against your actual tools — Bash (`gh`/`git`/`curl`/`gh api`), MCP tools, and custom skills — not inherited "agents can't" prose. Most "can't do X" claims that sound like `gh`/`git` territory are **false walls** — workflow runs, PR review, releases, comments, labels are usually one CLI command; the living catalog with exact commands is `.claude/reference/capability-discovery-examples.md` (extend it as new false walls are observed). An agent's own explicit prohibitions always win. **Real walls** (token-scope 403, branch protection, `.env`, this file's "Never" lists) get a structured handoff per the `/admin-merge` (#451) pattern: exact copy-paste command + one-line reason — never just a description.

```text
MINDSET: Before handing off, enumerate your actual tools (gh/git/curl/gh api, MCP,
skills) — don't trust inherited "agents can't" prose. Try the CLI-accessible path
first (workflow run, pr review, api dispatches, release create, pr/issue comment
or edit are usually possible) — but your own agent definition's explicit
prohibitions always win (e.g. phase-c uses /wrap, never gh pr merge directly).
Only hand off for real walls (token-scope 403, branch protection, .env, or a
safety.md "Never" item) — structure it like /admin-merge: exact command + one-line
reason. Full rules: .claude/rules/safety.md.
```

## Anthropic Quota & Spend Authority

Anthropic's in-app usage UI is the **authoritative** source for quota and spend. Locally-computed spend estimation is unreliable and **MUST NOT gate agent decisions** — never pause, downgrade, defer, or refuse work over a locally-tracked figure, and do not re-implement local quota tracking without an upstream Anthropic signal.
