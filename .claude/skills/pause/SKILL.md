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

**The window is a ceiling on the whole run, not a budget for its middle.** It
bounds every phase — landing, park bookkeeping, marker writing, state
persistence — and not merely the land phase. Once the deadline passes, the run
stops all remaining non-terminal work and cuts straight to the bounded terminal
path defined in Step 0, degrading optional output rather than blowing the
ceiling. A `/pause --window 15m` is observably finished shortly after minute
15, every time, and Step 8 names what was skipped to make that true.

## Step 0: Resolve helpers and parse arguments

`/pause` is invocable from any thread — including one whose cwd is not this repo. Resolve each helper the same way every other stop-style command does:

```bash
# Command entry — stamp the clock FIRST. The window is measured from the moment
# /pause was invoked, so preflight (resolving helpers, discovering the repo,
# reading the shutdown reference) is spent inside the window, not free time
# before it. Starting the clock after preflight would silently extend every
# deadline and under-report elapsed time in Step 8.
T_START=$(date -u +%s)

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
TABLE_FRESHNESS_SH=$(resolve_script table-freshness.sh) || TABLE_FRESHNESS_SH=""
EXECUTION_PAUSE_SH=$(resolve_script execution-pause.sh) || EXECUTION_PAUSE_SH=""
TASK_REGISTRY_SH=$(resolve_script background-task-registry.sh) || TASK_REGISTRY_SH=""

# Resolve repository identity independently of session-state persistence so a
# degraded state helper does not make the recovery marker undiscoverable.
REPO_KEY=""
if [[ -n "$SESSION_STATE_SH" ]]; then
  REPO_KEY=$("$SESSION_STATE_SH" --repo-key 2>/dev/null) || REPO_KEY=""
  # `--repo-key` NEVER returns empty: it prints `_unknown` and exits 0 when it
  # cannot resolve a repo. Normalise that sentinel to empty so the fallback
  # below actually runs and the `-z` guards downstream actually fire —
  # otherwise teardown clears `_unknown`, a scope nothing polls, and reads as a
  # successful disarm while the live record keeps the floor armed.
  [[ "$REPO_KEY" == "_unknown" ]] && REPO_KEY=""
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
# T_START was stamped at command entry, above — never re-stamp it here.
T_END=$(( T_START + WINDOW_MINUTES * 60 ))
# Fixed post-deadline ceiling: three minutes. Enough for one slow TaskStop or
# state-lock retry plus two file writes and the report — no more.
GRACE_SECONDS=180
T_GRACE_END=$(( T_END + GRACE_SECONDS ))
# Always defined before Step 7b builds PAUSE_JSON with --argjson.
WINDOW_EXPIRED=false
```

### The deadline model (one model, used by every later step)

**The check idiom.** Every step that performs work calls this before each unit
of work. The first call that finds the deadline passed latches
`WINDOW_EXPIRED`; it never unlatches:

```bash
past_deadline() {                       # true once T_END has passed
  (( $(date -u +%s) >= T_END )) && WINDOW_EXPIRED=true
  [[ "$WINDOW_EXPIRED" == true ]]
}
past_grace() { (( $(date -u +%s) >= T_GRACE_END )); }
```

**The bounded terminal path** is exactly four moves, in this order:

1. Stop leftover work (Step 2) — the specialized Monitor teardown and the
   exact-ID hard-stops are both this one move, not separate phases
2. Write the marker — compact form when `WINDOW_EXPIRED` is true (Step 7a)
3. Persist pause state (Step 7b)
4. Print the report (Step 8)

**`T_GRACE_END` bounds each of those four moves, not just the run as a whole.**
Call `past_grace` before starting a terminal move and before any retry inside
one — a state-lock retry, a re-attempted `mv`. A pre-check alone cannot bound an
operation that hangs, so **invoke each move bounded**: rely on the helpers' own
timeouts rather than waiting indefinitely (`session-state.sh` and
`handoff-state.sh` exit `6` on lock timeout; a `TaskStop` that does not confirm
is recorded `stopped: false`, never awaited). When a move exceeds the bound,
stop waiting rather than finishing: record that move as incomplete, do not
retry it, skip straight to the report, and select `INCOMPLETE SHUTDOWN` under
the existing rules below. A grace bound that nothing checks is decoration; this is the check
that makes three minutes a real ceiling.

**Only these four moves may run between `T_END` and `T_GRACE_END`.** Everything
else — landing a further unit, a local review round, a commit or push, a
long-form marker section — is skipped the moment `past_deadline` returns true.
Step 1's two gate writes are the one other unconditional move: closing the
launch gates is what makes a stop a stop, so it runs to completion whenever it
is reached, before any deadline arithmetic can shorten it.

**The checkable rule:** every step that runs after `T_END` is computed either
calls `past_deadline` before each unit of work, is one of the named moves
above, or is one of the two bookkeeping exceptions named below. No step in this
skill is exempt, and none may run unbounded. **The rule governs work that waits
or mutates**; the exceptions are neither, and they run to completion without a
`past_deadline` check of their own.

**Two named exceptions, both bookkeeping rather than work.** Neither waits, and
neither mutates anything outside this run's own in-memory board, which is why
neither is a hole in the rule above:

1. **Step 3 collection under `--window 0`.** `T_END == T_START` makes
   `past_deadline` true before the first read, but this path does no landing
   and no mutation, so the collected board *is* its whole output. The three
   bounded reads run; skipping them would publish an empty record of a machine
   that was not empty. The skip belongs to a window that was spent, not to one
   never offered.
2. **The post-deadline bookkeeping pass — Step 4's classification and sweep,
   and Step 6's recording.** These carry already-collected units to the
   terminal path: Step 4 relabels every unit `park` (an in-memory pass with no
   `gh` call and nothing that can block), and Step 6 records each at its actual
   state *without mutation*. Both must run to completion. A half-swept board
   strands `land` units that no step will then dispatch, and an unrecorded unit
   is lost exactly as surely as one never read — which is why Step 3 forbids
   routing collected work straight to the terminal path. **So "only these four
   moves" means only these four may *wait or mutate*; it never barred the
   non-mutating bookkeeping that gives them something to write.**

Both exceptions are bounded by construction — a fixed number of non-blocking
steps over an already-finite board — not by a clock check. Everything else
stays subject to the rule above, and the terminal-move and gate-write
restrictions are unchanged.

**Re-check the clock at terminal entry.** `WINDOW_EXPIRED` only latches when
`past_deadline` is actually called, so call it once more on entering the
terminal path — before choosing the marker form in Step 7a and before building
`PAUSE_JSON` in Step 7b. Without that call a run whose last working-step check
fell just inside the window would write a full-length marker and record
`window_expired: false` while already past the deadline. The recorded flag must
describe the clock at the moment the artifacts are built, not the last time a
working step happened to look.

**`--window 0` is unchanged.** It still forces every unit to `park`, skips
landing and checkpoint work entirely, and stops immediately. `T_END` equals
`T_START`, so `past_deadline` is true from the first call — the immediate
branch and the past-deadline branch are the same shape reached two ways, and
the terminal path still publishes the marker and the JSON state.

**"Immediately" scopes to waiting and mutation, never to reading.** What
`--window 0` skips is landing, checkpoint time, and every park-phase mutation —
not Step 3's collection, which ran on this path before the ceiling existed and
still does. The marker and JSON state this path publishes are built *from* the
collected board, so a `--window 0` run that read nothing would publish an empty
record of a machine that was not empty. Step 3 states the same carve-out from
its own side; the two are one rule.

## Step 1: Close both launch gates

**Bounded move — runs unconditionally, deadline or not** (Step 0). These are two
state writes with no waiting in them, and leaving a gate open is worse than any
overrun: a `/pause` that skipped them would let another thread start new work
while the laptop is closing.

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

**The specialized Monitor teardown below is the first half of terminal move 1**
(Step 0) — the same move as the exact-ID hard-stops further down, not a phase
before them. It runs whether or not the deadline has passed: these are stops and
their bookkeeping writes, never waits, and a Monitor left ticking after the
laptop closes is the exact failure this command exists to prevent. Attempt each
stop within `T_GRACE_END`; a Monitor that cannot be stopped inside that bound is
recorded `stopped: false` and named in Step 8, never retried indefinitely.

Enumerate Monitors in this order and record the result of each stop:

1. **Per-PR babysit watchers** — for each PR where `.prs["N"].babysit.active == true`: delegate to the existing `/babysit-pr-stop <PR>` skill. Record `stopped: true` on success.
2. **PR fleet monitor (`/pr-monitor-and-manage`)** — delegate to `/pr-monitor-and-manage-stop`. Record `stopped: true` on success.
3. **Day-mode loop** — follow the `/pm` 2D.4 teardown order exactly:
   a. `"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.stop_requested=true"`
   b. `TaskStop` the exact recorded `day.monitor_task_id`. Missing ID, or a failed stop → keep `active=true`, retain the ID, record `stopped: false`.
   c. Only after the stop succeeds: `active=false`, `monitor_task_id=null`, `monitor_generation=null`.
