# Backlog & PM

<!-- catalog:category id=backlog-pm order=80 -->
<!-- catalog:covers Scripts that surface stale issues, duplicate candidates, forgotten PRs, and backlog metrics -->

Scripts that surface stale issues, duplicate candidates, forgotten PRs, and backlog metrics.

Full contract — flags, exit codes, behavior — lives in each script's `--help` output and header; where a reference doc owns the mechanism, this page names it.

| Script | Purpose |
|--------|---------|
<!-- catalog:rows:begin -->
| [backlog-health.sh](../backlog-health.sh) | Aggregate backlog health metrics wrapping `backlog-staleness.sh` |
| [backlog-staleness.sh](../backlog-staleness.sh) | Detect stale backlog issues (solved by merged PR, inactive, superseded, potential duplicate) |
| [candidate-ownership.sh](../candidate-ownership.sh) | Read-only pre-dispatch sweep — does another thread already own this candidate, is it live or dead, and how is it resumed |
| [chip-offer-registry.sh](../chip-offer-registry.sh) | Repo-scoped, lifecycle-aware registry of chip offers across all emitters, with an atomic reservation at the creation boundary |
| [churn-hotspot-wrap-plan.sh](../churn-hotspot-wrap-plan.sh) | Classify churn detector JSON into `/wrap` action and suppression sets using recorded decision baselines |
| [churn-hotspots.sh](../churn-hotspots.sh) | Detect files touched by many distinct merged PRs as refactor candidates |
| [estimate-log.sh](../estimate-log.sh) | Record and report guess-vs-actual durations for merged PRs in `~/.claude/estimate-log.jsonl` |
| [estimate-resolve.sh](../estimate-resolve.sh) | Resolve an issue number to its estimate string so every dispatch helper reports the same figure |
| [forgotten-pr-triage.sh](../forgotten-pr-triage.sh) | Detect and classify open PRs that have gone quiet past a staleness threshold |
| [issue-claim.sh](../issue-claim.sh) | Claim an issue at pick time so two threads cannot work the same issue at once |
| [issue-dedup.sh](../issue-dedup.sh) | Score open issues against keywords to find duplicate candidates before filing |
| [makespan.sh](../makespan.sh) | Model batch makespan from per-issue estimates, respecting the concurrency ceiling, dependency chains, and reviewer throughput |
| [pm-config-get.sh](../pm-config-get.sh) | Extract a named section from `.claude/pm-config.md` |
| [window-plan.sh](../window-plan.sh) | Parse a user-stated planning window ("until 5:00 PM", "overnight") into canonical machine values |
<!-- catalog:rows:end -->

---

[← back to the index](../README.md)
