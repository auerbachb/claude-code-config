#!/bin/bash
# install-config-sync.sh — register the per-machine Claude config sync with
# launchd, in one command (issue #1524).
# catalog: scheduling-monitoring — Register the per-machine config sync (`claude-config-sync.sh`) as a macOS launchd LaunchAgent — one run at login, then every `--interval` seconds
#
# Installs a LaunchAgent that runs claude-config-sync.sh at login (RunAtLoad)
# and hourly thereafter (StartInterval). launchd survives reboots and coalesces
# every interval missed while the machine slept into one run on wake, so the
# job catches up on its own — no hand-rolled catch-up path.
#
# Opt-in and manually invoked, exactly like install-silence-watchdog.sh. It is
# deliberately NOT called from setup.sh: a machine gets the scheduler when its
# owner asks for it.
#
# Usage: install-config-sync.sh [--interval SECONDS] [--help]
#
#   --interval SECONDS   Override the StartInterval (default 3600, minimum 60)
#   --help               Print this usage and exit 0
#
# SCRIPT PATH RESOLUTION
#   The plist points at the skills-worktree copy of claude-config-sync.sh when
#   one exists — that worktree is pinned to `main`, so the scheduled job keeps
#   running the merged script even while this checkout sits on a feature branch.
#   Without a worktree it points at this checkout's copy and says so.
#
# EXIT CODES
#   0  installed and verified running
#   1  not macOS, template missing, or the job did not appear in launchctl
#   2  usage error
#
# Uninstall with uninstall-config-sync.sh.
#
# DEPENDENCIES
#   bash, launchctl, sed, id, mkdir (all base macOS)

set -euo pipefail

LABEL="com.user.claude-config-sync"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_PLIST="$SCRIPT_DIR/${LABEL}.plist"

usage() {
  cat <<'EOF'
Usage: install-config-sync.sh [--interval SECONDS] [--help]

  Registers the per-machine Claude config sync (claude-config-sync.sh) as a
  launchd LaunchAgent: one run at login, then every StartInterval seconds.
  launchd restarts it after a reboot and coalesces runs missed during sleep.

OPTIONS
  --interval SECONDS   StartInterval override (default 3600, minimum 60)
  --help               Print this usage and exit 0

EXIT CODES
  0  installed and verified running
  1  not macOS, template missing, or the job did not appear in launchctl list
  2  usage error

FILES
  ~/Library/LaunchAgents/com.user.claude-config-sync.plist   installed job
  ~/.claude/logs/claude-config-sync.log                      run log

  Remove it again with uninstall-config-sync.sh.
EOF
}

# Captured before the parsing loop shifts them away — the telemetry line below
# is meant to record what the caller actually passed.
ORIGINAL_ARGS="$*"

