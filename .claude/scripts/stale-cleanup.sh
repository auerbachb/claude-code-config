#!/usr/bin/env bash
# stale-cleanup.sh — Detect and optionally remove stale worktrees and branches.
#
# PURPOSE
#   Replaces the self-cleanup that /wrap used to do (worktree removal + branch
#   deletion in the running session). Runs out-of-band as part of /pm-update so
#   the active session never deletes itself. Detects three classes of stale
#   refs on the root repo:
#     1. Local worktrees whose HEAD commit is older than STALE_DAYS.
#     2. Local branches whose tip commit is older than STALE_DAYS.
#     3. Remote branches (refs/remotes/origin/*) whose tip commit is older
#        than STALE_DAYS.
#
#   Default mode is --check (dry-run). --apply performs the deletions only
#   for items that pass every safety check below. Nothing is ever deleted in
#   --check mode.
#
# SAFETY CHECKS (always applied; cannot be bypassed)
#   Worktrees:
#     - Skip the main worktree (root repo).
#     - Skip the worktree the caller is currently inside (resolved from $PWD).
#     - Skip if the worktree has uncommitted tracked changes (git diff).
#     - Skip if the worktree's branch has an open PR.
#   Local branches:
#     - Skip protected names: main, master, develop.
#     - Skip the current branch in any worktree (git refuses anyway).
#     - Skip branches checked out in any worktree.
#     - Skip branches with an open PR.
#   Remote branches:
#     - Skip protected names: main, master, develop, HEAD.
#     - Skip branches with an open PR.
#
# CONFIGURATION
#   STALE_DAYS — env var, default 7. Tip commits older than this are stale.
#
# USAGE
#   stale-cleanup.sh --check                    # dry-run (default)
#   stale-cleanup.sh --apply                    # delete stale items
#   stale-cleanup.sh --check --json             # machine-readable output
#   stale-cleanup.sh --help | -h
#
#   --check    Report stale items without deleting. Exit 0 if none, 1 if any.
#   --apply    Delete stale items that pass safety checks. Exit 0 on success
#              (or no stale items), 2 on partial failure.
#   --json     Emit a JSON object instead of human-readable text.
#
# OUTPUT (human-readable, default)
#   Stale worktrees (older than 7 days):
#     <path> (branch <branch>, last commit <YYYY-MM-DD>)
#     ...
#   Stale local branches (older than 7 days):
#     <branch> (last commit <YYYY-MM-DD>)
#   Stale remote branches (older than 7 days):
#     origin/<branch> (last commit <YYYY-MM-DD>)
#   Skipped (with reason):
#     <name> — <reason>
#
#   On --apply, each successful deletion is logged as "removed: <thing>" and
#   each failure as "failed: <thing> — <reason>".
#
# EXIT STATUS
#   0  No stale items, or --apply succeeded for all stale items.
#   1  --check found one or more stale items.
#   2  --apply hit one or more deletion failures (other items may have
#      succeeded — see output).
#   3  Usage error.
#   4  Environment error (cannot resolve repo, gh missing, etc.).

set -euo pipefail

print_help() {
  awk 'NR == 1 { next } /^$/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

usage_error() {
  echo "stale-cleanup.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 3
}

MODE="check"
JSON=0
MODE_SET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --check|--apply)
      if (( MODE_SET == 1 )); then
        usage_error "--check and --apply are mutually exclusive"
      fi
      MODE="${1#--}"
      MODE_SET=1
      shift
      ;;
    --json)
      JSON=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage_error "unknown flag: $1"
      ;;
    *)
      usage_error "unexpected positional argument: $1"
      ;;
  esac
done

STALE_DAYS="${STALE_DAYS:-7}"
if ! [[ "$STALE_DAYS" =~ ^[0-9]+$ ]] || (( STALE_DAYS < 1 )); then
  echo "error: STALE_DAYS must be a positive integer (got: $STALE_DAYS)" >&2
  exit 3
fi

NOW="$(date +%s)"
THRESHOLD=$(( NOW - STALE_DAYS * 86400 ))

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_SH="$SCRIPT_DIR/repo-root.sh"
if [[ ! -x "$REPO_ROOT_SH" ]]; then
  echo "error: repo-root.sh not found or not executable at $REPO_ROOT_SH" >&2
  exit 4
fi

ROOT=""
if ! ROOT="$("$REPO_ROOT_SH" "$SCRIPT_DIR" 2>/dev/null)"; then
  echo "error: could not resolve root repo" >&2
  exit 4
