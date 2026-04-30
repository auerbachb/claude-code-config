> **Always:** Poll `codeant-ai[bot]` and `graphite-app[bot]` on the same three PR endpoints as CodeRabbit when those tools are enabled; process threads and blocking CI like other bots.
> **Ask first:** Merging — always ask the user (unchanged from repo defaults).
> **Never:** Treat Graphite as a merge-gate tier until it posts reliably; do not spam `@codeant-ai` / `@graphite-app` triggers.

# CodeAnt & Graphite — supplemental AI review

> **CodeAnt:** On the **CR path**, when CodeAnt has participated on current HEAD (reviews, inline/issue comments, **or** a CodeAnt-associated check-run on that commit), `merge-gate.sh` requires a clean signal (`APPROVED` on HEAD or successful CodeAnt check-run). `@codeant-ai review` to nudge. Full contract: `cr-merge-gate.md` Step 1 + `merge-gate.sh`.
> **Graphite:** Poll `graphite-app[bot]` like other bots; clear threads and blocking CI. **Not** a merge-gate tier until reviews post reliably. If enabled but silent: verify [Graphite GitHub App](https://github.com/apps/graphite-app) repo access, Graphite AI review toggle for this repo, workspace↔GitHub link, and plan limits; then `@graphite-app re-review` on a test PR (see `fixpr` skill).

Chain: CR → BugBot → Greptile (unchanged). CodeAnt/Graphite run parallel to CR only.
