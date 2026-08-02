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

> **Do not remove the `<!-- test-anchor: … -->` comments below.** They are how
> `.claude/scripts/tests/pmm-wake-step-4a.test.sh` extracts and runs *these*
> blocks rather than a copy, so the #871 fail-open cannot be re-opened by a
> prose cleanup (issue #888). Reword and reorder freely — just keep each anchor
> immediately above its fence. Changing the guards means re-running the
> discrimination control documented in that test.

Read saved config and fleet snapshot:

<!-- test-anchor: pmm-wake-step-4a-scan -->
```bash
CONFIG=$("$SESSION_STATE_SH" --get '.pmm.config_at_pause' 2>/dev/null || echo 'null')
# Fall back to `null`, NOT `[]`: an empty array is a *valid* snapshot (a fleet
# that drained to zero), so defaulting to it would turn a failed state read into
# a silent "fleet changed" and resume. `null` fails the guard below instead.
FLEET_AT_PAUSE=$("$SESSION_STATE_SH" --get '.pmm.fleet_at_pause' 2>/dev/null || echo 'null')
AUTHOR=$(jq -r '.author // empty' <<<"$CONFIG" 2>/dev/null || echo '')
REPO=$(jq -r '.repo // empty' <<<"$CONFIG" 2>/dev/null || echo '')
REPO_FLAG=()
[[ -n "$REPO" ]] && REPO_FLAG=(--repo "$REPO")

# Fail closed: a scan that cannot *prove* the fleet changed must keep the pause.
# An unchecked failure here reads as a fleet change and starts a full monitor
# run the user never asked for (issue #871).
scan_failed() {
  echo "ERROR: [auto-check] fleet scan failed — $1. Pause marker and re-scan kept; retrying on the next re-scan tick." >&2
  exit 1
}

# An empty $AUTHOR would silently rescope the scan (or error), so the result
# could never be compared against a snapshot taken for a specific author.
[[ -n "$AUTHOR" ]] || scan_failed "no author in .pmm.config_at_pause — cannot scope the scan"

# Lightweight scan — gh pr list only, no full per-PR gate reads.
# Capture the exit status rather than trusting it (the run_gh() idiom in
# .claude/scripts/pr-state.sh): `|| RC=$?` keeps set -e from swallowing it.
# Keep stderr OUT of $CURRENT — gh writes upgrade notices there even on success,
# and folding them in would corrupt otherwise-valid JSON.
SCAN_RC=0
CURRENT=$(gh pr list --state open --author "$AUTHOR" "${REPO_FLAG[@]}" \
  --json number,headRefOid,mergeStateStatus --limit 500 2>/dev/null) || SCAN_RC=$?

[[ $SCAN_RC -eq 0 ]] || scan_failed "gh pr list exited $SCAN_RC"
[[ -n "$CURRENT" ]]  || scan_failed "gh pr list returned empty output"
# `[]` is a VALID empty fleet (every PR landed) — a real change, never a failure.
jq -e 'type == "array"' <<<"$CURRENT" >/dev/null 2>&1 \
  || scan_failed "gh pr list output is not a JSON array"

# The saved snapshot is the other half of the comparison: a null or malformed
# .pmm.fleet_at_pause makes SAVED_FLEET empty, so a perfectly good CURRENT_FLEET
# compares as "changed" and resumes just as wrongly.
jq -e 'type == "array"' <<<"$FLEET_AT_PAUSE" >/dev/null 2>&1 \
  || scan_failed "saved snapshot .pmm.fleet_at_pause is missing or not a JSON array"

CURRENT_FLEET=$(jq -c '[.[] | {pr: .number, head_sha: .headRefOid, state: .mergeStateStatus}] | sort_by(.pr)' <<<"$CURRENT") \
  || scan_failed "could not normalise the scan result"
SAVED_FLEET=$(jq -c 'sort_by(.pr)' <<<"$FLEET_AT_PAUSE") \
  || scan_failed "could not normalise the saved snapshot"
```

Only once every guard above has passed may the two snapshots be compared:

<!-- test-anchor: pmm-wake-step-4a-compare -->
```bash
if [[ "$CURRENT_FLEET" == "$SAVED_FLEET" ]]; then
  # No-op: do NOT cancel the re-scan, do NOT clear the pause marker.
  echo "[auto-check] Fleet unchanged — re-scan continues."
  exit 0
fi
# Changed (count or per-PR state): cancel the re-scan (Step 3), then Step 4b
# (full resume + re-launch main skill).
```

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

# One atomic, locked read-modify-write. The two digest nulls MUST ride in this
# same call: this step clears .pmm.paused_at before the main skill runs, so its
# Step 0a reset branch (guarded on a non-null marker) never fires on this path —
# without them the stale digests survive and the first post-resume tick can
# render as a quiet heartbeat instead of the full table (issue #872).
# Mirror Step 0a exactly: .pmm_digest_streak is deliberately preserved.
"$SESSION_STATE_SH" \
  --set '.pmm.paused_at=null' \
  --set '.pmm.fleet_at_pause=null' \
  --set '.pmm.config_at_pause=null' \
  --set '.pmm_idle_streak=0' \
  --set '.pmm_active=true' \
  --set '.pmm_digest=null' \
  --set '.pmm_row_digest=null' \
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
- **A failed or unverifiable scan is never a fleet change.** If `gh pr list` errors, returns empty, or either snapshot fails to parse as a JSON array, Step 4a keeps the pause marker and the re-scan and exits non-zero — it never falls through to the comparison. Only a scan that *proves* a difference may resume.
- **Step 4b must null `.pmm_digest` and `.pmm_row_digest` in the same `--set` batch that clears the marker.** It clears `.pmm.paused_at` before the main skill runs, so the main skill's Step 0a reset cannot fire on this path; the digests are what make its Step 4 print the full table on the first post-resume tick.
- `--auto-check` must **not** run full per-PR gate reads — only `gh pr list` + comparison.
- Re-running `/pr-monitor-and-manage-wake` on a non-paused session is always a clean no-op (Step 2).
