#!/bin/bash
# usage-limit-record.sh — StopFailure hook (issue #824)
#
# PURPOSE
#   Leave a durable breadcrumb when a turn dies because the account hit its
#   usage limit, so the next session finds a pointer instead of silence.
#
#   This is a RECORDER, not a shutdown. By the time StopFailure fires the turn
#   is already over: the runtime documents the event as "Fire-and-forget — hook
#   output and exit codes are ignored", so this hook cannot warn the session,
#   inject context, or change any decision. It can only write to disk.
#
# THE HANDOFF POINTER (issue #901)
#   When /end has written a portable handoff, the breadcrumb names the most
#   recent one instead of pointing only at a transcript. That is the difference
#   between "reconstruct what was happening" and "here is what was happening" —
#   and it costs the session that died without warning nothing, because the
#   document was already on disk before the wall was hit.
#
#   The lookup is newest-by-modification-time over
#   ~/.claude/handoffs/portable-handoff-*.md, bounded to the last
#   HANDOFF_MAX_AGE_DAYS. It never opens the file: no parsing, no size
#   accounting, no quota arithmetic of any kind. With no such file present the
#   hint is byte-identical to what it has always been.
#
#   ORDERING: the durable record is written FIRST (phase 1), and the pointer
#   refines usage-limit-last.json afterwards (phase 2). Finding the newest of N
#   files is inherently O(N) — no cap makes it constant-time on a pathological
#   directory — and this hook is killed at 5s. Putting anything unbounded ahead
#   of the append would let a slow filesystem cost the user the record itself,
#   which is the one thing this hook exists to produce. Killed during phase 2,
#   the user still has exactly what they had before this feature existed.
#
#   WHY IT IS NOT SCOPED TO THIS SESSION OR REPO
#   Session-matching cannot work by construction: running /end is how a
#   session ends, so the session that later dies on a limit is never the one
#   that wrote the document. Repo-matching would mean reading the file to learn
#   which repo it describes, and not reading it is the property that keeps this
#   hook a cheap, unfailing recorder. So the pointer stays "the most recent
#   one", and the hint says so plainly — it tells the reader to check that the
#   document's objective matches before acting, rather than implying it does.
#   The age bound is what keeps "most recent" from meaning "from March".
#
# WHY THIS SHAPE (and not a pre-emptive wind-down)
#   No HOOK receives an approaching-limit signal — not this one, not any of the
#   other 31 events. The only program-facing surface carrying `rate_limits` is
#   the status line, which is display-only and never executes in a headless
#   (`--output-format stream-json`) desktop-app session; re-probed 2026-08-27
#   on 2.1.246, still zero invocations. So this hook stays a post-hoc recorder.
#
#   As of 2026-08-27 a pre-emptive signal DOES reach a session, by a route no
#   hook can use: the harness injects a remaining-token counter directly into
#   the model's context. That is Probe 0 (.claude/scripts/usage-horizon.sh) and
#   it does not change this hook's job — the counter says how much runway is
#   left, this record says the wall was hit. Full evidence and the 2026-08-27
#   addendum:
#       .claude/reference/usage-limit-signal-audit-2026-07.md
#
# SAFETY (.claude/rules/safety.md §"Anthropic Quota & Spend Authority")
#   The sole input is the runtime's own error classification (`error ==
#   "rate_limit"`). Nothing here estimates tokens, spend, or remaining quota,
#   and nothing here pauses, downgrades, defers, or refuses work. That rule is
#   satisfied as written and was NOT amended for this hook.
#
# INPUT   StopFailure payload on stdin:
#           { session_id, transcript_path, cwd, error, error_details,
#             last_assistant_message, ... }
# OUTPUT  Appends to ~/.claude/usage-limit-events.jsonl
#         Rewrites  ~/.claude/usage-limit-last.json (atomically)
#         Always exits 0 — a recorder must never become a new failure mode.
#
# WHICH LIMIT (issue #1633)
#   Every record also carries `limit_kind` (plan_window | overage |
#   unclassified) and `reset_at`, classified at write time through
#   ../scripts/lib/usage-limit-classify.sh. `error == "rate_limit"` says a
#   limit was hit but not which one, and the two are opposite facts: a
#   plan-window wall means the account is on plan and spent nothing, an overage
#   means it spent. Recording the distinction is what stops `credit-budget.sh`
#   from reading a weekly-limit hit as a day's credit spend. Both fields are
#   null when the library is unavailable — see the block at the classification
#   site for why that dependency stays optional.

set -uo pipefail

STDIN_JSON=$(cat)

# jq is the only dependency; without it the payload cannot be parsed safely.
command -v jq >/dev/null 2>&1 || exit 0

ERROR=$(printf '%s' "$STDIN_JSON" | jq -r '.error // empty' 2>/dev/null)

