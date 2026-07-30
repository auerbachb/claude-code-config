# Capability Discovery — False Walls vs Real Walls

Extracted from `.claude/rules/safety.md` "Capability Discovery — Try the CLI Before Deferring". The rule file keeps the operative ladder and the verbatim `MINDSET:` block; this file holds the worked catalog. **Extend the false-walls list as new ones are observed.**

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

## Common false walls — scope, not capability (issue #810)

The ladder's other entry point, and the one that slipped past issue #759. These deferrals never claim the work is impossible — they reassign it, so a rule keyed on "I can't" never fires:

| The deferral | What it actually is |
|--------------|---------------------|
| "that's not a session task" | rung 1 never walked |
| "that's a deployment step" | rung 1 never walked |
| "the runbook is in `docs/…`" | rung 4 claimed without rungs 1–3 |
| "I'll leave that to you in case you want to review it first" | rung 4 dressed up as courtesy |

Courtesy is the hardest of these to catch, because deferring to the user's judgment is sometimes right. Two things have to hold before you act instead of asking: the work is **reversible and inspectable**, and the target is **already established** by the task. Setting an env var on the service this session is already working against — one you can read back and change — is a step you can take and report, not a decision needing pre-approval. Standing up a new environment, or writing to one the task never named, is not: that is a real rung-4 handoff, and it should say so.

### Worked example — the motivating case

A security fix merged, CI green, session reported complete. The change altered no production behavior, because three env vars were still unset. The agent detected exactly that, named all three, wrote a correct runbook into `docs/security/S2S-IDENTITY.md`, and handed the session back. It never said "I can't" — it treated provisioning as somebody else's job, so the ladder sat loaded in context and never triggered.

Rung 1 would have ended it: `railway` was on disk and linked. Rungs 2 and 3 were unnecessary, and rung 4 was never reachable.

```bash
railway variables            # rung 1: which of the three are already set?

NEW_KEY=$(openssl rand -base64 32)                   # generated, never printed
[ -n "$NEW_KEY" ] || { echo "key generation failed" >&2; exit 1; }
railway variables --set "S2S_SIGNING_KEY=$NEW_KEY"   # provisioned, value stays out of output
```

That is one of the three. Repeat it for the second key, and set the third — `S2S_ISSUER`, not a secret — directly. Validating before provisioning matters: an unchecked `openssl` failure would quietly install an empty signing key, which is worse than the unset variable you started with.

**Secrets are not pre-refused.** The deferred work was generating and provisioning signing keys, and `safety.md`'s credential prohibitions read at a glance like "don't touch keys at all." They are narrower than that: generating a key and setting it through a provider CLI is the allowed path. What's prohibited is letting the *value* land anywhere durable — a commit, an issue or PR body, a subagent prompt, a review comment, or a log. Reference credentials by name in all of those. A credential-shaped task earns the same ladder walk as any other.

The interfaces differ — `vercel env add` reads the value from stdin, `railway variables --set` takes it as an argument — but the boundary does not: the value never reaches your output, a commit, or a PR body. Where a CLI offers a stdin path, prefer it.

## Rungs 1–3 in practice — the not-installed case

**Rung 1 — look at what you already have.** MCP tools and custom skills count here too: a connected MCP server or an existing skill may already cover the task, in which case no CLI is needed at all. For the CLI itself, check by absolute path — the Bash tool runs with a minimal PATH, so a bare `which railway` can report nothing for a tool that is in fact installed:

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

Typing "agents can't do X" where X sounds like something a CLI handles — stop and walk the ladder; the default answer is you probably CAN. The scope-shaped version of the same anti-pattern is quieter and just as wrong: calling X a deployment step, a follow-up, or somebody else's task, without ever having checked. Both are deferrals, and a handoff that fails to name the rung it stopped on, with a concrete reason, is not a finished answer. This doesn't loosen any prohibition: check `safety.md`'s "Never" lists before assuming a capability is off-limits.
