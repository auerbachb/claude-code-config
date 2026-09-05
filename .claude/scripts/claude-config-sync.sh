#!/usr/bin/env bash
# claude-config-sync.sh — one idempotent freshen pass for this machine's Claude
# config (issue #1524).
#
# PURPOSE
#   Keeps a machine current with `origin/main` without anyone opening a session
#   there. One pass: fast-forward the skills worktree, publish the skill, agent,
#   CLAUDE.md and rules symlinks, verify the managed links resolve, re-run the
#   idempotent setup steps (hook registration, trust-flag repair), and leave a
#   durable signal for the one step no scheduler can perform — restarting a live
#   Claude session.
#
#   Register it with launchd via install-config-sync.sh. It is equally safe to
#   run by hand at any time, including while sessions are live, and is a no-op
#   when the machine is already fresh.
#
# SCOPE BOUNDARY (non-negotiable)
#   This job touches the skills worktree and the ~/.claude links, NOTHING else.
#   It never pulls, resets, checks out, or stashes the ROOT repo checkout — root
#   `main` hygiene stays a session-start concern behind dirty-main-guard.sh
#   (.claude/rules/main-hygiene.md). The one root-repo command that can occur is
#   inside setup-skills-worktree.sh on the first-ever bootstrap, which must
#   `fetch` and `worktree add` to create the worktree at all; neither changes the
#   root checkout's branch or working tree.
#
# CANONICAL PATHS (single source of truth — session-start-sync.sh and
# statusline.sh restate the marker/lock paths and are held to it by
# .claude/scripts/tests/claude-config-sync.test.sh)
#   ~/.claude/logs/claude-config-sync.log             human-readable run log
#   ~/.claude/logs/claude-config-sync-state.json      durable state; ALSO the
#                                                     lock base — state-lock.sh
#                                                     locks "<path>.lock"
#   ~/.claude/logs/claude-config-sync-events.jsonl    append-only failure /
#                                                     recovery events
#   ~/.claude/sync-restart-recommended.json           the signal marker
#
# CONCURRENCY
#   The whole worktree + symlink region runs under the portable state-lock.sh
#   mutex, the same lock session-start-sync.sh takes for its own sync region. If
#   another sync holds it, this run SKIPS cleanly (outcome `skipped`, exit 0)
#   rather than racing — a scheduled tick that waits for a session-start sync
#   has nothing useful to add.
#
# SIGNALS
#   restart_recommended  written when a landed sync changed something a live
#                        session cannot pick up: .claude/agents/, .claude/rules/,
#                        CLAUDE.md or .claude/skills/ content, a newly published
#                        agent symlink, or a first-time bootstrap. Cleared by
#                        session-start-sync.sh on a `startup` source — a true
#                        restart, which by definition already picked the changes
#                        up. NOT cleared by a later successful tick.
#   sync_failure         written once the consecutive-failure streak reaches
#                        CONFIG_SYNC_FAILURE_THRESHOLD (default 3), carrying how
#                        long it has been failing. Cleared by the next
#                        successful tick.
#   Both surface through session-start-sync.sh's additionalContext and through
#   the statusline badge. When neither portion applies the marker file is
#   removed, so a clean machine shows nothing.
#
# USAGE
#   claude-config-sync.sh [--json] [--quiet] [--help]
#
#     --json    Print a one-line JSON summary on stdout and suppress the
#               progress lines (they still reach the log file), so the output is
#               machine-readable.
#     --quiet   Suppress progress lines on stdout; the log file still gets them.
#     --help    Print this usage and exit 0.
#
# EXIT CODES
#   0  Success — including a no-op run and a clean `skipped` on lock contention
#   1  Sync failure (fetch, reset, bootstrap, or symlink publish failed)
#   2  Usage error
#
#   A skipped run deliberately exits 0: overlapping with a session-start sync is
#   normal and the next tick covers it. It is never silent — the log line, the
#   `skipped` outcome in --json, and the untouched failure counter all say so.
#
# ENVIRONMENT
#   CLAUDE_CONFIG_SYNC_LOCK_TIMEOUT     seconds to wait for the lock (default 30)
#   CLAUDE_CONFIG_SYNC_GIT_BOUND        per-call ceiling on a lock-held git call
#                                       (default: half the lock staleness
#                                       window); clamped to what is left of the
#                                       region at each call
#   CLAUDE_CONFIG_SYNC_PUBLISH_BOUND    per-call ceiling on a lock-held symlink
#                                       publisher (default: a sixth of the
#                                       staleness window); clamped the same way
#                                       against the wider publish region
#   CONFIG_SYNC_FAILURE_THRESHOLD       consecutive failures before the marker
#                                       carries a failure notice (default 3)
#   CONFIG_SYNC_MAX_LOG_BYTES           rotate the log/events files past this
#                                       size, one generation kept (default
#                                       262144)
#
# DEPENDENCIES
#   bash, git, jq, mkdir, mv, rm, date, mktemp, chmod, wc, awk, grep, tail, tr,
#   basename, dirname; python3 only via the publish scripts and register-hooks.py

set -uo pipefail

SCRIPT_NAME="claude-config-sync.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: claude-config-sync.sh [--json] [--quiet] [--help]

  One idempotent freshen pass for this machine's Claude config: fast-forward
  ~/.claude/skills-worktree to origin/main (bootstrapping it when absent),
  publish the skill / agent / CLAUDE.md / rules symlinks, verify the managed
  links resolve, re-run hook registration and trust-flag repair, and record the
  restart-recommended / sync-failure signal.

  Scope is the skills worktree and ~/.claude links only. The root repo checkout
  is never pulled, reset, or checked out.

OPTIONS
  --json    One-line JSON summary on stdout; progress goes to the log only
  --quiet   Suppress progress lines on stdout
  --help    Print this usage and exit 0

EXIT CODES
  0  success, including a no-op run and a clean skip on lock contention
  1  sync failure (fetch, reset, bootstrap, or symlink publish failed)
  2  usage error

FILES
  ~/.claude/logs/claude-config-sync.log            run log
  ~/.claude/logs/claude-config-sync-state.json     durable state and lock base
  ~/.claude/logs/claude-config-sync-events.jsonl   failure/recovery events
  ~/.claude/sync-restart-recommended.json          restart / failure signal
EOF
}

# Captured before the parsing loop shifts them away — the telemetry line below
# is meant to record what the caller actually passed.
ORIGINAL_ARGS="$*"

OPT_JSON=0
OPT_QUIET=0
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json)    OPT_JSON=1; OPT_QUIET=1 ;;
    --quiet)   OPT_QUIET=1 ;;
    *)
      echo "$SCRIPT_NAME: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${ORIGINAL_ARGS//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SKILLS_WT="$HOME/.claude/skills-worktree"
LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/claude-config-sync.log"
STATE_FILE="$LOG_DIR/claude-config-sync-state.json"
EVENTS_FILE="$LOG_DIR/claude-config-sync-events.jsonl"
MARKER_FILE="$HOME/.claude/sync-restart-recommended.json"

LOCK_TIMEOUT="${CLAUDE_CONFIG_SYNC_LOCK_TIMEOUT:-30}"
FAILURE_THRESHOLD="${CONFIG_SYNC_FAILURE_THRESHOLD:-3}"
MAX_LOG_BYTES="${CONFIG_SYNC_MAX_LOG_BYTES:-262144}"

mkdir -p "$LOG_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

rotate_if_large() {
  local file="$1" bytes
  [[ -f "$file" ]] || return 0
  bytes="$(wc -c < "$file" 2>/dev/null | tr -d ' ')"
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 0
  (( bytes > MAX_LOG_BYTES )) || return 0
  mv -f "$file" "${file}.1" 2>/dev/null || true
}

log() {
  local level="$1"; shift
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [$level] $*"
  printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
  if (( OPT_QUIET == 0 )); then
    printf '%s\n' "$line"
  fi
}

