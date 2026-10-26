---
name: quotas-setup
description: Use when registering the AI subscription accounts whose quotas you track, adding a second paid Claude Code / Codex / Cursor account, re-logging in an expired one, nicknaming an account, asking which are logged in, installing the daily unattended usage snapshot, generating the shell launchers (`claude-work`, `codex-personal`, …) that start a CLI against one account, or sharing the primary install's skills, rules, hooks, plugins, and MCP servers into an account's profile. Gives each account an isolated login profile — a config dir or a CODEX_HOME; Cursor instead uses the login the Cursor IDE already holds. Display and config only — reads no usage figures, gates no work.
triggers:
  - quotas-setup
  - register my AI accounts
  - add another Claude account
  - add a Codex account
  - add a Cursor account
  - which AI accounts are logged in
  - re-login my AI account
  - nickname my AI account
  - install the daily quota snapshot
  - is the quota snapshot job running
  - generate the account launchers
  - make a shell function for my second Claude account
  - share my skills and rules with the other profile
argument-hint: "[list [--json] | add <claude|codex|cursor> <label> [--nick <name>] [--no-login] | nick <label> <name> [provider] | remove <label> [provider] | relogin <label> [provider] | schedule <install|remove|status> [--hour N] | launchers | share-config <label> [provider]]"
model: sonnet
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
---

Register the accounts behind the owner's parallel AI subscriptions, give each one an
isolated login profile, and report which are reachable.

