---
name: pause
description: Use when you are closing your laptop and need every current-session background task stopped at a resumable boundary. Blocks new launches, uses a bounded runway to land safe work, hard-stops leftovers, and writes machine-readable resume state. Triggers on "pause", "laptop close", "heading out", "park the work", "shutting down".
triggers:
  - pause
  - laptop close
  - heading out
  - park the work
  - shutting down
argument-hint: "[--window Nm] (default: --window 15m; --window 0 stops immediately)"
---

Land what can land. Park the rest at a deliberate boundary. Write a resume point you can pick up cold.

Two outputs, in this order: an active wind-down that drives near-done PRs to merged, then a machine-readable marker and human-readable summary the companion `/pause-resume` reads when you sit back down.

**This command never relaxes a gate.** `cr-merge-gate.md` Steps 1–1d, 1b and the Step 2 AC verification bind unchanged. The hard stops in `CLAUDE.md` "PR MERGE AUTHORIZATION" (human `CHANGES_REQUESTED` on HEAD, failing/incomplete CI, unresolved threads, unchecked AC, protection-modifying bypass) are hard stops here. The window never makes a borderline PR eligible; it only decides how long to wait on already-eligible ones.

**One parameter: `--window Nm`.** Fifteen minutes is the default graceful
shutdown runway and triage threshold; a caller may choose a shorter or longer
non-negative window. The command stops earlier when all owned work is terminal.
At the chosen deadline it stops leftovers; it never merely returns while
billable work continues.

## Step 0: Resolve helpers and parse arguments

`/pause` is invocable from any thread — including one whose cwd is not this repo. Resolve each helper the same way every other stop-style command does:

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
SESSION_STATE_SH=$(resolve_script session-state.sh)     || SESSION_STATE_SH=""
HANDOFF_STATE_SH=$(resolve_script handoff-state.sh)     || HANDOFF_STATE_SH=""
MERGE_GATE_SH=$(resolve_script merge-gate.sh)           || MERGE_GATE_SH=""
AC_CHECKBOXES_SH=$(resolve_script ac-checkboxes.sh)     || AC_CHECKBOXES_SH=""
PR_STATE_SH=$(resolve_script pr-state.sh)               || PR_STATE_SH=""
LOCAL_REVIEW_SH=$(resolve_script local-review.sh)       || LOCAL_REVIEW_SH=""
CLEAN_BEHIND_SH=$(resolve_script clean-behind-check.sh) || CLEAN_BEHIND_SH=""
EXECUTION_PAUSE_SH=$(resolve_script execution-pause.sh) || EXECUTION_PAUSE_SH=""
TASK_REGISTRY_SH=$(resolve_script background-task-registry.sh) || TASK_REGISTRY_SH=""

# Resolve repository identity independently of session-state persistence so a
# degraded state helper does not make the recovery marker undiscoverable.
REPO_KEY=""
if [[ -n "$SESSION_STATE_SH" ]]; then
  REPO_KEY=$("$SESSION_STATE_SH" --repo-key 2>/dev/null) || REPO_KEY=""
