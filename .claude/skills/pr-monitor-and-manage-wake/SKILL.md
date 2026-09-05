---
name: pr-monitor-and-manage-wake
description: Resume companion to /pr-monitor-and-manage. Wakes a paused PR-fleet manager from its saved pause marker, stops any auto-wake Monitor, and re-arms the main Monitor. Also serves as the lightweight --auto-check target for that re-scan. Triggers on "/pr-monitor-and-manage-wake", "/pmm-wake", "wake PR monitor".
triggers:
  - pr-monitor-and-manage-wake
  - pmm-wake
  - wake PR monitor
  - resume PR fleet
argument-hint: "[--auto-check] (default: user-initiated resume; --auto-check = lightweight fleet scan from the auto-wake re-scan)"
---

Resume companion to `/pr-monitor-and-manage`. Wakes a **paused** PR-fleet manager: reads the pause marker, stops any auto-wake Monitor, clears the marker, and re-arms the main Monitor at base cadence.

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

- **`--auto-check`** — lightweight fleet scan (invoked by the auto-wake Monitor). Compare `gh pr list` against `.pmm.fleet_at_pause`; re-launch main skill only if changed. It must carry the runtime-only `--monitor-generation <token>` emitted by that Monitor.
- **No flags (default)** — user-initiated resume: clear marker, stop the re-scan, re-arm the main Monitor.

Before reading the pause marker in `--auto-check` mode, parse the supplied generation and compare it
with `.pmm.auto_wake_monitor_generation`. Missing or unequal means a queued event from an old or
unidentified re-scan: print `[auto-check] Ignoring a stale Monitor generation.` and exit 0 without
reading GitHub or mutating state. This gate is first so an event queued before exact `TaskStop`
cannot see a later pause marker and cancel or resume the replacement generation.

Execute that parser and generation gate explicitly before Step 2:

```bash
MODE="user-resume"
AUTO_CHECK_GENERATION=""
_AUTO_CHECK_EXPECT_GENERATION=false
for _WAKE_ARG in $ARGUMENTS; do
  if [[ "$_AUTO_CHECK_EXPECT_GENERATION" == true ]]; then
    AUTO_CHECK_GENERATION="$_WAKE_ARG"
    _AUTO_CHECK_EXPECT_GENERATION=false
    continue
  fi
  case "$_WAKE_ARG" in
    --auto-check) MODE="auto-check" ;;
    --monitor-generation) _AUTO_CHECK_EXPECT_GENERATION=true ;;
  esac
done
if [[ "$_AUTO_CHECK_EXPECT_GENERATION" == true ]]; then
  echo "ERROR: --monitor-generation requires a token." >&2
  exit 2
fi
if [[ "$MODE" == "auto-check" ]]; then
  RECORDED_AUTO_CHECK_GENERATION=$("$SESSION_STATE_SH" --get '.pmm.auto_wake_monitor_generation' 2>/dev/null || echo null)
  if [[ -z "$AUTO_CHECK_GENERATION" || "$AUTO_CHECK_GENERATION" == "null" ||
        "$AUTO_CHECK_GENERATION" != "$RECORDED_AUTO_CHECK_GENERATION" ]]; then
    echo "[auto-check] Ignoring a stale Monitor generation."
    exit 0
  fi
elif [[ -n "$AUTO_CHECK_GENERATION" ]]; then
  echo "ERROR: --monitor-generation is runtime-only and requires --auto-check." >&2
  exit 2
fi
```

Ignore `--monitor-generation` and its captured token in any later mode/config parsing. Never copy a
generation into the replacement main Monitor; Step 4b generates a fresh one for that arm.

## Step 2: Check pause marker

```bash
PAUSED_AT=$("$SESSION_STATE_SH" --get '.pmm.paused_at' 2>/dev/null || echo null)
STOP_PENDING=$("$SESSION_STATE_SH" --get '.pmm.stop_requested' 2>/dev/null || echo false)
```

- If `$STOP_PENDING` is `true` → report incomplete PMM teardown and exit non-zero; never resume or
  auto-check until `/pmm-stop` completes exact task teardown.
