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
PMM_EXPECTED=$("$SESSION_STATE_SH" --get-json '.pmm_active') || PMM_RC=$?
if [ "$PMM_RC" -eq 3 ]; then PMM_EXPECTED=null; fi
```

| `PMM_RC` | Value | Arm? |
|----------|-------|------|
| 0 | `true` | **No** — a fleet monitor is live |
| 0 | `false` / `null` | Yes |
| 3 | — | Yes — no state file has ever been written |
| 4, 6, other, or another value | — | **No** — unreadable state is not permission |

When it refuses, say it in one line and stop: `Day mode and /pr-monitor-and-manage are the same lane — run /pmm-stop first, then /pm day.` A **paused** fleet (`pmm_active` false with `.pmm.paused_at` set) is not dispatching and does **not** block: arm, and say in the same heartbeat that the paused fleet stays paused and day mode now owns the PRs.

**(b) Read the day once for duplicate detection and park selection.**
Keep this snapshot for the claim in (c). A change after this read invalidates
the claim. Recovery can also run the same snapshot block without claiming.

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

On an arming invocation, run the duplicate-day check before the park route
in (b+). A fresh active day already owns dispatch. A stale heartbeat allows
recovery of an older loop, including an unparseable or absent heartbeat.
An unpublished reservation is different. Its owner may still be running
the first pipeline, so elapsed time alone cannot release it. An unreadable
snapshot, malformed activity or cadence, or unavailable clock stops arming.

<!-- test-anchor: pm-day-start-freshness -->

```bash
pm_day_start_route() {
  local now
  case "$DAY_SNAPSHOT_RC" in
    3) printf '%s\n' inactive; return ;;
    0) ;;
    *) return 4 ;;
  esac
  now=$(date -u +%s) || return 4
  [[ "$now" =~ ^[0-9]+$ ]] || return 4
  jq -ers --argjson now "$now" '
    select(length == 1) | .[0] |
    if . == null then "inactive"
    elif (.active | type) != "boolean" and .active != null then
      error("invalid day activity")
    elif .active != true then "inactive"
    elif .monitor_task_id == null and
      (.monitor_generation | type == "string" and test("^day-[0-9a-f]{32}$"))
    then "reserved"
    else
      (.cadence_effective_minutes |
        if . == null then 5
        elif type == "string" then select(test("^[0-9]+$")) | tonumber
        else . end |
        select(type == "number" and . >= 0 and floor == .)
      ) as $cadence |
      (try (.last_tick_at | fromdateiso8601) catch null) as $last |
      if $last == null or $now - $last > ([3 * $cadence, 15] | max) * 60 then "stale"
      else "live" end
    end' <<< "$DAY_SNAPSHOT"
}
DAY_START_ROUTE=$(pm_day_start_route) || DAY_START_ROUTE=unreadable
printf 'DAY_START_ROUTE=%s\n' "$DAY_START_ROUTE"
```

For `live`, say a day loop is already running and name how to stop it
(`say "stop"`). For `reserved`, say a day start still owns dispatch and
start nothing. Its owner can release it. If the prior owner's session has
been verified ended, use the exact unpublished reservation in
`pm_day_release_start` and rerun the fresh startup checks. A missing or
ambiguous liveness check leaves the reservation standing.
For `unreadable`, say the state or clock could not be read.
For `stale`, report recovery and continue to (b+). For `inactive`, continue
to (b+) normally. The freshness window is max(3 × effective cadence, 15m).
A future heartbeat also holds ownership.

**(b+) Session-restart during a usage-limit park.** Classify that same snapshot before ordinary arming. A failed read can hide an
active park. The snapshot already retries a lock timeout once. The clock is
needed only when the route depends on a deadline. A weekly park requires a
successful explicit `/end-resume` for the same repository. Keep the typed
weekly snapshot captured when asking the user to resume. On a later explicit
arming invocation, supply that snapshot as `PM_DAY_WEEKLY_RESUMED_SNAPSHOT`
only after verifying the manual resume succeeded for that park. The exact
comparison leaves a replacement park alone. Automatic recovery leaves this
input unset. A future or missing weekly deadline still holds.

<!-- test-anchor: pm-day-park-route -->

```bash
pm_day_park_route() {
  local rc now deadline
  for rc in "$PARK_RC" "$LIMIT_KIND_RC" "$LIMIT_CAUSE_RC" "$LIMIT_FIRES_RC" \
      "$CLAIM_TOKEN_RC" "$PARK_GENERATION_RC" "$RESUME_GENERATION_RC"; do
    case "$rc" in 0|3) ;; *) echo manual:unreadable; return ;; esac
  done

  if [ "$PARK_CLAIM_TOKEN" != null ]; then echo manual:unfinished; return; fi
  if [ "$PARK_LIMIT_KIND" = weekly ] &&
      { [ "${PM_DAY_WEEKLY_RESUMED_SNAPSHOT:-}" != "$DAY_SNAPSHOT" ] || [ "$PARKED_UNTIL" = null ]; }; then
    echo manual:weekly
    return
  fi
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
  elif [ "$PARK_LIMIT_KIND" = weekly ]; then
    echo manual:weekly
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
Promise automatic resume only after the wake is published. For
`manual:weekly`, retain the park, arm nothing, and name `/end-resume`.
For other `manual:*` routes, retain the park, arm nothing, and name the
reason and `/pause-resume` in one line. A saved positive preemptive bound holds through the nominal deadline:
wind-down can take time before the sleep-first probe starts. An unfinished
claim, spent bound, or missing bound sentinel also takes precedence over
deadline expiry.

