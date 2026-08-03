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

> **Wake coupling:** `/pr-monitor-and-manage-wake` Step 4b rebuilds `PMM_FLAGS` from the `config_at_pause` blob — including `--confirm-merges` when `confirm_merges` is true — before re-arming the Monitor. The main skill's Step 0a uses the same blob for flag merging on direct re-invocation. `-wake` Step 4a reads it too, but only for `author` / `repo`, to scope its lightweight fleet scan (issue #871) — which is why a missing blob fails that scan closed rather than resuming.

---

## Step 0a: Resume from pause

On **every** invocation, before Step 1, check for a pause marker. If present, this invocation is a
**resume** — capture config, stop any auto-wake re-scan, merge config, and defer marker removal until
the replacement main Monitor is both armed and publishable:

```bash
PAUSED_AT=$(.claude/scripts/session-state.sh --get '.pmm.paused_at' 2>/dev/null || echo null)
if [ "$PAUSED_AT" != null ] && [ -n "$PAUSED_AT" ]; then
  # 1. Read saved config into the $SAVED shell variable (fallback defaults if missing) —
  #    step 3 below clears .pmm.config_at_pause in session-state, so step 4 MUST use this
  #    already-captured $SAVED variable, never re-read .pmm.config_at_pause from
  #    session-state after step 3 has run (it will be null by then).
  SAVED=$(.claude/scripts/session-state.sh --get '.pmm.config_at_pause' 2>/dev/null || echo '{}')
  # 2. Read both .pmm_monitor_task_id and .pmm.auto_wake_monitor_task_id. When
  #    present, stop each exact task; any failed TaskStop aborts resume and
  #    preserves both IDs and the pause marker. This covers degraded pauses that
  #    retained a main-task ID after its stop failed.
  # 3. Set a shell-only RESUMING_FROM_PAUSE=true marker. Do not publish active
  #    state or clear any on-disk pause fields yet.
  RESUMING_FROM_PAUSE=true
  # 4. Merge flags: explicit $ARGUMENTS override the captured $SAVED value.
  echo "[PMM] Resuming from pause (paused_at=$PAUSED_AT) — flags on this invocation override saved config."
fi
```

Step 7 treats the persisted old main-task ID as absent (it was stopped above) and arms the main
Monitor at base cadence. Only after it returns a task ID does one atomic
`session-state.sh` write publish that ID and `pmm_active=true`, clear all three pause-marker fields
and `.pmm.auto_wake_monitor_task_id`, reset `pmm_idle_streak`, and null both table digests. If the
arm or state write fails, stop the new task and leave the pause marker intact. If the rollback stop
fails too, report the exact new task ID rather than claiming rollback. This ordering makes direct
re-invocation transactional in the same way as the `-wake` path.

Before that publication write, Step 4 treats the prior table digests as null **in shell** so the
current direct-resume tick renders the full table. It must not persist those nulls early: rendering
state can be provisional, but destroying the durable pause marker cannot.

> **The digest reset has two owners, one per resume path.** Step 7's publication transaction covers
> **direct re-invocation** when `RESUMING_FROM_PAUSE=true`. On the **`-wake`** path, Step 4b clears the
> marker before the next main-skill tick, so `-wake` Step 4b nulls `.pmm_digest` and `.pmm_row_digest`
> in its own atomic `--set` batch (Issue #872). The guarantee "both digests are null after **any**
> resume" holds only while both sides do it; neither is redundant.

Resume logic is shared with `/pr-monitor-and-manage-wake` — see `.claude/skills/pr-monitor-and-manage-wake/SKILL.md` Step 3 (re-scan teardown) and Step 4b (marker clear + Monitor re-arm). When resuming via re-invoking this skill (not `-wake`), apply the precedence rule in Step 1 after parsing `$ARGUMENTS`: any flag explicitly supplied on this invocation wins; omitted flags inherit from `.pmm.config_at_pause`. After resume, continue with Step 1 using the merged config and run a full discovery tick at **base** cadence (not the widened backoff cadence).

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

### 2. Stop the main Monitor

Read `.pmm_monitor_task_id`, stop that exact task with `TaskStop`, then clear the ID. A missing or
unstoppable task is a degraded state that must be reported; set `pmm_active=false` so no later tick
claims the fleet remains watched.

If the ID is present and `TaskStop` fails, retain it and do not arm the optional auto-wake Monitor:
two pollers must never be created from an unverified handoff. The pause marker may still be written
so a later explicit resume can retry exact teardown.

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

After Step 2's `TaskStop` succeeds, add `--set '.pmm_monitor_task_id=null'` to this same batch.
If the stop failed, omit that write and retain the ID for diagnosis.

Preserve `pmm_digest`, `pmm_digest_streak`, and `pmm_idle_streak` as audit trail.

### 5. Optional auto-wake re-scan (`--auto-wake`)

When `$PMM_AUTO_WAKE` is true, keep a low-frequency re-scan running instead of going fully quiet at pause:

```bash
while sleep "<$PMM_AUTO_WAKE_CADENCE in seconds>"; do
  printf '%s\n' '/pr-monitor-and-manage-wake --auto-check'
done
```

Arm that command through `Monitor` with `persistent: true`; store the returned task ID in
`.pmm.auto_wake_monitor_task_id` so resume and stop can terminate the exact process. Nothing is
recorded in `polling_jobs[]`. This replaces both the `CronCreate` job removed by issue #827 and the
unreliable `/loop` re-scan retired by issue #924.

If Monitor arming fails or returns no task ID, leave `.pmm.auto_wake_monitor_task_id=null` and
report that the fleet is paused without auto-wake. Never claim a re-scan is armed from intent alone.

Cross-session continuity is the pause marker's job, not this Monitor's — see the note under Step 0a.

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
# Stop the recorded main/auto-wake Monitor task IDs with TaskStop. Clear each ID
# only after that exact stop succeeds; retain a failed task ID for diagnosis.
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
