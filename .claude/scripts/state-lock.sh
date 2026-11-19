#!/usr/bin/env bash
# state-lock.sh — portable advisory write lock for ~/.claude/session-state.json.
# catalog: session-state-locking — *(library — source, do not execute)* Portable mkdir-based advisory lock for session-state writes
#
# PURPOSE
#   Serializes the WHOLE read-modify-write cycle of every writer that touches
#   ~/.claude/session-state.json (issue #639). Each individual write was
#   already atomic (mktemp + mv), but the read that precedes it was not
#   covered: two writers that both read, both modify, and both write back
#   silently lose one of the two changes. This library gives all writers a
#   single mutual-exclusion primitive so they take turns instead.
#
#   Sourced, not executed:
#       source "$(dirname "$0")/state-lock.sh"
#       state_lock_acquire "$STATE_FILE" || exit $?
#       ... read … modify … write …
#       state_lock_release
#
# WHY mkdir AND NOT flock(1)
#   This fleet runs on macOS (darwin), where `flock(1)` is not installed by
#   default — a flock-based lock would silently no-op or hard-fail on the
#   primary platform. `mkdir` is the portable alternative: POSIX requires it
#   to fail if the directory already exists, and that test-and-create is
#   atomic on every local filesystem (and on NFSv3+, unlike O_EXCL creat).
#   The cost of mkdir over flock is that the kernel does NOT release the lock
#   when the holder dies, so stale-lock recovery has to be explicit — see
#   STALENESS POLICY.
#
# LOCK LAYOUT
#   Lock directory:  <state-file>.lock/            (e.g. session-state.json.lock)
#   Owner metadata:  <state-file>.lock/owner       (published atomically right
#                    after the mkdir wins) containing:
#       pid=<holder pid>
#       host=<hostname>
#       epoch=<unix seconds when the lock was taken>
#       started=<ISO 8601 UTC>
#       cmd=<basename of the holding script>
#       token=<unique per-acquisition id>
#
#   The owner file is written to a temp path INSIDE the lock directory and
#   renamed onto `owner`, so it is never observable half-written. That matters
#   because "owner unreadable" used to be indistinguishable from "holder is
#   gone" — see STALENESS POLICY (issue #930).
#
#   `token` identifies one ACQUISITION, not one process. A bare pid cannot
#   distinguish this acquisition from a later one by the same pid, so every
#   ownership decision (release, and the state_lock_assert_held check below)
#   compares tokens.
#
# STALENESS POLICY
#   A lock is considered stale — and may be broken — when EITHER holds:
#     1. The owner metadata is PRESENT, names THIS host, and `kill -0 <pid>`
#        says that process no longer exists (holder died mid-write).
#     2. The lock is older than STALE_AGE seconds (default 120, override with
#        CLAUDE_STATE_LOCK_STALE_AGE). This is the cross-host / unparseable-
#        metadata fallback: a foreign hostname makes the local pid check
#        meaningless, so age is the only usable signal. Age comes from the
#        `epoch=` line, falling back to the lock directory's own mtime.
#   A real write holds the lock for single-digit milliseconds, so a 120s age
#   ceiling carries roughly four orders of magnitude of headroom.
#
#   AN INDETERMINATE AGE IS NOT STALE. Both conditions above require positive
#   evidence; when neither the `epoch=` line nor the directory mtime can be
#   read, the lock is left ALONE and the caller's timeout bounds the wait.
#   The inverse — "cannot tell, therefore stale" — is what broke live holders
#   on Linux (issue #930): `stat -f %m` is BSD spelling, and GNU coreutils
#   parses `-f` as --file-system and `%m` as a FILE operand, so the age lookup
#   returned a non-numeric blob and every unreadable owner aged out instantly.
#   Missing owner metadata is a routine, sub-millisecond state (a lock being
#   acquired or released), NOT a death certificate.
#
#   Breaking is guarded against the classic double-steal (two waiters both
#   declare the same lock stale, both break it, and one then destroys the
#   OTHER's freshly acquired lock): the breaker samples the owner metadata,
#   waits briefly, re-reads it, and aborts the break unless the bytes are
#   byte-for-byte identical and the lock is still stale. A newly acquired
#   lock always writes a different pid/epoch, so a lock that changed hands
#   in the interim is never broken. The break itself renames the directory
#   aside (`mv` — atomic, only one racer can win it) before deleting it.
#
# FAILURE MODES (documented deliberately — see the PR body for issue #639)
#   • Holder killed mid-write: the next writer detects the dead pid and breaks
#     the lock within one poll interval. The state file itself is untouched,
#     because the killed writer's partial output only ever existed in its
#     temp file — the `mv` is all-or-nothing.
#   • Holder alive but wedged >STALE_AGE: the lock IS broken. Chosen
#     deliberately: the alternative (never break a live holder's lock) wedges
#     every future session in the fleet forever, which is the exact failure
#     this issue exists to prevent. The wedged victim can no longer lose an
#     interleaved write silently, though — breaking a lock rotates the token,
#     so the victim's state_lock_assert_held fails and it MUST abandon its
#     read-modify-write instead of committing (issue #930). Callers surface
#     that as exit 6, "unchanged, retry".
#   • Shared/network HOME: pid liveness is not meaningful across hosts, so
#     cross-host locks fall back to the age rule alone.
#   • Lock directory not writable: acquisition fails fast rather than writing
#     unserialized (see exit code 6).
#   • Starvation: `mkdir` contention is not FIFO, so under heavy fan-out (a
#     dozen-plus writers at once, each fighting for CPU) an unlucky waiter can
#     lose several rounds in a row. The 30s default timeout is sized for that
#     tail — a real critical section is milliseconds, so a writer that waits
#     30s is reporting a genuine problem, not ordinary contention.
#
# TUNABLES (environment)
#   CLAUDE_STATE_LOCK_TIMEOUT    seconds to wait for the lock   (default 30)
#   CLAUDE_STATE_LOCK_STALE_AGE  seconds before a lock is stale (default 120)
#   CLAUDE_STATE_LOCK_HELD       set automatically while held; makes a nested
#                                acquire of the SAME lock a no-op so a holder
#                                that shells out to another state-writing
#                                script cannot deadlock against itself.
#   CLAUDE_STATE_LOCK_TOKEN      set alongside it, so a nested writer can still
#                                verify the inherited lock with
#                                state_lock_assert_held.
#
# BOUNDED DEADLINE AND TIMEOUT DIAGNOSTICS (issue #2433)
#   CLAUDE_STATE_LOCK_TIMEOUT is a real upper bound: the deadline is checked
#   after every lost mkdir, after a failed parent-directory creation, and
#   before every stale-break attempt after the first (a break's 0.2s resample
#   counts as waiting; the first break is always allowed so a zero-timeout
#   caller still recovers a dead holder). Overshoot is at most one poll or one
#   break resample.
#
#   The timeout message is ONE line on stderr and always names a holder pid
#   and host. It keeps the substrings `timed out after <N>s waiting` and
#   `refusing to write unserialized`. The parenthesised holder is one of:
#     held by pid <pid> on <host> (cmd <cmd>, held <n>s)   current owner file
#     last observed held by pid <pid> on <host> (<n>s ago) owner gone at the
#                                    deadline; last snapshot taken mid-wait
#     held by pid unknown on unknown (owner not published or unreadable; lock age <n>s)
#     held by pid unknown on unknown (holder released before its owner was observed)
#     held by pid unknown on unknown (lock directory could not be created; not contention)
#                                    (only when the directory was never seen)
#     held by pid unknown on unknown (parent directory <p> could not be created; not contention)
#   Contention forms contain `held by pid <digits>`; non-contention forms
#   contain `not contention` (pause-launch-gate.sh classifies on these). Every
#   field comes from ONE read of the owner file, and the waiter's own pid/host
#   is never reported. The owner file's `host=` is never empty: $HOSTNAME,
#   hostname(1), `uname -n`, then `unknown-host`.
#
# EXIT / RETURN CODE
#   state_lock_acquire returns 0 on success and STATE_LOCK_EXIT_TIMEOUT (6)
#   when the lock could not be acquired within the timeout. Callers propagate
#   6 so a writer that cannot serialize exits non-zero with a distinct code
#   INSTEAD of writing anyway.
#
#   state_lock_assert_held returns 0 while this process still holds the lock it
#   acquired (or the one it inherited) and non-zero once the lock has been
#   broken and re-acquired by somebody else. EVERY caller must check it
#   immediately before committing its read-modify-write — that is the whole
#   defence against a stolen lock turning into a silently dropped update, and
#   the check must sit as close to the commit `mv` as possible.
#
# STATE_LOCK_WAITED — DID THIS ACQUIRE HAVE TO WAIT? (issue #1567)
#   state_lock_acquire sets STATE_LOCK_WAITED on every return, alongside
#   STATE_LOCK_DIR / STATE_LOCK_TOKEN. It is the only party that knows the
#   answer exactly; a caller inferring it from outside (a lockdir pre-check, a
#   whole-second clock either side of the call) is guessing, and both guesses
#   are lossy (issue #1751: a slow uncontended acquire crossing a second
#   boundary read as contended).
#     0  the FIRST mkdir won — nobody held the lock when this call arrived.
#        Clearing a legacy flock artifact or creating a missing parent
#        directory first does not count: neither is another holder.
#     1  at least one mkdir attempt FAILED with the parent directory present.
#        That is a lock somebody else held: a live holder this call waited
#        out, OR a STALE lock it broke and then took. Stale recovery reports 1
#        deliberately — another holder existed, it may have died or wedged
#        mid-write after changing the protected state, and the break itself
#        sleeps — so a caller asking "was anyone else in here around my
#        acquire?" must hear yes. The lock is NOT re-checked after a failed
#        attempt (a holder that released in the meantime was still a holder),
#        so a failure with another cause — an unwritable directory — also
#        reports 1: over-reporting a wait only ever sends a caller down its
#        conservative branch, and a persistent one ends in a timeout anyway.
#   Re-entrant acquire (CLAUDE_STATE_LOCK_HELD names this lock): 0. Nothing was
#     attempted — the ancestor already holds the lock — so nothing was waited
#     for. The ancestor's own value is NOT inherited: a nested writer's flag
#     describes its own call, and only the acquire that won the mkdir can say
#     whether that mkdir had to wait.
#   Failed acquire (non-zero return): still set — 1 once any attempt was lost,
#     which a timeout always implies — but the caller holds nothing and should
#     not branch on it.
#   state_lock_release resets it to "" (no acquisition in effect), so read it
#   immediately after the acquire it describes; a later acquire — including a
#   re-entrant one in the same process — overwrites it. Treat anything other
#   than an explicit 0 as "waited": that reading fails safe if the flag is
#   ever empty.
#   Published as a shell global like STATE_LOCK_DIR and STATE_LOCK_TOKEN, NOT
#   exported into the environment: it describes THIS process's call, and a
#   child that inherited it would be reading a value about an acquire it never
#   made — the outside guess this flag exists to replace.
#
# DEPENDENCIES
#   mkdir, mv, rm, date, sleep, hostname (all POSIX / base macOS).

