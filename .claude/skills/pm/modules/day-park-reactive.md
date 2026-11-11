<!-- pm-routing:begin -->
Route `day:park-reactive`. Read after a verified structured account-cap signal in a day turn. The pre-emptive route can read this phase when it reaches shared gate and wake handling. A successful resume tick reads only the cleanup subsection before D5.
<!-- pm-routing:end -->
### 2D.6: Usage-limit park and wake

**When the harness or API reports a usage-limit error during any day-mode turn** — an error explicitly indicating the account's rolling window or weekly cap is exhausted, paired with or without a reset time — run this section before the turn ends. This is an explicit upstream signal; `safety.md` §Anthropic Quota & Spend Authority still forbids acting on locally-computed token counts.

**Signal detection.** A usage-limit signal is a structured API error whose runtime classification explicitly indicates an account cap — `error_type == "rate_limit_error"`, `error.type == "rate_limit_error"`, or an equivalent vendor-supplied error code field that names account-level exhaustion, not context-window exhaustion. Text matching alone (e.g. "out of tokens", "weekly limit") is not sufficient, because those phrases can appear in context-window exhaustion errors or other upstream messages. Require the structured classification first; then extract the reset time from the confirmed signal text only — never from local token accounting. If no structured error type is present, do not treat the event as an account-cap exhaustion.

**Classify the horizon.** Parse the reset epoch from the signal. Validate `signal_reset_epoch` as a numeric integer strictly greater than `NOW_EPOCH` before using it — empty, zero, past, or non-numeric values all fall back to the 60-minute default (rolling-window classification):

```bash
NOW_EPOCH=$(date -u +%s)
# Validate: must be a non-empty integer strictly greater than NOW_EPOCH
if [[ "${signal_reset_epoch:-}" =~ ^[0-9]+$ ]] && \
   (( signal_reset_epoch > NOW_EPOCH )); then
  RESET_EPOCH="$signal_reset_epoch"
else
  RESET_EPOCH=$(( NOW_EPOCH + 3600 ))
fi
HORIZON_SECONDS=$(( RESET_EPOCH - NOW_EPOCH ))

# Rolling window: horizon <= 8 hours (covers the 5-hour rolling window with margin)
# Weekly/long: > 8 hours
LIMIT_KIND="rolling_window"
[ "$HORIZON_SECONDS" -gt $(( 8 * 3600 )) ] && LIMIT_KIND="weekly"
PARKED_UNTIL=$(date -u -d "@$RESET_EPOCH" +%FT%TZ 2>/dev/null || \
               date -u -r "$RESET_EPOCH" +%FT%TZ)
```

**Park.** A rolling-window limit is temporary and auto-resuming, so run the
`/pause` mechanics with `--window 0`. Run Step 1's execution-gate activation
(`execution-pause.sh --activate --command pause --window-minutes 0`) before
Steps 2–7, but skip only Step 1's `.refill.paused` write. That field is
human-owned; an automatic machine-initiated park must not touch it because the
auto-wake would otherwise clear a pause the user explicitly set. The execution
gate stays closed throughout task shutdown and marker publication.
A weekly limit is the long-horizon token/credit case and follows `/end` in the
weekly branch below. After the selected wind-down steps complete, read the
current `consecutive_limit_hits` and increment it:

```bash
HITS_RC=0
PRIOR_HITS=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.consecutive_limit_hits") || HITS_RC=$?
[ "$HITS_RC" -eq 3 ] && PRIOR_HITS=0   # no state file — first limit hit ever

# Fail closed on any other unreadable state: a corrupt or lock-timed count cannot
# be safely reset to 0 — doing so would let thrash guards be bypassed.
# The block below must terminate this section; nothing after it — NEW_HITS computation,
# state writes, or Monitor arming — may execute when this condition is true.
if [[ "$HITS_RC" -ne 0 && "$HITS_RC" -ne 3 ]]; then
  echo "Parked (usage limit) — consecutive_limit_hits unreadable (rc=$HITS_RC); staying parked to avoid thrash. Resume manually."
  return  # EXIT this section — do not compute NEW_HITS, write state, or arm a Monitor
fi
[[ "$PRIOR_HITS" =~ ^[0-9]+$ ]] || PRIOR_HITS=0
NEW_HITS=$(( PRIOR_HITS + 1 ))
MAX_LIMIT_HITS=3  # mirrors max_pipeline_failures range; not currently user-configurable
```