WARNINGS=()
warn() {
  WARNINGS+=("$*")
  log warn "$*"
}

rotate_if_large "$LOG_FILE"
rotate_if_large "$EVENTS_FILE"
# Owner-only from the moment they exist: these files record this machine's
# config activity and belong to nobody else.
: >> "$LOG_FILE" 2>/dev/null || true
chmod 600 "$LOG_FILE" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Helper resolution (RESOLVE contract, .claude/reference/portable-skill-resolution.md)
#
# The skills worktree copy wins after the fast-forward: it is pinned to main, so
# a scheduled tick installed from an older checkout still runs the newest
# publisher. This script's own directory is the fallback.
# ---------------------------------------------------------------------------
resolve_helper() {
  local name="$1" subdir="${2:-scripts}" candidate
  for candidate in \
    "$SKILLS_WT/.claude/$subdir/$name" \
    "$HOME/.claude/$subdir/$name" \
    "$SCRIPT_DIR/../$subdir/$name" \
    "$SCRIPT_DIR/$name"
  do
    # -r as well as -f: every caller runs `bash "$candidate"`, which needs read
    # access. Without it, an unreadable stale worktree copy would be selected
    # and fail, shadowing a perfectly good later candidate (the same rule the
    # installer applies to its worktree-vs-local choice).
    if [[ -f "$candidate" && -r "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Lock — the entire worktree + symlink + state region runs under it.
# ---------------------------------------------------------------------------
LOCK_LIB="$SCRIPT_DIR/state-lock.sh"
if [[ ! -f "$LOCK_LIB" ]]; then
  log error "state-lock.sh not found at $LOCK_LIB — refusing to sync unserialized"
  exit 1
fi
# shellcheck source=state-lock.sh
source "$LOCK_LIB"

# ---------------------------------------------------------------------------
# Bounded git — the locked region must never outlive the lock's own staleness
# window.
#
# state-lock.sh breaks a lock on AGE ALONE, with no liveness check: its
# _state_lock_is_stale returns "stale" once the lock is older than STALE_AGE
# (120s by default), and its header states the tradeoff outright — "Holder
# alive but wedged >STALE_AGE: the lock IS broken." An unbounded `git fetch`
# over a slow or hanging network therefore lets a perfectly healthy holder be
# dispossessed mid-run: a session-start hook or the next tick breaks the lock,
# resets and publishes against the same worktree concurrently, and this run's
# later commit_json is refused by state_lock_assert_held — so the restart
# marker it owed never lands at all.
#
# Bounding the git calls to comfortably less than STALE_AGE removes the race by
# construction: the region either finishes inside the window or fails loudly
# with a diagnostic, and a failure that records itself is strictly better than a
# silent loss of the mutex.
#
# It has to be ONE budget across the calls, not a bound per call. There are TWO
# of them under a single acquire — fetch, then reset — so two independent 2/3
# bounds came to 160s against a 120s window. A slow-but-successful fetch could
# leave the reset still running past the point where another sync reads this
# lock as stale, breaks it, and publishes against the half-updated tree, while
# this run's own commit_json is then refused by state_lock_assert_held and the
# marker it owed never lands. Both halves of the race the bound exists to
# prevent, reached through the bound itself.
BOUNDED_LIB="$SCRIPT_DIR/lib/bounded-run.sh"
GIT_BOUND_AVAILABLE=0
if [[ -f "$BOUNDED_LIB" ]]; then
  # shellcheck source=lib/bounded-run.sh
  source "$BOUNDED_LIB" && GIT_BOUND_AVAILABLE=1
fi

_stale_age="${CLAUDE_STATE_LOCK_STALE_AGE:-120}"
[[ "$_stale_age" =~ ^[1-9][0-9]*$ ]] || _stale_age=120
# Half the window for the git region as a WHOLE — both calls together — leaving
# the other half for the publish, hook registration, trust repair and state
# commit that also run under this lock. The per-call value below is a ceiling on
# any single call; _git_bound_remaining clamps it to what is left of the region.
_git_region_budget=$(( _stale_age / 2 ))
(( _git_region_budget > 0 )) || _git_region_budget=60
_GIT_MIN_BOUND_SECS=5
# The publishers hold the SAME lock, and were deliberately left outside the
# budget above by PR #1553 on the grounds that a few dozen readlink/ln/mv calls
# finish in well under a second (issue #1593). "In practice" is the gap: on a
# stalled network home a publisher can hold this lock past STALE_AGE, at which
# point a second sync breaks it and mutates the same worktree and the same
# ~/.claude links concurrently — the exact race the lock exists to prevent.
#
# They are therefore scheduled against the SAME staleness window, measured from
# the SAME acquire instant, with the last quarter reserved for the hook
# registration, trust repair and state commit that follow them under this lock.
_PUBLISH_TAIL_RESERVE_SECS=$(( _stale_age / 4 ))
(( _PUBLISH_TAIL_RESERVE_SECS > 0 )) || _PUBLISH_TAIL_RESERVE_SECS=30
_publish_region_budget=$(( _stale_age - _PUBLISH_TAIL_RESERVE_SECS ))
(( _publish_region_budget > 0 )) || _publish_region_budget=90
# Per-call ceiling, clamped to what is left of the region at each call.
_default_publish_bound=$(( _stale_age / 6 ))
(( _default_publish_bound > 0 )) || _default_publish_bound=20
_PUBLISH_MIN_BOUND_SECS=3
PUBLISH_BOUND_SECS="$_default_publish_bound"
# Set at the acquire, so the region is measured from when the lock was taken —
# which is also when the staleness clock this budget defends against starts.
_git_region_t0=""
_default_git_bound="$_git_region_budget"
if (( GIT_BOUND_AVAILABLE == 1 )); then
  GIT_BOUND_SECS="$(normalize_bound "${CLAUDE_CONFIG_SYNC_GIT_BOUND:-}" "$_default_git_bound")"
  PUBLISH_BOUND_SECS="$(normalize_bound "${CLAUDE_CONFIG_SYNC_PUBLISH_BOUND:-}" "$_default_publish_bound")"
  CAPTURE="$(mktemp "${TMPDIR:-/tmp}/config-sync-out.XXXXXX")"    || CAPTURE=""
  CAPTURE_ERR="$(mktemp "${TMPDIR:-/tmp}/config-sync-err.XXXXXX")" || CAPTURE_ERR=""
  [[ -n "$CAPTURE" && -n "$CAPTURE_ERR" ]] || GIT_BOUND_AVAILABLE=0
  # record_failure exits 1 from wherever it is called, so the captures are
  # reaped from a trap rather than a line at the end that a failure path skips.
  trap 'rm -f "${CAPTURE:-}" "${CAPTURE_ERR:-}" 2>/dev/null || true' EXIT
fi

# Run one git call under the bound. GIT_OUT / GIT_ERR mirror the `$( )` capture
# they replace; GIT_TIMED_OUT says whether the bound cut the call short.
# NEVER call this inside `$( )` — bounded-run.sh's contract, because a subshell
# discards BOUNDED_TIMED_OUT and the capture handover.
#
# The helper supplies `-C "$SKILLS_WT"` ITSELF rather than taking it from the
# caller. That keeps the scope guarantee structural — there is no spelling of a
# git_sync call that can reach the root repo checkout — and it keeps every git
# invocation in this file literally scoped, which the scope guard in
# claude-config-sync.test.sh Test 6 checks line by line.
GIT_OUT=""
GIT_ERR=""
GIT_TIMED_OUT=0
# The bound actually applied to the last call — the region-clamped value, which
# is what the failure messages must name rather than the per-call ceiling.
GIT_LAST_BOUND="${GIT_BOUND_SECS:-0}"
# Seconds left of the REGION budget — deliberately NOT clamped to the per-call
# ceiling. The caller applies the floor to this figure and the ceiling
# separately, because conflating them makes any explicitly configured ceiling
# below the floor decline every call instead of honouring it. The floor asks
# "is there room to finish?", which is a question about the region, not about
# how short the operator chose to make one call.
#
# Falls back to the region budget when the clock is unusable: an unreadable
# clock must not collapse every bound to zero and disable the sync outright.
#
# The optional argument names WHICH budget to measure against — the git region
# by default, the wider publish region for the publishers. Both are measured
# from the same _git_region_t0, because both defend the same staleness clock,
# which starts at the acquire.
_git_region_remaining() { # _git_region_remaining [budget-secs]
  local now elapsed remaining budget="${1:-$_git_region_budget}"
  [[ -n "$_git_region_t0" ]] || { printf '%s' "$budget"; return 0; }
  now="$(date -u +%s 2>/dev/null)" || { printf '%s' "$budget"; return 0; }
  [[ "$now" =~ ^[0-9]+$ ]] || { printf '%s' "$budget"; return 0; }
  elapsed=$(( now - _git_region_t0 ))
  remaining=$(( budget - elapsed ))
  (( remaining < 0 )) && remaining=0
  printf '%s' "$remaining"
}

# Phrase a trip honestly: a call that ran out of time "exceeded its Ns bound",
# one that never started was "declined". Both are recorded failures either way.
_git_trip_reason() {
  if [[ "${GIT_ERR:-}" == declined:* ]]; then
    printf '%s' "$GIT_ERR"
  else
    printf 'exceeded its %ss bound' "${GIT_LAST_BOUND:-$GIT_BOUND_SECS}"
  fi
}

git_sync() { # git_sync <git subcommand and args…>  (always -C the worktree)
  local rc=0
  GIT_TIMED_OUT=0
  if (( GIT_BOUND_AVAILABLE == 0 )); then
    # Refuse rather than run unbounded while holding the lock — the same stance
    # session-start-sync.sh's _run_locked takes, against the same lock, for the
    # same reason. Without a bound there is no deadline at all, so a call can
    # outlive the ${_stale_age}s staleness window; another sync then treats this
    # LIVE holder's lock as stale and mutates the same worktree concurrently,
    # while this run's own commit_json is refused by state_lock_assert_held, so
    # the restart marker it owed never lands. Both halves of the race the bound
    # exists to prevent.
    #
    # This branch used to warn and proceed, which left that race open on exactly
    # the path least able to diagnose it. A missed tick is the cheap failure —
    # the next tick retries, and the session-start hook covers the interim — so
    # the trade runs the other way.
    #
    # Wording note: no bare "git " token in the message. Test 6's scope guard
    # greps this file for invocations and reads one in a string as a stray
    # unscoped call.
    GIT_TIMED_OUT=1
    GIT_OUT=""
    GIT_ERR="declined: bounded-run.sh unavailable — refusing to run unbounded while holding the config-sync lock"
    return 124
  fi
  local region_left
  region_left="$(_git_region_remaining)"
  # Ceiling and floor applied to different things on purpose — see
  # _git_region_remaining.
  GIT_LAST_BOUND="$region_left"
  (( GIT_LAST_BOUND > GIT_BOUND_SECS )) && GIT_LAST_BOUND="$GIT_BOUND_SECS"
  if (( region_left < _GIT_MIN_BOUND_SECS )); then
    # Decline rather than start a call that cannot finish inside the region.
    # Starting it is what lets the lock go stale under a live holder, and a
    # recorded failure is strictly better than a silently surrendered mutex.
    GIT_TIMED_OUT=1
    GIT_OUT=""
    # Wording note: no bare "git " token here. Test 6's scope guard greps this
    # file for git invocations, and a message containing one trips it as a
    # stray unscoped call.
    GIT_ERR="declined: only ${region_left}s left of the ${_git_region_budget}s lock-held fetch/reset budget"
    return 124
  fi
  run_bounded "$GIT_LAST_BOUND" git -C "$SKILLS_WT" "$@" || rc=$?
  GIT_OUT="$(cat "$CAPTURE" 2>/dev/null)" || GIT_OUT=""
  GIT_ERR="$(cat "$CAPTURE_ERR" 2>/dev/null)" || GIT_ERR=""
  [[ "${BOUNDED_TIMED_OUT:-0}" -eq 1 ]] && GIT_TIMED_OUT=1
  return "$rc"
}

# ---------------------------------------------------------------------------
# State helpers — all writes happen while the lock is held.
# ---------------------------------------------------------------------------
read_state() {
  if [[ -f "$STATE_FILE" ]]; then
    local doc
    doc="$(cat "$STATE_FILE" 2>/dev/null)" || doc=""
    if [[ -n "$doc" ]] && printf '%s' "$doc" | jq -e 'type == "object"' >/dev/null 2>&1; then
      printf '%s' "$doc"
      return 0
    fi
  fi
  printf '%s' '{}'
}

# commit_json <json> <destination>
# Atomic, lock-verified write of one JSON document. The temp file is created in
# the DESTINATION's own directory so the commit `mv` is a same-filesystem rename.
commit_json() {
  local doc="$1" dest="$2" tmp rc dest_dir
  dest_dir="$(dirname "$dest")"
  tmp="$(mktemp "${dest_dir}/.config-sync.XXXXXX" 2>/dev/null)" || {
    warn "could not create a temp file in $dest_dir — $dest not written"
    return 1
  }
  chmod 600 "$tmp" 2>/dev/null || true
  if ! printf '%s\n' "$doc" > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    warn "could not write temp file for $dest"
    return 1
  fi
  state_lock_commit "$tmp" "$dest"
  rc=$?
  if (( rc != 0 )); then
    warn "could not commit $dest (state-lock rc=$rc)"
    return 1
  fi
  return 0
}

append_event() {
  local event="$1"
  printf '%s\n' "$event" >> "$EVENTS_FILE" 2>/dev/null || true
  chmod 600 "$EVENTS_FILE" 2>/dev/null || true
}

read_marker() {
  if [[ -f "$MARKER_FILE" ]]; then
    local doc
    doc="$(cat "$MARKER_FILE" 2>/dev/null)" || doc=""
    if [[ -n "$doc" ]] && printf '%s' "$doc" | jq -e 'type == "object"' >/dev/null 2>&1; then
      printf '%s' "$doc"
      return 0
    fi
  fi
  printf '%s' '{}'
}

# write_marker <marker-json> — commits it, or removes the file when both signal
# portions are absent so a clean machine shows no badge at all.
write_marker() {
  local doc="$1" empty
  empty="$(printf '%s' "$doc" | jq -r '
    ((.restart_recommended // null) == null) and ((.sync_failure // null) == null)
  ' 2>/dev/null)" || empty="false"
  if [[ "$empty" == "true" ]]; then
    # Removal is a WRITE and gets the same ownership check the commit path
    # inherits from state_lock_commit. Without it this was the only mutation in
    # the file a DISPOSSESSED holder could still land: a run whose lock had
    # already been broken on age would delete a restart or failure marker the new
    # owner had just written. That is the precise loss this lock exists to
    # prevent, in its worst shape — a delete leaves nothing behind to show a
    # signal was dropped, so the user simply never sees the reminder.
    #
    # Returning non-zero rather than exiting: every caller already treats a
    # non-zero write_marker as "marker not persisted" and says so.
    if ! state_lock_assert_held; then
      warn "lock was broken by another writer; refusing to remove $MARKER_FILE — a newer marker may be present"
      return 1
    fi
    rm -f "$MARKER_FILE" 2>/dev/null || true
    return 0
  fi
  commit_json "$doc" "$MARKER_FILE"
}

# ---------------------------------------------------------------------------
# Outcome accumulators
# ---------------------------------------------------------------------------
OUTCOME="ok"
OLD_SHA=""
NEW_SHA=""
HEAD_CHANGED="false"
BOOTSTRAPPED="false"
RESTART_CATEGORIES=()
ERROR_MESSAGE=""

# json_array <element…> — a JSON array of the arguments, with empty strings
# dropped. Called with an EMPTY bash array this yields `[]` rather than `[""]`,
# which is the whole reason it exists in one place: every call site needs that
# behaviour and a second hand-rolled copy would eventually diverge.
json_array() {
  printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(length > 0))'
}

emit_summary() {
  local consecutive="$1" restart_flag="$2"
  if (( OPT_JSON == 1 )); then
    jq -cn \
      --arg outcome "$OUTCOME" \
      --arg old_sha "$OLD_SHA" \
      --arg new_sha "$NEW_SHA" \
      --argjson head_changed "$HEAD_CHANGED" \
      --argjson bootstrapped "$BOOTSTRAPPED" \
      --argjson restart_recommended "$restart_flag" \
      --argjson categories "$(json_array "${RESTART_CATEGORIES[@]+"${RESTART_CATEGORIES[@]}"}")" \
      --argjson warnings "$(json_array "${WARNINGS[@]+"${WARNINGS[@]}"}")" \
      --argjson consecutive_failures "$consecutive" \
      --arg error "$ERROR_MESSAGE" \
      --arg log_path "$LOG_FILE" \
      '{outcome: $outcome, head_changed: $head_changed, bootstrapped: $bootstrapped,
        old_sha: $old_sha, new_sha: $new_sha, restart_recommended: $restart_recommended,
        restart_categories: $categories, warnings: $warnings,
        consecutive_failures: $consecutive_failures, error: $error, log_path: $log_path}'
  fi
}

# elapsed_days <iso-timestamp> — whole days between then and now, 0 on any
# parse failure. Both `date` dialects are tried; an unparseable stamp reports 0
# rather than a fabricated age.
elapsed_days() {
  local stamp="$1" then_epoch now_epoch
  then_epoch="$(date -u -d "$stamp" +%s 2>/dev/null)" || then_epoch=""
  if [[ ! "$then_epoch" =~ ^[0-9]+$ ]]; then
    then_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$stamp" +%s 2>/dev/null)" || then_epoch=""
  fi
  now_epoch="$(date -u +%s 2>/dev/null)" || now_epoch=""
  if [[ "$then_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ && "$now_epoch" -ge "$then_epoch" ]]; then
    printf '%s' $(( (now_epoch - then_epoch) / 86400 ))
  else
    printf '0'
  fi
}

# record_failure <message> — bump the streak, extend the marker past the
# threshold, and exit 1.
# Derive the restart categories from what the fast-forward actually brought in.
# Called at the fast-forward rather than in Step 5 so the categories survive a
# record_failure between the two — see the call site for why that matters.
collect_head_change_categories() {
  local changed_paths
  [[ "$HEAD_CHANGED" == "true" && -n "$OLD_SHA" && -n "$NEW_SHA" ]] || return 0
  changed_paths="$(git -C "$SKILLS_WT" diff --name-only "$OLD_SHA" "$NEW_SHA" 2>/dev/null)" || changed_paths=""
  if [[ -z "$changed_paths" ]]; then
    warn "could not diff $OLD_SHA..$NEW_SHA — restart categories may be incomplete"
    return 0
  fi
  # Here-strings, never `printf … | grep -q` — see the SIGPIPE note above.
  grep -q '^\.claude/agents/' <<< "$changed_paths" && RESTART_CATEGORIES+=("agents")
  grep -q '^\.claude/rules/'  <<< "$changed_paths" && RESTART_CATEGORIES+=("rules")
  grep -q '^\.claude/skills/' <<< "$changed_paths" && RESTART_CATEGORIES+=("skills")
  grep -q '^CLAUDE\.md$'      <<< "$changed_paths" && RESTART_CATEGORIES+=("claude-md")
  return 0
}

record_failure() {
  local message="$1" state consecutive first_failure days marker new_marker new_state
  ERROR_MESSAGE="$message"
  OUTCOME="failed"
  log error "$message"

  state="$(read_state)"
  consecutive="$(printf '%s' "$state" | jq -r '(.consecutive_failures // 0) | tonumber? // 0' 2>/dev/null)" || consecutive=0
  [[ "$consecutive" =~ ^[0-9]+$ ]] || consecutive=0
  consecutive=$(( consecutive + 1 ))
  first_failure="$(printf '%s' "$state" | jq -r '.first_failure_at // empty' 2>/dev/null)" || first_failure=""
  [[ -n "$first_failure" ]] || first_failure="$NOW_ISO"

  new_state="$(printf '%s' "$state" | jq \
    --arg now "$NOW_ISO" \
    --arg first "$first_failure" \
    --arg err "$message" \
    --argjson streak "$consecutive" \
    '. + {schema_version: 1, last_run_at: $now, last_failure_at: $now,
          consecutive_failures: $streak, first_failure_at: $first, last_error: $err}' 2>/dev/null)" \
    || new_state=""
  if [[ -n "$new_state" ]]; then
    # Never `|| true`. commit_json warns about the CAUSE; this names the
    # CONSEQUENCE, which is the part that matters and is otherwise invisible:
    # the bumped streak did not reach disk, so the next tick re-reads the old
    # count and bumps to the same number again. A persistently unwritable state
    # file therefore pins consecutive_failures below FAILURE_THRESHOLD forever
    # and the repeated-failure badge — the only in-session signal that this job
    # is broken — never fires, however long the job has been failing.
    if ! commit_json "$new_state" "$STATE_FILE"; then
      warn "failure streak not persisted (now $consecutive) — the repeated-failure signal in $MARKER_FILE may never fire while $STATE_FILE stays unwritable"
      append_event "$(jq -cn --arg at "$NOW_ISO" --arg file "$STATE_FILE" \
        '{at: $at, event: "state_commit_failed", file: $file, phase: "failure"}')"
    fi
  else
    warn "could not build the failure state document"
  fi

  append_event "$(jq -cn --arg at "$NOW_ISO" --arg err "$message" --argjson streak "$consecutive" \
    '{at: $at, event: "failure", consecutive_failures: $streak, error: $err}')"

  # Preserve the restart signal for content that ALREADY landed. This function
  # exits the run, so without this the categories collected at the fast-forward
  # die here — and they cannot be recovered later, because the next tick sees an
  # unchanged HEAD and an empty diff. The failure is real and reported, but the
  # user still has to restart to pick up the definitions that did land.
  if (( ${#RESTART_CATEGORIES[@]} > 0 )); then
    local fail_categories_json fail_marker fail_new_marker
    fail_categories_json="$(json_array "${RESTART_CATEGORIES[@]+"${RESTART_CATEGORIES[@]}"}")" \
      || fail_categories_json=""
    if [[ -n "$fail_categories_json" ]]; then
      fail_marker="$(read_marker)"
      fail_new_marker="$(printf '%s' "$fail_marker" | jq \
        --arg now "$NOW_ISO" \
        --arg sha "$NEW_SHA" \
        --argjson categories "$fail_categories_json" \
        '(. + {restart_recommended: {
                categories: (((.restart_recommended.categories // []) + $categories) | unique),
                head_sha: $sha, at: $now}})
         | .restart_recommended.reason =
             ("config sync updated " + (.restart_recommended.categories | join(", ")))' 2>/dev/null)" \
        || fail_new_marker=""
      if [[ -n "$fail_new_marker" ]]; then
        write_marker "$fail_new_marker" || true
        log info "restart recommended (${RESTART_CATEGORIES[*]}) despite this failure — signal in $MARKER_FILE"
      else
        warn "could not preserve the restart signal across this failure"
      fi
    fi
  fi

  if (( consecutive >= FAILURE_THRESHOLD )); then
    days="$(elapsed_days "$first_failure")"
    marker="$(read_marker)"
    new_marker="$(printf '%s' "$marker" | jq \
      --arg now "$NOW_ISO" \
      --arg first "$first_failure" \
      --argjson streak "$consecutive" \
      --arg msg "config sync has been failing for ${days} day(s) — ${consecutive} consecutive failures; see $LOG_FILE" \
      '. + {sync_failure: {message: $msg, consecutive_failures: $streak,
                           first_failure_at: $first, at: $now}}' 2>/dev/null)" || new_marker=""
    if [[ -n "$new_marker" ]]; then
      write_marker "$new_marker" || true
      log warn "surfaced sync-failure signal in $MARKER_FILE (streak $consecutive)"
    else
      warn "could not build the failure marker document"
    fi
  fi

  state_lock_release
  # Report the same restart state the marker just recorded. Hardcoding "false"
  # here would make the --json summary contradict the durable marker on exactly
  # the path the block above exists to cover: a failure after content landed.
  local failure_restart_flag="false"
  (( ${#RESTART_CATEGORIES[@]} > 0 )) && failure_restart_flag="true"
  emit_summary "$consecutive" "$failure_restart_flag"
  exit 1
}

# ---------------------------------------------------------------------------
# Acquire the lock. Contention is a clean skip, not a failure.
# ---------------------------------------------------------------------------
if ! state_lock_acquire "$STATE_FILE" "$LOCK_TIMEOUT"; then
  OUTCOME="skipped"
  ERROR_MESSAGE="another config sync holds the lock; skipping this tick"
  log info "$ERROR_MESSAGE"
  emit_summary 0 "false"
  exit 0
fi

# The lock is held from here, so the staleness clock this budget defends
# against starts here too — measure the git region from the same instant.
_git_region_t0="$(date -u +%s 2>/dev/null)" || _git_region_t0=""

log info "config sync starting (worktree: $SKILLS_WT)"

# ---------------------------------------------------------------------------
# Step 1 — bootstrap the worktree when it is absent, else fast-forward it.
# ---------------------------------------------------------------------------
if [[ ! -d "$SKILLS_WT/.claude/skills" || ! -e "$SKILLS_WT/.git" ]]; then
  log info "skills worktree missing or incomplete — bootstrapping"
  repo_root=""
  repo_root_helper="$(resolve_helper repo-root.sh)" || repo_root_helper=""
  checkout_root="$(cd -- "$SCRIPT_DIR/../.." 2>/dev/null && pwd)" || checkout_root=""
  if [[ -n "$repo_root_helper" && -n "$checkout_root" ]]; then
    repo_root="$(bash "$repo_root_helper" "$checkout_root" 2>/dev/null)" || repo_root=""
  fi
  [[ -n "$repo_root" ]] || repo_root="$checkout_root"
  if [[ -z "$repo_root" || ! -f "$repo_root/setup-skills-worktree.sh" ]]; then
    record_failure "cannot bootstrap: setup-skills-worktree.sh not found from $SCRIPT_DIR"
  fi
  # Bounded for the same reason the fetch/reset below are (and it is the larger
  # exposure of the two): setup-skills-worktree.sh clones and fetches over the
  # network while THIS run holds the lock. Left unbounded, a hung fetch carries
  # the locked region past STALE_AGE, at which point another sync treats this
  # lock as stale and starts mutating the same worktree concurrently. A tripped
  # bound is a recorded failure, never a silently surrendered lock.
  #
  # run_bounded is called at statement level, never inside `$( )` — a subshell
  # would discard BOUNDED_TIMED_OUT and the capture handover (bounded-run.sh's
  # contract, same as git_sync).
  if (( GIT_BOUND_AVAILABLE == 0 )); then
    # Refused for the same reason as git_sync above, and this is the LARGER
    # exposure of the two: setup-skills-worktree.sh clones and fetches over the
    # network while this run holds the lock, so unbounded it is the likeliest
    # call to carry the locked region past the staleness window.
    record_failure "cannot bootstrap: bounded-run.sh unavailable — refusing to run setup-skills-worktree.sh unbounded while holding the config-sync lock, which could outlive the ${_stale_age}s staleness window and let a concurrent sync mutate the same worktree"
  else
    _bootstrap_rc=0
    # Clamped to what is LEFT of the lock-held region, exactly as git_sync
    # clamps its own calls — GIT_BOUND_SECS is only a per-call ceiling. Passing
    # that ceiling raw let an operator override (CLAUDE_CONFIG_SYNC_GIT_BOUND,
    # which normalize_bound accepts at any size) schedule a single lock-held
    # call for longer than the ${_stale_age}s staleness window, so the bound
    # meant to prevent dispossession could licence it instead.
    #
    # Same floor/ceiling separation as git_sync: the floor is asked of the
    # REGION ("is there room to finish?"), the ceiling of the call.
    _bootstrap_region_left="$(_git_region_remaining)"
    GIT_LAST_BOUND="$_bootstrap_region_left"
    (( GIT_LAST_BOUND > GIT_BOUND_SECS )) && GIT_LAST_BOUND="$GIT_BOUND_SECS"
    if (( _bootstrap_region_left < _GIT_MIN_BOUND_SECS )); then
      GIT_TIMED_OUT=1
      GIT_ERR="declined: only ${_bootstrap_region_left}s left of the ${_git_region_budget}s lock-held region budget"
      record_failure "setup-skills-worktree.sh $(_git_trip_reason) — aborted before the ${_stale_age}s lock staleness window could dispossess this run"
    fi
    run_bounded "$GIT_LAST_BOUND" bash "$repo_root/setup-skills-worktree.sh" || _bootstrap_rc=$?
    bootstrap_out="$(cat "$CAPTURE" 2>/dev/null)" || bootstrap_out=""
    _bootstrap_err="$(cat "$CAPTURE_ERR" 2>/dev/null)" || _bootstrap_err=""
    if (( _bootstrap_rc != 0 )); then
      if [[ "${BOUNDED_TIMED_OUT:-0}" -eq 1 ]]; then
        record_failure "setup-skills-worktree.sh $(_git_trip_reason) — aborted before the ${_stale_age}s lock staleness window could dispossess this run"
      else
        record_failure "setup-skills-worktree.sh failed: $(printf '%s' "${_bootstrap_err:-$bootstrap_out}" | tail -5 | tr '\n' ' ')"
      fi
    fi
  fi
  BOOTSTRAPPED="true"
  HEAD_CHANGED="true"
  RESTART_CATEGORIES+=("bootstrap")
  NEW_SHA="$(git -C "$SKILLS_WT" rev-parse HEAD 2>/dev/null)" || NEW_SHA=""
  log info "bootstrap complete (HEAD ${NEW_SHA:-unknown})"
else
  OLD_SHA="$(git -C "$SKILLS_WT" rev-parse HEAD 2>/dev/null)" || OLD_SHA=""
  # No degraded-path warning here any more: git_sync now DECLINES when the bound
  # is unavailable rather than running unbounded, and records the reason through
  # the same _git_trip_reason path as any other trip. A warning saying the calls
  # "run unbounded" would now be untrue.
  # The two calls that can block on the network or a stalled filesystem, and so
  # the two that could carry the locked region past STALE_AGE. A tripped bound
  # is a recorded failure, never a silently surrendered lock.
  if ! git_sync fetch origin main --quiet; then
    if (( GIT_TIMED_OUT == 1 )); then
      record_failure "skills worktree fetch $(_git_trip_reason) — aborted before the ${_stale_age}s lock staleness window could dispossess this run"
    else
      record_failure "skills worktree fetch failed: $(printf '%s' "${GIT_ERR:-$GIT_OUT}" | tr '\n' ' ')"
    fi
  fi
  if ! git_sync reset --hard origin/main --quiet; then
    if (( GIT_TIMED_OUT == 1 )); then
      record_failure "skills worktree reset $(_git_trip_reason) — aborted before the ${_stale_age}s lock staleness window could dispossess this run"
    else
      record_failure "skills worktree reset failed: $(printf '%s' "${GIT_ERR:-$GIT_OUT}" | tr '\n' ' ')"
    fi
  fi
  NEW_SHA="$(git -C "$SKILLS_WT" rev-parse HEAD 2>/dev/null)" || NEW_SHA=""
  if [[ -n "$OLD_SHA" && -n "$NEW_SHA" && "$OLD_SHA" != "$NEW_SHA" ]]; then
    HEAD_CHANGED="true"
    log info "worktree fast-forwarded ${OLD_SHA:0:8} -> ${NEW_SHA:0:8}"
    # Collected HERE, immediately after the content lands, and not down in
    # Step 5. record_failure exits the run, so any failure between this point
    # and Step 5 — a publisher, the trust repair — used to discard these
    # categories permanently: the fast-forward has already been written to the
    # worktree, so the NEXT tick sees an unchanged HEAD, an empty diff, and
    # never emits a restart signal for content that did land.
    collect_head_change_categories
  else
    log info "worktree already at ${NEW_SHA:0:8}"
  fi
fi

# ---------------------------------------------------------------------------
# Step 2 — publish symlinks. Links are the whole point of the pass, so a
# publisher failure is a hard failure.
# ---------------------------------------------------------------------------
# Resolved through repo-root.sh rather than a hand-rolled listing. That script
# exists to centralize exactly this "first `worktree ` stanza" lookup, and —
# the reason it matters HERE — it bounds its own git calls through
# lib/bounded-run.sh. The raw listing this replaced ran UNBOUNDED while this run
# holds the config-sync lock, which is the same hazard the fetch/reset bounds
# above exist to remove: a lock broken on age alone under a live holder, another
# sync mutating the same worktree, and this run's commit_json refused so the
# marker never lands. Bounding fetch and reset while leaving a lock-held git
# call beside them unbounded defends nothing.
#
# The SIGPIPE lesson that shaped the previous spelling is preserved by having no
# pipeline at all. It was: under `set -o pipefail` an early-exiting consumer
# (`head -1`) closes the pipe while git is still writing, git dies of SIGPIPE,
# and the pipeline reports failure even though the correct path already reached
# stdout — so a `|| ROOT_REPO_HINT=""` fallback would erase a good answer. That
# mattered twice over, because an empty hint drops MANAGED_LEGACY_HOOKS_DIR
# below and the publishers' legacy-migration argument, silently disabling both
# migrations on exactly the long-lived machines with enough worktrees to trigger
# the race. A single captured command has no pipe to break.
#
# An unresolvable helper or a genuine git failure still yields the empty string,
# which every consumer already treats as "no legacy root known".
ROOT_REPO_HINT=""
_root_repo_helper="$(resolve_helper repo-root.sh)" || _root_repo_helper=""
if [[ -n "$_root_repo_helper" ]]; then
  # No `|| ROOT_REPO_HINT=""` on the assignment. The variable is pre-initialized
  # empty above, so the fallback would buy nothing — and it is exactly the shape
  # that erased a good answer before: a command that printed the correct path but
  # returned non-zero would have its output thrown away. Failures send their
  # diagnostics to stderr, so a failed lookup already yields the empty string.
  ROOT_REPO_HINT="$(bash "$_root_repo_helper" "$SKILLS_WT" 2>/dev/null)"
else
  warn "repo-root.sh not found — legacy-root migrations are disabled for this tick"
fi

# run_publisher <script> — run a publish script BOUNDED, with its two streams
# captured SEPARATELY, because they mean different things: stdout is one line
# per CHANGE (so an unchanged machine produces none), stderr carries standing
# advisories — a user-owned symlink left alone, a legacy link whose target is
# not on main yet. Merging them would turn every advisory into a phantom change
# on every hourly tick. Sets PUBLISH_STDOUT / PUBLISH_STDERR / PUBLISH_TIMED_OUT;
# returns the script's status, or 124 when the bound cut it short.
#
# The separation is now structural rather than hand-rolled: run_bounded writes
# the child's stdout to $CAPTURE and its stderr to $CAPTURE_ERR, which is
# precisely the split the mktemp'd error file existed to produce. That file — and
# the merged-stream fallback that silently lost the distinction whenever mktemp
# failed — go with it.
#
# NEVER call this inside `$( )`, for the same reason as git_sync: a subshell
# discards BOUNDED_TIMED_OUT and the capture handover (bounded-run.sh contract).
PUBLISH_STDOUT=""
PUBLISH_STDERR=""
PUBLISH_TIMED_OUT=0
# Whether the last publisher call was DECLINED (never started) rather than cut
# short by its bound. Tracked as an explicit flag, not inferred from
# PUBLISH_STDERR, because that variable is overwritten with the child's own
# stderr after a bounded run — a publisher whose stderr happened to begin with
# "declined:" would otherwise have a real timeout reported as a decline
# (CodeRabbit, PR #1640). This mirrors _bound_declined in session-start-sync.sh.
PUBLISH_DECLINED=0
# The bound actually applied to the last call — the region-clamped value, which
# is what a failure message must name rather than the per-call ceiling.
PUBLISH_LAST_BOUND="${PUBLISH_BOUND_SECS:-0}"
run_publisher() {
  local script="$1" rc=0 region_left
  PUBLISH_STDOUT=""
  PUBLISH_STDERR=""
  PUBLISH_TIMED_OUT=0
  PUBLISH_DECLINED=0
  if (( GIT_BOUND_AVAILABLE == 0 )); then
    # Refuse rather than run unbounded while holding the lock — the same stance
    # git_sync takes above, against the same lock, for the same reason: without
    # a bound there is no deadline, so a stalled publisher can outlive the
    # ${_stale_age}s staleness window, another sync then treats this LIVE
    # holder's lock as stale and rewrites the same links concurrently, and this
    # run's own commit_json is refused by state_lock_assert_held so the restart
    # marker it owed never lands.
    PUBLISH_TIMED_OUT=1
    PUBLISH_DECLINED=1
    PUBLISH_LAST_BOUND=0
    PUBLISH_STDERR="declined: bounded-run.sh unavailable — refusing to run unbounded while holding the config-sync lock"
    return 124
  fi
  region_left="$(_git_region_remaining "$_publish_region_budget")"
  # Ceiling and floor applied to different things on purpose — see
  # _git_region_remaining. The floor asks "is there room to finish?", a question
  # about the region; the ceiling is how long one call may ever take.
  PUBLISH_LAST_BOUND="$region_left"
  (( PUBLISH_LAST_BOUND > PUBLISH_BOUND_SECS )) && PUBLISH_LAST_BOUND="$PUBLISH_BOUND_SECS"
  if (( region_left < _PUBLISH_MIN_BOUND_SECS )); then
    # Decline rather than start a call that cannot finish inside the region.
    # Starting it is what lets the lock go stale under a live holder, and a
    # recorded failure is strictly better than a silently surrendered mutex.
    PUBLISH_TIMED_OUT=1
    PUBLISH_DECLINED=1
    PUBLISH_STDERR="declined: only ${region_left}s left of the ${_publish_region_budget}s lock-held publish budget"
    return 124
  fi
  run_bounded "$PUBLISH_LAST_BOUND" bash "$script" "$SKILLS_WT" "$ROOT_REPO_HINT" || rc=$?
  PUBLISH_STDOUT="$(cat "$CAPTURE" 2>/dev/null)" || PUBLISH_STDOUT=""
  PUBLISH_STDERR="$(cat "$CAPTURE_ERR" 2>/dev/null)" || PUBLISH_STDERR=""
  [[ "${BOUNDED_TIMED_OUT:-0}" -eq 1 ]] && PUBLISH_TIMED_OUT=1
  return $rc
}

# Phrase a publisher trip honestly, exactly as _git_trip_reason does for the
# git calls: a call that ran out of time "exceeded its Ns bound", one that never
# started was "declined". Both are recorded failures either way.
_publish_trip_reason() {
  if (( ${PUBLISH_DECLINED:-0} == 1 )); then
    printf '%s' "$PUBLISH_STDERR"
  else
    printf 'exceeded its %ss bound' "${PUBLISH_LAST_BOUND:-$PUBLISH_BOUND_SECS}"
  fi
}

one_line() { printf '%s' "$1" | tr '\n' ';'; }

# Snapshot the published agent set BEFORE the publish. The restart signal is
# derived from this rather than from the publisher's prose: matching
# "— creating" in its human-readable output couples this script to wording it
# does not own, and a reworded line would silently stop recommending restarts.
# The filesystem is the fact.
AGENTS_LINK_DIR="$HOME/.claude/agents"
agents_dir_existed=true
[[ -d "$AGENTS_LINK_DIR" ]] || agents_dir_existed=false

# Snapshot each entry as "name -> target", not the bare name. A legacy-migration
# repoint — ~/.claude/agents/foo.md moving from the root repo to the worktree —
# leaves the NAME set identical while changing which file the definition is
# read from, and the two can differ whenever the root repo sits on a feature
# branch. That is precisely a change a live session cannot pick up, so a
# name-only comparison would stay silent on the one case the worktree
# indirection exists to handle. Non-symlink entries readlink to the empty
# string, which compares fine and needs no special case.
snapshot_link_dir() { # snapshot_link_dir <directory>
  local dir="$1" entry name
  [[ -d "$dir" ]] || return 0
  for entry in "$dir"/*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="$(basename "$entry")"
    printf '%s -> %s\n' "$name" "$(readlink "$entry" 2>/dev/null)"
  done | sort
}

# Single-path variant for the two links that are not directories of links.
# A missing path prints the `absent` sentinel rather than nothing, so
# "was missing, now linked" is a visible transition while "missing before and
# after" (the publisher never ran) compares equal and raises no permanent nag.
snapshot_one_link() { # snapshot_one_link <path>
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    printf '%s -> %s\n' "$(basename "$path")" "$(readlink "$path" 2>/dev/null)"
  else
    printf 'absent\n'
  fi
}

snapshot_agent_links() { snapshot_link_dir "$AGENTS_LINK_DIR"; }
agents_before="$(snapshot_agent_links)" || agents_before=""

# The SAME treatment for skills, CLAUDE.md and rules. Deriving those three
# categories only from the Step 5 `git diff` (which needs HEAD to have moved)
# misses the migration this whole feature exists to perform: on a machine where
# the old session-start hook kept the worktree at origin/main but published only
# AGENT symlinks, the first run of this sync creates the missing skill /
# CLAUDE.md / rules links with no SHA change at all. Those are definitions a
# live session cannot pick up, and without a filesystem snapshot no restart
# would ever be recommended for them.
SKILLS_LINK_DIR="$HOME/.claude/skills"
CLAUDE_MD_LINK="$HOME/.claude/CLAUDE.md"
RULES_LINK="$HOME/.claude/rules"
skills_before="$(snapshot_link_dir "$SKILLS_LINK_DIR")"   || skills_before=""
claude_md_before="$(snapshot_one_link "$CLAUDE_MD_LINK")" || claude_md_before=""
rules_before="$(snapshot_one_link "$RULES_LINK")"         || rules_before=""

publish_skills="$(resolve_helper publish-skill-symlinks.sh)" || publish_skills=""
if [[ -n "$publish_skills" ]]; then
  if ! run_publisher "$publish_skills"; then
    if (( PUBLISH_TIMED_OUT == 1 )); then
      record_failure "publish-skill-symlinks.sh $(_publish_trip_reason) — aborted before the ${_stale_age}s lock staleness window could dispossess this run"
    else
      record_failure "publish-skill-symlinks.sh failed: $(one_line "${PUBLISH_STDERR:-$PUBLISH_STDOUT}")"
    fi
  fi
  [[ -n "$PUBLISH_STDOUT" ]] && log info "skills publish: $(one_line "$PUBLISH_STDOUT")"
  [[ -n "$PUBLISH_STDERR" ]] && warn "skills publish advisory: $(one_line "$PUBLISH_STDERR")"
else
  # A hard failure, not a warning. Step 2 states the rule — "links are the whole
  # point of the pass, so a publisher failure is a hard failure" — and a MISSING
  # publisher refreshes exactly as few links as a failing one. Warning here let
  # the run report outcome ok and clear the failure streak while CLAUDE.md,
  # rules and every skill link stayed stale or absent.
  record_failure "publish-skill-symlinks.sh not found — skill/CLAUDE.md/rules links not refreshed"
fi

# Compare immediately after the publish that owns these three legs, so the
# categories reflect what the publisher actually did rather than what the diff
# in Step 5 suggests it might have done. Step 5 still contributes its own
# entries when HEAD moved; the de-duplication below merges the two sources.
skills_after="$(snapshot_link_dir "$SKILLS_LINK_DIR")"   || skills_after=""
claude_md_after="$(snapshot_one_link "$CLAUDE_MD_LINK")" || claude_md_after=""
rules_after="$(snapshot_one_link "$RULES_LINK")"         || rules_after=""
# Spelled as `if` blocks, not `[[ … ]] && …`: a trailing false test would leave
# a non-zero $? for whatever runs next to trip over.
if [[ "$skills_before" != "$skills_after" ]]; then
  RESTART_CATEGORIES+=("skills")
fi
if [[ "$claude_md_before" != "$claude_md_after" ]]; then
  RESTART_CATEGORIES+=("claude-md")
fi
if [[ "$rules_before" != "$rules_after" ]]; then
  RESTART_CATEGORIES+=("rules")
fi

publish_agents="$(resolve_helper publish-agent-symlinks.sh)" || publish_agents=""
agents_out=""
if [[ -n "$publish_agents" ]]; then
  if ! run_publisher "$publish_agents"; then
    if (( PUBLISH_TIMED_OUT == 1 )); then
      record_failure "publish-agent-symlinks.sh $(_publish_trip_reason) — aborted before the ${_stale_age}s lock staleness window could dispossess this run"
    else
      record_failure "publish-agent-symlinks.sh failed: $(one_line "${PUBLISH_STDERR:-$PUBLISH_STDOUT}")"
    fi
  fi
  # Only stdout feeds the restart signal below — an advisory is not a change.
  agents_out="$PUBLISH_STDOUT"
  [[ -n "$PUBLISH_STDOUT" ]] && log info "agents publish: $(one_line "$PUBLISH_STDOUT")"
  [[ -n "$PUBLISH_STDERR" ]] && warn "agents publish advisory: $(one_line "$PUBLISH_STDERR")"
else
  warn "publish-agent-symlinks.sh not found — agent links not refreshed"
fi

# Any change to the published agent set — a new definition linked, one pruned,
# one repointed at a different source file, or the directory created for the
# first time — is a change a live session cannot pick up: Claude Code registers
# agent types at session start.
agents_after="$(snapshot_agent_links)" || agents_after=""
agents_dir_exists=false
[[ -d "$AGENTS_LINK_DIR" ]] && agents_dir_exists=true
# The directory's EXISTENCE only counts as a change when it actually flipped.
# Keying on `agents_dir_existed != true` alone would recommend a restart on
# every single tick of a machine where the publisher is missing and the
# directory is therefore never created — a permanent, unactionable nag.
if [[ "$agents_dir_exists" == true && "$agents_dir_existed" != true ]] \
   || [[ "$agents_before" != "$agents_after" ]]; then
  RESTART_CATEGORIES+=("agents")
fi
# agents_out is kept for the log line above; it deliberately no longer feeds any
# decision.
: "${agents_out:-}"

# ---------------------------------------------------------------------------
# Step 3 — verify the managed links resolve. Warnings only: a dangling link is
# worth reporting but is not a reason to fail the whole pass.
# ---------------------------------------------------------------------------
verify_link() {
  local link="$1"
  [[ -L "$link" ]] || return 0
  [[ -e "$link" ]] && return 0
  warn "dangling symlink: $link -> $(readlink "$link" 2>/dev/null)"
}

verify_link "$HOME/.claude/CLAUDE.md"
verify_link "$HOME/.claude/rules"
for _dir in "$HOME/.claude/skills" "$HOME/.claude/agents"; do
  [[ -d "$_dir" ]] || continue
  for _link in "$_dir"/*; do
    [[ -L "$_link" ]] || continue
    verify_link "$_link"
  done
done

# ---------------------------------------------------------------------------
# Step 4 — the other idempotent setup steps.
# ---------------------------------------------------------------------------
register_hooks="$(resolve_helper register-hooks.py hooks)" || register_hooks=""
if [[ -n "$register_hooks" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    # MANAGED_LEGACY_HOOKS_DIR mirrors setup-skills-worktree.sh Step 6 and the
    # session-start hook: it names the pre-worktree root-repo hooks directory as
    # a second managed root. register-hooks.py repoints or prunes a settings.json
    # entry only when the path it currently names lives inside a managed root —
    # anything else is the user's own hook. Without it this scheduled tick could
    # never finish the legacy migration, so a machine whose only sync is this
    # LaunchAgent would keep stale root-repo hook paths indefinitely.
    hooks_rc=0
    if [[ -n "$ROOT_REPO_HINT" ]]; then
      hooks_out="$(MANAGED_LEGACY_HOOKS_DIR="$ROOT_REPO_HINT/.claude/hooks" \
                   python3 "$register_hooks" "$SKILLS_WT" 2>&1)" || hooks_rc=$?
    else
      hooks_out="$(python3 "$register_hooks" "$SKILLS_WT" 2>&1)" || hooks_rc=$?
    fi
    if (( hooks_rc != 0 )); then
      warn "register-hooks.py reported errors: $(printf '%s' "$hooks_out" | tail -3 | tr '\n' ' ')"
    else
      log info "hooks and statusLine registered"
    fi
  else
    warn "python3 not found — hook registration skipped"
  fi
else
  warn "register-hooks.py not found — hook registration skipped"
fi

trust_repair="$(resolve_helper repair-trust-all.sh)" || trust_repair=""
if [[ -n "$trust_repair" ]]; then
  if ! trust_out="$(bash "$trust_repair" 2>&1)"; then
    warn "repair-trust-all.sh reported errors: $(printf '%s' "$trust_out" | tail -3 | tr '\n' ' ')"
  else
    log info "trust flags repaired"
  fi
else
  warn "repair-trust-all.sh not found — trust-flag repair skipped"
fi

# ---------------------------------------------------------------------------
# Step 5 — change detection across the fast-forward.
#
# The diff-derived categories are collected up at the fast-forward itself (see
# collect_head_change_categories, called there) rather than here, so a later
# record_failure cannot lose them. What remains at this point are the
# publisher-derived categories accumulated above.
# ---------------------------------------------------------------------------

# De-duplicate while preserving order.
DEDUPED=()
for _cat in "${RESTART_CATEGORIES[@]+"${RESTART_CATEGORIES[@]}"}"; do
  _seen=0
  for _known in "${DEDUPED[@]+"${DEDUPED[@]}"}"; do
    [[ "$_known" == "$_cat" ]] && { _seen=1; break; }
  done
  (( _seen == 0 )) && DEDUPED+=("$_cat")
done
RESTART_CATEGORIES=("${DEDUPED[@]+"${DEDUPED[@]}"}")

RESTART_FLAG="false"
(( ${#RESTART_CATEGORIES[@]} > 0 )) && RESTART_FLAG="true"

# ---------------------------------------------------------------------------
# Step 6 — commit success state and the marker.
# ---------------------------------------------------------------------------
state="$(read_state)"
prev_streak="$(printf '%s' "$state" | jq -r '(.consecutive_failures // 0) | tonumber? // 0' 2>/dev/null)" || prev_streak=0
[[ "$prev_streak" =~ ^[0-9]+$ ]] || prev_streak=0

new_state="$(printf '%s' "$state" | jq \
  --arg now "$NOW_ISO" \
  --arg sha "$NEW_SHA" \
  '. + {schema_version: 1, last_run_at: $now, last_success_at: $now,
        consecutive_failures: 0, first_failure_at: null, last_error: null,
        last_head_sha: $sha}' 2>/dev/null)" || new_state=""
if [[ -n "$new_state" ]]; then
  # Same reasoning as the failure path: report the consequence, not just the
  # cause. A success that fails to commit leaves the PREVIOUS failure streak on
  # disk, so a recovered job keeps looking broken and can still trip the
  # repeated-failure badge on a later tick.
  if ! commit_json "$new_state" "$STATE_FILE"; then
    warn "success state not persisted — a stale failure streak may survive in $STATE_FILE and misreport this job as failing"
    append_event "$(jq -cn --arg at "$NOW_ISO" --arg file "$STATE_FILE" \
      '{at: $at, event: "state_commit_failed", file: $file, phase: "success"}')"
  fi
else
  warn "could not build the success state document"
fi

if (( prev_streak > 0 )); then
  append_event "$(jq -cn --arg at "$NOW_ISO" --argjson prev "$prev_streak" \
    '{at: $at, event: "recovered", previous_consecutive_failures: $prev}')"
  log info "recovered after $prev_streak consecutive failure(s)"
fi

marker="$(read_marker)"
categories_json="$(json_array "${RESTART_CATEGORIES[@]+"${RESTART_CATEGORIES[@]}"}")"
new_marker="$(printf '%s' "$marker" | jq \
  --arg now "$NOW_ISO" \
  --arg sha "$NEW_SHA" \
  --argjson categories "$categories_json" \
  --argjson restart "$RESTART_FLAG" \
  '
    # A successful tick always clears the failure portion...
    (. + {sync_failure: null})
    # ...and adds (never removes) the restart portion: a live session still has
    # to restart even though this pass succeeded.
    | (if $restart
       then (. + {restart_recommended: {
              categories: (((.restart_recommended.categories // []) + $categories) | unique),
              head_sha: $sha, at: $now}})
            | .restart_recommended.reason =
                ("config sync updated " + (.restart_recommended.categories | join(", ")))
       else . end)
    | with_entries(select(.value != null))
  ' 2>/dev/null)" || new_marker=""

if [[ -n "$new_marker" ]]; then
  # Not `|| true`. This write carries BOTH directions of the signal: it clears a
  # stale sync_failure badge and adds a newly earned restart_recommended. A
  # silent failure therefore either leaves the user staring at a failure badge
  # for a job that has recovered, or withholds the restart reminder for changes
  # that just landed — while the run reports outcome ok either way.
  if ! write_marker "$new_marker"; then
    warn "marker not persisted — a stale badge may survive, or a newly earned restart signal be lost, in $MARKER_FILE"
    append_event "$(jq -cn --arg at "$NOW_ISO" --arg file "$MARKER_FILE" \
      '{at: $at, event: "marker_commit_failed", file: $file, phase: "success"}')"
  fi
  if [[ "$RESTART_FLAG" == "true" ]]; then
    log info "restart recommended (${RESTART_CATEGORIES[*]}) — signal in $MARKER_FILE"
  fi
else
  warn "could not build the marker document"
fi

log info "config sync finished (outcome ok, ${#WARNINGS[@]} warning(s))"

state_lock_release
emit_summary 0 "$RESTART_FLAG"
exit 0
