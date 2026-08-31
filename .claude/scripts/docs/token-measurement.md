# Token Measurement

Scripts that capture per-repo token spend and usage baselines.

Full contract — flags, exit codes, behavior — lives in each script's `--help` output and header; where a reference doc owns the mechanism, this page names it.

| Script | Purpose |
|--------|---------|
| [ccusage-baseline.sh](../ccusage-baseline.sh) | Read-only per-session spend baseline via `ccusage`; exits 0 OK / 1 no data / 2 usage error / 3 ccusage missing / 4 invocation error; `--json` for machine output, `--recent` for last 3 days (#781) |
| [credit-budget.sh](../credit-budget.sh) | Evaluate the daily autonomous-dispatch credit budget against authoritative usage signals only — never a local estimate |
| [usage-horizon.sh](../usage-horizon.sh) | Turn the harness-injected remaining-token counter into a `clear` / `approaching` / `critical` / `unknown` verdict |
| [spend-telemetry-report.sh](../spend-telemetry-report.sh) | Summarize thread-vs-inline spend and model-tier telemetry from `~/.claude/spend-telemetry.log` |

---

[← back to the index](../README.md)