**Claim the park slot rather than overwriting one (#1428, #1622).** A real kill can land while 2D.7 — or a subagent-running thread (`subagent-thread-limit-park.md` §2) — has already parked the board. Every one of those paths writes these same fields, so a plain write here would replace `parked_until` and the cause and null the wake identity pair, stranding a live Monitor that nothing can name to `TaskStop`. So the reactive path does not write a park; it **claims** one, by the same compare-and-set on `limit_cause` that 2D.7 Step 3 and the subagent leg already use. `limit_cause` is null until exactly one path claims it, and the whole record rides that single compare (`--cas` composed with `--set`, #1445), so there is no window between owning the slot and finishing the metadata:

The winning claim emits `PARK_GENERATION`. Carry that exact binding into wake publication; do not fetch it from a later record. Missing entropy/helper fails closed before a claim. Completed parks retain this durable identity until retirement (#1715).

<!-- test-anchor: pm-day-2d6-park-claim -->

```bash
PARK_GENERATION_SH=""
for candidate in "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/park-generation.sh}" "${HOME:+$HOME/.claude/scripts/park-generation.sh}"; do
  if [ -x "$candidate" ]; then PARK_GENERATION_SH="$candidate"; break; fi
done
PARK_GENERATION=""
PARK_CLAIM_RC=0
if ! [[ "${NEW_HITS:-}" =~ ^[0-9]+$ ]]; then
  # The thrash guard is only a guard if the counter is a number. An unset NEW_HITS
  # writes an empty string, which the `[[ =~ ^[0-9]+$ ]] || PRIOR_HITS=0` coercion
  # above then reads back as a reset streak — so MAX_LIMIT_HITS could never bite.
  # Same guard, same reason, as 2D.7 Step 3.
  echo "PARK_CLAIM=error rc=hits"
elif [ -z "$PARK_GENERATION_SH" ] || ! PARK_GENERATION=$("$PARK_GENERATION_SH"); then
  echo "PARK_CLAIM=error rc=generation"
else
  # ONE invocation, one lock hold, all-or-nothing (#1445): the cause CAS gates the
  # eight metadata writes riding with it, so a competing park either loses this
  # compare (exit 7, nothing written) or already owns the record. There is no
  # interleaving that leaves half of ours mixed into half of theirs. Every --set
  # path is a SIBLING of the CAS path under `.day`; naming an ancestor of it is a
  # usage error (exit 2), not a write.
  # Nulling `park_claim_token` (#1596) is what makes this claim RETIRE any 2D.7
  # claim in flight, in the same atomic write that takes the slot from it — so
  # that claim's later finalisation and release both exit 7 instead of writing
  # over the record we just won.
  "$SESSION_STATE_SH" \
    --cas ".repos[\"$REPO_KEY\"].day.limit_cause=\"reactive\"" --expect null \
    --set ".repos[\"$REPO_KEY\"].day.parked_until=\"$PARKED_UNTIL\"" \
    --set ".repos[\"$REPO_KEY\"].day.limit_kind=\"$LIMIT_KIND\"" \
    --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=null" \
    --set ".repos[\"$REPO_KEY\"].day.consecutive_limit_hits=$NEW_HITS" \
    --set ".repos[\"$REPO_KEY\"].day.park_claim_token=null" \
    --set ".repos[\"$REPO_KEY\"].day.park_generation=\"$PARK_GENERATION\"" \
    --set ".repos[\"$REPO_KEY\"].day.limit_resume_task_id=null" \
    --set ".repos[\"$REPO_KEY\"].day.limit_resume_generation=null" \
    >/dev/null 2>&1 || PARK_CLAIM_RC=$?
  case "$PARK_CLAIM_RC" in
    0) echo "PARK_GENERATION=$PARK_GENERATION"; echo "PARK_CLAIM=won" ;;
    7) echo "PARK_CLAIM=adopted" ;;   # 2D.7, or a subagent thread, parked first
    *) echo "PARK_CLAIM=error rc=$PARK_CLAIM_RC" ;;
  esac
fi
```

- **`won`** → the slot is ours. Continue to the thrash guard and the wake below.
- **`adopted`** (exit 7) → a park already exists and the path that opened it owns the wake. **Adopt it:** write nothing further, arm no Monitor, and do **not** `TaskStop` anything — that wake belongs to the surviving record, and stopping it would leave a park with no wake at all. The wind-down already run above is not wasted: a kill has landed, so the board belongs stopped either way. One line, then stop this section — `Parked (usage limit) — the board is already parked; adopting that park and its wake.`
- **`error`** (any other rc, `rc=hits` included) → fail closed exactly as the unreadable-count branch above does: park nothing, arm nothing, and say so in one line naming the rc — `Parked (usage limit) — park record could not be written (rc={RC}); not arming auto-wake. Resume manually.`

**Why nulling the identity pair on a win is a safe no-op.** A win means `limit_cause` was null, and every path that publishes a wake identity — the auto-wake below, 2D.7 Step 4, the subagent leg's §4 — writes `limit_cause` **before** it publishes. A null cause therefore proves no wake is armed, so the two nulls in the claim restate a resting value rather than orphaning a Monitor. The third null, `park_claim_token`, is the opposite case and is doing real work: a null cause is exactly the window in which a 2D.7 claim may be mid-assembly, and retiring its token here is what stops that claim from finishing over the record this write just created.

**The one record that pair-without-cause can survive on is already wakeless.** `limit_resume_task_id` predates `limit_cause` in the schema (#1288 vs #1428), so a `session-state.json` last written by a pre-#1428 skill can carry a live-looking identity pair with no cause at all, and this CAS wins against it. That is still not a stranding, for two independent reasons. A record that old is by construction *cross-session* — its Monitor died with the session that armed it, so there is nothing left for a `TaskStop` to name and nothing for the nulls to orphan. And the identity pair is not how a park is recovered: 2D.1(b+) and 2D.5 re-arm from `parked_until`, `limit_kind`, `limit_cause` and `limit_probe_fires_remaining`, never from `limit_resume_task_id`, which exists solely to stop a Monitor that is live *in this session*. The win also replaces `parked_until` with the reset time from the kill that just fired — a fresher bound than the stale one it retires — and arms this section's own wake over it. So the invariant the paragraph above states for in-session paths is not merely unbroken by legacy state; legacy state is the case where nulling the pair is most obviously free.

**Why the `TaskStop`-before-write guard is gone (#1622).** It used to stop whatever wake was armed before the reactive write nulled its ID, on the reasoning that a vendor reset time beats 2D.7's probe bound and so the reactive record should win on content. Under `--expect null` that sequence is not merely redundant, it is incompatible: a claim lost *after* a successful stop would have killed a wake the surviving park still needed, with no ID left anywhere to re-arm it. Whichever path claims `limit_cause` first now owns the record, and the loser adopts — the same contract 2D.7 and the subagent leg already keep. Rationale: `.claude/reference/pm-day-mode.md`.

**Thrash guard.** Only a `won` claim reaches this point — `adopted` and `error` both stop above, as does an unreadable `HITS_RC` (non-zero and non-3). If `NEW_HITS >= MAX_LIMIT_HITS`, stay parked permanently and notify, with no auto-wake:

> Parked (usage limit) — {NEW_HITS} consecutive limit hits on resume; staying parked to avoid a hot loop. Resume manually when the window reopens.

**Auto-wake (rolling window only, when `NEW_HITS < MAX_LIMIT_HITS`).** Arm one persistent `Monitor` that sleeps until the reset time plus a 2-minute buffer, fires once, then breaks. The fire command passes the generation so `/pause-resume` can reject a stale or duplicate wake. Do **not** pass `--resume-refill` — the automatic park did not write `.refill.paused`, so the wake must not clear it:

If wind-down used the entire delay, start a fresh two-minute sleep. After the sleep, the one-shot waits briefly for its exact wake identity to be published. Bind the verified absolute `SESSION_STATE_SH` path, `REPO_KEY`, and the captured `PARK_GENERATION` into the Monitor with its delay and wake generation. A replacement park or wake ends this Monitor's attempt. If publication cannot be verified within the bounded wait, report that the park needs manual resume.

<!-- test-anchor: pm-day-2d6-reactive-wake-delay -->

```bash
WAKE_SLEEP=$(( RESET_EPOCH - $(date -u +%s) + 120 ))  # reset + 2 min buffer
if [ "$WAKE_SLEEP" -le 0 ]; then WAKE_SLEEP=120; fi
# Exponential backoff for consecutive hits: 2^(NEW_HITS-1) * WAKE_SLEEP minimum
BACKOFF_MULT=$(( 1 << (NEW_HITS - 1) ))
WAKE_SLEEP=$(( WAKE_SLEEP * BACKOFF_MULT < WAKE_SLEEP ? WAKE_SLEEP : WAKE_SLEEP * BACKOFF_MULT ))
LIMIT_GENERATION="limit-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
# One-shot Monitor: wait for both the reset delay and the published identity.
sleep "$WAKE_SLEEP" || exit 0
for ((WAKE_CHECK=0; WAKE_CHECK<=12; WAKE_CHECK++)); do
  WAKE_ROUTE=unreadable
  if WAKE_STATE=$("$SESSION_STATE_SH" --repo "$REPO_KEY" --get-json ".repos[\"$REPO_KEY\"].day" 2>/dev/null); then
    WAKE_ROUTE=$(jq -r --arg park "$PARK_GENERATION" --arg wake "$LIMIT_GENERATION" '
      if type != "object" then "unreadable"
      elif .park_generation != $park or .limit_cause != "reactive" or .limit_kind != "rolling_window"
      then "superseded"
      elif .limit_resume_generation == $wake and
        (.limit_resume_task_id | (type == "string" and length > 0 and . != "null") or
          (type == "number" and . >= 0 and . <= 9007199254740991 and floor == .))
      then "ready"
      elif .limit_resume_generation == null and .limit_resume_task_id == null then "pending"
      else "superseded" end' <<< "$WAKE_STATE") || WAKE_ROUTE=unreadable
  fi
  case "$WAKE_ROUTE" in
    ready) printf '%s\n' "/pause-resume --generation $LIMIT_GENERATION"; break ;;
    superseded) break ;;
  esac
  if [ "$WAKE_CHECK" -eq 12 ]; then
    printf '%s\n' 'PM day wake could not verify publication. The park is still active. Resume manually with /pause-resume.'
    break
  fi
  sleep 10 || break
done
```

Record the task ID immediately — an unrecorded Monitor cannot be stopped. The shared helper checks the completed park and the empty identity pair, then publishes both fields in one full-day compare-and-set (#1713):

<!-- test-anchor: pm-day-2d6-wake-publish -->

```bash
# TaskStop is the harness tool; stop only the Monitor this invocation armed.
WAKE_PUBLISH_SH=""
for candidate in "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/park-wake-publish.sh}" "${HOME:+$HOME/.claude/scripts/park-wake-publish.sh}"; do
  if [ -x "$candidate" ]; then WAKE_PUBLISH_SH="$candidate"; break; fi
done
PUBLISH_RC=4
if [ -n "$WAKE_PUBLISH_SH" ]; then
  PUBLISH_RC=0
  "$WAKE_PUBLISH_SH" --repo "$REPO_KEY" --cause reactive \
    --task-id "$LIMIT_MONITOR_TASK_ID" --generation "$LIMIT_GENERATION" \
    --park-generation "${PARK_GENERATION:-}" --task-encoding json-or-string --state-helper "$SESSION_STATE_SH" >/dev/null || PUBLISH_RC=$?
fi
if [ "$PUBLISH_RC" -eq 0 ]; then
  echo "WAKE_PUBLISH=armed"
elif TaskStop "$LIMIT_MONITOR_TASK_ID"; then
  if [ "$PUBLISH_RC" -eq 7 ]; then echo "WAKE_PUBLISH=lost"; else echo "WAKE_PUBLISH=failed"; fi
else
  echo "WAKE_PUBLISH=stranded"
fi
```

Only `armed` permits the automatic-resume promise below. `lost` means the park was retired/replaced or another wake won; ours is stopped, so say nothing. On `failed`, ours was stopped but registration is unverified: `parked (usage window) — could not register a wake; resume with /pause-resume.` On `stranded`, surface the ID: `parked (usage window) — could not stop the unrecorded wake {LIMIT_MONITOR_TASK_ID}; stop it manually.` Do not unconditionally clear park metadata after a failed publication; it may belong to a newer writer.

**Weekly/long horizon — no auto-wake.** Do not invoke the user-only `/end`
command. Instead, execute `/end/SKILL.md` Steps 0–6 inline as the internal
weekly-stop procedure, using its default 5-minute window and the authoritative
usage-limit signal already classified above. This shares the gate, checkpoint,
exact-ID shutdown, audit, and handoff mechanics without pretending a user
invoked the command or estimating quota. Write `parked_until` and
`limit_kind="weekly"`. Do not arm a Monitor; do not write
`limit_resume_task_id`. One-line notify:

> Stopped — weekly cap reached; continuing would incur overage charges. Window reopens at {PARKED_UNTIL}. Resume manually with `/end-resume --resume-refill` when ready.

**Heartbeat lines (always the last output from this section):**
- Rolling window, only after `WAKE_PUBLISH=armed`: `parked until {PARKED_UNTIL} — usage window; resuming automatically`. Use the failure/stranded diagnostic above otherwise; a lost publication stays silent.
- Weekly: `stopped — weekly cap reached; awaiting manual resume`

**On a successful resume** (tick completes without hitting a limit): reset `consecutive_limit_hits = 0` and clear `parked_until`, `limit_kind`, `limit_cause`, `limit_probe_fires_remaining`, `park_claim_token`, `park_generation`, `limit_resume_task_id`, `limit_resume_generation` and `limit_resume_stop_proofs` in one write before D5's heartbeat fires. Clearing the cause and the probe bound together with the rest is what stops a later recovery from re-arming a probe wake for a park that has already ended; clearing the token with them is what returns the slot to a state a fresh claim can win, and leaving a spent one behind would make the next claim's token indistinguishable from a stale predecessor's.

**That clear is compare-and-set on the identity it read (#1663)** — the same contract `/pause-resume` Step 5's `retire_limit_park` keeps, written once in `.claude/reference/pm-day-mode.md` §"The park-retirement contract". The exposure here is the empty slot: by the time this runs `parked_until` is usually null, and a 2D.7 Step 1 claim from a sibling thread (or the subagent leg) wins that slot on `--cas parked_until --expect null` and publishes its token in the window between this step's read and its write. An unconditional clear then erases a park that had just been legitimately opened, along with its bound and its wake identity — leaving a live Monitor nothing can name to `TaskStop`.

<!-- test-anchor: pm-day-d5-resume-clear -->

```bash
# ONE read, bound: the anchor and the verdict must come from the same instant, or
# the CAS pins to a record this step never saw.
D5_SNAPSHOT_RC=0
D5_SNAPSHOT=$("$SESSION_STATE_SH" --get-json ".repos[\"$REPO_KEY\"].day" 2>/dev/null) \
  || D5_SNAPSHOT_RC=$?
D5_CLEAR_RC=0
if [[ "$D5_SNAPSHOT_RC" -ne 0 && "$D5_SNAPSHOT_RC" -ne 3 ]]; then
  D5_CLEAR_RC=8                      # unreadable identity: fail closed, clear nothing
else
  [[ "$D5_SNAPSHOT_RC" -eq 3 ]] && D5_SNAPSHOT=null
  D5_EXPECT=$(printf '%s' "$D5_SNAPSHOT" | jq -c '
if (. == null or type == "object") and
  (.park_generation == null or
   ((.park_generation | type) == "string" and (.park_generation | length) > 0 and .park_generation != "null"))
then . else error("invalid durable park identity") end
' 2>/dev/null) || D5_CLEAR_RC=8
fi
if [[ "$D5_CLEAR_RC" -eq 0 ]]; then
  PARK_RETIRE_SH=""
  for candidate in "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/park-retire.sh}" "${HOME:+$HOME/.claude/scripts/park-retire.sh}"; do
    if [ -x "$candidate" ]; then PARK_RETIRE_SH="$candidate"; break; fi
  done
  D5_CLEAR_RC=4
  if [[ -n "$PARK_RETIRE_SH" ]]; then
    D5_CLEAR_RC=0
    "$PARK_RETIRE_SH" --repo "$REPO_KEY" --snapshot "$D5_EXPECT" \
      --state-helper "$SESSION_STATE_SH" --reset-hits || D5_CLEAR_RC=$?
  fi
fi

case "$D5_CLEAR_RC" in
  0) echo "RESUME_CLEAR=cleared" ;;
  7) echo "RESUME_CLEAR=superseded" ;;   # a newer park owns the slot — nothing written
  *) echo "RESUME_CLEAR=error rc=$D5_CLEAR_RC" ;;
esac
```

- **`cleared`** → the park is retired and the thrash counter reset; carry on to D5's heartbeat.
- **`superseded`** (exit 7) → a park claimed the slot after this step read it. **Nothing was written**, so its bound, kind, token and wake identity are intact and its owner runs its own recovery. Do not retry, do not `TaskStop` anything, and do not reset the counter; the board is parked again, so drop this tick's resume heartbeat and emit the park's own line instead — `Parked (usage limit) — a new park opened while this resume was landing; adopting it and its wake.`
- **`error`** (any other rc, `8` = unreadable identity included) → fail closed: the park record is left exactly as found, in one line naming the rc — `Resume clear failed (rc={RC}) — park record left standing; resume manually if the board stays parked.`

**Disarm on manual resume.** When `/pause-resume` is invoked manually while a limit-wake Monitor is armed, the skill disarms the Monitor before delegating to `/pm day resume` — see `/pause-resume` Step 5. This prevents a double resume when both paths race. **That same step retires the park** — the park fields and durable generation above, one write — and has to (#1595): 2D.1(b+) and 2D.5 stay parked on a `preemptive` cause with a `0`/`-1` bound *regardless of* `parked_until` and stop recovery before 2D.2's init write, which is the only other place the park is cleared. A resume that merely restamped the sentinel could therefore never lift the park those branches tell the user to lift exactly this way.