# Defense in depth: the registered matcher already scopes this hook to
# `rate_limit`, but matcher config lives in a different file and can drift.
# Any other API failure (auth, overloaded, server_error) is not a usage limit
# and must not be recorded as one.
[[ "$ERROR" == "rate_limit" ]] || exit 0

STATE_DIR="${CLAUDE_USAGE_LIMIT_DIR:-$HOME/.claude}"

# The record embeds conversation content (a truncated assistant message) plus
# absolute paths. Create everything owner-only so it is not readable by other
# users on a shared machine.
umask 077

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

EVENTS_LOG="$STATE_DIR/usage-limit-events.jsonl"
LAST_FILE="$STATE_DIR/usage-limit-last.json"
LOCK_DIR="$STATE_DIR/.usage-limit-record.lock"
LOG_MAX_SIZE=262144 # 256 KiB, then rotate to .1

# umask only constrains newly created files; tighten anything left behind by an
# earlier run (or an earlier version of this hook) too.
chmod 600 "$EVENTS_LOG" "$LAST_FILE" 2>/dev/null

file_size() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f %z "$1" 2>/dev/null
  else
    stat -c %s "$1" 2>/dev/null
  fi
}

RECORDED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
[[ -n "$RECORDED_AT" ]] || RECORDED_AT="unknown"

# LIMIT KIND (issue #1633)
#
# `error == "rate_limit"` says a limit was hit. It does NOT say WHICH limit,
# and the two possibilities are opposite facts about the account: a plan-window
# wall (rolling 5-hour or weekly) means the account is on plan and spent
# nothing, while a credit overage means it spent. `credit-budget.sh` read every
# record here as the second and froze autonomous dispatch for a whole day on
# four events that were all the first.
#
# Classifying at write time is what keeps the vendor's prose parsed in ONE
# place: the gate reads this field rather than re-deriving it, and reaches for
# the same library only for records written before this field existed.
#
# The dependency is OPTIONAL, and deliberately so. This hook's contract is that
# it always exits 0 and always writes the record; a recorder must never become
# a new failure mode. With the library missing or unloadable both fields are
# null, which is exactly the legacy shape the gate already knows how to
# classify for itself.
#
# Classification reads `last_assistant_message` ONLY — the same field the gate's
# fallback sees — so a record's stored kind and a re-derivation from its stored
# text can never disagree. That invariant is about the STORED text, so the
# expression below must stay byte-identical to the one writing the field near
# the end of this file, truncation included: classifying the full message while
# storing 1,000 characters would let a notice living past the cutoff produce a
# stored kind the gate's fallback cannot reproduce from the record it can see.
LIMIT_KIND=""
RESET_AT=""
_ulc_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../scripts/lib/usage-limit-classify.sh"
if [[ -r "$_ulc_lib" ]]; then
  # shellcheck source=../scripts/lib/usage-limit-classify.sh
  if source "$_ulc_lib" 2>/dev/null; then
    _ulc_msg=$(printf '%s' "$STDIN_JSON" \
      | jq -r '((.last_assistant_message // null)
                | if . == null then ""
                  elif type == "string" then .[0:1000]
                  else (tojson | .[0:1000]) end)' 2>/dev/null) || _ulc_msg=""
    LIMIT_KIND=$(usage_limit_kind "$_ulc_msg" 2>/dev/null) || LIMIT_KIND=""
    RESET_AT=$(usage_limit_reset_at "$_ulc_msg" "$RECORDED_AT" 2>/dev/null) || RESET_AT=""
  fi
fi

# Only handoffs modified within HANDOFF_MAX_AGE_DAYS are eligible. Without a
# bound, a document from a different project weeks ago stays advertised forever
# and grows steadily more misleading the longer it sits there — a stale pointer
# presented as current is worse than no pointer, because it reads as an answer.
# `find -mtime` keeps this a pure filesystem test: still no reading of the file.
HANDOFF_MAX_AGE_DAYS="${CLAUDE_HANDOFF_MAX_AGE_DAYS:-7}"
# Validate before it reaches `find`. An inherited non-numeric value would make
# find fail, and its stderr is discarded — so a perfectly good handoff would be
# silently omitted and the breadcrumb would quietly degrade to transcript-only.
# A bad setting should not cost the user the pointer.
[[ "$HANDOFF_MAX_AGE_DAYS" =~ ^[0-9]+$ ]] && (( HANDOFF_MAX_AGE_DAYS > 0 )) \
  || HANDOFF_MAX_AGE_DAYS=7

# NO scan cap. There was one, and it was wrong in a way worth recording: taking
# the lexically greatest N names and then comparing mtimes within that window
# means the newest-by-mtime file can sit outside it, so the lookup could
# advertise an older handoff than the one it promises.
#
# The cap existed to stop a slow lookup consuming the hook's 5s budget before
# the durable append ran. The phase split removed that risk at the root — the
# record is on disk before this runs at all (see ORDERING above) — so the cap
# was defending against something that could no longer happen, at the cost of
# correctness. Deleting it makes newest-by-mtime exactly true.

