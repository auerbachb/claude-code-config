# Schemas

JSON schemas and structured-data contracts.

Back to the [reference index](../README.md).

## Contents

- `ai-account-ledger.md` — Session account capture, metadata-only Codex backfill, and rolling project/account reports.
- `handoff-file-schema.json` — full JSON schema for `~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json`
- `session-state-schema.json` — full JSON schema for `~/.claude/session-state.json`
- `review-stack-baseline.json` — the review stack's recorded roles, billed state, and expected caps, schema `review-stack-baseline/v1`; the baseline `/review-stack-audit` compares each run against. Seeded from the 2026-06 audit; Issue #1199's decision record replaces its `tools` array (#1201)
- `review-stack-baseline-hotspot-decision.md` — keep one review-stack drift baseline (Issue #1263)
