---
name: pr-monitor-and-manage
description: Thread-level PR fleet manager. Rediscovers your open PRs every tick, prints a status table, and auto-dispatches the per-PR decision tree (rebase / parallel phase-a-fixer / sequential /wrap) until the fleet is clean, hard-blocked, or idle. Auto-pauses when idle; resume with /pr-monitor-and-manage-wake. Triggers on "/pr-monitor-and-manage", "/pmm", "manage PRs", "PR fleet", "watch PRs".
triggers:
  - pr-monitor-and-manage
  - pmm
  - manage PRs
  - PR fleet
  - watch PRs
  - manage my open PRs
argument-hint: "[--author <login>] [--repo <owner/repo>] [--cadence Nm] [--max-parallel N] [--idle-pause-after N] [--auto-wake] [--auto-wake-cadence Nm] [--confirm-merges] (defaults: author=current gh user, repo=current, cadence=5m, max-parallel=3, idle-pause-after=3, auto-wake=off, auto-wake-cadence=60m, confirm-merges=off)"
---

Thread-level **PR fleet manager**. This skill turns the current thread into a dedicated monitor that watches every open PR you own and drives each one to merge-ready (or a named hard block) by dispatching the per-PR decision tree on a recurring cadence. Fix work (`has-recoverable-blockers` / verdict `fixpr`) is handled by **parallel `phase-a-fixer` subagents** (default cap 3, `--max-parallel N`). Merge-ready PRs get **sequential `/wrap`** dispatch only.

> **Implicit merge authorization.** Invoking `/pr-monitor-and-manage` carries merge authorization for the duration of the run — the same exception as `/wrap` and `/merge` in `CLAUDE.md`'s "PR MERGE AUTHORIZATION" block. PMM never merges directly; it lands merge-ready PRs only by dispatching the full `/wrap` workflow inline, and `/wrap`'s existing authorization covers the squash merge after gate + AC pass. Scope is precise: this auth covers only `gh pr merge --squash` via `/wrap` — never branch-protection changes, never dismissing human reviews, never bypassing gate or AC failures. With `--confirm-merges` off (default), PMM dispatches `/wrap` immediately on merge-ready PRs with no per-PR "merge now?" prompt.

> **Per-PR dispatch is inlined below.** `TODO: refactor to call /babysit-pr per discovered PR after #456 lands.` Until #456 merges, Step 3's decision tree is the single owner of per-PR logic. When `/babysit-pr` exists, replace Step 3's inline branches with one `/babysit-pr <PR>` dispatch per discovered PR — the table, discovery, idempotency, and backoff scaffolding here stay unchanged.

This is a **set-and-monitor** command. Once invoked it acknowledges the mode, establishes a `/loop`, and at every tick reprints the fleet table and acts. The **parent thread** never edits feature code directly — it dispatches subagents to do that work — and never drifts into unrelated work.

---

## Step 0: Enter PR-fleet-manager mode (MANDATORY, first tick only)

### Step 0a: Resume from pause (when `.pmm.paused_at` is set)

On **every** invocation, before Step 1, check for a pause marker. If present, this invocation is a **resume** — tear down any auto-wake cron, clear the marker, merge config, and continue into normal ticking:

```bash
PAUSED_AT=$(.claude/scripts/session-state.sh --get '.pmm.paused_at' 2>/dev/null || echo null)
if [ "$PAUSED_AT" != null ] && [ -n "$PAUSED_AT" ]; then
  # 1. Read saved config into the $SAVED shell variable (fallback defaults if missing) —
  #    step 3 below clears .pmm.config_at_pause in session-state, so step 4 MUST use this
  #    already-captured $SAVED variable, never re-read .pmm.config_at_pause from
  #    session-state after step 3 has run (it will be null by then).
  SAVED=$(.claude/scripts/session-state.sh --get '.pmm.config_at_pause' 2>/dev/null || echo '{}')
  # 2. Delete auto-wake cron (fail-closed — see pr-monitor-and-manage-wake Step 3)
  # 3. Clear pause marker + reset pmm_idle_streak=0 + set pmm_active=true (atomic batch)
  # 4. Merge flags: explicit $ARGUMENTS override $SAVED (the step-1 variable, not
  #    session-state — that field is already cleared by step 3 at this point)
  echo "[PMM] Resuming from pause (paused_at=$PAUSED_AT) — flags on this invocation override saved config."
fi
```

Resume logic is shared with `/pr-monitor-and-manage-wake` — see `.claude/skills/pr-monitor-and-manage-wake/SKILL.md` Step 2 (cron teardown) and Step 3 (marker clear + loop re-arm). When resuming via re-invoking this skill (not `-wake`), apply the precedence rule in Step 1 after parsing `$ARGUMENTS`: any flag explicitly supplied on this invocation wins; omitted flags inherit from `.pmm.config_at_pause`. After resume, continue with Step 1 using the merged config and run a full discovery tick at **base** cadence (not the widened backoff cadence).

A stale marker left by a killed session is safely reconciled here: the next `/pr-monitor-and-manage` invocation reads it, resumes (or the user runs `/pmm-stop`), and re-runs discovery from scratch.

On the **first** invocation in a thread (and after any resume), acknowledge the mode up front so the constraints are explicit and survive context compaction:

> **PR-fleet-manager mode active.** My only job in **this parent thread** is to watch and manage your open PRs as a fleet — rediscover them each tick, print a status table, and dispatch rebase / parallel `phase-a-fixer` subagents (fix work, including merge conflicts) / sequential `/wrap` (merge-ready) per the decision tree. Merge-ready PRs are landed autonomously via inline `/wrap` dispatch (unless `--confirm-merges` is set). I will not edit feature code **directly in this thread**, start issues, or do unrelated work here — but I **will** dispatch subagents that edit code, resolve conflicts, fix findings, push, and reply/resolve threads.

### Parent scope vs Subagent scope

| Scope | Role | Allowed | Disallowed |
|-------|------|---------|------------|
| **Parent (this thread)** | Fleet orchestrator | Discover PRs, classify state, dispatch subagents, aggregate exit reports, update the fleet table, decide next tick; git rebase/force-push for `BEHIND` (Step 5a); stale-bot dismiss + re-trigger (Steps 5b/5b′); inline `/wrap` for merge-ready PRs | Direct code edits; direct git beyond discovery/rebase/dismiss; direct merges (`gh pr merge`); starting new issues; unrelated work |
| **Subagents (spawned per PR)** | Fix worker | Edit files, resolve merge conflicts, fix CR/CI findings, push commits, reply to threads, resolve bot threads — one PR each, per `.claude/rules/subagent-orchestration.md` and #509 (parallel subagents) | Modify branch protection; dismiss human reviews; bypass SAFETY rules |

Spawn pattern reference: `.claude/rules/subagent-orchestration.md` (Phase A fixer / Phase C merger). Every spawn includes the verbatim `SAFETY:` block from `.claude/rules/safety.md`.

**Prohibited for the parent thread (refuse and redirect):**

- Writing or editing **feature code directly** — dispatch a `phase-a-fixer` subagent instead (merge conflicts, CR findings, CI failures are all dispatch cases, not refusal cases).
- Invoking `/start-issue`, `/prompt`, or spawning subagents for **new work unrelated to the discovered fleet**.
- Creating issues or PRs (other than the follow-ups `/wrap` itself creates on merge).
- Any task unrelated to managing the discovered PR fleet.

**Refusal template** when asked for genuinely out-of-scope *parent* work (not dispatchable fleet fix work):

> That's outside PR-fleet-manager mode. I'm keeping this thread focused on monitoring your open PRs. Start a separate thread (e.g. `/start-issue`) for that work — say `/pmm-stop` first if you want me to stop monitoring here.

### Common misreads / Anti-patterns

> If you catch yourself telling the user "I can't edit code in this thread" as a reason to **stop** rather than **dispatch**, that's wrong — the parent doesn't edit code, but its subagents do, and that's the whole point. Merge conflicts, CR findings, and CI failures are all handled by spawning fix subagents, not by refusing or hard-blocking pre-dispatch.

The parent is orchestration-only with respect to source edits: the only direct writes it performs are git rebase/force-push (Step 5a), stale-bot review dismissal + owning-bot re-trigger (Steps 5b/5b′), and the bounded mutations that `phase-a-fixer` subagents and `/wrap` already own. Fix work — including merge-conflict resolution — is delegated to parallel `phase-a-fixer` subagents (`.claude/agents/phase-a-fixer.md`); merge work stays sequential via `/wrap`. The parent never reimplements fix/merge logic beyond the shared dismiss/re-trigger helpers that `/fixpr` also uses.

---

## Step 1: Parse arguments + identify the fleet (every tick)

