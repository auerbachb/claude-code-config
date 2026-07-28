# Token burn is structural, not stylistic

**Finding (issue #773, 2026-07):** heavy sessions exhausted the 5h quota in 3–4h. Research across four reports converged: output verbosity is a minority cost (~8.5% measured, not the advertised ~65%); the dominant taxes are fixed always-loaded context, transcript repetition (per-tool-call injections, every-tick tables), subagent fan-out (~15× chat), and giant invoked skills (5K/skill post-compaction re-injection cap).

**Why:** every API call re-transmits history, so per-turn junk compounds ~quadratically; caching discounts price, not window share.

**How to apply:** before adding any recurring output (hook injection, per-tick table, heartbeat prose), ask what it costs *per session*, not per message. Routine status = one line; full detail only on change/blocker/failure — hard stops always print in full. Optimize tokens-to-verified-outcome, never tokens-per-response. Full verdicts + deferred cuts: `.claude/reference/token-efficiency-audit-2026-07.md`.
