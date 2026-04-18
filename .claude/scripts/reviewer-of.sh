#!/usr/bin/env bash
# reviewer-of.sh — Determine which reviewer (cr/bugbot/greptile) owns a PR.
#
# PURPOSE
#   Centralizes the reviewer-ownership resolution contract defined in
#   .claude/rules/cr-merge-gate.md (Step 1 — CR/BugBot/Greptile paths). Reads
#   .prs["<N>"].reviewer from ~/.claude/session-state.json first, falls back
#   to a live GitHub-history scan when the state file has no entry, and
#   optionally persists an explicit sticky assignment back to session-state.
#
#   Normalizes the legacy short form "g" (written by pre-C-14 skills) to
#   "greptile". Output is always one of: cr / bugbot / greptile / unknown.
#
# USAGE
#   reviewer-of.sh <pr_number>
#   reviewer-of.sh <pr_number> --sticky <cr|bugbot|greptile>
#   reviewer-of.sh --help | -h
#
# MODES
#   Default  — Session-state lookup → live-history fallback. Prints the
#              resolved reviewer on stdout. Does NOT mutate state.
#   --sticky <value>
#            — Skip detection; write <value> atomically to
#              .prs["<pr_number>"].reviewer in ~/.claude/session-state.json
#              (preserving all sibling keys) and print <value> on stdout.
#              Callers are responsible for choosing a chain-consistent value
#              (cr → bugbot → greptile is one-way down per bugbot.md /
#              greptile.md sticky-assignment rules).
#
# RESOLUTION ORDER (default mode)
#   1. ~/.claude/session-state.json  .prs["<N>"].reviewer — if present and
#      one of cr / bugbot / greptile / g, return that (normalizing g →
#      greptile). Unknown or empty values fall through to step 2.
#   2. Live history — collect distinct `user.login` values across the three
#      endpoints (pulls/reviews, pulls/comments, issues/comments, paginated):
#        • greptile-apps[bot] present → greptile
#        • cursor[bot] present AND coderabbitai[bot] absent → bugbot
#        • coderabbitai[bot] present → cr
#        • else → unknown (exit 1)
#      Matches the resolve_reviewer() logic in merge-gate.sh.
#
# OUTPUT
#   stdout: single word — one of cr / bugbot / greptile / unknown (no
#           trailing whitespace beyond the newline).
#   stderr: one-line error messages on failure.
#
# EXIT STATUS
#   0  Reviewer determined (printed on stdout). Also the success path for
#      --sticky writes.
#   1  Cannot determine — "unknown" printed on stdout, no matching bot
#      author found in session-state or live history.
#   2  Usage error (missing/invalid PR number, unknown flag, invalid
#      --sticky value).
#   3  PR not found (live-history fallback only — gh pr view returned a
#      not-found error).
#
# ATOMICITY (--sticky)
#   Writes go through `jq … > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp"
#   "$STATE_FILE"`. `mv` within the same filesystem is atomic on POSIX.
#   Sibling top-level keys (prs for other PRs, greptile_daily, cr_quota,
#   active_agents, etc.) are preserved by merging via jq's `.prs[$pr].reviewer
#   = $v` assignment rather than rewriting the whole object.
#
# DEPENDENCIES
#   - jq
#   - gh (only for the live-history fallback and PR-existence check)
#
# EXAMPLES
#   # Default: detect without persisting.
#   reviewer-of.sh 287
#   # -> cr
#
#   # Persist a sticky greptile assignment after CR+BugBot both failed.
#   reviewer-of.sh 287 --sticky greptile
#   # -> greptile  (also writes .prs["287"].reviewer = "greptile" to session-state)
#
#   # Unknown PR (no bot activity yet).
#   reviewer-of.sh 9999
#   # -> unknown  (exit 1)

set -uo pipefail

STATE_FILE="${HOME}/.claude/session-state.json"

print_help() {
  sed -n '/^# PURPOSE$/,/^# EXAMPLES$/p' "$0" | sed 's/^# \{0,1\}//'
}

die_usage() {
  echo "reviewer-of.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

# --- arg parsing ---
PR_NUMBER=""
STICKY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --sticky)
      if [[ $# -lt 2 || -z "${2-}" ]]; then
        die_usage "--sticky requires a value (cr|bugbot|greptile)"
      fi
      STICKY="$2"
      shift 2
      ;;
    --sticky=*)
      STICKY="${1#--sticky=}"
      if [[ -z "$STICKY" ]]; then
        die_usage "--sticky requires a value (cr|bugbot|greptile)"
      fi
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      die_usage "unknown flag: $1"
      ;;
    *)
      if [[ -n "$PR_NUMBER" ]]; then
        die_usage "unexpected positional argument: $1"
      fi
      PR_NUMBER="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUMBER" ]]; then
  die_usage "<pr_number> is required"
fi
if ! [[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  die_usage "<pr_number> must be a positive integer, got: $PR_NUMBER"
fi

if [[ -n "$STICKY" ]]; then
  case "$STICKY" in
    cr|bugbot|greptile) ;;
    *) die_usage "--sticky must be one of: cr, bugbot, greptile (got: $STICKY)" ;;
  esac
fi

# --- dependency check ---
if ! command -v jq >/dev/null 2>&1; then
  echo "reviewer-of.sh: 'jq' not found on PATH" >&2
  exit 2
fi

