#!/usr/bin/env bash
# churn-hotspots.sh — Detect multi-PR file churn and surface refactor candidates (issue #755).
#
# PURPOSE:
#   Some files are magnets: every feature passes through them, and any
#   long-lived branch that touches them pays a conflict tax on every sync. The
#   signal already sits in merge history — the same file appearing across many
#   distinct merged PRs in a short window — but nothing reads it, so hotspots
#   only surface when a human notices the pattern in a wrap-up summary.
#
#   This script reads that signal mechanically. It enumerates which files were
#   touched by which merged PRs inside a window, weights conflict rounds
#   recorded in session state, and reports every file whose churn score crosses
#   the threshold, along with any refactor-candidate issue already open for it.
#
#   It is READ-ONLY: it never creates an issue, posts a comment, or mutates
#   state. `/wrap` (Phase 3, Step 3.10a) consumes this output and owns the
#   file-or-comment decision, so the detector stays safe to run anywhere.
#
# USAGE:
#   churn-hotspots.sh [--since <date|ref>] [--threshold N] [--repo <owner/repo>]
#                     [--conflict-weight N] [--exclude <glob,glob>]
#                     [--no-default-excludes] [--source auto|git|gh]
#                     [--ref <ref>] [--fetch] [--pr-cap N] [--top N] [--json]
#   churn-hotspots.sh --help
#
#   --since <date|ref>   Window start. A date (YYYY-MM-DD) is used as-is; any
#                        other value is resolved as a git ref/SHA via its commit
#                        date. Default: 14 days back (via gh-window.sh).
#   --threshold N        Hotspot score threshold. Default 3.
#   --repo <owner/repo>  Target repo. Defaults to the current checkout. Naming a
#                        repo other than the checkout forces --source gh.
#   --ref <ref>          Scan this ref on the git path instead of the
#                        auto-resolved default branch. Exits 3 when it does not
#                        resolve — an explicit ref is never silently ignored.
#                        git path only (rejected with --source gh / --repo).
#                        Also exits 3 when the ref resolves but carries no
#                        PR-marked commits under --source auto: the gh fallback
#                        scans repo-wide and cannot honour a ref, so the run
#                        refuses rather than measuring something else.
#   --fetch              Best-effort `git fetch origin` before resolving the
#                        scan ref, so a stale remote-tracking ref cannot narrow
#                        the window. OFF by default: this script is otherwise
#                        read-only, and a blocking fetch inside /wrap is a
#                        hazard. A failed fetch is non-fatal (warned, not
#                        fatal); skipped when there is no `origin` remote.
#   --conflict-weight N  Score added per recorded conflict round. Default 2.
#   --exclude <globs>    Comma-separated globs to ignore, in addition to the
#                        defaults below.
#   --no-default-excludes  Drop the built-in exclusion list.
#   --source auto|git|gh   Enumeration source. Default auto (git, falling back
#                        to gh when git yields no PR-marked commits).
#   --pr-cap N           Max PRs to inspect on the gh path. Default 150.
#   --top N              Report only the N highest-scoring hotspots. Default 0
#                        (all). `total_hotspot_count` always reports the full
#                        pre-truncation count, so a bounded call never hides how
#                        much it dropped.
#   --json               Emit a single JSON object. Default emits TSV rows.
#
# SCORING (the documented weight — issue #755 AC 2):
#
#     score = distinct_pr_count + (conflict_weight * conflict_rounds)
#     hotspot  <=>  score >= threshold  AND  distinct_pr_count >= 2
#
#   With no recorded conflicts, `score == distinct_pr_count`, so the plain
#   reading ("files touched by >= N distinct merged PRs") holds exactly.
#
#   The `distinct_pr_count >= 2` floor is deliberate: without it, one PR that
#   re-resolved conflicts three times would score 1 + 2*3 = 7 and be reported as
#   "multi-PR churn" when only a single PR touched the file. Conflict rounds
#   accelerate a genuinely multi-PR file across the line; they can never
#   manufacture a hotspot on their own.
#
#   CALIBRATION. The default threshold of 3 is sensitive by design, and how many
#   files clear it scales with how busy the repo is. Measured on this repo over
#   a 14-day window covering 103 merged PRs: 63 files at threshold 3, 33 at 5,
#   16 at 8, 9 at 10. An active repo should raise --threshold; a quiet one
#   should leave it at 3. Callers that FILE on this output must bound their own
#   volume (see /wrap Step 3.10a, which files at most one new hotspot issue per
#   run and reports how many candidates the cap held back).
#
#   CONFLICT SIGNAL (best-effort). Rounds are read from session state per PR:
#   `.prs["<N>"].babysit.conflict_streak` (written by /babysit-pr when it
#   dispatches /fixpr for a conflicting PR) and the forward-compatible
#   `.prs["<N>"].conflict_rounds`. The LARGER of the two is used, never the sum,
#   so a babysit-driven /fixpr round is not double-counted. `conflict_streak` is
#   a resettable per-watcher streak, not a lifetime total, so it under-reports
#   as often as not. A missing state file, missing repo scope, or missing key
#   all read as 0 — which is what lets this run in a fresh clone with no session
#   history at all.
#
# DEFAULT EXCLUSIONS:
#   package-lock.json, yarn.lock, pnpm-lock.yaml, Cargo.lock, poetry.lock,
#   go.sum, CHANGELOG.md — generated or append-only files that churn by design
#   and are never refactor candidates. The list is deliberately universal;
#   repo-specific by-design churn (an index or catalog file every change edits)
#   belongs in --exclude, not baked in here.
#
# ENUMERATION:
#   git path (primary) — `git log --no-merges --name-only` over the window,
#     scoped to an EXPLICIT ref, never to the invoking checkout's `HEAD`. The
#     ref is resolved in order: --ref, `origin/HEAD` (honours a default branch
#     not named `main`), then `origin/main`, `origin/master`, `main`, `master`.
#     Nothing resolving degrades to `HEAD` with a loud warning, and every run
#     reports what it scanned (`scan_ref` / `scan_ref_source`). This matters
#     because callers run from a feature-branch worktree: that `HEAD` misses the
#     squash commits on the default branch and carries pre-squash commits the
#     default branch will never have (issue #861).
#     PR attribution: a squash-merged PR carries GitHub's appended `(#N)` marker
#     at the END of the subject, so ONLY a trailing marker counts. A leading
#     `type(#N):` conventional-commit prefix is an ISSUE reference — a subject
#     with only that (`docs(#838): summary`, the shape of every unsquashed
#     feature-branch commit here) contributes nothing. `fix(#749): x (#750)`
#     still attributes to 750. Zero API calls; works in a fresh clone.
#   gh path (fallback) — `gh pr list --state merged` plus per-PR
#     `pulls/{N}/files`, capped by --pr-cap. Used when the git path finds no
#     PR-marked commits (merge-commit or rebase-merge repos) or when --repo
#     names a different repo. This is the "works from gh data alone" path.
#   Renames are NOT followed: a renamed file appears as two paths. `git log
#   --follow` is single-path-only, so rename tracking is out of scope.
#   Files absent from the scanned tree are now dropped: a path from history that
#   no longer exists at the scanned ref (git path: `git cat-file -e`) or in the
#   working tree (gh path: `[ -e ]`) is silently skipped before it enters the
#   TSV stream. The count is reported as `missing_count` (a false-positive
#   guard — a deleted file is not a refactor candidate regardless of its score).
#
# EXISTING-ISSUE LOOKUP:
#   For each hotspot, issues in BOTH states (`--state all`) are searched for
#   `Refactor hotspot in:title` and matched CLIENT-SIDE on an exact title
#   (`Refactor hotspot: <path>`) or an exact body marker
#   (`<!-- churn-hotspot: <path> -->`). GitHub tokenizes paths in `in:title`
#   search, so a server-side path query can match a sibling file; searching
#   broadly and comparing exactly avoids that. When the lookup itself fails,
#   `existing_lookup_failed` is true in the output and callers must NOT file
#   (filing blind risks a duplicate).
#
#   CLOSED MATCHES ARE REPORTED, NOT DROPPED (issue #915). An open-only lookup
#   made an already-adjudicated hotspot invisible, so `/wrap` read it as
#   never-ticketed and re-filed it on every wrap, forever. Both states are now
#   returned, and `existing_hotspot_issue_state` says which one was matched, so
#   the caller can treat a closed match as a weak match instead of a blank slate.
#   When a path has BOTH an open and a closed issue, the OPEN one wins: that is
#   what keeps a re-file from looping, since the issue `/wrap` files becomes the
#   chosen match on the next run. This detector still decides nothing — it only
#   stops hiding the closed hit.
#
#   `--state all` enlarges the candidate set, so the ISSUE_LOOKUP_CAP guard below
#   matters MORE, not less. It is unchanged: a capped lookup still sets
#   `existing_lookup_failed` and blocks filing.
#
# OUTPUT:
#   Default: one TSV row per hotspot, no header —
#     path <TAB> pr_count <TAB> conflict_rounds <TAB> score <TAB> pr_numbers <TAB> existing_issue
#   (pr_numbers comma-separated; existing_issue is the issue number for an open
#   match, `<number> (closed)` for a closed one, `<number> (unknown)` when the
#   state could not be read, or "-" when there is no match. The suffix is there
#   so a person scanning the TSV cannot read a closed-issue hotspot as already
#   handled.)
#   --json: a single object with `repo`, `since`, `threshold`, `conflict_weight`,
#   `min_prs`, `source`, `scan_ref`, `scan_ref_source` (one of `explicit`,
#   `origin-head`, `candidate`, `head-fallback`, or `n/a` on the gh path),
#   `scanned_pr_count`, `excluded_count`, `missing_count` (paths dropped because
#   the file does not exist at the scanned ref or in the working tree), `truncated`,
#   `existing_lookup_failed`, `total_hotspot_count` (before any --top bound),
#   and `hotspots[]` (each: `file`, `pr_count`,
#   `pr_numbers`, `conflict_rounds`, `conflict_prs`, `score`, `first_merged_at`,
#   `last_merged_at`, `existing_hotspot_issue`, `existing_hotspot_issue_state`
#   — `"open"`, `"closed"`, `"unknown"` when a match was found but its state
#   could not be read, or null ONLY when there is no match at all. Null never
#   means "matched but unclassifiable": a caller may read `state == null` as
#   never-ticketed, which is precisely the bug issue #915 fixed).
#   Valid (possibly empty) output is emitted on every exit path.
#
# EXIT CODES:
#   0  At least one hotspot found
#   1  Clean — no file crossed the threshold
#   2  Usage error (unknown flag, missing or invalid value)
#   3  Environment error (missing dependency, not a git repo, no window,
#      unresolvable --ref, or a --ref the chosen enumeration path cannot honour)
#   4  gh/API error during enumeration
#
# EXAMPLES:
#   .claude/scripts/churn-hotspots.sh --json
#   .claude/scripts/churn-hotspots.sh --threshold 4 --since 2026-06-01
#   .claude/scripts/churn-hotspots.sh --exclude 'docs/*,*.md' --json \
#     | jq -r '.hotspots[] | "\(.file) \(.pr_count)"'
#
# DEPENDENCIES:
#   git, jq, bash 3.2+ (macOS-compatible — no associative arrays).
#   gh is required only for the gh enumeration path and the issue lookup.

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

