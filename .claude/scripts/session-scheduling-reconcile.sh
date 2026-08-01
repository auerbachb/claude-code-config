#!/usr/bin/env bash
# session-scheduling-reconcile.sh — reconcile durable scheduling state at
# session start (issues #827, #874).
#
# CronCreate jobs are in-memory and session-scoped: every job recorded by a
# previous session is already gone by the time this runs. Rather than trying to
# re-arm them (there is nothing left to re-arm), this purges the dead
# bookkeeping and surfaces the durable on-disk records that DO survive — a
# harness-audit month that came due, a paused PR fleet waiting to resume.
#
# Issue #874 FIX — multi-session safety:
#   SessionStart fires across concurrent sessions sharing the same HOME.
#   A newly-started session must NOT purge bookkeeping that belongs to a live
#   sibling session.
#
#   For .polling_jobs[] and .pmm.auto_wake_cron_id each record now carries an
#   optional owner_session stamp ({pid, host}). This script checks that stamp
#   with kill -0 — the same dead-holder test state-lock.sh uses — and reaps
#   ONLY records whose owning process is provably dead on this host.
#
#   Fail-closed: a record with no stamp, a cross-host stamp, or a stamp whose
#   liveness cannot be determined is SKIPPED, not purged. A notice is surfaced
#   so the operator can see it.
#
#   .repos[*].prs[*].babysit.active is already protected by the freshness
#   window (max(3 x cadence, BABYSIT_DISPATCH_TTL_MIN)): a live watcher in a
#   sibling session ticks recently enough that its last_tick_at is inside the
#   window and it is never reaped. No change to that path.
#
# Rationale: .claude/reference/cross-session-durability.md
#
# Fail-soft by contract: a missing, unreadable, or corrupt state file must
# never block a session from starting, so every failure path still exits 0.

set -uo pipefail

STATE_FILE="${HOME}/.claude/session-state.json"
AUDIT_WATERMARK="${HOME}/.claude/harness-audit/last-run.json"

usage() {
  cat <<'EOF'
PURPOSE
  Reconcile durable scheduling state at session start: purge scheduler
  bookkeeping whose owning session is provably dead, and report the on-disk
  records that did survive.

USAGE
  session-scheduling-reconcile.sh [--check] [--format text|json]

  --check          Report only; make no writes. Exit 0 always.
  --format text    Human-readable lines (default).
  --format json    {"purged":{...},"notices":[...]} for the hook to embed.

WHAT IT PURGES (writes go through session-state.sh, the locked single writer)
  .polling_jobs[]                      -> entry removed when owner_session.pid
                                          is dead on this host (kill -0 fails).
                                          Entries with no stamp or cross-host
                                          stamp are SKIPPED (fail-closed).
  .pmm.auto_wake_cron_id               -> null when auto_wake_owner_session.pid
                                          is dead on this host. Skipped without
                                          a verifiable dead-owner stamp.
  .repos[*].prs[*].babysit.cron_job_id -> null (always dead: CronCreate jobs
                                          are in-memory and session-scoped)
  .repos[*].prs[*].babysit.active      -> false, but ONLY past /babysit-pr's
                                          own freshness window (its A2 check;
                                          canonical definition:
                                          .claude/reference/cross-session-durability.md
                                          "Freshness window"). SessionStart also
                                          fires on compact, when a live watcher's
                                          last tick is legitimately minutes old.

WHAT IT SURFACES (durable, still meaningful)
  harness-audit due this month  (~/.claude/harness-audit/last-run.json)
  a paused PR fleet             (.pmm.paused_at)
  unverifiable scheduling records (skipped due to unknown ownership)

EXIT STATUS
  0  Always. This runs on the session-start path; it never blocks a session.
EOF
}

CHECK_ONLY=0
FORMAT=text

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --format)
      [[ $# -ge 2 ]] || { echo "session-scheduling-reconcile.sh: --format needs a value" >&2; exit 0; }
      FORMAT="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "session-scheduling-reconcile.sh: unknown flag '$1'" >&2; exit 0 ;;
  esac
done

case "$FORMAT" in
  text|json) ;;
  *) echo "session-scheduling-reconcile.sh: --format must be text or json" >&2; exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || {
  # No jq: report nothing rather than guessing. Still a clean session start.
  [[ "$FORMAT" == json ]] && echo '{"purged":{},"notices":[]}'
  exit 0
}

