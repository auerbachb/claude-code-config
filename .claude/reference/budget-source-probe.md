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

**Scope note (2026-08-27, issue #1427).** This document has since grown a
second axis. Probe 0 below covers **window quota runway** in tokens, read from
the harness-injected in-context counter — a different wallet from the credit
spend the rest of the file governs, evaluated by a different script
(`usage-horizon.sh`, not `credit-budget.sh`), and never mixed with it.

Cross-references: `usage-limit-signal-audit-2026-07.md` (the July probe that
found no pre-emptive signal — see its 2026-08-27 addendum, which records that a
pre-emptive signal has since appeared via in-context injection),
`issue-852-browser-rung-verification.md` (browser MCP read path), `safety.md`
§"Anthropic Quota & Spend Authority".

---

## Probe Order

### Probe 0 — In-context remaining-token counter (pre-emptive)

**Files:** `~/.claude/usage-horizon.jsonl` (append-only observation log, mode
600) and `~/.claude/session-state.json` `.usage_horizon` (last reading + last
stable verdict).

**Written by:** `.claude/scripts/usage-horizon.sh --observe <remaining>
[--limit <total>]`, called by the model with the figure the **harness** printed
into its own context. Nothing writes here automatically — there is no hook that
can see this number (see the audit's §2), so the model reading it out and
handing it over IS the transport.

**What it tells you:** How much runway the account has left, *before* the wall.
The harness injects `<total_tokens>N tokens left</total_tokens>` at session
start and refreshes it after every tool result; on 2026-08-27 it was observed
starting at 15,000,000 and decrementing per turn. This is the first
quantitative, **pre-emptive** quota signal reachable from a session — Probe 1 is
binary and post-hoc, Probe 2 is not automatable, Probe 3 does not exist.

**How `usage-horizon.sh` uses it:** Comparison only. `--observe` records the
reading and computes a verdict against the `usage_horizon_*` knobs in
`pm-config.md` `## Budget` (percentage thresholds when a total is stated, the
absolute floor when it is not), with hysteresis so adjacent readings cannot
flap the verdict. `--check` re-reads it, applies the freshness/integrity gate,
and emits `STATUS=clear|approaching|critical|unknown`. The script never reads a
transcript, never converts or counts tokens, and has no estimation fallback
path — the ban in `safety.md` is satisfied architecturally, exactly as it is
for `credit-budget.sh`.

**Open characterization question (deliberately unanswered):** does the counter
track the **account 5-hour window**, a **per-session allowance**, or a **shared
pool** across concurrent sessions? Suggestive evidence for the account-window
reading: on 2026-08-27 four concurrent sessions on one machine were killed
within 15 minutes of each other, all naming a single reset time. That is
consistent with a pooled account window but does not establish it. The
evidence source for settling this is the observation log,
`~/.claude/usage-horizon.jsonl` — it accumulates `{ts, session_id, remaining,
limit}` across sessions and window resets, which is precisely the series
needed to tell a per-session allowance (each session decrements its own budget
from the same start) from a shared pool (concurrent sessions decrement one
series). Until it is settled, no consumer may assume either interpretation.

**Corroboration, not a source:** a vendor-classified usage warning appearing in
context (`USAGE_WARNING_PREFIXES` — "You've used", "You're close to"; see the
audit's 2.1.221 notes) may corroborate a reading and supply a reset time. Use
the vendor's own classification only — never free-form phrase matching, which
is the failure mode `classifier-override-patterns-source-specific` records.

**Limitations:**

- **Model-mediated.** A session that never calls `--observe` has no reading, so
  its verdict is `unknown` — never `clear`.
- **Uncharacterized semantics** (the open question above). No consumer may
  assume the counter means a session budget or an account pool.
- **Ages out** at `usage_horizon_reading_ttl_s`.
- **One state slot, machine-wide.** `.usage_horizon` holds the most recent
  `--observe` from *any* session. A session displaced by another reads
  `no-reading-this-session` and gets `unknown` — never the other session's
  verdict. Safe, but on a machine running several sessions at once (as this one
  does) it is the **common** case, so a consumer must treat `unknown` as
  routine rather than exceptional. The observation log is unaffected: every
  session's readings are appended, so the evidence series stays complete.
- **Tokens, not dollars.** It says nothing about Probe 1's wallet and never
  feeds `credit-budget.sh`.

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

The **automatic** evaluation path relies solely on Probe 1 (the harness signal).
Because only a binary post-hoc signal is reachable automatically, the budget
degrades as follows:

| Signal state | `credit-budget.sh` exits | Dispatch posture |
|---|---|---|
| No `rate_limit` event this ET day | `0` (`ok`) | Dispatch proceeds normally |
| A `rate_limit` event recorded this ET day | `1` (`reached`) | Land near-done work; park until next ET day |
| Probe 1 unreadable (file missing, corrupt, unwritable) | `2` (`unknown`) | Conservative: finish in-flight, start nothing new |

Probe 0 is **model-mediated**, so it degrades on its own axis — a session that
never observed a reading is indistinguishable from one whose reading went
stale, and both are `unknown`:

| Signal state | `usage-horizon.sh --check` exits | Posture |
|---|---|---|
| Fresh reading above the approaching threshold | `0` (`clear`) | Normal working posture |
| Fresh reading at/below `usage_horizon_approaching_pct` (or the floor) | `1` (`approaching`) | Prefer landing work over starting it |
| Fresh reading at/below `usage_horizon_critical_pct` (or the derived floor) | `2` (`critical`) | Wind down; checkpoint and hand off |
| No reading, foreign session, past TTL, corrupt/malformed state, jq or session identity unavailable | `3` (`unknown`) | Conservative: finish in-flight, start nothing new |

**Unreadable state is never permission.** In both probes an unreadable signal
is treated as `unknown`, which uses the conservative posture. Neither probe
falls back to a local token/dollar estimate. If no authoritative source is
reachable, the system says so and starts nothing new — it does not invent a
number and proceed. `usage-horizon.sh` gives `unknown` its **own exit code**
rather than folding it into `clear`, precisely so an `if script; then proceed;
fi` caller cannot read a degraded state as a green light.

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

`usage-horizon.sh` meets the same bar for Probe 0 and is held to it by a test:
its inputs are the number the model was handed and the configured thresholds,
so there is no code path an estimate could enter. That is why the safety
amendment for #1427 could name the counter as authoritative while leaving the
estimation ban verbatim — the carve-out admits an *upstream* figure, not a
derived one, and admitting a derived one would require new code that does not
exist.

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
