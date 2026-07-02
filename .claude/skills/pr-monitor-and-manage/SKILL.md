---
name: pr-monitor-and-manage
description: Thread-level PR fleet manager. Rediscovers your open PRs every tick, prints a status table, and auto-dispatches the per-PR decision tree (rebase / parallel phase-a-fixer / sequential /wrap) until the fleet is clean or hard-blocked. Triggers on "/pr-monitor-and-manage", "/pmm", "manage PRs", "PR fleet", "watch PRs".
triggers:
  - pr-monitor-and-manage
  - pmm
  - manage PRs
  - PR fleet
  - watch PRs
  - manage my open PRs
argument-hint: "[--author <login>] [--repo <owner/repo>] [--cadence Nm] [--max-parallel N] (defaults: author=current gh user, repo=current, cadence=5m, max-parallel=3)"
---

Thread-level **PR fleet manager**. This skill turns the current thread into a dedicated monitor that watches every open PR you own and drives each one to merge-ready (or a named hard block) by dispatching the per-PR decision tree on a recurring cadence. Fix work (`has-recoverable-blockers` / verdict `fixpr`) is handled by **parallel `phase-a-fixer` subagents** (default cap 3, `--max-parallel N`). Merge-ready PRs get **sequential `/wrap`** dispatch only.

> **Per-PR dispatch is inlined below.** `TODO: refactor to call /babysit-pr per discovered PR after #456 lands.` Until #456 merges, Step 3's decision tree is the single owner of per-PR logic. When `/babysit-pr` exists, replace Step 3's inline branches with one `/babysit-pr <PR>` dispatch per discovered PR — the table, discovery, idempotency, and backoff scaffolding here stay unchanged.

This is a **set-and-monitor** command. Once invoked it acknowledges the mode, establishes a `/loop`, and at every tick reprints the fleet table and acts. It never writes feature code and never drifts into unrelated work.

---

## Step 0: Enter PR-fleet-manager mode (MANDATORY, first tick only)

On the **first** invocation in a thread, acknowledge the mode up front so the constraints are explicit and survive context compaction:

> **PR-fleet-manager mode active.** My only job in this thread is to watch and manage your open PRs as a fleet — rediscover them each tick, print a status table, and dispatch rebase / parallel `phase-a-fixer` subagents (fix work) / sequential `/wrap` (merge-ready) per the decision tree. I will not write feature code, start issues, or do unrelated work here.

**Prohibited in this thread (refuse and redirect):**

- Writing or editing **feature code** of any kind.
- Invoking `/start-issue`, `/prompt`, or spawning coding subagents for new work.
- Creating issues or PRs (other than the follow-ups `/wrap` itself creates on merge).
- Any task unrelated to managing the discovered PR fleet.

**Refusal template** when asked for a prohibited activity:

> That's outside PR-fleet-manager mode. I'm keeping this thread focused on monitoring your open PRs. Start a separate thread (e.g. `/start-issue`) for that work — say `/pmm-stop` first if you want me to stop monitoring here.

This skill is read-only with respect to source: the only writes it performs are git rebase/force-push (Step 5a), and the bounded mutations that `phase-a-fixer` subagents and `/wrap` already own. Fix work is delegated to parallel `phase-a-fixer` subagents (`.claude/agents/phase-a-fixer.md`); merge work stays sequential via `/wrap`. The parent never reimplements fix/merge logic.

---

## Step 1: Parse arguments + identify the fleet (every tick)

Parse `$ARGUMENTS` (re-parse every tick — a `/loop` re-invocation passes the same args, but treat them as the source of truth, never a cached value):

- `--author <login>` — whose PRs to manage. **Default:** the current authenticated user via `gh api user --jq .login`.
- `--repo <owner/repo>` — which repo. **Default:** the current repo.
- `--cadence Nm` — base poll interval. **Default:** `5m`.
- `--max-parallel N` — max concurrent `phase-a-fixer` subagents for fix work. **Default:** `3`. Excess PRs needing fixes wait for a slot to free on a subsequent tick.

> **`--repo` constraint (load-bearing).** `--repo` scopes **discovery** (`gh pr list`) and the GraphQL/REST reads. But the per-PR helpers (`merge-gate.sh`, `pr-issue-ref.sh`, `cr-review-hourly.sh`, `dismiss-stale-bot-changes.sh`) and all git actions (rebase, force-push, fix subagents, `/wrap`) operate on the **current checkout** — they resolve the repo via `gh repo view`, not a flag. So managing a repo requires running this skill from a worktree of **that** repo. If `--repo` names a repo other than the current checkout, **stop and reconcile** (same multi-repo hazard guard as `cr-github-review.md`) rather than acting against the wrong repo.

```bash
# Defaults
PMM_AUTHOR=""; PMM_REPO=""; PMM_CADENCE="5m"; PMM_MAX_PARALLEL=3
# (parse $ARGUMENTS into the four vars above; bare flags override defaults)

if [ -z "$PMM_AUTHOR" ]; then
  PMM_AUTHOR=$(gh api user --jq .login 2>/dev/null || true)
  if [ -z "$PMM_AUTHOR" ]; then
    echo "WARNING: gh api user failed — pass --author <login> explicitly"; exit 1
  fi
fi

# Current checkout is the source of truth for per-PR actions.
CURRENT_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
OWNER_REPO="${PMM_REPO:-$CURRENT_REPO}"
if [ -n "$PMM_REPO" ] && [ "$PMM_REPO" != "$CURRENT_REPO" ]; then
  echo "[PMM] STOP: --repo $PMM_REPO != current checkout $CURRENT_REPO. Per-PR actions"
  echo "      (rebase, fix subagents, /wrap) run against the checkout. Re-run from a worktree of"
  echo "      $PMM_REPO, or drop --repo to manage $CURRENT_REPO."; exit 1
fi
OWNER="${OWNER_REPO%/*}"; REPO="${OWNER_REPO#*/}"
REPO_FLAG=(--repo "$OWNER_REPO")   # explicit so discovery + reads always agree
echo "[PMM] fleet = author:$PMM_AUTHOR repo:$OWNER_REPO cadence:$PMM_CADENCE max-parallel:$PMM_MAX_PARALLEL"
```

