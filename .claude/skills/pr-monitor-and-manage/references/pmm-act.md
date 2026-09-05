# PMM Act: Per-Verdict Dispatch Detail

Reference doc for `.claude/skills/pr-monitor-and-manage/SKILL.md`. Contains the
full implementation detail for Steps 5a–5e: rebase, dismiss helper, stale-bot
recovery, parallel fixer dispatch (including subagent prompt template), sequential
`/wrap` dispatch, and dedicated monitor mode.

---

## Shared gate idiom (Steps 3, 5a, 5d, 5e, 6)

An `active_agents` row with `phase == "A"` and `status` not in `{complete, failed}` blocks rebase, `/wrap`, and fix-dispatch gates unless drained. **PMM-owned** entries (`id` starts with `pmm-fix-`) are blocking until Step 2.5/5e drains them via exit report. **Foreign** entries (any other `id`) are blocking only while NOT stale: apply `PMM_LOCK_STALE_SECS` (default 3600s) to `last_seen_at` (or `launched`), and when the window is exceeded **and** there is no live progress evidence on that PR (HEAD SHA unchanged, no new bot/CI activity since the timestamp), treat the entry as **non-blocking** — PMM never mutates it, but stops deferring on it. All gate checks below use this idiom consistently.

**Track actions this tick** for idle detection (Step 6). Initialize `TICK_HAD_ACTION=false` and `MERGED_THIS_TICK='[]'` at the start of Step 5; set `TICK_HAD_ACTION=true` whenever any of the following fire for any PR: rebase + force-push (Step 5a), stale-bot dismissal (Step 5b or 5b′), explicit owning-bot re-trigger from Step 5b′ (or post-subagent Step 2.5/5e), `phase-a-fixer` spawn (Step 5c), `/wrap` dispatch (Step 5d), or a reviewer trigger from `pr-preflight.sh` that actually posts (non-no-op output). Append PR numbers to `MERGED_THIS_TICK` when `/wrap` successfully merges a PR (Step 5d). Waiting, gone, error, `BLOCKED:*`, and no-op pre-flight do **not** set the flag.

---

## Step 5a: Rebase (verdict `rebase`, i.e. `merge_state == BEHIND`)

