# Capability Discovery — False Walls vs Real Walls

Extracted from `.claude/rules/safety.md` "Capability Discovery — Try the CLI Before Handoff". The rule file keeps the operative ladder and the verbatim `MINDSET:` block; this file holds the worked catalog. **Extend the false-walls list as new ones are observed.**

## Common false walls — GitHub (usually doable)

- Manual Actions run → `gh workflow run <workflow> --ref <branch>`
- Review approve/reject → `gh pr review --approve|--request-changes`
- Admin-bypass merge → `gh pr merge --admin`
- workflow_dispatch → `gh api repos/{owner}/{repo}/actions/workflows/{id}/dispatches -f ref=<branch>`
- Release create → `gh release create`
- Comment → `gh pr comment` / `gh issue comment`
- Label/assign → `gh issue edit` / `gh pr edit`

An agent's own explicit prohibitions still win (e.g. `phase-c-merger` uses `/wrap`, never `gh pr merge` directly).

## Common false walls — provider CLIs

The ladder is not a GitHub rule. Every provider below is a one-liner, not a dashboard errand. Full command surface and auth notes: `.claude/reference/cli-tool-defaults.md`.

| "I can't…" | Actual command |
|------------|----------------|
| set a Railway env var (**the motivating case, issue #759**) | `railway variables --set "{KEY}={value}"` on the linked service |
| read which Railway env vars already exist | `railway variables` |
| redeploy or read logs on Railway | `railway redeploy` · `railway logs` |
| add a Vercel env var | `vercel env add {NAME} {environment}` (value on stdin — never inline it) |
| ship a Vercel preview or production deploy | `vercel deploy` · `vercel deploy --prod` |
| create a Neon branch to test a migration | `neonctl branches create --project-id {id} --name {branch}` |
| upload an asset to Cloudinary | `cloudinary uploader upload {file} public_id={id}` |

Writing a markdown file full of copy-paste commands **and then saying "you'll have to run these"** — on a project where the CLI is installed and linked — is the exact anti-pattern this ladder exists to kill. If you can write the command, you can run it.

## Rungs 1–3 in practice — the not-installed case

**Rung 1 — look locally, by absolute path.** The Bash tool runs with a minimal PATH, so a bare `which railway` can report nothing for a tool that is in fact installed. Check the real path instead:

```bash
ls -l /opt/homebrew/bin/railway || command -v railway
```

**Rung 2 — absent? Check whether the provider ships a CLI at all.** Nearly every major service does. Cap this at **one** lookup — a documentation detour mid-task costs more than the handoff it would save. No published CLI, or an inconclusive lookup → rung 4.

**Rung 3 — install it yourself** when the path is non-interactive and every rail in `safety.md` holds: package name confirmed against official docs, no `curl … | sh` of an unvetted URL, no TLS bypass, no `sudo`.

```bash
brew install railway   # name confirmed against the official Railway docs
```

Mention the new install in your response. Do **not** edit `cli-tool-defaults.md` as a side effect of unrelated work.

## Real walls (handoff is correct, but structured)

A token-scope 403 with no workaround, a branch-protection change, a `.env` edit, an install requiring `sudo`, or anything in `safety.md`'s "Never" lists. **Interactive auth is the wall you will actually hit most often** — `brew install railway` is trivial; `railway login` opens a browser, and no agent can complete that.

Use the `/admin-merge` (#451) pattern: exact copy-paste command, a one-line reason, and — when you just installed something — the auth step too. Name the rung you stopped on:

```text
Stopped at rung 4 (interactive auth): `railway login` opens a browser I can't drive.
Run these two and I'll set the variables:

  railway login
  railway link
```

Never substitute a prose description of what needs doing for the commands themselves.

## Anti-pattern

Typing "agents can't do X" where X sounds like something a CLI handles — stop and walk the ladder; the default answer is you probably CAN. A handoff that fails to name the rung it stopped on, with a concrete reason, is not a finished answer. This doesn't loosen any prohibition: check `safety.md`'s "Never" lists before assuming a capability is off-limits.
