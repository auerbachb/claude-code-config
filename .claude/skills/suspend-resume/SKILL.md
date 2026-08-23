---
name: suspend-resume
description: Resume companion to /suspend. Reads the parked state from the last /suspend run, prints the board (what landed, what is parked with next move, what is waiting on a reviewer), re-arms Monitors that were stopped, and reports the refill pause with instructions for lifting it. Thin restorer — it delegates into /babysit-pr, /pr-monitor-and-manage-wake, and /pm day resume rather than reimplementing their logic. Triggers on "suspend-resume", "resume from suspend", "back from laptop", "restore parked work", "what did I park".
triggers:
  - suspend-resume
  - resume from suspend
  - back from laptop
  - restore parked work
  - what did I park
argument-hint: "[--resume-refill] (--resume-refill clears the refill pause; without it the pause stands and is reported)"
---

Thin restorer for `/suspend`. Reads the suspend state, prints the board as it is **now** (not as it was parked — it re-reads GitHub before printing), re-arms what was stopped, and reports what is waiting on you.

Running this when no suspend state exists is a clean no-op: `No parked session found — nothing to resume.`

## Step 0: Resolve helpers

`/suspend-resume` is invocable from any thread — including one whose cwd is a different worktree than the one `/suspend` ran in. The three-candidate resolution order is identical to every other stop-style command:

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
SESSION_STATE_SH=$(resolve_script session-state.sh) || SESSION_STATE_SH=""
```

An unresolved `session-state.sh` in this skill is fatal for the state-read path but recoverable: fall back to the marker file in Step 1. Say which path is being used so the user knows.

Parse `--resume-refill`:

```bash
RESUME_REFILL=false
for arg in $ARGUMENTS; do
  case "$arg" in
    --resume-refill) RESUME_REFILL=true ;;
  esac
done
```

## Step 1: Read suspend state

Try the state file first; fall back to the newest repo-matching marker if it fails. The marker filename includes the repo key (set by `/suspend` Step 7a) — validate it before choosing so a marker from another repo cannot be mistaken for this one's state:

```bash
SUSPEND_STATE=""
USE_MARKER=false
MARKER_PATH=""
if [[ -n "$SESSION_STATE_SH" ]]; then
  REPO_KEY=$("$SESSION_STATE_SH" --repo-key 2>/dev/null) || REPO_KEY=""
  if [[ -n "$REPO_KEY" ]]; then
    SUSPEND_STATE=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].suspend" 2>/dev/null || echo "")
  fi
fi

