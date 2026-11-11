<!-- pm-routing:begin -->
Route `day:preconditions`. Read after Step 0a and before Step 1 for an arming run. Recovery reads this when it needs the 2D.1(b+) parked snapshot.
<!-- pm-routing:end -->
### 2D.1: Arm-time preconditions (non-tick invocation only)

Skip this whole sub-step when `DAY_TICK=true` — it is arm-time only.

```bash
REPO_KEY=$("$SESSION_STATE_SH" --repo-key)
NOW=$(date -u +%FT%TZ)
```

**(a) Mutual exclusion with `/pr-monitor-and-manage`.** Both dispatch `/fixpr` and `/wrap` against PRs; two owners on one PR races two merges. Read `.pmm_active`:

```bash
PMM_RC=0
PMM_ACTIVE=$("$SESSION_STATE_SH" --get '.pmm_active') || PMM_RC=$?
```

| `PMM_RC` | Value | Arm? |
|----------|-------|------|
| 0 | `true` | **No** — a fleet monitor is live |
| 0 | `false` / `null` | Yes |
| 3 | — | Yes — no state file has ever been written |
| 4, 6, other | — | **No** — unreadable state is not permission |

When it refuses, say it in one line and stop: `Day mode and /pr-monitor-and-manage are the same lane — run /pmm-stop first, then /pm day.` A **paused** fleet (`pmm_active` false with `.pmm.paused_at` set) is not dispatching and does **not** block: arm, and say in the same heartbeat that the paused fleet stays paused and day mode now owns the PRs.

**(b) Duplicate-day check, with a freshness window.** A day loop whose session died leaves `active: true` behind forever, and a naive check would then refuse to ever arm again. Borrow `/babysit-pr`'s A2 rule: `active` counts only while its last tick is fresh.

Read all three fields **with their exit codes**, and never `|| echo` a default over a failure — a substituted value is indistinguishable from a real one, so a failed read would present itself as fact:

```bash
ACTIVE_RC=0; TICK_RC=0; EFF_RC=0
DAY_ACTIVE=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.active") || ACTIVE_RC=$?
DAY_LAST_TICK=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.last_tick_at") || TICK_RC=$?
DAY_EFF_MIN=$("$SESSION_STATE_SH" --get ".repos[\"$REPO_KEY\"].day.cadence_effective_minutes") || EFF_RC=$?
```

Apply 3.4's exit-code table to each: `0` is the value, `3` means no state file has ever been written (genuinely absent — arm), and **anything else is unreadable state, so refuse to arm** and say the read failed. `DAY_EFF_MIN` is the one that most repays this care: defaulting it to `5` on a failed read shrinks the freshness window from `max(3 × 30, 15) = 90m` to `15m` for a loop running at a 30-minute widened cadence, so a live loop that ticked 20 minutes ago reads as dead and gets a second owner. A fabricated default does not merely lose information — it makes "we failed to look" indistinguishable from "nothing is there" (`safety.md` fail-closed posture).

With three readable values: freshness window is `max(3 × cadence_effective_minutes, 15m)`. `active == true` **and** `last_tick_at` inside that window → a live loop is already running: refuse, one line, and name how to stop it (`say "stop"`). `active == true` with a stale — or unparseable, which is stale for this purpose — `last_tick_at` → the previous loop died with its session: **reclaim it**, say so in one line, and continue arming. Anything else → arm normally.

**(b+) Session-restart during a usage-limit park.** After resolving the `active` / freshness question, take one `.day` snapshot for every park/wake-selection field and retain its exit code:

<!-- test-anchor: pm-day-park-snapshot -->