# --- atomic write helper (--sticky path) ---
# Writes .prs["$PR_NUMBER"].reviewer = "$1" to $STATE_FILE, preserving all
# sibling keys (other PRs, greptile_daily, cr_quota, active_agents, etc.).
# Creates the file with a minimal object if missing or corrupt.
write_sticky() {
  local value="$1"
  local state_dir
  state_dir="$(dirname "$STATE_FILE")"
  if ! mkdir -p "$state_dir" 2>/dev/null; then
    echo "reviewer-of.sh: could not create state dir: $state_dir" >&2
    exit 2
  fi

  local input_file="$STATE_FILE"
  local seeded_tmp=""
  if [[ ! -f "$STATE_FILE" ]] || ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    # File missing or corrupt — seed a temp file with an empty object so jq
    # has valid input. The original file (if any) is not modified until the
    # atomic mv at the end.
    seeded_tmp="$(mktemp)"
    printf '%s\n' '{}' > "$seeded_tmp"
    input_file="$seeded_tmp"
  fi

  local tmp="$STATE_FILE.tmp.$$"
  local jq_err
  jq_err="$(mktemp)"

  # Cleanup on any exit from this function onwards. Values are captured at
  # trap-definition time; we conditionally include seeded_tmp only when set.
  # shellcheck disable=SC2064
  if [[ -n "$seeded_tmp" ]]; then
    trap "rm -f '$tmp' '$jq_err' '$seeded_tmp' 2>/dev/null" EXIT
  else
    trap "rm -f '$tmp' '$jq_err' 2>/dev/null" EXIT
  fi

  if ! jq \
    --arg pr "$PR_NUMBER" \
    --arg rev "$value" \
    '.prs = ((.prs // {}) | .[$pr] = ((.[$pr] // {}) | .reviewer = $rev))
     | .last_updated = (now | todate)' \
    "$input_file" > "$tmp" 2>"$jq_err"; then
    echo "reviewer-of.sh: jq failed updating $STATE_FILE: $(cat "$jq_err")" >&2
    exit 2
  fi

  if ! mv "$tmp" "$STATE_FILE" 2>/dev/null; then
    echo "reviewer-of.sh: could not write $STATE_FILE" >&2
    exit 2
  fi
}

# --- --sticky short-circuit ---
# --sticky is authoritative: skip detection, persist, print.
if [[ -n "$STICKY" ]]; then
  write_sticky "$STICKY"
  printf '%s\n' "$STICKY"
  exit 0
fi

# --- session-state lookup (default mode, step 1) ---
if [[ -f "$STATE_FILE" ]] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
  FROM_STATE="$(jq -r --arg pr "$PR_NUMBER" '.prs[$pr].reviewer // ""' "$STATE_FILE" 2>/dev/null || echo "")"
  case "$FROM_STATE" in
    cr|bugbot|greptile)
      printf '%s\n' "$FROM_STATE"
      exit 0
      ;;
    g)
      # Legacy short form — normalize to full word.
      printf '%s\n' "greptile"
      exit 0
      ;;
    "" | *)
      # Empty or unrecognized — fall through to live scan.
      :
      ;;
  esac
fi

# --- live-history fallback (default mode, step 2) ---
if ! command -v gh >/dev/null 2>&1; then
  echo "reviewer-of.sh: 'gh' not found on PATH — cannot fall back to live history" >&2
  exit 2
fi

# Verify the PR exists. Distinguishes "not found" (exit 3) from generic gh
# errors. We use `gh api repos/{owner}/{repo}/pulls/$N` rather than
# `gh pr view --json number` because the latter has a quirk where it exits
# 0 and echoes `{"number":N}` even for PR numbers that don't exist.
PR_CHECK_ERR="$(mktemp)"
trap "rm -f '$PR_CHECK_ERR' 2>/dev/null" EXIT
if ! gh api "repos/{owner}/{repo}/pulls/$PR_NUMBER" >/dev/null 2>"$PR_CHECK_ERR"; then
  if grep -qi "http 404\|not found\|could not resolve\|no pull request\|no such" "$PR_CHECK_ERR"; then
    echo "reviewer-of.sh: PR #$PR_NUMBER not found" >&2
    exit 3
  fi
  echo "reviewer-of.sh: gh api failed: $(cat "$PR_CHECK_ERR")" >&2
  exit 2
fi

# Collect distinct bot authors across all three endpoints (paginated). Route
# errors through stderr so the resulting variable is clean.
AUTHORS="$(
  {
    gh api --paginate "repos/{owner}/{repo}/pulls/$PR_NUMBER/reviews?per_page=100" \
      --jq '.[]?.user.login // empty' 2>/dev/null
    gh api --paginate "repos/{owner}/{repo}/pulls/$PR_NUMBER/comments?per_page=100" \
      --jq '.[]?.user.login // empty' 2>/dev/null
    gh api --paginate "repos/{owner}/{repo}/issues/$PR_NUMBER/comments?per_page=100" \
      --jq '.[]?.user.login // empty' 2>/dev/null
  } | sort -u
)"

# Detection priority matches merge-gate.sh resolve_reviewer(): greptile wins
# over anything else (sticky); bugbot only when cursor is the sole reviewer
# (CR+cursor means CR is primary — BugBot auto-triggers on every push);
# otherwise cr if CR has any activity.
if printf '%s\n' "$AUTHORS" | grep -q '^greptile-apps\[bot\]$'; then
  printf '%s\n' "greptile"
  exit 0
fi
if printf '%s\n' "$AUTHORS" | grep -q '^cursor\[bot\]$' \
   && ! printf '%s\n' "$AUTHORS" | grep -q '^coderabbitai\[bot\]$'; then
  printf '%s\n' "bugbot"
  exit 0
fi
if printf '%s\n' "$AUTHORS" | grep -q '^coderabbitai\[bot\]$'; then
  printf '%s\n' "cr"
  exit 0
fi

printf '%s\n' "unknown"
exit 1