# Distinct exit code for "could not acquire the lock in time". Chosen to not
# collide with the existing 2/3/4/5 vocabulary shared by the state scripts.
STATE_LOCK_EXIT_TIMEOUT=6

# Path of the lock directory currently held by THIS process ("" when none).
# Release authority: set ONLY when this process won the mkdir itself, so a
# nested (re-entrant) writer can never release its ancestor's lock.
STATE_LOCK_DIR=""

# Path this process is covered by — its own lock OR one inherited through
# CLAUDE_STATE_LOCK_HELD. state_lock_assert_held checks against this.
STATE_LOCK_HELD_DIR=""

# Token of the acquisition covering this process ("" when none).
STATE_LOCK_TOKEN=""

# Whether the most recent state_lock_acquire had to wait: 0, 1, or "" when no
# acquisition is in effect. Contract in the header (STATE_LOCK_WAITED section).
STATE_LOCK_WAITED=""

# Current unix time. Uses bash's printf time format when available (a builtin,
# no fork) and falls back to date(1) on bash 3.2 — macOS system bash. Forks are
# expensive enough on macOS (~8ms each, measured) that the acquire hot path is
# deliberately kept to the two unavoidable ones: `mkdir` and `rm -rf`.
if printf '%(%s)T' -1 >/dev/null 2>&1; then
  _STATE_LOCK_PRINTF_TIME=1
else
  _STATE_LOCK_PRINTF_TIME=0
fi

_state_lock_now() {
  if [[ "$_STATE_LOCK_PRINTF_TIME" == 1 ]]; then
    printf '%(%s)T' -1
  else
    date +%s
  fi
}

# `epoch<space>ISO-8601-UTC`, in one shot, builtin when possible.
_state_lock_stamp() {
  if [[ "$_STATE_LOCK_PRINTF_TIME" == 1 ]]; then
    TZ=UTC printf '%(%s)T %(%Y-%m-%dT%H:%M:%SZ)T' -1 -1
  else
    date -u +'%s %Y-%m-%dT%H:%M:%SZ'
  fi
}

