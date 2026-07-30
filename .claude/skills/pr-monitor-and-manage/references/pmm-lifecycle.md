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
| `.pmm.fleet_at_pause` | `[{pr, head_sha, state}]` | Main skill Pause step 3 | `-wake` Step 4a |
| `.pmm.config_at_pause` | object | Main skill Pause step 3 | Step 0a, `-wake` Step 4b |
| `.pmm.auto_wake_cron_id` | string or null | Main skill Pause step 5 | `-stop` Step 3, `-wake` Step 3 |

`config_at_pause` fields: `author`, `repo`, `cadence`, `max_parallel`, `idle_pause_after`, `auto_wake`, `auto_wake_cadence`, `confirm_merges`.

> **Wake coupling:** `/pr-monitor-and-manage-wake` Step 4b rebuilds `PMM_FLAGS` from the `config_at_pause` blob — including `--confirm-merges` when `confirm_merges` is true — before re-arming the loop. The main skill's Step 0a uses the same blob for flag merging on direct re-invocation.

---

## Step 0a: Resume from pause

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
  CRON_ID=$(.claude/scripts/session-state.sh --get '.pmm.auto_wake_cron_id' 2>/dev/null || echo null)
  if [[ -n "$CRON_ID" && "$CRON_ID" != "null" ]]; then
    CronDelete "$CRON_ID" || {
      echo "ERROR: CronDelete failed for $CRON_ID — NOT clearing pause marker; cron may still fire, retry." >&2
      exit 1
    }
    JOBS=$(.claude/scripts/session-state.sh --get '.polling_jobs' 2>/dev/null || echo '[]')
    if [[ "$JOBS" != "null" && -n "$JOBS" ]]; then
      NEW_JOBS=$(jq -c --arg id "$CRON_ID" 'map(select(.id != $id))' <<<"$JOBS")
    else
      NEW_JOBS='[]'
    fi
    .claude/scripts/session-state.sh --set ".polling_jobs=$NEW_JOBS" --set '.pmm.auto_wake_cron_id=null'
  fi
  # 3. Clear pause marker + reset pmm_idle_streak=0 + set pmm_active=true
  #    + null .pmm_digest and .pmm_row_digest (atomic batch) — the digest reset
  #    forces Step 4's full table on the first post-resume tick (condition a/b)
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

Resume logic is shared with `/pr-monitor-and-manage-wake` — see `.claude/skills/pr-monitor-and-manage-wake/SKILL.md` Step 2 (cron teardown) and Step 3 (marker clear + loop re-arm). When resuming via re-invoking this skill (not `-wake`), apply the precedence rule in Step 1 after parsing `$ARGUMENTS`: any flag explicitly supplied on this invocation wins; omitted flags inherit from `.pmm.config_at_pause`. After resume, continue with Step 1 using the merged config and run a full discovery tick at **base** cadence (not the widened backoff cadence).

A stale marker left by a killed session is safely reconciled here: the next `/pr-monitor-and-manage` invocation reads it, resumes (or the user runs `/pmm-stop`), and re-runs discovery from scratch.

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

### 5. Optional auto-wake cron (`--auto-wake`)

When `$PMM_AUTO_WAKE` is true, register an hourly scan at pause time:

> **Warning:** `CronCreate` is **session-only** — this job fires only while Claude is running in the current session. `durable: true` has no effect. `--auto-wake` does **not** survive session turnover. (Behavioral redesign tracked as a follow-up ticket.)

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

Tell the user the cron job id and 7-day auto-expiry; note that the job is session-scoped (see `scheduling-reliability.md` contract note).

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
Merged:   <PR #s successfully merged this session via /wrap — e.g. "PR #1599, PR #1601"; "none" if none>
Subagents: <per-PR spawn/complete/failed summary from active_agents audit>
Blocked:  <PR # + reason for each HARD_BLOCK entry reported this session — e.g. "PR #123 human CHANGES_REQUESTED by @alice">
```

Hard-blocked PRs are reported here for visibility; the fleet may auto-pause afterward when idle.

---

## Deferred follow-ups (bounded refactor scope)

The following were intentionally left out of this PR (scope: bounded dedup + reference-extraction per Issue #815 / Issue #778 Option 2):

- **`resolve_script()` dedup across `-stop`/`-wake` family** — the same three-candidate lookup appears verbatim in `-stop/SKILL.md` and `-wake/SKILL.md`. A shared canonical location would prevent drift, but touching companion skills is out of scope here. Tracked for a future PR.
- **`pmm_delete_auto_wake_cron` helper** — the cron teardown block is duplicated in `-stop/SKILL.md`, `-wake/SKILL.md`, and now this file (Step 0a). A single shared helper (bash script or reference) would prevent lock-step edits. Tracked for a future PR.
- **Full FU-2 ≤150-line dispatcher collapse** — this bounded refactor brings SKILL.md to ~400 lines. The full collapse to ≤150 lines (with a script-side no-change short-circuit) remains deferred until the `/babysit-pr` delegation contract (#456/#460) is settled, per `token-efficiency-audit-2026-07.md` FU-2.
- **Per-PR `/babysit-pr` delegation** (#456/#460) — replacing Step 3's inline per-PR decision tree with one `/babysit-pr <PR>` dispatch per PR. The table, discovery, idempotency, and backoff scaffolding in SKILL.md stay unchanged until this lands.