---

## Step 2: Discover open PRs (every tick — NEVER cache across ticks)

**Rediscover the fleet on every single tick.** A PR may have merged, closed, or been opened since the last tick — a cached list silently rots. Always re-run `gh pr list`:

```bash
PMM_LIMIT=500   # high cap so a real fleet is never silently truncated
PR_LIST=$(gh pr list --state open --author "$PMM_AUTHOR" "${REPO_FLAG[@]}" \
  --json number,title,headRefName,mergeStateStatus,reviewDecision --limit "$PMM_LIMIT")
PR_NUMS=$(jq -r '.[].number' <<<"$PR_LIST")
PR_COUNT=$(jq 'length' <<<"$PR_LIST")
```

> **No silent truncation.** `gh pr list` caps results at `--limit`; with `--author` it goes through the Search API (hard ceiling ~1000). Use a high `--limit` (500 above) and **warn** when the fleet hits it: if `PR_COUNT == PMM_LIMIT`, print "Showing $PMM_LIMIT PRs — fleet may be larger; results may be incomplete" and, if you genuinely expect >500 open PRs for one author, page via `gh api`/GraphQL instead. A default 30 (the `gh` default) or a small fixed cap would silently drop PRs — never rely on it.

**Empty fleet → clean exit.** If `PR_COUNT == 0`, jump to **Stop & Clean Exit** with "Fleet empty — no open PRs found". Do not keep polling an empty fleet.

---

## Step 2.5: Aggregate prior-tick subagent exit reports (every tick — BEFORE classification)

Before Step 3 re-classifies the fleet, process any `phase-a-fixer` subagents that completed (or failed) since the last tick. Read `session-state.json`'s `active_agents` and match entries where `phase == "A"` and `task` references PMM fix work.

For each completed subagent, run steps 1-3 **unconditionally first** (cleanup must finish before any respawn, so a replacement's fresh record can never be clobbered by the completed agent's own removal):

1. **Parse the Structured Exit Report** from its output (`EXIT_REPORT` block per `.claude/reference/exit-report-format.md`). No exit report = silent failure — check GitHub for the PR's current HEAD and surface `failed` in the Subagent column.
2. **Clean up the Phase A worktree.** `phase-a-fixer` subagents run with `isolation: "worktree"` (Step 5c) — the worktree persists whenever the subagent made changes (only a no-op agent gets auto-cleaned). If the subagent's completion result names a worktree path, remove it: `git worktree remove <path> --force`; on failure, fall back to `git worktree prune`. Do this for every outcome (success, exhaustion, crash) — a leftover child worktree keeps the PR's branch checked out and blocks the parent's later `git checkout`/rebase (Step 5a) or another dispatch for the same PR.
3. **Remove this agent's own `active_agents` record and clear its `pmm_in_flight[N]` lock — for every outcome, including crash and exhaustion.** Scope the removal to this specific completed entry (`id == "pmm-fix-$N"`), not a blanket `pr`+`phase` filter — a blanket filter would also delete a sibling Phase A row for the same PR belonging to a different (non-PMM) workflow sharing `active_agents`:
   ```bash
   CURRENT_AGENTS=$(.claude/scripts/session-state.sh --get '.active_agents' 2>/dev/null || echo null)
   [ "$CURRENT_AGENTS" = "null" ] && CURRENT_AGENTS='[]'
   FILTERED_AGENTS=$(jq --arg id "pmm-fix-$N" '[.[] | select(.id != $id)]' <<<"$CURRENT_AGENTS")
   .claude/scripts/session-state.sh --set ".active_agents=$FILTERED_AGENTS" \
     --set ".pmm_in_flight.\"$N\"=null"
   ```
   This must be a real read-filter-write, not a no-op comment — Step 3's concurrency cap and idempotency check both count live entries in this array.
