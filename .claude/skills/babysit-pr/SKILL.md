---
name: babysit-pr
description: Watch a single PR on a recurring /loop and auto-dispatch /fixpr (recoverable blockers) or /wrap (merge-ready). Reads PR state via pr-state.sh + merge-gate.sh each tick, classifies into {merged, merge-ready, has-recoverable-blockers, waiting-on-bots, hard-blocked}, tracks in-flight dispatches in session-state for idempotency, applies stable-state backoff, emits a timestamped heartbeat per tick, and hard-terminates on merge/hard-blocked/N blocker ticks/user stop. Stop with /babysit-pr-stop. Invoke as `/babysit-pr <PR> [--cadence Nm] [--max-iter N] [--silent] [--durable]`.
triggers:
  - babysit pr
  - babysit this pr
  - watch this pr
  - keep an eye on pr
argument-hint: "<PR> [--cadence Nm] [--max-iter N] [--silent] [--durable]"
---

Watch one PR and drive it toward merge **without looping forever**. Each tick reads the PR's state through the shared scripts, classifies it, and dispatches the right skill — `/fixpr` to fix recoverable blockers, `/wrap` to merge when the gate is met — then re-arms the poll until a terminal condition fires.

`/babysit-pr` is a **thin orchestrator**: it never re-implements PR-state aggregation, the merge gate, fix logic, or the merge flow. It reads `pr-state.sh` + `merge-gate.sh`, and it dispatches `/fixpr` / `/wrap`. All code-verification, thread resolution, CI fixing, and merge-gate enforcement stay inside those skills (`fixpr/SKILL.md`, `wrap/SKILL.md`, `cr-merge-gate.md`). This skill only decides *which* to call and *when to stop*.