```bash
# One lock-protected record per recovery attempt; never mix park generations.
DAY_SNAPSHOT_RC=0
DAY_SNAPSHOT=$("$SESSION_STATE_SH" --get-json ".repos[\"$REPO_KEY\"].day" 2>/dev/null) || DAY_SNAPSHOT_RC=$?
if [ "$DAY_SNAPSHOT_RC" -eq 6 ]; then
  DAY_SNAPSHOT_RC=0
  DAY_SNAPSHOT=$("$SESSION_STATE_SH" --get-json ".repos[\"$REPO_KEY\"].day" 2>/dev/null) || DAY_SNAPSHOT_RC=$?
fi
if [ "$DAY_SNAPSHOT_RC" -eq 0 ] && ! printf '%s\n' "$DAY_SNAPSHOT" \
    | jq -e -s 'length == 1 and (.[0] | type == "object" or . == null)' >/dev/null 2>&1; then
  DAY_SNAPSHOT_RC=4
fi
read_day() {  # read_day <field> -> DAY_VALUE, DAY_RC, from this snapshot only
  local parsed_time
  DAY_RC=$DAY_SNAPSHOT_RC
  DAY_VALUE=null
  if [ "$DAY_RC" -eq 0 ]; then
    # Validate nullable wake fields BEFORE raw rendering can erase JSON types.
    DAY_VALUE=$(printf '%s\n' "$DAY_SNAPSHOT" | jq -r --arg field "$1" '
      .[$field] as $value |
      if $value == null then null
      elif $field == "parked_until" then
        if ($value | type) == "string" and ($value | length) == 20
           and ($value | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
        then $value else error("invalid park timestamp") end
      elif $field == "limit_probe_fires_remaining" then
        if ($value | type) != "number" then error("invalid probe counter")
        elif $value < -1 or $value > 9007199254740991 or ($value | floor) != $value
        then error("probe counter must be an exact integer") else $value end
      elif $field == "limit_kind" or $field == "limit_cause"
           or $field == "park_claim_token" or $field == "park_generation" or $field == "limit_resume_generation" then
        if ($value | type) == "string" and ($value | length) > 0 and $value != "null"
        then $value else error("invalid nullable park identifier") end
      else $value end' 2>/dev/null) || { DAY_RC=4; DAY_VALUE=null; }
    if [ "$DAY_RC" -eq 0 ] && [ "$1" = parked_until ] && [ "$DAY_VALUE" != null ]; then
      parsed_time=$(date -u -d "$DAY_VALUE" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$DAY_VALUE" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || parsed_time=""
      if [ "$parsed_time" != "$DAY_VALUE" ]; then DAY_RC=4; DAY_VALUE=null; fi
    fi
  fi
  return 0
}
read_day parked_until; PARKED_UNTIL="$DAY_VALUE"; PARK_RC="$DAY_RC"
read_day limit_kind; PARK_LIMIT_KIND="$DAY_VALUE"; LIMIT_KIND_RC="$DAY_RC"
read_day limit_cause; PARK_LIMIT_CAUSE="$DAY_VALUE"; LIMIT_CAUSE_RC="$DAY_RC"
read_day limit_probe_fires_remaining; PARK_LIMIT_FIRES="$DAY_VALUE"; LIMIT_FIRES_RC="$DAY_RC"
read_day park_claim_token; PARK_CLAIM_TOKEN="$DAY_VALUE"; CLAIM_TOKEN_RC="$DAY_RC"
read_day park_generation; PARK_GENERATION_RC="$DAY_RC"
PARK_GENERATION=""; [ "$DAY_VALUE" = null ] || PARK_GENERATION="$DAY_VALUE"
read_day limit_resume_generation; PARK_RESUME_GENERATION="$DAY_VALUE"; RESUME_GENERATION_RC="$DAY_RC"
```

