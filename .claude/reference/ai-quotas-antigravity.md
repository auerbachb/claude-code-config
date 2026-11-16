# Google Antigravity — quota research (Issue #2407)

Research date: 2026-11-16. Not auto-loaded. Part of the quota-tracking reference set
(`ai-quotas.md`). **Outcome: the interactive `/usage` panel in `agy` prints parseable text**
(percent remaining per group, relative reset times, and "Quota available" when full). No
`antigravity` provider is built yet. The remaining work for Issue #2407 is a parser for that
text plus a capture route. What was and was not verified is below so the next attempt does
not repeat it.

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
parseable text (sample above). Reading the backend directly would mean borrowing the OAuth
token the product holds for the signed-in Google user and calling an undocumented endpoint;
that is neither documented nor verified, so it is not done.

Remaining work for Issue #2407:

1. **A parser** for the `/usage` text, with the sample above as the fixture. It must
   convert percent remaining to percent used, parse "Refreshes in Nh Mm", map "Quota
   available" to a full window with no countdown, and keep the three groups distinct.
2. **A capture route.** Either drive `agy` then `/usage` in a terminal, or accept the pasted
   panel text as an observation. The existing observation-file shape that `ai-quotas.sh
   --browser-results` uses (`.claude/scripts/lib/quotas-browser.py`) allows at most two rows
   per account, one per window name, and has no model-group field, so it needs a group
   identifier and a larger row limit before it can hold this sample.

Design constraints for whichever lands: display-only (never feed `quota-reserve.sh`);
no credential printed, logged, or stored; the `unreadable` row must name "open View Usage in
Antigravity" as the action.
