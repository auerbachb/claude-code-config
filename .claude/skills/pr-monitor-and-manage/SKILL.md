---
name: pr-monitor-and-manage
description: Thread-level PR fleet manager. Rediscovers your open PRs every tick, prints a status table, and auto-dispatches the per-PR decision tree (rebase / /fixpr / /wrap) until the fleet is clean or hard-blocked. Triggers on "/pr-monitor-and-manage", "/pmm", "manage PRs", "PR fleet", "watch PRs".
triggers:
  - pr-monitor-and-manage
  - pmm
  - manage PRs
  - PR fleet
  - watch PRs
  - manage my open PRs
argument-hint: "[--author <login>] [--repo <owner/repo>] [--cadence Nm] (defaults: author=current gh user, repo=current, cadence=5m)"
---

Thread-level **PR fleet manager**. This skill turns the current thread into a dedicated monitor that watches every open PR you own and drives each one to merge-ready (or a named hard block) by dispatching the per-PR decision tree on a recurring cadence.

> **Per-PR dispatch is inlined below.** `TODO: refactor to call /babysit-pr per discovered PR after #456 lands.` Until #456 merges, Step 3's decision tree is the single owner of per-PR logic. When `/babysit-pr` exists, replace Step 3's inline branches with one `/babysit-pr <PR>` dispatch per discovered PR — the table, discovery, idempotency, and backoff scaffolding here stay unchanged.

This is a **set-and-monitor** command. Once invoked it acknowledges the mode, establishes a `/loop`, and at every tick reprints the fleet table and acts. It never writes feature code and never drifts into unrelated work.

---

## Step 0: Enter PR-fleet-manager mode (MANDATORY, first tick only)

On the **first** invocation in a thread, acknowledge the mode up front so the constraints are explicit and survive context compaction:

> **PR-fleet-manager mode active.** My only job in this thread is to watch and manage your open PRs as a fleet — rediscover them each tick, print a status table, and dispatch rebase / `/fixpr` / `/wrap` per the decision tree. I will not write feature code, start issues, or do unrelated work here.

**Prohibited in this thread (refuse and redirect):**

- Writing or editing **feature code** of any kind.
- Invoking `/start-issue`, `/prompt`, or spawning coding subagents for new work.
- Creating issues or PRs (other than the follow-ups `/wrap` itself creates on merge).
- Any task unrelated to managing the discovered PR fleet.

**Refusal template** when asked for a prohibited activity:

> That's outside PR-fleet-manager mode. I'm keeping this thread focused on monitoring your open PRs. Start a separate thread (e.g. `/start-issue`) for that work — say `/pmm-stop` first if you want me to stop monitoring here.

This skill is read-only with respect to source: the only writes it performs are git rebase/force-push (Step 3), and the bounded mutations that `/fixpr` and `/wrap` already own. It dispatches those skills; it does not reimplement their fix/merge logic.

---

## Step 1: Parse arguments + identify the fleet (every tick)

Parse `$ARGUMENTS` (re-parse every tick — a `/loop` re-invocation passes the same args, but treat them as the source of truth, never a cached value):

- `--author <login>` — whose PRs to manage. **Default:** the current authenticated user via `gh api user --jq .login`.
- `--repo <owner/repo>` — which repo. **Default:** the current repo.
- `--cadence Nm` — base poll interval. **Default:** `5m`.

```bash
# Defaults
PMM_AUTHOR=""; PMM_REPO=""; PMM_CADENCE="5m"
# (parse $ARGUMENTS into the three vars above; bare flags override defaults)

if [ -z "$PMM_AUTHOR" ]; then
  PMM_AUTHOR=$(gh api user --jq .login 2>/dev/null || true)
  if [ -z "$PMM_AUTHOR" ]; then
    echo "WARNING: gh api user failed — pass --author <login> explicitly"; exit 1
  fi
fi
REPO_FLAG=(); [ -n "$PMM_REPO" ] && REPO_FLAG=(--repo "$PMM_REPO")

# Resolve owner/repo for the GraphQL + REST calls used in Step 3 (honors --repo).
OWNER_REPO="${PMM_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
OWNER="${OWNER_REPO%/*}"; REPO="${OWNER_REPO#*/}"
echo "[PMM] fleet = author:$PMM_AUTHOR repo:$OWNER_REPO cadence:$PMM_CADENCE"
```

---

## Step 2: Discover open PRs (every tick — NEVER cache across ticks)

