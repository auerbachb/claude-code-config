#!/usr/bin/env bash
# forgotten-pr-triage.sh — detect + classify "forgotten" open PRs (issue #657).
#
# PURPOSE:
#   Surfaces the author's open PRs that have gone quiet — last activity older
#   than a threshold (default 3 days) — and recommends, per PR, whether to
#   close it or merge it. Consumed by /pm's startup triage block (rendered
#   after "## Your Open PRs"); strictly read-only, so /pm owns every mutation
#   behind its own confirmation gates.
#
# AGE BASIS:
#   "Forgotten" is measured against `updatedAt` (last activity), NOT
#   `createdAt` — a PR touched yesterday is not forgotten even if it was
#   opened last week. A PR is forgotten when its last activity is strictly
#   MORE than --days days ago.
#
# CLOSE CLASSIFIER (exactly two signals; first match wins, else "merge"):
#   1. linked-issue-closed — the PR body's `Closes/Fixes #N` issue is CLOSED
#      (via pr-issue-ref.sh + `gh issue view`). Rationale: "linked issue #N
#      closed". Checked first (cheap: no git fetch).
#   2. superseded / already in main — the PR contributes zero net-new commits
#      to main (all commits already landed, by reachability or patch-id
#      equivalence, so this also covers "another merged PR covers it"). Tested
#      with `git cherry <base> <pr-head>` counting `+` lines. Rationale:
#      "superseded / already in main".
#   CI/conflict state is deliberately NOT a close signal — a red or conflicted
#   PR classifies "merge" and fails the merge gate visibly downstream.
#
# USAGE:
#   forgotten-pr-triage.sh [--days N] [--author LOGIN] [--json]
#   forgotten-pr-triage.sh --help | -h
#
#   --days N        Forgotten threshold in days. Default 3. Non-numeric or
#                   non-positive values fall back to 3 with a stderr warning.
#   --author LOGIN  GitHub login whose open PRs are enumerated. Default "@me"
#                   (the authenticated user). /pm passes its resolved $GH_USER.
#   --json          Emit a JSON array on stdout. Default emits one
#                   tab-separated line per PR: "number\trecommendation\trationale".
#
# OUTPUT:
#   One record per forgotten PR. JSON record shape:
#     {"number": N, "title": "...", "url": "...", "headRefName": "...",
#      "updatedAt": "...Z", "age_days": N,
#      "recommendation": "close"|"merge", "rationale": "..."}
#   `rationale` is empty for "merge". Zero forgotten PRs is a valid result
#   (prints "[]" / no lines) — NOT an error.
#
# EXIT CODES (match backlog-staleness.sh — the consumer reads --json, so
# "found" is not a distinct code):
#   0  OK — ran to completion (including the zero-forgotten case)
#   2  Usage error (unknown flag, --days/--author requires a value)
#   3  Environment error (gh/jq/git missing or not a git repo; gh API failure)
#
# READ-ONLY CONTRACT:
#   No PR is closed/merged, no branch deleted, nothing pushed. Git fetches use
#   `--refmap=''` and land only in FETCH_HEAD + the object store — no
#   remote-tracking ref (e.g. origin/main), branch, index, or working-tree
#   change. "Read-only" is w.r.t. refs/branches/worktree/index/PRs.
#
# CONFIGURATION (env):
#   FORGOTTEN_REMOTE       git remote to fetch from. Default "origin".
#   FORGOTTEN_BASE_BRANCH  branch fetched (into FETCH_HEAD) as the "already in
#                          main" comparison base. Default "main".
#   FORGOTTEN_BASE_REF     optional explicit LOCAL ref used as the base instead
#                          of fetching (no ref writes). Handy for tests. Unset
#                          by default (the base branch is fetched).
#
# EXAMPLES:
#   .claude/scripts/forgotten-pr-triage.sh --json
#   .claude/scripts/forgotten-pr-triage.sh --days 7 --author octocat
#
# DEPENDENCIES:
#   - gh CLI (authenticated), git, jq, bash 3.2+ (macOS-compatible)

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

print_help() {
  # Print only the leading comment block (stops at the first non-comment line)
  # so usage text never bleeds into executable lines like `set -uo pipefail`.
  awk 'NR==1{next} !/^#/{exit} {sub(/^# ?/,""); print}' "$0"
}

err() {
  printf 'forgotten-pr-triage.sh: %s\n' "$1" >&2
}

DAYS=3
AUTHOR="@me"
EMIT_JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --days)
      if [ $# -lt 2 ] || [ -z "${2-}" ]; then
        err "--days requires a value"
        exit 2
      fi
      DAYS="$2"
      shift 2
      ;;
    --days=*)
      DAYS="${1#--days=}"
      shift
      ;;
    --author)
      if [ $# -lt 2 ] || [ -z "${2-}" ]; then
        err "--author requires a value"
        exit 2
      fi
      AUTHOR="$2"
      shift 2
      ;;
    --author=*)
      AUTHOR="${1#--author=}"
      shift
      ;;
    --json)
      EMIT_JSON=1
      shift
      ;;
    *)
      err "unknown flag: $1"
      err "Run with --help for usage."
      exit 2
      ;;
  esac