- If `$PAUSED_AT` is `null`/empty → print **"PMM not paused — either not started or already running."** and exit 0 (idempotent no-op).
- If present → **Step 3.5 first** (re-consult the usage horizon; a non-resuming verdict ends the invocation before anything is stopped), then route by mode:
  - **`--auto-check`** → Step 4a (compare fleet; the re-scan stays unless changed).
  - **User-initiated (default)** → Step 3 (cancel re-scan) → Step 4b (resume).

## Step 3.5: Re-consult the usage horizon before resuming anything (issue #1444)

Runs on **both** resume routes, immediately after Step 2 routes and **before** Step 3 tears anything down. A wake that resumes straight back into a closed usage window undoes the stand-down that paused the fleet in the first place, and the pause it would have to re-take costs another full tick. Consulting before teardown is what lets a refusal be a true no-op: nothing has been stopped yet, so a still-`critical` verdict leaves the armed re-scan exactly as it found it rather than having to arm a replacement — which §8.1 forbids this loop from doing anyway.

Resolve `usage-horizon.sh` with the same candidate order as `session-state.sh` (`$HOME/.claude/skills-worktree/.claude/scripts/`, `$HOME/.claude/scripts/`, `.claude/scripts/`), then run `subagent-thread-limit-park.md` §7.1's gate block followed by §8.1's posture block — resolved through the matching `.claude/reference/` order, not re-derived here. Feed §7.1 the counter the **harness** printed into this turn's context and nothing else; an absent counter is `unknown`.

| Verdict | This wake |
|---------|-----------|
| `clear` | Resume normally — Step 4a / Step 4b unchanged. |
| `approaching` | Resume. The fleet polls again and Step 3.7 of the main skill keeps suppressing new fixer dispatch while the verdict holds — a paused fleet cannot land the merge-ready PRs an `approaching` window still has room for. |
| `critical` | **Do not resume.** Stop nothing, arm nothing, write nothing: the pause marker, the config, the fleet snapshot, and any armed re-scan all stay exactly as they are. Print the line below and exit 0. This path claims no park and never touches `.repos["<key>"].day.*` (§8). |
| `unknown` | **Do not resume dispatch, and park nothing further.** The existing pause already holds; leave every field untouched, say the verdict was unreadable, and exit 0. A user who wants the fleet back regardless re-runs this command after the counter is readable, or starts `/pr-monitor-and-manage` directly. |

```text
[$TS] PMM stays paused — usage horizon critical (paused_at=<PAUSED_AT>, cause=<pause_cause>). Re-run /pr-monitor-and-manage-wake once the window reopens.
```

`unknown` prints the same line with `— horizon verdict unreadable` in place of the verdict clause. Read `.pmm.pause_cause` for that line only: a fleet paused for `empty_fleet` and one paused for `usage_horizon` both stay paused here, so the cause is reporting, not routing. On `--auto-check`, a non-resuming verdict leaves the re-scan running and counts as "no change" for its own purposes — the next re-scan tick re-consults.

## Step 3: Cancel the auto-wake re-scan (user resume and auto-check-on-change only)

**Do NOT run this step in `--auto-check` mode when the fleet is unchanged** — the re-scan must keep running until a change is detected.

When `$MODE` is `--auto-check`, skip to Step 4a first; only cancel the re-scan from Step 4b after a fleet change is confirmed, or when `$MODE` is user-initiated resume (default).

Read both task IDs and their matching generations (`.pmm.auto_wake_monitor_task_id` plus
`.pmm.auto_wake_monitor_generation`, and `.pmm_monitor_task_id` plus
`.pmm_monitor_generation`) and stop each recorded task with exact `TaskStop`. The main-task ID is
normally null while paused, but a degraded pause retains it when teardown failed. Clear each
successfully stopped ID and generation immediately through one atomic
`session-state.sh` write while leaving the complete pause marker/config/fleet intact. If either
present ID cannot be stopped, abort the resume: retain that failed identity pair, clear only
identity pairs whose exact stops succeeded, and do not arm the replacement main Monitor. This prevents a later retry from
treating an already-stopped task as a live teardown failure. Nothing is removed from
`polling_jobs[]`; Issue #924 replaces the unreliable `/loop` re-scan with this recorded Monitor
task.

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