Parse `$ARGUMENTS` (re-parse every tick — a `/loop` re-invocation passes the same args, but treat them as the source of truth, never a cached value):

- `--author <login>` — whose PRs to manage. **Default:** the current authenticated user via `gh api user --jq .login`.
- `--repo <owner/repo>` — which repo. **Default:** the current repo.
- `--cadence Nm` — base poll interval. **Default:** `5m`.
- `--max-parallel N` — max concurrent `phase-a-fixer` subagents for fix work. **Default:** `3`. Excess PRs needing fixes wait for a slot to free on a subsequent tick.
- `--idle-pause-after N` — consecutive idle ticks before auto-pause. **Default:** `3`.
- `--auto-wake` — when set, register an hourly `CronCreate` job at pause time that lightweight-scans for fleet changes. **Default:** off.
- `--auto-wake-cadence Nm` — cadence for the auto-wake cron. **Default:** `60m`.
- `--confirm-merges` — require an explicit user confirmation before each `/wrap` merge dispatch. **Default:** off (invocation is authorization). This flag only adds a prompt before the `/wrap` dispatch — it never overrides hard stops (`BLOCKED:*` verdicts, gate failures, AC failures). Safety checks in `/wrap` still apply.

> **`--repo` constraint (load-bearing).** `--repo` scopes **discovery** (`gh pr list`) and the GraphQL/REST reads. But the per-PR helpers (`merge-gate.sh`, `pr-issue-ref.sh`, `cr-review-hourly.sh`, `dismiss-stale-bot-changes.sh`) and all git actions (rebase, force-push, fix subagents, `/wrap`) operate on the **current checkout** — they resolve the repo via `gh repo view`, not a flag. So managing a repo requires running this skill from a worktree of **that** repo. If `--repo` names a repo other than the current checkout, **stop and reconcile** (same multi-repo hazard guard as `cr-github-review.md`) rather than acting against the wrong repo.

```bash
# Defaults
PMM_AUTHOR=""; PMM_REPO=""; PMM_CADENCE="5m"; PMM_MAX_PARALLEL=3
PMM_IDLE_PAUSE_AFTER=3; PMM_AUTO_WAKE=false; PMM_AUTO_WAKE_CADENCE="60m"
PMM_CONFIRM_MERGES=false
# (parse $ARGUMENTS into the vars above; bare flags override defaults)

# When resuming from pause (Step 0a), merge saved config into flags omitted on
# this invocation — explicit $ARGUMENTS win. Detect omission via $ARGUMENTS
# substring (or parse-time *_EXPLICIT tracking).
if [ -n "${SAVED:-}" ] && [ "$SAVED" != "{}" ]; then
  [[ "$ARGUMENTS" != *"--author"* ]]            && PMM_AUTHOR=$(jq -r '.author // empty' <<<"$SAVED")
  [[ "$ARGUMENTS" != *"--repo"* ]]              && PMM_REPO=$(jq -r '.repo // empty' <<<"$SAVED")
  [[ "$ARGUMENTS" != *"--cadence"* ]]           && PMM_CADENCE=$(jq -r '.cadence // "5m"' <<<"$SAVED")
  [[ "$ARGUMENTS" != *"--max-parallel"* ]]      && PMM_MAX_PARALLEL=$(jq -r '.max_parallel // 3' <<<"$SAVED")
  [[ "$ARGUMENTS" != *"--idle-pause-after"* ]]  && PMM_IDLE_PAUSE_AFTER=$(jq -r '.idle_pause_after // 3' <<<"$SAVED")
  [[ "$ARGUMENTS" != *"--auto-wake-cadence"* ]]  && PMM_AUTO_WAKE_CADENCE=$(jq -r '.auto_wake_cadence // "60m"' <<<"$SAVED")
  if [[ "$ARGUMENTS" != *"--auto-wake"* ]]; then
    PMM_AUTO_WAKE=$(jq -r '.auto_wake // false' <<<"$SAVED")
  fi
  [[ "$ARGUMENTS" != *"--confirm-merges"* ]]    && \
    PMM_CONFIRM_MERGES=$(jq -r '.confirm_merges // false' <<<"$SAVED")
fi

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
echo "[PMM] fleet = author:$PMM_AUTHOR repo:$OWNER_REPO cadence:$PMM_CADENCE max-parallel:$PMM_MAX_PARALLEL idle-pause-after:$PMM_IDLE_PAUSE_AFTER auto-wake:$PMM_AUTO_WAKE confirm-merges:$PMM_CONFIRM_MERGES"
```

---

## Step 2: Discover open PRs (every tick — NEVER cache across ticks)

**Rediscover the fleet on every single tick.** A PR may have merged, closed, or been opened since the last tick — a cached list silently rots. Always re-run `gh pr list`:

```bash
PMM_LIMIT=500   # high cap so a real fleet is never silently truncated
PR_LIST=$(gh pr list --state open --author "$PMM_AUTHOR" "${REPO_FLAG[@]}" \
  --json number,title,headRefName,headRefOid,mergeStateStatus,reviewDecision --limit "$PMM_LIMIT")
PR_NUMS=$(jq -r '.[].number' <<<"$PR_LIST")
PR_COUNT=$(jq 'length' <<<"$PR_LIST")
```

> **No silent truncation.** `gh pr list` caps results at `--limit`; with `--author` it goes through the Search API (hard ceiling ~1000). Use a high `--limit` (500 above) and **warn** when the fleet hits it: if `PR_COUNT == PMM_LIMIT`, print "Showing $PMM_LIMIT PRs — fleet may be larger; results may be incomplete" and, if you genuinely expect >500 open PRs for one author, page via `gh api`/GraphQL instead. A default 30 (the `gh` default) or a small fixed cap would silently drop PRs — never rely on it.

**Empty fleet → immediate Pause.** If `PR_COUNT == 0`, jump to **Pause** (Step 8) with reason `empty fleet`. Do not keep polling an empty fleet — pause immediately with no 3-tick wait.

---

## Step 2.5: Aggregate prior-tick subagent exit reports (every tick — BEFORE classification)

Before Step 3 re-classifies the fleet, process any **PMM-owned** `phase-a-fixer` subagents that completed (or failed) since the last tick. Read `session-state.json`'s `active_agents` and match entries where `phase == "A"`, `id` starts with `pmm-fix-`, and `task` references PMM fix work. **Foreign Phase A entries** (any other `id` sharing the same `active_agents` array) are intentionally out of scope here — PMM has no exit report to parse for them and must never remove or mutate state it does not own; they drain solely via Step 5e's poll-based mechanism (disappearance / terminal `status` / staleness timeout).

**Initialize `EXHAUSTION_RESPAWN_PRS='[]'` at the start of this step, every tick — never carry it over.** Like `GATE_BY_PR`, it is a plain in-memory variable scoped to the current tick's execution (each `/loop` re-invocation is a fresh run of this skill from Step 1), not a durable field in `session-state.json` — so there is nothing to reset from a *prior* tick's memory, but the step must still start from an explicitly empty list rather than an implicit/undefined one, so a tick with zero exhaustion outcomes never accidentally inherits stale entries from a bug elsewhere in this skill's execution.

**Load persisted hard blocks at tick start** so a `blocked` merge-conflict outcome from a prior tick is not re-dispatched when Step 3 still sees `mergeable == CONFLICTING`:

```bash
PERSISTED_HARD_BLOCK=$(.claude/scripts/session-state.sh --get '.pmm_hard_block // {}' 2>/dev/null || echo '{}')
HARD_BLOCK_JSON="$PERSISTED_HARD_BLOCK"   # map PR number → reason; survives across ticks
```

