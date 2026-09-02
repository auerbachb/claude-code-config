---
name: pause-resume
description: Resume companion to /pause; `/go-on` is the primary resume entry point and routes here. Explicitly clears the background-launch gate, reads parked and stopped-task recovery state, prints the current board, and re-arms selected work without duplicating live tasks. The refill gate is cleared only with --resume-refill. Triggers on "pause-resume", "resume from pause", "back from laptop", "restore parked work", "what did I park".
triggers:
  - pause-resume
  - resume from pause
  - back from laptop
  - restore parked work
  - what did I park
argument-hint: "[--resume-refill] (--resume-refill clears the refill pause; without it the pause stands and is reported)"
---

Thin restorer for `/pause`. Reads the pause state, prints the board as it is **now** (not as it was parked — it re-reads GitHub before printing), re-arms what was stopped, and reports what is waiting on you.

> **`/go-on` is the primary entry point for resuming.** It classifies the stoppage from recorded evidence and routes here when the newest record is a `/pause`, forwarding `--resume-refill` verbatim — so nobody has to remember which stop happened (Issue #1397; ladder: `.claude/reference/universal-resume.md`). This command keeps working unchanged and stays the direct path when you already know the work was paused; it remains the executor, and `/go-on` never reimplements the restore below.

Running this when no pause state exists is a clean no-op: `No parked session found — nothing to resume.`

## Step 0: Resolve helpers

`/pause-resume` is invocable from any thread — including one whose cwd is a different worktree than the one `/pause` ran in. The three-candidate resolution order is identical to every other stop-style command:

```bash
resolve_script() {
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}
SESSION_STATE_SH=$(resolve_script session-state.sh) || SESSION_STATE_SH=""
EXECUTION_PAUSE_SH=$(resolve_script execution-pause.sh) || EXECUTION_PAUSE_SH=""
TASK_REGISTRY_SH=$(resolve_script background-task-registry.sh) || TASK_REGISTRY_SH=""
```

The current checkout is intentionally not a fallback: this resume command may
run from an unrelated or untrusted repository, and must execute only installed
helpers.

An unresolved `session-state.sh` in this skill is fatal for the state-read path but recoverable: fall back to the marker file in Step 1. Say which path is being used so the user knows.

Parse `--resume-refill` and the internal auto-wake generation token:

```bash
RESUME_REFILL=false
CALLER_GENERATION=""
EXPLICIT_MARKER=""
_NEXT_IS_GENERATION=false
_NEXT_IS_MARKER=false
for arg in $ARGUMENTS; do
  if [[ "$_NEXT_IS_GENERATION" == true ]]; then
    CALLER_GENERATION="$arg"
    _NEXT_IS_GENERATION=false
    continue
  fi
  if [[ "$_NEXT_IS_MARKER" == true ]]; then
    EXPLICIT_MARKER="$arg"
    _NEXT_IS_MARKER=false
    continue
  fi
  case "$arg" in
    --resume-refill) RESUME_REFILL=true ;;
    --generation) _NEXT_IS_GENERATION=true ;;
    --marker) _NEXT_IS_MARKER=true ;;
  esac
done
[[ "$_NEXT_IS_GENERATION" == false ]] || \
  { echo "ERROR: --generation requires a value." >&2; exit 2; }
[[ "$_NEXT_IS_MARKER" == false ]] || \
  { echo "ERROR: --marker requires a value." >&2; exit 2; }
```

Before clearing any gate, validate a Monitor-supplied generation against the
current saved generation. A stale or unreadable generation terminates without
changing state, so an old wake cannot reopen execution or re-arm work:

```bash
if [[ -n "$CALLER_GENERATION" ]]; then
  [[ -n "$SESSION_STATE_SH" ]] || \
    { echo "Cannot validate auto-wake generation; no gate was cleared." >&2; exit 1; }
  REPO_KEY=$("$SESSION_STATE_SH" --repo-key 2>/dev/null) || REPO_KEY=""
  [[ -n "$REPO_KEY" ]] || \
    { echo "Cannot identify the auto-wake repository; no gate was cleared." >&2; exit 1; }
  STORED_GENERATION=$("$SESSION_STATE_SH" \
    --get ".repos[\"$REPO_KEY\"].day.limit_resume_generation" 2>/dev/null) || \
    { echo "Cannot read the saved auto-wake generation; no gate was cleared." >&2; exit 1; }
  if [[ -z "$STORED_GENERATION" || "$STORED_GENERATION" == "null" || \
        "$CALLER_GENERATION" != "$STORED_GENERATION" ]]; then
    echo "Stale auto-wake rejected; no gate was cleared or work re-armed."
    exit 0
  fi
fi
```

## Step 1: Read pause state

Try the state file first; fall back to the newest repo-matching marker if it fails. The marker filename includes the repo key (set by `/pause` Step 7a) — validate it before choosing so a marker from another repo cannot be mistaken for this one's state:

```bash
PAUSE_STATE=""
USE_MARKER=false
MARKER_PATH=""
STATE_KEY="pause"
if [[ -n "$SESSION_STATE_SH" ]]; then
  REPO_KEY=$("$SESSION_STATE_SH" --repo-key 2>/dev/null) || REPO_KEY=""
  if [[ -n "$REPO_KEY" ]]; then
    PAUSE_STATE=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].pause" 2>/dev/null || echo "")
    if [[ -z "$PAUSE_STATE" || "$PAUSE_STATE" == "null" ]]; then
      PAUSE_STATE=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].suspend" 2>/dev/null || echo "")
      if [[ -n "$PAUSE_STATE" && "$PAUSE_STATE" != "null" ]]; then
        STATE_KEY="suspend"
        echo "(using legacy pre-Issue-1310 suspend state; new pauses use .pause)"
      fi
    fi
  fi
fi

# Fall back to the newest marker file if state was not readable.
# Validate the repo key embedded in the filename before using a candidate.
if [[ -z "$PAUSE_STATE" || "$PAUSE_STATE" == "null" ]]; then
  if [[ -n "$EXPLICIT_MARKER" ]]; then
    [[ -r "$EXPLICIT_MARKER" ]] || \
      { echo "Explicit pause marker is unreadable: $EXPLICIT_MARKER" >&2; exit 1; }
    case "$(basename "$EXPLICIT_MARKER")" in
      pause-*.md) STATE_KEY="pause" ;;
      suspend-*.md) STATE_KEY="suspend" ;;
      *) echo "Explicit marker is not a pause/suspend recovery artifact." >&2; exit 1 ;;
    esac
    MARKER_REPO=$(sed -n 's/^Repository: `\([^`]*\)`$/\1/p' "$EXPLICIT_MARKER" | head -1)
    if [[ -n "$MARKER_REPO" && "$MARKER_REPO" != "_unknown" && \
          -n "${REPO_KEY:-}" && "$MARKER_REPO" != "$REPO_KEY" ]]; then
      echo "Explicit marker belongs to $MARKER_REPO, not $REPO_KEY." >&2
      exit 1
    fi
    MARKER_PATH="$EXPLICIT_MARKER"
  fi
  if [[ -z "$MARKER_PATH" && -z "${REPO_KEY:-}" ]]; then
    # Without a repo key we cannot safely distinguish our own markers from
    # another repo's — the pattern *--* would match anything. Fail closed.
    echo "No parked session found — nothing to resume."
    exit 0
  fi
  if [[ -z "$MARKER_PATH" ]]; then
    REPO_OWNER="${REPO_KEY%%/*}"
    REPO_NAME="${REPO_KEY#*/}"
    REPO_KEY_SAFE="${#REPO_OWNER}-${REPO_OWNER}-${#REPO_NAME}-${REPO_NAME}"
    LEGACY_REPO_KEY_SAFE="${REPO_KEY//\//-}"
    # New pause markers use an injective filename key and also carry the exact
    # owner/repo in their content. Legacy suspend markers use the old key.
    while IFS= read -r candidate; do
      MARKER_NAME="$(basename "$candidate")"
      MARKER_REPO=$(sed -n 's/^Repository: `\([^`]*\)`$/\1/p' "$candidate" 2>/dev/null | head -1)
      if [[ "$MARKER_NAME" == pause-*"-${REPO_KEY_SAFE}-"* && \
            "$MARKER_REPO" == "$REPO_KEY" ]]; then
        MARKER_PATH="$candidate"
        break
      elif [[ "$MARKER_NAME" == suspend-*"-${LEGACY_REPO_KEY_SAFE}-"* ]]; then
        # Compatibility-only path for markers written before Issue #1310.
        MARKER_PATH="$candidate"
        STATE_KEY="suspend"
        break
      fi
    done < <(ls -t "$HOME/.claude/handoffs/pause-"*.md \
      "$HOME/.claude/handoffs/suspend-"*.md 2>/dev/null)
  fi

  if [[ -n "$MARKER_PATH" ]]; then
    echo "(reading from marker file — session-state.json was not readable; using $MARKER_PATH)"
    USE_MARKER=true
    # Parse key fields from the human-readable marker. The marker's sections
    # mirror the pause state block; extract what is available.
    PAUSE_STATE=$(awk '
      /^##? Landed/        { in_landed=1; in_parked=0; in_monitors=0 }
      /^##? Parked/        { in_parked=1; in_landed=0; in_monitors=0 }
      /^##? Monitors/      { in_monitors=1; in_landed=0; in_parked=0 }
      /^##/                { in_landed=0; in_parked=0; in_monitors=0 }
      { print }
    ' "$MARKER_PATH")
    # The marker is human-readable prose; later steps read it directly via
    # $MARKER_PATH rather than parsing $PAUSE_STATE as JSON.
  fi
fi

# If neither source has state, this is a clean no-op
if [[ -z "$PAUSE_STATE" && "$USE_MARKER" == false ]]; then
  echo "No parked session found — nothing to resume."
  exit 0
fi
```

**Reading from `session-state.json` is the primary path.** When that path is available, all later steps can use `jq` to parse `$PAUSE_STATE` as JSON. When the marker fallback is active (`USE_MARKER=true`), later steps read the marker file directly from `$MARKER_PATH` — they cannot assume `$PAUSE_STATE` is valid JSON, and should extract what they can from the human-readable sections.

**The `pause` block is invisible to `--session-view`** (that projection lifts only `.prs` and `.root_repo`). Always read it with an explicit `--get .repos["<key>"].pause` — never via `--session-view`.

The legacy `.suspend` read and `suspend-*.md` glob above are compatibility
inputs only. They preserve resumability for sessions parked before Issue #1310;
new `/pause` runs never write those names. `STATE_KEY` remembers which JSON
record was loaded so Step 7 closes that same record safely.

New marker auto-discovery requires the exact `Repository: \`owner/repo\`` field;
the injective filename match is an index, not repository-identity authority.
An `_unknown` marker is resumable only through the explicit `--marker` path
printed by `/pause`.

## Step 2: Check if already resumed

For a JSON state read, check the `active` flag. For a marker-only read, the marker's existence implies an incomplete restore (a fully-resumed session writes `active: false` in the state file, which masks the state before this step runs):

```bash
if [[ "$USE_MARKER" == false ]]; then
  ACTIVE=$(jq -r '.active // true' <<<"$PAUSE_STATE" 2>/dev/null || echo "true")
  if [[ "$ACTIVE" == "false" ]]; then
    # Check whether any re-arms were incomplete (added in Step 7)
    if ! PENDING_REARMS=$(jq -er '
      ((.monitors_stopped // [])
        | map(select((.rearmed // false) != true))
        | length)
      + ((.background_tasks_stopped // [])
        | map(select((.rearmed // false) != true))
        | length)
    ' <<<"$PAUSE_STATE" 2>/dev/null); then
      echo "Pause recovery state is unreadable; keeping the session active." >&2
      PENDING_REARMS=-1
    fi
    if [[ "$PENDING_REARMS" -lt 0 ]]; then
      exit 1
    fi
    if [[ "$PENDING_REARMS" -gt 0 ]]; then
      echo "Pause session was partially resumed ($PENDING_REARMS re-arm(s) still pending). Continuing restore..."
    else
      echo "Pause state exists but is already marked resumed (active: false). Run /pause again to park a new session."
      exit 0
    fi
  fi
fi
```

Idempotent on a fully-resumed session. On a partially-resumed session (some re-arms failed), the step continues so Step 5 can retry the incomplete entries.

## Step 3: Re-read GitHub for each parked PR

Before printing the board, re-read GitHub for each PR listed in `.pause.parked`. A state that moved since pause (a review that landed, a merge that completed after the `/wrap` window, CI that finished) is reported as it is **now**, not as it was parked.

For each parked PR, run `gh pr view <N> --json state,mergeStateStatus,mergeable,reviewDecision` and update the parked entry's display. A PR whose `state: MERGED` is reported as landed (with a note that it merged after the window) rather than parked. A PR whose CI finished running is reported with its updated status.

This re-read is display-only: it does not change the persisted `pause` block. The block is a historical record of the parking point.

## Step 4: Print the board

For JSON state, render the timestamp as
`jq -r '.paused_at // .suspended_at // "unknown"'`. The second field is the
legacy pre-Issue-1310 spelling; never print an empty timestamp merely because
the parked session predates the rename.

```
=== Resuming from pause at <paused_at> (window was <window_minutes>m) ===

Landed during pause:
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
  <REFILL_PAUSED=true: "Refilling is paused (full_stop). To resume: tell Claude 'resume refilling' in this session, or /pause-resume --resume-refill to clear it now.">
  <REFILL_PAUSED=false: "Refilling is not paused.">
```

The parked units show current GitHub state alongside the parking-point snapshot, so the user immediately sees what changed while the session was closed.

## Step 4b: Open the execution gate for recovery

Only after Step 1 found state and Step 2 confirmed recovery is still active,
clear the session execution gate. This ordering keeps a missing or already
resumed pause as a clean no-op that does not mutate the gate. Clear before any
Monitor, Agent, Workflow, or background Bash is re-armed; if clearing fails,
stop without re-arming anything:

```bash
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
if [[ -z "$EXECUTION_PAUSE_SH" ]] || \
   ! "$EXECUTION_PAUSE_SH" --clear --session "$SESSION_ID"; then
  echo "Could not clear the pause execution gate; no work was re-armed." >&2
  exit 1
fi
```

## Step 5: Re-arm what was stopped

First inspect current-session stopped registry entries. Re-check runtime state
before every re-arm so an already-running identity is never duplicated. Resume
stopped agents by their exact runtime ID with `SendMessage`; for workflows,
background commands, and Monitors use the recorded recovery path and owning
skill, then mark the old entry `rearmed`. A missing recovery path is reported
as pending, not guessed. Preserve the stopped entry for audit history.

**Before delegating to any re-arm skill, disarm the usage-limit auto-wake Monitor if one is armed.** This prevents a double resume when the user runs `/pause-resume` manually while a limit-wake Monitor is still ticking (i.e. the rolling-window park from 2D.6 has not yet fired automatically). **One registry covers both wake shapes:** 2D.7's bounded probe Monitor (#1428) records its identity in these same fields, so the block below stops it too — clearing `limit_probe_fires_remaining` with the pair is what stops a later recovery re-arming a probe for a park the user has already resumed past. When `/pause-resume` is invoked **by the Monitor itself** (not manually), it carries `--generation <id>`; validate the generation before proceeding to reject stale or duplicate wakes:

```bash
LIMIT_WAKE_RESOLVED=false
if [[ -n "$SESSION_STATE_SH" && -n "$REPO_KEY" ]]; then
  LIMIT_TASK_RC=0
  LIMIT_TASK_ID=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.limit_resume_task_id" 2>/dev/null) || LIMIT_TASK_RC=$?
  if [[ "$LIMIT_TASK_RC" -ne 0 && "$LIMIT_TASK_RC" -ne 3 ]]; then
    # Read failure: report degraded state — cannot confirm whether an auto-wake Monitor is armed.
    echo "(DEGRADED: could not read day.limit_resume_task_id (rc=$LIMIT_TASK_RC) — recovery remains active)"
  elif [[ "$LIMIT_TASK_RC" -eq 0 && -n "$LIMIT_TASK_ID" && "$LIMIT_TASK_ID" != "null" ]]; then
    # Only act when the field is readable and non-null
    # Stop the auto-wake before we re-arm day mode below; a successful stop clears the fields.
    if TaskStop "$LIMIT_TASK_ID" 2>/dev/null; then
      if "$SESSION_STATE_SH" \
        --set ".repos[\"$REPO_KEY\"].day.limit_resume_task_id=null" \
        --set ".repos[\"$REPO_KEY\"].day.limit_resume_generation=null" \
        --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=null"; then
        LIMIT_WAKE_RESOLVED=true
        echo "(disarmed usage-limit auto-wake $LIMIT_TASK_ID)"
      else
        echo "(DEGRADED: auto-wake stopped but its state could not be cleared — recovery remains active)"
      fi
    else
      echo "(WARNING: could not stop usage-limit auto-wake $LIMIT_TASK_ID — recovery remains active)"
    fi
  else
    # Missing/null means there is no armed auto-wake to disarm.
    LIMIT_WAKE_RESOLVED=true
  fi
fi
```

**Handle the leave-time wind-down too (issue #1525) — but read before you touch anything.**

**Gate first: `leave.active` must be `true`.** The window is **shared state**: `/pm --window` arms
the same `.repos["<key>"].window` with no `.leave` block at all, and that case is indistinguishable
downstream from "nothing armed". `leave.active != true` (false, null, absent, or unreadable) →
**skip this entire block**: stop nothing, re-arm nothing, leave `.window` exactly as found, and
settle no entry. Without the gate here — ahead of every branch below, not after them — an ordinary
coffee-break `/pause` → `/pause-resume` on a PM planning board would arm a phantom `/leave-by`
check-in and later `/pause` a board that never declared a leave time.

**Then read and validate the deadline, still before stopping anything.** Read
`.repos["$REPO_KEY"].window.deadline_epoch` (the leave block never carries it — `/leave-by` Step 5)
with Step 11's exit-code table and numeric test, **binding it** so the retirement CAS below can pin
its write to the exact value the spent-verdict was reached on:

```bash
RESUMED_DEADLINE_EPOCH=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].window.deadline_epoch" 2>/dev/null) \
  || RESUMED_DEADLINE_RC=$?
# Separately, the WHOLE window object — that is what the retirement CAS below compares against,
# because --expect is matched at the --cas path and that path is `.window`, not a scalar under it.
RESUMED_WINDOW=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].window" 2>/dev/null) \
  || RESUMED_WINDOW=""
```
 Validating *after* the `TaskStop` is what strands a
declaration: the stop clears the identity pair, the deadline then reads unreadable, and the
inconsistent-record branch preserves `leave.active` while re-arming nothing — an active leave time
with no Monitor and no task ID left to recover it. Read first, and the stop only ever runs on a
branch that knows what it will do next.

**An unreadable or malformed deadline stops here — before the disarm, not after it.** Reading early
is not enough on its own: if the validation fails and the disarm runs anyway, the identity pair is
gone and the inconsistent-record branch below then preserves `leave.active` while re-arming
nothing — an active leave time with no Monitor and no task ID, which is precisely the state that
branch exists to avoid creating. So on any non-numeric, `null`, or unreadable deadline with
`leave.active == true`: report the one-line inconsistent-record verdict, **leave
`winddown_task_id` and `winddown_generation` exactly as found**, stop nothing, and skip the rest of
this block. The live wake stays live and nameable, and `/leave-by` Step 11 can still recover it.

With the gate passed and the deadline read **and validated**, disarm: same shape as the block above,
over `.repos["$REPO_KEY"].leave.winddown_task_id` — read it with its exit code (unreadable → one
`DEGRADED:` line, recovery stays active; null or exit 3 → nothing armed, resolved), **binding the
value** so the release CAS below can name exactly the ID this step was holding:

```bash
OLD_WINDDOWN_TASK_ID=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].leave.winddown_task_id" 2>/dev/null) \
  || OLD_WINDDOWN_TASK_RC=$?
```

Then
**invalidate the generation before stopping the task** — the order `/leave-by` Step 9 mandates and
`/pause` Step 2 repeats, for the same reason: a `TaskStop` cannot retract a `--checkin` the Monitor
has already emitted, and a queued one still passes Step 8.1 here, starting a `/pause` inside a
restore that is still running — the very nesting the re-arm branch below refuses to do inline.
Nulling the token first makes every queued event inert whatever the stop then does:

```bash
INVALIDATE_RC=0
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].leave.winddown_generation=null" || INVALIDATE_RC=$?
# retry once on 6 (lock timeout)
```

**Read that exit code, and fail closed — the same contract as `/leave-by` Step 9.** The null
precedes the `TaskStop` only because a queued `--checkin` stays valid until the token is gone, so a
failed write leaves that window open. Stopping the task and continuing anyway would let a queued
event pass Step 8.1 and start a `/pause` inside a restore that is still running — the exact nesting
this ordering exists to prevent. On a non-zero `INVALIDATE_RC` after the retry: stop nothing, clear
nothing, re-arm nothing; report it in one line naming the task ID, and leave `.leave` as found for
`/leave-by` Step 11.

Only then `TaskStop` a non-null ID, and on a confirmed stop clear the ID it was holding:

```bash
"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].leave.winddown_task_id=null"
```

**On an unconfirmed stop, release the slot anyway — under a CAS, and without claiming the stop.**
The generation is already null, so that Monitor's every event is inert; what the dead ID does still
do is **squat the slot** the re-arm below must win with `--expect null`. Left there, Step 6's CAS
returns `7`, and its exit-7 bullet — written for a *live successor* owning `.leave` — then
`TaskStop`s the Monitor this step just created and leaves the leave time silently un-armed: the old
wake inert, the new one stopped, the check-in never firing (issue #1525). Release exactly what you
hold, never a slot someone else has taken since:

```bash
"$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].leave.winddown_task_id=null" \
  --expect "$OLD_WINDDOWN_TASK_ID"   # exit 7 = already replaced, nothing to do
```

This releases the slot without asserting the Monitor stopped: **still report the un-stopped task ID**
so a human can end it, and still leave its `monitors_stopped` entry `stopped: false`. Releasing the
slot and claiming the stop are different claims, and only the first is true here.

**Where the un-stopped ID lives after this.** Releasing the slot empties
`leave.winddown_task_id`, so that field is no longer the record of an un-stopped Monitor and no
later branch may claim it is. The durable copy is the `owner: "leave_winddown"` entry in
`monitors_stopped`, which carries the ID alongside `stopped: false` and outlives this step; the
in-memory copy is `OLD_WINDDOWN_TASK_ID`, which is what the report prints. Both branches below that
mention an un-stopped ID mean **those** two, never the released slot.

**Then branch on the deadline, not on the pause** — using the value already read and validated
above:

- **Deadline still in the future** → the leave time **still applies**, and this resume is an
  ordinary mid-afternoon return, not a withdrawal. Keep `leave.active=true`, keep `.window`, and
  **re-arm the wind-down** for the remaining time with a **fresh generation**, publishing the new
  identity pair exactly as `/leave-by` Step 6 does. **Branch on `checkin_epoch` the way Step 11's
  table does, rather than re-arming blindly:** a check-in that already fired leaves `checkin_epoch`
  in the past, and arming a Monitor for a past instant clamps the sleep to one second and winds the
  board down again seconds after the user asked for it back. `checkin_epoch` in the future → re-arm
  for the remaining time. `checkin_epoch` past with the deadline still ahead → the check-in is
  **overdue**, and it is delivered the same way every other check-in is: arm the Monitor with a
  **fresh published generation** and let its sleep clamp to one second, so the check-in arrives as
  its own event once this resume has returned. **Never invoke Step 8 inline from here.** Two
  distinct failures come of that: it nests a `/pause` inside the restore that is still running, and
  Step 8.1 would validate against the generation this step just nulled and exit silently — losing
  the wind-down at the exact moment it was due. The armed-event route has neither problem, because
  Step 6 publishes the generation before arming. Say it in one line:
  `leave time still armed: until 7:00 PM ET · check-in at 6:30 PM ET`. Clearing here instead would
  mean a coffee-break `/pause` at 4 PM silently cancels the 7 PM wind-down the user asked for once
  and never hears about again — the exact promise this feature exists to keep.
- **Deadline confirmed in the past** → the leave time is spent. Retire it per the branches below;
  do not re-arm. Resuming *past* a declared leave time is the user saying it no longer applies, and
  re-arming then would park the board again minutes after they asked for it back.
- **Deadline absent, non-numeric, or unreadable, with `leave.active == true`** → an **inconsistent
  record**, not an expired one — the same verdict `/leave-by` Step 11 reaches on the same evidence.
  Report it in one line, preserve `leave.active` **and** the shared `.window` exactly as found, and
  neither re-arm nor retire. Retiring here would destroy a live deadline on the strength of a lock
  timeout, and the two files must not disagree about what a half-readable record means.

**`leave.active=false` is written on both resolved paths, not only after a `TaskStop`.** The
already-null path is the *normal* one — `/pause` Step 2 stopped the wind-down and nulled the pair
before this ever runs — so clearing only after a stop this step performed would leave the common
case at `active: true` with no Monitor behind it, and `/leave-by` Step 11's recovery would re-arm
the wind-down on the next session start: a leave time the user explicitly resumed past, resurrected
by the resume itself. So:

The `leave.active` gate that admitted this block at all is stated once, at the top — it governs
every branch here, the future-deadline re-arm included, and is not re-derived per branch. Its
load-bearing consequence for *this* path: clearing the window on a null task ID alone would wipe a
PM planning deadline that no leave time ever touched, on every ordinary `/pause` → `/pause-resume`
cycle.

With the gate passed **and the deadline spent**:

- **Null / exit 3 (nothing armed), or a confirmed `TaskStop`** → set
  `leave.active=false` with the (already or newly) null pair **and** clear the armed deadline
  (`.repos["$REPO_KEY"].window=null`) — the latter **under a CAS on the deadline this step read and
  validated**, never blind:

  ```bash
  "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].leave.active=false"
  "$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].window=null" \
    --expect "$RESUMED_WINDOW" >/dev/null 2>&1 || :   # exit 7 = another writer owns .window
  ```

  `.window` is shared with `/pm` planning deadlines, and this block only ever established that the
  *leave* record is spent. Between the read at the top of this block and the write here, a
  re-declaration or a planning deadline can take the slot; a blind `--set` would then clear a live
  deadline this resume never examined — the same hazard the gate note above raises for the
  null-task-ID path, one step further along. The CAS pins the write to the exact
  `deadline_epoch` the spent-verdict was reached on, and its exit `7` means the window moved on and
  is no longer this step's to clear. Clearing the window is the load-bearing half: a spent
  `deadline_epoch` left behind sits in the past forever, so `/subagent` Step 7's gate would decline
  every pipeline in this repo from here on — the resume would reopen the launch gates and then
  refuse all work through a different one. Mark the `owner: "leave_winddown"` entry in
  `monitors_stopped` `rearmed: true` — for this owner "resolved" means disarmed, not restarted —
  and say it in one line: `leave time cleared — re-declare with /leave-by if it still applies`.
- **An unconfirmed `TaskStop`** → the deadline is still **spent**, so retire it exactly as above —
  `leave.active=false` **and** `.repos["$REPO_KEY"].window=null` — leave the entry `rearmed: false`
  and `stopped: false`, and name the un-stopped ID from `OLD_WINDDOWN_TASK_ID` and the
  `monitors_stopped` entry in the report. **Do not look for it in `leave.winddown_task_id`:** the
  release CAS above already emptied that slot, so treating the field as the surviving record would
  report an un-stopped Monitor as stopped.
  A stop that was not confirmed says nothing about whether the deadline passed, and the two must not
  be conflated: holding `.window` open here re-creates the precise failure the bullet above exists
  to prevent — a past `deadline_epoch` sitting in the past forever while `/subagent` Step 7 declines
  every pipeline in this repo, from a resume that had just reopened the launch gates (issue #1525).
  The Monitor is inert either way (its generation was nulled above), so nothing is left to fire.
  Never claim a Monitor stopped when the stop was not confirmed — retaining and naming the ID is how
  that promise is kept, not by leaving a spent deadline armed.
- **Unreadable** → keep `active=true`, the ID, and `.window` exactly as found, leave the entry
  `rearmed: false`, and report it. Here the deadline genuinely is not known to be spent, so there is
  nothing to retire and no cleared line to print.

For each entry in `monitors_stopped` where `stopped: true` and `rearmed` is not
already `true`, delegate to the appropriate re-arm skill — never reimplement
their logic. Skip entries already confirmed rearmed so retries are idempotent.
Before runtime inspection or delegation, atomically claim the exact task ID in
the shared registry, using the same reservation as `/end-resume`:

```bash
"$TASK_REGISTRY_SH" --transition --session "$SESSION_ID" \
  --task-id "$TASK_ID" --status rearming --from-status stopped
```

Exit 7 means another `/pause-resume` invocation already claimed or completed
the entry; re-read it and do not launch. A missing registry record or task ID
keeps the pause entry pending rather than falling back to an unlocked launch.
After the claim, re-check the execution gate immediately before delegation. A
blocked or failed launch rolls `rearming -> stopped`; a confirmed successor
rolls `rearming -> rearmed`, then (and only then) sets the pause array entry's
`rearmed: true`. The successor registers its own runtime ID through the normal
launch hook. This ordering makes concurrent invocations single-writer even
before either one persists the pause-state array:

- **Babysit watcher for a PR** — invoke `/babysit-pr <PR>` for each entry with `owner: "babysit"`.
- **PR fleet monitor** — invoke `/pr-monitor-and-manage-wake` for any entry with `owner: "pmm"`. The wake companion reads its own saved config (cadence, author, max-parallel, etc.) and re-arms at base cadence.
- **Day-mode loop** — invoke `/pm day resume` for any entry with `owner: "day"`. This re-arms the persistent Monitor and picks up from where the loop paused. After `/pm day` re-arms, it reads the current `day.parked_until`; if the value is still in the future (the limit window has not yet reopened), it will re-arm the auto-wake instead of the tick Monitor — the disarm above ensures only one wake Monitor runs at a time.
- **Usage-limit auto-wake** — entries with `owner: "day_limit_wake"` are
  handled by the disarm block above. Set `rearmed: true` only when
  `LIMIT_WAKE_RESOLVED=true`; otherwise preserve `rearmed: false` and record
  the read, stop, or state-clear error. Never close recovery around an
  unconfirmed disarm.
- **Leave-time wind-down** — entries with `owner: "leave_winddown"` are settled by
  the leave block above, which branches on the **deadline**, not on the pause
  (issue #1525): a deadline still in the future is re-armed with a fresh
  generation and keeps the leave time live; a spent one is disarmed and retired,
  never re-armed, since resuming past a declared leave time is the user
  withdrawing it. Set `rearmed: true` only when the re-arm was published or the
  clear succeeded, and report an unconfirmed disarm exactly as the row above does.

Entries with `stopped: false` are listed as "not confirmed stopped at pause time — verify manually before re-arming."

If any re-arm delegation fails, report it and carry on — a partial re-arm is better than stopping entirely. **Record a per-entry `rearmed: true/false` field** in the state so Step 7 can set `active=false` only when all required entries are done, and Step 2 can detect a partially-resumed session and retry:

Apply the same filter and bookkeeping to `background_tasks_stopped`, keyed by
exact `task_id`: skip `rearmed: true` entries and process only entries still
requiring restoration. Use the same locked `stopped -> rearming` registry claim
before inspection or launch and the same rollback/finalize transitions. Set
`rearmed: true` only after runtime verification. Set or preserve
`rearmed: false` when recovery failed or required metadata is missing, and add
`resume_error` naming the missing path/action. Persist both updated arrays with
`session-state.sh --set`; never mutate the state file directly.

After those writes succeed, set
`STATE_PATH=".repos[\"$REPO_KEY\"].$STATE_KEY"` and re-read that exact block
into `PAUSE_STATE`. This matters for a legacy restore: reading `.pause` after
updating `.suspend` would evaluate stale or absent arrays. A failed refresh is
a partial restore: keep `active=true`, report the read failure, and do not run
Step 7's completion write. Step 7 must evaluate the freshly persisted arrays,
never the pre-rearm snapshot captured at command start.

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

## Step 7: Mark the pause as resumed

Only set `active=false` after **all** required re-arms in Step 5 have been confirmed (`rearmed: true`). If any required re-arm is still pending, keep `active=true` so the next invocation's Step 2 detects the incomplete restore and retries:

```bash
if [[ -n "$SESSION_STATE_SH" && -n "$REPO_KEY" ]]; then
  STATE_PATH=".repos[\"$REPO_KEY\"].$STATE_KEY"
  ALL_REARMED=true
  # Check both specialized Monitors and the general stopped-task inventory.
  # An entry with missing recovery metadata remains pending by design.
  PENDING=-1
  if PENDING_RESULT=$(jq -er '
    ((.monitors_stopped // [])
      | map(select((.rearmed // false) != true))
      | length)
    + ((.background_tasks_stopped // [])
      | map(select((.rearmed // false) != true))
      | length)
  ' <<<"$PAUSE_STATE" 2>/dev/null); then
    PENDING="$PENDING_RESULT"
  else
    echo "Recovery state is unreadable; keeping pause active." >&2
  fi
  [[ "$PENDING" -ne 0 ]] && ALL_REARMED=false

  NOW=$(date -u +%FT%TZ)
  if [[ "$ALL_REARMED" == true ]]; then
    "$SESSION_STATE_SH" \
      --set "$STATE_PATH.active=false" \
      --set "$STATE_PATH.resumed_at=\"$NOW\""
  else
    # Keep active=true; update resumed_at to record the attempt
    "$SESSION_STATE_SH" \
      --set "$STATE_PATH.resumed_at=\"$NOW\""
    if [[ "$PENDING" -lt 0 ]]; then
      echo "Partial restore: recovery state could not be verified. Run /pause-resume again to retry."
    else
      echo "Partial restore: $PENDING re-arm(s) still pending. Run /pause-resume again to retry."
    fi
  fi
fi
```

The `active=false` write is the idempotent guard from Step 2. The record is kept for history; landed and parked history remains, while both stopped arrays retain their per-entry recovery result.

## Safety

- **Never auto-clear the refill pause.** It stays paused until the user supplies `--resume-refill` or explicitly says "resume refilling" in chat. A pause that auto-cleared the pause on resume would defeat the purpose of pausing in the first place.
- **Re-read GitHub before printing**, not after. The board should reflect current state, not stale parking-point state, because the user is deciding what to work on next.
- **Fail closed on the no-state check.** An unreadable state file and an absent marker produce a clean no-op with a clear message, not an attempt to resume phantom state.
- **Delegation, not reimplementation.** The re-arm steps delegate to the existing companion skills (`/babysit-pr`, `/pr-monitor-and-manage-wake`, `/pm day resume`) rather than reimplementing their logic. Those skills own their own Monitor-arming contracts and generation tracking; reimplementing them here creates a second code path with a high risk of divergence.
