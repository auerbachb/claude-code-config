#!/usr/bin/env bash
# session-scheduling-reconcile.sh — reconcile durable scheduling state at
# session start (issue #827).
#
# CronCreate jobs are in-memory and session-scoped: every job recorded by a
# previous session is already gone by the time this runs. Rather than trying to
# re-arm them (there is nothing left to re-arm), this purges the dead
# bookkeeping and surfaces the durable on-disk records that DO survive — a
# harness-audit month that came due, a paused PR fleet waiting to resume.
#
# Rationale and the per-feature decisions: .claude/reference/cross-session-durability.md
#
# Invoked by the SessionStart hook (.claude/hooks/session-start-sync.sh), which
# passes --check on every source except `startup` — compact/resume/clear fire
# inside a live session, where a recorded job may still be running and a watcher
# may be about to refresh its own last_tick_at.
# Fail-soft by contract: a missing, unreadable, or corrupt state file must
# never block a session from starting, so every failure path still exits 0.

set -uo pipefail

STATE_FILE="${HOME}/.claude/session-state.json"
AUDIT_WATERMARK="${HOME}/.claude/harness-audit/last-run.json"

usage() {
  cat <<'EOF'
PURPOSE
  Reconcile durable scheduling state at session start: purge scheduler
  bookkeeping that cannot have survived the previous session, and report the
  on-disk records that did.

USAGE
  session-scheduling-reconcile.sh [--check] [--format text|json]

  --check          Report only; make no writes. Exit 0 always.
  --format text    Human-readable lines (default).
  --format json    {"purged":{...},"notices":[...]} for the hook to embed.

WHAT IT PURGES (writes go through session-state.sh, the locked single writer)
  .polling_jobs                        -> []
  .pmm.auto_wake_cron_id               -> null
  .repos[*].prs[*].babysit.cron_job_id -> null
  .repos[*].prs[*].babysit.active      -> false, but ONLY past /babysit-pr's
                                          own freshness window (its A2 check;
                                          canonical definition and the reason
                                          both copies must agree:
                                          .claude/reference/cross-session-durability.md
                                          "Freshness window"). SessionStart also
                                          fires on compact, when a live watcher's
                                          last tick is legitimately minutes old.

WHAT IT SURFACES (durable, still meaningful)
  harness-audit due this month  (~/.claude/harness-audit/last-run.json)
  a paused PR fleet             (.pmm.paused_at)

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
        | ($p + ["babysit","active"] | as_path) ] as $dead
    | (if ((.polling_jobs? // []) | type == "array") then (.polling_jobs | length) else 0 end) as $pj
    | (if (.pmm.auto_wake_cron_id? // null) != null then 1 else 0 end) as $aw
    | {
        counts: {polling_jobs: $pj, auto_wake_cron_id: $aw,
                 babysit_cron_ids: ($cron_ids | length), babysit_watchers: ($dead | length)},
        sets: (( if $pj > 0 then [".polling_jobs=[]"] else [] end)
             + ( if $aw > 0 then [".pmm.auto_wake_cron_id=null"] else [] end)
             + ( $cron_ids | map(. + "=null"))
             + ( $dead     | map(. + "=false")))
      }
  ' "$STATE_FILE" 2>/dev/null)" || PLAN=""

  if [[ -n "$PLAN" ]]; then
    PURGED_JSON="$(jq -c '.counts' <<<"$PLAN" 2>/dev/null || echo '{}')"
    TOTAL="$(jq -r '.sets | length' <<<"$PLAN" 2>/dev/null || echo 0)"
    [[ "$TOTAL" =~ ^[0-9]+$ ]] || TOTAL=0

    if (( CHECK_ONLY == 0 && TOTAL > 0 )); then
      if [[ -x "$SESSION_STATE_SH" ]]; then
        # One atomic multi---set call under the helper's lock, not N writes.
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
