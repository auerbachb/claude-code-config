#!/bin/bash
# install-backfill-review.sh — register the overnight backfill review
# (backfill-review.sh) with launchd, in one command (issue #1941).
# catalog: scheduling-monitoring — Register the overnight backfill review (`backfill-review.sh --repo-dir <checkout>`) as a macOS launchd LaunchAgent — every `--interval` seconds (default 1800); the runner gates on its own quiet window
#
# Installs a LaunchAgent that runs backfill-review.sh --repo-dir <checkout> at
# load (RunAtLoad) and every 30 minutes thereafter (StartInterval). The runner
# checks its own quiet window and exits 0 at once outside it, so a plain
# interval timer is all it needs. Modelled on install-config-sync.sh — same
# placeholder rendering, validation, backup/rollback and launchctl sequence.
#
# Opt-in and manually invoked. NOT called from setup.sh: a machine gets the
# scheduler when its owner asks for it.
#
# Usage: install-backfill-review.sh --repo-dir DIR [--interval SECONDS] [--help]
#
#   --repo-dir DIR       git checkout to backfill (required; resolved to its
#                        absolute top level, must have an `origin` remote)
#   --interval SECONDS   Override the StartInterval (default 1800, minimum 60)
#   --help               Print this usage and exit 0
#
# SCRIPT PATH RESOLUTION
#   The plist points at the skills-worktree copy of backfill-review.sh when it
#   and its sibling helpers are present — that worktree is pinned to `main`, so
#   the job keeps running the merged script while this checkout sits on a
#   feature branch. Otherwise it points at this checkout's copy and says so.
#
# PATH
#   launchd starts jobs with a bare PATH, and the runner exits 3 without git,
#   jq, python3 and gh. The installer resolves those four (required) plus the
#   coderabbit and codeant CLIs (warned about when missing) and renders their
#   directories, then the base system directories, deduplicated.
#
# EXIT CODES
#   0  installed and verified running
#   1  not macOS, a required tool, the checkout, the runner or the template is
#      missing or invalid, or the job did not appear in launchctl
#   2  usage error
#
# Uninstall with uninstall-backfill-review.sh (keeps the ledger).
#
# DEPENDENCIES
#   bash, launchctl, sed, id, mkdir (all base macOS); git, jq, python3, gh

set -euo pipefail

LABEL="com.user.claude-backfill-review"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_PLIST="$SCRIPT_DIR/${LABEL}.plist"
BASE_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# backfill-review.sh refuses to start without these siblings (exit 3), so a
# runner copy missing any of them is not a usable target for the plist.
RUNNER_HELPERS="unreviewed-merge-ledger.sh local-review.sh issue-file.sh issue-dedup.sh lib/backfill_review.py"

usage() {
  cat <<'EOF'
Usage: install-backfill-review.sh --repo-dir DIR [--interval SECONDS] [--help]

  Registers the overnight backfill review (backfill-review.sh) as a launchd
  LaunchAgent: one run at load, then every StartInterval seconds. The runner
  exits 0 at once outside its quiet window, so most ticks do nothing.

OPTIONS
  --repo-dir DIR       git checkout to backfill (required)
  --interval SECONDS   StartInterval override (default 1800, minimum 60)
  --help               Print this usage and exit 0

EXIT CODES
  0  installed and verified running
  1  not macOS; a required tool, the checkout, the runner or the template is
     missing or invalid; or the job did not appear in launchctl list
  2  usage error

FILES
  ~/Library/LaunchAgents/com.user.claude-backfill-review.plist   installed job
  ~/.claude/logs/backfill-review.log                             run log

  Remove it again with uninstall-backfill-review.sh (the ledger is kept).
EOF
}

# Captured before the parsing loop shifts them away — the telemetry line below
# is meant to record what the caller actually passed.
ORIGINAL_ARGS="$*"

