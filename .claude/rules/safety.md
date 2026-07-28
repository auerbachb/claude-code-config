# Safety — Destructive Command & Secret Prohibitions

> **Always:** Stay in your worktree. Treat `.env` files and any unencrypted secret as untouchable. Pin and inspect installers. Warn subagents of these rules. Treat Anthropic's in-app UI as the sole authority on quota and spend. Restrict automated PR writes to PRs you authored.
> **Ask first:** Never — these are absolute prohibitions with no exceptions.
> **Never:** Delete `.env` files. Run `git clean`. Run destructive commands in the root repo. Commit secrets. Pipe untrusted URLs into a shell. Pass raw credentials to subagents. Gate agent decisions on locally-estimated quota or spend. Have an automated tool write to (merge, rebase, comment, trigger a review, resolve threads, close, enroll in polling) a PR you did not author, absent an explicit per-PR chat override.

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

## Authorship — Automated PR Writes (issue #733)

Every automated PR flow — sweeper, monitor, babysitter, fixer, merger — may **write only to PRs authored by the authenticated user** (`gh api user --jq .login`; discovery scopes to `--author "@me"`). A collaborator's or bot's PR is read-only context at most. Author-dimension analog of the invoking-repo scope (issue #687).

**"Touch" = any write:** merge, rebase, force-push, close, comment, trigger a review (`@coderabbitai`/`@cursor`/`@greptileai` — these spend the author's reviewer budgets and notify people), resolve a thread, enroll in babysit/polling. All are blocked on a PR you did not author.

**Fail closed:** when authorship cannot be determined (gh error, empty author), treat the PR as **not yours** and skip it with a visible note — never act on an unverified author.

**Override:** the ONLY way an automated tool acts on someone else's PR is you naming that specific PR in chat — per-PR, per-session, never inferred and never a default. The tool must state it is operating under an override.

**Read-only visibility is preserved:** status tables may still display collaborator PRs as context, clearly separated from your own actionable rows.

**Enforcement.** `.claude/scripts/pr-authorship.sh <pr>` is the gate — **only exit 0 (mine) authorizes a write**; 1 (not yours), 3 (not found), 4 (undetermined) all refuse, naming this guard. The same fail-safe is built into `polling-state-gate.sh --ensure-session` (enrolment) and `admin-merge.sh` (bypass merge), so it holds even when a skill's prose degrades or context compacts. `merge-gate.sh` blocks a **confirmed** foreign author and emits an `authorship` field, so read-only callers (e.g. `/status`) can still show collaborator PRs as clearly-marked non-actionable context — display is never write authorization. All three accept `--allow-nonauthor`, passed only under an explicit user override. Per-script detail: `.claude/reference/authorship-guard.md`.

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

## Capability Discovery — Try the CLI Before Handoff

Before telling the user a task "can't" be done, walk this ladder. It covers **any** provider — `gh`, `git`, `vercel`, `neonctl`, `railway`, `cloudinary`, or a service you have never used — not just GitHub.

1. **Look at what you already have** — MCP tools, custom skills, and the provider's CLI on disk, the last checked by absolute path (`/opt/homebrew/bin/<tool>`): the Bash tool's PATH is minimal, so a bare `which` under-reports what is installed.
2. **Absent? Check whether the provider ships a CLI at all** — most do. One lookup, then move on; a research detour mid-task is not warranted.
3. **Install it yourself** when a non-interactive path exists and the rails above hold: package name confirmed against official docs, no `curl … | sh` of an unvetted URL, no TLS bypass, no `sudo`. Any rail that blocks — or an install whose auth step opens a browser — drops to rung 4. Note a new install in your response; don't edit the CLI docs as a side effect.
4. **Hand off a runbook, not a description** — exact copy-paste command(s) plus one line on why it needs a human, in the `/admin-merge` (#451) shape, covering the `<tool> login` step when auth is interactive.

Only a dead-ended ladder licenses "I can't", and the answer must **name the rung it stopped on and the concrete reason** — token-scope 403, browser-only OAuth, a "Never" item above. "I don't think agents can do that" is never a complete answer. Your own agent definition's explicit prohibitions still win (e.g. `phase-c-merger` uses `/wrap`, never `gh pr merge`). Worked examples: `.claude/reference/capability-discovery-examples.md` — extend it as new false walls appear.

```text
MINDSET: Before handing off, walk the capability ladder for ANY provider CLI
(gh, git, railway, vercel, neonctl, …): (1) look at what you already have — MCP
tools, skills, and the CLI on disk by absolute path (/opt/homebrew/bin/<tool>),
since minimal PATH makes bare `which` lie; (2) if absent, check whether the
provider ships one, one lookup max; (3) install it when non-interactive and
safety rails hold (docs-confirmed name, no curl-pipe-sh, no TLS bypass, no
sudo); (4) else hand off an /admin-merge-shaped runbook: exact commands +
one-line reason, incl. interactive auth. Your own definition's prohibitions
still win (phase-c uses /wrap, never gh pr merge). "I can't" is valid only
after the ladder dead-ends, naming the rung and reason.
Full rules: .claude/rules/safety.md.
```

## Anthropic Quota & Spend Authority

Anthropic's in-app usage UI is the **authoritative** source for quota and spend. Locally-computed spend estimation is unreliable and **MUST NOT gate agent decisions** — never pause, downgrade, defer, or refuse work over a locally-tracked figure, and do not re-implement local quota tracking without an upstream Anthropic signal.