fi
if [[ -z "$ROOT" || ! -d "$ROOT" ]]; then
  echo "error: resolved root repo is empty or missing" >&2
  exit 4
fi

GIT=(git -C "$ROOT")

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not found — open-PR safety check requires it" >&2
  exit 4
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq not found — required for parsing gh JSON output and emit_json" >&2
  exit 4
fi

PROTECTED_BRANCHES=("main" "master" "develop")
is_protected() {
  local b="$1"
  for p in "${PROTECTED_BRANCHES[@]}"; do
    [[ "$b" == "$p" ]] && return 0
  done
  return 1
}

# Cache open-PR head refs once. `gh pr list --json headRefName` caps at 1000
# per call (gh's hard limit), so we paginate via `--search "is:open"` with
# created-time pagination by walking pages until we get a short page back.
# For typical repos (dozens to low-hundreds of open PRs) this is one round
# trip; for a repo with thousands of open PRs it stays correct without
# silently dropping entries.
OPEN_PR_BRANCHES=""
gh_pr_page() {
  # gh pr list with --json forces non-interactive mode; --limit 1000 is the
  # max gh accepts per call. We use the search API via --search to enable
  # cursor-style pagination through `created:<timestamp` filters.
  local cursor="$1"
  local query="state:open"
  if [[ -n "$cursor" ]]; then
    query="$query created:<$cursor"
  fi
  gh pr list --search "$query" --limit 1000 --json headRefName,createdAt 2>/dev/null
}
fetch_open_prs() {
  local cursor=""
  local prev_cursor=""
  local accumulated=""
  while :; do
    local page
    page="$(gh_pr_page "$cursor")" || break
    [[ "$page" == "[]" || -z "$page" ]] && break
    local refs
    refs="$(printf '%s' "$page" | jq -r '.[].headRefName' 2>/dev/null || true)"
    if [[ -n "$refs" ]]; then
      if [[ -z "$accumulated" ]]; then
        accumulated="$refs"
      else
        accumulated="$accumulated"$'\n'"$refs"
      fi
    fi
    # Page < 1000 entries means no more results.
    local count
    count="$(printf '%s' "$page" | jq 'length' 2>/dev/null || echo 0)"
    (( count < 1000 )) && break
    # Advance cursor to the oldest createdAt we just saw.
    prev_cursor="$cursor"
    cursor="$(printf '%s' "$page" | jq -r '[.[].createdAt] | min' 2>/dev/null || echo "")"
    [[ -z "$cursor" || "$cursor" == "null" ]] && break
    # Guard against pathological case where 1000+ PRs share the same
    # createdAt timestamp — without this check we'd refetch the same page
    # forever. In practice 1000 collisions is impossible (timestamps have
    # second resolution and PR creation is rate-limited), but the bound
    # makes the loop demonstrably terminating.
    if [[ "$cursor" == "$prev_cursor" ]]; then
      break
    fi
  done
  printf '%s' "$accumulated"
}
OPEN_PR_BRANCHES="$(fetch_open_prs)"
has_open_pr() {
  local b="$1"
  [[ -z "$OPEN_PR_BRANCHES" ]] && return 1
  printf '%s\n' "$OPEN_PR_BRANCHES" | grep -Fxq "$b"
}

