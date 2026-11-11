<!-- pm-routing:begin -->
Route `shared:ownership`. Use the existing read-only planning or fresh pre-launch sweep. On refill, use the current Step 3.4 candidates and retain its existing degraded and adoption outcomes.
<!-- pm-routing:end -->
**Ownership sweep (read-only when planning, rechecked before dispatch).** In-flight work does not live only on GitHub — it also lives in other threads: a coding thread paused mid-issue, a PM thread that parked itself, a fleet manager waiting on its wake command, a session that died with resumable state on disk. The claim gate alone cannot see any of that, and a stale claim is re-picked with only a warning, which is how issue #652 shipped twice. During ranking, pass the candidate numbers as `PM_OWNERSHIP_ISSUES` to the same read-only sweep below. Reuse fresh results from this evaluation for surviving `BATCH_ISSUES` after window trimming. At launch, recheck any result that is missing or stale. Branch three ways (issue #1431):

**Get the session listing first — it is what makes `adopt` reachable (issue #1459).** Liveness is resolved against a listing of this harness's sessions, and no CLI enumerates them: the source is the **deferred** MCP tool `mcp__ccd_session_mgmt__list_sessions`. Deferred means its schema is not loaded, so calling it straight away fails — load it once per thread, then call it:

1. `ToolSearch` with `select:mcp__ccd_session_mgmt__list_sessions`.
2. Call it with `include_archived: true` and an explicit `limit` far above the number of sessions on the machine — not merely above the board size, which counts issues rather than sessions. The default 20 truncates a busy day, and a session truncated out of the listing reads as *absent*, which classifies **dead** -> adopt. Use `limit: 500` and export the same number as `SESSION_LISTING_LIMIT` so the block can detect a listing that still came back full.
3. Write the returned array **verbatim** to a file and export its path as `SESSION_LISTING_RAW_PATH`, then run the block below. It validates the JSON, refuses a listing it cannot vouch for, appends this thread's own record, and sets `SESSION_LISTING_PATH`.

<!-- test-anchor: pm-1b5-session-listing -->
```bash
SESSION_LISTING_PATH=""
SESSION_LISTING_SKIP="mcp__ccd_session_mgmt__list_sessions unavailable or unreadable"
if [[ -n "${SESSION_LISTING_RAW_PATH:-}" && -r "${SESSION_LISTING_RAW_PATH:-}" ]] \
   && jq -e 'type == "array"' "$SESSION_LISTING_RAW_PATH" >/dev/null 2>&1; then
  SESSION_LISTING_SKIP=""
  # A listing that came back exactly as long as the limit we asked for is a
  # listing that may have been CUT at that limit, and a session cut out of it
  # reads as absent -> dead -> adopt. There is no way to tell a full page from a
  # complete one, so an unverifiable listing is not used at all: degrading costs
  # a surfaced line, trusting it costs a duplicate implementation.
  if [[ -n "${SESSION_LISTING_LIMIT:-}" ]] \
     && jq -e --argjson lim "${SESSION_LISTING_LIMIT}" 'length >= $lim' \
          "$SESSION_LISTING_RAW_PATH" >/dev/null 2>&1; then
    SESSION_LISTING_SKIP="listing returned ${SESSION_LISTING_LIMIT} records at the ${SESSION_LISTING_LIMIT} limit — possibly truncated; re-call with a higher limit"
  # `list_sessions` EXCLUDES the calling session, and a session absent from a
  # listing that WAS read classifies `dead` -> adopt. This thread's own record
  # is appended so the sweep can never adopt work this very thread is running —
  # which means an unknown `CLAUDE_SESSION_ID` cannot produce a usable listing:
  # forwarding one without the self-record is exactly the self-adoption the
  # append exists to prevent, so it degrades instead.
  elif [[ -z "${CLAUDE_SESSION_ID:-}" ]]; then
    SESSION_LISTING_SKIP="CLAUDE_SESSION_ID is unset — this thread's own record cannot be added, so the listing could classify this thread's work as dead"
  fi
  if [[ -z "$SESSION_LISTING_SKIP" ]]; then
    # An explicit XXXXXX template, not `mktemp -t <name>`: GNU mktemp rejects a
    # `-t` template with no X's ("too few X's"), so the BSD-only spelling would
    # fail outright on Linux and take the listing — and adoption — down with it.
    SESSION_LISTING_PATH="$(mktemp "${TMPDIR:-/tmp}/pm-session-listing.XXXXXX")"
    if ! jq -c --arg id "$CLAUDE_SESSION_ID" \
         '. + [{sessionId:$id, title:"this /pm thread",
                isArchived:false, isRunning:true}]' \
         "$SESSION_LISTING_RAW_PATH" > "$SESSION_LISTING_PATH"; then
      rm -f "$SESSION_LISTING_PATH"; SESSION_LISTING_PATH=""
      SESSION_LISTING_SKIP="could not build the listing file"
    fi
  fi
fi
if [[ -z "$SESSION_LISTING_PATH" ]]; then
  echo "DEGRADED: no session listing (${SESSION_LISTING_SKIP:-unusable}) — liveness indeterminate; owned candidates are surfaced, never adopted"
fi
```

**A missing listing degrades the sweep, it never blocks it.** With no `SESSION_LISTING_PATH`, liveness is `indeterminate`, which resolves to **live** — fail toward surfacing, never toward adopting. That direction is deliberate: surfacing a thread that turned out to be dead costs one line, adopting work a live thread is still doing costs a duplicate implementation. Headless runs, where the tool does not exist, land on surface-and-skip by construction.

<!-- test-anchor: pm-1b5-ownership-sweep -->
```bash
# Ranking provides a bounded candidate list. A launch recheck defaults to the
# actual batch after window trimming.
if [[ -n "${PM_OWNERSHIP_ISSUES[0]:-}" ]]; then
  CANDIDATE_NUMS=("${PM_OWNERSHIP_ISSUES[@]}")
  unset PM_OWNERSHIP_ISSUES
else
  CANDIDATE_NUMS=(${BATCH_ISSUES[@]+"${BATCH_ISSUES[@]}"})
fi

SWEEP=""; SWEEP_RC=0; SWEEP_ERR=""
if [[ -n "$CANDIDATE_OWNERSHIP" && ${#CANDIDATE_NUMS[@]} -gt 0 ]]; then
  SWEEP_ARGS=("${CANDIDATE_NUMS[@]}" --json)
  # Liveness needs the session listing built above; the `owned_dead` -> adopt
  # branch is unreachable without it, so a dead thread's work would be surfaced
  # rather than resumed.
  if [[ -n "${SESSION_LISTING_PATH:-}" && -r "${SESSION_LISTING_PATH:-}" ]]; then
    SWEEP_ARGS+=(--sessions "$SESSION_LISTING_PATH")
  fi
  SWEEP_ERRFILE="$(mktemp)"
  SWEEP="$("$CANDIDATE_OWNERSHIP" "${SWEEP_ARGS[@]}" 2>"$SWEEP_ERRFILE")" || SWEEP_RC=$?
  SWEEP_ERR="$(cat "$SWEEP_ERRFILE")"; rm -f "$SWEEP_ERRFILE"
fi
# The listing is a temp file this thread wrote; drop it now the sweep has read
# it, on the degraded path too. A later tick rebuilds it from a fresh
# `list_sessions` call rather than re-reading a snapshot that has since aged.
if [[ -n "${SESSION_LISTING_PATH:-}" ]]; then
  rm -f "$SESSION_LISTING_PATH"; SESSION_LISTING_PATH=""
fi
```

**A sweep that did not run is a named degradation, never a silent one.** `SWEEP_RC` non-zero or empty output with candidates present means the ownership filter is *off* for this tick — print the `sweep degraded` line below for every candidate, quoting `SWEEP_ERR`, and fall back to claim-gate-only. Discarding the error and continuing would let a usage error silently disable the whole guard, which is the failure mode this sweep exists to prevent.

Each line carries `action`, and `action` is the whole contract:

| `action` | `/pm` does |
|---|---|
| `dispatch` | eligible for the ranked batch or standing plan. Send only current launch picks to 3.1. |
| `skip` | do not dispatch; print the owned line below. **Never** resume, message, or write the owning thread's state: a human parked it, and running the same work in two places is how duplicates get shipped |
| `adopt` | the owner is archived or gone. Keep the disposition while planning. At launch, take the claim over via the existing stale-takeover path (`issue-claim.sh <N> --claim`) and dispatch **from the surviving state** named in `adopt` — `from: pr` enters the normal PR flow at `adopt.phase`, `from: branch` resumes Phase A on that branch, `from: null` is a fresh dispatch. Work with surviving state is never redone from scratch |

Print one line per non-dispatch candidate, as a sibling of the window-fit exclusion idiom, immediately before `## Suggested Next Issues`:

```
- `#N` — owned by {owner_label} ({state}); resume with {resume_route}
- `#N` — adopted from {owner_label} (archived); resuming from {adopt.from} #{adopt.pr}
- `#N` — sweep degraded: {degraded[0]}; using claim gate only
```

Rules that bind this step:

- **The sweep never blocks.** It is read-only, it never waits on a user answer while any unowned candidate remains dispatchable, and its only writes are on the adoption path (the claim takeover plus normal dispatch bookkeeping). A prospective pick takes that path only at launch.
- **A degraded candidate falls back to claim-gate-only** — name the file in the line above and treat that one candidate as today. A read failure is never a silent skip of the whole sweep and never a dispatch block.
- **All-owned edge case only:** if every rankable candidate is owned and the pipeline would otherwise sit idle, present a menu (`ask-menu.md`) listing the owned items and their resume routes. In every other case keep the surface-and-skip posture — no permission questions.
- The paused PR fleet is not a special case any more, just the instance whose `resume_route` is `/pr-monitor-and-manage-wake`. Day mode's arm-time fleet takeover (2D.1(a)) is a different decision and is unchanged.

Mechanism, reader set, and verdict table: `.claude/reference/pm-ownership-sweep.md`.