**Rediscover the fleet on every single tick.** A PR may have merged, closed, or been opened since the last tick — a cached list silently rots. Always re-run `gh pr list`:

```bash
PR_LIST=$(gh pr list --state open --author "$PMM_AUTHOR" "${REPO_FLAG[@]}" \
  --json number,title,headRefName,mergeStateStatus,reviewDecision --limit 100)
PR_NUMS=$(jq -r '.[].number' <<<"$PR_LIST")
PR_COUNT=$(jq 'length' <<<"$PR_LIST")
```

**Empty fleet → clean exit.** If `PR_COUNT == 0`, jump to **Stop & Clean Exit** with "Fleet empty — no open PRs found". Do not keep polling an empty fleet.

---

## Step 3: Gather per-PR state (in parallel) + classify + act

For **each** PR number, gather state. Run the per-PR fetches **in parallel across PRs** (one batch of background jobs, then collect), since they are independent network calls:

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
```

### Decision tree (per PR — first match wins)

Read `merge_state` / `mergeable` **literally** from the gate JSON. **Do NOT infer `BEHIND` from `BLOCKED`** — `BLOCKED` also covers missing checks/reviews, not just behind-base. Only the literal `BEHIND` triggers a rebase.

| Condition (checked in order) | Action | Verdict cell |
|------------------------------|--------|--------------|
| `human_changes_requested` non-empty (human CR on HEAD) | **Hard block.** Name each login. Never auto-dismiss. | `BLOCKED:human(@login)` |
| `mergeable == CONFLICTING` | **Hard block.** Surface; recommend `/merge-conflict`. Do not auto-merge. | `BLOCKED:conflicts` |
| `merge_state == BEHIND` | **Rebase** (see Step 3a) + `git push --force-with-lease`, then dismiss stale bot reviews (Step 3b). | `rebased` |
| `CI_FAILING > 0` **or** `UNRESOLVED > 0` | **Dispatch `/fixpr`** (idempotency-gated, Step 3c). | `→/fixpr` |
| `MET == true` (gate fully met: clean review on HEAD + CI green + 0 unresolved threads + no blockers) | **Dispatch `/wrap`** (idempotency-gated, Step 3c). | `→/wrap` |
| Otherwise (CI in-progress, awaiting reviewer, `REVIEW_REQUIRED`, `UNKNOWN`) | **No-op.** Reviewer/CI owns the next move. | `waiting` |

`merge-gate.sh` exit `3` (PR gone — merged/closed between Step 2 and now) → drop the PR from the fleet this tick and note it. Exit `2`/`4` (tooling/network) → mark `error` in the Verdict cell, do not dispatch, retry next tick.

### Step 3a: Rebase (only when `merge_state == BEHIND`)

**Use `git rebase origin/main` + `git push --force-with-lease` — NEVER GitHub's update-branch API.** The API creates bot merge commits that block CI; `auto-update-prs.yml` was removed for exactly this reason.

```bash
# Pre-flight: never rebase on a dirty tree. This skill runs from a worktree;
# stay in it and never touch the root repo (safety.md).
if [ -n "$(git status --porcelain)" ]; then
  echo "[PMM] PR #$N BEHIND but working tree dirty — skipping rebase, surfacing"; # verdict: error:dirty
else
  git fetch origin main --quiet
  git checkout "$HEADREF" 2>/dev/null || git switch "$HEADREF"
  if git rebase origin/main; then
    git push --force-with-lease
    REBASED_SHA=$(git rev-parse HEAD)
  else
    git rebase --abort
    echo "[PMM] PR #$N rebase hit conflicts — hard block, recommend /merge-conflict"; # verdict: BLOCKED:conflicts
  fi
fi
```

If the checkout/rebase cannot proceed (branch not present locally, multiple worktrees), surface the PR as `error` and leave it for the user rather than guessing.

### Step 3b: Dismiss stale bot reviews after a force-push

Run only after Step 3a actually force-pushed. Use the shared helper; **note the macOS bash 3.x blocker**:

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

### Step 3c: Idempotency-gated dispatch of `/fixpr` and `/wrap`

**Never re-dispatch a skill for a PR while a prior invocation is still in flight.** Track in-flight dispatches in `session-state.json`:

```bash
INFLIGHT=$(.claude/scripts/session-state.sh --get ".pmm_in_flight.\"$N\"" 2>/dev/null || echo null)
```

- If `$INFLIGHT` is non-null **and** its `dispatched_at` is within the last **30 minutes** **and** the PR's HEAD SHA is unchanged since dispatch → **skip**; Verdict cell shows `awaiting prior <skill>`.
- Otherwise record the dispatch, then run the skill:

```bash
NOW=$(date -u +%FT%TZ)
HEAD_SHA=$(jq -r '.head_sha' <<<"$GATE")
.claude/scripts/session-state.sh --set \
  ".pmm_in_flight.\"$N\"={\"skill\":\"$SKILL\",\"dispatched_at\":\"$NOW\",\"head_sha\":\"$HEAD_SHA\"}"