print_help() {
  # Self-terminating: print the contiguous comment header and stop at the first
  # line that is not one. A hardcoded end line silently truncates help the next
  # time the header grows.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

err() {
  printf 'churn-hotspots.sh: %s\n' "$1" >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- defaults ---------------------------------------------------------------
SINCE=""
THRESHOLD=3
REPO=""
CONFLICT_WEIGHT=2
MIN_PRS=2
EXTRA_EXCLUDES=""
USE_DEFAULT_EXCLUDES=1
SOURCE_MODE="auto"
REF=""
DO_FETCH=0
PR_CAP=150
TOP=0
AS_JSON=0
ISSUE_LOOKUP_CAP=200

DEFAULT_EXCLUDES="package-lock.json,yarn.lock,pnpm-lock.yaml,Cargo.lock,poetry.lock,go.sum,CHANGELOG.md"

# ---- flag parsing (supports --flag value and --flag=value) ------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --since=*)            SINCE="${1#*=}" ;;
    --since)              shift; [ $# -gt 0 ] || { err "--since requires a value"; exit 2; }; SINCE="$1" ;;
    --threshold=*)        THRESHOLD="${1#*=}" ;;
    --threshold)          shift; [ $# -gt 0 ] || { err "--threshold requires a value"; exit 2; }; THRESHOLD="$1" ;;
    --repo=*)             REPO="${1#*=}" ;;
    --repo)               shift; [ $# -gt 0 ] || { err "--repo requires a value"; exit 2; }; REPO="$1" ;;
    --conflict-weight=*)  CONFLICT_WEIGHT="${1#*=}" ;;
    --conflict-weight)    shift; [ $# -gt 0 ] || { err "--conflict-weight requires a value"; exit 2; }; CONFLICT_WEIGHT="$1" ;;
    --exclude=*)          EXTRA_EXCLUDES="${1#*=}" ;;
    --exclude)            shift; [ $# -gt 0 ] || { err "--exclude requires a value"; exit 2; }; EXTRA_EXCLUDES="$1" ;;
    --no-default-excludes) USE_DEFAULT_EXCLUDES=0 ;;
    --source=*)           SOURCE_MODE="${1#*=}" ;;
    --source)             shift; [ $# -gt 0 ] || { err "--source requires a value"; exit 2; }; SOURCE_MODE="$1" ;;
    --ref=*)              REF="${1#*=}" ;;
    --ref)                shift; [ $# -gt 0 ] || { err "--ref requires a value"; exit 2; }; REF="$1" ;;
    --fetch)              DO_FETCH=1 ;;
    --pr-cap=*)           PR_CAP="${1#*=}" ;;
    --pr-cap)             shift; [ $# -gt 0 ] || { err "--pr-cap requires a value"; exit 2; }; PR_CAP="$1" ;;
    --top=*)              TOP="${1#*=}" ;;
    --top)                shift; [ $# -gt 0 ] || { err "--top requires a value"; exit 2; }; TOP="$1" ;;
    --json)               AS_JSON=1 ;;
    --help|-h)            print_help; exit 0 ;;
    *)                    err "unknown argument: $1"; exit 2 ;;
  esac
  shift
