#!/bin/bash
# Session-start sync — SessionStart hook (fires at session start and on resume)
# Syncs the skills worktree and root repo to ensure skills, rules, and
# CLAUDE.md are up to date with origin/main. Runs on every session start
# (fresh session, resume, clear, compact, fork).

# Consume stdin (required by hook protocol) and keep it: SessionStart carries
# a `source` telling us WHY it fired — startup | resume | clear | compact.
# Only `startup` is a genuinely new session; the rest fire inside a live one.
hook_stdin=$(cat)
session_source=$(jq -r '.source // empty' <<<"$hook_stdin" 2>/dev/null)

# Whether the config-sync lock had to be WAITED for. Set at the acquire below
# and read by the restart-marker clear near the end: waiting is unambiguous
# evidence that another sync was in flight during this startup, and so that
# changes may have landed after this session loaded its definitions.
_lock_contended=0

# --- Sync skills worktree ---
skills_wt="$HOME/.claude/skills-worktree"
_hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
_scripts_dir="$(cd "$_hook_dir/../scripts" 2>/dev/null && pwd)"
# Assigned HERE, above the lock branch, on purpose: the root-repo sync near the
# bottom runs on the lock-skip path too (a contended login is exactly the
# overlap this hook tolerates), and an assignment left inside the locked region
# leaves this unset there — a false "root repo could not be resolved" error and
# a skipped main pull on every login overlap.
_repo_root_helper="${_scripts_dir}/repo-root.sh"
setup_script="$(cd "$_hook_dir/../.." 2>/dev/null && pwd)/setup-skills-worktree.sh"
errors=""
_agents_notices=""
_marker_notice=""   # config-sync marker text (restart recommended / sync failing)
_skip_notice=""     # why the config-sync region was skipped this session, if it was

# --- Config-sync mutex (issue #1524) ---
# The scheduled claude-config-sync.sh LaunchAgent performs the SAME worktree
# fast-forward, symlink publish and hook registration this hook does, on its own
# hourly schedule. Both take the one lock below so an overlap serializes instead
# of racing a `git reset --hard` against a symlink publish reading the same tree.
#
# The lock base path is claude-config-sync.sh's canonical state file; that script
# owns the definition and .claude/scripts/tests/claude-config-sync.test.sh holds
# the two spellings to each other.
_sync_lock_base="$HOME/.claude/logs/claude-config-sync-state.json"
_lock_lib="${_scripts_dir}/state-lock.sh"
# --- Bounded-run setup (MUST precede state_lock_acquire) ---
# Ordering is load-bearing, not stylistic. state_lock_acquire installs an EXIT
# trap that runs state_lock_release, and it CHAINS onto whatever EXIT trap the
# caller already has. Installing the capture-cleanup trap after the acquire
# would REPLACE that chained trap with temp-file cleanup alone, so an abort or
# a hook timeout while the lock is held would leave
# claude-config-sync-state.json.lock behind for the full staleness window.
# claude-config-sync.sh sets its trap before its own acquire for this reason;
# the hook now matches it. The capture files are created here even though they
# are only used inside the lock-held branch below — that is the price of
# getting the trap in before the acquire, and two empty temp files are cheap.
_bounded_lib="${_scripts_dir}/lib/bounded-run.sh"
_bound_available=0
if [[ -n "$_scripts_dir" && -f "$_bounded_lib" ]]; then
  # shellcheck source=../scripts/lib/bounded-run.sh
  source "$_bounded_lib" && _bound_available=1
fi
# Hook budget — a DEADLINE, not a set of independent per-call bounds.
#
# This hook is registered with `timeout: 30` in global-settings.json. Per-call
# bounds alone cannot honour that, because the number of bounded calls varies
# by path: a steady-state pass runs fetch then reset, while a first-time
# bootstrap runs setup-skills-worktree.sh AND THEN fetch and reset, since a
# successful setup satisfies the worktree test below. Any fixed arithmetic is
# therefore wrong for one path or the other — the original 10s wait plus two
# 20s bounds came to 50s, and simply shrinking the bound to fit two calls still
# left three calls overrunning, while starving the bootstrap that legitimately
# needs longer than a fetch.
#
# Being killed here is the outcome that must not happen: a hook killed part-way
# through `reset --hard` leaves a half-updated worktree, and the publish guard
# below only blocks publishing a partial tree when the failure was RECORDED —
# which a kill never is. So the whole git region is scheduled against one
# deadline: each call gets whatever is left of the budget, capped at what that
# particular call should ever need, and a call with too little left is DECLINED
# rather than started and killed. Declining is recorded, so the guard holds.
#
# The lock wait counts against the same budget, which is what makes a login
# overlap safe: time burnt waiting shortens the calls instead of overrunning.
_HOOK_TIMEOUT_SECS=30
# Reserved for everything after the git region: the publishers, hook
# registration, trust repair, the marker work and the root-repo sync.
_HOOK_GIT_RESERVE_SECS=9
_HOOK_MIN_BOUND_SECS=3
_hook_t0="$(date -u +%s 2>/dev/null)" || _hook_t0=""
_last_bound=0
_bound_declined=0
# Per-call ceilings. Setup gets a larger one because it does strictly more:
# clone or fetch over the network, `worktree add`, both publishes and hook
# registration. Bounding it like a single fetch reported healthy first-time
# bootstraps as "setup failed" and skipped publishing — on exactly the machines
# with no LaunchAgent, for which this hook is the only setup path.
_setup_bound_secs=18
_sync_bound_secs=8
if (( _bound_available == 1 )); then
  _sync_bound_secs="$(normalize_bound "${CLAUDE_CONFIG_SYNC_HOOK_GIT_BOUND:-}" 8)"
  _setup_bound_secs="$(normalize_bound "${CLAUDE_CONFIG_SYNC_HOOK_SETUP_BOUND:-}" 18)"
  CAPTURE="$(mktemp "${TMPDIR:-/tmp}/session-start-sync-out.XXXXXX")"     || CAPTURE=""
  CAPTURE_ERR="$(mktemp "${TMPDIR:-/tmp}/session-start-sync-err.XXXXXX")" || CAPTURE_ERR=""
  [[ -n "$CAPTURE" && -n "$CAPTURE_ERR" ]] || _bound_available=0
  trap 'rm -f "${CAPTURE:-}" "${CAPTURE_ERR:-}" 2>/dev/null || true' EXIT