4. **Usage-limit auto-wake Monitor** (`day.limit_resume_task_id`) — if the day state block contains a non-null `limit_resume_task_id`, stop it to prevent a double resume after manual `/pause`. **This one entry covers both wake shapes**: 2D.6's sleep-until-reset one-shot and 2D.7's bounded probe Monitor (#1428) record their identity in the same pair, so a pre-emptive park is torn down here with no new monitor class to teach this step about:
   a. Read `day.limit_resume_task_id` with its exit code. If the read is unreadable (non-zero and non-3 exit code), **report the failure** — do not silently skip or claim cleanup succeeded: record `stopped: false` with `owner: "day_limit_wake"` in `monitors_stopped` and name the read failure in the Step 8 report so the user knows the auto-wake Monitor identity could not be confirmed. If the value is null or the state file never existed (exit 3), skip — no Monitor to stop.
   b. `TaskStop` the recorded ID. On success: `"$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.limit_resume_task_id=null"`, `--set ".repos[\"$REPO_KEY\"].day.limit_resume_generation=null"`, and `--set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=-1"` (the probe bound belongs to the wake that was just stopped). **`-1`, not `null`** (#1445): the field is three-valued, and `null` means "the reset time is known — re-arm the sleep-until-reset one-shot", so writing it here would order a later `/pm` recovery to resurrect the very wake this step deliberately stopped. `-1` says what is actually true — the park stands, no bound is in force, no reset time is known — and routes recovery to stay parked and require a manual resume. Record `stopped: true` in `monitors_stopped` with `owner: "day_limit_wake"`.
   c. On failure: keep the ID, record `stopped: false`, and name the task ID in the Step 8 report so the user can stop it manually.
5. **Leave-time wind-down Monitor** (`leave.winddown_task_id`, issue #1525) — if `.repos["$REPO_KEY"].leave` holds a non-null `winddown_task_id`, stop it. A manual `/pause` **is** the wind-down; leaving its scheduled twin armed would fire a second one into a thread that has already parked, against state this run is about to rewrite. Note that a `/pause` reached *through* `/leave-by`'s own check-in finds this pair already null — that path disarms before delegating — so this entry only ever fires on a manual pause, which is exactly when it should:
   a. Read `leave.winddown_task_id` **into `OLD_WINDDOWN_TASK_ID`** with its exit code — the release CAS in `c` names that variable, so the read is what binds it, and reading the pair here (before any write) is also what keeps the `--expect` values from naming a successor's identity:

      ```bash
      OLD_WINDDOWN_TASK_RC=0
      OLD_WINDDOWN_TASK_ID=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].leave.winddown_task_id" 2>/dev/null) \
        || OLD_WINDDOWN_TASK_RC=$?
      OLD_WINDDOWN_GENERATION=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].leave.winddown_generation" 2>/dev/null) \
        || OLD_WINDDOWN_GENERATION=""
      ```

      Unreadable (non-zero and non-3) → **report the failure**: record `stopped: false` with `owner: "leave_winddown"` in `monitors_stopped` and name the read failure in Step 8, so the user knows the wind-down Monitor identity could not be confirmed. Null, or exit 3 (no state file), → skip; there is no Monitor to stop. **An unbound `OLD_WINDDOWN_TASK_ID` is the failure this read exists to prevent:** `jq -R .` on an empty value makes the release CAS in `c` expect `""`, which no stored ID ever equals, so the CAS loses every time — silently, while looking guarded — and the dead ID keeps squatting the slot `/leave-by` Step 6 must later win with `--expect null`.
   b. **Invalidate the generation first, then stop the task** — the same order `/leave-by` Step 9 mandates, for the same reason: `TaskStop` cannot retract a `--checkin` the Monitor has already emitted, so stopping first leaves a queued event that still passes Step 8.1 and starts a *second* `/pause` while this one is mid-teardown. Nulling the token first makes every queued event inert whatever the stop then does. In order:
      1. `INVALIDATE_RC=0; EXPECT_GEN=$( [ -n "$OLD_WINDDOWN_GENERATION" ] && [ "$OLD_WINDDOWN_GENERATION" != "null" ] && printf '%s' "$OLD_WINDDOWN_GENERATION" | jq -R . || printf 'null' ); "$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].leave.winddown_generation=null" --expect "$EXPECT_GEN" >/dev/null 2>&1 || INVALIDATE_RC=$?` — a **CAS on the token read in `a`, never a blind `--set`**: this is the field `/leave-by` Step 6 publishes and Step 8.5 disarms, both under CAS, and `.leave` is repo-scoped state a re-declaration in another session can rewrite between the read and this write. A blind null there wipes a *successor's* generation, and its live Monitor's `--checkin` then fails Step 8.1 and winds nothing down — armed-looking and unable to fire (issue #1525). `INVALIDATE_RC == 7` means a successor already published: stop nothing, clear nothing, record `stopped: false`, and leave the leave time to its new owner. Otherwise retry once on `6` (lock timeout), and **read that exit code**. The ordering above is a safety property only if the null lands: a queued `--checkin` stays valid until the token is gone, so stopping and continuing on a failed write leaves exactly the second-`/pause` nesting this order exists to prevent. On a non-zero `INVALIDATE_RC` after the retry, **stop nothing and clear nothing** — record `stopped: false` with `owner: "leave_winddown"`, name the task ID and the unwritten generation in the Step 8 report, and leave `.leave` as found. Same contract as `/leave-by` Step 9 and `/pause-resume` Step 5.
      2. only then `TaskStop` the leave-time wind-down ID recorded in `winddown_task_id`
      3. on a confirmed stop, release the slot **under a CAS on the ID this step is holding**, never a blind `--set` — and **capture that CAS's exit code before claiming anything**:

         ```bash
         RELEASE_RC=0
         "$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].leave.winddown_task_id=null" \
           --expect "$(printf '%s' "$OLD_WINDDOWN_TASK_ID" | jq -R .)" >/dev/null 2>&1 || RELEASE_RC=$?
         # retry once on 6 (lock timeout)
         ```

         A confirmed stop proves the **Monitor** is gone, not that the slot is still this step's to empty: a re-declaration publishing a new ID during that external call would lose the only record of a live wake, so nothing could name or stop it, and Step 11 would read the null pair as unarmed and start a *second* Monitor. Exit `7` means a successor already holds the slot and there is nothing to release — a clean outcome. **Record `stopped: true` with `owner: "leave_winddown"` only on `RELEASE_RC` `0` or `7`; any other code, after the retry, leaves the stale ID in place**, so report the release failure alongside the confirmed stop rather than a cleanup that did not happen — the two claims are separate, and only the stop is true there. Same contract as `/pause-resume` Step 5, which writes the same field the same way on both its branches.

      Leave `leave.active` and `checkin_epoch` untouched — the declared time still stands, and `/leave-by` Step 11's recovery is what decides whether to re-arm.
   c. On failure: keep the ID, record `stopped: false`, and name the task ID in the Step 8 report.

**A failed `TaskStop` is recorded as `stopped: false` and reported in Step 8.** Never claim a Monitor was stopped when the stop itself was not confirmed. Stopped Monitors are recorded in the `monitors_stopped` array of the pause state block (Step 7).

**Disarm the table-freshness floor by DATA, not by the stop.** A paused round is not an active one, so the hourly floor (`.claude/reference/time-estimates.md` §"Table freshness — the hourly floor") must go quiet here. Use `$TABLE_FRESHNESS_SH`, already resolved in Step 0 alongside every other helper — an inline "resolve it here" is how this call comes to be skipped when the helper is missing, since there is then no Step 0 `DEGRADED:` line to say the floor is unavailable. Run `"$TABLE_FRESHNESS_SH" --clear --repo "$REPO_KEY" --session "${CLAUDE_SESSION_ID:-default}"` — or record the terminal board with `--note-rendered --active 0 --repo "$REPO_KEY" --session "${CLAUDE_SESSION_ID:-default}"`, which does the same job while leaving a readable last render. Both flags are named explicitly, the same pair the watch was armed with: a disarm that addressed a different repo or session would clear a record nothing polls and leave the live one armed. Do this **whether or not** its watch was stopped: the tick reads `active_pipelines` and exits silently at `0`, so clearing the record silences even a watch whose `TaskStop` failed or that no step owned an ID for. Skipping it is what leaves `TABLE FLOOR` lines arriving into a paused session.

Two ways this can degrade, and both stay quiet rather than guessing: an **unresolved helper** → one `DEGRADED:` line, then continue. An **empty `REPO_KEY`** (Step 0 resolved neither remote nor state) → **skip the call entirely** and say so — `DEGRADED: repo key unresolved — table-freshness floor not disarmed` — then continue. Skipping is what makes that a report rather than a lie: calling with an empty key lets the script fall back to the cwd and clear `_unknown`, a no-op that looks like a successful disarm while the real record keeps the floor armed. The pause itself never waits on either.

After the specialized Monitor teardown above, follow
`background-task-shutdown.md` for every registry entry in this session. Give
productive agents, workflows, and background commands the remaining bounded
window to checkpoint; stop them as soon as they finish, and hard-stop exact
remaining IDs at `T_END`. Record output, handoff, worktree, and recovery paths
in `parked`. A failed stop keeps the gates closed and makes the result
incomplete.

**The hard-stop of remaining task IDs is the first move of the
bounded terminal path** (Step 0), so it still runs after the deadline — that is the whole point
of a hard stop. Call `past_deadline` before granting checkpoint time: **if the
deadline has already passed when this step is reached, skip the cooperative
checkpoint interval entirely**, hard-stop by exact ID every remaining productive
task the shutdown contract marks safe to stop, and leave `WINDOW_EXPIRED`
latched true. **The one carve-out is a `/wrap` in flight** — a merge killed
mid-write is the unrecorded state this command exists to prevent, so it is
checkpointed and recorded per Step 5, never stopped where it stands. Selection
of what is safe to stop stays with `background-task-shutdown.md`; the deadline
changes the timing, never the contract. Checkpoint time
is the negotiable part; the stop itself never is. A failed stop still keeps the
gates closed and still makes the result incomplete — the grace path weakens
none of that.

## Step 3: Collect the board

Gather the complete picture of what is in flight. For authorship reasons (`safety.md` §"Authorship"), only PRs authored by `@me` in the current repo are eligible for landing or parking by this session's automation.

Collect:

1. **Open PRs** — `gh pr list --state open --author "@me"` from the current repo.
2. **Running subagents** — the `active_agents` map (keyed by agent id) from `session-state.sh --session-view`. Treat its values as a candidate list, not a fact: an agent in the list may have already completed and written its handoff.
3. **Worktree branches with uncommitted or unpushed work** — check each local worktree for staged/unstaged changes and commits not yet on the remote.

With no `session-state.sh` resolved, collection is limited to what `gh pr list` returns. Report "could not read what was running" for subagents and worktrees rather than "nothing was running".

**Budget check — call `past_deadline` before each collection above, and again
before each worktree in item 3.** Collection is not a terminal move, so it does
not run past `T_END`: **start no new read once the deadline has passed** — no
`gh pr list`, no `session-state` read, no worktree enumeration or status scan.
Finish the read already in progress — then continue through Step 4, which
classifies everything collected `park`, and Step 6, which records those units
without mutation. **Collected results are never routed straight to the terminal
path:** a unit that was read but never classified or recorded is lost exactly
as surely as one never read. What the deadline skips is new reads and every
mutation, never the recording of what is already in hand. In practice this step
runs minutes before the deadline.

**`--window 0` still collects the board.** `T_END == T_START` makes
`past_deadline` true from the first call, so the check above would otherwise
skip every read on the immediate path — which does no landing and no mutation,
making the recorded board its *entire* output. Skipping collection there would
leave the marker holding nothing but Step 2's registry leftovers and strand
every open PR, exactly the "we did not look" rendered as "nothing was there"
that the next paragraph forbids. So the skip is scoped to a window that was
*spent*: it applies when `WINDOW_MINUTES > 0` and the clock ran out, never to
`--window 0`, where the three bounded reads always run. This is what keeps
`--window 0` behavior unchanged from before the ceiling existed.

**What went uncollected is recorded unavailable, never as empty.** This is the
same rule Step 0 states for an unreadable inventory — "we did not look" must
never render as "nothing was there", because an in-flight unit that goes
unlisted is a unit the user cannot resume. Concretely:

- A collection not performed is named in the Step 8 report as unread
  (`PR list unread — deadline`, `worktree scan cut short — N unread`), never
  reported as an empty list.
- Work already known from Step 2's registry teardown is still parked and
  recorded — that inventory is in hand and costs nothing to reuse.
- A worktree enumerated but not scanned gets its own `park` entry, with
  `stopped_at` of `working-tree state unread — deadline` and a `next_move`
  naming the check the resume should run first. It keeps its `issue-N` branch
  name, so `candidate-ownership.sh` still matches it and `/pause-resume`
  re-reads it cold.

Every unit collected still gets a `land` or `park` classification in Step 4.

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

**Budget check — call `past_deadline` once before classifying, again before
each `merge-gate.sh` run, and once more immediately after each returns, before
its result is recorded.** A gate call takes real time, so the deadline can pass
*during* it; without the after-check a `land` verdict earned a moment too late
would be printed as `land` and only corrected at Step 5. Past the deadline
every unit is `park` by
definition: there is no runway left to land anything, so the gate is not worth
querying. Skip the remaining gate calls, then — **in this order** — sweep,
print, and go to Step 6, which records the result without mutation. This is the
same forcing `--window 0` applies, reached by the clock instead of the
argument.

**The sweep reclassifies *every* unit `park`, not only the ones still
unclassified.** The deadline can trip partway through this step, after some
units have already been classified `land`. Because this branch goes straight to
Step 6, it never reaches Step 5's "reclassify every remaining `land` unit
`park`" rule — so a unit left holding `land` here is dispatched by nobody and
recorded by nobody, and it reaches neither the marker nor the pause state.
Sweep the whole board, including units classified earlier in this same pass.

**The sweep itself carries no deadline check, and must not grow one.** It is an
in-memory relabel of units already collected — no `gh` call, no `merge-gate.sh`
run (the budget check above already skipped those), nothing that can block — so
there is no operation here for `T_END` or `T_GRACE_END` to bound. Aborting it
partway would leave exactly the orphaned `land` units it exists to prevent, so
a half-swept board is strictly worse than a late one. The grace bound belongs
to the terminal moves that follow, which own it already.

**Sweep before printing.** The printed classification is this step's contract
with the user (`Every in-flight unit gets exactly one of land | park, stated
with its reason before any action is taken`), so it must show the post-sweep
board — the same one Step 6 consumes. Printing first would announce a `land`
that nothing will ever dispatch.

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

**The window is a budget, not a promise.** Before dispatching each `land` unit, call `past_deadline` (Step 0) — it compares `$(date -u +%s)` against `T_END` and latches `WINDOW_EXPIRED`. A unit that has not reached `merged` by `T_END` is reclassified `park` and recorded at its actual state — never left running on the assumption the user is still watching.

**On the first `past_deadline` true, landing is over.** `WINDOW_EXPIRED` is now
`true`: dispatch nothing further, reclassify every remaining `land` unit `park`,
and record each at its actual state. Step 6 then records those units without
mutation, and the run proceeds to the bounded terminal path.

For each `land` unit, dispatch `/wrap`. Monitor its outcome. If the window
expires while a `/wrap` is still in flight, request its checkpoint and record
its actual boundary, then **stop waiting on it — never hard-stop its runtime
ID.** This is the Step 2 carve-out in full: a merge killed mid-write is exactly
the unrecorded state this command exists to prevent, so an in-flight `/wrap` is
the one productive task the exact-ID hard stop never claims (`pause-state.md`
§Deadline semantics). Reclassify the unit `park` and record it as still in
flight at the boundary, never as finished; `/pause-resume` re-reads GitHub
before deciding whether it still needs work, so a merge that completed after the
window shows up as landed at resume.

A `land` unit that hits a hard stop during `/wrap` (human `CHANGES_REQUESTED`, protection-modifying bypass, etc.) is reclassified `park` immediately and the hard stop is named in its `stopped_at` field.

## Step 6: Park phase

Bring each `park` unit to a deliberate boundary **before** recording it. Per unit, in order:

**Immediate branch (`WINDOW_MINUTES == 0`):** record the state already captured
after the exact-ID hard stop and skip actions 1 and 2 below. Do not post review
replies, run local review, commit, push, or launch any landing/checkpoint work.
Set the boundary to `stopped immediately; no mutation attempted` plus the exact
recovery path. This is the machine-park path and the explicit user fast-stop
path; Step 7 still publishes the marker and JSON state.

**Past-deadline branch (`past_deadline` returns true):** the same shape as the
immediate branch, reached by the clock instead of the argument. **The window is
a budget here too, not a promise** — call `past_deadline` before each unit, and
again before each mutating action within a unit (posting review replies in
action 1; running local review, committing, and pushing in action 2). A unit
reached after `T_END` records the state it is actually in, attempts no
mutation, and sets its `boundary` to `stopped past deadline; no mutation
attempted` plus the exact recovery path. Never start a local review round, a
commit, or a push once the deadline has passed — an unpushed fix recorded
truthfully is recoverable; a shutdown that overran is not.

**Keep the machine-required fields in both branches.** `candidate-ownership.sh`
matches parked entries by regex, so a unit that maps to an issue keeps its
`branch` in `issue-N-*` form and keeps the `#N` reference inside `stopped_at`
or `next_move`. A compact boundary string never costs a unit its identity.

1. **Post pending review replies** — any bot finding that has been addressed but not yet replied to gets a reply now.
2. **Commit and push fixes** — **inside the window only** (`past_deadline` false; past it, the branch above has already recorded the unit unmutated). If the remaining budget before `T_END` allows a local review loop, run it; otherwise skip the review and commit and push anyway — the push is the cheaper half and the one that makes the work recoverable. When a push is impossible (no upstream, auth failure, conflict), say exactly why in the parked entry's `boundary` field: "pushed without local review — window expired", "push failed: no upstream", etc. Never leave fixes only in a worktree when a push was possible inside the window.
3. **Record the stopping point** — fill in `stopped_at` (what state it reached), `next_move` (the next action for resume), `waiting_on` (reviewer | ci | null), and `boundary` (pushed | unpushed with reason).

No half-applied review round: either a round's fixes are all committed and its threads replied, or the entry records exactly which findings were applied and which were not.

For running subagents: record what each was doing, its exact runtime ID, and
where its handoff/output/worktree lives. They must be confirmed terminal before
Step 8 can report completion.

## Step 7: Persist the pause state

Two writes, in this order: **first the marker** (so `MARKER_PATH` is known before the JSON is built), **then the `session-state.sh` write** (which embeds the marker path).

New pauses write only `.repos[<key>].pauses[<session-id>]` state and
`pause-*.md` markers. `/pause-resume` retains read-only support for the
singleton `.pause` and `.suspend` state slots and `suspend-*.md` markers
created before Issues #1310 and #1576; `/pause` never creates new legacy
records.

**The state record is keyed per session (issue #1576).** The old
`.repos[<key>].pause` slot was a repo singleton, so two sessions pausing the
same repo minutes apart silently clobbered each other: the later write replaced
the earlier session's board outright, and that board survived only as its
marker file. A board with unpushed worktrees or re-arm-required Monitors would
have been dropped with no error anywhere. Keying by session ID — the shape
`execution_pauses` already uses — makes each `/pause` its own record, so
concurrency costs nothing and `/pause-resume` can enumerate every un-resumed
board.

### 7a: Write the human-readable marker

**Terminal-path move 2** (Step 0) — it is never skipped for being past the
deadline, and is bounded by `T_GRACE_END` like every terminal move. What the
deadline changes is how much it says, never whether or where it is published;
what `T_GRACE_END` changes is that an unfinished write stops rather than runs
on, leaving `MARKER_PUBLISHED=false` and an `INCOMPLETE SHUTDOWN` report.

Use the same atomic `mktemp` + `mv` publish that `/end` Step 6 uses. Staging inside `$OUT_DIR` keeps `mv` on one filesystem. The marker filename includes the repo key so a resume from a different repo cannot accidentally pick it up as a cross-repo fallback:

```bash
OUT_DIR="$HOME/.claude/handoffs"
MARKER_PUBLISHED=false
MARKER_ERROR=""
if ! mkdir -p "$OUT_DIR"; then
  MARKER_ERROR="mkdir -p $OUT_DIR failed"
fi
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
# One sanitization, two consumers: this same value is the marker filename
# segment below AND the `.pauses[<session-id>]` state key in Step 7b. Sanitizing
# it twice, or in only one of the two places, produces a marker and a state
# record that no longer name each other.
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

#### Compact marker (selected when `WINDOW_EXPIRED` is true)

**The marker step can never be the reason the window blows.** Past the
deadline, write the compact form: everything a machine or a cold reader needs
to recover, and nothing else.

**Kept — non-negotiable, these are what make the marker a recovery artifact:**

- The exact ``Repository: `owner/repo` `` line, first field, unchanged — Step 1
  of `/pause-resume` greps it verbatim for auto-discovery
- The landed list (one merged PR per line), and — because this marker is
  written only when the deadline passed — an explicit line marking it
  provisional: `Window expired: landed list may be incomplete; re-read GitHub`.
  The marker is the fallback index used exactly when `session-state.sh` is
  unreadable, so a resume reading it never sees the JSON `window_expired` flag.
  Dropping this line lets a marker-only resume trust a landed list that a
  `/wrap` finishing after the deadline has already made stale.
- Each parked unit: its identity, its stopping point, its next move, and its
  exact recovery path — keeping the `issue-N` branch and `#N` issue references
  that `candidate-ownership.sh` matches on
- The stopped-task records with their exact recovery paths
- **The stopped-Monitor records** — each entry's owner and whether the stop was
  confirmed. `/pause-resume` re-arms babysit, fleet, and day-mode watchers from
  `monitors_stopped`, and on the marker-only path it has nothing but this
  section to rebuild them from. Dropping it leaves those Monitors stopped with
  no record that they ever existed, which is the one loss a resume cannot
  detect by re-reading GitHub.
- The refill pause status and how to lift it
- The resume command line

**Dropped:** long-form narrative prose, per-unit explanation and rationale,
formatted tables, restated triage reasoning, and any section that exists to
read well rather than to be acted on. Terse lines and fragments are correct
here; polish is the optional output the ceiling spends first.

Everything mechanical stays exactly as above: the atomic `mktemp` + `mv`
publish, the injective `pause-<stamp>-<repokey>-<session>-<tag>.md` filename
encoding, the fallback-path behavior, and the `chmod 644` permissions. A
compact marker is discovered by `/pause-resume` the same way a full one is.

**`WINDOW_EXPIRED` is the only trigger for the compact form** — there is no
second rule. Because `T_GRACE_END` is reachable only after `T_END`, an
approaching grace bound is always already inside the expired path; it tightens
how much the compact marker says, never whether the compact form is chosen.

**The compact marker is always preferred over exceeding `T_GRACE_END`** — pick
the compact form as soon as the path is entered, so the write finishes inside
the bound rather than racing it. **No marker write begins or continues past
`T_GRACE_END`:** check `past_grace` before starting the write and before any
retry of the `mv` publish; if it is already true, do not start one. A write cut
short leaves `MARKER_PUBLISHED=false`, and the existing `INCOMPLETE SHUTDOWN`
handling applies unchanged — report that no artifact exists rather than
claiming a fallback that is not there. Degrading the marker is how the bound is
met; overrunning it is not an available trade.

### 7b: `session-state.sh --set` the `.repos[<key>].pauses[<session-id>]` record

**Terminal-path move 3** (Step 0) — never skipped for being past the deadline,
and its shape does not degrade: the state block is the machine record the whole
command exists to produce. It is bounded by `T_GRACE_END` like every terminal
move: bound the state-lock retry rather than waiting indefinitely, and on
expiry leave `PAUSE_PERSISTED` nonzero and report `INCOMPLETE SHUTDOWN`. `WINDOW_EXPIRED` is initialized `false` in
Step 0 and only ever latched `true`, so it is always a bare `true`/`false` by
the time `jq -n` reads it — `--argjson window_expired` never sees an empty
string.

**This block is invisible to `session-state.sh --session-view`** (that projection lifts only `.prs` and `.root_repo`). Like `refill` and `day`, read it with an explicit `--get` or an armed pause reports as absent. Never inline `jq … > tmp && mv tmp` — that bypasses the state lock (`handoff-files.md`).

**Write the record under this session's key, never the singleton slot.** The
path is `.repos["$REPO_KEY"].pauses["$SESSION_ID"]`, reusing the value Step 7a
already resolved and sanitized — do not re-derive it from `CLAUDE_SESSION_ID`
here, or an unsanitized key will disagree with the marker filename. `--set`
assigns one map entry and preserves its siblings, so a concurrent `/pause` in
another session writes its own key and neither board is lost. A plain `--set` is
the right primitive: there is no claim to win, because two sessions never
contend for one key. `session_id` also goes **inside** the record so a board
read out of the map identifies itself without its key having to be carried
alongside.

`WINDDOWN_PERSISTED` is `1` (success) or `0` (failed) — convert it to a JSON boolean before embedding in the state block:

```bash
PAUSE_PERSISTED=1
if [[ "$MARKER_PUBLISHED" == true && -n "$SESSION_STATE_SH" && \
      -n "$REPO_KEY" && "$REPO_KEY" != "unknown" ]]; then
  [[ "$WINDDOWN_PERSISTED" == "1" ]] && REFILL_PAUSED_BOOL=true || REFILL_PAUSED_BOOL=false
  NOW=$(date -u +%FT%TZ)
  PAUSE_JSON=$(jq -n \
  --argjson active true \
  --arg session_id "$SESSION_ID" \
  --arg paused_at "$NOW" \
  --argjson window_minutes "$WINDOW_MINUTES" \
  --argjson window_expired "$WINDOW_EXPIRED" \
  --argjson landed "$LANDED_JSON" \
  --argjson parked "$PARKED_JSON" \
  --argjson monitors_stopped "$MONITORS_STOPPED_JSON" \
  --argjson background_tasks_stopped "$BACKGROUND_TASKS_STOPPED_JSON" \
  --argjson refill_paused "$REFILL_PAUSED_BOOL" \
  --arg marker_path "$MARKER_PATH" \
    '{active:$active, session_id:$session_id, paused_at:$paused_at,
    window_minutes:$window_minutes, window_expired:$window_expired,
    landed:$landed, parked:$parked,
    monitors_stopped:$monitors_stopped,
    background_tasks_stopped:$background_tasks_stopped,
    refill_paused:$refill_paused, marker_path:$marker_path,
      resumed_at:null}')
  if "$SESSION_STATE_SH" \
       --set ".repos[\"$REPO_KEY\"].pauses[\"$SESSION_ID\"]=$PAUSE_JSON"; then
    PAUSE_PERSISTED=0
  fi
fi
```

If `MARKER_PUBLISHED` is not true, skip the state write because it would embed
a nonexistent marker path. Keep both gates closed, set `PAUSE_PERSISTED` to a
nonzero value, and report `MARKER_ERROR` in Step 8 as `INCOMPLETE SHUTDOWN`.

If `session-state.sh` was not resolved in Step 0, skip this write and set `PAUSE_PERSISTED=1` (failed). Say so in Step 8.

## Step 8: Report

**Terminal-path move 4** (Step 0). Compact, per `CLAUDE.md` #3. No phase-by-phase narration, no progress tables.

```
=== Pause <complete | INCOMPLETE SHUTDOWN> ===
Timing: window <WINDOW_MINUTES>m · elapsed <M>m · grace <used | not used>
        <WINDOW_EXPIRED=true: "skipped to meet the deadline: <what was skipped>">
Stopped: <WINDDOWN_PERSISTED=1: "refill paused (lift with: tell Claude 'resume refilling' in the next session)">
         <WINDDOWN_PERSISTED=0: "COULD NOT record the refill pause — another thread may still start new work">

Landed:
  merged PR #N  (one line per merged PR)
  <nothing landed> only if collection was COMPLETE and the list is empty
  <PR list unread — deadline; landed state unknown> if the PR list was PARTIAL or SKIPPED

Parked (<N> units):
  PR #M — <stopped_at> · next: <next_move> · waiting on: <waiting_on>
  Subagent <kind> — handoff at <path>
  <nothing parked> only if collection was COMPLETE and the list is empty
  <subagent list unread — deadline> if item 2 was PARTIAL or SKIPPED
  <worktree scan cut short — N unread> if item 3 was PARTIAL
  <board not collected — deadline; N sources unread> if collection was SKIPPED

Monitors stopped: <N stopped of M total; any not-stopped named here>
Background tasks stopped: <N stopped of M total; exact unresolved IDs named here>

Resume state: <PAUSE_PERSISTED=0: "stored in session state; marker at $MARKER_PATH">
              <PAUSE_PERSISTED!=0 and MARKER_PUBLISHED=true: "session state failed; marker fallback at $MARKER_PATH">
              <MARKER_AUTO_DISCOVERABLE=false and MARKER_PUBLISHED=true: "repository identity unavailable; resume explicitly with /pause-resume --marker $MARKER_PATH">
              <MARKER_PUBLISHED=false: "NO recovery artifact was published — manual recovery required; $MARKER_ERROR">

Resume with: <MARKER_AUTO_DISCOVERABLE=true: "/go-on [--resume-refill]   (routes to /pause-resume; call it directly if you prefer)">
             <MARKER_AUTO_DISCOVERABLE=false: "/pause-resume --marker $MARKER_PATH [--resume-refill]   (an undiscoverable marker cannot be classified, so /go-on cannot route it)">
```

**An empty list is never printed for a source that was not read.** Step 3's
rule — "we did not look" must never render as "nothing was there" — binds the
report and the marker, not just the prose: `<nothing landed>` and `<nothing
parked>` assert a board was collected and found empty, so they are reserved for
that case alone.

**Collection has three outcomes, tracked separately from whether it ran at
all** — the budget check fires before each source and again before each
worktree, so it can stop partway:

- **Complete** — every source in Step 3 was read. Only here may an empty list
  print `<nothing landed>` / `<nothing parked>`.
- **Partial** — some sources read, others cut short. **Track it per source**
  (Step 3's three items), not as one flag for the whole board, and render each
  unread source in the section that would otherwise have shown its results —
  even when what *was* read came back empty. An unread PR list makes the
  `Landed:` section unknown, not empty; unread agents or worktrees do the same
  to `Parked:`.
- **Skipped** — the deadline had already passed at Step 3, so nothing was read.

Neither a reader nor a marker-only `/pause-resume` can then mistake an unread
or half-read board for a clean idle session. The compact marker carries the
same three-way distinction on the same terms.

**The `Timing:` line is always printed**, on-time runs included — an overrun
should be visible in the transcript without a stopwatch. Elapsed is
`$(date -u +%s) - T_START` rounded to the nearest minute; `grace used` when the
run passed `T_END`, `not used` otherwise. Report the elapsed time actually
measured — never the window as if it were the outcome.

**When `WINDOW_EXPIRED` is true, name what was skipped** on the second line, in
the command's own terms: `landing cut short (N units reclassified park)`,
`park mutations skipped on N units`, `long-form marker prose dropped`,
`worktree scan cut short — N unread`. Name the work that did **not** happen — the compact
marker was written, so it is never listed as skipped; what was dropped is its
prose. A run that met its deadline by doing less says so; silently doing less
is the failure this line exists to prevent.

**Truthful reporting is not weakened by the grace path.** Every
`INCOMPLETE SHUTDOWN` condition below binds exactly as before — meeting the
deadline is never a reason to call an incomplete shutdown complete, and
`window_expired` is a note about scope, never an excuse for an unstopped task.

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
