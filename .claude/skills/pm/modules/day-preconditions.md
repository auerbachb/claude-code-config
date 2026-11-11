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

Classify that same snapshot before ordinary arming. A failed read can hide an
active park. The snapshot already retries a lock timeout once. The clock is
needed only when the route depends on a deadline.

<!-- test-anchor: pm-day-park-route -->

```bash
pm_day_park_route() {
  local rc now deadline
  for rc in "$PARK_RC" "$LIMIT_KIND_RC" "$LIMIT_CAUSE_RC" "$LIMIT_FIRES_RC" \
      "$CLAIM_TOKEN_RC" "$PARK_GENERATION_RC" "$RESUME_GENERATION_RC"; do
    case "$rc" in 0|3) ;; *) echo manual:unreadable; return ;; esac
  done

  if [ "$PARK_CLAIM_TOKEN" != null ]; then echo manual:unfinished; return; fi
  case "$PARK_LIMIT_FIRES" in
    0) echo manual:spent; return ;;
    -1) echo manual:no-bound; return ;;
    null) ;;
    *)
      if [ "$PARK_LIMIT_CAUSE" = preemptive ] && [ "$PARK_LIMIT_KIND" = rolling_window ] \
          && [ "$PARKED_UNTIL" != null ]; then
        echo recover:probe
      else
        echo manual:unverified
      fi
      return ;;
  esac

  if [ "$PARKED_UNTIL" = null ]; then echo normal; return; fi
  if ! now=$(date -u +%s) || ! [[ "$now" =~ ^[0-9]+$ ]] ||
     ! deadline=$(date -u -d "$PARKED_UNTIL" +%s 2>/dev/null \
       || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$PARKED_UNTIL" +%s 2>/dev/null) ||
     ! [[ "$deadline" =~ ^-?[0-9]+$ ]]; then
    echo manual:unreadable
  elif [ "$deadline" -le "$now" ]; then
    echo normal
  elif [ "$PARK_LIMIT_KIND" = rolling_window ]; then
    echo recover:oneshot
  else
    echo manual:unverified
  fi
}
PARK_ROUTE=$(pm_day_park_route)
printf 'PARK_ROUTE=%s\n' "$PARK_ROUTE"
```

Only `normal` continues to the day claim and Steps 1 and 2. For either
`recover:*` route, use 2D.5's **Recover the captured wake** with the same
`DAY_SNAPSHOT`, then stop this invocation without running Steps 1 and 2.
Promise automatic resume only after the wake is published. For `manual:*`,
retain the park, arm nothing, and name the reason and `/pause-resume` in one
line. A saved positive preemptive bound holds through the nominal deadline:
wind-down can take time before the sleep-first probe starts. An unfinished
claim, spent bound, or missing bound sentinel also takes precedence over
deadline expiry.

**(c) Settle the race before arming: publish, then re-read.** (a) and (b) are read-then-write across separate `session-state.sh` calls, so each call is locked but the pair is not: `/pm day` and `/pr-monitor-and-manage` starting within the same moment can each read the other as clear and both arm. Close it without inventing a lease — write your own claim **first**, then re-read theirs:

1. Write **only** `.repos[<key>].day.active=true` — a bare ownership claim, nothing else:

   ```bash
   "$SESSION_STATE_SH" --set ".repos[\"$REPO_KEY\"].day.active=true"
   ```

   Not the full init object: that runs in 2D.2, after Steps 1 and 2, and it *replaces* the whole `day` object — writing it here would destroy any goal a previous run stored before 2D.2 gets the chance to read and carry it forward.
2. **Re-read `.pmm_active`.** Still clear → you own the repo; continue (Steps 1 and 2, then 2D.2 arms the `Monitor`).
3. Set → the fleet won the race: write `.repos[<key>].day.active=false` to release the claim, arm nothing, run no part of Step 1, and stand down with the same one-line message as (a).

Whoever writes second is guaranteed to see the other's claim, so this can never leave two owners. It *can* leave zero — both stand down if they interleave exactly — which is safe and re-runnable, and far cheaper than the lease protocol that would be needed to also guarantee a winner. `/pr-monitor-and-manage` Step 0-pre runs the mirror of this sequence.

