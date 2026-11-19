# AI Quota Tracking — the Claude reader and token renewal

Part of the quota reference — start at [`ai-quotas.md`](./ai-quotas.md). The display-only rule, the reserve exception and the separate-wallet boundary stated there apply to this file.

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
place, and never routes model traffic through it. Renewing that same token for that same
read is the same call, restated (2026-09-14, #1716): the renewal uses the credential
already in the store, through Claude Code's own grant, and still routes no model traffic.

### The status-line reading, tried before the token (#2403)

Claude Code passes the status line a `rate_limits` object (Claude Code 2.1.321:
`five_hour` and `seven_day`, each with `used_percentage` and `resets_at` in epoch
seconds; it appears after the session's first API response and only for subscription
sign-ins). `statusline.sh` already runs every 10 seconds in each CLI profile, so it now
files those figures and the reader prefers them — they are the provider's own number
handed over by the harness, need no token, and cannot hit the token endpoint's rate limit.
Display and the reserve therefore stay inside `safety.md`'s rule against locally
estimated usage.

- **Where.** `~/.claude/ai-quotas/status-line/claude--<label>.json` (override:
  `AI_QUOTAS_STATUSLINE_DIR`). Mode 600 in a 700 folder, written to a temp file and moved
  into place. It holds the whole `rate_limits` object as handed over (`spend_limit`
  included), `subscription_type`, the capture time (`captured_at_epoch` and UTC ISO-8601
  `captured_at`), the account label, and a normalised `windows` view the reader uses. Later
  columns (fetched, resets, paid usage) read their fields from this file. Only those
  payload keys are copied, so a credential elsewhere in the payload cannot reach it.
- **Which account.** The session's own `.claude.json` names the signed-in email
  (`${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json`); the registry's Claude account whose
  profile `.claude.json` (or email-shaped label) carries the same email owns the reading.
  Never by folder name (#1850). Zero or several matches: the reading is dropped. The
  default `~/.claude` install is the same account as the profile that shares its email.
- **When it is used.** The reader (`lib/claude-status-reading.sh`, called first in
  `read_claude_account`) uses a reading no older than `AI_QUOTAS_STATUSLINE_MAX_AGE`
  (default 1800 s) whose 7-day window has not since reset, and whose stored label matches.
  The row's `source` is `status-line` and its note says how old the figure is. Otherwise
  the token path runs, and a successful token-path row notes why the saved reading was
  passed over. `--five-hour` adds the saved 5-hour window.
- **No network, no slow work.** The status line does only local file reads and writes,
  skips the write when nothing changed inside 60 s, does nothing when the payload has no
  `rate_limits`, and prints its line whatever happens in this path.
- **Reserve.** `quota-reserve.sh --refresh` reads through `ai-quotas.sh --json
  --no-last-known`, so a status-line row is a normal provider-reported row for it.
- **Cool-off after a 429.** When the token endpoint answers 429, renewal for that
  account is skipped for `AI_QUOTAS_CLAUDE_COOLOFF_SECONDS` (default 1800, or the
  `Retry-After` when longer, at most 6 h). The marker is
  `~/.claude/ai-quotas/token-cooloff/claude--<label>.json` (`AI_QUOTAS_COOLOFF_DIR`),
  two timestamps only; a successful renewal clears it. During the cool-off the row reads
  `rate-limited` and says renewal is paused.
- **Live check owed.** The payload shape was taken from the 2.1.321 binary and the
  issue, not from a captured live payload; the tests use fixtures of that shape.
  Confirm once with `claude-work`: send a message, run `/quotas`, compare with the
  app's usage page.
- **Not covered.** The desktop app renders no status line (its agent files a reading
  instead, below), and headless `-p` runs may not either; those accounts still read
  through the token path.

### The app usage tool reading (#2404)

The Claude desktop app runs no status line, and its usage tool
(`mcp__ccd_session_mgmt__get_usage`) is callable only by an agent, never by a hook or the
scheduled reader. So the agent takes the reading and pipes the tool's JSON (the whole
object, or just `plan`) to `claude-usage-observe.sh -` (or a file path). The skills name the
points: `/quotas` before printing the table, `/pm` and `/subagent` at session start and
before an autonomous launch or refill. A missing tool, or a refusal, is skipped silently:
the reading is optional and gates nothing.

- **Refused** (one-line reason, exit 1, nothing written): plan `status` not `ok`; no single
  `Weekly · all models` window; its `percentUsed` not a number from 0 to 100; its `resetsAt`
  not a UTC ISO-8601 timestamp or already past; the session's account unreadable (`CLAUDE_CODE_USER_EMAIL` unset and no signed-in `.claude.json`), those two disagreeing, unregistered, or matching
  several registered accounts (compared case-insensitively, exactly; never guessed).
- **Where.** `claude-app--<label>.json` beside the status line's file (same folder, mode
  600/700, temp file then move, no credential). It has the status-line file's `windows`
  shape, `source: "app-usage-tool"`, `captured_at_epoch`, and the blocks the paid-usage,
  resets and top-tier columns read (Issues #2409, #2408, #2415; see "Paid usage, resets and
  top tier" in [`ai-quotas-reader.md`](./ai-quotas-reader.md)): `extra_usage` (enabled, percent, spent, monthly limit, currency),
  `weekly_models` (the per-model weekly windows) and `limit_resets` (an optional block an
  agent supplies, because the tool does not return it).
- **Newer of two.** The reader looks at both files for an account and uses the usable one
  with the smaller age (fresh within `AI_QUOTAS_STATUSLINE_MAX_AGE`, weekly window not yet
  reset). The row's `source` is `status-line` or `app-usage-tool` and its note says which.
  A passed-over reading adds a note only when neither was usable.
- **Capture time.** Every saved-reading row sets `fetched_at_epoch` to the capture time, the
  field a provider sets for a figure not read live in this run, so the `fetched` column shows
  the figure's own date.
- **Reserve.** `quota-reserve.sh --refresh` reads through `ai-quotas.sh --json`, so the row
  is an ordinary provider-reported one. A reading older than the limit is not used, the
  account reads `unknown`, and the reserve fails open as before.
- **Live check owed.** Run `/quotas` in a desktop-app session and compare with the app's
  usage card.

### Renewing an expired access token (#1716)

**The bug this removes.** On 2026-09-14 both Claude rows read `needs-login` three days
after those profiles were logged in. Nothing was wrong with the stored credential: the
access token had simply expired, and the thing that normally renews it — Claude Code,
on launch — is never run on an isolated side profile. The daily snapshot job had been
recording `needs-login` the whole time. A tracker whose rows go dark within hours of a
login cannot feed a history or a forecast, so the reader now renews the token itself.

**The stored item.** *Observed 2026-09-14, Claude Code 2.1.270. Undocumented and
Claude Code's own — re-verify before relying on any of it.* The Keychain item named by
`credential_ref.service` holds one JSON document:

```
claudeAiOauth.accessToken            the bearer token the usage call uses
claudeAiOauth.refreshToken           the grant this renewal spends
claudeAiOauth.expiresAt              MILLISECONDS since the epoch (13 digits)
claudeAiOauth.refreshTokenExpiresAt
claudeAiOauth.scopes[]               e.g. user:inference, user:profile, …
claudeAiOauth.subscriptionType       e.g. "max"
claudeAiOauth.rateLimitTier
```

Confirmed by reading only the item's **key paths** (`jq 'paths|join(".")'`), never its
values. `expiresAt` is accepted **only when it is a number** — a store that moved it to
a string date would otherwise compare as a string, read as "not expired" forever, and
reproduce exactly the silent success this change removes.

**The endpoint and client id.** *Observed 2026-09-14, read out of the installed Claude
Code bundle (`strings` over `claude.app/Contents/MacOS/claude`), not guessed:*

| | Value | Where it came from |
|---|---|---|
| Token endpoint | `https://platform.claude.com/v1/oauth/token` | `TOKEN_URL:` in the bundle's OAuth config object |
| Client id | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` | `CLIENT_ID:` in the same object — matches the community value |
| Request | `POST`, `Content-Type: application/json`, body `{grant_type:"refresh_token", refresh_token, client_id, scope:"<space-joined>"}` | the bundle's own refresh call |
| Response | `{access_token, refresh_token, expires_in}`; the new expiry is `now + expires_in × 1000` ms, and an omitted `refresh_token` means **keep the stored one** | same |

Seams: `AI_QUOTAS_CLAUDE_TOKEN_URL`, `AI_QUOTAS_CLAUDE_CLIENT_ID`.

**When it renews.** Before the usage call when the stored `expiresAt` has passed (with a
60 s margin, so a token cannot die mid-request), and otherwise on a 401/403 from the
usage endpoint — **one refresh and one retry, never a loop.** A second 401 is a dead
login, and asking again only burns the rate limit on the way to the same answer. A store
carrying **no** expiry never triggers a refresh on that ground alone; it would cost a
refresh per account per run.

**What each failure says.** The distinction is load-bearing, because `needs-login` sends
the owner through an interactive login and most of these are not fixable that way:

| Outcome | Status | Note |
|---|---|---|
| Refresh rejected — an explicit `invalid_grant`/`invalid_client`/`unauthorized_client`, or HTTP 401 | `needs-login` | names the error code or status, plus the existing `/quotas-setup relogin` command |
| HTTP 429 | `rate-limited` | names any `Retry-After`; nothing is written back |
| Token endpoint unreachable, or any other non-200 — **a bare 400 or 403 with no OAuth error code included** | `unreachable` | names the curl exit or the HTTP status |
| HTTP 200 carrying no `access_token` | `unreachable` | a **changed shape**, not a dead grant — a login could not fix it |
| Renewed, but the write-back failed | `ok` | the figures were read; the row discloses that the renewal was not persisted |

A bare 400 or 403 is deliberately **not** `needs-login`: 403 is what an edge proxy
answers, and sending the owner through an interactive login over a WAF block is the
misdiagnosis this status split exists to prevent. Only an error code from RFC 6749's
vocabulary, or a 401 from the endpoint itself, says the grant is finished.

**Two error envelopes are read, not one.** RFC 6749 §5.2 puts a bare string in `error`;
Anthropic nests it — `{"error":{"type":"rate_limit_error","message":…}}`, *observed
2026-09-14 on a live 429 through Cloudflare*. A reader that understood only the flat
shape would classify a genuinely dead grant delivered in the nested one as `unreachable`
and never tell the owner to log in again. Only the `type`/`error` **code** is ever
quoted; the `message` beside it is not, because an endpoint that echoed the submitted
token inside a message would otherwise print it.

**429 is `rate-limited`, not `unreachable`.** The renewal endpoint really does rate-limit
(same 2026-09-14 observation), and the reader already owns a status that says so.
Recording a rate limit as `unreachable` would put a run of outages that never happened
into the snapshot history the burn-rate projection reads.

**Rotation makes concurrency a correctness problem, not a tidiness one.** Claude Code
renews this same item, and the daily job can overlap a manual run. Refresh tokens
**rotate**, so whoever renews second is holding a token the first renewal already
invalidated. Both directions are handled:

- **Before writing:** the store is re-read and the write stands down unless it still
  holds the access token this run started from — compare-and-set, the same shape as the
  park-retirement writes in #1596. A blind last-writer-wins store could otherwise leave
  the item holding an already-invalidated token, and the *next* run would report
  `needs-login` on a login nobody lost. The window is not zero (nothing here can make a
  Keychain write atomic against another process) but it is the width of one `security`
  call rather than of a network round trip.
- **Before believing a rejection:** an `invalid_grant`/401 is checked against the store
  first. If it now holds a *different* access token, somebody else renewed and this run's
  refresh token was invalidated **by that rotation** — the login is alive, so their
  credential is adopted and the read proceeds. Only a rejection with nothing new in the
  store is a dead login. Losing either race costs nothing and is not reported as a
  problem.

**The write-back.** The renewed `accessToken`, `refreshToken`, and `expiresAt` are
**merged into** the stored document — never replacing it — and written back to the same
store, so Claude Code and this reader stay in step on one credential instead of each
holding half a rotated pair. Everything else in the item (`scopes`, `subscriptionType`,
`rateLimitTier`, anything a later Claude Code adds) is preserved; a write that dropped
those would break the very client this is keeping in step.

An omitted `expires_in` **deletes** the stored `expiresAt` rather than leaving the old
one in place. Keeping it would park a past timestamp beside a freshly renewed token, and
every later run would read that as "expired" and spend another refresh for ever; with the
field absent the proactive check stands down and the 401 path still covers the token,
which is the honest state — unknown.

- **Keychain:** `security add-generic-password -U -a <acct> -s <service> -w`, with the
  document on **stdin**. Three things are not optional here, all measured 2026-09-14:
  `-w` must be **last and valueless** or the value is in argv and therefore in `ps`;
  security(1) then asks for the value **twice** ("password data for new item:", "retype
  password for new item:"), so it is written twice; and **no keychain may be named**,
  because a trailing keychain argument is eaten by `-w` as the password itself — it
  writes the *path* as the secret into the default keychain. The `acct` attribute is read
  back off the attribute dump (`find-generic-password` **without** `-w`, so no value is
  involved) and passed to the update, or `-U` lands a second item beside the one Claude
  Code reads. An attribute dump this reader cannot parse an `acct` out of **refuses the
  write** rather than guessing at the item's identity — the row then reads `ok` and
  discloses that the renewal was not persisted.
- **`<profile_dir>/.credentials.json`:** written to a `mktemp` sibling in the same
  directory, `chmod 600` **before** any content lands in it, then renamed over the
  original — atomic on the same filesystem, so a concurrent reader sees the old document
  or the new one, never a truncated one.

**Nothing is printed.** The renewal request body is built by `jq` into a 0600 file inside
the run's 0700 temp dir and handed to `curl` as `--data-binary @<path>`, so neither token
is in this script's argv or curl's. **Nor in `jq`'s:** the tokens reach `jq` through a
per-command environment entry (`$ENV.AIQ_RT`), never `--arg`, because `--arg` is an
argument like any other and argv is world-readable through `ps`. `jq` has no test seam —
it is the real binary — so the suite asserts this at the **source** level instead, with a
control that proves the scan fires on the shape it forbids. Failure notes are built from an HTTP status and an
OAuth error **code** from RFC 6749's fixed vocabulary, never from a response body
verbatim — an endpoint that echoed the submitted token back inside an error message would
otherwise print it. The tokens are cleared from their globals as soon as the request they
serve returns — **and on the paths where no request happens at all**: a stored document
carrying a `refreshToken` but no `accessToken` has already loaded the refresh material by
the time the read fails, so that failure clears before it returns rather than leaving the
token live until the next Claude account is read or the shell exits (CodeRabbit, #1721).