4. **Branch on OUTCOME** (steps 1-3 above are already done, so this branch never races the cleanup):
   - `pushed_fixes` or `no_findings` → verify push SHA matches `HEAD_SHA` in the report (`gh pr view N --json commits --jq '.commits[-1].oid'`). Verify handoff file exists at `~/.claude/handoffs/pr-{N}-handoff.json` with `phase_completed: "A"`.
   - `exhaustion` → launch a replacement `phase-a-fixer` subagent within 60s (an "Always do" action per `subagent-orchestration.md`'s Token/Turn Exhaustion Protocol), using the same spawn-record pattern as Step 5c to register its fresh `active_agents` entry and `pmm_in_flight[N]` lock — the slot is guaranteed clear because step 3 already removed the old record. Report to user and **stop further parent actions for this tick** — do not proceed to Step 5d `/wrap` or Step 6 until the replacement completes or fails.
   - Missing/corrupt report, or a crash with no handoff file → mark `failed` and add `#N` to `HARD_BLOCK[]` with reason `crashed(needs-approval)`. **Do NOT leave it eligible for silent re-dispatch** — `subagent-orchestration.md`'s Phase Transition Autonomy table requires user permission before respawning a crashed/no-handoff subagent. Step 7 routes to Stop & Clean Exit so the user can approve.
5. **Record per-PR outcome** in a `SUBAGENT_STATUS[N]` map (`complete` / `failed`) for the Step 4 table.

PMM does **not** launch Phase B/C after Phase A — it only fixes and pushes. Step 5e's monitor posture borrows `monitor-mode.md`'s orchestration-only discipline but explicitly skips `phase-protocols.md`'s Phase Completion Protocols (which would otherwise auto-launch Phase B). The next tick re-classifies each PR on its new SHA (may become `waiting`, `wrap`, or `fixpr` again).

**Handoff file isolation:** each PR uses its own `~/.claude/handoffs/pr-{N}-handoff.json`. Parallel subagents never share a handoff path — confirm no cross-PR handoff references before spawning.

---

## Step 3: Gather per-PR state + classify (compute verdicts — NO actions)

This step is **side-effect-free**: it gathers state and computes a verdict per PR, but performs **no** rebases or dispatches. Actions happen in **Step 5**, after the table prints (Step 4). This ordering is required so the heartbeat table always shows the classification *before* any long-running dispatch.

For **each** PR number, gather state. Run the per-PR fetches **in parallel across PRs** (one batch of background jobs, then collect), since they are independent network calls.

For a single PR `$N` (with `$HEADREF` = its `headRefName` from the Step 2 `$PR_LIST`):

```bash
# Gate verdict — single source of truth for merge readiness, CI, merge_state,
# review_decision, human_changes_requested, stale_bot_changes_requested_count.
GATE=$(.claude/scripts/merge-gate.sh "$N"); GATE_EXIT=$?
# Linked issue for the Issue column (exit 1 = no link, expected).
ISSUE=$(.claude/scripts/pr-issue-ref.sh "$N" 2>/dev/null || true)
# Unresolved review threads (GraphQL — covers every bot/human author).
UNRESOLVED=$(gh api graphql -f query='
  query($owner:String!,$repo:String!,$n:Int!){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$n){
        reviewThreads(first:100){ nodes { isResolved } } } } }' \
  -F owner="$OWNER" -F repo="$REPO" -F n="$N" \
  --jq '[.data.repository.pullRequest.reviewThreads.nodes[]|select(.isResolved==false)]|length' \
  2>/dev/null || echo "?")
```

Pull the fields the table and decision tree need out of `$GATE`:

```bash
MET=$(jq -r '.met' <<<"$GATE")
MERGE_STATE=$(jq -r '.merge_state' <<<"$GATE")          # CLEAN|BEHIND|BLOCKED|...
MERGEABLE=$(jq -r '.mergeable' <<<"$GATE")              # MERGEABLE|CONFLICTING|UNKNOWN
REVIEW_DECISION=$(jq -r '.review_decision' <<<"$GATE")  # APPROVED|CHANGES_REQUESTED|REVIEW_REQUIRED
CI_FAILING=$(jq -r '.ci_status.failing' <<<"$GATE")
CI_INPROG=$(jq -r '.ci_status.in_progress' <<<"$GATE")
CI_PASSING=$(jq -r '.ci_status.passing' <<<"$GATE")
HUMAN_CR=$(jq -r '.human_changes_requested | join(",")' <<<"$GATE")
STALE_BOT_CR=$(jq -r '.stale_bot_changes_requested_count // 0' <<<"$GATE")
```

### Decision tree (per PR — first match wins → assign `VERDICT`)

Read `merge_state` / `mergeable` **literally** from the gate JSON. **Do NOT infer `BEHIND` from `BLOCKED`** — `BLOCKED` also covers missing checks/reviews, not just behind-base. Only the literal `BEHIND` triggers a rebase.

| Condition (checked in order) | `VERDICT` | Acted on in Step 5 as |
|------------------------------|-----------|------------------------|
| `human_changes_requested` non-empty (human CR on HEAD) | `BLOCKED:human(@login)` | **Hard block** → Stop & Clean Exit (name each login; never auto-dismiss) |
| `mergeable == CONFLICTING` | `BLOCKED:conflicts` | **Hard block** → Stop & Clean Exit (recommend `/merge-conflict`; never auto-merge) |
| `merge_state == BEHIND` | `rebase` | Rebase + force-push + stale-bot dismissal (Step 5a/5b) |
| `CI_FAILING > 0` **or** `UNRESOLVED > 0` | `fixpr` (`has-recoverable-blockers`) | Spawn `phase-a-fixer` subagent (Step 5c) |
| `MET == false` **and** (`STALE_BOT_CR > 0` **or** `REVIEW_DECISION == CHANGES_REQUESTED` with no human CR) | `fixpr` (`has-recoverable-blockers`) | Spawn `phase-a-fixer` subagent — it dismisses stale bot reviews + re-triggers the owning bot (Step 5c) |
| `MET == true` (clean review on HEAD + CI green + 0 unresolved threads + no blockers) | `wrap` | Dispatch `/wrap` sequentially (Step 5d) |
| Otherwise (CI in-progress, reviewer genuinely pending, `REVIEW_REQUIRED` with no bot signal yet, `UNKNOWN`) | `waiting` | No-op — reviewer/CI owns the next move |

`merge-gate.sh` exit `3` (PR gone — merged/closed between Step 2 and now) → `VERDICT=gone` (drop from the fleet this tick). Exit `2`/`4` (tooling/network) → `VERDICT=error` (do not act; retry next tick).

**Collect, but do not act yet:** push every PR with a `BLOCKED:*` verdict onto a `HARD_BLOCK[]` list (with its reason). Step 7 routes to **Stop & Clean Exit** when `HARD_BLOCK[]` is non-empty. The `rebase`/`fixpr`/`wrap` verdicts are executed in Step 5.

**Pre-fetch findings for fix subagents (verdict `fixpr` only):** while gathering state, also fetch review findings from the three endpoints so Step 5c can embed them in each subagent prompt without a second round-trip:

```bash
# Per PR with fixpr verdict — stash in FINDINGS_JSON[N]
gh api "repos/$OWNER/$REPO/pulls/$N/reviews?per_page=100"
gh api "repos/$OWNER/$REPO/pulls/$N/comments?per_page=100"
gh api "repos/$OWNER/$REPO/issues/$N/comments?per_page=100"
```

Filter to actionable bot findings (`coderabbitai[bot]`, `cursor[bot]`, `greptile-apps[bot]`, `codeant-ai[bot]`, `graphite-app[bot]`). Also record the **reviewer classification** (`cr`, `bugbot`, or `greptile`) from `reviewer-of.sh` or gate JSON for the subagent prompt.

### Refine `fixpr` verdicts for concurrency + idempotency (read-only, still Step 3)

Step 5c's parallel-dispatch decisions (skip-if-in-flight, cap slots) are pure reads against `session-state.json` — compute them here, **before Step 4 prints the table**, so the heartbeat never shows a stale `fixpr` for a PR that is actually already in flight or waiting on a slot.

For every PR whose base verdict is `fixpr`:

1. **In-flight check.** Refine to `awaiting fix subagent` if an `active_agents` entry exists with matching `pr == N`, `phase == "A"`, and `status` not in `{complete, failed}`, OR if `pmm_in_flight[N]` has an active lock for the same PR **that is not stale** — apply the same `PMM_LOCK_STALE_SECS` (default 3600s) staleness rule Step 5d uses for `/wrap` locks. A stale lock (e.g. a `wrap` lock left over from a crashed parent, on a PR now reclassified `fixpr`) is broken here too, not just in Step 5d — otherwise a stale non-`phase-a-fixer` lock can block fix dispatch forever with no path to clear it.
2. **Cap check.** Among the PRs still `fixpr` after step 1, count currently active **PMM-spawned** fix subagents (`id` prefixed `pmm-fix-` — excludes Phase A agents spawned by other workflows sharing the same `active_agents` array) and compute remaining slots:

   ```bash
   ACTIVE_COUNT=$(jq '[.[] | select(.phase == "A" and (.status != "complete" and .status != "failed")
     and ((.id // "") | startswith("pmm-fix-")))] | length' \
     <<<"$(.claude/scripts/session-state.sh --get '.active_agents' 2>/dev/null || echo '[]')")
   SLOTS=$(( PMM_MAX_PARALLEL - ACTIVE_COUNT ))
   (( SLOTS < 0 )) && SLOTS=0
   ```

   The first `$SLOTS` PRs (by PR number order, for determinism) keep verdict `fixpr`; the rest refine to `queued (cap)`.

Store the refined verdict per PR (`fixpr`, `awaiting fix subagent`, or `queued (cap)`) for both Step 4's table and Step 5c's dispatch loop — Step 5c dispatches only PRs still refined to `fixpr` and does not repeat this check.

---

## Step 4: Print the status table (the per-tick heartbeat — EVERY tick, BEFORE any action)

The table is this skill's heartbeat. Print it **every tick** and **before** Step 5 runs any rebase or dispatch, so the classification is visible even if a dispatch is long-running. Lead with an Eastern-time timestamp (per `CLAUDE.md` #1):

```bash
TS=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET')
echo "[$TS] PMM tick — $PR_COUNT PR(s) in fleet (author:$PMM_AUTHOR)"
```

| Issue | PR | State | Reviews | CI | Unresolved Threads | Verdict | Subagent |
|-------|----|-------|---------|----|--------------------|---------|----------|
| #<issue or —> | #<N> | <merge_state> | <review_decision> | <pass>/<fail>/<prog> | <count> | <VERDICT from Step 3> | <SUBAGENT_STATUS> |

- **Issue** — from `pr-issue-ref.sh`, or `—` when the PR body has no closing keyword.
- **State** — literal `merge_state` (`CLEAN`/`BEHIND`/`BLOCKED`/`CONFLICTING`/`UNKNOWN`).
- **Reviews** — literal `review_decision` (`APPROVED`/`CHANGES_REQUESTED`/`REVIEW_REQUIRED`).
- **CI** — `passing`/`failing`/`in_progress` counts from the gate.
- **Unresolved Threads** — count of `isResolved == false` (or `?` if the GraphQL fetch failed).
- **Verdict** — the Step 3 verdict: `rebase`, `fixpr`, `wrap`, `waiting`, `awaiting fix subagent`, `queued (cap)`, `rate-limited`, `BLOCKED:human(@x)`, `BLOCKED:conflicts`, `gone`, `error`.
- **Subagent** — per-PR agent state for fix work: `—` (not spawned / no fix dispatch this tick), `spawned`, `working`, `complete`, `failed`. Populated from `active_agents` + Step 2.5 outcomes. Merge-ready `/wrap` dispatches show `—` (wrap is parent-inline, not a subagent).

Only after the table is printed does Step 5 execute the actions.

---

## Step 5: Act on the verdicts (after the table)

Iterate the fleet and execute each PR's Step 3 verdict. `waiting`, `gone`, `error`, and `BLOCKED:*` verdicts do **no** work here (`BLOCKED:*` is handled by the Stop routing in Step 7).

### Step 5.0: Pre-flight per discovered PR (before any dispatch — issue #493)

**Before the per-PR decision tree acts, run the shared `pr-preflight.sh` once per discovered PR.** This flips a draft PR you own to ready and engages all four conditionally-triggered reviewers (CodeAnt, CodeRabbit, Cursor, Graphite) on each PR's current SHA, so the fleet is review-ready before any rebase / fix subagent / `/wrap` dispatch. It is the **same** script `/fixpr` Step 0c and `/babysit-pr` T1b use — PMM never re-implements the draft flip or trigger logic.

```bash
PREFLIGHT_SH=""
for c in "$HOME/.claude/skills-worktree/.claude/scripts/pr-preflight.sh" \
         "$HOME/.claude/scripts/pr-preflight.sh" \
         ".claude/scripts/pr-preflight.sh"; do
  [ -x "$c" ] && { PREFLIGHT_SH="$c"; break; }
done

# Strictly per-PR — pr-preflight.sh takes a single PR and holds NO cross-PR
# state, so a draft flip on PR A can never leak into PR B's reviewer-trigger
# logic. Run it in a per-PR loop over the fleet; skip verdicts gone/error.
for N in $PR_NUMS; do
  # Skip PRs whose Step 3 verdict was `gone` or `error` — calling pr-preflight.sh
  # on them would cause avoidable API failures and noise.
  _verdict=$(jq -r --arg n "$N" '.[$n].verdict // ""' <<<"${VERDICTS_JSON:-{}}" 2>/dev/null || true)
  if [[ "$_verdict" == "gone" || "$_verdict" == "error" ]]; then continue; fi
  if [ -n "$PREFLIGHT_SH" ]; then
    PF_OUT=$("$PREFLIGHT_SH" "$N") || echo "[PMM] pr-preflight.sh #$N exited non-zero (exit $?) — continuing"
    echo "$PF_OUT"   # timestamped action lines per PR feed the heartbeat
    # stash the per-PR PREFLIGHT_SUMMARY for the Step 7 summary (keyed by PR)
  else
    echo "[PMM] pr-preflight.sh not found — skipping draft/reviewer pre-flight for #$N"
  fi
done
```

`pr-preflight.sh` is idempotent (a PR already ready with all four reviewers engaged is a no-op printing `Pre-flight clean — proceeding`), rate-cap safe (it gates `@coderabbitai full review` on `cr-review-hourly.sh` — `--check` + atomic `--record-explicit` — and skips only CR when the cap is hit, still posting the other three), never flips another user's intentional draft, and never triggers Greptile. Because the pre-flight may have just triggered reviewers, the verdicts computed in Step 3 are from *before* the triggers; the next tick re-discovers and re-classifies on the post-trigger state — the rebase / fix subagent / `/wrap` actions below still run on this tick's verdicts.

### Step 5a: Rebase (verdict `rebase`, i.e. `merge_state == BEHIND`)

**Skip if any Phase A agent is still active for this PR — not just PMM's own.** `BEHIND` is checked before `fixpr` in the decision tree (Step 3), so a PR with a fixer subagent still running from a prior tick can flip to verdict `rebase` if main advanced mid-fix — checking out that branch here would collide with that subagent's own worktree (git refuses to check out the same branch twice) and race its push. This check must match Step 3's in-flight check exactly (same reasoning: two Phase A fixers on one PR is risky regardless of which system spawned them) — checking only `pmm-fix-` entries would miss a foreign (non-PMM) Phase A agent sharing the same `active_agents` array, since `BEHIND`-verdict PRs never go through Step 3's `fixpr`-only refinement pass and so get no other protection. Before rebasing, check for **any** `active_agents` entry with `pr == N`, `phase == "A"`, `status` not in `{complete, failed}` (regardless of `id`), or an active `pmm_in_flight[N]` lock; if found, skip this PR this tick (verdict stays `rebase` for the table, but no action runs) — it becomes rebase-eligible once the agent completes and its worktree is cleaned up (Step 2.5 for PMM's own fixers; foreign agents clean up under their own workflow's rules).

**Use `git rebase origin/main` + `git push --force-with-lease` — NEVER GitHub's update-branch API.** The API creates bot merge commits that block CI; `auto-update-prs.yml` was removed for exactly this reason.

```bash
# Pre-flight: never rebase on a dirty tree. This skill runs from a worktree;
# stay in it and never touch the root repo (safety.md).
if [ -n "$(git status --porcelain)" ]; then
  echo "[PMM] PR #$N BEHIND but working tree dirty — skipping rebase, surfacing"; # verdict downgrades to error
else
  git fetch origin main --quiet
  git checkout "$HEADREF" 2>/dev/null || git switch "$HEADREF"
  if git rebase origin/main; then
    git push --force-with-lease
    REBASED_SHA=$(git rev-parse HEAD)
    # then run Step 5b (dismiss stale bot reviews on the new SHA)
  else
    git rebase --abort
    echo "[PMM] PR #$N rebase hit conflicts — hard block, recommend /merge-conflict"
    # add #N to HARD_BLOCK[] with reason "conflicts"
  fi
fi
```

If the checkout/rebase cannot proceed (branch not present locally, multiple worktrees), surface the PR as `error` and leave it for the user rather than guessing.

### Step 5b: Dismiss stale bot reviews after a force-push

Run only after Step 5a actually force-pushed. Use the shared helper; **note the macOS bash 3.x blocker**:

> ⚠️ **`dismiss-stale-bot-changes.sh` uses `mapfile` (bash 4+).** On macOS the default `/bin/bash` is 3.2, where `mapfile` is undefined and the script aborts. Until that script is fixed to be 3.x-safe, invoke it through a bash 4+ shim **or** use the inline REST fallback below. Linux CI/cloud agents ship bash 4+, so the direct call works there.

```bash
DISMISS=""
for c in "$HOME/.claude/skills-worktree/.claude/scripts/dismiss-stale-bot-changes.sh" \
         "$HOME/.claude/scripts/dismiss-stale-bot-changes.sh" \
         ".claude/scripts/dismiss-stale-bot-changes.sh"; do
  [ -x "$c" ] && { DISMISS="$c"; break; }
done

BASH4=""; for b in bash /opt/homebrew/bin/bash /usr/local/bin/bash; do
  v=$("$b" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 0); [ "${v:-0}" -ge 4 ] && { BASH4="$b"; break; }
done

if [ -n "$DISMISS" ] && [ -n "$BASH4" ]; then
  "$BASH4" "$DISMISS" "$N"
else
  # Inline REST fallback (POSIX-safe, no mapfile) — same allowlist + semantics
  # as the script: dismiss only Bot-authored CHANGES_REQUESTED whose commit_id
  # != current HEAD. NEVER touches human reviews.
  HEAD_SHA=$(gh pr view "$N" --json headRefOid --jq .headRefOid)
  gh api --paginate "repos/$OWNER/$REPO/pulls/$N/reviews?per_page=100" | jq -s 'add // []' \
   | jq -r --arg sha "$HEAD_SHA" '
       ["coderabbitai[bot]","cursor[bot]","greptile-apps[bot]","codeant-ai[bot]","graphite-app[bot]"] as $allow
       | .[] | select(.state=="CHANGES_REQUESTED")
       | select((.commit_id//"")!="" and .commit_id!=$sha)
       | select((.user.type//"")=="Bot")
       | select(.user.login as $l | $allow|index($l)) | .id' \
   | while read -r rid; do
       [ -n "$rid" ] && gh api -X PUT \
         "repos/$OWNER/$REPO/pulls/$N/reviews/$rid/dismissals" \
         -f message="Superseded by rebase onto main" >/dev/null 2>&1 \
         && echo "[PMM] dismissed stale bot review_id=$rid on #$N"
     done
fi
```

### Step 5c: Parallel `phase-a-fixer` dispatch (verdict `fixpr` — has-recoverable-blockers)

Fix work runs in **parallel** via one `phase-a-fixer` subagent per PR, capped at `$PMM_MAX_PARALLEL` (default 3). Merge dispatch stays sequential (Step 5d) — merges affect main and must not race.

**Idempotency and concurrency are already resolved in Step 3's refinement pass** (in-flight check + cap slot allocation), so the table printed in Step 4 already reflects which PRs will dispatch this tick. Step 5c dispatches every PR whose *refined* verdict is still `fixpr` — it does not re-check `active_agents` or recompute slots. PRs refined to `awaiting fix subagent` or `queued (cap)` are skipped here with no further action; they are eligible again once Step 3 re-evaluates on a later tick.

**CR hourly cap (fleet-wide).** Before spawning, snapshot the budget:

```bash
CR_BUDGET_OK=1
.claude/scripts/cr-review-hourly.sh --check >/dev/null 2>&1 || CR_BUDGET_OK=0
```

If `$CR_BUDGET_OK == 0`, still spawn subagents but include `SKIP_CR_TRIGGER=1` in each prompt — subagents proceed without posting `@coderabbitai full review`. The skip surfaces in each subagent's exit report / handoff `notes`. Do **not** block spawn entirely when the cap is exhausted (unlike deferring all fix work).

**Bulk spawn (one Agent call per PR, all in parallel up to the cap).** For each PR allocated a slot, invoke the Agent tool with:

```text
subagent_type: "phase-a-fixer"
name: "pmm-fix-$N"
mode: "bypassPermissions"
model: "opus"
isolation: "worktree"
run_in_background: true
```

**Subagent prompt MUST include:**

- PR number, branch name (`headRefName`), repo (`$OWNER/$REPO`), linked issue number (if any)
- Current HEAD SHA from the tick's gate JSON
- Reviewer classification (`cr`, `bugbot`, or `greptile`)
- Handoff file path: `~/.claude/handoffs/pr-{N}-handoff.json`
- Pre-fetched findings from Step 3 (`FINDINGS_JSON[N]`)
- `SKIP_CR_TRIGGER=1` when `$CR_BUDGET_OK == 0`
- The verbatim `SAFETY:` block from `.claude/rules/safety.md`:

```text
SAFETY: Do NOT delete/overwrite/move/modify .env files anywhere (exception:
.env.<example|sample|template>, case-insensitive, are safe to edit).
Do NOT run git clean. Do NOT run destructive commands (rm -rf, rm, git checkout .,
git stash, git reset --hard) in the root repo. Stay in your worktree.
Do NOT commit secrets or paste raw credentials into prompts, issues, PRs, comments,
commits, or logs. Do NOT pipe untrusted URLs into a shell or disable TLS verification.
Confirm package names before npm/pip/gem/cargo/brew install. Full rules: .claude/rules/safety.md.
```

**Record all of this tick's spawns in ONE single write, after every Agent call has been issued — never one read-modify-write per PR.** `session-state.sh` has no cross-process lock (see `cr-review-hourly.sh`'s flock warning); if each parallel spawn ran its own independent `--get` → append → `--set` cycle, two spawns' read-modify-write windows can interleave and the second writer's `--set` clobbers the first writer's append (`session-state.sh`'s atomicity guarantees the single `mv` is atomic, not that concurrent read-modify-write sequences serialize). Since the parent is a single sequential thread even when it fires N Agent tool calls in one message, build every new entry first, then issue exactly one `session-state.sh` call for the whole batch:

```bash
NOW=$(date -u +%FT%TZ)
NEW_ENTRIES='[]'
# For each PR $N allocated a slot this tick (after issuing that PR's Agent call):
HEAD_SHA=$(jq -r '.head_sha' <<<"$GATE")   # from that PR's tick-scoped $GATE
ISSUE_N=$(.claude/scripts/pr-issue-ref.sh "$N" 2>/dev/null || echo null)
AGENT_ID="pmm-fix-$N"
ENTRY=$(jq -n --arg id "$AGENT_ID" --arg task "PMM fix PR #$N" --argjson issue "$ISSUE_N" \
  --argjson pr "$N" --arg launched "$NOW" --arg head_sha "$HEAD_SHA" \
  '{id:$id, task:$task, issue:$issue, pr:$pr, phase:"A", status:"spawned", launched:$launched, head_sha:$head_sha}')
NEW_ENTRIES=$(jq --argjson entry "$ENTRY" '. + [$entry]' <<<"$NEW_ENTRIES")
# ... repeat for every spawned PR, accumulating into $NEW_ENTRIES ...

# After the loop — ONE read of the current array, ONE append of the whole batch, ONE write:
CURRENT_AGENTS=$(.claude/scripts/session-state.sh --get '.active_agents' 2>/dev/null || echo null)
[ "$CURRENT_AGENTS" = "null" ] && CURRENT_AGENTS='[]'
UPDATED_AGENTS=$(jq --argjson entries "$NEW_ENTRIES" '. + $entries' <<<"$CURRENT_AGENTS")
IN_FLIGHT_SETS=()
for N in $SPAWNED_PR_NUMS; do   # the same PR numbers folded into $NEW_ENTRIES above
  IN_FLIGHT_SETS+=(--set ".pmm_in_flight.\"$N\"={\"skill\":\"phase-a-fixer\",\"status\":\"active\",\"dispatched_at\":\"$NOW\",\"head_sha\":\"$HEAD_SHA\",\"agent_id\":\"pmm-fix-$N\"}")
done
.claude/scripts/session-state.sh --set ".active_agents=$UPDATED_AGENTS" "${IN_FLIGHT_SETS[@]}"
```

