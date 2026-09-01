#!/usr/bin/env bash
# handoff-state.sh — Locked read/write helper for per-repo handoff files.
#
# PURPOSE
#   Serializes the WHOLE read-modify-write cycle of every writer that touches
#   a per-PR handoff file (issue #682 — follow-up to #639). Without this lock
#   two concurrent orchestrators (/babysit-pr, /pr-monitor-and-manage, Phase B
#   subagents) can each read, each append, and each write back, silently losing
#   one of the two appends. The individual write was already atomic (mktemp + mv
#   in polling-state-gate.sh), but the surrounding RMW cycle was not protected.
#
#   This helper is the SINGLE WRITE PATH for all handoff writers. Every writer
#   — polling-state-gate.sh, dismiss-stale-bot-changes.sh, Phase A/B agent
#   prompts, parent/wrap deletes — routes through this script so only one lock
#   path exists. A lock only one writer respects is not a lock (lesson from #639).
#
# REPO SCOPING (issues #655, #1366)
#   Handoff files are stored in a per-repo subdirectory so two repos at the same
#   PR number can never share one file:
#     ~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json
#
#   EVERY mode resolves that scoped path, and owner/repo is resolved in the same
#   precedence session-state.sh uses:
#     1. --owner-repo <owner/repo>  (explicit; must precede the mode flag)
#     2. $CLAUDE_SESSION_REPO
#     3. the cwd's `origin` remote  (repo_identity(), lib/pr-scope-resolver.sh)
#   When none of the three yields an owner/repo, the script exits 2 having
#   written nothing.  It does NOT fall back to the flat path (issue #1366).
#
# LEGACY FLAT PATH (issues #1302, #1366)
#     ~/.claude/handoffs/pr-{N}-handoff.json
#   is reachable ONLY on explicit request — --legacy-flat, or
#   CLAUDE_HANDOFF_FLAT_OK=1 for a caller that cannot add a flag.  Omission is
#   NOT a request for it.
#
#   The two escapes differ in what they say.  --legacy-flat is silent: naming
#   the flat path per call means you meant it (polling-state-gate.sh refreshing
#   an already-flat handoff, /wrap's flat-layout delete sweep,
#   handoff-migrate.sh).  CLAUDE_HANDOFF_FLAT_OK=1 is silent only when nothing
#   was bypassed; when the context WOULD have resolved a scope it notes on
#   stderr that it "sent --<mode> on PR #<N> to the legacy flat path, bypassing
#   the scope '<owner/repo>' this context resolves to".  The variable is
#   ambient, so it can cover calls its author never considered — that note is
#   what keeps the #1366 defect visible when it is set wider than intended.
#
#   An explicit --owner-repo always wins over CLAUDE_HANDOFF_FLAT_OK=1, and says
#   so on stderr.  The env var is ambient — /wrap exports it for a flat-layout
#   sweep — so letting it silently redirect a call that named its repo would
#   reintroduce the very defect #1366 closes, one scope wider.  --legacy-flat is
#   a per-call flag, so combining it with --owner-repo is a usage error instead.
#
#   Why omission stopped being a fallback: the flat write reports success while
#   every scoped reader sees nothing, so a phase's whole batch of updates is an
#   invisible no-op.  Warning about it (the #1302 fix) left the wrong path
#   reachable by the easy default; deriving the repo removes the default without
#   removing the flat path.  Deriving a scoped path while an un-migrated flat
#   file exists warns and names handoff-migrate.sh rather than orphaning it.
#   Decision record: .claude/reference/handoff-missing-owner-repo-decision.md
#
# USAGE
#   Scope flags (optional, any order, before the mode flag):
#     --owner-repo <owner/repo>   scope explicitly — preferred at every call site
#     --legacy-flat               target the legacy flat path instead
#     --require-existing          --set/--append update only; exit 3 (nothing
#                                 written) instead of seeding a new record from
#                                 `{}` when the target is absent. Checked under
#                                 the lock, so it is race-free where a caller's
#                                 own -e test is not.
#
#   handoff-state.sh [<scope-flags>] --path   <pr_number>        # print canonical path (no lock)
#   handoff-state.sh [<scope-flags>] --get    <pr_number>        # lock-free read
#   handoff-state.sh [<scope-flags>] --create <pr_number> <json> # locked create/overwrite
#   handoff-state.sh [<scope-flags>] --init   <pr_number> <json> # locked create-if-absent (no-op if exists)
#   handoff-state.sh [<scope-flags>] --set    <pr_number> <jq-path>=<value>
#   handoff-state.sh [<scope-flags>] --append <pr_number> <field> <value>
#   handoff-state.sh [<scope-flags>] --delete <pr_number>        # locked delete
#
# CONCURRENCY MODEL
#   The lock is a `mkdir`-based advisory lock directory at
#   <handoff-file>.lock/, reusing the same state-lock.sh library as
#   session-state.sh (#639). Every writer acquires state_lock_acquire before
#   reading the file; the mv back is already atomic. Reads (--path, --get,
#   Phase C, require_handoff_and_state) are lock-free because mv is atomic on
#   POSIX.
#
#   Lock path: ~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json.lock/
#              (flat legacy: ~/.claude/handoffs/pr-{N}-handoff.json.lock/)
#   Same stale-holder recovery (dead pid, age > STALE_AGE), timeout
#   (CLAUDE_STATE_LOCK_TIMEOUT, default 30s), and re-entrancy rules as the
#   parent library. Full contract: state-lock.sh header.
#
#   A writer that cannot acquire the lock exits STATE_LOCK_EXIT_TIMEOUT (6)
#   having written nothing — treat 6 as "unchanged, retry".
#
# DEDUP CONTRACT (from handoff-files.md)
#   --append enforces:
#     • String arrays: dedup by exact value (unique elements).
#     • findings_dismissed: dedup by .id (object identity).
#   Unknown fields are always preserved (forward compatibility).
#
# --set VALUES (issue #1357)
#   A value that parses as JSON is stored as that JSON literal; anything else is
#   stored verbatim as a string.  The one exception is a raw jq PROGRAM
#   (`.notes + " x"`, `(.a // [])`): it is REFUSED with exit 4, file unchanged,
#   instead of storing its own source text over the previous value.  To store
#   such text literally, pass it as a JSON string ("...").
#
# EXIT CODES
#   0  Success.
#   2  Usage error (missing args, unknown flag, malformed path=value,
#      unresolvable scope — see REPO SCOPING).
#   3  Handoff file not found (--get always; --set/--append only under
#      --require-existing, which otherwise create/seed from {}).
#   4  jq parse or evaluation failure. ALSO: --set refuses a value that is an
#      unevaluated jq expression rather than data (issue #1357) — the file is
#      left unmodified. Evaluate the expression first and pass the result.
#   5  Cannot complete the operation on disk. Three causes, all leaving the
#      handoff file exactly as it was: mktemp / temp-write / mv failure,
#      rm failure under --delete, or a REQUIRED sibling library missing at
#      startup (see DEPENDENCIES — that one fails before anything is read).
#   6  Lock timeout (STATE_LOCK_EXIT_TIMEOUT from state-lock.sh).
#
# DEPENDENCIES
#   jq, mktemp, mv, rm (POSIX), plus THREE required sibling libraries. Each is
#   sourced at startup and a missing one exits 5, so a copy of this script that
#   carries only some of them cannot run at all:
#     .claude/scripts/state-lock.sh             lock lifecycle (issue #639)
#     .claude/scripts/lib/repo-normalizer.sh    owner/repo case key (issue #704)
#     .claude/scripts/lib/pr-scope-resolver.sh  cwd -> owner/repo (issue #1366)

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  2>/dev/null >> "${HOME}/.claude/script-usage.log" || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK_LIB="${SCRIPT_DIR}/state-lock.sh"
HANDOFF_DIR="${HOME}/.claude/handoffs"