done

case "$THRESHOLD" in ''|*[!0-9]*) err "--threshold must be a non-negative integer"; exit 2 ;; esac
case "$CONFLICT_WEIGHT" in ''|*[!0-9]*) err "--conflict-weight must be a non-negative integer"; exit 2 ;; esac
case "$PR_CAP" in ''|*[!0-9]*) err "--pr-cap must be a non-negative integer"; exit 2 ;; esac
[ "$PR_CAP" -gt 0 ] || { err "--pr-cap must be positive"; exit 2; }
case "$TOP" in ''|*[!0-9]*) err "--top must be a non-negative integer"; exit 2 ;; esac
case "$SOURCE_MODE" in auto|git|gh) ;; *) err "--source must be one of: auto, git, gh"; exit 2 ;; esac

command -v jq >/dev/null 2>&1 || { err "jq is required but not installed"; exit 3; }
command -v git >/dev/null 2>&1 || { err "git is required but not installed"; exit 3; }

# ---- emit helpers -----------------------------------------------------------
# Every exit path emits valid (possibly empty) output before returning.
SOURCE_USED="$SOURCE_MODE"
SCAN_REF=""
SCAN_REF_SOURCE="n/a"
SCANNED_PR_COUNT=0
EXCLUDED_COUNT=0
MISSING_COUNT=0
TRUNCATED=false
LOOKUP_FAILED=false
TOTAL_HOTSPOT_COUNT=0
GIT_MARKED_COMMITS=0

