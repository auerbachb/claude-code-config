<!-- pm-routing:begin -->
Route `day:park-preemptive`. Read on D2 critical or on a typed probe wake. Read day:park-reactive only where this phase calls its shared gate or wake procedure.
<!-- pm-routing:end -->
### 2D.7: Usage-horizon pre-emptive park (#1428)

**Trigger:** D2's horizon gate set `HORIZON_PARK=true` (verdict `critical`). Run this before the tick ends, then stop the tick. Nothing else triggers it — `approaching` only stops refill, and `unknown` is a posture, never a park.

The difference from 2D.6 is *when*, not *what*: no error has fired yet, so there is still runway to land near-done work, and there may be no vendor reset time to sleep until. Everything else is 2D.6's machinery, reused by reference — the execution gate, `/pause` Steps 2–7 with checkpoints, the same park fields and thrash guard, the same generation-tagged wake in the same `limit_resume_task_id` registry, the same teardown and recovery paths. **Do not add a second park record, a second wake class, or a second resume route.**

**Knobs** (env override; shipped defaults otherwise). The validation is **executed in Step 1's block below**, not left to this table — it falls back to the shipped default and names the rejected input on stderr, exactly as the preamble does for `--cadence`. A documented range that no code enforces is not a range:

| Value | Default | Env | Accepted |
|-------|---------|-----|----------|
| Landing window for the park | `2` minutes | `CLAUDE_HORIZON_PARK_WINDOW_MINUTES` | `^[0-9]{1,6}$` — **`0` is legal** and selects reactive parity |
| Probe cadence | `30` minutes | `CLAUDE_HORIZON_PROBE_CADENCE_MINUTES` | `^[0-9]{1,6}$` **and `> 0`** |
| Probe fire bound | `12` fires | `CLAUDE_HORIZON_PROBE_MAX_FIRES` | `^[0-9]{1,6}$` **and `> 0`** |

The two probe knobs reject zero for concrete reasons, not tidiness: a cadence of `0` makes the Monitor's `sleep 0` a hot loop firing a turn as fast as the harness allows — the runaway this whole park exists to avoid, at the worst possible moment — and a bound of `0` arms a wake whose first fire immediately reads the bound as spent, so the board parks with a Monitor that can only ever stop itself. The window knob is the opposite case: `0` is the documented way to ask for 2D.6's exact behavior.

**Step 1 — Claim the park, before shutting anything down.** Exactly one park record may exist. A real kill can already have parked the board through 2D.6 microseconds earlier; claiming first means a lost race costs nothing, while shutting down first and *then* losing would leave a stopped board with no park record and no wake. `session-state.sh --cas` decides it under one lock hold (exit `7` is a clean loss, distinct from I/O failure):