```

Then execute the **full** skill workflow inline in this thread (`/fixpr` = its Steps 0–7 including the Step 4d wait loop; `/wrap` = its 4 phases). Do not shell out to an opaque wrapper. On completion:

- `/fixpr` finished (any terminal `Status:`) → **clear** `pmm_in_flight[N]` so the next tick re-evaluates the new SHA.
- `/wrap` merged the PR → clear `pmm_in_flight[N]`; the PR drops out of the fleet on the next `gh pr list`.
- `/fixpr`/`/wrap` returned a **hard block** (`NEEDS_HUMAN_REVIEW`, `CONFLICTS`, `NEW_FINDINGS` at cap, CR budget exhausted, human CR) → clear in-flight and route to the hard-block stop condition.

**CR rate-cap respect (before any `/fixpr` that may trigger CodeRabbit):** `/fixpr` already calls `cr-review-hourly.sh` internally, but check first here so the table can show `rate-limited` instead of dispatching into an exhausted budget:

```bash
if ! .claude/scripts/cr-review-hourly.sh --check >/dev/null 2>&1; then
  echo "[PMM] CR hourly budget exhausted — deferring /fixpr CR triggers on #$N"; # verdict: rate-limited
fi
```

---

## Step 4: Print the status table (the per-tick heartbeat — EVERY tick, before dispatch)

The table is this skill's heartbeat. Print it **every tick** and **before** executing any dispatch action, so the classification is visible even if a dispatch is long-running. Lead with an Eastern-time timestamp (per `CLAUDE.md` #1):

```bash
TS=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET')
echo "[$TS] PMM tick — $PR_COUNT PR(s) in fleet (author:$PMM_AUTHOR)"
```

| Issue | PR | State | Reviews | CI | Unresolved Threads | Verdict |
|-------|----|-------|---------|----|--------------------|---------|
| #<issue or —> | #<N> | <merge_state> | <review_decision> | <pass>/<fail>/<prog> | <count> | <action this tick> |

- **Issue** — from `pr-issue-ref.sh`, or `—` when the PR body has no closing keyword.
- **State** — literal `merge_state` (`CLEAN`/`BEHIND`/`BLOCKED`/`CONFLICTING`/`UNKNOWN`).
- **Reviews** — literal `review_decision` (`APPROVED`/`CHANGES_REQUESTED`/`REVIEW_REQUIRED`).
- **CI** — `passing`/`failing`/`in_progress` counts from the gate.
- **Unresolved Threads** — count of `isResolved == false` (or `?` if the GraphQL fetch failed).
- **Verdict** — what this tick did/decided: `rebased`, `→/fixpr`, `→/wrap`, `waiting`, `awaiting prior /fixpr`, `rate-limited`, `BLOCKED:human(@x)`, `BLOCKED:conflicts`, `error`.

After the table, dispatch the actions from Step 3 (rebase / `/fixpr` / `/wrap`) for the PRs whose verdict calls for them.

---

## Step 5: Stable-state backoff (per `scheduling-reliability.md`)

Compute a **per-tick fleet digest** and track a streak so an idle fleet stops hammering the API. Hash the per-PR tuple `(number, head_sha, merge_state, review_decision, ci_blocking_count, unresolved_threads)` across the whole fleet (sorted by PR number for stability):

```bash
DIGEST=$(printf '%s' "$FLEET_TUPLE_SORTED" | sha256sum | awk '{print $1}')
PREV=$(.claude/scripts/session-state.sh --get '.pmm_digest' 2>/dev/null || echo null)
STREAK=$(.claude/scripts/session-state.sh --get '.pmm_digest_streak' 2>/dev/null || echo 0)
[ "$STREAK" = null ] && STREAK=0
if [ "$DIGEST" = "$PREV" ]; then STREAK=$((STREAK+1)); else STREAK=0; fi
.claude/scripts/session-state.sh --set ".pmm_digest=\"$DIGEST\"" --set ".pmm_digest_streak=$STREAK"
```

Backoff schedule (matches `scheduling-reliability.md` "Stable-State Backoff"):

- **Streak ≥ 3** → widen base cadence to **15m**: re-arm with `/loop 15m /pr-monitor-and-manage <same args>`.
- **Any digest change** (or a new user message) → reset streak to 0 and restore the configured base cadence.
- **Streak ≥ 9** → the fleet has been frozen for many ticks; print a suggestion to `/pmm-stop` (the user can re-invoke when something changes) but do not force-stop unless a hard block is also present.

A widened cadence is per-fleet here (one loop), but each PR keeps its own row in the digest tuple so a single PR changing state resets the whole loop to base cadence — the cheapest correct behavior for a single shared loop.

---

## Step 6: Establish / re-arm the polling loop

`/loop` is the **canonical** primitive for this recurring poll — never a hand-rolled `ScheduleWakeup` chain (`scheduling-reliability.md`). On the first tick, establish it and state the cancel command in the same message:

```text
/loop <cadence> /pr-monitor-and-manage <original args>
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

