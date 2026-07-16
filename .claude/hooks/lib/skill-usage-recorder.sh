#!/bin/bash
# Shared skill-usage recorder — sourced by hooks, never executed directly.
#
# Single authoritative writer for skill telemetry (#584). Both capture paths
# funnel through record_skill_usage():
#   - skill-usage-tracker.sh   (PostToolUse, matcher Skill) -> source "posttool"
#   - skill-command-tracker.sh (UserPromptSubmit)           -> source "userprompt"
#
# Storage model — everything lives under ~/.claude/. NEVER write telemetry into
# the skills worktree: session-start-sync.sh can `git reset --hard` it away.
#   - ~/.claude/skill-usage.log — append-only, one tab-separated line per
#     invocation: ISO8601 UTC \t skill_name \t session_id. Read by
#     skill-usage-report.sh (#416); the line format is a contract.
#   - ~/.claude/skill-usage.csv — aggregated use_count / last_used.
#   - ~/.claude/skills-worktree/.claude/skill-usage.csv — git-tracked seed used
#     to bootstrap the live CSV on first run.
#   - ~/.claude/.skill-usage-pending/<session>__<skill> — dedupe marker holding
#     the epoch seconds at which a user-typed invocation was recorded.
#
# Exactly-once dedupe: a user-typed slash command reaches the model already
# expanded into the prompt and produces no Skill tool call, so on current builds
# the two paths never both fire for one invocation. The marker makes that hold
# by construction on any surface that emits both: the UserPromptSubmit detector
# records and then drops a marker; a PostToolUse call for the same
# session + skill consumes a fresh marker and skips its own line. Consume-once
# plus the freshness bound cap both failure modes at a single line.
#
# Every function is best-effort and returns 0 — telemetry must never break a
# hook, and both callers are non-blocking.

SKILL_USAGE_LOG="${HOME}/.claude/skill-usage.log"
SKILL_USAGE_CSV="${HOME}/.claude/skill-usage.csv"
SKILL_USAGE_SEED_CSV="${HOME}/.claude/skills-worktree/.claude/skill-usage.csv"
SKILL_USAGE_MARKER_DIR="${HOME}/.claude/.skill-usage-pending"

# How long a marker may suppress a PostToolUse line. The marker exists only to
# cover a *future* build emitting a Skill call for the same turn as a typed
# command — that would happen within the same turn (seconds), not minutes
# later. Kept short so a genuinely separate later Skill call for the same
# skill + session (e.g. the user asks to re-run it) is never misattributed as
# the earlier typed invocation (#592 CodeAnt review).
SKILL_USAGE_MARKER_TTL=30
# Orphaned markers (typed command that never produced a Skill call — the normal
# case today) are swept after this many minutes.
SKILL_USAGE_MARKER_PRUNE_MIN=60

# Reduce an untrusted string to characters that are safe in a filename.
_skill_usage_sanitize_component() {
  local raw="${1:-}"
  printf '%s' "${raw//[^[:alnum:]_.-]/_}"
}

# Resolve the session id the same way for both paths: payload value, else the
# ambient session env var, else "unknown".
skill_usage_resolve_session() {
  local session="${1:-}"
  session="${session:-${CLAUDE_SESSION_ID:-}}"
  session="$(_skill_usage_sanitize_component "$session")"
  printf '%s' "${session:-unknown}"
}