fi
if [[ -z "$REPO_KEY" ]]; then
  REMOTE=$(git remote get-url origin 2>/dev/null) || REMOTE=""
  REPO_KEY=$(printf '%s' "$REMOTE" | sed -e 's|\.git$||' \
    -e 's|.*github\.com[:/]\([^/]*/[^/]*\)$|\1|')
  [[ "$REPO_KEY" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || REPO_KEY=""
  REPO_KEY=$(printf '%s' "$REPO_KEY" | tr '[:upper:]' '[:lower:]')
fi
```

Resolve `background-task-shutdown.md` from the skills-worktree, then the home
install location, and read it in full before Step 1. Never fall back to the
current checkout for scripts or instruction documents: `/pause` can be invoked
from an unrelated or untrusted repository, whose executable bit is not a trust
signal.

An unresolved `session-state.sh` is degraded-but-continue — say so when reporting and carry on, because the marker still gets written. An unresolved `merge-gate.sh` means the landing phase cannot classify PRs reliably; skip landing for all PRs and park them, naming the missing helper in each parked entry's `waiting_on` field.

An unresolved `TASK_REGISTRY_SH`, unreadable shutdown reference, or durable
registry-failure marker makes the shutdown audit unavailable. Arm every gate
that can still be armed, skip any claim that no tasks are live, and carry the
missing control into Step 8 as `INCOMPLETE SHUTDOWN`; never interpret an
unreadable inventory as an empty one.

**Parse `--window Nm`:** extract the integer N from the **first** `--window` argument; default to `15`. `--window 0` means skip landing and checkpoint time, then stop everything immediately. Accept a non-negative integer with an optional trailing `m`; normalize leading zeroes as decimal, and reject non-numeric, negative, or greater-than-1440-minute values. Stop processing `--window` arguments after the first valid value. Compute `T_end` once:

```bash
WINDOW_MINUTES=15
_WINDOW_SET=false
_NEXT_IS_WINDOW=false
for arg in $ARGUMENTS; do
  [[ "$_WINDOW_SET" == true ]] && continue
  if [[ "$_NEXT_IS_WINDOW" == true ]]; then
    _NEXT_IS_WINDOW=false
    # Strip optional trailing 'm', validate text, then bound before arithmetic.
    _RAW="${arg%m}"
    [[ "$_RAW" =~ ^[0-9]+$ ]] || \
      { echo "ERROR: --window requires a non-negative integer (got: $arg)" >&2; exit 2; }
    _NORMALIZED="${_RAW#"${_RAW%%[!0]*}"}"
    _NORMALIZED="${_NORMALIZED:-0}"
    (( ${#_NORMALIZED} < 4 )) || \
      { (( ${#_NORMALIZED} == 4 )) && [[ "$_NORMALIZED" < 1441 ]]; } || \
      { echo "ERROR: --window must not exceed 1440 minutes." >&2; exit 2; }
    WINDOW_MINUTES=$((10#$_NORMALIZED))
    _WINDOW_SET=true
    continue
  fi
  case "$arg" in
    --window) _NEXT_IS_WINDOW=true ;;
  esac
done
if [[ "$_NEXT_IS_WINDOW" == true ]]; then
  echo "ERROR: --window requires a value." >&2; exit 2
fi
T_END=$(( $(date -u +%s) + WINDOW_MINUTES * 60 ))
```

## Step 1: Close both launch gates

Stop every launch path before reading the board so nothing new enters the
pipeline during the runway:

```bash
WINDDOWN_PERSISTED=1
EXECUTION_GATE_PERSISTED=1
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
if [[ -n "$EXECUTION_PAUSE_SH" ]]; then
  "$EXECUTION_PAUSE_SH" --activate --session "$SESSION_ID" \
    --command pause --window-minutes "$WINDOW_MINUTES" \
    || EXECUTION_GATE_PERSISTED=0
else
  EXECUTION_GATE_PERSISTED=0
fi
if [[ -n "$SESSION_STATE_SH" && -n "$REPO_KEY" ]]; then
  NOW=$(date -u +%FT%TZ)
  "$SESSION_STATE_SH" \
    --set ".repos[\"$REPO_KEY\"].refill={\"paused\":true,\"reason\":\"full_stop\",\"scope\":null,\"at\":\"$NOW\"}" \
    || WINDDOWN_PERSISTED=0
else
  WINDDOWN_PERSISTED=0
fi
```

**The truthful report rule from `/end` Step 2 binds here.** Either
`WINDDOWN_PERSISTED=0` or `EXECUTION_GATE_PERSISTED=0` makes the final result
`INCOMPLETE SHUTDOWN`. Name the failed gate explicitly and never print
`Stopped: new work paused` or `Pause complete` after either failed write.

## Step 2: Stop passive Monitors, checkpoint productive work

Stop persistent Monitors owned by this session **before** the landing phase. This makes landing single-writer: a live `/babysit-pr` tick can dispatch `/fixpr` on the same PR `/pause` is about to drive through `/wrap`, and the two would race. The stop comes first so landing is orderly.

Enumerate Monitors in this order and record the result of each stop:

1. **Per-PR babysit watchers** — for each PR where `.prs["N"].babysit.active == true`: delegate to the existing `/babysit-pr-stop <PR>` skill. Record `stopped: true` on success.
2. **PR fleet monitor (`/pr-monitor-and-manage`)** — delegate to `/pr-monitor-and-manage-stop`. Record `stopped: true` on success.
3. **Day-mode loop** — follow the `/pm` 2D.4 teardown order exactly:
   a. `"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.stop_requested=true"`
   b. `TaskStop` the exact recorded `day.monitor_task_id`. Missing ID, or a failed stop → keep `active=true`, retain the ID, record `stopped: false`.
   c. Only after the stop succeeds: `active=false`, `monitor_task_id=null`, `monitor_generation=null`.
4. **Usage-limit auto-wake Monitor** (`day.limit_resume_task_id`) — if the day state block contains a non-null `limit_resume_task_id`, stop it to prevent a double resume after manual `/pause`. **This one entry covers both wake shapes**: 2D.6's sleep-until-reset one-shot and 2D.7's bounded probe Monitor (#1428) record their identity in the same pair, so a pre-emptive park is torn down here with no new monitor class to teach this step about:
   a. Read `day.limit_resume_task_id` with its exit code. If the read is unreadable (non-zero and non-3 exit code), **report the failure** — do not silently skip or claim cleanup succeeded: record `stopped: false` with `owner: "day_limit_wake"` in `monitors_stopped` and name the read failure in the Step 8 report so the user knows the auto-wake Monitor identity could not be confirmed. If the value is null or the state file never existed (exit 3), skip — no Monitor to stop.
   b. `TaskStop` the recorded ID. On success: `"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.limit_resume_task_id=null"`, `--set ".repos[\"$REPO_KEY\"].day.limit_resume_generation=null"`, and `--set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=null"` (the probe bound belongs to the wake that was just stopped). Record `stopped: true` in `monitors_stopped` with `owner: "day_limit_wake"`.
   c. On failure: keep the ID, record `stopped: false`, and name the task ID in the Step 8 report so the user can stop it manually.

**A failed `TaskStop` is recorded as `stopped: false` and reported in Step 8.** Never claim a Monitor was stopped when the stop itself was not confirmed. Stopped Monitors are recorded in the `monitors_stopped` array of the pause state block (Step 7).

After the specialized Monitor teardown above, follow
`background-task-shutdown.md` for every registry entry in this session. Give
productive agents, workflows, and background commands the remaining bounded
window to checkpoint; stop them as soon as they finish, and hard-stop exact
remaining IDs at `T_END`. Record output, handoff, worktree, and recovery paths
in `parked`. A failed stop keeps the gates closed and makes the result
incomplete.

## Step 3: Collect the board

Gather the complete picture of what is in flight. For authorship reasons (`safety.md` §"Authorship"), only PRs authored by `@me` in the current repo are eligible for landing or parking by this session's automation.

Collect:

1. **Open PRs** — `gh pr list --state open --author "@me"` from the current repo.
2. **Running subagents** — `active_agents` from `session-state.sh --session-view`. Treat the list as a candidate list, not a fact: an agent in the list may have already completed and written its handoff.
3. **Worktree branches with uncommitted or unpushed work** — check each local worktree for staged/unstaged changes and commits not yet on the remote.

With no `session-state.sh` resolved, collection is limited to what `gh pr list` returns. Report "could not read what was running" for subagents and worktrees rather than "nothing was running".

## Step 4: Triage — print before acting

Every in-flight unit gets exactly one of `land` | `park`, stated with its reason **before** any action is taken. Print the full classification before Step 5 begins.

**Triage rule (conservative, per issue Notes):**

```
land  ←  merge-gate.sh exits 0 (gate MET on current HEAD)
      ←  OR the ONLY outstanding blocker is unchecked Test Plan boxes that
          verify mechanically against code already pushed on current HEAD
          (AC checkboxes only, no code change needed)

park  ←  everything else
```

`park` therefore covers — and none of these can be argued into `land`:
- awaiting a fresh bot review round (any reviewer)
- CI still running or pending
- any unresolved review thread
- human `CHANGES_REQUESTED` on HEAD
- `mergeable: CONFLICTING`
- any AC box that needs a code change rather than a tick
- any PR where `merge-gate.sh` is unresolved and cannot run

Subagents are **never** `land` — they cannot be driven to a merge from outside. `--window 0` forces every unit to `park` before this step runs.

**`mergeStateStatus: BEHIND` is not a special case here.** `land` dispatches `/wrap`, and Step 1d's clean-`BEHIND` handling lives inside that path already. A protection-modifying bypass remains a hard stop that parks the unit and prints the `/admin-merge` runbook.

Example output:

```
=== Pause triage ===
[land]  PR #1248 — gate met on current HEAD (CodeRabbit APPROVED, CI green, all threads resolved)
[park]  PR #1251 — awaiting CodeRabbit review round (not fifteen-minute work)
[park]  Subagent phase-a-fixer PR #1249 — checkpoint then stop; handoff at ~/.claude/handoffs/.../pr-1249-handoff.json
```

## Step 5: Land phase (skipped entirely when `--window 0`)

Serial, not parallel — two concurrent `/wrap` runs against one repo race on main.

**The window is a budget, not a promise.** Before dispatching each `land` unit, check `$(date -u +%s)` against `T_END`. A unit that has not reached `merged` by `T_END` is reclassified `park` and recorded at its actual state — never left running on the assumption the user is still watching.

For each `land` unit, dispatch `/wrap`. Monitor its outcome. If the window
expires while a `/wrap` is still in flight, request its checkpoint, record its
actual boundary, then hard-stop its exact runtime ID via the shared shutdown
contract. Reclassify the unit `park`; `/pause-resume` re-reads GitHub before
deciding whether it still needs work.

A `land` unit that hits a hard stop during `/wrap` (human `CHANGES_REQUESTED`, protection-modifying bypass, etc.) is reclassified `park` immediately and the hard stop is named in its `stopped_at` field.

## Step 6: Park phase

Bring each `park` unit to a deliberate boundary **before** recording it. Per unit, in order:

**Immediate branch (`WINDOW_MINUTES == 0`):** record the state already captured
after the exact-ID hard stop and skip actions 1 and 2 below. Do not post review
replies, run local review, commit, push, or launch any landing/checkpoint work.
Set the boundary to `stopped immediately; no mutation attempted` plus the exact
recovery path. This is the machine-park path and the explicit user fast-stop
path; Step 7 still publishes the marker and JSON state.

1. **Post pending review replies** — any bot finding that has been addressed but not yet replied to gets a reply now.
2. **Commit and push fixes** — if the remaining budget allows a local review loop, run it; otherwise commit and push anyway. When a push is impossible (no upstream, auth failure, conflict), say exactly why in the parked entry's `boundary` field: "pushed without local review — window expired", "push failed: no upstream", etc. Never leave fixes only in a worktree when a push was possible.
3. **Record the stopping point** — fill in `stopped_at` (what state it reached), `next_move` (the next action for resume), `waiting_on` (reviewer | ci | null), and `boundary` (pushed | unpushed with reason).

No half-applied review round: either a round's fixes are all committed and its threads replied, or the entry records exactly which findings were applied and which were not.

For running subagents: record what each was doing, its exact runtime ID, and
where its handoff/output/worktree lives. They must be confirmed terminal before
Step 8 can report completion.

## Step 7: Persist the pause state

Two writes, in this order: **first the marker** (so `MARKER_PATH` is known before the JSON is built), **then the `session-state.sh` write** (which embeds the marker path).

New pauses write only `.repos[<key>].pause` state and `pause-*.md` markers.
`/pause-resume` retains a read-only fallback for `.suspend` state and
`suspend-*.md` markers created before Issue #1310; `/pause` never creates new
legacy records.

### 7a: Write the human-readable marker

Use the same atomic `mktemp` + `mv` publish that `/end` Step 6 uses. Staging inside `$OUT_DIR` keeps `mv` on one filesystem. The marker filename includes the repo key so a resume from a different repo cannot accidentally pick it up as a cross-repo fallback:

```bash
OUT_DIR="$HOME/.claude/handoffs"
MARKER_PUBLISHED=false
MARKER_ERROR=""
if ! mkdir -p "$OUT_DIR"; then
  MARKER_ERROR="mkdir -p $OUT_DIR failed"
fi
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
SESSION_ID="${SESSION_ID//[^[:alnum:]_.-]/_}"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
# A length-prefixed owner/repo encoding is injective; replacing '/' with '-'
# alone collides for names such as a-b/c and a/b-c.
REPO_KEY="${REPO_KEY:-_unknown}"
MARKER_AUTO_DISCOVERABLE=true
[[ "$REPO_KEY" == */* ]] || MARKER_AUTO_DISCOVERABLE=false
if [[ "$REPO_KEY" == */* ]]; then
  REPO_OWNER="${REPO_KEY%%/*}"
  REPO_NAME="${REPO_KEY#*/}"
  REPO_KEY_SAFE="${#REPO_OWNER}-${REPO_OWNER}-${#REPO_NAME}-${REPO_NAME}"
else
  REPO_KEY_SAFE="unknown"
fi
TMP_MARKER=""
if [[ -z "$MARKER_ERROR" ]] && \
   ! TMP_MARKER=$(mktemp "$OUT_DIR/.pause-marker.XXXXXX"); then
  MARKER_ERROR="mktemp $OUT_DIR/.pause-marker.XXXXXX failed"
fi
# The rendered marker starts with: Repository: `<exact owner/repo>`
# Derive the unique published name from mktemp's exclusive suffix.
MARKER_TAG="${TMP_MARKER##*.pause-marker.}"
MARKER_PATH="$OUT_DIR/pause-${STAMP}-${REPO_KEY_SAFE}-${SESSION_ID}-${MARKER_TAG}.md"
# ... write the marker content, including exact Repository, to "$TMP_MARKER" ...
if [[ -n "$TMP_MARKER" ]] && mv "$TMP_MARKER" "$MARKER_PATH"; then
  chmod 644 "$MARKER_PATH"
  MARKER_PUBLISHED=true
else
  # Keep the fallback path as a glob-discoverable name so /pause-resume can
  # still find it; rename the temp file to match the pause-* pattern.
  FALLBACK_PATH="$OUT_DIR/pause-${STAMP}-${REPO_KEY_SAFE}-${SESSION_ID}-${MARKER_TAG}-draft.md"
  PRIMARY_MARKER_PATH="$MARKER_PATH"
  if [[ -n "$TMP_MARKER" ]] && mv -f "$TMP_MARKER" "$FALLBACK_PATH" 2>/dev/null; then
    chmod 644 "$FALLBACK_PATH"
    MARKER_PATH="$FALLBACK_PATH"
    MARKER_PUBLISHED=true
    MARKER_ERROR="primary publish to $PRIMARY_MARKER_PATH failed; fallback published at $FALLBACK_PATH"
  else
    MARKER_ERROR="${MARKER_ERROR:-primary and fallback marker publication failed}"
    MARKER_PATH=""
  fi
fi
[[ "$MARKER_PUBLISHED" == true ]] || \
  echo "could not publish the pause marker: $MARKER_ERROR" >&2
```

The marker is also the fallback index for `/pause-resume`: if
`session-state.sh` is unreadable at resume, the companion globs `pause-*.md`,
matches the injective filename key, and verifies the exact `Repository:
\`owner/repo\`` field before selecting the newest candidate. Its content mirrors
the `pause` state block in human-readable form: what landed, what is parked,
each parked unit's stopping point and next move, exact stopped-task recovery
records, and the refill pause status with how to lift it.

### 7b: `session-state.sh --set` the `.repos[<key>].pause` block

**This block is invisible to `session-state.sh --session-view`** (that projection lifts only `.prs` and `.root_repo`). Like `refill` and `day`, read it with an explicit `--get` or an armed pause reports as absent. Never inline `jq … > tmp && mv tmp` — that bypasses the state lock (`handoff-files.md`).

`WINDDOWN_PERSISTED` is `1` (success) or `0` (failed) — convert it to a JSON boolean before embedding in the state block:

```bash
PAUSE_PERSISTED=1
if [[ "$MARKER_PUBLISHED" == true && -n "$SESSION_STATE_SH" && \
      -n "$REPO_KEY" && "$REPO_KEY" != "unknown" ]]; then
  [[ "$WINDDOWN_PERSISTED" == "1" ]] && REFILL_PAUSED_BOOL=true || REFILL_PAUSED_BOOL=false
  NOW=$(date -u +%FT%TZ)
  PAUSE_JSON=$(jq -n \
  --argjson active true \
  --arg paused_at "$NOW" \
  --argjson window_minutes "$WINDOW_MINUTES" \
  --argjson window_expired "$WINDOW_EXPIRED" \
  --argjson landed "$LANDED_JSON" \
  --argjson parked "$PARKED_JSON" \
  --argjson monitors_stopped "$MONITORS_STOPPED_JSON" \
  --argjson background_tasks_stopped "$BACKGROUND_TASKS_STOPPED_JSON" \
  --argjson refill_paused "$REFILL_PAUSED_BOOL" \
  --arg marker_path "$MARKER_PATH" \
    '{active:$active, paused_at:$paused_at,
    window_minutes:$window_minutes, window_expired:$window_expired,
    landed:$landed, parked:$parked,
    monitors_stopped:$monitors_stopped,
    background_tasks_stopped:$background_tasks_stopped,
    refill_paused:$refill_paused, marker_path:$marker_path,
      resumed_at:null}')
  if "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].pause=$PAUSE_JSON"; then
    PAUSE_PERSISTED=0
  fi
fi
```

If `MARKER_PUBLISHED` is not true, skip the state write because it would embed
a nonexistent marker path. Keep both gates closed, set `PAUSE_PERSISTED` to a
nonzero value, and report `MARKER_ERROR` in Step 8 as `INCOMPLETE SHUTDOWN`.

If `session-state.sh` was not resolved in Step 0, skip this write and set `PAUSE_PERSISTED=1` (failed). Say so in Step 8.

## Step 8: Report

Compact, per `CLAUDE.md` #3. No phase-by-phase narration, no progress tables.

```
=== Pause <complete | INCOMPLETE SHUTDOWN> ===
Stopped: <WINDDOWN_PERSISTED=1: "refill paused (lift with: tell Claude 'resume refilling' in the next session)">
         <WINDDOWN_PERSISTED=0: "COULD NOT record the refill pause — another thread may still start new work">

Landed:
  merged PR #N  (one line per merged PR)
  <nothing landed> if the list is empty

Parked (<N> units):
  PR #M — <stopped_at> · next: <next_move> · waiting on: <waiting_on>
  Subagent <kind> — handoff at <path>
  <nothing parked> if the list is empty

Monitors stopped: <N stopped of M total; any not-stopped named here>
Background tasks stopped: <N stopped of M total; exact unresolved IDs named here>

Resume state: <PAUSE_PERSISTED=0: "stored in session state; marker at $MARKER_PATH">
              <PAUSE_PERSISTED!=0 and MARKER_PUBLISHED=true: "session state failed; marker fallback at $MARKER_PATH">
              <MARKER_AUTO_DISCOVERABLE=false and MARKER_PUBLISHED=true: "repository identity unavailable; resume explicitly with /pause-resume --marker $MARKER_PATH">
              <MARKER_PUBLISHED=false: "NO recovery artifact was published — manual recovery required; $MARKER_ERROR">

Resume with: <MARKER_AUTO_DISCOVERABLE=true: "/go-on [--resume-refill]   (routes to /pause-resume; call it directly if you prefer)">
             <MARKER_AUTO_DISCOVERABLE=false: "/pause-resume --marker $MARKER_PATH [--resume-refill]   (an undiscoverable marker cannot be classified, so /go-on cannot route it)">
```

The `Resume with:` line names `/go-on` because a resume days later should not
depend on remembering that this stop was a pause (Issue #1397). Its second form
is the one case that still needs the specialized command by name: `/go-on` takes
no `--marker`, so a marker published without a usable repository identity has to
be handed to `/pause-resume` directly.

The `Stopped:` line has exactly two forms, matching `/end` Step 2's rule. After a failed refill-pause write, never print the first form — that would report something untrue about the one side effect the user is counting on.

Monitors or background tasks that were not stopped are named explicitly. Never
print `Pause complete` while either the registry or runtime audit has a live
owned task or could not be read, or while `EXECUTION_GATE_PERSISTED != 1`.
Pause-state persistence with `PAUSE_PERSISTED != 0` also selects `INCOMPLETE SHUTDOWN`.
The marker remains the recovery source only when `MARKER_PUBLISHED=true`. If it
is false, do not print `MARKER_PATH` or claim marker fallback; report that no
artifact exists, require manual recovery, and keep both gates closed.
An execution-gate activation failure must be reported even when every task that
was already visible stopped successfully, because a concurrent new launch
could have escaped the wind-down.

## What this command is not

- **A gate relaxer.** Every merge gate requirement that applies outside this command applies inside it. The window changes the deadline, never the standard.
- **A work deleter.** Hard stops preserve branches, worktrees, logs, handoffs,
  outputs, and recovery metadata for `/pause-resume`.
- **A second `/end`.** `/end` produces a harness-external document for a reader outside this harness and merges nothing. This command produces internal, machine-readable resume state and actively lands eligible work. They share Step 0 resolution, the refill-pause write, and the two-form report rule — and nothing else.

## Relationship to the other wind-down commands

| Command | Ends | Produces |
|---|---|---|
| `/wrap` | one pull request | a merge, follow-up issues, lessons |
| `/end` | current-session execution (budget thin; 5m default) | portable handoff + stopped-task recovery data |
| `/pause` | current-session execution (laptop close; 15m default) | machine-readable resume state + landed PRs |

Both stops are resumed through the same front door: `/go-on` reads the records
each one writes, works out which stop happened, and routes to `/pause-resume` or
`/end-resume` accordingly. `/pause` writes exactly what it wrote before.
