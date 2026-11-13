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
argument-hint: "[list [--json] | add <claude|codex|cursor> <label> [--nick <name>] [--no-login] | nick <label> <name> [provider] | report <label> <window> <used_pct> [reset] [provider] | remove <label> [provider] | relogin <label> [provider] | schedule <install|remove|status> [--hour N] | launchers | share-config <label> [provider]]"
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

For a logged-out account, lead with the exact action supplied by `/quotas` and preserve
its label/provider quoting. The human completes the provider's sign-in. Do not install
`claude setup-token` for this usage reader: those long-lived tokens are model-request-only.
Issue #1886 uses notification + one-line relogin as its explicit scope fallback, with
no password storage or replay. See the reference and Issue #1970 for the deferred
actual Codex-cause investigation; do not invent a cause or make it a prerequisite
for the authorized notification/relogin fallback.

## Step 1 — Resolve the helper

<!-- test-anchor: resolve-helper -->
```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/$name}" \
    "${HOME:+$HOME/.claude/scripts/$name}" \
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
| "doctor", "check profile layout" | `"$AI_QUOTAS_SETUP_SH" doctor [--json]` |
| "repair-layout \<provider\>" | Complete [Layout mismatch recovery](#layout-mismatch-recovery), including profile-location and quiescence checks, before `"$AI_QUOTAS_SETUP_SH" repair-layout <provider>`. |
| nothing, "list", "which accounts" | `"$AI_QUOTAS_SETUP_SH" list` |
| "add \<provider\> \<label\>" | `"$AI_QUOTAS_SETUP_SH" add <provider> <label>` |
| "register it now, I'll log in later" | `"$AI_QUOTAS_SETUP_SH" add <provider> <label> --no-login` |
| "call it \<name\>", "nickname this account" | `"$AI_QUOTAS_SETUP_SH" nick <label> "<name>" [<provider>]` |
| "record 86% for \<label\>, resets Nov 17", "I can see the figure, the reader can't" | `"$AI_QUOTAS_SETUP_SH" report <label> <window> <used_pct> [<reset>] [<provider>]` — stored as owner-reported; the next usable live read replaces it |
| "use <order> for <label>", "reset source order" | `"$AI_QUOTAS_SETUP_SH" sources <label> <comma-separated order\|default> [<provider>]` |
| "recommend a source change after N failures" | `"$AI_QUOTAS_SETUP_SH" sources threshold <N>` |
| "remove \<label\>" | `"$AI_QUOTAS_SETUP_SH" remove <label> [<provider>]` |
| "re-login \<label\>", an account showing `needs-login` | `"$AI_QUOTAS_SETUP_SH" relogin <label> [<provider>]` |
| "take a reading every day", "install the snapshot job" | `"$AI_QUOTAS_SETUP_SH" schedule install` |
| "is the daily job running" | `"$AI_QUOTAS_SETUP_SH" schedule status` |
| "stop the daily job" | `"$AI_QUOTAS_SETUP_SH" schedule remove` |
| "generate the launchers", "give me a `claude-work` command", a new account was just added or renamed | `"$AI_QUOTAS_SETUP_SH" launchers` |
| "share my skills/rules/MCP servers with \<label\>", "make the other profile behave like my main one" | `"$AI_QUOTAS_SETUP_SH" share-config <label> [<provider>]` |

`list` is the default when no action is given. `--json` is available on `list` and `doctor` for
machine consumption (increment 2's `/quotas` reads the config directly). `--no-login`
is available on `add`: it reserves the profile slot and records the account without
launching a login, which is what you want when the user cannot complete an interactive
flow right now. `list` reports whether the credential is present: a reserved slot can
already report `ok` if the registered profile or Cursor IDE holds one.

Providers are `claude`, `codex`, and `cursor`. The label is what the user types — for
these accounts, the email on the subscription. Ask for it rather than guessing; the
label names the profile directory and is how `remove` and `relogin` find the account
later.

## Step 3 — Adding an account

`add` creates the isolated profile directory, launches that provider's own login
against it, verifies a credential appeared, and only then records the account. One case
records without a login: `--no-login` reserves the slot without running the provider
login. Its status still reflects the credential the helper can see.

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
- Exit `7` — a registry write or relogin was blocked by contention, or the registered
  profile changed during login. This run did not commit its registry update. A login
  that already ran can have written credentials in its profile; relay the exact helper
  message and check the current registry before retrying.

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
- If `install` warns that launchd still holds the previous definition or did not load
  the job, say that the new plist was written and relay the warning and its recovery
  command. Do not report the new job as running.

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

**Desk notice (issue #2185, `claude` profiles only).** The `settings.json` copy strips any
`HUMAN_QUEUE_SCHEMA` entry from `.env`, because a desk binding belongs to one account in
the registry and never to a profile. The stripping is reported as
`stripped HUMAN_QUEUE_SCHEMA from settings.json`, without the value. After the summary
line, one nonfatal line names the desk queue for the profile: `desk queue: <name> (<schema>)`,
or `no desk queue — run <bind command>` with the profile's config directory in the command.
Relay that line. A new account starts unbound, so a fresh `share-config` reports the bind
command, not a queue. Only `desk queue: unknown (<reason>)` means the desk or registry could
not be read; the share itself still succeeded.

Anything already in the wanted state is `kept`, so a re-run changes nothing; anything in
the way is moved aside as `<name>.pre-share` and **never deleted** — the summary line says
so and gives the counts. A primary item that does not exist is `skipped` rather than
linked to nowhere. Report the per-item lines as printed; they name paths only.

- Exit `3` — a `cursor` account (no profile directory), a `profile_dir` that resolves to
  the primary install itself — the refusal that keeps this action from moving the real
  `~/.claude/skills` aside and linking it to itself — or one that sits outside the profile
  root (a hand-edited registry row). Relay and stop.
- Exit `4` — no such label; `list` to show the exact labels.
- Exit `5` — the profile directory does not exist yet (`relogin` first), the primary
  install is missing, `HOME` is unset without the `AI_QUOTAS_PRIMARY_*` overrides (on top
  of the `AI_QUOTAS_CONFIG` and `AI_QUOTAS_PROFILE_ROOT` every HOME-less run already
  needs), the profile's `.claude.json` is not parseable JSON — which is never rewritten —
  or that file changed while the merge was being computed. In the race case, the
  helper does not replace `.claude.json`; earlier share items may already have
  changed. Relay the per-item lines and stop; do not repair the file by hand. Share
  only with an idle profile: the check happens before the backup and replacement,
  so a write after the check can still race the replacement.

Neither action opens a login credential — `.credentials.json`, `auth.json`, and the
Keychain are never touched — and nothing from `.claude.json` is printed. One thing the
merge does carry across is the `mcpServers` block itself, and an MCP server entry can hold
an API key in its `env` block. Sharing preserves those values in the merged JSON;
serialization can change formatting. The report line gives a count, never a name or a value.

## Step 4 — Report the result

After a successful action, run `"$AI_QUOTAS_SETUP_SH" list` and show the table.
For a failed or interrupted `repair-layout`, follow
[Layout mismatch recovery](#layout-mismatch-recovery) instead of running `list`.
Each account reports as:

| Status | Meaning | What to do |
|--------|---------|------------|
| `ok` | A credential is present for that profile | nothing |
| `needs-login` | The helper could not verify credential presence | Read the note first |

If the note says the credential is missing or the Cursor IDE is signed out, offer
`relogin <label> [<provider>]`. If it names a missing probe tool or unreadable store,
report that problem before suggesting sign-in.

On a readable config `list` exits `0` whatever the statuses say. It is a report, never a
gate: a `needs-login` row does not block anything, and you must not treat it as a reason
to pause or re-route work. The one non-zero `list` is exit `5` — the config itself is
unusable (see the STOP conditions above), which is a broken tool, not a verdict about an
account.

Never paste the config file's raw contents when a table will do, and never run a
command that reads a credential value out of the keychain or a profile directory. The
helper probes for the credential without reading its value. The note distinguishes
a missing credential from a probe the helper could not complete.

## Reference

Config schema (including the `nickname` field and its limits), the exact per-provider
re-login commands, where each provider keeps its credential, how the Cursor IDE token is
read and why no browser is involved, the LaunchAgent this skill writes — every plist key,
why 09:00, and why the `PATH` has to name Homebrew — the generated `launchers.zsh` and
what `share-config` links, copies, and merges, and the increment boundary:
`.claude/reference/ai-quotas.md`.

## Layout mismatch recovery

If text `list` emits a layout warning, run `"$AI_QUOTAS_SETUP_SH" doctor`.
Exit 8 is a diagnostic report, never a tool failure or a dispatch gate; do not
pause or reroute unrelated work because of it. Report the findings. Run repair
only when the user requested repair or already authorized it in the current
task; a diagnostic warning alone is not repair authorization. Otherwise ask
whether repair is desired before invoking either repair command. Honor standing
authorization without asking again.
First compare the current session’s `CLAUDE_CONFIG_DIR` and `CODEX_HOME`
(including their default profile locations) with every affected `profile_dir`.
If this session uses an affected profile, stop: ask the user to run repair from
a shell outside those profiles, after this session has exited. If this session
is still running, do not start repair from another shell. Establish that other affected sessions, setup
commands and quota readers are stopped
before `"$AI_QUOTAS_SETUP_SH" repair-layout claude` or `"$AI_QUOTAS_SETUP_SH" repair-layout codex`. Use available session
evidence; if quiescence cannot be established, ask the user to confirm it. Never fix a mismatch by hand-editing `ai-quotas.json`:
the credential directories must move together with their registry identities.
Codex repair requires non-empty file-backed `auth.json`. Claude Keychain repair
supports only fully observed homogeneous cycles with verified Claude Code 2.1.312
service binding, matching refs/sidecars and no secure-storage override. It needs
macOS Swift/Python 3 and accessible item metadata; no password is requested or
replayed. Report a refusal; do not retry in-place repair. For mixed/non-cycle
cases, the owner can use the fresh-profile reauthentication runbook in
`.claude/reference/ai-quotas.md#fresh-profile-reauthentication`: preserve the old
profile, verify a new canonical profile independently, then retire only the old
registry row. This is an explicit owner sign-in; do not launch it from a diagnostic
or treat this fallback as authorization to bypass managed authentication policy.
Unknown client bindings and secure-storage overrides still refuse metadata repair.
Doctor reports a journal but does not reconstruct rename
steps. If exit 9 or `interrupted-repair` appears, preserve
`.layout-repair/plan.json` and any recovery instructions printed by the failed
repair; report the situation to the user and stop; never delete or automatically retry
over the journal.

## Usage source preferences

Run `ai-quotas-setup.sh sources <label> <comma-separated order> [<provider>]` to choose the account source order, or use `default` to restore it. Allowed sources: Claude `oauth-usage`; Codex `app-server,http`; Cursor `ide-token,browser`. `sources threshold <N>` sets the positive consecutive-failure recommendation threshold (default 3). Preferences contain source names only, never credentials. Listing shows effective sources. Browser remains interactive-only regardless of its position.

## Session ledger hooks

For requests to install account-ledger hooks, run `"$AI_QUOTAS_SETUP_SH" ledger-hooks`. It merges per-profile Codex SessionStart entries while preserving unrelated hooks and config.toml. If the action fails, report its message and stop that action. Hook support and trust depend on the Codex version.

For backfill requests or sessions missing live hook capture, resolve the ledger helper with `LEDGER_SH=$(resolve_script ai-account-ledger.sh || true)` and run `"$LEDGER_SH" backfill-codex` when it resolves. Otherwise report `ERROR: ai-account-ledger.sh not found (checked all three paths) — Codex backfill unavailable`. See `.claude/reference/ai-account-ledger.md` for privacy and historical ownership limits.
