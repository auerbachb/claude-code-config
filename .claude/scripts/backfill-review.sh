#!/usr/bin/env bash
# backfill-review.sh — overnight backfill review of PRs merged without an AI review (issue #1900).
# catalog: merge-gate-sequencing — Review merges logged by the no-review override with the FREE local CLIs only, file deduped issues for real bugs, mark each ledger row reviewed
#
# USAGE
#   backfill-review.sh [--repo-dir DIR] [--window HH:MM-HH:MM] [--tz ZONE]
#                      [--now ISO8601] [--ignore-window] [--channels LIST]
#                      [--max-reviews N] [--timeout SEC] [--dry-run]
#   backfill-review.sh --range [--from SHA] [--default-days N]
#                      [--range-bound N] [same options]   (range mode, issue #2324)
#   backfill-review.sh --help
#
# WHAT IT DOES
#   Reads `unreviewed-merge-ledger.sh list --pending` for the repo checked out
#   at --repo-dir (rows the no-review override logged), oldest merge first.
#   For each row it reviews the MERGED diff — merge commit vs its first parent —
#   in a throwaway detached worktree (git hooks disabled), with the local
#   CodeRabbit / CodeAnt CLIs through local-review.sh. Real bugs (severity
#   major/critical, or a CodeAnt bug/security label) still present on the
#   pinned origin/main are filed through issue-file.sh after an exact-marker
#   lookup and an issue-dedup.sh pass, each linked to the source PR. The row
#   then gets backfill_status reviewed-clean | issues-filed | skipped, a
#   `backfill` detail object, and the PR label merged-unreviewed is swapped
#   for backfill-reviewed. Mechanism: .claude/reference/backfill-review.md
#
# FREE REVIEWERS ONLY
#   The channel allowlist is hard-coded: coderabbit-cli, codeant-cli (local
#   CLIs on their own free quotas). --channels / BACKFILL_REVIEW_CHANNELS can
#   only narrow it. The script never comments on a PR and never posts a review
#   trigger, so BugBot, Greptile, and CodeRabbit on-demand reviews are
#   unreachable from here. Its only PR write is the label swap.
#
# FAIL CLOSED
#   Any review that is not a verified run (local-review.sh exit 3/4/5: error,
#   cap, rate limit, hang, not installed) drops that channel for the rest of
#   the run; when no channel is left the run stops. A failed origin/main
#   fetch, an unparseable capture, a failed or truncated marker lookup, a dedup lookup
#   error (issue-dedup.sh exit 4), or a failed issue create leaves the row
#   pending. Only a completed review marks a row reviewed. A row that fails
#   after its review ran counts an attempt; pending rows run fewest-attempts
#   first, and a row that reaches --max-row-attempts is skipped (never marked
#   reviewed), so one bad row cannot spend every run's review budget.
#
# OPTIONS
#   --repo-dir DIR     git checkout of the repo to backfill (default: cwd)
#   --repo owner/name  ledger repo key (default: derived from the origin URL;
#                      must match a GitHub origin, else exit 2)
#   --window W         quiet window, local time (default BACKFILL_REVIEW_WINDOW
#                      or 01:00-06:00; may cross midnight)
#   --tz ZONE          window time zone (default BACKFILL_REVIEW_TZ or
#                      America/New_York)
#   --now ISO8601      the run's starting instant for window checks (tests);
#                      later checks advance it by the run's elapsed time
#   --ignore-window    run now, whatever the time (a manual run)
#   --channels LIST    comma list from {coderabbit,codeant}, in try order
#                      (default BACKFILL_REVIEW_CHANNELS or coderabbit,codeant)
#   --max-reviews N    stop after N CLI review attempts this run (default 3 —
#                      the CodeRabbit CLI's hourly allowance)
#   --timeout SEC      local-review.sh idle bound per review (default 900)
#   --max-row-attempts N  failed post-review attempts before a row is skipped
#                      (default BACKFILL_MAX_ROW_ATTEMPTS or 3)
#   --dry-run          list what would be reviewed; review, file, label nothing
#
# RANGE MODE (--range, issue #2324)
#   Walks origin/main from a persisted "last reviewed commit" marker
#   (~/.claude/backfill-range-marker.json, override BACKFILL_RANGE_MARKER)
#   in stretches bounded by distinct changed-file count per reviewer
#   (CodeAnt 15, CodeRabbit 150; see the reference doc). Each stretch is one
#   committed-range review; the marker advances only after a verified run
#   whose findings were parsed and filed. Free reviewers only; no PR is
#   opened, labelled or commented on, and the per-PR ledger is not read.
#   --from SHA sets the start on a first run (no marker yet); without it the
#   start is the parent of the oldest first-parent commit within
#   --default-days (default 14, env BACKFILL_RANGE_DEFAULT_DAYS).
#   --range-bound N (env BACKFILL_RANGE_BOUND) lowers both file bounds.
#   A single commit over EVERY channel's hard cap (150 files) is never sent to
#   a reviewer: it is recorded in the marker's repos[<repo>].uncovered list and
#   the marker moves past it in the same atomic write. That is the only case
#   where the marker passes code no reviewer saw; a lowered bound yields
#   `partial` (some reviewer saw it), never `uncovered`.
#   Reference: .claude/reference/backfill-review.md §Range mode
#
# ENVIRONMENT
#   BACKFILL_CODERABBIT_BIN / BACKFILL_CODEANT_BIN  CLI override passed to
#   local-review.sh --bin (tests point these at stubs).
#   BACKFILL_MARKER_LOOKUP_LIMIT  issue-listing cap for the marker lookup
#   (default 5000); a listing that fills it is treated as a lookup failure.
#
# OUTPUT  One summary line on stdout:
#   backfill-review: reviewed=N clean=N issues_filed=N skipped=N pending_left=N stop=<reason>
#   stop is one of: done, window_closed, outside_window, lock_held,
#   capacity_exhausted, max_reviews, dry_run, main_fetch_failed.
#   Detail log: ~/.claude/logs/backfill-review.log
#
# SCHEDULING  Run it on a timer outside any Claude session (launchd on macOS);
#   it exits 0 at once outside the window, so a 30-minute StartInterval is
#   safe. Setup: .claude/reference/backfill-review.md §Scheduling.
#
# EXIT CODES
#   0 completed (including a capacity stop, a closed window, a held lock,
#     and every range-mode stop reason other than the two below)
#   2 usage · 3 a required tool or helper is missing · 4 ledger unreadable
#   5 range mode internal fault (git enumeration or marker write failed)
#   6 range mode refused the marker (unreadable, malformed, unknown commit,
#     or not an ancestor of origin/main); the marker is left untouched

set -uo pipefail

printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  2>/dev/null >> "$HOME/.claude/script-usage.log" || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWED_CHANNELS="coderabbit codeant"
MARKER_LOOKUP_LIMIT="${BACKFILL_MARKER_LOOKUP_LIMIT:-5000}"
[[ "$MARKER_LOOKUP_LIMIT" =~ ^[1-9][0-9]*$ ]] || MARKER_LOOKUP_LIMIT=5000
FROM_LABEL="merged-unreviewed"
TO_LABEL="backfill-reviewed"

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { local rc="$1"; shift; echo "backfill-review.sh: $*" >&2; exit "$rc"; }

