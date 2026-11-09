# Recover the captured wake

Both 2D.1(b+) and 2D.5 use this path after
selecting an active rolling-window park. Reuse the original `DAY_SNAPSHOT`
and its exit code. A completed park with an empty wake slot may re-arm.
An occupied slot requires a confirmed stop of its exact task in its owning
native session. Restart, absence from a list, a stale registry row, or
unknown session identity cannot prove that. An unfinished claim or
unverifiable wake stays parked for manual `/pause-resume`.

For an occupied slot, set `PM_WAKE_NATIVE_SESSION` only from this attempt's
verified native session identity. Unset it if the harness cannot establish
the identity. Run this block before any `TaskStop` or `Monitor`; keep the JSON
result as `PM_WAKE_PREPARED`, as data, without evaluating it as shell:

<!-- test-anchor: pm-day-wake-recovery-prepare -->

```bash
pm_wake_project() {
  jq -cse --arg repo "$REPO_KEY" --argjson now "$1" '
    def ident: type == "string" and length > 0 and . != "null";
    def exact_id: ident or
      (type == "number" and . >= 0 and . <= 9007199254740991 and floor == .);
    if length != 1 or (.[0] | type) != "object" then error("invalid day snapshot")
    else .[0] |
      {repo_key:$repo, park_generation, parked_until, limit_kind, limit_cause,
       park_claim_token, limit_probe_fires_remaining, limit_resume_task_id,
       limit_resume_generation} |
      select(.park_generation == null or (.park_generation | ident)) |
      select(.park_claim_token == null and .limit_kind == "rolling_window") |
      select(.limit_cause == "reactive" or .limit_cause == "preemptive") |
      select(.parked_until | type == "string" and
        (try (fromdateiso8601 | todateiso8601) catch null) == . and
        (try fromdateiso8601 catch 0) > $now) |
      select(.limit_probe_fires_remaining == null or
        (.limit_cause == "preemptive" and (.limit_probe_fires_remaining | type == "number"
          and . > 0 and . <= 9007199254740991 and floor == .))) |
      select((.limit_resume_task_id == null and .limit_resume_generation == null) or
        ((.limit_resume_task_id | exact_id) and (.limit_resume_generation | ident)))
    end'
}

pm_wake_prepare() {
  local binding route shape rows registry candidate live live_binding sid now
  [ "${DAY_SNAPSHOT_RC:-4}" -eq 0 ] || return 1
  [[ "$REPO_KEY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  now=$(date -u +%s) || return 1
  binding=$(printf '%s\n' "$DAY_SNAPSHOT" | pm_wake_project "$now") || return 1
  shape=$(printf '%s\n' "$binding" | jq -er '
    if .limit_probe_fires_remaining == null then "one-shot" else "probe" end') || return 1
  sid=""
  route=empty
  if ! printf '%s\n' "$binding" | jq -e '.limit_resume_task_id == null' >/dev/null; then
    route=stop
    printf '%s\n' "$binding" | jq -e '.limit_resume_task_id | type == "string"' >/dev/null || return 1
    sid="${PM_WAKE_NATIVE_SESSION:-}"
    case "$sid" in ""|default|unknown|_unknown|null) return 1 ;; esac
    registry=""
    for candidate in "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/background-task-registry.sh}" "${HOME:+$HOME/.claude/scripts/background-task-registry.sh}"; do
      if [ -x "$candidate" ]; then registry="$candidate"; break; fi
    done
    [ -n "$registry" ] || return 1
    rows=$("$registry" --repo "$REPO_KEY" --list --session "$sid" --live) || return 1
    # The registry stores strings: do not coerce numeric wake IDs to match.
    printf '%s\n' "$rows" | jq -es --argjson b "$binding" --arg sid "$sid" '
      length == 1 and (.[0] | type == "array") and
      (.[0] | map(select(.task_id == $b.limit_resume_task_id)) |
       length == 1 and (.[0] | .repo_key == $b.repo_key and .session_id == $sid
         and .type == "monitor" and .status == "running" and .stale == false))' >/dev/null || return 1
  fi
  # Recheck immediately before a stop. The new read can only disqualify the
  # original binding; it never supplies a replacement identity.
  live=$("$SESSION_STATE_SH" --get-json ".repos[\"$REPO_KEY\"].day") || return 1
  live_binding=$(printf '%s\n' "$live" | pm_wake_project "$now") || return 1
  [ "$live_binding" = "$binding" ] || return 1
  jq -cn --argjson binding "$binding" --arg route "$route" --arg shape "$shape" --arg sid "$sid" \
    '{binding:$binding, route:$route, shape:$shape, session_id:($sid | if . == "" then null else . end)}'
}

PM_WAKE_PREPARED=$(pm_wake_prepare 2>/dev/null) || PM_WAKE_PREPARED='{"route":"manual"}'
printf '%s\n' "$PM_WAKE_PREPARED"
```

- **`manual`** — retain the park and its wake record; do not stop, arm or
  dispatch. Say recovery could not verify the wake and name `/pause-resume`.
- **`stop`** — immediately call the native `TaskStop` in the verified session
  for the exact ID in `.binding.limit_resume_task_id`. Only the successful,
  matching native response from that call is proof. Save the actual response
  as `PM_WAKE_STOP_RESPONSE` and its verified native session as
  `PM_WAKE_STOP_SESSION`. Do not supply either on a failed, missing or
  ambiguous response. The registry only identifies the candidate.
- **`empty`** — no stop is needed; leave both stop inputs unset.

Before arming, run this block and retain its JSON as `PM_WAKE_AUTHORIZED`.
Clear all per-attempt inputs before a later recovery. Only a result with
`.route == "arm"` authorizes a new Monitor:

<!-- test-anchor: pm-day-wake-recovery-authorize -->

```bash
pm_wake_authorize() {
  local live
  live=$("$SESSION_STATE_SH" --get-json ".repos[\"$REPO_KEY\"].day") || return 1
  printf '%s\n' "$live" | jq -cse --arg repo "$REPO_KEY" \
    --argjson prepared "${PM_WAKE_PREPARED:-null}" \
    --argjson stop "${PM_WAKE_STOP_RESPONSE:-null}" --arg sid "${PM_WAKE_STOP_SESSION:-}" '
    $prepared.binding as $b |
    select(length == 1 and (.[0] | type == "object") and ($b | type == "object")) |
    .[0] as $day |
    select($b.repo_key == $repo and
      (reduce ($b | keys_unsorted[]) as $k ({}; .[$k] =
        (if $k == "repo_key" then $repo else $day[$k] end))) == $b) |
    select(
      if $prepared.route == "empty" then
        $b.limit_resume_task_id == null and $b.limit_resume_generation == null and
        $stop == null and $sid == ""
      elif $prepared.route == "stop" then
        ($prepared.session_id | type == "string" and length > 0) and
        $prepared.session_id == $sid and ($stop | type == "object") and
        ($stop.task_id // $stop.taskId) == $b.limit_resume_task_id and
        ($stop.task_id == null or $stop.taskId == null or $stop.task_id == $stop.taskId) and
        ($stop.task_type // $stop.taskType) == "monitor" and
        ($stop.task_type == null or $stop.taskType == null or $stop.task_type == $stop.taskType) and
        $stop.error == null and $stop.errorMessage == null and
        ($stop.status == null or $stop.status == "stopped" or $stop.status == "success")
      else false end) |
    {route:"arm", binding:$b, shape:$prepared.shape,
     dead_task:$b.limit_resume_task_id, dead_generation:$b.limit_resume_generation}'
}

PM_WAKE_AUTHORIZED=$(pm_wake_authorize 2>/dev/null) || PM_WAKE_AUTHORIZED='{"route":"manual"}'
printf '%s\n' "$PM_WAKE_AUTHORIZED"
```

If authorization is refused, leave the park alone and require manual resume.
On `arm`, use the authorized shape: 2D.6's remaining-time one-shot or 2D.7's
probe with the captured positive number of fires. The one-shot shape does not
change a preemptive park's cause. Use a fresh generation, distinct from the
old one; retain the new ID and generation as `PM_WAKE_NEW_TASK` and
`PM_WAKE_NEW_GENERATION`. Do not run the normal 2D.6/2D.7 publication block for
a recovery wake. Run this block immediately instead:

<!-- test-anchor: pm-day-wake-recovery-publish -->

```bash
pm_wake_publish_recovery() {
  local helper candidate binding cause park_gen dead_task dead_gen
  helper=""
  for candidate in "${HOME:+$HOME/.claude/skills-worktree/.claude/scripts/park-wake-publish.sh}" "${HOME:+$HOME/.claude/scripts/park-wake-publish.sh}"; do
    if [ -x "$candidate" ]; then helper="$candidate"; break; fi
  done
  [ -n "$helper" ] || return 4
  binding=$(printf '%s\n' "${PM_WAKE_AUTHORIZED:-null}" | jq -ce '
    select(.route == "arm") | .binding | objects') || return 5
  cause=$(printf '%s\n' "$binding" | jq -er '.limit_cause | select(. == "reactive" or . == "preemptive")') || return 5
  park_gen=$(printf '%s\n' "$binding" | jq -er '(.park_generation // "") | strings') || return 5
  dead_task=$(printf '%s\n' "$PM_WAKE_AUTHORIZED" | jq -c '.dead_task') || return 5
  dead_gen=$(printf '%s\n' "$PM_WAKE_AUTHORIZED" | jq -er '(.dead_generation // "") | strings') || return 5
  printf '%s\n' "$PM_WAKE_AUTHORIZED" | jq -e '
    .shape == "one-shot" or .shape == "probe"' >/dev/null || return 5
  # New Monitor IDs are opaque strings, even when their text is a number.
  [[ -n "${PM_WAKE_NEW_TASK:-}" && "$PM_WAKE_NEW_TASK" != null ]] || return 5
  "$helper" --repo "$REPO_KEY" --cause "$cause" --park-generation "$park_gen" \
    --task-id "$PM_WAKE_NEW_TASK" --generation "$PM_WAKE_NEW_GENERATION" --task-encoding string \
    --recovery-binding "$binding" --dead-task-json "$dead_task" --dead-generation "$dead_gen" \
    --state-helper "$SESSION_STATE_SH" >/dev/null
}

PM_WAKE_PUBLISH_RC=0
pm_wake_publish_recovery || PM_WAKE_PUBLISH_RC=$?
case "$PM_WAKE_PUBLISH_RC" in
  0) PM_WAKE_STATUS=armed ;;
  7) PM_WAKE_STATUS=lost ;;
  *) PM_WAKE_STATUS=failed ;;
esac
jq -cn --arg status "$PM_WAKE_STATUS" --arg new "$PM_WAKE_NEW_TASK" '
  {status:$status, stop_new_task:(if $status == "armed" then null else $new end)}'
```

The helper compares the original binding and atomically publishes the new
identity pair. Only `armed` permits an automatic-resume promise. Otherwise
call native `TaskStop` only for the newly armed Monitor named by
`stop_new_task` (use the exact ID returned by its Monitor call). If it stops,
leave the other owner alone on `lost` or name manual resume on `failed`. If
the stop fails, name the new task to stop manually. Never stop the captured
old task again during publication cleanup.