fi

_lock_held=0
_lock_available=0
if [[ -n "$_scripts_dir" && -f "$_lock_lib" ]]; then
  _lock_available=1
  mkdir -p "$(dirname "$_sync_lock_base")" 2>/dev/null || true
  # shellcheck source=../scripts/state-lock.sh
  source "$_lock_lib"
  # Short bound: this hook is registered with timeout 30, and a real critical
  # section is milliseconds. A scheduled sync that genuinely holds the lock for
  # longer has already done this hook's work.
  # Contention is detected three ways, OR-ed, because none alone is sound.
  #
  #   1. Structural: does the lock directory already exist as we walk up to it?
  #      state-lock.sh's lock for a given base is "${base}.lock" (documented in
  #      its header). Present => somebody else holds it right now.
  #   2. Probe: a zero-timeout state_lock_acquire. Its loop attempts mkdir
  #      BEFORE its first deadline check, so a 0 bound is a single non-blocking
  #      attempt — success proves no wait happened at all; failure proves a
  #      live holder in that instant. A stale lock does not false-positive:
  #      the loop breaks it and wins mkdir on the next iteration, still ahead
  #      of the deadline check.
  #   3. Timing: whole-second stamps either side of the acquire.
  #
  # The timing check ALONE is not enough: `date +%s` has one-second resolution,
  # so a real wait shorter than a second reads as a delta of 0 and would be
  # misreported as uncontended — which would clear the restart marker for
  # definitions this session never loaded (the failure that matters, since it
  # silently withholds the restart reminder). The structural check narrows that
  # window but cannot close it: a holder appearing after the test and releasing
  # within the same whole second slips both. The probe closes exactly that gap
  # — any wait at all implies a failed first attempt.
  #
  # All three are biased toward reporting CONTENDED, whose only cost is a
  # duplicate reminder. An unusable clock reads as CONTENDED for the same
  # reason.
  _lock_contended_pre=0
  [[ -d "${_sync_lock_base}.lock" ]] && _lock_contended_pre=1
  _lock_t0="$(date -u +%s 2>/dev/null)" || _lock_t0=""
  # 5, not 10. This wait is spent inside the same budget as the git calls below
  # (see the deadline block above), so a long wait does not overrun the hook —
  # it shortens those calls. Capping it anyway keeps a contended login from
  # spending the whole budget queueing for work the other holder is already
  # doing. The 0-timeout probe costs nothing when uncontended and never waits.
  _lock_probe_waited=0
  if state_lock_acquire "$_sync_lock_base" 0 2>/dev/null; then
    _lock_held=1
  else
    _lock_probe_waited=1
    if state_lock_acquire "$_sync_lock_base" "${CLAUDE_CONFIG_SYNC_HOOK_LOCK_TIMEOUT:-5}" 2>/dev/null; then
      _lock_held=1
    fi
  fi
  _lock_t1="$(date -u +%s 2>/dev/null)" || _lock_t1=""
  if (( _lock_contended_pre == 1 || _lock_probe_waited == 1 )); then
    _lock_contended=1
  elif [[ "$_lock_t0" =~ ^[0-9]+$ && "$_lock_t1" =~ ^[0-9]+$ ]]; then
    (( _lock_t1 > _lock_t0 )) && _lock_contended=1
  else
    _lock_contended=1
  fi
fi

if [[ "$_lock_held" != 1 ]]; then
  # Skip cleanly rather than proceed unserialized. Either the scheduled sync is
  # mid-run (it is doing exactly this work) or state-lock.sh is missing from the
  # checkout — in both cases an unlocked fast-forward is the wrong answer.
  if [[ "$_lock_available" == 1 ]]; then
    _skip_notice="CONFIG SYNC: the scheduled config sync holds the lock — skipped the worktree/symlink refresh this session start; it is already running."
  else
    _skip_notice="CONFIG SYNC: state-lock.sh not found at ${_lock_lib:-<unresolved>} — skipped the worktree/symlink refresh rather than running it unserialized."
  fi
else

# --- Bound the lock-held setup/fetch/reset ---
# Everything below runs while HOLDING the config-sync lock, and state-lock.sh
# breaks a holder by age alone once it passes STALE_AGE (default 120s) — at
# which point a second sync starts mutating the same worktree and the same
# ~/.claude links this run is rewriting. claude-config-sync.sh bounds exactly
# these calls for that reason; the hook has to as well rather than leaning on
# the hook's registered timeout, which is configured outside this file and so
# is invisible (and unenforced) here.
#
# The bound is deliberately tighter than the scheduled job's: this hook is
# registered with timeout 30, so any bound above that could never be reached.
# A tripped bound is a recorded error, never a silently surrendered lock.
#
# The lib is sourced and its capture files + EXIT trap are installed ABOVE, on
# purpose, BEFORE state_lock_acquire — see the note there.
#
# Run one lock-held command under the bound, mirroring claude-config-sync.sh's
# git_sync. Called at statement level ONLY, never inside `$( )`: a subshell
# discards BOUNDED_TIMED_OUT and the capture handover (bounded-run.sh contract).
_bounded_out=""
# Seconds left of the hook's git budget — deliberately NOT clamped to any
# per-call ceiling. The caller applies the floor to this figure and the ceiling
# separately: conflating them would make an explicitly configured ceiling below
# the floor decline every call rather than honouring it. The floor asks "is
# there room to finish?", a question about the budget, not about how short the
# operator chose to make one call.
#
# Falls back to the full budget when the clock is unusable — an unreadable clock
# must not silently collapse every bound to zero and disable the sync outright.
_budget_remaining() {
  local now elapsed remaining budget
  budget=$(( _HOOK_TIMEOUT_SECS - _HOOK_GIT_RESERVE_SECS ))
  (( budget > 0 )) || budget=1
  [[ -n "$_hook_t0" ]] || { printf '%s' "$budget"; return 0; }
  now="$(date -u +%s 2>/dev/null)" || { printf '%s' "$budget"; return 0; }
  [[ "$now" =~ ^[0-9]+$ ]] || { printf '%s' "$budget"; return 0; }
  elapsed=$(( now - _hook_t0 ))
  remaining=$(( budget - elapsed ))
  (( remaining < 0 )) && remaining=0
  printf '%s' "$remaining"
}