# Saved before any parsing shifts them, so a read-modify-write whose lock was
# stolen mid-flight can be retried from scratch (see _rmw_retry_or_fail).
ORIG_ARGS=("$@")

# Re-run this whole invocation after the lock was broken underneath us.
#
# The transform has to start over from a fresh read: the value we computed came
# from a snapshot another writer has replaced, so re-committing it would drop
# their update. Re-exec is the cheapest correct reset — it re-acquires the lock
# and redoes read → transform → commit with no leftover state. Bounded, because
# a lock that keeps being stolen is a real problem and must eventually surface
# rather than spin (issue #930).
_rmw_retry_or_fail() {
  local n="${CLAUDE_STATE_RMW_RETRY:-0}" max="${CLAUDE_STATE_RMW_MAX_RETRY:-8}"
  if (( n < max )); then
    export CLAUDE_STATE_RMW_RETRY=$(( n + 1 ))
    # Stagger the retries so contending writers do not re-collide in lockstep.
    sleep "0.0$(( (RANDOM % 8) + 1 ))"
    exec bash "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  fi
  echo "handoff-state.sh: lock was broken by another writer $max times running; giving up with $HANDOFF_FILE unchanged (retry)" >&2
  exit "$STATE_LOCK_EXIT_TIMEOUT"
}

# ---------------------------------------------------------------------------
# Load the lock library (required for all write paths).
# ---------------------------------------------------------------------------
if [[ ! -f "$LOCK_LIB" ]]; then
  echo "handoff-state.sh: state-lock.sh not found at $LOCK_LIB" >&2
  exit 5
fi
# shellcheck source=state-lock.sh
source "$LOCK_LIB"

# Shared case-normalizer (issue #704). Lowercases the --owner-repo value so
# ~/.claude/handoffs/{owner}/{repo}/ paths are always lowercase, preventing a
# mixed-case owner_repo from routing to a different directory than the lowercase
# form written by session-state.sh and polling-state-gate.sh.
NORMALIZER_LIB="${SCRIPT_DIR}/lib/repo-normalizer.sh"
if [[ ! -f "$NORMALIZER_LIB" ]]; then
  echo "handoff-state.sh: missing sibling library: $NORMALIZER_LIB" >&2
  exit 5
fi
# shellcheck source=./lib/repo-normalizer.sh
source "$NORMALIZER_LIB"

# repo_identity()/is_owner_repo_identity() — the same cwd->owner/repo resolver
# polling-state-gate.sh uses, so both agree on what "this checkout" is called.
# Required, not optional (issue #1366): scope resolution now depends on it, and
# a missing library must not silently reopen the flat-path default it replaced.
SCOPE_LIB="${SCRIPT_DIR}/lib/pr-scope-resolver.sh"
if [[ ! -f "$SCOPE_LIB" ]]; then
  echo "handoff-state.sh: missing sibling library: $SCOPE_LIB" >&2
  exit 5
fi
# shellcheck source=./lib/pr-scope-resolver.sh
source "$SCOPE_LIB"

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
MODE=""
PR_NUMBER=""
JQ_PATH_VALUE=""
ARRAY_FIELD=""
ARRAY_VALUE=""
JSON_BODY=""
OWNER_REPO=""
OWNER_REPO_EXPLICIT=""
LEGACY_FLAT=0
REQUIRE_EXISTING=0
SCOPE_SOURCE=""

