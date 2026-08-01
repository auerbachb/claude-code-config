# PMM Lifecycle: Resume, Pause, and Stop

Reference doc for `.claude/skills/pr-monitor-and-manage/SKILL.md`. Contains
the full Step 0a resume logic, Pause state machine (steps 1–6), pause-marker
schema, and Stop & Clean Exit procedure.

---

## Pause-marker schema

Pause marker fields live under nested `.pmm.*`. Existing runtime fields
(`pmm_active`, `pmm_digest`, `pmm_idle_streak`, etc.) remain flat.

| Field | Type | Written by | Read by |
|-------|------|-----------|---------|
| `.pmm.paused_at` | ISO-8601 string | Main skill Pause step 4 | Step 0a, `-wake` Step 2 |
| `.pmm.fleet_at_pause` | `[{pr, head_sha, state}]` | Main skill Pause step 4 (built in step 3) | `-wake` Step 4a |
| `.pmm.config_at_pause` | object | Main skill Pause step 4 (built in step 3) | Step 0a, `-wake` Step 4a, `-wake` Step 4b |

`config_at_pause` fields: `author`, `repo`, `cadence`, `max_parallel`, `idle_pause_after`, `auto_wake`, `auto_wake_cadence`, `confirm_merges`.

> **Wake coupling:** `/pr-monitor-and-manage-wake` Step 4b rebuilds `PMM_FLAGS` from the `config_at_pause` blob — including `--confirm-merges` when `confirm_merges` is true — before re-arming the loop. The main skill's Step 0a uses the same blob for flag merging on direct re-invocation. `-wake` Step 4a reads it too, but only for `author` / `repo`, to scope its lightweight fleet scan (issue #871) — which is why a missing blob fails that scan closed rather than resuming.

---

## Step 0a: Resume from pause

On **every** invocation, before Step 1, check for a pause marker. If present, this invocation is a **resume** — stop any auto-wake re-scan, clear the marker, merge config, and continue into normal ticking:

```bash
PAUSED_AT=$(.claude/scripts/session-state.sh --get '.pmm.paused_at' 2>/dev/null || echo null)
if [ "$PAUSED_AT" != null ] && [ -n "$PAUSED_AT" ]; then
  # 1. Read saved config into the $SAVED shell variable (fallback defaults if missing) —
  #    step 3 below clears .pmm.config_at_pause in session-state, so step 4 MUST use this
  #    already-captured $SAVED variable, never re-read .pmm.config_at_pause from
  #    session-state after step 3 has run (it will be null by then).
  SAVED=$(.claude/scripts/session-state.sh --get '.pmm.config_at_pause' 2>/dev/null || echo '{}')
  # 2. Cancel the auto-wake re-scan loop, if one is running (runtime loop-stop).
  #    Nothing to reconcile in state: since #827 the re-scan is a /loop, not a
  #    recorded cron job, so there is no id that can outlive this turn.
  # 3. Clear pause marker + reset pmm_idle_streak=0 + set pmm_active=true
  #    + null .pmm_digest and .pmm_row_digest (atomic batch) — the digest reset
  #    forces Step 4's full table on the first post-resume tick (condition a)
  .claude/scripts/session-state.sh \
    --set '.pmm.paused_at=null' \
    --set '.pmm.fleet_at_pause=null' \
    --set '.pmm.config_at_pause=null' \
    --set '.pmm_idle_streak=0' \
    --set '.pmm_active=true' \
    --set '.pmm_digest=null' \
    --set '.pmm_row_digest=null'
  # 4. Merge flags: explicit $ARGUMENTS override $SAVED (the step-1 variable, not
  #    session-state — that field is already cleared by step 3 at this point)
  echo "[PMM] Resuming from pause (paused_at=$PAUSED_AT) — flags on this invocation override saved config."
fi
```

> **The digest reset has two owners, one per resume path.** The branch above is guarded on a non-null `.pmm.paused_at`, so it covers only **direct re-invocation** of this skill. On the **`-wake`** path, Step 4b clears the marker before re-arming the loop — this branch is already skipped by the time the loop's first tick runs — so `-wake` Step 4b nulls `.pmm_digest` and `.pmm_row_digest` in its own atomic `--set` batch (issue #872). The guarantee "both digests are null after **any** resume" holds only while both sides do it; neither is redundant.