REPO_DIR="$PWD"
REPO=""
WINDOW="${BACKFILL_REVIEW_WINDOW:-01:00-06:00}"
TZONE="${BACKFILL_REVIEW_TZ:-America/New_York}"
NOW_ARG=""
IGNORE_WINDOW=0
CHANNELS_RAW="${BACKFILL_REVIEW_CHANNELS:-coderabbit,codeant}"
MAX_REVIEWS=3
REVIEW_TIMEOUT=900
MAX_ROW_ATTEMPTS="${BACKFILL_MAX_ROW_ATTEMPTS:-3}"
DRY_RUN=0
# Range mode (issue #2324). Bounds are changed distinct files per review:
# CodeAnt CLI skips files past 15 and reports them clean (local-review-cli-
# failure-modes.md "The 15-file cap"); CodeRabbit CLI is 150 files/review
# (pricing-matrix.md, CLI row). Overridable only downward.
RANGE_BOUND_CODEANT=15
RANGE_BOUND_CODERABBIT=150
RANGE_MODE=0
FROM_SHA=""
RANGE_DEFAULT_DAYS="${BACKFILL_RANGE_DEFAULT_DAYS:-14}"
RANGE_BOUND_OVERRIDE="${BACKFILL_RANGE_BOUND:-}"
RANGE_MARKER="${BACKFILL_RANGE_MARKER:-$HOME/.claude/backfill-range-marker.json}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir) REPO_DIR="${2:-}"; [[ -n "$REPO_DIR" ]] || die 2 "--repo-dir needs a value"; shift 2 ;;
    --repo) REPO="${2:-}"; [[ -n "$REPO" ]] || die 2 "--repo needs a value"; shift 2 ;;
    --window) WINDOW="${2:-}"; [[ -n "$WINDOW" ]] || die 2 "--window needs a value"; shift 2 ;;
    --tz) TZONE="${2:-}"; [[ -n "$TZONE" ]] || die 2 "--tz needs a value"; shift 2 ;;
    --now) NOW_ARG="${2:-}"; [[ -n "$NOW_ARG" ]] || die 2 "--now needs a value"; shift 2 ;;
    --ignore-window) IGNORE_WINDOW=1; shift ;;
    --channels) CHANNELS_RAW="${2:-}"; [[ -n "$CHANNELS_RAW" ]] || die 2 "--channels needs a value"; shift 2 ;;
    --max-reviews) MAX_REVIEWS="${2:-}"; [[ "$MAX_REVIEWS" =~ ^[0-9]+$ ]] || die 2 "--max-reviews needs an integer"; shift 2 ;;
    --timeout) REVIEW_TIMEOUT="${2:-}"; [[ "$REVIEW_TIMEOUT" =~ ^[0-9]+$ ]] || die 2 "--timeout needs an integer"; shift 2 ;;
    --max-row-attempts) MAX_ROW_ATTEMPTS="${2:-}"; [[ -n "$MAX_ROW_ATTEMPTS" ]] || die 2 "--max-row-attempts needs a value"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --range) RANGE_MODE=1; shift ;;
    --from) FROM_SHA="${2:-}"; [[ -n "$FROM_SHA" ]] || die 2 "--from needs a commit"; shift 2 ;;
    --default-days) RANGE_DEFAULT_DAYS="${2:-}"; [[ "$RANGE_DEFAULT_DAYS" =~ ^[1-9][0-9]*$ ]] || die 2 "--default-days needs a positive integer"; shift 2 ;;
    --range-bound) RANGE_BOUND_OVERRIDE="${2:-}"; [[ "$RANGE_BOUND_OVERRIDE" =~ ^[1-9][0-9]*$ ]] || die 2 "--range-bound needs a positive integer"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done
if [[ -n "$RANGE_BOUND_OVERRIDE" && ! "$RANGE_BOUND_OVERRIDE" =~ ^[1-9][0-9]*$ ]]; then
  die 2 "BACKFILL_RANGE_BOUND needs a positive integer"