# Print the whole leading comment block. Driven by the comment prefix rather
# than a hardcoded line range so adding a header section can never silently
# truncate the usage text (issue #1302 added one).
print_usage() {
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

if [[ $# -eq 0 ]]; then
  print_usage >&2; exit 2
fi

# Scope flags, in any order, before the mode flag. --owner-repo names the repo
# explicitly; --legacy-flat is the explicit opt-in to the pre-#655 flat path.
# They contradict each other, so passing both is a usage error rather than a
# silent precedence rule (issue #1366).
while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner-repo)
      OWNER_REPO_EXPLICIT="${2:-}"
      if [[ -z "$OWNER_REPO_EXPLICIT" ]]; then
        echo "handoff-state.sh: --owner-repo requires a value (e.g., --owner-repo owner/repo)" >&2; exit 2
      fi
      # Lowercase-normalize immediately so ~/.claude/handoffs/{owner}/{repo}/ paths
      # are always lowercase (issue #704 — mirrors session-state.sh's key contract).
      OWNER_REPO_EXPLICIT="$(normalize_repo_key "$OWNER_REPO_EXPLICIT")"
      # Validate the SHAPE, not just the presence of a slash. This value becomes
      # a {owner}/{repo} directory pair, so `org/a/b`, `org/`, `/repo` and
      # `org/repo name` have no valid target, and `./.` resolves back to the
      # legacy flat path — reaching the target --legacy-flat exists to gate
      # (CodeAnt, PR #1423). Refuse at the flag rather than deeper in.
      if ! is_strict_owner_repo "$OWNER_REPO_EXPLICIT"; then
        echo "handoff-state.sh: --owner-repo '${2:-}' is not a usable <owner>/<repo> value: it must be exactly two non-empty components drawn from [A-Za-z0-9._-] (no nested paths, no spaces, no . or .. components). Nothing was read or written. Pass --legacy-flat if you meant ${HANDOFF_DIR}/pr-<N>-handoff.json (issue #1366)." >&2
        exit 2
      fi
      shift 2
      ;;
    --legacy-flat)
      LEGACY_FLAT=1
      shift
      ;;
    --require-existing)
      REQUIRE_EXISTING=1
      shift
      ;;
    *)
      break
      ;;
  esac
done

if [[ -n "$OWNER_REPO_EXPLICIT" && "$LEGACY_FLAT" -eq 1 ]]; then
  echo "handoff-state.sh: --owner-repo and --legacy-flat are mutually exclusive — pass one" >&2; exit 2
fi

if [[ $# -eq 0 ]]; then
  echo "handoff-state.sh: scope flags require a mode flag after them" >&2; exit 2
fi

if [[ -n "$OWNER_REPO_EXPLICIT" ]]; then
  OWNER_REPO="$OWNER_REPO_EXPLICIT"
  SCOPE_SOURCE="--owner-repo"
fi

case "$1" in
  --path)
    MODE="path"
    PR_NUMBER="${2:-}"
    if [[ -z "$PR_NUMBER" ]]; then
      echo "handoff-state.sh: --path requires <pr_number>" >&2; exit 2
    fi
    ;;
  --get)
    MODE="get"
    PR_NUMBER="${2:-}"
    if [[ -z "$PR_NUMBER" ]]; then
      echo "handoff-state.sh: --get requires <pr_number>" >&2; exit 2
    fi
    ;;
  --create)
    MODE="create"
    PR_NUMBER="${2:-}"
    JSON_BODY="${3:-}"
    if [[ -z "$PR_NUMBER" || -z "$JSON_BODY" ]]; then
      echo "handoff-state.sh: --create requires <pr_number> <json-body>" >&2; exit 2
    fi
    ;;
  --init)
    MODE="init"
    PR_NUMBER="${2:-}"
    JSON_BODY="${3:-}"
    if [[ -z "$PR_NUMBER" || -z "$JSON_BODY" ]]; then
      echo "handoff-state.sh: --init requires <pr_number> <json-body>" >&2; exit 2
    fi
    ;;
  --set)
    MODE="set"
    PR_NUMBER="${2:-}"
    JQ_PATH_VALUE="${3:-}"
    if [[ -z "$PR_NUMBER" || -z "$JQ_PATH_VALUE" ]]; then
      echo "handoff-state.sh: --set requires <pr_number> <jq-path>=<value>" >&2; exit 2
    fi
    if [[ "$JQ_PATH_VALUE" != *"="* ]]; then
      echo "handoff-state.sh: --set argument must contain '=': $JQ_PATH_VALUE" >&2; exit 2
    fi
    ;;
  --append)
    MODE="append"
    PR_NUMBER="${2:-}"
    ARRAY_FIELD="${3:-}"
    ARRAY_VALUE="${4:-}"
    if [[ -z "$PR_NUMBER" || -z "$ARRAY_FIELD" || -z "$ARRAY_VALUE" ]]; then
      echo "handoff-state.sh: --append requires <pr_number> <field> <value>" >&2; exit 2
    fi
    ;;
  --delete)
    MODE="delete"
    PR_NUMBER="${2:-}"
    if [[ -z "$PR_NUMBER" ]]; then
      echo "handoff-state.sh: --delete requires <pr_number>" >&2; exit 2
    fi
    ;;
  -h|--help)
    print_usage; exit 0
    ;;
  *)
    echo "handoff-state.sh: unknown mode: $1" >&2; exit 2
    ;;
esac

if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "handoff-state.sh: pr_number must be a positive integer (got: $PR_NUMBER)" >&2; exit 2
fi

