---
name: end-resume
description: Resume work stopped by /end; `/go-on` is the primary resume entry point and routes here. Explicitly clears the current session's background-launch gate, reports preserved stopped tasks, and resumes selected recoverable work without duplicating live tasks. The refill gate stays paused unless --resume-refill is supplied. Triggers on "end-resume", "resume from end", "continue ended work", "resume ended work".
triggers:
  - end-resume
  - resume from end
  - continue ended work
  - resume ended work
argument-hint: "[--resume-refill] (--resume-refill also reopens pipeline refilling)"
---

Resume a cost-quiescent `/end` explicitly. This is the only normal path that
reopens the session-scoped launch gate; unrelated messages and timers do not.

> **`/go-on` is the primary entry point for resuming.** It classifies the
> stoppage from recorded evidence and routes here when the newest record is an
> `/end`, forwarding `--resume-refill` verbatim — so nobody has to remember which
> stop happened (Issue #1397; ladder:
> `.claude/reference/universal-resume.md`). This command keeps working unchanged
> and stays the direct path when you already know the session was ended; it
> remains the executor, and a routed invocation is still an explicit human
> invocation of it. Portable handoff documents keep naming `/end-resume` alone in
> their `Resume command:` field — that field is lint-restricted to this command
> because its reader may be outside this harness entirely.

## Step 0: Resolve state helpers

Resolve `execution-pause.sh`, `background-task-registry.sh`, and
`session-state.sh` using the standard stop-command order: skills worktree,
then `$HOME/.claude`. Do not execute a current-checkout fallback: this command
may be invoked from an unrelated or untrusted repository. Parse only
`--resume-refill`. Resolve `lib/legacy-stop-binding.py` from the same installed
scripts locations as `LEGACY_STOP_BINDING_SH`. Resolve `RESUME_REPO` with
`session-state.sh --repo-key` and stop on an unresolved repo. Set
`RESUME_REPO_ARGS=(--repo "$RESUME_REPO")`.

Bind the same session ID `/end` uses. A native conversation UUID takes
precedence; only an older runtime without one uses the legacy key.

<!-- test-anchor: end-resume-native-session -->

```bash
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
NATIVE_SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
if [[ "$NATIVE_SESSION_ID" =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]; then
  SESSION_ID="$NATIVE_SESSION_ID"
fi
```

Bash calls do not share shell variables. In each later call rebind `SESSION_ID`
and `RESUME_REPO` and compare them and the raw legacy key with the verified selection. Carry the
selected `STOP_SESSION_ID` and any `LEGACY_GATE_TOKEN` unchanged. Use
`STOP_SESSION_ID` for the old gate, task inventory and task transitions.
The successor uses the native runtime `SESSION_ID`. Always pass the verified
repo and a nonempty session to registry and gate operations.

Before inventory or any write, check the raw legacy key when it differs from
the native UUID. An active legacy gate is eligible only when the installed
verifier correlates one successful literal activation in the selected native
transcript with the same repo and gate. Ambiguous or unreadable evidence leaves
both gates and all tasks untouched. Recover from the original session context
if independent evidence is unavailable.

<!-- test-anchor: end-resume-other-gate -->

```bash
: "${SESSION_ID:?bind the verified resume session in this shell}"
LEGACY_GATE_SESSION_ID="${CLAUDE_SESSION_ID:-default}"
STOP_SESSION_ID="$SESSION_ID"
LEGACY_GATE_TOKEN=''
LEGACY_ALREADY_CLEARED=0
if [[ "$SESSION_ID" != "$LEGACY_GATE_SESSION_ID" ]]; then
  OTHER_GATE_STATUS=$("$EXECUTION_PAUSE_SH" ${RESUME_REPO_ARGS[@]+"${RESUME_REPO_ARGS[@]}"} \
    --status --session "$LEGACY_GATE_SESSION_ID" 2>/dev/null) || OTHER_GATE_STATUS=unreadable
  if [[ -n "${LEGACY_STOP_BINDING_SH:-}" && -n "${RESUME_REPO:-}" ]]; then
    if [[ "$OTHER_GATE_STATUS" == active ]]; then
      LEGACY_PROOF=$("$LEGACY_STOP_BINDING_SH" --repo "$RESUME_REPO" \
        --native-session "$SESSION_ID" --legacy-session "$LEGACY_GATE_SESSION_ID") || LEGACY_PROOF=''
      if [[ -n "$LEGACY_PROOF" ]]; then
        LEGACY_GATE_TOKEN=$(jq -er --arg repo "$RESUME_REPO" --arg native "$SESSION_ID" \
          --arg old "$LEGACY_GATE_SESSION_ID" '
          select(.verdict == "verified" and .repo == $repo and .native_session == $native
                 and .legacy_session == $old) | .gate_token | select(test("^[a-f0-9]{64}$"))
        ' <<< "$LEGACY_PROOF") || LEGACY_GATE_TOKEN=''
      fi
      if [[ -n "$LEGACY_GATE_TOKEN" ]]; then
        NATIVE_GATE_STATUS=$("$EXECUTION_PAUSE_SH" --repo "$RESUME_REPO" \
          --status --session "$SESSION_ID") || NATIVE_GATE_STATUS=unreadable
        if [[ "$NATIVE_GATE_STATUS" == inactive ]]; then
          STOP_SESSION_ID="$LEGACY_GATE_SESSION_ID"
        fi
      fi
    elif [[ "$OTHER_GATE_STATUS" == inactive ]]; then
      RESUME_SCOPE_RC=0
      RESUME_SCOPE=$("$EXECUTION_PAUSE_SH" --repo "$RESUME_REPO" --legacy-resume-scope \
        --session "$LEGACY_GATE_SESSION_ID" --native-session "$SESSION_ID") || RESUME_SCOPE_RC=$?
      if [[ "$RESUME_SCOPE_RC" -eq 0 && "$RESUME_SCOPE" == "$LEGACY_GATE_SESSION_ID" ]]; then
        STOP_SESSION_ID="$LEGACY_GATE_SESSION_ID"
        LEGACY_ALREADY_CLEARED=1
      elif [[ "$RESUME_SCOPE_RC" -ne 3 ]]; then
        OTHER_GATE_STATUS=unreadable
      fi
    fi
  fi
  if [[ "$OTHER_GATE_STATUS" != inactive && "$STOP_SESSION_ID" == "$SESSION_ID" ]]; then
    echo 'BLOCKED: an alternate legacy gate is active or unreadable. No gate was cleared; verify the original stopped session before resuming.' >&2
    exit 1
  fi
fi
```