# Coerce a counter variable to a bare integer in place. Every value handed to
# jq's --argjson must be valid JSON; a stray newline or blank from a counting
# pipeline would otherwise abort the emit with no usable output at all.
as_number() {  # $1 variable name
  local val
  eval "val=\${$1:-}"
  case "$val" in ''|*[!0-9]*) eval "$1=0" ;; esac
}

emit_and_exit() {  # $1 hotspots JSON array, $2 exit code
  local hotspots="$1" rc="$2"
  as_number SCANNED_PR_COUNT
  as_number EXCLUDED_COUNT
  as_number MISSING_COUNT
  as_number TOTAL_HOTSPOT_COUNT
  case "$hotspots" in ''|null) hotspots='[]' ;; esac
  if [ "$AS_JSON" -eq 1 ]; then
    jq -cn \
      --arg repo "$REPO" \
      --arg since "$SINCE" \
      --arg source "$SOURCE_USED" \
      --arg scan_ref "$SCAN_REF" \
      --arg scan_ref_source "$SCAN_REF_SOURCE" \
      --argjson threshold "$THRESHOLD" \
      --argjson conflict_weight "$CONFLICT_WEIGHT" \
      --argjson min_prs "$MIN_PRS" \
      --argjson scanned "$SCANNED_PR_COUNT" \
      --argjson excluded "$EXCLUDED_COUNT" \
      --argjson missing "$MISSING_COUNT" \
      --argjson truncated "$TRUNCATED" \
      --argjson lookup_failed "$LOOKUP_FAILED" \
      --argjson total "$TOTAL_HOTSPOT_COUNT" \
      --argjson hotspots "$hotspots" \
      '{repo:$repo, since:$since, source:$source,
        scan_ref:$scan_ref, scan_ref_source:$scan_ref_source, threshold:$threshold,
        conflict_weight:$conflict_weight, min_prs:$min_prs,
        scanned_pr_count:$scanned, excluded_count:$excluded, missing_count:$missing,
        truncated:$truncated, existing_lookup_failed:$lookup_failed,
        total_hotspot_count:$total, hotspots:$hotspots}'
  else
    printf '%s' "$hotspots" | jq -r '.[] | [
      .file, (.pr_count|tostring), (.conflict_rounds|tostring), (.score|tostring),
      (.pr_numbers|map(tostring)|join(",")),
      (if .existing_hotspot_issue == null then "-"
       elif .existing_hotspot_issue_state == "open"
         then (.existing_hotspot_issue|tostring)
       else ((.existing_hotspot_issue|tostring)
             + " (" + (.existing_hotspot_issue_state // "unknown") + ")") end)
    ] | @tsv'
  fi
  exit "$rc"
}

# ---- resolve repo -----------------------------------------------------------
IN_CHECKOUT=1
git rev-parse --show-toplevel >/dev/null 2>&1 || IN_CHECKOUT=0

CURRENT_REPO=""
if [ "$IN_CHECKOUT" -eq 1 ] && command -v gh >/dev/null 2>&1; then
  CURRENT_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
fi
if [ -z "$REPO" ]; then
  REPO="$CURRENT_REPO"
else
  # A --repo naming something other than this checkout cannot use git history.
  lc_repo=$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')
  lc_current=$(printf '%s' "$CURRENT_REPO" | tr '[:upper:]' '[:lower:]')
  if [ -z "$CURRENT_REPO" ] || [ "$lc_repo" != "$lc_current" ]; then
    if [ "$SOURCE_MODE" = "git" ]; then
      err "--source git cannot target --repo $REPO from this checkout"
      exit 2
    fi
    SOURCE_MODE="gh"
    IN_CHECKOUT=0
  fi
fi

REPO_ARGS=""   # bash 3.2-safe: expanded unquoted at the call site
[ -n "$REPO" ] && REPO_ARGS="--repo $REPO"

if [ "$SOURCE_MODE" = "git" ] && [ "$IN_CHECKOUT" -eq 0 ]; then
  err "--source git requires running inside a git checkout"
  exit 3
fi

# --ref and --fetch only mean anything on the git enumeration path. Accepting
# --ref silently on the gh path would let a caller believe it scoped a scan it
# did not scope, so that is a usage error; --fetch is merely inert, so it warns.
if [ "$SOURCE_MODE" = "gh" ] || [ "$IN_CHECKOUT" -eq 0 ]; then
  if [ -n "$REF" ]; then
    err "--ref applies to the git enumeration path only (not --source gh or a --repo outside this checkout)"
    exit 2
  fi
  [ "$DO_FETCH" -eq 1 ] && err "--fetch has no effect on the gh enumeration path — ignoring"
fi

# ---- resolve the scan ref ---------------------------------------------------
# NEVER scan a bare `HEAD` by default (issue #861). Callers run from a
# feature-branch worktree whose HEAD both MISSES the squash commits GitHub
# created on the default branch and CONTAINS pre-squash commits that branch will
# never have — so a HEAD-scoped scan can overcount and undercount at once.
# Resolution is deliberately independent of HEAD, so a worktree or a detached
# HEAD resolves the same ref as the root checkout.
resolve_scan_ref() {
  local cand branch
  # Fetch BEFORE resolving anything, --ref included: `--ref origin/main --fetch`
  # must validate the refreshed ref, not the stale one it would otherwise see.
  if [ "$DO_FETCH" -eq 1 ]; then
    if git remote get-url origin >/dev/null 2>&1; then
      GIT_TERMINAL_PROMPT=0 git fetch --quiet origin >/dev/null 2>&1 \
        || err "--fetch: 'git fetch origin' failed — continuing with the refs already on disk"
    else
      err "--fetch: no 'origin' remote — continuing with the refs already on disk"
    fi
  fi

  if [ -n "$REF" ]; then
    if ! git rev-parse --verify --quiet "${REF}^{commit}" >/dev/null 2>&1; then
      # An explicit ref that does not resolve is a hard error: silently scanning
      # something else is exactly the failure this flag exists to prevent.
      err "--ref '$REF' does not resolve to a commit in this checkout"
      exit 3
    fi
    SCAN_REF="$REF"; SCAN_REF_SOURCE="explicit"; return 0
  fi

  # origin/HEAD first: it names the remote's actual default branch, so a repo
  # whose default is not `main` resolves correctly without a hardcoded guess.
  cand=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo "")
  if [ -n "$cand" ] && git rev-parse --verify --quiet "${cand}^{commit}" >/dev/null 2>&1; then
    SCAN_REF="$cand"; SCAN_REF_SOURCE="origin-head"; return 0
  fi

  # Remote-tracking refs before local branches: a local `main` can lag origin.
  for cand in origin/main origin/master main master; do
    if git rev-parse --verify --quiet "${cand}^{commit}" >/dev/null 2>&1; then
      SCAN_REF="$cand"; SCAN_REF_SOURCE="candidate"; return 0
    fi
  done

  # Last resort — the pre-#861 behaviour, but never silent. Reaching here means
  # the repo has NO origin remote AND no main/master branch, in which case the
  # checked-out branch is almost certainly the only long-lived one, so HEAD is
  # usually the right answer rather than the wrong one. That is why this warns
  # and reports (`scan_ref_source: head-fallback`) instead of exiting: a hard
  # failure here would refuse a correct scan in a local-only repo and take the
  # /wrap churn check down with it. Callers that cannot tolerate the ambiguity
  # read `scan_ref_source`, or pin the ref with --ref.
  SCAN_REF="HEAD"; SCAN_REF_SOURCE="head-fallback"
  branch=$(git symbolic-ref -q --short HEAD 2>/dev/null || echo "a detached HEAD")
  err "no default-branch ref resolved (tried origin/HEAD, origin/main, origin/master, main, master) — scanning ${branch}; counts may reflect unmerged branch history. Pass --ref <ref> to scan a specific ref."
  return 0
}