# Scope flags must PRECEDE the mode flag; the parse loop above stops at the mode.
# Anything left over was ignored, and ignoring a misplaced --legacy-flat is the
# worst possible silence: the caller explicitly asked for the flat path and the
# write would land on the derived SCOPED one instead. Reject trailing arguments
# rather than discarding them (issue #1366).
case "$MODE" in
  path|get|delete)  _expected_argc=2 ;;
  create|init|set)  _expected_argc=3 ;;
  append)           _expected_argc=4 ;;
  *)                _expected_argc=$# ;;
esac
if [[ $# -gt "$_expected_argc" ]]; then
  shift "$_expected_argc"
  echo "handoff-state.sh: unexpected trailing argument(s) after --${MODE} ${PR_NUMBER}: $*" >&2
  echo "handoff-state.sh: leading flags (--owner-repo, --legacy-flat, --require-existing) must come BEFORE the mode flag — e.g. 'handoff-state.sh --legacy-flat --${MODE} ${PR_NUMBER} ...'. Nothing was read or written (issue #1366)." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Validate and resolve the handoff file path.
#
# Scoped (owner/repo resolved): ~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json
# Legacy flat (explicit only)  : ~/.claude/handoffs/pr-{N}-handoff.json
# ---------------------------------------------------------------------------
_resolve_handoff_path() {
  local pr="$1" owner_repo="$2"
  if [[ -n "$owner_repo" ]]; then
    local owner="${owner_repo%%/*}"
    local repo="${owner_repo#*/}"
    # Validate: must have a non-empty owner and repo separated by exactly one slash.
    if [[ -z "$owner" || -z "$repo" || "$owner" == "$owner_repo" ]]; then
      echo "handoff-state.sh: invalid --owner-repo '$owner_repo' (expected owner/repo)" >&2
      return 2
    fi
    # Guard against path traversal (GitHub slugs are alphanumeric+hyphen, but be safe).
    if [[ "$owner" == ".."* || "$repo" == ".."* || "$owner" == *"/"* || "$repo" == *"/"* ]]; then
      echo "handoff-state.sh: unsafe --owner-repo value: $owner_repo" >&2
      return 2
    fi
    printf '%s/%s/%s/pr-%s-handoff.json\n' "$HANDOFF_DIR" "$owner" "$repo" "$pr"
  else
    printf '%s/pr-%s-handoff.json\n' "$HANDOFF_DIR" "$pr"
  fi
}

# ---------------------------------------------------------------------------
# Resolve the scope when --owner-repo was omitted (issue #1366).
#
# Before this, omission silently selected the flat path: the write succeeded,
# exited 0, and landed somewhere every scoped reader ignores — a whole phase's
# updates gone with nothing to notice. PR #1337 made that case warn, which still
# left the wrong path as the easy default. Deriving the repo removes the default
# instead of the path: the flat path stays reachable, but only when asked for.
#
# Precedence mirrors session-state.sh (--repo / $CLAUDE_SESSION_REPO / cwd
# origin) so one checkout cannot resolve to two different repo keys depending on
# which helper is asked.
# ---------------------------------------------------------------------------
if [[ -n "$OWNER_REPO" ]]; then
  # Explicitly scoped. An ambient CLAUDE_HANDOFF_FLAT_OK=1 does NOT get to
  # redirect a call that named its repo — it is exported around flat-layout
  # sweeps, and silently swallowing --owner-repo inside one would recreate the
  # invisible wrong-path write this issue closes. Say so rather than picking
  # quietly; the caller passed two contradictory instructions.
  if [[ "${CLAUDE_HANDOFF_FLAT_OK:-0}" == "1" ]]; then
    echo "handoff-state.sh: note: CLAUDE_HANDOFF_FLAT_OK=1 is set, but --owner-repo $OWNER_REPO was passed explicitly and wins — using the scoped path. Unset the variable, or drop --owner-repo, to target ${HANDOFF_DIR}/pr-${PR_NUMBER}-handoff.json." >&2
  fi
elif [[ "$LEGACY_FLAT" -eq 1 ]]; then
  # Explicit per-call legacy request. Silent by contract: this caller means it.
  OWNER_REPO=""
  SCOPE_SOURCE="legacy-flat"
elif [[ "${CLAUDE_HANDOFF_FLAT_OK:-0}" == "1" ]]; then
  # Same escape, but ambient rather than per-call: /wrap exports it around a
  # flat-layout sweep, so it silently covers every omitting call in that process
  # tree. When the cwd WOULD have resolved a scope, say which scoped path is
  # being bypassed — the note that makes the #1366 defect visible if the
  # variable is set wider than its author intended.
  OWNER_REPO=""
  SCOPE_SOURCE="legacy-flat"
  _would_derive="$(repo_identity "$PWD" 2>/dev/null || true)"
  if [[ -n "${CLAUDE_SESSION_REPO:-}" ]] || is_owner_repo_identity "$_would_derive"; then
    _would_derive="${CLAUDE_SESSION_REPO:-$_would_derive}"
    echo "handoff-state.sh: note: CLAUDE_HANDOFF_FLAT_OK=1 sent --${MODE} on PR #${PR_NUMBER} to the legacy flat path, bypassing the scope '$(normalize_repo_key "$_would_derive")' this context resolves to. Pass --legacy-flat per call instead of exporting the variable, or --owner-repo to scope it (issue #1366)." >&2
  fi
else
  if [[ -n "${CLAUDE_SESSION_REPO:-}" ]]; then
    OWNER_REPO="$(normalize_repo_key "$CLAUDE_SESSION_REPO")"
    SCOPE_SOURCE="\$CLAUDE_SESSION_REPO"
    # A set-but-unusable override is its own failure. Falling through to cwd
    # derivation would answer a different question than the one the caller
    # configured, so name the variable rather than quietly routing around it.
    # Strict shape, same as --owner-repo above: a value that merely contains a
    # slash can still name no valid {owner}/{repo} pair, or name one session
    # state routes to `_unknown` — splitting the two halves of one session's
    # records instead of joining them (CodeAnt, PR #1423).
    if ! is_strict_owner_repo "$OWNER_REPO"; then
      echo "handoff-state.sh: \$CLAUDE_SESSION_REPO='${CLAUDE_SESSION_REPO}' is not a usable <owner>/<repo> value (exactly two non-empty components from [A-Za-z0-9._-]) — refusing to guess a different scope for --${MODE} on PR #${PR_NUMBER}. Nothing was read or written. Fix the variable, or pass --owner-repo <owner/repo> (issue #1366)." >&2
      exit 2
    fi
  else
    _derived="$(repo_identity "$PWD" 2>/dev/null || true)"
    # gitdir:/path:/_unknown/empty all mean "no owner/repo here".
    if is_owner_repo_identity "$_derived"; then
      OWNER_REPO="$_derived"
      SCOPE_SOURCE="the 'origin' remote of $PWD"
    fi
  fi
  if [[ -z "$OWNER_REPO" ]]; then
    echo "handoff-state.sh: cannot resolve owner/repo for --${MODE} on PR #${PR_NUMBER} — $PWD is not a git checkout with an 'origin' remote, and neither --owner-repo nor \$CLAUDE_SESSION_REPO is set. Nothing was read or written. Pass --owner-repo <owner/repo>, or --legacy-flat if you really mean ${HANDOFF_DIR}/pr-${PR_NUMBER}-handoff.json (issue #1366)." >&2
    exit 2
  fi
fi

HANDOFF_FILE="$(_resolve_handoff_path "$PR_NUMBER" "$OWNER_REPO")" || exit 2

case "$MODE" in
  create|init|set|append|delete) MODE_IS_WRITE=1 ;;
  *)                             MODE_IS_WRITE=0 ;;