# Reject names that would corrupt the CSV, the tab-separated log, or escape
# the marker directory.
_skill_usage_valid_skill() {
  case "${1:-}" in
    '') return 1 ;;
    *,*|*'"'*|*/*) return 1 ;;
    *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
  return 0
}

# Deliberately one marker per session + skill, not one per invocation. Typing
# the same command twice just refreshes it, which stays correct: each typed
# invocation logs as it happens, and the marker only ever suppresses the next
# Skill call for that same skill. Counting pending invocations would only matter
# on a surface that emits both paths AND lets a second prompt arrive before the
# first one's Skill call — no such surface exists.
_skill_usage_marker_path() {
  local session skill
  session="$(_skill_usage_sanitize_component "${1:-}")"
  skill="$(_skill_usage_sanitize_component "${2:-}")"
  printf '%s/%s__%s' "$SKILL_USAGE_MARKER_DIR" "${session:-unknown}" "$skill"
}

# Record that a user-typed invocation was just logged, so a Skill call for the
# same session + skill can recognize itself as the same logical invocation.
_skill_usage_mark_pending() {
  local marker tmp
  marker="$(_skill_usage_marker_path "${1:-}" "${2:-}")"
  mkdir -p "$SKILL_USAGE_MARKER_DIR" 2>/dev/null || return 0
  tmp="${marker}.tmp.$$"
  # Write-then-rename so a concurrent consumer can never read a partial marker.
  # Grouped redirect: see _skill_usage_append_log on silencing open failures.
  if { printf '%s\n' "$(date -u +%s)" >"$tmp"; } 2>/dev/null; then
    mv -f "$tmp" "$marker" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# Claim a pending marker. Returns 0 only when a FRESH marker was consumed,
# meaning the caller must skip recording. A stale or unreadable marker is
# consumed and discarded, and the caller records normally.
_skill_usage_consume_marker() {
  local marker tmp epoch now age
  marker="$(_skill_usage_marker_path "${1:-}" "${2:-}")"
  tmp="${marker}.consumed.$$"
  # rename() is atomic: under concurrency exactly one consumer can win, which is
  # what makes the suppression consume-once rather than sticky.
  mv "$marker" "$tmp" 2>/dev/null || return 1
  epoch="$(head -c 32 "$tmp" 2>/dev/null | tr -dc '0-9')"
  rm -f "$tmp" 2>/dev/null || true
  # Only a plausible epoch is trusted. A digit run this side of absurd cannot
  # overflow the arithmetic below, and anything else falls through to "record
  # normally" — the safe direction, since a lost line beats a silent skip.
  case "${#epoch}" in
    9|10|11) ;;
    *) return 1 ;;
  esac
  now="$(date -u +%s)"
  # 10# so a marker written with leading zeros is never read as octal.
  age=$(( now - 10#$epoch ))
  [ "$age" -le "$SKILL_USAGE_MARKER_TTL" ] || return 1
  return 0
}

# Sweep markers left behind by typed commands that never produced a Skill call.
_skill_usage_prune_markers() {
  [ -d "$SKILL_USAGE_MARKER_DIR" ] || return 0
  find "$SKILL_USAGE_MARKER_DIR" -type f -mmin "+${SKILL_USAGE_MARKER_PRUNE_MIN}" -delete 2>/dev/null || true
  return 0
}

# Returns non-zero if the line did not make it to disk, so the caller can avoid
# claiming an invocation it failed to record.
_skill_usage_append_log() {
  local skill="${1:-}" session="${2:-}"
  mkdir -p "$(dirname "$SKILL_USAGE_LOG")" 2>/dev/null || return 1
  # The redirect is wrapped so that a failure to open the log is silenced too —
  # a trailing 2>/dev/null only covers the command's own stderr, not the shell's
  # redirection error, and a hook must never leak to stderr.
  { printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$skill" "$session" >>"$SKILL_USAGE_LOG"; } 2>/dev/null || return 1
  return 0
}

# Serialized bootstrap + update inside a single Python transaction, protected
# by fcntl.flock on a sidecar lock file. Works on macOS + Linux; degrades
# gracefully on platforms without fcntl.
_skill_usage_update_csv() {
  local skill="${1:-}"

  # Ensure the parent directory exists (cheap, idempotent, race-free).
  mkdir -p "$(dirname "$SKILL_USAGE_CSV")" 2>/dev/null || return 0

  python3 - "$SKILL_USAGE_CSV" "$SKILL_USAGE_SEED_CSV" "$skill" <<'PY' 2>/dev/null || true
import csv, os, sys, tempfile
from datetime import datetime
try:
    import zoneinfo
    today = datetime.now(zoneinfo.ZoneInfo("America/New_York")).date().isoformat()
except Exception:
    # Fallback: machine local date (matches audit-skill-usage.sh fallback).
    today = datetime.now().date().isoformat()

csv_path, seed_path, skill = sys.argv[1], sys.argv[2], sys.argv[3]
lock_path = csv_path + ".lock"

# Acquire advisory lock via a sidecar file (works on macOS + Linux).
# Fail closed: if we cannot acquire the exclusive lock, abort without writing.
# Unlocked writes under concurrency could lose increments.
lock_fd = None
try:
    import fcntl
except Exception:
    # Platform has no fcntl (e.g. Windows). Concurrent writes are then
    # theoretically racy, but Skill invocations are rare enough in practice
    # that we proceed without a lock on such platforms.
    fcntl = None

if fcntl is not None:
    try:
        lock_fd = open(lock_path, "w")
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX)
    except Exception:
        # Lock acquisition failed — abort to avoid clobbering concurrent writes.
        if lock_fd is not None:
            try: lock_fd.close()
            except Exception: pass
        sys.exit(0)

def atomic_write(path, header, data):
    dir_ = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".skill-usage.", dir=dir_)
    try:
        with os.fdopen(fd, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(header)
            w.writerows(data)
        os.replace(tmp, path)
    except Exception:
        try: os.unlink(tmp)
        except Exception: pass
        raise

try:
    # BOOTSTRAP (under lock): if the live CSV does not exist, create it
    # from the seed (preferred) or from a bare header. This happens inside
    # the lock so a concurrent invocation cannot clobber our first update.
    if not os.path.exists(csv_path):
        if os.path.exists(seed_path):
            try:
                with open(seed_path, "r", newline="") as sf:
                    seed_rows = list(csv.reader(sf))
            except Exception:
                seed_rows = []
        else:
            seed_rows = []
        if not seed_rows:
            seed_rows = [["skill_name", "start_date", "use_count", "last_used"]]
        try:
            atomic_write(csv_path, seed_rows[0], seed_rows[1:])
        except Exception:
            sys.exit(0)

    # UPDATE (same lock): read the freshly-bootstrapped-or-existing CSV and
    # apply the increment.
    try:
        with open(csv_path, "r", newline="") as f:
            rows = list(csv.reader(f))
    except FileNotFoundError:
        sys.exit(0)
    if not rows:
        sys.exit(0)

    header, data = rows[0], rows[1:]
    found = False
    for row in data:
        if len(row) >= 4 and row[0] == skill:
            try:
                row[2] = str(int(row[2]) + 1)
            except ValueError:
                row[2] = "1"
            row[3] = today
            found = True
            break

    if not found:
        # Skill not in tracker yet — seed it (count=1, start_date=today)
        data.append([skill, today, "1", today])

    try:
        atomic_write(csv_path, header, data)
    except Exception:
        sys.exit(0)
finally:
    if lock_fd is not None:
        try: lock_fd.close()
        except Exception: pass
PY
  return 0
}

# record_skill_usage <skill_name> <session_id> <source>
#   source: "posttool"   — a Skill tool call (model-initiated, chip/agent threads)
#           "userprompt" — a user-typed slash command seen at UserPromptSubmit
#
# Logs one line and increments the CSV, unless this call is the second sighting
# of an invocation already recorded by the other path.
record_skill_usage() {
  local skill="${1:-}" session="${2:-}" source="${3:-posttool}"

  _skill_usage_valid_skill "$skill" || return 0
  session="$(skill_usage_resolve_session "$session")"

  # A marker keyed on an unidentified session is not an identity — it would
  # match any other unidentified session and silently drop that invocation. When
  # the session is unknown, skip dedupe entirely and let both paths record, which
  # is exactly how this behaved before the marker existed.
  local dedupe=1
  [ "$session" = "unknown" ] && dedupe=0

  if [ "$source" = "posttool" ] && [ "$dedupe" = "1" ] &&
     _skill_usage_consume_marker "$session" "$skill"; then
    # The UserPromptSubmit detector already logged this invocation.
    _skill_usage_prune_markers
    return 0
  fi

  local logged=0
  _skill_usage_append_log "$skill" "$session" && logged=1
  _skill_usage_update_csv "$skill"

  # Mark only once the line is on disk. The marker claims "this invocation is
  # already logged", so writing it after a failed append would suppress the Skill
  # call and lose the invocation from both paths. Nothing can slip into the
  # window between the two: UserPromptSubmit runs to completion before the model
  # — and therefore any Skill call — can act on the prompt.
  if [ "$source" = "userprompt" ] && [ "$dedupe" = "1" ] && [ "$logged" = "1" ]; then
    _skill_usage_mark_pending "$session" "$skill"
  fi

  _skill_usage_prune_markers
  return 0
}