Read config and reconstruct invocation flags:

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
```

Arm the replacement at **base** cadence (not widened backoff) through a persistent `Monitor`:

```bash
MONITOR_GENERATION="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
while sleep "<CADENCE in seconds>"; do
  printf '%s\n' "/pr-monitor-and-manage --tick --monitor-generation $MONITOR_GENERATION <PMM_FLAGS>"
done
```

Call `Monitor` with `persistent: true` and description `PR fleet monitor`, then require a returned task ID. If arming fails or returns no ID, leave the pause marker/config/fleet intact, keep `pmm_active=false`, and report that resume failed (the auto-wake re-scan was already stopped in Step 3).

After a successful arm, clear the marker and publish the new task ID in one atomic write:

```bash
# The two digest nulls MUST ride in this call: clearing .pmm.paused_at makes
# the main skill's Step 0a reset branch ineligible on its first Monitor tick.
# Mirror Step 0a exactly: .pmm_digest_streak is deliberately preserved.
"$SESSION_STATE_SH" \
  --set '.pmm.stop_requested=false' \
  --set '.pmm.paused_at=null' \
  --set '.pmm.pause_cause=null' \
  --set '.pmm.fleet_at_pause=null' \
  --set '.pmm.config_at_pause=null' \
  --set '.pmm_idle_streak=0' \
  --set '.pmm_active=true' \
  --set ".pmm_monitor_task_id=$MONITOR_TASK_ID" \
  --set ".pmm_monitor_generation=\"$MONITOR_GENERATION\"" \
  --set '.pmm.auto_wake_monitor_task_id=null' \
  --set '.pmm.auto_wake_monitor_generation=null' \
  --set '.pmm_digest=null' \
  --set '.pmm_row_digest=null' \
  --set '.pmm_next_expected_tick_at=null'
```

If that ID+generation publication write fails, stop the newly armed task with `TaskStop`; the atomic failure leaves the pause
marker intact, so never claim resume. If the rollback stop also fails, report the exact new task ID
and generation and retain the paused state; best-effort set `.pmm.stop_requested=true` and `.pmm_active=false` so
the new task's internal `--tick` events are no-ops and no retry can arm a duplicate. An unrecorded
live task must never be described as cleaned up.

The next tick runs full discovery + per-PR state read. Print:

```text
PMM resumed — Monitor re-armed at <CADENCE>. Fleet will be rediscovered on the next tick.
```

For `--auto-check` with detected change, add: `[auto-check] Fleet changed — re-scan stopped, main Monitor re-launched.`

## Safety

- Never clear the pause marker on resume without also cancelling the auto-wake re-scan (Step 3) — except `--auto-check` no-op exits without touching either.
- A present main or auto-wake task ID whose `TaskStop` fails is a hard resume abort. Never arm the
  replacement Monitor or discard that failed ID while an old task can still emit. IDs whose exact
  stops succeeded have their matching generations cleared before the abort so a retry never wedges
  on stale task identity.
- **A failed or unverifiable scan is never a fleet change.** If `gh pr list` errors, returns empty, or either snapshot fails to parse as a JSON array, Step 4a keeps the pause marker and the re-scan and exits non-zero — it never falls through to the comparison. Only a scan that *proves* a difference may resume.
- **Step 4b must null `.pmm_digest` and `.pmm_row_digest` in the same `--set` batch that clears the marker.** It clears `.pmm.paused_at` before the main skill runs, so the main skill's Step 0a reset cannot fire on this path; the digests are what make its Step 4 print the full table on the first post-resume tick.
- `--auto-check` must **not** run full per-PR gate reads — only `gh pr list` + comparison.
- Re-running `/pr-monitor-and-manage-wake` on a non-paused session is always a clean no-op (Step 2).