esac

# A scope that was DERIVED (not named by --owner-repo, not --legacy-flat) is a
# guess — a good one, but the caller never confirmed it. Two hazards follow, and
# both stay silent without this block.
if [[ -n "$OWNER_REPO" && "$SCOPE_SOURCE" != "--owner-repo" ]]; then
  _flat_candidate="${HANDOFF_DIR}/pr-${PR_NUMBER}-handoff.json"

  # (1) An un-migrated flat record for this PR, with no scoped file yet.
  #
  # REFUSE every write here. Warning was not enough: --set/--append seed from
  # `{}` when the scoped file is absent, so the write lands a PARTIAL record at
  # the derived path while the complete flat record is orphaned — losing
  # schema_version, reviewer, findings_fixed, and every array element the flat
  # file held. Worse, the warning below is gated on the scoped file's absence,
  # so it fires once and then goes quiet for the rest of the migration window:
  # a transient warning guarding a permanent split. The old code wrote INTO the
  # flat file and kept the record whole, so this would be a regression against
  # the very contract #1366 exists to protect ("unknown fields are always
  # preserved", handoff-files.md).
  #
  # Explicit --owner-repo and --legacy-flat callers are unaffected: both stated
  # which record they meant, and either is the way past this refusal.
  if [[ -f "$_flat_candidate" && ! -f "$HANDOFF_FILE" ]]; then
    if [[ "$MODE_IS_WRITE" -eq 1 ]]; then
      echo "handoff-state.sh: refusing --${MODE} on PR #${PR_NUMBER}: scope '$OWNER_REPO' was derived from ${SCOPE_SOURCE}, but this PR's handoff is still un-migrated at $_flat_candidate and no scoped record exists yet. Writing would strand that record and start a partial one at $HANDOFF_FILE. Nothing was written. Run handoff-migrate.sh, or name the target explicitly: --legacy-flat to update the existing record, --owner-repo $OWNER_REPO to start a scoped one (issue #1366)." >&2
      exit 2
    fi
    echo "handoff-state.sh: WARNING: using $HANDOFF_FILE (owner/repo '$OWNER_REPO' from ${SCOPE_SOURCE}), but an un-migrated flat handoff exists at $_flat_candidate — run handoff-migrate.sh to move it, or pass --legacy-flat to act on it" >&2

  # (2) Otherwise: name the derived scope on writes.
  #
  # The pre-#1366 code warned whenever a write omitted --owner-repo in a
  # resolvable checkout. Deriving silently would be a strict LOSS of diagnostics
  # for the case that actually bites — a write issued from a checkout whose
  # origin is not the PR's repo (/fixpr and the polling gate both run from
  # worktrees that need not match). One line naming the repo and where it came
  # from keeps that visible. Reads stay silent: path resolution is used
  # everywhere, and warning there was noise even under the old rule.
  elif [[ "$MODE_IS_WRITE" -eq 1 ]]; then
    echo "handoff-state.sh: note: --${MODE} on PR #${PR_NUMBER} used scope '$OWNER_REPO', derived from ${SCOPE_SOURCE} — no --owner-repo was passed. Pass it explicitly if this PR belongs to a different repo (issue #1366)." >&2
  fi
fi

# ---------------------------------------------------------------------------
# --path: print the canonical handoff file path and exit (no lock needed).
# ---------------------------------------------------------------------------
if [[ "$MODE" == "path" ]]; then
  printf '%s\n' "$HANDOFF_FILE"
  exit 0
fi