# Phrase a bound trip honestly: a call that ran out of time "exceeded" its
# bound, one that never started was "declined". Both must still carry the
# caller's "…failed" token, which is what the publish guard keys off.
_bound_trip_reason() {
  if (( _bound_declined == 1 )); then
    printf 'declined: %s' "$_bounded_out"
  else
    printf 'exceeded its %ss bound' "$_last_bound"
  fi
}

_run_locked() { # _run_locked <cap-seconds> <command…>
  local cap="$1"; shift
  local rc=0
  BOUNDED_TIMED_OUT=0
  _bound_declined=0
  if (( _bound_available == 0 )); then
    # Refuse rather than run unbounded while holding the lock. Without a bound
    # there is no deadline, so this call can outlive both the 30s hook timeout
    # and the lock staleness window — at which point another sync treats the
    # lock as stale and starts mutating the same worktree concurrently, which is
    # the race the lock exists to prevent. Declining costs one opportunistic
    # session refresh; the scheduled LaunchAgent, which has no 30s ceiling, still
    # does the work.
    _last_bound=0
    BOUNDED_TIMED_OUT=1
    _bound_declined=1
    _bounded_out="bounded-run.sh unavailable — refusing to run unbounded while holding the config-sync lock"
    return 124
  fi
  local budget_left
  budget_left="$(_budget_remaining)"
  # Ceiling and floor applied to different things on purpose — see
  # _budget_remaining.
  _last_bound="$budget_left"
  (( _last_bound > cap )) && _last_bound="$cap"
  if (( budget_left < _HOOK_MIN_BOUND_SECS )); then
    # Declining to start IS the fix. Starting a call that the hook timeout will
    # kill part-way leaves a half-updated worktree and records nothing, which is
    # precisely what the publish guard below cannot defend against.
    #
    # BOUNDED_TIMED_OUT is set because every caller keys its "…failed" token off
    # it, and that token is what the publish guard reads — but _bound_declined
    # distinguishes the two for the message, since "exceeded its Ns bound" would
    # be untrue of a call that never started.
    BOUNDED_TIMED_OUT=1
    _bound_declined=1
    _bounded_out="only ${budget_left}s left of the ${_HOOK_TIMEOUT_SECS}s hook budget"
    return 124
  fi
  run_bounded "$_last_bound" "$@" || rc=$?
  _bounded_out="$(cat "$CAPTURE_ERR" 2>/dev/null)" || _bounded_out=""
  [[ -n "$_bounded_out" ]] || _bounded_out="$(cat "$CAPTURE" 2>/dev/null)" || _bounded_out=""
  return "$rc"
}

# Bootstrap missing skills worktree if setup script is available.
# NOTE on the message wording below: the publish guard further down keys off the
# substrings "setup failed" and "reset failed", so a timed-out call must still
# carry its token or a bound trip would silently re-open the very partial-tree
# publish that guard exists to block.
_bootstrapped=0
# Set when a publisher could not be run at all, so its links were never
# refreshed. Kept separate from `errors` because it answers a different
# question: `errors` drives what the session is TOLD, this drives whether the
# restart marker may be CLEARED. A publisher that never ran leaves stale links
# in a category the marker describes, whether or not the miss was loud.
_publish_incomplete=0
if [[ ! -d "$skills_wt/.claude/skills" || ! -f "$skills_wt/.git" ]]; then
  if [[ -x "$setup_script" || -f "$setup_script" ]]; then
    if ! _run_locked "$_setup_bound_secs" bash "$setup_script"; then
      if [[ "${BOUNDED_TIMED_OUT:-0}" -eq 1 ]]; then
        errors="skills worktree setup failed: $(_bound_trip_reason) — aborted before the lock staleness window could dispossess this run"
      else
        errors="skills worktree setup failed: $_bounded_out"
      fi
    else
      _bootstrapped=1
    fi
  fi
fi

# `_bootstrapped` makes the two paths mutually exclusive, matching the if/else
# claude-config-sync.sh uses for the same choice.
#
# A successful setup-skills-worktree.sh has ALREADY put the worktree at
# origin/main and published the links, so the fetch and reset below would be
# redundant work — but they draw on the SAME hook budget the setup just spent
# most of. A slow-but-successful setup therefore left too little for the reset,
# which was declined and recorded as "reset failed"; the publish guard then read
# that as a partial-tree hazard and the session got a stale-config warning for a
# tree that was freshly and correctly built. Not running them is both cheaper
# and truer.
# HEAD either side of the fast-forward. Local rev-parse, instant and unbounded
# on purpose — it reads one ref, and a failure just leaves the resume-path
# restart write below with nothing to compare (safe: no signal is written on
# unknown SHAs, and the scheduled job's own diff still covers its runs).
_old_head=""
_new_head=""
if (( _bootstrapped == 0 )) && [[ -z "$errors" && -d "$skills_wt" && -f "$skills_wt/.git" ]]; then
  _old_head="$(git -C "$skills_wt" rev-parse HEAD 2>/dev/null)" || _old_head=""
  if ! _run_locked "$_sync_bound_secs" git -C "$skills_wt" fetch origin main --quiet; then
    if [[ "${BOUNDED_TIMED_OUT:-0}" -eq 1 ]]; then
      errors="skills worktree fetch failed: $(_bound_trip_reason) — aborted before the lock staleness window could dispossess this run"
    else
      errors="skills worktree fetch failed: $_bounded_out"
    fi
  elif ! _run_locked "$_sync_bound_secs" git -C "$skills_wt" reset --hard origin/main --quiet; then
    if [[ "${BOUNDED_TIMED_OUT:-0}" -eq 1 ]]; then
      errors="skills worktree reset failed: $(_bound_trip_reason) — aborted before the lock staleness window could dispossess this run"
    else
      errors="skills worktree reset failed: $_bounded_out"
    fi
  fi