INTERVAL=3600
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --interval)
      shift
      if [[ $# -eq 0 || ! "${1:-}" =~ ^[0-9]+$ ]]; then
        echo "install-config-sync.sh: --interval needs a positive integer (seconds)" >&2
        exit 2
      fi
      if (( $1 < 60 )); then
        echo "install-config-sync.sh: --interval must be at least 60 seconds (got $1)" >&2
        exit 2
      fi
      INTERVAL="$1"
      ;;
    *)
      echo "install-config-sync.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

# Platform check BEFORE any $HOME expansion: on a non-Darwin host with HOME
# unset, `set -u` would abort at the path assignments below instead of taking
# this documented, explicit exit (the uninstaller's issue #1430 lesson).
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "FAIL: claude-config-sync is macOS-only (launchd). Linux support is out of scope." >&2
  exit 1
fi

printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${ORIGINAL_ARGS//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
INSTALLED_PLIST="$LAUNCH_AGENTS_DIR/${LABEL}.plist"
LOG_DIR="$HOME/.claude/logs"
GUI_DOMAIN="gui/$(id -u)"
WORKTREE_SYNC="$HOME/.claude/skills-worktree/.claude/scripts/claude-config-sync.sh"
LOCAL_SYNC="$SCRIPT_DIR/claude-config-sync.sh"

if [[ ! -f "$TEMPLATE_PLIST" ]]; then
  echo "FAIL: plist template not found: $TEMPLATE_PLIST" >&2
  exit 1
fi

# Prefer the main-pinned worktree copy so the scheduled job never runs a feature
# branch's version of itself.
# `-r`, not just `-f`: the plist points launchd at this path, and a present but
# UNREADABLE script — a partially-populated worktree, a permissions mishap —
# would install a scheduler that fails on every tick with nothing here to say
# why. Falling through to the local copy is the better answer, and the `-r` also
# covers the `-f` case, so both candidates are tested the same way.
if [[ -f "$WORKTREE_SYNC" && -r "$WORKTREE_SYNC" ]]; then
  SYNC_SCRIPT="$WORKTREE_SYNC"
  SYNC_SOURCE="skills worktree (pinned to main)"
elif [[ -f "$LOCAL_SYNC" && -r "$LOCAL_SYNC" ]]; then
  SYNC_SCRIPT="$LOCAL_SYNC"
  SYNC_SOURCE="this checkout (no skills worktree yet)"
else
  echo "FAIL: claude-config-sync.sh not found at $WORKTREE_SYNC or $LOCAL_SYNC" >&2
  exit 1
fi

[[ -x "$SYNC_SCRIPT" ]] || chmod +x "$SYNC_SCRIPT" 2>/dev/null || true

mkdir -p "$LOG_DIR" "$LAUNCH_AGENTS_DIR"

# Escapes every character that is special on the RIGHT side of the `#`-delimited
# substitutions below: `&` (the whole-match backreference), `#` (the delimiter
# itself), and `\` (which would otherwise start an escape — `\1`, `\n`, or a
# swallowed delimiter). All three are handled in ONE pass by a single bracket
# expression, so there is no ordering hazard: sed rewrites each matched
# character once and never re-scans what the replacement emitted.
escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[\\&#]/\\&/g'
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  printf '%s' "$value"
}

ESCAPED_SCRIPT_PATH="$(escape_sed_replacement "$(xml_escape "$SYNC_SCRIPT")")"
ESCAPED_HOME="$(escape_sed_replacement "$(xml_escape "$HOME")")"

# The StartInterval rewrite is ANCHORED to the line after its own key rather
# than matching the literal default globally: a blind
# s#<integer>3600</integer># would also rewrite any other integer that happened
# to share the value. The multi-`-e` spelling is deliberate — a nested block
# written as one expression is rejected by BSD sed, which is the platform this
# installer only ever runs on.
# Rendered to a temp file in the destination directory, validated, and only then
# moved into place: a bad render must never replace a working installed plist.
RENDERED_PLIST="$(mktemp "${LAUNCH_AGENTS_DIR}/.${LABEL}.XXXXXX")"
sed \
  -e "s#__SHELL__#/bin/bash#g" \
  -e "s#__SCRIPT_PATH__#$ESCAPED_SCRIPT_PATH#g" \
  -e "s#__HOME__#$ESCAPED_HOME#g" \
  -e '/<key>StartInterval<\/key>/{' \
  -e 'n' \
  -e "s#<integer>[0-9]*</integer>#<integer>${INTERVAL}</integer>#" \
  -e '}' \
  "$TEMPLATE_PLIST" > "$RENDERED_PLIST"

# Validate before handing it to launchd: a broken substitution otherwise
# surfaces as an opaque `launchctl bootstrap` failure. plutil ships with macOS;
# the guard is skipped rather than failed when it is not on PATH, and says so.
if command -v plutil >/dev/null 2>&1; then
  if ! plutil_err="$(plutil -lint "$RENDERED_PLIST" 2>&1)"; then
    rm -f "$RENDERED_PLIST"
    echo "FAIL: the rendered plist is not valid: $plutil_err" >&2
    echo "      Any previously installed job was left untouched." >&2
    exit 1
  fi
else
  echo "NOTE: plutil not found — skipped validating the rendered plist." >&2
fi

# Keep whatever is currently installed until the new job is confirmed loaded.
# The bootout below unloads the running instance unconditionally, so without a
# copy to fall back on, a failed bootstrap would leave the machine with NO
# scheduler — strictly worse than before the upgrade was attempted.
PREV_PLIST=""
if [[ -f "$INSTALLED_PLIST" ]]; then
  PREV_PLIST="${INSTALLED_PLIST}.prev.$$"
  # Abort rather than continue with no fallback. Swallowing this failure would
  # walk straight into the very outcome the copy exists to prevent: the bootout
  # below unloads the running job unconditionally, so a failed bootstrap after a
  # failed backup leaves the machine with NO scheduler and nothing to restore.
  # Stopping here costs an un-upgraded install; continuing risks no install.
  if ! cp -p "$INSTALLED_PLIST" "$PREV_PLIST" 2>/dev/null; then
    rm -f "$PREV_PLIST" "$RENDERED_PLIST" 2>/dev/null || true
    echo "FAIL: could not back up the installed plist to $PREV_PLIST." >&2
    echo "      Nothing was changed — the existing job is still installed and loaded." >&2
    exit 1
  fi
fi

if ! mv -f "$RENDERED_PLIST" "$INSTALLED_PLIST"; then
  rm -f "$RENDERED_PLIST"
  if [[ -n "$PREV_PLIST" ]]; then rm -f "$PREV_PLIST"; fi
  echo "FAIL: could not move the rendered plist into $INSTALLED_PLIST." >&2
  echo "      Any previously installed job was left untouched and is still loaded." >&2
  exit 1
fi
chmod 644 "$INSTALLED_PLIST" 2>/dev/null || true

# Idempotently unload any existing instance before bootstrapping the new plist.
launchctl bootout "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1 || true
# Handled explicitly rather than left to `set -e`: an aborting bootstrap would
# exit with launchctl's own status (5, 36, …) and say nothing, breaking both the
# documented 0/1/2 contract and the diagnosis.
if ! launchctl bootstrap "$GUI_DOMAIN" "$INSTALLED_PLIST"; then
  echo "FAIL: launchctl bootstrap $GUI_DOMAIN $INSTALLED_PLIST failed — the LaunchAgent was not loaded." >&2
  # The bootout above already unloaded the previous instance, so returning here
  # without restoring it would take a working installation offline as the cost
  # of a failed upgrade. Put the old plist back and reload it.
  if [[ -n "$PREV_PLIST" ]] && mv -f "$PREV_PLIST" "$INSTALLED_PLIST" 2>/dev/null; then
    if launchctl bootstrap "$GUI_DOMAIN" "$INSTALLED_PLIST" >/dev/null 2>&1; then
      echo "      Rolled back: the previously installed job was restored and reloaded." >&2
    else
      echo "      Restored the previous plist at $INSTALLED_PLIST, but it did not reload." >&2
      echo "      Reload it with: launchctl bootstrap $GUI_DOMAIN $INSTALLED_PLIST" >&2
    fi
  else
    if [[ -n "$PREV_PLIST" ]]; then rm -f "$PREV_PLIST"; fi
    echo "      The rendered plist is still at $INSTALLED_PLIST; inspect it, then retry." >&2
  fi
  exit 1
fi
if [[ -n "$PREV_PLIST" ]]; then rm -f "$PREV_PLIST"; fi
# NOT best-effort, unlike the bootout above. `launchctl list` reports a job that
# is merely BOOTSTRAPPED, whether or not it is enabled — so a swallowed `enable`
# failure leaves a disabled job that lists, passes the verification below, and
# never runs. That is the one launchd error this script cannot detect after the
# fact, which is exactly why it is checked here instead.
if ! enable_err="$(launchctl enable "$GUI_DOMAIN/$LABEL" 2>&1)"; then
  echo "FAIL: launchctl enable $GUI_DOMAIN/$LABEL failed — the job is loaded but disabled, so it would never run." >&2
  # A plain `[[ … ]] && echo` would be the last command of this block on the
  # empty-stderr path, and under `set -e` its false test would exit the script
  # right here — dropping the recovery instructions below.
  if [[ -n "$enable_err" ]]; then echo "      launchctl: $enable_err" >&2; fi
  # Left loaded on purpose: the job is bootstrapped and one `enable` away from
  # working, so tearing it down would turn a recoverable state into a reinstall.
  echo "      The plist remains at $INSTALLED_PLIST. Finish the install with:" >&2
  echo "        launchctl enable $GUI_DOMAIN/$LABEL" >&2
  echo "        launchctl kickstart -k $GUI_DOMAIN/$LABEL" >&2
  exit 1
fi
# kickstart only forces the FIRST run to happen NOW; RunAtLoad and the
# StartInterval below still fire without it. So a failure here is worth saying
# out loud but is not an install failure — exiting would condemn a scheduler
# that is loaded, enabled, and will run on its own.
if ! kickstart_err="$(launchctl kickstart -k "$GUI_DOMAIN/$LABEL" 2>&1)"; then
  echo "WARN: launchctl kickstart -k $GUI_DOMAIN/$LABEL failed — only the immediate first run" >&2
  echo "      did not start; the job is loaded and enabled, so it still runs every ${INTERVAL}s and at login." >&2
  # Same `set -e` hazard as the enable branch, and here it would abort a run
  # that has already succeeded: this warning is the block's last statement.
  if [[ -n "$kickstart_err" ]]; then echo "      launchctl: $kickstart_err" >&2; fi
fi

# Capture first, match from a here-string. `launchctl list | grep -q` looks
# equivalent but is not: grep exits at the first match, launchctl takes SIGPIPE,
# and under `set -o pipefail` the pipeline reports FAILURE on a SUCCESSFUL match
# — so the verification would announce FAIL exactly when the install worked
# (repo memory: pipefail-sigpipe-false-failure).
launchctl_list="$(launchctl list 2>/dev/null || true)"
# Matched on the WHOLE label, not as a substring. `launchctl list` prints
# "PID<TAB>Status<TAB>Label", so the label is the last field; `grep -q "$LABEL"`
# would also accept a longer label that merely CONTAINS ours — a stray
# com.user.claude-config-sync-test agent would make a failed install report PASS.
# awk compares the field literally, which also sidesteps having to escape the
# dots in the reverse-DNS label as regex metacharacters.
if awk -v want="$LABEL" '$NF == want { found = 1 } END { exit !found }' <<< "$launchctl_list"; then
  echo "PASS: $LABEL is running (every ${INTERVAL}s, plus once at login)."
  echo "Script:  $SYNC_SCRIPT — $SYNC_SOURCE"
  echo "Log:     $LOG_DIR/claude-config-sync.log"
  echo "Verify with: launchctl list | grep claude-config-sync"
else
  # Reached only when bootstrap SUCCEEDED but the listing did not show the job,
  # so the agent may well be loaded and running — this is a failed verification,
  # not a failed install, and tearing down a possibly-working scheduler because
  # a listing query disagreed would be the worse trade. Say what state the
  # machine is actually in and how to finish either way.
  echo "FAIL: $LABEL did not appear in launchctl list after install." >&2
  echo "      launchctl bootstrap reported success, so the job may still be loaded;" >&2
  echo "      the plist remains at $INSTALLED_PLIST." >&2
  echo "      Check with:  launchctl list | grep claude-config-sync" >&2
  echo "      Remove with: $SCRIPT_DIR/uninstall-config-sync.sh" >&2
  exit 1
fi
