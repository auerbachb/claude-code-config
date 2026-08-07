# CLI Tool Defaults — Vercel, Neon, Railway, Cloudinary

Four service CLIs are installed on this machine (`vercel` v53.0.1, `neonctl` v2.22.0, `railway` v4.30.5, `cloudinary` v1.14.1). **Default to these CLIs for every operation they support — never direct the user to a web dashboard for something a CLI can do.** Referenced from `.claude/rules/repo-bootstrap.md`.

**These four are examples, not the allowed set.** Any other provider — Supabase, Fly, Stripe, Cloudflare, one you have never used — follows the same capability-discovery ladder in `.claude/rules/safety.md`: look locally by absolute path, check whether the provider ships a CLI, install it when the safety rails hold, and only then hand off a runbook. A provider's absence from this file is not a reason to send the user to a dashboard.

**Secrets:** several commands below print or write credentials (connection strings, pulled env files). Treat that output as secret — never paste it into issues, PRs, commits, or logs (`.claude/rules/safety.md`). Reference env vars by name only (e.g. `CLOUDINARY_URL`), never inline values.

## Vercel

```bash
vercel --version
```

**Deployments:**

```bash
vercel ls                      # recent deployments for the linked project
vercel deploy                  # preview deployment of cwd
vercel deploy --prod           # production deployment
vercel inspect {deployment-url}
vercel logs {deployment-url}
```

**Env vars** (never commit pulled files; `.env*` files are untouchable per `safety.md`):

```bash
vercel env ls
vercel env add {NAME} {environment}   # value read from stdin — never inline it
vercel env rm {NAME} {environment}
vercel env pull {path}                # writes to gitignored path, e.g. .env.local
```

**Projects & domains:**

```bash
vercel project ls
vercel link                    # link cwd to a project
vercel domains ls
vercel domains add {domain} {project}
vercel whoami
```

## Neon

```bash
neonctl --version
```

**Projects & branches:**

```bash
neonctl projects list
neonctl branches list --project-id {project-id}
neonctl branches create --project-id {project-id} --name {branch}
neonctl branches delete {branch} --project-id {project-id}
```

**Connection strings** (output contains the DB password — treat as secret):

```bash
neonctl connection-string {branch} --project-id {project-id}
neonctl databases list --project-id {project-id} --branch {branch}
```

## Railway

```bash
railway --version
```

**Status, deploys, logs:**

```bash
railway status                 # linked project / environment / service
railway up                     # deploy cwd (--detach to skip log streaming)
railway redeploy
railway logs
```

**Env vars & linking:**

```bash
railway variables              # list for linked service
railway variables --set "{KEY}={value}"   # takes value as argument (no stdin path) — use a shell var, never inline the literal secret
railway link                   # link cwd to project/environment/service
railway run {command}          # run a local command with service env injected
```

## Cloudinary

Auth comes from `CLOUDINARY_URL` in `~/.zshrc` — already configured; reference it by name only, never echo or print it.

```bash
cloudinary --version
```

**Uploads, listing, transformations:**

```bash
cloudinary uploader upload {file} public_id={id}
cloudinary admin resources max_results=25      # list resources
cloudinary search "folder:{folder}"
cloudinary url {public_id} {transformation}    # e.g. w_200,h_200,c_fill
```

## When a CLI is unavailable

Fall back to the web UI **only** when the CLI fails (auth error, outage, missing subcommand) or genuinely lacks the capability. State which CLI command failed and why before suggesting the dashboard.

If a CLI looks missing, **verify by absolute path before believing it** — the Bash tool's PATH is minimal, so a bare `which {tool}` under-reports what is installed:

```bash
ls -l /opt/homebrew/bin/{tool} || command -v {tool}
```

Genuinely absent is rung 1 of the ladder, not a dead end: continue to rung 2 (does the provider ship a CLI?), rung 3 (install it, if non-interactive and within the safety rails), and rung 4 (drive the browser when the operation itself lives in a web dashboard) before handing anything off. Rung 4 does not rescue CLI-initiated auth: `railway login`, `codeant login`, and friends open the system browser out of reach of any MCP browser surface, so they stay a rung-5 handoff. When you do install a CLI, note it in your response — don't append it to this file as a side effect of unrelated work.
