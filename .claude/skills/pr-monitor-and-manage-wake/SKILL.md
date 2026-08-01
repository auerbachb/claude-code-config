---
name: pr-monitor-and-manage-wake
description: Resume companion to /pr-monitor-and-manage. Wakes a paused PR-fleet-manager loop from its saved pause marker, cancels any auto-wake re-scan, and re-arms the main loop. Also serves as the lightweight --auto-check target for that re-scan. Triggers on "/pr-monitor-and-manage-wake", "/pmm-wake", "wake PR monitor".
triggers:
  - pr-monitor-and-manage-wake
  - pmm-wake
  - wake PR monitor
  - resume PR fleet
argument-hint: "[--auto-check] (default: user-initiated resume; --auto-check = lightweight fleet scan from the auto-wake re-scan)"
---

Resume companion to `/pr-monitor-and-manage`. Wakes a **paused** PR-fleet-manager loop: reads the pause marker, cancels any auto-wake re-scan, clears the marker, and re-arms the main loop at base cadence.

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

- **`--auto-check`** — lightweight fleet scan (invoked by the auto-wake re-scan `/loop`). Compare `gh pr list` against `.pmm.fleet_at_pause`; re-launch main skill only if changed.
- **No flags (default)** — user-initiated resume: clear marker, cancel the re-scan, re-arm loop.

## Step 2: Check pause marker

```bash
PAUSED_AT=$("$SESSION_STATE_SH" --get '.pmm.paused_at' 2>/dev/null || echo null)
```

- If `$PAUSED_AT` is `null`/empty → print **"PMM not paused — either not started or already running."** and exit 0 (idempotent no-op).
- If present → route by mode:
  - **`--auto-check`** → Step 4a (compare fleet; the re-scan stays unless changed).
  - **User-initiated (default)** → Step 3 (cancel re-scan) → Step 4b (resume).

## Step 3: Cancel the auto-wake re-scan (user resume and auto-check-on-change only)

**Do NOT run this step in `--auto-check` mode when the fleet is unchanged** — the re-scan must keep running until a change is detected.

When `$MODE` is `--auto-check`, skip to Step 4a first; only cancel the re-scan from Step 4b after a fleet change is confirmed, or when `$MODE` is user-initiated resume (default).

Cancel the `/loop` armed at pause time (runtime loop-stop), then proceed to marker clear / re-arm. Since issue #827 the re-scan is a plain `/loop` rather than a `CronCreate` job, so there is no id to delete, no `polling_jobs[]` entry to prune, and no fail-closed teardown to get wrong — a loop cannot outlive the turn that armed it.

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

- If `$CURRENT_FLEET` equals `$SAVED_FLEET` (count + per-PR state) → **no-op**. Print one line: `[auto-check] Fleet unchanged — re-scan continues.` Exit 0. Do **not** cancel the re-scan or clear the pause marker.
- If changed → cancel the re-scan (Step 3), then proceed to Step 4b (full resume + re-launch main skill).

## Step 4b: Resume (user wake or auto-check detected change)

Cancel the re-scan (Step 3) if not already done (user-initiated resume does it before this step; auto-check does it only after detecting a change).

Read config, reconstruct invocation flags, clear marker, reset idle streak, re-arm loop:

```bash
CONFIG=$("$SESSION_STATE_SH" --get '.pmm.config_at_pause' 2>/dev/null || echo '{}')
CADENCE=$(jq -r '.cadence // "5m"' <<<"$CONFIG")

# Rebuild PMM_FLAGS from saved config (must include every persisted field)
PMM_FLAGS=""
AUTHOR=$(jq -r '.author // empty' <<<"$CONFIG")
REPO=$(jq -r '.repo // empty' <<<"$CONFIG")
[ -n "$AUTHOR" ] && PMM_FLAGS="$PMM_FLAGS --author $AUTHOR"
[ -n "$REPO" ]    && PMM_FLAGS="$PMM_FLAGS --repo $REPO"
PMM_FLAGS="$PMM_FLAGS --cadence $(jq -r '.cadence // "5m"' <<<"$CONFIG")"
PMM_FLAGS="$PMM_FLAGS --max-parallel $(jq -r '.max_parallel // 3' <<<"$CONFIG")"
PMM_FLAGS="$PMM_FLAGS --idle-pause-after $(jq -r '.idle_pause_after // 3' <<<"$CONFIG")"
jq -e '.auto_wake == true' <<<"$CONFIG" >/dev/null 2>&1 && PMM_FLAGS="$PMM_FLAGS --auto-wake"
PMM_FLAGS="$PMM_FLAGS --auto-wake-cadence $(jq -r '.auto_wake_cadence // "60m"' <<<"$CONFIG")"
jq -e '.confirm_merges == true' <<<"$CONFIG" >/dev/null 2>&1 && PMM_FLAGS="$PMM_FLAGS --confirm-merges"

"$SESSION_STATE_SH" \
  --set '.pmm.paused_at=null' \
  --set '.pmm.fleet_at_pause=null' \
  --set '.pmm.config_at_pause=null' \
  --set '.pmm_idle_streak=0' \
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

For `--auto-check` with detected change, add: `[auto-check] Fleet changed — re-scan cancelled, main loop re-launched.`

## Safety

- Never clear the pause marker on resume without also cancelling the auto-wake re-scan (Step 3) — except `--auto-check` no-op exits without touching either.
- `--auto-check` must **not** run full per-PR gate reads — only `gh pr list` + comparison.
- Re-running `/pr-monitor-and-manage-wake` on a non-paused session is always a clean no-op (Step 2).
