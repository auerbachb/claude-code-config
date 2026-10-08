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
| [issue-deps.sh](../issue-deps.sh) | Parse issue dependency markers (`Depends on #N`, `blocked by`, `unblocks`, …) from bodies and comments — the one reading `/pm` 1B.3, `/wave` 5.1, and the desk's derived impact share; `edges` and transitive `dependents` |
| [issue-file.sh](../issue-file.sh) | Validate a seven-section issue body and file it with checked labels: the one create path for /issue-maker and the desk's idea: intent |
| [makespan.sh](../makespan.sh) | Model batch makespan from per-issue estimates, respecting the concurrency ceiling, dependency chains, and reviewer throughput |
| [pm-config-get.sh](../pm-config-get.sh) | Extract a named section from `.claude/pm-config.md` |
| [pm-priority.sh](../pm-priority.sh) | Operator backlog priority for `/pm` (`<main-root>/.claude/pm-priority.json`) — `/desk` records `top`/`bump`/`park`/`drop`, `/pm` overlays it on its ranking with `apply` |
| [pm-rank-cache.sh](../pm-rank-cache.sh) | `/pm`'s latest backlog ranking cache (`~/.claude/pm-rank/<owner>-<repo>.json`): `/pm` 1B.4c writes the order it presents, the desk's derived impact reads an issue's rank while the cache is under 24 hours old (else rank unknown) |
| [split-thresholds.sh](../split-thresholds.sh) | Resolve `SPLIT_OVER_MIN` / `INCREMENT_BOUND_MIN` (env → pm-config.md `## Budget` → shipped defaults) so every capture- and pick-time sizing surface reads one figure |
| [window-plan.sh](../window-plan.sh) | Parse a user-stated planning window ("until 5:00 PM", "overnight") into canonical machine values |
<!-- catalog:rows:end -->

---

[← back to the index](../README.md)