1. **Next tick scheduled?** Confirm `/loop` is active/re-armed (or widened per Step 5).
2. **Heartbeat sent?** The Step 4 timestamped table is the heartbeat — never end a tick silently.
3. **State recorded?** `pmm_active`, cadence, watermarks, `pmm_in_flight`, `pmm_digest(_streak)` written to `session-state.json`.

---

## Stop & Clean Exit

Terminate the loop and report when **any** stop condition holds:

1. **User command** — `/pmm-stop` (or "stop monitoring PRs"). See the companion `/pmm-stop` skill.
2. **Empty fleet** — `gh pr list` returns zero PRs (all merged/closed).
3. **Hard-blocked PR requiring human judgment:**
   - **Human `CHANGES_REQUESTED`** on a PR's current HEAD (`human_changes_requested` non-empty) — name the reviewer; never auto-dismiss.
   - **CR budget exhausted** — `cr-review-hourly.sh --check` exits 1 and no other PR is actionable.
   - **Greptile P0** — a Greptile P0 finding persists after `/fixpr` (per `greptile.md` severity gate).
   - **`mergeable == CONFLICTING`** that the rebase path could not auto-resolve.

On exit:

```bash
.claude/scripts/session-state.sh --set '.pmm_active=false'
# Best-effort: cancel the loop if a loop-id mechanism is available; otherwise the
# user's /pmm-stop / interrupt drops it. Clear stale next-tick watermark.
```

Print a final summary:

```text
=== PR fleet monitoring ended ===
Reason:   <user-stop | empty-fleet | hard-block>
Fleet:    <final status table>
Actions:  <rebases / /fixpr / /wrap dispatched this session, per PR>
Blocked:  <PR # + reason for each hard block — e.g. "#123 human CHANGES_REQUESTED by @alice">
```

For a hard-block exit, **name the blocking PR and the exact reason** so the user knows what needs them.

---

## Safety boundaries (HARD STOPS — `safety.md`, `cr-merge-gate.md`)

This skill is an **orchestrator**. It rebases/force-pushes and dispatches `/fixpr` and `/wrap`; it never reimplements their fix/merge/resolve logic. The following are absolute:

- **Never modify branch protection** — no calls to `.../branches/.../protection`.
- **Never dismiss human reviews** — only Bot-allowlist `CHANGES_REQUESTED` on a stale `commit_id` (Step 3b). Human CR is a hard block.
- **Never resolve a review thread without code-verification** — thread resolution happens only inside `/fixpr` Steps 1–4 after verifying the fix. This skill only *counts* unresolved threads.
- **Never bypass AI-reviewer rate caps** — `cr-review-hourly.sh` gates every CR re-trigger; Greptile/CodeAnt caps are respected by the dispatched skills.
- **Never use GitHub's update-branch API** for `BEHIND` — only `git rebase origin/main` + `--force-with-lease`.
- **Stay in the worktree; never run destructive commands in the root repo** — no `git clean`, `git reset --hard`, or `.env` edits anywhere.
- **Never merge directly** — merging happens only through `/wrap` (which carries its own merge authorization), after its gate + AC verification.
