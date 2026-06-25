---
name: babysit-pr
description: Watch a single PR on a recurring /loop and auto-dispatch /fixpr (recoverable blockers) or /wrap (merge-ready). Reads PR state via pr-state.sh + merge-gate.sh each tick, classifies into {merged, merge-ready, has-recoverable-blockers, waiting-on-bots, hard-blocked}, tracks in-flight dispatches in session-state for idempotency, applies stable-state backoff, emits a timestamped heartbeat per tick, and hard-terminates on merge/hard-blocked/N blocker ticks/user stop. Stop with /babysit-pr-stop. Invoke as `/babysit-pr <PR> [--cadence Nm] [--max-iter N] [--silent] [--durable]`.
triggers:
  - babysit pr
  - babysit this pr
  - watch this pr
  - keep an eye on pr
argument-hint: "<PR> [--cadence Nm] [--max-iter N] [--silent] [--durable]"
---

Watch one PR and drive it toward merge **without looping forever**. Each tick reads the PR's state through the shared scripts, classifies it, and dispatches the right skill — `/fixpr` to fix recoverable blockers, `/wrap` to merge when the gate is met — then re-arms the poll until a terminal condition fires.

`/babysit-pr` is a **thin orchestrator**: it never re-implements PR-state aggregation, the merge gate, fix logic, or the merge flow. It reads `pr-state.sh` + `merge-gate.sh`, and it dispatches `/fixpr` / `/wrap`. All code-verification, thread resolution, CI fixing, and merge-gate enforcement stay inside those skills (`fixpr/SKILL.md`, `wrap/SKILL.md`, `cr-merge-gate.md`). This skill only decides *which* to call and *when to stop*.