Set Subagent column to `spawned` immediately for every PR in this batch; transition to `working` once each subagent reports activity (first tool call or ~30s elapsed).

**Safety boundaries for every subagent (non-negotiable):**

- Never modify branch protection
- Never dismiss human-authored reviews
- Never resolve a review thread without code-verification (per `phase-a-fixer` Step 5)

### Step 5d: Sequential `/wrap` dispatch (verdict `wrap` — merge-ready)

Merge-ready PRs get **sequential** `/wrap` dispatch — one at a time, never parallelized. Merges affect main branch state (main-sync, follow-up detection, lessons) and must not race.

**Idempotency-gated via `pmm_in_flight`:**

```bash
INFLIGHT=$(.claude/scripts/session-state.sh --get ".pmm_in_flight.\"$N\"" 2>/dev/null || echo null)
```

Decision:

- `$INFLIGHT` has `status == "active"` → skip (verdict `awaiting prior /wrap`) unless stale per `PMM_LOCK_STALE_SECS` (default **3600s**) with no live progress evidence.
- `$INFLIGHT` is `null` (or stale lock broken) → acquire lock, run `/wrap` inline:

```bash
NOW=$(date -u +%FT%TZ)
HEAD_SHA=$(jq -r '.head_sha' <<<"$GATE")
.claude/scripts/session-state.sh --set \
  ".pmm_in_flight.\"$N\"={\"skill\":\"wrap\",\"status\":\"active\",\"dispatched_at\":\"$NOW\",\"head_sha\":\"$HEAD_SHA\"}"
```

