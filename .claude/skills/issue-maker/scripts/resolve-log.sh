#!/usr/bin/env bash
# resolve-log.sh — resolve THIS conversation's /issue-maker session log.
#
# Usage: resolve-log.sh [--key] [--quiet]
#
#   (no flags)  print the absolute log path on stdout
#   --key       print the session key alone (no path)
#   --quiet     suppress the stderr notes/warnings (stdout is unaffected)
#
# Notes and warnings always go to stderr, so stdout stays a single clean line a
# caller can capture directly.
#
# WHY THIS EXISTS (issue #1369)
#   SKILL.md used to derive the log name inline from
#   `${CLAUDE_SESSION_ID:-default}`. `CLAUDE_SESSION_ID` does not reach Bash
#   tool subshells, so EVERY concurrent conversation on the machine resolved
#   the same `~/.claude/handoffs/issue-maker-default-log.json` and interleaved
#   writes on it. On 2026-08-26 that produced three distinct corruptions inside
#   one six-minute window: `target_repo` flipped under a live session, a
#   foreign session's issue appearing inside another session's batch, and a
#   batch-wide offer stamp overwriting a foreign row's `chip_task_id`.
#
#   A silent shared `default` key must therefore never happen again.
#
# THE KEY
#   1. `$CLAUDE_SESSION_ID` when set — sanitized to [A-Za-z0-9._-].
#   2. Otherwise a derived `fallback-<digest>` key, minted ONCE per
#      conversation and persisted in a marker file, so every later invocation
#      in the same conversation (compaction recovery included) resolves the
#      SAME log.
#
# CONVERSATION IDENTITY — WHY NOT `$PPID` (measured, 2026-08-26)
#   The obvious fallback is `$PPID` plus cwd. It does not work: the depth of
#   the shell chain between this script and the harness VARIES per invocation.
#   Two Bash tool calls in one conversation measured
#
#       bash < bash < zsh < claude(53630) < …      (call 1)
#       bash < bash < zsh < claude(53630) < …      (call 2)
#
#   where every `bash`/`zsh` pid differed between the calls and only the
#   `claude` pid held still — and a command substitution adds another level
#   again. Keying on `$PPID` would therefore mint a NEW log on nearly every
#   invocation and strand the batch on the first compaction recovery.
#
#   So identity is the nearest ancestor process named `claude` — the CLI
#   process that owns this conversation — plus its start time. It is stable
#   across Bash tool calls and across shell-depth changes, and it differs
#   between concurrent conversations, which are separate `claude` processes.
#   The start time means a recycled pid mints a new key instead of adopting a
#   dead conversation's log.
#
#   `ISSUE_MAKER_CONV_ID` overrides the walk with an explicit identity string.
#   Nothing in the skill sets it; it exists so tests can simulate two distinct
#   conversations without building fake process trees.
#
#   The marker is looked up by the identity digest ALONE, deliberately not by
#   cwd: the Bash tool's cwd can drift between calls, and a key that moved with
#   it would strand a batch mid-session. cwd is folded into the minted digest
#   as extra entropy only — it separates two conversations that somehow share a
#   `claude` process (a subagent working in its own worktree) at mint time,
#   without making later lookups depend on it.
#
#   Markers are ~30 bytes each and are left in place; nothing here deletes
#   files.
#
# FILENAME SHAPE IS LOAD-BEARING
#   `issue-maker-<key>-log.json` under `~/.claude/handoffs/` is globbed by
#   `active-work-cap.sh`, `/wave`, and `/pm`. Those readers never inspect the
#   key segment, so a new key shape is transparent to them — but the
#   `issue-maker-*-log.json` shape itself must not change.
#
# Exit codes:
#   0  Resolved (path or key printed on stdout)
#   2  Usage error
#   4  No SHA-256 tool available — cannot mint a collision-resistant key

set -euo pipefail

MODE=path
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --key)   MODE=key ;;
    --path)  MODE=path ;;
    --quiet) QUIET=1 ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *)
      echo "resolve-log.sh: unknown option: $1" >&2
      echo "Usage: resolve-log.sh [--key] [--quiet]" >&2
      exit 2 ;;
  esac
  shift
done

warn() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