done

# Validate --days: non-numeric or non-positive falls back to 3 with a warning,
# rather than a hard failure (mirrors backlog-staleness.sh's --days handling).
case "$DAYS" in
  ''|*[!0-9]*)
    err "Invalid --days value '$DAYS', defaulting to 3 days"
    DAYS=3
    ;;
  *)
    if [ "$DAYS" -le 0 ]; then
      err "Threshold must be positive, defaulting to 3 days"
      DAYS=3
    fi
    ;;
esac

command -v gh >/dev/null 2>&1 || { err "gh CLI not found"; exit 3; }
command -v jq >/dev/null 2>&1 || { err "jq not found"; exit 3; }
command -v git >/dev/null 2>&1 || { err "git not found"; exit 3; }

# Supersession checks (signal a) need a real git repo for `git fetch` /
# `git cherry`. Without one, signal (a) simply never fires — linked-issue
# detection (signal b) still works — so a non-repo is a soft degrade, not a
# hard error. Track it and warn once.
GIT_OK=1
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  GIT_OK=0
  err "not inside a git repository — supersession (already-in-main) checks are skipped"
fi

REMOTE="${FORGOTTEN_REMOTE:-origin}"
BASE_BRANCH="${FORGOTTEN_BASE_BRANCH:-main}"
# Optional explicit LOCAL base ref (e.g. a test fixture ref). When set and
# resolvable it is used directly — no fetch, no ref writes.
BASE_REF_OVERRIDE="${FORGOTTEN_BASE_REF:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_ISSUE_REF="$SCRIPT_DIR/pr-issue-ref.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Portable ISO-8601 (…Z) → epoch seconds. BSD date first, GNU date fallback.
# Prints 0 when it cannot parse (caller treats 0 as "unparseable").
to_epoch() {
  local iso="$1"
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null \
    || date -u -d "$iso" +%s 2>/dev/null \
    || echo 0
}

# Resolve the comparison base once up front as a concrete commit SHA — never a
# persistent ref. `--refmap=''` keeps the fetch in FETCH_HEAD + the object store
# only (no origin/main remote-tracking write), so the script stays read-only;
# capturing the SHA now means later per-PR fetches that overwrite FETCH_HEAD
# don't disturb the base. Failure (offline, no remote) is non-fatal — signal (a)
# is simply skipped.
BASE_OK=0
BASE_SHA=""
if [ "$GIT_OK" -eq 1 ]; then
  if [ -n "$BASE_REF_OVERRIDE" ]; then
    BASE_SHA="$(git rev-parse --verify -q "${BASE_REF_OVERRIDE}^{commit}" 2>/dev/null || echo "")"
    [ -z "$BASE_SHA" ] && err "base ref override '$BASE_REF_OVERRIDE' does not resolve — supersession checks are skipped"
  elif git fetch --refmap='' -q "$REMOTE" "$BASE_BRANCH" >/dev/null 2>&1; then
    BASE_SHA="$(git rev-parse FETCH_HEAD 2>/dev/null || echo "")"
    [ -z "$BASE_SHA" ] && err "could not resolve fetched $REMOTE $BASE_BRANCH — supersession checks are skipped"
  else
    err "could not fetch $REMOTE $BASE_BRANCH — supersession checks are skipped"
  fi
  [ -n "$BASE_SHA" ] && BASE_OK=1
fi