Keep both winning outputs, `PARK_CLAIM_TOKEN` and `PARK_GENERATION`, across tool calls. Completion retires only the transient token; the durable generation remains the authority for wake publication and retirement (#1715).

<!-- test-anchor: pm-day-2d7-park-claim -->

```bash
# Knobs resolve HERE, in executable code. The table above documents them; it cannot
# enforce them. Bash arithmetic turns an unset or zero probe knob into 0, which makes
# PARK_EPOCH equal NOW_EPOCH below — and every reader in this skill treats a
# non-future parked_until as "the park resolved or never existed". The board would
# wind down while its own durable record says it is not parked.
# Every accepted knob is normalised through `10#` (#1619 review). `^[0-9]+$`
# admits a leading zero and `[ 08 -gt 0 ]` accepts it, but `$(( 08 * … ))` below is
# an OCTAL context and dies with "value too great for base" — leaving RESET_EPOCH
# empty and PARKED_UNTIL garbage, the exact silent half-park these knobs guard.
# `08` also reaches session-state.sh as a JSON number, which jq rejects.
# The digit bound is the same guard aimed at magnitude (#1619 review). A bare
# `^[0-9]+$` accepts a 20-digit knob that `10#` then WRAPS SILENTLY — rc 0, no
# error: `$(( 10#99999999999999999999 ))` is 7766279631452241919, and one more
# `* 60` lands on 0. That is a non-future PARKED_UNTIL, which every reader in
# this file treats as "the park resolved or never existed" — the same silent
# half-park by a different road. Six digits is ~1.9 years of minutes.
PARK_WINDOW_MIN=2; PROBE_CADENCE_MIN=30; PROBE_MAX_FIRES=12
if [ -n "${CLAUDE_HORIZON_PARK_WINDOW_MINUTES:-}" ]; then
  if [[ "$CLAUDE_HORIZON_PARK_WINDOW_MINUTES" =~ ^[0-9]{1,6}$ ]]; then
    PARK_WINDOW_MIN=$(( 10#$CLAUDE_HORIZON_PARK_WINDOW_MINUTES ))   # 0 is legal — reactive parity
  else
    echo "horizon: rejected CLAUDE_HORIZON_PARK_WINDOW_MINUTES='$CLAUDE_HORIZON_PARK_WINDOW_MINUTES' — using 2" >&2
  fi
fi
if [ -n "${CLAUDE_HORIZON_PROBE_CADENCE_MINUTES:-}" ]; then
  if [[ "$CLAUDE_HORIZON_PROBE_CADENCE_MINUTES" =~ ^[0-9]{1,6}$ ]] && [ "$CLAUDE_HORIZON_PROBE_CADENCE_MINUTES" -gt 0 ]; then
    PROBE_CADENCE_MIN=$(( 10#$CLAUDE_HORIZON_PROBE_CADENCE_MINUTES ))
  else
    echo "horizon: rejected CLAUDE_HORIZON_PROBE_CADENCE_MINUTES='$CLAUDE_HORIZON_PROBE_CADENCE_MINUTES' — using 30" >&2
  fi
fi
if [ -n "${CLAUDE_HORIZON_PROBE_MAX_FIRES:-}" ]; then
  if [[ "$CLAUDE_HORIZON_PROBE_MAX_FIRES" =~ ^[0-9]{1,6}$ ]] && [ "$CLAUDE_HORIZON_PROBE_MAX_FIRES" -gt 0 ]; then
    PROBE_MAX_FIRES=$(( 10#$CLAUDE_HORIZON_PROBE_MAX_FIRES ))
  else
    echo "horizon: rejected CLAUDE_HORIZON_PROBE_MAX_FIRES='$CLAUDE_HORIZON_PROBE_MAX_FIRES' — using 12" >&2
  fi
fi

NOW_EPOCH=$(date -u +%s)
# Reset time from a vendor-classified notice, when one is in hand; otherwise the
# probe bound (cadence x fires) is the conservative outer edge of the park.
if [[ "${HORIZON_RESET_EPOCH:-}" =~ ^[0-9]+$ ]] && (( HORIZON_RESET_EPOCH > NOW_EPOCH )); then
  PARK_EPOCH="$HORIZON_RESET_EPOCH"; PARK_RESET_KNOWN=true
else
  PARK_EPOCH=$(( NOW_EPOCH + PROBE_CADENCE_MIN * PROBE_MAX_FIRES * 60 )); PARK_RESET_KNOWN=false
fi
PREEMPTIVE_PARKED_UNTIL=$(date -u -d "@$PARK_EPOCH" +%FT%TZ 2>/dev/null || date -u -r "$PARK_EPOCH" +%FT%TZ)
# The probe bound is not written until Step 3, and the shutdown between here and
# there takes up to the landing window. Stamping the sentinel WITH the claim — one
# atomic write, `--cas` composed with `--set` (#1445) — is what keeps that gap from
# reading as a known reset: `null` means exactly that everywhere else, so leaving it
# null here would tell a restart inside the window to re-arm a sleep-until-reset
# one-shot against a `parked_until` that is really the fabricated cadence x fires edge.
if [ "$PARK_RESET_KNOWN" = true ]; then CLAIM_FIRES=null; else CLAIM_FIRES=-1; fi
# The claim's identity (#1596). `parked_until` cannot name this claim — with a
# known reset a reactive kill computes the same instant — and neither can
# `limit_cause`, which stays null through the whole assembly window and so is
# equally null under a SECOND pre-emptive claim that reused a slot ours was
# released from. The token is unique per claim, so every later mutation of this
# record can compare against it and a stale one matches nothing.
# Uniqueness has to come from the nonce, not from the timestamp and PID: those
# two collide the moment a PID is reused inside the same second, and a single
# `$RANDOM` leaves only 15 bits behind them. Draw 64 bits from /dev/urandom, and
# fall back to `$RANDOM` draws only where it is unreadable — an EMPTY
# nonce is the one shape to avoid, since Step 3 reads an empty token as "this
# step lost the claim" and would fail closed on a claim that actually won.
# The fallback renders FOUR draws as fixed-width hex (`%04x` — `$RANDOM` is
# 0-32767, so exactly four hex digits each): 60 bits, and the same 16-char
# lowercase-hex SHAPE the /dev/urandom path produces. Both matter. The width
# is why the fallback is not a narrower, variable-length nonce that every
# shape assertion downstream would have to special-case — three decimal
# draws run 3-15 characters and would sometimes read as narrower than a
# single draw. `printf` cannot yield an empty string, so the never-empty
# guarantee above holds on this path too.
PARK_CLAIM_NONCE=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
[ -n "$PARK_CLAIM_NONCE" ] || PARK_CLAIM_NONCE=$(printf '%04x%04x%04x%04x' \
  "${RANDOM:-0}" "${RANDOM:-0}" "${RANDOM:-0}" "${RANDOM:-0}")
PARK_CLAIM_TOKEN="park-$(date -u +%Y%m%dT%H%M%SZ)-$$-$PARK_CLAIM_NONCE"

PARK_GENERATION_SH=""
for candidate in "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/park-generation.sh}" "${HOME:+$HOME/.claude/scripts/park-generation.sh}"; do
  if [ -x "$candidate" ]; then PARK_GENERATION_SH="$candidate"; break; fi
done
PARK_GENERATION=""
PARK_CLAIM_RC=0
if [ "$PARK_EPOCH" -le "$NOW_EPOCH" ]; then
  # Refuse rather than claim: a deadline that is not in the future is indistinguishable
  # from no park at all, so claiming one would shut the board down invisibly.
  echo "PARK_CLAIM=error rc=window"
elif [ -z "$PARK_GENERATION_SH" ] || ! PARK_GENERATION=$("$PARK_GENERATION_SH"); then
  echo "PARK_CLAIM=error rc=generation"
else
  # The kind rides the claim too, because the token turns the assembly window
  # into a state recovery can NAME (2D.1(b+)) rather than one it must refuse: a
  # pre-emptive park is always rolling_window, and leaving the field null until
  # Step 3 would route an in-progress claim to the weekly-cap branch.
  "$SESSION_STATE_SH" \
    --cas ".repos[\"$REPO_KEY\"].day.parked_until=\"$PREEMPTIVE_PARKED_UNTIL\"" \
    --expect null \
    --set ".repos[\"$REPO_KEY\"].day.park_claim_token=\"$PARK_CLAIM_TOKEN\"" \
    --set ".repos[\"$REPO_KEY\"].day.park_generation=\"$PARK_GENERATION\"" \
    --set ".repos[\"$REPO_KEY\"].day.limit_kind=\"rolling_window\"" \
    --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=$CLAIM_FIRES" \
    >/dev/null 2>&1 || PARK_CLAIM_RC=$?
  case "$PARK_CLAIM_RC" in
    0) echo "PARK_GENERATION=$PARK_GENERATION"; echo "PARK_CLAIM_TOKEN=$PARK_CLAIM_TOKEN"; echo "PARK_CLAIM=won" ;;
    7) echo "PARK_CLAIM=lost" ;;   # a park record already exists — 2D.6 got there first
    *) echo "PARK_CLAIM=error rc=$PARK_CLAIM_RC" ;;
  esac
fi
```

**Carry `PARK_CLAIM_TOKEN` into Steps 2 and 3.** It is the only thing that
proves a later write belongs to *this* claim, so a step that lost it must not
guess: Step 3 fails closed on an empty token rather than reporting a
supersession that did not happen.

- **`won`** → continue to Step 2.
- **`lost`** → the board is already parked and a wake is already armed or being armed by the path that won. **Do nothing else**: no shutdown, no second write, no second Monitor, no second chat line. Stop the tick.
- **`error`** (a write failure, or `rc=window` — a deadline that is not in the future) → fail closed exactly as 2D.6 does on an unreadable count: park nothing, arm nothing, shut nothing down, and say in one line that the horizon read critical but the park record could not be written, so manual wind-down is needed. A shutdown with no durable record is the one outcome worse than not parking.

**Step 2 — Wind down through the existing pause mechanics.** Activate the execution gate (`execution-pause.sh --activate --command pause --window-minutes "$PARK_WINDOW_MIN"`), then run `/pause` Steps 2–7 with `--window "${PARK_WINDOW_MIN}m"`, **skipping only Step 1's `.refill.paused` write** — the same carve-out 2D.6 makes, for the same reason: that field is human-owned, and an automatic wake that cleared it would lift a pause the user set by hand.

**Why a non-zero window here when 2D.6 uses `--window 0`.** The window is the one parameter that differs, and it differs because the situations do: 2D.6 runs *after* the account is already refusing work, so there is nothing to land and `/pause` Steps 4–5 are skipped; 2D.7 runs while calls still succeed, and landing a PR that is one merge away is the entire reason to fire before the wall instead of after it. Two minutes is deliberately small — a budget, not a promise, enforced by `/pause`'s own `T_END` check, which reclassifies any unit that has not landed by then as `park` rather than leaving it running. Setting `CLAUDE_HORIZON_PARK_WINDOW_MINUTES=0` selects exact reactive parity.

**If the shutdown aborts** before Step 3 persists the rest of the record, release the claim through the block below, so the board is not left reading as parked with no wake, and the kind and the `-1` stamped with the claim retire with it in the same atomic write:

<!-- test-anchor: pm-day-2d7-park-release -->

```bash
PARK_RELEASE_RC=0
if [ -z "${PARK_CLAIM_TOKEN:-}" ]; then
  # No token means no proof of ownership, and a release that cannot prove
  # ownership is exactly the clobber this gate exists to stop. Say so; clear nothing.
  echo "PARK_RELEASE=error rc=token"
else
  "$SESSION_STATE_SH" \
    --cas ".repos[\"$REPO_KEY\"].day.park_claim_token=null" --expect "\"$PARK_CLAIM_TOKEN\"" \
    --set ".repos[\"$REPO_KEY\"].day.parked_until=null" \
    --set ".repos[\"$REPO_KEY\"].day.park_generation=null" \
    --set ".repos[\"$REPO_KEY\"].day.limit_kind=null" \
    --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=null" \
    >/dev/null 2>&1 || PARK_RELEASE_RC=$?
  # Exit 6 is a lock timeout and documented as retryable (`handoff-files.md`),
  # so retry it once rather than abandoning the claim: an unretried release
  # leaves this session's own token standing over a park nothing in this
  # session will clear. Retrying is safe because the guard is a compare-and-set
  # on that token — a retry after a release that did land matches nothing and
  # reports 7 (clear nothing), never a second clobbering write. Only 6 retries;
  # every other non-zero rc stays an error, unretried.
  if [ "$PARK_RELEASE_RC" = "6" ]; then
    PARK_RELEASE_RC=0
    "$SESSION_STATE_SH" \
      --cas ".repos[\"$REPO_KEY\"].day.park_claim_token=null" --expect "\"$PARK_CLAIM_TOKEN\"" \
      --set ".repos[\"$REPO_KEY\"].day.parked_until=null" \
    --set ".repos[\"$REPO_KEY\"].day.park_generation=null" \
      --set ".repos[\"$REPO_KEY\"].day.limit_kind=null" \
      --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=null" \
      >/dev/null 2>&1 || PARK_RELEASE_RC=$?
  fi
  case "$PARK_RELEASE_RC" in
    0) echo "PARK_RELEASE=released" ;;
    7) echo "PARK_RELEASE=superseded" ;;   # the slot is not ours any more — clear nothing
    *) echo "PARK_RELEASE=error rc=$PARK_RELEASE_RC" ;;
  esac
fi
```

**Gate the release on your claim token, not on your own timestamp and not on `limit_cause` (#1596).** Expecting `parked_until` to still equal `$PREEMPTIVE_PARKED_UNTIL` looks like it identifies your own claim, and with an unknown reset it nearly does. With a *known* reset it does not: `PARK_EPOCH` is then the vendor reset epoch, and a reactive kill parking off the same signal computes the same instant — so the two paths write a byte-identical timestamp and the release matches a park that is not yours. `limit_cause=null` fixed that collision but has one of its own, in the other direction: the field is null through this claim's entire assembly window, so it is *equally* null under a **second pre-emptive claim** that opened after ours was cleared. A release still in flight from the first claim then matches the second one's slot and clears a live park. The token has neither collision — it is unique per claim, and every competing parker retires it in the same atomic write that takes the slot (2D.6's reactive claim and the subagent leg's §2 both carry `--set park_claim_token=null`). So a reactive park, a sibling thread's park, or a second pre-emptive claim all take this release to exit 7 — clear nothing, stand down — while an abort with no competing park clears the claim it actually made.

**Step 3 — Finish the park record, re-checking ownership.** Read and increment `consecutive_limit_hits` exactly as 2D.6 does, including its fail-closed exit when the count is unreadable and its `MAX_LIMIT_HITS=3` thrash guard (at the cap: stay parked, no wake, notify). A pre-emptive park is always `rolling_window` — the horizon verdict measures the rolling window's runway and carries no weekly-cap classification, and **weekly caps remain the reactive path's business and stay manual-resume**.

**Winning Step 1 is not a licence to finish.** The shutdown between them takes up to the landing window, and a real kill can fire inside it: 2D.6 then rewrites the park with a vendor reset time and arms its own wake. A plain `--set` here would overwrite that winner's `limit_cause` and probe bound, and Step 4 would then arm a *second* Monitor over its identity — the double-wake this issue exists to prevent. So ownership is re-taken by compare-and-set on **the claim token Step 1 minted** (#1596) — **and the whole record rides that one compare** (`--cas` composed with `--set`, #1445), so there is no window between re-taking ownership and finishing the metadata:

<!-- test-anchor: pm-day-2d7-park-record -->

```bash
if [ "$PARK_RESET_KNOWN" = true ]; then PROBE_FIRES=null; else PROBE_FIRES="$PROBE_MAX_FIRES"; fi
RECORD_RC=0
if ! [[ "${NEW_HITS:-}" =~ ^[0-9]+$ ]]; then
  # The thrash guard is only a guard if the counter is a number. An unset NEW_HITS
  # writes an empty string, which 2D.6's own `[[ =~ ^[0-9]+$ ]] || PRIOR_HITS=0`
  # coercion then reads as a reset streak — so MAX_LIMIT_HITS could never bite.
  echo "PARK_RECORD=error rc=hits"
elif [ -z "${PARK_CLAIM_TOKEN:-}" ]; then
  # A lost token is a BUG, not a supersession, and the two demand opposite
  # handling: `superseded` says another park is in place and ends the sub-step
  # silently, while this leaves Step 1's claim standing with nothing to finish
  # it. `--expect ""` would compare an empty string against a real token, match
  # nothing, and report exactly the wrong one of those. Fail closed instead.
  echo "PARK_RECORD=error rc=token"
else
  # ONE invocation, one lock hold, all-or-nothing: the token CAS gates the four
  # metadata writes riding with it, so a competing parker either loses this compare
  # (exit 7, nothing written) or already owns the record. There is no interleaving
  # that can leave half of ours mixed into half of theirs. Clearing the token here
  # is what lets recovery tell a COMPLETED park from an in-progress claim.
  "$SESSION_STATE_SH" --cas ".repos[\"$REPO_KEY\"].day.park_claim_token=null" \
    --expect "\"$PARK_CLAIM_TOKEN\"" \
    --set ".repos[\"$REPO_KEY\"].day.limit_cause=\"preemptive\"" \
    --set ".repos[\"$REPO_KEY\"].day.limit_kind=\"rolling_window\"" \
    --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=$PROBE_FIRES" \
    --set ".repos[\"$REPO_KEY\"].day.consecutive_limit_hits=$NEW_HITS" \
    >/dev/null 2>&1 || RECORD_RC=$?
  if [ "$RECORD_RC" -eq 7 ]; then
    echo "PARK_RECORD=superseded"   # another parker took the slot mid-shutdown — write nothing, arm nothing
  elif [ "$RECORD_RC" -ne 0 ]; then
    echo "PARK_RECORD=error rc=$RECORD_RC"
  else
    echo "PARK_RECORD=written"
  fi
fi
```

`superseded` ends the sub-step: the surviving record and its wake are already in place and are the better ones, so 2D.7 says nothing and arms nothing. Note that it now covers **two** losses, not one — a reactive or sibling park that retired our token when it claimed the slot, and a second pre-emptive claim holding a different token — and neither needs to be told apart here, because the response to both is identical.

**Why the ownership re-read is gone.** It used to be load-bearing: `session-state.sh` locked each invocation, not a sequence of them, so winning the ownership CAS and completing the metadata write were two lock holds with a reactive kill able to land between them — and re-reading the claimed field was the only way to notice. #1445 made one invocation able to carry a `--cas` **and** its `--set` writes under that single hold, all-or-nothing, so the two-lock-hold window it guarded against no longer exists: exit 7 *is* the supersession signal, and exit 0 means the whole record is ours. A re-read after an atomic write would answer a question nothing can ask any more, while adding a lock hold and a failure mode of its own. The token (#1596) is what the compare is *on*; it does not reintroduce a read-then-act step, because the read and the act are the same invocation.

**Any `PARK_RECORD=error` must undo Step 1's claim.** By this point the board is already stopped, so simply arming nothing would leave the worst state available: `parked_until` durably set, no cause, no bound, and no wake. The half-record used to *read as a different park* as well — `limit_probe_fires_remaining` null is what recovery uses to mean "reset time known, re-arm the sleep-until-reset one-shot", against a `parked_until` that is really the fabricated cadence×fires outer edge. Step 1's `-1` closes that half: the record now says "no bound, no known reset" from the first instant, so recovery stays parked instead of re-arming the wrong wake. The rest still has to be undone — the claim's `rolling_window` kind and its token would otherwise leave a claim standing that nothing will ever finish. So on any non-zero: run the **`pm-day-2d7-park-release` block above** verbatim (the same token gate, for the same collision reasons, so no park that landed meanwhile is ever clobbered; the kind and the sentinel retire in the same atomic write), then surface one line — `parked pre-emptively (usage horizon) — park record could not be written (rc={RC}); board is stopped and will not wake itself. Resume with /pause-resume.` A `PARK_RELEASE=superseded` there is not a second error: it means another park now owns the slot, so there was nothing of ours left to undo. A silent half-park is the one outcome this whole step exists to prevent.

**Step 4 — Arm exactly one wake, in the existing registry.**

Both branches bind the same two variables — `WAKE_GENERATION` (minted here) and `WAKE_TASK_ID` (returned by the arming call) — so the publish below is identical either way:

- **Reset time known** (`PARK_RESET_KNOWN=true`): arm 2D.6's sleep-until-reset one-shot verbatim — same `while sleep … printf '/pause-resume --generation …'; break; done` shape, same reset-plus-2-minute buffer, same `2^(hits-1)` backoff — with `WAKE_GENERATION` in 2D.6's `limit-…` form.
- **Reset time unknown:** arm **one persistent** `Monitor` at the probe cadence. It re-invokes this skill, which is what lets the session re-read the harness counter — a Monitor cannot read the context by itself, so the fire has to come back through a turn:

  ```bash
  WAKE_GENERATION="probe-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
  while sleep "$(( PROBE_CADENCE_MIN * 60 ))"; do
    printf '%s\n' "/pm day --probe-wake --day-generation $WAKE_GENERATION"
  done
  ```

Either way, publish the identity pair **immediately** into the same fields `/pause` Step 2 item 4 and 2D.6 already read — through the shared publication helper (#1713). It requires the expected completed park and an empty identity pair, then self-compares the whole captured day while composing both identity writes in the same lock hold (#1445). A retired record cannot pass merely because its wake slot is null; competing publishers cannot overwrite each other. It also requires the original winning `PARK_GENERATION` (#1715); never fetch a replacement generation after arming:

<!-- test-anchor: pm-day-2d7-wake-publish -->

```bash
# TaskStop is the harness tool; stop only the Monitor this invocation armed.
WAKE_PUBLISH_SH=""
for candidate in "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/park-wake-publish.sh}" "${HOME:+$HOME/.claude/scripts/park-wake-publish.sh}"; do
  if [ -x "$candidate" ]; then WAKE_PUBLISH_SH="$candidate"; break; fi
done
PUBLISH_RC=4
if [ -n "$WAKE_PUBLISH_SH" ]; then
  PUBLISH_RC=0
  "$WAKE_PUBLISH_SH" --repo "$REPO_KEY" --cause preemptive \
    --task-id "$WAKE_TASK_ID" --generation "$WAKE_GENERATION" \
    --park-generation "${PARK_GENERATION:-}" --task-encoding string --state-helper "$SESSION_STATE_SH" >/dev/null || PUBLISH_RC=$?
fi
if [ "$PUBLISH_RC" -eq 0 ]; then
  echo "WAKE_PUBLISH=armed"
elif TaskStop "$WAKE_TASK_ID"; then
  if [ "$PUBLISH_RC" -eq 7 ]; then echo "WAKE_PUBLISH=lost"; else echo "WAKE_PUBLISH=failed"; fi
else
  echo "WAKE_PUBLISH=stranded"
fi
```

The three non-`armed` outcomes are not interchangeable, and only one of them is silent:

- **`lost`** (rc 7) — the park was retired/replaced or another path published its wake first; ours is stopped and nothing was written. Say nothing.
- **`failed`** — publication failed or could not be verified and ours is stopped. A metadata-only compare loss while the same park still lacks a wake is failure too, so it cannot leave an unarmed park silently. Surface it: `parked pre-emptively (usage horizon) — could not register a wake; resume with /pause-resume.`
- **`stranded`** — the stop itself failed, so a Monitor is live that nothing can name. Surface the ID: `parked pre-emptively (usage horizon) — could not stop the unrecorded wake {WAKE_TASK_ID}; stop it manually.`

That is the whole teardown story: the probe wake is not a new monitor class, it is the existing one with a different sleep, so manual `/pause` stops it, `/pause-resume` disarms it, and a stale fire is rejected by the same generation check.

**Step 5 — The probe fire (`--probe-wake`).** Validate the generation, re-observe the counter, then resume or decrement. The bound lives in state, not in the loop, so a session restart re-arms with the fires that are left rather than a fresh twelve:

<!-- test-anchor: pm-day-2d7-probe-fire -->

```bash
GEN_RC=0
STORED_GEN=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.limit_resume_generation") || GEN_RC=$?
if [ "$GEN_RC" -ne 0 ] && [ "$GEN_RC" -ne 3 ]; then
  # Only rc 3 (no state file) is legitimately "no generation". A lock timeout is
  # contention — likeliest precisely when a fleet is hammering this file — and reading
  # it as `stale` would exit silently AND spend no fire, so the bound never advances.
  echo "PROBE=fail-closed"
elif [ -z "$STORED_GEN" ] || [ "$STORED_GEN" = null ] || [ "$TICK_GENERATION" != "$STORED_GEN" ]; then
  echo "PROBE=stale"                    # superseded Monitor: no resume, no write, no output beyond this
else
  FIRES_RC=0; DEC_RC=0
  FIRES=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining") || FIRES_RC=$?
  if [ "$FIRES_RC" -ne 0 ] || ! [[ "$FIRES" =~ ^[0-9]+$ ]]; then
    # Unreadable, or the `-1` sentinel (#1445) — a fire arriving against a bound
    # that is not in force is exactly as untrustworthy as one against garbage, and
    # the non-negative-integer pattern already rejects both. Stay parked, surface it.
    echo "PROBE=fail-closed"
  elif [ "$HORIZON_STATUS" = clear ]; then
    echo "PROBE=resume"                 # window replenished -> /pause-resume --generation "$STORED_GEN"
  elif [ "$FIRES" -le 1 ]; then
    "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=0" || DEC_RC=$?
    [ "$DEC_RC" -eq 0 ] && echo "PROBE=exhausted" || echo "PROBE=fail-closed"
  else
    # The decrement IS the bound. `|| true` here would report a fire that was never
    # recorded, so every later fire re-reads the same count, `exhausted` is never
    # reached, and the Monitor probes forever — the runaway this park exists to avoid.
    "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.limit_probe_fires_remaining=$(( FIRES - 1 ))" || DEC_RC=$?
    [ "$DEC_RC" -eq 0 ] && echo "PROBE=continue" || echo "PROBE=fail-closed"
  fi
fi
```

`HORIZON_STATUS` comes from re-running D2's horizon block (observe, then `--check`) at the top of the fire — the same gate, so `unknown` cannot resume any more than it can park. Only `clear` resumes: `approaching` means the window has begun refilling but has not recovered, and resuming there walks straight back into the wall the thrash guard exists to prevent.

- `PROBE=resume` → invoke `/pause-resume --generation "$STORED_GEN"`, which validates the token, reopens the gate, and re-arms the day loop through `/pm day resume`. **Never pass `--resume-refill`** — this park never wrote `.refill.paused`.
- `PROBE=exhausted` / `PROBE=fail-closed` → `TaskStop` the recorded Monitor, null `limit_resume_task_id` and `limit_resume_generation`, leave the park in place, and surface one line: `probe wake exhausted after {N} checks — still parked; resume manually with /pause-resume`. Silence here would be a board that never comes back and never says so.
- `PROBE=stale` → exit silently, exactly as D0 does for a superseded tick.

**Step 6 — Chat surfacing.** Two lines on park, one on resume. On park, emit the two lines below only after `WAKE_PUBLISH=armed`. For `failed` or `stranded`, use the Step 4 diagnostic instead; for `lost`, say nothing. An absent or unreadable publication result is failure, never permission to promise automatic resume. On resume, use the resume line below.

```
parked pre-emptively (usage horizon) — landed #1421, checkpointed #1430 (Phase B), 2 queued
window reset unknown — probing every 30m, up to 12 checks (through 05:12 AM ET)
```

With a known reset the second line is 2D.6's shape instead (`resuming automatically at {PARKED_UNTIL}`). On resume: `resumed (usage window replenished) — day loop re-armed`.

**Recovery and teardown parity.** 2D.1(b+) and 2D.5 already gate on `parked_until` + `limit_kind`; both now also read `limit_cause` and `limit_probe_fires_remaining` so a restart re-arms the *right* wake: a known reset (`limit_probe_fires_remaining` null) re-arms the sleep-until-reset one-shot with the remaining time, and a pre-emptive park with fires left re-arms the probe Monitor with that count. Zero fires left, `-1`, a weekly kind, or an unreadable value all take the existing manual-resume branch unchanged. A `preemptive` cause is never a reason to skip a check the reactive path makes — it only selects which wake to re-arm. Both also read `park_claim_token` (#1596), which adds the one park state that had no branch before: a claim whose Step 3 never ran. It is recovered from the kind and bound Step 1 persists, not from a fresh bound.

**The bound field is three-valued (#1445).** `limit_probe_fires_remaining` used to carry two incompatible meanings in one `null`: "the reset time is known, so re-arm the sleep-until-reset one-shot" and "the reset is unknown and no bound has been written yet". `-1` now carries the second — written by Step 1's claim while the record is still being assembled, and by `/pause` teardown and `/pause-resume` disarm once the wake that owned the bound has been stopped. `null` keeps its original meaning exactly, so nothing reading it today changes behaviour; `>= 0` is still a live count. Every reader treats `-1` as "stay parked, re-arm nothing, manual resume" — which is what a `null` could not say without also ordering a wake.

**Now in scope elsewhere (#1619):** `monitor-mode.md`'s per-cycle checklist and `/subagent`'s monitor loop run this same reflex — the named follow-up has landed. A thread running Phase A/B/C subagents reads the horizon each cycle and, on `critical`, parks through `.claude/reference/subagent-thread-limit-park.md` §7 with `limit_cause="preemptive"`, this section's landing-window and probe knobs, and this section's probe-fire handler. It is not a second parker: it claims the same repo slot by compare-and-set on `limit_cause`, so day mode and a subagent thread on one repo can race freely and exactly one wins — the loser adopts and arms nothing. Day mode's own behaviour is unchanged.

**Also in scope, as readers only (#1444):** `/pr-monitor-and-manage` and `/babysit-pr` now run the same consult and honour the same verdicts, but they never claim a park — on `critical` each stands its own poll down in its own namespace and adopts whatever park is already open. Nothing in this section changes for them: no watch-only loop writes `.repos["<key>"].day.*`, so day mode's record still has exactly the parkers it had. The ownership rule that decides which loop may park which work — a loop may park the work it launched, and a loop that only watches PRs others launched honours a park without claiming one — is recorded once, in `subagent-thread-limit-park.md` §8, with the watch-only contract itself in §8.1.