Execute the **full** `/wrap` workflow inline (all 4 phases). On completion:

- `/wrap` merged the PR → clear `pmm_in_flight[N]`; PR drops from fleet on next `gh pr list`.
- `/wrap` returned a hard block → clear in-flight and add `#N` to `HARD_BLOCK[]`.

**"Fix subagents active this tick" means spawned just now by Step 5c OR still running from a prior tick** — check both: any Step 5c spawn this tick, **or** a live PMM-spawned entry already in `active_agents` (`phase == "A"`, `id` prefixed `pmm-fix-`, `status` not in `{complete, failed}`). This matters because a `/pmm-stop`-then-resume, or a tick where Step 3's refinement pass left every `fixpr` PR at `awaiting fix subagent`/`queued (cap)` with zero *new* spawns, would otherwise slip past a "spawned this tick" check while a background fixer is still mid-flight on a shared branch/worktree.

Process merge-ready PRs **only when no fix subagents are active this tick** (by the definition above) — run Step 5d sequentially before Step 5e. If any fix subagents are active, **defer all `/wrap` dispatches** until the Step 5e monitor loop has drained every active fix subagent. This keeps the parent out of concurrent parent work and honors dedicated monitor mode.

### Step 5e: Dedicated monitor mode while fix subagents are active

If any fix subagents are active this tick (per the definition above — spawned now or carried over from a prior tick), **immediately enter an orchestration-only posture borrowing `monitor-mode.md`'s Dedicated Monitor Mode discipline** — the parent's ONLY job until all fix subagents complete or fail is orchestration (poll, verify, heartbeat); no feature code, no local CR review, no substantive source analysis. **PMM does NOT execute `monitor-mode.md`'s Monitor Loop Per-Cycle Checklist verbatim** — specifically, it never runs `phase-protocols.md`'s Phase Completion Protocols, which would otherwise auto-launch Phase B after Phase A. Step 2.5's aggregation fully replaces that: PMM fixes and pushes only, per Step 0's contract ("PMM does not launch Phase B/C after Phase A").

