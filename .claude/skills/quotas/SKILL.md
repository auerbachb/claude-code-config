---
name: quotas
description: Use when deciding which AI subscription to work on next — how much of each registered account's cap is gone, when each one resets, and which need a re-login. Covers every account /quotas-setup registers — Claude, Codex, and Cursor (two monthly usage pools, reported as percent used, read through a saved browser session). Display only — it never gates dispatch, pauses work, or feeds any budget.
triggers:
  - quotas
  - how much quota is left
  - which account has room
  - when does my weekly cap reset
  - am I close to the weekly limit
  - check my Claude, Codex and Cursor usage
  - how much Cursor credit is left
argument-hint: "[--json] [--five-hour] [--account <label>]"
model: sonnet
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
---

Report how much of each registered account's allowance is gone and when it comes back,
one row per account per window.

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

Weekly rows are the default because the weekly cap is what the switching decision turns
on; the five-hour figures arrive in the same payload and are one flag away. Flag detail
and exit codes live in `"$AI_QUOTAS_SH" --help` — do not restate them here.

## Step 3 — Read the table

Columns: account, provider, window-or-pool, used %, remaining %, reset time in Eastern,
a countdown, status, and a note. The **account** column shows the email the provider
itself reports; when that differs from the registered label the note says
`registered as <label>`, which is how a mislabelled account becomes visible.

The third column is the **pool** where a provider has pools and the window otherwise. A
Cursor account contributes **two** rows — `cursor-models` (Composer, Cursor Grok, and
anything Auto routes there) and `other-models` (third-party models at API price) — both
against the same monthly billing cycle. Two rows for one account is expected, not a
duplicate.

Each row succeeds or fails on its own. One account's failure never suppresses the rest,
so a table with a broken row is a complete answer, not a partial one.

| Status | Meaning | What to tell the user |
|--------|---------|-----------------------|
| `ok` | Figures were read | the numbers |
| `needs-login` | No usable credential for that profile | the exact `/quotas-setup relogin <label> <provider>` command in the note |
| `rate-limited` | The provider answered 429 | when to retry; the note carries the window |
| `unreachable` | Network failure, a missing runtime or browser driver, or a response shape this reader does not recognise (the note prints the keys it saw) | that the figure is unknown — **never** a guess or a 0 %; if the note names an install command, relay it |
| `unreadable` | The response arrived but changed shape; the note names the keys seen | that the figure is unknown, and that the reader needs updating |
| `unsupported` | A provider this reader does not know | that it is not covered |

A `needs-login`, `rate-limited`, `unreachable`, or `unreadable` row is **not** a reason
to pause, re-route, or decline work. It means one number is unavailable, nothing more.

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
carry percentages rather than per-pool dollars), and the display-only boundary:
`.claude/reference/ai-quotas.md`.
