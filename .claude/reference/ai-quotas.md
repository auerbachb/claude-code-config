# AI Quota Tracking — account registry (`~/.claude/ai-quotas.json`)

Reference for `/quotas-setup` and `.claude/scripts/ai-quotas-setup.sh` (issue #1666).
Not auto-loaded; read it when working on the quota tools.

**Display and configuration only.** Nothing in this file — and nothing any tool built on
it produces — may gate dispatch, pause work, downgrade a model, or feed
`credit-budget.sh`. Quota and spend authority stays with Anthropic's in-app UI and
upstream harness signals, per `.claude/rules/safety.md` §"Anthropic Quota & Spend
Authority". This registry answers "which accounts exist and can I reach them", nothing
more.

## Why per-account profiles at all

Five prepaid premium subscriptions cost far less than overage on any one of them, so the
working pattern is to drain one account and switch to the next. None of the providers
supports two accounts side by side out of the box: each keeps one credential in one
place. Giving every account its own profile directory — `CLAUDE_CONFIG_DIR` for Claude
Code, `CODEX_HOME` for Codex, a browser profile for Cursor — is what lets all of them
stay logged in at once, and what lets a later reader borrow each account's live
credential in turn.

## Increment boundary

This registry is increment 1 of four (#1666 → #1667 → #1668 → #1669). It ends at a
registered, validated account list. **No usage figure is read here.** Increment 2 adds
`/quotas` and `.claude/scripts/ai-quotas.sh`, which read the config below and report
each account's remaining allowance; increment 3 (#1668) makes the Cursor slot live — the
browser login plus the two-pool reader documented at the end of this file. Keep the
schema simple — a reader that has to guess is a reader that reports the wrong number.

## Config file

- **Path** `~/.claude/ai-quotas.json` (override with `AI_QUOTAS_CONFIG`)
- **Mode** `600`, always — the file is created through a `600` temp file and installed
  by rename, so it is never briefly world-readable.
- **Location rationale** it lives under `~/.claude/`, never in a worktree, per the
  hook-storage rule (runtime state outlives any one worktree).

```json
{
  "schema_version": "1.0",
  "accounts": [
    {
      "provider": "claude",
      "label": "someone@example.com",
      "profile_dir": "/Users/you/.claude/ai-quotas/profiles/someone@example.com/claude",
      "added_at": "2026-09-07T16:40:00Z",
      "credential_ref": { "kind": "macos-keychain", "service": "Claude Code-credentials-1a2b3c4d" }
    }
  ]
}
```

| Field | Required | Meaning |
|-------|----------|---------|
| `schema_version` | yes | `"1.0"`. Compatibility is by **major**: the tool accepts any `1.x` config (keeping its minor and its unknown fields), and **refuses** a different major with exit `5` rather than rewriting a shape it would silently strip. Readers should tolerate unknown fields rather than fail. |
| `accounts[].provider` | yes | `claude`, `codex`, or `cursor`. |
| `accounts[].label` | yes | What the user typed — for these accounts, the subscription email. Unique per provider; it names the profile directory, so it must start with a letter or digit, may then contain letters, digits and `. _ @ + -`, and is capped at 128 characters (no slashes, nothing that could climb out of the profile root). |
| `accounts[].profile_dir` | yes | Absolute path to this account's isolated profile. |
| `accounts[].added_at` | yes | UTC ISO-8601 registration timestamp. |
| `accounts[].credential_ref` | no | macOS + `claude` only. The **name** of the Keychain item the login created — `{"kind":"macos-keychain","service":"…"}`. A name, never a value. |

**No field ever holds a token, cookie, or password.** That is not a convention, it is the
design: every reader borrows the provider tool's own live credential at run time, so
there is nothing here worth stealing.

The invariant the test suite asserts is about **key names**: no key anywhere in the
config matches `token|password|cookie`. The blunter check from the issue's Test Plan —
`grep -iE 'token|password|cookie' ~/.claude/ai-quotas.json` returning nothing — is also
asserted, but it scans the whole file, so a perfectly legitimate label such as
`token@example.com` would trip it. When it does, read the key names before concluding
anything leaked.

The same label may appear under two providers. When it does, `remove` and `relogin`
require the provider as a second argument rather than guessing which row was meant.

## Profile directories

```
~/.claude/ai-quotas/profiles/<label>/claude    # CLAUDE_CONFIG_DIR for that account
~/.claude/ai-quotas/profiles/<label>/codex     # CODEX_HOME for that account
~/.claude/ai-quotas/profiles/<label>/cursor    # Chromium persistent user-data dir
~/.claude/ai-quotas/profiles/<label>/.keychain-service-claude   # mode 600; see below
```

The `.keychain-service-<provider>` sidecar holds the **name** of the Keychain item the
provider's login created for that profile — never a value, never a secret. It is written
mode `600` beside the profile (not inside it, so nothing the provider's own tool reads is
disturbed), and it survives `remove`, which is the whole point: see below.

Created mode `700`, along with the parents the tool creates. `remove` deletes the
registry row and **leaves the directory on disk**, printing its path: dropping a row
must never destroy a working login. Delete it by hand if that is what you mean.

## Where each provider keeps its credential

| Provider | Credential artifact | How `list` sees it |
|----------|--------------------|--------------------|
| `claude` (macOS) | Keychain generic password, service `Claude Code-credentials-<suffix>` | `security find-generic-password -s "<service>"` — **never** `-w`, so no value is requested. The service is looked up by the name recorded at login time. |
| `claude` (other) | `<profile_dir>/.credentials.json` | file present and non-empty |
| `codex` | `<profile_dir>/auth.json` | file present and non-empty; if it is absent, `CODEX_HOME=<profile_dir> codex login status` is consulted and a zero exit counts as logged in. Its output is discarded, so no account detail is printed. |
| `cursor` | a Chromium persistent user-data dir — the saved session IS the credential | the cookie store is present and non-empty (`<dir>/Default/Network/Cookies`, `<dir>/Default/Cookies`, or `<dir>/Cookies`, depending on the build). **Presence only** — the file is never opened. |

### The Keychain suffix is observed, never derived

Claude Code appends a suffix to the Keychain service name that is derived from
`CLAUDE_CONFIG_DIR` by an undocumented function. The tool does **not** reimplement it.
It lists the `Claude Code-credentials*` service **names** before and after running the
login and records the one that appeared. Guessing the algorithm would fail silently the
first time upstream changed it — and a status probe that silently reports `needs-login`
for a perfectly good account is worse than one that never shipped.

If the recorded item later vanishes (keychain reset, item deleted), `list` reports
`needs-login` and `relogin` records whatever new item the next login creates.

**When no new item appears, the name is recalled, not guessed.** A login against a
profile that already has a Keychain item *rewrites* that item, so the before/after diff
is empty — the ordinary shape of re-registering a label whose profile `remove` left on
disk. The tool then falls back to the `.keychain-service-<provider>` sidecar written
beside the profile at the original login. The sidecar is never trusted on its own: the
status probe still asks the Keychain whether that item exists, so a stale sidecar yields
`needs-login`, never a false `ok`.

A sidecar that cannot be written does **not** fail the `add` — the credential itself is
already verified, and the row is genuine — but it is never silent either: the tool warns
on stderr at the moment the write (or its `chmod 600`) fails. Without that warning, the
cost lands much later and looks unexplained, as a re-add of that same label failing
closed for a reason nothing on screen accounts for.

**An ambiguous snapshot is refused, not guessed.** If two logins overlap, more than one
item can appear between one run's snapshots. Picking the first would bind an account to
another account's credential — a wrong answer that looks exactly like a right one — so
the tool exits `1`, records nothing, and asks for the login to be re-run on its own. The
alternative (a dedicated keychain lock held across the login) was declined: it would hold
a lock for the length of an unbounded interactive flow, well past the 120s staleness
ceiling that would then let another writer break it mid-login anyway.

## Statuses

| Status | Meaning |
|--------|---------|
| `ok` | The provider's own credential artifact is present for that profile. |
| `needs-login` | It is not — run `relogin`. Also what a `--no-login` reserved slot reports. |
On a readable config `list` always exits `0` whatever the statuses say — it is a report,
not a gate, and a `needs-login` row is not a failure. The one way `list` exits non-zero
is exit `5`, when the config itself cannot be read (missing `jq`, unparseable file, or a
different schema major); that is a broken tool, not a verdict about an account.

## Re-login commands (exact)

`/quotas-setup relogin <label> [<provider>]` runs these for you against the account's
existing profile directory, then re-verifies. To run one by hand:

```bash
# claude — replace <label> with the registered label.
# A bare `claude` against an unauthenticated CLAUDE_CONFIG_DIR opens the browser
# login and persists the credential scoped to that directory. Exit the session
# (/exit or Ctrl-D) once the login completes.
CLAUDE_CONFIG_DIR="$HOME/.claude/ai-quotas/profiles/<label>/claude" claude

# codex
CODEX_HOME="$HOME/.claude/ai-quotas/profiles/<label>/codex" codex login

# cursor — a headed browser on this account's own profile. Log in to
# cursor.com in the window it opens; the helper waits until the dashboard's
# usage endpoint answers, which is the only proof the session actually landed.
node .claude/scripts/lib/ai-quotas-cursor.js \
  --profile-dir "$HOME/.claude/ai-quotas/profiles/<label>/cursor" --mode login
```

A Cursor `relogin` **moves the old profile aside** to `<dir>.retired-<timestamp>` and
starts a fresh one, rather than logging in on top of it: layering a second session over
a half-expired one leaves a profile holding both, answering with whichever the browser
picks — a state no status probe can describe. The retired path is printed; delete it by
hand when you no longer want it.

Both are interactive: they open the provider's normal magic-link or SSO flow. The tool
launches the command and waits; it never types or reads credentials. If the CLI is not
installed, `ai-quotas-setup.sh` exits `6` and prints exactly the command above.

**Two `claude` alternatives were rejected, so nobody re-introduces them.**
`claude auth login` does not exist — there is no `auth` subcommand. `claude setup-token`
does exist, but it **prints** a one-year OAuth token to stdout rather than persisting it;
routing a credential value through this tool is precisely what the design forbids. The
undocumented-but-common `claude /login` shortcut is available without editing the script,
through `AI_QUOTAS_CLAUDE_LOGIN_ARGS=/login`.

## Helper contract

Full flags and exit codes: `ai-quotas-setup.sh --help`. Summary:

| Exit | Meaning |
|------|---------|
| 0 | Action completed (`list` exits 0 for any account status, on a readable config). |
| 1 | The login ran but left no visible credential; **nothing was recorded**. |
| 3 | Usage error — bad action/provider/label, duplicate pair, or an ambiguous label. |
| 4 | No account matches that label. |
| 5 | Dependency or write failure (`jq` missing, config unreadable, unparseable, or written by a different schema major). |
| 6 | The provider's login CLI was not found — for `cursor`, node or the Playwright helper; the manual command is printed. |
| 7 | The config write lock timed out or was broken mid-update; config unchanged. |

Config writes go through the shared `state-lock.sh` advisory lock and
`state_lock_commit`, so a concurrent `add` cannot lose the other's row.

**Test seams.** `AI_QUOTAS_CONFIG`, `AI_QUOTAS_PROFILE_ROOT`, `AI_QUOTAS_CLAUDE_BIN`,
`AI_QUOTAS_CODEX_BIN`, `AI_QUOTAS_SECURITY_BIN`, and `AI_QUOTAS_PLATFORM` exist so
`.claude/scripts/tests/ai-quotas-setup.test.sh` can exercise every path — including the
macOS Keychain probe — against stubs, without touching a real login, keychain, or
account. They are not meant for normal use.

## The reader — `/quotas` and `ai-quotas.sh` (increment 2, #1667)

`ai-quotas.sh` reads the registry above and prints one row per account per window:
account, provider, window, used %, remaining %, reset time in `America/New_York`, a
countdown, a status, and a note. `--five-hour` adds the short windows that arrive in the
same payload; `--account <label>` narrows the run; `--json` emits the same rows as
objects. Flags and exit codes: `ai-quotas.sh --help`.

**Display only, and the reader enforces it structurally: it opens no state file for
writing.** Its one write is the append-only telemetry line every script here emits to
`~/.claude/script-usage.log` (script name and the action word `read`, never the
arguments — those carry the account label). Nothing reads that log back into a decision,
so it is a log, not state. What the reader never opens for writing is the state that
could gate work: not `session-state.json`, not `credit-budget.sh`'s inputs
(`~/.claude/usage-limit-events.jsonl`, `~/.claude/usage-limit-last.json`, the
`credit_budget` state key), not any dispatch gate. A `needs-login` or `rate-limited` row
is a missing number, never a verdict about whether work may proceed —
`.claude/rules/safety.md` §"Anthropic Quota & Spend Authority" is the authority, and the
rolled-back `/quota` skill (#499) is the precedent for what gating on locally-read
numbers costs. Two surfaces legitimately gate dispatch: the user-configured
`daily_credit_budget_usd` budget and the #1427 usage-horizon counter. This is a third,
observational one, and it stays that way.

### JSON row shape

`provider`, `label`, `reported_email`, `window`, `used_pct`, `remaining_pct`,
`resets_at_epoch`, `resets_at_et`, `status` — plus `countdown`, `detail`, `source`
(which path produced the row), `plan`, and the pool fields `pool`, `used_usd`,
`included_usd`, `plan_used_usd`, `plan_included_usd`. Every row declares all of them;
the last five are `null` on providers with no such notion, so `--json` has ONE shape
whatever produced it. A figure this reader could not obtain is `null`, never `0`: a
zero would read as "no usage yet", which is the opposite of "we don't know".

The table's third column shows the **pool** where a provider has pools and the window
otherwise. A Cursor account contributes two rows for one window, so printing the window
there would render them as two identical lines differing only in a percentage.

Providers add fields through `emit_row`'s optional 11th argument — a JSON object merged
over the base row — rather than a second renderer. That is how the Cursor pools landed,
and how #1669's overage column will.

### Statuses

| Status | Meaning |
|--------|---------|
| `ok` | Figures were read for that window. |
| `needs-login` | No usable credential for that profile; the note carries the exact `/quotas-setup relogin <label> <provider>` command. |
| `rate-limited` | The provider answered 429; the note carries the retry window when the response named one. |
| `unreachable` | Network failure, a missing driver or runtime, or a response shape this reader does not recognise — in which case the note prints the top-level keys it actually saw. |
| `unreadable` | The response arrived but its shape changed. The note names the keys actually seen. Never a figure, never `0 %`. |
| `unsupported` | A provider this reader does not know. |

Each account is read independently: one failure takes down its own row and nothing else.

### Claude reader

Reads that profile's live OAuth access token — the Keychain item named by
`credential_ref.service` on macOS (`security find-generic-password -w`, the one place in
this toolset that asks for a value), or `<profile_dir>/.credentials.json` elsewhere —
and calls `GET https://api.anthropic.com/api/oauth/usage` with:

| Header | Value | Why |
|--------|-------|-----|
| `Authorization` | `Bearer <token>` | passed to `curl` **through a config on stdin** (`-K -`), never in argv, so the token never appears in `ps` |
| `anthropic-beta` | `oauth-2025-04-20` | the endpoint's beta gate |
| `User-Agent` | `claude-code/<installed version>` | **required** — without it the endpoint answers 429 indefinitely, which looks like a rate limit and is really a missing header |

The version comes from the installed `claude` CLI (override: `AI_QUOTAS_CLAUDE_VERSION`).
When it cannot be resolved the reader still sends a plausible User-Agent rather than
none, and any 429 that follows names the unresolved version in the note — the known
cause is the first thing the row should point at.

Windows rendered: `seven_day`, `seven_day_opus` when present, and `five_hour` under
`--five-hour`. `utilization` is treated as a percent; a *fractional* value at or below 1
is scaled by 100 (an integer `1` stays 1 %, because an integer percent is never
fractional). `resets_at` is accepted as ISO-8601 or as epoch seconds.

**A shape this reader does not recognise prints the keys it saw, not 0 %.** The endpoint
is undocumented; the failure mode worth engineering against is a silent zero that reads
as "plenty left".

Anthropic's Feb 2026 credential policy scopes subscription OAuth tokens to Claude Code
and Claude.ai. Owner's call (2026-09-07): a single user reading their own usage figures
is within the spirit of that policy — the reader is read-only, borrows the token in
place, and never routes model traffic through it.

### Codex reader

Preferred path: `codex app-server` under that account's `CODEX_HOME`, JSON-RPC
`initialize` → `initialized` → `account/rateLimits/read`. The requests go in over a
**FIFO**, not a plain pipe: a pipe closes stdin as soon as the last request is written
and the server shuts down having answered only `initialize` (measured). The reader polls
for the reply and kills the server the moment it lands, so a healthy account costs a
round trip rather than the whole bound.

The response is `result.rateLimits`: `primary` and `secondary`, each
`{usedPercent, windowDurationMins, resetsAt}` (epoch seconds), plus `planType` and
`accountId`.

**The weekly window is chosen by `windowDurationMins == 10080`, across both slots, never
by position.** Measured 2026-09-07 on a Pro account: the weekly figures arrive in
`primary` with `secondary` null. Reading `secondary` as "the weekly one" reports the
wrong window on some plans and looks exactly like a right answer. A response carrying
only one window is valid and is rendered; when `--five-hour` finds no short window, the
row says so rather than vanishing.

Fallback path, only when app-server is unavailable (no CLI, no answer within the bound,
or no rate limits in the reply): `GET https://chatgpt.com/backend-api/wham/usage` with
the `auth.json` bearer (again via `curl -K -`) and the `ChatGPT-Account-Id` header. Every
row records which path produced it, so a silently degraded read is visible.

`reported_email` comes from the `id_token` claim in `auth.json`. The JWT is decoded for
that one claim inside the reader; the token itself never leaves the function.

### Cursor reader (#1668)

Cursor is the one provider with **no individual usage API**: the Admin and Analytics
APIs are Enterprise-only, and the legacy token call returns request counts from a
pricing model Ultra no longer uses. The only reliable source is the logged-in dashboard,
so the reader drives it.

`.claude/scripts/lib/ai-quotas-cursor.js` launches Chromium through Playwright's
`launchPersistentContext` on that account's profile directory — headless for a read,
headed for a login — loads `https://cursor.com/dashboard/spending`, and captures the
response the page itself requests. The bash side never touches the browser: it runs the
helper under the same wall-clock bound as every other local probe
(`AI_QUOTAS_CURSOR_TIMEOUT`, 30s) and turns its one JSON verdict into rows.

**No cookie or session value leaves the profile directory.** The session is used in
place by the browser; the helper serialises a fixed set of numeric fields plus the
payload's top-level key names, and never a header, a cookie, or a body verbatim.

#### The captured endpoint

Recorded from the live Spending tab on **2026-09-08** (an Ultra account), not guessed.
Loading `/dashboard/spending` issues these, all `POST` with a `{}` body, authenticated
by the session cookie alone:

| Request | What it carries |
|---------|-----------------|
| `POST https://cursor.com/api/dashboard/get-current-period-usage` | **the two pools** and the billing cycle — the one the reader matches on |
| `POST https://cursor.com/api/dashboard/get-plan-info` | `planInfo.planName`, `includedAmountCents`, `price`, `billingCycleEnd` |
| `POST https://cursor.com/api/dashboard/get-monthly-billing-cycle` | `startDateEpochMillis`, `endDateEpochMillis` |
| `POST https://cursor.com/api/dashboard/get-credit-grants-balance` | credit grants (empty on this plan) |
| `POST https://cursor.com/api/dashboard/get-client-visible-credit-grants` | as above |
| `POST https://cursor.com/api/dashboard/get-sand-usage-status` | the Grok Bot pool, out of scope here |

Nothing else on that page is an API call — the dashboard is a Next.js app whose other
fetches are RSC payloads for its own routes. The reader matches the first URL as a path
**suffix**, so a host or query-string change does not silently stop matching; override
it with `--endpoint` if the path itself ever moves.

#### The response, and what each row takes from it

```json
{ "billingCycleStart": "1787933374000",
  "billingCycleEnd":   "1790611774000",
  "planUsage": { "totalSpend": 197210, "includedSpend": 40000, "bonusSpend": 157210,
                 "limit": 40000, "remainingBonus": false,
                 "autoPercentUsed": 49.02333333333333,
                 "apiPercentUsed": 100,
                 "totalPercentUsed": 56.34571428571429 },
  "spendLimitUsage": { "totalSpend": 100750, "individualLimit": 100000,
                       "individualUsed": 100750, "limitType": "user" },
  "displayMessage": "…", "autoBucketModels": ["composer-2.5", "cursor-grok-4.5", …] }
```

(Figures above are the shape as captured, with the account's own numbers left in place
as a worked example of the units.) Dollar amounts are **integer cents**; the cycle
bounds are epoch **milliseconds as strings**.

| Row / field | Source |
|-------------|--------|
| `pool: "cursor-models"` → `used_pct` | `planUsage.autoPercentUsed` — the "Cursor Models" bar (Composer, Cursor Grok; Auto draws here) |
| `pool: "other-models"` → `used_pct` | `planUsage.apiPercentUsed` — the "Other Models" bar (third-party models at API price) |
| `resets_at_*`, `countdown` | `billingCycleEnd`, milliseconds ÷ 1000, rendered in `America/New_York` |
| `plan` | `planInfo.planName` from `get-plan-info` (best effort; absent is not a failure) |
| `plan_used_usd`, `plan_included_usd` | `planUsage.totalSpend` and `planUsage.limit`, cents ÷ 100 |
| `window` | `billing-cycle` on both rows |

`used_pct` is rounded to one decimal, with a bare `.0` dropped, so the table shows `49`
where the dashboard shows `49% used`. `remaining_pct` is derived from the same rounded
number, so the two can never disagree.

#### Why `used_usd` and `included_usd` are null

**The response carries no per-pool dollar split, and neither does the Spending tab** —
it renders the two pools as percentage bars. The only dollars in the payload are
plan-wide (`totalSpend`, `limit`, `includedSpend`, `bonusSpend`) and the on-demand block.

So the two fields the issue names are declared on every row and left `null`, with the
plan-wide figures reported as what they are in `plan_used_usd` / `plan_included_usd` and
named in the note. Dividing a plan-wide total across two pools by their percentages
would produce a per-pool figure **Cursor never sent** — a wrong answer that looks exactly
like a right one, which is the failure every other reader in this file is built to
avoid. If Cursor ever adds the split, it becomes two more fields on the same rows.

`spendLimitUsage` is the on-demand overage — `individualUsed` of `individualLimit`, in
cents. It is deliberately **not** rendered here: that is #1669's column.

#### Statuses

| Verdict | When |
|---------|------|
| `ok` | the usage response was read; two rows follow |
| `needs-login` | no profile directory, a redirect to a login page, or HTTP 401/403 from the endpoint. The note carries the exact `/quotas-setup relogin <label> cursor` command. |
| `unreadable` | the response arrived but its shape changed, or the helper printed something that is not a verdict. The note names the keys actually seen — **never a figure, never 0 %**. |
| `unreachable` | no Node, no helper on disk, Playwright or the browser binary missing, the page would not load, or the bound elapsed. The note names which. |

A pool whose percentage the helper could not parse is **omitted from its list**, so the
account reports the pool it could read and never invents the other.

#### Install

Playwright is pinned to an exact version in `.claude/scripts/lib/package.json` — a
browser driver that floats is a reader whose behaviour changes without a commit. Install
it and the browser binary once per machine (`node_modules/` is gitignored):

```bash
npm install --prefix .claude/scripts/lib
npx --prefix .claude/scripts/lib playwright install chromium
```

Absent, every Cursor row reads `unreachable` naming exactly that command, and every other
account still reports.

#### Headless vs headed

The read runs **headless**, because the helper passes `headless: opts.mode === 'read'` to
`launchPersistentContext` — there is no `headless: true` literal to remove. Bot
protection on cursor.com was not encountered on the captured account; if it appears, the
documented fallback is a headed run. `--mode login` already is one, so confirm the
symptom by re-running the helper that way; to make a normal READ headed, change that
expression and say so here, per the issue's note.

#### One name to keep clear

`ai-quotas.sh` names its own clock `report_now_epoch`, **not** `now_epoch`. The latter
belongs to `lib/bounded-run.sh`, which the script sources; a same-named function defined
afterwards silently replaces the library's for the rest of the run. Since `run_bounded`
reads that clock twice to decide whether a child has overrun, a frozen `AI_QUOTAS_NOW`
made both reads equal and every wall-clock bound in the script vanish — invisibly, and
precisely under the test suite where the bounds are asserted. Do not rename it back.

### Test seams

`AI_QUOTAS_CONFIG`, `AI_QUOTAS_CURL_BIN`, `AI_QUOTAS_SECURITY_BIN`,
`AI_QUOTAS_CLAUDE_BIN`, `AI_QUOTAS_CODEX_BIN`, `AI_QUOTAS_CLAUDE_VERSION`,
`AI_QUOTAS_PLATFORM`, `AI_QUOTAS_ANTHROPIC_URL`, `AI_QUOTAS_CHATGPT_URL`,
`AI_QUOTAS_HTTP_TIMEOUT`, `AI_QUOTAS_CODEX_TIMEOUT`, and `AI_QUOTAS_NOW` (a fixed clock,
so countdown assertions do not drift) let
`.claude/scripts/tests/ai-quotas.test.sh` drive every path against stubs — no live
account, network, or keychain. They are not meant for normal use.

### Increment boundary

Provider coverage is complete at #1668: Claude, Codex, and Cursor. No row carries an
overage cost until #1669 adds that column — an additive change, a new field on the row
through the same extra-JSON argument the Cursor pools use. The `spendLimitUsage` block
of the captured Cursor response (above) is where that figure comes from.

## Symlink

Per `.claude/rules/skill-symlinks.md`, `/quotas-setup` and `/quotas` are symlinked into
`~/.claude/skills/` through the skills worktree **after** their PRs merge — never before,
and never directly to the root repo.