**Skip if any Phase A agent is still active for this PR — not just PMM's own.** `BEHIND` is checked before `fixpr` in the decision tree (Step 3), so a PR with a fixer subagent still running from a prior tick can flip to verdict `rebase` if main advanced mid-fix — checking out that branch here would collide with that subagent's own worktree (git refuses to check out the same branch twice) and race its push. This check must match Step 3's in-flight check exactly (same reasoning: two Phase A fixers on one PR is risky regardless of which system spawned them) — checking only `pmm-fix-` entries would miss a foreign (non-PMM) Phase A agent sharing the same `active_agents` array, since `BEHIND`-verdict PRs never go through Step 3's `fixpr`-only refinement pass and so get no other protection. Before rebasing, check for any **blocking** Phase A `active_agents` entry for this PR (per the shared gate idiom above — includes PMM-owned and non-stale foreign entries; stale foreign entries with no progress evidence are non-blocking), or an active `pmm_in_flight[N]` lock **that is not stale** (same `PMM_LOCK_STALE_SECS`, default 3600s, staleness rule as Step 3's in-flight check — a stale lock is broken here too, not treated as blocking); if found, skip this PR this tick (verdict stays `rebase` for the table, but no action runs) — it becomes rebase-eligible once the agent completes and its worktree is cleaned up (Step 2.5 for PMM's own fixers; foreign agents clean up under their own workflow's rules). For foreign Phase A agents, PMM detects completion via Step 5e's poll/staleness signal (entry disappearance, terminal `status`, or `PMM_LOCK_STALE_SECS` timeout with no progress evidence) rather than waiting on cleanup or an exit report it cannot observe.

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
    VERDICTS_JSON=$(jq --arg n "$N" '.[$n] = {verdict: "fixpr", tag: "merge-conflict", refined: "fixpr"}' <<<"$VERDICTS_JSON")
    REFINED_VERDICT[$N]="fixpr"
    # Do NOT add to HARD_BLOCK[] — spawn a phase-a-fixer subagent tasked with the
    # /merge-conflict workflow instead. Step 5c dispatch runs later this tick.
  fi
fi
```

If the checkout/rebase cannot proceed (branch not present locally, multiple worktrees), surface the PR as `error` and leave it for the user rather than guessing.

---

## Step 5b: Dismiss stale bot reviews after a force-push

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

---

## Step 5b′: Stale bot `CHANGES_REQUESTED` recovery (verdict `fixpr` — issue #514)

Run **before Step 5c** for every PR whose Step 3 verdict is `fixpr` (or refined `fixpr`) **and** `STALE_BOT_CR > 0` from the tick's gate JSON. Do **not** run when the only bot signal is a **fresh** `CHANGES_REQUESTED` on the current HEAD (`STALE_BOT_CR == 0`) — that PR needs Step 5c fix work, not dismissal/re-trigger. This is **independent of whether Step 5a rebased** — Step 5b only runs after a force-push; without 5b′ a PR blocked *only* by a stale bot review would spawn a no-op `phase-a-fixer` every tick forever.

**Dismiss** — run the shared dismiss helper with `DISMISS_MSG="Superseded — review was on a stale commit"`. Idempotent (already-`DISMISSED` counts as success). The helper only dismisses reviews whose `commit_id` ≠ current HEAD; never touches fresh bot CR on HEAD.

**Re-trigger the owning bot** — post an **explicit** trigger for the owning reviewer on the current HEAD. Resolve via `"$REVIEWER_OF_SH" "$N"` (same mapping as `pr-preflight.sh`'s `reviewer_trigger()`).

> **Since #576, Step 5.0's pre-flight already re-triggers a bot whose only activity is on a superseded commit** — which is exactly this step's situation (the review just dismissed was on a stale SHA). This step therefore **skips** any reviewer pre-flight already triggered on this tick; without that guard both would post for the same PR in the same tick, and for CodeRabbit that burns two of the ≤2/PR/hour explicit-trigger slots at once. It still runs when pre-flight was unavailable, skipped the PR, or reported the reviewer `already-present` / `skipped-rate-cap` — the case this step was written for.

```bash
REVIEWER=$("$REVIEWER_OF_SH" "$N" 2>/dev/null || echo unknown)

# Skip when Step 5.0's pre-flight already triggered this reviewer this tick
# (issue #576) — it re-triggers stale-SHA bots itself now, so a second post here
# would be a duplicate (and would double-spend CodeRabbit's per-PR cap).
PF_KEY=""
case "$REVIEWER" in
  cr) PF_KEY="coderabbit" ;;   # gate-side name → pre-flight reviewer key
  bugbot) PF_KEY="cursor" ;;
  graphite) PF_KEY="graphite" ;;
esac
if [ -n "$PF_KEY" ] && [ -n "${PF_SUMMARY_BY_PR[$N]:-}" ] \
   && [ "$(jq -r --arg k "$PF_KEY" '.reviewers[$k].status // ""' <<<"${PF_SUMMARY_BY_PR[$N]}" 2>/dev/null)" = "triggered" ]; then
  echo "[PMM] pre-flight already re-triggered $REVIEWER on #$N this tick — skipping duplicate explicit trigger"
  REVIEWER="__already_triggered__"
fi
CR_HOURLY=""
for c in "$HOME/.claude/skills-worktree/.claude/scripts/cr-review-hourly.sh" \
         "$HOME/.claude/scripts/cr-review-hourly.sh" \
         ""$CR_HOURLY_SH""; do
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
  __already_triggered__)
    : # pre-flight covered it this tick (#576) — message already printed above
    ;;
  *)
    echo "[PMM] unknown reviewer on #$N — skipping explicit re-trigger"
    ;;