When Step 2.5 (or Step 5e) adds a PR to `HARD_BLOCK[]`, also persist it: `.claude/scripts/session-state.sh --set ".pmm_hard_block.\"$N\"=\"$REASON\""`. Clear the entry only when the user explicitly approves a respawn or the PR merges/closes (Step 3 sets `VERDICT=gone` → `--set ".pmm_hard_block.\"$N\"=null"`).

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
   - `pushed_fixes` or `no_findings` → verify push SHA matches `HEAD_SHA` in the report (`gh pr view N --json commits --jq '.commits[-1].oid'`). Verify handoff file exists at `~/.claude/handoffs/pr-{N}-handoff.json` with `phase_completed: "A"`. When OUTCOME is `pushed_fixes`, run **Step 5b dismiss helper + Step 5b′ owning-bot re-trigger** on `#N` immediately (same contract as `/fixpr` Steps 3a/3b — a push without dismissal leaves obsolete bot `CHANGES_REQUESTED` on old SHAs and the gate never clears). Step 5e's inline completion path (item 2) runs the same pair when a subagent exits mid-tick.
   - `blocked` → add `#N` to `HARD_BLOCK[]` with reason from the exit report (e.g. `conflicts(needs-human)` for unresolvable merge conflicts). **Persist** the same reason to `pmm_hard_block` in `session-state.json` (see tick-start load above). Report once and drop from the actionable fleet this tick — the subagent already attempted resolution; do not re-dispatch silently.
   - `exhaustion` → **do not launch the replacement inline here.** Step 2.5 runs before Step 3 every tick, so `GATE_BY_PR`/pre-fetched `FINDINGS_JSON` (both populated in Step 3) are not available yet — Step 5c's full spawn pattern needs them. Instead, rely on step 3 above already clearing this PR's `active_agents`/`pmm_in_flight[N]` entries: the PR falls through into Step 3's classification with a clean slate later in this same tick, and if the underlying condition (CI failing, unresolved threads, stale bot review, merge conflicts) still holds, Step 3 naturally re-verdicts it `fixpr` and Step 5c's normal per-tick spawn respawns it — using this tick's freshly-computed `GATE_BY_PR`/`FINDINGS_JSON`. This still satisfies `subagent-orchestration.md`'s 60s Token/Turn Exhaustion Protocol SLA: Step 3 and Step 5c run seconds later in the same continuous tick execution, not on a separate `/loop` cycle. **Record `$N` into `EXHAUSTION_RESPAWN_PRS` for this tick** — Step 3's cap check (item 2) must never let this PR lose its slot to a competing fresh `fixpr` PR, since `subagent-orchestration.md` treats exhaustion-with-handoff respawn as mandatory, not slot-competitive. Report to user.
   - Missing/corrupt report, or a crash with no handoff file → mark `failed` and add `#N` to `HARD_BLOCK[]` with reason `crashed(needs-approval)`. **Persist** the same reason to `pmm_hard_block` in `session-state.json`. **Do NOT leave it eligible for silent re-dispatch** — `subagent-orchestration.md`'s Phase Transition Autonomy table requires user permission before respawning a crashed/no-handoff subagent. Reported once and dropped from the actionable fleet this tick (Step 3's `HARD_BLOCK[]` handling — it does not force-stop the fleet); the user can explicitly approve a respawn.
5. **Record per-PR outcome** in a `SUBAGENT_STATUS[N]` map (`complete` / `failed`) for the Step 4 table.

PMM does **not** launch Phase B/C after Phase A — it only fixes and pushes. Step 5e's monitor posture borrows `monitor-mode.md`'s orchestration-only discipline but explicitly skips `phase-protocols.md`'s Phase Completion Protocols (which would otherwise auto-launch Phase B). The next tick re-classifies each PR on its new SHA (may become `waiting`, `wrap`, or `fixpr` again).

**Handoff file isolation:** each PR uses its own `~/.claude/handoffs/pr-{N}-handoff.json`. Parallel subagents never share a handoff path — confirm no cross-PR handoff references before spawning.

---

## Step 3: Gather per-PR state + classify (compute verdicts — NO actions)

**Refresh `HARD_BLOCK_JSON` immediately before the per-PR loop** so Step 2.5 `blocked`/`crashed` persists from earlier in this same tick are visible to the decision tree (the Step 2.5 tick-start load is stale once Step 2.5 writes new entries):

```bash
HARD_BLOCK_JSON=$(.claude/scripts/session-state.sh --get '.pmm_hard_block // {}' 2>/dev/null || echo '{}')
```

This step is **side-effect-free**: it gathers state and computes a verdict per PR, but performs **no** rebases or dispatches. Actions happen in **Step 5**, after the table prints (Step 4). This ordering is required so the heartbeat table always shows the classification *before* any long-running dispatch.

For **each** PR number, gather state. Run the per-PR fetches **in parallel across PRs** (one batch of background jobs, then collect), since they are independent network calls.

For a single PR `$N` (with `$HEADREF` = its `headRefName` from the Step 2 `$PR_LIST`):