Then list tasks with
`background-task-registry.sh --repo "$RESUME_REPO" --list --session "$STOP_SESSION_ID"`
and read the refill state. If either read is unavailable or malformed, report
the hold and leave the execution gate closed.

## Step 1: Clear the execution gate

A first legacy resume clears the exact verified gate under the existing state
lock. If the native gate or legacy snapshot changed, stop before any refill
or task write. An interrupted legacy resume can continue from the exact
receipt without clearing a gate again. The native path uses `execution-pause.sh --clear`.

<!-- test-anchor: end-resume-clear-selected -->

```bash
: "${STOP_SESSION_ID:?missing stop scope}" "${SESSION_ID:?missing runtime scope}" "${RESUME_REPO:?missing repo}"
if [[ "$STOP_SESSION_ID" == "$SESSION_ID" ]]; then
  "$EXECUTION_PAUSE_SH" --repo "$RESUME_REPO" --clear --session "$STOP_SESSION_ID"
elif [[ "${LEGACY_ALREADY_CLEARED:-0}" -eq 1 ]]; then
  RESUME_SCOPE=$("$EXECUTION_PAUSE_SH" --repo "$RESUME_REPO" --legacy-resume-scope \
    --session "$STOP_SESSION_ID" --native-session "$SESSION_ID") || exit $?
  [[ "$RESUME_SCOPE" == "$STOP_SESSION_ID" ]]
else
  "$EXECUTION_PAUSE_SH" --repo "$RESUME_REPO" --clear --session "$STOP_SESSION_ID" \
    --expect-legacy-token "${LEGACY_GATE_TOKEN:?missing legacy proof}" --native-session "$SESSION_ID"
fi
```

Stop on a failed clear or receipt check before continuing.
This explicit human invocation authorizes new background starts again. Do not
clear `.repos[REPO].refill.paused` unless `--resume-refill` was supplied.

When `--resume-refill` is present, set refill to
`{"paused":false,"reason":null,"scope":null,"at":null}` with
`session-state.sh`. Report a failed write; do not claim refilling resumed.

## Step 2: Inventory preserved work

List registry entries for the current repo and session in `stopped`, `failed`,
`rearmed`, and `abandoned` states. Display each exact runtime ID, logical name,
type, output file, worktree/recovery path, and work item. Keep the historical
entry after resume so a second invocation is idempotent.

Before re-arming an entry, inspect Claude Code runtime tasks. If the same work
is already live, do not launch a duplicate; mark or leave it `rearmed` and
report the existing identity.

For a stopped entry that still needs a launch, atomically claim it before the
runtime check with:

<!-- test-anchor: end-resume-reserve-task -->

```bash
"$TASK_REGISTRY_SH" --repo "$RESUME_REPO" --transition --session "${STOP_SESSION_ID:?bind the verified stop session}" \
  --task-id "$TASK_ID" --status rearming --from-status stopped
```

Exit 7 means another resume invocation already changed the entry; skip it and
re-read rather than launching. Only the successful claimant proceeds. A failed
or incomplete recovery transitions `rearming -> stopped` with
`--from-status rearming`; a confirmed recovery transitions `rearming ->
rearmed`. Because the compare-and-set runs under the registry lock, concurrent
`/end-resume` invocations cannot both launch the same continuation.

`rearming` is a reservation, not a stoppable runtime identity, and is excluded
from registry `--live` results. Immediately before launching, require exact `inactive` status for both the
native runtime and raw legacy key in the verified repo. Check each distinct
key once. For legacy recovery also revalidate the continuation receipt.