HANDOFF_DIR="$HOME/.claude/handoffs"
MARKER_DIR="$HANDOFF_DIR/.issue-maker-keys"
mkdir -p "$HANDOFF_DIR"

# digest <material> — 20 hex chars. Returns 4 when no SHA-256 tool exists, so
# the caller aborts loudly rather than quietly falling back to a guessable key.
digest() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,20)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,20)}'
  else
    return 4
  fi
}

no_digest_tool() {
  echo "resolve-log.sh: could not compute a SHA-256 digest — shasum or sha256sum must be present and working" >&2
  echo "resolve-log.sh: refusing to fall back to a shared log name (issue #1369)" >&2
  exit 4
}

# conversation_identity — print "claude=<pid>|start=<lstart>" for the nearest
# ancestor process named `claude`, or nothing when there is no such ancestor.
# Walking (rather than reading $PPID) is what makes this survive the varying
# shell depth documented in the header.
conversation_identity() {
  local pid line ppid comm base start depth
  pid="${PPID:-0}"
  depth=0
  while [ "$depth" -lt 24 ]; do
    case "$pid" in ''|0|1) return 0 ;; esac
    line="$(ps -o ppid=,comm= -p "$pid" 2>/dev/null)" || line=""
    [ -n "$line" ] || return 0
    ppid="$(printf '%s' "$line" | awk '{print $1}')"
    # `comm` is a full path on macOS and may contain spaces, so take every
    # field after the first. Only the basename is compared, and the compare is
    # case-sensitive: the desktop app higher in the chain is `Claude`, which is
    # shared across conversations and must never match.
    comm="$(printf '%s' "$line" | awk '{$1=""; sub(/^[ \t]+/, ""); print}')"
    base="${comm##*/}"
    if [ "$base" = "claude" ]; then
      start="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' || true)"
      printf 'claude=%s|start=%s' "$pid" "$start"
      return 0
    fi
    pid="$ppid"
    depth=$((depth + 1))
  done
  return 0
}

SESSION_KEY=""
USED_FALLBACK=0
IDENT_SOURCE=""
MARKER=""

RAW_SID="${CLAUDE_SESSION_ID:-}"
if [ -n "$RAW_SID" ]; then
  # Same sanitize shape the hooks use: anything outside the filesystem-safe set
  # becomes `_`, so a session id can never escape the handoffs directory.
  SESSION_KEY="$(printf '%s' "$RAW_SID" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
fi

# An id made only of separators (e.g. "///") sanitizes to a non-empty but
# meaningless key, so treat a value with no alphanumeric character as absent
# rather than letting two such ids share a log.
case "$SESSION_KEY" in
  *[A-Za-z0-9]*) : ;;
  *) SESSION_KEY="" ;;
esac

if [ -z "$SESSION_KEY" ]; then
  USED_FALLBACK=1

  IDENT="${ISSUE_MAKER_CONV_ID:-}"
  IDENT_SOURCE="override"
  if [ -z "$IDENT" ]; then
    IDENT="$(conversation_identity)"
    IDENT_SOURCE="claude-ancestor"
  fi
  if [ -z "$IDENT" ]; then
    # No `claude` ancestor — not a Claude Code Bash tool call. The parent
    # process is the best remaining identity, but it is only as stable as the
    # caller's own shell, so say so instead of pretending otherwise.
    IDENT="ppid=${PPID:-0}|start=$(ps -o lstart= -p "${PPID:-0}" 2>/dev/null | tr -s ' ' || true)"
    IDENT_SOURCE="parent-process"
  fi

  IDENT_DIGEST="$(digest "$IDENT")" || no_digest_tool
  MARKER="$MARKER_DIR/imk-${IDENT_DIGEST}"

  if [ -r "$MARKER" ]; then
    SESSION_KEY="$(head -n 1 "$MARKER" | tr -d '\r\n')"
  fi

  # A marker that does not hold a well-formed key is treated as absent and
  # re-minted. Reusing a corrupt value would put the batch in an unpredictable
  # file — the very failure mode this script exists to remove.
  case "$SESSION_KEY" in
    fallback-[0-9a-f]*) : ;;
    *) SESSION_KEY="" ;;
  esac

  if [ -z "$SESSION_KEY" ]; then
    CWD="$(pwd -P 2>/dev/null || printf '%s' "${PWD:-}")"
    KEY_DIGEST="$(digest "${IDENT}|cwd=${CWD}")" || no_digest_tool
    SESSION_KEY="fallback-${KEY_DIGEST}"

    mkdir -p "$MARKER_DIR"

    # Publish the marker with an EXCLUSIVE create (noclobber gives the redirect
    # O_EXCL), never a plain overwrite. Two invocations of one conversation can
    # both reach this block — the parent and a subagent it spawned share the
    # `claude` ancestor that IS the identity — and cwd is folded into the minted
    # digest, so their keys genuinely differ. An overwriting publish would leave
    # each racer on the key it minted and future calls on whichever landed last:
    # one conversation split across two logs, which is #1369 in miniature.
    # So the first writer wins and every loser adopts the winning key below.
    if ( set -o noclobber; printf '%s\n' "$SESSION_KEY" > "$MARKER" ) 2>/dev/null; then
      : # We minted it — our key is now this conversation's key.
    else
      WON=""
      if [ -r "$MARKER" ]; then
        WON="$(head -n 1 "$MARKER" | tr -d '\r\n')"
      fi
      case "$WON" in
        fallback-[0-9a-f]*)
          # Lost the race. Adopt the winner so both callers converge on ONE log.
          SESSION_KEY="$WON"
          ;;
        *)
          # The existing marker is unreadable or malformed, so it owns no batch
          # worth protecting. Overwrite it with our well-formed key — the same
          # re-mint the corrupt-marker check above performs.
          printf '%s\n' "$SESSION_KEY" > "$MARKER" 2>/dev/null || true
          ;;
      esac
    fi
  fi
