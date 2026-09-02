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
  # Contention is detected two ways, OR-ed, because neither alone is sound.
  #
  #   1. Structural: does the lock directory already exist as we walk up to it?
  #      state-lock.sh's lock for a given base is "${base}.lock" (documented in
  #      its header). Present => somebody else holds it right now.
  #   2. Timing: whole-second stamps either side of the acquire.
  #
  # The timing check ALONE is not enough: `date +%s` has one-second resolution,
  # so a real wait shorter than a second reads as a delta of 0 and would be
  # misreported as uncontended — which would clear the restart marker for
  # definitions this session never loaded (the failure that matters, since it
  # silently withholds the restart reminder). The structural check catches
  # exactly that sub-second window. The timing check still earns its keep for a
  # lock taken after our test but before our acquire.
  #
  # Both are biased toward reporting CONTENDED, whose only cost is a duplicate
  # reminder. An unusable clock reads as CONTENDED for the same reason.
  _lock_contended_pre=0
  [[ -d "${_sync_lock_base}.lock" ]] && _lock_contended_pre=1
  _lock_t0="$(date -u +%s 2>/dev/null)" || _lock_t0=""
  if state_lock_acquire "$_sync_lock_base" "${CLAUDE_CONFIG_SYNC_HOOK_LOCK_TIMEOUT:-10}" 2>/dev/null; then
    _lock_held=1
  fi
  _lock_t1="$(date -u +%s 2>/dev/null)" || _lock_t1=""
  if (( _lock_contended_pre == 1 )); then
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
_bounded_lib="${_scripts_dir}/lib/bounded-run.sh"
_bound_available=0
if [[ -n "$_scripts_dir" && -f "$_bounded_lib" ]]; then
  # shellcheck source=../scripts/lib/bounded-run.sh
  source "$_bounded_lib" && _bound_available=1
fi
_sync_bound_secs=20
if (( _bound_available == 1 )); then
  _sync_bound_secs="$(normalize_bound "${CLAUDE_CONFIG_SYNC_HOOK_GIT_BOUND:-}" 20)"
  CAPTURE="$(mktemp "${TMPDIR:-/tmp}/session-start-sync-out.XXXXXX")"     || CAPTURE=""
  CAPTURE_ERR="$(mktemp "${TMPDIR:-/tmp}/session-start-sync-err.XXXXXX")" || CAPTURE_ERR=""
  [[ -n "$CAPTURE" && -n "$CAPTURE_ERR" ]] || _bound_available=0
  trap 'rm -f "${CAPTURE:-}" "${CAPTURE_ERR:-}" 2>/dev/null || true' EXIT
fi

# Run one lock-held command under the bound, mirroring claude-config-sync.sh's
# git_sync. Called at statement level ONLY, never inside `$( )`: a subshell
# discards BOUNDED_TIMED_OUT and the capture handover (bounded-run.sh contract).
_bounded_out=""
_run_locked() { # _run_locked <command…>
  local rc=0
  BOUNDED_TIMED_OUT=0
  if (( _bound_available == 0 )); then
    _bounded_out="$("$@" 2>&1)" || rc=$?
    return "$rc"
  fi
  run_bounded "$_sync_bound_secs" "$@" || rc=$?
  _bounded_out="$(cat "$CAPTURE_ERR" 2>/dev/null)" || _bounded_out=""
  [[ -n "$_bounded_out" ]] || _bounded_out="$(cat "$CAPTURE" 2>/dev/null)" || _bounded_out=""
  return "$rc"
}

# Bootstrap missing skills worktree if setup script is available.
# NOTE on the message wording below: the publish guard further down keys off the
# substrings "setup failed" and "reset failed", so a timed-out call must still
# carry its token or a bound trip would silently re-open the very partial-tree
# publish that guard exists to block.
if [[ ! -d "$skills_wt/.claude/skills" || ! -f "$skills_wt/.git" ]]; then
  if [[ -x "$setup_script" || -f "$setup_script" ]]; then
    if ! _run_locked bash "$setup_script"; then
      if [[ "${BOUNDED_TIMED_OUT:-0}" -eq 1 ]]; then
        errors="skills worktree setup failed: exceeded its ${_sync_bound_secs}s bound — aborted before the lock staleness window could dispossess this run"
      else
        errors="skills worktree setup failed: $_bounded_out"
      fi
    fi
  fi
fi

if [[ -z "$errors" && -d "$skills_wt" && -f "$skills_wt/.git" ]]; then
  if ! _run_locked git -C "$skills_wt" fetch origin main --quiet; then
    if [[ "${BOUNDED_TIMED_OUT:-0}" -eq 1 ]]; then
      errors="skills worktree fetch failed: exceeded its ${_sync_bound_secs}s bound — aborted before the lock staleness window could dispossess this run"
    else
      errors="skills worktree fetch failed: $_bounded_out"
    fi
  elif ! _run_locked git -C "$skills_wt" reset --hard origin/main --quiet; then
    if [[ "${BOUNDED_TIMED_OUT:-0}" -eq 1 ]]; then
      errors="skills worktree reset failed: exceeded its ${_sync_bound_secs}s bound — aborted before the lock staleness window could dispossess this run"
    else
      errors="skills worktree reset failed: $_bounded_out"
    fi
  fi
elif [[ -z "$errors" ]]; then
  errors="skills worktree not found at $skills_wt"
fi

# The root repo backing the skills worktree. Hoisted above the publish block
# because the hook-registration block further down needs it too — see the
# MANAGED_LEGACY_HOOKS_DIR note there. Empty when the worktree is absent or git
# cannot read it; every consumer treats empty as "no legacy root known".
_root_repo=$(git -C "$skills_wt" worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //') || _root_repo=""

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
    [[ -n "$out" ]] && _agents_notices="${_agents_notices:+$_agents_notices
}$out"
    [[ -n "$err" ]] && _agents_notices="${_agents_notices:+$_agents_notices
}$err"
    return 0
  }

  _skills_publish_script="${_scripts_dir}/publish-skill-symlinks.sh"
  if [[ -f "$_skills_publish_script" ]]; then
    _publish_one "$_skills_publish_script" "skill"
  fi

  _agents_publish_script="${_scripts_dir}/publish-agent-symlinks.sh"
  if [[ -f "$_agents_publish_script" ]]; then
    _publish_one "$_agents_publish_script" "agent"
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
if [[ -d "$skills_wt" && -f "$skills_wt/.git" ]]; then
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

# Release as soon as the shared region is done — the root-repo sync below is a
# different resource and must not hold this lock while it pulls.
if [[ "$_lock_held" == 1 ]]; then
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
_marker_file="$HOME/.claude/sync-restart-recommended.json"
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
  if [[ "$session_source" == "startup" && -z "$_skip_notice" && "$_lock_contended" == 0 ]]; then
    _clear_locked=0
    if [[ "$_lock_available" == 1 ]] && state_lock_acquire "$_sync_lock_base" 5 2>/dev/null; then
      _clear_locked=1
    fi
    if [[ "$_clear_locked" == 1 ]]; then
      _cleared=$(jq -c 'del(.restart_recommended)' "$_marker_file" 2>/dev/null) || _cleared=""
      if [[ -n "$_cleared" ]]; then
        if [[ "$(jq -r 'if (.sync_failure // null) == null then "empty" else "keep" end' <<<"$_cleared" 2>/dev/null)" == "empty" ]]; then
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
  root_repo=$(git -C "$skills_wt" worktree list 2>/dev/null | head -1 | awk '{print $1}')
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
