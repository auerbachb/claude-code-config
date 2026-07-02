---
name: pr-monitor-and-manage-wake
description: Resume companion to /pr-monitor-and-manage. Wakes a paused PR-fleet-manager loop from its saved pause marker, tears down any auto-wake cron, and re-arms the main loop. Also serves as the lightweight --auto-check target for the hourly auto-wake cron. Triggers on "/pr-monitor-and-manage-wake", "/pmm-wake", "wake PR monitor".
triggers:
  - pr-monitor-and-manage-wake
  - pmm-wake
  - wake PR monitor
  - resume PR fleet
argument-hint: "[--auto-check] (default: user-initiated resume; --auto-check = lightweight fleet scan from auto-wake cron)"
---

Resume companion to `/pr-monitor-and-manage`. Wakes a **paused** PR-fleet-manager loop: reads the pause marker, deletes any auto-wake cron, clears the marker, and re-arms the main loop at base cadence.

Idempotent: running on a non-paused session is a clean no-op.

> **Post-merge symlink:** after merge to `main`, symlink `~/.claude/skills/pr-monitor-and-manage-wake` → `~/.claude/skills-worktree/.claude/skills/pr-monitor-and-manage-wake` per `skill-symlinks.md` — never copy, never symlink to the root repo.

## Resolve the state helper

Same three-candidate lookup as `/babysit-pr-stop`:

```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
SESSION_STATE_SH=$(resolve_script session-state.sh) || { echo "ERROR: session-state.sh not found" >&2; exit 1; }
```

## Step 1: Parse mode

- **`--auto-check`** — lightweight fleet scan (invoked by the hourly auto-wake `CronCreate` job). Compare `gh pr list` against `.pmm.fleet_at_pause`; re-launch main skill only if changed.
- **No flags (default)** — user-initiated resume: clear marker, delete cron, re-arm loop.

## Step 2: Check pause marker

```bash
PAUSED_AT=$("$SESSION_STATE_SH" --get '.pmm.paused_at' 2>/dev/null || echo null)
```

- If `$PAUSED_AT` is `null`/empty → print **"PMM not paused — either not started or already running."** and exit 0 (idempotent no-op).
- If present → proceed.

## Step 3: Delete auto-wake cron (fail-closed — shared by all resume paths)

When an auto-wake cron exists, it must be deleted **before** clearing the pause marker or claiming resume success:

```bash
CRON_ID=$("$SESSION_STATE_SH" --get '.pmm.auto_wake_cron_id' 2>/dev/null || echo null)
if [[ -n "$CRON_ID" && "$CRON_ID" != "null" ]]; then
  CronDelete "$CRON_ID" || {
    echo "ERROR: CronDelete failed for $CRON_ID — NOT clearing pause marker; cron may still fire, retry /pr-monitor-and-manage-wake." >&2
    exit 1
  }
  JOBS=$("$SESSION_STATE_SH" --get '.polling_jobs' 2>/dev/null || echo '[]')
  if [[ "$JOBS" != "null" && -n "$JOBS" ]]; then
    NEW_JOBS=$(jq -c --arg id "$CRON_ID" 'map(select(.id != $id))' <<<"$JOBS")
  else
    NEW_JOBS='[]'
  fi
  "$SESSION_STATE_SH" --set ".polling_jobs=$NEW_JOBS" --set '.pmm.auto_wake_cron_id=null'
fi
```

Only **after** successful `CronDelete` (or when no cron was registered) proceed to marker clear / re-arm.

## Step 4a: `--auto-check` branch (lightweight scan)

Read saved config and fleet snapshot:

```bash
CONFIG=$("$SESSION_STATE_SH" --get '.pmm.config_at_pause' 2>/dev/null || echo '{}')
FLEET_AT_PAUSE=$("$SESSION_STATE_SH" --get '.pmm.fleet_at_pause' 2>/dev/null || echo '[]')
AUTHOR=$(jq -r '.author // empty' <<<"$CONFIG")
REPO=$(jq -r '.repo // empty' <<<"$CONFIG")
REPO_FLAG=()
[[ -n "$REPO" ]] && REPO_FLAG=(--repo "$REPO")

# Lightweight scan — gh pr list only, no full per-PR gate reads
CURRENT=$(gh pr list --state open --author "$AUTHOR" "${REPO_FLAG[@]}" \
  --json number,headRefOid,mergeStateStatus --limit 500)
CURRENT_FLEET=$(jq -c '[.[] | {pr: .number, head_sha: .headRefOid, state: .mergeStateStatus}] | sort_by(.pr)' <<<"$CURRENT")
SAVED_FLEET=$(jq -c 'sort_by(.pr)' <<<"$FLEET_AT_PAUSE")
```

- If `$CURRENT_FLEET` equals `$SAVED_FLEET` (count + per-PR state) → **no-op**. Print one line: `[auto-check] Fleet unchanged — cron continues.` Exit 0. Do **not** clear the pause marker.
- If changed → proceed to Step 4b (full resume + re-launch main skill).

## Step 4b: Resume (user wake or auto-check detected change)

Read config, reconstruct invocation flags, clear marker, re-arm loop:

```bash
CONFIG=$("$SESSION_STATE_SH" --get '.pmm.config_at_pause' 2>/dev/null || echo '{}')
# Build flag string from config (author, repo, cadence, idle-pause-after, auto-wake, auto-wake-cadence)
PMM_FLAGS="..."   # e.g. --author alice --repo org/repo --cadence 5m --idle-pause-after 3
CADENCE=$(jq -r '.cadence // "5m"' <<<"$CONFIG")

"$SESSION_STATE_SH" \
  --set '.pmm.paused_at=null' \
  --set '.pmm.fleet_at_pause=null' \
  --set '.pmm.config_at_pause=null' \
  --set '.pmm_active=true' \
  --set '.pmm_next_expected_tick_at=null'
```

Re-arm at **base** cadence (not widened backoff):

```text
/loop <CADENCE> /pr-monitor-and-manage <PMM_FLAGS>
```

The next tick runs full discovery + per-PR state read. Print:

```text
PMM resumed — re-armed at <CADENCE>. Fleet will be rediscovered on the next tick.
```

For `--auto-check` with detected change, add: `[auto-check] Fleet changed — cron deleted, main loop re-launched.`

## Safety

- Never clear the pause marker unless the auto-wake cron is confirmed deleted (Step 3).
- `--auto-check` must **not** run full per-PR gate reads — only `gh pr list` + comparison.
- Re-running `/pr-monitor-and-manage-wake` on a non-paused session is always a clean no-op (Step 2).