This is reused by `/pr-monitor-and-manage` (issue #460): that skill invokes `/babysit-pr` per discovered PR rather than re-implementing the per-PR decision tree.

## Safety boundaries (HARD STOPS — non-negotiable, `safety.md` / #450)

`/babysit-pr` is read-only plus the dispatches below. It MUST NOT:

- **Never modify branch protection** — no calls to `.../branches/.../protection`.
- **Never dismiss human-authored reviews.** Only `/fixpr`'s `dismiss-stale-bot-changes.sh` (bot allowlist, wrong `commit_id`) may dismiss, and only bot reviews.
- **Never resolve a review thread** itself — thread resolution happens only inside `/fixpr` Steps 1–4 after code-verification. `/babysit-pr` does not call `resolveReviewThread`.
- **Never bypass `/fixpr`'s code-verification step** — it dispatches the full `/fixpr` workflow, never a shortcut.
- **Never post `@coderabbitai full review`** without `cr-review-hourly.sh --check` passing first. The **only** sanctioned trigger path in this skill is the T1b pre-flight (`pr-preflight.sh`, issue #493), which gates CR on `cr-review-hourly.sh` (`--check` + atomic `--record-explicit`) automatically, never triggers Greptile, and never flips another user's draft. `/fixpr` owns any further triggers after a push.

A human `CHANGES_REQUESTED` on HEAD is `hard-blocked` → record and exit. Never auto-dismiss it.

## Arguments & knobs

| Argument | Default | Meaning |
|----------|---------|---------|
| `<PR>` (required) | — | PR number to watch. Must be an open PR. |
| `--cadence Nm` | `5m` | Base poll cadence. Floor `1m` (60s) — clamp anything lower. |
| `--max-iter N` | `6` | Hard termination after N **consecutive blocker-state ticks** (≈90 min once backoff widens to 15m). |
| `--silent` | off | Suppress the per-tick heartbeat **except** on state change, dispatch, or termination (those always print). |
| `--durable` | off | Use `CronCreate` instead of `/loop` for cross-session durability (per `scheduling-reliability.md`). Default is `/loop` (session-scoped). |

Parse from `$ARGUMENTS`. The first bare integer is `<PR>`. Validate `--cadence` matches `^[0-9]+m$`; clamp `< 1m` to `1m`. Validate `--max-iter` is a positive integer.

## Two modes: arm vs tick

This skill runs in one of two modes, disambiguated by the internal `--tick` flag:

- **Arm mode** (`/babysit-pr <PR> …`, no `--tick`): validate, initialize `session-state.json`, arm the recurring poll, run **one** tick immediately, then end the turn.
- **Tick mode** (`/babysit-pr <PR> --tick`): the body the poll re-invokes each cycle. Runs exactly one tick of classification + dispatch + bookkeeping. **Never re-arms the loop** (the runtime owns cadence) except to change cadence on a backoff threshold crossing.

The loop command armed in arm mode is `/babysit-pr <PR> --tick` (plus the resolved cadence flags), so every subsequent cycle enters tick mode.

---

## Resolve the shared scripts (once, both modes)

Use the standard three-candidate lookup (same pattern as `fixpr/SKILL.md`). Prefer the global install; fall back to the in-repo copy when developing the skill itself.

```bash
resolve_script() {
  # $1 = script basename; echoes the first executable path or empty
  local name="$1" candidate
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
  done
  return 1
}

PR_STATE_SH=$(resolve_script pr-state.sh)        || { echo "ERROR: pr-state.sh not found" >&2; exit 1; }
MERGE_GATE_SH=$(resolve_script merge-gate.sh)     || { echo "ERROR: merge-gate.sh not found" >&2; exit 1; }
SESSION_STATE_SH=$(resolve_script session-state.sh) || { echo "ERROR: session-state.sh not found" >&2; exit 1; }
CR_HOURLY_SH=$(resolve_script cr-review-hourly.sh)   || true   # optional; degrade gracefully
GREPTILE_SH=$(resolve_script greptile-budget.sh)     || true   # optional; degrade gracefully
PREFLIGHT_SH=$(resolve_script pr-preflight.sh)       || true   # optional; degrade gracefully (#493)

to_epoch() {
  # Portable ISO-8601 UTC (e.g. 2026-07-21T17:13:05Z) -> epoch seconds.
  # Tries GNU date, then BSD/macOS date. Returns non-zero (no stdout) if both
  # fail -- callers MUST check the exit code, never assume a numeric result
  # (a silently fabricated epoch previously corrupted TTL/age math -- #634).
  local iso="$1"
  date -u -d "$iso" +%s 2>/dev/null && return 0
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null && return 0
  return 1
}

bump_parse_failure_counter() {
  # $1 = field name under .prs["<PR>"].babysit, $2 = limit. Echoes the new
  # count on stdout (always -- callers can log it regardless of outcome).
  # Returns 0 while still under the limit (caller keeps its safe default).
  # Returns 1 once the count reaches the limit, OR if persisting the
  # increment itself fails -- an untrackable counter can never be trusted to
  # self-heal, so a write failure is treated the same as "limit reached"
  # (#634: a bounded counter that can silently fail to persist is really an
  # unbounded one).
  local field="$1" limit="$2" raw count
  raw=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].babysit.$field" 2>/dev/null)
  [[ "$raw" =~ ^[0-9]+$ ]] || raw=0   # missing/null/corrupt -> 0, never feed raw jq output to arithmetic
  count=$(( raw + 1 ))
  echo "$count"
  "$SESSION_STATE_SH" --set ".prs[\"$PR\"].babysit.$field=$count" >/dev/null 2>&1 || return 1
  (( count < limit ))
}
```

**Always read/write `session-state.json` via `session-state.sh --get`/`--set`** (atomic, sibling-preserving) — never raw `jq` writes (`handoff-files.md`). State for this skill lives under `.prs["<N>"]`:

- Backoff fields reuse the **shared schema fields** `.prs["<N>"].digest` and `.prs["<N>"].digest_streak` (per `scheduling-reliability.md` / `session-state-schema.json`) so the backoff watchdog sees a consistent streak.
- Babysit-specific fields live under a nested `.prs["<N>"].babysit` object so they don't collide with phase/reviewer fields other skills write.

```jsonc
// .prs["<N>"].babysit
{
  "active": true,
  "started_at": "2026-06-25T19:00:00Z",
  "last_tick_at": "2026-06-25T19:00:00Z",   // refreshed every tick — freshness signal for A2
  "last_tick_parse_failures": 0, // consecutive A2 to_epoch() failures on last_tick_at; treated as stale (reclaimed) at BABYSIT_PARSE_FAIL_LIMIT (default 3)
  "cadence_base_minutes": 5,
  "cadence_effective_minutes": 5,
  "tick_count": 0,
  "blocker_streak": 0,          // consecutive blocker-state ticks (drives --max-iter)
  "max_blocker_ticks": 6,
  "silent": false,
  "durable": false,
  "stop_requested": false,      // set true by /babysit-pr-stop
  "dispatch_in_flight": null,   // {"skill":"fixpr"|"wrap","started_at":"…"} while a dispatch runs
  "dispatch_parse_failures": 0, // consecutive T0 to_epoch() failures on dispatch_in_flight.started_at; force-reclaimed at BABYSIT_PARSE_FAIL_LIMIT (default 3)
  "last_dispatch": null,        // {"skill":"…","started_at":"…","completed_at":"…","status":"…"}
  "cron_job_id": null           // set when --durable arms a CronCreate job
}
```

---

## ARM MODE

Run only when invoked **without** `--tick`.

### A1. Validate the PR

```bash
PR_JSON=$(gh pr view "$PR" --json number,state,headRefOid 2>&1) || {
  echo "ERROR: PR #$PR not found or gh failed: $PR_JSON" >&2; exit 1; }
PR_PR_STATE=$(jq -r '.state' <<<"$PR_JSON")     # OPEN | MERGED | CLOSED
if [[ "$PR_PR_STATE" != "OPEN" ]]; then
  echo "PR #$PR is $PR_PR_STATE — nothing to babysit."; exit 0
fi
```

### A2. Refuse duplicate watchers (idempotent setup)

A live watcher writes `babysit.last_tick_at` every tick (T5). Treat `active == true` as a duplicate **only when the watcher is actually fresh** — otherwise a crashed/aborted session would leave `active=true` forever and brick re-arm. The freshness window is generous: `3 ×` the effective cadence, floored at the dispatch TTL (`BABYSIT_DISPATCH_TTL_MIN`, default 30m) so a long in-flight `/fixpr` never looks dead.

```bash
ALREADY=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].babysit.active"); RC=$?
if [[ "$RC" -eq 3 ]]; then ALREADY="null"; elif [[ "$RC" -ne 0 ]]; then
  echo "ERROR: session-state.sh --get failed (exit $RC) — aborting arm to avoid double-watch." >&2; exit "$RC"
fi
if [[ "$ALREADY" == "true" ]]; then
  LAST_TICK=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].babysit.last_tick_at" 2>/dev/null || echo "")
  EFF_MIN=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].babysit.cadence_effective_minutes" 2>/dev/null || echo 5)
  [[ "$EFF_MIN" =~ ^[0-9]+$ ]] || EFF_MIN=5
  FRESH_MIN=$(( EFF_MIN * 3 )); (( FRESH_MIN < ${BABYSIT_DISPATCH_TTL_MIN:-30} )) && FRESH_MIN=${BABYSIT_DISPATCH_TTL_MIN:-30}
  PARSE_FAIL_LIMIT="${BABYSIT_PARSE_FAIL_LIMIT:-3}"
  AGE_MIN=999999
  if [[ -n "$LAST_TICK" && "$LAST_TICK" != "null" ]]; then
    if LAST_TICK_EPOCH=$(to_epoch "$LAST_TICK"); then
      AGE_MIN=$(( ( $(date -u +%s) - LAST_TICK_EPOCH ) / 60 ))
      "$SESSION_STATE_SH" --set ".prs[\"$PR\"].babysit.last_tick_parse_failures=0" >/dev/null 2>&1 || true
    else
      if A2_FAIL_COUNT=$(bump_parse_failure_counter last_tick_parse_failures "$PARSE_FAIL_LIMIT"); then
        echo "WARNING: could not parse babysit.last_tick_at ('$LAST_TICK') as epoch on this platform's date (failure ${A2_FAIL_COUNT}/${PARSE_FAIL_LIMIT}) — treating watcher as fresh (safe default) instead of reclaiming it blind. If this persists, run /babysit-pr-stop $PR." >&2
        AGE_MIN=0
      else
        echo "WARNING: babysit.last_tick_at ('$LAST_TICK') failed to parse ${A2_FAIL_COUNT} arm attempts in a row, or the failure counter itself could not be persisted — treating watcher slot as corrupted and reclaiming it rather than blocking re-arm forever." >&2
        # AGE_MIN stays at its 999999 default above -> falls through to the stale/reclaim path below.
      fi
    fi
  fi
  if (( AGE_MIN < FRESH_MIN )); then
    echo "Already babysitting PR #$PR (last tick ${AGE_MIN}m ago) — not arming a second watcher. Use /babysit-pr-stop $PR to stop."
    exit 0
  fi
  echo "[babysit] stale watcher for PR #$PR (last tick ${AGE_MIN}m ago ≥ ${FRESH_MIN}m) — reclaiming and re-arming."
fi
```

### A3. Initialize state and arm the poll

Write the babysit object (one atomic `--set` batch), seeding backoff fields to a neutral start:

```bash
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
"$SESSION_STATE_SH" \
  --set ".prs[\"$PR\"].babysit={\"active\":true,\"started_at\":\"$NOW\",\"last_tick_at\":\"$NOW\",\"last_tick_parse_failures\":0,\"cadence_base_minutes\":$BASE_MIN,\"cadence_effective_minutes\":$BASE_MIN,\"tick_count\":0,\"blocker_streak\":0,\"max_blocker_ticks\":$MAX_ITER,\"silent\":$SILENT,\"durable\":$DURABLE,\"stop_requested\":false,\"dispatch_in_flight\":null,\"dispatch_parse_failures\":0,\"last_dispatch\":null,\"cron_job_id\":null}" \
  --set ".prs[\"$PR\"].digest_streak=0"
```

Arm the recurring poll. **`/loop` is the default primitive** (`scheduling-reliability.md` decision tree); `CronCreate` only when `--durable` is set (cross-session durability).

- **`/loop` (default):** arm `/loop <cadence> /babysit-pr <PR> --tick`. The runtime owns the cadence and re-arms each cycle.
- **`--durable` (CronCreate):** pick an off-peak minute via `.claude/scripts/off-peak-minute.sh`, create a recurring (`recurring: true`, `durable: true`) job whose prompt is `/babysit-pr <PR> --tick`, and persist the returned job id to `.prs["<N>"].babysit.cron_job_id` and to top-level `polling_jobs[]` (so `/babysit-pr-stop` and recovery can find it).

Then **run one tick immediately** (fall through to TICK MODE below) so the user gets instant feedback, and emit the initial heartbeat. Per the `scheduling-reliability.md` **pre-exit checklist**, before ending the arm turn confirm: (1) the next tick is scheduled (loop active / cron created), (2) a timestamped heartbeat was sent, (3) state was recorded.

---

## TICK MODE

Run on every poll cycle (and once at the end of arm mode). One tick = classify → maybe dispatch → bookkeep → maybe re-arm cadence → heartbeat.

### T0. Stop / terminal short-circuit (check FIRST)

```bash
STOP=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].babysit.stop_requested" 2>/dev/null || echo "false")
ACTIVE=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].babysit.active" 2>/dev/null || echo "false")
if [[ "$STOP" == "true" || "$ACTIVE" != "true" ]]; then
  # user ran /babysit-pr-stop, or state was cleared — terminate cleanly
  goto TERMINATE with reason="user-stop"
fi
```

If `dispatch_in_flight` is set, decide whether it is **still running** or **stale** using an explicit TTL (`BABYSIT_DISPATCH_TTL_MIN`, default `30` — comfortably longer than `/fixpr`'s 20-min wait cap plus `/wrap` recovery, so a live dispatch is never mistaken for stale).

A `started_at` that fails to parse on **both** GNU and BSD `date` (see `to_epoch()` above) is treated as still-running for that tick — the safe direction, since this check runs every tick unattended and wrongly reclaiming a live dispatch causes a duplicate `/fixpr`/`/wrap` run. But "safe for one tick" must not mean "stuck forever" if the value is genuinely corrupted (not just a transient hiccup): `dispatch_parse_failures` counts consecutive parse failures for the current `dispatch_in_flight`, and once it reaches `BABYSIT_PARSE_FAIL_LIMIT` (default `3`) the entry is force-reclaimed as corrupted rather than left blocking indefinitely:

```bash
TTL_MIN="${BABYSIT_DISPATCH_TTL_MIN:-30}"
PARSE_FAIL_LIMIT="${BABYSIT_PARSE_FAIL_LIMIT:-3}"
IN_FLIGHT=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].babysit.dispatch_in_flight" 2>/dev/null || echo "null")
DISPATCH_BLOCKING=0
if [[ "$IN_FLIGHT" != "null" && -n "$IN_FLIGHT" ]]; then
  STARTED=$(jq -r '.started_at // empty' <<<"$IN_FLIGHT")
  RECLAIM_REASON=""
  if STARTED_EPOCH=$(to_epoch "$STARTED"); then
    AGE_MIN=$(( ( $(date -u +%s) - STARTED_EPOCH ) / 60 ))
    "$SESSION_STATE_SH" --set ".prs[\"$PR\"].babysit.dispatch_parse_failures=0" >/dev/null 2>&1 || true
    (( AGE_MIN >= TTL_MIN )) && RECLAIM_REASON="stale (age ${AGE_MIN}m >= ${TTL_MIN}m TTL)"
  else
    if FAIL_COUNT=$(bump_parse_failure_counter dispatch_parse_failures "$PARSE_FAIL_LIMIT"); then
      echo "WARNING: could not parse dispatch_in_flight.started_at ('$STARTED') as epoch on this platform's date (failure ${FAIL_COUNT}/${PARSE_FAIL_LIMIT}) — treating dispatch as still in-flight this tick. If this persists, run /babysit-pr-stop $PR." >&2
    else
      echo "WARNING: dispatch_in_flight.started_at ('$STARTED') failed to parse ${FAIL_COUNT} ticks in a row, or the failure counter itself could not be persisted — treating as corrupted and force-reclaiming rather than blocking forever." >&2
      RECLAIM_REASON="corrupted (unparseable started_at, parse-failure counter reached ${PARSE_FAIL_LIMIT} or could not be persisted)"
    fi
  fi
  if [[ -n "$RECLAIM_REASON" ]]; then
    # Stale (TTL exceeded) or corrupted (parse-fail limit exceeded): reclaim so it never blocks forever.
    "$SESSION_STATE_SH" \
      --set ".prs[\"$PR\"].babysit.last_dispatch=$(jq -c '. + {completed_at: (now|todate), status: "stale-reclaimed"}' <<<"$IN_FLIGHT")" \
      --set ".prs[\"$PR\"].babysit.dispatch_in_flight=null" \
      --set ".prs[\"$PR\"].babysit.dispatch_parse_failures=0"
    echo "[babysit] reclaimed $RECLAIM_REASON dispatch — proceeding"
  else
    DISPATCH_BLOCKING=1            # a prior tick's /fixpr or /wrap is genuinely still running (or unparseable, within grace)
  fi
fi
```

If `DISPATCH_BLOCKING == 1`, **skip this tick's dispatch** (idempotency — see T4): emit a "dispatch in progress" heartbeat and finish the tick without classifying-and-dispatching on top of the running dispatch. Otherwise continue normally (a stale or corrupted in-flight has been reclaimed above).

### T1. Read PR state (the two shared scripts — never re-implement)

```bash
# Authoritative merge-readiness + blocker breakdown.
GATE_JSON=$("$MERGE_GATE_SH" "$PR"); GATE_EXIT=$?
```

**Fail closed before classifying** — `merge-gate.sh` exit codes are: `0` met (valid JSON), `1` not-met (valid JSON), `2` usage error, `3` PR not found/closed/merged, `4` gh/jq error. Only `0`/`1` produce real gate JSON. Do **not** let a transient tooling failure (`2`/`4`) or a bad `gh pr view` fall through into the jq parsing below — that would manufacture a bogus classification or dispatch:

```bash
case "$GATE_EXIT" in
  0|1) ;;                                  # valid gate JSON — proceed to classify
  3)  # PR not found / closed / merged — let T3's terminal handling decide (merged vs closed)
      PR_NOW=$(gh pr view "$PR" --json state --jq '{state}' 2>/dev/null || echo '{}')
      # fall through to T3 with GATE_JSON unused; T3 row 1/2 classify merged/closed
      SKIP_STATE_READ=1 ;;
  *)  # exit 2/4/other — tooling/transient error. Heartbeat + skip this tick (no classify, no dispatch).
      TS=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET')
      echo "[$TS] #$PR tick: merge-gate.sh failed (exit $GATE_EXIT) — skipping classification this tick, retrying next cadence."
      # update last_tick_at so A2 freshness still reflects a live watcher, then end the tick
      "$SESSION_STATE_SH" --set ".prs[\"$PR\"].babysit.last_tick_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" 2>/dev/null || true
      return 0 2>/dev/null || exit 0 ;;
esac
```

When `SKIP_STATE_READ` is unset, fetch the full state bundle (findings/threads/CI/SHA). Guard `gh pr view` and `pr-state.sh` the same way — a non-zero exit means skip the tick, never classify on empty data:

```bash
if [[ -z "${SKIP_STATE_READ:-}" ]]; then
  PR_CREATED=$(gh pr view "$PR" --json createdAt --jq '.createdAt') || {
    echo "[babysit] gh pr view failed — skipping tick, retry next cadence." >&2; exit 0; }
  BUNDLE=$("$PR_STATE_SH" --pr "$PR" --since "$PR_CREATED") || {
    echo "[babysit] pr-state.sh failed — skipping tick, retry next cadence." >&2; exit 0; }
fi
```

### T1b. Pre-flight — draft→ready + four-reviewer trigger (issue #493)

**Run after the gate-exit check (which sets `SKIP_STATE_READ`), then re-fetch `GATE_JSON` and `BUNDLE` so that T1c field extraction and T3 classification operate on post-trigger snapshots.** A reviewer just engaged by pre-flight is not misclassified as "missing" and does not cause a spurious `/fixpr` dispatch on the same tick.

Run the shared `pr-preflight.sh` so a draft PR you own is flipped ready and all four conditionally-triggered reviewers (CodeAnt, CodeRabbit, Cursor, Graphite) are engaged on the current SHA before T2/T3 decide anything. This is the **same** script `/fixpr` Step 0c and `/pr-monitor-and-manage` use — `/babysit-pr` never re-implements the draft flip or trigger logic. Since #576 "engaged on the current SHA" is enforced rather than assumed: a reviewer whose only artifact is on a superseded commit is re-triggered, so a PR does not sit in `waiting-on-bots` relying on each bot's own auto-review-on-push. It is idempotent (a PR whose reviewers are all fresh on HEAD is a no-op), rate-cap safe (skips only `@coderabbitai full review` when `cr-review-hourly.sh` reports the cap hit, posting the other three), never flips another user's draft, and never triggers Greptile.

Run **only** on a valid state read (skip when `SKIP_STATE_READ=1` — a gone/merged/closed PR needs no pre-flight):

```bash
PREFLIGHT_SUMMARY_JSON=""
if [[ -z "${SKIP_STATE_READ:-}" && -n "$PREFLIGHT_SH" ]]; then
  PREFLIGHT_OUT=$("$PREFLIGHT_SH" "$PR") || echo "[babysit] pr-preflight.sh exited non-zero (exit $?) — continuing tick" >&2
  echo "$PREFLIGHT_OUT"   # its timestamped action lines double as part of this tick's heartbeat
  PREFLIGHT_SUMMARY_JSON=$(sed -n 's/^PREFLIGHT_SUMMARY: //p' <<<"$PREFLIGHT_OUT")
elif [[ -z "$PREFLIGHT_SH" && -z "${SKIP_STATE_READ:-}" ]]; then
  echo "[babysit] pr-preflight.sh not found — skipping draft/reviewer pre-flight this tick"
fi
```

Re-fetch `GATE_JSON` and `BUNDLE` after pre-flight so that any reviewer or draft-state change made by pre-flight is captured before T3 classifies. Guard the same way as T1 — skip the tick on tooling error:

```bash
if [[ -z "${SKIP_STATE_READ:-}" ]]; then
  GATE_JSON=$("$MERGE_GATE_SH" "$PR"); GATE_EXIT=$?
  if [[ "$GATE_EXIT" != "0" && "$GATE_EXIT" != "1" ]]; then
    TS=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET')
    echo "[$TS] #$PR tick: merge-gate.sh post-preflight re-fetch failed (exit $GATE_EXIT) — skipping classification this tick."
    "$SESSION_STATE_SH" --set ".prs[\"$PR\"].babysit.last_tick_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" 2>/dev/null || true
    return 0 2>/dev/null || exit 0
  fi
  PR_CREATED=$(gh pr view "$PR" --json createdAt --jq '.createdAt') || {
    echo "[babysit] gh pr view failed (post-preflight re-fetch) — skipping tick, retry next cadence." >&2; exit 0; }
  BUNDLE=$("$PR_STATE_SH" --pr "$PR" --since "$PR_CREATED") || {
    echo "[babysit] pr-state.sh failed (post-preflight re-fetch) — skipping tick, retry next cadence." >&2; exit 0; }
fi
```

### T1c. Extract fields from post-preflight snapshots

Pull the fields the classifier needs (only when `GATE_EXIT` was `0`/`1` and the bundle was read). These snapshots were taken after pre-flight ran, so they reflect the post-trigger bot state:

```bash
HEAD_SHA=$(jq -r '.head_sha // ""'                 <<<"$GATE_JSON")
GATE_MET=$(jq -r '.met'                            <<<"$GATE_JSON")
HUMAN_CR=$(jq -r '.human_changes_requested | length' <<<"$GATE_JSON")
MERGE_STATE=$(jq -r '.merge_state // ""'           <<<"$GATE_JSON")
MERGEABLE=$(jq -r '.mergeable // ""'               <<<"$GATE_JSON")
CI_FAILING=$(jq -r '.ci_status.failing // 0'       <<<"$GATE_JSON")
CI_INCOMPLETE=$(jq -r '.ci_status.in_progress // 0' <<<"$GATE_JSON")
STALE_BOT_CR=$(jq -r '.stale_bot_changes_requested_count // 0' <<<"$GATE_JSON")
MISSING=$(jq -r '.missing | join(" | ")'           <<<"$GATE_JSON")
# Sorted blocking CI conclusions — the `ci_blocking_conclusions_sorted` field of
# the T5 digest tuple. merge-gate.sh exposes blocking runs as .ci_status.blocking[].
CI_BLOCKING_SORTED=$(jq -r '[.ci_status.blocking[].conclusion] | sort | join(",")' <<<"$GATE_JSON")

UNRESOLVED=$(jq -r '.threads.unresolved_count'      < "$BUNDLE")
NEW_FINDINGS=$(jq -r '.new_since_baseline.finding_count // 0' < "$BUNDLE")
CR_STATE=$(jq -r '.bot_statuses.CodeRabbit.state // "none"'   < "$BUNDLE")
GREP_STATE=$(jq -r '.bot_statuses.Greptile.state // "none"'   < "$BUNDLE")
# BugBot reports via check-run, not commit status; derive a coarse state.
BUGBOT_STATE=$(jq -r '[.check_runs.all[] | select((.name//""|ascii_downcase)|contains("cursor") or contains("bugbot"))] | (if length==0 then "none" elif any(.[]; .status!="completed") then "pending" else "done" end)' < "$BUNDLE" 2>/dev/null || echo "none")
```

(When `SKIP_STATE_READ=1` was set above — gate exit `3` — skip straight to T3's terminal handling, which classifies `merged` vs `closed-unmerged` from `PR_NOW`.)

Record the draft→ready action and any triggered reviewers in the T7 heartbeat / final summary from `$PREFLIGHT_SUMMARY_JSON`.

### T2. Rate-cap snapshot (MUST run before classification)

`/babysit-pr` never posts review triggers itself — `/fixpr` owns triggers and their caps. But the **classifier (T3) must already know** the budget state, so this snapshot runs **first**: it decides whether "missing fresh bot review" is a recoverable gap (a reviewer can still be triggered) or a `hard-blocked` budget-exhaustion (no path to the gate this window).

```bash
CR_BUDGET_OK=1; GREP_BUDGET_OK=1
if [[ -n "$CR_HOURLY_SH" ]]; then "$CR_HOURLY_SH" --check >/dev/null 2>&1 || CR_BUDGET_OK=0; fi
if [[ -n "$GREPTILE_SH" ]]; then "$GREPTILE_SH" --check >/dev/null 2>&1 || GREP_BUDGET_OK=0; fi
```

- **CodeRabbit:** `cr-review-hourly.sh --check` exit `1` ⇒ `CR_BUDGET_OK=0` (hourly budget exhausted). `/babysit-pr` only consults `--check`, never consumes — `/fixpr`'s own `--record-explicit` enforces the ≤2/PR/hour cap atomically when it actually posts `@coderabbitai full review`.
- **Greptile:** `greptile-budget.sh --check` exit `1` ⇒ `GREP_BUDGET_OK=0` (daily budget exhausted).
- **BugBot (`@cursor review`):** per-seat, no per-call charge — always safe (`bugbot.md`). Never gate on it.

The classifier (T3) consumes `CR_BUDGET_OK` / `GREP_BUDGET_OK`: a PR whose only gap is a fresh review becomes `hard-blocked` (budget exhaustion) **only** when CR **and** Greptile are both exhausted and there is no other recoverable work; otherwise it stays `waiting-on-bots` (a trigger path still exists). Re-running `/babysit-pr` after the window resets resumes cleanly.

### T3. Classify (first match wins, in this order)

Re-fetch the authoritative open/merged state once:

```bash
PR_NOW=$(gh pr view "$PR" --json state --jq '{state}')
PR_STATE_NOW=$(jq -r '.state' <<<"$PR_NOW")
PR_MERGED=$(jq -r '(.state == "MERGED")' <<<"$PR_NOW")
```

| # | Class | Condition | Action |
|---|-------|-----------|--------|
| 1 | `merged` | `PR_MERGED == true` (or gate exit 3 because merged) | **Exit** — terminal success. |
| 2 | `hard-blocked` | `HUMAN_CR > 0` (human `CHANGES_REQUESTED` on HEAD), **or** PR `CLOSED` unmerged, **or** the only gap is a fresh review and both budgets are exhausted (`CR_BUDGET_OK == 0 && GREP_BUDGET_OK == 0`, from T2), **or** a Greptile P0 needing design input persists | **Record blocker, exit.** Never auto-dismiss. |
| 3 | `merge-ready` | `GATE_MET == true` (gate exit 0) | **Dispatch `/wrap`** (T4). |
| 4 | `has-recoverable-blockers` | gate exit 1 **and** any of: `UNRESOLVED > 0`, `NEW_FINDINGS > 0`, `CI_FAILING > 0`, `STALE_BOT_CR > 0`, `MERGE_STATE` ∈ {`BEHIND`,`DIRTY`}, `MERGEABLE == CONFLICTING` | **Dispatch `/fixpr`** (T4). |
| 5 | `waiting-on-bots` | gate exit 1 and the only gaps are pending review/CI: `CI_INCOMPLETE > 0`, or a missing-but-pending bot approval / `REVIEW_REQUIRED` with no findings/threads/failing-CI (and at least one review budget remains per T2) | **Heartbeat only, no dispatch.** Bots are still working on the current SHA. |

`waiting-on-bots` is the "do nothing, just wait" state — the gate isn't met but there is nothing actionable yet (no findings to fix, no threads to resolve, CI still running, a bot hasn't posted its verdict). Do **not** dispatch `/fixpr` here — that would burn CR/CI cycles on a PR that just needs time. `/fixpr` owns its own bounded post-push wait (#454); `/babysit-pr` simply tolerates the gap across ticks.

### T4. Dispatch with idempotency (`session-state.json` is the source of truth)

Only classes `merge-ready` (→ `/wrap`) and `has-recoverable-blockers` (→ `/fixpr`) dispatch.

1. **Idempotency guard (already evaluated in T0).** `DISPATCH_BLOCKING` from T0 is authoritative: it is `1` only when a prior `dispatch_in_flight` is **within** the `BABYSIT_DISPATCH_TTL_MIN` window (genuinely still running) — a stale entry was already reclaimed to `null` there. If `DISPATCH_BLOCKING == 1`, **refuse to re-dispatch**: emit "dispatch in progress (<skill>), skipping" and finish the tick. This prevents two overlapping `/fixpr` (or `/wrap`) runs racing on the same PR when a dispatch outlives the cadence, while the TTL guarantees a crashed dispatch cannot wedge the watcher forever.
2. **Mark in-flight before invoking:**

   ```bash
   START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
   "$SESSION_STATE_SH" \
     --set ".prs[\"$PR\"].babysit.dispatch_in_flight={\"skill\":\"$TARGET\",\"started_at\":\"$START\"}" \
     --set ".prs[\"$PR\"].babysit.dispatch_parse_failures=0"
   ```

3. **Invoke the full skill.** Execute the complete `.claude/skills/$TARGET/SKILL.md` workflow inline (or via a Phase A subagent in `bypassPermissions` mode with the `safety.md` block when the parent is in monitor mode — `subagent-orchestration.md`). `/fixpr` runs Steps 0–7 including its Step 4d post-push wait; `/wrap` runs its merge-gate recovery + AC + squash-merge + main-sync. **Do not shortcut either.**
4. **Clear in-flight after it returns:**

   ```bash
   DONE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
   "$SESSION_STATE_SH" \
     --set ".prs[\"$PR\"].babysit.last_dispatch={\"skill\":\"$TARGET\",\"started_at\":\"$START\",\"completed_at\":\"$DONE\",\"status\":\"$DISPATCH_STATUS\"}" \
     --set ".prs[\"$PR\"].babysit.dispatch_in_flight=null"
   ```

   `DISPATCH_STATUS` = the parsed `Status:` / `FIXPR_WRAP_STATUS:` from `/fixpr`, or `merged`/`blocked`/`stopped` from `/wrap`.
5. **On dispatch error:** record `status: "error"`, clear `dispatch_in_flight`, do **not** retry within this tick — the next tick re-classifies from scratch.

After a `/wrap` dispatch that reports the PR merged, the next tick (T3 #1) sees `merged` and terminates. After a `/fixpr` dispatch, the next tick re-reads state on the new SHA.

### T5. Backoff + bookkeeping (`scheduling-reliability.md` stable-state backoff)

Compute the per-tick **digest** over the canonical tuple (free-text blockers excluded):

```
digest = sha256( head_sha | cr_state | bugbot_state | greptile_state | ci_blocking_conclusions_sorted | blocker_kind )
```

where `blocker_kind` is the classification name (`merge-ready` / `has-recoverable-blockers` / `waiting-on-bots` / `hard-blocked`) and `ci_blocking_conclusions_sorted` is the sorted list of blocking CI conclusions from the gate JSON.

```bash
DIGEST=$(printf '%s|%s|%s|%s|%s|%s' "$HEAD_SHA" "$CR_STATE" "$BUGBOT_STATE" "$GREP_STATE" "$CI_BLOCKING_SORTED" "$CLASS" | sha256sum | awk '{print "sha256:"$1}')
PREV_DIGEST=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].digest" 2>/dev/null || echo "null")
PREV_STREAK=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].digest_streak" 2>/dev/null || echo 0)
[[ "$PREV_STREAK" =~ ^[0-9]+$ ]] || PREV_STREAK=0
if [[ "$DIGEST" == "$PREV_DIGEST" ]]; then STREAK=$((PREV_STREAK + 1)); else STREAK=1; fi
```

**Cadence tiers** (`scheduling-reliability.md` widens a stable state and stops a frozen one). The widened cadence is **derived from the configured base**, never hard-coded, so it is **always slower than the base** regardless of `--cadence`:

```bash
# Widened cadence: at least 15m, and at least 3× the base — whichever is larger.
# base 5m → 15m (satisfies the AC); base 1m → 15m; base 20m → 60m (still slower).
WIDE_MIN=$(( BASE_MIN * 3 )); (( WIDE_MIN < 15 )) && WIDE_MIN=15
(( WIDE_MIN < BASE_MIN )) && WIDE_MIN=$BASE_MIN     # guard: never faster than base
```

| `digest_streak` | Effective cadence |
|-----------------|-------------------|
| `< 3` | base (`--cadence`, default 5m) |
| `>= 3` | `WIDE_MIN` = `max(15m, 3 × base)` — for the default 5m base this is **15m** (satisfies the AC) |
| `>= 9` | **terminate** (truly frozen — cancel `/loop`; `CronDelete` in durable mode) |

**Revert to base cadence on any state change** (digest differs → `STREAK` reset to 1 → `cadence_effective_minutes` returns to `BASE_MIN`).

**Blocker-streak** (drives `--max-iter` termination): a tick is a *blocker-state tick* when `CLASS` ∈ {`has-recoverable-blockers`, `waiting-on-bots`} **and** the digest did not change (no forward progress). Increment `blocker_streak` on such ticks; reset to `0` on `merge-ready`/`merged` or on any digest change.

Persist all counters atomically, then increment the tick count. `$DIGEST` (the `sha256:…` string computed above) is not valid JSON, so `session-state.sh --set` stores it as a string literal:

```bash
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
"$SESSION_STATE_SH" \
  --set ".prs[\"$PR\"].digest=$DIGEST" \
  --set ".prs[\"$PR\"].digest_streak=$STREAK" \
  --set ".prs[\"$PR\"].babysit.blocker_streak=$BLOCKER_STREAK" \
  --set ".prs[\"$PR\"].babysit.tick_count=$NEW_TICK_COUNT" \
  --set ".prs[\"$PR\"].babysit.cadence_effective_minutes=$EFFECTIVE_MIN" \
  --set ".prs[\"$PR\"].babysit.last_tick_at=$NOW"
```

**Re-arm cadence only when it crosses a tier boundary.** `/loop` owns the cadence, so to change it: stop the current loop and re-arm `/loop <new-cadence> /babysit-pr <PR> --tick` (durable mode: `CronUpdate`/recreate the job at the new minute-range, persisting the new id). If the effective cadence is unchanged, do nothing — never re-arm an unchanged loop (forbidden hand-rolled re-arm churn).

### T6. Termination check

Terminate (→ T-END) when **any** hold:

- `CLASS == merged` → reason `merged`.
- `CLASS == hard-blocked` → reason `hard-blocked` (record the specific blocker: human reviewer login(s), conflict, budget exhaustion, persistent P0).
- PR `CLOSED` unmerged → reason `closed-unmerged`.
- `blocker_streak >= max_blocker_ticks` (default 6) → reason `blocker-tick-cap` (≈90 min once backed off to 15m).
- `digest_streak >= 9` → reason `stable-frozen` (`scheduling-reliability.md` ≥9 stop).
- `stop_requested == true` / `active != true` → reason `user-stop`.

Otherwise the loop continues — the next cycle re-enters tick mode.

### T7. Heartbeat (per tick — never silent by default)

Always run a `date` for the timestamp (never estimate — `monitor-mode.md`):

```bash
TS=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET')
```

One-liner format:

```
[<TS>] #<PR> tick <n>: state=<class>, action=<dispatch /fixpr | dispatch /wrap | no-op | waiting | dispatch-in-progress>, next in <effective-cadence>
```

Append context: blocker reason on `hard-blocked`/`waiting-on-bots`; dispatch target on a dispatch; `(backoff: stable ×<streak>, widened to <WIDE_MIN>m)` when cadence widened; the final summary on termination.

**`--silent`:** suppress the line on plain `waiting-on-bots`/no-change ticks, but **always** print on state change, any dispatch, backoff transitions, and termination. (Default — no `--silent` — prints every tick, satisfying the per-tick heartbeat AC.)

### T-END. Terminate cleanly

```bash
"$SESSION_STATE_SH" \
  --set ".prs[\"$PR\"].babysit.active=false" \
  --set ".prs[\"$PR\"].babysit.dispatch_in_flight=null"
```

**Cancelling the poll is a required terminal action — the loop does NOT lapse on its own** (`/loop` re-arms every cycle; `CronCreate` fires until deleted). Tear it down explicitly:

- **`/loop` mode (default):** cancel the active loop now (runtime loop-stop / "stop polling"). Do not re-arm it.
- **Durable mode:** **fail closed** — `CronDelete` the `cron_job_id` and only prune `polling_jobs[]` / clear the id **after** it succeeds, so a failed delete never leaves a cron firing against state that claims it's gone. `session-state.sh --set` cannot splice an array, so read → filter with `jq` (a read/transform) → write the new array back via `--set` (same supported delete path as `/babysit-pr-stop`):

  ```bash
  CRON_ID=$("$SESSION_STATE_SH" --get ".prs[\"$PR\"].babysit.cron_job_id") || CRON_ID=""
  if [[ -n "$CRON_ID" && "$CRON_ID" != "null" ]]; then
    CronDelete "$CRON_ID" || { echo "ERROR: CronDelete failed for $CRON_ID — leaving job recorded; re-run /babysit-pr-stop $PR." >&2; exit 1; }
    JOBS=$("$SESSION_STATE_SH" --get '.polling_jobs')
    if [[ "$JOBS" != "null" && -n "$JOBS" ]]; then
      NEW_JOBS=$(jq -c --arg id "$CRON_ID" 'map(select(.id != $id))' <<<"$JOBS")
    else
      NEW_JOBS='[]'
    fi
    "$SESSION_STATE_SH" --set ".polling_jobs=$NEW_JOBS" --set ".prs[\"$PR\"].babysit.cron_job_id=null"
  fi
  ```

Belt-and-suspenders: even if cancellation is delayed, the T0 short-circuit (`active != true`) makes every subsequent tick an immediate no-op terminate — but cancellation is still mandatory so the runtime stops invoking the watcher.

Emit the final summary:

```
=== babysit-pr complete ===
PR:           #<PR>
Pre-flight:   <last tick's draft→ready + reviewers triggered, from $PREFLIGHT_SUMMARY_JSON; "clean" when no-op across ticks>
Final state:  <class>
Reason:       merged | hard-blocked | closed-unmerged | blocker-tick-cap | stable-frozen | user-stop
Ticks:        <tick_count>
Dispatches:   <count> (/fixpr ×N, /wrap ×M)
Last dispatch: <skill> → <status>
Blocker:      <named blocker when hard-blocked / blocker-tick-cap, else "none">
```

---

## Notes

- **Stop anytime:** `/babysit-pr-stop <PR>` sets `stop_requested=true` (and `CronDelete`s in durable mode); the next tick's T0 terminates cleanly. See `.claude/skills/babysit-pr-stop/SKILL.md`.
- **One watcher per PR** — arm mode refuses a duplicate (A2).
- **Monitor mode:** while a dispatch subagent is in flight, the parent follows `monitor-mode.md` (orchestration only, ≤5-min heartbeat). The per-tick heartbeat satisfies the heartbeat requirement.
- **Post-merge install:** after this skill lands on `main`, symlink it globally via the skills worktree per `skill-symlinks.md`.