Validate nullable timestamp/counter/identifier types before raw rendering; actual JSON null alone is absence. The string "null", wrong types and invalid timestamps are unreadable, so stop before normal arming. Apply 3.4's exit-code table to every field derived from this snapshot, including `PARK_GENERATION_RC` (an unreadable generation stops recovery): `0` is the stored value, `3` means no state file has ever been written, anything else is unreadable — retry `6` (a lock timeout; `handoff-files.md`) once at the snapshot boundary, then fail closed; other errors fail closed immediately: report the read failure and stop before normal arming. Do not treat an unreadable `parked_until` as "no park pending" — a lock timeout or parse failure can hide an active park, allowing Steps 1 and 2 to dispatch while the account limit is still active. If `PARKED_UNTIL` is non-null, non-JSON-`"null"`, and in the future (`date -u -d "$PARKED_UNTIL" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$PARKED_UNTIL" '+%s'` is greater than `$(date -u +%s)` — **`-u` on the BSD fallback too**: without it macOS parses the `Z` timestamp as local time, so an ET machine reads every park as four hours longer than it is): the session restarted while a park was active. Only re-arm the limit-wake Monitor if `PARK_LIMIT_KIND == "rolling_window"` — weekly parks cannot be auto-woken because no in-session Monitor can outlast days. If limit_kind is readable and not "rolling_window" (or is readable and non-"rolling_window"), do not re-arm; print one line (`Session restarted during weekly-cap park; manual resume required when window reopens`) and stop. If limit_kind is unreadable (LIMIT_KIND_RC non-zero and non-3), fail closed: do not re-arm and print one line naming the read failure. For a confirmed rolling_window park: use 2D.5’s **Recover the captured wake** path, then **stop without running Steps 1 and 2**. Resolve the wake shape and ownership before arming anything. **Which wake** depends on how the park was recorded — use the snapshotted `PARK_LIMIT_CAUSE`, `PARK_LIMIT_FIRES`, and `PARK_CLAIM_TOKEN` (next paragraph, #1596), with the same exit-code table (`0` value, `3` no state file, anything else unreadable → fail closed and re-arm nothing): a null/absent `limit_probe_fires_remaining` selects 2D.6’s remaining-time one-shot; a `limit_cause == "preemptive"` park with positive fires remaining selects 2D.7’s probe **with that count**, not a fresh bound. Report automatic recovery only after the captured wake is published. Zero fires left means the bound was already spent — stay parked, manual resume, no re-arm. **`-1` is the third value** (#1445): the park stands but no probe bound is in force and no reset time is known — a claim whose record never completed, or a wake `/pause` / `/pause-resume` deliberately stopped. Handle it exactly as zero — stay parked, re-arm nothing, one line (`Day loop parked (no usable wake bound) — resume manually with /pause-resume`) — never as the null branch above, since re-arming a sleep-until-reset one-shot against a fabricated deadline is precisely the misread `-1` exists to end. Otherwise the board is parked and will resume when the wake fires.

**An in-progress claim is a state, not an anomaly — use the snapshotted `PARK_CLAIM_TOKEN` too (#1596).** Apply the same exit-code table (`0` value, `3` no state file, anything else unreadable → fail closed and re-arm nothing). A **non-null token with a null `limit_cause`** is 2D.7 Step 1's claim caught mid-assembly: Step 1 persisted the bound and kind without a completed park. A completed park has a cause and a null token. An unfinished claim or leftover token does not authorize a replacement wake: keep the record and require manual `/pause-resume`.

**A spent bound outlives its own deadline — check it before the expiry shortcut.** A pre-emptive park with an unknown reset sets `parked_until` to exactly `cadence x fires` ahead, which is the same instant the last probe fires. So the moment the bound is spent, `parked_until` is in the *past* — and an expiry-first test reads that as "the park resolved". It did not: `PROBE=exhausted` leaves the park in place, awaiting a manual `/pause-resume`, with the execution gate still closed. Arming normally there erases the manual-resume state and starts a loop whose every launch the gate then blocks — a live board that cannot dispatch and never says why. So when `limit_cause == "preemptive"` and `limit_probe_fires_remaining` reads `0` — or `-1`, whose park has no bound to spend and no deadline worth trusting either — stay parked **regardless of `parked_until`**: re-arm nothing, print one line (`Day loop parked (probe bound spent) — resume manually with /pause-resume`, or the `no usable wake bound` wording above for `-1`, where nothing was spent), and stop recovery. Only with those cases excluded does the expiry shortcut apply: if `parked_until` is in the past or null, the park resolved or never existed; continue arming normally.

**(c) Settle the race before arming: publish, then re-read.** (a) and (b) are read-then-write across separate `session-state.sh` calls, so each call is locked but the pair is not: `/pm day` and `/pr-monitor-and-manage` starting within the same moment can each read the other as clear and both arm. Close it without inventing a lease — write your own claim **first**, then re-read theirs:

1. Write **only** `.repos[<key>].day.active=true` — a bare ownership claim, nothing else:

   ```bash
   "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.active=true"
   ```

   Not the full init object: that runs in 2D.2, after Steps 1 and 2, and it *replaces* the whole `day` object — writing it here would destroy any goal a previous run stored before 2D.2 gets the chance to read and carry it forward.
2. **Re-read `.pmm_active`.** Still clear → you own the repo; continue (Steps 1 and 2, then 2D.2 arms the `Monitor`).
3. Set → the fleet won the race: write `.repos[<key>].day.active=false` to release the claim, arm nothing, run no part of Step 1, and stand down with the same one-line message as (a).

Whoever writes second is guaranteed to see the other's claim, so this can never leave two owners. It *can* leave zero — both stand down if they interleave exactly — which is safe and re-runnable, and far cheaper than the lease protocol that would be needed to also guarantee a winner. `/pr-monitor-and-manage` Step 0-pre runs the mirror of this sequence.