# Fall back to the newest marker file if state was not readable.
# Validate the repo key embedded in the filename before using a candidate.
if [[ -z "$SUSPEND_STATE" || "$SUSPEND_STATE" == "null" ]]; then
  if [[ -z "${REPO_KEY:-}" ]]; then
    # Without a repo key we cannot safely distinguish our own markers from
    # another repo's — the pattern *--* would match anything. Fail closed.
    echo "No parked session found — nothing to resume."
    exit 0
  fi
  REPO_KEY_SAFE="${REPO_KEY//\//-}"
  # Search only for markers that contain this repo's key, newest first
  while IFS= read -r candidate; do
    if [[ "$(basename "$candidate")" == *"-${REPO_KEY_SAFE}-"* ]]; then
      MARKER_PATH="$candidate"
      break
    fi
  done < <(ls -t "$HOME/.claude/handoffs/suspend-"*.md 2>/dev/null)

  if [[ -n "$MARKER_PATH" ]]; then
    echo "(reading from marker file — session-state.json was not readable; using $MARKER_PATH)"
    USE_MARKER=true
    # Parse key fields from the human-readable marker. The marker's sections
    # mirror the suspend state block; extract what is available.
    SUSPEND_STATE=$(awk '
      /^##? Landed/        { in_landed=1; in_parked=0; in_monitors=0 }
      /^##? Parked/        { in_parked=1; in_landed=0; in_monitors=0 }
      /^##? Monitors/      { in_monitors=1; in_landed=0; in_parked=0 }
      /^##/                { in_landed=0; in_parked=0; in_monitors=0 }
      { print }
    ' "$MARKER_PATH")
    # The marker is human-readable prose; later steps read it directly via
    # $MARKER_PATH rather than parsing $SUSPEND_STATE as JSON.
  fi
fi

# If neither source has state, this is a clean no-op
if [[ -z "$SUSPEND_STATE" && "$USE_MARKER" == false ]]; then
  echo "No parked session found — nothing to resume."
  exit 0
fi
```

**Reading from `session-state.json` is the primary path.** When that path is available, all later steps can use `jq` to parse `$SUSPEND_STATE` as JSON. When the marker fallback is active (`USE_MARKER=true`), later steps read the marker file directly from `$MARKER_PATH` — they cannot assume `$SUSPEND_STATE` is valid JSON, and should extract what they can from the human-readable sections.

**The `suspend` block is invisible to `--session-view`** (that projection lifts only `.prs` and `.root_repo`). Always read it with an explicit `--get .repos["<key>"].suspend` — never via `--session-view`.

## Step 2: Check if already resumed

For a JSON state read, check the `active` flag. For a marker-only read, the marker's existence implies an incomplete restore (a fully-resumed session writes `active: false` in the state file, which masks the state before this step runs):

```bash
if [[ "$USE_MARKER" == false ]]; then
  ACTIVE=$(jq -r '.active // true' <<<"$SUSPEND_STATE" 2>/dev/null || echo "true")
  if [[ "$ACTIVE" == "false" ]]; then
    # Check whether any re-arms were incomplete (added in Step 7)
    PENDING_REARMS=$(jq -r '.monitors_stopped // [] | map(select(.stopped == true and (.rearmed // false) == false)) | length' <<<"$SUSPEND_STATE" 2>/dev/null || echo "0")
    if [[ "$PENDING_REARMS" -gt 0 ]]; then
      echo "Suspend session was partially resumed ($PENDING_REARMS re-arm(s) still pending). Continuing restore..."
    else
      echo "Suspend state exists but is already marked resumed (active: false). Run /suspend again to park a new session."
      exit 0
    fi
  fi
fi
```

Idempotent on a fully-resumed session. On a partially-resumed session (some re-arms failed), the step continues so Step 5 can retry the incomplete entries.

## Step 3: Re-read GitHub for each parked PR

Before printing the board, re-read GitHub for each PR listed in `.suspend.parked`. A state that moved since suspend (a review that landed, a merge that completed after the `/wrap` window, CI that finished) is reported as it is **now**, not as it was parked.

For each parked PR, run `gh pr view <N> --json state,mergeStateStatus,mergeable,reviewDecision` and update the parked entry's display. A PR whose `state: MERGED` is reported as landed (with a note that it merged after the window) rather than parked. A PR whose CI finished running is reported with its updated status.

This re-read is display-only: it does not change the persisted `suspend` block. The block is a historical record of the parking point.

## Step 4: Print the board

```
=== Resuming from suspend at <suspended_at> (window was <window_minutes>m) ===

Landed during suspend:
  merged PR #N  (<at>)
  <also merged after window: PR #M — merged after window expiry>
  <nothing landed> if empty

Parked (<N> units) — current state:
  PR #M [<current GitHub state>] — stopped at: <stopped_at> · next: <next_move> · waiting on: <waiting_on>
  Subagent <kind> — handoff at <path>
  <nothing parked> if empty

Monitors to re-arm:
  babysit PR #N — will re-arm via /babysit-pr
  PR fleet monitor — will re-arm via /pr-monitor-and-manage-wake
  Day-mode loop — will re-arm via /pm day resume
  <nothing to re-arm> if all monitors_stopped entries have no stopped entry

Refill pause:
  <REFILL_PAUSED=true: "Refilling is paused (full_stop). To resume: tell Claude 'resume refilling' in this session, or /suspend-resume --resume-refill to clear it now.">
  <REFILL_PAUSED=false: "Refilling is not paused.">
```

The parked units show current GitHub state alongside the parking-point snapshot, so the user immediately sees what changed while the session was closed.

## Step 5: Re-arm what was stopped

**Before delegating to any re-arm skill, disarm the usage-limit auto-wake Monitor if one is armed.** This prevents a double resume when the user runs `/suspend-resume` manually while a limit-wake Monitor is still ticking (i.e. the rolling-window park from 2D.6 has not yet fired automatically). When `/suspend-resume` is invoked **by the Monitor itself** (not manually), it carries `--generation <id>`; validate the generation before proceeding to reject stale or duplicate wakes:

```bash
if [[ -n "$SESSION_STATE_SH" && -n "$REPO_KEY" ]]; then
  LIMIT_TASK_RC=0
  LIMIT_TASK_ID=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.limit_resume_task_id" 2>/dev/null) || LIMIT_TASK_RC=$?
  LIMIT_GEN_RC=0
  STORED_GENERATION=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.limit_resume_generation" 2>/dev/null) || LIMIT_GEN_RC=$?

  # If a --generation was passed (Monitor-initiated wake), validate it before proceeding.
  if [[ -n "${CALLER_GENERATION:-}" ]]; then
    if [[ "$LIMIT_GEN_RC" -ne 0 || -z "$STORED_GENERATION" || "$STORED_GENERATION" == "null" ]]; then
      echo "(WARNING: cannot read stored wake generation — generation mismatch cannot be checked; continuing with caution)"
    elif [[ "$CALLER_GENERATION" != "$STORED_GENERATION" ]]; then
      echo "(Stale auto-wake rejected — caller generation '$CALLER_GENERATION' does not match stored '$STORED_GENERATION')"
      # EXIT: this is an old Monitor; do not resume
    fi
  fi

  if [[ "$LIMIT_TASK_RC" -ne 0 && "$LIMIT_TASK_RC" -ne 3 ]]; then
    # Read failure: report degraded state — cannot confirm whether an auto-wake Monitor is armed.
    echo "(DEGRADED: could not read day.limit_resume_task_id (rc=$LIMIT_TASK_RC) — manual check needed; proceeding without disarm)"
  elif [[ "$LIMIT_TASK_RC" -eq 0 && -n "$LIMIT_TASK_ID" && "$LIMIT_TASK_ID" != "null" ]]; then
    # Only act when the field is readable and non-null
    # Stop the auto-wake before we re-arm day mode below; a successful stop clears the fields.
    # On failure: keep the ID visible and continue — a duplicate resume is preferable to a silent orphan.
    if TaskStop "$LIMIT_TASK_ID" 2>/dev/null; then
      "$SESSION_STATE_SH" \
        --set ".repos[\"$REPO_KEY\"].day.limit_resume_task_id=null" \
        --set ".repos[\"$REPO_KEY\"].day.limit_resume_generation=null" || true
      echo "(disarmed usage-limit auto-wake $LIMIT_TASK_ID)"
    else
      echo "(WARNING: could not stop usage-limit auto-wake $LIMIT_TASK_ID — it may fire again and trigger a duplicate resume)"
    fi
  fi
fi
```

For each entry in `monitors_stopped` where `stopped: true`, delegate to the appropriate re-arm skill — never reimplement their logic:

- **Babysit watcher for a PR** — invoke `/babysit-pr <PR>` for each entry with `owner: "babysit"`.
- **PR fleet monitor** — invoke `/pr-monitor-and-manage-wake` for any entry with `owner: "pmm"`. The wake companion reads its own saved config (cadence, author, max-parallel, etc.) and re-arms at base cadence.
- **Day-mode loop** — invoke `/pm day resume` for any entry with `owner: "day"`. This re-arms the persistent Monitor and picks up from where the loop paused. After `/pm day` re-arms, it reads the current `day.parked_until`; if the value is still in the future (the limit window has not yet reopened), it will re-arm the auto-wake instead of the tick Monitor — the disarm above ensures only one wake Monitor runs at a time.
- **Usage-limit auto-wake** — entries with `owner: "day_limit_wake"` are informational only: the disarm block above already handled them. Mark `rearmed: true` regardless so Step 7 counts them as resolved and does not block the `active=false` write.

Entries with `stopped: false` are listed as "not confirmed stopped at suspend time — verify manually before re-arming."

If any re-arm delegation fails, report it and carry on — a partial re-arm is better than stopping entirely. **Record a per-entry `rearmed: true/false` field** in the state so Step 7 can set `active=false` only when all required entries are done, and Step 2 can detect a partially-resumed session and retry:

## Step 6: Clear the refill pause (--resume-refill only)

When `--resume-refill` was supplied:

```bash
if [[ "$RESUME_REFILL" == true && -n "$SESSION_STATE_SH" && -n "$REPO_KEY" ]]; then
  "$SESSION_STATE_SH" \
    --set ".repos[\"$REPO_KEY\"].refill={\"paused\":false,\"reason\":null,\"scope\":null,\"at\":null}" \
    && echo "Refill pause cleared — pipeline will refill on the next tick." \
    || echo "Could not clear the refill pause (session-state.sh --set failed) — lift it manually."
fi
```

Without `--resume-refill`, the pause stands and Step 4 has already stated plainly how to lift it.

## Step 7: Mark the suspend as resumed

Only set `active=false` after **all** required re-arms in Step 5 have been confirmed (`rearmed: true`). If any required re-arm is still pending, keep `active=true` so the next invocation's Step 2 detects the incomplete restore and retries:

```bash
if [[ -n "$SESSION_STATE_SH" && -n "$REPO_KEY" ]]; then
  ALL_REARMED=true
  # Check if any required entry (stopped: true) is still rearmed: false/absent
  PENDING=$(jq -r '.monitors_stopped // [] | map(select(.stopped == true and (.rearmed // false) == false)) | length' <<<"$SUSPEND_STATE" 2>/dev/null || echo "0")
  [[ "$PENDING" -gt 0 ]] && ALL_REARMED=false

  NOW=$(date -u +%FT%TZ)
  if [[ "$ALL_REARMED" == true ]]; then
    "$SESSION_STATE_SH" \
      --set ".repos[\"$REPO_KEY\"].suspend.active=false" \
      --set ".repos[\"$REPO_KEY\"].suspend.resumed_at=\"$NOW\""
  else
    # Keep active=true; update resumed_at to record the attempt
    "$SESSION_STATE_SH" \
      --set ".repos[\"$REPO_KEY\"].suspend.resumed_at=\"$NOW\""
    echo "Partial restore: $PENDING re-arm(s) still pending. Run /suspend-resume again to retry."
  fi
fi
```

The `active=false` write is the idempotent guard from Step 2. The record is kept for history — only `active` and `resumed_at` change, not the arrays of landed, parked, and stopped monitors.

## Safety

- **Never auto-clear the refill pause.** It stays paused until the user supplies `--resume-refill` or explicitly says "resume refilling" in chat. A suspend that auto-cleared the pause on resume would defeat the purpose of pausing in the first place.
- **Re-read GitHub before printing**, not after. The board should reflect current state, not stale parking-point state, because the user is deciding what to work on next.
- **Fail closed on the no-state check.** An unreadable state file and an absent marker produce a clean no-op with a clear message, not an attempt to resume phantom state.
- **Delegation, not reimplementation.** The re-arm steps delegate to the existing companion skills (`/babysit-pr`, `/pr-monitor-and-manage-wake`, `/pm day resume`) rather than reimplementing their logic. Those skills own their own Monitor-arming contracts and generation tracking; reimplementing them here creates a second code path with a high risk of divergence.