esac
```

Never batch mention strings; never auto-trigger Greptile. Set `TICK_HAD_ACTION=true` when dismissal or re-trigger posts.

**Re-gate and gate Step 5c** — re-run `"$MERGE_GATE_SH" "$N"`, stash in `GATE_BY_PR[$N]`, re-read `MET`, `CI_FAILING`, `STALE_BOT_CR`, `UNRESOLVED` (re-fetch unresolved thread count if needed). Then:
   - **`MET == true`** → treat as `wrap` for Step 5d this tick (skip Step 5c spawn for this PR).
   - **`CI_FAILING > 0` or `UNRESOLVED > 0`** → proceed to Step 5c spawn (real fix work remains).
   - **Otherwise** (reviewer pending on fresh trigger, no CI/thread fix work) → skip Step 5c; verdict becomes `waiting` on the next tick when the bot lands.

---

## Step 5c: Parallel `phase-a-fixer` dispatch (verdict `fixpr`)

Fix work runs in **parallel** via one `phase-a-fixer` subagent per PR, capped at `$PMM_MAX_PARALLEL` (default 3). Merge dispatch stays sequential (Step 5d) — merges affect main and must not race.

**Two fixer task types share this dispatch path:**

1. **CR/CI/thread fix work** (`fixpr` from CI failing, unresolved threads, or stale bot CR) — standard Phase A fixer workflow per `.claude/agents/phase-a-fixer.md`.
2. **Merge-conflict resolution** (`fixpr` with `merge-conflict` tag from `mergeable == CONFLICTING`, or from Step 5a rebase hitting conflicts) — same spawn shape, but the subagent prompt directs it to run the `/merge-conflict` skill workflow: rebase onto base → `resolve_merge_conflicts.py` for safe hunks → apply judgment to complex hunks → commit + force-push. Unresolvable conflicts exit with `OUTCOME: blocked` (see Step 2.5); the parent surfaces them as `BLOCKED:conflicts(needs-human)`.

Conflict dispatches participate in the same parallel cap, batched `session-state.sh --set` write, and `pmm-fix-$N` tracking as CR/CI fixers. Set the Subagent column to `dispatched (merge-conflict)` when spawning for conflict resolution.

**Idempotency and concurrency are already resolved in Step 3's refinement pass** — Step 5c dispatches every PR whose *refined* verdict is still `fixpr` **and** Step 5b′ did not re-gate it to `wrap`/`waiting`. PRs refined to `awaiting fix subagent` or `queued (cap)` are skipped here with no further action; they are eligible again once Step 3 re-evaluates on a later tick.

**CR hourly cap (fleet-wide).** Before spawning, snapshot the budget:

```bash
CR_BUDGET_OK=1
"$CR_HOURLY_SH" --check >/dev/null 2>&1 || CR_BUDGET_OK=0
```

If `$CR_BUDGET_OK == 0`, still spawn subagents but include `SKIP_CR_TRIGGER=1` in each prompt. Do **not** block spawn entirely when the cap is exhausted.

**Bulk spawn (one Agent call per PR, all in parallel up to the cap).** For each PR allocated a slot, read `VERDICTS_JSON[$N].tag` — when it is `merge-conflict`, set `TASK_TYPE=merge-conflict`. Otherwise use `TASK_TYPE=fixpr`. Invoke the Agent tool with:

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
- Handoff file path: resolve with `handoff-state.sh --owner-repo owner/repo --path N` (scoped: `~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json`; the legacy flat layout needs an explicit `--legacy-flat`)
- Pre-fetched findings from Step 3 (`FINDINGS_JSON[N]`) — omit for merge-conflict-only dispatches
- `SKIP_CR_TRIGGER=1` when `$CR_BUDGET_OK == 0`
- The verbatim `SAFETY:` block from `.claude/rules/safety.md`
- The verbatim `MINDSET:` block from `.claude/rules/safety.md`
- The verbatim `SKILLS:` block from `.claude/rules/skill-first.md`

**Record all of this tick's spawns in ONE single write, after every Agent call has been issued.** `.active_agents` is a map keyed by agent id (issue #1631), so each spawn writes only its own key — a sibling thread's entries are structurally untouchable, and the old `--get` → append → `--set`-the-whole-array idiom that lost them is gone. Batching is still the rule: one call per tick is one atomic write and one lock acquisition instead of N. Build every entry first, then issue exactly one `session-state.sh` call for the whole batch:

```bash
NOW=$(date -u +%FT%TZ)
AGENT_SETS=()
IN_FLIGHT_SETS=()
# ONE loop per spawned PR — build that PR's entry AND its --set argument together,
# each using ONLY that PR's own head_sha. Never hoist head_sha into a shared
# variable reused across iterations or across a second loop — the last PR's SHA
# would silently overwrite every earlier PR's lock.
for N in $SPAWNED_PR_NUMS; do
  N_HEAD_SHA=$(jq -r '.head_sha' <<<"${GATE_BY_PR[$N]}")   # that PR's own tick-scoped $GATE
  # --first: one primary issue per agent entry. Default mode is set-valued
  # (issue #1492) and a two-line value would break the `jq --argjson` below.
  ISSUE_N=$("$PR_ISSUE_REF_SH" --first "$N" 2>/dev/null || echo null)
  AGENT_ID="pmm-fix-$N"
  # -c is load-bearing: the entry is interpolated into a --set argument below,
  # and jq's default pretty-print would embed newlines in it.
  ENTRY=$(jq -n -c --arg id "$AGENT_ID" --arg task "PMM fix PR #$N" --argjson issue "$ISSUE_N" \
    --argjson pr "$N" --arg launched "$NOW" --arg head_sha "$N_HEAD_SHA" \
    '{id:$id, task:$task, issue:$issue, pr:$pr, phase:"A", status:"spawned", launched:$launched, head_sha:$head_sha}')
  # Targeted per-key write — never a whole-map `--set '.active_agents=...'`.
  AGENT_SETS+=(--set ".active_agents[\"$AGENT_ID\"]=$ENTRY")
  IN_FLIGHT_SETS+=(--set ".pmm_in_flight.\"$N\"={\"skill\":\"phase-a-fixer\",\"status\":\"active\",\"dispatched_at\":\"$NOW\",\"head_sha\":\"$N_HEAD_SHA\",\"agent_id\":\"$AGENT_ID\"}")
