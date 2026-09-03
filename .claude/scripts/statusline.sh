#!/usr/bin/env bash
# statusline.sh — Render the Claude Code status line: ET time · branch · agents · watchers.
#
# Implements FU-3 from .claude/reference/token-efficiency-audit-2026-07.md. A
# status line renders OUTSIDE the model's context window, so everything it shows
# costs zero tokens — unlike a hook injection, which is re-transmitted with every
# later turn. This surfaces the three facts the agent otherwise re-states in prose
# (ET time, branch, how much background work is in flight) for free.
#
# It SUPPLEMENTS, never replaces, CLAUDE.md's timestamp-prefix rule and the
# UserPromptSubmit `timestamp-injector.sh` hook — the model still needs the time
# in context to write the prefix. What shrinks is the human's reliance on reading
# it out of the transcript.
#
# WHERE IT ACTUALLY RENDERS (read before filing a bug):
#   The status-line command runs only inside the interactive terminal TUI — the
#   executor lives in Claude Code's Ink/React render path and its stdout becomes
#   `statusLineText`. A headless session (the Claude desktop app runs
#   `claude --output-format stream-json …`) has no status line, so this script is
#   never invoked there. Evidence and a live probe:
#   .claude/reference/usage-limit-signal-audit-2026-07.md §1. Registering it is
#   still correct — it costs nothing when unused and works in every terminal
#   session — but the token saving only lands where a TUI is rendering.
#
# Usage:
#   statusline.sh          # reads the session JSON Claude Code pipes on stdin
#   statusline.sh --help
#
# Registered via the `statusLine` key in global-settings.json; the placeholder
# path there is resolved to the deployed skills-worktree path by
# .claude/hooks/register-hooks.py (session start) and setup-skills-worktree.sh
# (install), the same way hook paths are.
#
# Input (stdin, optional):
#   The status-line session JSON. Only two fields are read:
#     .workspace.current_dir  — directory to resolve the git branch from
#     .cwd                    — fallback when .workspace is absent
#   Empty, absent, or malformed stdin is NOT an error: the script falls back to
#   its own working directory. stdin is only read when it is not a TTY, so a
#   manual run from a terminal returns immediately instead of blocking on `cat`.
#
# Output (stdout, exactly one line):
#   <ET time> · <branch> [· N agents] [· M watchers] [· ⚠ sync failing] [· ↻ restart]
#
#   e.g. "Sat Aug 1 09:37 PM ET · issue-779-statusline · 2 agents · 1 watcher"
#
#   - ET time uses CLAUDE.md's format: TZ='America/New_York' +'%a %b %-d %I:%M %p ET'
#   - branch is the checked-out branch, or "(detached)" in a repo with no current
#     branch, or "(no repo)" when the directory is not a git working tree
#   - the agent and watcher segments are omitted entirely at zero, and are
#     singularized at one ("1 agent", "1 watcher")
#   - the sync badges appear only while ~/.claude/sync-restart-recommended.json
#     carries the matching portion (issue #1524): "↻ restart" while a scheduled
#     config sync has landed changes a live session cannot pick up, "⚠ sync
#     failing" while the job's failure streak is past its threshold
#
# Counts come from ~/.claude/session-state.json via `session-state.sh
# --session-view`:
#     agents   = .active_agents | length
#     watchers = (.polling_jobs | length)
#              + (.prs[] | select(.babysit.active == true) | count)
#              + (1 when .pmm_active == true)
#   `.pmm_active` is counted because /pr-monitor-and-manage is a real watcher and
#   records itself there rather than in `polling_jobs`, which has been empty by
#   design since issue #827.
#
#   SCOPE, precisely — the two kinds of source differ, and saying only
#   "scoped to the invoking repo" would over-promise:
#     • Per-PR sources (agents, babysitters) ARE repo-scoped. `--session-view`
#       drops entries belonging to another repo, so another checkout's work
#       never appears here.
#     • Session-global sources (`polling_jobs`, `pmm_active`) are NOT, because
#       they are session facts rather than repo facts and pass through
#       `--session-view` unfiltered by design. /pr-monitor-and-manage watches a
#       fleet and records no repo of its own, so there is nothing to filter on;
#       when it is running, it is genuinely running for this session whatever
#       directory the TUI sits in. Counting it is the true reading, and the line
#       is a session status line.
#
#   No network call, no `gh`, no CronList — this renders on a timer, so it reads
#   only the local state file. `--session-view` is a lock-free read.
#
# Exit codes:
#   0 — always. A status line must never break the render, so every failure mode
#       (no stdin, malformed stdin, no git, missing/corrupt session-state.json,
#       missing session-state.sh) degrades to a shorter line instead of an error.
#       --help also exits 0.
#
# NOTE — deliberately NOT logging to $HOME/.claude/script-usage.log, unlike every
# other script here. This one is invoked by a render loop (refreshInterval, plus
# every assistant message), so logging each call would add thousands of lines a
# day and drown the real adherence signal `script-usage-report.sh` computes from
# that file. Telemetry value here is nil — the invocation is automatic, never a
# choice an agent made.
#
# Staying silent here is only half of it: the `session-state.sh --session-view`
# call below logs a line of its own on every invocation, which would move the
# flood one script to the left rather than avoid it. That child call therefore
# runs with CLAUDE_SCRIPT_USAGE_LOG=0 — an opt-out session-state.sh honors for
# render-loop callers only, never by default.

