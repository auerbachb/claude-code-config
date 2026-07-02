# Instruction-Set Size & Optimization Audit — July 2026

**Issue:** [#462](https://github.com/auerbachb/claude-code-config/issues/462) (1-month re-check after #443 recalibration)

**Date:** 2026-07-02

**Related precedent:** [#443](https://github.com/auerbachb/claude-code-config/issues/443) / PR [#463](https://github.com/auerbachb/claude-code-config/pull/463) (June 2026 recalibration), [#461](https://github.com/auerbachb/claude-code-config/issues/461) / PR [#474](https://github.com/auerbachb/claude-code-config/pull/474) (double-loading fix), [repo-audit-2026-05.md](repo-audit-2026-05.md), [harness-model-audit-2026-06.md](harness-model-audit-2026-06.md)

---

## Executive summary

### Verdict: **KEEP**

Keep the current caps (soft **12,000** / hard **13,000** / ratchet **+750** / per-file warn **2,000**) and the existing file division. No cap raise, no emergency cut in this cycle.

**Rationale:**

1. **Corpus is healthy.** 11,453 words — 547 words under the soft cap, 1,547 under the hard cap, ~1.5% of a 1M-token window.
2. **1M-window economics unchanged.** Opus 4.8 / Fable 5 / Sonnet 5 still ship 1M context at flat standard pricing; cached rule load is ~$0.008/turn on Opus 4.8 (~15K tokens × $0.50/MTok cache hit).
3. **Budget exists for adherence, not context pressure** — the #443 rationale still holds; redundant/contradictory rules misfire harder on literal-following models.
4. **Per-file balance is fine.** Largest file is `cr-github-review.md` at 1,628 words (812 below the 2,000-word warning).
5. **Double-loading is fixed.** #461 resolved via project-local `claudeMdExcludes`; effective in-context rule size in this repo is a single ~15K-token copy (was ~30K).
6. **Ratchet headroom is tightening.** Only **239 words** remain before the committed ratchet cap (11,692). At the observed ~741 words/month growth rate, the ratchet will bind before the soft cap unless a cut pass or `--update-cap` after intentional reduction. Monitor; no cut mandated this cycle because corpus is still under soft limit and recent additions were purposeful feature rules (wrap/fixpr delegation, thread-resolution helper, quota authority).

### Top actionable findings

| # | Finding | Severity | Action |
|---|---------|----------|--------|
| 1 | Ratchet headroom low (239w) vs soft headroom (547w) | Medium | Track; schedule cut pass if growth continues without reduction |
| 2 | Thread-resolution guidance drift | Low | Align `cr-merge-gate.md` + `bugbot.md` with `resolve-review-threads.sh` mandate in `cr-github-review.md` |
| 3 | `trust-dialog-fix.md` + `repo-bootstrap.md` → skills | Low | Continue defer from #443; revisit when ratchet binds |
| 4 | Sonnet alias drift (Sonnet 5 vs Sonnet 4.6) | Info | Partially addressed in #510; harness-model audit FU items still apply |

---

## 1. Corpus measurement

**Command (canonical):**

```bash
{ cat CLAUDE.md; find .claude/rules -name '*.md' -exec cat {} +; } | wc -w
```

**Result (2026-07-02):** **11,453 words**

| Metric | Value |
|--------|------:|
| Post-#443 baseline (PR #463, 2026-06-11) | 10,934 |
| Delta | **+519 words (+4.7%)** |
| Elapsed | ~21 days |
| Implied run rate | ~741 words/month |
| Soft limit (12,000) headroom | 547 words |
| Hard limit (13,000) headroom | 1,547 words |
| Ratchet cap (`.budget-soft-cap`) | 11,692 |
| Ratchet headroom | **239 words** |
| `rule-lint.sh` | **PASS** |

**Growth drivers since #443** (by commit, net +519w):

| PR / theme | Approx. impact | Files touched |
|------------|----------------|---------------|
| #474 double-loading cross-refs | +~15w | `skill-symlinks.md`, `trust-dialog-fix.md` |
| #487 / #455 wrap↔fixpr delegation | +~140w | `phase-protocols.md`, `subagent-orchestration.md`, `cr-merge-gate.md` |
| #489 thread-resolution helper mandate | +~25w | `cr-github-review.md` |
| #506 quota/spend authority | +~35w | `safety.md` |
| #449 issue-maker capture mode | +~30w | `issue-planning.md` |
| #468 CLI-first defaults | +~5w | `repo-bootstrap.md` |
| #465 coderabbit `--agent` flag | ~neutral | `cr-local-review.md` |
| #510 model lineup refresh | ~neutral | `CLAUDE.md`, `subagent-orchestration.md` |

Growth is **feature-driven**, not drift or duplication bloat. The ratchet cap was not re-anchored (`--update-cap` runs only after intentional cuts), so organic growth consumed ~511 of the original 750-word ratchet headroom.

---

## 2. Cap validation vs current model fleet

**Sources:** [Anthropic pricing docs](https://platform.claude.com/docs/en/about-claude/pricing) (2026-07), [1M context GA blog](https://www.claude.com/blog/1m-context-ga) (2026-03-13), [Opus 4.8 product page](https://www.anthropic.com/claude/opus) (2026-05-28).

| Model | Context | Input $/MTok | Cache hit $/MTok | Notes |
|-------|---------|-------------:|-----------------:|-------|
| Opus 4.8 | 1M | $5.00 | $0.50 | Primary harness model |
| Fable 5 | 1M | $10.00 | $1.00 | Listed in CLAUDE.md fleet |
| Sonnet 5 | 1M | $3.00 | $0.30 | Alias `sonnet` per #510 |
| Sonnet 4.6 | 1M | $3.00 | $0.30 | Still valid; Sonnet 5 supersedes in selection policy |
| Haiku 4.5 | 200K | $1.00 | $0.10 | Subagent light tier |

**Corpus economics (Opus 4.8, ~15.2K tokens):**

| Scenario | Cost per turn |
|----------|-------------:|
| Cache hit (0.1× input) | ~$0.0076 |
| 5-min cache write (1.25×) | ~$0.095 |
| No cache (full input) | ~$0.076 |

**Assessment:** The #443 recalibration (soft 12K / hard 13K) remains appropriate. Raising caps would not improve economics materially (corpus is ~1.5% of window; cache hits are already ~90% off). Tightening caps is unnecessary while corpus stays under soft limit and per-file sizes are balanced.

**Fleet delta since #443:** Sonnet 4.6 → Sonnet 5 in selection aliases (#510). Context window and pricing tier unchanged. No cap adjustment warranted.

---

## 3. Per-file balance

| File | Words | vs 2,000 warn | vs #443 baseline | Verdict |
|------|------:|--------------:|-----------------:|---------|
| `cr-github-review.md` | 1,628 | OK (−372) | +35 | **KEEP** |
| `cr-merge-gate.md` | 1,432 | OK (−568) | +21 | **KEEP** |
| `CLAUDE.md` | 1,156 | OK | ~0 | **KEEP** |
| `subagent-orchestration.md` | 787 | OK | +57 | **KEEP** |
| `phase-protocols.md` | 801 | OK | +139 | **KEEP** — wrap/fixpr delegation |
| `greptile.md` | 636 | OK | ~0 | **KEEP** |
| `monitor-mode.md` | 585 | OK | ~0 | **KEEP** |
| `safety.md` | 535 | OK | +39 | **KEEP** — quota authority |
| `scheduling-reliability.md` | 504 | OK | ~0 | **KEEP** |
| `skill-symlinks.md` | 501 | OK | +2 | **KEEP** |
| `bugbot.md` | 499 | OK | ~0 | **KEEP** |
| `issue-planning.md` | 487 | OK | +86 | **KEEP** |
| `main-hygiene.md` | 443 | OK | ~0 | **KEEP** |
| `repo-bootstrap.md` | 426 | OK | +17 | **KEEP** — skill candidate deferred |
| `cr-local-review.md` | 398 | OK | ~0 | **KEEP** |
| `handoff-files.md` | 383 | OK | ~0 | **KEEP** |
| `trust-dialog-fix.md` | 252 | OK | +36 | **KEEP** — skill candidate deferred |
| **Total** | **11,453** | — | **+519** | — |

No file near or over the 2,000-word per-file warning. No splits required this cycle.

---

## 4. Division sanity (overlap / duplication / contradictions)

Spot-check prioritized newest/most-edited files since #443.

### Intentional cross-references (OK)

- **`phase-protocols.md` ↔ `subagent-orchestration.md`:** wrap/fixpr delegation contract appears in both; phase-protocols owns the machine-token contract, subagent-orchestration owns Phase C behavioral note. Intentional, not duplicate prose.
- **`skill-symlinks.md` ↔ `trust-dialog-fix.md`:** double-loading note cross-refs `double-loading-fix.md`; trust content unchanged.
- **`cr-github-review.md` ↔ `cr-merge-gate.md`:** merge gate remains canonical in `cr-merge-gate.md`; review loop references it. Correct boundary.

### Drift found (file follow-up)

| Topic | Canonical home | Stale references | Risk |
|-------|----------------|------------------|------|
| Thread resolution | `cr-github-review.md` — **must use** `resolve-review-threads.sh`; never inline `resolveReviewThread` (#489) | `cr-merge-gate.md` line 80 still says "Reply + `resolveReviewThread`"; `bugbot.md` line 42 still lists inline mutations | Low adherence risk — literal models may use deprecated inline pattern |

No contradictions found in merge gate semantics, autonomy table, or safety prohibitions.

### Deferred from #443 (unchanged)

- **`trust-dialog-fix.md` + `repo-bootstrap.md` → skills:** still low ROI vs adherence-regression risk; both under 500 words; defer until ratchet binds or a dedicated skill-authoring sprint.
- **Consolidate 6 review-chain files into one `review-chain.md`:** still rejected — would exceed 2,000-word per-file limit.

---

## 5. #461 double-loading status

**Status: RESOLVED** (PR #474, merged 2026-06-25)

| Metric | Before #461 | After #474 |
|--------|------------:|-----------:|
| Copies loaded in this repo | 2 (global skills-worktree + project) | 1 (project only) |
| Effective rule tokens/session | ~30K | ~15K |
| Version skew mid-PR | Yes (main-pinned global vs branch project) | No |
| Mechanism | — | `claudeMdExcludes` in `.claude/settings.json` |
| Documentation | — | `.claude/reference/double-loading-fix.md` |

**Effective in-context rule size (this repo, post-fix):** 11,453 words ≈ **~15.2K tokens**, single copy, project scope (branch-accurate).

**Caveat (documented in reference):** brand-new never-trusted worktrees may double-load on the very first turn until trust flags are repaired — transient, self-healing.

---

## 6. Verdict detail

| Option | Decision | Why |
|--------|----------|-----|
| **Keep** | **YES** | Corpus under soft cap; per-file balance good; caps validated against 1M fleet; double-loading fixed; growth is purposeful |
| **Raise** | No | No context or cost pressure; raising would weaken the adherence/maintainability guardrail without benefit |
| **Cut** | No (this cycle) | No emergency; no file over 2,000w; no obvious full-removal wins. Ratchet pressure warrants monitoring, not an emergency trim |

**Next re-check:** ~2026-08-11 (1 month). Sooner if ratchet cap binds (239w headroom at current growth ≈ ~10 days to cap at present run rate, though soft limit allows 547w more).

---

## Follow-up issues filed

- [#519](https://github.com/auerbachb/claude-code-config/issues/519) — ratchet headroom monitoring; bundled cut pass before cap binds
- [#520](https://github.com/auerbachb/claude-code-config/issues/520) — align thread-resolution guidance (`cr-merge-gate.md`, `bugbot.md` → `resolve-review-threads.sh`)

---

## Verification commands

```bash
# Corpus count
{ cat CLAUDE.md; find .claude/rules -name '*.md' -exec cat {} +; } | wc -w

# Lint
bash .github/scripts/rule-lint.sh

# Per-file breakdown
wc -w CLAUDE.md .claude/rules/*.md | sort -n

# Double-loading settings
cat .claude/settings.json

# Thread-resolution drift check
rg 'resolveReviewThread|resolve-review-threads' .claude/rules/
```