> **Display and configuration only.** Nothing this skill produces may gate dispatch,
> pause work, downgrade a model, or feed `credit-budget.sh`. Quota and spend authority
> belongs to Anthropic's own in-app UI and upstream harness signals — see
> `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority". Reading usage figures
> is a different tool (`/quotas`, increment 2); this skill stops at a validated account
> list.

> **No credential ever passes through you.** Every login is the provider's own
> interactive flow (magic link, SSO, CAPTCHA) — and for Cursor it is not even this
> tool's to run: the Cursor IDE holds that login. The helper launches what it can and
> waits — it never types, reads, prints, or stores a password, token, or cookie, and
> neither do you. If a login needs the user's hands, say so and stop; do not offer to
> type credentials.

## Step 1 — Resolve the helper

<!-- test-anchor: resolve-helper -->
```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
AI_QUOTAS_SETUP_SH=$(resolve_script ai-quotas-setup.sh || true)
[[ -n "$AI_QUOTAS_SETUP_SH" ]] || { echo "ERROR: ai-quotas-setup.sh not found (checked all three paths) — account registration unavailable" >&2; exit 1; }
```

**STOP** if the helper does not resolve: print that one line and end. Do not hand-roll
the registry — a second writer to `~/.claude/ai-quotas.json` is how the config and the
profile directories drift apart.

## Step 2 — Route the request

| The user asked | Run |
|----------------|-----|
| nothing, "list", "which accounts" | `"$AI_QUOTAS_SETUP_SH" list` |
| "add \<provider\> \<label\>" | `"$AI_QUOTAS_SETUP_SH" add <provider> <label>` |
| "register it now, I'll log in later" | `"$AI_QUOTAS_SETUP_SH" add <provider> <label> --no-login` |
| "call it \<name\>", "nickname this account" | `"$AI_QUOTAS_SETUP_SH" nick <label> "<name>" [<provider>]` |
| "remove \<label\>" | `"$AI_QUOTAS_SETUP_SH" remove <label> [<provider>]` |
| "re-login \<label\>", an account showing `needs-login` | `"$AI_QUOTAS_SETUP_SH" relogin <label> [<provider>]` |
| "take a reading every day", "install the snapshot job" | `"$AI_QUOTAS_SETUP_SH" schedule install` |
| "is the daily job running" | `"$AI_QUOTAS_SETUP_SH" schedule status` |
| "stop the daily job" | `"$AI_QUOTAS_SETUP_SH" schedule remove` |
| "generate the launchers", "give me a `claude-work` command", a new account was just added or renamed | `"$AI_QUOTAS_SETUP_SH" launchers` |
| "share my skills/rules/MCP servers with \<label\>", "make the other profile behave like my main one" | `"$AI_QUOTAS_SETUP_SH" share-config <label> [<provider>]` |

`list` is the default when no action is given. `--json` is available on `list` for
machine consumption (increment 2's `/quotas` reads the config directly). `--no-login`
is available on `add`: it reserves the profile slot and records the account without
launching a login, which is what you want when the user cannot complete an interactive
flow right now. The account then reports `needs-login` until a `relogin`.

Providers are `claude`, `codex`, and `cursor`. The label is what the user types — for
these accounts, the email on the subscription. Ask for it rather than guessing; the
label names the profile directory and is how `remove` and `relogin` find the account
later.

## Step 3 — Adding an account

`add` creates the isolated profile directory, launches that provider's own login
against it, verifies a credential appeared, and only then records the account. One case
records without a login: `--no-login`, which reserves the slot on purpose and lists as
`needs-login` rather than `ok`.

- **`claude`** — a per-account `CLAUDE_CONFIG_DIR` under
  `~/.claude/ai-quotas/profiles/<label>/claude`, then `claude` run against it. A bare
  `claude` on an unauthenticated config dir opens the browser login and persists the
  credential scoped to that directory; tell the user to exit the session (`/exit` or
  Ctrl-D) once the login completes. Do **not** substitute `claude auth login` (no such
  subcommand) or `claude setup-token` (it prints a token instead of storing one).
- **`codex`** — a per-account `CODEX_HOME` under `…/<label>/codex`, then `codex login`.
- **`cursor`** — **no profile directory and no login to launch** (#1703). The Cursor IDE
  owns this credential, and nothing else can create it: cursor.com's sign-in page runs a
  human-verification check that fails in every automation browser, which is why the
  Playwright login that used to live here was removed. So `add cursor` and
  `relogin … cursor` both mean **"open the Cursor IDE and sign in"** — tell the user
  exactly that. Each then confirms a token is present (`sqlite3`, presence only, the
  value never read) and exits `1` with that same instruction when the IDE is signed out;
  relay it and retry once they have. Exit `6` is the different failure of `sqlite3`
  being missing. One IDE holds one account, so this machine registers one Cursor
  account — a second Cursor subscription cannot be tracked here, and `add cursor` under a
  second label is **refused** with exit `3` naming the label that already holds the slot
  (two labels would otherwise render two `/quotas` rows with identical usage).
  A `relogin` no longer retires anything: signing in again in the IDE replaces the token,
  so there is no profile to move aside and nothing to roll back.

The `claude` and `codex` logins are interactive and blocking. Tell the user one is about
to open, and let it run — a magic link or SSO round trip can take a minute. Adding a
second account of the same provider never disturbs the first: each has its own profile
directory and its own credential. **Cursor is the exception on both counts** — nothing
opens, and a second account is not possible.

**STOP conditions for `add`:**

- Exit `1` — the login ran but left no credential the helper can see. Nothing was
  recorded. Report what the helper printed. Offer exactly two next steps: re-run the
  `add`, or `add … --no-login` to reserve the slot and log in later. Never invent an
  entry by hand.
- Exit `3` — a usage problem: unknown provider, malformed label, a
  `(provider, label)` pair already registered, or a **second `cursor` account under a
  different label**. Report it; for an already-registered pair the fix is `relogin`, not
  a second `add`. For the cursor refusal the message names the label already holding the
  slot — one IDE holds one account, so a second label would report the same usage twice;
  the fix is `relogin` on that label, or `remove` it first.
- Exit `6` — the provider's login tool is not installed: its CLI, or for `cursor`
  `sqlite3`, which reads the IDE state store. For `claude` and `codex` the helper prints
  the exact manual login command; relay it and stop. For `cursor` there is no manual
  login to print — the instruction is to install `sqlite3` and re-run.

**STOP conditions for every action, `list` included:**

- Exit `2` (`schedule` only) — this host is not macOS, so there is no LaunchAgent to
  install. Relay the line and stop.
- Exit `4` (`remove` / `relogin` / `nick`) — no account matches that label. Say so, ask the user
  to confirm the exact label (run `list` to show them), and stop. Nothing changed.
- Exit `5` (`schedule` also) — the job could not be set up: `HOME` is unset, the
  `ai-quotas.sh` to schedule could not be found, or the plist could not be written or
  did not validate. Nothing was installed; relay the message and stop.
- Exit `5` — the tool cannot use the config: `jq` is missing, the file is unparseable,
  or it was written by a different schema major. Report the helper's message and stop.
- Exit `7` — the config write lock timed out or was broken mid-update. The config is
  unchanged; say so and offer to retry.

On **any** non-zero exit above — 1, 3, 4, 5, 6, or 7 — **do not hand-edit
`~/.claude/ai-quotas.json`**. A second writer is how
the registry and the profile directories drift apart, and a config the tool refused to
parse is exactly the one you should not be repairing by hand.

## Step 3b — Nicknames

`/quotas` prints a nickname in place of the account's full email, which is what keeps a
five-account table inside a normal terminal. Set one at registration with
`add <provider> <label> --nick "<name>"`, or later with `nick <label> "<name>"`. Clear one
by passing an empty name — `nick <label> ""` — which removes the field rather than
storing a blank.

Keep them short (the column is sized by the longest one) and let the **user** choose the
words: a nickname is how they refer to the account, not a label for you to infer. Names
over 32 characters, or containing a tab, newline, control character, or leading/trailing
space, are refused with exit `3` and nothing is written — the table is tab-separated, and
a tab inside a name would split the row away from its headers.

A label registered under two providers needs the provider as a third argument
(`nick <label> "<name>" codex`), the same disambiguation `remove` and `relogin` require.

## Step 3c — The daily unattended snapshot (macOS only)

`/quotas` records every reading it takes, but only when someone runs it. `schedule
install` adds a per-user LaunchAgent (`com.claude.ai-quotas`) that takes one reading a
day at 09:00 local — `--hour <0-23>` moves it — plus one immediately on load, logging to
`~/.claude/ai-quotas/launchd.log`. `schedule remove` unloads and deletes it. `schedule
status` reports whether the plist is there, whether launchd holds the job, and when the
last unattended reading happened.

- Offer it when `/quotas` shows `LAST SNAPSHOT: none yet`. Installing it is a **config**
  change like any other action here — it schedules a reader, not a decision.
- **The job never gates anything.** It reads figures and appends them to
  `~/.claude/ai-quotas-history.jsonl`. Nothing consults that file to decide whether work
  may proceed, and you must not either.
- It opens **no browser at all** (#1703 removed the last one). A Cursor IDE that is
  signed out records as `needs-login` and waits for the user to sign in there; nothing
  is recorded for that row — an unread row appends no snapshot rather than a fabricated
  one.
- **Exit `2`** on any host that is not macOS: launchd is the only scheduler with access
  to this user's Keychain, `CODEX_HOME` directories, and the Cursor IDE state store, so there is
  nothing to install elsewhere. Report the one line it prints and stop — do **not** offer
  to write a cron entry instead, which would record `needs-login` every day and call it
  history.
- If `install` warns that it scheduled the reader from a checkout, relay it: the job
  keeps working until that worktree is removed. Re-run `schedule install` once the skills
  worktree is in place.

## Step 3d — Launchers: one shell function per account (#1851)

`launchers` writes `~/.claude/ai-quotas/launchers.zsh`: one zsh function per registered
`claude` and `codex` account, named `<provider>-<nickname slug>` — `Claude Work` becomes
`claude-work`, `GPT Personal` becomes `codex-personal` (a leading provider word is dropped
so the prefix is not doubled; an account with no nickname uses the local part of its
label). Each function sets the terminal tab title to the nickname, then resolves the
account's profile directory **from the registry by label** through `list --json` and runs
the CLI with `CLAUDE_CONFIG_DIR` or `CODEX_HOME` set to it. It never builds the path from
the label — #1850 records that the directories can be named backwards — and it reads no
credential: the CLI finds its own inside the profile. Cursor accounts are skipped with a
note; there is no CLI to launch.

The action ends by printing the one line to add to `~/.zshrc`. **Relay that line; never
edit `~/.zshrc` yourself** — the tool does not either. Run `launchers` again after every
`add`, `remove`, or `nick`; a file it generated is overwritten in place, while a file
written by hand is moved aside as `launchers.zsh.pre-share` and said so.

- Exit `3` — two accounts would define the same function (two Claude accounts both
  nicknamed "Work", say), or the registry holds one `(provider, label)` pair twice. The
  message names both; the fix is `nick <label> <name>` on one of them (or repairing the
  duplicate row), then re-run. Nothing was written.
- Exit `5` — `HOME` is unset without `AI_QUOTAS_LAUNCHERS_FILE` (on top of the
  `AI_QUOTAS_CONFIG` and `AI_QUOTAS_PROFILE_ROOT` every HOME-less run already needs), or
  the file could not be written. Relay and stop.

## Step 3e — share-config: make a profile behave like the primary install (#1851)

A fresh profile has a login and nothing else — no skills, rules, hooks, plugins, memory,
or MCP servers. `share-config <label> [<provider>]` links or copies them in from the
primary install:

- **`claude`** — symlinks `skills`, `agents`, `rules`, `hooks`, `plugins`, `projects`,
  `CLAUDE.md`, and `account-config.md` to the `~/.claude` equivalents; copies
  `settings.json`; merges the `mcpServers` block of `~/.claude.json` into the profile's
  own `.claude.json`, keeping every other field that file already holds (its login and
  onboarding state is what makes it that account's).
- **`codex`** — symlinks `rules` and copies `config.toml` from `~/.codex`.

Anything already in the wanted state is `kept`, so a re-run changes nothing; anything in
the way is moved aside as `<name>.pre-share` and **never deleted** — the summary line says
so and gives the counts. A primary item that does not exist is `skipped` rather than
linked to nowhere. Report the per-item lines as printed; they name paths only.

- Exit `3` — a `cursor` account (no profile directory), or a `profile_dir` that resolves
  to the primary install itself — the refusal that keeps this action from moving the real
  `~/.claude/skills` aside and linking it to itself. Relay and stop.
- Exit `4` — no such label; `list` to show the exact labels.
- Exit `5` — the profile directory does not exist yet (`relogin` first), the primary
  install is missing, `HOME` is unset without the `AI_QUOTAS_PRIMARY_*` overrides (on top
  of the `AI_QUOTAS_CONFIG` and `AI_QUOTAS_PROFILE_ROOT` every HOME-less run already
  needs), the profile's `.claude.json` is not parseable JSON — which is never rewritten —
  or that file changed while the merge was being computed, which means a Claude Code
  session on that profile is writing it: nothing was replaced, re-run when it is idle.
  Relay and stop; do not repair the file by hand.

Neither action reads or prints a credential: `.credentials.json`, `auth.json`, and the
Keychain are never opened, and nothing from `.claude.json` is printed — an MCP server
entry can carry an API key in its `env` block, so the merge reports a count, never a name.

## Step 4 — Report the result

After any action, run `list` and show the table. Each account reports as:

| Status | Meaning | What to do |
|--------|---------|------------|
| `ok` | A credential is present for that profile | nothing |
| `needs-login` | No credential is visible | `relogin <label>` |

On a readable config `list` exits `0` whatever the statuses say. It is a report, never a
gate: a `needs-login` row does not block anything, and you must not treat it as a reason
to pause or re-route work. The one non-zero `list` is exit `5` — the config itself is
unusable (see the STOP conditions above), which is a broken tool, not a verdict about an
account.

Never paste the config file's raw contents when a table will do, and never run a
command that reads a credential value out of the keychain or a profile directory. The
statuses above are derived from the *presence* of the artifact the provider's own tool
wrote, which is all anyone needs.

## Reference

Config schema (including the `nickname` field and its limits), the exact per-provider
re-login commands, where each provider keeps its credential, how the Cursor IDE token is
read and why no browser is involved, the LaunchAgent this skill writes — every plist key,
why 09:00, and why the `PATH` has to name Homebrew — the generated `launchers.zsh` and
what `share-config` links, copies, and merges, and the increment boundary:
`.claude/reference/ai-quotas.md`.