done

# After the loop — ONE write carrying every per-key agent assignment plus the locks.
"$SESSION_STATE_SH" ${AGENT_SETS[@]+"${AGENT_SETS[@]}"} ${IN_FLIGHT_SETS[@]+"${IN_FLIGHT_SETS[@]}"}
```

Set Subagent column to `spawned` immediately for every PR in this batch; transition to `working` once each subagent reports activity (first tool call or ~30s elapsed).

**Safety boundaries for every subagent (non-negotiable):**
- Never modify branch protection
- Never dismiss human-authored reviews
- Never resolve a review thread without code-verification (per `phase-a-fixer` Step 5)

---

## Step 5d: Sequential `/wrap` dispatch (verdict `wrap` — merge-ready)

Merge-ready PRs get **sequential** `/wrap` dispatch — one at a time, never parallelized. Merges affect main branch state (main-sync, follow-up detection, lessons) and must not race. PMM never runs `gh pr merge` directly — landing always flows through the full `/wrap` workflow.

**Deferral gate — check this FIRST, before any lock acquisition or `/wrap` execution below.** "Fix subagents active this tick" means spawned just now by Step 5c OR still running from a prior tick — check both: any Step 5c spawn this tick, **or** a **blocking** Phase A `active_agents` entry (per the shared gate idiom — any `id`, not just `pmm-fix-` prefixed; stale foreign entries with no progress evidence are non-blocking; this must match Step 5a's rebase-skip check exactly). This matters because a `/pmm-stop`-then-resume, or a tick where Step 3's refinement pass left every `fixpr` PR at `awaiting fix subagent`/`queued (cap)` with zero *new* spawns, would otherwise slip past a "spawned this tick" check while a background fixer is still mid-flight on a shared branch/worktree.

Process merge-ready PRs **only when no fix subagents are active this tick** — run Step 5d sequentially before Step 5e. **If any fix subagents are active, stop here and defer all `/wrap` dispatches** until the Step 5e monitor loop has drained every active fix subagent.

**Merge-sequencing gate (issue #756) — apply after the deferral gate, before any lock.** Read each PR's Step 3.6 action from `SEQ`:
- **`held(#A)`** → skip this tick entirely. No confirmation prompt, no lock write, no `/wrap`. The PR keeps its `wrap` readiness and is re-evaluated next tick.
- **`batch(#A)`** → dispatch it in **this** tick, alongside every other `batch` member of the same anchor. They still merge **one at a time**, but all within this single tick's merge window.
- **`merge`** → dispatch normally.

**Order within the tick:** anchors first, then batch members in ascending PR number, then everything else.

**The merge-dispatch set is `wrap` ∪ `batch(#A)`, minus `held(#A)`** — define it explicitly before the loop below. Step 3.6 *replaces* a PR's `wrap` verdict with `batch(#A)` when it releases a hold, so a dispatch condition written as "`VERDICT == wrap`" alone would silently skip every released PR:

```bash
MERGE_SET=()
for N in $PR_NUMS; do
  case "${REFINED_VERDICT[$N]:-${VERDICT_BY_PR[$N]}}" in
    wrap|batch\(*) MERGE_SET+=("$N") ;;   # both dispatch
    held\(*)       ;;                      # held this tick — no lock, no /wrap
  esac
done
```

**Idempotency-gated via `pmm_in_flight`** (only reached once the deferral gate above is open):

```bash
INFLIGHT=$("$SESSION_STATE_SH" --get ".pmm_in_flight.\"$N\"" 2>/dev/null || echo null)
```

- `$INFLIGHT` has `status == "active"` → skip (verdict `awaiting prior /wrap`) unless stale per `PMM_LOCK_STALE_SECS` (default **3600s**) with no live progress evidence.
- `$INFLIGHT` is `null` (or stale lock broken) → proceed to merge dispatch below.

**Merge dispatch — no confirmation prompt by default.** For each `$N` in `MERGE_SET` (verdict `wrap` **or** `batch(#A)` — never `held(#A)`), in the order above:

1. **When `PMM_CONFIRM_MERGES` is true:** emit a per-PR confirmation prompt ("Merge-ready: dispatch `/wrap` for #N?") **before** acquiring any lock. If declined, skip this PR this tick with **no** `pmm_in_flight` write — do not leave a stale lock.
2. **When confirmed (or when `PMM_CONFIRM_MERGES` is false):** acquire the idempotency lock:

```bash
NOW=$(date -u +%FT%TZ)
HEAD_SHA=$(jq -r '.head_sha' <<<"${GATE_BY_PR[$N]}")
"$SESSION_STATE_SH" --set \
  ".pmm_in_flight.\"$N\"={\"skill\":\"wrap\",\"status\":\"active\",\"dispatched_at\":\"$NOW\",\"head_sha\":\"$HEAD_SHA\"}"
```

Execute the **full** `/wrap` workflow inline (all 4 phases). PMM relies on `/wrap`'s own gate re-check (`merge-gate.sh`) and AC verification (`ac-checkboxes.sh`) — if the gate is no longer met (SHA moved, CI regressed) or AC fails, `/wrap` stops and returns a hard block; PMM records it and re-classifies on the next tick without re-authorizing or re-prompting.

On completion:
- `/wrap` merged the PR → clear `pmm_in_flight[N]`; append `#N` to `MERGED_THIS_TICK` and `MERGED_THIS_SESSION` (dedupe on append); PR drops from fleet on next `gh pr list`.
- `/wrap` returned a hard block → clear in-flight and add `#N` to `HARD_BLOCK[]` for reporting (Step 4 next tick). Do **not** force-stop the fleet.

---

## Step 5e: Dedicated monitor mode while fix subagents are active

If any **blocking** fix subagents are active this tick (per the shared gate idiom and the deferral-gate definition in Step 5d — spawned now or carried over from a prior tick), **immediately enter an orchestration-only posture borrowing `monitor-mode.md`'s Dedicated Monitor Mode discipline** — the **parent's** ONLY job until every blocking fix subagent completes, fails, or is drained (foreign: disappearance / terminal `status` / `PMM_LOCK_STALE_SECS` staleness timeout) is orchestration (poll, verify, heartbeat); the parent does no direct feature-code edits, no local CR review, no substantive source analysis — but its subagents edit code, resolve conflicts, and push as designed. **PMM does NOT execute `monitor-mode.md`'s Monitor Loop Per-Cycle Checklist verbatim** — specifically, it never runs `phase-protocols.md`'s Phase Completion Protocols, which would otherwise auto-launch Phase B after Phase A. Step 2.5's aggregation fully replaces that: PMM fixes and pushes only, per Step 0's contract ("PMM does not launch Phase B/C after Phase A").

**PMM's own monitor loop (~60s cadence — replaces, not layers on, `monitor-mode.md`'s checklist):**

