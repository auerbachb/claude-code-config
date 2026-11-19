# AI Quota Tracking — the Cursor reader

Part of the quota reference — start at [`ai-quotas.md`](./ai-quotas.md). The display-only rule, the reserve exception and the separate-wallet boundary stated there apply to this file.

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
like a right one, which is the failure every other quota reader is built to
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

### Cursor observation route and the encrypted IDE token (Issue #1870)

Cursor 3.29.9 keeps the IDE access token encrypted (`cursor-safe-storage:v1:`), so the IDE-token reader
cannot read a user id and reports `unreadable` with a pointer to the observation route. That state is a standing
condition, not a new fault each run: the outcome ledger records it under the fixed class `ide_token_encrypted`,
and `quotas-outcomes.py` leaves that class out of each source's `consecutive_failures`, so it never grows into a
"source failed N consecutive reads" recommendation. The account-level streak still counts the unreadable reads,
because the account really was unreadable. The reader does not decrypt the token and does not ask the macOS
keychain for the storage key.

The working route is an agent reading the signed-in Spending page, `https://cursor.com/dashboard/spending`, in the
Claude desktop app's built-in browser pane (`mcp__Claude_Browser__*`), or in Chrome (`mcp__claude-in-chrome__*`).
`lib/quotas-browser.py --print-instructions cursor` prints the fields and file shape; the agent records them in a
private file and passes it with `--browser-results`. Reading of 2026-11-16 (Ultra): Cursor Models 100% used,
Other Models 100% used, On-Demand $6.33 of $50, limits reset Nov 28.

Observation fields added on top of the pool rows, all optional so older files still validate: `plan`,
`on_demand_used_usd`, `on_demand_limit_usd` (or `on_demand_unlimited: true`, never both), `cycle_resets_at_epoch`
(fills pool rows with no reset of their own). In `--json` rows they appear as `plan`, `spend_limit_used_usd`,
`spend_limit_usd` and `spend_limit_unlimited` (`true` or `null`). The table keeps its existing columns; separate
paid-usage columns are Issue #2409, which only has to render these fields.

Cursor identity (#1870): the Cursor dashboard shows no account email, so a Cursor observation's `email` is optional
(empty, null or absent). Without one the figures still show, the row detail says `account not verified`, `--json`
carries `identity_verified: false`, and the last-known record is saved under the source `live: browser (account not
verified)`. A supplied email must match the IDE's cached email (`identity_verified: true`); a mismatch is rejected
as before. `identity_verified` is on every row, null for every provider and path where it does not apply. Provider
`claude` is unchanged: its email stays required. The page shows a spinner first; the figures can take 15 seconds or
more, so the reader waits and re-reads before calling it unreadable.