elif (( _bootstrapped == 0 )) && [[ -z "$errors" ]]; then
  # `_bootstrapped == 0` repeated on purpose. Without it a SUCCESSFUL bootstrap
  # — which skips the branch above by design — would fall through to this else
  # and report the worktree it just created as "not found", turning the fix
  # above into a worse bug than the one it replaced.
  errors="skills worktree not found at $skills_wt"
fi
if [[ -z "$errors" && -d "$skills_wt" && -f "$skills_wt/.git" ]]; then
  _new_head="$(git -C "$skills_wt" rev-parse HEAD 2>/dev/null)" || _new_head=""
fi

# The root repo backing the skills worktree. Hoisted above the publish block
# because the hook-registration block further down needs it too — see the
# MANAGED_LEGACY_HOOKS_DIR note there. Empty when the worktree is absent or the
# lookup fails; every consumer treats empty as "no legacy root known".
#
# Resolved through repo-root.sh, which centralizes this "first `worktree `
# stanza" lookup and — the reason it matters here — bounds its own git calls via
# lib/bounded-run.sh. The raw listing this replaced ran UNBOUNDED inside the
# locked region, beside calls this hook already declines rather than run
# unbounded; bounding those while leaving this one uncapped defends nothing.
# Dropping the `| head -1 | sed` pipeline also removes the SIGPIPE hazard that
# shape carries under pipefail, where an early-exiting consumer makes a
# SUCCESSFUL lookup report failure.
#
# No `|| _root_repo=""` on the assignment: it is pre-initialized empty, so the
# fallback would buy nothing while being the very shape that discards a correct
# path printed by a command that happened to return non-zero.
_root_repo=""
# _repo_root_helper is assigned at the top of the file, above the lock branch —
# the root-repo sync below the region needs it on the lock-skip path too.
if [[ -f "$_repo_root_helper" ]]; then
  # Bounded to fit this hook's own arithmetic: repo-root.sh defaults to 10s
  # PER git call and may run two, which alone exceeds the 9s post-region
  # reserve — a slow-but-successful reset could then have the hook killed
  # before publish with no recorded failure token, the exact unrecorded-kill
  # the deadline scheduling above exists to prevent. 3s x 2 calls fits the
  # reserve with room for the file-level work that follows, and the lookup is
  # a local `git worktree list`, for which 3s is generous.
  _root_repo="$(REPO_ROOT_TIMEOUT_SECS=3 bash "$_repo_root_helper" "$skills_wt" 2>/dev/null)"
fi

# --- Publish skill and agent symlinks on the steady-state path ---
# git reset --hard above updates worktree contents (including .claude/skills/
# and .claude/agents/) but never creates the per-entry symlinks under
# ~/.claude/. Run both publishes every session so new, renamed, and removed
# definitions propagate without a manual setup-skills-worktree.sh run on
# existing installs (agents: issue #1197; skills/CLAUDE.md/rules: issue #1524).
# Run whenever the worktree is present AND neither the reset nor the bootstrap
# failed:
#   - Fetch failure leaves the worktree in its last-good state — safe to publish.
#   - Reset failure may leave the worktree in a partially-updated state; the
#     publish scripts interpret absent worktree files as authoritative removals,
#     so publishing from a partial reset could prune valid installed links.
#   - Setup (bootstrap) failure is the same hazard arriving by a different name.
#     setup-skills-worktree.sh can fail PART WAY: `git worktree add` succeeds,
#     so `$skills_wt/.git` exists and the -d/-f test above passes, but the
#     checkout never completed — an all-but-empty worktree that the publishers
#     would read as "every definition was deleted upstream" and prune. Matching
#     only "reset failed" let that case through, because the recorded string is
#     "skills worktree setup failed: …".
if [[ -d "$skills_wt" && -f "$skills_wt/.git" ]] && \
   ! [[ "$errors" == *"reset failed"* || "$errors" == *"setup failed"* ]]; then
  # Both publishers separate their streams on purpose: stdout is one line per
  # CHANGE, stderr carries standing advisories (a user-owned symlink left alone,
  # a legacy link not yet on main). Capture them apart so an advisory is never
  # mistaken for a change; both still reach the session, labelled.
  _publish_err_file=$(mktemp "${TMPDIR:-/tmp}/session-start-publish.XXXXXX" 2>/dev/null) || _publish_err_file=""

  # Categories whose links a publisher actually CHANGED this run, for the
  # resume-path restart write below. Detection is a WHITELIST of the
  # publishers' change verbs, not "any stdout": the agents publisher prints
  # its standing user-owned-symlink advisory (and a restart note) on stdout,
  # so a personal agent link would otherwise raise a phantom restart on every
  # resume. Counted only in the separated-stderr case; the mixed-stream
  # fallback counts nothing — an advisory must never become a phantom signal.
  _links_changed_cats=""
  _publish_change_verbs='— (creating|updating symlink|symlinked|migrating|replacing directory copy|removing stale)'
  _publish_one() { # _publish_one <script> <label>
    local script="$1" label="$2" out="" err="" rc=0
    if [[ -n "$_publish_err_file" ]]; then
      out=$(bash "$script" "$skills_wt" "${_root_repo}" 2>"$_publish_err_file") || rc=$?
      err=$(cat "$_publish_err_file" 2>/dev/null)
    else
      out=$(bash "$script" "$skills_wt" "${_root_repo}" 2>&1) || rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
      errors="${errors:+$errors; }${label} symlink publish failed: ${err:-$out}"
      return 0
    fi
    if [[ -n "$_publish_err_file" && -n "$out" ]] \
        && grep -Eq "$_publish_change_verbs" <<< "$out"; then
      case "$label" in
        skill) _links_changed_cats="${_links_changed_cats:+$_links_changed_cats }skills" ;;
        agent) _links_changed_cats="${_links_changed_cats:+$_links_changed_cats }agents" ;;
      esac
    fi
    [[ -n "$out" ]] && _agents_notices="${_agents_notices:+$_agents_notices
}$out"
    [[ -n "$err" ]] && _agents_notices="${_agents_notices:+$_agents_notices
}$err"
    return 0
  }

  _skills_publish_script="${_scripts_dir}/publish-skill-symlinks.sh"
  if [[ -f "$_skills_publish_script" ]]; then
    _publish_one "$_skills_publish_script" "skill"
  else
    # A MISSING publisher refreshes exactly as few links as a failing one, so it
    # is recorded the same way — the rule claude-config-sync.sh states at its own
    # missing-publisher branch. Skipping silently was worse here than there: it
    # left `errors` empty, so the marker clear below saw a clean run and deleted
    # the restart signal while every skill, CLAUDE.md and rules link stayed
    # stale. The wording keeps the "publish failed" shape the other publish
    # failures use.
    errors="${errors:+$errors; }skill symlink publish failed: $_skills_publish_script not found — skill/CLAUDE.md/rules links not refreshed"
    _publish_incomplete=1
  fi

  _agents_publish_script="${_scripts_dir}/publish-agent-symlinks.sh"
  if [[ -f "$_agents_publish_script" ]]; then
    _publish_one "$_agents_publish_script" "agent"
  else
    # Severity stays a NOTICE, matching claude-config-sync.sh, which
    # record_failure's a missing skills publisher but only warns for agents.
    #
    # Severity and clear-safety are different questions, though, and conflating
    # them is what made this a bug rather than a style choice. The marker's
    # restart_recommended covers the AGENTS category too, so a startup that never
    # refreshed the agent links must not delete a signal describing them, however
    # quietly it reports the miss. In the sync a warn is harmless because the
    # sync WRITES the marker; here an empty `errors` is exactly what lets the
    # clear fire, so the clear gets its own flag instead.
    _agents_notices="${_agents_notices:+$_agents_notices
}publish-agent-symlinks.sh not found — agent links not refreshed"
    _publish_incomplete=1
  fi

  [[ -n "$_publish_err_file" ]] && rm -f "$_publish_err_file" 2>/dev/null
