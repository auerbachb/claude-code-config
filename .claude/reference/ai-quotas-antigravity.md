# Google Antigravity — quota research (Issues #2407, #2465, #2466)

Research date: 2026-11-16; reader built the same day (Issue #2407). Not auto-loaded. Part of
the quota-tracking reference set (`ai-quotas.md`). **Outcome: the interactive `/usage` panel
in `agy` prints parseable text** (percent remaining per group, relative reset times, and
"Quota available" when full), and `/quotas` now has an `antigravity` provider that parses it.
The panel is not a "no machine-readable source" case: no JSON or file exists, but the text is
stable enough to parse. What was and was not verified is below.

## How the limits work (documented, vendor sources)

| Fact | Source |
|------|--------|
| Two windows apply: a **five-hour** limit and a **weekly** limit. Models in a group share both. Groups shown: Gemini (Flash, Pro) and the Claude and GPT models Antigravity offers. | [Antigravity CLI `/usage` docs](https://antigravity.google/docs/cli/commands/usage/) |
| Google AI Ultra: largest quota, refreshed every five hours, highest weekly limit. Google AI Pro: high quota refreshed every five hours until the weekly limit is hit. Other plans (free, AI Plus): a smaller quota refreshed **weekly** only. | [Antigravity plans](https://antigravity.google/docs/plans) |
| No numeric token or prompt caps are published; usage is a percentage of an undisclosed allowance. Limits "depend on capacity" and may change. | plans page; corroborated by third-party write-ups |
| Unused quota does not roll over. | third-party write-ups (not vendor-stated) |
| Pro and Ultra can spend purchased or promotional **AI credits** past the quota. The "AI Credit Overages" setting is `Never` (wait for refresh) or `Always` (use credits). Credits are billed at Gemini Enterprise consumption pricing. | plans page |
| No manual quota reset or "reset allowance" is described anywhere; extra capacity is bought as credits. Bring-your-own-key is not supported. | plans page |
| Billing rides on Google AI plans; there is no Antigravity-only subscription. | third-party write-ups |

Third-party sites disagree on some windows (one claims free is five-hourly). The vendor
plans page above is treated as authoritative and the rest as unverified.

## Where the figure can be read

- **IDE:** model selector under the prompt box, then `View Usage`; Settings also shows
  baseline usage across models (vendor plans page and third-party guides).
- **CLI (`agy`):** the interactive slash command `/usage` (alias `/quota`) opens a
  "Models & Quota" panel and refreshes from the backend first. The vendor docs describe no
  file or non-interactive output. **Owner-reported 2026-11-16, not captured by an agent:**
  the panel prints text with three groups. Each figure is percent **remaining** (the
  `/quotas` row shows percent used, so convert), resets are relative "Refreshes in Nh Mm",
  and a full window reads "Quota available" with no countdown.

Recorded sample from the owner's account (email redacted as `<email>`; the source is the
owner's comment on Issue #2407, 2026-11-16):

```text
  Account: <email>

GEMINI MODELS
  Models within this group: Gemini 4 Hydrogen, Gemini 3.8 Flash

  Weekly Limit Remaining
    [████████████████████████████████████░░░░░░░░░░░░░░] 71.68%
    Refreshes in 153h 32m

  Five Hour Limit Remaining
    [██████████████████████████████████████████████████] 100.00%
    Quota available

CLAUDE AND GPT MODELS
  Models within this group: Claude Opus 5.5, Claude Sonnet 5.5, GPT-OSS 120B

  Weekly Limit Remaining
    [██████████████████████████████████████████████████] 100.00%
    Quota available

  Five Hour Limit Remaining
    [██████████████████████████████████████████████████] 100.00%
    Quota available

GEMINI 4 ARGON
  For paid Pro plans, Argon quota is separate. Higher Argon quota (included as part of the larger Gemini quota bucket) is available on Ultra plans.

  Gemini 4 Argon Weekly Limit
    [████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░] 24.95%
    Refreshes in 153h 28m
```

The three groups are: Gemini models (weekly and five-hour windows), Claude and GPT models
(weekly and five-hour windows), and Gemini 4 Argon (weekly only, a separate top-tier
allowance on paid Pro plans).

## What was verified on this Mac (read-only; nothing signed in, no endpoint called)

- Installed: `/Applications/Antigravity.app`, `/Applications/Antigravity IDE.app`, and
  the CLI at `/opt/homebrew/bin/agy` (Homebrew cask `antigravity-cli`, version 1.5.9).
- `agy --help` lists no usage, quota or JSON-status subcommand. Subcommands are
  `acp agent agents changelog help install mcp mic-serve models plugin plugins
  remote-control update`. Print mode (`-p`) with `--output-format json|stream-json`
  exists for prompts, not for a usage report. Whether `agy -p "/usage"` returns the panel
  was **not** tried: it would call the signed-in backend, which this phase forbids.
- Data folders exist: `~/.gemini/` (`antigravity`, `antigravity-cli`, `antigravity-ide`,
  `config`, plus a standalone OAuth token file) and `~/.antigravity/` (extensions only),
  and `~/Library/Application Support/Antigravity/` (an Electron profile). Only names and
  sizes were listed. No file or key named for quota or usage exists outside a browser
  profile's generic `QuotaManager` (disk storage, unrelated).
- The CLI log (`~/.gemini/antigravity-cli/log/cli-*.log`) shows a `quota_manager` task
  that logs only `doRefreshQuota: starting reload` or `skipped (throttled)`. Neither the
  percentages nor the reset times are written to the log.
- The OAuth token file and the Electron cookie store were not opened.

## Conclusion and what would change it

The figure is readable from the interactive `/usage` panel in `agy`, and that panel prints
parseable text (sample above). Reading the backend directly means using the OAuth
token the product holds for the signed-in Google user and calling an undocumented endpoint;
the owner approved that on 2026-11-18 and it is now the first source (see "Backend source").

## What the reader does (built)

- **Parser** (`.claude/scripts/lib/quotas-antigravity.py`): reads the panel text with the sample
  above as its fixture (`tests/fixtures/antigravity-usage-panel.txt`). It converts percent
  remaining to percent used (one decimal), turns "Refreshes in 153h 32m" into an absolute
  epoch computed from the capture time, reads "Quota available" as a full window with no
  reset, keeps the account line, and keeps groups it has not seen before. It ignores bar
  characters, ANSI colour and blank lines, copes with a missing group, and returns
  `unreadable` (never 0%) when no window can be read or a percent is out of range.
- **Observation file** (`~/.claude/ai-quotas-antigravity.json`, mode 0600, or the path in
  `AI_QUOTAS_ANTIGRAVITY_OBSERVATION`): `{schema:"antigravity-usage/1", provider, captured_at_epoch,
  via, text}`. It is a new shape rather than the browser-observation one, because that shape
  (`quotas-browser.py`) allows at most two rows per account and has no group field. The text
  is parsed at read time so a parser fix applies to old captures. It holds the account line as
  printed (the owner's own file, never committed); fixtures and docs use `<email>`.
- **Provider** (`.claude/scripts/lib/ai-quotas-antigravity.sh`): one row per group and window,
  window label `<group> <window>` (`gemini 7-day`, `gemini 5-hour`, `claude-gpt 7-day`,
  `claude-gpt 5-hour`, `gemini-4-argon 7-day`), `source` `observation`, the detail naming
  where the text came from (`pasted /usage text` or `agy -p /usage`) and its age, plus
  `group` and `group_models` fields. Registered by `/quotas-setup add antigravity <label>`
  (one account per machine; checks only that `agy` is installed; "account not verified").
- **Stale and missing**: an observation older than 3 hours (`AI_QUOTAS_ANTIGRAVITY_STALE_SECONDS`),
  or a window whose computed reset has passed, is shown `unreadable` with its age and the last
  known figure; no figure is invented. With no saved text the row says so and names the capture
  command. The forecast columns (START, %/DAY, LEFT) stay blank: no history-based forecast applies.
- **Display only:** `quota-reserve.sh` keeps only Claude and Codex rows, so Antigravity never
  feeds the weekly reserve gate. Last-known staging and the history-based forecast do not apply
  (the observation file is its own last-known); the outcomes ledger records it.
- **Capture** (`.claude/scripts/quotas-antigravity-capture.sh`): `--from-file FILE` or `--stdin`
  save pasted text (manual route: run `agy`, type `/usage`, copy the panel, `pbpaste |
  quotas-antigravity-capture.sh --stdin`). `--live` runs `agy -p "/usage"` with stdin closed
  and a 90 s limit, keeps stdout only, and saves nothing unless a usage panel parses.

## Backend source (Issue #2465, researched 2026-11-18)

The `/usage` panel is not reachable from print mode: `agy -p "/usage"` prints no panel (owner
live check 2026-11-18, exit 0). The CLI's own `quota_manager` task reads the same figures from
Google's backend, so `/quotas` now does too. Everything below was found read-only: the CLI log
(`~/.gemini/antigravity-cli/log/cli-*.log`), the strings of the `agy` binary (protobuf
descriptors), and one live call per endpoint with the product's own token (owner approval in chat,
2026-11-18). The token was used in memory only; no value was printed, logged, saved or committed.

| Fact | Finding |
|------|---------|
| Endpoint | `POST https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` (the log shows `quota_manager` calling it; the log line names only the URL, never a figure). Undocumented, internal: it can change without notice. |
| Where the token lives | The macOS login keychain, generic password, service `gemini`, account `antigravity` (log line `keyringAuth: loaded token`). Value: `go-keyring-base64:` + base64 of JSON `{"token":{"access_token","token_type","refresh_token","expiry","expires_in"},"auth_method","id_token_email","writer_id"}`. Other platforms are not supported by the reader (`token_unsupported`). |
| Auth shape | `Authorization: Bearer <access_token>`, `Content-Type: application/json`. |
| Token lifetime | About one hour (`expires_in` 3599). `agy` refreshes it when it runs (log: `token refreshed, new expiry=…`); the refresh needs the app's own OAuth client, so the reader does not refresh: an expired token is `unreadable` ("run agy and sign in") and the next `agy` start renews it. |
| Project | Request body `{"project": "<id>"}` (required). The id comes from `POST …/v1internal:loadCodeAssist` with `{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}`, field `cloudaicompanionProject` (observed: `aicode-consumers`). A call with no project is a 403 `SUBSCRIPTION_REQUIRED`, which is why the project step exists. |
| Request fields | `RetrieveUserQuotaSummaryRequest` has one field, `project` (descriptor in the binary). `metadata` is rejected (400). |
| Response shape | `{"groups":[{"displayName","description","buckets":[{"bucketId","displayName","window","resetTime","remainingFraction", optional "remainingAmount","disabled"}]}], "buckets":[…ungrouped…], "description"}`. `displayName` of a group is e.g. `Claude and GPT models`; its `description` is `Models within this group: …`. A bucket's `displayName` is the panel's window title (`Weekly Limit Remaining`); `window` is `weekly` (other values map through the same window-name rules); `resetTime` is RFC 3339 UTC; `remainingFraction` is 0–1. Observed on a free-tier account: one group (Claude and GPT models) with one weekly bucket. |
| Errors seen | 403 `PERMISSION_DENIED` / `SUBSCRIPTION_REQUIRED` for a missing project. 400 for an unknown field. |

What stays unknown: the exact `window` value strings for the five-hour bucket (the reader falls
back to the bucket `displayName`, then to the `window` text, and keeps an unseen name as is);
whether a bucket with `remainingFraction` 0 is serialised with the field present (proto3 JSON
omits zero, so the reader treats a bucket without it as `unreadable` rather than as an exhausted
window — never an invented figure); how the service answers for Pro and Ultra accounts (only a
free-tier account was available). These are checked on the next real reading and recorded here.

**Reader:** `lib/quotas-antigravity.py backend <epoch> <observation-file>` does the two requests
and saves `{schema, provider, captured_at_epoch, via:"backend", response}` (0600, atomically; no
token, no email). `show` parses the saved response with the same group/window rules as the panel
text, so rows are identical in shape: `gemini 7-day`, `claude-gpt 5-hour`, and so on, percent
used, reset epoch. `lib/ai-quotas-antigravity.sh` adds the `backend` source: default order
`backend,terminal,observation` (Issue #2466); `/quotas` fetches when the saved reading is missing or older than
`AI_QUOTAS_ANTIGRAVITY_REFRESH_SECONDS` (default 300, so repeated runs do not hit Google each
time; the stale bound stays 3 h for the display), and the row detail says `from Google backend`
or `from pasted /usage text`. Failures (`token_missing`, `token_expired`, `http_401/403/429`,
`network`, `response_shape`) give an `unreadable` row naming the reason and the next step; with a
saved reading behind it, the observation row shows its own stale state plus the backend reason.
Only a loopback `AI_QUOTAS_ANTIGRAVITY_BACKEND_URL` is honoured (tests), so the token cannot be
sent to another host; `AI_QUOTAS_ANTIGRAVITY_TOKEN_FILE` replaces the keychain read in tests.
Antigravity stays display-only: `quota-reserve.sh` never sees it.

## Terminal source (Issue #2466)

The backend read fails whenever `agy`'s ~1 h login has expired. Print mode cannot help
(`agy -p "/usage"` prints no panel), and an agent cannot click through a login, so the next
source is the interactive panel read in a terminal **a person can see**. Default order is now
`backend,terminal,observation`; `terminal` is a valid name for `ai-quotas-setup.sh sources`.

**What runs.** `lib/quotas-antigravity.py terminal <agy> <epoch> <observation-file>` starts `agy`
with no arguments on a pseudo-terminal, copies everything `agy` prints to the visible terminal,
copies the person's keystrokes to `agy`, types `/usage` and Enter once `agy` has been quiet for
2.5 s and its latest output does not ask for a sign-in, and saves the panel text it prints with
source `terminal` (same observation file and parser as the pasted route; rows read `source
terminal`, detail `from agy terminal /usage`). It stops `agy` afterwards (Ctrl-C, then SIGTERM).
The tab is the person's own terminal, never a hidden PTY and never a new window or pane.

**Which terminal (host design).** A shell script cannot call the desktop app's MCP tools, and a
script cannot open a new tab in an arbitrary terminal either, so the design is "the terminal
this process already has":

| Host | How it works |
|------|--------------|
| Plain terminal (the person runs `ai-quotas.sh` or `/quotas` helpers themselves) | The controlling terminal (`/dev/tty`) is the visible tab. The reader uses it only when its own stdin is a terminal. |
| Claude desktop app (agent runs `/quotas`) | The agent's Bash tool has no terminal on stdin, so the source answers `terminal_unavailable` at once and the row names the command. The agent then runs `quotas-antigravity-capture.sh --terminal` in the **Terminal panel** with `mcp__terminal__run_in_terminal` (the panel is a real TTY the person watches and types into), waits for `saved:` (read the panel with `read_terminal`), and re-runs `/quotas`, which now has a fresh `terminal` reading. |
| Cloud sessions, SSH without a tty, cron, CI, the scheduled snapshot | Cannot work: there is no terminal a person is looking at. The source refuses (attended runs: `terminal_unavailable`; scheduled runs: skipped before any attempt). The paste route stays. |

`AI_QUOTAS_TERMINAL=off` skips the source on any run. `AI_QUOTAS_TERMINAL_TIMEOUT` (seconds,
default 300, 5 to 1800) bounds the whole read, sign-in included. Tests aim the reader at a
pseudo-terminal with `AI_QUOTAS_TERMINAL_DEVICE` (ignored in normal use).

**Sign-in.** If the latest burst of `agy` output matches a narrow sign-in pattern (for example
"must sign in", "not signed in", "accounts.google.com"), the terminal shows "sign in to Antigravity
in this terminal, then wait: the read finishes by itself. Nothing here signs in for you." and the
tool types nothing. The person signs in at that prompt (typing goes straight to `agy`). Once the
prompt is gone, `agy` has been quiet for 2.5 s and the person has not typed for 5 s, `/usage` is
typed. Nothing automates the login, and `/usage` is never typed into a sign-in prompt. No sign-in before
the timeout: `unreadable`, reason `no sign-in to Antigravity within Ns`, and the next step
`pbpaste | quotas-antigravity-capture.sh --stdin`; nothing is saved. Other failures:
`agy_exited`, `terminal_timeout` (no panel parsed, or `agy`/the terminal stopped accepting input), `panel_garbled`,
`agy_missing`, `terminal_unavailable`. A stalled write never outlives the timeout, and SIGTERM/SIGHUP unwind
through the cleanup that restores the terminal.

**Unattended.** A scheduled snapshot (`--quiet`, `AI_QUOTAS_SOURCE=scheduled`) never reaches the
source: the chain skips it (`skip_reason: terminal-unattended`) before `agy` can start, the next
source's rows carry "terminal read skipped: no terminal is opened on an unattended run", and the
outcomes ledger records the backend failure.

**After a terminal read.** Running `agy` refreshes the keychain token, so a backend read
straight afterwards would probably succeed. Decision: the figures just read are the rows; the
run does not call Google again. The next `/quotas` run tries `backend` first (the saved terminal
reading is not "fresh" for the 5 minute reuse rule, which only covers backend readings), which
will usually succeed on the renewed token and replace the terminal reading with a backend one.

**Credentials.** The tool never reads, prints, stores or logs a credential. The session's
output goes to the visible terminal only; the one thing saved is the panel text, and only when
it parses as a usage panel (the account line as printed, like the pasted route). Failure reasons
are fixed strings. Antigravity stays display-only (`quota-reserve.sh` never sees it).

**Unverified live (needs the owner's first run).** Tests drive a stub `agy`. Not yet confirmed
against the real TUI: that `/usage` + Enter opens the panel without a slash-command menu
selecting first, that the repainted panel is parseable from the raw stream (a TUI that redraws
in place could duplicate or garble lines; a panel whose windows repeat is refused as `panel_garbled` and the
row says so), what the
real sign-in prompt says (if it avoids the sign-in pattern the tool types `/usage` into it
once per 20 s, at most four times, harmlessly), that Ctrl-C ends `agy` (SIGTERM follows), and that
`agy` starts in the home directory without a folder-trust prompt. Check: run
`quotas-antigravity-capture.sh --terminal` in a terminal with `agy` signed in, then signed out.

## Needs a live check

`agy -p "/usage"` is known to print no panel (see above), so `quotas-antigravity-capture.sh --live`
is not a validation route; the manual paste (`pbpaste | quotas-antigravity-capture.sh --stdin`)
is the panel-capture fallback. To validate the backend reader, the owner runs `/quotas` once with
a signed-in `agy` and checks that the Antigravity rows say `from Google backend`; with no sign-in
the row must be `unreadable` with the next step, unless a saved reading exists: a backend reading younger than 5 minutes is shown without a fetch, and any
saved reading under 3 hours old is shown as the fallback with the backend failure reason appended, so
neither proves the no-sign-in path. Remove the saved reading (the Antigravity observation file) before
the no-sign-in check. The live request has not been run in tests
(it contacts Google); the tests use a loopback stub.

Design constraints kept: display-only; no credential read, printed, logged or stored; the
`unreadable` row names the capture command to run.