# Hostname without forking hostname(1) when bash already knows it. Used to
# decide whether a recorded pid is meaningful on THIS machine, and published
# into the owner file. Never prints an empty string (issue #2433): $HOSTNAME,
# then hostname(1), then `uname -n`, then the literal `unknown-host`. Cached
# per process so the staleness check and the owner file always agree.
_STATE_LOCK_HOST_CACHE=""
# Fill the cache in the CALLING shell (never inside $(...), where the
# assignment would be lost with the subshell).
_state_lock_host_init() {
  [[ -n "$_STATE_LOCK_HOST_CACHE" ]] && return 0
  local h="${HOSTNAME:-}"
  [[ -n "$h" ]] || h="$(hostname 2>/dev/null)" || h=""
  [[ -n "$h" ]] || h="$(uname -n 2>/dev/null)" || h=""
  # One line only: an embedded newline (an environment-supplied HOSTNAME)
  # would inject extra `key=` records into the owner file.
  h="${h%%$'\n'*}"
  h="${h//$'\r'/}"
  [[ -n "$h" ]] || h="unknown-host"
  _STATE_LOCK_HOST_CACHE="$h"
}
_state_lock_hostname() {
  _state_lock_host_init
  printf '%s' "$_STATE_LOCK_HOST_CACHE"
}

# Read the owner file ONCE and publish its fields as
# _SL_SNAP_PID / _SL_SNAP_HOST / _SL_SNAP_EPOCH / _SL_SNAP_CMD (issue #2433).
# Reading each field with a separate open can mix two acquisitions' fields
# when the lock changes hands between reads. Returns 0 when a pid was read,
# 1 otherwise (all four left empty).
_state_lock_snapshot() {
  local file="$1/owner" line
  _SL_SNAP_PID="" _SL_SNAP_HOST="" _SL_SNAP_EPOCH="" _SL_SNAP_CMD=""
  [[ -f "$file" ]] || return 1
  { while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        pid=*) _SL_SNAP_PID="${line#*=}" ;;
        host=*) _SL_SNAP_HOST="${line#*=}" ;;
        epoch=*) _SL_SNAP_EPOCH="${line#*=}" ;;
        cmd=*) _SL_SNAP_CMD="${line#*=}" ;;
      esac
    done < "$file"; } 2>/dev/null
  if [[ -z "$_SL_SNAP_PID" ]]; then
    _SL_SNAP_HOST="" _SL_SNAP_EPOCH="" _SL_SNAP_CMD=""
    return 1
  fi
  [[ -n "$_SL_SNAP_HOST" ]] || _SL_SNAP_HOST="unknown"
  return 0
}

# One-line timeout diagnostic (issue #2433). Always names a holder pid and
# host — the real current holder, the last one observed during the wait
# (labelled), or `unknown` with an explicit reason. Never the waiter's own.
#   $1 lock dir  $2 timeout  $3 last-observed pid  $4 host  $5 seen-at (unix)
#   $6 optional reason override (e.g. parent directory creation failed)
#   $7 1 when the lock directory was seen present after some lost mkdir
_state_lock_timeout_message() {
  local lock_dir="$1" timeout="$2" lpid="$3" lhost="$4" lseen="$5" reason="${6:-}" saw_dir="${7:-0}"
  local now holder age
  now="$(_state_lock_now)"
  if [[ -n "$reason" ]]; then
    holder="held by pid unknown on unknown ($reason; not contention)"
  elif _state_lock_snapshot "$lock_dir"; then
    holder="held by pid ${_SL_SNAP_PID} on ${_SL_SNAP_HOST}"
    if [[ "$_SL_SNAP_EPOCH" =~ ^[0-9]+$ ]]; then
      holder+=" (cmd ${_SL_SNAP_CMD:-unknown}, held $(( now - _SL_SNAP_EPOCH ))s)"
    else
      holder+=" (cmd ${_SL_SNAP_CMD:-unknown})"
    fi
  elif [[ -n "$lpid" ]]; then
    holder="last observed held by pid ${lpid} on ${lhost:-unknown} ($(( now - lseen ))s ago)"
  elif [[ -d "$lock_dir" ]]; then
    if age="$(_state_lock_age "$lock_dir")"; then
      holder="held by pid unknown on unknown (owner not published or unreadable; lock age ${age}s)"
    else
      holder="held by pid unknown on unknown (owner not published or unreadable; lock age unknown)"
    fi
  elif [[ "$saw_dir" == 1 ]]; then
    # The lock existed during the wait but is gone now: a holder that never
    # published an owner (or released just now). Contention, identity unknown.
    holder="held by pid unknown on unknown (holder released before its owner was observed)"
  else
    # mkdir failed every time and the directory was never seen: a creation
    # failure, not another holder.
    holder="held by pid unknown on unknown (lock directory could not be created; not contention)"
  fi
  # The contract is ONE line: flatten any newline a path or owner field holds.
  local msg
  msg="$(printf 'state-lock: timed out after %ss waiting for %s (%s); refusing to write unserialized' \
    "$timeout" "$lock_dir" "$holder")"
  msg="${msg//$'\n'/ }"
  printf '%s\n' "${msg//$'\r'/ }"
}

# Read one `key=value` line out of an owner file. Prints nothing when absent.
_state_lock_meta() {
  local file="$1" key="$2" line
  [[ -f "$file" ]] || return 0
  # The redirect is guarded too: the lock can be released (and the owner file
  # unlinked) between the test above and the open below — a benign race that
  # would otherwise print "No such file or directory" to stderr.
  #
  # The suppression has to wrap the WHOLE group rather than trail the `done`.
  # Redirections are applied left to right, so `done < "$file" 2>/dev/null`
  # opens the (missing) input file while stderr is still the real one and the
  # message escapes anyway — observed leaking during the issue #930 repro.
  { while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        "$key="*) printf '%s' "${line#*=}"; return 0 ;;
      esac
    done < "$file"; } 2>/dev/null
  return 0
}

# Modification time of $1 in unix seconds, printed on stdout; returns non-zero
# when it cannot be determined.
#
# `stat` is not portable between GNU and BSD, and — critically — the wrong
# spelling does NOT fail cleanly on either. GNU treats `-f` as --file-system
# and `%m` as a FILE operand: it prints a multi-line filesystem dump on stdout
# and exits non-zero, so a naive `stat -f %m … || stat -c %Y …` chain CONCATENATES
# the dump with the real mtime and yields a non-numeric string. Only a numeric
# result may be trusted, so each spelling is validated rather than chained on
# exit status alone (issue #930).
_state_lock_file_mtime() {
  local path="$1" m
  m="$(stat -c %Y "$path" 2>/dev/null)"      # GNU coreutils
  if [[ "$m" =~ ^[0-9]+$ ]]; then printf '%s' "$m"; return 0; fi
  m="$(stat -f %m "$path" 2>/dev/null)"      # BSD / macOS
  if [[ "$m" =~ ^[0-9]+$ ]]; then printf '%s' "$m"; return 0; fi
  return 1
}

