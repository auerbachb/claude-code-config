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
    if [[ -f "$candidate" ]]; then
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
BOUNDED_LIB="$SCRIPT_DIR/lib/bounded-run.sh"
GIT_BOUND_AVAILABLE=0
if [[ -f "$BOUNDED_LIB" ]]; then
  # shellcheck source=lib/bounded-run.sh
  source "$BOUNDED_LIB" && GIT_BOUND_AVAILABLE=1
fi

_stale_age="${CLAUDE_STATE_LOCK_STALE_AGE:-120}"
[[ "$_stale_age" =~ ^[1-9][0-9]*$ ]] || _stale_age=120
# Two thirds of the window: enough headroom that the publish, hook registration
# and state commit still finish inside it after a worst-case fetch.
_default_git_bound=$(( _stale_age * 2 / 3 ))
(( _default_git_bound > 0 )) || _default_git_bound=80
if (( GIT_BOUND_AVAILABLE == 1 )); then
  GIT_BOUND_SECS="$(normalize_bound "${CLAUDE_CONFIG_SYNC_GIT_BOUND:-}" "$_default_git_bound")"
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
git_sync() { # git_sync <git subcommand and args…>  (always -C the worktree)
  local rc=0
  GIT_TIMED_OUT=0
  if (( GIT_BOUND_AVAILABLE == 0 )); then
    # Degraded, and said out loud at the call site rather than pretending the
    # bound is in force.
    GIT_OUT="$(git -C "$SKILLS_WT" "$@" 2>/dev/null)" || rc=$?
    GIT_ERR=""
    return "$rc"
  fi
  run_bounded "$GIT_BOUND_SECS" git -C "$SKILLS_WT" "$@" || rc=$?
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
  emit_summary "$consecutive" "false"
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
  if ! bootstrap_out="$(bash "$repo_root/setup-skills-worktree.sh" 2>&1)"; then
    record_failure "setup-skills-worktree.sh failed: $(printf '%s' "$bootstrap_out" | tail -5 | tr '\n' ' ')"
  fi
  BOOTSTRAPPED="true"
  HEAD_CHANGED="true"
  RESTART_CATEGORIES+=("bootstrap")
  NEW_SHA="$(git -C "$SKILLS_WT" rev-parse HEAD 2>/dev/null)" || NEW_SHA=""
  log info "bootstrap complete (HEAD ${NEW_SHA:-unknown})"
else
  OLD_SHA="$(git -C "$SKILLS_WT" rev-parse HEAD 2>/dev/null)" || OLD_SHA=""
  if (( GIT_BOUND_AVAILABLE == 0 )); then
    warn "bounded-run.sh unavailable — the fetch below runs unbounded and could outlive the ${_stale_age}s lock staleness window"
  fi
  # The two calls that can block on the network or a stalled filesystem, and so
  # the two that could carry the locked region past STALE_AGE. A tripped bound
  # is a recorded failure, never a silently surrendered lock.
  if ! git_sync fetch origin main --quiet; then
    if (( GIT_TIMED_OUT == 1 )); then
      record_failure "skills worktree fetch exceeded its ${GIT_BOUND_SECS}s bound — aborted before the ${_stale_age}s lock staleness window could dispossess this run"
    else
      record_failure "skills worktree fetch failed: $(printf '%s' "${GIT_ERR:-$GIT_OUT}" | tr '\n' ' ')"
    fi
  fi
  if ! git_sync reset --hard origin/main --quiet; then
    if (( GIT_TIMED_OUT == 1 )); then
      record_failure "skills worktree reset exceeded its ${GIT_BOUND_SECS}s bound — aborted before the ${_stale_age}s lock staleness window could dispossess this run"
    else
      record_failure "skills worktree reset failed: $(printf '%s' "${GIT_ERR:-$GIT_OUT}" | tr '\n' ' ')"
    fi
  fi
  NEW_SHA="$(git -C "$SKILLS_WT" rev-parse HEAD 2>/dev/null)" || NEW_SHA=""
  if [[ -n "$OLD_SHA" && -n "$NEW_SHA" && "$OLD_SHA" != "$NEW_SHA" ]]; then
    HEAD_CHANGED="true"
    log info "worktree fast-forwarded ${OLD_SHA:0:8} -> ${NEW_SHA:0:8}"
  else
    log info "worktree already at ${NEW_SHA:0:8}"
  fi
fi

# ---------------------------------------------------------------------------
# Step 2 — publish symlinks. Links are the whole point of the pass, so a
# publisher failure is a hard failure.
# ---------------------------------------------------------------------------
# The awk deliberately does NOT `exit` after the first match, and there is no
# `|| ROOT_REPO_HINT=""` fallback. This file runs under `set -o pipefail`: an
# early-exiting consumer closes the pipe while `git worktree list` is still
# writing, git dies of SIGPIPE, and the PIPELINE reports failure even though the
# correct path already reached stdout — so the fallback would erase a perfectly
# good answer. It is load-bearing twice over: an empty hint drops
# MANAGED_LEGACY_HOOKS_DIR below and the publishers' legacy-migration argument,
# silently disabling both migrations on exactly the long-lived machines that
# have enough worktrees to trigger the race. Consuming the whole stream costs
# nothing here and removes the failure mode outright. A genuine git failure
# still yields an empty string, which every consumer already treats as "no
# legacy root known".
ROOT_REPO_HINT="$(git -C "$SKILLS_WT" worktree list --porcelain 2>/dev/null \
  | awk '/^worktree /{if (!seen++) {sub(/^worktree /, ""); print}}')"

# run_publisher <script> — run a publish script with its two streams captured
# SEPARATELY, because they mean different things: stdout is one line per CHANGE
# (so an unchanged machine produces none), stderr carries standing advisories —
# a user-owned symlink left alone, a legacy link whose target is not on main
# yet. Merging them would turn every advisory into a phantom change on every
# hourly tick. Sets PUBLISH_STDOUT / PUBLISH_STDERR; returns the script's status.
PUBLISH_STDOUT=""
PUBLISH_STDERR=""
run_publisher() {
  local script="$1" err_file rc=0
  PUBLISH_STDOUT=""
  PUBLISH_STDERR=""
  err_file="$(mktemp "${LOG_DIR}/.publish-err.XXXXXX" 2>/dev/null)" || err_file=""
  if [[ -n "$err_file" ]]; then
    PUBLISH_STDOUT="$(bash "$script" "$SKILLS_WT" "$ROOT_REPO_HINT" 2>"$err_file")" || rc=$?
    PUBLISH_STDERR="$(cat "$err_file" 2>/dev/null)"
    rm -f "$err_file" 2>/dev/null || true
  else
    # No temp file available: a merged capture loses the distinction but keeps
    # the diagnostics, which beats discarding stderr outright.
    PUBLISH_STDOUT="$(bash "$script" "$SKILLS_WT" "$ROOT_REPO_HINT" 2>&1)" || rc=$?
    PUBLISH_STDERR=""
  fi
  return $rc
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
    record_failure "publish-skill-symlinks.sh failed: $(one_line "${PUBLISH_STDERR:-$PUBLISH_STDOUT}")"
  fi
  [[ -n "$PUBLISH_STDOUT" ]] && log info "skills publish: $(one_line "$PUBLISH_STDOUT")"
  [[ -n "$PUBLISH_STDERR" ]] && warn "skills publish advisory: $(one_line "$PUBLISH_STDERR")"
else
  warn "publish-skill-symlinks.sh not found — skill/CLAUDE.md/rules links not refreshed"
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
    record_failure "publish-agent-symlinks.sh failed: $(one_line "${PUBLISH_STDERR:-$PUBLISH_STDOUT}")"
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
# ---------------------------------------------------------------------------
if [[ "$HEAD_CHANGED" == "true" && -n "$OLD_SHA" && -n "$NEW_SHA" ]]; then
  changed_paths="$(git -C "$SKILLS_WT" diff --name-only "$OLD_SHA" "$NEW_SHA" 2>/dev/null)" || changed_paths=""
  if [[ -z "$changed_paths" ]]; then
    warn "could not diff $OLD_SHA..$NEW_SHA — restart categories may be incomplete"
  else
    # Here-strings, never `printf … | grep -q` — see the SIGPIPE note above.
    grep -q '^\.claude/agents/' <<< "$changed_paths" && RESTART_CATEGORIES+=("agents")
    grep -q '^\.claude/rules/'  <<< "$changed_paths" && RESTART_CATEGORIES+=("rules")
    grep -q '^\.claude/skills/' <<< "$changed_paths" && RESTART_CATEGORIES+=("skills")
    grep -q '^CLAUDE\.md$'      <<< "$changed_paths" && RESTART_CATEGORIES+=("claude-md")
  fi
fi

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
       then . + {restart_recommended: {
              reason: ("config sync updated " + ($categories | join(", "))),
              categories: $categories, head_sha: $sha, at: $now}}
       else . end)
    | with_entries(select(.value != null))
  ' 2>/dev/null)" || new_marker=""

if [[ -n "$new_marker" ]]; then
  write_marker "$new_marker" || true
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