fi
if [[ -n "$FROM_SHA" && "$RANGE_MODE" -eq 0 ]]; then die 2 "--from needs --range"; fi
if [[ ! "$RANGE_DEFAULT_DAYS" =~ ^[1-9][0-9]*$ ]]; then die 2 "BACKFILL_RANGE_DEFAULT_DAYS needs a positive integer"; fi
if ! [[ "$MAX_ROW_ATTEMPTS" =~ ^[0-9]+$ ]] || (( 10#$MAX_ROW_ATTEMPTS < 1 )); then
  die 2 "--max-row-attempts / BACKFILL_MAX_ROW_ATTEMPTS needs an integer >= 1"
fi
MAX_REVIEWS=$(( 10#$MAX_REVIEWS )) REVIEW_TIMEOUT=$(( 10#$REVIEW_TIMEOUT ))   # "08" is not octal here
MAX_ROW_ATTEMPTS=$(( 10#$MAX_ROW_ATTEMPTS ))

# Channels: the hard-coded allowlist, narrowed (never widened) by config.
CHANNELS=()
IFS=',' read -r -a _req <<<"$CHANNELS_RAW"
for c in "${_req[@]+"${_req[@]}"}"; do
  c="${c// /}"; c="${c%-cli}"
  case " $ALLOWED_CHANNELS " in
    *" $c "*)
      # A repeated name would retry a channel already dropped as failed.
      case " ${CHANNELS[*]+"${CHANNELS[*]}"} " in *" $c "*) ;; *) CHANNELS+=("$c") ;; esac ;;
    *) die 2 "channel '$c' is not a free local reviewer (allowed: $ALLOWED_CHANNELS)" ;;
  esac
done
[[ ${#CHANNELS[@]} -gt 0 ]] || die 2 "no review channel left after --channels"

for t in git jq python3 gh; do command -v "$t" >/dev/null 2>&1 || die 3 "$t not found on PATH"; done
LEDGER_SH="$SCRIPT_DIR/unreviewed-merge-ledger.sh"
LOCAL_REVIEW="$SCRIPT_DIR/local-review.sh"
ISSUE_FILE="$SCRIPT_DIR/issue-file.sh"
ISSUE_DEDUP="$SCRIPT_DIR/issue-dedup.sh"
HELPER="$SCRIPT_DIR/lib/backfill_review.py"
for h in "$LEDGER_SH" "$LOCAL_REVIEW" "$ISSUE_FILE" "$ISSUE_DEDUP" "$HELPER"; do
  [[ -f "$h" ]] || die 3 "helper missing: $h"
done
GH_BIN="$(command -v gh)"

REPO_DIR="$(cd "$REPO_DIR" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" \
  || die 2 "--repo-dir is not inside a git checkout"
ORIGIN_URL="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)" || die 2 "no origin remote in $REPO_DIR"
ORIGIN_SAFE="$(printf '%s' "$ORIGIN_URL" | sed -E 's#//[^/@]+@#//***@#')"   # never log a URL credential
ORIGIN_SLUG=""
if [[ "$ORIGIN_URL" =~ ^(git@github\.com:|ssh://git@github\.com/|https://github\.com/) ]]; then
  ORIGIN_SLUG="$(printf '%s' "$ORIGIN_URL" | sed -E -e 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)##' -e 's#\.git$##' -e 's#/$##' | tr '[:upper:]' '[:lower:]')"
elif [[ "$ORIGIN_URL" =~ ^(https?|ssh|git)://([^/@]+@)?github\.com(:[0-9]+)?/ ]]; then
  # Credentialed or port-qualified GitHub URLs (https://user:token@github.com/o/r).
  ORIGIN_SLUG="$(printf '%s' "$ORIGIN_URL" | sed -E -e 's#^[a-z]+://([^/@]+@)?github\.com(:[0-9]+)?/##' -e 's#\.git$##' -e 's#/$##' | tr '[:upper:]' '[:lower:]')"
elif [[ "$ORIGIN_URL" == *github.com* ]]; then
  # A GitHub origin this parser cannot read must not let any --repo through.
  die 2 "cannot parse the GitHub origin of --repo-dir ($ORIGIN_SAFE)"
fi
[[ -n "$REPO" ]] || REPO="$ORIGIN_SLUG"
REPO="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"
[[ "$REPO" =~ ^[a-z0-9_.-]+/[a-z0-9_.-]+$ ]] || die 2 "cannot derive owner/name (origin: $ORIGIN_SAFE); pass --repo"
# The reviewed code comes from --repo-dir; issues and labels go to $REPO. A
# GitHub origin that names a different repo would file into the wrong one.
if [[ -n "$ORIGIN_SLUG" && "$ORIGIN_SLUG" != "$REPO" ]]; then
  die 2 "--repo $REPO does not match the origin of --repo-dir ($ORIGIN_SLUG)"
fi

LOG_DIR="$HOME/.claude/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || die 3 "cannot create $LOG_DIR"
LOG="$LOG_DIR/backfill-review.log"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG" 2>/dev/null || true; }

REVIEWED=0 CLEAN=0 FILED=0 SKIPPED=0 PENDING_LEFT=0 ATTEMPTS=0
summary() { # stop-reason
  log "$REPO stop=$1 reviewed=$REVIEWED clean=$CLEAN issues_filed=$FILED skipped=$SKIPPED pending_left=$PENDING_LEFT"
  printf 'backfill-review: reviewed=%s clean=%s issues_filed=%s skipped=%s pending_left=%s stop=%s\n' \
    "$REVIEWED" "$CLEAN" "$FILED" "$SKIPPED" "$PENDING_LEFT" "$1"
}

# ---- quiet window ----------------------------------------------------------
# --now pins the run's starting instant; later checks advance it by $SECONDS
# (elapsed run time), so a slow step is seen to eat into the window.
window_left() { # [--seconds] — prints the time left; non-zero outside the window
  local args=(window --window "$WINDOW" --tz "$TZONE" "$@")
  [[ -n "$NOW_ARG" ]] && args+=(--now "$NOW_ARG" --elapsed "$SECONDS")
  python3 "$HELPER" "${args[@]}"
}
minutes_left() { window_left; }
# window_has_room — 0 when the window still fits one more review: local-review.sh
# caps a run at 2x its idle --timeout, so reserve that much.
window_has_room() {
  [[ "$IGNORE_WINDOW" -eq 1 ]] && return 0
  local secs
  secs="$(window_left --seconds)" || return 1
  [[ "$secs" =~ ^[0-9]+$ ]] && (( secs >= 2 * REVIEW_TIMEOUT ))
}
if [[ "$IGNORE_WINDOW" -eq 0 ]]; then
  LEFT="$(minutes_left)"; rc=$?
  [[ $rc -eq 2 ]] && die 2 "invalid --window '$WINDOW' or --tz '$TZONE'"
  if [[ $rc -ne 0 ]]; then summary outside_window; exit 0; fi
  log "$REPO window $WINDOW $TZONE open, ${LEFT}m left"
fi

# ---- single-owner run lock ---------------------------------------------------
# flock(2) held by a small holder process on a descriptor only it has open
# (Python fds are not inherited), so no helper child of this shell — gh, git,
# a hung CLI — can keep the lock alive after the runner dies. The holder
# watches getppid() rather than a PID (a reused PID cannot fool it) and exits
# as soon as this shell is gone, however it dies; the EXIT trap stops it at
# once on a normal exit. It writes its identity into the lock file for the
# lock_held diagnostic. There is no stale-PID takeover to race on.
RUN_LOCK="$HOME/.claude/backfill-review.flock"
LOCK_HOLDER_PY='
import fcntl, os, sys, time
path, runner = sys.argv[1], int(sys.argv[2])
if os.getppid() != runner:
    print("not-a-child", flush=True); sys.exit(1)
try:
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    print("held", flush=True); sys.exit(1)
os.ftruncate(fd, 0)
os.write(fd, ("holder=%d runner=%d started=%s\n" % (os.getpid(), runner,
         time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))).encode())
print("locked", flush=True)
while os.getppid() == runner:
    time.sleep(0.2)
'
SCRATCH="" LOCK_PID=""
cleanup() {
  if [[ -n "$SCRATCH" && -d "$SCRATCH" ]]; then cleanup_worktree; fi
  if [[ -n "$LOCK_PID" ]]; then kill "$LOCK_PID" 2>/dev/null; wait "$LOCK_PID" 2>/dev/null; fi
}
trap cleanup EXIT
LOCK_STATUS_FILE="$(mktemp "${TMPDIR:-/tmp}/backfill-review-lock.XXXXXX")" || die 3 "cannot create a lock status file"
python3 -c "$LOCK_HOLDER_PY" "$RUN_LOCK" "$$" </dev/null >"$LOCK_STATUS_FILE" 2>/dev/null &
LOCK_PID=$!
LOCK_STATE="" _tries=0
while (( _tries < 100 )); do   # ~10s for the holder to answer
  IFS= read -r LOCK_STATE <"$LOCK_STATUS_FILE" 2>/dev/null
  [[ -n "$LOCK_STATE" ]] && break
  if ! kill -0 "$LOCK_PID" 2>/dev/null; then IFS= read -r LOCK_STATE <"$LOCK_STATUS_FILE" 2>/dev/null; break; fi
  sleep 0.1; _tries=$(( _tries + 1 ))
done
rm -f "$LOCK_STATUS_FILE"
if [[ "$LOCK_STATE" != locked ]]; then
  # Held elsewhere, unlockable, or no answer: never run unlocked.
  _holder="$(head -n 1 "$RUN_LOCK" 2>/dev/null | tr -cd '[:alnum:] =:_.-')"
  _hpid="$(printf '%s' "$_holder" | sed -n 's/.*holder=\([0-9][0-9]*\).*/\1/p')"
  _alive="unknown"
  if [[ -n "$_hpid" ]]; then
    if kill -0 "$_hpid" 2>/dev/null; then _alive="alive"; else _alive="gone (another process holds the lock)"; fi
  fi
  log "$REPO lock not acquired (${LOCK_STATE:-no answer}); last holder: ${_holder:-unrecorded}; holder pid $_alive"
  summary lock_held; exit 0
fi

# Per-PR preamble (ledger rows, dry run, label retries). Range mode skips it:
# it never reads the ledger and never writes a PR label.
if [[ "$RANGE_MODE" -eq 0 ]]; then
# ---- pending rows ----------------------------------------------------------
ALL_ROWS="$("$LEDGER_SH" list --repo "$REPO")" || die 4 "ledger list failed"
# Fewest failed attempts first, then oldest merge: a row that keeps failing
# sinks behind fresh rows instead of spending every run's budget.
ROW_ATTEMPTS_JQ='(.backfill | if type == "object" then .attempts else null end) | if type == "number" then floor else 0 end'
PENDING="$(jq -c "map(select(.backfill_status == \"pending\")) | sort_by(($ROW_ATTEMPTS_JQ), .merged_at // .recorded_at // \"\", .pr)" <<<"$ALL_ROWS")" \
  || die 4 "ledger list is not a JSON array"
PENDING_LEFT="$(jq 'length' <<<"$PENDING")"

ledger_mark() { # pr sha status detail-json
  printf '%s' "$4" | "$LEDGER_SH" backfill --repo "$REPO" --pr "$1" --sha "$2" --status "$3" --detail-json - >/dev/null
}

# row_failed <row-json> <reason> — the row's review ran (it spent budget) but
# the row could not be completed. Count the attempt: below the cap the row
# stays pending with {attempts, last_failure}; at the cap it is skipped with
# the reason, never marked reviewed, and keeps the merged-unreviewed label.
row_failed() {
  local row="$1" reason="$2" pr sha n now
  pr="$(jq -r .pr <<<"$row")"; sha="$(jq -r .head_sha <<<"$row")"
  n="$(jq -r "$ROW_ATTEMPTS_JQ" <<<"$row" 2>/dev/null)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  n=$(( n + 1 )); now="$(date -u +%FT%TZ)"
  if (( n >= MAX_ROW_ATTEMPTS )); then
    if ledger_mark "$pr" "$sha" skipped "$(jq -cn --argjson n "$n" --arg r "$reason" --arg now "$now" \
         '{skip_reason: ("gave up after \($n) failed review attempts; last: " + $r),
           attempts: $n, last_failure: $r, skipped_at: $now, label_synced: false}')"; then
      SKIPPED=$(( SKIPPED + 1 )); PENDING_LEFT=$(( PENDING_LEFT - 1 ))
      log "$REPO PR #$pr $reason — skipped after $n failed attempts"
    else
      log "$REPO PR #$pr $reason — left pending (attempt cap reached, ledger write failed)"
    fi
  else
    ledger_mark "$pr" "$sha" pending "$(jq -cn --argjson n "$n" --arg r "$reason" --arg now "$now" \
      '{attempts: $n, last_failure: $r, last_failure_at: $now}')" \
      || log "$REPO PR #$pr attempt count not recorded (ledger write failed)"
    log "$REPO PR #$pr $reason — left pending (attempt $n of $MAX_ROW_ATTEMPTS)"
  fi
}

swap_label() { # pr — returns 0 when the label swap landed
  "$GH_BIN" label create "$TO_LABEL" --repo "$REPO" --color "0e8a16" \
    --description "Reviewed after merge by the backfill (issue #1900)" >/dev/null 2>&1 || true
  "$GH_BIN" pr edit "$1" --repo "$REPO" --remove-label "$FROM_LABEL" --add-label "$TO_LABEL" >/dev/null 2>&1
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  jq -r '.[] | "would review PR #\(.pr) merged \(.merged_at // "?") \(.merge_commit_sha // "no-merge-sha")"' <<<"$PENDING"
  summary dry_run; exit 0
fi

# Retry label swaps that failed on an earlier run (the review itself is done).
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  pr="$(jq -r .pr <<<"$row")"; sha="$(jq -r .head_sha <<<"$row")"; st="$(jq -r .backfill_status <<<"$row")"
  if swap_label "$pr"; then
    ledger_mark "$pr" "$sha" "$st" "$(jq -c '.backfill | .label_synced = true' <<<"$row")" \
      || log "$REPO PR #$pr label retried but ledger update failed"
  fi
done < <(jq -c '.[] | select((.backfill_status == "reviewed-clean" or .backfill_status == "issues-filed")
                              and .backfill.label_synced == false)' <<<"$ALL_ROWS")

[[ "$PENDING_LEFT" -gt 0 ]] || { summary "done"; exit 0; }
fi

# Pin origin/main once: every finding is verified against this SHA.
if ! git -C "$REPO_DIR" fetch --quiet origin main 2>>"$LOG"; then
  summary main_fetch_failed; exit 0
fi
MAIN_SHA="$(git -C "$REPO_DIR" rev-parse --verify origin/main 2>/dev/null)" || { summary main_fetch_failed; exit 0; }

# ---- per-entry review --------------------------------------------------------
WT="" BASE_BRANCH=""
cleanup_worktree() {
  if [[ -n "$WT" ]]; then git -C "$REPO_DIR" worktree remove --force "$WT" >/dev/null 2>&1 || true; fi
  if [[ -n "$BASE_BRANCH" ]]; then git -C "$REPO_DIR" branch -D "$BASE_BRANCH" >/dev/null 2>&1 || true; fi
  if [[ -n "$SCRATCH" ]]; then
    rm -f "$SCRATCH"/*.out "$SCRATCH"/*.err "$SCRATCH"/*.md 2>/dev/null
    rmdir "$SCRATCH" 2>/dev/null || true
  fi
  WT="" BASE_BRANCH="" SCRATCH=""
}

ALIVE=("${CHANNELS[@]}")
drop_channel() { # channel
  local keep=() c
  for c in "${ALIVE[@]+"${ALIVE[@]}"}"; do [[ "$c" == "$1" ]] || keep+=("$c"); done
  ALIVE=("${keep[@]+"${keep[@]}"}")
}

# review_entry <merge_sha> <pr> — sets REVIEW_JSON (local-review contract),
# REVIEW_TOOL, REVIEW_LOG. Returns 0 on a verified run, 1 when every channel
# is gone (stop the run), 2 on a per-entry setup failure (skip this run),
# 3 when the quiet window no longer fits a review (stop the run).
review_entry() {
  local merge="$1" pr="$2" ch rc bin_var bin out
  REVIEW_JSON="" REVIEW_TOOL="" REVIEW_LOG=""
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/backfill-review.XXXXXX")" || return 2
  WT="$SCRATCH/wt"
  # core.hooksPath=/dev/null: no repo hook runs on the reviewed code's checkout.
  git -C "$REPO_DIR" -c core.hooksPath=/dev/null worktree add --quiet --detach "$WT" "$merge" >/dev/null 2>>"$LOG" \
    || { WT=""; return 2; }
  BASE_BRANCH="backfill-base-$pr-$$"
  git -C "$REPO_DIR" branch --quiet "$BASE_BRANCH" "$merge^1" 2>>"$LOG" || { BASE_BRANCH=""; return 2; }
  for ch in "${ALIVE[@]+"${ALIVE[@]}"}"; do
    if (( ATTEMPTS >= MAX_REVIEWS )); then return 1; fi
    # Re-checked here, after the merge lookup, fetches, and worktree setup
    # (and any failed channel before this one) have spent part of the window.
    window_has_room || return 3
    ATTEMPTS=$(( ATTEMPTS + 1 ))
    bin_var="BACKFILL_$(printf '%s' "$ch" | tr '[:lower:]' '[:upper:]')_BIN"
    bin="${!bin_var:-}"
    local args=(--tool "$ch" --scope committed --base "$BASE_BRANCH" --timeout "$REVIEW_TIMEOUT" --log-dir "$SCRATCH")
    [[ -n "$bin" ]] && args+=(--bin "$bin")
    out="$(cd "$WT" && bash "$LOCAL_REVIEW" "${args[@]}" 9>&-)"; rc=$?
    log "$REPO PR #$pr $ch rc=$rc $(printf '%s' "$out" | jq -c '{verified_run,findings,failure_mode}' 2>/dev/null)"
    if [[ $rc -le 1 ]] && [[ "$(printf '%s' "$out" | jq -r '.verified_run' 2>/dev/null)" == true ]]; then
      REVIEW_JSON="$out" REVIEW_TOOL="$ch" REVIEW_LOG="$(printf '%s' "$out" | jq -r .log_path)"
      return 0
    fi
    # Not a verified run (cap, rate limit, error, hang, missing CLI): fail closed.
    drop_channel "$ch"
  done
  return 1
}

# resolve_main_path <merge_sha> <path> — prints where <path> lives on main:
# itself, or its rename target (git diff -M, merge -> main). Returns 1 when
# neither resolves: deleted, or renamed past rename detection — the caller
# must not read that as "fixed".
resolve_main_path() {
  local merge="$1" path="$2" st a b
  if git -C "$REPO_DIR" cat-file -e "$MAIN_SHA:$path" 2>/dev/null; then printf '%s' "$path"; return 0; fi
  while IFS= read -r -d '' st; do
    case "$st" in
      R*|C*)
        IFS= read -r -d '' a || break; IFS= read -r -d '' b || break
        if [[ "$a" == "$path" ]] && git -C "$REPO_DIR" cat-file -e "$MAIN_SHA:$b" 2>/dev/null; then
          printf '%s' "$b"; return 0
        fi ;;
      *) IFS= read -r -d '' a || break ;;
    esac
  done < <(git -C "$REPO_DIR" diff -M --name-status -z "$merge" "$MAIN_SHA" 2>/dev/null)
  return 1
}

# verify_finding <finding-json> <merge_sha> — prints "<verdict><TAB><path on main>",
# verdict still_present | changed. A path that cannot be resolved on main
# (deleted, or renamed beyond detection) is "changed" with an empty main path:
# filed with a locate-and-confirm note, never dropped (the filing bias).
verify_finding() {
  local f="$1" merge="$2" path line mp text_at_merge old_blob new_blob
  path="$(jq -r .path <<<"$f")"; line="$(jq -r '.line // empty' <<<"$f")"
  mp="$(resolve_main_path "$merge" "$path")" || { printf 'changed\t\n'; return; }
  old_blob="$(git -C "$REPO_DIR" rev-parse -q --verify "$merge:$path" 2>/dev/null)"
  new_blob="$(git -C "$REPO_DIR" rev-parse -q --verify "$MAIN_SHA:$mp" 2>/dev/null)"
  if [[ -n "$old_blob" && "$old_blob" == "$new_blob" ]]; then printf 'still_present\t%s\n' "$mp"; return; fi
  if [[ "$line" =~ ^[0-9]+$ ]]; then
    text_at_merge="$(git -C "$REPO_DIR" show "$merge:$path" 2>/dev/null | sed -n "${line}p")"
    if [[ -n "${text_at_merge//[[:space:]]/}" ]] \
       && grep -qxF -- "$text_at_merge" <<<"$(git -C "$REPO_DIR" show "$MAIN_SHA:$mp" 2>/dev/null)"; then
      printf 'still_present\t%s\n' "$mp"; return
    fi
  fi
  printf 'changed\t%s\n' "$mp"
}

# marker_lookup <marker> — prints the matching issue URL, empty for none; returns 2 on error/ambiguity
marker_lookup() {
  local list n total
  list="$("$GH_BIN" issue list --repo "$REPO" --state all --limit "$MARKER_LOOKUP_LIMIT" --json number,url,body 2>/dev/null)" || return 2
  # A listing that filled the limit may be truncated: absence is unproven.
  total="$(jq 'length' <<<"$list" 2>/dev/null)" || return 2
  [[ "$total" =~ ^[0-9]+$ ]] && (( total < MARKER_LOOKUP_LIMIT )) || return 2
  n="$(jq --arg m "$1" '[.[] | select((.body // "") | contains($m))] | length' <<<"$list" 2>/dev/null)" || return 2
  [[ "$n" =~ ^[0-9]+$ ]] || return 2
  (( n > 1 )) && return 2
  (( n == 1 )) && jq -r --arg m "$1" '[.[] | select((.body // "") | contains($m))][0].url' <<<"$list"
  return 0
}

neutralize() { # stdin -> stdout: no @-mentions, no fence breakouts, no headings
  # A quoted line starting `## Estimate` (any `#`) would count as a section
  # heading in issue-file.sh's order check, which does not see fences.
  sed -e 's/@/@\&#8203;/g' -e 's/```/` ` `/g' -e 's/^#/ #/'
}
# safe_inline <text> — one line for an inline code span: no backtick, CR/LF, or @.
safe_inline() { printf '%s' "$1" | tr '\r\n`' "  '" | sed 's/@/(at)/g'; }

# file_finding <finding-json> <row-json> <verdict> <merge-sha> <main-path> — prints the issue URL; non-zero = leave pending
file_finding() {
  local f="$1" row="$2" verdict="$3" merge="$4" main_path="$5" fp marker url path line sev text title body dup dup_rc kw pr_url
  fp="$(jq -r .fingerprint <<<"$f")"; path="$(jq -r .path <<<"$f")"; line="$(jq -r '.line // "?"' <<<"$f")"
  sev="$(jq -r .severity <<<"$f")"; text="$(jq -r .text <<<"$f")"
  pr_url="$(jq -r '.url // ""' <<<"$row")"
  marker="<!-- backfill-finding: $REPO#$(jq -r .pr <<<"$row"):$fp -->"
  url="$(marker_lookup "$marker")" || return 1
  if [[ -n "$url" ]]; then printf '%s\n' "$url"; return 0; fi
  kw="$(printf '%s %s' "$(basename "$path")" "$(printf '%s' "$text" | head -n 1)" | tr -c '[:alnum:]_.-' ' ' | cut -c1-200)"
  dup="$(bash "$ISSUE_DEDUP" "$kw" --repo "$REPO" --max-results 3 2>/dev/null)"; dup_rc=$?
  [[ $dup_rc -eq 4 || $dup_rc -eq 2 ]] && return 1
  dup="$(jq -r '.[]? | "Possibly duplicates #\(.number) — \(.title)"' <<<"${dup:-[]}" 2>/dev/null | neutralize)"
  title="Backfill: $(basename "$path") — $(printf '%s' "$text" | head -n 1 | tr -s '[:space:]' ' ')"
  title="$(printf '%s' "$title" | python3 -c 'import sys; t=sys.stdin.read().strip(); print(t if len(t)<=70 else t[:69].rstrip()+"…")')"
  title="$(printf '%s' "$title" | sed 's/@/(at)/g')"
  body="$SCRATCH/issue-$fp.md"
  {
    printf '## Background\n\n'
    printf 'PR #%s (%s) merged without an AI review through the no-review override. The overnight backfill (issue #1900) reviewed merge commit `%s` with the %s CLI and flagged this.\n\n' \
      "$(jq -r .pr <<<"$row")" "$pr_url" "$merge" "$(jq -r .tool <<<"$f")"
    printf '## Problem\n\n`%s` line %s (severity: %s). Finding text, quoted as untrusted review data:\n\n```text\n' \
      "$(safe_inline "$path")" "$(safe_inline "$line")" "$(safe_inline "$sev")"
    printf '%s\n' "$text" | neutralize
    printf '```\n\n'
    printf '## Proposed solution\n\nConfirm the finding against current `main` and fix it if it still applies.\n\n'
    printf '## Acceptance Criteria\n\n- [ ] The flagged behaviour is fixed on `main`, or this issue is closed with the reason it does not apply.\n\n'
    printf '## Test Plan\n\n- [ ] A test or manual check shows the flagged case behaves correctly.\n\n'
    printf '## Notes / Open questions\n\n'
    printf -- '- Verified against `main` at `%s`: %s.\n' "$MAIN_SHA" "$verdict"
    if [[ -z "$main_path" ]]; then
      printf -- '- This path is not on `main` and no rename was detected — locate the code (renamed, moved, or deleted) and confirm the finding still applies before fixing.\n'
    else
      if [[ "$main_path" != "$path" ]]; then printf -- '- The file was renamed after the merge; on `main` it is `%s`.\n' "$(safe_inline "$main_path")"; fi
      if [[ "$verdict" == changed ]]; then printf -- '- The file changed after the merge — confirm the finding still applies before fixing.\n'; fi
    fi
    if [[ -n "$dup" ]]; then printf -- '- %s\n' "$dup"; fi
    printf -- '- Filed automatically; no reviewer was asked to re-review.\n\n%s\n\n' "$marker"
    printf '## Estimate\n\nEst: 15–30 min · plan on 30\n\n_Captured via /issue-maker._\n'
  } > "$body" || return 1
  ISSUE_FILE_GH="$GH_BIN" bash "$ISSUE_FILE" --repo "$REPO" --title "$title" --body-file "$body" --label bug --json 2>>"$LOG" \
    | jq -er '.url' || return 1
}

# ---- range mode (issue #2324) ----------------------------------------------
# Everything below is defined before the dispatch at the end of this section,
# so the helpers above (verify_finding, marker_lookup, file_finding's
# neutralize/safe_inline, cleanup_worktree, drop_channel) are all in scope.
RANGE_CUT_SHA="" RANGE_CUT_FILES=0 RANGE_CUT_COMMITS=0 RANGE_CUT_PARTIAL=0 RANGE_FIRST=""
RANGE_LAST=""
short() { printf '%s' "${1:0:12}"; }

range_hard_bound() { # channel -> the reviewer's own file cap, never lowered; unknown = 0 (refuse)
  case "$1" in
    codeant) printf '%s' "$RANGE_BOUND_CODEANT" ;;
    coderabbit) printf '%s' "$RANGE_BOUND_CODERABBIT" ;;
    *) printf '0' ;;
  esac
}

range_max_hard_bound() { # the largest hard cap of any allowed channel; a commit above it fits no reviewer
  local c b m=0
  for c in $ALLOWED_CHANNELS; do
    b="$(range_hard_bound "$c")"
    if (( b > m )); then m=$b; fi
  done
  printf '%s' "$m"
}

range_bound() { # channel -> the file bound for that reviewer
  local b=0
  case "$1" in
    codeant) b=$RANGE_BOUND_CODEANT ;;
    coderabbit) b=$RANGE_BOUND_CODERABBIT ;;
  esac
  if [[ -n "$RANGE_BOUND_OVERRIDE" ]] && (( 10#$RANGE_BOUND_OVERRIDE < b )); then
    b=$(( 10#$RANGE_BOUND_OVERRIDE ))
  fi
  printf '%s' "$b"
}

# range_marker_read — sets RANGE_LAST to the recorded commit. An absent file, or
# a file with no entry for this repo, is "no marker" (RANGE_LAST empty). Any
# other shape is refused (return 1): an empty file, a file holding anything but
# one JSON object, a repo entry with no usable commit, or a commit that is not
# a full hex SHA. Nothing here falls back to a default start.
range_marker_read() {
  local sha=""
  RANGE_LAST=""
  [[ -e "$RANGE_MARKER" ]] || return 0
  jq -e 'type == "object"' "$RANGE_MARKER" >/dev/null 2>&1 || return 1
  # Only an ABSENT repo key prints the word null (jq -r). A present key must be
  # an object with a commit; an explicit null, a non-object, an empty commit, or
  # a missing commit fails here or in the SHA check below. None is "absent".
  sha="$(jq -r --arg r "$REPO" 'if type == "object" and ((.repos | type) == "object") then
             (if ((.repos | has($r)) | not) then null
              else (.repos[$r] | if type == "object"
                    then (.last_reviewed_commit // error("no commit for repo"))
                    else error("repo entry is not an object") end) end)
           else error("marker shape") end' "$RANGE_MARKER" 2>/dev/null)" || return 1
  if [[ "$sha" == null ]]; then return 0; fi
  [[ "$sha" =~ ^[0-9a-f]{40,64}$ ]] || return 1
  RANGE_LAST="$sha"
}

# range_marker_write <sha> <files> <bound> <channel> <partial 0|1> — atomic:
# temp file in the same directory, then rename. Uses RANGE_FIRST / RANGE_CUT_COMMITS.
range_marker_write() {
  local sha="$1" files="$2" bound="$3" ch="$4" partial="$5" dir tmp now
  dir="$(dirname "$RANGE_MARKER")"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$(mktemp "$dir/.backfill-range-marker.XXXXXX")" || return 1
  now="$(date -u +%FT%TZ)"
  {
    if [[ -e "$RANGE_MARKER" ]]; then cat "$RANGE_MARKER"; else printf '%s' '{"schema_version":1,"repos":{}}'; fi
  } | jq --arg r "$REPO" --arg sha "$sha" --arg now "$now" --arg first "$RANGE_FIRST" \
        --argjson commits "$RANGE_CUT_COMMITS" --argjson files "$files" --argjson bound "$bound" \
        --arg ch "$ch" --argjson partial "$partial" '
      .repos[$r] = ((.repos[$r] // {}) + {last_reviewed_commit: $sha, updated_at: $now,
        last_range: {first: $first, last: $sha, commits: $commits, files: $files,
                     bound: $bound, channel: $ch, partial: ($partial == 1)}})
      | if $partial == 1
        then .repos[$r].partial_commits = ((.repos[$r].partial_commits // []) + [{commit: $sha, files: $files, bound: $bound}])
        else . end' > "$tmp" && mv "$tmp" "$RANGE_MARKER" || { rm -f "$tmp"; return 1; }
}

# range_marker_write_uncovered <sha> <files> <largest-cap> — the one case where the
# marker moves past code no reviewer saw. A single commit over every channel's
# hard cap is appended to repos[<repo>].uncovered and the marker advances to it
# in ONE atomic write. last_range and partial_commits are not touched: nothing
# was reviewed. Failure returns 1 with the marker unchanged (the caller stops).
range_marker_write_uncovered() {
  local sha="$1" files="$2" cap="$3" dir tmp now
  dir="$(dirname "$RANGE_MARKER")"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$(mktemp "$dir/.backfill-range-marker.XXXXXX")" || return 1
  now="$(date -u +%FT%TZ)"
  {
    if [[ -e "$RANGE_MARKER" ]]; then cat "$RANGE_MARKER"; else printf '%s' '{"schema_version":1,"repos":{}}'; fi
  } | jq --arg r "$REPO" --arg sha "$sha" --arg now "$now" --arg first "$RANGE_FIRST" \
        --argjson files "$files" --argjson cap "$cap" '
      .repos[$r] = ((.repos[$r] // {}) + {last_reviewed_commit: $sha, updated_at: $now})
      | .repos[$r].uncovered = ((.repos[$r].uncovered // []) + [{
          commit: $sha, files: $files, largest_cap: $cap, recorded_at: $now,
          reason: "exceeds every channel hard cap; no reviewer was run on this commit"}])' \
    > "$tmp" && mv "$tmp" "$RANGE_MARKER" || { rm -f "$tmp"; return 1; }
}

# range_cut <start> <end> <bound> — walks first-parent commits after start and
# cuts at the last boundary whose cumulative distinct-file count (diff from
# start, renames off) is at or under <bound>. A first commit alone over the
# bound is the cut, flagged partial. Sets RANGE_CUT_*, RANGE_FIRST.
# Returns 1 on a git failure, 2 when there is no commit to cut.
range_cut() {
  local start="$1" end="$2" bound="$3" c n=0 diffout nfiles cut="" cfiles=0 cn=0 first="" partial=0 commits
  RANGE_CUT_SHA="" RANGE_CUT_FILES=0 RANGE_CUT_COMMITS=0 RANGE_CUT_PARTIAL=0 RANGE_FIRST=""
  commits="$(git -C "$REPO_DIR" rev-list --first-parent --reverse "$start..$end" 2>/dev/null)" || return 1
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    n=$(( n + 1 ))
    [[ -n "$first" ]] || first="$c"
    diffout="$(git -C "$REPO_DIR" diff --no-renames --name-only "$start" "$c" 2>/dev/null)" || return 1
    nfiles="$(printf '%s' "$diffout" | awk 'NF' | wc -l | tr -d ' ')"
    if (( nfiles > bound )); then
      if [[ -z "$cut" ]]; then cut="$c"; cfiles=$nfiles; cn=$n; partial=1; fi
      break
    fi
    cut="$c"; cfiles=$nfiles; cn=$n
  done <<< "$commits"
  [[ -n "$cut" ]] || return 2
  RANGE_CUT_SHA="$cut" RANGE_CUT_FILES=$cfiles RANGE_CUT_COMMITS=$cn RANGE_CUT_PARTIAL=$partial RANGE_FIRST="$first"
}

# range_introducer <path> <start> <cut> — the PR behind the last commit in the
# range that touched <path>, read from its squash subject. Path-level only.
range_introducer() {
  local path="$1" start="$2" cut="$3" c subj n
  c="$(git -C "$REPO_DIR" log --first-parent -1 --format=%H "$start..$cut" -- "$path" 2>/dev/null)" || c=""
  if [[ -z "$c" ]]; then printf 'not determinable (no commit in the range touches this path)'; return; fi
  subj="$(git -C "$REPO_DIR" log -1 --format=%s "$c" 2>/dev/null)"
  n="$(printf '%s' "$subj" | sed -n 's/.*(#\([0-9][0-9]*\))[^(]*$/\1/p')"
  if [[ -n "$n" ]]; then
    printf 'PR #%s (commit %s, the last commit in the range touching this path; path-level, approximate)' "$n" "$(short "$c")"
  else
    printf 'commit %s (no PR number in its subject; path-level, approximate)' "$(short "$c")"
  fi
}

# range_review_channel <start> <cut> <channel> — one committed-range review in a
# throwaway detached worktree at <cut>, base = <start>. Returns 0 on a verified
# run (REVIEW_JSON / REVIEW_LOG set), 1 when not verified, 2 on a setup
# failure, 3 when the quiet window no longer fits a review.
range_review_channel() {
  local start="$1" cut="$2" ch="$3" bin_var bin out rc
  REVIEW_JSON="" REVIEW_LOG=""
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/backfill-range.XXXXXX")" || return 2
  WT="$SCRATCH/wt"
  git -C "$REPO_DIR" -c core.hooksPath=/dev/null worktree add --quiet --detach "$WT" "$cut" >/dev/null 2>>"$LOG" \
    || { WT=""; return 2; }
  BASE_BRANCH="backfill-range-base-$$"
  git -C "$REPO_DIR" branch --quiet "$BASE_BRANCH" "$start" 2>>"$LOG" || { BASE_BRANCH=""; return 2; }
  window_has_room || return 3
  ATTEMPTS=$(( ATTEMPTS + 1 ))
  bin_var="BACKFILL_$(printf '%s' "$ch" | tr '[:lower:]' '[:upper:]')_BIN"
  bin="${!bin_var:-}"
  local args=(--tool "$ch" --scope committed --base "$BASE_BRANCH" --timeout "$REVIEW_TIMEOUT" --log-dir "$SCRATCH")
  [[ -n "$bin" ]] && args+=(--bin "$bin")
  out="$(cd "$WT" && bash "$LOCAL_REVIEW" "${args[@]}" 9>&-)"; rc=$?
  log "$REPO range $(short "$start")..$(short "$cut") $ch rc=$rc $(printf '%s' "$out" | jq -c '{verified_run,findings,failure_mode}' 2>/dev/null)"
  if [[ $rc -le 1 ]] && [[ "$(printf '%s' "$out" | jq -r '.verified_run' 2>/dev/null)" == true ]]; then
    REVIEW_JSON="$out" REVIEW_LOG="$(printf '%s' "$out" | jq -r .log_path)"
    return 0
  fi
  return 1
}

# file_range_finding <finding> <start> <cut> <verdict> <main_path> <introducer> <range-info>
# Same filing path as file_finding (exact marker, dedup, issue-file.sh) with a
# range-scoped marker. The fingerprint is location-based, with no PR and no range.
file_range_finding() {
  local f="$1" start="$2" cut="$3" verdict="$4" main_path="$5" intro="$6" info="$7"
  local fp path line sev text marker url kw dup dup_rc title body
  fp="$(jq -r .fingerprint <<<"$f")"; path="$(jq -r .path <<<"$f")"; line="$(jq -r '.line // "?"' <<<"$f")"
  sev="$(jq -r .severity <<<"$f")"; text="$(jq -r .text <<<"$f")"
  marker="<!-- backfill-range-finding: $REPO:$fp -->"
  url="$(marker_lookup "$marker")" || return 1
  if [[ -n "$url" ]]; then printf '%s\n' "$url"; return 0; fi
  kw="$(printf '%s %s' "$(basename "$path")" "$(printf '%s' "$text" | head -n 1)" | tr -c '[:alnum:]_.-' ' ' | cut -c1-200)"
  dup="$(bash "$ISSUE_DEDUP" "$kw" --repo "$REPO" --max-results 3 2>/dev/null)"; dup_rc=$?
  [[ $dup_rc -eq 4 || $dup_rc -eq 2 ]] && return 1
  dup="$(jq -r '.[]? | "Possibly duplicates #\(.number) — \(.title)"' <<<"${dup:-[]}" 2>/dev/null | neutralize)"
  title="Backfill range: $(basename "$path") — $(printf '%s' "$text" | head -n 1 | tr -s '[:space:]' ' ')"
  title="$(printf '%s' "$title" | python3 -c 'import sys; t=sys.stdin.read().strip(); print(t if len(t)<=70 else t[:69].rstrip()+"…")')"
  title="$(printf '%s' "$title" | sed 's/@/(at)/g')"
  body="$SCRATCH/range-issue-$fp.md"
  {
    printf '## Background\n\n'
    printf 'The backfill range review (issue #2324) reviewed the commits `%s`..`%s` on `main` as one committed-range diff (%s). The range begins after the last reviewed commit `%s`. The change behind the flagged line: %s.\n\n' \
      "$(short "$RANGE_FIRST")" "$(short "$cut")" "$info" "$(short "$start")" "$intro"
    printf '## Problem\n\n`%s` line %s (severity: %s). Finding text, quoted as untrusted review data:\n\n```text\n' \
      "$(safe_inline "$path")" "$(safe_inline "$line")" "$(safe_inline "$sev")"
    printf '%s\n' "$text" | neutralize
    printf '```\n\n'
    printf '## Proposed solution\n\nConfirm the finding against current `main` and fix it if it still applies.\n\n'
    printf '## Acceptance Criteria\n\n- [ ] The flagged behaviour is fixed on `main`, or this issue is closed with the reason it does not apply.\n\n'
    printf '## Test Plan\n\n- [ ] A test or manual check shows the flagged case behaves correctly.\n\n'
    printf '## Notes / Open questions\n\n'
    printf -- '- Verified against `main` at `%s`: %s.\n' "$MAIN_SHA" "$verdict"
    if [[ -z "$main_path" ]]; then
      printf -- '- This path is not on `main` and no rename was detected — locate the code (renamed, moved, or deleted) and confirm the finding still applies before fixing.\n'
    else
      if [[ "$main_path" != "$path" ]]; then printf -- '- The file was renamed after the range; on `main` it is `%s`.\n' "$(safe_inline "$main_path")"; fi
      if [[ "$verdict" == changed ]]; then printf -- '- The file changed after the range — confirm the finding still applies before fixing.\n'; fi
    fi
    if [[ -n "$dup" ]]; then printf -- '- %s\n' "$dup"; fi
    printf -- '- Filed automatically from a range review; no reviewer was asked to re-review.\n\n%s\n\n' "$marker"
    printf '## Estimate\n\nEst: 15–30 min · plan on 30\n\n_Captured via /issue-maker._\n'
  } > "$body" || return 1
  ISSUE_FILE_GH="$GH_BIN" bash "$ISSUE_FILE" --repo "$REPO" --title "$title" --body-file "$body" --label bug --json 2>>"$LOG" \
    | jq -er '.url' || return 1
}

# range_main — the range loop. Always exits (summary + exit code).
range_main() {
  local start="" source="" cursor="" ch bound cut nfiles ncommits partial rc2 dry_count=0
  local f vline verdict main_path intro url ok ISSUES BUGS FINDINGS reported parsed info
  if ! range_marker_read; then summary range_marker_unreadable; exit 6; fi
  if [[ -n "$FROM_SHA" && -n "$RANGE_LAST" ]]; then
    die 2 "--from is for a first run; a marker already exists for $REPO (reset it to restart)"
  fi
  if [[ -n "$RANGE_LAST" ]]; then
    start="$RANGE_LAST"; source="marker"
    if ! git -C "$REPO_DIR" cat-file -e "$start^{commit}" 2>/dev/null; then
      summary range_marker_unknown_commit; exit 6
    fi
  elif [[ -n "$FROM_SHA" ]]; then
    start="$(git -C "$REPO_DIR" rev-parse --verify -q "$FROM_SHA^{commit}" 2>/dev/null)" || start=""
    [[ -n "$start" ]] || die 2 "--from $FROM_SHA is not a commit in $REPO_DIR"
    source="--from"
  else
    local oldest
    oldest="$(git -C "$REPO_DIR" rev-list --first-parent --since="$RANGE_DEFAULT_DAYS days ago" "$MAIN_SHA" 2>/dev/null | tail -n 1)" \
      || { summary range_internal_error; exit 5; }
    if [[ -z "$oldest" ]]; then summary range_no_commits; exit 0; fi
    start="$(git -C "$REPO_DIR" rev-parse --verify -q "$oldest^" 2>/dev/null)" || start=""
    if [[ -z "$start" ]]; then summary range_no_start; exit 0; fi
    source="default: commits since $RANGE_DEFAULT_DAYS days ago"
  fi
  if ! git -C "$REPO_DIR" merge-base --is-ancestor "$start" "$MAIN_SHA" 2>/dev/null; then
    if [[ "$source" == marker ]]; then summary range_marker_not_ancestor; exit 6; fi
    die 2 "range start $start is not an ancestor of origin/main"
  fi
  cursor="$start"
  printf 'backfill-review: range start=%s source=%s\n' "$(short "$start")" "$source"
  log "$REPO range start $start source=$source"

  while :; do
    if [[ "$cursor" == "$MAIN_SHA" ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then summary dry_run; else summary "done"; fi
      exit 0
    fi
    if [[ "$DRY_RUN" -eq 0 ]]; then
      window_has_room || { summary window_closed; exit 0; }
      if (( ATTEMPTS >= MAX_REVIEWS )); then summary max_reviews; exit 0; fi
    elif (( dry_count >= MAX_REVIEWS )); then
      summary dry_run; exit 0
    fi
    # The probe bound below only sizes the cut when no channel is alive; the
    # uncovered verdict depends on the file count alone, so it runs first.
    ch="${ALIVE[0]:-coderabbit}"; bound="$(range_bound "$ch")"
    rc2=0; range_cut "$cursor" "$MAIN_SHA" "$bound" || rc2=$?
    if [[ $rc2 -ne 0 ]]; then summary range_internal_error; exit 5; fi
    cut="$RANGE_CUT_SHA"; nfiles="$RANGE_CUT_FILES"; ncommits="$RANGE_CUT_COMMITS"; partial="$RANGE_CUT_PARTIAL"

    # A single commit over EVERY channel's hard cap fits no reviewer. It is never
    # handed to one and never stalls the run: it is recorded as uncovered and the
    # marker moves past it, in one atomic write. An unavailable channel is not
    # this case (that stays capacity_exhausted below, marker untouched).
    max_hard="$(range_max_hard_bound)"
    if [[ "$partial" -eq 1 ]] && (( nfiles > max_hard )); then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        printf 'would record uncovered commit %s files=%s largest_cap=%s (no reviewer run; nothing written)\n' \
          "$cut" "$nfiles" "$max_hard"
        cursor="$cut"; continue
      fi
      if ! range_marker_write_uncovered "$cut" "$nfiles" "$max_hard"; then
        summary range_uncovered_write_failed; exit 5
      fi
      log "$REPO UNCOVERED commit $cut: $nfiles files exceed every channel cap (largest $max_hard); no reviewer was run; recorded in marker uncovered[]"
      printf 'backfill-review: uncovered commit %s files=%s largest_cap=%s; no reviewer saw it; recorded in the marker under repos["%s"].uncovered\n' \
        "$cut" "$nfiles" "$max_hard" "$REPO"
      cursor="$cut"; continue
    fi

    if [[ ${#ALIVE[@]} -eq 0 ]]; then summary capacity_exhausted; exit 0; fi

    info="$ncommits commit(s), $nfiles changed file(s), bound $bound for $ch"
    [[ "$partial" -eq 1 ]] && info="$info; single commit over the bound, reviewed alone and recorded partially covered"
    if (( nfiles == 0 )); then summary range_empty; exit 0; fi
# A channel never reviews more files than ITS OWN bound (not the lowered
# --range-bound). A single oversized commit cut for CodeRabbit (150) would
# otherwise reach CodeAnt, which skips files past 15 and reads clean.
hard="$(range_hard_bound "$ch")"
if (( nfiles > hard )); then
  log "$REPO range $(short "$RANGE_FIRST")..$(short "$cut") refused for $ch: $nfiles files exceed its $hard-file bound"
  drop_channel "$ch"; continue
fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf 'would review range %s..%s commits=%s files=%s bound=%s channel=%s partial=%s\n' \
        "$(short "$RANGE_FIRST")" "$(short "$cut")" "$ncommits" "$nfiles" "$bound" "$ch" "$([[ $partial -eq 1 ]] && echo yes || echo no)"
      dry_count=$(( dry_count + 1 )); cursor="$cut"; continue
    fi

    rc2=0; range_review_channel "$cursor" "$cut" "$ch" || rc2=$?
    if [[ $rc2 -eq 3 ]]; then cleanup_worktree; summary window_closed; exit 0; fi
    if [[ $rc2 -eq 2 ]]; then cleanup_worktree; summary range_setup_failed; exit 0; fi
    if [[ $rc2 -eq 1 ]]; then cleanup_worktree; drop_channel "$ch"; continue; fi

    FINDINGS="$(python3 "$HELPER" normalize --tool "$ch" --log "$REVIEW_LOG" --repo "$REPO" --pr "")" || {
      cleanup_worktree; summary range_findings_unparsed; exit 0; }
    reported="$(printf '%s' "$REVIEW_JSON" | jq -r '.findings // 0')"
    parsed="$(jq length <<<"$FINDINGS")"
    if ! [[ "$reported" =~ ^[0-9]+$ && "$parsed" =~ ^[0-9]+$ ]] || (( parsed < reported )); then
      cleanup_worktree; summary range_findings_unparsed; exit 0
    fi

    # Bugs only; a bug with a location but no text is kept with placeholder
    # text; findings at one location share one issue quoting every text.
    BUGS="$(jq -c 'map(select(.bug == true and (.path // "") != ""))
      | map(if ((.text // "") | gsub("\\s"; "")) == ""
            then .text = "(the reviewer flagged this location as a bug but gave no description)" else . end)
      | group_by(.fingerprint)
      | map(.[0] + {text: (map(.text) | join("\n\n----- another finding at the same location -----\n\n"))})' <<<"$FINDINGS")"
    ISSUES='[]' ok=1
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      vline="$(verify_finding "$f" "$cut")"
      verdict="${vline%%$'\t'*}"; main_path="${vline#*$'\t'}"
      intro="$(safe_inline "$(range_introducer "$(jq -r .path <<<"$f")" "$cursor" "$cut")")"
      url="$(file_range_finding "$f" "$cursor" "$cut" "$verdict" "$main_path" "$intro" "$info")" && [[ -n "$url" ]] || { ok=0; break; }
      ISSUES="$(jq -c --arg u "$url" '. + [$u] | unique' <<<"$ISSUES")"
    done < <(jq -c '.[]' <<<"$BUGS")
    if [[ $ok -eq 0 ]]; then cleanup_worktree; summary range_filing_failed; exit 0; fi

    # Marker last: only a verified run whose findings were all parsed and filed.
    if ! range_marker_write "$cut" "$nfiles" "$bound" "$ch" "$partial"; then
      cleanup_worktree; summary range_marker_write_failed; exit 5
    fi
    REVIEWED=$(( REVIEWED + 1 ))
    if [[ "$(jq length <<<"$ISSUES")" -gt 0 ]]; then FILED=$(( FILED + 1 )); else CLEAN=$(( CLEAN + 1 )); fi
    log "$REPO range $RANGE_FIRST..$cut verified $info issues=$(jq -c . <<<"$ISSUES")"
    cleanup_worktree
    cursor="$cut"
  done
}

if [[ "$RANGE_MODE" -eq 1 ]]; then
  range_main
fi

for (( i = 0; i < $(jq length <<<"$PENDING"); i++ )); do
  row="$(jq -c ".[$i]" <<<"$PENDING")"
  pr="$(jq -r .pr <<<"$row")"; sha="$(jq -r .head_sha <<<"$row")"; merge="$(jq -r '.merge_commit_sha // ""' <<<"$row")"

  window_has_room || { summary window_closed; exit 0; }
  if [[ ${#ALIVE[@]} -eq 0 ]]; then summary capacity_exhausted; exit 0; fi
  if (( ATTEMPTS >= MAX_REVIEWS )); then summary max_reviews; exit 0; fi

  # A failed lookup or fetch is not "no merge commit": leave the row pending.
  # Only a successful answer that names no usable merge commit is a skip.
  if [[ -z "$merge" ]]; then
    if ! merge="$("$GH_BIN" pr view "$pr" --repo "$REPO" --json mergeCommit --jq '.mergeCommit.oid // ""' 2>/dev/null)"; then
      log "$REPO PR #$pr merge-commit lookup failed — left pending"; continue
    fi
  fi
  if [[ -n "$merge" ]] && ! git -C "$REPO_DIR" cat-file -e "$merge^{commit}" 2>/dev/null; then
    if ! git -C "$REPO_DIR" fetch --quiet origin "$merge" 2>>"$LOG"; then
      log "$REPO PR #$pr fetch of $merge failed — left pending"; continue
    fi
  fi
  # A merge commit whose first parent is absent locally (a shallow checkout)
  # is a fetch problem, not "no merge commit": fetch the parent by SHA, and
  # leave the row pending if it is still missing. Only a root commit (no
  # parent line at all) is a skip.
  parent=""
  if [[ -n "$merge" ]] && git -C "$REPO_DIR" cat-file -e "$merge^{commit}" 2>/dev/null; then
    parent="$(git -C "$REPO_DIR" cat-file -p "$merge" 2>/dev/null | sed -n 's/^parent \([0-9a-f]*\)$/\1/p' | head -n 1)"
    if [[ -n "$parent" ]] && ! git -C "$REPO_DIR" cat-file -e "$parent^{commit}" 2>/dev/null; then
      git -C "$REPO_DIR" fetch --quiet origin "$parent" 2>>"$LOG" || true
      if ! git -C "$REPO_DIR" cat-file -e "$parent^{commit}" 2>/dev/null; then
        log "$REPO PR #$pr first parent $parent of $merge unavailable — left pending"; continue
      fi
    fi
  fi
  if [[ -z "$merge" ]] || ! git -C "$REPO_DIR" cat-file -e "$merge^{commit}" 2>/dev/null \
     || [[ -z "$parent" ]]; then
    ledger_mark "$pr" "$sha" skipped "$(jq -cn --arg m "$merge" --arg now "$(date -u +%FT%TZ)" \
      '{skip_reason: ("merge commit unavailable: " + (if $m == "" then "none recorded" else $m end)), reviewed_at: $now, label_synced: false}')" \
      && { SKIPPED=$(( SKIPPED + 1 )); PENDING_LEFT=$(( PENDING_LEFT - 1 )); }
    continue
  fi

  review_entry "$merge" "$pr"; rc=$?
  if [[ $rc -ne 0 ]]; then
    cleanup_worktree
    if [[ $rc -eq 2 ]]; then log "$REPO PR #$pr worktree setup failed — left pending"; continue; fi
    if [[ $rc -eq 3 ]]; then summary window_closed; exit 0; fi
    if [[ ${#ALIVE[@]} -eq 0 ]]; then summary capacity_exhausted; else summary max_reviews; fi
    exit 0
  fi

  FINDINGS="$(python3 "$HELPER" normalize --tool "$REVIEW_TOOL" --log "$REVIEW_LOG" --repo "$REPO" --pr "$pr")" || {
    cleanup_worktree; row_failed "$row" "capture unparseable"; continue; }
  # A verified run whose findings did not all parse is not "clean": a lost
  # finding could be the one real bug.
  reported="$(printf '%s' "$REVIEW_JSON" | jq -r '.findings // 0')"
  parsed="$(jq length <<<"$FINDINGS")"
  if ! [[ "$reported" =~ ^[0-9]+$ && "$parsed" =~ ^[0-9]+$ ]] || (( parsed < reported )); then
    cleanup_worktree; row_failed "$row" "$reported finding(s) reported but $parsed parsed"; continue
  fi

  # A bug with a location but no text (CodeAnt contentless finding) is still a
  # possible real bug: give it placeholder text, never drop it. Then group the
  # fileable bugs by fingerprint: findings at the same anchor share one marker,
  # so they are filed as ONE issue quoting every finding's text — the second is
  # never mistaken for "already filed" with its text lost.
  FINDINGS="$(jq -c 'map(if .bug == true and (.path // "") != "" and ((.text // "") | gsub("\\s"; "")) == ""
                          then .text = "(the reviewer flagged this location as a bug but gave no description)" else . end)' <<<"$FINDINGS")"
  ANCHOR_TEXT="$(jq -c '[.[] | select(.bug == true and (.path // "") != "")] | group_by(.fingerprint)
                        | map({key: .[0].fingerprint, value: (if length > 1
                              then (map(.text) | join("\n\n----- another finding at the same location -----\n\n"))
                              else null end)}) | from_entries' <<<"$FINDINGS")"
  RESULTS='[]' ISSUES='[]' FILED_AT='{}' ok=1
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    disp="" verdict="" url="" main_path=""
    if [[ "$(jq -r .bug <<<"$f")" != true ]]; then disp="dropped: below bug severity"
    elif [[ -z "$(jq -r '.path' <<<"$f")" ]]; then disp="dropped: no file anchor"
    else
      fp="$(jq -r .fingerprint <<<"$f")"
      vline="$(verify_finding "$f" "$merge")"
      verdict="${vline%%$'\t'*}"; main_path="${vline#*$'\t'}"
      prior="$(jq -r --arg k "$fp" '.[$k] // ""' <<<"$FILED_AT")"
      to_file="$f"
      if [[ "$(jq -r --arg k "$fp" '.[$k] | type' <<<"$ANCHOR_TEXT")" == string ]]; then
        to_file="$(jq -c --argjson a "$ANCHOR_TEXT" --arg k "$fp" '.text = $a[$k]' <<<"$f")"
      fi
      if [[ "$verdict" != still_present && "$verdict" != changed ]]; then ok=0; break
      elif [[ -n "$prior" ]]; then
        url="$prior"; disp="filed (same anchor as an earlier finding; quoted in its issue)"
      elif url="$(file_finding "$to_file" "$row" "$verdict" "$merge" "$main_path")" && [[ -n "$url" ]]; then
        disp="filed"; ISSUES="$(jq -c --arg u "$url" '. + [$u] | unique' <<<"$ISSUES")"
        FILED_AT="$(jq -c --arg k "$fp" --arg u "$url" '.[$k] = $u' <<<"$FILED_AT")"
      else ok=0; break
      fi
    fi
    RESULTS="$(jq -c --argjson f "$f" --arg d "$disp" --arg v "$verdict" --arg u "$url" --arg mp "$main_path" \
      '. + [{fingerprint: $f.fingerprint, tool: $f.tool, path: $f.path, line: $f.line, severity: $f.severity,
             verdict: (if $v == "" then null else $v end), main_path: (if $mp == "" then null else $mp end),
             disposition: $d, issue: (if $u == "" then null else $u end)}]' <<<"$RESULTS")"
  done < <(jq -c '.[]' <<<"$FINDINGS")
  if [[ $ok -eq 0 ]]; then
    cleanup_worktree; row_failed "$row" "filing or dedup lookup failed"; continue
  fi

  status=reviewed-clean
  [[ "$(jq length <<<"$ISSUES")" -gt 0 ]] && status=issues-filed
  # Ledger first, label second: a failed ledger write must never leave a PR
  # labelled reviewed while its row is still pending.
  synced=false
  detail="$(jq -cn --arg tool "$REVIEW_TOOL" --arg main "$MAIN_SHA" --arg merge "$merge" --arg now "$(date -u +%FT%TZ)" \
    --argjson findings "$RESULTS" --argjson issues "$ISSUES" --argjson synced "$synced" \
    '{channel: ($tool + "-cli"), main_sha: $main, merge_commit_sha: $merge, reviewed_at: $now,
      findings: $findings, issues: $issues, label_synced: $synced}')"
  if ledger_mark "$pr" "$sha" "$status" "$detail"; then
    REVIEWED=$(( REVIEWED + 1 )); PENDING_LEFT=$(( PENDING_LEFT - 1 ))
    if swap_label "$pr"; then
      synced=true
      ledger_mark "$pr" "$sha" "$status" "$(jq -c '.label_synced = true' <<<"$detail")" \
        || log "$REPO PR #$pr label swapped but label_synced update failed (next run re-swaps, a no-op)"
    fi
    if [[ "$status" == issues-filed ]]; then FILED=$(( FILED + 1 )); else CLEAN=$(( CLEAN + 1 )); fi
    log "$REPO PR #$pr $status issues=$(jq -c . <<<"$ISSUES") label_synced=$synced"
  else
    log "$REPO PR #$pr reviewed but the ledger write failed — left pending (the marker lookup stops a duplicate issue next run)"
  fi
  cleanup_worktree
done

summary "done"
exit 0
