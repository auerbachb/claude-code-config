# Google Antigravity — quota research (Issues #2407, #2465)

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
`backend,observation`; `/quotas` fetches when the saved reading is missing or older than
`AI_QUOTAS_ANTIGRAVITY_REFRESH_SECONDS` (default 300, so repeated runs do not hit Google each
time; the stale bound stays 3 h for the display), and the row detail says `from Google backend`
or `from pasted /usage text`. Failures (`token_missing`, `token_expired`, `http_401/403/429`,
`network`, `response_shape`) give an `unreadable` row naming the reason and the next step; with a
saved reading behind it, the observation row shows its own stale state plus the backend reason.
Only a loopback `AI_QUOTAS_ANTIGRAVITY_BACKEND_URL` is honoured (tests), so the token cannot be
sent to another host; `AI_QUOTAS_ANTIGRAVITY_TOKEN_FILE` replaces the keychain read in tests.
Antigravity stays display-only: `quota-reserve.sh` never sees it.

## Needs a live check

`agy --help` (v1.5.9) shows print mode (`-p`, `--output-format`) and `--disable-slash-commands`,
which suggests slash commands may expand in print mode, but nothing confirms `agy -p "/usage"`
prints the panel instead of sending "/usage" to a model. It was not run (it contacts the
signed-in backend). Until the owner runs `quotas-antigravity-capture.sh --live` once and sees
`saved: 5 windows in 3 groups`, treat `--live` as unverified and use the manual route.

Design constraints kept: display-only; no credential read, printed, logged or stored; the
`unreadable` row names the capture command to run.