set -uo pipefail

NO_REPO_LABEL="(no repo)"
DETACHED_LABEL="(detached)"

print_usage() {
  awk '
    NR == 1 { next }
    /^# Usage:/ { in_block = 1 }
    in_block && !/^#/ { exit }
    in_block {
      sub(/^# ?/, "")
      print
    }
  ' "$0"
}

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      # An unknown argument must not break the render either — ignore it.
      ;;
  esac
done

# --------------------------------------------------------------------------
# 1. ET time (always shown)
# --------------------------------------------------------------------------
ET_TIME=$(TZ='America/New_York' date +'%a %b %-d %I:%M %p ET' 2>/dev/null)
[[ -z "$ET_TIME" ]] && ET_TIME="ET time unavailable"

# --------------------------------------------------------------------------
# 2. Resolve the working directory from the session JSON
# --------------------------------------------------------------------------
# Only read stdin when something is piped in: a manual `statusline.sh` from a
# terminal would otherwise hang in `cat` waiting for EOF.
SESSION_JSON=""
if [[ ! -t 0 ]]; then
  SESSION_JSON=$(cat 2>/dev/null || true)
fi

WORK_DIR=""
if [[ -n "$SESSION_JSON" ]]; then
  # printf, not echo — echo mangles JSON containing backslash escapes under some
  # shells (repo memory: zsh-echo-jq-json-corruption). Malformed JSON just leaves
  # WORK_DIR empty and falls through to $PWD.
  WORK_DIR=$(printf '%s' "$SESSION_JSON" \
    | jq -r '(.workspace.current_dir // .cwd // "") | tostring' 2>/dev/null) || WORK_DIR=""
fi
if [[ -z "$WORK_DIR" || "$WORK_DIR" == "null" || ! -d "$WORK_DIR" ]]; then
  WORK_DIR="$PWD"
fi

# --------------------------------------------------------------------------
# 3. Branch
# --------------------------------------------------------------------------
# `branch --show-current` (git >= 2.22) also names an unborn branch in a freshly
# initialized repo, where `rev-parse --abbrev-ref HEAD` fails outright. It prints
# nothing on a detached HEAD, which is why the git-dir probe below distinguishes
# "detached inside a repo" from "not a repo at all".
BRANCH=$(git -C "$WORK_DIR" branch --show-current 2>/dev/null) || BRANCH=""
if [[ -z "$BRANCH" ]]; then
  if git -C "$WORK_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    BRANCH="$DETACHED_LABEL"
  else
    BRANCH="$NO_REPO_LABEL"
  fi
fi

# --------------------------------------------------------------------------
# 4. Active agents and watchers from session-state.json
# --------------------------------------------------------------------------
AGENTS=0
WATCHERS=0

SESSION_STATE_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/session-state.sh"
if [[ -x "$SESSION_STATE_SH" ]]; then
  # Run from the session's directory so --session-view resolves the repo scope
  # from that repo's origin remote rather than from wherever the TUI happened to
  # spawn this process.
  #
  # CLAUDE_SESSION_REPO has to be cleared for this one call. session-state.sh
  # resolves scope as --repo > $CLAUDE_SESSION_REPO > cwd origin, so a value
  # inherited from another checkout outranks the `cd` above and pairs THIS
  # repo's branch with ANOTHER repo's counts — one line claiming to describe one
  # repo while sourcing its two halves from two, with nothing on screen to say
  # so. Unsetting inside the command substitution keeps the caller's
  # environment untouched.
  # CLAUDE_SCRIPT_USAGE_LOG=0 for the same reason this script does not log
  # either (see the NOTE in the header): session-state.sh appends one
  # script-usage.log line per call, and a render-loop caller would otherwise
  # move the flood one script to the left rather than avoid it.
  STATE_VIEW=$(
    cd "$WORK_DIR" 2>/dev/null &&
      unset CLAUDE_SESSION_REPO &&
      CLAUDE_SCRIPT_USAGE_LOG=0 "$SESSION_STATE_SH" --session-view 2>/dev/null
  ) || STATE_VIEW=""
  if [[ -n "$STATE_VIEW" ]]; then
    COUNTS=$(printf '%s' "$STATE_VIEW" | jq -r '
      def arrlen($v): if ($v | type) == "array" then ($v | length) else 0 end;
      [
        arrlen(.active_agents),
        ( arrlen(.polling_jobs)
          + ( if (.prs | type) == "object"
              then [ .prs[] | select((type == "object") and (.babysit?.active == true)) ] | length
              else 0 end )
          + ( if .pmm_active == true then 1 else 0 end )
        )
      ] | join(" ")
    ' 2>/dev/null) || COUNTS=""
    if [[ "$COUNTS" =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
      AGENTS="${BASH_REMATCH[1]}"
      WATCHERS="${BASH_REMATCH[2]}"
    fi
  fi
fi

# --------------------------------------------------------------------------
# 5. Config-sync signal badge (issue #1524)
# --------------------------------------------------------------------------
# claude-config-sync.sh writes ~/.claude/sync-restart-recommended.json when a
# scheduled sync lands changes a live session cannot pick up, or when the job has
# been failing repeatedly. The status line is the between-sessions surface for
# both: session-start-sync.sh delivers them into a session's context, but a
# machine sitting idle with a stale config has no session to deliver into.
#
# One cheap local read, no network — same contract as the rest of this script.
# The marker path is defined canonically in claude-config-sync.sh; the three
# spellings of it are held together by
# .claude/scripts/tests/claude-config-sync.test.sh.
SYNC_MARKER="${HOME:-}/.claude/sync-restart-recommended.json"
SYNC_SEGMENTS=()
if [[ -n "${HOME:-}" && -r "$SYNC_MARKER" ]]; then
  while IFS= read -r _badge; do
    [[ -n "$_badge" ]] || continue
    SYNC_SEGMENTS+=("$_badge")
  done < <(jq -r '
    [ (if (.sync_failure // null) != null then "⚠ sync failing" else empty end),
      (if (.restart_recommended // null) != null then "↻ restart" else empty end)
    ] | .[]
  ' "$SYNC_MARKER" 2>/dev/null)
fi

# --------------------------------------------------------------------------
# 6. Emit one line
# --------------------------------------------------------------------------
pluralize() { # count singular-noun -> "N noun" / "N nouns"
  if [[ "$1" -eq 1 ]]; then
    printf '%s %s' "$1" "$2"
  else
    printf '%s %ss' "$1" "$2"
  fi
}

SEGMENTS=("$ET_TIME" "$BRANCH")
[[ "$AGENTS" -gt 0 ]] && SEGMENTS+=("$(pluralize "$AGENTS" agent)")
[[ "$WATCHERS" -gt 0 ]] && SEGMENTS+=("$(pluralize "$WATCHERS" watcher)")
SEGMENTS+=("${SYNC_SEGMENTS[@]+"${SYNC_SEGMENTS[@]}"}")

LINE="${SEGMENTS[0]}"
for ((i = 1; i < ${#SEGMENTS[@]}; i++)); do
  LINE="$LINE · ${SEGMENTS[i]}"
done

printf '%s\n' "$LINE"
exit 0
