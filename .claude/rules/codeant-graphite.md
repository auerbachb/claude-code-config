> **Always:** When CodeAnt or Graphite is enabled, poll `codeant-ai[bot]` and `graphite-app[bot]` on the same three PR endpoints as CodeRabbit; clear threads and blocking CI like other bots.
> **Ask first:** Merging — always ask the user.
> **Never:** Treat Graphite as a merge-gate tier until it posts reliably; avoid spamming `@codeant-ai` / `@graphite-app`.

# CodeAnt & Graphite

**CodeAnt (CR path):** If CodeAnt participated on current HEAD (comments or CodeAnt check-run), `merge-gate.sh` needs a clean signal per `cr-merge-gate.md`. Use `@codeant-ai review` to nudge.

**Graphite:** Poll like other bots; not a merge-gate tier until reliable. If silent: check [Graphite app](https://github.com/apps/graphite-app) access, AI review toggle, workspace link, limits; try `@graphite-app re-review` on a test PR.

Primary chain stays CR → BugBot → Greptile. CodeAnt/Graphite are parallel supplements.