1. **Poll active subagent statuses — ownership-aware drain.** Each ~60s cycle, read `active_agents` (a map keyed by agent id — iterate its values) and partition the Phase A entries gating deferred PRs into **PMM-owned** (`id` starts with `pmm-fix-`) and **foreign** (any other `id`) sets.

   **PMM-owned entries:** Transition Subagent column: `spawned` → `working` → `complete` / `failed`. On completion (success, exhaustion, or crash), proceed to item 2 below.

   **Foreign entries:** PMM has no exit report to parse and must never clean up or remove state it does not own — foreign agents drain by poll-based observation only (see below). While waiting, surface the PR's Subagent column as `deferred(foreign-agent)`.

   For each foreign Phase A entry, the **drain signal** is:
   - The entry **disappears** from `active_agents` (authoritative — the owning workflow removed it), **or**
   - Its `status` flips to `complete` or `failed` (secondary/opportunistic).

   PMM must **not** perform worktree cleanup, remove, or mutate the foreign entry or any foreign lock — the owning workflow cleans up under its own rules. PMM only observes and stops deferring once the entry is gone or terminal.

   **Staleness fallback (foreign only):** Reuse `PMM_LOCK_STALE_SECS` (default 3600s), applied to the foreign entry's freshness timestamp (`last_seen_at` if present, else `launched`). When the entry exceeds the staleness window **and** there is no live evidence of progress on that PR (HEAD SHA unchanged since the timestamp, no new bot/CI activity since the timestamp), log the stale foreign agent, surface the Subagent column as `foreign-agent-stale`, and treat the entry as **non-blocking** per the shared gate idiom — the deferral gate reopens for that PR so `/wrap` may proceed after the monitor loop exits (rebase on the next tick also proceeds, since Step 5a uses the same idiom). Same conservatism as the existing lock-staleness idiom — the wide window and no-progress corroboration prevent pre-empting a healthy long-running foreign fixer; PMM still does not touch the foreign entry, it only stops waiting on it.

   **Gate reopen:** Once a PR has no remaining **blocking** Phase A entry of either kind, the deferral gate for that PR reopens and its deferred `/wrap` dispatch proceeds after the monitor loop exits, per existing Step 5d/5e ordering.

