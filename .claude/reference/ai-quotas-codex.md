# AI Quota Tracking — the Codex reader

Part of the quota reference — start at [`ai-quotas.md`](./ai-quotas.md). The display-only rule, the reserve exception and the separate-wallet boundary stated there apply to this file.

### Codex reader

Preferred path: `codex app-server` under that account's `CODEX_HOME`, JSON-RPC
`initialize` → `initialized` → `account/rateLimits/read`. The requests go in over a
**FIFO**, not a plain pipe: a pipe closes stdin as soon as the last request is written
and the server shuts down having answered only `initialize` (measured). The reader polls
for the reply and kills the server the moment it lands, so a healthy account costs a
round trip rather than the whole bound.

The response is `result.rateLimits`: `primary` and `secondary`, each
`{usedPercent, windowDurationMins, resetsAt}` (epoch seconds), plus `planType` and
`accountId`.

**The weekly window is chosen by `windowDurationMins == 10080`, across both slots, never
by position.** Measured 2026-09-07 on a Pro account: the weekly figures arrive in
`primary` with `secondary` null. Reading `secondary` as "the weekly one" reports the
wrong window on some plans and looks exactly like a right answer. A response carrying
only one window is valid and is rendered; when `--five-hour` finds no short window, the
row says so rather than vanishing.

Fallback path, only when app-server is unavailable (no CLI, no answer within the bound,
or no rate limits in the reply): `GET https://chatgpt.com/backend-api/wham/usage` with
the `auth.json` bearer (again via `curl -K -`) and the `ChatGPT-Account-Id` header. Every
row records which path produced it, so a silently degraded read is visible.

`reported_email` comes from the `id_token` claim in `auth.json`. The JWT is decoded for
that one claim inside the reader; the token itself never leaves the function.

### Captured Codex HTTP wire format (Issue #1864)

The 2026-11-07 fixture in `scripts/tests/fixtures/codex-wham-usage-2026-11-07.json`
was captured at 23:29:58 UTC through the existing authenticated HTTP reader
(HTTP 200, reader revision `dabd51bf`). The original reader rejected this body
as an unrecognized shape. Identifiers, wallet balance, and opaque model metadata
were redacted; reported window values and types are unchanged. No credentials
or request headers are stored in the fixture. Later mutated test bodies are
synthetic controls, not additional provider captures.

The HTTP boundary maps `rate_limit.primary_window` and `secondary_window` to
the shared renderer: `used_percent`, `limit_window_seconds` (seconds to minutes),
and absolute `reset_at`, falling back to `reset_after_seconds` on the reader's
clock. Invalid percentages or explicit unsupported durations fail closed. The shared
renderer labels whole hours, so a present fractional-hour wire window refuses
the response rather than truncating its label or presenting it as absent. An
omitted duration remains an honestly labelled generic window. Weekly selection
still follows duration rather than slot position. The app-server path and older
HTTP camelCase bodies retain their existing behavior. An unlabelled
`credits.balance` is not evidence of a USD amount and is not converted.
