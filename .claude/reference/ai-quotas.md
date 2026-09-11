# AI Quota Tracking — account registry (`~/.claude/ai-quotas.json`)

Reference for `/quotas-setup` and `.claude/scripts/ai-quotas-setup.sh` (issue #1666).
Not auto-loaded; read it when working on the quota tools.

**Display and configuration only.** Nothing in this file — and nothing any tool built on
it produces — may gate dispatch, pause work, downgrade a model, or feed
`credit-budget.sh`. Quota and spend authority stays with Anthropic's in-app UI and
upstream harness signals, per `.claude/rules/safety.md` §"Anthropic Quota & Spend
Authority". This registry answers "which accounts exist and can I reach them", nothing
more.

**Distinct wallet.** This file governs the owner's **AI coding-assistant subscriptions** —
Claude Max, ChatGPT Pro / Codex, Cursor Ultra — including what continuing past their caps
costs (§"Overage — what continuing costs"). `.claude/reference/pricing-matrix.md` is the
separate **review-stack** wallet: CodeRabbit, BugBot, Greptile, CodeAnt. The two are never
mixed, and no price is copied between them — a figure that appears in both files is a
figure that will be updated in one of them and silently stale in the other.

## Why per-account profiles at all

Five prepaid premium subscriptions cost far less than overage on any one of them, so the
working pattern is to drain one account and switch to the next. None of the providers
supports two accounts side by side out of the box: each keeps one credential in one
place. Giving every account its own profile directory — `CLAUDE_CONFIG_DIR` for Claude
Code, `CODEX_HOME` for Codex — is what lets all of them stay logged in at once, and what
lets a later reader borrow each account's live credential in turn. Cursor is the
exception, and unavoidably so: its credential belongs to the Cursor IDE, which holds
exactly one account (#1703).

## Increment boundary

This registry is increment 1 of six (#1666 → #1667 → #1668 → #1669 → #1700 → #1701). It
ends at a registered, validated account list. **No usage figure is read here.** Increment
2 adds `/quotas` and `.claude/scripts/ai-quotas.sh`, which read the config below and
report each account's remaining allowance; increment 3 (#1668) makes the Cursor slot
live — the two-pool reader documented later in this file, rebuilt in #1703 on the Cursor
IDE's own token after the browser login proved impossible to seed;
increment 4 (#1669) adds the overage column and the cheapest-next hint; increment 5
(#1700) records every reading to a history file, adds the daily unattended snapshot,
nicknames, and the compact table; increment 6 (#1701) reads that history for a burn rate
and a days-left projection, and **closes the chain**. Keep the schema simple — a reader
that has to guess is a reader that reports the wrong number.

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
| `accounts[].nickname` | no | Short display name (#1700), set by `add … --nick <name>` or `nick <label> <name>`. `/quotas` shows it in place of the label. Max 32 characters; no tabs, newlines, control characters, or leading/trailing spaces — it is rendered into a tab-separated table, and a tab in it would split the row into columns that no longer line up with their headers. Clearing it (`nick <label> ""`) **deletes the key** rather than storing `""`. Enforced on **read** as well as on write: the reader accepts any compatible `1.x` registry — hand-edited, or written by a future sibling — and a nickname carrying a control character is dropped there too, falling back to the label exactly as an absent one does. |
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
                                               # cursor has NO profile directory —
                                               # the Cursor IDE owns that login (#1703)
~/.claude/ai-quotas/profiles/<label>/.keychain-service-claude   # mode 600; see below
~/.claude/ai-quotas/profiles/.relogin-slots/<label>__<provider> # relogin slot; see below
```

### Relogin slots

`relogin` claims `.relogin-slots/<label>__<provider>` — an empty directory holding a
`pid` file — for the whole run, and refuses (**exit 7**) when another relogin already
holds it. Two relogins for one account must not overlap: both would write the registry
row, and whichever finished last would decide what the account points at.

The slot no longer guards a **profile retirement**. Through #1668 a Cursor relogin moved
the old Chromium profile aside to `<dir>.retired-<timestamp>`, with a rollback trap to
put it back on failure; #1703 removed all of it along with the browser. An IDE token has
no profile to retire and no layering to prevent — signing in again in the IDE simply
replaces it — so the slot's whole job is now refusing the concurrent run.

The slot is a flat key under the profile root rather than a sibling of the profile,
because a sibling would have to be created through the label and provider components —
the ones `ensure_profile_dir` refuses to create through until it has proved on the
physical path that no symlink redirects them out of the root.

A relogin killed hard leaves a marker no one owns. The next run reads the recorded pid,
and a holder it can **prove** is gone (`kill -0` fails) is taken over; a live one, or one
whose pid cannot be read, is refused — guessing "probably dead" is the outcome the slot
exists to prevent. That takeover is itself serialized by a `<slot>.recovering` guard,
which is refused rather than broken: it covers a handful of non-blocking filesystem calls
and nothing else, so there is no slow case to wait out.

Both paths are cleared by hand if a crash ever leaves one behind — the refusal message
names the exact directory to delete once you have confirmed no relogin is running.

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
| `cursor` | the **Cursor IDE's own login**, in its state store (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, keys `cursorAuth/accessToken` and `cursorAuth/cachedEmail`; Linux and Windows paths in the reader section). No profile directory is created. | `sqlite3 -readonly` asks whether `cursorAuth/accessToken` is a non-empty string and answers with an exit status. **Presence only** — the value is never fetched or printed. A token can be present and expired, so only `/quotas` proves it still works. |

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

# cursor — there is NO command. Open the Cursor IDE and sign in there.
```

Cursor is the exception and stays one: `add cursor` and `relogin … cursor` launch
nothing, create no profile directory, and simply confirm afterwards that the IDE holds a
token, printing `open the Cursor IDE and sign in` when it does not. Nothing else can
create that credential — cursor.com refuses automation browsers (#1703).

The `claude` and `codex` logins are interactive: they open the provider's normal
magic-link or SSO flow. The tool launches the command and waits; it never types or reads
credentials. If the CLI is not installed, `ai-quotas-setup.sh` exits `6` and prints
exactly the command above — for `cursor` the missing tool is `sqlite3`, and the message
says so rather than naming a `cursor` login binary that has never existed.

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
| 6 | The provider's login CLI was not found — for `cursor`, `sqlite3`, which is what reads the IDE state store; the manual command is printed. |
| 7 | Contention, refused rather than raced; nothing changed. The config write lock timed out or was broken mid-update, or a `relogin` found another relogin already running for the same account. |

Config writes go through the shared `state-lock.sh` advisory lock and
`state_lock_commit`, so a concurrent `add` cannot lose the other's row.

**Test seams.** `AI_QUOTAS_CONFIG`, `AI_QUOTAS_PROFILE_ROOT`, `AI_QUOTAS_CLAUDE_BIN`,
`AI_QUOTAS_CODEX_BIN`, `AI_QUOTAS_SECURITY_BIN`, `AI_QUOTAS_SQLITE3_BIN`,
`AI_QUOTAS_CURSOR_STATE_DB`, and `AI_QUOTAS_PLATFORM` exist so
`.claude/scripts/tests/ai-quotas-setup.test.sh` can exercise every path — including the
macOS Keychain probe — against stubs, without touching a real login, keychain, or
account. They are not meant for normal use.

## The reader — `/quotas` and `ai-quotas.sh` (increment 2, #1667)

`ai-quotas.sh` reads the registry above and prints one row per account per window:
account, provider, window, used %, remaining %, reset time in `America/New_York`, a
countdown, a status, and a note. `--five-hour` adds the short windows that arrive in the
same payload; `--account <label>` narrows the run; `--json` emits a document carrying
those rows (§"Output" under "Overage" below — it was a bare array before #1669). Flags and
exit codes: `ai-quotas.sh --help`.

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

`provider`, `label`, `nickname`, `reported_email`, `window`, `used_pct`, `remaining_pct`,
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
and how #1669's Cursor spend-limit and Codex reset-balance fields land.

#### Fields added at #1669

`overage`, `spend_limit_used_usd`, `spend_limit_usd`, and the two speculative Codex live
figures `free_resets_remaining` and `credits_remaining_usd` are declared on **every** row
alongside the pool fields, `null` where the provider has no such notion.
`codex_live_overage` **drops** a key it cannot read as a plain number, so without those
declarations the field would be present on some Codex rows and absent everywhere else —
the "test whether the key exists before reading it" shape the one-shape promise exists to
prevent. `overage` is
filled in after every row is built, by `quotas-cheapest-next.sh` — the price of continuing
is a property of the provider and the reset watermark, not of any single read. Declaring
it in `emit_row` is what makes a run where that helper is unavailable emit the same keys,
with `null` where a price would be. §"Overage — what continuing costs" has the rest, and
§"Output" there describes the document `--json` now emits.

#### Fields added at #1701

`window_start_epoch` (when this row's window opened), `resets_at_et_short` (the reset as
a weekday and time, which is what the table prints now), and the seven projection fields
`usage_start_epoch`, `usage_start_is_floor`, `usage_start_day`, `usage_start_display`,
`pct_per_day`, `days_left`, `days_left_note`. All nine are declared on **every** row like
everything else here, `null` where nothing could be computed — and the seven projection
ones are filled in after every row is built, by `quotas-forecast.sh`, for the same reason
`overage` is: a pace is a property of the recorded history rather than of this read.

`days_left` is a **number or null, never the string the table prints**. When the pace
would carry past the reset, `days_left` is `null` and `days_left_note` is `resets first`
— a numeric field that sometimes holds prose is a field every consumer has to type-test
before comparing, and one of them eventually will not.

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

### Cursor reader (#1668, rebuilt on the IDE token in #1703)

Cursor is the one provider with **no individual usage API**: the Admin and Analytics
APIs are Enterprise-only, and the legacy token call returns request counts from a
pricing model Ultra no longer uses. The only reliable source is the logged-in dashboard.

#### Why the browser reader is gone

#1668 read that dashboard by driving a saved Playwright browser session. On
**2026-09-10** the owner tried three times to seed that session on a real account and
could not: cursor.com's sign-in page runs a human-verification check that fails inside
any automation browser ("Can't verify the user is human"), and Google SSO refuses those
browsers outright. The design could not get past login, so every Cursor row read
`unreachable`. **A reader that depends on defeating a CAPTCHA is not a reader**, and it
was removed rather than kept as a bot-check-prone opt-in — dead weight that would rot.
It is recoverable from git history if a second Cursor account ever needs it.

#### The IDE-token path

`ai-quotas.sh` now borrows the token the Cursor IDE is holding anyway, exactly as the
claude reader borrows Claude Code's:

1. Read `cursorAuth/accessToken` and `cursorAuth/cachedEmail` from the `ItemTable`
   key/value table of the IDE's state store (paths below).
2. Decode the token's `sub` claim and build the dashboard cookie **in memory**:
   `WorkosCursorSessionToken=<userId>%3A%3A<accessToken>`.
3. `POST` `{}` to the three dashboard endpoints with `curl`, cookie supplied on stdin.

`<userId>` is the `sub` with **only a leading `auth0|` removed**. Taking the segment
after the final `|` instead — the obvious-looking reading — is wrong and was measured
wrong: this account's `sub` is `google-oauth2|<id>`, and the dashboard answers 401 with
that prefix stripped. Verified end to end against the owner's live account on
**2026-09-11**: all three endpoints returned 200.

**No browser is launched on any path**, so the daily launchd job (#1700) runs with
`sqlite3` and `curl` alone.

**One IDE holds one account**, so one machine reads one Cursor account. A second Cursor
subscription cannot be registered here; that is a property of the IDE, not a limit of
this tool.

`add cursor` **enforces** it (CodeAnt, PR #1711): a second cursor label exits `3` naming
the label already holding the slot. The pre-existing duplicate guard cannot catch this
one — it matches on `(provider, label)`, and here the labels differ while the account
does not.

The check runs **twice**, and the second time is the one that makes this a guarantee
rather than a hope (CodeAnt): once pre-flight, so the refusal comes before a login runs,
and again **under the config write lock**, because two concurrent `add cursor` runs both
clear a pre-flight read and the loser would otherwise append the duplicate row. Both
sites call one `cursor_label_held` expression, so they cannot drift. The `(provider,
label)` guard has had the same pair of checks all along; this one now matches it. The
regression test drives the race deterministically through the sqlite3 seam — the presence
probe runs inside exactly that window — and was verified to fail, appending a second
cursor row, with the under-lock check removed. Every other provider isolates accounts by profile directory, so two labels
really are two accounts; cursor has no directory, so two labels are one account read
twice, and `/quotas` would render two rows with identical usage, identical reset, and
identical credentials.

#### Reading the state store: read-only, never a copy

The reader opens the store with `sqlite3 -readonly` and **does not copy it**. #1703's
plan of record called for a temp copy because Cursor holds the file locked. Measured on
this machine the store is **10 GB**, so a copy is minutes of I/O and 10 GB of disk to
answer two key lookups — and it is unnecessary: the store is a **WAL** database, where
readers and the writer coexist by design. With the IDE running, both queries answer in
~15 ms (measured 2026-09-11).

Two deliberate choices inside that:

- **`-readonly`, not a `file:…?mode=ro` URI.** The flag takes a plain path, so the space
  in the default macOS path — or a `?` or `#` in someone else's — needs no
  percent-encoding to be read correctly.
- **No `immutable=1` fallback.** It opens a WAL database while *ignoring* the WAL, which
  returns whatever token predates the last checkpoint. A stale token is
  indistinguishable here from a current one and fails later as a 401 — i.e. it would
  report "signed out" about an IDE that is signed in. A read this reader cannot do
  honestly is reported, not guessed.

#### State-store paths

| Platform | Path |
|----------|------|
| macOS | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` |
| Linux | `~/.config/Cursor/User/globalStorage/state.vscdb` |
| Windows | `%APPDATA%\Cursor\User\globalStorage\state.vscdb` |

macOS and Linux are **selected automatically** from `$PLATFORM` (`uname -s`, overridable
with `AI_QUOTAS_PLATFORM`) — hardcoding the macOS path made a signed-in Linux user read
`needs-login`, which tells them to sign in again over a path the reader was looking for in
the wrong place (CodeAnt, PR #1711). Anything else, Windows included, falls back to the
macOS path and is reachable through `AI_QUOTAS_CURSOR_STATE_DB`: the `%APPDATA%` path
above is documented but nothing in this fleet or in CI can exercise it, and a guessed path
that does not exist reads as `needs-login` — the failure the platform branch removes.
Both `ai-quotas.sh` and `ai-quotas-setup.sh` resolve it identically, so `list` and
`/quotas` can never disagree about whether this machine is signed in.

#### The token never leaves the function

The token and the derived cookie live in two globals, are handed to `curl` **on stdin**
(`-K -`) so they never reach argv and `ps` never sees them, and are cleared the moment
the three calls return. Neither is ever printed, logged, written to the history file,
put in a row, or copied to disk. The regression test asserts
`grep -iE 'WorkosCursorSessionToken=|eyJ'` finds nothing in stdout, stderr, or the
telemetry line.

#### Issue #1692 re-verified against this path — 2026-09-11

#1692 deferred three live-account items from #1668 because they needed a headed browser
and a local Playwright install. Two of the three described a browser that no longer
exists, so they are **re-scoped rather than carried forward**; measured on the owner's
live `cursor-ultra` account:

| #1692 item (as written) | Re-scoped | Result |
|---|---|---|
| `relogin` opens a headed browser, login completes, `list` shows `ok` | Open the Cursor IDE and sign in; `list` shows `ok` | **Verified.** `list` reports `ok` with the note `the Cursor IDE is signed in`. No browser, no profile directory. |
| `/quotas` renders both pool rows with percentages and a matching billing-cycle reset | unchanged | **Verified live:** `cursor-models 53.2 %`, `other-models 100 %`, reset `Mon Sep 28 12:09 PM EDT`, plan `Ultra`, plan-wide spend `$2098.59 of $400`, on-demand `$1007.50 of $1000`. `used_usd`/`included_usd` stay `null` per #1689 — Cursor publishes no per-pool dollar split. Comparing those figures against the Spending tab by eye remains the owner's check; the reader takes them from the response that tab itself requests. |
| Headless run completes in under ~20 s | The read completes promptly | **Verified:** the whole account read takes **1.1 s** (the browser path budgeted 30 s). |

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
cents. Since #1669 the helper reports it as `spend_limit_used_usd` / `spend_limit_usd`
(cents ÷ 100), and both Cursor rows carry the pair: it is **one spend limit for the
account**, not a per-pool one, so splitting it across the pools would manufacture a figure
Cursor never sent — the same reason the plan-wide dollars are not divided. It renders in
the overage column as `on-demand $1007.50 of $1000`; a payload without the block leaves both
fields `null` and the column falls back to the checked-in `on-demand` label, because a
missing block must not read as `$0 spent`.

#### Statuses

| Verdict | When |
|---------|------|
| `ok` | the usage response was read; two rows follow |
| `needs-login` | no readable state store, the store holds no access token, or HTTP 401/403 from the endpoint. The note carries the instruction **`open the Cursor IDE and sign in`** — there is no command to run, because the credential belongs to the IDE. |
| `unreadable` | the response arrived but its shape changed (no pool percentages, or a body that is not a JSON object), or the stored token carries no decodable `sub`. The note names the keys actually seen — **never a figure, never 0 %**. |
| `unreachable` | no `sqlite3`, a state store `sqlite3` could not read, `curl` failed, or the usage endpoint answered any other non-200. The note names which. |

A pool whose percentage the reader could not parse is **omitted from its list**, so the
account reports the pool it could read and never invents the other.

The three failure modes are kept distinct on purpose: collapsing them into `needs-login`
would tell a user to sign in again over a missing `sqlite3` or a changed payload shape —
the one instruction that cannot possibly help.

#### Enrichment calls fail soft

Only `get-current-period-usage` decides the row: every figure rendered comes from it, and
it carries `billingCycleStart`/`End` of its own. `get-monthly-billing-cycle` is the
authoritative source for those bounds and `get-plan-info` supplies the plan name, so a
non-200 from either costs a **label, not a number** — the row still renders. A row that
went `unreachable` because a plan-*name* lookup 500'd would be reporting a blackout it
does not have.

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
`AI_QUOTAS_HTTP_TIMEOUT`, `AI_QUOTAS_CODEX_TIMEOUT`, `AI_QUOTAS_SQLITE3_BIN`,
`AI_QUOTAS_CURSOR_STATE_DB` (a fixture SQLite DB, so no test touches the real Cursor IDE
store), and `AI_QUOTAS_NOW` (a fixed clock,
so countdown assertions do not drift — and, since #1669, the ET month the reset watermark
is read against) let `.claude/scripts/tests/ai-quotas.test.sh` drive every path against
stubs — no live account, network, or keychain. They are not meant for normal use.

`AI_QUOTAS_CHEAPEST_BIN` (the path to `quotas-cheapest-next.sh`),
`CLAUDE_QUOTAS_STATE_DIR` (the reset watermark's directory), and
`CLAUDE_QUOTAS_PM_CONFIG` (the `pm-config.md` supplying the threshold knob) join them at
#1669. `CLAUDE_QUOTAS_PM_CONFIG` exists because `repo-root.sh` resolves from the script's
own directory, so no choice of working directory keeps a suite from reading this repo's
real `pm-config.md`: a test asserting "the default is 20" would in fact be reading the
repo's `= 20`, passing for the wrong reason and going on passing if the default changed.
`AI_QUOTAS_CHEAPEST_BIN` is used **exclusively** when set — no fall-through to the
portable search — because a seam that falls back finds the repo copy through the relative
candidate whenever the caller is standing in a checkout, which is the only place anyone
runs the suite: the "helper unavailable" path could never then be exercised.

### Increment boundary

Provider coverage is complete at #1668: Claude, Codex, and Cursor. #1669 adds the
overage column and the cheapest-next hint below. #1700 adds the snapshot history, the
daily unattended job, nicknames, and the compact table — everything needed to answer
"how did this account get here"; #1701 reads that history and **closes the chain** with
a burn rate and a days-left projection.

## Overage — what continuing costs (increment 4, #1669)

`/quotas` answers "how much is left". At the end of a drained week the next question is
"what does it cost to keep going, and where". `.claude/scripts/quotas-cheapest-next.sh`
owns that answer: it annotates each row with an `overage` object and, when at least one
account is at or below the threshold, names the cheapest account to continue on.

**Informational only.** The hint **never switches accounts, never purchases anything, and
never gates dispatch.** It is a third observational surface, exactly like the table it
sits under — `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority" holds the
authority, and the rolled-back `/quota` skill (#499) is the precedent for what gating on
locally-read numbers costs. Buying a Codex reset, enabling Claude usage credits, and
raising a Cursor spend limit are the account owner's actions, taken in the provider's own
UI. No script here does any of them.

### The table

**These prices are only as fresh as their `last verified` dates.** Re-check them when a
row looks wrong; a stale table produces a confident hint about a price that moved.

| Provider | Overage | What it buys | Source | Last verified |
|----------|---------|--------------|--------|---------------|
| **ChatGPT Pro / Codex** | `1 free reset`, then `~$90/reset` | An instant reset restores the 5-hour **and** weekly allowances at once and starts a new weekly period on the next request — it pulls the normal weekly allowance forward rather than adding a separate entitlement. Free resets are **promotional and offer-dependent**, not a standing plan entitlement: at the last check OpenAI described one free reset to start on eligible plans plus resets banked from referrals, with eligibility, delivery, expiry, and future availability all varying by account, region, and plan — and an expired banked reset is not restored or reissued. Buying one is available to Plus and Pro personal accounts from Settings → Usage or the Codex app. **Credits are the other lever** — a balance bought from the same screen. | [help.openai.com — paid weekly Work and Codex rate limit resets](https://help.openai.com/en/articles/20001507-paid-weekly-work-and-codex-rate-limit-resets); [credits](https://help.openai.com/en/articles/12642688-using-credits-for-flexible-usage-in-chatgpt-freegopluspro-sora) | 2026-09-09 |
| **Claude Max** | `API rate` | Extra usage continues at **standard API rates** once usage credits are enabled; auto-reload for the credit balance is a Console billing setting. Metered — you pay for the work actually done. | [support.claude.com — using Claude Code with your Pro or Max plan](https://support.claude.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan); rates at [claude.com/pricing#api](https://claude.com/pricing#api) | 2026-09-09 |
| **Cursor Ultra** | `on-demand` | Once the included monthly usage is spent, extra usage continues at the **standard model API rates** as pay-as-you-go. Metered, per pool, against the spend limit the account sets. | [cursor.com/docs/account/pricing](https://cursor.com/docs/account/pricing) | 2026-09-09 |

**The `~$90` figure is owner-reported (2026-09-07), not published.** OpenAI's help page
documents the reset product and states that available amounts and prices vary by account,
region, and plan; it prints no figure. The label says `~` for that reason, and the source
URL above is the product page, not a price list. The **one free reset per month** cadence
is likewise the owner's observation, not a documented grant — which is exactly why the
watermark below records a reset as *used* rather than counting down from an assumed
monthly allowance, and why a live figure in the payload would outrank it. If the
promotion ends, the watermark keeps working: it goes on saying "no reset recorded this
month", and the account owner, who is the one who sees the offer, is the one who decides.

### Preferring a live figure

A checked-in table is a fallback. Where a provider's own response carries the number, the
live one wins and the row says so in `overage.figure_source`:

| Row field | Provider source | Renders as |
|-----------|-----------------|------------|
| `spend_limit_used_usd`, `spend_limit_usd` | Cursor's `spendLimitUsage.individualUsed` / `.individualLimit`, cents ÷ 100 — the on-demand block of the captured response documented above | `on-demand $1007.50 of $1000`, `figure_source: "live"` |
| `free_resets_remaining` | Codex — **speculative**. No captured `account/rateLimits/read` payload has ever carried it; the reader looks for `freeResetsRemaining`, `free_resets_remaining`, and `resets.freeRemaining` and contributes **nothing** when none is a plain number | `2 free resets`, `figure_source: "live"` |
| `credits_remaining_usd` | Codex — speculative on the same terms (`creditBalanceUsd`, `credits.balanceUsd`) | reported in the `overage` object, not yet in the label |

The Codex lookups are a hook, not an observation, and they are written so that being wrong
costs nothing: a key that is absent, or present with a value that is not a plain number,
leaves the watermark to answer. A bare `tonumber` there would turn `"n/a"` into `0` and
render `0 free resets` — a figure nobody sent, pointing straight at a paid reset. If
OpenAI ships the balance under a third name, add it in `codex_live_overage` and here.

### The Codex reset watermark

`~/.claude/quotas/codex-reset.json` (override the directory with
`CLAUDE_QUOTAS_STATE_DIR`), written **only** by an explicit
`quotas-cheapest-next.sh --record-codex-reset [YYYY-MM-DD]`:

```json
{"schema_version": "1.0", "month": "2026-09", "used_on": "2026-09-07",
 "recorded_at": "2026-09-09T18:41:02Z"}
```

A `month` equal to the current **Eastern** month means the free reset is spent, and the
row prices the next one at `~$90/reset`. Any other month, or no file, means one is
available. `--codex-reset-status` prints the verdict; `AI_QUOTAS_NOW` freezes the month
for tests.

**The read fails soft, in the safe direction.** A missing, unreadable, or malformed file
degrades to "one free reset assumed" (`figure_source: "assumed"`) with a warning — never
to an error, and never to "already spent". The latter is the reading that steers the hint
toward a $90 purchase, and it must not come from a parse failure.

**One record, not one per account.** The file carries no account dimension, so recording a
reset marks the free reset spent for *every* Codex account that falls back to the
watermark. Accounts reporting a live free-reset figure are unaffected — a live figure is
preferred over the watermark. With more than one Codex account registered, read the
verdict as "a reset was used somewhere this month", not as a per-account balance. Keying
it by account is issue #1696.

**Backfilling an older month is refused.** The file holds one slot, so recording an August
reset over a September record would erase the only evidence September's reset was spent
and the next report would offer one that is gone. `--record-codex-reset` reads the
existing record first and exits 5 rather than replacing it with a strictly older month,
naming the file to remove if the overwrite is deliberate. The date is also round-tripped
through `date`, so `2026-99-99` and `2026-02-31` are rejected: a banked `2026-99` sorts
after every real month and would otherwise block every later recording permanently.

### The threshold knob

`quotas_cheapest_next_threshold_pct` in `.claude/pm-config.md` `## Budget` — integer
percent `0`–`100`, default **20**. Precedence, most specific first: `--threshold <pct>` on
the invocation, then `CLAUDE_QUOTAS_CHEAPEST_NEXT_THRESHOLD_PCT`, then the config value,
then the default.

**The two bad-value paths differ, deliberately.** An unparseable value from the **env
override or the config file** is reported on stderr and replaced by the default — the same
fail-soft handling `usage-horizon.sh` gives its knobs, because a typo in a config file
must not abort a display-only report. An unparseable **`--threshold`** is a usage error:
`die_usage`, **exit 3**, nothing printed. Someone who just typed the flag is present to
retype it, and silently substituting 20 for what they meant would answer a different
question than the one they asked. The config file itself is
resolved through `repo-root.sh` unless `CLAUDE_QUOTAS_PM_CONFIG` names one directly (see
§"Test seams"); a run that resolves no repo simply skips that rung.

The threshold is the **trigger**, not the filter: once any readable row sits at or below
it — **inclusive**, because an account exactly on the line is the case the hint exists for
— every `ok` row with a readable figure competes, including the drained one. Continuing
where you are, at API rate, is a legitimate answer.

### How the ranking works, and what it does not claim

**The units do not convert.** A Codex reset buys a fixed week at a flat price; Claude and
Cursor overage is metered per unit of work. The ranking is over *what continuing costs
you*, not over dollars, and every verdict carries a `basis` string saying so — printed
under the hint, and present in `--json`:

1. **Included quota you have already paid for** — a row still above the threshold. Ordered by remaining percentage, highest first.
2. **A banked free Codex reset** — no money, but it spends the one you have.
3. **Metered overage** — Claude's API rate, Cursor's on-demand: you pay for the work actually done.
4. **A flat-fee reset** — a fixed price for a week you may not use.

Only rows with `status: "ok"` and a readable `remaining_pct` are candidates. A
`needs-login` account is never recommended however much it claims to have left — its
overage price is still reported, because the price does not depend on whether the read
succeeded.

### Output

The table gains an **OVERAGE** column between REMAIN and RESETS (ET), showing that row's
`overage.label` and `-` where no price is known. When the hint fires, three lines follow
the table: `Cheapest to continue on: <label> (<reason>)`, the basis, and the
informational-only restatement.

`--json` changed shape at #1669, from a bare row **array** to a **document**:

```json
{"schema_version": "1.0", "threshold_pct": 20, "basis": "…",
 "rows": [ … ], "cheapest_next": {"label": …, "reason": …, "basis": …, "overage": … }}
```

`cheapest_next` is a property of the whole report rather than of any row, and an array had
nowhere to put it. `schema_version` is there so a consumer can tell the two apart rather
than inferring it from the JSON type. The "no accounts registered" and "no account
matched" exits emit the **same** document with an empty `rows` — never a bare `[]`,
because a consumer forced to special-case emptiness is a consumer that will eventually
read a partial answer as a complete one.

Each row's `overage` object carries `label`, `base_label` (the table's generic wording,
which the hint's prose uses), `kind` (`metered` or `reset`), `detail`, `source`,
`last_verified`, `cost_rank`, and `figure_source` — `live`, `watermark`, `assumed`, or
`table`. A provider this script has no prices for gets `overage: null`, never a guess.

### When the helper is unavailable

`ai-quotas.sh` resolves `quotas-cheapest-next.sh` sibling-first, then through the standard
three-candidate portable lookup (`AI_QUOTAS_CHEAPEST_BIN` overrides all of them, and is
used exclusively when set). Missing or failing, the run says `DEGRADED:` **once** on
stderr and reports without prices or a hint — every row still renders, `overage` is `null`
on each, `cheapest_next` is `null`, and the exit status is still `0`. A missing price is a
missing number, never a verdict about whether work may proceed.

## Snapshot history, the daily job, nicknames (increment 5, #1700)

`/quotas` answered "where does each account stand **now**". A single reading cannot tell
"used 57 % over six days" from "used 57 % since yesterday", so this increment records
every reading, takes one unattended reading a day so quiet days leave no hole, and
narrows the table enough to read five accounts at a glance.

**History is display data, exactly like the table it comes from.** Nothing in this repo
reads `ai-quotas-history.jsonl` to decide whether work may proceed, and nothing may
start: no dispatch gate, no pause, no model downgrade, no input to `credit-budget.sh`.
Quota and spend authority stays with Anthropic's own in-app UI and upstream harness
signals — `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority", with the
rolled-back `/quota` skill (#499) as the precedent for what gating on locally-read
numbers costs. The projection in #1701 is the file's first and only reader, and it is a
projection printed to a human, not a verdict.

### The history file

- **Path** `~/.claude/ai-quotas-history.jsonl` (override with `AI_QUOTAS_HISTORY`)
- **Mode** `600`, created through a `077` umask so it is never briefly world-readable
- **Format** JSON Lines: one object per line, append-only, never rewritten

Every run of `ai-quotas.sh` appends one line per **successfully read** row:

```json
{"ts":"2026-09-10T13:00:04Z","provider":"codex","label":"admin@localmovers.com",
 "nickname":"GPT LM","window":"7-day","used_pct":71,"resets_at_epoch":1789200000,
 "source":"scheduled"}
```

| Field | Meaning |
|-------|---------|
| `ts` | UTC ISO-8601 instant of the RUN, identical on every line the run appends — so a run is a group, not a scatter of near-equal times. |
| `provider` | `claude`, `codex`, or `cursor`. |
| `label` | The registry label, which is the stable key across renames of the nickname. |
| `nickname` | The nickname at the time of the reading, or `null`. Recorded rather than looked up later, so a renamed account keeps its old readings labelled the way they were shown. |
| `window` | The row's **pool** where the provider has pools, its window otherwise — the same value the table's third column shows. This is what makes a Cursor account's two pool rows two distinct series rather than two readings of one; a burn rate computed without it would average two unrelated pools. |
| `used_pct` | The percentage the row reported. Never `null` — a row without a figure appends nothing at all. |
| `resets_at_epoch` | When that window resets, or `null`. A series crossing a reset is what tells a projection where one cycle ended. |
| `window_start_epoch` | When the window that reading belongs to OPENED, or `null` (#1701). Derived per provider — `resets_at − 604800` for a Claude week, `resets_at − windowDurationMins × 60` for Codex, the billing-cycle start Cursor itself reports. Recorded rather than re-derived at read time: the reset time can move, and a line carrying its own window start can be assigned to a cycle months later without knowing what the window length was then. |
| `source` | `manual` for a hand-run `/quotas`, `scheduled` for the unattended job (`--quiet`, or `AI_QUOTAS_SOURCE=scheduled`). An unrecognised `AI_QUOTAS_SOURCE` is refused on stderr and the run records `manual`. |

**Lines written before #1701 have no `window_start_epoch`,** and they stay readable: the
projection derives a window start from the row's label and reset time (`7-day` →
`resets_at − 7 days`) where it can, and treats the line as unusable where it cannot.
Nothing rewrites the file to add the field — the history is append-only, and a reader
that needs a field older lines never had is a reader that must degrade, not a reason to
rewrite a record.

**A failed row appends nothing.** No line with a null percentage: three months later such
a line is indistinguishable from a genuine reading, and a projection averaging it would
treat a failure as a `0`. The statuses in the table already say which accounts did not
read.

**Every failure here is non-fatal and loud.** An unwritable history file changes neither
the table nor the exit status — a display tool that started failing because its optional
log was unwritable would be a gate by accident — but it always says so on stderr, because
a hole in the record with nothing explaining it is exactly what a projection would
misread as a quiet day.

**No retention policy, deliberately.** CodeRabbit proposed one during local review and
it was declined for this increment: the daily job writes one line per account per day —
five accounts is under 400 KB a year — and a projection over a longer history is strictly
better than one over a truncated one, so the first thing a retention rule would delete is
the data #1701 exists to use. Revisit it if the file ever becomes large enough to notice,
which at this rate is years away.

**Concurrency.** The whole run's lines are appended in ONE `cat >>`, not one write per
row. A hand-run `/quotas` while the LaunchAgent happens to fire is the ordinary case, and
appending once keeps that block contiguous instead of interleaving it row by row with the
other run's. This narrows the window; it is not atomicity, and the distinction is the
point. `cat` writes in buffer-sized chunks, so a block larger than one chunk becomes
several `O_APPEND` writes and a concurrent appender can land between them. The cost is
bounded: `O_APPEND` advances the offset atomically per write, so the two runs never
overwrite each other and nothing written on an earlier day can be damaged — the only
casualty is the pair of records straddling a chunk boundary, which arrive torn. Readers
use `fromjson?` per line and skip what does not parse, so a torn line (from this, or from
a run killed mid-append) costs only itself, and the next run records again. A lock was
declined for the same reason a retention policy was: it would buy those two records at
the price of a stale-lock failure mode on a file whose whole contract is that it never
blocks the report it decorates.

**Reading order is not append order.** Every row of a run carries the clock that run
*started* on, while its position in the file is where the run *finished* — so a slow run
that began at 09:00 and appended at 09:05 sits after a quick one that began at 09:02. The
`LAST SNAPSHOT` footer therefore takes the newest `ts`, not the last line; the timestamps
are fixed-width UTC `%Y-%m-%dT%H:%M:%SZ`, so ordering them is a lexicographic sort.
`/quotas-setup schedule status` keeps its own copy of that lookup and sorts identically —
two commands answering "when did the job last run" differently is worse than either
answer being wrong. Anything else reading this file for a latest value owes itself the
same care.

**The history path is never followed through a symlink.** `-f` is true for a link to a
regular file and `-e` is false for a dangling one, so the plain tests would have let the
`chmod 600` retarget an unrelated file's mode, the append write quota JSON into it, and a
dangling link bring its target into existence. A symlink at that path is refused outright,
with a warning, before the create, the mode check, or the append — the run still exits 0,
because this is a record and not a gate.

### The daily unattended job

`/quotas-setup schedule install` writes `~/Library/LaunchAgents/com.claude.ai-quotas.plist`
(override with `AI_QUOTAS_LAUNCH_AGENT`) and loads it.

| Plist key | Value |
|-----------|-------|
| `Label` | `com.claude.ai-quotas` — also the launchctl service name. |
| `ProgramArguments` | The absolute path to `ai-quotas.sh`, then `--json --quiet`. |
| `RunAtLoad` | `true`, so installing it takes a reading immediately rather than waiting for tomorrow. |
| `StartCalendarInterval` | `Hour` **9**, `Minute` 0, local time. `--hour <0-23>` (or `AI_QUOTAS_SCHEDULE_HOUR`) changes it. |
| `StandardOutPath` / `StandardErrorPath` | `~/.claude/ai-quotas/launchd.log` (override with `AI_QUOTAS_LAUNCHD_LOG`). |
| `EnvironmentVariables` | `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` and `HOME`, plus `AI_QUOTAS_CONFIG` and `AI_QUOTAS_HISTORY` when the installing shell had them set. |

**Why 09:00.** launchd runs a missed calendar job at the next wake rather than skipping
it, but a reading taken hours late is a reading attributed to the wrong day; 09:00 is
late enough that the Mac is normally awake and early enough that the day's usage has not
yet accumulated, so consecutive snapshots measure a day apart rather than a day plus
however long the owner slept in.

**Why the explicit `PATH`.** launchd hands a job a minimal environment — typically
`/usr/bin:/bin:/usr/sbin:/sbin`. Every tool the reader needs beyond the base system lives
in Homebrew's prefix: `jq`, `codex`, and `node` are all under `/opt/homebrew/bin` on this
Mac (`/usr/local/bin` on Intel). Without it the scheduled run finds no `jq`, exits 5, and
writes a hole in the history every night.

**Why the path overrides are carried.** `AI_QUOTAS_CONFIG` and `AI_QUOTAS_HISTORY` each
override a `HOME`-derived default, so a shell that has one set gets it honoured by every
command the owner types — `schedule install`, `schedule status`, `/quotas` itself — while
a job that did not inherit it would resolve the default instead. The result would be two
history files, each looking complete, neither holding every reading. `AI_QUOTAS_PROFILE_ROOT`
is deliberately *not* carried: the reader never consults it, taking each account's
`profile_dir` from the registry (already absolute), so passing it would advertise an
effect it does not have.

**Why a re-install can report the previous definition.** launchd holds a job by label,
not by path. `schedule install` boots the old job out before bootstrapping the new plist,
but when the bootout does not take, neither `bootstrap` nor the legacy `load -w` can
replace it — and `launchctl list` keeps answering "loaded", because something under that
label is. The install says so explicitly rather than reporting success: the plist on disk
is the new one and takes effect at the next login, but until then the job running is the
one loaded before the install, at the old hour and the old reader path.

**Why launchd and not cron, and not a Claude scheduler.** The reader needs this user's
login context: the Keychain items the `claude` login created, the per-account
`CODEX_HOME` directories, the Cursor IDE's state store. A per-user LaunchAgent runs inside
exactly that context. A cron line or an agent-side scheduler would run the same reader
with none of it and record `needs-login` every day — not a gap in the history but a
history full of confident wrong answers. The `mcp__scheduled-tasks__*` scheduler is
declined for the same reason it is declined elsewhere
(`.claude/reference/cross-session-durability.md`), plus this one.

**The scheduled run opens no browser at all.** Since #1703 the Cursor read is `sqlite3`
plus `curl` — there is no browser left to launch headed or headless, so the bot-check
caveat #1668 carried under launchd is gone with it. A Cursor IDE that is signed out
yields a `needs-login` row, never a prompt and never a window appearing on the owner's
desktop at 09:00.

**Which copy of the reader gets scheduled.** The plist must outlive any checkout, so the
path is resolved `~/.claude/skills-worktree/.claude/scripts/ai-quotas.sh`, then
`~/.claude/scripts/ai-quotas.sh`, then the script's own sibling — and choosing the
sibling prints a warning naming the problem, because a LaunchAgent pointing into a
worktree keeps working until that worktree is removed and then fails every night into a
log nobody reads. `AI_QUOTAS_READER_BIN` overrides all three and is used **exclusively**
when set, for the same reason `AI_QUOTAS_CHEAPEST_BIN` is: a seam that falls back finds
the repo copy whenever the caller stands in a checkout, so the "reader unresolvable" path
could never be exercised from the one place the suite runs.

`schedule remove` runs `launchctl bootout gui/$(id -u)/com.claude.ai-quotas` (falling back
to `launchctl unload -w`) and deletes the plist; the recorded history is left alone.
`schedule status` reports the plist as present or absent, the job as loaded or not, the
log path, and the `ts` of the most recent `scheduled` snapshot. On a host that is not
macOS all three print one line and exit **2**.

`install` is idempotent: it boots out an already-loaded job before bootstrapping the new
plist, because `bootstrap` refuses a label launchd already holds and a re-install without
that would leave the OLD definition running while the new plist sat on disk looking
installed. Where `bootstrap` is unavailable it falls back to `launchctl load -w`.

### Nicknames and the compact table

`add <provider> <label> --nick <name>` and `nick <label> <name> [<provider>]` store
`nickname` in the registry; `/quotas` prints it in the ACCOUNT column in place of the
provider-reported email. The note still says `registered as <label>` whenever the label
differs from the reported email, so a nickname shortens a row without hiding which
registry entry produced it.

The table dropped **REMAIN** (it was `100 - USED` on every row) and the NOTE column now
carries **actionable text only** — the mislabelled-account warning and the row's detail.
`plan pro` and `via app-server` moved to `--json`: they are provenance, there is nothing
to do about either on an `ok` row, and together they were the widest thing on a healthy
one. `remaining_pct`, `plan`, and `source` are all still on every `--json` row —
dropping a derived column from the display is not a reason to break a consumer.

**The 100-column budget.** Five accounts with nicknames of about a dozen characters and
rows reading `ok` render at 98 columns, which the suite asserts by measuring the widest
line of an actual five-account render rather than by eyeballing a fixture. Two things can
legitimately exceed it, and both should: the note on a **failing** row is as long as the
instruction it carries, because truncating a `/quotas-setup relogin` command to save
columns trades the one line worth printing for the merely tidy ones; and a Cursor
`on-demand $1007.50 of $1000` overage label carries live dollars nobody would want
abbreviated.

Under the table, `LAST SNAPSHOT` names the most recent **scheduled** snapshot —
`stale (>1 day)` past 24 hours, `none yet` (with the install command) when the job has
never run. Manual snapshots deliberately do not count: the line is about whether the
unattended job is working. `--json` carries the same instant in
`last_scheduled_snapshot_at`, on every document including the two empty ones, so there is
nothing for a consumer to special-case. `--quiet` drops the footer and the cheapest-next
prose — under the unattended job they would only tell the job log about itself — but it
does **not** silence stderr, because the log is the only place a broken scheduled read
can be noticed.

### Test seams added at #1700

`AI_QUOTAS_HISTORY` and `AI_QUOTAS_SOURCE` on the reader; `AI_QUOTAS_LAUNCH_AGENT`,
`AI_QUOTAS_LAUNCHCTL_BIN`, `AI_QUOTAS_READER_BIN`, `AI_QUOTAS_LAUNCHD_LOG`,
`AI_QUOTAS_HISTORY`, and `AI_QUOTAS_SCHEDULE_HOUR` on the setup script. The plist, the job
log, and the history file otherwise resolve from `HOME`, which the suites already
redirect — so no case can touch the real `~/Library/LaunchAgents` or the owner's own
registry.

> **No apostrophes inside the reader's `jq` programs.** They are single-quoted shell
> strings, and one apostrophe in a jq comment closes the string; bash then parses the jq
> source and reports a syntax error a hundred lines from the comment that caused it.
> A comment reading "the row's detail" cost a full test-suite round to find.

## Burn-rate projection (increment 6, #1701)

A weekly cap that is 57 % used means something different on day two than on day six.
This increment reads the history above and answers the question the percentage does not:
**when did usage start in this window, how fast is it going, and how long does that
leave.** `.claude/scripts/quotas-forecast.sh` owns the arithmetic, annotating the
document `ai-quotas.sh --json` builds — the same row-in / row-out shape
`quotas-cheapest-next.sh` uses, for the same reason: a pace is a property of the recorded
history, not of any single read.

**Informational only, and this is the last place the boundary needs restating.** The
projection **never gates dispatch, never pauses, defers, or downgrades anything, and
never feeds `credit-budget.sh`.** It is the same third observational surface the table
and the cheapest-next hint are — `.claude/rules/safety.md` §"Anthropic Quota & Spend
Authority" holds the authority, and the rolled-back `/quota` skill (#499) is the
precedent for what gating on locally-read numbers costs. A days-left figure is a
sentence printed to the owner, and the owner decides what to do with it.

### The three columns

| Column | What it is |
|--------|-----------|
| `START` | The first day of this window any usage was recorded, as the ET weekday plus `d<N>` — `Wed d3` is "day 3 of the window, a Wednesday". A `<=` prefix (`<=Tue d2`) means the record does not reach back to the window start, so usage may have begun earlier: the day shown is the **latest** it can have been. |
| `%/DAY` | `used_pct / max(days_since_start, 1)`, one decimal. The `max` is what keeps a window whose usage started today from dividing by nothing. |
| `LEFT` | `remaining_pct / pct_per_day` in days, one decimal — or `resets first` when that runs past the reset, because the window comes back before the account runs out. |

`-` in any of the three means there is nothing to project: no window to place the reading
in, no usage yet (a 0 % row has no pace), or a row that did not read. Never a `0`, which
would read as "nothing is being spent".

### How the series is built

- **This account, this pool, this window.** History lines match on `provider`, `label`,
  and `window` — where `window` is the row's pool when the provider has pools, exactly as
  the history records it. A Cursor account's two pools are two series; averaging them
  would report a pace nobody set.
- **This window only.** A line whose `ts` falls before the window opened describes a
  cycle that has already reset. A line that recorded its **own** `window_start_epoch` is
  checked against this row's as well, and dropped when the two are more than half a
  window apart — near rather than equal, because a provider may move a reset by an hour
  inside a cycle and strict equality would then drop every earlier line and report every
  day as a fresh floor start.
- **A reading has to be inside its own window.** When the reset has already passed and
  the provider is still reporting the old figure, nothing is projected: placing today in
  that window would print `d9` of a seven-day one and measure a runway against a reset in
  the past.
- **Remaining is floored at zero.** Cursor percentages are not clamped at 100, and a
  negative remainder over a positive rate would print a runway of `-0.4` days.
- **Plus this run's own live reading**, in memory rather than from the file. That is what
  makes the first run project at all, and what keeps a run whose history append failed
  from silently reporting a stale pace.
- **One reading per day, the later one winning.** Day granularity is what was asked for;
  a rate computed over two readings an hour apart swings wildly. A hand-run `/quotas` at
  8 pm supersedes the unattended reading at 8 am rather than competing with it.

### The floor, and why the rate moves with it

When the earliest snapshot **in** the window already shows usage, nothing recorded proves
usage did not start sooner. The row is marked `usage_start_is_floor: true`, the cell gets
its `<=`, and the rate is computed **from the window start** rather than from the
snapshot. That is the slowest pace consistent with the record, which is the honest
direction to be wrong in — computing from the snapshot would divide by a shorter elapsed
time, report a faster burn, and promise a shorter runway than the evidence supports.

### `<=` and `-`, not `≤` and `—`

The table is aligned by `column -t`, which pads by counting **bytes** under the C locale
this fleet runs in. A three-byte character in one cell shifts every column to its right
on that row only, so the symbol that says "we are not sure it started this late" would be
paid for in a table nobody can read across. `<=` says the same thing in ASCII and
survives a pipe into anything; `-` is the marker every other unknown in this table
already uses.

### What the table gave up to fit

Three columns had to come from somewhere, and a five-account table has to stay inside 100
columns to be read at a glance:

- **The PROVIDER column is gone.** It was fixed-width and repeated what the account name
  already tells the owner — the same trade #1700 made when it dropped REMAIN. `provider`
  is still on every `--json` row.
- **STATUS folded into NOTE.** The status word now leads the note on any row that is not
  `ok` (`needs-login; /quotas-setup relogin …`), which is where the instruction about it
  already lived; an `ok` row says nothing, which is what `ok` was worth as a column. The
  vocabulary is unchanged, the two are now read as one sentence rather than as two
  columns that have to be crossed, and `status` is still on every `--json` row and is
  still the field to branch on.
- **RESETS shows a weekday and a time** (`Thu 8:00 PM`) rather than a full date with a
  zone. The countdown beside it says how far away that is and the heading says ET.
  `resets_at_et` keeps the long form for consumers; `resets_at_et_short` is the new field
  the table prints.
- **The countdown lost its `in ` prefix** — the `IN` heading supplies it.

The measured promise is the **clean** five-account table, exactly as it was at #1700: a
row carrying a relogin note, or a `resets first` cell, is wider, and always has been.
`.claude/scripts/tests/ai-quotas.test.sh` measures it rather than eyeballing a fixture.

### Test seams added at #1701

`AI_QUOTAS_FORECAST_BIN` on the reader — used **exclusively** when set, like
`AI_QUOTAS_CHEAPEST_BIN`, so the "helper unavailable" path can be exercised from inside a
checkout — and `AI_QUOTAS_HISTORY` plus `AI_QUOTAS_NOW` on `quotas-forecast.sh` itself.
The reader passes both through explicitly rather than letting them be inherited: a
projection that read a different history, or a different instant, than the table above it
would disagree with the table it decorates.

### A projection may only fill blanks

That seam is also the reason the reader cannot take the helper's word for what came back.
`AI_QUOTAS_FORECAST_BIN` points it at an arbitrary executable, so the returned document is
checked against the one that was sent: same rows, and every field that already **carried a
value** — `schema_version`, the threshold and basis, `cheapest_next`, and on each row the
provider, label, status and the figure itself — returned unchanged. A field that was
`null` on the way in is one the helper is there to fill — and only the **seven** it owns:
`usage_start_epoch`, `usage_start_is_floor`, `usage_start_day`, `usage_start_display`,
`pct_per_day`, `days_left`, `days_left_note`. A figure appearing in `overage` (null on
every row whenever the cheapest-next helper degraded) came from no provider, and the
table has no way to say so.

The key set is identical besides, top level and every row. A blank the helper **deleted**
instead of filling would leave the field off the document, and one report shape whatever
ran is exactly why those fields are declared `null` on rows nothing was projected for; a
key that was never **sent** has no legitimate way back, because every value the projection
writes already has a null waiting for it.

Counting rows is not enough. A same-length document that dropped `schema_version` or a
row's `provider`, or that rewrote a `used_pct` this run actually measured, is well-formed,
passes a shape check, and prints a report missing or misstating the fields a consumer
reads it for — with exit 0. Any such document is discarded **whole**: `$DOC` stays exactly
as it was, the three projection columns keep their `-`, and stderr says `DEGRADED` once.
Half a projection is not better than none, because nothing downstream could tell which
half it got.

## Symlink

Per `.claude/rules/skill-symlinks.md`, `/quotas-setup` and `/quotas` are symlinked into
`~/.claude/skills/` through the skills worktree **after** their PRs merge — never before,
and never directly to the root repo.