**PMM's own monitor loop (~60s cadence — replaces, not layers on, `monitor-mode.md`'s checklist):**

1. Poll active subagent statuses. Transition Subagent column: `spawned` → `working` → `complete` / `failed`.
2. On any completion — success, exhaustion, or crash — **run Step 2.5's steps 1-3 in full** (parse exit report, worktree cleanup, remove this agent's own `active_agents` record + clear `pmm_in_flight[N]`) before branching on outcome. This is unconditional, not just the success path — a failure that skips clearing `pmm_in_flight[N]` would otherwise leave a stale lock blocking Step 3's idempotency check until `PMM_LOCK_STALE_SECS` expires.
3. Branch on outcome (per Step 2.5's step 4, cleanup from step 2 above already done):
   - **Crash / no exit report / stale >15 min:** mark `failed` in the table and add `#N` to `HARD_BLOCK[]` with reason `crashed(needs-approval)` — never re-dispatch silently. Step 7 routes to Stop & Clean Exit so the user can explicitly approve a respawn (`subagent-orchestration.md`: "Ask first only: ... respawning a crashed/no-handoff subagent").
   - **Token/turn exhaustion with a valid handoff file:** respawn immediately per Step 2.5 (an "Always do" action per `subagent-orchestration.md`'s Token/Turn Exhaustion Protocol) — do not wait for the next tick.
4. Send heartbeat if >5 min since last user message (timestamp prefix required).
5. Investigate stale agents (>15 min Phase A without progress).

**While subagents run:** do not start rebases, additional spawns, or `/wrap` dispatches. Deferred merge-ready PRs from Step 5d run immediately after the monitor loop exits (all fix subagents complete or fail). The tick completes only after all spawned fix subagents return (or fail) and any deferred `/wrap` dispatches finish. Then proceed to Step 6.

**#497 compatibility (idle auto-pause):** when all subagents exit and no parent dispatches remain in-flight, treat the tick as idle for digest/backoff purposes — the stable-state countdown in Step 6 applies as if the tick were a no-op dispatch tick.

---

## Step 6: Stable-state backoff (per `scheduling-reliability.md`)

Compute a **per-tick fleet digest** and track a streak so an idle fleet stops hammering the API. Hash the per-PR tuple `(number, head_sha, merge_state, review_decision, ci_blocking_count, unresolved_threads)` across the whole fleet (sorted by PR number for stability):

```bash
DIGEST=$(printf '%s' "$FLEET_TUPLE_SORTED" | sha256sum | awk '{print $1}')
PREV=$(.claude/scripts/session-state.sh --get '.pmm_digest' 2>/dev/null || echo null)
STREAK=$(.claude/scripts/session-state.sh --get '.pmm_digest_streak' 2>/dev/null || echo 0)
[ "$STREAK" = null ] && STREAK=0
if [ "$DIGEST" = "$PREV" ]; then STREAK=$((STREAK+1)); else STREAK=0; fi
.claude/scripts/session-state.sh --set ".pmm_digest=\"$DIGEST\"" --set ".pmm_digest_streak=$STREAK"

# Resolve the effective cadence from the streak (used by Step 7's loop re-arm).
if [ "$STREAK" -ge 3 ]; then EFFECTIVE_CADENCE="15m"; else EFFECTIVE_CADENCE="$PMM_CADENCE"; fi
```

Backoff schedule (matches `scheduling-reliability.md` "Stable-State Backoff"):

- **Streak ≥ 3** → `EFFECTIVE_CADENCE=15m`; re-arm with `/loop 15m /pr-monitor-and-manage <same args>`.
- **Any digest change** (or a new user message) → streak resets to 0, so `EFFECTIVE_CADENCE` falls back to the configured base `$PMM_CADENCE`.
- **Streak ≥ 9** → the fleet has been frozen for many ticks; print a suggestion to `/pmm-stop` (the user can re-invoke when something changes) but do not force-stop unless a hard block is also present.

A widened cadence is per-fleet here (one loop), but each PR keeps its own row in the digest tuple so a single PR changing state resets the whole loop to base cadence — the cheapest correct behavior for a single shared loop.

**#497 idle auto-pause compatibility:** when a tick finishes with all fix subagents exited and no in-flight parent dispatches, the digest/backoff logic treats the tick as idle — a stable fleet with unchanged digest increments `pmm_digest_streak` normally, and after 3 idle ticks the cadence widens to 15m.

---

## Step 7: Stop routing, then establish / re-arm the polling loop

**First, check the stop conditions.** If any holds, go to **Stop & Clean Exit** instead of re-arming the loop:

1. **User command** — `/pmm-stop` (or "stop monitoring PRs"). See the companion `/pmm-stop` skill.
2. **Empty fleet** — `PR_COUNT == 0` from Step 2 (all PRs merged/closed).
3. **Hard-blocked PR** — `HARD_BLOCK[]` is non-empty (human `CHANGES_REQUESTED` on HEAD, `mergeable == CONFLICTING` the rebase couldn't resolve, a crashed/no-handoff `phase-a-fixer` awaiting respawn approval (`crashed(needs-approval)`, Step 2.5/5e), `/wrap` returned a hard block, CR budget exhausted with nothing else actionable, or a persistent Greptile P0 per `greptile.md`).

Otherwise, **re-arm the loop.** `/loop` is the **canonical** primitive for this recurring poll — never a hand-rolled `ScheduleWakeup` chain (`scheduling-reliability.md`). On the first tick, establish it and state the cancel command in the same message:

```text
/loop <EFFECTIVE_CADENCE> /pr-monitor-and-manage <original args>
To stop: say /pmm-stop (or "stop monitoring PRs"), or interrupt the loop.
```

Record monitoring state every tick (preserve unknown fields — `session-state.sh` does this atomically):

```bash
NOW=$(date -u +%FT%TZ)
.claude/scripts/session-state.sh \
  --set '.pmm_active=true' \
  --set ".pmm_cadence=\"$EFFECTIVE_CADENCE\"" \
  --set ".pmm_author=\"$PMM_AUTHOR\"" \
  --set ".pmm_last_tick_at=\"$NOW\""
# On the FIRST tick also set .pmm_started_at; every tick set the next-expected watermark.
```

**Pre-exit checklist (run before ending every polling turn — `scheduling-reliability.md`):**

1. **Next tick scheduled?** Confirm `/loop` is active/re-armed at `$EFFECTIVE_CADENCE` (or stopped per the routing above).
2. **Heartbeat sent?** The Step 4 timestamped table is the heartbeat — never end a tick silently.
3. **State recorded?** `pmm_active`, cadence, watermarks, `pmm_in_flight`, `active_agents`, `pmm_digest(_streak)` written to `session-state.json`.

---

## Stop & Clean Exit

Reached from Step 7 when a stop condition holds. Tear down and report:

```bash
.claude/scripts/session-state.sh --set '.pmm_active=false' --set '.pmm_next_expected_tick_at=null'
# Best-effort: cancel the loop if a loop-id mechanism is available; otherwise the
# user's /pmm-stop / interrupt drops it.
```

Print a final summary:

```text
=== PR fleet monitoring ended ===
Reason:   <user-stop | empty-fleet | hard-block>
Fleet:    <final status table>
Pre-flight: <per-PR draft→ready + reviewers triggered this session, from each PR's PREFLIGHT_SUMMARY; "clean" where no-op>
Actions:  <rebases / phase-a-fixer subagents / /wrap dispatched this session, per PR — include Subagent outcomes>
Subagents: <per-PR spawn/complete/failed summary from active_agents audit>
Blocked:  <PR # + reason for each HARD_BLOCK entry — e.g. "#123 human CHANGES_REQUESTED by @alice">
```

For a hard-block exit, **name the blocking PR and the exact reason** so the user knows what needs them.

---

## Safety boundaries (HARD STOPS — `safety.md`, `cr-merge-gate.md`)

This skill is an **orchestrator**. It rebases/force-pushes, spawns parallel `phase-a-fixer` subagents for fix work, and dispatches `/wrap` sequentially for merges. It never reimplements fix/merge/resolve logic. The following are absolute:

- **Never modify branch protection** — no calls to `.../branches/.../protection`. Subagents inherit this prohibition.
- **Never dismiss human reviews** — only Bot-allowlist `CHANGES_REQUESTED` on a stale `commit_id` (Step 5b). Human CR is a hard block. Subagents must not dismiss human-authored reviews.
- **Never resolve a review thread without code-verification** — thread resolution happens only inside `phase-a-fixer` Step 5 after verifying the fix. This skill only *counts* unresolved threads.
- **Never bypass AI-reviewer rate caps** — `cr-review-hourly.sh` gates every CR re-trigger; Greptile/CodeAnt caps are respected by subagents and `/wrap`. The Step 5.0 pre-flight (`pr-preflight.sh`, issue #493) is the sanctioned per-PR trigger path: it gates `@coderabbitai full review` on `cr-review-hourly.sh`, never triggers Greptile, never flips another user's draft, and is strictly per-PR (no shared accumulator — a flip/trigger on one PR never leaks to another).
- **Never use GitHub's update-branch API** for `BEHIND` — only `git rebase origin/main` + `--force-with-lease`.
- **Stay in the worktree; never run destructive commands in the root repo** — no `git clean`, `git reset --hard`, or `.env` edits anywhere.
- **Never merge directly** — merging happens only through `/wrap` (which carries its own merge authorization), after its gate + AC verification.
