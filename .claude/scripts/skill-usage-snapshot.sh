#!/usr/bin/env bash
# skill-usage-snapshot.sh — Keep a machine-independent snapshot of the skill
# telemetry (~/.claude/skill-usage.log + .csv) on the repo's dedicated
# `skill-telemetry` branch, and restore from it on a fresh machine.
#
# STORAGE MODEL (issue #572):
#   Live files stay in ~/.claude/ (written by skill-usage-tracker.sh). This
#   script pushes copies of them — plus a manifest.json — to the branch root
#   of `skill-telemetry` via the GitHub contents API (gh api; no local
#   checkout, no worktree, no commits to main). The Stop hook
#   skill-usage-snapshot-hook.sh backgrounds `--push --quiet` at most once
#   per SNAPSHOT_INTERVAL_DAYS, so no single laptop is ever the only copy.
#
# USAGE:
#   skill-usage-snapshot.sh --push [--force] [--quiet]
#   skill-usage-snapshot.sh --restore [--from <dir>]
#   skill-usage-snapshot.sh --status
#   skill-usage-snapshot.sh --help
#
#   --push     Snapshot the live files to the skill-telemetry branch.
#              Throttled to once per SNAPSHOT_INTERVAL_DAYS (default 7) via
#              ~/.claude/skill-usage-snapshot-state.json; --force bypasses
#              the throttle. State advances only on a confirmed push (or on
#              a verified no-change), so an offline attempt simply retries
#              on a later Stop. --quiet swallows all output AND all errors
#              (exit 0) — the background-hook contract.
#   --restore  Fetch the snapshot files and merge them into the live files
#              via skill-usage-merge.sh --csv-counts recompute (idempotent,
#              overlap-safe; on a fresh machine it degrades to a copy).
#              --from <dir> skips the fetch and restores from an already-
#              downloaded directory (testing / manual escape hatch).
#   --status   Show last push time, throttle state, and local vs remote
#              line counts (remote is best-effort).
#
# CONCURRENCY: a mkdir lock (~/.claude/skill-usage-snapshot.lock) serializes
#   pushes across concurrent sessions; a lock older than 15 minutes is
#   presumed stale (crashed pusher) and stolen. macOS ships no flock(1), so
#   mkdir is the portable atomic primitive here.
#
# NO-CHANGE PUSHES: file blobs are compared via `git hash-object` against the
#   branch's blob SHAs; when nothing changed, no commit is created and the
#   throttle state still advances (an idle week produces zero branch noise).
#
# TESTING OVERRIDES (env): SKILL_TELEMETRY_BRANCH (default skill-telemetry),
#   SNAPSHOT_INTERVAL_DAYS (default 7).
#
# EXIT STATUS:
#   0  success, throttled no-op, or --quiet swallowing a failure
#   2  usage error
#   3  environment error (no git/gh/python3, cannot resolve repo)
#   4  push/restore failure (without --quiet)

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

