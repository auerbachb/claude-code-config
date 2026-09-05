#!/usr/bin/env bash
# worktree-status.sh — Report a worktree's own HEAD SHA and current branch.
#
# PURPOSE
#   Replaces the two-command pair
#
#     git -C <wt> rev-parse HEAD; git -C <wt> branch --show-current
#
#   with ONE plain script call. A worktree-isolated agent is refused that pair
#   by the harness's worktree-isolation guard — "this command is too complex to
#   verify that it stays inside the worktree" — because the guard classifies by
#   command SHAPE, and two `;`-separated commands are already too complex for it
#   even when both pin `-C <the agent's own worktree>`. A single script call is
#   an allowed shape, and the git calls this script makes are its own child
#   processes, which the guard does not gate. Full catalog of refused vs allowed
#   shapes: .claude/reference/worktree-isolation-command-shapes.md (issue #1470).
#
#   THIS IS NOT repo-root.sh. repo-root.sh answers "where is the MAIN worktree
#   root", which is the wrong question here: an isolated agent needs the state of
#   the LINKED worktree it is standing in. Given a linked worktree, this script
#   reports that worktree's own HEAD, its own branch, and its own top level —
#   never main's. Pinned by the test suite, because resolving through
#   repo-root.sh would silently return the other repo's answer and every field
#   would still look plausible.
#
# USAGE
#   worktree-status.sh [--repo <path>] [--json]
#   worktree-status.sh --help | -h
#
#   --repo <path>  Report the worktree containing <path> instead of the caller's
#                  current directory. Also accepts --repo=<path>. This is the
#                  flag that makes the script reachable without a `cd`: the
#                  worktree-isolated caller passes its own worktree path rather
#                  than wrapping the call in a refused compound.
#   --json         Emit a single JSON object instead of KEY=VALUE lines.
#
# OUTPUT
#   Default — four KEY=VALUE lines on stdout, in this order, one per line:
#
#     HEAD=<object id>        HEAD commit of this worktree (40 hex chars in a
#                             SHA-1 repo, 64 in a SHA-256 one — do not pin 40)
#     BRANCH=<name>           current branch; EMPTY when HEAD is detached
#     DETACHED=<true|false>   whether HEAD is detached
#     ROOT=<abs path>         top level of THIS worktree (not the main worktree)
#
#   Read one field the way escalate-review.sh's STATUS= is read:
#     HEAD_SHA=$(worktree-status.sh --repo "$WT" | sed -n 's/^HEAD=//p')
#
#   --json — one object with the same four keys, lowercased: head, branch,
#   detached (boolean), root. `branch` is the empty string when detached.
#
#   An UNBORN branch (a fresh `git init`, no commit yet) has no HEAD to report
#   and exits 1 rather than printing an empty or invented SHA.
#
#   CONTROL CHARACTERS. A directory name may legally contain a newline or a tab,
#   and a newline in ROOT would inject a fake `KEY=` line into the default
#   output — a consumer's `sed -n 's/^HEAD=//p'` would then read an attacker- or
#   accident-supplied value as a field. The line protocol cannot represent such a
#   path, so it is REFUSED (exit 1) rather than emitted ambiguously; the same
#   posture worktree-guard.sh already takes for a newline in a target path.
#   `--json` CAN represent them and does: control characters are escaped, so the
#   JSON form still answers for such a worktree.
#
#   stderr: one-line diagnostic on failure.
#
# EXIT STATUS
#   0  Success — fields printed on stdout.
#   1  Not a git repo, unborn branch, a git call failed, or a field contains a
#      control character the default line protocol cannot represent (use --json).
#      DETERMINATE: git ran and reported it.
#   2  Usage error (unknown flag, missing/empty --repo value, --repo path does
#      not exist).
#   3  Timed out — a git call exceeded WORKTREE_STATUS_TIMEOUT_SECS and was
#      killed rather than left to block the caller (issue #1363 class).
#   4  Nothing could be determined: a required helper or the bounded-run library
#      is missing, or git could not be launched at all (shell 126/127). NOT
#      determinate — a caller must not fall back to $PWD or another git call.
#   70 --help header extraction produced no output (internal defect).
#
# ENVIRONMENT
#   WORKTREE_STATUS_TIMEOUT_SECS  Wall-clock bound, in whole seconds, applied to
#                                 each git call (default 10). Empty, non-numeric
#                                 or zero values fall back to the default rather
#                                 than disabling the bound.
#
# REQUIREMENTS
#   mktemp, awk, cat, head, date, sleep, dirname, rm — all checked up front so a
#   missing one exits 4 instead of letting the shell's own 127 escape as an
#   undocumented status. Also requires lib/bounded-run.sh beside this script; an
#   unreadable one exits 4, because without the bound a wedged filesystem turns
#   this into the silent 20-minute stall the bound exists to prevent (#1404).
#
#   `git` is required too, but deliberately NOT in that preflight — same posture
#   as repo-root.sh. A git that cannot run is diagnosed by the 126/127 machinery
#   below, which relays what the shell actually said about it; a blunt "not found
#   on PATH" here would preempt that with less information. Either way the exit
#   status is 4.
#
# EXAMPLES
#   .claude/scripts/worktree-status.sh
#   .claude/scripts/worktree-status.sh --repo "$MY_WORKTREE"
#   .claude/scripts/worktree-status.sh --repo "$MY_WORKTREE" --json | jq -r .branch