fi

# --- Sync hooks from global-settings.json into ~/.claude/settings.json ---
# Ensures new hooks added to the template are auto-registered each session.
# Uses the same registration logic as setup-skills-worktree.sh Step 6.
# Matches by script basename to detect existing hooks; preserves user hooks
# and custom timeouts. No-op if the skills worktree is unavailable.
#
# Inside the config-sync lock: claude-config-sync.sh runs the same registration
# on its schedule, and two concurrent writers of ~/.claude/settings.json is
# exactly the interleaving the lock exists to prevent.
#
# Gated on the same setup/reset failures as the publish block above, and for the
# same reason: register-hooks.py prunes a settings.json entry whose target is
# missing from a managed root, so running it against a half-built worktree would
# read "not checked out yet" as "decommissioned" and strip a live hook
# registration. A failed fetch is still fine here — it leaves the worktree at
# its last-good checkout.
if [[ -d "$skills_wt" && -f "$skills_wt/.git" ]] && \
   ! [[ "$errors" == *"reset failed"* || "$errors" == *"setup failed"* ]]; then
  register_script="${_hook_dir}/register-hooks.py"
  if [[ -f "$register_script" ]]; then
    # MANAGED_LEGACY_HOOKS_DIR names the pre-worktree root-repo hooks directory
    # as a SECOND managed root, exactly as setup-skills-worktree.sh Step 6 does.
    # register-hooks.py only migrates a settings.json entry to the canonical
    # worktree path, or prunes a decommissioned one, when the path it currently
    # points at sits inside a managed root; everything else is treated as the
    # user's own hook and left untouched. Omitting the variable here therefore
    # made this session-start path — and the scheduled sync in
    # claude-config-sync.sh — permanently unable to finish the migration that
    # install-time performs, which is the opposite of this hook's purpose
    # (keeping existing installs current without a manual setup re-run).
    # Unset when the root repo could not be resolved: an empty value is dropped
    # by register-hooks.py, but not exporting it at all is the honest spelling.
    if [[ -n "$_root_repo" ]]; then
      err=$(MANAGED_LEGACY_HOOKS_DIR="$_root_repo/.claude/hooks" \
              python3 "$register_script" "$skills_wt" 2>&1) || \
        errors="${errors:+$errors; }hook sync failed: $err"
    else
      err=$(python3 "$register_script" "$skills_wt" 2>&1) || \
        errors="${errors:+$errors; }hook sync failed: $err"
    fi
  else
    errors="${errors:+$errors; }hook sync helper missing: $register_script"
  fi
fi

fi  # end of config-sync locked region

# Defined here rather than at its first use below: the snapshot immediately
# after it has to read the file while this lock is still held.
_marker_file="$HOME/.claude/sync-restart-recommended.json"