This is reused by `/pr-monitor-and-manage` (issue #460): that skill invokes `/babysit-pr` per discovered PR rather than re-implementing the per-PR decision tree.

## Safety boundaries (HARD STOPS — non-negotiable, `safety.md` / #450)

`/babysit-pr` is read-only plus the dispatches below. It MUST NOT:

- **Never modify branch protection** — no calls to `.../branches/.../protection`.
- **Never dismiss human-authored reviews.** Only `/fixpr`'s `dismiss-stale-bot-changes.sh` (bot allowlist, wrong `commit_id`) may dismiss, and only bot reviews.
- **Never resolve a review thread** itself — thread resolution happens only inside `/fixpr` Steps 1–4 after code-verification. `/babysit-pr` does not call `resolveReviewThread`.
- **Never bypass `/fixpr`'s code-verification step** — it dispatches the full `/fixpr` workflow, never a shortcut.
- **Never post `@coderabbitai full review`** without `cr-review-hourly.sh --check` passing first (`/fixpr` owns the actual trigger + the atomic `--record-explicit` cap).

A human `CHANGES_REQUESTED` on HEAD is `hard-blocked` → record and exit. Never auto-dismiss it.

## Arguments & knobs

| Argument | Default | Meaning |
|----------|---------|---------|
| `<PR>` (required) | — | PR number to watch. Must be an open PR. |
| `--cadence Nm` | `5m` | Base poll cadence. Floor `1m` (60s) — clamp anything lower. |
| `--max-iter N` | `6` | Hard termination after N **consecutive blocker-state ticks** (≈90 min once backoff widens to 15m). |
| `--silent` | off | Suppress the per-tick heartbeat **except** on state change, dispatch, or termination (those always print). |
| `--durable` | off | Use `CronCreate` instead of `/loop` for cross-session durability (per `scheduling-reliability.md`). Default is `/loop` (session-scoped). |

Parse from `$ARGUMENTS`. The first bare integer is `<PR>`. Validate `--cadence` matches `^[0-9]+m$`; clamp `< 1m` to `1m`. Validate `--max-iter` is a positive integer.

## Two modes: arm vs tick

This skill runs in one of two modes, disambiguated by the internal `--tick` flag:

- **Arm mode** (`/babysit-pr <PR> …`, no `--tick`): validate, initialize `session-state.json`, arm the recurring poll, run **one** tick immediately, then end the turn.
- **Tick mode** (`/babysit-pr <PR> --tick`): the body the poll re-invokes each cycle. Runs exactly one tick of classification + dispatch + bookkeeping. **Never re-arms the loop** (the runtime owns cadence) except to change cadence on a backoff threshold crossing.

The loop command armed in arm mode is `/babysit-pr <PR> --tick` (plus the resolved cadence flags), so every subsequent cycle enters tick mode.

---

## Resolve the shared scripts (once, both modes)

Use the standard three-candidate lookup (same pattern as `fixpr/SKILL.md`). Prefer the global install; fall back to the in-repo copy when developing the skill itself.

```bash
resolve_script() {
  # $1 = script basename; echoes the first executable path or empty
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}

PR_STATE_SH=$(resolve_script pr-state.sh)        || { echo "ERROR: pr-state.sh not found" >&2; exit 1; }
MERGE_GATE_SH=$(resolve_script merge-gate.sh)     || { echo "ERROR: merge-gate.sh not found" >&2; exit 1; }
SESSION_STATE_SH=$(resolve_script session-state.sh) || { echo "ERROR: session-state.sh not found" >&2; exit 1; }
CR_HOURLY_SH=$(resolve_script cr-review-hourly.sh)   || true   # optional; degrade gracefully
GREPTILE_SH=$(resolve_script greptile-budget.sh)     || true   # optional; degrade gracefully
```

**Always read/write `session-state.json` via `session-state.sh --get`/`--set`** (atomic, sibling-preserving) — never raw `jq` writes (`handoff-files.md`). State for this skill lives under `.prs["<N>"]`:

- Backoff fields reuse the **shared schema fields** `.prs["<N>"].digest` and `.prs["<N>"].digest_streak` (per `scheduling-reliability.md` / `session-state-schema.json`) so the backoff watchdog sees a consistent streak.
- Babysit-specific fields live under a nested `.prs["<N>"].babysit` object so they don't collide with phase/reviewer fields other skills write.

```jsonc
// .prs["<N>"].babysit
{
  "active": true,
  "started_at": "2026-06-25T19:00:00Z",
  "cadence_base_minutes": 5,
  "cadence_effective_minutes": 5,
  "tick_count": 0,
  "blocker_streak": 0,          // consecutive blocker-state ticks (drives --max-iter)
  "max_blocker_ticks": 6,
  "silent": false,
  "durable": false,
  "stop_requested": false,      // set true by /babysit-pr-stop
  "dispatch_in_flight": null,   // {"skill":"fixpr"|"wrap","started_at":"…"} while a dispatch runs
  "last_dispatch": null,        // {"skill":"…","started_at":"…","completed_at":"…","status":"…"}
  "cron_job_id": null           // set when --durable arms a CronCreate job
}
```

---

## ARM MODE

Run only when invoked **without** `--tick`.

### A1. Validate the PR

```bash
PR_JSON=$(gh pr view "$PR" --json number,state,merged,headRefOid 2>&1) || {
  echo "ERROR: PR #$PR not found or gh failed: $PR_JSON" >&2; exit 1; }
PR_PR_STATE=$(jq -r '.state' <<<"$PR_JSON")     # OPEN | MERGED | CLOSED
if [[ "$PR_PR_STATE" != "OPEN" ]]; then
  echo "PR #$PR is $PR_PR_STATE — nothing to babysit."; exit 0
fi
```

### A2. Refuse duplicate watchers (idempotent setup)

```bash
ALREADY=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].babysit.active" 2>/dev/null || echo "null")
if [[ "$ALREADY" == "true" ]]; then
  echo "Already babysitting PR #$PR — not arming a second watcher. Use /babysit-pr-stop $PR to stop."
  exit 0
fi
```

### A3. Initialize state and arm the poll

Write the babysit object (one atomic `--set` batch), seeding backoff fields to a neutral start:

```bash
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
"$SESSION_STATE_SH" \
  --set ".prs[\"$PR\"].babysit={\"active\":true,\"started_at\":\"$NOW\",\"cadence_base_minutes\":$BASE_MIN,\"cadence_effective_minutes\":$BASE_MIN,\"tick_count\":0,\"blocker_streak\":0,\"max_blocker_ticks\":$MAX_ITER,\"silent\":$SILENT,\"durable\":$DURABLE,\"stop_requested\":false,\"dispatch_in_flight\":null,\"last_dispatch\":null,\"cron_job_id\":null}" \
  --set ".prs[\"$PR\"].digest_streak=0"
```

Arm the recurring poll. **`/loop` is the default primitive** (`scheduling-reliability.md` decision tree); `CronCreate` only when `--durable` is set (cross-session durability).

- **`/loop` (default):** arm `/loop <cadence> /babysit-pr <PR> --tick`. The runtime owns the cadence and re-arms each cycle.
- **`--durable` (CronCreate):** pick an off-peak minute via `.claude/scripts/off-peak-minute.sh`, create a recurring (`recurring: true`, `durable: true`) job whose prompt is `/babysit-pr <PR> --tick`, and persist the returned job id to `.prs["<N>"].babysit.cron_job_id` and to top-level `polling_jobs[]` (so `/babysit-pr-stop` and recovery can find it).

Then **run one tick immediately** (fall through to TICK MODE below) so the user gets instant feedback, and emit the initial heartbeat. Per the `scheduling-reliability.md` **pre-exit checklist**, before ending the arm turn confirm: (1) the next tick is scheduled (loop active / cron created), (2) a timestamped heartbeat was sent, (3) state was recorded.

---

## TICK MODE

Run on every poll cycle (and once at the end of arm mode). One tick = classify → maybe dispatch → bookkeep → maybe re-arm cadence → heartbeat.

### T0. Stop / terminal short-circuit (check FIRST)

```bash
STOP=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].babysit.stop_requested" 2>/dev/null || echo "false")
ACTIVE=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].babysit.active" 2>/dev/null || echo "false")
if [[ "$STOP" == "true" || "$ACTIVE" != "true" ]]; then
  # user ran /babysit-pr-stop, or state was cleared — terminate cleanly
  goto TERMINATE with reason="user-stop"
fi
```

If `dispatch_in_flight` is set and its `started_at` is **recent** (a prior tick's `/fixpr` or `/wrap` is still running — ticks can overlap when a dispatch outlives the cadence), **skip this tick's dispatch** (idempotency — see T4) and emit a "dispatch in progress" heartbeat. Do not classify-and-dispatch on top of an in-flight dispatch.

### T1. Read PR state (the two shared scripts — never re-implement)

```bash
# Authoritative merge-readiness + blocker breakdown.
GATE_JSON=$("$MERGE_GATE_SH" "$PR"); GATE_EXIT=$?
# Full state bundle for findings/threads/CI/SHA. --since the PR's createdAt picks
# up every bot finding; classification fields drive new-findings detection.
PR_CREATED=$(gh pr view "$PR" --json createdAt --jq '.createdAt')
BUNDLE=$("$PR_STATE_SH" --pr "$PR" --since "$PR_CREATED")   # prints path
```

Pull the fields the classifier needs:

```bash
HEAD_SHA=$(jq -r '.head_sha // ""'                 <<<"$GATE_JSON")
GATE_MET=$(jq -r '.met'                            <<<"$GATE_JSON")
HUMAN_CR=$(jq -r '.human_changes_requested | length' <<<"$GATE_JSON")
MERGE_STATE=$(jq -r '.merge_state // ""'           <<<"$GATE_JSON")
MERGEABLE=$(jq -r '.mergeable // ""'               <<<"$GATE_JSON")
CI_FAILING=$(jq -r '.ci_status.failing // 0'       <<<"$GATE_JSON")
CI_INCOMPLETE=$(jq -r '.ci_status.in_progress // 0' <<<"$GATE_JSON")
STALE_BOT_CR=$(jq -r '.stale_bot_changes_requested_count // 0' <<<"$GATE_JSON")
MISSING=$(jq -r '.missing | join(" | ")'           <<<"$GATE_JSON")

UNRESOLVED=$(jq -r '.threads.unresolved_count'      < "$BUNDLE")
NEW_FINDINGS=$(jq -r '.new_since_baseline.finding_count // 0' < "$BUNDLE")
CR_STATE=$(jq -r '.bot_statuses.CodeRabbit.state // "none"'   < "$BUNDLE")
GREP_STATE=$(jq -r '.bot_statuses.Greptile.state // "none"'   < "$BUNDLE")
# BugBot reports via check-run, not commit status; derive a coarse state.
BUGBOT_STATE=$(jq -r '[.check_runs.all[] | select((.name//""|ascii_downcase)|contains("cursor") or contains("bugbot"))] | (if length==0 then "none" elif any(.[]; .status!="completed") then "pending" else "done" end)' < "$BUNDLE" 2>/dev/null || echo "none")
```

If `merge-gate.sh` exits `3` (PR not found / not open) or `gh pr view` shows merged/closed, jump to T2's terminal handling.

### T2. Classify (first match wins, in this order)

Re-fetch the authoritative open/merged state once:

```bash
PR_NOW=$(gh pr view "$PR" --json state,merged --jq '{state,merged}')
PR_STATE_NOW=$(jq -r '.state' <<<"$PR_NOW")
PR_MERGED=$(jq -r '.merged'   <<<"$PR_NOW")
```

| # | Class | Condition | Action |
|---|-------|-----------|--------|
| 1 | `merged` | `PR_MERGED == true` (or gate exit 3 because merged) | **Exit** — terminal success. |
| 2 | `hard-blocked` | `HUMAN_CR > 0` (human `CHANGES_REQUESTED` on HEAD), **or** PR `CLOSED` unmerged, **or** all needed reviewers are budget-exhausted (T3), **or** a Greptile P0 needing design input persists | **Record blocker, exit.** Never auto-dismiss. |
| 3 | `merge-ready` | `GATE_MET == true` (gate exit 0) | **Dispatch `/wrap`** (T4). |
| 4 | `has-recoverable-blockers` | gate exit 1 **and** any of: `UNRESOLVED > 0`, `NEW_FINDINGS > 0`, `CI_FAILING > 0`, `STALE_BOT_CR > 0`, `MERGE_STATE` ∈ {`BEHIND`,`DIRTY`}, `MERGEABLE == CONFLICTING` | **Dispatch `/fixpr`** (T4). |
| 5 | `waiting-on-bots` | gate exit 1 and the only gaps are pending review/CI: `CI_INCOMPLETE > 0`, or a missing-but-pending bot approval / `REVIEW_REQUIRED` with no findings/threads/failing-CI | **Heartbeat only, no dispatch.** Bots are still working on the current SHA. |

`waiting-on-bots` is the "do nothing, just wait" state — the gate isn't met but there is nothing actionable yet (no findings to fix, no threads to resolve, CI still running, a bot hasn't posted its verdict). Do **not** dispatch `/fixpr` here — that would burn CR/CI cycles on a PR that just needs time. `/fixpr` owns its own bounded post-push wait (#454); `/babysit-pr` simply tolerates the gap across ticks.

### T3. Rate-cap gating (before classifying anything as needing a review trigger)

`/babysit-pr` never posts review triggers itself — `/fixpr` owns triggers and their caps. But the **classifier** must not route to a dispatch that would immediately hit a cap with no path forward. Before treating "missing fresh bot review" as recoverable:

- **CodeRabbit:** if `CR_HOURLY_SH` is present, run `"$CR_HOURLY_SH" --check`. Exit `1` ⇒ CR hourly budget exhausted. Do **not** classify as needing a CR trigger this tick; if CR is the only path to the gate, this contributes to `hard-blocked` (budget exhaustion). `/fixpr`'s own `--record-explicit` enforces the ≤2/PR/hour cap atomically — `/babysit-pr` only consults `--check`, never consumes.
- **Greptile:** if `GREPTILE_SH` is present, run `"$GREPTILE_SH" --check`. Exit `1` ⇒ Greptile daily budget exhausted — same treatment.
- **BugBot (`@cursor review`):** per-seat, no per-call charge — always safe (`bugbot.md`). Never gate on it.

If CR **and** Greptile are both exhausted **and** the PR still needs a fresh review to reach the gate (no other recoverable work), classify `hard-blocked` with a budget-exhaustion blocker and exit — re-running `/babysit-pr` after the window resets resumes cleanly.

### T4. Dispatch with idempotency (`session-state.json` is the source of truth)

Only classes `merge-ready` (→ `/wrap`) and `has-recoverable-blockers` (→ `/fixpr`) dispatch.

1. **Idempotency guard.** Read `.prs["<N>"].babysit.dispatch_in_flight`. If non-null and its `started_at` is recent (still running), **refuse to re-dispatch** the same skill — emit "dispatch in progress (<skill>), skipping" and finish the tick. This prevents two overlapping `/fixpr` (or `/wrap`) runs racing on the same PR when a dispatch outlives the cadence.
2. **Mark in-flight before invoking:**
   ```bash
   START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
   "$SESSION_STATE_SH" --set ".prs[\"$PR\"].babysit.dispatch_in_flight={\"skill\":\"$TARGET\",\"started_at\":\"$START\"}"
   ```
3. **Invoke the full skill.** Execute the complete `.claude/skills/$TARGET/SKILL.md` workflow inline (or via a Phase A subagent in `bypassPermissions` mode with the `safety.md` block when the parent is in monitor mode — `subagent-orchestration.md`). `/fixpr` runs Steps 0–7 including its Step 4d post-push wait; `/wrap` runs its merge-gate recovery + AC + squash-merge + main-sync. **Do not shortcut either.**
4. **Clear in-flight after it returns:**
   ```bash
   DONE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
   "$SESSION_STATE_SH" \
     --set ".prs[\"$PR\"].babysit.last_dispatch={\"skill\":\"$TARGET\",\"started_at\":\"$START\",\"completed_at\":\"$DONE\",\"status\":\"$DISPATCH_STATUS\"}" \
     --set ".prs[\"$PR\"].babysit.dispatch_in_flight=null"
   ```
   `DISPATCH_STATUS` = the parsed `Status:` / `FIXPR_WRAP_STATUS:` from `/fixpr`, or `merged`/`blocked`/`stopped` from `/wrap`.
5. **On dispatch error:** record `status: "error"`, clear `dispatch_in_flight`, do **not** retry within this tick — the next tick re-classifies from scratch.

After a `/wrap` dispatch that reports the PR merged, the next tick (T2 #1) sees `merged` and terminates. After a `/fixpr` dispatch, the next tick re-reads state on the new SHA.

### T5. Backoff + bookkeeping (`scheduling-reliability.md` stable-state backoff)

Compute the per-tick **digest** over the canonical tuple (free-text blockers excluded):

```
digest = sha256( head_sha | cr_state | bugbot_state | greptile_state | ci_blocking_conclusions_sorted | blocker_kind )
```

where `blocker_kind` is the classification name (`merge-ready` / `has-recoverable-blockers` / `waiting-on-bots` / `hard-blocked`) and `ci_blocking_conclusions_sorted` is the sorted list of blocking CI conclusions from the gate JSON.

```bash
DIGEST=$(printf '%s|%s|%s|%s|%s|%s' "$HEAD_SHA" "$CR_STATE" "$BUGBOT_STATE" "$GREP_STATE" "$CI_BLOCKING_SORTED" "$CLASS" | sha256sum | awk '{print "sha256:"$1}')
PREV_DIGEST=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].digest" 2>/dev/null || echo "null")
PREV_STREAK=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].digest_streak" 2>/dev/null || echo 0)
[[ "$PREV_STREAK" =~ ^[0-9]+$ ]] || PREV_STREAK=0
if [[ "$DIGEST" == "$PREV_DIGEST" ]]; then STREAK=$((PREV_STREAK + 1)); else STREAK=1; fi
```

**Cadence tiers** (base default 5m; `scheduling-reliability.md` widens a stable state and stops a frozen one). For `/babysit-pr` the first widen tier coincides with the 5m base, so the streak widens straight to **15m at ≥3 consecutive same-digest ticks** (satisfying the AC), and a frozen state stops at ≥9:

| `digest_streak` | Effective cadence |
|-----------------|-------------------|
| `< 3` | base (`--cadence`, default 5m) |
| `>= 3` | **15m** (widened) |
| `>= 9` | **terminate** (truly frozen — `CronDelete` in durable mode) |

**Revert to base cadence on any state change** (digest differs → `STREAK` reset to 1 → cadence returns to base).

**Blocker-streak** (drives `--max-iter` termination): a tick is a *blocker-state tick* when `CLASS` ∈ {`has-recoverable-blockers`, `waiting-on-bots`} **and** the digest did not change (no forward progress). Increment `blocker_streak` on such ticks; reset to `0` on `merge-ready`/`merged` or on any digest change.

Persist all counters atomically, then increment the tick count:

```bash
"$SESSION_STATE_SH" \
  --set ".prs[\"$PR\"].digest=$JSON_DIGEST" \
  --set ".prs[\"$PR\"].digest_streak=$STREAK" \
  --set ".prs[\"$PR\"].babysit.blocker_streak=$BLOCKER_STREAK" \
  --set ".prs[\"$PR\"].babysit.tick_count=$NEW_TICK_COUNT" \
  --set ".prs[\"$PR\"].babysit.cadence_effective_minutes=$EFFECTIVE_MIN"
```

**Re-arm cadence only when it crosses a tier boundary.** `/loop` owns the cadence, so to change it: stop the current loop and re-arm `/loop <new-cadence> /babysit-pr <PR> --tick` (durable mode: `CronUpdate`/recreate the job at the new minute-range, persisting the new id). If the effective cadence is unchanged, do nothing — never re-arm an unchanged loop (forbidden hand-rolled re-arm churn).

### T6. Termination check

Terminate (→ T-END) when **any** hold:

- `CLASS == merged` → reason `merged`.
- `CLASS == hard-blocked` → reason `hard-blocked` (record the specific blocker: human reviewer login(s), conflict, budget exhaustion, persistent P0).
- PR `CLOSED` unmerged → reason `closed-unmerged`.
- `blocker_streak >= max_blocker_ticks` (default 6) → reason `blocker-tick-cap` (≈90 min once backed off to 15m).
- `digest_streak >= 9` → reason `stable-frozen` (`scheduling-reliability.md` ≥9 stop).
- `stop_requested == true` / `active != true` → reason `user-stop`.

Otherwise the loop continues — the next cycle re-enters tick mode.

### T7. Heartbeat (per tick — never silent by default)

Always run a `date` for the timestamp (never estimate — `monitor-mode.md`):

```bash
TS=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET')
```

One-liner format:

```
[<TS>] #<PR> tick <n>: state=<class>, action=<dispatch /fixpr | dispatch /wrap | no-op | waiting | dispatch-in-progress>, next in <effective-cadence>
```

Append context: blocker reason on `hard-blocked`/`waiting-on-bots`; dispatch target on a dispatch; `(backoff: stable ×<streak>, widened to 15m)` when cadence widened; the final summary on termination.

**`--silent`:** suppress the line on plain `waiting-on-bots`/no-change ticks, but **always** print on state change, any dispatch, backoff transitions, and termination. (Default — no `--silent` — prints every tick, satisfying the per-tick heartbeat AC.)

### T-END. Terminate cleanly

```bash
"$SESSION_STATE_SH" \
  --set ".prs[\"$PR\"].babysit.active=false" \
  --set ".prs[\"$PR\"].babysit.dispatch_in_flight=null"
```

- **Durable mode:** `CronDelete` the `cron_job_id` and remove it from `polling_jobs[]`.
- **`/loop` mode:** do **not** re-arm — letting the loop lapse is the stop. (If the runtime keeps re-invoking, the T0 short-circuit makes every further tick a no-op terminate.)

Emit the final summary:

```
=== babysit-pr complete ===
PR:           #<PR>
Final state:  <class>
Reason:       merged | hard-blocked | closed-unmerged | blocker-tick-cap | stable-frozen | user-stop
Ticks:        <tick_count>
Dispatches:   <count> (/fixpr ×N, /wrap ×M)
Last dispatch: <skill> → <status>
Blocker:      <named blocker when hard-blocked / blocker-tick-cap, else "none">
```

---

## Notes

- **Stop anytime:** `/babysit-pr-stop <PR>` sets `stop_requested=true` (and `CronDelete`s in durable mode); the next tick's T0 terminates cleanly. See `.claude/skills/babysit-pr-stop/SKILL.md`.
- **One watcher per PR** — arm mode refuses a duplicate (A2).
- **Monitor mode:** while a dispatch subagent is in flight, the parent follows `monitor-mode.md` (orchestration only, ≤5-min heartbeat). The per-tick heartbeat satisfies the heartbeat requirement.
- **Post-merge install:** after this skill lands on `main`, symlink it globally via the skills worktree per `skill-symlinks.md`.