# Newest portable handoff by modification time. Modification time is the only
# ordering signal used; when two files share one, the lexically greater name
# wins purely so the result is DETERMINISTIC rather than dependent on directory
# iteration order. That fallback is not a chronology claim — same-second
# handoffs carry the same embedded timestamp, so their name order says nothing
# about which was written last.
#
# `-nt` is a bash builtin comparison, which keeps this free of the BSD/GNU
# `stat` split the file_size() helper above has to switch on. The file is never
# opened; only its name and mtime are consulted.
newest_portable_handoff() {
  local dir="$1" newest="" f
  [[ -d "$dir" ]] || return 0
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if [[ -z "$newest" ]]; then
      newest="$f"
    elif [[ "$f" -nt "$newest" ]]; then
      newest="$f"
    elif [[ ! "$newest" -nt "$f" && "$f" > "$newest" ]]; then
      newest="$f"
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name 'portable-handoff-*.md' \
             -mtime "-${HANDOFF_MAX_AGE_DAYS}" 2>/dev/null)
  printf '%s' "$newest"
}

# Handoffs live at ~/.claude/handoffs — a fixed location /end writes to, NOT a
# subdirectory of this hook's own output dir. Deriving it from STATE_DIR would
# tie the two together, so setting CLAUDE_USAGE_LIMIT_DIR (which exists to
# isolate this hook's records) would silently point the lookup at a directory no
# handoff is ever written to. Separate concept, separate override.
HANDOFF_DIR="${CLAUDE_HANDOFF_DIR:-$HOME/.claude/handoffs}"

# Kept as a variable so the no-handoff case stays byte-identical to the hint
# this hook has always written.
RESUME_HINT_BASE="Turn ended on an Anthropic usage limit. Reconstruct in-flight state from the transcript above, then resume; see .claude/reference/usage-limit-signal-audit-2026-07.md."