# is_superseded <pr_number> — 0 (true) when the PR contributes zero net-new
# commits to BASE_REF, i.e. every commit is already reachable from or
# patch-equivalent to something on main. Non-zero otherwise, or when the PR
# head cannot be fetched (can't determine → not superseded → defaults to merge).
# Fetches into FETCH_HEAD only (a transient fetch artifact, always overwritten)
# so nothing persistent is written — keeps the script read-only.
is_superseded() {
  local n="$1"
  [ "$BASE_OK" -eq 1 ] || return 1
  # `refs/pull/N/head` resolves the PR's tip regardless of fork origin;
  # `--refmap=''` keeps it in FETCH_HEAD only (no ref written).
  if ! git fetch --refmap='' -q "$REMOTE" "refs/pull/$n/head" >/dev/null 2>&1; then
    return 1
  fi
  local head_sha
  head_sha="$(git rev-parse FETCH_HEAD 2>/dev/null)" || return 1
  [ -n "$head_sha" ] || return 1
  # `git cherry <upstream> <head>` prints one line per commit in <head>: `+`
  # when the change is NOT present upstream, `-` when an equivalent patch
  # already is. Zero `+` lines ⇒ nothing net-new ⇒ superseded / already in main.
  # Check cherry's own exit code FIRST: a failed cherry emits nothing, and
  # `grep -c` on empty input returns "0" — which would otherwise be misread as
  # "zero net-new commits" and wrongly recommend close.
  local cherry_out cherry_rc
  cherry_out="$(git cherry "$BASE_SHA" "$head_sha" 2>/dev/null)"; cherry_rc=$?
  [ "$cherry_rc" -eq 0 ] || return 1   # cherry failed → indeterminate → not superseded
  local plus
  plus="$(printf '%s\n' "$cherry_out" | grep -c '^+' || true)"
  [ "${plus:-1}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Enumerate the author's open PRs.
# ---------------------------------------------------------------------------
PR_LIMIT=200
if ! OPEN_PRS="$(gh pr list --state open --author "$AUTHOR" --limit "$PR_LIMIT" \
    --json number,title,updatedAt,headRefName,url 2>"$TMP/prs.err")"; then
  err "gh pr list (open, author=$AUTHOR) failed: $(cat "$TMP/prs.err")"
  exit 3
fi
if [ "$(printf '%s' "$OPEN_PRS" | jq 'length')" -eq "$PR_LIMIT" ]; then
  err "Open PR count hit the ${PR_LIMIT}-item fetch cap — results may be incomplete."
fi

NOW="$(date -u +%s)"
CUTOFF=$(( NOW - DAYS * 86400 ))

: > "$TMP/forgotten.jsonl"

# Iterate PRs. The pipe puts the loop in a subshell, so classifications are
# appended to a temp JSONL file (persists past the subshell) rather than a
# shell array — same pattern backlog-staleness.sh uses.
printf '%s' "$OPEN_PRS" \
  | jq -r '.[] | [(.number|tostring), .updatedAt, .headRefName, .url, .title] | @tsv' \
  | while IFS=$'\t' read -r NUM UPDATED HEADREF URL TITLE; do
      EPOCH="$(to_epoch "$UPDATED")"
      if [ "$EPOCH" -eq 0 ]; then
        err "could not parse updatedAt '$UPDATED' for PR #$NUM — skipping"
        continue
      fi
      # Forgotten ⇔ last activity strictly MORE than --days days ago.
      if [ "$EPOCH" -ge "$CUTOFF" ]; then
        continue
      fi
      AGE_DAYS=$(( (NOW - EPOCH) / 86400 ))

      REC="merge"
      RATIONALE=""

      # Signal (b): linked issue closed (cheap — no git). First match wins.
      ISSUE=""
      if [ -x "$PR_ISSUE_REF" ]; then
        ISSUE="$("$PR_ISSUE_REF" "$NUM" 2>/dev/null || true)"
      else
        err "pr-issue-ref.sh not found at $PR_ISSUE_REF — linked-issue signal skipped for #$NUM"
      fi
      if [ -n "$ISSUE" ]; then
        # Capture gh's own exit code: a network/auth/API failure must surface as
        # an indeterminate signal on stderr, not silently degrade into a normal
        # "merge" recommendation as though the issue were open.
        ISTATE="$(gh issue view "$ISSUE" --json state --jq '.state' 2>/dev/null)"; istate_rc=$?
        if [ "$istate_rc" -ne 0 ]; then
          err "could not fetch issue #$ISSUE state for PR #$NUM (gh exit $istate_rc) — linked-issue close signal skipped for this PR"
        elif [ "$ISTATE" = "CLOSED" ]; then
          REC="close"
          RATIONALE="linked issue #$ISSUE closed"
        fi
      fi

      # Signal (a): superseded / already in main (only if not already close).
      if [ "$REC" = "merge" ] && is_superseded "$NUM"; then
        REC="close"
        RATIONALE="superseded / already in main"
      fi

      jq -cn \
        --arg num "$NUM" --arg title "$TITLE" --arg url "$URL" \
        --arg head "$HEADREF" --arg updated "$UPDATED" \
        --arg age "$AGE_DAYS" --arg rec "$REC" --arg rat "$RATIONALE" '
        {number: ($num|tonumber), title: $title, url: $url,
         headRefName: $head, updatedAt: $updated, age_days: ($age|tonumber),
         recommendation: $rec, rationale: $rat}
      ' >> "$TMP/forgotten.jsonl"
    done

# ---------------------------------------------------------------------------
# Emit (sorted oldest-first so the most-forgotten surface at the top).
# ---------------------------------------------------------------------------
if [ "$EMIT_JSON" -eq 1 ]; then
  jq -c -s 'sort_by(.age_days) | reverse' "$TMP/forgotten.jsonl" 2>/dev/null || echo "[]"
else
  jq -r -s 'sort_by(.age_days) | reverse | .[] | [.number, .recommendation, .rationale] | @tsv' \
    "$TMP/forgotten.jsonl" 2>/dev/null || true
fi

exit 0