print_help() {
  awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

usage_error() {
  echo "skill-usage-snapshot.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

MODE=""
FORCE=0
QUIET=0
FROM_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --push|--restore|--status)
      [[ -n "$MODE" ]] && usage_error "--push/--restore/--status are mutually exclusive"
      MODE="${1#--}"
      shift
      ;;
    --force) FORCE=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --from)
      [[ $# -ge 2 ]] || usage_error "--from requires a directory"
      FROM_DIR="$2"
      shift 2
      ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done

[[ -z "$MODE" ]] && usage_error "one of --push / --restore / --status is required"
[[ "$FORCE" == 1 && "$MODE" != "push" ]] && usage_error "--force only applies to --push"
[[ -n "$FROM_DIR" && "$MODE" != "restore" ]] && usage_error "--from only applies to --restore"

say() { [[ "$QUIET" == 1 ]] || echo "$@"; }
warn() { [[ "$QUIET" == 1 ]] || echo "$@" >&2; }
# Failure exit honoring the --quiet background contract (swallow, exit 0).
die_soft() {
  warn "skill-usage-snapshot: $1"
  [[ "$QUIET" == 1 ]] && exit 0
  exit 4
}

BRANCH="${SKILL_TELEMETRY_BRANCH:-skill-telemetry}"
INTERVAL_DAYS="${SNAPSHOT_INTERVAL_DAYS:-7}"
if ! [[ "$INTERVAL_DAYS" =~ ^[0-9]+$ ]] || (( INTERVAL_DAYS < 1 )); then
  usage_error "SNAPSHOT_INTERVAL_DAYS must be a positive integer (got: $INTERVAL_DAYS)"
fi
INTERVAL_SECS=$(( INTERVAL_DAYS * 86400 ))

LIVE_LOG="$HOME/.claude/skill-usage.log"
LIVE_CSV="$HOME/.claude/skill-usage.csv"
STATE_FILE="$HOME/.claude/skill-usage-snapshot-state.json"
LOCK_DIR="$HOME/.claude/skill-usage-snapshot.lock"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cleanup state is global: traps fire in top-level context after functions
# have returned, so function-locals would be gone by then.
STAGING=""
FETCH_DIR=""
HOLDING_LOCK=0
cleanup() {
  [[ -n "$STAGING" ]] && rm -rf "$STAGING"
  [[ -n "$FETCH_DIR" ]] && rm -rf "$FETCH_DIR"
  (( HOLDING_LOCK == 1 )) && rmdir "$LOCK_DIR" 2>/dev/null
  return 0
}
trap cleanup EXIT

for tool in git gh python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    [[ "$QUIET" == 1 ]] && exit 0
    echo "error: $tool not found" >&2
    exit 3
  fi
done

# Resolve owner/repo from the checkout containing this script — works no
# matter what cwd the (possibly backgrounded) caller had.
resolve_repo() {
  local url
  url="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null)" || return 1
  url="${url%.git}"
  case "$url" in
    git@*:*) printf '%s\n' "${url#*:}" ;;
    http://*|https://*|ssh://*)
      url="${url#*://}"          # host/owner/repo (drop scheme)
      url="${url#*@}"            # drop user@ if present
      printf '%s\n' "${url#*/}"  # drop host
      ;;
    *) return 1 ;;
  esac
}

