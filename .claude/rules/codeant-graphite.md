# CodeAnt & Graphite — supplemental AI review

> **CodeAnt:** On the **CR path**, when `codeant-ai[bot]` has participated on current HEAD, `merge-gate.sh` requires a clean signal (`APPROVED` on HEAD or successful CodeAnt check-run). Poll same three GitHub endpoints as CR. `@codeant-ai review` to nudge. Full contract: `cr-merge-gate.md` Step 1 + `merge-gate.sh`.
> **Graphite:** Poll `graphite-app[bot]` like other bots; clear threads and blocking CI. **Not** a merge-gate tier until reviews post reliably. If enabled but silent: verify [Graphite GitHub App](https://github.com/apps/graphite-app) repo access, Graphite AI review toggle for this repo, workspace↔GitHub link, and plan limits; then `@graphite-app re-review` on a test PR (see `fixpr` skill).

Chain: CR → BugBot → Greptile (unchanged). CodeAnt/Graphite run parallel to CR only.
