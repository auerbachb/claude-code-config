---
name: quotas
description: Use when deciding which AI subscription to work on next — how much of each registered account's cap is gone, when each one resets, what continuing past a drained cap costs on each provider, and which need a re-login. Covers every account /quotas-setup registers — Claude, Codex, and Cursor (two monthly usage pools, reported as percent used, read through a saved browser session). Display only — it never switches accounts, never buys anything, and never gates dispatch.
triggers:
  - quotas
  - how much quota is left
  - which account has room
  - when does my weekly cap reset
  - am I close to the weekly limit
  - check my Claude, Codex and Cursor usage
  - how much Cursor credit is left
  - which account is cheapest to keep working on
  - what does it cost to keep going past my cap
argument-hint: "[--json] [--five-hour] [--account <label>]"
model: sonnet
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
---

Report how much of each registered account's allowance is gone, when it comes back, and
what continuing past it would cost — one row per account per window.

> **The cheapest-next hint never acts.** It **never switches accounts, never purchases
> anything, and never gates dispatch.** It names an account and stops. Buying a Codex
> reset, enabling Claude usage credits, and raising a Cursor spend limit are the owner's
> actions, taken in the provider's own UI — do not offer to perform any of them, and do
> not treat "cheapest to continue on" as an instruction to re-route work. The prices it
> quotes are a checked-in table with `last verified` dates, so it is only as fresh as
> those dates.

> **Display only — never a gate.** Nothing this skill produces may gate dispatch, pause
> work, downgrade a model, defer a launch, or feed `credit-budget.sh`. Quota and spend
> authority belongs to Anthropic's own in-app UI and upstream harness signals — see
> `.claude/rules/safety.md` §"Anthropic Quota & Spend Authority". This is a **third,
> purely observational surface**, distinct from the two that legitimately gate: the
> user-configured `daily_credit_budget_usd` budget and the `#1427` usage-horizon
> counter. The earlier `/quota` skill was rolled back in issue #499 for exactly this —
> gating agent decisions on locally-read numbers. Answer the user's question and stop.

> **No credential value ever passes through you.** The helper borrows each account's
> live token in place for one request — or, for Cursor, drives a browser on a saved
> session that never leaves its profile directory — and never prints either. Do not run
> a command that reads a credential out of the Keychain, a profile directory, or a
> browser cookie store yourself, and never repeat a token, cookie, or `auth.json` body
> into the conversation.

## Step 1 — Resolve the helper

<!-- test-anchor: resolve-helper -->
```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
AI_QUOTAS_SH=$(resolve_script ai-quotas.sh || true)
[[ -n "$AI_QUOTAS_SH" ]] || { echo "ERROR: ai-quotas.sh not found (checked all three paths) — quota reporting unavailable" >&2; exit 1; }
```

**STOP** if the helper does not resolve: print that one line and end. Do not hand-roll a
reader — a second caller of the provider APIs is how two answers start disagreeing, and
reading a credential by hand is exactly what this design forbids.

## Step 2 — Route the request

| The user asked | Run |
|----------------|-----|
| nothing, "quotas", "how much is left" | `"$AI_QUOTAS_SH"` |
| "include the five-hour windows" | `"$AI_QUOTAS_SH" --five-hour` |
| about one account | `"$AI_QUOTAS_SH" --account <label>` |
| for machine-readable rows | `"$AI_QUOTAS_SH" --json` |
| "what does continuing cost", "which is cheapest" | `"$AI_QUOTAS_SH"` — the Overage column and the trailing hint are part of the default table |

Weekly rows are the default because the weekly cap is what the switching decision turns
on; the five-hour figures arrive in the same payload and are one flag away. Flag detail
and exit codes live in `"$AI_QUOTAS_SH" --help` — do not restate them here.

## Step 3 — Read the table

Columns: account, provider, window-or-pool, used %, remaining %, **overage**, reset time
in Eastern, a countdown, status, and a note. The **account** column shows the email the provider
itself reports; when that differs from the registered label the note says
`registered as <label>`, which is how a mislabelled account becomes visible. **Cursor
rows carry no such email** — the dashboard response has none — so a Cursor row shows the
registered label and can never carry a `registered as` note. Absence of that note on a
Cursor row says nothing about whether the label is right.

