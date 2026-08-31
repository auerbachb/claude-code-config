# Scheduling & Monitoring

Scripts that manage the background-silence ceiling, launchd watchdog, and time helpers.

Full contract — flags, exit codes, behavior — lives in each script's `--help` output and header; where a reference doc owns the mechanism, this page names it.

| Script | Purpose |
|--------|---------|
| [bgwork-ceiling.sh](../bgwork-ceiling.sh) | Hard ceiling on chat silence while background work (subagents, watchers) runs |
| [active-work-cap.sh](../active-work-cap.sh) | Repo-wide budget for simultaneously active coding work — resolves `ACTIVE_WORK_CAP`, counts open PRs + live chips + pre-PR pipelines, emits `FREE` for batch chip emitters |
| [statusline.sh](../statusline.sh) | Render the Claude Code status line — one stdout line of `ET time · branch · N agents · M watchers`; reads the session JSON on stdin, always exits 0 |
| [install-silence-watchdog.sh](../install-silence-watchdog.sh) | Install the macOS launchd watchdog that monitors Claude heartbeat files |
| [uninstall-silence-watchdog.sh](../uninstall-silence-watchdog.sh) | Uninstall the macOS launchd silence watchdog |
| [silence-watchdog.sh](../silence-watchdog.sh) | External launchd watchdog that checks heartbeat files when Claude is stalled (macOS only) |
| [off-peak-minute.sh](../off-peak-minute.sh) | Deterministic per-repo off-peak cron minute selector for CronCreate jobs |
| [gh-window.sh](../gh-window.sh) | GitHub date-window builder (ET-anchored, macOS + GNU dual-syntax) |
| [workday.sh](../workday.sh) | US business-day calculator (ET-anchored, macOS + GNU date) |
| [overrun-check.sh](../overrun-check.sh) | Per-pipeline planning-bound breach check for the monitor loop; emits one alert line on the first breach only |
| [session-scheduling-reconcile.sh](../session-scheduling-reconcile.sh) | Session-start reconciliation of durable scheduling state — purge dead in-memory job bookkeeping, surface the on-disk records that survived |

---

[← back to the index](../README.md)
