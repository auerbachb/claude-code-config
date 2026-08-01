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
#   When /pause has written a portable handoff, the breadcrumb names the most
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
#   WHY IT IS NOT SCOPED TO THIS SESSION OR REPO
#   Session-matching cannot work by construction: running /pause is how a
#   session ends, so the session that later dies on a limit is never the one
#   that wrote the document. Repo-matching would mean reading the file to learn
#   which repo it describes, and not reading it is the property that keeps this
#   hook a cheap, unfailing recorder. So the pointer stays "the most recent
#   one", and the hint says so plainly — it tells the reader to check that the
#   document's objective matches before acting, rather than implying it does.
#   The age bound is what keeps "most recent" from meaning "from March".
#
# WHY THIS SHAPE (and not a pre-emptive wind-down)
#   Claude Code exposes no approaching-limit signal to any hook, skill, or
#   session. The only surface carrying `rate_limits` is the status line, which
#   is display-only and never executes in a headless (`--output-format
#   stream-json`) desktop-app session. Full evidence, including the live probe
#   that produced zero invocations:
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
# Only handoffs modified within HANDOFF_MAX_AGE_DAYS are eligible. Without a
# bound, a document from a different project weeks ago stays advertised forever
# and grows steadily more misleading the longer it sits there — a stale pointer
# presented as current is worse than no pointer, because it reads as an answer.
# `find -mtime` keeps this a pure filesystem test: still no reading of the file.
HANDOFF_MAX_AGE_DAYS="${CLAUDE_HANDOFF_MAX_AGE_DAYS:-7}"

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

# Handoffs live at ~/.claude/handoffs — a fixed location /pause writes to, NOT a
# subdirectory of this hook's own output dir. Deriving it from STATE_DIR would
# tie the two together, so setting CLAUDE_USAGE_LIMIT_DIR (which exists to
# isolate this hook's records) would silently point the lookup at a directory no
# handoff is ever written to. Separate concept, separate override.
HANDOFF_DIR="${CLAUDE_HANDOFF_DIR:-$HOME/.claude/handoffs}"
PORTABLE_HANDOFF=$(newest_portable_handoff "$HANDOFF_DIR")

# Kept as a variable so the no-handoff case stays byte-identical to the hint
# this hook has always written.
RESUME_HINT_BASE="Turn ended on an Anthropic usage limit. Reconstruct in-flight state from the transcript above, then resume; see .claude/reference/usage-limit-signal-audit-2026-07.md."

# Build the record with jq so every field is escaped correctly. The last
# assistant message is truncated — it is a resume hint, not a transcript.
RECORD=$(printf '%s' "$STDIN_JSON" | jq -c \
  --arg recorded_at "$RECORDED_AT" \
  --arg hint_base "$RESUME_HINT_BASE" \
  --arg handoff "$PORTABLE_HANDOFF" \
  '{
     recorded_at: $recorded_at,
     reason: "rate_limit",
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
   }' 2>/dev/null)

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
LOCKED=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCKED=1
    break
  fi
  # Reap a lock orphaned by a killed hook (the runtime kills us at the timeout).
  LOCK_AGE_REF=$(find "$LOCK_DIR" -maxdepth 0 -mmin +1 2>/dev/null)
  if [[ -n "$LOCK_AGE_REF" ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null
    continue
  fi
  sleep 0.1
done
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
if printf '%s\n' "$RECORD" >>"$EVENTS_LOG" 2>/dev/null; then
  # `last` is what a resuming session should read first; write it atomically so
  # a reader never observes a partial file.
  TMP_LAST="${LAST_FILE}.tmp.$$"
  if printf '%s\n' "$RECORD" >"$TMP_LAST" 2>/dev/null; then
    mv -f "$TMP_LAST" "$LAST_FILE" 2>/dev/null || rm -f "$TMP_LAST" 2>/dev/null
  fi
fi

exit 0