# ---------------------------------------------------------------------------
# --get: lock-free read (mv is atomic on POSIX, so readers always see a
# complete document — never a partial write). Matches the read-doesn't-lock
# rule from session-state.sh and handoff-files.md.
#
# Soft owner_repo assertion: warns on mismatch but never fails hard so that
# callers reading a just-migrated file see the warning rather than an error.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "get" ]]; then
  if [[ ! -f "$HANDOFF_FILE" ]]; then
    echo "handoff-state.sh: handoff file not found: $HANDOFF_FILE" >&2; exit 3
  fi
  # Soft read-time assertion when --owner-repo was provided.
  if [[ -n "$OWNER_REPO" ]]; then
    stored_owner="$(jq -r '.owner_repo // ""' "$HANDOFF_FILE" 2>/dev/null || true)"
    if [[ -n "$stored_owner" && "$stored_owner" != "$OWNER_REPO" ]]; then
      echo "handoff-state.sh: WARNING: owner_repo mismatch in $HANDOFF_FILE: expected '$OWNER_REPO', found '$stored_owner'" >&2
    fi
  fi
  cat "$HANDOFF_FILE"
  exit 0
fi

# The #1302 write-time flat-path warning was removed here by issue #1366: it
# fired when a write omitted --owner-repo in a repo-resolvable checkout, and
# that case now resolves the scoped path instead of the flat one, so the
# condition can no longer occur. The flat path is reached only through
# --legacy-flat, where a warning would be noise because the caller named the
# path on that very call, or through CLAUDE_HANDOFF_FLAT_OK=1, which is ambient
# and therefore carries its own note at scope-resolution time whenever it
# bypasses a scope this context resolves.

# ---------------------------------------------------------------------------
# All write modes: ensure the directory exists, then acquire the lock.
# ---------------------------------------------------------------------------
_file_dir="$(dirname "$HANDOFF_FILE")"
mkdir -p "$_file_dir"

state_lock_acquire "$HANDOFF_FILE" || exit "$STATE_LOCK_EXIT_TIMEOUT"

# --require-existing: refuse to CREATE the record, only to update one.
#
# --set/--append seed from `{}` when the target is absent, which makes them
# silently creating operations. A caller that has already decided "no handoff,
# nothing to update" cannot express that today: it tests -e itself, outside this
# lock, and a delete or migration landing in that window turns its skip into a
# partial record holding only the field it appended — the same `{}`-seeded
# split this file refuses for un-migrated flat records above (issue #1366).
#
# Checked HERE, inside the lock, because a caller-side test can only ever be a
# TOCTOU (CodeAnt, PR #1423). Opt-in, so every existing caller keeps the
# seed-on-absent behavior it was written against.
#
# Scoped to the seeding modes: --create and --init are meant to create, and
# --delete already tolerates an absent target.
if [[ "$REQUIRE_EXISTING" -eq 1 && ( "$MODE" == "set" || "$MODE" == "append" ) && ! -f "$HANDOFF_FILE" ]]; then
  echo "handoff-state.sh: --${MODE} on PR #${PR_NUMBER} requires an existing handoff, but none is at $HANDOFF_FILE (--require-existing). Nothing was written; the record was never created, or was deleted/migrated after the caller checked." >&2
  state_lock_release
  exit 3
fi

# Atomic write using a same-directory temp so mv is on the same filesystem
# (the POSIX guarantee that mv is atomic only holds within one filesystem).
# The lock is already held, so competing writers are serialized before they
# reach this helper — the same-dir mktemp is belt-and-suspenders atomicity.
_atomic_write() {
  local content="$1"
  local tmp
  tmp="$(mktemp "${_file_dir}/.pr-${PR_NUMBER}-handoff.XXXXXX")" || {
    echo "handoff-state.sh: mktemp failed in ${_file_dir}" >&2
    state_lock_release
    exit 5
  }
  printf '%s\n' "$content" > "$tmp" || {
    rm -f "$tmp" 2>/dev/null || true
    echo "handoff-state.sh: write to temp file failed" >&2
    state_lock_release
    exit 5
  }
  # Fail closed if the lock was broken and re-taken while we were reading and
  # transforming. $content was computed from a snapshot another writer has
  # since replaced, so committing it would silently discard their update —
  # the exact lost-append failure in issue #930. Exit 6 ("unchanged, retry")
  # instead: a loud, retryable error beats a silent overwrite. This sits as
  # late as possible, immediately before the commit.
  if ! state_lock_assert_held; then
    rm -f "$tmp" 2>/dev/null || true
    state_lock_release
    _rmw_retry_or_fail
  fi
  if ! mv "$tmp" "$HANDOFF_FILE"; then
    rm -f "$tmp" 2>/dev/null || true
    echo "handoff-state.sh: mv to $HANDOFF_FILE failed" >&2
    state_lock_release
    exit 5
  fi
}

# ---------------------------------------------------------------------------
# --create: create or overwrite the handoff file with the supplied JSON body.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "create" ]]; then
  if ! printf '%s\n' "$JSON_BODY" | jq -e . >/dev/null 2>&1; then
    echo "handoff-state.sh: --create body is not valid JSON" >&2
    state_lock_release; exit 4
  fi
  _atomic_write "$JSON_BODY"
  state_lock_release; exit 0
fi

# ---------------------------------------------------------------------------
# --init: create the handoff file ONLY if it does not already exist. The
# existence check and the write both happen inside the advisory lock, so there
# is no race between a concurrent Phase A writer and a polling checkpoint.
# If the file already exists (e.g., Phase A beat us here), exit 0 without
# touching it — preserving the richer phase handoff (Greptile P1, issue #682).
# ---------------------------------------------------------------------------
if [[ "$MODE" == "init" ]]; then
  if ! printf '%s\n' "$JSON_BODY" | jq -e . >/dev/null 2>&1; then
    echo "handoff-state.sh: --init body is not valid JSON" >&2
    state_lock_release; exit 4
  fi
  if [[ -f "$HANDOFF_FILE" ]]; then
    # File already exists — another writer (Phase A/B) got here first; no-op.
    state_lock_release; exit 0
  fi
  _atomic_write "$JSON_BODY"
  state_lock_release; exit 0