# ---- resolve window ---------------------------------------------------------
# A bare date is used as-is; anything else is resolved as a git ref/SHA.
if [ -z "$SINCE" ]; then
  GW="$SCRIPT_DIR/gh-window.sh"
  if [ -x "$GW" ] || [ -f "$GW" ]; then
    SINCE=$(bash "$GW" --days 14 --format date 2>/dev/null || echo "")
  fi
  if [ -z "$SINCE" ]; then
    SINCE=$(date -u -v-14d +%Y-%m-%d 2>/dev/null || date -u -d '14 days ago' +%Y-%m-%d 2>/dev/null || echo "")
  fi
  [ -n "$SINCE" ] || { err "could not compute the default 14-day window"; exit 3; }
else
  case "$SINCE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
      ;;
    *)
      if [ "$IN_CHECKOUT" -eq 1 ]; then
        REF_DATE=$(git log -1 --format=%cI "$SINCE" -- 2>/dev/null || echo "")
      else
        REF_DATE=""
      fi
      if [ -z "$REF_DATE" ]; then
        err "--since '$SINCE' is neither a YYYY-MM-DD date nor a resolvable git ref"
        exit 3
      fi
      SINCE="$REF_DATE"
      ;;
  esac
fi

# The window is day-granular on BOTH enumeration paths: `git log --since` takes
# the calendar date, and the gh path compares mergedAt's date portion against
# this. Keeping one canonical date string is what stops the two paths from
# disagreeing about the same --since value.
SINCE_DATE_ONLY="${SINCE:0:10}"

# ---- exclusion matching -----------------------------------------------------
EXCLUDE_LIST=""
[ "$USE_DEFAULT_EXCLUDES" -eq 1 ] && EXCLUDE_LIST="$DEFAULT_EXCLUDES"
if [ -n "$EXTRA_EXCLUDES" ]; then
  if [ -n "$EXCLUDE_LIST" ]; then EXCLUDE_LIST="$EXCLUDE_LIST,$EXTRA_EXCLUDES"; else EXCLUDE_LIST="$EXTRA_EXCLUDES"; fi
fi