<!-- test-anchor: end-resume-prelaunch-gates -->

```bash
: "${SESSION_ID:?missing runtime scope}" "${STOP_SESSION_ID:?missing stop scope}" "${RESUME_REPO:?missing repo}"
for gate_scope in "$SESSION_ID" "${LEGACY_GATE_SESSION_ID:?missing checked legacy scope}"; do
  gate_status=$("$EXECUTION_PAUSE_SH" --repo "$RESUME_REPO" --status --session "$gate_scope") || exit 1
  [[ "$gate_status" == inactive ]] || exit 1
  [[ "$SESSION_ID" != "$LEGACY_GATE_SESSION_ID" ]] || break
done
if [[ "$STOP_SESSION_ID" != "$SESSION_ID" ]]; then
  RESUME_SCOPE=$("$EXECUTION_PAUSE_SH" --repo "$RESUME_REPO" --legacy-resume-scope \
    --session "$STOP_SESSION_ID" --native-session "$SESSION_ID") || exit $?
  [[ "$RESUME_SCOPE" == "$STOP_SESSION_ID" ]] || exit 1
fi
```
If either check blocks launch, return the reservation to `stopped` before
exiting. A concurrent `/end` or `/pause` activation blocks the new launch.
A successful successor registers its own runtime ID through the normal launch hook before the old reservation becomes `rearmed`, so shutdown
audits stop the successor ID rather than racing on the old stopped ID. If launch
is blocked or fails, compare-and-set the reservation back to `stopped`.

On a later resume, a `rearming` reservation older than five minutes is an
interrupted claim. Inspect runtime tasks and the registry first: finalize it as
`rearmed` when a successor is already registered, otherwise reset it to
`stopped` with `--from-status rearming` and retry. Never reclaim a fresh
reservation or infer successor liveness from the display name.

## Step 3: Resume recoverable entries

- Agent: send a continuation message to the exact agent runtime ID, naming its
  checkpoint/output path. If that identity cannot resume, create a successor
  only from the recorded handoff or recovery path and record the new runtime ID.
- Workflow, background Bash, or Monitor: delegate to the owning skill or use
  the recorded recovery action. Never guess a command from its display name.
- Missing or unreadable recovery metadata: leave the entry stopped and report
  the exact missing field.

After a confirmed re-arm, transition the claimed entry to `rearmed` with
`--from-status rearming`. Re-read the registry and runtime list before
reporting.

**Re-arm the table-freshness floor when a round resumes.** `/end` disarms it by
DATA (it clears the render record) and its shutdown stops the persistent
Monitor, so both halves are gone — and `/subagent` arms that watch **once per
session**, on the assumption it outlives the round. Nothing else re-arms it, so
without this a resumed round has no unprompted hourly pulse for the rest of its
life: `--check` still answers when a heartbeat asks, but the floor stops
volunteering, which is the whole guarantee. `/pause-resume` Step 5 handles this
same pair of lost halves; keep the two in step.

Do this only when a round is actually resuming (at least one pipeline re-armed
above), and only with a resolved repo key:

```bash
# `--repo-key` prints `_unknown` and exits 0 when it cannot resolve a repo, so
# an emptiness test alone never fires — normalise the sentinel, or the watch is
# armed on a scope no render will ever write to.
REPO_KEY="$RESUME_REPO"
[[ "$REPO_KEY" == "_unknown" ]] && REPO_KEY=""
TABLE_FRESHNESS_SH=$(resolve_script table-freshness.sh) || TABLE_FRESHNESS_SH=""
if [[ -n "$TABLE_FRESHNESS_SH" && -n "$REPO_KEY" ]]; then
  # Record the resumed board FIRST, then arm: arming over an absent record
  # gives a watch that polls nothing and stays silent while looking armed.
  ACTIVE_COUNT=<pipelines re-armed above, running + queued>
  if [[ "${ACTIVE_COUNT:-}" =~ ^[0-9]+$ ]] && (( ACTIVE_COUNT > 0 )); then
    if "$TABLE_FRESHNESS_SH" --note-rendered --active "$ACTIVE_COUNT" \
         --repo "$REPO_KEY" --session "$SESSION_ID" \
         --surface end-resume; then
      # Hand `--arm-command` output to the Monitor tool with persistent: true.
      "$TABLE_FRESHNESS_SH" --arm-command --repo "$REPO_KEY" \
        --session "$SESSION_ID"
    else
      echo 'DEGRADED: table-freshness clock not recorded on resume — floor not re-armed; re-render the "Running now" table on every heartbeat'
    fi
  fi
fi
```

Nothing to re-arm (an empty board) correctly leaves the floor disarmed — that is
the idle exemption, not a gap.

## Step 4: Report

```text
=== End resumed ===
Launch gate: cleared
Refill gate: <cleared | still paused | clear failed>
Rearmed: <exact old ID -> resumed/new ID, or none>
Still stopped: <exact IDs and missing recovery requirement, or none>
```

Never report an entry rearmed merely because a launch was attempted. A second
invocation must not duplicate anything already running.