fi

# ---------------------------------------------------------------------------
# --delete: lock-guarded delete to prevent a delete from racing a still-running
# writer on the same PR. Idempotent — deleting an absent file exits 0.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "delete" ]]; then
  if [[ -f "$HANDOFF_FILE" ]]; then
    rm -f "$HANDOFF_FILE" 2>/dev/null || {
      echo "handoff-state.sh: rm failed for $HANDOFF_FILE" >&2
      state_lock_release; exit 5
    }
  fi
  state_lock_release; exit 0
fi

# ---------------------------------------------------------------------------
# --set / --append: read-modify-write (lock is already held above).
# Seed from the existing file when present; otherwise start from {}.
# ---------------------------------------------------------------------------
CURRENT="{}"
if [[ -f "$HANDOFF_FILE" ]]; then
  if ! CURRENT="$(jq -e . "$HANDOFF_FILE" 2>/dev/null)"; then
    echo "handoff-state.sh: existing handoff is not valid JSON: $HANDOFF_FILE" >&2
    state_lock_release; exit 4
  fi
fi

if [[ "$MODE" == "set" ]]; then
  JQ_PATH="${JQ_PATH_VALUE%%=*}"
  JQ_VAL="${JQ_PATH_VALUE#*=}"
  # Detect whether the value is a valid JSON literal or a bare string by asking
  # `--argjson` itself, which is the exact operation the JSON branch performs.
  #
  # NOT `jq -e .`: `-e` sets its exit status from the OUTPUT value's truthiness
  # rather than parse success, so the perfectly valid literals `null` and `false`
  # exit non-zero and get silently coerced to the strings "null"/"false". "false"
  # is TRUTHY in jq, so a later `if .merge_gate_met then` reads a failed gate as
  # passed (issue #853).
  #
  # NOT `jq empty` either: it accepts zero-value input — empty AND whitespace-only
  # ("", " ", "\t") — while `--argjson` rejects all three, so those values would
  # pass the probe and then hard-fail the write instead of storing as strings.
  # Probing with `--argjson` keeps every value it cannot carry on the string path.
  if jq -n --argjson v "$JQ_VAL" 'empty' >/dev/null 2>&1; then
    UPDATED="$(printf '%s\n' "$CURRENT" | jq --argjson v "$JQ_VAL" "${JQ_PATH} = \$v")" || {
      echo "handoff-state.sh: jq --set failed on path $JQ_PATH" >&2
      state_lock_release; exit 4
    }
  else
    # The value is not a JSON literal, so it is headed for the --arg string
    # branch. Before storing it verbatim, refuse the one shape that is never
    # data: an unevaluated jq PROGRAM the caller meant to have evaluated
    # (issue #1357). `--set N .notes=.notes + " x"` used to exit 0 and store the
    # expression SOURCE, clobbering the previous notes with no error — the loss
    # only surfaced on read-back. A hard refusal leaves the old value intact.
    #
    # Three independent signals must ALL fire, because the string branch is the
    # normal home of prose notes, SHAs, paths and URLs, and a false reject is a
    # broken write for a legitimate value:
    #   1. It STARTS like a jq path expression — optional whitespace, an
    #      optional `(`, then `.` followed by an identifier character. The
    #      identifier requirement is what keeps relative paths out: `./x`,
    #      `../x` and `.github/workflows/ci.yml` are common values, and only the
    #      last of those even reaches signal 2.
    #   2. It CONTAINS a jq operator, so a bare path-shaped token
    #      (`.claude/scripts/handoff-state.sh`) is still stored as a string.
    #   3. It COMPILES as a jq program. Signals 1+2 alone would reject prose
    #      like `.env + .env.local are ignored`; that text is not valid jq, so
    #      this check keeps it on the string path. The probe wraps the value in
    #      a `def` that is never invoked and leaves `empty` as the only
    #      top-level expression, so nothing in the value is evaluated and no
    #      input is read — a property the `#` and `;` bail-outs below are what
    #      actually guarantee, since either character lets the value reach the
    #      terminator and promote its own tail to top level.
    # Anything short of all three keeps the pre-existing store-as-string
    # behavior, so an unrecognized expression degrades to today's semantics
    # rather than to a new failure.
    #
    # The probe must never EVALUATE the value, only compile it. Two different
    # constructs can carry the value across the terminator and defeat that, so
    # there are three defences (PR #1378 / issue #1357):
    #
    #   * The probe is assembled across FOUR LINES — the value gets a line of
    #     its own; the `;` terminator and `empty` get theirs. On one line, a
    #     value ending in `#` swallows the terminator and promotes its OWN
    #     tail to top-level expression, which jq then EXECUTES during what is
    #     supposed to be a compile: `.a + 1; def g: 1; last(repeat(1)) #` hung
    #     a single-line probe indefinitely while this script held the state
    #     lock, blocking every sibling pipeline (CodeAnt). Confined to its own
    #     line, a comment can no longer reach the terminator. That closes the
    #     COMMENT route only — on its own it does not make `empty` the
    #     top-level expression, which is what the `;` bail-out below is for.
    #
    #   * A value containing `#` at all skips the probe. Line discipline stops
    #     the comment at the value, but INSIDE the value it still hides
    #     everything after it, so jq would be judging a PREFIX and reporting
    #     "compiles" for text that is not an expression: `.claude/rules +
    #     .claude/reference # see PR #1378` compiles down to `.claude/rules +
    #     .claude/reference` and would be refused as an expression. Declining
    #     to judge is the conservative branch — a `#` value stores as a string
    #     exactly as it does today. It also costs a false NEGATIVE on real jq
    #     carrying a `#` in a string literal (`.notes + "issue #1357"`), which
    #     is the direction this guard is allowed to be wrong in.
    #
    #   * A value containing `;` at all skips the probe. Line discipline stops
    #     a COMMENT from reaching the terminator, but a trailing unterminated
    #     `def` absorbs it outright: jq's grammar admits `Exp := FuncDef Exp`,
    #     so `.a ; last(repeat(1)) as $x | def h: 1` ends the probe's own `def`
    #     early at its first `;`, hands the terminator to `def h` as ITS
    #     terminator, and leaves `last(repeat(1))` a TOP-LEVEL expression that
    #     jq executes — the same indefinite hang under the state lock, with no
    #     `#` anywhere (CodeRabbit). Escaping the wrapper at all requires
    #     ending the probe's `def` early, and that requires a `;`, so refusing
    #     to judge any value containing one closes the class rather than one
    #     shape: with no `;` in the value the terminator is either still ours
    #     (`empty` is the only top-level expression, nothing evaluates) or is
    #     absorbed by a trailing `def` that then leaves NO top-level expression
    #     at all, which jq rejects at compile time — verified both ways. Same
    #     conservative trade as `#`: a `;` value stores as a string exactly as
    #     it does today, costing a false NEGATIVE on genuine jq that uses `;`
    #     (`reduce .[] as $x (0; . + $x)`), the direction this guard is allowed
    #     to be wrong in.
    _JQ_EXPR_START='^[[:space:]]*\(?[[:space:]]*\.[A-Za-z_]'
    _JQ_EXPR_OPS='(\||//|\+|map\(|select\()'
    _JQ_PROBE="def _handoff_set_probe:
${JQ_VAL}
;
empty"
    if [[ "$JQ_VAL" != *'#'* ]] && [[ "$JQ_VAL" != *';'* ]] \
       && [[ "$JQ_VAL" =~ $_JQ_EXPR_START ]] && [[ "$JQ_VAL" =~ $_JQ_EXPR_OPS ]] \
       && jq -n "$_JQ_PROBE" </dev/null >/dev/null 2>&1; then
      echo "handoff-state.sh: refusing to write — the value for '$JQ_PATH' is an unevaluated jq expression, not data: '$JQ_VAL' (see issue #1357); evaluate it first and pass the resulting scalar; $HANDOFF_FILE left unmodified" >&2
      state_lock_release; exit 4
    fi
    UPDATED="$(printf '%s\n' "$CURRENT" | jq --arg v "$JQ_VAL" "${JQ_PATH} = \$v")" || {
      echo "handoff-state.sh: jq --set (string) failed on path $JQ_PATH" >&2
      state_lock_release; exit 4
    }
  fi
  _atomic_write "$UPDATED"
  state_lock_release; exit 0
fi

if [[ "$MODE" == "append" ]]; then
  # NOTE: the jq-expression refusal above is deliberately --set-only (issue
  # #1357). --append does not share that value branch, its values are array
  # ELEMENTS rather than whole-field replacements, and it cannot clobber a
  # prior value — appending a bad element leaves everything already in the
  # array intact. Widening the guard here is a separate decision, not an
  # oversight.
  # findings_dismissed deduplicates by .id; all other arrays dedup by exact value.
  if [[ "$ARRAY_FIELD" == "findings_dismissed" ]]; then
    if ! printf '%s' "$ARRAY_VALUE" | jq -e 'type == "object" and has("id")' >/dev/null 2>&1; then
      echo "handoff-state.sh: findings_dismissed elements must be JSON objects with an .id field" >&2
      state_lock_release; exit 4
    fi
    UPDATED="$(printf '%s\n' "$CURRENT" | jq \
      --argjson elem "$ARRAY_VALUE" \
      --arg field "$ARRAY_FIELD" \
      '.[$field] = (((.[$field] // []) + [$elem]) | unique_by(.id))')" || {
      echo "handoff-state.sh: jq append (findings_dismissed) failed" >&2
      state_lock_release; exit 4
    }
  else
    # String array: only treat value as pre-encoded JSON when it IS a JSON string
    # (starts with '"'). Numbers and other JSON scalars must be coerced to strings to
    # preserve the string-array contract — a bare numeric ID like 1234567890 would
    # otherwise parse as a JSON number and break exact-value deduplication and
    # downstream string consumers (Greptile P1, issue #682).
    if [[ "$ARRAY_VALUE" == '"'* ]] && printf '%s' "$ARRAY_VALUE" | jq -e 'type == "string"' >/dev/null 2>&1; then
      UPDATED="$(printf '%s\n' "$CURRENT" | jq \
        --argjson elem "$ARRAY_VALUE" \
        --arg field "$ARRAY_FIELD" \
        '.[$field] = (((.[$field] // []) + [$elem]) | unique)')" || {
        echo "handoff-state.sh: jq append (json value) failed for field $ARRAY_FIELD" >&2
        state_lock_release; exit 4
      }
    else
      UPDATED="$(printf '%s\n' "$CURRENT" | jq \
        --arg elem "$ARRAY_VALUE" \
        --arg field "$ARRAY_FIELD" \
        '.[$field] = (((.[$field] // []) + [$elem]) | unique)')" || {
        echo "handoff-state.sh: jq append (string) failed for field $ARRAY_FIELD" >&2
        state_lock_release; exit 4
      }
    fi
  fi
  _atomic_write "$UPDATED"
  state_lock_release; exit 0
fi

# Should never reach here.
echo "handoff-state.sh: internal error — unhandled mode: $MODE" >&2
state_lock_release; exit 2