The third column is the **pool** where a provider has pools and the window otherwise. A
Cursor account normally contributes **two** rows — `cursor-models` (Composer, Cursor
Grok, and anything Auto routes there) and `other-models` (third-party models at API
price) — both against the same monthly billing cycle. Two rows for one account is
expected, not a duplicate. A pool whose percentage the response omits or reports
unreadably is left out rather than shown as `0`, so **one** row is possible; the pool
that is missing is the one there is no figure for.

Each row succeeds or fails on its own. One account's failure never suppresses the rest,
so a table with a broken row is a complete answer, not a partial one.

| Status | Meaning | What to tell the user |
|--------|---------|-----------------------|
| `ok` | Figures were read | the numbers |
| `needs-login` | No usable credential for that profile | the exact `/quotas-setup relogin <label> <provider>` command in the note |
| `rate-limited` | The provider answered 429 | when to retry; the note carries the window |
| `unreachable` | Nothing answered: a network failure, a missing runtime or browser driver, a helper that crashed, or a probe that hit its time bound | that the figure is unknown — **never** a guess or a 0 %; if the note names an install command, relay it |
| `unreadable` | The response arrived but changed shape; the note names the keys seen | that the figure is unknown, and that the reader needs updating |
| `unsupported` | A provider this reader does not know | that it is not covered |

A `needs-login`, `rate-limited`, `unreachable`, or `unreadable` row is **not** a reason
to pause, re-route, or decline work. It means one number is unavailable, nothing more.

## Step 3b — The Overage column and the cheapest-next line

The **OVERAGE** column is what continuing PAST that row's cap costs: `1 free reset` or
`~$90/reset` on Codex, `API rate` on Claude, `on-demand` (or `on-demand $1007.50 of $1000`
when Cursor reported the figure) on Cursor. `-` means no price is known — an unrecognised
provider, or a run where the helper was unavailable and said `DEGRADED:` on stderr. It
never means free.

When **at least one** account is at or below the threshold (default 20 % remaining), three
lines follow the table:

```
Cheapest to continue on: codex-one@example.com (60 % weekly left, 1 free reset this month)
  Approximate: a Codex reset buys a fixed week at a flat price, while Claude and Cursor
  overage is metered per unit of work — the units do not convert. …
  Informational only — it never switches accounts, never buys anything, and never gates dispatch.
```

Relay all three, or none. Repeat the recommendation without its basis and a reader takes
it for a price comparison, which it is not — the units genuinely do not convert.

**Restating the boundary at the point of use:** this line is a suggestion for the owner,
not an instruction for you. Do not switch accounts, do not offer to buy a reset or enable
credits, and do not let it change what work you dispatch or defer. Nothing prints at all
when every account still has room, and that silence is the normal case.

Prices, their sources and `last verified` dates, the threshold knob, the Codex reset
watermark, and how the ranking orders included quota before a free reset before metered
overage before a flat fee: `.claude/reference/ai-quotas.md` §"Overage — what continuing
costs". `.claude/reference/pricing-matrix.md` is a **different wallet** — the review
stack — and its numbers never apply here.

## Step 4 — Report

Show the table. Lead with the answer the user asked for — usually which account has the
most room this week and when the drained one resets — then the rows. If every row is
`ok`, that is two lines and the table; do not narrate the reader's internals.

**STOP conditions.** On a non-zero exit, report the helper's message and stop:

- Exit `3` — a usage problem (unknown flag, `--account` with no label). Fix the
  invocation and re-run.
- Exit `5` — the tool cannot run: `jq` is missing, or `~/.claude/ai-quotas.json` is
  unreadable, unparseable, or written by a different schema major. Do **not** hand-edit
  that file; `/quotas-setup` owns it.

"No accounts registered yet" is exit `0`, not a failure — route the user to
`/quotas-setup add <provider> <label>`.

## Reference

Registry schema, where each provider keeps its credential, which endpoint each reader
calls, why the Codex weekly window is chosen by duration rather than position, the
Cursor dashboard endpoint captured from the live Spending tab (and why the Cursor rows
carry percentages rather than per-pool dollars), the overage table with its sources and
`last verified` dates, and the display-only boundary: `.claude/reference/ai-quotas.md`.

`--json` emits a **document** — `{schema_version, threshold_pct, basis, rows,
cheapest_next}` — not the bare row array it emitted before #1669. Read the rows from
`.rows`; `cheapest_next` is `null` unless the hint fired. The "no accounts registered"
and "no account matched" exits emit that same object with an empty `rows`, and a run
whose pricing helper was unavailable emits it with `threshold_pct` and `basis` `null` and
`overage` `null` on every row — one shape in every case, so there is nothing to
special-case.
