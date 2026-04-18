# Script Extraction Audit

Audit of deterministic agent actions that could be extracted from rule/skill/agent prose into `.claude/scripts/` shell utilities for speed, token savings, and testability. Produced for issue #271.

> **Scope of this doc:** Inventory and ranking only. No code is extracted here — each P0 candidate gets its own follow-up implementation issue, and the "Recommended Extraction Order" at the bottom lists them.

## Audit Coverage

Every directory below was walked (read every `.md`, `.sh`, `.py`, `.json`, `.yml`) on 2026-04-15 against branch `claude/tender-easley` (base: `8f7f53a`):

- `.claude/rules/*.md` (15 files, 75 KB)
- `.claude/skills/*/SKILL.md` (22 skills, 5,800 lines)
- `.claude/skills/fixpr/audit.sh` (the one existing per-skill script — template for extractions)
- `.claude/agents/*.md` (5 agents + README, 51 KB)
- `.claude/reference/*.md` and `.claude/reference/*.json` (11 files)
- `.claude/scripts/*.sh` + README (existing extractions)
- `.claude/hooks/*.sh` + `*.py` + README (9 hooks)
- `.github/workflows/*.yml` (2 workflows)
- Root: `CLAUDE.md`, `global-settings.json`, `setup.sh`, `setup-skills-worktree.sh`
- Memory index (`~/.claude/projects/-…/memory/MEMORY.md`) — scanned for confirmed pain points

Total prose in rule/skill/agent surface area: ~9,000 lines of Markdown. The audit focuses on deterministic, side-effect-free or single-side-effect procedures that the agent repeats in prose today.

---

## Summary

| Bucket | Count |
|-------:|:------|
| **Total extraction candidates** | **22** |
| P0 — extract first (high reuse × high token cost × deterministic) | **7** (2 extracted, 5 pending) |
| P1 — extract next (meaningful reuse OR meaningful token cost) | **8** |
| P2 — extract later (low reuse or low cost, but still mechanical) | **7** |
| Existing extracted scripts in `.claude/scripts/` | 6 (see "Existing Scripts") |
| Existing per-skill scripts (not in `.claude/scripts/`) | 1 (`fixpr/audit.sh`) |
| Existing hook scripts in `.claude/hooks/` | 9 |

**Estimated combined savings if all P0+P1 are extracted:** ~12,000–18,000 tokens per typical Phase B cycle (polling one PR through a fix round to merge), driven mostly by the merge-gate verifier (C-01), the PR-state snapshot (C-02) unifying what fixpr/audit.sh already does, and the all-threads-resolver (C-04). Secondary wins: removing ~200 lines of duplicated bash from `merge`, `wrap`, `continue`, `status`, and the Phase B/C agent files, which cuts their on-load weight for every invocation.

