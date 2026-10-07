---
name: desk
description: "Use when you want one place to answer every question your agent threads ask — the human queue's control session. Registers this session as the desk, ticks the queue on a persistent Monitor, shows waiting Decisions as menus or long-form prompts, lets you discuss one, writes the answers, and wakes each asking thread."
triggers:
  - desk
  - open the desk
  - human queue
  - answer the queue
argument-hint: "[--cadence Nm]"
---

# /desk — the human queue's control session

The desk is the operator's single point of contact (`desk/DESIGN.md` 2.3, 2.6). Worker threads' questions are captured into the store by the capture hook (`desk/README.md`, "Capture hook") and render **only here**, as the same clickable menus a normal session shows. Answers go to the store; the asking thread gets a pointer and reads the store.

The hook queues a question only while a desk is **live**: a registered control session whose last tick is at most 15 minutes old. Running `/desk` is what makes it live, so the steps below are exact — a desk that believes it is ticking and is not leaves every worker's questions with nobody to show them to.

**This file is a router.** It owns starting the desk, the Monitor, its events, and the end-of-turn gate. Each kind of work lives in its own file, loaded when it is needed:

| File | Owns | Issue |
|------|------|-------|
| `decisions.md` | Simple Decisions: sets, menus, replies, answers, wake-ups | #1779 |
| `longform.md` | Long-form and multipart Decisions: one text prompt at a time, part by part, answers stored word for word | #1780 |
| `discuss.md` | `discuss <n\|D-id>`: talk one item through with its context loaded, then answer it | #1780 |
| `desk.jq` | The functions both views call: which Decisions fit a menu, multipart groups, the long-form and discussion cards | #1779, #1780 |
| `wakeups.md` | Wake-up retries on the next three ticks, then `answer-parked`, shown once | #1781 |
| `history.md` | `show D-<n>` (an item's sub-thread) and `history` (today's answered items), printed without a state line | #1781 |
| `priorities.md` | `top`, `bump`, `park`, `drop`, `priorities`: the operator's backlog order for `/pm`, kept in the target repo's `.claude/pm-priority.json` | #1767 |
| `reviews.md` | The Reviews view: `reviews` (one line per unreviewed item, by day and repo), `open R-<n>` (level 2, cached), `diff R-<n> [path]` (level 3, live), `reviewed`, `reviewed all today`, `flag`, and `follow up` | #1782 |

## The prelude (every Bash call)

Shell state does not survive between Bash calls, so every block below starts with this prelude. The desk runs in any directory, so it resolves its own folder only from installed locations, never from the current checkout:

<!-- test-anchor: desk-prelude -->

```bash
DESK=""
for c in "${HUMAN_QUEUE_DESK_DIR:-}" "$HOME/.claude/skills-worktree/desk"; do
  if [ -n "$c" ] && [ -x "$c/bin/desk-cli.sh" ]; then DESK="$c"; break; fi
done
if [ -z "$DESK" ]; then
  echo "ERROR: desk/bin/desk-cli.sh not found (checked \$HUMAN_QUEUE_DESK_DIR and ~/.claude/skills-worktree/desk) — the desk is unavailable"
fi
HQ="$DESK/bin/desk-cli.sh"
SKILL_SID="${CLAUDE_SESSION_ID}"
SID="${SKILL_SID:-${CLAUDE_CODE_SESSION_ID:-}}"
SESSION_STATE_SH=""
for c in "$HOME/.claude/skills-worktree/.claude/scripts/session-state.sh" "$HOME/.claude/scripts/session-state.sh"; do
  if [ -x "$c" ]; then SESSION_STATE_SH="$c"; break; fi
done
```