2. **On PMM-owned completion** — success, exhaustion, or crash — **run Step 2.5's steps 1-3 in full** (parse exit report, worktree cleanup, remove this agent's own `active_agents` record + clear `pmm_in_flight[N]`) before branching on outcome. When OUTCOME is `pushed_fixes`, also run **Step 5b dismiss helper + Step 5b′ owning-bot re-trigger** on that PR (issue #514 — mirrors `/fixpr` 3a/3b; set `TICK_HAD_ACTION=true` if dismissal or re-trigger posts). This is unconditional, not just the success path — a failure that skips clearing `pmm_in_flight[N]` would otherwise leave a stale lock blocking Step 3's idempotency check until `PMM_LOCK_STALE_SECS` expires.
3. Branch on outcome for **PMM-owned** entries only (per Step 2.5's step 4, cleanup from item 2 above already done):
   - **Crash / no exit report / stale >15 min:** mark `failed` in the table and add `#N` to `HARD_BLOCK[]` with reason `crashed(needs-approval)` — never re-dispatch silently. Reported once and dropped from the actionable fleet this tick; the user can explicitly approve a respawn.
   - **`blocked` (unresolvable merge conflict or other fix blocker):** add `#N` to `HARD_BLOCK[]` with reason from the exit report (e.g. `conflicts(needs-human)`). Report once and drop from the actionable fleet.
   - **Token/turn exhaustion with a valid handoff file:** respawn immediately **using Step 5c's spawn pattern**, but with **freshly re-fetched** gate and findings data for this PR — do NOT reuse tick-start `GATE_BY_PR[$N]`/`FINDINGS_JSON[$N]` verbatim. Real time has passed since Step 3 computed them, and the exhausted subagent may have pushed partial progress before running out of tokens, moving the PR's actual HEAD SHA and review state past that tick-start snapshot; a respawn using the stale SHA/findings would hand the replacement outdated context. Re-run `"$MERGE_GATE_SH" "$N"` (and re-fetch findings from the three endpoints, same as Step 3's pre-fetch) immediately before building the replacement's spawn record.
4. Send heartbeat if >5 min since last user message (timestamp prefix required).
5. Investigate stale **PMM-owned** agents (>15 min Phase A without progress). Foreign staleness is handled by item 1's `PMM_LOCK_STALE_SECS` fallback.

**While subagents run:** do not start rebases, new spawns for other PRs, or `/wrap` dispatches. **Exception:** an exhaustion respawn for a PR already in this tick's active-fixer set is a continuation of already-approved fix work — it is exempt from this restriction and proceeds inline. Deferred merge-ready PRs from Step 5d run immediately after the monitor loop exits. The tick completes only after all spawned fix subagents return (or fail) and any deferred `/wrap` dispatches finish. Then proceed to Step 6.

**#497 compatibility (idle auto-pause):** when all subagents exit and no parent dispatches remain in-flight, treat the tick as idle for digest/backoff purposes — the stable-state countdown in Step 6 applies as if the tick were a no-op dispatch tick.

**Tick merge summary.** After all Step 5 actions complete, if `MERGED_THIS_TICK` is non-empty, print one line per merged PR (already recorded in `MERGED_THIS_SESSION` at `/wrap` completion — do not append again here):

```text
merged #N
```

Initialize `MERGED_THIS_SESSION='[]'` on the first tick in Step 0/Step 1.