Resume logic is shared with `/pr-monitor-and-manage-wake` — see `.claude/skills/pr-monitor-and-manage-wake/SKILL.md` Step 3 (re-scan teardown) and Step 4b (marker clear + loop re-arm). When resuming via re-invoking this skill (not `-wake`), apply the precedence rule in Step 1 after parsing `$ARGUMENTS`: any flag explicitly supplied on this invocation wins; omitted flags inherit from `.pmm.config_at_pause`. After resume, continue with Step 1 using the merged config and run a full discovery tick at **base** cadence (not the widened backoff cadence).

A stale marker left by a killed session is safely reconciled here: the next `/pr-monitor-and-manage` invocation reads it, resumes (or the user runs `/pmm-stop`), and re-runs discovery from scratch.

**This marker is the fleet's cross-session continuity** (issue #827). It lives on disk in `session-state.json`, so it outlives the session that wrote it — which the `--auto-wake` cron never did, despite being documented as if it had. A session start also surfaces the marker unprompted (`session-scheduling-reconcile.sh`), so a paused fleet is offered back rather than waiting to be remembered.

---

## Pause (auto-pause — resumable)

Reached from Step 7 when the fleet is empty or idle. Unlike Stop & Clean Exit, Pause preserves a resume marker so `/pr-monitor-and-manage-wake` or re-invoking this skill can pick up where it left off.

### 1. Final heartbeat

Print the **full** Step 4 status table one last time — terminal snapshots (Pause here, Stop & Clean Exit) are an explicit exception to Step 4's quiet-tick suppression, so the user always gets a final fleet snapshot even when the pause tick itself was quiet — then a one-line reason:

```text
[$TS] PMM pausing — reason: <empty fleet | N idle ticks>
```

### 2. Cancel the loop

Cancel the recurring `/loop`:
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

### 5. Optional auto-wake re-scan (`--auto-wake`)

When `$PMM_AUTO_WAKE` is true, keep a low-frequency re-scan running instead of going fully quiet at pause:

```text
/loop $PMM_AUTO_WAKE_CADENCE /pr-monitor-and-manage-wake --auto-check
```

Nothing is recorded in `polling_jobs[]` and there is no job id to track — a `/loop` cannot outlive the turn that armed it, so there is no orphan to fail closed against. This replaces the `CronCreate` job that issue #827 removed: that job was session-scoped too, but was documented as surviving session turnover, and the fail-closed teardown it needed was duplicated across three files.

Cross-session continuity is the pause marker's job, not this loop's — see the note under Step 0a.

### 6. Summary line

```text
PMM paused — <N> PR(s) waiting on reviewer, no changes for <idle window>. Wake with `/pr-monitor-and-manage-wake` or re-run `/pr-monitor-and-manage <flags>`.
```

If `--auto-wake` is set, add: `Auto-wake re-scan armed — will scan every <cadence> for fleet changes while this session lasts.`

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
Merged:   <PR #s successfully merged this session via /wrap — e.g. "PR #1599, PR #1601"; "none" if none>
Subagents: <per-PR spawn/complete/failed summary from active_agents audit>
Blocked:  <PR # + reason for each HARD_BLOCK entry reported this session — e.g. "PR #123 human CHANGES_REQUESTED by @alice">
```

Hard-blocked PRs are reported here for visibility; the fleet may auto-pause afterward when idle.

---

## Deferred follow-ups (bounded refactor scope)

The following were intentionally left out of this PR (scope: bounded dedup + reference-extraction per Issue #815 / Issue #778 Option 2):

- **`resolve_script()` dedup across `-stop`/`-wake` family** — the same three-candidate lookup appears verbatim in `-stop/SKILL.md` and `-wake/SKILL.md`. A shared canonical location would prevent drift, but touching companion skills is out of scope here. Tracked for a future PR.
- ~~**`pmm_delete_auto_wake_cron` helper**~~ — **resolved by issue #827**, which removed the auto-wake cron entirely. The teardown block it would have factored no longer exists in any of the three files.
- **Full FU-2 ≤150-line dispatcher collapse** — this bounded refactor brings SKILL.md to ~400 lines. The full collapse to ≤150 lines (with a script-side no-change short-circuit) remains deferred until the `/babysit-pr` delegation contract (#456/#460) is settled, per `token-efficiency-audit-2026-07.md` FU-2.
- **Per-PR `/babysit-pr` delegation** (#456/#460) — replacing Step 3's inline per-PR decision tree with one `/babysit-pr <PR>` dispatch per PR. The table, discovery, idempotency, and backoff scaffolding in SKILL.md stay unchanged until this lands.