# Age in seconds of the lock at $1, printed on stdout. Prefers the recorded
# epoch and falls back to the lock directory's mtime. Returns non-zero (and
# prints nothing) when NEITHER can be determined.
#
# There is deliberately no "very large number" sentinel any more. Reporting an
# unknowable age as ancient makes every unreadable owner file look like a dead
# holder, which is precisely how live holders got their locks broken (#930).
# An unknown age is now the caller's problem to treat conservatively.
_state_lock_age() {
  local lock_dir="$1" epoch mtime now
  now="$(_state_lock_now)"
  epoch="$(_state_lock_meta "$lock_dir/owner" epoch)"
  if [[ "$epoch" =~ ^[0-9]+$ ]]; then
    printf '%s' "$(( now - epoch ))"
    return 0
  fi
  if mtime="$(_state_lock_file_mtime "$lock_dir")"; then
    printf '%s' "$(( now - mtime ))"
    return 0
  fi
  return 1
}

# 0 when the lock at $1 qualifies as stale under STALENESS POLICY above.
# Both rules require POSITIVE evidence; absent evidence means "not stale".
_state_lock_is_stale() {
  local lock_dir="$1" stale_age="$2" pid host age
  if age="$(_state_lock_age "$lock_dir")" && [[ "$age" -ge "$stale_age" ]]; then
    return 0
  fi
  pid="$(_state_lock_meta "$lock_dir/owner" pid)"
  host="$(_state_lock_meta "$lock_dir/owner" host)"
  # A pid check only means something on the host that recorded it — and only
  # when a pid was actually recorded. An ABSENT owner file means the lock is
  # mid-acquire or mid-release (both sub-millisecond, both routine), never
  # that the holder died; reading it as a dead holder is the #930 bug.
  _state_lock_host_init
  if [[ -n "$pid" && "$host" == "$_STATE_LOCK_HOST_CACHE" && "$pid" =~ ^[0-9]+$ ]]; then
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# Remove a lock directory we are entitled to remove, atomically from the point
# of view of everyone else: rename it out of the way first, THEN delete it.
#
# A plain `rm -rf "$lock_dir"` unlinks `owner` before it removes the directory,
# so the lock spends the whole teardown visible-but-ownerless — one of the two
# windows that made #930 fire. `rename` collapses that to a single atomic step:
# other processes see the lock as fully present or entirely gone, never as an
# orphan worth breaking.
_state_lock_destroy() {
  local lock_dir="$1" aside="${1}.rel.$$-${RANDOM}"
  if mv "$lock_dir" "$aside" 2>/dev/null; then
    rm -rf "$aside" 2>/dev/null || true
  else
    rm -rf "$lock_dir" 2>/dev/null || true
  fi
}

# COMMIT GATE (issue #2460)
#   Judging a lock stale and renaming it away are two steps, and the commit's
#   ownership check and its `mv` are two more. A cleaner could pass the stale
#   check, pause, and rename a SUCCESSOR's fresh lock; a writer could pass its
#   ownership check, be broken and replaced, then land its `mv` after the
#   successor's. Both are closed by one tiny mutual-exclusion directory,
#   `<lock>.gate`, taken (mkdir, atomic) around exactly those pairs:
#     - the breaker re-judges staleness and renames UNDER the gate, so what it
#       judged is what it moves;
#     - the committer asserts ownership and `mv`s UNDER the gate, so a breaker
#       cannot swap the lock in between.
#     - release checks its token and removes the lock UNDER the gate, so a lock
#       cannot be released and re-taken between a breaker's re-check and its
#       rename (the lock directory only ever vanishes under the gate).
#   A breaker that finds the gate taken abandons the break (the committer is
#   live and mid-commit). A committer that finds it taken waits briefly, then
#   refuses with exit 6 (unchanged, retry) -- the safe direction.
#
#   The gate records its holder's pid in `<gate>/pid`. A gate is abandoned --
#   and removable -- ONLY when that pid is dead, or when no pid was ever written
#   and the gate is older than _STATE_LOCK_GATE_STALE seconds (holder killed
#   between mkdir and the pid write). Age alone never frees a gate whose holder
#   is alive: a commit stalled mid-gate (SIGSTOP, a suspended laptop) must not
#   have its gate stolen, or the lock behind it could be broken and the resumed
#   commit would overwrite newer state. A live-but-stalled holder therefore
#   blocks commits and breaks until it resumes; everyone else fails closed
#   (exit 6 / acquire timeout), never open.
_STATE_LOCK_GATE_STALE=30

# 0 when the gate at $1 is abandoned (see COMMIT GATE above).
_state_lock_gate_abandoned() {
  local gate="$1" pid mtime now
  pid="$(cat "$gate/pid" 2>/dev/null)"
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    ! kill -0 "$pid" 2>/dev/null
    return
  fi
  mtime="$(_state_lock_file_mtime "$gate")" || return 1
  now="$(_state_lock_now)"
  (( now - mtime >= _STATE_LOCK_GATE_STALE ))
}

# Remove an abandoned gate. Rename-aside first, then confirm what was moved is
# still abandoned; a gate another process re-took in between is put back.
# 0 when the gate is gone, 1 when it is still (or again) in place.
_state_lock_gate_reap() {
  local gate="$1" aside="${1}.dead.$$-${RANDOM}"
  if ! mv "$gate" "$aside" 2>/dev/null; then
    [[ -d "$gate" ]] && return 1
    return 0
  fi
  if _state_lock_gate_abandoned "$aside"; then
    rm -rf "$aside" 2>/dev/null || true
    return 0
  fi
  mv "$aside" "$gate" 2>/dev/null || rm -rf "$aside" 2>/dev/null || true
  return 1
}

# _state_lock_gate_take <lock-dir> <retries>: 0 when taken (0.1s per retry).
_state_lock_gate_take() {
  local gate="${1}.gate" tries="${2:-0}"
  while :; do
    if mkdir "$gate" 2>/dev/null; then
      printf '%s\n' "$$" > "$gate/pid" 2>/dev/null || true
      return 0
    fi
    # Already ours: an EXIT trap releasing while this process was mid-commit.
    [[ "$(cat "$gate/pid" 2>/dev/null)" == "$$" ]] && return 0
    if [[ -d "$gate" ]] && _state_lock_gate_abandoned "$gate" \
       && _state_lock_gate_reap "$gate"; then
      continue
    fi
    (( tries-- > 0 )) || return 1
    sleep 0.1
  done
}

# Drop a gate this process took. Never removes one recording another pid.
_state_lock_gate_drop() {
  local gate="${1}.gate" pid
  pid="$(cat "$gate/pid" 2>/dev/null)"
  [[ -z "$pid" || "$pid" == "$$" ]] || return 0
  rm -f "$gate/pid" 2>/dev/null || true
  rmdir "$gate" 2>/dev/null || true
}

# Break a stale lock, guarded against the double-steal described above.
# Returns 0 when the lock was removed (or vanished on its own), 1 when the
# break was abandoned because the lock changed hands or stopped being stale.
_state_lock_break() {
  local lock_dir="$1" stale_age="$2" before after aside before_token
  before="$(cat "$lock_dir/owner" 2>/dev/null || printf '__no_owner__')"
  sleep 0.2
  [[ -d "$lock_dir" ]] || return 0
  after="$(cat "$lock_dir/owner" 2>/dev/null || printf '__no_owner__')"
  # Different bytes => a live holder rewrote it or the lock was re-acquired by
  # someone else in the interim. Never break in that case. Each acquisition
  # stamps a fresh `token=`, so a lock that changed hands never compares equal
  # even if the same pid re-took it.
  [[ "$before" == "$after" ]] || return 1
  # Re-sampling identical "__no_owner__" bytes proves nothing on its own -- an
  # acquire and a release both pass through that state, and under CPU
  # contention a holder can sit in it longer than the resample window. The
  # decision is left to _state_lock_is_stale, which for an owner-less lock
  # falls back to the DIRECTORY's mtime: fresh => leave it alone (a live holder
  # mid-acquire), older than STALE_AGE => genuinely orphaned and breakable, so
  # a holder that died between mkdir and publishing `owner` still recovers
  # rather than wedging the fleet forever (#930).
  _state_lock_is_stale "$lock_dir" "$stale_age" || return 1
  before_token="$(_state_lock_meta "$lock_dir/owner" token)"
  # Judge-and-move must be one step (#2460): take the gate, then confirm the
  # lock is STILL the instance judged stale before renaming it. Without this a
  # cleaner that paused after the check above could rename a successor's fresh
  # lock. A taken gate means a commit is in flight -- abandon, never wait.
  _state_lock_gate_take "$lock_dir" 0 || return 1
  if [[ ! -d "$lock_dir" ]]; then
    _state_lock_gate_drop "$lock_dir"
    return 0
  fi
  if [[ "$(_state_lock_meta "$lock_dir/owner" token)" != "$before_token" ]] \
     || ! _state_lock_is_stale "$lock_dir" "$stale_age"; then
    _state_lock_gate_drop "$lock_dir"
    return 1
  fi
  aside="${lock_dir}.stale.$$-${RANDOM}"
  # Rename-aside is atomic: at most one racer can move this exact directory.
  if mv "$lock_dir" "$aside" 2>/dev/null; then
    _state_lock_gate_drop "$lock_dir"
    local dead_pid
    dead_pid="$(_state_lock_meta "$aside/owner" pid)"
    rm -rf "$aside" 2>/dev/null || true
    echo "state-lock: broke stale lock $lock_dir (previous holder pid ${dead_pid:-unknown})" >&2
    return 0
  fi
  _state_lock_gate_drop "$lock_dir"
  return 1
}

# state_lock_acquire <state-file-path> [timeout-seconds]
# Blocks until the lock is held, the timeout expires, or the lock dir is
# unwritable. Registers an EXIT trap so the lock is released even if the
# caller exits early (including `set -e` aborts). Sets STATE_LOCK_WAITED on
# every return — see the header for the 0/1 contract.
state_lock_acquire() {
  local state_file="$1"
  local timeout="${2:-${CLAUDE_STATE_LOCK_TIMEOUT:-30}}"
  local stale_age="${CLAUDE_STATE_LOCK_STALE_AGE:-120}"
  local lock_dir="${state_file}.lock"
  local parent started_at

  # Re-entrancy: a holder that shells out to another state-writing script
  # passes CLAUDE_STATE_LOCK_HELD down through the environment. Re-acquiring
  # the same lock in that subtree is a no-op instead of a self-deadlock.
  if [[ "${CLAUDE_STATE_LOCK_HELD:-}" == "$lock_dir" ]]; then
    # Adopt the ancestor's token so this process can still verify the lock via
    # state_lock_assert_held. STATE_LOCK_DIR stays EMPTY on purpose: only the
    # process that won the mkdir may release it.
    STATE_LOCK_HELD_DIR="$lock_dir"
    STATE_LOCK_TOKEN="${CLAUDE_STATE_LOCK_TOKEN:-}"
    # No attempt was made, so none was lost (header: STATE_LOCK_WAITED).
    STATE_LOCK_WAITED=0
    return 0
  fi

  # Not waited until an attempt actually loses to a lock already present —
  # set inside the loop, never inferred from a clock (issue #1567).
  STATE_LOCK_WAITED=0
  # Resolve the host once, in this shell, so the owner file and every
  # staleness check use the same identity.
  _state_lock_host_init

  # Legacy artifact: before issue #639, cr-review-hourly.sh used flock(1) on a
  # regular FILE at this exact path. A file sitting there makes `mkdir` fail
  # forever (and it is not a lock anyone still holds — flock's advisory lock
  # dies with the process, the file is just leftover). Clear it once.
  if [[ -e "$lock_dir" && ! -d "$lock_dir" ]]; then
    rm -f "$lock_dir" 2>/dev/null || true
  fi

  # $SECONDS is a bash builtin counter — a deadline without forking date(1).
  started_at=$SECONDS
  # Last non-empty owner snapshot seen while waiting (issue #2433), sampled
  # every few polls so the diagnostic survives a holder that released (or an
  # ownerless window) right at the deadline.
  local polls=0 last_pid="" last_host="" last_seen="" saw_dir=0 breaks=0
  while :; do
    if mkdir "$lock_dir" 2>/dev/null; then
      # One stamp call for both fields, and $HOSTNAME instead of hostname(1):
      # acquisition sits in the hot path of every state write, so each avoided
      # fork is measurable.
      local stamp token owner_tmp
      stamp="$(_state_lock_stamp)"
      # Unique per ACQUISITION: pid alone repeats (same process re-acquiring,
      # and pid reuse across processes), and every ownership decision downstream
      # depends on telling two acquisitions apart. $RANDOM is a bash builtin —
      # no fork on the hot path.
      token="$$-${stamp%% *}-${RANDOM}${RANDOM}"
      owner_tmp="$lock_dir/.owner.$$"
      # Publish atomically: build the file under a temp name, then rename it
      # into place. A direct `> owner` is a sequence of separate writes, so
      # readers can catch it existing-but-incomplete — and an owner file
      # missing its `epoch=` line used to read as "ancient, break it" (#930).
      { printf 'pid=%s\n' "$$"
        printf 'host=%s\n' "$_STATE_LOCK_HOST_CACHE"
        printf 'epoch=%s\n' "${stamp%% *}"
        printf 'started=%s\n' "${stamp#* }"
        printf 'cmd=%s\n' "${0##*/}"
        printf 'token=%s\n' "$token"
      } > "$owner_tmp" 2>/dev/null && mv "$owner_tmp" "$lock_dir/owner" 2>/dev/null || {
        # Ownership is proven by this file at release time, so a lock we
        # cannot stamp is a lock we could never safely release. Give it back
        # immediately rather than holding something unreleasable.
        rm -f "$owner_tmp" 2>/dev/null || true
        _state_lock_destroy "$lock_dir"
        echo "state-lock: could not write owner metadata to $lock_dir/owner — releasing" >&2
        return "$STATE_LOCK_EXIT_TIMEOUT"
      }
      STATE_LOCK_DIR="$lock_dir"
      STATE_LOCK_HELD_DIR="$lock_dir"
      STATE_LOCK_TOKEN="$token"
      export CLAUDE_STATE_LOCK_HELD="$lock_dir"
      export CLAUDE_STATE_LOCK_TOKEN="$token"
      # Chain onto whatever EXIT trap the caller already installed for its own
      # temp files, so releasing the lock never silently drops their cleanup.
      _state_lock_install_trap
      return 0
    fi

    # mkdir can also fail because the PARENT does not exist yet (fresh HOME).
    # Create it lazily — off the hot path, where the parent normally exists.
    if [[ ! -d "${lock_dir%/*}" ]]; then
      parent="${lock_dir%/*}"
      if mkdir -p "$parent" 2>/dev/null; then
        continue
      fi
      # A parent that cannot be created used to spin here forever, past the
      # timeout (issue #2433). The deadline bounds this path too.
      if (( SECONDS - started_at >= timeout )); then
        _state_lock_timeout_message "$lock_dir" "$timeout" "" "" "" \
          "parent directory $parent could not be created" >&2
        return "$STATE_LOCK_EXIT_TIMEOUT"
      fi
      sleep 0.05
      continue
    fi

    # This attempt lost: the lock is (or just was) somebody else's. Set BEFORE
    # the stale branch on purpose — a stale lock we break and then take still
    # had another holder, and reports 1 (header: STATE_LOCK_WAITED).
    #
    # Deliberately NOT gated on re-checking that the lock directory still
    # exists. A holder can release between our failed mkdir and any look we
    # take now; it was still a holder, and reporting 0 for that acquire is the
    # unsafe direction — the caller would treat a contended acquire as clean.
    # A mkdir that failed for some other reason (an unwritable parent) lands
    # here too: if it persists it can only end in the timeout below, where the
    # caller holds nothing and the flag decides nothing; if it was transient,
    # over-reporting a wait costs a caller only its conservative branch.
    STATE_LOCK_WAITED=1

    # Low-rate identity sample (every 10th lost poll, plus the first): cheap,
    # and enough for the timeout diagnostic to name a holder truthfully.
    if (( polls % 10 == 0 )) && _state_lock_snapshot "$lock_dir"; then
      last_pid="$_SL_SNAP_PID" last_host="$_SL_SNAP_HOST" last_seen="$(_state_lock_now)"
    fi
    polls=$(( polls + 1 ))
    [[ -d "$lock_dir" ]] && saw_dir=1

    # The deadline is checked before every stale-break attempt after the
    # first, so neither a break that keeps failing nor a chain of successful
    # breaks can run past it; overshoot is at most one 0.2s resample. The
    # first break is always allowed, so even a zero-timeout caller still
    # recovers a dead holder's lock (issue #2433).
    if [[ -d "$lock_dir" ]] && _state_lock_is_stale "$lock_dir" "$stale_age"; then
      if (( breaks > 0 && SECONDS - started_at >= timeout )); then
        _state_lock_timeout_message "$lock_dir" "$timeout" "$last_pid" "$last_host" "$last_seen" "" "$saw_dir" >&2
        return "$STATE_LOCK_EXIT_TIMEOUT"
      fi
      breaks=$(( breaks + 1 ))
      # A refused break (commit gate busy, lock changed hands) falls through to
      # the timeout check below instead of retrying unconditionally — otherwise
      # a persistently busy gate would spin past the caller's timeout (#2460).
      if _state_lock_break "$lock_dir" "$stale_age"; then
        continue
      fi
    fi

    if (( SECONDS - started_at >= timeout )); then
      _state_lock_timeout_message "$lock_dir" "$timeout" "$last_pid" "$last_host" "$last_seen" "" "$saw_dir" >&2
      return "$STATE_LOCK_EXIT_TIMEOUT"
    fi
    sleep 0.05
  done
}

# Release the lock held by this process, if any. Safe to call more than once,
# and safe to call when the lock was already broken by someone else — the
# owner pid is re-checked so we never delete a lock that is no longer ours.
state_lock_release() {
  local lock_dir="$STATE_LOCK_DIR" token="$STATE_LOCK_TOKEN" owner_token
  # Reset for every caller, re-entrant ones included: once released, no
  # acquisition is in effect for the flag to describe.
  STATE_LOCK_WAITED=""
  # STATE_LOCK_DIR is empty for a re-entrant caller, so an inner writer can
  # never release the lock its ancestor owns.
  [[ -n "$lock_dir" ]] || return 0
  STATE_LOCK_DIR=""
  STATE_LOCK_HELD_DIR=""
  STATE_LOCK_TOKEN=""
  unset CLAUDE_STATE_LOCK_HELD
  unset CLAUDE_STATE_LOCK_TOKEN
  [[ -d "$lock_dir" ]] || return 0
  # Token check and removal run under the commit gate (#2460): a breaker that
  # re-checked this lock's token under the gate must not see it released and
  # re-taken before its rename. If the gate stays busy (a live holder stalled
  # mid-commit), release without it rather than leak the lock -- the residual
  # is a release racing a break of this same lock, which our token check
  # below still confines to a lock we own.
  local gated=0
  _state_lock_gate_take "$lock_dir" 50 && gated=1
  owner_token="$(_state_lock_meta "$lock_dir/owner" token)"
  # Delete ONLY on a positive ownership match, and match on the TOKEN rather
  # than the pid: a pid match cannot distinguish our acquisition from a later
  # one, and a lock broken as stale then re-taken by a recycled pid would be
  # deleted out from under its new owner. An empty/unreadable token is NOT
  # ours by default either — that is also the window between another process
  # winning `mkdir` and publishing its owner file (CodeAnt, PR #662).
  # Declining to delete is the safe error: a lock we fail to release ages out
  # via the staleness rules; one we wrongly delete lets two writers into the
  # critical section at once.
  if [[ -z "$token" || "$owner_token" != "$token" ]]; then
    (( gated )) && _state_lock_gate_drop "$lock_dir"
    return 0
  fi
  _state_lock_destroy "$lock_dir"
  (( gated )) && _state_lock_gate_drop "$lock_dir"
  return 0
}

# 0 while this process still holds the lock covering it, non-zero once that
# lock has been broken and re-acquired by somebody else.
#
# Breaking a stale lock can never be perfectly safe — a wedged-but-alive holder
# may wake up and finish its write. The defence is that the victim can find
# out: a break rotates the token, so the check below fails and the caller must
# ABANDON its read-modify-write rather than commit a value computed from a
# snapshot someone else has since replaced. Call it immediately before the
# commit `mv`, not earlier: everything between the check and the commit is
# still unprotected (#930).
# state_lock_commit <tmp-file> <destination>
#
# The guarded commit every read-modify-write writer should use: assert we still
# hold the lock, then move the temp file into place. Returns
# STATE_LOCK_EXIT_TIMEOUT (6) without committing when the lock was broken
# underneath us, and 5 when the move itself fails; the temp file is removed on
# either failure.
#
# This exists so the assertion cannot be forgotten. It is the ONLY thing
# standing between a broken lock and a silently dropped update, and a check
# that each writer has to remember independently is one that some writer will
# eventually skip — as three of them already had (CodeAnt, PR #937).
#
# CLOSED WINDOW (issue #2460)
#   The assertion and the `mv` used to be two unguarded operations. They now
#   run under the commit gate (COMMIT GATE above), which a breaker must also
#   hold to rename a lock away, so a stale break cannot land between them. A
#   wedged holder that loses the race is refused (exit 6), never committed.
state_lock_commit() {
  local tmp="$1" dest="$2" mv_err gate_dir="$STATE_LOCK_HELD_DIR"
  # Ownership check and `mv` run under the commit gate so a breaker cannot
  # replace the lock between them (#2460); see COMMIT GATE above.
  if [[ -n "$gate_dir" ]] && ! _state_lock_gate_take "$gate_dir" 50; then
    rm -f "$tmp" 2>/dev/null || true
    echo "state-lock: commit gate busy; refusing to commit $dest (unchanged, retry)" >&2
    return "$STATE_LOCK_EXIT_TIMEOUT"
  fi
  if ! state_lock_assert_held; then
    [[ -n "$gate_dir" ]] && _state_lock_gate_drop "$gate_dir"
    rm -f "$tmp" 2>/dev/null || true
    echo "state-lock: lock was broken by another writer mid-update; refusing to commit $dest (unchanged, retry)" >&2
    return "$STATE_LOCK_EXIT_TIMEOUT"
  fi
  # Capture mv's own diagnostic. A commit fails for distinct reasons -- a
  # read-only filesystem, ENOSPC, a permission change, a cross-device temp --
  # and each needs a different response, so swallowing stderr leaves the
  # operator with one indistinguishable message (CodeRabbit, PR #937).
  if ! mv_err="$(mv "$tmp" "$dest" 2>&1)"; then
    [[ -n "$gate_dir" ]] && _state_lock_gate_drop "$gate_dir"
    rm -f "$tmp" 2>/dev/null || true
    echo "state-lock: could not write $dest${mv_err:+ — $mv_err}" >&2
    return 5
  fi
  [[ -n "$gate_dir" ]] && _state_lock_gate_drop "$gate_dir"
  return 0
}

state_lock_assert_held() {
  local lock_dir="$STATE_LOCK_HELD_DIR" owner_token
  [[ -n "$lock_dir" ]] || return 1
  # An inherited lock with no token predates this library version (a parent
  # still running the old code). Unverifiable, but it is not ours to police,
  # and failing closed there would break re-entrant writers for no gain.
  [[ -n "$STATE_LOCK_TOKEN" ]] || return 0
  [[ -d "$lock_dir" ]] || return 1
  owner_token="$(_state_lock_meta "$lock_dir/owner" token)"
  [[ "$owner_token" == "$STATE_LOCK_TOKEN" ]]
}

# Install an EXIT trap that releases the lock, preserving any trap the caller
# had already set (these scripts install their own temp-file cleanup traps).
# Installed at most once per process: a script that acquires and releases in a
# loop would otherwise re-wrap its own trap on every cycle, growing the trap
# string without bound. state_lock_release is a no-op when nothing is held, so
# one installation covers every later acquire.
_STATE_LOCK_TRAP_INSTALLED=0
_state_lock_install_trap() {
  local existing
  [[ "$_STATE_LOCK_TRAP_INSTALLED" == 1 ]] && return 0
  _STATE_LOCK_TRAP_INSTALLED=1
  existing="$(trap -p EXIT)"
  # `trap -p` prints e.g.  trap -- 'rm -f /tmp/x' EXIT
  existing="${existing#trap -- }"
  existing="${existing% EXIT}"
  # Strip the surrounding single quotes bash adds, un-escaping embedded ones.
  if [[ "$existing" == \'*\' ]]; then
    existing="${existing#\'}"
    existing="${existing%\'}"
    existing="${existing//\'\\\'\'/\'}"
  fi
  if [[ -n "$existing" ]]; then
    # shellcheck disable=SC2064
    trap "state_lock_release; $existing" EXIT
  else
    trap 'state_lock_release' EXIT
  fi
}

# state_lock_sweep_asides <state-file> <inventory|apply> [grace-seconds] [max-candidates]
#
# Lock-aside sweep (issue #2402). Release and stale-break rename a lock to
# `<state-file>.lock.rel.<pid>-<n>` / `.lock.stale.<pid>-<n>` and then
# `rm -rf` it; a process killed between the two (a hook timeout, for one)
# leaves the aside behind for good. An aside is no longer a lock — nothing
# reads it as one, and its only remaining use is its own removal — so it can
# be removed without proving the fleet quiet. A releaser removing the same
# aside at the same moment is benign (its `rm` errors are suppressed). The
# real risk is filesystem substitution, so a candidate is removed only when
# ALL of these hold, re-checked immediately before deletion:
#   - an exact direct sibling name: <base>.lock.(rel|stale).<digits>-<digits>
#     (the live `<base>.lock` and its `.gate` never match);
#   - a real directory, not a symlink, owned by the current user;
#   - mtime older than grace-seconds (default 3600; a real lock lives
#     milliseconds, a stale one is broken at 120 s);
#   - it holds only regular, non-symlink `owner` / `.owner.*` files.
# Files are removed one by one, then `rmdir` — never `rm -rf`, never a
# followed symlink. Anything else is retained and reported with its reason.
# Candidates beyond max-candidates (default 500) are counted unexamined.
# Never touches acquire or release; costs nothing on the lock hot path.
#
# stdout: one `<outcome>\t<reason>\t<path>` line per candidate (outcome:
# removed | removable | retained | failed | unexamined), then
# `totals\tremoved=N removable=N retained=N failed=N unexamined=N\t<state-file>`.
# Returns 0, 1 when any removal failed, 2 on a usage error.
state_lock_sweep_asides() (
  local state_file="${1:-}" mode="${2:-inventory}" grace="${3:-3600}" cap="${4:-500}"
  local dir base now c name entry reason mtime examined=0 phys_dir
  local removed=0 removable=0 retained=0 failed=0 unexamined=0
  # Bounded digit strings, read as decimal (a leading 0 must not mean octal).
  [[ -n "$state_file" && ( "$mode" == inventory || "$mode" == apply ) &&
     "$grace" =~ ^[0-9]{1,9}$ && "$cap" =~ ^[0-9]{1,9}$ ]] || {
    echo "state-lock: usage: state_lock_sweep_asides <state-file> <inventory|apply> [grace-seconds 0-999999999] [max 0-999999999]" >&2
    return 2
  }
  grace=$((10#$grace)); cap=$((10#$cap))
  dir="$(dirname -- "$state_file")"; base="$(basename -- "$state_file")"
  shopt -s nullglob dotglob
  now="$(_state_lock_now)"
  report() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
  # One entry's verdict: empty when it is an expected lock file, or when it
  # vanished (a concurrent releaser finishing the same cleanup).
  entry_problem() {
    local e="$1" n
    n="$(basename -- "$e")"
    [[ -e "$e" || -L "$e" ]] || return 0
    if [[ -L "$e" ]]; then echo "symlink entry $n"; return; fi
    if [[ -d "$e" ]]; then echo "nested directory $n"; return; fi
    [[ -f "$e" ]] || { echo "unexpected entry $n"; return; }
    case "$n" in owner|.owner.*) ;; *) echo "unexpected entry $n" ;; esac
  }
  for c in "$dir/$base".lock.rel.* "$dir/$base".lock.stale.*; do
    name="$(basename -- "$c")"
    [[ "$name" =~ ^.+\.lock\.(rel|stale)\.[0-9]+-[0-9]+$ && "${name%.lock.*}" == "$base" ]] || {
      retained=$((retained + 1)); report retained "name does not match the aside pattern" "$c"; continue; }
    if (( examined >= cap )); then
      unexamined=$((unexamined + 1)); report unexamined "over the candidate cap ($cap)" "$c"; continue
    fi
    examined=$((examined + 1))
    reason=""
    if [[ -L "$c" ]]; then reason="symlink"
    elif [[ ! -d "$c" ]]; then reason="not a directory"
    elif [[ ! -O "$c" ]]; then reason="foreign owner"
    elif ! mtime="$(_state_lock_file_mtime "$c")"; then reason="age unknown"
    elif (( now - mtime < grace )); then reason="too young ($((now - mtime))s < ${grace}s)"
    else
      for entry in "$c"/*; do
        reason="$(entry_problem "$entry")"
        [[ -z "$reason" ]] || break
      done
    fi
    if [[ -n "$reason" ]]; then
      retained=$((retained + 1)); report retained "$reason" "$c"; continue
    fi
    if [[ "$mode" == inventory ]]; then
      removable=$((removable + 1)); report removable "stale aside" "$c"; continue
    fi
    # Vanished since the check: a concurrent releaser finished it.
    if [[ ! -e "$c" && ! -L "$c" ]]; then
      removed=$((removed + 1)); report removed "removed concurrently" "$c"; continue
    fi
    # Re-validate type and ownership right before deleting anything.
    if [[ -L "$c" || ! -d "$c" || ! -O "$c" ]]; then
      retained=$((retained + 1)); report retained "changed before removal" "$c"; continue
    fi
    # Delete from INSIDE the verified directory, bound to its inode: enter it,
    # confirm the physical path is the aside itself (a swap to a symlink would
    # land elsewhere, e.g. in the live lock), and unlink entries relative to
    # it, so a later swap of the name cannot redirect a deletion.
    phys_dir="$(cd -P -- "$dir" 2>/dev/null && pwd -P)" || phys_dir=""
    reason="$(
      [[ -n "$phys_dir" ]] || { echo "parent directory unresolvable"; exit 0; }
      cd -P -- "$c" 2>/dev/null || { [[ -e "$c" || -L "$c" ]] && echo "could not enter"; exit 0; }
      [[ "$(pwd -P)" == "$phys_dir/$name" && -O . ]] || { echo "changed before removal: resolves elsewhere"; exit 0; }
      for entry in ./*; do
        problem="$(entry_problem "$entry")"
        [[ -z "$problem" ]] || { echo "changed before removal: $problem"; exit 0; }
        [[ -e "$entry" || -L "$entry" ]] || continue
        if ! rm -f -- "$entry" 2>/dev/null && [[ -e "$entry" || -L "$entry" ]]; then
          echo "could not remove ${entry#./}"; exit 0
        fi
      done
    )"
    if [[ -z "$reason" ]] && ! rmdir -- "$c" 2>/dev/null; then
      # Gone already (a racing releaser finished it) counts as removed.
      [[ -e "$c" || -L "$c" ]] && reason="rmdir failed"
    fi
    if [[ -n "$reason" ]]; then
      failed=$((failed + 1)); report failed "$reason" "$c"
    else
      removed=$((removed + 1)); report removed "stale aside" "$c"
    fi
  done
  printf 'totals\tremoved=%s removable=%s retained=%s failed=%s unexamined=%s\t%s\n' \
    "$removed" "$removable" "$retained" "$failed" "$unexamined" "$state_file"
  (( failed == 0 )) || return 1
  return 0
)

# Guard: this file is a library. Running it directly just prints the header.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  sed -n '/^# PURPOSE$/,/^$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
  echo "This file is a library — source it, do not execute it." >&2
  exit 2
fi
