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

## Active work

```ini
ACTIVE_WORK_CAP=6
```

- **ACTIVE_WORK_CAP** — repo-wide cap on simultaneously active coding work: your open PRs + live offered chips + running inline pipelines not yet at PR. Must be a **positive integer in [1, 10]**. Absent is the normal case and falls back to the default **silently**; only a value that is present but unparseable or out of range warns on stderr before falling back. **`CLAUDE_ACTIVE_WORK_CAP` env overrides** when set. Read via `.claude/scripts/active-work-cap.sh`.
- **Default 6, upper bound 10.** Derived from CodeRabbit's measured **5 reviews/hour per developer** (not the retracted ~8): rebase re-review reaches parity with productive review at 5 concurrent PRs, and past 5 a PR no longer gets even one review round per hour. 6 is one step into that degraded band — a ceiling, not a target; the target is the 3–4 working set. Full derivation: [`active-work-cap.md`](reference/active-work-cap.md).
- **Subordinate, never superior, to the per-thread ceiling** — the governing limit is `min(3–4 pipeline ceiling, ACTIVE_WORK_CAP)`. Raising this never widens a thread's own pipeline band.

## Budget

```ini
daily_credit_budget_usd = 25

LEAVE_LEAD_TIME_MIN = 30

usage_horizon_approaching_pct = 25
usage_horizon_critical_pct    = 10
usage_horizon_floor_tokens    = 2000000
usage_horizon_hysteresis_pct  = 3
usage_horizon_reading_ttl_s   = 1800
```

- **daily_credit_budget_usd** — owner's stated daily Anthropic credit overage tolerance (USD). User-editable; window is an ET calendar day. **`CLAUDE_DAILY_CREDIT_BUDGET_USD` env overrides** when set. Read via `.claude/scripts/credit-budget.sh`. This wallet covers Anthropic credit spend **only** — third-party reviewer-tool costs are tracked separately in `pricing-matrix.md`.
- **Default 25** — $25/day is the owner's stated acceptable overage exposure for a continuous autonomous thread. Budget is evaluated against authoritative harness signals only (see `.claude/reference/budget-source-probe.md`); local token/cost estimation is never used.
- **Gates autonomous dispatch only** — explicit user requests in chat always proceed with a one-line budget note. Day mode and refill respect this cap; interactive work does not.
- **LEAVE_LEAD_TIME_MIN** — minutes before a declared leave time at which the thread posts its check-in and starts winding down (issue #1525). Must be an **integer in [5, 240]**; an out-of-range or unparseable value is rejected on stderr and falls back to the default rather than being clamped — a 2-minute lead is a wind-down that cannot finish, and a 10-hour one fires before the work does. **`CLAUDE_LEAVE_LEAD_TIME_MIN` env overrides** when set, and an explicit `--lead Nm` on the invocation beats both. Read by **`/leave-by`** via `pm-config-get.sh --section Budget`, same env → config → code-default cascade as `STALL_MARGIN_MIN`.
- **Default 30** — the motivating case: told at 3 PM that the desk is empty at 7, the thread checks in at 6:30. Long enough for `/pause` to land a PR that is one merge away, short enough that the last half-hour is not spent idle. Whether it should scale with fleet size is open (issue #1525 notes).

### Usage horizon (window runway)

Five knobs turning the harness-injected in-context remaining-token counter into a verdict. All are read by **`.claude/scripts/usage-horizon.sh`**; a per-invocation env override always wins over the value here. **Distinct wallet from `daily_credit_budget_usd`** — that one is credit *spend*, these are window *quota runway*.

- **usage_horizon_approaching_pct** — integer percent `0`–`100`, default **25**. Env: **`CLAUDE_USAGE_HORIZON_APPROACHING_PCT`**. A reading at or below this share of the stated window total is `approaching`.
- **usage_horizon_critical_pct** — integer percent `0`–`100`, default **10**, and must be strictly below the approaching knob (an inverted pair is reported and falls back to the shipped defaults). Env: **`CLAUDE_USAGE_HORIZON_CRITICAL_PCT`**. At or below this share, `critical`.
- **usage_horizon_floor_tokens** — non-negative integer below 1e12, default **2000000**. Env: **`CLAUDE_USAGE_HORIZON_FLOOR_TOKENS`**. The absolute stand-in used when a reading carries **no known total**: the percentage knobs need a denominator, so the floor supplies the approaching threshold directly and the critical threshold scales by the same ratio the percentages express (`floor × critical_pct ÷ approaching_pct`). One absolute knob, same severity ordering — the `RELEASE_BUILD_FACTOR` + `RELEASE_NOTIFY_FLOOR_MIN` pairing from `release-policy.sh`, where a proportional rule keeps an absolute stand-in for the case the proportion cannot be computed.
- **usage_horizon_hysteresis_pct** — integer percent `0`–`100`, default **3**. Env: **`CLAUDE_USAGE_HORIZON_HYSTERESIS_PCT`**. Stops adjacent readings from flapping the verdict: worsening applies immediately, while leaving a band requires exceeding that band's threshold by this margin (scaled into tokens by the same ratio in floor mode). `0` disables hysteresis.
- **usage_horizon_reading_ttl_s** — seconds, `1`–`999999999`, default **1800**. Env: **`CLAUDE_USAGE_HORIZON_TTL_SECONDS`**. A stored reading older than this is `unknown`, not `clear`.

**Consuming the verdict — `/pm` day mode (#1428).** Three further values shape what day mode *does* with a verdict, and they are **env-only** — deliberately not `ini` keys here, because nothing reads this file for them and a knob that silently does nothing is worse than no knob: `CLAUDE_HORIZON_PARK_WINDOW_MINUTES` (default **2** — the landing window the pre-emptive park gives `/pause`; `0` selects exact reactive-park parity), `CLAUDE_HORIZON_PROBE_CADENCE_MINUTES` (default **30**), and `CLAUDE_HORIZON_PROBE_MAX_FIRES` (default **12**) — the bounded probe wake used when a park has no known reset time. Contract: `/pm` Step 2D.7; rationale: `.claude/reference/pm-day-mode.md`.

**These knobs gate horizon verdicts only.** They never authorize local token estimation — `usage-horizon.sh` compares an upstream-supplied number and has no code path that could consume an estimate (`.claude/rules/safety.md` §"Anthropic Quota & Spend Authority"; `.claude/reference/budget-source-probe.md` §"Probe 0").

## Infrastructure

No hosting/deployment infrastructure detected (no Railway, Vercel, Fly.io, Render, Supabase, Neon, Netlify, or Node/Python package manifests at repo root). This repo is a Claude Code configuration/skills distribution — it ships shell scripts, Markdown skill/rule definitions, and GitHub Actions workflows, not a deployed service.

- **CI:** GitHub Actions — `cr-plan-on-issue.yml`, `cursor-review-pr-comment.yml`, `hook-scripts.yml`, `rule-lint.yml`
- **Test sandbox:** `tests/Dockerfile` (Ubuntu 22.04) — isolated container for `setup.sh` / `setup-skills-worktree.sh` test scenarios; not a deployment artifact
- **Review bots:** CodeRabbit (`.coderabbit.yaml`)

## Architecture

- **Entry points:** none — this repo has no application runtime entry point. `setup.sh` and `setup-skills-worktree.sh` are install-time bootstrap scripts only (run once to provision `~/.claude/`), not something invoked at runtime.
- **Standard directories** (counts as of this scan — re-run `/pm-handoff` to refresh):
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
