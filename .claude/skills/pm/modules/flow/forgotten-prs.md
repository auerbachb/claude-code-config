<!-- pm-routing:begin -->
Run the existing forgotten-PR triage after Your Open PRs, before Suggested Next Issues.
<!-- pm-routing:end -->

Runs on **every** `/pm` invocation, no flag required — both 1A.4 (resume) and 1B.5 (cold start) call it, rendering its block **immediately after `## Your Open PRs` and before `## Suggested Next Issues`**. It is informational-first: its block never alters 1B.3 narrowing, 1B.4 scoring, or the 1B.4b judgment check.

**Run the read-only helper:** resolve `forgotten-pr-triage.sh` (`${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/forgotten-pr-triage.sh}`, then `${HOME:+$HOME/.claude/scripts/forgotten-pr-triage.sh}`, then `.claude/scripts/forgotten-pr-triage.sh`; first executable wins; if none resolves, print `DEGRADED: forgotten-pr-triage.sh not found (checked all three paths) — forgotten PR triage unavailable` and render `## Forgotten PRs` as "unavailable"). Then run `"$FORGOTTEN_PR_TRIAGE_SH" --json` with `--days "$FORGOTTEN_PR_DAYS"` when that is set and `--author "$GH_USER"` when `$GH_USER` is set. Render its output as the `## Forgotten PRs` block. The helper never closes, merges, or deletes anything, and this step offers no close or merge actions — those are handled by `/pr-monitor-and-manage` for open PRs.

Mark `1D ran` when the triage finishes, or `1D failed` with the reason if the helper cannot run.