# Resolve "where am I right now?" so we never delete the caller's own worktree
# even if its HEAD commit happens to be older than STALE_DAYS (e.g., long-lived
# branch the user is actively working on).
CALLER_PWD="$(pwd -P 2>/dev/null || pwd)"
caller_in_worktree() {
  local wt="$1"
  # Resolve symlinks in both paths so we compare canonicalized forms.
  local wt_real
  wt_real="$(cd "$wt" 2>/dev/null && pwd -P || echo "$wt")"
  [[ "$CALLER_PWD" == "$wt_real" || "$CALLER_PWD" == "$wt_real"/* ]]
}

# Compatibility note: macOS ships bash 3.2, which has no associative arrays.
# Worktree records are stored as one delimited line per worktree in WORKTREES,
# and CHECKED_OUT_BRANCHES is a newline-joined string of branch names. We look
# up by linear scan / grep — fine for the dozens-of-worktrees scale we expect.
#
# Records use the ASCII unit separator (US, 0x1f) as the field delimiter
# instead of `|` — git refnames and filesystem paths can both contain `|`
# but never US, so parsing stays unambiguous regardless of input shape.
US=$'\x1f'
WORKTREES=()           # each entry: "is_main<US>path<US>branch<US>head_ts"
CHECKED_OUT_BRANCHES="" # newline-separated list of branches checked out anywhere

# `git worktree list --porcelain` emits records separated by blank lines:
#   worktree <path>
#   HEAD <sha>
#   branch refs/heads/<name>      (or `detached`)
parse_worktrees() {
  local cur_path="" cur_branch="" cur_head=""
  # `first` is intentionally accessible to the nested flush() below via bash's
  # dynamic scoping — flush() flips it to 0 after recording the first record
  # so subsequent records are tagged as non-main worktrees. Don't promote
  # `first` to global without also updating flush().
  local first=1
  flush() {
    if [[ -n "$cur_path" ]]; then
      local is_main=0
      if (( first == 1 )); then is_main=1; first=0; fi
      WORKTREES+=("${is_main}${US}${cur_path}${US}${cur_branch}${US}${cur_head}")
      if [[ -n "$cur_branch" ]]; then
        if [[ -z "$CHECKED_OUT_BRANCHES" ]]; then
          CHECKED_OUT_BRANCHES="$cur_branch"
        else
          CHECKED_OUT_BRANCHES="$CHECKED_OUT_BRANCHES"$'\n'"$cur_branch"
        fi
      fi
    fi
    cur_path=""; cur_branch=""; cur_head=""
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" ]]; then
      flush
      continue
    fi
    case "$line" in
      "worktree "*) cur_path="${line#worktree }" ;;
      "HEAD "*)
        local sha="${line#HEAD }"
        # Empty fallback (NOT 0) — 0 would compare as "ancient" against
        # THRESHOLD and force the worktree to be classified stale even
        # though we couldn't read its HEAD. Classification skips entries
        # with empty/non-numeric ts and logs the worktree.
        cur_head="$("${GIT[@]}" log -1 --format=%ct "$sha" 2>/dev/null || echo "")"
        ;;
      "branch refs/heads/"*) cur_branch="${line#branch refs/heads/}" ;;
      "detached") cur_branch="" ;;
    esac
  done < <("${GIT[@]}" worktree list --porcelain)
  flush
}

parse_worktrees

is_branch_checked_out() {
  local b="$1"
  [[ -z "$CHECKED_OUT_BRANCHES" ]] && return 1
  printf '%s\n' "$CHECKED_OUT_BRANCHES" | grep -Fxq "$b"
}

# Classify each worktree. Stale ⇔ not main, not the caller's, no uncommitted
# tracked changes, branch has no open PR, HEAD older than threshold.
STALE_WORKTREES=()
SKIPPED_WORKTREES=()
for record in "${WORKTREES[@]}"; do
  IFS="$US" read -r is_main wt branch ts <<<"$record"
  if (( is_main == 1 )); then
    SKIPPED_WORKTREES+=("${wt}${US}main worktree")
    continue
  fi
  if caller_in_worktree "$wt"; then
    SKIPPED_WORKTREES+=("${wt}${US}caller's current worktree")
    continue
  fi
  if [[ ! -d "$wt" ]]; then
    SKIPPED_WORKTREES+=("${wt}${US}directory missing — run 'git worktree prune'")
    continue
  fi
  # Tracked-only dirty detection inside the worktree.
  if ! git -C "$wt" diff --quiet 2>/dev/null \
     || ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
    SKIPPED_WORKTREES+=("${wt}${US}uncommitted tracked changes")
    continue
  fi
  if [[ -n "$branch" ]] && has_open_pr "$branch"; then
    SKIPPED_WORKTREES+=("${wt}${US}open PR on branch $branch")
    continue
  fi
  # Unreadable HEAD (`git log -1 --format=%ct` failed): conservatively
  # skip rather than treating as ancient and deleting.
  if [[ -z "$ts" ]] || ! [[ "$ts" =~ ^[0-9]+$ ]]; then
    SKIPPED_WORKTREES+=("${wt}${US}HEAD unreadable — cannot determine staleness")
    continue
  fi
  if (( ts > THRESHOLD )); then
    continue  # fresh — not stale, not skipped (just normal)
  fi
  STALE_WORKTREES+=("${wt}${US}${branch}${US}${ts}")
done

# Local branches: any refs/heads entry whose tip is older than threshold.
STALE_LOCAL_BRANCHES=()
SKIPPED_LOCAL_BRANCHES=()
while IFS="$US" read -r branch ts; do
  [[ -z "$branch" ]] && continue
  if is_protected "$branch"; then
    SKIPPED_LOCAL_BRANCHES+=("${branch}${US}protected")
    continue
  fi
  if is_branch_checked_out "$branch"; then
    SKIPPED_LOCAL_BRANCHES+=("${branch}${US}checked out in a worktree")
    continue
  fi
  if has_open_pr "$branch"; then
    SKIPPED_LOCAL_BRANCHES+=("${branch}${US}open PR")
    continue
  fi
  if (( ts > THRESHOLD )); then
    continue
  fi
  STALE_LOCAL_BRANCHES+=("${branch}${US}${ts}")
done < <("${GIT[@]}" for-each-ref --format="%(refname:short)${US}%(committerdate:unix)" refs/heads/)

# Remote branches under origin/. Skip the symbolic origin/HEAD and protected
# names. We do NOT auto-fetch — that's a network operation the caller can run
# explicitly before invoking this script. Stale state on a stale fetch is
# still real signal.
STALE_REMOTE_BRANCHES=()
SKIPPED_REMOTE_BRANCHES=()
while IFS="$US" read -r ref ts; do
  [[ -z "$ref" ]] && continue
  # ref is e.g. "origin/feature-x"; strip leading origin/.
  case "$ref" in
    origin/HEAD) continue ;;
    origin/*) branch="${ref#origin/}" ;;
    *) continue ;;
  esac
  if is_protected "$branch"; then
    SKIPPED_REMOTE_BRANCHES+=("${ref}${US}protected")
    continue
  fi
  if has_open_pr "$branch"; then
    SKIPPED_REMOTE_BRANCHES+=("${ref}${US}open PR")
    continue
  fi
  if (( ts > THRESHOLD )); then
    continue
  fi
  STALE_REMOTE_BRANCHES+=("${ref}${US}${ts}")
done < <("${GIT[@]}" for-each-ref --format="%(refname:short)${US}%(committerdate:unix)" refs/remotes/origin/)

ts_to_date() {
  # Portable across BSD/GNU date: read a unix ts on stdin, emit YYYY-MM-DD.
  local ts="$1"
  if date -r "$ts" +%Y-%m-%d 2>/dev/null; then return; fi
  date -d "@$ts" +%Y-%m-%d 2>/dev/null || echo "?"
}

emit_text() {
  echo "Stale threshold: ${STALE_DAYS} days (commits before $(ts_to_date "$THRESHOLD"))"
  echo
  if (( ${#STALE_WORKTREES[@]} == 0 )); then
    echo "Stale worktrees: none"
  else
    echo "Stale worktrees:"
    for entry in "${STALE_WORKTREES[@]}"; do
      IFS="$US" read -r p b t <<<"$entry"
      printf '  %s (branch %s, last commit %s)\n' "$p" "${b:-detached}" "$(ts_to_date "$t")"
    done
  fi
  if (( ${#STALE_LOCAL_BRANCHES[@]} == 0 )); then
    echo "Stale local branches: none"
  else
    echo "Stale local branches:"
    for entry in "${STALE_LOCAL_BRANCHES[@]}"; do
      IFS="$US" read -r b t <<<"$entry"
      printf '  %s (last commit %s)\n' "$b" "$(ts_to_date "$t")"
    done
  fi
  if (( ${#STALE_REMOTE_BRANCHES[@]} == 0 )); then
    echo "Stale remote branches: none"
  else
    echo "Stale remote branches:"
    for entry in "${STALE_REMOTE_BRANCHES[@]}"; do
      IFS="$US" read -r r t <<<"$entry"
      printf '  %s (last commit %s)\n' "$r" "$(ts_to_date "$t")"
    done
  fi
  local skipped_total=$(( ${#SKIPPED_WORKTREES[@]} + ${#SKIPPED_LOCAL_BRANCHES[@]} + ${#SKIPPED_REMOTE_BRANCHES[@]} ))
  if (( skipped_total > 0 )); then
    echo
    echo "Skipped (safety):"
    for entry in "${SKIPPED_WORKTREES[@]}"; do
      IFS="$US" read -r p reason <<<"$entry"
      printf '  worktree %s — %s\n' "$p" "$reason"
    done
    for entry in "${SKIPPED_LOCAL_BRANCHES[@]}"; do
      IFS="$US" read -r b reason <<<"$entry"
      printf '  branch %s — %s\n' "$b" "$reason"
    done
    for entry in "${SKIPPED_REMOTE_BRANCHES[@]}"; do
      IFS="$US" read -r r reason <<<"$entry"
      printf '  remote %s — %s\n' "$r" "$reason"
    done
  fi
}

emit_json() {
  local wt_json="[]" lb_json="[]" rb_json="[]"
  local sw_json="[]" sl_json="[]" sr_json="[]"
  if (( ${#STALE_WORKTREES[@]} > 0 )); then
    wt_json="$(printf '%s\n' "${STALE_WORKTREES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {path:.[0], branch:.[1], last_commit_ts:(.[2]|tonumber)}]')"
  fi
  if (( ${#STALE_LOCAL_BRANCHES[@]} > 0 )); then
    lb_json="$(printf '%s\n' "${STALE_LOCAL_BRANCHES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {branch:.[0], last_commit_ts:(.[1]|tonumber)}]')"
  fi
  if (( ${#STALE_REMOTE_BRANCHES[@]} > 0 )); then
    rb_json="$(printf '%s\n' "${STALE_REMOTE_BRANCHES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {ref:.[0], last_commit_ts:(.[1]|tonumber)}]')"
  fi
  if (( ${#SKIPPED_WORKTREES[@]} > 0 )); then
    sw_json="$(printf '%s\n' "${SKIPPED_WORKTREES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {path:.[0], reason:.[1]}]')"
  fi
  if (( ${#SKIPPED_LOCAL_BRANCHES[@]} > 0 )); then
    sl_json="$(printf '%s\n' "${SKIPPED_LOCAL_BRANCHES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {branch:.[0], reason:.[1]}]')"
  fi
  if (( ${#SKIPPED_REMOTE_BRANCHES[@]} > 0 )); then
    sr_json="$(printf '%s\n' "${SKIPPED_REMOTE_BRANCHES[@]}" \
      | jq -Rn --arg D "$US" '[inputs | split($D) | {ref:.[0], reason:.[1]}]')"
  fi
  jq -n --argjson wt "$wt_json" --argjson lb "$lb_json" --argjson rb "$rb_json" \
        --argjson sw "$sw_json" --argjson sl "$sl_json" --argjson sr "$sr_json" \
        --arg threshold_days "$STALE_DAYS" \
        --arg threshold_ts "$THRESHOLD" \
        '{stale_days:($threshold_days|tonumber),
          threshold_ts:($threshold_ts|tonumber),
          stale_worktrees:$wt,
          stale_local_branches:$lb,
          stale_remote_branches:$rb,
          skipped_worktrees:$sw,
          skipped_local_branches:$sl,
          skipped_remote_branches:$sr}'
}

if [[ "$MODE" == "check" ]]; then
  if (( JSON == 1 )); then emit_json; else emit_text; fi
  total=$(( ${#STALE_WORKTREES[@]} + ${#STALE_LOCAL_BRANCHES[@]} + ${#STALE_REMOTE_BRANCHES[@]} ))
  if (( total > 0 )); then exit 1; fi
  exit 0
fi

# --apply: delete each stale item, recording outcomes.
FAILURES=0
emit_text
echo

for entry in "${STALE_WORKTREES[@]}"; do
  IFS="$US" read -r p b _ <<<"$entry"
  # TOCTOU re-check: between classification (Phase --check) and apply, the
  # user may have started editing the worktree or opened a PR on its
  # branch. Re-run the same safety checks used during classification and
  # skip if anything has changed — losing user work to a stale dry-run is
  # a much bigger problem than skipping a deletion.
  if [[ -d "$p" ]] && { ! git -C "$p" diff --quiet 2>/dev/null \
       || ! git -C "$p" diff --cached --quiet 2>/dev/null; }; then
    echo "skipped: worktree $p (became dirty after dry-run)"
    continue
  fi
  if [[ -n "$b" ]] && has_open_pr "$b"; then
    echo "skipped: worktree $p (open PR on branch $b appeared after dry-run)"
    continue
  fi
  if out="$("${GIT[@]}" worktree remove "$p" 2>&1)"; then
    echo "removed: worktree $p"
  else
    echo "failed: worktree $p — $out"
    FAILURES=$(( FAILURES + 1 ))
  fi
done

for entry in "${STALE_LOCAL_BRANCHES[@]}"; do
  IFS="$US" read -r b _ <<<"$entry"
  if out="$("${GIT[@]}" branch -D "$b" 2>&1)"; then
    echo "removed: local branch $b"
  else
    echo "failed: local branch $b — $out"
    FAILURES=$(( FAILURES + 1 ))
  fi
done

for entry in "${STALE_REMOTE_BRANCHES[@]}"; do
  IFS="$US" read -r ref _ <<<"$entry"
  branch="${ref#origin/}"
  if out="$("${GIT[@]}" push origin --delete "$branch" 2>&1)"; then
    echo "removed: remote branch $branch"
  else
    echo "failed: remote branch $branch — $out"
    FAILURES=$(( FAILURES + 1 ))
  fi
done

if (( FAILURES > 0 )); then exit 2; fi
exit 0
