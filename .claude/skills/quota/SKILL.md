---
name: quota
description: Report today's API spend and monthly burn against the monthly cap. Triggers on "quota", "spend", "how much have I spent", "budget today", "am I over budget", "monthly spend".
triggers:
  - quota
  - api spend
  - how much have I spent today
  - how much have I spent this month
  - daily budget
  - monthly budget
  - end of day projection
  - end of month projection
  - am I over budget
model: sonnet
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
---

Report today's API spend and this month's burn against the monthly cap, with a
secondary daily warn signal.

Spend is tracked locally: the `quota-usage-hook.sh` PostToolUse hook appends one
tab-separated line of raw token counts per assistant response to
`~/.claude/quota-usage.log`. `quota-budget.sh` converts those counts to USD via
the pricing in `quota-config.json`. Spend tracking is **observational** — it
warns, it never blocks work.

## Default: `/quota` snapshot (keep it ≤200 words)

Run from the repo root so the script resolves `quota-config.json`:

```bash
.claude/scripts/quota-budget.sh --check
```

It prints one JSON line and caches it under `quota_daily` in
`~/.claude/session-state.json`. Key fields:

**Monthly (primary signal):**
- `monthly_spend_usd` — spend so far this ET month.
- `monthly_cap_usd` — monthly cap (default $1000; user-set — see below).
- `monthly_spend_pct` — `monthly_spend_usd / monthly_cap_usd`.
- `projected_eom_usd` — linear extrapolation: `monthly_spend ÷ fraction_of_month_elapsed`.
- `projected_eom_pct` — projection ÷ cap.
- `monthly_status` — `ok` / `info` / `warn` / `critical` (from `projected_eom_pct`).

**Daily (secondary signal — caps at warn, never critical):**
- `estimated_usd` — today's spend (ET day).
- `daily_warn_threshold_usd` — daily warn trigger (default $100).
- `daily_spend_pct_of_warn` — today's spend ÷ daily warn threshold.
- `daily_status` — `ok` / `info` / `warn` (NEVER `critical`).

**Combined:**
- `status` — max severity of monthly_status and daily_status.
- `surface` — true when monthly ≥60% OR daily ≥$80.
- `by_model` — list sorted by spend (top models).

If the ledger is empty, the script reports `estimated_usd: 0` — say "no spend
recorded yet" rather than erroring.

Output a compact summary, e.g.:

```
Quota — 2026-07-01 (ET)
Month (Jul) : $42.50 of $1000 cap  (4%)  projected EoM $85.00 ✅ on track
Today       : $8.20  of $100 warn  (8%)  ✅ under threshold
Responses   : 7   ·  top: claude-opus-4-8 $7.10
```

Map the monthly verdict from `monthly_status`:
- `ok` → `✅ on track` (projected < 60% of cap).
- `info` → `ℹ️ on watch` (projection ≥ 60% of cap).
- `warn` → `⚠️ trending over` — add the projected overage.
- `critical` → `🛑 likely over cap` — projection ≥ 95% of cap.

Map the daily verdict from `daily_status`:
- `ok` → `✅ under threshold`.
- `info` → `ℹ️ approaching warn` ($80–$100 today).
- `warn` → `⚠️ high single-day burn` (≥$100 today — big session; monthly cap is the authoritative limit).

## Companions

- **Last 7 days:** `.claude/scripts/quota-budget.sh --week` — JSON with a
  zero-filled `days[]` array (oldest → newest), `total_usd`, `month_spend_usd`,
  `monthly_cap_usd`, `daily_warn_threshold_usd`, and `by_model`.
- **Current month day-by-day:** `.claude/scripts/quota-budget.sh --month` — JSON
  with a zero-filled `days[]` array for all days in the ET month, `total_usd`,
  and `by_model`.
- **Show config:** `.claude/scripts/quota-budget.sh --config` — caps, thresholds,
  `stop_hook_threshold`, pricing.
- **Set the cap (`/quota --config-cap monthly=N daily-warn=M`):**

```bash
# Set monthly cap to $2000, daily warn to $150
.claude/scripts/quota-budget.sh --config-cap monthly=2000 daily-warn=150
# Set only the monthly cap
.claude/scripts/quota-budget.sh --config-cap monthly=2000
# Set only the daily warn threshold
.claude/scripts/quota-budget.sh --config-cap daily-warn=50
```

  The $1000 monthly cap is a generous default — users on Anthropic Pro ($100/month)
  should set `monthly=100`; enterprise users may want a higher limit. Anthropic
  has no machine-readable plan endpoint, so the cap stays user-configured.

- **Reset today's cached counter:** `.claude/scripts/quota-budget.sh --reset`
  (the durable ledger is never modified; cross-day reset is automatic at ET midnight;
  cross-month reset is automatic at ET first-of-month).
- **A specific past day:** `.claude/scripts/quota-budget.sh --check --date YYYY-MM-DD`.
- **Per-model breakdown for today:**

```bash
.claude/scripts/quota-budget.sh --check | jq -r '.by_model[] | "\(.model)\t$\(.estimated_usd)"'
```

## Config schema

`quota-config.json` (repo root):

```json
{
  "monthly_cap_usd": 1000,
  "daily_warn_threshold_usd": 100,
  "thresholds": {
    "monthly": { "info": 0.60, "warn": 0.80, "critical": 0.95 },
    "daily":   { "info": 80, "warn": 100 }
  },
  "stop_hook_threshold": { "monthly_pct": 0.60, "daily_usd": 80 }
}
```

**Migration:** if an existing `quota-config.json` has the legacy `daily_cap_usd`
field, `quota-budget.sh` auto-migrates it on first run:
- `daily_cap_usd ≤ $5` (the old Pro-tier auto-default) → `monthly_cap_usd: 1000,
  daily_warn_threshold_usd: 100`.
- `daily_cap_usd > $5` (user-set) → `daily_warn_threshold_usd: <that value>`,
  `monthly_cap_usd: 1000`.
The migration is logged to stderr and noted in the first snapshot's `migration_note` field.

## Notes

- A Stop hook (`quota-stop-notify.sh`) prints a one-line `[quota] …` reminder
  after a turn when monthly projected ≥ 60% of cap OR today's spend ≥ $80.
  Below both thresholds it is silent. Format:
  `[quota] today $X / day-warn $DW (Y%) — month $A / $MC (B%) projected EoM $C — <severity>`
- Monthly projection: `projected_eom = monthly_spend / (day_of_month_frac / days_in_month)`,
  with the denominator floored at 1 day so the first day of the month cannot
  explode the projection.
- Daily projection: `projected_eod = today_spend / fraction_of_day_elapsed`, with
  the denominator floored at 1 hour. Used only for `projected_eod_usd` — never
  escalates to critical; the daily signal is observational only.
- The daily signal captures burst days (big single-session spend). The monthly
  signal is the authoritative budget signal.
- The ledger stores only timestamp, model, token counts, and session id — never
  prompts, completions, or secrets.
