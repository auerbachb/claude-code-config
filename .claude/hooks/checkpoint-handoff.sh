#!/usr/bin/env bash
# checkpoint-handoff.sh — automatic, document-only handoff checkpoint (issue #941)
#
# PURPOSE
#   `usage-limit-record.sh` writes a breadcrumb when a turn dies on an Anthropic
#   usage limit, and that breadcrumb points at the most recent portable handoff
#   so the next session reads *what was happening* instead of reconstructing it
#   from a transcript. On 2026-08-01 the account limit killed three concurrent
#   sessions and every record came out with `"portable_handoff": null`, because
#   no handoff existed: the only thing that writes one is invoked by hand, and a
#   limit that arrives without warning is precisely the case where nobody did.
#
#   This script closes that gap from the other side. It writes the ARTIFACT and
#   nothing else — no wind-down, no stopping, no decision of any kind — so the
#   document the recorder already looks for is on disk when it looks.
#
# WHAT THIS IS NOT
#   It is not the pre-emptive wind-down blocked upstream (issues #824 / #835),
#   and it is not the hand-invoked pause on a timer. Those stop work; this only
#   describes it. The hand-invoked command keeps its contract — it "runs because
#   you asked, and for no other reason" — because this is a different producer
#   of the same artifact, not a scheduled invocation of that command.
#
# SAFETY (.claude/rules/safety.md §"Anthropic Quota & Spend Authority")
#   No token, spend, or quota arithmetic anywhere. Nothing here pauses,
#   downgrades, defers, or refuses work, and no output gates a decision. That
#   rule is satisfied as written and was NOT amended for this script — the same
#   standing the post-hoc recorder has.
#
# THE DEGRADE LADDER (the design's load-bearing idea)
#   `portable-handoff-lint.sh` rejects any relative `.claude/` path, phase
#   vocabulary, internal state-file names, and any slash-command name resolved
#   from the live skill catalog. A mechanical renderer walks into all of these
#   without meaning to: run it in THIS repository and the changed-file list is
#   full of `.claude/scripts/…`, and a pull request title elsewhere may quote a
#   command name. A human renderer just rewrites the offending line; a script
#   cannot.
#
#   So the script renders, lints, and on failure drops to a less specific
#   rendering, shipping the first tier that passes:
#
#     1  changed-file paths listed, pull request titles quoted
#     2  paths replaced by a count and a `git status` instruction
#     3  titles dropped — pull requests named by number and URL only
#     4  minimal: absolute working directory, counts, universal commands
#
#   Tier 4 deliberately names no branch, no path, and no borrowed text, so it
#   has essentially nothing left to fail on. If even that does not pass, the
#   script writes NOTHING rather than emitting a document that fails its own
#   gate. Four renders, four lint calls, all local.
#
#   This makes "the output is portable" a property the script enforces on
#   itself in whatever repository it runs in, rather than one the author hoped
#   would hold everywhere.
#
# THROTTLE
#   Registered on SubagentStop, this can fire many times a minute. It writes at
#   most once per CLAUDE_CHECKPOINT_MIN_INTERVAL, and additionally whenever the
#   local state fingerprint changes inside that window.
#
#   Time is the PRIMARY trigger, not the fingerprint, and that ordering matters:
#   in an orchestration session the parent's own git state barely moves while
#   subagents work in their own worktrees, so a purely fingerprint-gated
#   checkpoint would go stale in exactly the session that most needs a current
#   one. The fingerprint only ever makes it write MORE often, never less.
#
#   The fingerprint lives in an HTML comment in the document itself, so this
#   needs no sidecar state file and takes no write lock.
#
# USAGE
#   checkpoint-handoff.sh [OPTIONS]
#
# OPTIONS
#   --out-dir DIR        Where handoffs live. Default $CLAUDE_HANDOFF_DIR, then
#                        ~/.claude/handoffs.
#   --min-interval SECS  Throttle window. Default $CLAUDE_CHECKPOINT_MIN_INTERVAL,
#                        then 600.
#   --retention-days N   Prune checkpoints older than this. Default 7, matching
#                        the recorder's own handoff age bound.
#   --force              Ignore the throttle.
#   --stdout             Render and lint, print to stdout, publish nothing.
#   --no-remote          Skip the pull request lookup (no network).
#   -h, --help           This text.
#
# EXIT STATUS
#   Always 0. A checkpoint that becomes a new failure mode is worse than no
#   checkpoint — the same reason the recorder is written this way. Diagnostics
#   go to stderr; --stdout is the way to see what it would write.

