# Safety — Destructive Command & Secret Prohibitions

> **Always:** Stay in your worktree. Treat `.env` files and any unencrypted secret as untouchable. Pin and inspect installers. Warn subagents of these rules.
> **Ask first:** Never — these are absolute prohibitions with no exceptions.
> **Never:** Delete `.env` files. Run `git clean`. Run destructive commands in the root repo. Commit secrets. Pipe untrusted URLs into a shell. Pass raw credentials to subagents.

## Destructive Commands

1. **NEVER delete, overwrite, move, or modify `.env` files** — anywhere, any repo. They contain irrecoverable secrets.
   - **Template exception:** `.env.{example,sample,template,dist,tpl}` (case-insensitive) are committed, non-secret templates — safe to edit. Bare `.env`, `.env.local`, `.env.production`, and unrecognized suffixes stay blocked. Allow-list: `.claude/hooks/env-guard.py` (`SAFE_ENV_SUFFIXES`).
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

When spawning subagents, include this warning in the prompt AND always set `mode: "bypassPermissions"` on the Agent tool call (see `subagent-orchestration.md` "How to Spawn Subagents" for why):

```
SAFETY: Do NOT delete, overwrite, move, or modify .env files — anywhere, any repo.
Exception: template files matching .env.<example|sample|template|dist|tpl>
(case-insensitive) are committed, non-secret, and safe to edit.
Do NOT run git clean in ANY directory. Do NOT run destructive commands (rm -rf, rm,
git checkout ., git stash, git reset --hard) in the root repo directory. Stay in your
worktree directory at all times.
Do NOT commit secrets or paste raw credentials into prompts/issue-PR bodies/comments/commits/logs. Do NOT
pipe untrusted URLs into a shell or disable TLS verification. Confirm package names
before npm/pip/gem/cargo/brew install. Full rules: .claude/rules/safety.md.
```