```bash
# Gate verdict — single source of truth for merge readiness, CI, merge_state,
# review_decision, human_changes_requested, stale_bot_changes_requested_count.
GATE=$(.claude/scripts/merge-gate.sh "$N"); GATE_EXIT=$?
GATE_BY_PR[$N]="$GATE"   # retain per-PR — Step 5c/5d look up THIS PR's gate by
                          # number rather than relying on a loop-scoped $GATE,
                          # which is only valid for whichever PR Step 3 last
                          # iterated and goes stale/wrong once other steps
                          # iterate their own PR lists.
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
| PR in persisted `pmm_hard_block` (prior-tick `blocked` / `crashed` — load at Step 2.5) | `BLOCKED:<reason>` | **Hard block** → reported, dropped; **overrides** `mergeable == CONFLICTING` so Step 5c does not re-dispatch silently |
| `human_changes_requested` non-empty (human CR on HEAD) | `BLOCKED:human(@login)` | **Hard block** → reported, dropped from actionable fleet (name each login; never auto-dismiss) |
| `mergeable == CONFLICTING` | `fixpr` (`merge-conflict`) | Spawn `phase-a-fixer` subagent tasked with `/merge-conflict` workflow (Step 5c) — resolves and pushes; never auto-merge |
| `merge_state == BEHIND` | `rebase` | Rebase + force-push + stale-bot dismissal (Step 5a/5b) |
| `CI_FAILING > 0` **or** `UNRESOLVED > 0` | `fixpr` (`has-recoverable-blockers`) | Spawn `phase-a-fixer` subagent (Step 5c) |
| `MET == false` **and** (`STALE_BOT_CR > 0` **or** `REVIEW_DECISION == CHANGES_REQUESTED` with no human CR) | `fixpr` (`has-recoverable-blockers`) | Step 5b′ (when `STALE_BOT_CR > 0` only) dismisses stale bot reviews + re-triggers the owning bot, re-gates; spawn `phase-a-fixer` (Step 5c) when fix work remains (`CI_FAILING > 0`, `UNRESOLVED > 0`, or fresh bot CR on HEAD) |
| `MET == true` (clean review on HEAD + CI green + 0 unresolved threads + no blockers) | `wrap` | Dispatch `/wrap` sequentially (Step 5d) |
| Otherwise (CI in-progress, reviewer genuinely pending, `REVIEW_REQUIRED` with no bot signal yet, `UNKNOWN`) | `waiting` | No-op — reviewer/CI owns the next move |

`merge-gate.sh` exit `3` (PR gone — merged/closed between Step 2 and now) → `VERDICT=gone` (drop from the fleet this tick). Exit `2`/`4` (tooling/network) → `VERDICT=error` (do not act; retry next tick).

**Accumulate `VERDICTS_JSON` as each PR is classified — this is what Step 5.0's pre-flight gone/error skip reads.** Without this, `VERDICTS_JSON` stays an implicit empty object, the skip check never matches, and pre-flight runs against merged/errored PRs it should have skipped:

```bash
VERDICTS_JSON=$(jq --arg n "$N" --arg v "$VERDICT" '.[$n] = {verdict: $v}' <<<"${VERDICTS_JSON:-{}}")
```

**Collect hard blocks for reporting, but do not force-stop the fleet.** Push every PR with a `BLOCKED:*` verdict onto a `HARD_BLOCK[]` list (with its reason). These PRs are **reported once and dropped from the actionable fleet** for this tick — they do not trigger Stop & Clean Exit. A fleet of only hard-blocked/waiting PRs converges to auto-Pause via the idle counter (Step 6/7). The `rebase`/`fixpr`/`wrap` verdicts are executed in Step 5.

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

1. **In-flight check.** Refine to `awaiting fix subagent` if a **blocking** Phase A `active_agents` entry exists for this PR (per Step 5's shared gate idiom — foreign entries past `PMM_LOCK_STALE_SECS` with no progress evidence are non-blocking), OR if `pmm_in_flight[N]` has an active lock for the same PR **that is not stale** — apply the same `PMM_LOCK_STALE_SECS` (default 3600s) staleness rule Step 5d uses for `/wrap` locks. A stale lock (e.g. a `wrap` lock left over from a crashed parent, on a PR now reclassified `fixpr`) is broken here too, not just in Step 5d — otherwise a stale non-`phase-a-fixer` lock can block fix dispatch forever with no path to clear it.
2. **Cap check.** Among the PRs still `fixpr` after step 1, count currently active **PMM-spawned** fix subagents (`id` prefixed `pmm-fix-` — excludes Phase A agents spawned by other workflows sharing the same `active_agents` array) and compute remaining slots:

   ```bash
   ACTIVE_COUNT=$(jq '[.[] | select(.phase == "A" and (.status != "complete" and .status != "failed")
     and ((.id // "") | startswith("pmm-fix-")))] | length' \
     <<<"$(.claude/scripts/session-state.sh --get '.active_agents' 2>/dev/null || echo '[]')")
   SLOTS=$(( PMM_MAX_PARALLEL - ACTIVE_COUNT ))
   (( SLOTS < 0 )) && SLOTS=0
   ```

   Allocate the `$SLOTS` available slots in two tiers, never by plain PR-number order alone: **tier 1** — every PR in `EXHAUSTION_RESPAWN_PRS` (populated by Step 2.5 this tick) keeps verdict `fixpr` unconditionally, even if it exceeds `$SLOTS` — an exhaustion-with-handoff respawn is mandatory per `subagent-orchestration.md`, not slot-competitive, so it must never lose to a fresh PR. **Tier 2** — remaining slots (`$SLOTS` minus tier-1 count, floored at 0) go to the rest of the still-`fixpr` PRs by PR number order, for determinism. Anything past that refines to `queued (cap)`. (A tick with more exhaustion respawns than `$PMM_MAX_PARALLEL` will transiently run over the nominal cap — acceptable, since these are already-approved in-flight fixes being continued, not new work.)

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
- **State** — literal `merge_state` (`CLEAN`/`BEHIND`/`BLOCKED`/`UNKNOWN`); when `mergeable == CONFLICTING`, append `(CONFLICTING)` to the State cell so the conflict signal is visible (CONFLICTING is a `mergeable` value, not a `merge_state` value).
- **Reviews** — literal `review_decision` (`APPROVED`/`CHANGES_REQUESTED`/`REVIEW_REQUIRED`).
- **CI** — `passing`/`failing`/`in_progress` counts from the gate.
- **Unresolved Threads** — count of `isResolved == false` (or `?` if the GraphQL fetch failed).
- **Verdict** — the Step 3 verdict: `rebase`, `fixpr`, `wrap`, `waiting`, `awaiting fix subagent`, `queued (cap)`, `rate-limited`, `BLOCKED:human(@x)`, `BLOCKED:conflicts(needs-human)`, `gone`, `error`.
- **Subagent** — per-PR agent state for fix work: `—` (not spawned / no fix dispatch this tick), `dispatched (merge-conflict)` (conflict-resolution fixer spawned this tick — transitions to `spawned`/`working`/`complete`/`failed` as the subagent runs), `spawned`, `working`, `complete`, `failed`, `deferred(foreign-agent)` (Step 5d/5e deferral gate closed because a foreign Phase A entry blocks this PR), `foreign-agent-stale` (Step 5e staleness timeout fired on a silent foreign entry — gate treated as drained). Populated from `active_agents` + Step 2.5 outcomes (PMM-owned only) + Step 5e foreign-drain polling. Merge-ready `/wrap` dispatches show `—` (wrap is parent-inline, not a subagent).

A PR merged this tick is reported via the per-tick `merged #N` line (Step 5d) and then naturally disappears from the fleet on the next `gh pr list` discovery — no table row lingers.

Only after the table is printed does Step 5 execute the actions.

---

## Step 5: Act on the verdicts (after the table)

**Blocking Phase A entry (shared gate idiom — Steps 3, 5a, 5d, 5e, 6):** An `active_agents` row with `phase == "A"` and `status` not in `{complete, failed}` blocks rebase, `/wrap`, and fix-dispatch gates unless drained. **PMM-owned** entries (`id` starts with `pmm-fix-`) are blocking until Step 2.5/5e drains them via exit report. **Foreign** entries (any other `id`) are blocking only while NOT stale: apply `PMM_LOCK_STALE_SECS` (default 3600s) to `last_seen_at` (or `launched`), and when the window is exceeded **and** there is no live progress evidence on that PR (HEAD SHA unchanged, no new bot/CI activity since the timestamp), treat the entry as **non-blocking** — PMM never mutates it, but stops deferring on it. All gate checks below use this idiom consistently.

**Track actions this tick** for idle detection (Step 6). Initialize `TICK_HAD_ACTION=false` and `MERGED_THIS_TICK='[]'` at the start of Step 5; set `TICK_HAD_ACTION=true` whenever any of the following fire for any PR: rebase + force-push (Step 5a), stale-bot dismissal (Step 5b or 5b′), explicit owning-bot re-trigger from Step 5b′ (or post-subagent Step 2.5/5e), `phase-a-fixer` spawn (Step 5c), `/wrap` dispatch (Step 5d), or a reviewer trigger from `pr-preflight.sh` that actually posts (non-no-op output). Append PR numbers to `MERGED_THIS_TICK` when `/wrap` successfully merges a PR (Step 5d). Waiting, gone, error, `BLOCKED:*`, and no-op pre-flight do **not** set the flag.

Iterate the fleet and execute each PR's Step 3 verdict. Skip PRs in `HARD_BLOCK[]` — they were reported in Step 4's table and are dropped from actionable work. `waiting`, `gone`, and `error` verdicts do **no** work here.

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

**Skip if any Phase A agent is still active for this PR — not just PMM's own.** `BEHIND` is checked before `fixpr` in the decision tree (Step 3), so a PR with a fixer subagent still running from a prior tick can flip to verdict `rebase` if main advanced mid-fix — checking out that branch here would collide with that subagent's own worktree (git refuses to check out the same branch twice) and race its push. This check must match Step 3's in-flight check exactly (same reasoning: two Phase A fixers on one PR is risky regardless of which system spawned them) — checking only `pmm-fix-` entries would miss a foreign (non-PMM) Phase A agent sharing the same `active_agents` array, since `BEHIND`-verdict PRs never go through Step 3's `fixpr`-only refinement pass and so get no other protection. Before rebasing, check for any **blocking** Phase A `active_agents` entry for this PR (per Step 5's shared gate idiom — includes PMM-owned and non-stale foreign entries; stale foreign entries with no progress evidence are non-blocking), or an active `pmm_in_flight[N]` lock **that is not stale** (same `PMM_LOCK_STALE_SECS`, default 3600s, staleness rule as Step 3's in-flight check — a stale lock is broken here too, not treated as blocking); if found, skip this PR this tick (verdict stays `rebase` for the table, but no action runs) — it becomes rebase-eligible once the agent completes and its worktree is cleaned up (Step 2.5 for PMM's own fixers; foreign agents clean up under their own workflow's rules). For foreign Phase A agents, PMM detects completion via Step 5e's poll/staleness signal (entry disappearance, terminal `status`, or `PMM_LOCK_STALE_SECS` timeout with no progress evidence) rather than waiting on cleanup or an exit report it cannot observe.

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
    echo "[PMM] PR #$N rebase hit conflicts — routing to merge-conflict fixer dispatch (Step 5c)"
    # Override Step 3's `rebase` verdict so Step 5c includes this PR in the *same* tick
    # (Step 5c only dispatches PRs whose refined verdict is `fixpr`, not `rebase`):
    VERDICTS_JSON=$(jq --arg n "$N" '.[$n] = {verdict: "fixpr", tag: "merge-conflict", refined: "fixpr"}' <<<"${VERDICTS_JSON:-{}}")
    REFINED_VERDICT[$N]="fixpr"
    # Do NOT add to HARD_BLOCK[] — spawn a phase-a-fixer subagent tasked with the
    # /merge-conflict workflow instead. Step 5c dispatch runs later this tick.
  fi
fi
```

If the checkout/rebase cannot proceed (branch not present locally, multiple worktrees), surface the PR as `error` and leave it for the user rather than guessing.

### Step 5b: Dismiss stale bot reviews after a force-push

Run only after Step 5a actually force-pushed. Uses the **shared dismiss helper** below; **note the macOS bash 3.x blocker**:

> ⚠️ **`dismiss-stale-bot-changes.sh` uses `mapfile` (bash 4+).** On macOS the default `/bin/bash` is 3.2, where `mapfile` is undefined and the script aborts. Until that script is fixed to be 3.x-safe, invoke it through a bash 4+ shim **or** use the inline REST fallback below. Linux CI/cloud agents ship bash 4+, so the direct call works there.

**Shared dismiss helper** (Steps 5b, 5b′, Step 2.5 post-push, and Step 5e inline completion all call this — pass `$N`, optional `$DISMISS_MSG` defaulting to `"Superseded by rebase onto main"` for 5b or `"Superseded — review was on a stale commit"` for 5b′/post-push):

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

DISMISS_MSG="${DISMISS_MSG:-Superseded by rebase onto main}"

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
         -f message="$DISMISS_MSG" >/dev/null 2>&1 \
         && echo "[PMM] dismissed stale bot review_id=$rid on #$N"
     done
fi
```

### Step 5b′: Stale bot `CHANGES_REQUESTED` recovery (verdict `fixpr` — issue #514)

Run **before Step 5c** for every PR whose Step 3 verdict is `fixpr` (or refined `fixpr`) **and** `STALE_BOT_CR > 0` from the tick's gate JSON. Do **not** run when the only bot signal is a **fresh** `CHANGES_REQUESTED` on the current HEAD (`STALE_BOT_CR == 0`) — that PR needs Step 5c fix work, not dismissal/re-trigger. This is **independent of whether Step 5a rebased** — Step 5b only runs after a force-push; without 5b′ a PR blocked *only* by a stale bot review would spawn a no-op `phase-a-fixer` every tick forever.

**Dismiss** — run the shared dismiss helper with `DISMISS_MSG="Superseded — review was on a stale commit"`. Idempotent (already-`DISMISSED` counts as success). The helper only dismisses reviews whose `commit_id` ≠ current HEAD; never touches fresh bot CR on HEAD.

**Re-trigger the owning bot** — `pr-preflight.sh` Step 5.0 is idempotent and **skips** bots that already have prior activity on the PR; a dismissed stale review still counts as prior activity, so post an **explicit** trigger for the owning reviewer on the current HEAD. Resolve via `.claude/scripts/reviewer-of.sh "$N"` (same mapping as `pr-preflight.sh`'s `reviewer_trigger()`):

```bash
REVIEWER=$(.claude/scripts/reviewer-of.sh "$N" 2>/dev/null || echo unknown)
CR_HOURLY=""
for c in "$HOME/.claude/skills-worktree/.claude/scripts/cr-review-hourly.sh" \
         "$HOME/.claude/scripts/cr-review-hourly.sh" \
         ".claude/scripts/cr-review-hourly.sh"; do
  [ -x "$c" ] && { CR_HOURLY="$c"; break; }
done

case "$REVIEWER" in
  cr)
    if [ -n "$CR_HOURLY" ] && "$CR_HOURLY" --check >/dev/null 2>&1 \
       && "$CR_HOURLY" --peek-explicit "$N" >/dev/null 2>&1; then
      if gh pr comment "$N" --body "@coderabbitai full review" >/dev/null 2>&1; then
        "$CR_HOURLY" --record-explicit "$N" >/dev/null 2>&1 || true
        echo "[PMM] re-triggered owning bot (cr) on #$N"
      fi
    else
      echo "[PMM] CodeRabbit rate cap hit — skipping explicit re-trigger on #$N"
    fi
    ;;
  bugbot)
    gh pr comment "$N" --body "@cursor review" >/dev/null 2>&1 \
      && echo "[PMM] re-triggered owning bot (bugbot) on #$N"
    ;;
  graphite)
    gh pr comment "$N" --body "@graphite-app re-review" >/dev/null 2>&1 \
      && echo "[PMM] re-triggered owning bot (graphite) on #$N"
    ;;
  greptile)
    echo "[PMM] greptile owning reviewer on #$N — no auto-trigger per greptile.md"
    ;;
  *)
    echo "[PMM] unknown reviewer on #$N — skipping explicit re-trigger"
    ;;
esac
```

Never batch mention strings; never auto-trigger Greptile. Set `TICK_HAD_ACTION=true` when dismissal or re-trigger posts.

**Re-gate and gate Step 5c** — re-run `.claude/scripts/merge-gate.sh "$N"`, stash in `GATE_BY_PR[$N]`, re-read `MET`, `CI_FAILING`, `STALE_BOT_CR`, `UNRESOLVED` (re-fetch unresolved thread count if needed). Then:
   - **`MET == true`** → treat as `wrap` for Step 5d this tick (skip Step 5c spawn for this PR).
   - **`CI_FAILING > 0` or `UNRESOLVED > 0`** → proceed to Step 5c spawn (real fix work remains).
   - **Otherwise** (reviewer pending on fresh trigger, no CI/thread fix work) → skip Step 5c; verdict becomes `waiting` on the next tick when the bot lands.

### Step 5c: Parallel `phase-a-fixer` dispatch (verdict `fixpr` — has-recoverable-blockers or merge-conflict)

Fix work runs in **parallel** via one `phase-a-fixer` subagent per PR, capped at `$PMM_MAX_PARALLEL` (default 3). Merge dispatch stays sequential (Step 5d) — merges affect main and must not race.

**Two fixer task types share this dispatch path:**

1. **CR/CI/thread fix work** (`fixpr` from CI failing, unresolved threads, or stale bot CR) — standard Phase A fixer workflow per `.claude/agents/phase-a-fixer.md`.
2. **Merge-conflict resolution** (`fixpr` with `merge-conflict` tag from `mergeable == CONFLICTING`, or from Step 5a rebase hitting conflicts) — same spawn shape, but the subagent prompt directs it to run the `/merge-conflict` skill workflow: rebase onto base → `resolve_merge_conflicts.py` for safe hunks → apply judgment to complex hunks → commit + force-push. Unresolvable conflicts exit with `OUTCOME: blocked` (see Step 2.5); the parent surfaces them as `BLOCKED:conflicts(needs-human)`.

Conflict dispatches participate in the same parallel cap, batched `session-state.sh --set` write, and `pmm-fix-$N` tracking as CR/CI fixers. Set the Subagent column to `dispatched (merge-conflict)` when spawning for conflict resolution.

**Idempotency and concurrency are already resolved in Step 3's refinement pass** (in-flight check + cap slot allocation), so the table printed in Step 4 already reflects which PRs will dispatch this tick. Step 5c dispatches every PR whose *refined* verdict is still `fixpr` **and** Step 5b′ did not re-gate it to `wrap`/`waiting` — it does not re-check `active_agents` or recompute slots. **Exception:** PRs whose Step 5a rebase aborted on conflicts override their refined verdict to `fixpr (merge-conflict)` in-place (see Step 5a) and are eligible for Step 5c dispatch in the same tick even though Step 4 already printed `rebase`. PRs refined to `awaiting fix subagent` or `queued (cap)` are skipped here with no further action; they are eligible again once Step 3 re-evaluates on a later tick.

**CR hourly cap (fleet-wide).** Before spawning, snapshot the budget:

```bash
CR_BUDGET_OK=1
.claude/scripts/cr-review-hourly.sh --check >/dev/null 2>&1 || CR_BUDGET_OK=0
```

If `$CR_BUDGET_OK == 0`, still spawn subagents but include `SKIP_CR_TRIGGER=1` in each prompt — subagents proceed without posting `@coderabbitai full review`. The skip surfaces in each subagent's exit report / handoff `notes`. Do **not** block spawn entirely when the cap is exhausted (unlike deferring all fix work).

**Bulk spawn (one Agent call per PR, all in parallel up to the cap).** For each PR allocated a slot, read `VERDICTS_JSON[$N].tag` — when it is `merge-conflict` (from Step 3 `mergeable == CONFLICTING` **or** Step 5a rebase abort), set `TASK_TYPE=merge-conflict` even if GitHub still reports `BEHIND`/`MERGEABLE`. Otherwise use `TASK_TYPE=fixpr`. Invoke the Agent tool with:

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
- Reviewer classification (`cr`, `bugbot`, or `greptile`) — omit or set to `none` for merge-conflict-only dispatches
- **Task type:** `fixpr` (CR/CI findings) or `merge-conflict` (conflict resolution) — for `merge-conflict`, include: "Run the `/merge-conflict` skill workflow: fetch main, rebase, run `resolve_merge_conflicts.py`, resolve complex hunks with judgment, commit + force-push. Exit with `OUTCOME: blocked` if conflicts are genuinely unresolvable."
- Handoff file path: `~/.claude/handoffs/pr-{N}-handoff.json`
- Pre-fetched findings from Step 3 (`FINDINGS_JSON[N]`) — omit for merge-conflict-only dispatches
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
IN_FLIGHT_SETS=()
# ONE loop per spawned PR — build that PR's entry AND its --set argument together,
# each using ONLY that PR's own head_sha. Never hoist head_sha into a shared
# variable reused across iterations or across a second loop — the last PR's SHA
# would silently overwrite every earlier PR's lock.
for N in $SPAWNED_PR_NUMS; do
  N_HEAD_SHA=$(jq -r '.head_sha' <<<"${GATE_BY_PR[$N]}")   # that PR's own tick-scoped $GATE
  ISSUE_N=$(.claude/scripts/pr-issue-ref.sh "$N" 2>/dev/null || echo null)
  AGENT_ID="pmm-fix-$N"
  ENTRY=$(jq -n --arg id "$AGENT_ID" --arg task "PMM fix PR #$N" --argjson issue "$ISSUE_N" \
    --argjson pr "$N" --arg launched "$NOW" --arg head_sha "$N_HEAD_SHA" \
    '{id:$id, task:$task, issue:$issue, pr:$pr, phase:"A", status:"spawned", launched:$launched, head_sha:$head_sha}')
  NEW_ENTRIES=$(jq --argjson entry "$ENTRY" '. + [$entry]' <<<"$NEW_ENTRIES")
  IN_FLIGHT_SETS+=(--set ".pmm_in_flight.\"$N\"={\"skill\":\"phase-a-fixer\",\"status\":\"active\",\"dispatched_at\":\"$NOW\",\"head_sha\":\"$N_HEAD_SHA\",\"agent_id\":\"$AGENT_ID\"}")
done

# After the loop — ONE read of the current array, ONE append of the whole batch, ONE write:
CURRENT_AGENTS=$(.claude/scripts/session-state.sh --get '.active_agents' 2>/dev/null || echo null)
[ "$CURRENT_AGENTS" = "null" ] && CURRENT_AGENTS='[]'
UPDATED_AGENTS=$(jq --argjson entries "$NEW_ENTRIES" '. + $entries' <<<"$CURRENT_AGENTS")
.claude/scripts/session-state.sh --set ".active_agents=$UPDATED_AGENTS" "${IN_FLIGHT_SETS[@]}"
```

Set Subagent column to `spawned` immediately for every PR in this batch; transition to `working` once each subagent reports activity (first tool call or ~30s elapsed).

**Safety boundaries for every subagent (non-negotiable):**

- Never modify branch protection
- Never dismiss human-authored reviews
- Never resolve a review thread without code-verification (per `phase-a-fixer` Step 5)

### Step 5d: Sequential `/wrap` dispatch (verdict `wrap` — merge-ready)

Merge-ready PRs get **sequential** `/wrap` dispatch — one at a time, never parallelized. Merges affect main branch state (main-sync, follow-up detection, lessons) and must not race. PMM never runs `gh pr merge` directly — landing always flows through the full `/wrap` workflow.

**Deferral gate — check this FIRST, before any lock acquisition or `/wrap` execution below.** "Fix subagents active this tick" means spawned just now by Step 5c OR still running from a prior tick — check both: any Step 5c spawn this tick, **or** a **blocking** Phase A `active_agents` entry (per Step 5's shared gate idiom — any `id`, not just `pmm-fix-` prefixed; stale foreign entries with no progress evidence are non-blocking; this must match Step 5a's rebase-skip check exactly: a foreign, non-PMM Phase A agent can hold the same PR's branch in its own worktree, and `/wrap` checking out or pushing to that branch races it just as much as a rebase would). This matters because a `/pmm-stop`-then-resume, or a tick where Step 3's refinement pass left every `fixpr` PR at `awaiting fix subagent`/`queued (cap)` with zero *new* spawns, would otherwise slip past a "spawned this tick" check while a background fixer is still mid-flight on a shared branch/worktree.

Process merge-ready PRs **only when no fix subagents are active this tick** (by the definition above) — run Step 5d sequentially before Step 5e. **If any fix subagents are active, stop here and defer all `/wrap` dispatches** until the Step 5e monitor loop has drained every active fix subagent — do not proceed to the idempotency check or lock acquisition below for any PR while the gate is closed. This keeps the parent out of concurrent parent work and honors dedicated monitor mode. **Foreign Phase A entries** blocking `/wrap` are drained by Step 5e's poll-based condition (entry disappearance from `active_agents`, terminal `status` flip, or `PMM_LOCK_STALE_SECS` staleness timeout with no progress evidence) — not by parsing an exit report — so the deferral gate always has a documented reopen path.

**Idempotency-gated via `pmm_in_flight`** (only reached once the deferral gate above is open):

```bash
INFLIGHT=$(.claude/scripts/session-state.sh --get ".pmm_in_flight.\"$N\"" 2>/dev/null || echo null)
```

Decision:

- `$INFLIGHT` has `status == "active"` → skip (verdict `awaiting prior /wrap`) unless stale per `PMM_LOCK_STALE_SECS` (default **3600s**) with no live progress evidence.
- `$INFLIGHT` is `null` (or stale lock broken) → proceed to merge dispatch below.

**Merge dispatch — no confirmation prompt by default.** When `VERDICT == wrap`:

1. **When `PMM_CONFIRM_MERGES` is true:** emit a per-PR confirmation prompt ("Merge-ready: dispatch `/wrap` for #N?") **before** acquiring any lock. If declined, skip this PR this tick with **no** `pmm_in_flight` write — do not leave a stale lock.
2. **When confirmed (or when `PMM_CONFIRM_MERGES` is false):** acquire the idempotency lock, then dispatch immediately:

```bash
NOW=$(date -u +%FT%TZ)
HEAD_SHA=$(jq -r '.head_sha' <<<"${GATE_BY_PR[$N]}")
.claude/scripts/session-state.sh --set \
  ".pmm_in_flight.\"$N\"={\"skill\":\"wrap\",\"status\":\"active\",\"dispatched_at\":\"$NOW\",\"head_sha\":\"$HEAD_SHA\"}"
```

Default (`PMM_CONFIRM_MERGES` false): dispatch the **full** `/wrap` workflow inline (all 4 phases) immediately — invocation already authorized it per `CLAUDE.md`'s merge-auth exception.

Execute the **full** `/wrap` workflow inline (all 4 phases). PMM relies on `/wrap`'s own gate re-check (`merge-gate.sh`) and AC verification (`ac-checkboxes.sh`) — if the gate is no longer met (SHA moved, CI regressed) or AC fails, `/wrap` stops and returns a hard block; PMM records it and re-classifies on the next tick without re-authorizing or re-prompting.

On completion:

- `/wrap` merged the PR → clear `pmm_in_flight[N]`; append `#N` to `MERGED_THIS_TICK` and `MERGED_THIS_SESSION` (dedupe on append); PR drops from fleet on next `gh pr list`.
- `/wrap` returned a hard block → clear in-flight and add `#N` to `HARD_BLOCK[]` for reporting (Step 4 next tick). Do **not** force-stop the fleet — the hard-blocked PR is dropped from actionable work and the idle counter handles convergence to Pause.

### Step 5e: Dedicated monitor mode while fix subagents are active

If any **blocking** fix subagents are active this tick (per Step 5's shared gate idiom and the deferral-gate definition in Step 5d — spawned now or carried over from a prior tick), **immediately enter an orchestration-only posture borrowing `monitor-mode.md`'s Dedicated Monitor Mode discipline** — the **parent's** ONLY job until every blocking fix subagent completes, fails, or is drained (foreign: disappearance / terminal `status` / `PMM_LOCK_STALE_SECS` staleness timeout) is orchestration (poll, verify, heartbeat); the parent does no direct feature-code edits, no local CR review, no substantive source analysis — but its subagents edit code, resolve conflicts, and push as designed. **PMM does NOT execute `monitor-mode.md`'s Monitor Loop Per-Cycle Checklist verbatim** — specifically, it never runs `phase-protocols.md`'s Phase Completion Protocols, which would otherwise auto-launch Phase B after Phase A. Step 2.5's aggregation fully replaces that: PMM fixes and pushes only, per Step 0's contract ("PMM does not launch Phase B/C after Phase A").

**PMM's own monitor loop (~60s cadence — replaces, not layers on, `monitor-mode.md`'s checklist):**

1. **Poll active subagent statuses — ownership-aware drain.** Each ~60s cycle, read `active_agents` and partition the Phase A entries gating deferred PRs into **PMM-owned** (`id` starts with `pmm-fix-`) and **foreign** (any other `id`) sets.

   **PMM-owned entries:** Transition Subagent column: `spawned` → `working` → `complete` / `failed`. On completion (success, exhaustion, or crash), proceed to item 2 below.

   **Foreign entries:** PMM has no exit report to parse and must never clean up or remove state it does not own — foreign agents drain by poll-based observation only (see below). While waiting, surface the PR's Subagent column as `deferred(foreign-agent)`.

   For each foreign Phase A entry, the **drain signal** is:
   - The entry **disappears** from `active_agents` (authoritative — the owning workflow removed it), **or**
   - Its `status` flips to `complete` or `failed` (secondary/opportunistic — honored only if the owning workflow happens to set it).

   PMM must **not** perform worktree cleanup, remove, or mutate the foreign entry or any foreign lock — the owning workflow cleans up under its own rules. PMM only observes and stops deferring once the entry is gone or terminal.

   **Staleness fallback (foreign only):** Reuse `PMM_LOCK_STALE_SECS` (default 3600s), applied to the foreign entry's freshness timestamp (`last_seen_at` if present, else `launched`). When the entry exceeds the staleness window **and** there is no live evidence of progress on that PR (HEAD SHA unchanged since the timestamp, no new bot/CI activity since the timestamp), log the stale foreign agent, surface the Subagent column as `foreign-agent-stale`, and treat the entry as **non-blocking** per Step 5's shared gate idiom — the deferral gate reopens for that PR so `/wrap` may proceed after the monitor loop exits (rebase on the next tick also proceeds, since Step 5a uses the same idiom). Same conservatism as the existing lock-staleness idiom — the wide window and no-progress corroboration prevent pre-empting a healthy long-running foreign fixer; PMM still does not touch the foreign entry, it only stops waiting on it.

   **Gate reopen:** Once a PR has no remaining **blocking** Phase A entry of either kind (PMM-owned or foreign — foreign entries past `PMM_LOCK_STALE_SECS` with no progress evidence count as non-blocking even if the row remains in `active_agents`), the deferral gate for that PR reopens and its deferred `/wrap` dispatch proceeds after the monitor loop exits, per existing Step 5d/5e ordering.

2. **On PMM-owned completion** — success, exhaustion, or crash — **run Step 2.5's steps 1-3 in full** (parse exit report, worktree cleanup, remove this agent's own `active_agents` record + clear `pmm_in_flight[N]`) before branching on outcome. When OUTCOME is `pushed_fixes`, also run **Step 5b dismiss helper + Step 5b′ owning-bot re-trigger** on that PR (issue #514 — mirrors `/fixpr` 3a/3b; set `TICK_HAD_ACTION=true` if dismissal or re-trigger posts). This is unconditional, not just the success path — a failure that skips clearing `pmm_in_flight[N]` would otherwise leave a stale lock blocking Step 3's idempotency check until `PMM_LOCK_STALE_SECS` expires. Foreign entries are out of scope for this item — they drain per item 1's poll/staleness signal only.
3. Branch on outcome for **PMM-owned** entries only (per Step 2.5's step 4, cleanup from item 2 above already done):
   - **Crash / no exit report / stale >15 min:** mark `failed` in the table and add `#N` to `HARD_BLOCK[]` with reason `crashed(needs-approval)` — never re-dispatch silently. Reported once and dropped from the actionable fleet this tick (do **not** force-stop — see Step 3's `HARD_BLOCK[]` handling); the user can explicitly approve a respawn (`subagent-orchestration.md`: "Ask first only: ... respawning a crashed/no-handoff subagent").
   - **`blocked` (unresolvable merge conflict or other fix blocker):** add `#N` to `HARD_BLOCK[]` with reason from the exit report (e.g. `conflicts(needs-human)`). Report once and drop from the actionable fleet — do not re-dispatch silently.
   - **Token/turn exhaustion with a valid handoff file:** respawn immediately **using Step 5c's spawn pattern**, but with **freshly re-fetched** gate and findings data for this PR — do NOT reuse tick-start `GATE_BY_PR[$N]`/`FINDINGS_JSON[$N]` verbatim. Real time has passed since Step 3 computed them, and the exhausted subagent may have pushed partial progress before running out of tokens, moving the PR's actual HEAD SHA and review state past that tick-start snapshot; a respawn using the stale SHA/findings would hand the replacement outdated context. Re-run `.claude/scripts/merge-gate.sh "$N"` (and re-fetch findings from the three endpoints, same as Step 3's pre-fetch) immediately before building the replacement's spawn record, and use *that* fresh result — not the cached tick-start one — for its `head_sha`, `GATE_BY_PR[$N]` update, and prompt findings. This is an "Always do" action per `subagent-orchestration.md`'s Token/Turn Exhaustion Protocol — do not wait for the next tick, and do NOT defer to Step 2.5's exhaustion handling here (Step 2.5's deferral only works at tick-*start*, before Step 3 has run; Step 5e is mid-tick, after Step 3 already ran, so an inline respawn is possible here — it just needs fresh data, not the tick-start cache).
4. Send heartbeat if >5 min since last user message (timestamp prefix required).
5. Investigate stale **PMM-owned** agents (>15 min Phase A without progress). Foreign staleness is handled by item 1's `PMM_LOCK_STALE_SECS` fallback.

**While subagents run:** do not start rebases, new spawns for other PRs, or `/wrap` dispatches. **Exception:** an exhaustion respawn (item 3 above) for a PR already in this tick's active-fixer set is a continuation of already-approved fix work, not a new spawn — it is exempt from this restriction and proceeds inline. Deferred merge-ready PRs from Step 5d run immediately after the monitor loop exits (all fix subagents — PMM-owned or foreign — complete, fail, or are drained via staleness timeout). The tick completes only after all spawned fix subagents return (or fail) and any deferred `/wrap` dispatches finish. Then proceed to Step 6.

**#497 compatibility (idle auto-pause):** when all subagents exit and no parent dispatches remain in-flight, treat the tick as idle for digest/backoff purposes — the stable-state countdown in Step 6 applies as if the tick were a no-op dispatch tick.

**Tick merge summary.** After all Step 5 actions complete, if `MERGED_THIS_TICK` is non-empty, print one line per merged PR (already recorded in `MERGED_THIS_SESSION` at `/wrap` completion — do not append again here):

```text
merged #N
```

Initialize `MERGED_THIS_SESSION='[]'` on the first tick in Step 0/Step 1.

---

## Step 6: Stable-state backoff + idle streak (per `scheduling-reliability.md`)

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

### Idle tick definition + `pmm_idle_streak`

An **idle tick** is one where **all** of the following hold:

1. **No dispatch fired** — `TICK_HAD_ACTION=false` from Step 5 (no rebase, no fix subagent spawn, no `/wrap`, no reviewer trigger).
2. **No state change vs prior tick** — fleet digest unchanged (`DIGEST == PREV` from above).
3. **No active fix subagents** — no **blocking** Phase A `active_agents` entry (per Step 5's shared gate idiom — stale foreign entries with no progress evidence do not count). A tick can have `TICK_HAD_ACTION=false` and an unchanged digest while a long-running Phase A fixer from a prior tick is still working — that is not idle, and counting it as such risks auto-pausing mid-fix.

Maintain a dedicated **`pmm_idle_streak`** counter (flat, sibling to `pmm_digest_streak`):

```bash
IDLE_PREV=$(.claude/scripts/session-state.sh --get '.pmm_idle_streak' 2>/dev/null || echo 0)
[ "$IDLE_PREV" = null ] && IDLE_PREV=0
ACTIVE_FIXERS=$(jq '[.[] | select(.phase == "A" and (.status != "complete" and .status != "failed"))] | length' \
  <<<"$(.claude/scripts/session-state.sh --get '.active_agents' 2>/dev/null || echo '[]')")
if [ "$TICK_HAD_ACTION" = false ] && [ "$DIGEST" = "$PREV" ] && [ "$ACTIVE_FIXERS" -eq 0 ]; then
  IDLE_STREAK=$((IDLE_PREV + 1))
else
  IDLE_STREAK=0
fi
.claude/scripts/session-state.sh --set ".pmm_idle_streak=$IDLE_STREAK"
```

**`pmm_idle_streak` is orthogonal to cadence widening** — widening 5m→15m via `pmm_digest_streak` must **not** reset `pmm_idle_streak`. Only an action or digest change resets the idle counter. Three idle ticks at the widened 15-min cadence still counts toward auto-pause.

---

## Step 7: Stop routing, Pause routing, then establish / re-arm the polling loop

**First, check the stop/pause conditions.** Routing order:

1. **User command** — `/pmm-stop` (or "stop monitoring PRs"). See the companion `/pmm-stop` skill → **Stop & Clean Exit**.
2. **Empty fleet** — `PR_COUNT == 0` from Step 2 → **immediate Pause** (Step 8) with reason `empty fleet` (no 3-tick wait).
3. **Idle streak** — `pmm_idle_streak >= PMM_IDLE_PAUSE_AFTER` → **Pause** (Step 8) with reason `"$PMM_IDLE_PAUSE_AFTER idle ticks"`.
4. Otherwise → **re-arm the loop** (below).

Hard-blocked PRs (`HARD_BLOCK[]`, including a crashed/no-handoff `phase-a-fixer` awaiting respawn approval — `crashed(needs-approval)`, Step 2.5/5e) do **not** trigger Stop or Pause by themselves — they are reported and dropped from the actionable fleet; the idle counter handles convergence when nothing actionable remains.

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
  --set ".pmm_last_tick_at=\"$NOW\"" \
  --set ".pmm_idle_streak=$IDLE_STREAK"
# On the FIRST tick also set .pmm_started_at; every tick set the next-expected watermark.
```

**Pre-exit checklist (run before ending every polling turn — `scheduling-reliability.md`):**

1. **Next tick scheduled?** Confirm `/loop` is active/re-armed at `$EFFECTIVE_CADENCE` (or stopped/paused per the routing above).
2. **Heartbeat sent?** The Step 4 timestamped table is the heartbeat — never end a tick silently.
3. **State recorded?** `pmm_active`, cadence, watermarks, `pmm_in_flight`, `active_agents`, `pmm_digest(_streak)`, `pmm_idle_streak` written to `session-state.json`.

---

## Pause (auto-pause — resumable)

Reached from Step 7 when the fleet is empty or idle. Unlike Stop & Clean Exit, Pause preserves a resume marker so `/pr-monitor-and-manage-wake` or re-invoking this skill can pick up where it left off.

### 1. Final heartbeat

Print the Step 4 status table one last time, then a one-line reason:

```text
[$TS] PMM pausing — reason: <empty fleet | N idle ticks>
```

### 2. Cancel the loop

Cancel the recurring `/loop` (same guidance as Stop & Clean Exit):

- If the runtime exposes a loop id / cancel handle, cancel it explicitly.
- Otherwise interrupt the active loop. The next tick must not re-arm.

### 3. Build fleet snapshot + config for the pause marker

```bash
NOW=$(date -u +%FT%TZ)
# fleet_at_pause: array of {pr, head_sha, state} from Step 2 PR_LIST (headRefOid + mergeStateStatus)
FLEET_AT_PAUSE=$(jq -c '[.[] | {pr: .number, head_sha: .headRefOid, state: .mergeStateStatus}]' <<<"$PR_LIST")
CONFIG_AT_PAUSE=$(jq -nc \
  --arg author "$PMM_AUTHOR" --arg repo "$OWNER_REPO" --arg cadence "$PMM_CADENCE" \
  --argjson max_parallel "$PMM_MAX_PARALLEL" \
  --argjson idle_pause_after "$PMM_IDLE_PAUSE_AFTER" \
  --argjson auto_wake "$PMM_AUTO_WAKE" --arg auto_wake_cadence "$PMM_AUTO_WAKE_CADENCE" \
  --argjson confirm_merges "$PMM_CONFIRM_MERGES" \
  '{author:$author, repo:$repo, cadence:$cadence, max_parallel:$max_parallel, idle_pause_after:$idle_pause_after, auto_wake:$auto_wake, auto_wake_cadence:$auto_wake_cadence, confirm_merges:$confirm_merges}')
```

> **Wake coupling:** `/pr-monitor-and-manage-wake` Step 4b rebuilds `PMM_FLAGS` from this blob — including `--confirm-merges` when `confirm_merges` is true — before re-arming the loop.

> **Schema note:** pause marker fields live under nested `.pmm.*` per the AC; existing runtime fields (`pmm_active`, `pmm_digest`, `pmm_idle_streak`, etc.) remain flat.

### 4. Write pause marker (atomic batch)

```bash
.claude/scripts/session-state.sh \
  --set ".pmm.paused_at=\"$NOW\"" \
  --set ".pmm.fleet_at_pause=$FLEET_AT_PAUSE" \
  --set ".pmm.config_at_pause=$CONFIG_AT_PAUSE" \
  --set '.pmm_active=false' \
  --set '.pmm_next_expected_tick_at=null'
```

Preserve `pmm_digest`, `pmm_digest_streak`, and `pmm_idle_streak` as audit trail.

### 5. Optional auto-wake cron (`--auto-wake`)

When `$PMM_AUTO_WAKE` is true, register a durable hourly scan at pause time:

```bash
# Derive cadence minutes from PMM_AUTO_WAKE_CADENCE (e.g. 60m → 60)
AW_CADENCE_MIN="${PMM_AUTO_WAKE_CADENCE%m}"
if [ "$AW_CADENCE_MIN" -ge 60 ] && [ $((AW_CADENCE_MIN % 60)) -eq 0 ]; then
  # off-peak-minute.sh's --every-n-min only accepts 1..59 (it builds a step-range
  # within one hour) — for hourly-or-longer cadences (the 60m default), use the
  # plain no-flag minute + a */H hour step instead, matching /pm's hourly pattern.
  AW_HOURS=$((AW_CADENCE_MIN / 60))
  AW_MINUTE=$(.claude/scripts/off-peak-minute.sh)
  if [ "$AW_HOURS" -eq 1 ]; then
    AW_CRON="$AW_MINUTE * * * *"
  else
    AW_CRON="$AW_MINUTE */$AW_HOURS * * *"
  fi
else
  { read -r AW_MINUTE; read -r AW_CRON; } < <(.claude/scripts/off-peak-minute.sh --every-n-min "$AW_CADENCE_MIN")
fi
# CronCreate with prompt "/pr-monitor-and-manage-wake --auto-check", cron="$AW_CRON", recurring=true, durable=true
# Persist returned job id to .pmm.auto_wake_cron_id and append to polling_jobs[]
```

Follow `scheduling-reliability.md`: cross-session durability requires `CronCreate` (not `/loop`). Tell the user the cron job id and 7-day auto-expiry.

### 6. Summary line

```text
PMM paused — <N> PR(s) waiting on reviewer, no changes for <idle window>. Wake with `/pr-monitor-and-manage-wake` or re-run `/pr-monitor-and-manage <flags>`.
```

If `--auto-wake` is set, add: `Auto-wake cron registered (<job_id>) — will scan hourly for fleet changes.`

> **Post-merge symlink:** after this skill's `-wake` companion merges to `main`, symlink `~/.claude/skills/pr-monitor-and-manage-wake` → the skills-worktree copy per `skill-symlinks.md`.

---

## Stop & Clean Exit

Reached from Step 7 when the **user** invokes `/pmm-stop`. Tear down and report (this is a terminal stop — no resume marker):

```bash
.claude/scripts/session-state.sh --set '.pmm_active=false' --set '.pmm_next_expected_tick_at=null'
# Best-effort: cancel the loop if a loop-id mechanism is available; otherwise the
# user's /pmm-stop / interrupt drops it.
```

Print a final summary:

```text
=== PR fleet monitoring ended ===
Reason:   <user-stop>
Fleet:    <final status table>
Pre-flight: <per-PR draft→ready + reviewers triggered this session, from each PR's PREFLIGHT_SUMMARY; "clean" where no-op>
Actions:  <rebases / phase-a-fixer subagents / /wrap dispatched this session, per PR — include Subagent outcomes>
Merged:   <PR #s successfully merged this session via /wrap — e.g. "#1599, #1601"; "none" if none>
Subagents: <per-PR spawn/complete/failed summary from active_agents audit>
Blocked:  <PR # + reason for each HARD_BLOCK entry reported this session — e.g. "#123 human CHANGES_REQUESTED by @alice">
```

Hard-blocked PRs are reported here for visibility; the fleet may auto-pause afterward when idle.

---

## Safety boundaries (HARD STOPS — `safety.md`, `cr-merge-gate.md`)

This skill is a **parent orchestrator**. The parent rebases/force-pushes (Step 5a), spawns parallel `phase-a-fixer` subagents for fix work (including merge conflicts), and dispatches `/wrap` sequentially for merges. Subagents edit code, resolve conflicts, fix findings, push, and reply/resolve threads — that is their purpose. The parent never reimplements fix/merge/resolve logic directly. The following are absolute:

- **Parent never edits feature code directly** — dispatch a `phase-a-fixer` subagent instead. Subagents are explicitly permitted and expected to edit feature code.
- **Never modify branch protection** — no calls to `.../branches/.../protection`. Subagents inherit this prohibition.
- **Never dismiss human reviews** — only Bot-allowlist `CHANGES_REQUESTED` on a stale `commit_id` (Steps 5b and 5b′, plus post-subagent dismiss in Step 2.5/5e after a push). Human CR is a hard block. Subagents must not dismiss human-authored reviews.
- **Never resolve a review thread without code-verification** — thread resolution happens only inside `phase-a-fixer` Step 5 after verifying the fix. This skill only *counts* unresolved threads.
- **Never bypass AI-reviewer rate caps** — `cr-review-hourly.sh` gates every CR re-trigger; Greptile/CodeAnt caps are respected by subagents and `/wrap`. The Step 5.0 pre-flight (`pr-preflight.sh`, issue #493) is the sanctioned per-PR trigger path: it gates `@coderabbitai full review` on `cr-review-hourly.sh`, never triggers Greptile, never flips another user's draft, and is strictly per-PR (no shared accumulator — a flip/trigger on one PR never leaks to another).
- **Never use GitHub's update-branch API** for `BEHIND` — only `git rebase origin/main` + `--force-with-lease`.
- **Stay in the worktree; never run destructive commands in the root repo** — no `git clean`, `git reset --hard`, or `.env` edits anywhere.
- **Never merge directly** — PMM never runs `gh pr merge` itself. It lands PRs only by dispatching the full `/wrap` workflow inline; `/wrap` carries the merge authorization (after its gate + AC verification). No bypass path exists.