**Recommended extraction order:** C-01 → C-02 → C-04 → ~~C-06~~ (extracted — issue #279) → C-05 → C-03 → C-07, then the P1 batch in the order listed. Rationale at bottom of this doc.

---

## Existing Scripts (current inventory + bypass call sites)

| Script | Purpose | Called from | Known bypass / inline reinvention |
|--------|---------|-------------|------------------------------------|
| `.claude/scripts/repair-trust-all.sh` | Mass-fix trust flags in `~/.claude.json` | Manual, documented in `.claude/rules/trust-dialog-fix.md` | `.claude/hooks/trust-flag-repair.sh` reimplements the same logic for the Stop-hook path (**intentional** — the hook must be self-contained; not a bypass, but a near-duplicate worth noting for dedup) |
| `.claude/scripts/repair-trust-single.sh` | Fix trust flags for one project path | Manual | Same logic duplicated in `repair-trust-all.sh` + `trust-flag-repair.sh` — three copies of the same atomic-write-to-`~/.claude.json` pattern |
| `.claude/scripts/repair-worktrees.sh` | Detect + remove stale worktrees (dry-run by default) | Manual | No bypass call site, but `/wrap` Step 5 reimplements a subset (worktree remove + branch delete) inline |
| `.claude/scripts/audit-skill-usage.sh` | Monthly skill-usage audit | Manual | No bypass |
| `.claude/scripts/cycle-count.sh` | Per-PR review-then-fix cycle count (epoch-normalized). Prints integer to stdout. | `/merge`, `/wrap`, `/pm-rate-team`, `/pm-sprint-review` | Extracted C-06 (issue #279). No remaining bypass. |
| `.claude/skills/fixpr/audit.sh` | Gather PR state (threads + checks + comments + statuses + new-since classifier) → JSON | `/fixpr` (via `~/.claude/skills/fixpr/audit.sh` fallback chain in SKILL.md) | **Major bypass surface.** All of `/merge`, `/wrap`, `/continue`, `/status`, `phase-b-reviewer`, and `phase-c-merger` fetch overlapping subsets of the same data inline with `gh api` one-liners. See C-02 — promoting `audit.sh` into a shared `.claude/scripts/pr-state.sh` and pointing every skill at it is the single biggest extraction win |

**Hooks (`.claude/hooks/`)** are out of scope for this audit — they run outside the agent loop on Stop/PostToolUse/PreToolUse events and do not consume agent tokens. They're listed only because three of them (`trust-flag-repair.sh`, `session-start-sync.sh`, `env-guard.py`) inline logic that a shared helper would simplify. Those are deferred P2+ (out of scope for token-cost extraction).

---

## Candidates

Columns: **ID** | **Candidate** | **Where it lives today** | **Call sites** | **Tokens/session (est)** | **Determinism** | **Risk of extraction** | **Priority** | **Proposed CLI (P0/P1 only)**

Tokens/session is a conservative estimate of the prose + inline-bash tokens the agent spends per invocation of the call-site skill (not per session overall — extracting a P0 candidate saves this much every time a skill that uses it runs).

### P0 — Extract first

| ID | Candidate | Where it lives today | Call sites | Tokens/session (est) | Determinism | Risk | Priority | Proposed CLI signature + exit contract |
|----|-----------|----------------------|------------|---------------------:|-------------|------|:--------:|----------------------------------------|
| **C-01** ✅ | Merge-gate verifier (CR 2-clean / BugBot 1-clean / Greptile severity) | **Extracted to `.claude/scripts/merge-gate.sh`** — now called from `merge` Step 2, `wrap` Step 2.1, `continue` Step 8, `phase-c-merger` Step 1, `status` Step 3 | 5 skills + 1 agent | ~2,500 | Fully deterministic given (PR, HEAD SHA, reviewer). Reviewer assignment comes from session-state or live history. | Low — read-only `gh api` queries. Side-effects only on session-state write-back for sticky reviewer. | **P0** | `merge-gate.sh <pr_number> [--reviewer cr\|bugbot\|greptile]` → JSON `{met, reviewer, path, missing, head_sha, ci_status, merge_state}`. Exits: `0` gate met, `1` gate not met (stdout JSON always), `2` usage error, `3` PR not found / closed, `4` gh/network error. Folds in CI hardening (#270) and BEHIND check (#273). |
| **C-02** | PR state snapshot — threads + checks + 3 comment endpoints + statuses + merge_state + (opt) classify-since | Fully implemented in `.claude/skills/fixpr/audit.sh`; inline shards in `merge`, `wrap`, `continue`, `status`, `pm` (Section 2.1), `phase-b-reviewer` polling loop, `phase-c-merger` Step 1 | 7 skills + 2 agents | ~3,500 (for skills that refetch everything) | Deterministic per-SHA. Classify-since window is deterministic given baseline timestamp. | Low — `fixpr/audit.sh` has been in production; move it to `.claude/scripts/pr-state.sh` and add call-site wrappers in other skills | **P0** | `pr-state.sh [--pr N] [--since <iso-8601>]` → JSON bundle to `/tmp/pr-state-<PR>-<epoch>.json`, prints path on stdout. Exits: `0` OK, `2` usage, `3` not on a branch and no `--pr` given, `4` PR closed or not found, `5` gh/network error. Canonical interface is `--pr N`; when omitted the script auto-detects from the current branch (same behavior as today's `fixpr/audit.sh`). No positional argument. (Effectively: promote `fixpr/audit.sh` to `.claude/scripts/pr-state.sh`, change the output-path prefix, and expose the implicit branch-based PR lookup as an explicit optional `--pr` override.) |
| **C-03** ✅ | CR plan comment detection on an issue (substantive filter) | **Extracted to `.claude/scripts/cr-plan.sh`** (#276); `start-issue` Step 3, `subagent` Step 2, and `pm-worker` "Issue Creation" Step 3 all migrated | 3 skills | ~800 | Deterministic given issue number + filter regex (exclude "actions performed", require length > 200) | Low — read-only `gh issue view --json comments` + jq filter | **P0** | `cr-plan.sh <issue_number> [--poll <minutes>] [--max-age-minutes N]` → stdout: plan body (plaintext) or empty. Exits: `0` plan found (printed), `1` no plan after poll window, `2` usage, `3` issue not found or closed, `4` gh error. `--poll` enters a 60s polling loop until timeout. |
| **C-04** ✅ | All-threads-resolver — fetch unresolved review threads → filter to `coderabbitai\|cursor\|greptile-apps` → `resolveReviewThread` (fallback `minimizeComment`) — extracted to `.claude/scripts/resolve-review-threads.sh` in #277; `phase-a-fixer`/`fixpr`/`continue` migrated | `phase-a-fixer` Step 5, `fixpr` Step 4b, `continue` Step 7, rule prose in `cr-github-review.md` "Processing CR Feedback" step 4 | 2 skills + 1 agent + 1 rule | ~1,200 (GraphQL query + mutation loop + fallback is verbose) | Fully deterministic given PR number | Low — only mutating call is the GraphQL resolution itself, which is idempotent | **P0** | `resolve-review-threads.sh <pr_number> [--authors coderabbitai,cursor,greptile-apps] [--dry-run]` → stdout per-thread status lines. Exits: `0` all resolved (or dry-run OK), `1` ≥1 thread could not be resolved (both mutations failed), `2` usage, `3` PR not found, `4` gh error. Dry-run prints the thread IDs that would be resolved and exits 0 without mutating. |
| **C-05** ✅ | Root-repo path resolver (`git worktree list \| head -1 \| awk '{print $1}'`) | `work-log.md` rule (×2), `safety.md` rule, `skill-symlinks.md` rule (×2), `setup-skills-worktree.sh`, `session-start-sync.sh`, `wrap` (×2), `start-issue` (×2), `merge` Step 5b, `pm-worker`, `repair-worktrees.sh`, `pm` Step 2.1 | 3 rules + 5 skills + 2 agents + 2 hooks + 3 existing scripts | ~300 per call site, ~3,500 total prose | Fully deterministic | Near-zero — one-line bash. Extraction risk is over-engineering. | ✅ **Extracted** | `.claude/scripts/repo-root.sh` — Extracted for issue #278. 10 call sites migrated across rules, skills, agents, and scripts. Hook call sites retain inline fallback for robustness. |
| **C-06** ✅ | Cycle-count reconstruction — per-PR review-then-fix pairings | **Extracted to `.claude/scripts/cycle-count.sh`** (issue #279). Call sites migrated: `merge` Step 6, `wrap` Step 2.7, `pm-rate-team` Step 3b, `pm-sprint-review` Step 5c. | 4 skills + 1 reference | ~900 | Fully deterministic given PR (reviews + commits timeline). | Low — pure read from GitHub API. | **P0** ✅ | `cycle-count.sh <pr_number> [--exclude-bots]` → stdout: integer cycle count. Exits: `0` OK (count on stdout), `2` usage, `3` PR not found, `4` gh error. `--exclude-bots` filters reviews whose `user.login` ends in `[bot]` or equals `github-actions` (matches `pm-data-patterns.md` bot filter). |
| **C-07** ✅ | GH date-window builder — `SINCE_DATE` + `SINCE_ISO` with colon-offset, ET anchor, macOS + GNU dual-syntax | **Extracted to `.claude/scripts/gh-window.sh`.** Migrated: `pm-rate-team` Step 1 (full), `pm-sprint-review` Step 1 (full), `pm-team-standup` Step 1 (`SINCE_DATE` only — skill anchors `SINCE_ISO` to noon ET, not midnight), `standup` (CANDIDATE seed in the smart-lookback helper suite), `pm-data-patterns.md` "Time window utilities" (now references the script). **`pm-sprint-plan`:** originally listed but confirmed (via grep + git history) to have no `SINCE_DATE`/`SINCE_ISO` pattern — nothing to migrate. | 4 skills + 1 reference migrated; 1 skill N/A | ~400 per call site, ~1,900 saved total | Fully deterministic | Extracted — no further action | **P0 ✅** | `gh-window.sh --days N [--format date\|iso\|both]` → stdout: one value (or two tab-separated for `both`). Exits: `0` OK, `2` usage (missing/invalid `--days`), `3` `date` command failed on this platform. Default `--format both` prints `"$SINCE_DATE\t$SINCE_ISO"`. |

### P1 — Extract next

| ID | Candidate | Where it lives today | Call sites | Tokens/session (est) | Determinism | Risk | Priority | Proposed CLI signature + exit contract |
|----|-----------|----------------------|------------|---------------------:|-------------|------|:--------:|----------------------------------------|
| **C-08** ✅ | CI health check — all-check-runs pass / blocking / incomplete splits | **Extracted to `.claude/scripts/ci-status.sh`** (issue #281). `merge-gate.sh` now calls it internally; `merge` Step 4 / `wrap` Step 2.3 reference it for higher-level inspection; `continue` Step 8 + `phase-c-merger` Step 1 transitively migrated via `merge-gate.sh`; `cr-polling-commands.md` + `cr-merge-gate.md` Step 1b updated to point at the script. | 4 skills + 1 agent + 2 references migrated | ~700 | Deterministic per-SHA | Low — read-only | **P1 ✅** | `ci-status.sh <head_sha_or_pr_number> [--format json\|summary]` → JSON `{head_sha, total, passing, failing, in_progress, blocking: [...], in_progress_runs: [...]}` (summary mode prints one line). Exits: `0` CI clean and complete, `1` incomplete runs remain, `2` usage, `3` blocking failures present, `4` SHA/PR not found, `5` gh error. Distinct exit codes 1 vs 3 let callers branch on "wait" vs "fix". |
| **C-09** | Reply-to-thread with inline/PR-comment fallback + reviewer-specific @mention rules (CR: mention `@coderabbitai`; BugBot/Greptile: plain text) | `phase-a-fixer` Step 4, `phase-b-reviewer` "Processing Findings" step 3, `fixpr` Step 4a, `continue` Step 7, `cr-github-review.md` "Processing CR Feedback" step 3, `greptile-reply-format.md`, `bugbot.md` "Processing BugBot Findings" | 2 skills + 2 agents + 3 references | ~600 | Deterministic given {comment ID, body, reviewer} | Low — one mutating call, but reviewer rules already locked in | **P1** | `reply-thread.sh <comment_id> --reviewer cr\|bugbot\|greptile --body "<text>" [--pr N]` → stdout: posted URL. Exits: `0` reply posted (inline endpoint), `1` reply posted via PR-comment fallback, `2` usage, `3` comment ID not found, `4` both endpoints failed, `5` gh error. Auto-applies `@coderabbitai` prefix in CR mode; strips any `@cursor`/`@greptileai` tokens from `--body` in the BugBot/Greptile modes. |
| **C-10** ✅ | Test-Plan checkbox extractor + updater (PR body) | **Extracted to `.claude/scripts/ac-checkboxes.sh`** — migrated call sites: `check-acceptance-criteria` Step 2 + 4, `merge` Step 3, `wrap` Step 2.2, `continue` Step 9, `subagent` Phase C, `phase-c-merger` Step 2 | 5 skills + 1 agent | ~500 | Deterministic text transformation | Low — the write call is `gh pr edit --body-file`, user-reviewable | **P1** ✅ | `ac-checkboxes.sh <pr_number> [--extract\|--tick <regex-or-indexes>\|--all-pass]` → `--extract` prints JSON `[{index, checked, text}]`; `--tick 0,2,3` or `--tick "regex"` updates the PR body via `gh pr edit`; `--all-pass` ticks every unchecked box. Exits: `0` OK, `1` no Test Plan section found OR section exists but has no checkbox items (both blocking per CLAUDE.md), `2` usage / internal script error, `3` PR not found, `4` `gh pr edit --body-file` failed (only from `--tick`/`--all-pass`). |
| **C-11** | `session-state.json` surgical updater (preserve siblings, atomic write) | `phase-b-reviewer` Greptile budget check (×2 inline jq expressions), `continue` Step 6 rate-limit branch, `handoff-files.md` reference, `pm` resume mode | 2 agents + 1 skill + 1 reference | ~450 | Fully deterministic | Medium — write to state file; atomic-write pattern must match the one in `repair-trust-all.sh` | **P1** | `session-state.sh --set <jq-path>=<value> [--set ...]` (uses `jq --arg` under the hood; multiple `--set` flags merge into one write). Also `--get <jq-path>` for reads. Exits: `0` OK, `2` usage, `3` state file missing (creates default on `--set`, errors on `--get`), `4` jq parse error, `5` write failed. Uses tempfile + `mv` atomic-write pattern from `repair-trust-*.sh`. |
| **C-12** ✅ | Greptile daily budget check + atomic decrement | **Extracted to `.claude/scripts/greptile-budget.sh`** (issue #285). Migrated: `phase-b-reviewer` "Daily Budget Check" now invokes `greptile-budget.sh --consume`; `greptile.md` "Daily Budget" section replaced the prose algorithm with the script contract. `cr-github-review.md` already delegates to `greptile.md` (no direct budget references, nothing to migrate). | 1 agent + 1 rule migrated | ~800 | Fully deterministic given today's ET date | Medium — write-back to session-state; must be atomic to prevent double-decrement | **P1** ✅ | `greptile-budget.sh [--check\|--consume\|--reset] [--budget N]` — `--check` prints JSON `{date, reviews_used, budget, exhausted: bool}`; `--consume` increments (with same-day reset) and prints the new state; `--reset` zeros today's counter. Exits: `0` consumed successfully, `1` exhausted (no decrement performed), `2` usage, `5` write failed. Used as guard before every `@greptileai` post. |
| **C-13** ✅ | pm-config section extractor (line-anchored `^## Header` parser) — **extracted in #286** | `pm-okr` Step 2, `pm-update` Step 2, `prioritize` Step 0, `pr-review-help` Step 1a, `pm-handoff` Step 3, `pm-rate-team` Step 2, `pm-sprint-plan` Step 1, `pm-sprint-review` Step 2, `pm-team-standup` Step 2, `pm` Step 1A/1B.1 | 10 skills | ~600 | Deterministic — `awk`/`sed` line-anchor parse | Near-zero | **P1** | `.claude/scripts/pm-config-get.sh --section <name> [--json] [--file <path>]` (+ `--list` to enumerate headers) → stdout: raw section body (headings stripped) or empty if missing. Exits: `0` section present with non-empty body, `1` section missing or body empty, `2` config file missing, `3` usage. `--json` emits `{section, content, present, file}` for structured callers. |
| **C-14** | Reviewer-ownership detection (session-state first → review-history fallback → sticky flag) | `merge` Step 2, `wrap` Step 2.1, `continue` Step 5, `phase-c-merger` init, `status` Step 3 | 4 skills + 1 agent | ~350 | Deterministic given PR state | Low — read-only when `--read`; write to session-state when `--sticky <reviewer>` | **P1** | `reviewer-of.sh <pr_number> [--sticky <cr\|bugbot\|greptile>]` → stdout: one of `cr`, `bugbot`, `greptile`, or `unknown`. Exits: `0` reviewer determined (printed), `1` cannot determine (reviewer unknown printed), `2` usage, `3` PR not found. `--sticky` writes the override into session-state after reading. |
| **C-15** | Bot-comment classifier (finding vs acknowledgment) — the `classify:` jq snippet from `fixpr/audit.sh` | Embedded in `fixpr/audit.sh` Step 6; rule prose describes the contract in `fixpr` SKILL.md Step 5b; no other skill uses it yet but `/wrap` Phase 1 and `/continue` Step 7 reinvent the same logic in English-only form | 1 skill (used) + 2 skills (reinvented) | ~200 direct, ~700 in unified form across bypass call sites | Deterministic (regex) | Low — pure string classifier | **P1** | `classify-bot-comment.sh [--stdin\|--body "<text>"] [--json]` → stdout: `finding` or `acknowledgment` (or JSON `{class, reason}` with `--json`). Exits: `0` classified (class on stdout), `2` usage (no input). This is a pure function — stateless, no `gh` calls. Easy to unit-test. **Note:** C-15 overlaps with C-02 — if C-02 (PR-state) is extracted first, C-15 should be surfaced from the same script rather than extracted separately (export the `classify:` jq as a shared bash function or a second entry point on `pr-state.sh`). Listed here so the P1 follow-up issue references the overlap explicitly and does not duplicate work. |

### P2 — Extract later

| ID | Candidate | Where it lives today | Call sites | Tokens/session (est) | Determinism | Risk | Priority |
|----|-----------|----------------------|------------|---------------------:|-------------|------|:--------:|
| **C-16** | Main-sync helper (uncommitted-changes guard + checkout main + `pull --ff-only` + BEFORE/AFTER SHA reporting) | `merge` Step 5b, `wrap` Step 2.6, `session-start-sync.sh` hook | 2 skills + 1 hook | ~500 | Deterministic | Medium — writes to root repo working tree | **P2** |
| **C-17** | Issue-number extractor from PR body (`Closes #N`/`Fixes #N`/`Resolves #N`) | `wrap` Step 3.1, `standup` Step 3 (linked-issue lookup), `merge` Step 6 work-log pairing | 3 skills | ~150 | Deterministic regex | Near-zero | **P2** |
| **C-18** | Workday / US-holiday calculator (smart lookback) | `standup` SKILL.md lines 30–180 (150 lines of bash including leap-year, observed-date, floating-holiday helpers) | 1 skill | ~2,000 (this is by FAR the biggest single inline block in any SKILL.md) | Deterministic | Medium — date math is the class of code where extraction pays off most, but the call site count is 1 today | **P2** (would be P0 if a second skill needed it; defer until then, but flag this for `/standup` token budget alone) |
| **C-19** | HHG two-ticket state-code extractor | `wrap` Step 3.2 | 1 skill | ~300 | Deterministic (regex against 50 USPS codes) | Near-zero | **P2** |
| **C-20** | Work-log directory detector | `work-log.md` rule, `wrap` Step 5.1, `pm-worker` Work Log Updates, `merge` Step 6 | 1 rule + 3 skills + 1 agent | ~200 | Fully deterministic (find pattern) | Near-zero | **P2** |
| **C-21** | `repo-bootstrap.sh` — ensure `.github/workflows/cr-plan-on-issue.yml` exists + check branch-protection on `main` | `repo-bootstrap.md` rule, `pm-worker` "Repo Bootstrap" | 1 rule + 1 agent | ~250 | Deterministic | Medium — writes workflow file into the target repo; requires user confirmation for branch-protection changes (per rule) | **P2** |
| **C-22** | Off-peak cron-minute selector (`cksum`-hashed per-repo offset, nudged off pile-up minutes 0/5/30/55) | `pm` Step 2.3, memory note `feedback_cron_step_range_truncation.md` | 1 skill + 1 memory | ~200 | Deterministic given repo name | Near-zero | **P2** |

---

## Why these rankings

- **P0 criteria (all four must hold):** (1) ≥3 distinct call sites across skills/agents, (2) ≥500 tokens of duplicated prose/bash per call site, (3) fully deterministic given well-defined inputs, (4) low extraction risk (read-only or idempotent-mutating).
- **P1 criteria:** Meets 3 of 4 P0 criteria. Typically either fewer call sites but heavy per-call-site tokens (e.g., C-12 Greptile budget), or many call sites but lightweight per-call-site cost (e.g., C-13 pm-config parser).
- **P2 criteria:** Deterministic and extractable, but either the call-site count is 1 or the per-call cost is modest. C-18 is the one P2 outlier worth calling out — it's the single biggest inline bash block in the entire codebase (150 lines) but sits in a single skill today; extracting it is a token win for `/standup` alone.

## Bypass call sites — the "hidden" extraction opportunity

Per AC #5, this audit must identify existing scripts that agent call sites bypass. The full bypass map:

1. **`fixpr/audit.sh` is not reused outside `/fixpr`.** Every other skill that needs PR state — `merge`, `wrap`, `continue`, `status`, `phase-b-reviewer`, `phase-c-merger` — calls `gh api` one-liners inline instead of shelling out to `audit.sh`. Promoting this to `.claude/scripts/pr-state.sh` and wiring every bypass site through it is C-02 and the single largest token-saving opportunity in this audit.
2. **`repair-trust-single.sh`, `repair-trust-all.sh`, and `hooks/trust-flag-repair.sh` are three copies of the same logic.** Not strictly a bypass (the hook must run standalone), but the shared core (read-flags, mutate, atomic-write) could live in a single helper that all three source. Deferred — hooks are outside this audit's token-cost scope.
3. **`repair-worktrees.sh` is not called by `/wrap`.** `/wrap` Step 5 reimplements a narrower version (one-worktree remove + branch delete) instead of calling `repair-worktrees.sh --apply` scoped to the just-merged branch. Low-impact bypass because the reimplementation is small; noted for future cleanup.
4. **`pm-data-patterns.md` is a reference doc, not a script.** The "canonical" patterns are still inlined in every PM skill; `pm-data-patterns.md` lists 2 skills as "migrated" (they cite it) but still inline the same bash. This is the state that C-13 + C-07 + C-06 collectively correct — once those three scripts exist, the PM skills can be truly migrated (replace inline bash with a script call) instead of being "migrated" in name only.

## Recommended Extraction Order

1. **C-01 merge-gate** — highest per-call saving; unblocks a cleaner `/merge`, `/wrap`, and `phase-c-merger`.
2. **C-02 pr-state** — promote `fixpr/audit.sh`. Every skill that currently hand-fetches state gets a one-line replacement.
3. **C-04 resolve-review-threads** — closes off the mutating half of the review loop in one helper.
4. **C-06 cycle-count** — feeds into `/merge` and `/wrap` logging plus all four `pm-rate-team`/`pm-sprint-*`/`pm-team-standup` skills.
~~5. **C-05 repo-root** — tiny but ubiquitous. One-off PR worth 20 lines of extraction and touches 10+ call sites.~~ ✅ Done: #278
6. **C-03 cr-plan** — clean win for `/start-issue`, `/subagent`, `pm-worker`.
7. **C-07 gh-window** — unblocks the real migration of the PM skills off inlined date bash.
8. C-08 → C-15 as the P1 batch in whatever order the next sprint tackles them; C-11 + C-12 are natural pairs (both mutate session-state via the same atomic pattern).

## Follow-up issue TODOs (not yet filed)

Per the #271 Exit Criteria, this audit PR is allowed to list follow-up issue titles as TODOs instead of filing them immediately (AC #7 requires the audit + follow-up tracking — filing is deferred to the PM). Each P0 should become its own implementation issue. **Not yet filed** — the PM will open these once the audit merges:

- **P0 — Extract merge-gate verifier (`.claude/scripts/merge-gate.sh`)** — ref #271 C-01
- **P0 — Promote `fixpr/audit.sh` to shared `.claude/scripts/pr-state.sh` and migrate bypass call sites** — ref #271 C-02
- **P0 — Extract `cr-plan.sh` issue plan detector** — ref #271 C-03
- **P0 — Extract `resolve-review-threads.sh`** — ref #271 C-04 — ✅ extracted (#277)
- ~~**P0 — Extract `repo-root.sh` root-worktree resolver** — ref #271 C-05~~ ✅ Done: #278
- **P0 — Extract `cycle-count.sh` review-cycle reconstruction** — ref #271 C-06
- **P0 — Extract `gh-window.sh` GitHub date-window builder** — ref #271 C-07

P1/P2 issues can be filed as they reach top-of-sprint; keeping them as entries in this audit is sufficient for now.

---

## Audit methodology notes

- Every candidate was checked against the actual file content, not memory — call-site counts were produced by grepping the worktree at the SHA above. Token estimates are counted from the prose blocks plus inline bash directly (not LLM tokenizer output); they're accurate to ±25% and are meant for ranking, not for budget forecasting.
- "Deterministic" here means same inputs produce the same outputs *in the absence of GitHub-side state change*. A script that calls `gh api` is still classified deterministic if the response shape is the only variable — the script's logic over that response must be pure.
- "Low risk of extraction" means the script can be tested in isolation with a stable input fixture (saved `gh api` JSON) and its behavior verified without mutating a live PR. C-01, C-02, C-06, C-08, C-13, C-14, C-15, C-17, C-18, C-19, C-20, C-22 all fit this test-first extraction shape.
- The audit deliberately excludes (a) LLM-judgment actions (classifying findings as actionable-vs-outdated, writing memory-worthy lessons, ranking issues by business impact), and (b) procedures that are already more than half-extracted (hooks directory — they don't consume agent tokens even though they duplicate logic).