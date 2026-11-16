# Google Antigravity — quota research (Issue #2407)

Research date: 2026-11-16. Not auto-loaded. Part of the quota-tracking reference set
(`ai-quotas.md`). **Outcome: no verified machine-readable usage source exists, so no
`antigravity` provider is built yet.** What was and was not verified is below so the next
attempt does not repeat it.

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
  "Models & Quota" panel and refreshes from the backend first. The docs do not say
  whether values are percentages or counts, give no reset timestamps, and describe no
  file or non-interactive output.

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

Readable only through the interactive in-app panel (or, unverified, an interactive CLI
panel). Reading the backend directly would mean borrowing the OAuth token the product
holds for the signed-in Google user and calling an undocumented endpoint; that is
neither documented nor verified, so it is not done.

Options for a follow-up, cheapest first:

1. **Agent-taken observation.** With the owner present, drive `View Usage` in the IDE (or
   `/usage` in `agy`) once, record the real percentages and reset times, and add them as
   a recorded sample. A provider can then reuse the private observation-file shape that
   `ai-quotas.sh --browser-results` uses for Cursor and Claude (`lib/quotas-browser.py`),
   with windows `5-hour` and `weekly`. This needs a live, signed-in session.
2. Ask Google for a documented usage endpoint or a machine-readable `agy` command.

Design constraints for whichever lands: display-only (never feed `quota-reserve.sh`);
no credential printed, logged, or stored; resets-left blank, since no reset allowance is
documented; the `unreadable` row must name "open View Usage in Antigravity" as the action.