NOTICES=()   # human-facing lines the hook forwards into session context
PURGED_JSON='{}'

# ---------------------------------------------------------------------------
# Session liveness helper — mirrors the dead-holder test in state-lock.sh.
# Fail-closed: anything we cannot verify is NOT treated as dead.
# ---------------------------------------------------------------------------
CURRENT_HOST="${HOSTNAME:-$(hostname 2>/dev/null || echo "")}"

# session_is_dead <pid> <host>
# Exit 0 (true) only when the owning session is provably dead on THIS host.
# Exit 1 (false) for alive, unknown, cross-host, or malformed input.
session_is_dead() {
  local pid="$1" host="$2"
  [[ -z "$pid" || -z "$host" || -z "$CURRENT_HOST" ]] && return 1   # unknown
  [[ "$host" != "$CURRENT_HOST" ]]                      && return 1   # cross-host
  [[ "$pid" =~ ^[0-9]+$ ]]                              || return 1   # malformed
  ! kill -0 "$pid" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 1. Purge dead scheduler bookkeeping
# ---------------------------------------------------------------------------
# Counting and rewriting happen in one jq pass over the whole document so the
# counts always describe the write that actually landed. `.prs` is addressed
# through `.repos[]` (the scoped layout, issue #638) AND at the top level, so a
# not-yet-migrated legacy file is reconciled too rather than silently skipped.

SESSION_STATE_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/session-state.sh"

# Migrate BEFORE planning. session-state.sh migrates a legacy top-level `.prs`
# into `.repos[...]` as a side effect of any write, THEN applies our assignments
# — so a plan built against the pre-migration layout would recreate a clean
# top-level record while the migrated scoped record kept its stale cron_job_id
# and active flag. Real consumers read the scoped path, so the purge would have
# looked successful and changed nothing that matters.
if [[ -f "$STATE_FILE" && -x "$SESSION_STATE_SH" && "$CHECK_ONLY" -eq 0 ]]; then
  "$SESSION_STATE_SH" --migrate >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Pre-compute per-record liveness verdicts for .polling_jobs[] and
# .pmm.auto_wake_cron_id before the main jq plan.
#
# These two fields lack the freshness-window protection that babysit watchers
# have, so we need explicit owner liveness checks. We do this in bash (kill -0
# is not available in jq) and pass the results in as JSON for the plan to use.
#
# Verdict values: "dead" | "alive" | "unknown"
# Fail-closed: unknown ownership => verdict "unknown" => skip (do not purge).
# ---------------------------------------------------------------------------
PJ_VERDICTS_JSON="[]"    # per-index verdict array for .polling_jobs[]
PJ_SNAPSHOT="[]"         # snapshot of .polling_jobs used for jq plan (index-aligned)
AW_VERDICT="unknown"     # verdict for .pmm.auto_wake_cron_id

if [[ -f "$STATE_FILE" ]]; then
  # --- .polling_jobs[] -------------------------------------------------------
  # Capture exactly one snapshot so the verdict index stays aligned with what
  # the jq plan sees: a concurrent --set between the bash read and the jq pass
  # would otherwise shift entries and mis-classify their verdicts.
  PJ_SNAPSHOT="$(jq -c '.polling_jobs // []' "$STATE_FILE" 2>/dev/null || echo "[]")"
  if jq -e 'length > 0' <<<"$PJ_SNAPSHOT" >/dev/null 2>&1; then
    VERDICTS=()
    while IFS=$'\t' read -r _idx pid host; do
      if session_is_dead "$pid" "$host"; then
        VERDICTS+=("\"dead\"")
      elif [[ -n "$pid" && -n "$host" && "$host" == "$CURRENT_HOST" ]]; then
        VERDICTS+=("\"alive\"")
      else
        VERDICTS+=("\"unknown\"")
      fi
    done < <(jq -r '
      to_entries[] |
      [ (.key | tostring),
        (.value.owner_session.pid  // "" | tostring),
        (.value.owner_session.host // "")
      ] | @tsv
    ' <<<"$PJ_SNAPSHOT" 2>/dev/null)
    if (( ${#VERDICTS[@]} > 0 )); then
      # IFS=, in a subshell to join without a trailing newline (printf avoids
      # the echo newline that would corrupt the JSON literal).
      PJ_VERDICTS_JSON="[$(IFS=,; printf '%s' "${VERDICTS[*]}")]"
    fi
  fi

  # --- .pmm.auto_wake_cron_id -----------------------------------------------
  # Check the sibling auto_wake_owner_session stamp; fail-closed if absent.
  if jq -e '(.pmm.auto_wake_cron_id? // null) != null' "$STATE_FILE" >/dev/null 2>&1; then
    RC_AW=0
    AW_OWNER="$(jq -rc '.pmm.auto_wake_owner_session // empty' "$STATE_FILE" 2>/dev/null)" \
      || RC_AW=$?
    if [[ -n "${AW_OWNER:-}" && "$RC_AW" -eq 0 ]]; then
      AW_PID="$(jq -r  '.pid  // ""' <<<"$AW_OWNER" 2>/dev/null || echo "")"
      AW_HOST="$(jq -r '.host // ""' <<<"$AW_OWNER" 2>/dev/null || echo "")"
      if session_is_dead "$AW_PID" "$AW_HOST"; then
        AW_VERDICT="dead"
      elif [[ -n "$AW_PID" && -n "$AW_HOST" && "$AW_HOST" == "$CURRENT_HOST" ]]; then
        AW_VERDICT="alive"
      fi
      # else: cross-host or malformed → stays "unknown"
    fi
    # No stamp at all → stays "unknown"
  fi
fi

if [[ -f "$STATE_FILE" ]]; then
  NOW_EPOCH="$(date -u +%s)"

  # Deciding a watcher is dead uses /babysit-pr's OWN freshness rule (its A2
  # duplicate-watcher check): a watcher is presumed alive within
  # max(3 x cadence_effective_minutes, BABYSIT_DISPATCH_TTL_MIN). Two reasons it
  # must match rather than approximate:
  #
  #   1. SessionStart fires on compact/resume/fork as well as a fresh start, so
  #      this can run mid-session with a genuinely live watcher whose last tick
  #      is legitimately minutes old. A naive "older than now" test reaps it,
  #      and the next tick's T0 short-circuit then kills the watcher for good.
  #   2. If the two rules disagreed, A2 and this script would each believe a
  #      different thing about the same watcher.
  #
  # Read-only: this pass computes paths; every write goes through
  # session-state.sh below (handoff-files.md — that helper is the only writer,
  # and a raw jq+mv here would clobber a concurrent --set that held the lock).
  PLAN="$(jq -c \
      --argjson now "$NOW_EPOCH" \
      --argjson pj_verdicts "$PJ_VERDICTS_JSON" \
      --argjson pj_snapshot "$PJ_SNAPSHOT" \
      --arg aw_verdict "$AW_VERDICT" \
      --argjson ttl "${BABYSIT_DISPATCH_TTL_MIN:-30}" '
    def prs_paths:
      [paths(type == "object" and has("babysit"))]
      | map(select(.[-2] == "prs"));

    # Render a path array as a literal jq path for session-state.sh --raw-path.
    # The leading "." is required: session-state.sh rejects a bare-key path, and
    # the resulting no-op is swallowed rather than raised.
    def as_path:
      "." + (map(if type == "number" then "[\(.)]" else "[\"\(.)\"]" end) | join(""));

    def watcher_dead($b):
      # Accept "15" as well as 15: /babysit-pr A2 tests with a bash numeric
      # regex, so a string-typed cadence is live there. Falling back to 5 would
      # SHRINK the window below the one A2 uses and reap a backed-off watcher
      # that A2 still considers fresh.
      (($b.cadence_effective_minutes // 5) | try tonumber catch 5) as $cad
      | ([$cad * 3, $ttl] | max) as $fresh_min
      | ($b.last_tick_at // null) as $t
      | if $t == null then true
        else
          # An unparseable stamp is deliberately NOT dead: this runs unattended
          # on every compact, and wrongly clearing `active` makes the next tick
          # T0-terminate a live watcher. A genuinely corrupt stamp is reclaimed
          # by the bounded `last_tick_parse_failures` counter in A2 instead,
          # which can afford to be aggressive because a human is watching it.
          ($t | try (fromdateiso8601 < ($now - $fresh_min * 60)) catch false)
        end;

    . as $doc
    | prs_paths as $pp
    | [ $pp[] as $p | select(($doc | getpath($p)).babysit.cron_job_id != null)
        | ($p + ["babysit","cron_job_id"] | as_path) ] as $cron_ids
    | [ $pp[] as $p | ($doc | getpath($p)).babysit as $b
        | select($b.active == true and watcher_dead($b))
        | ($p + ["babysit","active"] | as_path) ] as $dead_watchers

    # polling_jobs: per-record verdict from the bash precompute above.
    # Index into $pj_verdicts by array position; treat out-of-range as "unknown"
    # (fail-closed: a concurrent write could have shifted the array).
    #
    # We compute dead fingerprints (pid+host pairs) from the snapshot rather than
    # a "kept" list, then filter the LIVE .polling_jobs at write time.  Using the
    # live array means jobs added by sibling sessions after the snapshot was taken
    # are preserved — writing the snapshot kept-list would silently drop them.
    | ( if ($pj_snapshot | type == "array") then
          ( $pj_snapshot | to_entries
            | { dead:     map(select(($pj_verdicts[.key] // "unknown") == "dead"))    | length,
                unknown:  map(select(($pj_verdicts[.key] // "unknown") == "unknown")) | length,
                dead_fps: map(select(($pj_verdicts[.key] // "unknown") == "dead"))
                          | map(.value | {pid:  (.owner_session.pid  // "" | tostring),
                                          host: (.owner_session.host // "")}) }
          )
        else {dead: 0, unknown: 0, dead_fps: []} end ) as $pj

    # auto_wake_cron_id: only clear when the bash precompute determined "dead".
    | ( (.pmm.auto_wake_cron_id? // null) != null ) as $aw_exists
    | ( if $aw_exists then
          { clear:   ($aw_verdict == "dead"),
            unknown: (if $aw_verdict == "unknown" then 1 else 0 end) }
        else {clear: false, unknown: 0} end ) as $aw

    | {
        counts: { polling_jobs:       $pj.dead,
                  polling_jobs_skip:  $pj.unknown,
                  auto_wake_cron_id:  (if $aw.clear then 1 else 0 end),
                  auto_wake_skip:     $aw.unknown,
                  babysit_cron_ids:   ($cron_ids | length),
                  babysit_watchers:   ($dead_watchers | length) },
        sets: ( ( if $pj.dead > 0 then
                    [".polling_jobs=" + (
                       (.polling_jobs? // [])
                       | map(
                           (. | {pid:  (.owner_session.pid  // "" | tostring),
                                 host: (.owner_session.host // "")}) as $fp
                           | select($pj.dead_fps | map(. == $fp) | any | not)
                         )
                       | tojson
                     )]
                  else [] end )
              + ( if $aw.clear then [".pmm.auto_wake_cron_id=null"] else [] end )
              + ( $cron_ids    | map(. + "=null") )
              + ( $dead_watchers | map(. + "=false") ) )
      }
  ' "$STATE_FILE" 2>/dev/null)" || PLAN=""

  if [[ -n "$PLAN" ]]; then
    PURGED_JSON="$(jq -c '.counts' <<<"$PLAN" 2>/dev/null || echo '{}')"
    TOTAL="$(jq -r '.sets | length' <<<"$PLAN" 2>/dev/null || echo 0)"
    [[ "$TOTAL" =~ ^[0-9]+$ ]] || TOTAL=0

    if (( CHECK_ONLY == 0 && TOTAL > 0 )); then
      if [[ -x "$SESSION_STATE_SH" ]]; then
        # One atomic multi-set call under the helper's lock, not N writes.
        SET_ARGS=()
        while IFS= read -r assignment; do
          [[ -n "$assignment" ]] && SET_ARGS+=(--set "$assignment")
        done < <(jq -r '.sets[]' <<<"$PLAN" 2>/dev/null)
        if (( ${#SET_ARGS[@]} > 0 )); then
          if ! "$SESSION_STATE_SH" --raw-path "${SET_ARGS[@]}" >/dev/null 2>&1; then
            # Exit 6 is a lock timeout; anything else is a helper/parse failure.
            # Either way the file is untouched — say so instead of claiming a
            # clean purge, and let the next session start retry.
            NOTICES+=("scheduling-reconcile: could not clear $TOTAL dead scheduling record(s) — session-state.json left unmodified; will retry next session.")
            TOTAL=0
            PURGED_JSON='{}'   # nothing landed; `purged` must not claim otherwise
          fi
        fi
      else
        NOTICES+=("scheduling-reconcile: session-state.sh not found — left $TOTAL dead scheduling record(s) in place.")
        TOTAL=0
        PURGED_JSON='{}'
      fi
    fi

    if (( TOTAL > 0 )); then
      if (( CHECK_ONLY == 1 )); then
        NOTICES+=("Would clear $TOTAL dead scheduling record(s) left by a previous session (--check: nothing written).")
      else
        NOTICES+=("Cleared $TOTAL dead scheduling record(s) left by a previous session (CronCreate jobs do not survive session exit).")
      fi
    fi

    # Surface skipped records so the operator can see them and knows they were
    # not silently discarded. Skipping is the fail-closed safe action; records
    # with provably dead owners are cleared on the next session start once the
    # owning session stamps them correctly.
    SKIP_PJ="$(jq -r '(.counts.polling_jobs_skip // 0)' <<<"$PLAN" 2>/dev/null || echo 0)"
    SKIP_AW="$(jq -r '(.counts.auto_wake_skip   // 0)' <<<"$PLAN" 2>/dev/null || echo 0)"
    [[ "$SKIP_PJ" =~ ^[0-9]+$ ]] || SKIP_PJ=0
    [[ "$SKIP_AW" =~ ^[0-9]+$ ]] || SKIP_AW=0
    (( SKIP_PJ > 0 )) && NOTICES+=("scheduling-reconcile: $SKIP_PJ polling_job record(s) have no verified dead owner — skipped to protect a possible live sibling session (fail-closed).")
    (( SKIP_AW > 0 )) && NOTICES+=("scheduling-reconcile: auto_wake_cron_id has no verified dead owner — skipped to protect a possible live sibling session (fail-closed).")
  fi
fi

# ---------------------------------------------------------------------------
# 2. Surface the durable records that DID survive
# ---------------------------------------------------------------------------

# 2a. harness-audit — the watermark file is the durable record; a session start
#     is the tick. Sessions start far more often than monthly, so this cannot
#     miss a month the way an expiring in-memory cron could.
if [[ -f "$AUDIT_WATERMARK" ]]; then
  MONTH="$(TZ='America/New_York' date +%Y-%m)"
  AUDIT_DUE="$(jq -r --arg m "$MONTH" '
      if (.nudge_enabled // false) != true then "off"
      elif (.last_completed_month // "") == $m then "done"
      elif (.last_offered_month // "") == $m then "offered"
      else "due" end
    ' "$AUDIT_WATERMARK" 2>/dev/null || echo "off")"
  case "$AUDIT_DUE" in
    due)     NOTICES+=("harness-audit is due for $MONTH — run /harness-audit --tick to inventory and get the judgment-pass chip.") ;;
    offered) NOTICES+=("harness-audit already offered its $MONTH step-up chip — click it, or run /harness-audit to audit now.") ;;
  esac
fi

# 2b. A paused PR fleet resumes from the on-disk marker, in any later session —
#     this is the cross-session continuity --auto-wake never actually provided.
if [[ -f "$STATE_FILE" ]]; then
  PAUSED_AT="$(jq -r '.pmm.paused_at // empty' "$STATE_FILE" 2>/dev/null || echo "")"
  [[ -n "$PAUSED_AT" ]] && NOTICES+=("A paused PR fleet is recorded (paused at $PAUSED_AT) — resume with /pr-monitor-and-manage-wake, or /pmm-stop to discard it.")
fi

# ---------------------------------------------------------------------------
# 3. Report
# ---------------------------------------------------------------------------
if [[ "$FORMAT" == json ]]; then
  printf '%s\n' "${NOTICES[@]:-}" \
    | jq -R . | jq -sc --argjson purged "$PURGED_JSON" \
        '{purged: $purged, notices: map(select(. != ""))}'
else
  for n in "${NOTICES[@]:-}"; do [[ -n "$n" ]] && echo "$n"; done
fi

exit 0