set -uo pipefail

CAPTURE=""
CAPTURE_ERR=""
TARGET_DESC=""
on_exit() {
  local rc=$?
  if [[ -n "$CAPTURE" ]]; then rm -f "$CAPTURE" 2>/dev/null || true; fi
  if [[ -n "$CAPTURE_ERR" ]]; then rm -f "$CAPTURE_ERR" 2>/dev/null || true; fi
  # 126/127 mean the shell could not launch something, decided before the
  # callee's own code ran. This script never exits those on purpose, so an
  # escaping one is normalized to 4 — "nothing was determined" — exactly as
  # repo-root.sh does, so callers never read a raw shell status as an answer.
  if [[ "$rc" -eq 126 || "$rc" -eq 127 ]]; then
    echo "worktree-status.sh: a required command could not be launched (shell exit $rc), so nothing was determined${TARGET_DESC:+ about $TARGET_DESC} — repair PATH and retry" >&2
    exit 4
  fi
  exit "$rc"
}
trap on_exit EXIT

# Usage telemetry. Best-effort and fully guarded, matching repo-root.sh: an
# unset HOME, a missing ~/.claude, or a read-only log must never be able to
# change this script's contract. Skipped outright when HOME is unset, so a
# stray file is never dropped at the filesystem root.
if [[ -n "${HOME:-}" ]]; then
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ 2>/dev/null || true)" "${0##*/}" "${*//$'\n'/ }" \
    2>/dev/null >> "$HOME/.claude/script-usage.log" || true
fi

# Self-extract the leading header block for --help: every line after the shebang
# up to (not including) the first blank line. Terminating on a BLANK line rather
# than a named heading is deliberate — a range ends AT its terminator, which is
# how six scripts silently swallowed their own EXAMPLES section (issue #1475).
print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; n = 1; next } { exit } END { exit(n ? 0 : 1) }' "$0" ||
    { printf '%s: --help header extraction produced no output\n' "$0" >&2; exit 70; }
}

usage_error() {
  echo "worktree-status.sh: $1" >&2
  echo "Run with --help for usage." >&2
  exit 2
}

