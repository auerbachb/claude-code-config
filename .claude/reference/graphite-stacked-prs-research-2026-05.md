# Graphite Stacked-PR Workflow — Research & Recommendation (2026-05)

**Status:** RESEARCH — no functional changes proposed in this PR. The deliverable is this report and a list of follow-up issues for the user to triage.

**Issue:** [#418](https://github.com/auerbachb/claude-code-config/issues/418)

**Author:** Claude (claude-opus-4-7-1m)

**Date:** 2026-05-01

---

## Executive Summary

**Recommendation: DEFER**

The CodeRabbit hourly rate-limit budget (8 reviews/hour) is the binding constraint on this repo's coding throughput, and stacked PRs would multiply CR consumption by ~4x for the same code volume on 3-layer stacks. At current adoption levels (zero stacks), the budget is already exhausted at peak hours — `cr-review-hourly.sh --check` reports `8/8` used, `0` remaining as of this writing. Adopting stacks for even 30% of work would cut effective throughput in half. The workload that genuinely benefits from stacking (large multi-component features) is <10% of historical PRs in this repo.

**Top supporting findings:**
1. **CR is the binding constraint.** Today's budget is 8/8 exhausted; 4 of 41 PRs merged in the last 7 days landed in already-saturated hours. We don't have headroom for review-amplifying workflows.
2. **Stacking compounds the cost it's meant to reduce.** Each layer pays its own CR-convergence tax (each fix-push triggers fresh review per `feedback_cr_review_convergence.md`); plus every parent merge force-pushes children, consuming 1 CR slot per child per merge (per `feedback_rebase_exhausts_cr_budget.md`).
3. **The break-even threshold excludes most work.** Of the last 100 merged PRs, only 6 cross the size threshold (>500 lines + >7 files) where stack-driven reviewability gains outpace the multiplied review cost.
4. **Tooling needs ~5 critical surface-area refactors** (`merge-gate.sh`, `fixpr`, `wrap`, `start-issue`, `cr-merge-gate.md`) for an ROI delivered on <10% of work.
5. **`gt` itself works fine** — the blockers are upstream of the CLI, in our review pipeline economics.

**Top tradeoff (one sentence):** Stacks save human/AI review time per layer at the cost of multiplying total CR review-budget consumption per feature, and our binding constraint is review-budget, not review-time.

---

## 1. Rate-Limit Math

### 1.1 Current CR consumption

**Budget:** `CR_HOURLY_BUDGET=8` per `.claude/scripts/cr-review-hourly.sh:49` — rolling 3600s window. Each `git push` to an open PR (initial submit, fix push, or rebase force-push) consumes one slot when CR is configured to auto-review on push.

**Current state (this session, 2026-05-01 17:39 UTC):**

```json
{"reviews_used":8,"budget":8,"remaining":0,"exhausted":true}
```

**Recent merge cadence (last 7 days, from `gh pr list --state merged`):**

| Date       | Merges |
|------------|--------|
| 2026-04-24 | 1      |
| 2026-04-25 | 1      |
| 2026-04-27 | 1      |
| 2026-04-28 | 4      |
| 2026-04-29 | 17     |
| 2026-04-30 | 9      |
| 2026-05-01 | 8 (so far) |

**Peak hour:** 4 merges/hour (well under the 8/hr budget *for merges*, but each PR consumes ~2-3 CR reviews across its lifecycle, so peak *consumption* hours saturate).

**Real CR consumption per PR (from `gh api .../reviews?per_page=100`):**

| PR    | Lines | Files | CR reviews | Notes                          |
|-------|-------|-------|------------|--------------------------------|
| #422  | 721   | 5     | 2          | merge-conflict skill           |
| #401  | 475   | 11    | 2          | polling-state-gate fix         |
| #406  | 449   | 9     | 4          | CR rate limits batching        |
| #393  | 370   | 11    | **10**     | reviewer escalation gate       |
| #357  | 235   | 22    | 2          | merge-gate refactor            |

**Key takeaway:** Median PR consumes 2-3 CR reviews; outliers (#393) consume 10. CR consumption is bounded by convergence behavior (per `feedback_cr_review_convergence.md`), not by code size.

### 1.2 Stacked-PR consumption multiplier

A 3-layer stack for a feature that today ships as 1 PR consumes:

**Initial submission:**
- 3 PRs opened → 3 CR reviews (vs. 1 for flat PR).

**Fix-and-converge per layer:**
- Each layer's review cycle is independent (CR re-reads each layer's diff against its parent).
- Average 1 fix push per layer to satisfy CR (typical case for ~150-line layers).
- 3 layers × 1 fix push each = 3 additional CR reviews.

**Rebase amplification on merge:**
- When layer 1 merges, layers 2 and 3 must rebase (force-push). Each force-push = 1 CR review consumed (per `feedback_rebase_exhausts_cr_budget.md`).
- When layer 2 merges, layer 3 rebases again (or `gt sync` rebases automatically — same push cost).
- Total rebase consumption: 2 (layer 2) + 2 (layer 3) = 4 reviews after parent merges, but only the post-rebase reviews on the *not-yet-merged* layers count: layer 2 = 1, layer 3 = 2 → **3 rebase reviews**.

**Total stacked consumption (3-layer, 1 fix per layer, sequential merge):**

```text
Initial:   3 reviews
Fix loop:  3 reviews
Rebases:   3 reviews
─────────────────────
Total:     9 CR reviews
```

**Total flat consumption (1 PR, 1 fix push):** 2 CR reviews.

**Multiplier: 9 / 2 = 4.5×** for 3-layer stacks. **2-layer multiplier: ~2.5×.**

### 1.3 Adoption-shift projections

Assuming flat-PR baseline of 2.0 CR reviews/PR and stacked baseline of 9 CR reviews per "feature" (3-layer):

| % of work as 3-layer stacks | Effective reviews per logical feature | Throughput vs. today (8/hr budget) |
|-----------------------------|---------------------------------------|------------------------------------|
| 0% (today)                  | 2.0                                   | 4.0 features/hour                  |
| 30%                         | 0.7×2 + 0.3×9 = 4.1                   | 1.95 features/hour (-51%)          |
| 50%                         | 0.5×2 + 0.5×9 = 5.5                   | 1.45 features/hour (-64%)          |
| 70%                         | 0.3×2 + 0.7×9 = 6.9                   | 1.16 features/hour (-71%)          |

**At current 8-review/hour ceiling, 30% adoption already cuts coding throughput in half.**

The math improves at 1.5× multiplier (2-layer stacks with no rebase replay), but the typical "3-layer feature" is exactly the case stack proponents target — and that's the worst case for our budget.

---

## 2. Break-Even Analysis

A stacked workflow pays off when (review-time saved by smaller PRs) > (extra reviewer-budget consumed by more PRs). Since CR consumption per PR is roughly constant regardless of size (CR re-reads the full diff per push, not per line), splitting a 600-line PR into three 200-line PRs **multiplies review consumption without proportionally reducing per-review effort**.

### 2.1 Historical PR size distribution (last 100 merged)

```json
{
  "total": 100,
  "lines_p25": 69,
  "lines_median": 159,
  "lines_p75": 338,
  "lines_p90": 481,
  "lines_max": 1094,

  "files_median": 4,
  "files_p75": 7,
  "files_p90": 11,
  "files_max": 33
}
```

**Of 100 recent PRs:**
- 85 are ≤ 480 lines (p90 cutoff) — too small to justify splitting; one PR is fine.
- 15 are 300-749 lines (p75-p99 range) — splittable in theory; mostly already focused on one file/feature.
- 6 are >480 lines AND >7 files — the realistic "stack candidate" set.

**100% of the last 100 PRs targeted `main` directly (zero current stack adoption).**

### 2.2 Where stacking pays off

Stacking is genuinely useful when *all* of these are true:

1. **>500 lines changed, across ≥4 files** — small-file changes don't slow human reviewers enough to matter.
2. **At least one natural seam where layer N is independently mergeable** without layer N+1 (e.g., schema migration → backend logic → frontend UI).
3. **Each layer is independently testable** — partial-stack merges leave the codebase in a working state.
4. **Layers ship in sequence, not in parallel** (parallel layers merge as separate PRs anyway, no stack needed).

**Scoring last 100 PRs against this:** 6 candidates max, of which (eyeballing the list) maybe 3 had natural multi-layer seams (#385 telemetry — could split data-collection vs. analysis; #377 audit doc — already monolithic by nature; #422 merge-conflict skill — single coherent feature).

**Realistic ROI footprint: 3-5% of historical work.**

### 2.3 Why CR consumption is roughly constant per PR

Per `feedback_cr_review_convergence.md`: "Each new fix commit triggers fresh line-by-line scrutiny of the *new* code. CR isn't just verifying old findings; it re-reads the entire diff on each new HEAD." This means:
- A 100-line PR and a 500-line PR consume similar review counts to converge.
- Splitting one 500-line PR into three 167-line PRs ≈ triples consumption.

The asymmetry kills the math: smaller PRs save *human* review time but cost *reviewer-budget* the same.

---

## 3. Tooling Evaluation

### 3.1 `gt` CLI sandbox test (~10 min)

Tested in `/tmp/gt-sandbox-test` (init → 2-layer stack → log → cleanup):

```bash
$ gt init --trunk main
Welcome to Graphite!
Trunk set to main

$ gt create -m "feat: layer 1"     # branch: 05-01-feat_layer_1
$ gt create -m "feat: layer 2..."  # branch: 05-01-feat_layer_2_depends_on_layer_1_

$ gt log
◉ 05-01-feat_layer_2_depends_on_layer_1_ (current)
│ a17f356 - feat: layer 2 (depends on layer 1)
◯ 05-01-feat_layer_1
│ cf16f9e - feat: layer 1
◯ main
│ 0a24da0 - init
```

**Findings:**
- ✅ `gt init` succeeds without auth (sandbox).
- ✅ `gt create` produces correctly-parented branches with date-prefixed auto-names.
- ❌ **Branch names violate our rule:** auto-generated `MM-DD-feat_layer_N` does not contain the issue number. Our `CLAUDE.md` mandates `issue-N-*` and the `stale-worktree-warn.sh` hook warns when the branch doesn't match the task issue. `gt create` would need either `--name issue-418-layer-1` (manual) or a wrapper script.

**Not tested (skipped to stay within 30-min time budget):**
- `gt submit` (requires Graphite auth token + would create real PRs).
- `gt sync` after parent merge (requires merged PR in sandbox).
- Whether `gt sync` preserves child review threads after rebase.

The not-tested paths are the riskiest ones, and that's noted as a remaining unknown.

### 3.2 Integration with our scripts

Audit of branch/base assumptions in our tooling:

| File / Script | Assumption | Stack-compatible? |
|---|---|---|
| `merge-gate.sh:165` | reads `baseRefName` from `gh pr view` | ✅ Yes — uses dynamic base |
| `merge-gate.sh:326` | "branch is BEHIND base" message | ✅ Generic enough |
| `dirty-main-guard.sh` | hardcoded `origin/main` | ✅ Operates on root repo's main only — orthogonal |
| `main-sync.sh` | hardcoded `origin/main` | ✅ Used for root-main sync, not PR base |
| `fixpr/SKILL.md:532-534` | `git rebase origin/main` for BEHIND/CONFLICTING | ❌ **Wrong for stacked PRs** — should rebase onto parent, not main |
| `wrap/SKILL.md:155, 162` | `gh pr merge --squash` + reset main to origin/main | ❌ **Wrong for non-trunk PRs** — squash-merging a layer-2 PR onto layer-1 then walking up the stack needs different handling |
| `start-issue/SKILL.md` | one issue → one branch → one PR | ❌ Mental model mismatch — a stack is one issue → multiple branches → multiple PRs |
| `cr-merge-gate.md` | "current HEAD" assumes single PR per work unit | ⚠️ Partially — needs per-layer gate semantics |
| `cr-github-review.md` | per-cycle 60s polling per PR | ⚠️ 3 PRs in stack = 3× polling, no logic change but state explosion |
| `cr-review-hourly.sh` | tracks pushes globally | ⚠️ No issue, but doesn't distinguish "rebase amplification" pushes |

**Required code changes for safe stack adoption (estimated):**
- New `--base <ref>` flag on `fixpr` rebase paths.
- New "stack-aware" merge orchestration in `/wrap` (walk up layers; squash-merge into next-layer's base, not main).
- `start-issue` opt-in `--stack` mode.
- New `gt`-aware branch naming wrapper or relaxation of `issue-N-*` rule.
- Stack-tracking handoff state (parent SHA, child PRs).

**Estimated implementation cost:** 6-10 PRs across 5 critical files. For a workflow that delivers ROI on 3-5% of work.

### 3.3 Existing `graphite` plugin skill

The user already has a `graphite` skill installed (via `claude-code-graphite` marketplace, see `~/.claude/plugins/marketplaces/claude-code-graphite/plugins/graphite/skills/graphite/SKILL.md`). It:
- Detects `.git/.graphite_repo_config` and routes user-facing commit/push commands to `gt`.
- Defaults to **user-driven** (the user types "make this a stack", not the agent autonomously deciding).
- Doesn't override our `phase-a-fixer` / `phase-b-reviewer` / `phase-c-merger` automation.
- Recommends each layer be "atomic, ideally under 250 lines, focused, reviewable independently."

**This means stacked workflow is already available on demand.** What the original strawman in #418 proposes is *automating* it (Phase A on layer N+1 in parallel with Phase B on layer N). That's the part that needs the math to work.

---

## 4. Concurrency Cost

The strawman in #418 proposes parallel Phase A (layer N+1) + Phase B (layer N). Here's what that actually costs:

### 4.1 Subagent slot saturation

`subagent-orchestration.md`: "Keep 3-4 active CR-polled PRs max; at 7+ CR reviews/hour expect Greptile fallback."

A 3-layer stack uses 3 of those 4 slots immediately. Adding even one independent flat PR pushes us to 4/4. This is workable for a single-feature session but breaks down when:
- The user runs `/pm` and triggers 2+ subagent threads concurrently.
- Multiple stacks are in flight (each consuming 3 slots).

### 4.2 Token cost

Each subagent has a 32K output-token limit (per `subagent-orchestration.md`). Running Phase A + Phase B on different layers concurrently:
- Phase A (heaviest): ~15K-25K output (fix code + commit + push + reply to threads).
- Phase B (lighter): ~5K-15K output (poll + verify + handoff update).
- Concurrent total: ~30-40K output per pass.

Doesn't break individual agent budgets, but triples the parent monitor-mode polling load and the `cr-review-hourly.sh` race conditions (already noted as a flock-less race risk on macOS).

### 4.3 Cache budget conflict with `scheduling-reliability.md`

Per that file: parent agent should keep cache warm with sub-300s wakeups. With 3 stacked PRs each on 60s polling, the parent's per-cycle work triples, increasing the chance of slow ticks that miss the 5-minute cache TTL.

**Net: orchestration is technically capable but operationally fragile** — it pushes us close to several existing limits that today have comfortable headroom.

---

## 5. Recommended Criteria

If we adopt stacked PRs anyway (against this report's recommendation), the criteria below are the tightest defensible bounds.

### When to stack (all must hold)

1. **Issue size estimate ≥500 lines AND ≥4 files.** Below this, splitting just adds review overhead.
2. **At least one natural seam** where layer N is shippable without layer N+1.
3. **Each layer is independently CI-passing.** No broken intermediate states.
4. **User explicit opt-in.** The agent never autonomously decides to stack — the user types "use a stack" or invokes a `--stack` flag. This protects the CR budget from agent-side mistakes.
5. **Maximum 3 layers.** A 4-layer stack with one rebase cycle per layer = 16 CR reviews against an 8/hour ceiling; one feature would exhaust the entire hour.
6. **Stack must not span more than 2 sessions.** Stale rebases multiply consumption.

### When NOT to stack (any one disqualifies)

1. PR fits comfortably in one ≤400-line submission.
2. CR budget is at or near exhaustion (`cr-review-hourly.sh --check` shows `remaining ≤ 3`).
3. Two or more other active PRs are already in CR-polling phase.
4. Layers are not naturally separable (artificial splits double cost without gain).
5. Strong time pressure to merge (stacks have higher tail-latency due to rebase amplification).

### Heuristic vs. opt-in

**Opt-in is the right gate.** A heuristic ("if estimated >500 lines, stack it") would route some PRs to stack mode where the user would have preferred a flat single PR. The cost of a wrong heuristic decision is high (multiplied CR consumption) and the user has better information than the agent about when seams exist.

---

## 6. Show-Stoppers

### 6.1 Hard blockers (would need to be resolved before any pilot)

1. **CR budget headroom.** Current state: 8/8 exhausted at 1pm ET on a normal Friday. We have no slack. Would need either:
   - Tier upgrade with CodeRabbit (likely paid; needs business decision).
   - Primary-reviewer migration (CR → BugBot/CodeAnt/Greptile primary). BugBot is per-seat and has no per-call cost — could absorb stack amplification — but `feedback_bugbot_auto_trigger_unreliable.md` documents reliability gaps and `feedback_bugbot_commit_id_stale.md` documents merge-gate false-positive risks.

2. **Branch naming rule conflict.** `CLAUDE.md` requires `issue-N-*`; `gt create` produces `MM-DD-msg_slug`. Either relax the rule (loses worktree-warn signal) or wrap `gt create` in a script that injects `issue-N-` prefix (small lift, but new code path).

3. **`fixpr` rebase target.** Currently rebases onto `origin/main` unconditionally. For non-trunk-rooted layers, this corrupts the stack. Would need `--base <ref>` flag or `gt restack` invocation in the BEHIND/CONFLICTING handlers.

4. **`/wrap` merge orchestration.** Currently merges into main and resets root main to `origin/main`. For layer-1 PRs that's correct; for layer-2/3 it's wrong (layer-2 should merge into layer-1 base, then layer-1 unblocks once all children land, then squash-merge stack-tip into main).

### 6.2 Soft issues (would need attention but aren't blockers)

1. **Handoff file schema.** `~/.claude/handoffs/pr-{N}-handoff.json` is per-PR; a stack needs cross-PR linkage (parent SHA, sibling state). Not a blocker — could add `stack: { parent_pr, child_pr }` fields without breaking existing clients (per `feedback_*_handoff_files.md` forward-compat rules).

2. **Phase orchestration parallelism.** `phase-protocols.md` is sequential per PR; concurrent layer-N Phase A + layer-N-1 Phase B works but isn't tested. Could lead to handoff race conditions.

3. **`merge-gate.sh` per-layer semantics.** Currently treats single PR; for stacks needs to gate on whole-stack health (any child blocking blocks the parent's merge readiness, since merging parent invalidates children's reviews).

4. **`stale-worktree-warn.sh` hook.** Compares branch name to task issue number; would warn on every layer of an `issue-418-layer-2` style stack. Minor adjustment.

### 6.3 Not show-stoppers

- `merge-gate.sh` already reads `baseRefName` dynamically.
- `cr-review-hourly.sh` already tracks pushes correctly (it just won't be enough headroom).
- The `graphite` plugin skill already exists and provides the user-facing primitives.
- `gt` itself works as advertised in the sandbox.

---

## Recommendation

**DEFER.**

**Rationale:**
1. The CR rate-limit budget is the binding constraint on this repo's coding throughput. Any review-amplifying workflow at current adoption levels worsens the bottleneck we're already hitting.
2. The set of historical PRs where stacking would clearly pay off (>500 lines + multi-component + naturally separable) is 3-5% of work. Building tooling for that ROI footprint, when ~6-10 PRs of integration work would be needed, isn't justified.
3. The existing `graphite` skill (already installed) gives the user the option for explicit-opt-in stacking today. We don't need to automate it to get value from it.
4. Re-evaluate when one of these changes:
   - CR budget materially increases (tier upgrade or primary-reviewer migration to BugBot/Greptile).
   - We start regularly producing 500+ line PRs (current p90 = 481 lines, so we're close — but most of the >480 PRs are intentionally monolithic, e.g., audit docs, schema migrations).
   - The `feedback_cr_review_convergence.md` issue is solved (CR converges in 1 round, eliminating per-layer fix-push tax).

**Alternative if user prefers ADOPT-WITH-LIMITS:**
- Pilot mode: opt-in only, max 3 layers, max one stack in flight at a time, max 6 CR reviews used in the session before opening a stack.
- Implement only the smallest possible patch: `fixpr --base <ref>`, `/wrap` no-op when PR is non-trunk-rooted (defer to user-driven `gt sync`), `start-issue --stack` flag.
- Skip automating Phase A on layer N+1 + Phase B on layer N; let the user trigger each layer manually.
- Re-evaluate after 5 stacks (probably 1-2 months given the eligibility criteria).

That alternative is defensible — it caps the downside while keeping the option open. But it's still implementation cost for marginal benefit, and that's why the primary recommendation remains DEFER.

---

## Proposed Child Issues

If the user, after reviewing this report, decides to pursue any subset, these are the natural follow-up units. **Do not open these without explicit user approval — list them here for triage.**

1. **CR budget tier-upgrade research / primary-reviewer migration plan**
   Before any stack adoption, resolve the CR-budget bottleneck. Options: upgrade CR tier, migrate primary review to BugBot (per-seat, no per-call cost), or split review duties so CR only reviews a tagged subset of PRs. Output: a recommendation with cost estimates.

2. **`fixpr` `--base <ref>` flag for non-trunk-rooted PRs**
   Currently hardcodes `git rebase origin/main`. Add `--base` flag that defaults to `origin/main` but accepts a parent branch. Update `BEHIND`/`CONFLICTING` rebase paths in `fixpr/SKILL.md`. Required regardless of whether we adopt stacks — also unlocks rebase-onto-feature-branch for non-stack scenarios.

3. **`/wrap` stack-aware merge mode**
   When the merging PR has a non-`main` base, skip the root-main reset and report "stack layer merged — re-run /wrap on parent layer to continue." Don't try to merge the whole stack atomically.

4. **`start-issue --stack` opt-in mode**
   Branch naming wrapper that injects `issue-N-layer-K` prefix when `gt create` is invoked, plus a planning prompt that asks the user to enumerate layers before code starts.

5. **Handoff file `stack` extension**
   Add optional `stack: { parent_pr_number, child_pr_numbers, layer_index }` fields to `~/.claude/handoffs/pr-{N}-handoff.json`. Document forward-compat behavior. No-op when absent.

6. **CR-budget gate on stack creation**
   Require `cr-review-hourly.sh --check` to report `remaining >= 6` before allowing a new stack to be opened. Block at lower thresholds with a clear message.

7. **Stale-worktree-warn relaxation for stacks**
   Update `stale-worktree-warn.sh` to accept `issue-N-layer-K` patterns when an explicit stack flag is set in session state.

8. **Documentation: when to use stacks**
   Add a short note to `CLAUDE.md` or `issue-planning.md` pointing to the existing `graphite` skill and listing the criteria from §5 of this report. Cheapest possible deliverable; even on a DEFER decision this is worth doing so users know the option exists.

9. **Long-running pilot tracking**
   If the user picks ADOPT-WITH-LIMITS, instrument the next 5 stacks: capture pre-stack `cr-review-hourly.sh --check`, count actual CR reviews consumed, count rebase cycles, and write a follow-up report. Decide after pilot whether to commit to or roll back the workflow.

---

## Appendix A: Data sources

- `gh pr list --state merged --limit 100 --json ...` — PR size distribution.
- `gh api repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100` — per-PR CR review counts.
- `.claude/scripts/cr-review-hourly.sh --check` — current budget snapshot.
- `.claude/scripts/cycle-count.sh <pr>` — review/fix cycle counts.
- Memory: `feedback_cr_review_convergence.md`, `feedback_cr_reviews_paused.md`, `feedback_rebase_exhausts_cr_budget.md`, `feedback_rebase_race_parallel_extractions.md`.
- `gt --version` 1.8.5 (sandbox tested).
- `~/.claude/plugins/marketplaces/claude-code-graphite/plugins/graphite/skills/graphite/SKILL.md` — existing graphite skill documentation.

## Appendix B: Remaining unknowns (gt sandbox time-budget)

These were not verified within the 30-minute test budget; assumptions noted:

- `gt submit` PR-base behavior — *assumed* correct from CLI docs ("submits each branch to GitHub, creating distinct pull requests for each").
- `gt sync` thread-preservation after parent merge — *assumed* GitHub-side preservation since `gt sync` is a force-push operation and review threads persist across force-pushes in GitHub's UI; but `commit_id` would update, which interacts with our SHA-freshness rules in `cr-merge-gate.md`.
- Concurrency of `gt sync` with our parent agent's polling — untested.

If any pilot moves forward, the first action should be a real-PR sandbox test of these three behaviors against this repo's CR/CodeAnt/BugBot configuration.