**(c) Reserve one day dispatcher.** Only the `normal` park route can enter
this step. Compare the whole observed day and the typed inactive fleet value
in the same write. Publish a fresh heartbeat and the existing Monitor
generation immediately. Leave its task slot empty until 2D.2 publishes the
native ID. The reservation preserves the saved goal and other day fields.

<!-- test-anchor: pm-day-start-ownership -->

```bash
pm_day_claim_start() {
  local prior now nonce
  [[ "$REPO_KEY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 4
  case "$DAY_SNAPSHOT_RC" in
    0) prior="$DAY_SNAPSHOT" ;;
    3) prior=null ;;
    *) return 4 ;;
  esac
  case "$PMM_EXPECTED" in false|null) ;; *) return 4 ;; esac
  now=$(date -u +%FT%TZ) || return 4
  nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 4
  [[ "$nonce" =~ ^[0-9a-f]{32}$ ]] || return 4
  DAY_ARM_GENERATION="day-$nonce"
  DAY_STATE_PATH=".repos[\"$REPO_KEY\"].day"
  DAY_RESERVATION=$(jq -cn --argjson prior "$prior" --arg gen "$DAY_ARM_GENERATION" \
    --arg now "$now" --argjson cadence "$DAY_CADENCE_MIN" '
      ($prior // {}) | .active=true | .monitor_generation=$gen |
      .monitor_task_id=null | .last_tick_at=$now | .cadence_effective_minutes=$cadence |
      .stop_requested=false') || return 4
  "$SESSION_STATE_SH" --cas "$DAY_STATE_PATH=$DAY_RESERVATION" --expect "$prior" \
    --expect-at '.pmm_active' "$PMM_EXPECTED"
}

pm_day_renew_start() {
  local now next
  now=$(date -u +%FT%TZ) || return 4
  next=$(jq -c --arg now "$now" '.last_tick_at=$now' <<< "$DAY_RESERVATION") || return 4
  "$SESSION_STATE_SH" --cas "$DAY_STATE_PATH=$next" --expect "$DAY_RESERVATION" \
    --expect-at '.pmm_active' "$PMM_EXPECTED" || return $?
  DAY_RESERVATION="$next"
}

pm_day_release_start() {
  local released
  released=$(jq -c '.active=false | .monitor_generation=null | .last_tick_at=null' \
    <<< "$DAY_RESERVATION") || return 4
  "$SESSION_STATE_SH" --cas "$DAY_STATE_PATH=$released" --expect "$DAY_RESERVATION"
}
```

Run `pm_day_claim_start` once. A comparison loss means the state changed.
Report that the start was skipped, and run no work or cleanup for that
attempt. On any other failure, report the failed claim and stop.
Do not rerun the claim against state you have not re-evaluated.

After a successful claim, run `pm_day_renew_start` to recheck the fleet
and your reservation. Run it again immediately before the arming turn
dispatches from Step 1, even if ranking or cleanup took time. If either
renewal fails, run `pm_day_release_start` once, report the conflict or
unreadable state, and start no further work. A release comparison loss
means the reservation changed and leaves it alone. A reserved startup
keeps ownership across a long first turn, even if its heartbeat ages out. Report other release
errors as unverified. The fleet still does its reciprocal read after its
own claim.

Carry `DAY_ARM_GENERATION`, `DAY_RESERVATION`, `DAY_STATE_PATH`,
`PMM_EXPECTED`, and the release operation into 2D.2.