REPO=""
JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help
      exit 0
      ;;
    --repo)
      [[ $# -ge 2 ]] || usage_error "--repo requires a value"
      [[ -n "$2" ]] || usage_error "--repo value cannot be empty"
      REPO="$2"
      shift 2
      ;;
    --repo=*)
      REPO="${1#--repo=}"
      [[ -n "$REPO" ]] || usage_error "--repo value cannot be empty"
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
      usage_error "unexpected positional argument: $1 (did you mean --repo $1?)"
      ;;
  esac
done
[[ $# -eq 0 ]] || usage_error "unexpected positional argument: $1 (did you mean --repo $1?)"

# A typo'd path is the CALLER's mistake, so it is a usage error here rather than
# a resolution failure of an existing tree — same split, same message shape, as
# dirty-main-guard.sh.
if [[ -n "$REPO" && ! -d "$REPO" ]]; then
  usage_error "--repo path does not exist: $REPO"
fi

TARGET_DESC="the current directory"
[[ -n "$REPO" ]] && TARGET_DESC="$REPO"

# Checked before any state is created, and with `command -v` — a bash builtin,
# so the check needs nothing from the PATH it is testing. Placed after argument
# parsing so --help and usage errors keep answering first in exactly the broken
# environment where an operator most needs to read them.
MISSING_HELPERS=""
for helper in mktemp awk cat head date sleep dirname rm; do
  command -v "$helper" >/dev/null 2>&1 \
    || MISSING_HELPERS="${MISSING_HELPERS:+$MISSING_HELPERS }$helper"
done
if [[ -n "$MISSING_HELPERS" ]]; then
  echo "worktree-status.sh: required helper(s) not found on PATH ($MISSING_HELPERS), so nothing was determined about $TARGET_DESC — repair PATH and retry" >&2
  exit 4
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
BOUNDED_RUN_LIB="${SCRIPT_DIR:-.}/lib/bounded-run.sh"
if [[ ! -r "$BOUNDED_RUN_LIB" ]]; then
  echo "worktree-status.sh: required library not found at $BOUNDED_RUN_LIB, so the wall-clock bound could not be loaded and nothing was determined about $TARGET_DESC — reinstall .claude/scripts/lib/ and retry" >&2
  exit 4
fi
# shellcheck source=lib/bounded-run.sh
source "$BOUNDED_RUN_LIB"

TIMEOUT_SECS="$(normalize_bound "${WORKTREE_STATUS_TIMEOUT_SECS:-10}" 10)"

# Both capture files are required. Unchecked, a failed mktemp leaves an empty
# path, every run_bounded redirection fails, and git is reported as failing for
# a reason that has nothing to do with git — a wrong answer dressed as a real
# one. This script uses `set -uo pipefail`, not `set -e`, so nothing else stops
# it. Fail closed and say why.
CAPTURE="$(mktemp "${TMPDIR:-/tmp}/worktree-status.XXXXXX" 2>/dev/null || true)"
CAPTURE_ERR="$(mktemp "${TMPDIR:-/tmp}/worktree-status-err.XXXXXX" 2>/dev/null || true)"
if [[ -z "$CAPTURE" || -z "$CAPTURE_ERR" || ! -w "$CAPTURE" || ! -w "$CAPTURE_ERR" ]]; then
  echo "worktree-status.sh: could not create the capture files under ${TMPDIR:-/tmp} (mktemp failed or the result is not writable) — nothing was read" >&2
  exit 5
fi

# Always at least one element, so the expansion is safe under `set -u` on bash
# 3.2 (macOS default), which errors on expanding an empty array.
GIT_CMD=(git)
if [[ -n "$REPO" ]]; then
  GIT_CMD=(git -C "$REPO")
fi

GIT_UNRUNNABLE=0

timeout_die() {
  if [[ "$BOUNDED_CLOCK_UNREADABLE" -eq 1 ]]; then
    echo "worktree-status.sh: could not read the clock (date -u +%s), so the ${TIMEOUT_SECS}s bound on '$1' could not be enforced — killed the call rather than running it unbounded" >&2
  else
    echo "worktree-status.sh: timed out after ${TIMEOUT_SECS}s running '$1' — killed it rather than blocking the caller (raise WORKTREE_STATUS_TIMEOUT_SECS if the repo is genuinely this slow)" >&2
  fi
  exit 3
}

# Runs one bounded git call and leaves its stdout in $GIT_OUT (first line,
# trimmed of the trailing newline). Returns the child's real status. NEVER call
# this inside `$( )`: a command substitution runs it in a subshell, where
# BOUNDED_TIMED_OUT and any `exit` from timeout_die are discarded and a bounded
# failure silently becomes an unbounded one.
GIT_OUT=""
git_call() { # description, args…
  local desc="$1"; shift
  local rc=0
  GIT_OUT=""
  # BOUNDED_REQUIRE_OUTPUT stays 0: several of the calls below legitimately
  # produce empty stdout (a detached HEAD prints no branch name), so an empty
  # capture must not be read as "the child never really finished".
  BOUNDED_REQUIRE_OUTPUT=0
  run_bounded "$TIMEOUT_SECS" "${GIT_CMD[@]}" "$@" || rc=$?
  if [[ "$BOUNDED_TIMED_OUT" -eq 1 ]]; then
    timeout_die "$desc"
  fi
  case "$rc" in 126|127) GIT_UNRUNNABLE=1 ;; esac
  # The WHOLE capture, not `head -n 1`. A worktree path may legally contain a
  # newline, and taking only the first line would silently truncate ROOT to a
  # different, perfectly plausible-looking path — the control-character guard at
  # the output boundary would then never see it.
  #
  # The sentinel matters for the same reason at the other end: `$( )` strips
  # EVERY trailing newline, so a path that ENDS in one would come back with it
  # silently removed and sail past the guard as a valid-looking different path.
  # Appending `x` and stripping it back preserves them all; then exactly ONE is
  # removed — git's own line terminator, which is not part of the path. An empty
  # capture (the documented detached-HEAD answer from `branch --show-current`)
  # stays empty through both steps.
  GIT_OUT="$(cat "$CAPTURE" 2>/dev/null || true; printf 'x')"
  GIT_OUT="${GIT_OUT%x}"
  GIT_OUT="${GIT_OUT%$'\n'}"
  return "$rc"
}

# Report what git actually said instead of collapsing a broken install, a bad
# PATH, an unreadable object store and a genuinely non-repo directory into one
# confident sentence.
die_not_repo() { # what failed
  local said
  said="$(head -n 1 "$CAPTURE_ERR" 2>/dev/null || true)"
  if [[ "$GIT_UNRUNNABLE" -eq 1 ]]; then
    echo "worktree-status.sh: git could not run (missing, not executable, or a broken PATH), so nothing was determined about $TARGET_DESC${said:+ — git said: $said}" >&2
    exit 4
  fi
  echo "worktree-status.sh: $1 for $TARGET_DESC${said:+ — git said: $said}" >&2
  exit 1
}

# --- ROOT: the top level of THIS worktree ------------------------------------
# --show-toplevel is deliberately used instead of repo-root.sh: it answers for
# the worktree the caller is standing in, which is the whole point (see PURPOSE).
git_call "git rev-parse --show-toplevel" rev-parse --show-toplevel || die_not_repo "not a git repository"
ROOT="$GIT_OUT"
[[ -n "$ROOT" ]] || die_not_repo "not a git repository"

# --- HEAD: fail loudly on an unborn branch instead of inventing a SHA ---------
if ! git_call "git rev-parse HEAD" rev-parse HEAD; then
  die_not_repo "could not read HEAD (unborn branch, or an unreadable object store)"
fi
HEAD_SHA="$GIT_OUT"
[[ -n "$HEAD_SHA" ]] || die_not_repo "git reported an empty HEAD"

# --- BRANCH: empty output is the DOCUMENTED detached answer, not a failure ----
# `branch --show-current` exits 0 and prints nothing on a detached HEAD, so the
# empty string is load-bearing here and must not be treated as an error.
BRANCH=""
DETACHED="false"
if git_call "git branch --show-current" branch --show-current; then
  BRANCH="$GIT_OUT"
else
  die_not_repo "could not read the current branch"
fi
if [[ -z "$BRANCH" ]]; then
  DETACHED="true"
fi

if [[ "$JSON" -eq 1 ]]; then
  # jq is not a hard requirement of this script, so the object is emitted
  # directly. Every field is a git SHA, a ref name, a literal boolean, or an
  # absolute path; the path and the ref name are the two that can carry a
  # character JSON cares about, control characters included.
  json_escape() { # value
    local raw="$1" out="" i ch
    for (( i = 0; i < ${#raw}; i++ )); do
      ch="${raw:i:1}"
      case "$ch" in
        '\')  out+='\\' ;;
        '"')  out+='\"' ;;
        $'\n') out+='\n' ;;
        $'\r') out+='\r' ;;
        $'\t') out+='\t' ;;
        $'\b') out+='\b' ;;
        $'\f') out+='\f' ;;
        *)
          # Every remaining C0 control character (and DEL) must be escaped to be
          # valid JSON; printable bytes, multi-byte UTF-8 included, pass through.
          if [[ "$ch" == [[:cntrl:]] ]]; then
            out+="$(printf '\\u%04x' "'$ch")"
          else
            out+="$ch"
          fi
          ;;
      esac
    done
    printf '%s' "$out"
  }
  printf '{"head":"%s","branch":"%s","detached":%s,"root":"%s"}\n' \
    "$(json_escape "$HEAD_SHA")" "$(json_escape "$BRANCH")" \
    "$DETACHED" "$(json_escape "$ROOT")"
else
  # The line protocol cannot represent a control character: a newline in ROOT
  # would inject a fake `KEY=` line that a consumer's `sed -n 's/^HEAD=//p'`
  # would read as a real field. Refuse rather than emit something ambiguous, and
  # name the escape hatch. HEAD and DETACHED are script-generated and cannot
  # carry one; BRANCH is checked anyway rather than trusted.
  for field in "BRANCH:$BRANCH" "ROOT:$ROOT"; do
    if [[ "${field#*:}" == *[[:cntrl:]]* ]]; then
      echo "worktree-status.sh: ${field%%:*} contains a control character, which the KEY=VALUE output cannot represent unambiguously — re-run with --json" >&2
      exit 1
    fi
  done
  echo "HEAD=$HEAD_SHA"
  echo "BRANCH=$BRANCH"
  echo "DETACHED=$DETACHED"
  echo "ROOT=$ROOT"
fi

exit 0
