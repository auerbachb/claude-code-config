# Budget Source Probe — Authoritative Usage Signal Discovery

> **Distinct wallet:** This document governs **Anthropic credit spend** only.
> Third-party reviewer-tool costs (Greptile, CodeAnt, BugBot) are tracked
> separately in `pricing-matrix.md` and `spend-telemetry-pipeline.md`. The two
> knobs and docs must never be confused in an audit.

## Background

Issue #1289 requires a daily credit budget (`daily_credit_budget_usd = 25`,
ET calendar day) that autonomous dispatch respects. The budget must be evaluated
**only against authoritative signals** — never against a local token/dollar
estimate. This document records what authoritative signals are actually reachable
from a session, in the order they are probed, and defines the degradation
contract when none are reachable.

Cross-references: `usage-limit-signal-audit-2026-07.md` (full probe that found
no pre-emptive signal), `issue-852-browser-rung-verification.md` (browser MCP
read path), `safety.md` §"Anthropic Quota & Spend Authority".

---

## Probe Order

### Probe 1 — Harness overage/limit signal (automatic, binary, post-hoc)

**Files:** `~/.claude/usage-limit-last.json` (latest event) and
`~/.claude/usage-limit-events.jsonl` (full event log)

**Written by:** `.claude/hooks/usage-limit-record.sh` on every
`StopFailure error == "rate_limit"` event.

**What it tells you:** A turn ended because the account hit its usage limit.
The record carries `recorded_at` (ISO timestamp) and `reason: "rate_limit"`.
It does **not** carry a dollar amount — it is a binary post-hoc signal.

**How credit-budget.sh uses it:** Read `~/.claude/usage-limit-events.jsonl`
and filter for events where `recorded_at` falls within the current ET calendar
day (keyed as `TZ='America/New_York' date +'%Y-%m-%d'`). If any such event
exists, the day's remaining budget is treated as **unknown-spent** and the
script returns `reached`.

**Limitations:** Post-hoc only — the signal arrives after the limit is hit, not
before. No dollar amount is available. The hook may not fire if the session was
killed before the hook could write.

### Probe 2 — Anthropic usage surface via browser MCP (manual / non-automatic)

**URL:** `https://console.anthropic.com/settings/limits` (or equivalent billing
page)

**How:** `mcp__Claude_Browser__*` tools navigate to the Console and read the
usage display. `issue-852-browser-rung-verification.md` documents that this
path was verified to work as a browser MCP task.

**Automation status:** **Non-automatic.** Driving a browser requires an
interactive session; it is not suitable for autonomous dispatch gating. This
probe is available for a human or an agent acting on explicit instruction, not
as a background budget check during day-mode ticks.

**What it tells you:** The Anthropic Console shows credit balance and usage
figures. These are authoritative but require navigation and are not machine-
readable without DOM scraping.

### Probe 3 — CLI or API path

**Finding:** **No path exists.** There is no `claude` CLI subcommand, no
`/usage`-style surface, and no Admin/Billing API accessible from a session that
returns pre-emptive credit usage or balance figures. Full evidence:
`usage-limit-signal-audit-2026-07.md`. This probe is documented as absent so
future implementers do not re-investigate from scratch.

---

## Degradation Contract

The automatic evaluation path relies solely on Probe 1 (the harness signal).
Because only a binary post-hoc signal is reachable automatically, the budget
degrades as follows:

| Signal state | `credit-budget.sh` exits | Dispatch posture |
|---|---|---|
| No `rate_limit` event this ET day | `0` (`ok`) | Dispatch proceeds normally |
| A `rate_limit` event recorded this ET day | `1` (`reached`) | Land near-done work; park until next ET day |
| Probe 1 unreadable (file missing, corrupt, unwritable) | `2` (`unknown`) | Conservative: finish in-flight, start nothing new |

**Unreadable state is never permission.** An unreadable signal is treated as
`unknown`, which uses the conservative posture. The probe never falls back to a
local token/dollar estimate. If no authoritative source is reachable, the system
says so and starts nothing new — it does not invent a number and proceed.

**The $25 knob's role:** `daily_credit_budget_usd = 25` in `pm-config.md` is
the owner's stated daily overage tolerance — a declared preference, not a
computed or enforced dollar limit. It is stored as a user-visible, user-editable
value so the intent is documented and so a future authoritative dollar source
(should one become reachable) can compare against it directly. Under the current
automatic probe path the knob does not drive a numeric comparison against spend;
it signals intent. When the authoritative probe returns `reached` (an overage
event was found), the system treats the day's budget as spent and parks —
consistent with the owner's stated tolerance — but no dollar arithmetic is
performed.

---

## Hard Rule

**Local token/cost estimation is never used as a fallback source.** This is
enforced in `credit-budget.sh`'s probe logic: the script reads only the harness
signal files and never computes or consults a token count, a token-to-dollar
conversion, or any locally-derived spend figure. The rule from `safety.md`
§"Anthropic Quota & Spend Authority" is satisfied architecturally, not only
by prose.

---

## Weekly-cap interplay

Issue #1288 parks day mode on weekly limits (no auto-overage). This budget ($25
/day) captures the owner's stated tolerance for daily overage spending. The two
compose: a weekly limit says "window closed", the $25 knob says "how much daily
overage the owner considers acceptable" — a reference value for a future
authoritative dollar source, not an automatic authorization the current probe
can enforce. When both the weekly limit and a `rate_limit` event appear in the
same day's session, the weekly-cap parking wins (its lock is explicit) and the
budget gate does not override it.
