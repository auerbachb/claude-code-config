---
name: quota
description: Report today's API spend from the local usage ledger and project end-of-day spend against the daily cap. Triggers on "quota", "spend", "how much have I spent", "budget today", "am I over budget".
triggers:
  - quota
  - api spend
  - how much have I spent today
  - daily budget
  - end of day projection
  - am I over budget
model: sonnet
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
---

Report today's API spend and project end-of-day spend versus the daily cap.

Spend is tracked locally: the `quota-usage-hook.sh` PostToolUse hook appends one
tab-separated line of raw token counts per assistant response to
`~/.claude/quota-usage.log` (same append-only family as `script-usage.log`).
`quota-budget.sh` converts those counts to USD via the pricing in
`quota-config.json`; this skill formats its output. Spend tracking is
**observational** — it warns, it never blocks work.

## Default: `/quota` snapshot (keep it ≤200 words)

Run from the repo root so the script resolves `quota-config.json`:

```bash
.claude/scripts/quota-budget.sh --check
```

It prints one JSON line and caches it under `quota_daily` in
`~/.claude/session-state.json`. Read these fields:

- `estimated_usd` — spend so far today (ET).
- `budget_usd` — daily cap (`daily_cap_usd`).
- `spend_pct` — `estimated_usd / cap`.
- `responses` — assistant responses counted today.
- `fraction_of_day_elapsed` — fraction (0–1) of the ET day elapsed.
- `projected_eod_usd` — `estimated_usd ÷ fraction_of_day_elapsed` (linear run-rate).
- `projected_pct` — projection ÷ cap.
- `status` — `ok` / `info` / `warn` / `critical` (from `projected_pct`).
- `by_model` — list sorted by spend (top models).
- `over_cap` — already past the cap.

If the ledger is empty, the script reports `estimated_usd: 0` — say "no spend
recorded yet" rather than erroring.

Output a compact summary, e.g.:

```
Quota — 2026-06-25 (ET)
Spent today : $2.10 of $3.33 cap   (63%)
Responses   : 2   ·  top: claude-opus-4-8 $1.80
Day elapsed : 81%
Projected   : $2.60 by end of day  ⚠️ trending over (info)
```

Map the verdict from `status`:
- `ok` → `✅ under budget`.
- `info` → `ℹ️ on watch` (projection ≥ 60% of cap).
- `warn` → `⚠️ trending over` — add the projected overage (`projected_eod_usd − budget_usd`).
- `critical` → `🛑 likely over` — projection ≥ 95% of cap.

If `over_cap` is true, also note the actual overage (`estimated_usd − budget_usd`).

## Companions

- **Last 7 days:** `.claude/scripts/quota-budget.sh --week` — JSON with a
  zero-filled `days[]` array (oldest → newest, including zero-usage days),
  `total_usd`, and `by_model`.
- **Show config:** `.claude/scripts/quota-budget.sh --config` — cap, thresholds,
  `stop_hook_threshold`, plan metadata, pricing.
- **Set the cap (`/quota --config-cap <amount>`):** edit `daily_cap_usd` in
  `quota-config.json` (jq, preserving the rest), then re-run `--config` to confirm:

```bash
amount=25
tmp="$(mktemp)"; jq --argjson c "$amount" '.daily_cap_usd = $c' quota-config.json > "$tmp" && mv "$tmp" quota-config.json
.claude/scripts/quota-budget.sh --config | jq '.daily_cap_usd'
```

- **Reset today's cached counter:** `.claude/scripts/quota-budget.sh --reset`
  (the durable ledger is never modified; cross-day reset is automatic at ET midnight).
- **A specific past day:** `.claude/scripts/quota-budget.sh --check --date YYYY-MM-DD`.
- **Per-model breakdown for today:**

```bash
.claude/scripts/quota-budget.sh --check | jq -r '.by_model[] | "\(.model)\t$\(.estimated_usd)"'
```

## Notes

- A Stop hook (`quota-stop-notify.sh`) prints a one-line `[quota] …` reminder
  after a turn once today's spend reaches `stop_hook_threshold` (default 60% of
  cap); it is silent below that.
- The PostToolUse hook fires only when a tool runs, so a final text-only
  response is not counted — the ledger captures the large majority of spend.
- The projection is a linear run-rate (`estimated_usd ÷ fraction_of_day_elapsed`)
  with the denominator floored at 1 hour, so just after ET midnight it cannot
  explode to a false over-cap. Even so, weight actual `estimated_usd` more
  heavily before noon ET — the run-rate is noisy with little data.
- The ledger stores only timestamp, model, token counts, and session id — never
  prompts, completions, or secrets.