- `HQ` is `human-queue.sh` with the store's URL found the way the capture hook finds it (the app's Bash and Monitor do not source your shell profile). It never prints the URL. Exit **7** from any call means the store is unreachable.
- `SID` is this session's id **as the capture hook sees it** (the hook input's `session_id`). `${CLAUDE_SESSION_ID}` is the skill's own substitution when the harness provides it; `CLAUDE_CODE_SESSION_ID` is the same id from the environment. Never use `CLAUDE_CODE_HOST_SESSION_ID` (the app's `local_…` id) here: the hook would not recognise it, and would deny the desk's own menus.
- `SESSION_STATE_SH` empty → `DEGRADED: session-state.sh not found (checked both paths) — the desk's Monitor identity is not recorded, continuing without it`. Keep the task id and generation in this conversation instead, and skip every `"$SESSION_STATE_SH"` call below (steps 4 and 7, the `replaced` event, the end-of-turn gate's step 3): with it empty, the call would run `--get-json` or `--set` as a command and fail.

## Start: `/desk [--cadence Nm]`

1. **Prelude.** `DESK` or `SID` empty → say so in one line and stop. Nothing is armed.
2. **Cadence.** `--cadence Nm`, a whole number of minutes, default 5, and **shorter than the live-desk bound**: the capture hook queues only while the last tick is at most that old (15 minutes unless `desk/policy.json` sets `live_desk_max_tick_age_min`), so a cadence at or past it leaves the desk stale between ticks and worker menus render in their own threads again. `desk-tick.sh` enforces it (1 to 60, and below the bound it reads through the hook's own policy parser): step 5 passes the cadence, so a bad one stops the start there with exit 4 and one line naming the bound. Anything that is not a whole number → one line naming the range, and stop.
3. **Migrate**, then **register** this session:

   <!-- test-anchor: desk-start -->

   ```bash
   "$HQ" migrate && "$HQ" register-control "$SID"
   ```

   - `migrate` is idempotent and applies any migration a merge added (the desk needs `005_wake_events.sql` and `006_answer_parked.sql`, and the Reviews view `007_reviews_summary_l1.sql`).
   - Exit 7 → `Desk not started: the store is unreachable (<the CLI's one line>).` and stop. Exit 1 or 4 → the same shape with that line. **Do not arm anything** and never say the desk is live.
   - `control session <SID> (replaces <OTHER>)` → another desk was registered; it stops ticking on its own at its next cycle (`desk-tick.sh` exits on `replaced`). Mention it in the start line.
4. **Stop an earlier loop of this session** (a second `/desk` in the same thread): read `.desk` with `"$SESSION_STATE_SH" --get-json .desk` (with `SESSION_STATE_SH` empty, skip the read and use the task id this conversation holds, if any). When its `session` is `SID` and it names a `monitor_task_id`, `TaskStop` that task first. A `TaskStop` failure on a task that no longer exists is fine; any other failure → keep the old identity, say so in one line, and stop.
5. **Tick once, inline**, with a new generation. This stamps the tick time, which is what makes the desk live from this moment:

   <!-- test-anchor: desk-first-tick -->

   ```bash
   GEN="desk-$(date -u +%Y%m%dT%H%M%SZ)-$$"
   "$DESK/bin/desk-tick.sh" --session "$SID" --generation "$GEN" --cadence <N> --once; echo "GEN=$GEN"
   ```

   An `error` line → the same "not started" report as step 3, and stop. Exit 4 → the cadence (or another argument) was refused: report its one stderr line as "not started", and stop. Nothing is armed.
6. **Arm the Monitor** with `persistent: true`, description `Desk tick`, and the longest `timeout_ms` the tool allows. Its command, with `DESK`, `SID`, `GEN`, and the cadence written in literally:

   ```bash
   "<DESK>/bin/desk-tick.sh" --session "<SID>" --generation "<GEN>" --cadence <N>
   ```

   The loop sleeps first (the inline tick was this cycle). Each cadence it confirms this session is still the control session, runs `tick` and `wake-due`, and prints a line only when there is something to do (see "Monitor events").
7. **Record the identity at once.** An unrecorded Monitor cannot be stopped by a later turn:

   ```bash
   "$SESSION_STATE_SH" --set ".desk={\"session\":\"$SID\",\"generation\":\"$GEN\",\"monitor_task_id\":\"<TASK_ID>\",\"cadence_minutes\":<N>,\"armed_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
   ```

   - Arming failed (no task id) → `Desk not started: the Monitor did not arm.` Leave `.desk` unwritten.
   - `SESSION_STATE_SH` empty (the prelude's DEGRADED line) → skip this write and keep `TASK_ID`, `GEN`, and the cadence in this conversation. That is the degraded mode, not a failure: the desk starts.
   - Arming worked but this write failed → `TaskStop` the task id you hold now, then report the desk as not started. If that `TaskStop` also fails, name the task id in the message so the operator can stop it.
8. **Show what is already waiting.** The first tick reports only what changed since the last desk ticked, so read the whole backlog once: `"$HQ" list --kind decision --status open --json`, and hand it to `decisions.md` ("Showing items"). With nothing waiting, the start report is one line: `Desk live — nothing waiting; ticking every <N> min.`

## Monitor events

Each stdout line of the loop arrives as a notification. A line whose generation is not the recorded `.desk.generation` (or the `GEN` in this conversation) comes from a superseded loop: ignore it silently.

| Line | Do |
|------|----|
| `desk-tick <GEN> new D-43 D-44` | Load `decisions.md` and follow "Showing items" for those ids. While a long-form prompt waits for its reply, hold them instead (`longform.md`, "Tick events while a prompt waits") |
| `desk-tick <GEN> retry D-43 D-44` | Answers whose last wake-up failed, each due a retry. Load `wakeups.md` and follow "A `retry` event" at once, even while a long-form prompt waits: a retry shows nothing unless an answer parks |
| `desk-tick <GEN> replaced` | Another session registered as the desk. The loop has exited. Write `.desk=null` (skip with `SESSION_STATE_SH` empty), say `The desk moved to another session; this one has stopped ticking.`, and arm nothing |
| `desk-tick <GEN> error <cmd> exit <n>: <line>` | One line, action first: `Desk can't reach the store (<cmd> exit <n>) — still retrying every <N> min; once the last tick is older than the live-desk bound (15 min by default), worker threads show their own menus again.` The loop keeps going |
| `desk-tick <GEN> recovered` | One line: `Store reachable again — desk live.` |
| The Monitor exited or expired | Re-arm: steps 5–7 with a new generation (no new registration; `register-control` is only for start) |

A quiet tick prints nothing, and the desk says nothing about it.

## Replies the operator types

Read each operator message in this order:

1. **`show D-<n>`** or **`history`** (`history <YYYY-MM-DD>`), as the whole message → load `history.md`. This works at any time, including while a long-form prompt waits or during a discussion, and stores nothing.
   **A priority command** (`top: #a #b`, `bump #N`, `park #N until <date>`, `drop #N`, `priorities`, each optionally ending `in <repo>`), as the whole message → load `priorities.md`. The same holds: any time, and nothing goes to the store.
   **A Reviews verb** as the whole message — `reviews` (`reviews since <YYYY-MM-DD>`), `open R-<n>`, `diff R-<n> [path]`, `reviewed` (`reviewed R-<n>`, `reviewed all today`), `flag R-<n> "…"`, or `follow up R-<n>` → load `reviews.md`. Also at any time; a waiting long-form prompt keeps waiting and is shown again after. Interrupts, policy, and feedback tags (#1783) and the day plan and end-of-day sweep (#1784) have no verb here yet.
2. **`discuss`**, `discuss <n>`, or `discuss D-<id>` → load `discuss.md`.
3. **A long-form prompt waits for its reply** → load `longform.md` and follow "Replies to a long-form prompt": the whole message is that item's answer, stored word for word, unless it is `skip`, `discuss …`, or a `D-<n>:` reply for another item.
4. **A message that starts with an item number or an id followed by a colon** is a reply: `2: B`, `1: A, 2: C`, `D-43: B`, `1: yes, but after CI; 3: use staging`. Load `decisions.md` and follow "Typed replies".
5. Any other message is ordinary conversation.

## End-of-turn gate (STOP before ending any desk turn)

`scheduling-reliability.md`'s pre-exit checklist, made concrete for the desk. Run it before every turn of this session ends, including turns that only rendered a menu:

<!-- test-anchor: desk-end-of-turn -->

```bash
"$HQ" control-status --json
```

1. **Ticking, not just armed.** The JSON's `session` is `SID` and `tick_age_seconds` is at most the cadence in seconds plus 60. Arming is not ticking: the inline tick at start or a loop tick must have run. Too old → run the step 5 inline tick now, and if the Monitor has exited, re-arm (steps 5–7).
2. **The Monitor is live.** The recorded `monitor_task_id` is still running (no exit or expiry notice since it was armed). Not running → re-arm.
3. **State recorded.** `"$SESSION_STATE_SH" --set ".desk.last_tick_at=\"<last_tick_at from the JSON>\"" --set ".desk.checked_at=\"<now, UTC>\""`. With `SESSION_STATE_SH` empty, skip it (degraded mode).
4. **Output.** Say something only for a blocker, a failed first wake-up (`decisions.md`; a failed retry stays quiet), a parked answer's one-time notice (`wakeups.md`), a menu or long-form prompt the operator must answer, or a reply to what the operator just typed (a discussion card and its follow-ups, `discuss.md`; a stored-answer or left-open line; `show` or `history` output, `history.md`) — never a routine "still watching", and never a state line nobody asked for.

If 1 or 2 cannot be fixed (the store is down, the Monitor will not arm), say so in one line. Never end a turn claiming the desk is watching when either check failed.

Background work in flight still follows `scheduling-reliability.md` item 1 (`bgwork-ceiling.sh --check`): the desk's Monitor does not replace the ceiling watch.