is_excluded() {  # $1 path -> 0 when excluded
  local path="$1" pattern base
  [ -n "$EXCLUDE_LIST" ] || return 1
  base="${path##*/}"
  local OLD_IFS="$IFS"
  IFS=','
  for pattern in $EXCLUDE_LIST; do
    [ -n "$pattern" ] || continue
    # A bare filename pattern matches that file at any depth; a pattern with a
    # slash is matched against the full path.
    case "$pattern" in
      */*) case "$path" in $pattern) IFS="$OLD_IFS"; return 0 ;; esac ;;
      *)   case "$base" in $pattern) IFS="$OLD_IFS"; return 0 ;; esac
           case "$path" in $pattern) IFS="$OLD_IFS"; return 0 ;; esac ;;
    esac
  done
  IFS="$OLD_IFS"
  return 1
}

file_present() {  # $1 path -> 0 when the file exists at the scan target
  local file="$1"
  if [ -n "$SCAN_REF" ]; then
    git cat-file -e "${SCAN_REF}:${file}" 2>/dev/null
  else
    [ -e "$file" ]
  fi
}

# ---- enumeration ------------------------------------------------------------
# Both paths produce the same TSV stream on stdout: pr <TAB> merged_at <TAB> file
TOUCH_TSV=$(mktemp) || { err "could not create a temp file"; exit 3; }
SEEN_PRS=$(mktemp) || { err "could not create a temp file"; exit 3; }
cleanup() { rm -f "$TOUCH_TSV" "$SEEN_PRS"; }
trap cleanup EXIT

enumerate_git() {
  local line rest commit_date subject pr file
  # `@@C@@date@@S@@subject` marks a commit header; every other non-empty line is
  # a path. Plain ASCII sentinels, not control bytes: under bash 3.2 (macOS)
  # `${line#$'\x01'}` silently fails to strip even where the matching `case`
  # pattern succeeds, which leaked the byte into every timestamp. Nothing here
  # relies on ANSI-C quoting.
  while IFS= read -r line; do
    case "$line" in
      '@@C@@'*)
        rest="${line#@@C@@}"
        commit_date="${rest%%@@S@@*}"
        subject="${rest#*@@S@@}"
        # ONLY a TRAILING (#N) marker is a PR number — that is the suffix GitHub
        # appends when it squash-merges. A leading `type(#N):` prefix is an ISSUE
        # reference, so a subject carrying only that (every unsquashed
        # feature-branch commit under this repo's convention) yields no PR and
        # contributes nothing. `fix(#749): repair (#750)` still yields 750.
        pr=$(printf '%s' "$subject" | grep -oE '\(#[0-9]+\)[[:space:]]*$' 2>/dev/null | tr -dc '0-9')
        [ -n "$pr" ] && GIT_MARKED_COMMITS=$((GIT_MARKED_COMMITS + 1))
        ;;
      '')
        ;;
      *)
        file="$line"
        [ -n "${pr:-}" ] || continue
        if is_excluded "$file"; then
          EXCLUDED_COUNT=$((EXCLUDED_COUNT + 1))
          continue
        fi
        if ! file_present "$file"; then
          MISSING_COUNT=$((MISSING_COUNT + 1))
          continue
        fi
        printf '%s\t%s\t%s\n' "$pr" "$commit_date" "$file" >> "$TOUCH_TSV"
        printf '%s\n' "$pr" >> "$SEEN_PRS"
        ;;
    esac
  done < <(git -c core.quotePath=false log --no-merges --since="$SINCE" --name-only \
             --pretty=format:'@@C@@%cI@@S@@%s' "$SCAN_REF" 2>/dev/null)
}

enumerate_gh() {
  command -v gh >/dev/null 2>&1 || { err "gh is required for the gh enumeration path"; return 4; }
  local pr_json rc=0 owner_repo="$REPO"
  if [ -z "$owner_repo" ]; then
    owner_repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
    [ -n "$owner_repo" ] || { err "could not resolve owner/repo for the gh path"; return 4; }
    REPO="$owner_repo"
  fi

  pr_json=$(gh pr list --state merged --limit "$PR_CAP" \
              --json number,mergedAt $REPO_ARGS 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$pr_json" ]; then
    err "gh pr list failed for $owner_repo"
    return 4
  fi

  local total_merged
  total_merged=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null || echo 0)
  [ "$total_merged" -ge "$PR_CAP" ] && TRUNCATED=true

  # Compare CALENDAR DATE to calendar date, not instant to instant. --since is a
  # day-granular value (gh-window.sh anchors it to ET; a git ref resolves to that
  # commit's date), while mergedAt is a UTC instant. Stamping the date as
  # T00:00:00Z compared an ET-anchored day against a UTC midnight, so the same
  # --since produced a different window on the gh path than `git log --since`
  # gives on the git path. Day-granular comparison makes both paths agree and
  # stays inclusive at the start boundary (>=, never >).
  local in_window
  in_window=$(printf '%s' "$pr_json" | jq -r --arg since "$SINCE_DATE_ONLY" \
    '[.[] | select(.mergedAt != null and (.mergedAt[0:10]) >= $since)]
     | .[] | "\(.number)\t\(.mergedAt)"' 2>/dev/null)

  local pr merged_at files
  while IFS=$'\t' read -r pr merged_at; do
    [ -n "$pr" ] || continue
    files=$(gh api "repos/${owner_repo}/pulls/${pr}/files" --paginate \
              --jq '.[].filename' 2>/dev/null) || {
      err "gh api pulls/${pr}/files failed — skipping PR #${pr}"
      continue
    }
    printf '%s\n' "$pr" >> "$SEEN_PRS"
    local file
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      if is_excluded "$file"; then
        EXCLUDED_COUNT=$((EXCLUDED_COUNT + 1))
        continue
      fi
      if ! file_present "$file"; then
        MISSING_COUNT=$((MISSING_COUNT + 1))
        continue
      fi
      printf '%s\t%s\t%s\n' "$pr" "$merged_at" "$file" >> "$TOUCH_TSV"
    done <<< "$files"
  done <<< "$in_window"
  return 0
}

if [ "$SOURCE_MODE" = "git" ] || [ "$SOURCE_MODE" = "auto" ]; then
  if [ "$IN_CHECKOUT" -eq 1 ]; then
    resolve_scan_ref
    enumerate_git
    SOURCE_USED="git"
  fi
fi

# auto falls through to gh only when the git history carries no PR markers at
# all (merge-commit or rebase-merge repos). Gating on GIT_MARKED_COMMITS rather
# than an empty result matters: a run whose every touched path was excluded is a
# legitimate empty answer, not a reason to re-enumerate over the API.
if [ "$SOURCE_MODE" = "gh" ] || { [ "$SOURCE_MODE" = "auto" ] && [ "$GIT_MARKED_COMMITS" -eq 0 ]; }; then
  # An explicit --ref is a promise about WHAT gets measured, and the gh path
  # cannot keep it: it enumerates merged PRs repo-wide, so it would answer a
  # different question than the one asked. `--source gh --ref` is already
  # rejected up front (exit 2); reaching the same destination via the auto
  # fallback must not be softer just because it is discovered later. A stderr
  # warning is not enough — /wrap's documented call site is
  # `"$CHURN_SH" --json 2>/dev/null`, which discards it, leaving a repo-wide
  # scan wearing a caller-supplied ref's authority. That is exactly the
  # measuring-the-wrong-thing failure issue #861 exists to prevent.
  if [ -n "$REF" ]; then
    err "--ref '$REF' resolved, but carries no PR-marked commits, and --source auto's fallback (the gh path) enumerates merged PRs repo-wide and cannot honour a ref. Re-run with --source git to scan the ref as-is, or drop --ref to accept a repo-wide gh scan."
    exit 3
  fi
  : > "$TOUCH_TSV"
  : > "$SEEN_PRS"
  EXCLUDED_COUNT=0
  # The gh path enumerates merged PRs over the API — no ref is involved, and
  # reporting a leftover one would misdescribe what was scanned.
  SCAN_REF=""
  SCAN_REF_SOURCE="n/a"
  enumerate_gh
  GH_RC=$?
  if [ "$GH_RC" -ne 0 ]; then
    emit_and_exit '[]' 4
  fi
  SOURCE_USED="gh"
fi

# `grep -c` prints 0 AND exits 1 on an empty file, so a `|| echo 0` fallback
# would emit "0\n0" and break the --argjson call downstream. wc -l always
# exits 0; tr strips the padding BSD wc adds.
SCANNED_PR_COUNT=$(sort -u "$SEEN_PRS" 2>/dev/null | sed '/^$/d' | wc -l | tr -d '[:space:]')
as_number SCANNED_PR_COUNT

if [ ! -s "$TOUCH_TSV" ]; then
  emit_and_exit '[]' 1
fi

# ---- conflict rounds per PR -------------------------------------------------
# One session-state read for the whole run; per-PR lookups happen in jq.
CONFLICT_MAP='{}'
SESSION_STATE_SH=""
for candidate in \
  "$HOME/.claude/skills-worktree/.claude/scripts/session-state.sh" \
  "$HOME/.claude/scripts/session-state.sh" \
  "$SCRIPT_DIR/session-state.sh"; do
  if [ -x "$candidate" ]; then SESSION_STATE_SH="$candidate"; break; fi
done

if [ -n "$SESSION_STATE_SH" ]; then
  PRS_JSON=$("$SESSION_STATE_SH" ${REPO:+--repo "$REPO"} --get '.prs' 2>/dev/null) || PRS_JSON=""
  case "$PRS_JSON" in ''|null) PRS_JSON='{}' ;; esac
  # Larger of babysit.conflict_streak and conflict_rounds — never the sum, so a
  # babysit-driven /fixpr round is not double-counted.
  CONFLICT_MAP=$(printf '%s' "$PRS_JSON" | jq -c '
    if type == "object" then
      with_entries(
        .value |= ([ (.babysit.conflict_streak? // 0), (.conflict_rounds? // 0) ]
                   | map(if type == "number" then . else 0 end) | max)
      ) | with_entries(select(.value > 0))
    else {} end' 2>/dev/null) || CONFLICT_MAP='{}'
  case "$CONFLICT_MAP" in ''|null) CONFLICT_MAP='{}' ;; esac
fi

# ---- aggregate --------------------------------------------------------------
HOTSPOTS=$(jq -Rs -c \
  --argjson conflicts "$CONFLICT_MAP" \
  --argjson threshold "$THRESHOLD" \
  --argjson weight "$CONFLICT_WEIGHT" \
  --argjson min_prs "$MIN_PRS" '
  split("\n")
  | map(select(length > 0) | split("\t") | {pr: .[0], merged_at: .[1], file: .[2]})
  | group_by(.file)
  | map(
      (map(.pr) | unique) as $prs
      | ($prs | map($conflicts[.] // 0)) as $rounds
      | ($rounds | add // 0) as $conflict_rounds
      | ($prs | length) as $pr_count
      | {
          file: .[0].file,
          pr_count: $pr_count,
          pr_numbers: ($prs | map(tonumber? // .) | sort),
          conflict_rounds: $conflict_rounds,
          conflict_prs: [ $prs[] | select(($conflicts[.] // 0) > 0) | (tonumber? // .) ] | sort,
          score: ($pr_count + ($weight * $conflict_rounds)),
          first_merged_at: (map(.merged_at) | sort | .[0]),
          last_merged_at: (map(.merged_at) | sort | .[-1])
        }
    )
  | map(select(.pr_count >= $min_prs and .score >= $threshold))
  | sort_by(-.score, -.pr_count, .file)
' < "$TOUCH_TSV" 2>/dev/null) || HOTSPOTS=""

case "$HOTSPOTS" in ''|null) HOTSPOTS='[]' ;; esac

TOTAL_HOTSPOT_COUNT=$(printf '%s' "$HOTSPOTS" | jq 'length' 2>/dev/null || echo 0)
if [ "$TOTAL_HOTSPOT_COUNT" -eq 0 ]; then
  emit_and_exit '[]' 1
fi

# --top bounds what is REPORTED, never what was counted: total_hotspot_count
# keeps the full figure so a bounded call cannot look like a complete one.
if [ "$TOP" -gt 0 ] && [ "$TOTAL_HOTSPOT_COUNT" -gt "$TOP" ]; then
  HOTSPOTS=$(printf '%s' "$HOTSPOTS" | jq -c --argjson n "$TOP" '.[0:$n]' 2>/dev/null) || HOTSPOTS='[]'
  err "reporting the top ${TOP} of ${TOTAL_HOTSPOT_COUNT} hotspots (--top)"
fi

# ---- existing hotspot issue lookup -----------------------------------------
# Search broadly on the title convention, then match EXACTLY client-side:
# GitHub tokenizes paths in `in:title`, so a server-side path query can match a
# sibling file. When the lookup fails, callers must not file (duplicate risk).
#
# `--state all`, NOT `--state open` (issue #915). An open-only search hid every
# hotspot issue the owner had already reviewed and closed, so the caller read the
# path as never-ticketed and re-filed it on every run. Closed hits now come back
# labelled (see the merge below) and the caller decides. `--state all` enlarges
# the candidate set, which is exactly why the cap guard below stays.
CANDIDATE_ISSUES='[]'
if command -v gh >/dev/null 2>&1; then
  ISSUES_RAW=$(gh issue list --state all --search "Refactor hotspot in:title" \
                 --limit "$ISSUE_LOOKUP_CAP" --json number,title,body,state $REPO_ARGS 2>/dev/null) || ISSUES_RAW=""
  if [ -z "$ISSUES_RAW" ]; then
    LOOKUP_FAILED=true
  else
    CANDIDATE_ISSUES=$(printf '%s' "$ISSUES_RAW" | jq -c '.' 2>/dev/null) || { CANDIDATE_ISSUES='[]'; LOOKUP_FAILED=true; }
    ISSUE_HITS=$(printf '%s' "$CANDIDATE_ISSUES" | jq 'length' 2>/dev/null || echo 0)
    if [ "$ISSUE_HITS" -ge "$ISSUE_LOOKUP_CAP" ]; then
      # A capped lookup is an INCOMPLETE lookup: an existing hotspot issue may
      # sit beyond the cap, so absence of a match no longer proves absence of an
      # issue. Callers gate filing on existing_lookup_failed, so it must be set
      # here too — reporting only `truncated` would let a caller file a
      # duplicate for a hotspot that already has one.
      err "issue lookup hit the ${ISSUE_LOOKUP_CAP}-issue cap — an existing hotspot issue may have been missed; not safe to file"
      TRUNCATED=true
      LOOKUP_FAILED=true
    fi
  fi
else
  LOOKUP_FAILED=true
fi

# Collect EVERY title/marker match for the path, then prefer an open one. A path
# can carry both (a closed adjudication plus a later re-file), and picking the
# first hit in whatever order the search returned would report either at random.
# An unrecognized state reports the number with state `"unknown"` — never a
# dropped match, and never null. Null is reserved for "no match at all", so
# overloading it here would recreate this ticket's own bug in miniature: a
# consumer branching on `state == null` would read a matched-but-unclassifiable
# hotspot as a blank slate. `unknown` keeps "did we match?" answerable from the
# state field alone. `state` is always requested above, so this only fires on a
# malformed payload; it still must not read as never-ticketed.
#
# norm_state type-checks instead of calling ascii_downcase blind: on a
# non-string the whole program would abort, and this jq's failure mode is an
# EMPTY hotspot list emitted under exit 0 — every hotspot lost, not just one.
HOTSPOTS=$(printf '%s' "$HOTSPOTS" | jq -c --argjson issues "$CANDIDATE_ISSUES" '
  def norm_state: (if type == "string" then ascii_downcase else "" end);
  map(
    . as $h
    | [ $issues[]
        | select(
            (.title == ("Refactor hotspot: " + $h.file))
            or ((.body // "") | contains("<!-- churn-hotspot: " + $h.file + " -->"))
          )
      ] as $matches
    | ( ([ $matches[] | select((.state | norm_state) == "open") ] | first)
        // ($matches | first) ) as $chosen
    | .existing_hotspot_issue = ($chosen.number // null)
    | .existing_hotspot_issue_state = (
        if $chosen == null then null
        else
          ($chosen.state | norm_state) as $s
          | if $s == "open" or $s == "closed" then $s else "unknown" end
        end
      )
  )
' 2>/dev/null) || HOTSPOTS='[]'

case "$HOTSPOTS" in ''|null) HOTSPOTS='[]' ;; esac

emit_and_exit "$HOTSPOTS" 0