# Build the record with jq so every field is escaped correctly. The last
# assistant message is truncated — it is a resume hint, not a transcript.
build_record() { # $1 = portable handoff path, or "" for none
    printf '%s' "$STDIN_JSON" | jq -c \
    --arg recorded_at "$RECORDED_AT" \
    --arg hint_base "$RESUME_HINT_BASE" \
    --arg handoff "$1" \
    --arg limit_kind "$LIMIT_KIND" \
    --arg reset_at "$RESET_AT" \
    '{
       recorded_at: $recorded_at,
       reason: "rate_limit",
       limit_kind: (if $limit_kind == "" then null else $limit_kind end),
       reset_at: (if $reset_at == "" then null else $reset_at end),
       session_id: (.session_id // null),
       cwd: (.cwd // null),
       transcript_path: (.transcript_path // null),
       error_details: ((.error_details // null)
         | if . == null then null
           elif type == "string" then .[0:500]
           else (tojson | .[0:500]) end),
       last_assistant_message: ((.last_assistant_message // null)
         | if . == null then null
           elif type == "string" then .[0:1000]
           else (tojson | .[0:1000]) end),
       resume_hint: (if $handoff == "" then $hint_base
                     else $hint_base
                          + " The most recent portable handoff is at "
                          + $handoff
                          + " — read it first. It is the newest one on this machine, not necessarily one about this repository, so check that its stated objective matches before acting on it."
                     end),
       portable_handoff: (if $handoff == "" then null else $handoff end)
     }' 2>/dev/null
}

# PHASE 1 — the durable record, with NO handoff pointer.
#
# The pointer lookup is deliberately NOT in front of this. Finding the newest of
# N files is inherently O(N), so no cap makes it constant-time on a pathological
# directory — and this hook has a 5s budget after which it is killed. Anything
# expensive placed before the append can therefore cost the user the record
# itself, which is the one thing this hook exists to produce. So the record goes
# to disk first and the pointer refines it afterwards (phase 2).
RECORD=$(build_record "")

# A malformed or unparseable payload must not append a broken line.
[[ -n "$RECORD" ]] || exit 0

# Concurrency is the EXPECTED case here, not an edge case: one account hitting
# its limit fails every active session at once, so several copies of this hook
# can run simultaneously. Serialize rotation + append + publish so a rotation
# race cannot drop records.
#
# mkdir is the portable atomic mutex — macOS ships no flock(1). The wait is
# bounded (~1s); if the lock cannot be taken we proceed anyway, because losing
# the record is worse than a rare interleave.
take_lock() {  # echoes 1 when acquired, 0 otherwise
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then echo 1; return 0; fi
    # Reap a lock orphaned by a killed hook (the runtime kills us at the timeout).
    if [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
      rmdir "$LOCK_DIR" 2>/dev/null
      continue
    fi
    sleep 0.1
  done
  echo 0
}

LOCKED=$(take_lock)
if (( LOCKED )); then
  # Single quotes on purpose: expand LOCK_DIR at trap time, so a state dir
  # containing a quote character cannot break the trap string.
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
fi

# Rotate ONLY while holding the lock. Rotation is rm + mv — two unsynchronized
# rotations near the cap can replace the archive with a freshly-emptied log and
# discard the previous one. Appending unlocked risks at worst an interleave;
# rotating unlocked risks losing history, so the unlocked path skips it and
# lets a later locked run rotate instead.
if (( LOCKED )); then
  SIZE=$(file_size "$EVENTS_LOG")
  [[ -n "$SIZE" ]] || SIZE=0
  # Byte count, not ${#RECORD}: that is a character count, so multibyte UTF-8 in
  # the captured message would under-measure and defer rotation past the cap.
  # The +1 the newline adds is included by printf'ing exactly what gets appended.
  RECORD_BYTES=$(printf '%s\n' "$RECORD" | wc -c | tr -d '[:space:]')
  [[ "$RECORD_BYTES" =~ ^[0-9]+$ ]] || RECORD_BYTES=${#RECORD}
  if (( SIZE + RECORD_BYTES >= LOG_MAX_SIZE )); then
    rm -f "${EVENTS_LOG}.1" 2>/dev/null
    mv "$EVENTS_LOG" "${EVENTS_LOG}.1" 2>/dev/null
  fi
fi

# Publish `last` only if the durable append succeeded — otherwise the pointer
# would advertise an event the log does not contain.
PUBLISHED=0
if printf '%s\n' "$RECORD" >>"$EVENTS_LOG" 2>/dev/null; then
  # `last` is what a resuming session should read first; write it atomically so
  # a reader never observes a partial file.
  TMP_LAST="${LAST_FILE}.tmp.$$"
  if printf '%s\n' "$RECORD" >"$TMP_LAST" 2>/dev/null; then
    mv -f "$TMP_LAST" "$LAST_FILE" 2>/dev/null && PUBLISHED=1 || rm -f "$TMP_LAST" 2>/dev/null
  fi
fi

# Release the lock before phase 2 so the slow part does not hold up the other
# sessions that hit the same limit at the same instant. Phase 2 re-takes it
# before publishing (see below) — dropping it here buys concurrency, it does not
# make the publish unserialized.
if (( LOCKED )); then
  rmdir "$LOCK_DIR" 2>/dev/null
  trap - EXIT
  LOCKED=0
fi

# PHASE 2 — refine the published pointer with the handoff, if one exists.
#
# Everything durable is already on disk, so this step can be as slow as the
# filesystem makes it without costing the record. If the hook is killed here,
# the user still has exactly what they had before this feature existed.
#
# Only `usage-limit-last.json` is refined. The events log is a history of what
# happened; `last` is the pointer a resuming session reads first, and the
# pointer is the thing worth improving. Rewriting history to add a field the
# reader will get from `last` anyway is not worth a second append.
(( PUBLISHED )) || exit 0

PORTABLE_HANDOFF=$(newest_portable_handoff "$HANDOFF_DIR")
[[ -n "$PORTABLE_HANDOFF" ]] || exit 0

ENRICHED=$(build_record "$PORTABLE_HANDOFF")
[[ -n "$ENRICHED" ]] || exit 0

# Re-serialize, and only replace OUR OWN record.
#
# Concurrency is the expected case here — one account limit fails every active
# session at once — so a slow invocation can reach this point after a newer one
# has already published. Overwriting blind would roll `last` back to an older
# session_id, transcript, and cwd while the events log ends with the newer
# event, breaking the one thing `last` promises: that it is the most recent.
#
# The guard is exact rather than clever: if `last` no longer holds the very
# record this invocation wrote, a newer one has published and it owns the file.
# Skip — it will run its own phase 2.
# Without the lock the guard is not a guard: another invocation can replace the
# file between the read below and the rename, which is exactly the clobber this
# block exists to prevent. Enrichment is optional and `last` being correct is
# not, so losing the race means skipping — the invocation that won it publishes
# its own pointer anyway.
LOCKED=$(take_lock)
(( LOCKED )) || exit 0
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

CURRENT_LAST=$(cat "$LAST_FILE" 2>/dev/null)
if [[ "$CURRENT_LAST" == "$RECORD" ]]; then
  TMP_LAST="${LAST_FILE}.tmp.$$"
  if printf '%s\n' "$ENRICHED" >"$TMP_LAST" 2>/dev/null; then
    mv -f "$TMP_LAST" "$LAST_FILE" 2>/dev/null || rm -f "$TMP_LAST" 2>/dev/null
  fi
fi

exit 0