OWNER_REPO="$(resolve_repo)" || true
if [[ -z "${OWNER_REPO:-}" || "$OWNER_REPO" != */* ]]; then
  [[ "$QUIET" == 1 ]] && exit 0
  echo "error: cannot resolve owner/repo from $SCRIPT_DIR's origin remote" >&2
  exit 3
fi

now_epoch() { date +%s; }
now_utc() { date -u +%FT%TZ; }

state_get_epoch() {
  # Best-effort read of last_push_epoch; 0 when missing/garbled.
  [[ -f "$STATE_FILE" ]] || { echo 0; return; }
  local v
  v="$(sed -n 's/.*"last_push_epoch"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$STATE_FILE" | head -1)"
  echo "${v:-0}"
}

write_state() {
  # write_state <result> <log_lines> <csv_rows>
  local tmp
  tmp="$(mktemp "$STATE_FILE.XXXXXX")" || return 1
  printf '{\n  "schema_version": 1,\n  "last_push_epoch": %s,\n  "last_push_at": "%s",\n  "last_result": "%s",\n  "branch": "%s",\n  "repo": "%s",\n  "hostname": "%s",\n  "log_lines": %s,\n  "csv_rows": %s\n}\n' \
    "$(now_epoch)" "$(now_utc)" "$1" "$BRANCH" "$OWNER_REPO" "$(hostname -s 2>/dev/null || echo unknown)" "$2" "$3" > "$tmp" \
    && mv "$tmp" "$STATE_FILE"
}

count_lines() {
  if [[ -f "$1" ]]; then wc -l < "$1" | tr -d ' '; else echo 0; fi
}

count_csv_rows() {
  # Data rows only — the header line is not a skill row.
  local n
  n="$(count_lines "$1")"
  if (( n > 0 )); then echo $(( n - 1 )); else echo 0; fi
}

# gh api wrapper. Exit codes: 0 success (body on stdout), 44 HTTP 404
# (missing object — actionable), 1 anything else (offline, auth, 5xx —
# skip this cycle). Exit codes survive command substitution, unlike
# variables set inside the $() subshell.
gh_api() {
  local err out rc
  err="$(mktemp)" || return 1
  if out="$(gh api "$@" 2>"$err")"; then
    rm -f "$err"
    printf '%s\n' "$out"
    return 0
  fi
  rc=1
  grep -q "HTTP 404" "$err" && rc=44
  rm -f "$err"
  return "$rc"
}

ensure_branch() {
  local rc default_branch base_sha
  gh_api "repos/$OWNER_REPO/git/ref/heads/$BRANCH" >/dev/null
  rc=$?
  (( rc == 0 )) && return 0
  (( rc == 44 )) || return 1   # network/auth trouble — not ours to fix
  default_branch="$(gh_api "repos/$OWNER_REPO" --jq .default_branch)" || return 1
  [[ -n "$default_branch" ]] || default_branch="main"
  base_sha="$(gh_api "repos/$OWNER_REPO/git/ref/heads/$default_branch" --jq .object.sha)" || return 1
  say "creating branch $BRANCH from $default_branch @ ${base_sha:0:7}"
  gh_api -X POST "repos/$OWNER_REPO/git/refs" \
    -f ref="refs/heads/$BRANCH" -f sha="$base_sha" >/dev/null
}

remote_blob_sha() {
  # remote_blob_sha <path> — prints the blob SHA, or "" when the file does
  # not exist on the branch (404). Returns 1 only on non-404 failure.
  local sha rc
  sha="$(gh_api "repos/$OWNER_REPO/contents/$1?ref=$BRANCH" --jq .sha)"
  rc=$?
  if (( rc == 0 )); then
    printf '%s\n' "$sha"
    return 0
  fi
  if (( rc == 44 )); then
    echo ""
    return 0
  fi
  return 1
}

put_file() {
  # put_file <local-file> <repo-path> <message> <remote-sha-or-empty>
  local local_file="$1" repo_path="$2" message="$3" remote_sha="$4"
  # JSON body built in python: no shell argv limits as the log grows, and
  # base64 handled without BSD/GNU flag differences.
  python3 - "$local_file" "$message" "$BRANCH" "$remote_sha" <<'PY' | gh_api -X PUT "repos/$OWNER_REPO/contents/$repo_path" --input - >/dev/null || return 1
import base64, json, sys
path, message, branch, sha = sys.argv[1:5]
with open(path, "rb") as fh:
    content = base64.b64encode(fh.read()).decode("ascii")
body = {"message": message, "content": content, "branch": branch}
if sha:
    body["sha"] = sha
print(json.dumps(body))
PY
  say "pushed: $repo_path"
}

# sync_file <staged-file> <repo-path> <message>
# Pushes the staged file unless the branch already has identical content.
# Verdict lands in SYNC_RESULT (changed|unchanged) — a global, not stdout,
# so put_file's progress output is not swallowed by command substitution.
# Returns 1 on failure. Must be called from the main shell, not a subshell.
SYNC_RESULT=""
sync_file() {
  local staged="$1" repo_path="$2" message="$3" remote_sha local_sha
  SYNC_RESULT=""
  remote_sha="$(remote_blob_sha "$repo_path")" || return 1
  local_sha="$(git hash-object "$staged" 2>/dev/null)" || local_sha=""
  if [[ -n "$local_sha" && "$local_sha" == "$remote_sha" ]]; then
    say "unchanged: $repo_path"
    SYNC_RESULT="unchanged"
    return 0
  fi
  put_file "$staged" "$repo_path" "$message" "$remote_sha" || return 1
  SYNC_RESULT="changed"
}

do_push() {
  # Cheap throttle check (authoritative re-check happens under the lock).
  local last now
  last="$(state_get_epoch)"
  now="$(now_epoch)"
  if (( FORCE == 0 )) && (( now - last < INTERVAL_SECS )); then
    say "throttled: last push $(( (now - last) / 86400 ))d ago (< ${INTERVAL_DAYS}d); use --force to override"
    return 0
  fi

  if [[ ! -f "$LIVE_LOG" && ! -f "$LIVE_CSV" ]]; then
    say "nothing to push: no live telemetry files yet"
    return 0
  fi

  # Serialize concurrent pushers; steal locks older than 15 minutes. The
  # steal renames the stale dir first — mv is atomic, so exactly one
  # contender wins it and a freshly re-created lock can never be removed
  # by a racing second stealer.
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +15 2>/dev/null)" ]]; then
      if mv "$LOCK_DIR" "$LOCK_DIR.stale.$$" 2>/dev/null; then
        rmdir "$LOCK_DIR.stale.$$" 2>/dev/null || true
        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
          say "another push holds the lock"
          return 0
        fi
      else
        say "another push is stealing the lock"
        return 0
      fi
    else
      say "another push is in flight"
      return 0
    fi
  fi
  HOLDING_LOCK=1

  # Re-check throttle under the lock (a concurrent pusher may have just won).
  last="$(state_get_epoch)"
  now="$(now_epoch)"
  if (( FORCE == 0 )) && (( now - last < INTERVAL_SECS )); then
    say "throttled: a concurrent push just completed"
    return 0
  fi

  # Copy to a staging dir so all three PUTs describe one moment in time. The
  # tracker's log append (>>) is unlocked — a torn final line here is
  # possible but self-heals on the next push.
  STAGING="$(mktemp -d)" || die_soft "mktemp failed"
  local log_lines=0 csv_rows=0
  if [[ -f "$LIVE_LOG" ]]; then
    cp "$LIVE_LOG" "$STAGING/skill-usage.log" || die_soft "cp log failed"
    log_lines="$(count_lines "$STAGING/skill-usage.log")"
  fi
  if [[ -f "$LIVE_CSV" ]]; then
    cp "$LIVE_CSV" "$STAGING/skill-usage.csv" || die_soft "cp csv failed"
    csv_rows="$(count_csv_rows "$STAGING/skill-usage.csv")"
  fi

  ensure_branch || die_soft "cannot reach GitHub (offline?) — will retry on a later Stop"

  local stamp msg pushed_any=0
  stamp="$(now_utc)"
  msg="telemetry: snapshot $stamp from $(hostname -s 2>/dev/null || echo unknown) [skip ci]"

  if [[ -f "$STAGING/skill-usage.log" ]]; then
    sync_file "$STAGING/skill-usage.log" "skill-usage.log" "$msg" \
      || die_soft "push of skill-usage.log failed"
    [[ "$SYNC_RESULT" == "changed" ]] && pushed_any=1
  fi
  if [[ -f "$STAGING/skill-usage.csv" ]]; then
    sync_file "$STAGING/skill-usage.csv" "skill-usage.csv" "$msg" \
      || die_soft "push of skill-usage.csv failed"
    [[ "$SYNC_RESULT" == "changed" ]] && pushed_any=1
  fi

  if (( pushed_any == 1 )); then
    printf '{\n  "schema_version": 1,\n  "pushed_at": "%s",\n  "hostname": "%s",\n  "log_lines": %s,\n  "csv_rows": %s\n}\n' \
      "$stamp" "$(hostname -s 2>/dev/null || echo unknown)" "$log_lines" "$csv_rows" > "$STAGING/manifest.json"
    local msha
    msha="$(remote_blob_sha "manifest.json")" || die_soft "contents lookup failed"
    put_file "$STAGING/manifest.json" "manifest.json" "$msg" "$msha" \
      || die_soft "push of manifest.json failed"
    write_state "pushed" "$log_lines" "$csv_rows" || die_soft "state write failed"
    say "snapshot pushed to $OWNER_REPO@$BRANCH ($log_lines log line(s), $csv_rows csv row(s))"
  else
    # Verified no-change: advance the throttle without creating a commit.
    write_state "unchanged" "$log_lines" "$csv_rows" || die_soft "state write failed"
    say "snapshot already current on $OWNER_REPO@$BRANCH — no commit created"
  fi
}

fetch_file() {
  # fetch_file <repo-path> <dest> — raw media type avoids base64 handling.
  # Exit: 0 fetched, 44 file not on the branch (404 — legitimately skippable),
  # 1 anything else (offline/auth/5xx — the caller must ABORT, not treat the
  # file as absent, or a transient failure silently restores partial state).
  local err rc
  err="$(mktemp)" || return 1
  if gh api -H "Accept: application/vnd.github.raw" \
      "repos/$OWNER_REPO/contents/$1?ref=$BRANCH" > "$2" 2>"$err"; then
    rm -f "$err"
    return 0
  fi
  rc=1
  grep -q "HTTP 404" "$err" && rc=44
  rm -f "$err"
  rm -f "$2"   # gh writes the JSON error body to stdout — never keep it
  return "$rc"
}

do_restore() {
  local src="$FROM_DIR" rc
  if [[ -n "$src" ]]; then
    if [[ ! -d "$src" ]]; then
      echo "error: --from dir not found: $src" >&2
      exit 3
    fi
  else
    FETCH_DIR="$(mktemp -d)" || die_soft "mktemp failed"
    src="$FETCH_DIR"
    say "fetching snapshot from $OWNER_REPO@$BRANCH ..."
    fetch_file "skill-usage.log" "$src/skill-usage.log"
    rc=$?
    (( rc == 1 )) && die_soft "fetch of skill-usage.log failed (offline?) — aborting restore"
    fetch_file "skill-usage.csv" "$src/skill-usage.csv"
    rc=$?
    (( rc == 1 )) && die_soft "fetch of skill-usage.csv failed (offline?) — aborting restore"
  fi

  local args=()
  [[ -s "$src/skill-usage.log" ]] && args+=(--log "$src/skill-usage.log")
  [[ -s "$src/skill-usage.csv" ]] && args+=(--csv "$src/skill-usage.csv")
  if (( ${#args[@]} == 0 )); then
    die_soft "no snapshot files found on $OWNER_REPO@$BRANCH — nothing to restore"
  fi
  bash "$SCRIPT_DIR/skill-usage-merge.sh" "${args[@]}" --csv-counts recompute \
    || die_soft "merge step failed"
  say "restore complete — run skill-usage-report.sh to verify the window"
}

do_status() {
  echo "repo:   $OWNER_REPO"
  echo "branch: $BRANCH"
  echo "interval: ${INTERVAL_DAYS}d"
  if [[ -f "$STATE_FILE" ]]; then
    echo "state ($STATE_FILE):"
    sed 's/^/  /' "$STATE_FILE"
    local last now due
    last="$(state_get_epoch)"
    now="$(now_epoch)"
    due=$(( last + INTERVAL_SECS ))
    if (( now >= due )); then
      echo "next push: due now (on next Stop hook)"
    else
      echo "next push: in $(( (due - now) / 86400 ))d $(( ((due - now) % 86400) / 3600 ))h"
    fi
  else
    echo "state: none — no push has succeeded yet (first due Stop hook will push)"
  fi
  echo "local:  $(count_lines "$LIVE_LOG") log line(s), $(count_csv_rows "$LIVE_CSV") csv row(s)"
  local manifest
  if manifest="$(gh api -H "Accept: application/vnd.github.raw" \
      "repos/$OWNER_REPO/contents/manifest.json?ref=$BRANCH" 2>/dev/null)"; then
    echo "remote manifest:"
    printf '%s\n' "$manifest" | sed 's/^/  /'
  else
    echo "remote manifest: unavailable (no snapshot yet, or offline)"
  fi
}

case "$MODE" in
  push) do_push ;;
  restore) do_restore ;;
  status) do_status ;;
esac