INTERVAL=1800
REPO_DIR_ARG=""
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --interval)
      shift
      if [[ $# -eq 0 || ! "${1:-}" =~ ^[0-9]+$ ]]; then
        echo "install-backfill-review.sh: --interval needs a positive integer (seconds)" >&2
        exit 2
      fi
      # Base 10 explicitly: "0900" is otherwise an invalid octal literal.
      if (( 10#$1 < 60 )); then
        echo "install-backfill-review.sh: --interval must be at least 60 seconds (got $1)" >&2
        exit 2
      fi
      INTERVAL=$(( 10#$1 ))
      ;;
    --repo-dir)
      shift
      if [[ $# -eq 0 || -z "${1:-}" ]]; then
        echo "install-backfill-review.sh: --repo-dir needs a path" >&2
        exit 2
      fi
      REPO_DIR_ARG="$1"
      ;;
    *)
      echo "install-backfill-review.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ -z "$REPO_DIR_ARG" ]]; then
  echo "install-backfill-review.sh: --repo-dir is required" >&2
  usage >&2
  exit 2
fi

# Platform check BEFORE any $HOME expansion (the config-sync installers'
# issue #1430 lesson: with HOME unset, `set -u` would abort first).
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "FAIL: the backfill-review LaunchAgent is macOS-only (launchd)." >&2
  exit 1
fi

printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${ORIGINAL_ARGS//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
INSTALLED_PLIST="$LAUNCH_AGENTS_DIR/${LABEL}.plist"
LOG_DIR="$HOME/.claude/logs"
GUI_DOMAIN="gui/$(id -u)"
WORKTREE_RUNNER="$HOME/.claude/skills-worktree/.claude/scripts/backfill-review.sh"
LOCAL_RUNNER="$SCRIPT_DIR/backfill-review.sh"

if [[ ! -f "$TEMPLATE_PLIST" ]]; then
  echo "FAIL: plist template not found: $TEMPLATE_PLIST" >&2
  exit 1
fi

# ── Everything below up to the render is read-only: a bad checkout, a missing
#    tool or an incomplete runner must fail before any file is written. ──

has_control_char() { [[ "$1" == *[[:cntrl:]]* ]]; }

# Required tools: backfill-review.sh checks these before its window gate, so a
# job without them fails on EVERY tick (exit 3), not just overnight.
PATH_DIRS=()
for tool in gh git jq python3; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  if [[ -z "$tool_path" || "$tool_path" != /* ]]; then
    echo "FAIL: $tool not found on PATH — backfill-review.sh needs it on every run." >&2
    exit 1
  fi
  PATH_DIRS+=("$(dirname "$tool_path")")
done

# Reviewer CLIs: optional at install time — the runner drops a missing channel
# and stops cleanly when none is left. `command -v` first (the owner's own
# shell is the best witness), then the candidate directories local-review.sh
# itself probes.
for tool in coderabbit codeant; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  if [[ -z "$tool_path" || "$tool_path" != /* ]]; then
    tool_path=""
    for cand in "/opt/homebrew/bin/$tool" "$HOME/.local/bin/$tool" "$HOME/bin/$tool" "/usr/local/bin/$tool"; do
      if [[ -x "$cand" ]]; then tool_path="$cand"; break; fi
    done
  fi
  if [[ -n "$tool_path" ]]; then
    PATH_DIRS+=("$(dirname "$tool_path")")
  else
    echo "WARN: $tool CLI not found — that review channel will be skipped until it is installed." >&2
  fi
done

# Build the job PATH: resolved tool directories first, then the base, with
# duplicates dropped. A directory containing `:` cannot be expressed in PATH at
# all, and a control character would corrupt the plist — refuse both.
JOB_PATH=""
IFS=':' read -r -a BASE_DIRS <<< "$BASE_PATH"
for dir in "${PATH_DIRS[@]}" "${BASE_DIRS[@]}"; do
  if [[ "$dir" == *:* ]] || has_control_char "$dir"; then
    echo "FAIL: tool directory cannot go on a PATH (contains ':' or a control character): $dir" >&2
    exit 1
  fi
  case ":$JOB_PATH:" in
    *":$dir:"*) ;;
    *) JOB_PATH="${JOB_PATH:+$JOB_PATH:}$dir" ;;
  esac
done

# The checkout: launchd has no meaningful working directory, so the plist gets
# the absolute top level, resolved the same way backfill-review.sh does it.
if has_control_char "$REPO_DIR_ARG"; then
  echo "FAIL: --repo-dir contains a control character." >&2
  exit 1
fi
if ! REPO_DIR="$(cd -- "$REPO_DIR_ARG" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" || [[ -z "$REPO_DIR" ]]; then
  echo "FAIL: --repo-dir is not inside a git checkout: $REPO_DIR_ARG" >&2
  exit 1
fi
if has_control_char "$REPO_DIR"; then
  echo "FAIL: the resolved checkout path contains a control character: $REPO_DIR" >&2
  exit 1
fi
if ! git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
  echo "FAIL: no origin remote in $REPO_DIR — backfill-review.sh needs it to find the repo." >&2
  exit 1
fi

# runner_complete <path> — the runner and every helper it requires are
# readable regular files. `-r`, not just `-f`, for the reason the config-sync
# installer gives: a present but unreadable script installs a job that fails
# every tick with nothing here to say why.
runner_complete() {
  local runner="$1" dir h
  [[ -f "$runner" && -r "$runner" ]] || return 1
  dir="$(dirname "$runner")"
  for h in $RUNNER_HELPERS; do
    [[ -f "$dir/$h" && -r "$dir/$h" ]] || return 1
  done
  return 0
}

if runner_complete "$WORKTREE_RUNNER"; then
  RUNNER="$WORKTREE_RUNNER"
  RUNNER_SOURCE="skills worktree (pinned to main)"
elif runner_complete "$LOCAL_RUNNER"; then
  RUNNER="$LOCAL_RUNNER"
  RUNNER_SOURCE="this checkout (no complete skills worktree copy) — NOT pinned to main"
else
  echo "FAIL: no complete backfill-review.sh (with its helpers: $RUNNER_HELPERS)" >&2
  echo "      at $WORKTREE_RUNNER or $LOCAL_RUNNER" >&2
  exit 1
fi
if has_control_char "$RUNNER"; then
  echo "FAIL: the runner path contains a control character: $RUNNER" >&2
  exit 1
fi

[[ -x "$RUNNER" ]] || chmod +x "$RUNNER" 2>/dev/null || true

mkdir -p "$LOG_DIR" "$LAUNCH_AGENTS_DIR"

# Same escaping as install-config-sync.sh: XML-escape the value, then escape
# `\`, `&` and `#` for the RIGHT side of the `#`-delimited substitutions in one
# bracket-expression pass (no ordering hazard).
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

ESCAPED_SCRIPT_PATH="$(escape_sed_replacement "$(xml_escape "$RUNNER")")"
ESCAPED_REPO_DIR="$(escape_sed_replacement "$(xml_escape "$REPO_DIR")")"
ESCAPED_PATH="$(escape_sed_replacement "$(xml_escape "$JOB_PATH")")"
ESCAPED_HOME="$(escape_sed_replacement "$(xml_escape "$HOME")")"

# StartInterval rewrite anchored to the line after its key (multi-`-e`, which
# BSD sed accepts); rendered to a temp file, validated, then moved into place.
RENDERED_PLIST="$(mktemp "${LAUNCH_AGENTS_DIR}/.${LABEL}.XXXXXX")"
sed \
  -e "s#__SHELL__#/bin/bash#g" \
  -e "s#__SCRIPT_PATH__#$ESCAPED_SCRIPT_PATH#g" \
  -e "s#__REPO_DIR__#$ESCAPED_REPO_DIR#g" \
  -e "s#__PATH__#$ESCAPED_PATH#g" \
  -e "s#__HOME__#$ESCAPED_HOME#g" \
  -e '/<key>StartInterval<\/key>/{' \
  -e 'n' \
  -e "s#<integer>[0-9]*</integer>#<integer>${INTERVAL}</integer>#" \
  -e '}' \
  "$TEMPLATE_PLIST" > "$RENDERED_PLIST"

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

# Keep whatever is installed until the new job is confirmed loaded; abort when
# the backup itself fails (rationale: install-config-sync.sh).
PREV_PLIST=""
if [[ -f "$INSTALLED_PLIST" ]]; then
  PREV_PLIST="${INSTALLED_PLIST}.prev.$$"
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

launchctl bootout "$GUI_DOMAIN/$LABEL" >/dev/null 2>&1 || true
if ! launchctl bootstrap "$GUI_DOMAIN" "$INSTALLED_PLIST"; then
  echo "FAIL: launchctl bootstrap $GUI_DOMAIN $INSTALLED_PLIST failed — the LaunchAgent was not loaded." >&2
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
# Fatal, unlike bootout: a disabled job still lists, so this is the one launchd
# failure the verification below cannot catch.
if ! enable_err="$(launchctl enable "$GUI_DOMAIN/$LABEL" 2>&1)"; then
  echo "FAIL: launchctl enable $GUI_DOMAIN/$LABEL failed — the job is loaded but disabled, so it would never run." >&2
  if [[ -n "$enable_err" ]]; then echo "      launchctl: $enable_err" >&2; fi
  echo "      The plist remains at $INSTALLED_PLIST. Finish the install with:" >&2
  echo "        launchctl enable $GUI_DOMAIN/$LABEL" >&2
  echo "        launchctl kickstart -k $GUI_DOMAIN/$LABEL" >&2
  exit 1
fi
# kickstart only forces the first run now; RunAtLoad and StartInterval still
# fire without it, so a failure is a warning, not an install failure.
if ! kickstart_err="$(launchctl kickstart -k "$GUI_DOMAIN/$LABEL" 2>&1)"; then
  echo "WARN: launchctl kickstart -k $GUI_DOMAIN/$LABEL failed — only the immediate first run" >&2
  echo "      did not start; the job is loaded and enabled, so it still runs every ${INTERVAL}s." >&2
  if [[ -n "$kickstart_err" ]]; then echo "      launchctl: $kickstart_err" >&2; fi
fi

# Capture, then match the whole label as the last field (no `| grep -q` under
# pipefail; no substring match on a lookalike label) — see install-config-sync.sh.
launchctl_list="$(launchctl list 2>/dev/null || true)"
if awk -v want="$LABEL" '$NF == want { found = 1 } END { exit !found }' <<< "$launchctl_list"; then
  echo "PASS: $LABEL is running (every ${INTERVAL}s, plus once at load)."
  echo "Script:   $RUNNER — $RUNNER_SOURCE"
  echo "Checkout: $REPO_DIR"
  echo "PATH:     $JOB_PATH"
  echo "Log:      $LOG_DIR/backfill-review.log (launchd: backfill-review-stdout.log / -stderr.log)"
  echo "One-off run now: $RUNNER --repo-dir \"$REPO_DIR\" --ignore-window"
  echo "Verify with: launchctl list | grep claude-backfill-review"
else
  echo "FAIL: $LABEL did not appear in launchctl list after install." >&2
  echo "      launchctl bootstrap reported success, so the job may still be loaded;" >&2
  echo "      the plist remains at $INSTALLED_PLIST." >&2
  echo "      Check with:  launchctl list | grep claude-backfill-review" >&2
  echo "      Remove with: $SCRIPT_DIR/uninstall-backfill-review.sh" >&2
  exit 1
fi
