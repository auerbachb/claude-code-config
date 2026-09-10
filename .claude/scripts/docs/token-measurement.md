# Token Measurement

<!-- catalog:category id=token-measurement order=90 -->
<!-- catalog:covers Scripts that capture per-repo token spend and usage baselines -->

Scripts that capture per-repo token spend and usage baselines.

Full contract — flags, exit codes, behavior — lives in each script's `--help` output and header; where a reference doc owns the mechanism, this page names it.

| Script | Purpose |
|--------|---------|
<!-- catalog:rows:begin -->
| [ai-quotas-setup.sh](../ai-quotas-setup.sh) | Register AI subscription accounts (`claude`/`codex`/`cursor`) and their isolated per-account login profiles in `~/.claude/ai-quotas.json`, name them with short nicknames, install or remove the macOS LaunchAgent that takes one unattended usage reading a day, and report which accounts are currently logged in — labels and paths only, never a credential value |
| [ai-quotas.sh](../ai-quotas.sh) | Read every account registered by `/quotas-setup` and print one row per usage window — used %, reset time in Eastern, and a countdown — for `claude` (Anthropic OAuth usage endpoint), `codex` (`codex app-server`, HTTP fallback), and `cursor` (the dashboard's own usage response, read through a saved browser session), recording each reading to `~/.claude/ai-quotas-history.jsonl`; display only, never a dispatch or spend gate |
| [ccusage-baseline.sh](../ccusage-baseline.sh) | Read-only per-session spend baseline via `ccusage`; exits 0 OK / 1 no data / 2 usage error / 3 ccusage missing / 4 invocation error; `--json` for machine output, `--recent` for last 3 days (#781) |
| [credit-budget.sh](../credit-budget.sh) | Evaluate the daily autonomous-dispatch credit budget against authoritative usage signals only — never a local estimate |
| [quotas-cheapest-next.sh](../quotas-cheapest-next.sh) | Annotate `ai-quotas.sh --json` rows with each provider's overage cost (Codex free-or-paid reset, Claude API rate, Cursor on-demand) from a checked-in table with `last verified` dates, prefer a live figure when the row carries one, and name the cheapest account to continue on when any account is at or below the configurable remaining threshold; informational only, never a dispatch or spend gate |
| [spend-telemetry-report.sh](../spend-telemetry-report.sh) | Summarize thread-vs-inline spend and model-tier telemetry from `~/.claude/spend-telemetry.log` |
| [usage-horizon.sh](../usage-horizon.sh) | Turn the harness-injected remaining-token counter into a `clear` / `approaching` / `critical` / `unknown` verdict |
<!-- catalog:rows:end -->

---

[← back to the index](../README.md)
