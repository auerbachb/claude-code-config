# AI Quota Tracking — the shared reader contract, overage, ledger and usage sources

Part of the quota reference — start at [`ai-quotas.md`](./ai-quotas.md). The display-only rule, the reserve exception and the separate-wallet boundary stated there apply to this file.

## Logged-out actions, notifications, and diagnosis (Issue #1886)

Every final report row declares `action`, a string on `needs-login` and null otherwise.
Claude/Codex actions are `/quotas-setup relogin <label> <provider>` with shell quoting
when needed; Cursor says `open the Cursor IDE and sign in`. Text prints each account's
action once before the table. The JSON `detail` is unchanged. Relaying an account must
lead with its action. Labels with terminal controls have no printable action and are
excluded from notifications. No path stores/replays a password or completes a human's
OAuth sign-in.

A scheduled snapshot (`--quiet` or `AI_QUOTAS_SOURCE=scheduled`) attempts a native macOS
notification for each **final** logged-out account, after source fallback. Interactive
reads and reserve refreshes do not notify. The local calendar date follows the machine's
time zone, not the report's UTC/ET display clock. State is private mode 0600 at
`~/.claude/ai-quotas-notifications.json`, override `AI_QUOTAS_NOTIFY_STATE`. The shared
state lock serializes claims; a bounded, atomically published `(provider,label,day)`
claim precedes delivery. Multiple usage windows and simultaneous runs cannot duplicate
an attempt. At most one **attempt** per account/day: failed/disabled OS delivery is not
retried that day. The latest seven observed local dates are retained (at most 1000
claims). A clock rollback before that retained window skips delivery, preserving
deduplication without unbounded state; returning to a retained date reuses its claim.
Corrupt, oversized, symlink, special-file or contended state fails open for the report
and skips delivery. OS notification settings may suppress presentation. The adapter is
bounded to three seconds per account; lock wait is at most one second. Notifications
use only provider, registered label and exact action, never endpoint detail, tokens or
reported-email metadata. The helper owns its cleanup and cannot replace the reader's
trap. `AI_QUOTAS_NOTIFY_DAY` and `AI_QUOTAS_NOTIFY_BIN` are synthetic-test seams.

