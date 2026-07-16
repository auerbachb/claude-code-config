# PM Config

## Role

<!-- Optional: who uses this config (human-editable). -->

## OKRs

No OKRs set — add objectives under this header when ready.

## Complexity triggers

<!-- Issue #362 — tune per repo. Defaults match claude-code-config calibration (25 merged PRs, threshold 100 → 72% would exceed). -->

```ini
THRESHOLD_SCORE=100
FIRST_CR_ROUND=3
CADENCE_ROUNDS=2
FILE_WEIGHT=5
ENABLE_PR_REVIEW_HELP=0
```

- **THRESHOLD_SCORE** — minimum `complexity-score.sh` value before auto-trigger; must be a **non-negative integer**. Repo file sets the default; **`COMPLEXITY_THRESHOLD_SCORE` env overrides** when set.
- **FIRST_CR_ROUND** — first fire at this CodeRabbit round count (must be **≥ 3**; scripts error out otherwise — needs ≥ 2 completed CR rounds before first fire). Uses `cycle-count.sh <PR> --cr-only`. **`COMPLEXITY_FIRST_CR_ROUND` env overrides** when set.
- **CADENCE_ROUNDS** — after the first fire, fire again every N additional CR rounds (e.g. 2 → rounds 3, 5, 7…); must be **≥ 1**. **`COMPLEXITY_CADENCE_ROUNDS` env overrides** when set.
- **FILE_WEIGHT** — multiplier on `changedFiles` inside the score; must be a **positive integer** (0 and non-positive values are rejected). **`COMPLEXITY_FILE_WEIGHT` env overrides** when set.
- **ENABLE_PR_REVIEW_HELP** — `1` / `true` / `yes` / `on` posts a fourth comment `/pr-review-help #<PR_NUMBER>` after the three single-mention triggers.

## Infrastructure

No hosting/deployment infrastructure detected (no Railway, Vercel, Fly.io, Render, Supabase, Neon, Netlify, or Node/Python package manifests at repo root). This repo is a Claude Code configuration/skills distribution — it ships shell scripts, Markdown skill/rule definitions, and GitHub Actions workflows, not a deployed service.

- **CI:** GitHub Actions — `cr-plan-on-issue.yml`, `cursor-review-pr-comment.yml`, `hook-scripts.yml`, `rule-lint.yml`
- **Test sandbox:** `tests/Dockerfile` (Ubuntu 22.04) — isolated container for `setup.sh` / `setup-skills-worktree.sh` test scenarios; not a deployment artifact
- **Review bots:** CodeRabbit (`.coderabbit.yaml`)

## Architecture

- **Entry points:** none — this repo has no application runtime entry point. `setup.sh` and `setup-skills-worktree.sh` are install-time bootstrap scripts only (run once to provision `~/.claude/`), not something invoked at runtime.
- **Standard directories** (counts as of this scan — re-run `/pm-update` to refresh):
  - `.claude/skills/` — 26 skill definitions (`SKILL.md` per skill)
  - `.claude/rules/` — 17 rule files (workflow policy, auto-loaded into every session)
  - `.claude/scripts/` — 48 helper scripts (bash/python) backing skills and hooks
  - `.claude/hooks/` — 19 hook scripts (session lifecycle, guards)
  - `.claude/agents/` — subagent definitions (phase-a-fixer, phase-b-reviewer, phase-c-merger, pm-worker, researcher)
  - `.claude/reference/` — 37 reference docs (schemas, decision trees, failure-mode logs)
  - `.claude/memory/`, `.claude/data/` — persisted state
  - `tests/` — bash + Python test suite, runs in a Docker sandbox
- **Database patterns:** none (no ORM/migrations directories)
- **Test patterns:** `tests/test-setup.sh` (bash, 7 scenarios for setup/worktree scripts) + `tests/test_*.py` (Python unit tests: config protection, CR-plan filter, env guard, merge-conflict resolve, worktree guard)
- **CI:** `.github/workflows/` — `cr-plan-on-issue.yml`, `cursor-review-pr-comment.yml`, `hook-scripts.yml`, `rule-lint.yml`
- **Config files:** `.coderabbit.yaml`, `global-settings.json`

## Team

<!-- Optional: contributor display names. -->

## Notes

<!-- Free-form. -->