fi

LOG="$HANDOFF_DIR/issue-maker-${SESSION_KEY}-log.json"

if [ "$MODE" = key ]; then
  printf '%s\n' "$SESSION_KEY"
  exit 0
fi

if [ "$USED_FALLBACK" -eq 1 ]; then
  warn "NOTE: CLAUDE_SESSION_ID is unset — /issue-maker derived the per-conversation key '$SESSION_KEY' from $IDENT_SOURCE (marker: $MARKER). This replaces the shared 'default' log that collided across sessions (issue #1369)."
  if [ "$IDENT_SOURCE" = "parent-process" ]; then
    warn "WARN: no 'claude' ancestor process was found, so the key is derived from this shell's parent. It is unique per caller but NOT guaranteed stable across invocations — verify the log path before relying on a recovered batch."
  fi
fi

# Collision backstop — the log exists but records a different session key.
# Reaching this means two conversations resolved the same path, which is the
# #1369 failure itself; say so rather than writing into it silently.
#
# The read status is kept SEPARATE from the value. Folding a failed read into
# an empty session_id would make the three states that matter — "no owner
# recorded", "the file is corrupt", "jq is missing" — indistinguishable, and
# the backstop would go quiet in exactly the cases where ownership is least
# verifiable. An unverifiable log gets a warning of its own instead.
if [ -f "$LOG" ]; then
  if EXISTING_SID="$(jq -r '.session_id // ""' "$LOG" 2>/dev/null)"; then
    if [ -n "$EXISTING_SID" ] && [ "$EXISTING_SID" != "$SESSION_KEY" ]; then
      warn "WARN: $LOG records session_id '$EXISTING_SID' but this conversation resolved '$SESSION_KEY' — another session may be writing to this log. Do NOT run batch-wide writes against it; start a fresh capture thread."
    fi
  else
    warn "WARN: could not read session_id from $LOG — it is unreadable or not valid JSON, or jq is unavailable. Ownership could NOT be verified, so the collision backstop did not run. Inspect the log by hand before any batch-wide write."
  fi
fi

# A pre-#1369 shared log is never adopted automatically: that sharing IS the
# bug. Point at it so a batch captured under the old scheme is not silently
# lost, and let the operator move it across deliberately.
LEGACY_LOG="$HANDOFF_DIR/issue-maker-default-log.json"
if [ "$USED_FALLBACK" -eq 1 ] && [ ! -f "$LOG" ] && [ -f "$LEGACY_LOG" ]; then
  warn "NOTE: a pre-#1369 shared log exists at $LEGACY_LOG. It is NOT adopted automatically — copy across only the entries this conversation owns."
fi

printf '%s\n' "$LOG"
