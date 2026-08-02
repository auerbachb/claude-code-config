#!/usr/bin/env bash
# state-lock.sh — portable advisory write lock for ~/.claude/session-state.json.
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
# decide whether a recorded pid is meaningful on THIS machine.
_state_lock_hostname() {
  if [[ -n "${HOSTNAME:-}" ]]; then
    printf '%s' "$HOSTNAME"
  else
    hostname
  fi
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
  if [[ -n "$pid" && "$host" == "$(_state_lock_hostname)" && "$pid" =~ ^[0-9]+$ ]]; then
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

# Break a stale lock, guarded against the double-steal described above.
# Returns 0 when the lock was removed (or vanished on its own), 1 when the
# break was abandoned because the lock changed hands or stopped being stale.
_state_lock_break() {
  local lock_dir="$1" stale_age="$2" before after aside
  before="$(cat "$lock_dir/owner" 2>/dev/null || printf '__no_owner__')"
  sleep 0.2
  [[ -d "$lock_dir" ]] || return 0
  after="$(cat "$lock_dir/owner" 2>/dev/null || printf '__no_owner__')"
  # Different bytes ⇒ a live holder rewrote it or the lock was re-acquired by
  # someone else in the interim. Never break in that case. Each acquisition
  # stamps a fresh `token=`, so a lock that changed hands never compares equal
  # even if the same pid re-took it.
  [[ "$before" == "$after" ]] || return 1
  # Re-sampling identical "__no_owner__" bytes proves nothing on its own — an
  # acquire and a release both pass through that state, and under CPU
  # contention a holder can sit in it longer than the resample window. The
  # decision is left to _state_lock_is_stale, which for an owner-less lock
  # falls back to the DIRECTORY's mtime: fresh ⇒ leave it alone (a live holder
  # mid-acquire), older than STALE_AGE ⇒ genuinely orphaned and breakable, so
  # a holder that died between mkdir and publishing `owner` still recovers
  # rather than wedging the fleet forever (#930).
  _state_lock_is_stale "$lock_dir" "$stale_age" || return 1
  aside="${lock_dir}.stale.$$-${RANDOM}"
  # Rename-aside is atomic: at most one racer can move this exact directory.
  if mv "$lock_dir" "$aside" 2>/dev/null; then
    local dead_pid
    dead_pid="$(_state_lock_meta "$aside/owner" pid)"
    rm -rf "$aside" 2>/dev/null || true
    echo "state-lock: broke stale lock $lock_dir (previous holder pid ${dead_pid:-unknown})" >&2
    return 0
  fi
  return 1
}

# state_lock_acquire <state-file-path> [timeout-seconds]
# Blocks until the lock is held, the timeout expires, or the lock dir is
# unwritable. Registers an EXIT trap so the lock is released even if the
# caller exits early (including `set -e` aborts).
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
    return 0
  fi

  # Legacy artifact: before issue #639, cr-review-hourly.sh used flock(1) on a
  # regular FILE at this exact path. A file sitting there makes `mkdir` fail
  # forever (and it is not a lock anyone still holds — flock's advisory lock
  # dies with the process, the file is just leftover). Clear it once.
  if [[ -e "$lock_dir" && ! -d "$lock_dir" ]]; then
    rm -f "$lock_dir" 2>/dev/null || true
  fi

  # $SECONDS is a bash builtin counter — a deadline without forking date(1).
  started_at=$SECONDS
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
        printf 'host=%s\n' "$(_state_lock_hostname)"
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
      mkdir -p "$parent" 2>/dev/null || true
      continue
    fi

    if [[ -d "$lock_dir" ]] && _state_lock_is_stale "$lock_dir" "$stale_age"; then
      _state_lock_break "$lock_dir" "$stale_age" || true
      continue
    fi

    if (( SECONDS - started_at >= timeout )); then
      echo "state-lock: timed out after ${timeout}s waiting for $lock_dir (held by pid $(_state_lock_meta "$lock_dir/owner" pid) on $(_state_lock_meta "$lock_dir/owner" host)); refusing to write unserialized" >&2
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
  # STATE_LOCK_DIR is empty for a re-entrant caller, so an inner writer can
  # never release the lock its ancestor owns.
  [[ -n "$lock_dir" ]] || return 0
  STATE_LOCK_DIR=""
  STATE_LOCK_HELD_DIR=""
  STATE_LOCK_TOKEN=""
  unset CLAUDE_STATE_LOCK_HELD
  unset CLAUDE_STATE_LOCK_TOKEN
  [[ -d "$lock_dir" ]] || return 0
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
    return 0
  fi
  _state_lock_destroy "$lock_dir"
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
# RESIDUAL WINDOW (deliberate, documented rather than papered over)
#   The assertion and the `mv` are two operations, so in principle a breaker
#   could steal the lock between them and this function would still commit.
#   POSIX shell has no compare-and-swap that would close that gap, so the
#   window is narrowed instead of eliminated, on two fronts:
#     • Nothing forks between the check and the `mv` — the gap is microseconds,
#       against the entire read-modify-write it used to span.
#     • Breaking a live lock now requires POSITIVE evidence: a dead holder pid,
#       or an age past STALE_AGE (120s default). A holder that reaches this
#       function within its first two minutes is not breakable at all, so the
#       residual applies only to a holder already wedged past that ceiling —
#       the case the header's FAILURE MODES section accepts on purpose.
#   Do not read this as "the race is fixed". It is bounded and evidence-gated;
#   a caller that needs more must not share one state file across writers.
state_lock_commit() {
  local tmp="$1" dest="$2" mv_err
  if ! state_lock_assert_held; then
    rm -f "$tmp" 2>/dev/null || true
    echo "state-lock: lock was broken by another writer mid-update; refusing to commit $dest (unchanged, retry)" >&2
    return "$STATE_LOCK_EXIT_TIMEOUT"
  fi
  # Capture mv's own diagnostic. A commit fails for distinct reasons — a
  # read-only filesystem, ENOSPC, a permission change, a cross-device temp —
  # and each needs a different response, so swallowing stderr leaves the
  # operator with one indistinguishable message (CodeRabbit, PR #937).
  if ! mv_err="$(mv "$tmp" "$dest" 2>&1)"; then
    rm -f "$tmp" 2>/dev/null || true
    echo "state-lock: could not write $dest${mv_err:+ — $mv_err}" >&2
    return 5
  fi
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

# Guard: this file is a library. Running it directly just prints the header.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  sed -n '/^# PURPOSE$/,/^$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
  echo "This file is a library — source it, do not execute it." >&2
  exit 2
fi