**Token scope fallback.** [Official Claude authentication documentation](https://code.claude.com/docs/en/authentication#generate-a-long-lived-token)
states that `setup-token` produces a one-year token for model requests and prints it
instead of saving it. That scope cannot serve the usage reader; the issue explicitly
narrows the delivery scope to notification + relogin in this case. The original Codex
cause investigation is deferred to [Issue #1970](https://github.com/auerbachb/claude-code-config/issues/1970),
not an additional acceptance gate for that authorized fallback. No long-lived-token installer or reader
override is shipped, and no token was minted or live credential inspected to verify
this. Existing OAuth refresh behavior remains in place. Do not run `setup-token` merely
to inspect its output or store a password to work around expiry.

**Codex diagnosis remains unverified.** On November 6, 2026, a metadata-only audit of
the actual default/`AI_QUOTAS_HISTORY`, configured LaunchAgent history, and reserve
reader outcome paths found 317 Codex outcomes across two account labels, all
`ok`, `app-server`, and null error class. No refresh failure was present. The previous
two bounded ordinary profile reads also succeeded; there is no basis to claim expiry,
revocation or reuse caused the reported historical logouts. `credential_unavailable`,
HTTP 401, or a generic reader failure alone cannot distinguish these causes. Preserve
sanitized fixed upstream failure codes when they become available and correlate their
account/source/time before naming a cause. Do not copy response bodies, auth files,
tokens or passwords into the ledger or a diagnosis. The original diagnosis is not
claimed completed: [Issue #1970](https://github.com/auerbachb/claude-code-config/issues/1970)
tracks the actual failure evidence and follow-up work under the original conditional
scope. Unknown history does not prevent the notification/relogin fallback from shipping
once its active acceptance criteria and the normal review/CI gates pass.

## The reader — `/quotas` and `ai-quotas.sh` (increment 2, #1667)

`ai-quotas.sh` reads the registry ([overview](./ai-quotas.md)) and prints one row per account per window:
account, provider, window, used %, remaining %, reset time in `America/New_York`, a
countdown, a status, and a note. `--five-hour` adds the short windows that arrive in the
same payload; `--account <label>` narrows the run; `--json` emits a document carrying
those rows (§"Output" under "Overage" below — it was a bare array before #1669). Flags and
exit codes: `ai-quotas.sh --help`.

**Display only, and the reader enforces it structurally: it opens no state file for
writing.** Its writes are the append-only telemetry line every script here emits to
`~/.claude/script-usage.log` (script name and the action word `read`, never the
arguments — those carry the account label), and the last-known folder described in
§"Last-known folder (#2280)" below, which only the display reads. Nothing reads that log back into a decision,
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

### Test seams

`AI_QUOTAS_CONFIG`, `AI_QUOTAS_CURL_BIN`, `AI_QUOTAS_SECURITY_BIN`,
`AI_QUOTAS_CLAUDE_BIN`, `AI_QUOTAS_CODEX_BIN`, `AI_QUOTAS_CLAUDE_VERSION`,
`AI_QUOTAS_PLATFORM`, `AI_QUOTAS_ANTHROPIC_URL`, `AI_QUOTAS_CHATGPT_URL`,
`AI_QUOTAS_HTTP_TIMEOUT`, `AI_QUOTAS_CODEX_TIMEOUT`, `AI_QUOTAS_SQLITE3_BIN`,
`AI_QUOTAS_CURSOR_STATE_DB` (a fixture SQLite DB, so no test touches the real Cursor IDE
store), `AI_QUOTAS_CLAUDE_TOKEN_URL` and `AI_QUOTAS_CLAUDE_CLIENT_ID` (#1716 — the
renewal endpoint and client id, so the refresh cases run entirely against the fake `curl`
and the fake `security`, and no test can renew or overwrite a real credential), and
`AI_QUOTAS_NOW` (a fixed clock,
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
| `spend_limit_used_usd`, `spend_limit_usd` | Cursor's `spendLimitUsage.individualUsed` / `.individualLimit`, cents ÷ 100 — the on-demand block of the captured response documented in [`ai-quotas-cursor.md`](./ai-quotas-cursor.md) (§"The response, and what each row takes from it") | `on-demand $1007.50 of $1000`, `figure_source: "live"` |
| `free_resets_remaining` | Codex — **measured (#1862)**. `account/rateLimits/read` carries `rateLimitResetCredits.availableCount` as a sibling of `rateLimits`; the HTTP fallback carries `rate_limit_reset_credits.available_count`. The older guessed keys (`freeResetsRemaining`, `free_resets_remaining`, `resets.freeRemaining`) stay as fallbacks. Contributes **nothing** when none is a plain number | `2 free resets`, `figure_source: "live"` |
| `free_reset_expires_epoch`, `free_reset_expires_et_short` | Codex — the soonest `expiresAt` among `rateLimitResetCredits.credits` whose `status` is `available`, as an epoch and as an Eastern date and time. App-server path only: the HTTP summary carries a count and no credit list. Credits expire, so this is what answers "when must I use it by" | `1 free reset, exp Nov 6 6:31PM` in the table cell (compact, as this column sets the table width); the full `Nov 6 6:31 PM ET` stays on the row and in the hint |
| `credits_remaining_usd` | Codex — speculative on the same terms (`creditBalanceUsd`, `credits.balanceUsd`) | reported in the `overage` object, not yet in the label |

The count above was a hook until 2026-10-27, when a real payload settled where it lives: the
reader had been keeping only `.result.rateLimits` and discarding the sibling that holds the
balance. The lookups are still written so that being wrong costs nothing: a key that is absent, or present with a value that is not a plain number,
leaves the watermark to answer. A bare `tonumber` there would turn `"n/a"` into `0` and
render `0 free resets` — a figure nobody sent, pointing straight at a paid reset. If
OpenAI renames the balance again, add it in `codex_live_overage` and here.

### The Codex reset watermark

`~/.claude/quotas/codex-reset.json` (override the directory with
`CLAUDE_QUOTAS_STATE_DIR`) records resets **per registered Codex label**. Write only
explicitly after using a reset:

```bash
quotas-cheapest-next.sh --record-codex-reset --account my-codex [YYYY-MM-DD]
```

The date defaults to today in Eastern time. The label must exist as a Codex account
in `~/.claude/ai-quotas.json` (`AI_QUOTAS_CONFIG` overrides that registry). Schema 2.0
stores an `accounts` object keyed by label, each with `month`, `used_on` and
`recorded_at`. Only that label's current-Eastern-month record marks its free reset
spent. Other accounts retain their own verdict; account renaming does not transfer
a watermark. Live per-row reset figures still take precedence.

`--codex-reset-status` returns `{month, accounts, watermark_file}` with one verdict
per registered Codex label. Each verdict has `free_reset_available`, `figure_source`
and `used_on`. It has no aggregate spent/free verdict. `AI_QUOTAS_NOW` freezes the
month in tests.

Missing or unreadable records assume a free reset for that account. A corrupt
individual entry does not discard valid siblings. Legacy global schema-1 records
belong to no account, so they never mark every account spent; an explicit account
recording replaces that legacy shape. Unknown schemas or corrupt top-level files
must be repaired or moved aside before writing. A missing/broken registry prevents
recording; it never invents an account association.

Writes use a bounded shared OS lock and private atomic replacement, preserving other
accounts. Backfilling an older month over the selected account's newer record is
refused (exit 5); another account's newer month does not block it. Invalid calendar
dates are refused (exit 3). These records remain advisory: no purchases, logins or
dispatch decisions occur.

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

## Read-outcome ledger (Issue #1883)

Every supported account read records one terminal attempt, independently of how many
usage windows it produces. Successful window history keeps its existing schema and
retention; outcomes live in `<history-stem>.outcomes.jsonl` beside `AI_QUOTAS_HISTORY`
(default `~/.claude/ai-quotas-history.outcomes.jsonl`). This keeps forecast consumers
and redirected reserve/history reads isolated. No history destination means no
outcome persistence. Each row has `ts`, `provider`, `label`, `source`, `status`,
`error_class`, and `trigger` (`manual`/`scheduled`). Unsupported providers and excluded
accounts are not attempted.

Statuses: `ok`, `logged_out` (the display row remains `needs-login`), `unreadable`
(transport/tool failure), `rate_limited`, `timeout` (curl exit 28), `parse_error`
(invalid JSON or unusable response shape). The terminal source reflects the source
that produced the result, including a successful Codex HTTP fallback. Only fixed
error classes and numeric HTTP/curl codes are allowed (`[a-z0-9_]{1,40}`); unknown
classes become `other`, and successful attempts have null error class. Details,
response bodies, and credentials never enter this ledger.

The Python 3 helper retains 45 days and at most 50,000 rows, tolerates malformed
lines, refuses symlink/non-regular destinations, and atomically replaces mode-600
files under a bounded OS advisory lock. Lock files remain in place; process exit
automatically releases their locks, avoiding stale-lock recovery races. Persistence
failure warns and leaves the report working. Python 3 is required for this optional
ledger; missing Python disables outcomes with an explicit warning.

JSON `account_reliability` and the table's RELIABILITY footer show per-account 7d/30d
attempt counts, failure counts/rates (fractions), and the consecutive failure streak
(`streak_count`, `streak_status`, `streak_since`). Statistics include the current run
exactly once, even if persistence fails, and only show accounts attempted this run.
Same-timestamp attempts retain append order; the streak counts reads, not days.
Unattended `--quiet` runs still record outcomes but suppress the footer.

A missing Claude/Codex credential is a local `credential-store` preflight outcome,
not an attempted usage-endpoint request. Existing endpoint source IDs remain
unchanged once that reader runs. Cursor HTTP 429 uses the existing `rate-limited`
display status and `rate_limited` ledger status.

### Ordered usage sources (#1884)

Optional account `sources` arrays select the acquisition order. Defaults are Claude `oauth-usage,browser` (#2299), Codex `app-server,http`, Cursor `ide-token,browser`. Configure with `ai-quotas-setup.sh sources <label> <comma-separated order> [<provider>]`; `default` removes the override. `sources threshold <N>` sets the registry `source_failure_threshold` (default 3). Unknown reader source names produce safe unreadable attempts; setup accepts only known provider sources. Winning rows retain their acquisition `.source` and identify `via <source>` in a compact SOURCE footer.

Every source attempt uses the bounded sibling outcomes ledger introduced in #1883. Its six status values are unchanged. Optional `terminal:false` marks intermediate attempts, preserving account reliability rates/streaks using the terminal result; historical rows without this field remain terminal. `requested_source` preserves adapter selection when acquisition stopped at a credential-store preflight. Per-source consecutive failures remain separate, so fallback success does not hide a broken primary. Browser skips retain `status:unreadable`, `skip_reason:browser-unattended`, and `terminal:false`; the fixed `skipped:browser-unattended` meaning is excluded from both account and source failure streaks. Reserve history redirection also isolates this derived ledger.

`--browser` is explicit interactive authority to invoke the supported Claude CLI v2.1.248-or-later `--chrome` bridge. Only navigation to the Cursor usage dashboard and rendered-page reading are permitted; the bridge enforces its tool boundary with PreToolUse/PostToolUse hooks. It initializes a native tab group and creates a dedicated tab. Navigation acknowledgments never authorize reads: fresh native `tabs_context_mcp` metadata must prove the actual dedicated-tab URL before each page read, and the permission is consumed by that read. Redirects, errors and unknown context remain unavailable. It never signs in, types credentials, executes page JavaScript, or changes settings. Chrome must already have its extension/session connected. Plain shell and quiet/scheduled runs never invoke it. `--browser-results <file>` supports externally mediated observations and resumes at browser; private regular result files, schema, freshness, identity and finite pool numbers are strictly validated. CLI transport failure, missing connection and malformed observations fail closed without echoing diagnostics. See `/quotas` for the exact schema. The previous IDE-only implementation remains the default first source. Claude's `browser` source (#2299) has no collector: plain `--browser` records `browser_agent_observation_required`, and a `--browser-results` file with `provider:"claude"` (windows `7-day`, `5-hour`) is the only input. The expected identity is the profile's `oauthAccount.emailAddress` agreeing with an email-shaped label; a conflict or no identity rejects. The observation's `email` stays required; it is rendered in the claude.ai profile menu at the bottom of the sidebar. An optional `organization_id` (the Account page's "Organization ID", Settings → Account) is an extra check matched against the profile's `oauthAccount.organizationUuid` (#2337): a non-matching ID is rejected, and an ID with no email is rejected, since one organization can have several members. A profile with no recorded organization ID skips that comparison. The observation's `provider` selects the account among any that share the label: a Codex account with the same label is left out of the browser pass, and a provider with no account for that label, or an unreadable file, is a usage error (exit 3) before any read. An `ok` observation is saved to last-known through the same ok-row path as every other live read, and scheduled runs record `browser-unattended` for it.

Supported CLI integration: [Claude Code Chrome documentation](https://code.claude.com/docs/en/chrome) and [CLI reference](https://code.claude.com/docs/en/cli-reference). The live Chrome extension may be unavailable in a given runtime; synthetic bridge tests verify support independently of live login availability.

#### Browser failure diagnostics (Issue #1906)

The outcomes ledger retains fixed classes, without raw CLI errors, tool payloads,
page text, tab IDs, URLs, paths, credentials or email in diagnostic evidence.
The separate private guard record contains only an allowlisted last failure and
two booleans (owned tab proved; read authorized). It is observational and never
changes tool permission or substitutes for fresh URL proof. Recovered failures
clear on positive proof; missing/invalid records are unknown.

| `error_class` | Proven boundary and recovery |
|---|---|
| `browser_launch_failed` | OS failure launching the bridge; check the installed CLI. |
| `browser_connection_unavailable` | Native context query failed before ownership; check the existing extension connection. |
| `browser_tool_denied` | The read-only guard denied a tool; inspect its allowed workflow. |
| `browser_tab_create_failed` | The owned-tab creation response failed or did not prove creation. |
| `browser_destination_unverified` | An owned navigation acknowledgment or applicable fresh destination check failed. |
| `browser_observation_rejected` | The completed envelope/result file failed schema, privacy, identity or freshness validation. |
| `browser_timeout` | The actual outer subprocess raised its 90-second timeout; ledger status is `timeout`. |
| `browser_stage_unknown` | Available facts cannot establish a stage; retain the fallback without guessing a login cause. |
| `browser_agent_observation_required` | Claude only (#2299): plain `--browser` never opens claude.ai. Supply an agent-collected observation with `--browser-results`. |

Other failures retain `unreadable`; validated signed-out observations retain
`logged_out` / `browser_logged_out`. A model's valid `unreadable` result alone
does not prove a stage. Missing post events or CLI-side permission rejection may
therefore remain unknown. Invalid/private-format result files can prove only
observation rejection, not which browser operation failed. Unknown helper classes
become `browser_stage_unknown` before logging or display. The ledger's existing
sanitizer checks class syntax only; older `browser_unavailable` rows remain intact.

No diagnostic reruns a probe. A future bounded live read requires an existing
Chrome connection, independent expected account identity and explicit owner
authorization. Never automate sign-in or repeat a failed probe without a
concrete new reason. These diagnostics were validated with synthetic fixtures.

### Completed native browser reads

Internal Chrome-CLI `ok` observations require a private per-attempt completion
receipt, separate from diagnostics and permission booleans. The guard correlates a
read's allowed `PreToolUse` with successful `PostToolUse` using its tool-use ID,
owned tab and attempt nonce. Fresh native actual-URL metadata is still required
before every read. Missing, mismatched, reused, denied, failed, interrupted or
unknown read evidence cannot produce an `ok` quota row. A fixed
`browser_read_unverified` class reports unreadable provenance; the six ledger
statuses and source fallback order are unchanged.

The native MCP boundary was exercised with installed Claude Code2.1.312, a private
configuration, a synthetic stdio MCP tool and a loopback model stub, with no live
browser, production credential or paid request. Successful MCP reads emitted
`tool_response` as a nonempty text content-block list with `tool_use_id`; an
`isError:true` tool emitted no successful post event. The committed synthetic
fixture records that generic boundary, not a live Chrome capture. Other shapes
remain unsupported. [Claude's hook reference](https://code.claude.com/docs/en/hooks#posttooluse-input)
documents tool-specific responses and correlation IDs.

Receipt files contain only schema version, attempt nonce and bounded completion
count. They retain no page/error/tool payload, URL, tab ID, email or credential.
Authorization state stays separate and private; diagnostics never grant access.
This relies on the native CLI/hook boundary and preserves the existing identity,
freshness and observation-schema checks. Independently mediated
`--browser-results` files keep their separate explicit/private validation boundary
and do not require internal-hook receipts. Sign-in is never automated.

API-first assessment (2026-11-08 UTC): Cursor documents usage/spending endpoints in
its [Admin API](https://cursor.com/docs/account/teams/admin-api). Its current
[API overview](https://cursor.com/docs/api) lists Admin/Analytics availability for
Enterprise teams and administrator-managed keys; the
[Analytics documentation](https://cursor.com/docs/account/teams/analytics-api)
also states Enterprise-only availability. No documented individual-subscription
self-service usage endpoint was found in those references. This is a documentation
finding, not a claim about private endpoints or this owner's eligibility. An
eligible existing provider API remains preferable; this fix mints no key, changes
no provider acquisition order and performs no sign-in or live verification.

## Last-known folder (#2280)

A failed live read used to show `unknown` even when a good reading from an hour or a week
ago would answer the question. The reader now keeps each account's last usable reading in a
private folder and shows it, labelled, when the live read fails.

**Location.** `~/.claude/ai-quotas/last-known/`, or `AI_QUOTAS_LAST_KNOWN_DIR` when set. One
file per account: `<provider>--<label>.json`. The folder is `0700`, each file `0600`. A symlinked
or world-writable folder is refused with a warning, and the report still renders.

**What is stored.** Usage percentages, reset times, the source name and account labels. No
credential, cookie, token, user id or provider payload. Only `ok` rows with a finite
`used_pct` are saved, so a failed read never overwrites its file.

**Who writes it.** `.claude/scripts/lib/quotas-last-known.py` is the only code that touches the
folder. The reader calls it with `record` after each run; `/quotas-setup report` calls it with
`owner-report`. Locking, reread under the lock, `0600` temporary files, `fsync`, atomic replace
and refusal of older-than-saved records follow `quotas-codex-reset.py`. Test seam:
`AI_QUOTAS_LAST_KNOWN_BIN` replaces the helper, as `AI_QUOTAS_CHEAPEST_BIN` does.

**Schema.** `schema`, `provider`, `label`, `nickname`, `fetched_at_epoch`, `fetched_at_et`,
`source`, and `rows[]` with `window`, `pool`, `used_pct`, `resets_at_epoch`, `resets`, `overage`,
and optional row-level `source` and `fetched_at_epoch`. Missing row fields inherit the file's
values. A Cursor row without `pool` whose window is `cursor-models` or `other-models` is read as
that pool, so the stopgap files still read.

**Display.** A failed account gets one derived row per saved series. Its live `status`,
`detail` and `action` are copied, `used_pct` stays `null`, and the saved figure appears only in
the `last_known_*` fields and in the table's NOTE column: `100% (last known, Nov 12,
owner-reported); resets Nov 28`. When the saved reset has passed, the note reads
`expired: ...; reset ...`. A healthy account keeps `null` in every `last_known_*` field.
JSON fields: `last_known_used_pct`, `last_known_at_epoch`, `last_known_at_et`,
`last_known_source`, `last_known_resets_at_epoch`, `last_known_resets_et`,
`last_known_expired`.

**Readers stay live-only (#2330).** The Claude and Codex readers emit only what the live
read returned: an account-wide failure is one figureless `7-day` placeholder. They never
emit saved windows. `apply_last_known` in `ai-quotas.sh` alone attaches saved series, and it
runs after history, last-known recording, forecasting and notifications, so none of those
ever sees a cached figure. That placeholder is enough to show every saved window: a saved
`5-hour` series appears under it even without `--five-hour`.

**Placement.** Each saved series is placed once per account, in live-row order: on the first
unusable row whose window (Cursor: pool) is its own, else on the account's first unusable
row. A row's own series come before such orphans. An unusable row that receives no saved
series, a later row with a duplicate window included, is shown unchanged with its own status
and detail. Accounts with no saved series are not touched.

**Partial success is not enriched.** An account with any usable live row is not looked up,
so a failed sibling window (a figureless Codex `5-hour` next to a live weekly row) shows no
saved figure. The helper still keeps that series' saved reading. Showing it is a separate
follow-up.

**Owner readings.** `/quotas-setup report <label> <window> <used_pct> [<reset>] [<provider>]`
records one reading as `owner-reported`. Cursor pools are `cursor-models` and `other-models`.
The reset accepts `YYYY-MM-DD` (midnight Eastern), an ISO-8601 timestamp, or epoch seconds.
The next usable live `ok` read replaces that series. Series the live run did not read `ok` keep
their saved reading, so one failed window or pool never erases another's last good figure.

**Gates never read it.** `quota-reserve.sh --refresh` passes `--no-last-known`, so the reader
makes no helper call at all. `credit-budget.sh` never calls the reader. A static test asserts
that neither gate names the folder, its override, or the helper.

**Stopgap migration.** A hand-made `refresh.sh` and `LATEST.md` once kept this folder. Existing
files in the stopgap shape stay readable. `refresh.sh` does not honour the lock, and the daily
job now keeps the folder itself, so delete `refresh.sh` and any scheduler that runs it. The
reader does not maintain `LATEST.md`; the `/quotas` table supersedes it. `/quotas-setup doctor`
reports both leftovers and the folder mode, read-only.

## The FETCHED column (#2406)

The table has a **FETCHED** column after USED: when the figure on that row was read.
`now` means it was read live during this request. A figure read earlier shows its date as
`Mmm dd` in Eastern time with a zero-padded day (`Nov 16`, `Jan 01`); a figure saved
earlier today shows today's date, never `now`. A row with no figure shows `-`.

**The 120-second rule.** A figure read within 120 seconds before the run started counts as
fetched for this request and shows `now`, whatever produced it: a live read, a saved
status-line or app-usage reading, or a browser or text observation. The check is
`run time - fetched_at_epoch <= 120`, so a figure exactly 120 seconds old is `now` and one
121 seconds old shows its date. `fetched_at` keeps the **exact** instant the figure was
read (it is not rounded to the run time), so `--json` still says when. A last-known
reading restored after a failed live read never takes this rule: it is by definition not
a figure read for this request.

Every `--json` row carries three fields, stamped last (after saved figures are placed) by
`stamp_fetched_field` in `lib/ai-quotas-report.sh`:

| Field | Value |
|-------|-------|
| `fetched_at` | ISO-8601 UTC instant the figure was read; the run time for a live network read; the exact capture instant for a saved reading or observation; `null` with no figure, or when date operations are unavailable. |
| `fetched` | `live` (read within the 120-second rule or by a network read in this run), `saved`, or `null` (no figure). Never depends on the date helper. |
| `fetched_display` | What the table prints: `now`, `Mmm dd`, or `null`. With date operations unavailable a live read still says `now`; only a saved date degrades, to `null` (the blank marker), never to `now`. |

**Adding a source of saved figures.** A provider only has to set one field on its row: pass
`{"fetched_at_epoch": <epoch the figure was read>}` in the `emit_row` extra object. The
status-line reader does (the capture time of its saved file) and so do the browser
observations (the observation's own `observed_at_epoch`). The stamp then marks the row
`saved` and prints the date. The default is strict: a row with a figure and no
`fetched_at_epoch` counts as live only when its `source` is by construction a network read
made in this run (`oauth-usage`, `app-server`, `http`, `ide-token`); every other source,
including one added later, is left blank rather than claiming `now`. A reading whose
`fetched_at_epoch` is within 120 seconds of the run is `live` (the rule above); an older one
is `saved`. The Antigravity reader sets it to the saved observation's capture time, so its
rows show that date unless it was captured within 120 seconds; a stale row (no figure) shows
its last-known date. Last-known rows take `last_known_at_epoch`.

**Per-row read times.** `record_last_known` keeps each row's own `fetched_at_epoch` (the run
time only when a row has none), so a saved reading is never re-dated as new, and
`quotas-last-known.py` stores and returns that time per row. The file's account-level
`fetched_at_epoch` is the newest row time, and is the fallback for older files whose rows
carry none. Rows read at different times (a status-line weekly row beside a live five-hour
row) therefore each show their own date.

To keep the table inside its column budget the LEFT cell prints `resets` where
`days_left_note` says `resets first`; the `--json` value is unchanged.

## Paid usage, resets and top tier (Issues #2409, #2408, #2415)

Six columns say what the owner needs on contract work, where a client may not reimburse
paid usage. All are display only: they gate nothing, and an unknown is never turned into a
number or an icon.

| Column | `--json` field(s) | Meaning |
|--------|-------------------|---------|
| `$?` | `paid_enabled` | ✅ when the provider says paid usage can happen, ❌ when it says it cannot, `-` when unknown. It follows whether spending can actually happen, not whether a limit is set: Claude Work has a $1,000 limit set with usage credits off and shows ❌. |
| `$ CAP` | `paid_cap_usd`, `paid_cap_unlimited` | The limit on paid usage for the period: `$500`, `$50`; `none` when the provider said there is no limit; `off` whenever the provider said paid usage is off, even with a limit set (the limit stays in `--json` as `paid_cap_usd`, so a $1000 limit never reads as spendable money); `-` when unknown. A whole-dollar cap prints without cents. A non-USD currency leaves the amounts blank and adds a note to the row (`paid amounts are in EUR, not shown`); the `$?` flag is kept. A figure restored from last-known after a failed read is shown only while its window has not passed. |
| `$` | `paid_spent_usd` | Dollars of paid usage this period, always with cents (`$315.79`, `$0.00`). |
| `RST` | `limit_resets_available`, `limit_resets` | How many limit resets are available. `0` only when the provider said none are left; `-` when unknown **or** when the provider has no reset allowance. |
| `TOP` | `top_label` | The provider's own label for the top-tier model or pool that has a separate allowance (`Fable`, `Argon`). Taken from the data, never hard-coded; `-` when there is none or it is unknown. |
| `TOP%` | `top_used_pct`, `top_resets_at_epoch` | Percent of that allowance **used**, on the same basis as USED. |

`--json` also carries `paid_currency` (always `USD`: amounts in another currency are
dropped, because the fields are dollars), `paid_period` (`monthly`), and
`paid_read_at_epoch` (when the figures were read). Every row of every provider declares all
of these (null when unknown), so a consumer never tests for a missing key.

**The blank-versus-zero rule.** `❌`, `0` and `$0.00` appear only when the provider said so.
A reading that lacks the data leaves the fields `null` and the table prints `-`; nothing is
estimated locally. Missing or unreadable amounts are dropped, not zeroed: `"lots"`, a
negative number, or an amount in another currency becomes null while the on/off flag, if the
provider gave one, is kept. A paid-usage cap is `none` only when the provider said
unlimited, never because the cap was simply absent.

**One value per account.** The columns describe the account, so the table shows them on one
row only: the account's first row that carries any of them (or its first row when none
does), and `-` on the rest, so a Cursor account's two pools or an Antigravity account's five
groups are never double-counted by eye. `--json` repeats the values on every row of the
account and says which row the table uses with `account_primary` (true or false on every
row).

**Where each provider's value comes from.**

| Provider | Source | Notes |
|----------|--------|-------|
| Claude, app usage tool file (`claude-app--<label>.json`) | `extra_usage` (`enabled`, `spent`, `monthly_limit`, `currency`), `weekly_models` (`Weekly · Fable`: the label after the `Weekly · ` prefix is `top`; with several windows the first), `limit_resets` | `enabled` is saved as true, false, or null when the tool omitted it. |
| Claude, status-line file (`claude--<label>.json`) | `rate_limits.spend_limit` and any `rate_limits.seven_day_<model>` window | **Unverified shape.** No live sample of `spend_limit` has been seen, so only an explicit boolean `enabled`/`is_enabled` and amounts under a `*_usd` key are read (a bare number could be cents); a per-model window is named from its key. A reading without them leaves the columns blank. |
| Claude, claude.ai usage-page observation (`--browser-results`) | optional `extra_usage` (`enabled`, `spent_usd`, `monthly_limit_usd`), `limit_resets`, `top_model` (`label`, `used_pct`, `resets_at_epoch`) | Validated; a malformed block rejects the observation, an absent block means not reported. |
| Codex | `limit_resets_available` from `free_resets_remaining` (the reset-credit count) | The payload reports credits in unlabelled units and no spend or cap, so `$?`, `$ CAP`, `$` stay blank rather than invent dollars. |
| Cursor | `spend_limit_used_usd`, `spend_limit_usd`, `spend_limit_unlimited` (the on-demand block) | ✅ when the limit is above 0 or unlimited, ❌ when it is 0, unknown with no limit figure. `RST` and `TOP` stay blank: Cursor has no reset allowance (its [pricing page](https://cursor.com/docs/account/pricing), the one the overage table cites, describes only pay-as-you-go on-demand usage) and no separate top-tier pool is known. |
| Antigravity | the group the `/usage` panel prints with no "Models within this group" line (a single named model with its own allowance) | `TOP` is the last word of the group name as printed (`Gemini 4 Argon` shows as `Argon`), `TOP%` is 100 minus the remaining percent the panel prints. No reset allowance is documented (see [ai-quotas-antigravity.md](./ai-quotas-antigravity.md)), so `RST` is blank. A stale capture shows none. |

**Claude limit resets.** The usage page shows "Limit resets: N available" with a kind and
an expiry for each; no saved reading carries it (the status-line input and the usage tool
do not). An agent that reads the page supplies it as an optional `limit_resets` object next
to the tool result passed to `claude-usage-observe.sh`
(`{"count": 1, "items": [{"kind": "Weekly reset", "expires_at": "2027-03-09T00:00:00Z"}]}`;
a bare list of items also works, `items` may be omitted), or as `limit_resets` in a
claude.ai page observation (`expires_at_epoch`). It is validated (a count of 0 to 1000,
items matching the count, a plain kind, a UTC ISO-8601 expiry); a malformed block refuses the
observation with the reason, and writes nothing. Without it the Claude `RST` cell is `-`,
never `0`.

**Saved figures keep the columns.** `record_last_known` saves each row's account-level
fields beside the series (`account` in the last-known file, type-checked on read), and a
saved figure restored after a failed live read brings them back with the row's own read time
(`paid_read_at_epoch` stays the time they were read, not the time of this run).

**Why the table changed shape.** Fitting the extra columns in 140 columns meant: cells one
space apart; the two icons counted as two columns (so the table is laid out by the reader,
not `column -t`); the Antigravity composite window shortened (`gemini-4-argon 7d`); `AM`/`PM`
joined to the time (`Thu 8:00PM`); the resets-count header `RST` and the top-percent header
`TOP%`; and any note over 11 characters or overage label over 12 printed as a numbered
footnote under the table (`[1]` in the row, `[1] text` below, identical texts sharing one
number). The footnotes are part of the table, so `--quiet` keeps them and drops only the
advisory sections. Every cell has control characters replaced by spaces, so a hostile label
cannot forge a row. The time column's header is now `RESET (ET)`.

**Needs a live check.** The columns are built from readings recorded on 2026-11-16; compare
each against the provider's own page once in a live session: Claude Personal (✅ $500
$315.79, Fable), Claude Work (❌ off $0.00, 2 resets), Cursor (✅ $50 $6.33), Antigravity
(Argon), Codex (0 resets).

## Antigravity (Issue #2407)

`antigravity` is a fourth provider: one registered account, rows read from Google's quota service with the sign-in `agy` holds (source `backend`, Issue #2465), then (attended runs only, Issue #2466) interactive `agy` in a visible terminal (source `terminal`), then the saved text of the `agy` `/usage` panel, through an observation file (`~/.claude/ai-quotas-antigravity.json`), one row per model group and window, display only (never read by `quota-reserve.sh`). Limits, sample, parser, stale rule and the one unverified live step: [ai-quotas-antigravity.md](./ai-quotas-antigravity.md).

## Plan tier and monthly price (TIER, $/MO) — Issue #2469

The table's `TIER` and `$/MO` columns, and the `--json` fields `plan_tier`, `plan_tier_source`
(`provider` | `override`), `plan_usd_month` and `plan_price_source` (`list` | `override`), are
built by `derive_plan_fields` in `lib/ai-quotas-report.sh` from three inputs:

1. **The plan the provider reports.** Each reader puts it in the row's existing `plan` field:
   Claude takes `subscription_type` from the saved status-line or app reading, else
   `subscriptionType` (refined by a `5x`/`20x` suffix of `rateLimitTier`, giving `max_20x`) from
   the stored login (`claude_detect_plan`, in memory, no credential value kept); Codex takes
   `planType`; Cursor takes `planName` from `get-plan-info`; Antigravity takes the `paidTier` or
   `currentTier` name (else id) from the `loadCodeAssist` response of the backend read, saved
   beside the observation as `plan`. A reader that is told nothing leaves it null: nothing is guessed.
2. **The price list** `.claude/reference/quotas-plan-prices.json` (override with
   `AI_QUOTAS_PRICE_LIST`): provider, then tier, with `usd_per_month`, `match` keys (lowercase,
   non-alphanumerics collapsed to `_`), a source URL and a `last_checked` date. A tier is left
   off when its price could not be verified; a reported tier the list lacks keeps its own name
   and shows `-` for the price, never `$0`. Re-check the URLs and bump `last_checked` when prices move.
3. **A manual override**, `plan_override: {tier, usd_per_month?}` on the account entry in the
   registry, written by `ai-quotas-setup.sh plan <label> <tier> [<usd_per_month>] [<provider>]`
   (an empty tier deletes it). It beats the reported tier; its price beats the list, and a
   tier-only override is priced from the list when the list knows that tier. The table marks an
   overridden cell with `*` and prints one line under it saying so. This stored shape is the one a
   future export carries.

Both columns show once per account, on its primary row. Display only: nothing gates work on
them and `quota-reserve.sh` never reads them. To fit 140 columns, WINDOW is capped at 13, OVERAGE
labels over 8 characters are footnoted, and an `IN` of ten or more days shows days only.
