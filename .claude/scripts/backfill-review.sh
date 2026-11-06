#!/usr/bin/env bash
# backfill-review.sh — overnight backfill review of PRs merged without an AI review (issue #1900).
# catalog: merge-gate-sequencing — Review merges logged by the no-review override with the FREE local CLIs only, file deduped issues for real bugs, mark each ledger row reviewed
#
# USAGE
#   backfill-review.sh [--repo-dir DIR] [--window HH:MM-HH:MM] [--tz ZONE]
#                      [--now ISO8601] [--ignore-window] [--channels LIST]
#                      [--max-reviews N] [--timeout SEC] [--dry-run]
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
#   pending. Only a completed review marks a row reviewed.
#
# OPTIONS
#   --repo-dir DIR     git checkout of the repo to backfill (default: cwd)
#   --repo owner/name  ledger repo key (default: derived from the origin URL;
#                      must match a GitHub origin, else exit 2)
#   --window W         quiet window, local time (default BACKFILL_REVIEW_WINDOW
#                      or 01:00-06:00; may cross midnight)
#   --tz ZONE          window time zone (default BACKFILL_REVIEW_TZ or
#                      America/New_York)
#   --now ISO8601      evaluate the window at this instant (tests)
#   --ignore-window    run now, whatever the time (a manual run)
#   --channels LIST    comma list from {coderabbit,codeant}, in try order
#                      (default BACKFILL_REVIEW_CHANNELS or coderabbit,codeant)
#   --max-reviews N    stop after N CLI review attempts this run (default 3 —
#                      the CodeRabbit CLI's hourly allowance)
#   --timeout SEC      local-review.sh idle bound per review (default 900)
#   --dry-run          list what would be reviewed; review, file, label nothing
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
#   0 completed (including a capacity stop, a closed window, a held lock)
#   2 usage · 3 a required tool or helper is missing · 4 ledger unreadable

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
DRY_RUN=0

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
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done
MAX_REVIEWS=$(( 10#$MAX_REVIEWS ))

# Channels: the hard-coded allowlist, narrowed (never widened) by config.
CHANNELS=()
IFS=',' read -r -a _req <<<"$CHANNELS_RAW"
for c in "${_req[@]+"${_req[@]}"}"; do
  c="${c// /}"; c="${c%-cli}"
  case " $ALLOWED_CHANNELS " in
    *" $c "*) CHANNELS+=("$c") ;;
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
ORIGIN_SLUG=""
if [[ "$ORIGIN_URL" =~ ^(git@github\.com:|ssh://git@github\.com/|https://github\.com/) ]]; then
  ORIGIN_SLUG="$(printf '%s' "$ORIGIN_URL" | sed -E -e 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)##' -e 's#\.git$##' -e 's#/$##' | tr '[:upper:]' '[:lower:]')"
fi
[[ -n "$REPO" ]] || REPO="$ORIGIN_SLUG"
REPO="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"
[[ "$REPO" =~ ^[a-z0-9_.-]+/[a-z0-9_.-]+$ ]] || die 2 "cannot derive owner/name (origin: $ORIGIN_URL); pass --repo"
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
minutes_left() { # prints minutes left in the window; non-zero outside it
  local args=(window --window "$WINDOW" --tz "$TZONE")
  [[ -n "$NOW_ARG" ]] && args+=(--now "$NOW_ARG")
  python3 "$HELPER" "${args[@]}"
}
if [[ "$IGNORE_WINDOW" -eq 0 ]]; then
  LEFT="$(minutes_left)"; rc=$?
  [[ $rc -eq 2 ]] && die 2 "invalid --window '$WINDOW' or --tz '$TZONE'"
  if [[ $rc -ne 0 ]]; then summary outside_window; exit 0; fi
  log "$REPO window $WINDOW $TZONE open, ${LEFT}m left"
fi

# ---- single-owner run lock ---------------------------------------------------
# flock(2) on fd 9, taken by a python child: the lock belongs to the open file
# description, which this shell keeps open, so it is held until this process
# exits — however it dies — and there is no stale-PID takeover to race on.
RUN_LOCK="$HOME/.claude/backfill-review.flock"
SCRATCH=""
cleanup() {
  if [[ -n "$SCRATCH" && -d "$SCRATCH" ]]; then cleanup_worktree; fi
}
exec 9>>"$RUN_LOCK" || die 3 "cannot open lock file $RUN_LOCK"
if ! python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)' 2>/dev/null; then
  summary lock_held; exit 0   # held elsewhere, or unlockable: never run unlocked
fi
trap cleanup EXIT

# ---- pending rows ----------------------------------------------------------
ALL_ROWS="$("$LEDGER_SH" list --repo "$REPO")" || die 4 "ledger list failed"
PENDING="$(jq -c 'map(select(.backfill_status == "pending")) | sort_by(.merged_at // .recorded_at // "", .pr)' <<<"$ALL_ROWS")" \
  || die 4 "ledger list is not a JSON array"
PENDING_LEFT="$(jq 'length' <<<"$PENDING")"

ledger_mark() { # pr sha status detail-json
  printf '%s' "$4" | "$LEDGER_SH" backfill --repo "$REPO" --pr "$1" --sha "$2" --status "$3" --detail-json - >/dev/null
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
# is gone (stop the run), 2 on a per-entry setup failure (skip this run).
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

# verify_finding <finding-json> <merge_sha> — prints still_present | changed | removed
verify_finding() {
  local f="$1" merge="$2" path line text_at_merge
  path="$(jq -r .path <<<"$f")"; line="$(jq -r '.line // empty' <<<"$f")"
  git -C "$REPO_DIR" cat-file -e "$MAIN_SHA:$path" 2>/dev/null || { echo removed; return; }
  if git -C "$REPO_DIR" diff --quiet "$merge" "$MAIN_SHA" -- "$path" 2>/dev/null; then echo still_present; return; fi
  if [[ "$line" =~ ^[0-9]+$ ]]; then
    text_at_merge="$(git -C "$REPO_DIR" show "$merge:$path" 2>/dev/null | sed -n "${line}p")"
    if [[ -n "${text_at_merge//[[:space:]]/}" ]] \
       && grep -qxF -- "$text_at_merge" <<<"$(git -C "$REPO_DIR" show "$MAIN_SHA:$path" 2>/dev/null)"; then
      echo still_present; return
    fi
  fi
  echo changed
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

neutralize() { # stdin -> stdout: no @-mentions, no fence breakouts
  sed -e 's/@/@\&#8203;/g' -e 's/```/` ` `/g'
}
# safe_inline <text> — one line for an inline code span: no backtick, CR/LF, or @.
safe_inline() { printf '%s' "$1" | tr '\r\n`' "  '" | sed 's/@/(at)/g'; }

# file_finding <finding-json> <row-json> <verdict> <merge-sha> — prints the issue URL; non-zero = leave pending
file_finding() {
  local f="$1" row="$2" verdict="$3" merge="$4" fp marker url path line sev text title body dup dup_rc kw pr_url
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
    [[ "$verdict" == changed ]] && printf -- '- The file changed after the merge — confirm the finding still applies before fixing.\n'
    if [[ -n "$dup" ]]; then printf -- '- %s\n' "$dup"; fi
    printf -- '- Filed automatically; no reviewer was asked to re-review.\n\n%s\n\n' "$marker"
    printf '## Estimate\n\nEst: 15–30 min · plan on 30\n\n_Captured via /issue-maker._\n'
  } > "$body" || return 1
  ISSUE_FILE_GH="$GH_BIN" bash "$ISSUE_FILE" --repo "$REPO" --title "$title" --body-file "$body" --label bug --json 2>>"$LOG" \
    | jq -er '.url' || return 1
}

for (( i = 0; i < $(jq length <<<"$PENDING"); i++ )); do
  row="$(jq -c ".[$i]" <<<"$PENDING")"
  pr="$(jq -r .pr <<<"$row")"; sha="$(jq -r .head_sha <<<"$row")"; merge="$(jq -r '.merge_commit_sha // ""' <<<"$row")"

  if [[ "$IGNORE_WINDOW" -eq 0 && -z "$NOW_ARG" ]]; then
    LEFT="$(minutes_left)" || { summary window_closed; exit 0; }
    # local-review.sh caps a run at 2x its idle --timeout: reserve that much.
    (( LEFT * 60 < 2 * REVIEW_TIMEOUT )) && { summary window_closed; exit 0; }
  fi
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
  if [[ -z "$merge" ]] || ! git -C "$REPO_DIR" cat-file -e "$merge^{commit}" 2>/dev/null \
     || ! git -C "$REPO_DIR" cat-file -e "$merge^1^{commit}" 2>/dev/null; then
    ledger_mark "$pr" "$sha" skipped "$(jq -cn --arg m "$merge" --arg now "$(date -u +%FT%TZ)" \
      '{skip_reason: ("merge commit unavailable: " + (if $m == "" then "none recorded" else $m end)), reviewed_at: $now, label_synced: false}')" \
      && { SKIPPED=$(( SKIPPED + 1 )); PENDING_LEFT=$(( PENDING_LEFT - 1 )); }
    continue
  fi

  review_entry "$merge" "$pr"; rc=$?
  if [[ $rc -ne 0 ]]; then
    cleanup_worktree
    if [[ $rc -eq 2 ]]; then log "$REPO PR #$pr worktree setup failed — left pending"; continue; fi
    if [[ ${#ALIVE[@]} -eq 0 ]]; then summary capacity_exhausted; else summary max_reviews; fi
    exit 0
  fi

  FINDINGS="$(python3 "$HELPER" normalize --tool "$REVIEW_TOOL" --log "$REVIEW_LOG" --repo "$REPO" --pr "$pr")" || {
    log "$REPO PR #$pr capture unparseable — left pending"; cleanup_worktree; continue; }
  # A verified run whose findings did not all parse is not "clean": a lost
  # finding could be the one real bug.
  reported="$(printf '%s' "$REVIEW_JSON" | jq -r '.findings // 0')"
  parsed="$(jq length <<<"$FINDINGS")"
  if ! [[ "$reported" =~ ^[0-9]+$ && "$parsed" =~ ^[0-9]+$ ]] || (( parsed < reported )); then
    log "$REPO PR #$pr $reported finding(s) reported but $parsed parsed — left pending"; cleanup_worktree; continue
  fi

  RESULTS='[]' ISSUES='[]' ok=1
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    disp="" verdict="" url=""
    if [[ "$(jq -r .bug <<<"$f")" != true ]]; then disp="dropped: below bug severity"
    elif [[ -z "$(jq -r '.path' <<<"$f")" || -z "$(jq -r '.text | gsub("\\s"; "")' <<<"$f")" ]]; then disp="dropped: no file anchor or no text"
    else
      verdict="$(verify_finding "$f" "$merge")"
      if [[ "$verdict" == removed ]]; then disp="dropped: file gone on main"
      elif url="$(file_finding "$f" "$row" "$verdict" "$merge")" && [[ -n "$url" ]]; then
        disp="filed"; ISSUES="$(jq -c --arg u "$url" '. + [$u] | unique' <<<"$ISSUES")"
      else ok=0; break
      fi
    fi
    RESULTS="$(jq -c --argjson f "$f" --arg d "$disp" --arg v "$verdict" --arg u "$url" \
      '. + [{fingerprint: $f.fingerprint, tool: $f.tool, path: $f.path, line: $f.line, severity: $f.severity,
             verdict: (if $v == "" then null else $v end), disposition: $d, issue: (if $u == "" then null else $u end)}]' <<<"$RESULTS")"
  done < <(jq -c '.[]' <<<"$FINDINGS")
  if [[ $ok -eq 0 ]]; then
    log "$REPO PR #$pr filing or dedup lookup failed — left pending"; cleanup_worktree; continue
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