# Snapshot the marker BEFORE releasing, i.e. as the last act of the locked
# region, so the clear far below can ask "did a sync land after this session
# finished its own region?" and get a true answer.
#
# The comparison the clear already makes — surfaced vs. current — only catches a
# sync that lands between the READ and the clear. A sync that lands between this
# RELEASE and that read is invisible to it: the new marker is what gets surfaced,
# so surfaced and current agree, and the clear deletes a signal describing
# definitions this session loaded no part of. Anchoring at region exit closes
# that window, because any sync that published after this point — before or
# after the read — moves the marker away from this snapshot.
#
# Safe when the lock was never held: the clear is already gated on an empty
# _skip_notice, and a lock this hook did not hold always sets one.
# --- Resume-path restart signal (BugBot High, PR #1553) ---
# On a NON-startup source (resume/compact/clear), this session keeps the
# definitions it loaded at its original start: the fast-forward + publish above
# just made the on-disk links newer than what is running, and nothing else will
# ever say so — the scheduled job only signals changes ITS OWN run made, and a
# later tick sees an unchanged HEAD and stays silent. Write the restart signal
# here, while still holding the lock, so the reminder survives to the next
# startup. Categories mirror claude-config-sync.sh's
# collect_head_change_categories; existing categories are unioned in, never
# replaced (a live session may owe restarts to more than one sync).
if [[ "$session_source" != "startup" && "$_lock_held" == 1 && -z "$errors" ]]; then
  _resume_cats=""
  # Leg 1: the fast-forward moved HEAD — categories from the content diff.
  if [[ -n "$_old_head" && -n "$_new_head" && "$_old_head" != "$_new_head" ]]; then
    _resume_changed="$(git -C "$skills_wt" diff --name-only "$_old_head" "$_new_head" 2>/dev/null)" || _resume_changed=""
    grep -q '^\.claude/agents/' <<< "$_resume_changed" && _resume_cats="agents"
    grep -q '^\.claude/rules/'  <<< "$_resume_changed" && _resume_cats="${_resume_cats:+$_resume_cats }rules"
    grep -q '^\.claude/skills/' <<< "$_resume_changed" && _resume_cats="${_resume_cats:+$_resume_cats }skills"
    grep -q '^CLAUDE\.md$'      <<< "$_resume_changed" && _resume_cats="${_resume_cats:+$_resume_cats }claude-md"
  fi
  # Leg 2: a successful bootstrap built the whole worktree this run — the same
  # "bootstrap" category claude-config-sync.sh uses for it.
  if (( _bootstrapped == 1 )); then
    case " $_resume_cats " in *" bootstrap "*) ;; *) _resume_cats="${_resume_cats:+$_resume_cats }bootstrap";; esac
  fi
  # Leg 3: a publish that created or repointed links with an UNCHANGED head —
  # a later scheduled tick sees a stable HEAD and the links already in place,
  # so nothing else will ever signal it (same forever-silent shape as leg 1).
  for _lc in $_links_changed_cats; do
    case " $_resume_cats " in *" $_lc "*) ;; *) _resume_cats="${_resume_cats:+$_resume_cats }$_lc";; esac
  done
  if [[ -n "$_resume_cats" ]]; then
    _resume_marker="$(cat "$_marker_file" 2>/dev/null)" || _resume_marker=""
    [[ -n "$_resume_marker" ]] || _resume_marker="{}"
    # shellcheck disable=SC2086 — word-splitting $_resume_cats is the point.
    _resume_cats_json="$(printf '%s\n' $_resume_cats | jq -R . | jq -sc .)" || _resume_cats_json=""
    _resume_new=""
    if [[ -n "$_resume_cats_json" ]]; then
      _resume_new="$(jq -c \
        --arg now "$(date -u +%FT%TZ)" \
        --arg sha "$_new_head" \
        --argjson cats "$_resume_cats_json" \
        '. + {restart_recommended: {
               categories: (((.restart_recommended.categories // []) + $cats) | unique),
               head_sha: $sha, at: $now}}
         | .restart_recommended.reason =
             ("config sync updated " + (.restart_recommended.categories | join(", ")))' \
        <<<"$_resume_marker" 2>/dev/null)" || _resume_new=""
    fi
    if [[ -n "$_resume_new" ]]; then
      # Ownership re-asserted before mutating, exactly as the clear path below
      # does: state-lock.sh breaks a holder on age alone, and a dispossessed
      # hook must not overwrite a marker the new owner just wrote.
      if [[ "$_lock_available" == 1 ]] && ! state_lock_assert_held 2>/dev/null; then
        : # dispossessed — leave the marker to its new owner
      else
        _marker_tmp="${_marker_file}.tmp.$$"
        if printf '%s\n' "$_resume_new" > "$_marker_tmp" 2>/dev/null; then
          chmod 600 "$_marker_tmp" 2>/dev/null || true
          mv -f "$_marker_tmp" "$_marker_file" 2>/dev/null || rm -f "$_marker_tmp" 2>/dev/null || true
        else
          rm -f "$_marker_tmp" 2>/dev/null || true
        fi
      fi
    fi
  fi
fi

_region_exit_restart="null"
if [[ "$_lock_held" == 1 ]]; then
  _region_exit_restart=$(jq -c '.restart_recommended // null' "$_marker_file" 2>/dev/null) || _region_exit_restart="null"
  state_lock_release
  _lock_held=0
fi

# --- Surface (and, on a true restart, clear) the config-sync marker ---
# claude-config-sync.sh writes ~/.claude/sync-restart-recommended.json when a
# landed sync changed something a live session cannot pick up, and when the job
# has been failing repeatedly. Deliver both into the session context here.
#
# READING is lock-free and runs even when the sync region above was skipped: a
# lock-contention skip must never suppress the one notice that asks the user to
# act. The CLEAR is a read-modify-write shared with claude-config-sync.sh, so it
# takes the lock briefly; if it cannot, the marker simply survives to the next
# startup — a duplicate reminder, never a lost one.
#
# `source == "startup"` is a genuinely NEW session: it already loaded the linked
# agents, rules and skills, so the restart portion has served its purpose and is
# cleared. resume/clear/compact fire INSIDE a live session that has NOT picked
# the changes up, so the signal must survive those. The failure portion is never
# cleared here — only a successful sync tick clears it.
# _marker_file is set above, before the lock release, so the region-exit
# snapshot could read it under the lock.
if [[ -f "$_marker_file" ]]; then
  _marker_text=$(jq -r '
    [ (.restart_recommended // empty
       | "RESTART RECOMMENDED: " + (.reason // "config sync landed changes")
         + " (" + ((.at // "unknown time") | tostring) + "). Restart Claude Code when convenient so the new definitions register."),
      (.sync_failure // empty
       | "CONFIG SYNC FAILING: " + (.message // "repeated config sync failures"))
    ] | join("\n")
  ' "$_marker_file" 2>/dev/null) || _marker_text=""
  if [[ -n "$_marker_text" ]]; then
    _marker_notice="$_marker_text"
  fi

  # Remember the exact restart_recommended this session surfaced. The clear
  # below runs after the sync lock has been released and re-acquired, and a
  # scheduled tick can complete entirely inside that gap — landing new links and
  # writing a NEW marker. Both acquires still look uncontended, so the
  # contention guard below cannot see it, and the clear would delete a signal
  # for definitions this session never loaded. Comparing the object identifies
  # that case: a marker written in the gap does not match what was surfaced.
  _surfaced_restart=$(jq -c '.restart_recommended // null' "$_marker_file" 2>/dev/null) || _surfaced_restart="null"

  # `startup` alone is NOT sufficient to clear. The restart portion may only be
  # retired by a startup that actually ran the sync region, because only then is
  # "this session already loaded the current definitions" true.
  #
  # At login the two paths overlap: launchd fires the scheduled sync at
  # RunAtLoad while a new session starts. The hook can lose the lock, skip the
  # worktree and symlink refresh, and then — having loaded the OLD definitions —
  # delete the marker the scheduled job wrote for changes it just landed. The
  # user would be left on stale agents, rules and skills with neither the
  # context notice nor the statusline badge to say so.
  #
  # Skipping the clear is the safe direction and matches the posture stated
  # above for a failed clear-lock: the marker survives to the next startup, a
  # duplicate reminder rather than a lost one. The notice for THIS session was
  # already captured above, so nothing is suppressed by declining to clear.
  # Second condition, independent of the skip: the lock must have been
  # UNCONTENDED. "Startup already loaded the current definitions" only holds
  # for changes that landed before it started. A hook that waits out the lock
  # timeout and then acquires it HAS run the sync region — so the skip guard
  # above passes — yet whoever held the lock may have finished, written the
  # marker and released during that wait, describing changes this session does
  # not have.
  #
  # Contention is the right signal, not a timestamp comparison: both `at` and
  # any clock we could sample here have one-second resolution, so a sync and a
  # session start in the SAME second are indistinguishable — and that same
  # second is exactly the race. Waiting at all, by contrast, is unambiguous
  # evidence that another sync was in flight during this startup. An
  # uncontended acquire is sub-second, so a zero-second delta is reliable.
  # Third condition: the sync region must have SUCCEEDED. The skip guard only
  # asks whether the region ran, so a region that ran and failed — a tripped
  # bound, a failed reset, a setup that could not complete — still passed it,
  # and this session would delete the marker while sitting on definitions it
  # never loaded. That is the same failure the other two guards exist to
  # prevent, reached by a third route, and it is the likeliest of the three:
  # a failed sync is far more common than a lost lock race.
  # Fourth condition: the marker must be the one that was already in place when
  # this session's sync region ended. The contention guard cannot see a sync
  # that started only AFTER this hook released — both acquires look uncontended
  # — and the surfaced-vs-current comparison below cannot see one that finished
  # before the marker was read. The region-exit snapshot covers both: if it
  # differs from what was surfaced, some sync published after this session did
  # its work, and the marker describes definitions this session never loaded.
  # Fifth condition: every publisher actually ran. A publisher that could not be
  # run refreshed none of its links, and the marker's categories cover those
  # links — so clearing here would retire a signal for definitions still stale on
  # disk. The agent publisher reaches this as a NOTICE rather than an error, so
  # `errors` alone cannot see it.
  if [[ "$session_source" == "startup" && -z "$_skip_notice" && -z "$errors" \
        && "$_lock_contended" == 0 && "$_region_exit_restart" == "$_surfaced_restart" \
        && "$_publish_incomplete" == 0 ]]; then
    _clear_locked=0
    if [[ "$_lock_available" == 1 ]] && state_lock_acquire "$_sync_lock_base" 5 2>/dev/null; then
      _clear_locked=1
    fi
    if [[ "$_clear_locked" == 1 ]]; then
      # Re-read under the lock and clear ONLY the restart_recommended this
      # session actually surfaced. If a sync completed in the gap since the
      # first release, the marker now describes changes this session never
      # loaded; leaving it is the same safe direction taken for a failed
      # clear-lock — a duplicate reminder next startup, never a lost one.
      _current_restart=$(jq -c '.restart_recommended // null' "$_marker_file" 2>/dev/null) || _current_restart="null"
      if [[ "$_current_restart" != "$_surfaced_restart" ]]; then
        _cleared=""
      else
        _cleared=$(jq -c 'del(.restart_recommended)' "$_marker_file" 2>/dev/null) || _cleared=""
      fi
      if [[ -n "$_cleared" ]]; then
        # Ownership re-asserted immediately before mutating, exactly as the
        # sync's write_marker does for its own removal. state-lock.sh breaks a
        # lock on AGE ALONE, so having acquired it a few lines up is not proof of
        # still holding it here — and without this check a dispossessed hook
        # could delete or overwrite a marker the new owner had just written,
        # which is the one loss this whole clear path is guarded to avoid.
        if [[ "$_lock_available" == 1 ]] && ! state_lock_assert_held 2>/dev/null; then
          : # Lock lost mid-clear. Leave the marker alone — a duplicate reminder
            # next startup is the safe direction, and the same one every other
            # guard here takes.
        elif [[ "$(jq -r 'if (.sync_failure // null) == null then "empty" else "keep" end' <<<"$_cleared" 2>/dev/null)" == "empty" ]]; then
          rm -f "$_marker_file" 2>/dev/null || true
        else
          _marker_tmp="${_marker_file}.tmp.$$"
          if printf '%s\n' "$_cleared" > "$_marker_tmp" 2>/dev/null; then
            # Match the marker's owner-only mode before it replaces the original;
            # the temp file would otherwise inherit whatever umask is in effect.
            chmod 600 "$_marker_tmp" 2>/dev/null || true
            mv -f "$_marker_tmp" "$_marker_file" 2>/dev/null || rm -f "$_marker_tmp" 2>/dev/null || true
          else
            rm -f "$_marker_tmp" 2>/dev/null || true
          fi
        fi
      fi
      state_lock_release
    fi
  fi
fi

# --- Sync root repo (derives path from skills worktree) ---
# Re-check skills worktree availability independently — fetch/reset errors above
# don't block this pull, and the root repo path is derived from the worktree.
if [[ -d "$skills_wt" && -f "$skills_wt/.git" ]]; then
  # Same delegation as _root_repo above, for the same two reasons: repo-root.sh
  # owns this lookup and bounds its git calls, and dropping the `| head -1 |`
  # pipeline removes the SIGPIPE shape that reports a SUCCESSFUL lookup as a
  # failure under pipefail. This one runs outside the lock, so only the second
  # reason bites here — but leaving one spelling of the lookup behind is how the
  # next reader concludes the two are meant to differ.
  root_repo=""
  if [[ -f "$_repo_root_helper" ]]; then
    # Same 3s-per-call bound as the _root_repo lookup above. This one runs
    # outside the lock, but it spends the same registered-30s hook budget —
    # and the two spellings staying identical is the point.
    root_repo="$(REPO_ROOT_TIMEOUT_SECS=3 bash "$_repo_root_helper" "$skills_wt" 2>/dev/null)"
  fi
  if [[ -n "$root_repo" && -e "$root_repo/.git" ]]; then
    # Only pull if on main branch (don't disrupt feature branches).
    # Delegate the actual sync to main-sync.sh: exit 0 = updated/up-to-date,
    # exit 1 = benign skip (uncommitted tracked changes — leave the root repo
    # alone), exit 2 = hard failure. Only exit 2 is reported as an error.
    current_branch=$(git -C "$root_repo" branch --show-current 2>/dev/null)
    if [[ "$current_branch" == "main" ]]; then
      main_sync_script="$root_repo/.claude/scripts/main-sync.sh"
      # Match the `setup_script` guard on line 32: `-x` alone is too strict,
      # since `bash "$script"` only requires readability. Systems with
      # `core.filemode=false` or mounts that drop the exec bit would still
      # have a usable helper but the `-x` test would silently fall through
      # to the inline `git pull` fallback, losing main-sync.sh's status
      # reporting and error handling (see BugBot finding on PR #345).
      if [[ -x "$main_sync_script" || -f "$main_sync_script" ]]; then
        main_sync_out=$(bash "$main_sync_script" --repo "$root_repo" 2>&1)
        main_sync_rc=$?
        if [[ $main_sync_rc -eq 2 ]]; then
          errors="${errors:+$errors; }root repo sync failed: $main_sync_out"
        fi
      elif ! err=$(git -C "$root_repo" pull origin main --ff-only --quiet 2>&1); then
        errors="${errors:+$errors; }root repo pull failed: $err"
      fi
    fi
  else
    errors="${errors:+$errors; }root repo could not be resolved from skills worktree at $skills_wt"
  fi
fi

# --- Reconcile durable scheduling state (issue #827) ---
# CronCreate jobs are in-memory and die with the session that armed them, so
# every job this file recorded before now is already gone. Purge that dead
# bookkeeping and surface the durable on-disk records that DID survive (an
# overdue harness-audit, a paused PR fleet). Fail-soft by contract — the
# script always exits 0, and any failure here must not block the session.

# Resolved from this hook's own location, not from the skills worktree: the
# reconciler reads session-state, so a broken or missing worktree — exactly
# when stale bookkeeping is most likely — must not also suppress the cleanup.
#
# Purge ONLY on `startup`. compact/resume/clear fire inside a live session,
# where a job or watcher recorded in state may still be running: clearing its
# bookkeeping there orphans a live job, and deciding a watcher is dead races
# the tick that is about to refresh it. On a true startup neither is possible —
# nothing from the previous session survived — so the purge is unambiguous.
# An absent `source` (older harness) is treated as NOT startup: a stale record
# lingering one more session is strictly cheaper than clearing a live one.
notices=""
reconcile_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" 2>/dev/null && pwd)/session-scheduling-reconcile.sh"
if [[ -f "$reconcile_script" ]]; then
  if [[ "$session_source" == "startup" ]]; then
    notices=$(bash "$reconcile_script" 2>/dev/null)
  else
    notices=$(bash "$reconcile_script" --check 2>/dev/null)
  fi
fi

# Fold symlink-publish notices into the notices variable before sanitization so
# they reach the user when no other notices are present.
if [[ -n "$_agents_notices" ]]; then
  if [[ -n "$notices" ]]; then
    notices="${notices}
${_agents_notices}"
  else
    notices="$_agents_notices"
  fi
fi

# The config-sync notices go FIRST — the marker is the one notice that asks the
# user to do something, and the skip notice explains why the refresh below may
# not have run at all. Joined here so each keeps its own variable above.
_config_sync_notice="$_marker_notice"
if [[ -n "$_skip_notice" ]]; then
  _config_sync_notice="${_skip_notice}${_config_sync_notice:+
$_config_sync_notice}"
fi
if [[ -n "$_config_sync_notice" ]]; then
  if [[ -n "$notices" ]]; then
    notices="${_config_sync_notice}

${notices}"
  else
    notices="$_config_sync_notice"
  fi
fi

# Strip control characters before they reach jq. `$errors` carries raw git
# stderr, and a clone/fetch progress meter emits carriage returns and escape
# sequences — noise that lands verbatim in the context block, on exactly the
# first run in a fresh HOME when the sync warning matters most.
# CR (\015) is inside the deleted set: it is the character progress meters
# actually emit, so leaving it out would have made this scrub miss its target.
# Tab (\011) and newline (\012) are preserved — they carry real formatting.
errors=$(printf '%s' "$errors" | LC_ALL=C tr -d '\000-\010\013-\015\016-\037')
notices=$(printf '%s' "$notices" | LC_ALL=C tr -d '\000-\010\013-\015\016-\037')

# Report result
if [[ -n "$errors" ]]; then
  jq -n --arg errors "$errors" --arg notices "$notices" '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: ("SESSION SYNC WARNING: Config sync encountered errors: " + $errors + ". Skills, rules, or CLAUDE.md may be stale. Run manually: git -C ~/.claude/skills-worktree fetch origin main && git -C ~/.claude/skills-worktree reset --hard origin/main" + (if $notices == "" then "" else "\n\n" + $notices end))
    }
  }'
elif [[ -n "$notices" ]]; then
  jq -n --arg notices "$notices" '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: $notices
    }
  }'
else
  echo '{}'
fi

exit 0