set -uo pipefail

OUT_DIR=""
MIN_INTERVAL=""
RETENTION_DAYS=""
FORCE=0
TO_STDOUT=0
NO_REMOTE=0

usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; $d'; }

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force) FORCE=1 ;;
    --stdout) TO_STDOUT=1 ;;
    --no-remote) NO_REMOTE=1 ;;
    --out-dir) [[ $# -ge 2 ]] || { echo "checkpoint-handoff.sh: --out-dir needs a directory" >&2; exit 0; }; OUT_DIR="$2"; shift ;;
    --min-interval) [[ $# -ge 2 ]] || { echo "checkpoint-handoff.sh: --min-interval needs a value" >&2; exit 0; }; MIN_INTERVAL="$2"; shift ;;
    --retention-days) [[ $# -ge 2 ]] || { echo "checkpoint-handoff.sh: --retention-days needs a value" >&2; exit 0; }; RETENTION_DAYS="$2"; shift ;;
    *) echo "checkpoint-handoff.sh: unknown option: $1" >&2; exit 0 ;;
  esac
  shift
done

# A hook receives the event payload on stdin. Drain it so the writer never gets
# EPIPE — this script has no use for it, but a broken pipe upstream is a new
# failure mode, which is the one thing it must not introduce.
#
# Skipped for --stdout, which is the by-hand inspection mode: there the caller's
# stdin is whatever the shell handed down and may never close, and blocking on
# it would turn "show me what this would write" into an apparent hang. The hook
# path keeps the drain and is bounded by the registered timeout regardless.
if (( ! TO_STDOUT )) && [[ ! -t 0 ]]; then
  cat >/dev/null 2>&1 || true
fi

command -v git >/dev/null 2>&1 || exit 0

OUT_DIR="${OUT_DIR:-${CLAUDE_HANDOFF_DIR:-$HOME/.claude/handoffs}}"

# Validate the numeric settings before use. An inherited non-numeric value would
# otherwise reach an arithmetic comparison and abort mid-run, costing the user
# the checkpoint over a typo in an environment variable.
MIN_INTERVAL="${MIN_INTERVAL:-${CLAUDE_CHECKPOINT_MIN_INTERVAL:-600}}"
[[ "$MIN_INTERVAL" =~ ^[0-9]+$ ]] || MIN_INTERVAL=600
RETENTION_DAYS="${RETENTION_DAYS:-${CLAUDE_CHECKPOINT_RETENTION_DAYS:-7}}"
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && (( RETENTION_DAYS > 0 )) || RETENTION_DAYS=7

CHECKPOINT_GLOB='portable-handoff-*-checkpoint.md'

# --- Helpers --------------------------------------------------------------

# Resolve a sibling script the way the other from-anywhere commands do: this may
# run with a working directory in a completely different project, where a
# repo-relative path silently resolves to nothing.
#
# The `../scripts` candidate is what makes THIS checkout's copies win. Hook
# registration joins a manifest basename onto the hooks directory, so this file
# has to live beside the other hooks while the helpers it needs live one
# directory over — without that candidate the first hit would be the shared
# worktree's copy, and a run inside a checkout that changed the checker would
# quietly be verified by a different version of it.
resolve_script() {
  local name="$1" candidate self_dir
  self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
  for candidate in \
    "$self_dir/$name" \
    "$self_dir/../scripts/$name" \
    "$HOME/.claude/skills-worktree/.claude/scripts/$name" \
    "$HOME/.claude/scripts/$name" \
    ".claude/scripts/$name"; do
    if [[ -x "$candidate" ]]; then printf '%s' "$candidate"; return 0; fi
  done
  return 1
}

digest() { # stdin -> short hex
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | cut -c1-16
  else
    cksum 2>/dev/null | tr -d ' ' | cut -c1-16
  fi
}

file_mtime_epoch() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# Newest file matching a glob, by modification time. `-nt` is a bash builtin, so
# this stays free of the BSD/GNU `stat` split.
newest_matching() { # $1 = dir, $2 = -name pattern, $3 = optional ! -name pattern
  local dir="$1" pat="$2" notpat="${3:-}" newest="" f
  [[ -d "$dir" ]] || return 0
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if [[ -z "$newest" || "$f" -nt "$newest" ]]; then newest="$f"; fi
  done < <(
    if [[ -n "$notpat" ]]; then
      find "$dir" -maxdepth 1 -type f -name "$pat" ! -name "$notpat" 2>/dev/null
    else
      find "$dir" -maxdepth 1 -type f -name "$pat" 2>/dev/null
    fi
  )
  printf '%s' "$newest"
}

# --- Local state (cheap; runs before the throttle) -------------------------

WORKDIR=$(pwd -P 2>/dev/null || pwd)
IN_REPO=0
BRANCH=""
HEAD_SHA=""
CHANGED_COUNT=0
CHANGED_LIST=""
UNPUSHED=""
REPO_SLUG=""
TOPLEVEL=""

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IN_REPO=1
  TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  HEAD_SHA=$(git rev-parse --short HEAD 2>/dev/null)
  PORCELAIN=$(git status --porcelain 2>/dev/null)
  if [[ -n "$PORCELAIN" ]]; then
    CHANGED_COUNT=$(printf '%s\n' "$PORCELAIN" | grep -c . 2>/dev/null || true)
    [[ "$CHANGED_COUNT" =~ ^[0-9]+$ ]] || CHANGED_COUNT=0
    # Strip the two status columns; keep the path. Rename entries ("R  a -> b")
    # keep both sides, which is what a reader wants to see anyway.
    CHANGED_LIST=$(printf '%s\n' "$PORCELAIN" | sed 's/^...//' | sort)
  fi
  UNPUSHED=$(git rev-list --count '@{u}..HEAD' 2>/dev/null)
  [[ "$UNPUSHED" =~ ^[0-9]+$ ]] || UNPUSHED=""
  ORIGIN=$(git remote get-url origin 2>/dev/null)
  if [[ -n "$ORIGIN" ]]; then
    REPO_SLUG="${ORIGIN%.git}"
    REPO_SLUG="${REPO_SLUG##*:}"
    REPO_SLUG="${REPO_SLUG#https://}"
    REPO_SLUG="${REPO_SLUG#*github.com/}"
  fi
fi
[[ -n "$REPO_SLUG" ]] || REPO_SLUG=$(basename "${TOPLEVEL:-$WORKDIR}")

FINGERPRINT=$(printf '%s\n%s\n%s\n%s\n%s\n' \
  "$BRANCH" "$HEAD_SHA" "$CHANGED_COUNT" "${UNPUSHED:-na}" "$CHANGED_LIST" | digest)
FINGERPRINT_MARK="<!-- checkpoint-fingerprint: ${FINGERPRINT} -->"

# --- Throttle -------------------------------------------------------------
#
# Write when the interval has elapsed, OR when the fingerprint moved inside it.
# The fingerprint can only ever make this fire more often — see THROTTLE above
# for why time is the primary trigger and not the other way round.

if (( ! FORCE )) && (( ! TO_STDOUT )); then
  PREV=$(newest_matching "$OUT_DIR" "$CHECKPOINT_GLOB")
  if [[ -n "$PREV" ]]; then
    PREV_MTIME=$(file_mtime_epoch "$PREV")
    NOW_EPOCH=$(date +%s 2>/dev/null)
    if [[ "$PREV_MTIME" =~ ^[0-9]+$ && "$NOW_EPOCH" =~ ^[0-9]+$ ]]; then
      AGE=$(( NOW_EPOCH - PREV_MTIME ))
      if (( AGE < MIN_INTERVAL )) && grep -qF "$FINGERPRINT_MARK" "$PREV" 2>/dev/null; then
        exit 0
      fi
    fi
  fi
fi

# --- Remote state (only past the throttle, so the common path is free) -----

ISSUE_NUM=""
[[ "$BRANCH" =~ (^|[^0-9])issue-([0-9]+) ]] && ISSUE_NUM="${BASH_REMATCH[2]}"

# One record per line, fields joined by US (0x1f) — NOT by a tab.
#
# Tab is an IFS whitespace character, so `IFS=$'\t' read` collapses a run of
# them: a pull request with an empty title turns "42<TAB><TAB>url" into
# number=42, title=url, url=empty, and the document then shows a URL where a
# title belongs with no error anywhere. US is not IFS whitespace, so empty
# fields hold their position.
PR_SEP=$'\x1f'
PR_ROWS=""
if (( ! NO_REMOTE )) && command -v gh >/dev/null 2>&1 && [[ -n "$REPO_SLUG" ]]; then
  PR_ROWS=$(gh pr list --author "@me" --state open --limit 10 \
              --json number,title,url \
              --jq '.[] | [(.number|tostring), .title, .url] | join("\u001f")' 2>/dev/null)
fi

# Background units still recorded as running. Read through the state helper when
# it resolves — direct reads of that file are not this script's business — and
# treat any failure as "could not tell", never as zero.
AGENTS_COUNT=""
if SESSION_STATE_SH=$(resolve_script session-state.sh); then
  AGENTS_COUNT=$("$SESSION_STATE_SH" --session-view 2>/dev/null \
                   | jq -r '(.active_agents // []) | length' 2>/dev/null)
  [[ "$AGENTS_COUNT" =~ ^[0-9]+$ ]] || AGENTS_COUNT=""
fi

# The most recent hand-written handoff, so a fresh shallow checkpoint never
# buries an older rich one. Only the BASENAME is ever printed: the absolute path
# runs through a directory this harness named, which the portability lint
# rejects — and the reader is holding a file in that same directory anyway, so
# the basename is the part that actually locates it for them.
PRIOR_RICH=$(newest_matching "$OUT_DIR" 'portable-handoff-*.md' "$CHECKPOINT_GLOB")
PRIOR_RICH_NAME=""
[[ -n "$PRIOR_RICH" ]] && PRIOR_RICH_NAME=$(basename "$PRIOR_RICH")

HUMAN_TIME=$(date '+%Y-%m-%d %H:%M %Z' 2>/dev/null)
[[ -n "$HUMAN_TIME" ]] || HUMAN_TIME="an unrecorded time"

# --- Rendering ------------------------------------------------------------

# $1 list_files (1|0)   $2 with_titles (1|0)   $3 minimal (1|0)
render() {
  local list_files="$1" with_titles="$2" minimal="$3"
  local n title url

  printf '# Session handoff — %s — %s\n\n' "$REPO_SLUG" "$HUMAN_TIME"
  printf 'Written automatically while work was in progress, not at a stopping point.\n'
  printf 'Everything below reflects that moment; check the current state of anything\n'
  printf 'you are about to change before changing it.\n\n'

  printf '## Start here\n\n'
  if (( minimal )); then
    printf 'Open a terminal in the working directory named at the bottom of this document\n'
    printf 'and run `git status` to see what is unfinished there.\n\n'
  else
    printf 'Open a terminal in the working directory named at the bottom of this document\n'
    printf 'and run `git status`'
    if (( CHANGED_COUNT > 0 )); then
      printf ' — there were %d uncommitted change(s) when this was written,\nso start by understanding those before doing anything else' "$CHANGED_COUNT"
    else
      printf ' to confirm the tree is still clean'
    fi
    printf '.\n\n'
  fi

  printf "## What we're working on\n\n"
  if (( minimal )); then
    printf 'This checkpoint was written automatically by a background task, so it records\n'
    printf 'no statement of intent. The repository is `%s`. Run `git log --oneline -20`\n' "$REPO_SLUG"
    printf 'and `git status` in the working directory below to see what was underway.\n\n'
  else
    printf 'Repository `%s`' "$REPO_SLUG"
    if [[ -n "$ISSUE_NUM" ]]; then
      printf ', working on issue %s' "$ISSUE_NUM"
      [[ -n "$REPO_SLUG" ]] && printf ' (https://github.com/%s/issues/%s)' "$REPO_SLUG" "$ISSUE_NUM"
    fi
    printf '.\n\n'
    printf 'This checkpoint was written automatically rather than by a person, so what\n'
    printf 'follows is what the repository state says, not a statement of intent. Read the\n'
    printf 'issue linked above, if any, for the actual goal.\n\n'
  fi

  printf '## Open work\n\n'
  if [[ -z "$PR_ROWS" ]]; then
    printf 'No open pull requests were recorded for this account when this was written.\n'
    printf 'Run `gh pr list --author "@me" --state open` to check the current position.\n\n'
  else
    while IFS="$PR_SEP" read -r n title url; do
      [[ -n "$n" ]] || continue
      if (( with_titles )) && [[ -n "$title" ]]; then
        printf -- '- **Pull request %s — %s**\n' "$n" "$title"
      else
        printf -- '- **Pull request %s**\n' "$n"
      fi
      printf '  %s\n' "$url"
      printf '  Status: open when this was written. Run `gh pr view %s` for its current\n' "$n"
      printf '  review state, checks, and unanswered comments.\n'
    done <<<"$PR_ROWS"
    printf '\n'
  fi

  printf '## Decisions made this session\n\n'
  printf 'None are recorded here. This document was produced automatically by a background\n'
  printf 'task that observes repository state and cannot know why a choice was made.\n'
  if [[ -n "$PRIOR_RICH_NAME" ]]; then
    printf '\nA handoff written by hand, which does carry that reasoning, sits in this same\n'
    printf 'directory as `%s`. Read it as well — it is\n' "$PRIOR_RICH_NAME"
    printf 'older than this file, so prefer this one for repository state and that one for\n'
    printf 'intent. Check that its stated objective matches before acting on it.\n'
  fi
  printf '\n'

  printf '## Local state on this machine\n\n'
  printf 'Working directory: %s\n' "$WORKDIR"
  if (( ! minimal )); then
    [[ -n "$BRANCH" ]] && printf 'Branch: %s\n' "$BRANCH"
    [[ -n "$HEAD_SHA" ]] && printf 'Most recent commit: %s\n' "$HEAD_SHA"
  fi

  if (( IN_REPO )); then
    if (( CHANGED_COUNT == 0 )); then
      printf 'Uncommitted changes: none\n'
    elif (( list_files )) && (( ! minimal )); then
      printf 'Uncommitted changes: %d file(s) —\n' "$CHANGED_COUNT"
      printf '%s\n' "$CHANGED_LIST" | sed 's/^/  /'
    else
      printf 'Uncommitted changes: %d file(s). Run `git status` in the directory above to\n' "$CHANGED_COUNT"
      printf '  list them; the names are not reproduced here because they would not mean\n'
      printf '  anything outside this checkout.\n'
    fi
    if [[ -z "$UNPUSHED" ]]; then
      printf 'Unpushed commits: could not be determined (the branch has no upstream set).\n'
    elif (( UNPUSHED == 0 )); then
      printf 'Unpushed commits: none\n'
    else
      printf 'Unpushed commits: %s. Run `git log --oneline @{u}..HEAD` to see them.\n' "$UNPUSHED"
    fi
  else
    printf 'This directory is not a git checkout, so no branch or change list was available.\n'
  fi

  if [[ -n "$AGENTS_COUNT" ]] && (( AGENTS_COUNT > 0 )); then
    printf '\n%s background unit(s) were still recorded as running when this was written.\n' "$AGENTS_COUNT"
    printf 'They may have been interrupted, so treat any work they owned as unfinished\n'
    printf 'until you have checked it yourself.\n'
  fi

  printf '\n%s\n' "$FINGERPRINT_MARK"
}

# --- Verify: render, lint, degrade ----------------------------------------

LINT_SH=$(resolve_script portable-handoff-lint.sh) || LINT_SH=""
LINT_ROOT=""
if [[ -n "$LINT_SH" ]]; then
  # Canonicalize before walking up. The resolved path can contain a `..`
  # component (the `../scripts` candidate above), and appending another `../..`
  # to an uncanonicalized path is the kind of thing that happens to work until
  # the candidate that produced it changes. `pwd -P` settles it once.
  LINT_DIR=$(cd "$(dirname "$LINT_SH")" 2>/dev/null && pwd -P)
  [[ -n "$LINT_DIR" ]] && LINT_SH="$LINT_DIR/$(basename "$LINT_SH")"
  LINT_ROOT=$(cd "${LINT_DIR:-.}/../.." 2>/dev/null && pwd -P)
  # The catalog the checker needs lives under the root's skills directory. If
  # this root has none, pass no root at all rather than a wrong one — the
  # checker's own fallback chain is better than a confident bad answer.
  [[ -n "$LINT_ROOT" && -d "$LINT_ROOT/.claude/skills" ]] || LINT_ROOT=""
fi

mkdir -p "$OUT_DIR" 2>/dev/null || exit 0
TMP_DOC=$(mktemp "$OUT_DIR/.checkpoint-handoff.XXXXXX" 2>/dev/null) || exit 0
trap 'rm -f "$TMP_DOC" 2>/dev/null' EXIT

# list_files with_titles minimal
TIERS=("1 1 0" "0 1 0" "0 0 0" "0 0 1")
ACCEPTED=0
TIER_USED=0
for tier in "${TIERS[@]}"; do
  read -r T_FILES T_TITLES T_MINIMAL <<<"$tier"
  TIER_USED=$(( TIER_USED + 1 ))
  render "$T_FILES" "$T_TITLES" "$T_MINIMAL" >"$TMP_DOC" 2>/dev/null || continue
  [[ -s "$TMP_DOC" ]] || continue
  if [[ -z "$LINT_SH" ]]; then
    # No checker resolved. Ship the most conservative rendering rather than the
    # richest unverified one: an unverified document is worth having, but it
    # should be the tier least likely to contain something the reader cannot
    # use, since nothing is going to catch it.
    if (( TIER_USED == ${#TIERS[@]} )); then ACCEPTED=1; fi
    continue
  fi
  # Capture the checker's status explicitly instead of reading $? after the
  # if/else. `$?` there is the status of whichever branch ran, which is the same
  # value today and stops being so the moment anything is appended to a branch —
  # a guard that silently starts reporting something else is the failure mode
  # this file is otherwise built to avoid.
  LINT_RC=0
  if [[ -n "$LINT_ROOT" ]]; then
    "$LINT_SH" --repo-root "$LINT_ROOT" --quiet "$TMP_DOC" >/dev/null 2>&1 || LINT_RC=$?
  else
    "$LINT_SH" --quiet "$TMP_DOC" >/dev/null 2>&1 || LINT_RC=$?
  fi
  if (( LINT_RC == 0 )); then ACCEPTED=1; break; fi
done

# Every tier failed, including the minimal one. Emit nothing: a document that
# fails its own portability gate is the failure this whole ladder exists to
# prevent, and silence is recoverable in a way a misleading file is not.
(( ACCEPTED )) || { echo "checkpoint-handoff.sh: no rendering passed the portability check; nothing written" >&2; exit 0; }

if (( TO_STDOUT )); then
  cat "$TMP_DOC"
  exit 0
fi

# --- Publish --------------------------------------------------------------

SESSION_ID="${CLAUDE_SESSION_ID:-default}"
SESSION_ID="${SESSION_ID//[^[:alnum:]_.-]/_}"
SESSION_ID="${SESSION_ID:-default}"
STAMP=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null)
[[ -n "$STAMP" ]] || STAMP="unknown"
OUT="$OUT_DIR/portable-handoff-${STAMP}-${SESSION_ID}-checkpoint.md"

# Same-directory mktemp + mv is an atomic single-writer publish: a reader sees a
# complete document or none, never a half-written one.
if mv -f "$TMP_DOC" "$OUT" 2>/dev/null; then
  trap - EXIT
  chmod 644 "$OUT" 2>/dev/null
  printf '%s\n' "$OUT"
else
  echo "checkpoint-handoff.sh: could not publish the checkpoint" >&2
  exit 0
fi

# --- Retention ------------------------------------------------------------
#
# Only files this script wrote are candidates. The `-checkpoint.md` suffix is
# what separates them from a hand-written handoff, which is the user's document
# and is never a deletion candidate at any age.
find "$OUT_DIR" -maxdepth 1 -type f -name "$CHECKPOINT_GLOB" \
  -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null

exit 0
