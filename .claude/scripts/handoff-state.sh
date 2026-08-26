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
# REPO SCOPING (issue #655)
#   Handoff files are stored in a per-repo subdirectory to prevent two repos at
#   the same PR number from sharing one file:
#     ~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json
#   Pass --owner-repo <owner/repo> (e.g., --owner-repo auerbachb/myrepo) as
#   the FIRST argument (before the mode flag) to use the scoped path.  Without
#   --owner-repo the legacy flat path is used:
#     ~/.claude/handoffs/pr-{N}-handoff.json
#   The flat path is preserved for backward compatibility during migration; new
#   code should always pass --owner-repo.  The handoff-migrate.sh script moves
#   existing flat files into the scoped layout.
#
# FLAT-PATH WARNING (issue #1302)
#   A WRITE mode that omits --owner-repo while standing in a checkout that
#   resolves to owner/repo warns on stderr and proceeds on the flat path.  It
#   warns rather than refuses so genuinely repo-less and pre-migration callers
#   keep working; the silent fallback is what let a Phase B agent write the flat
#   path while Phase C read the scoped one.  Read modes (--path, --get) never
#   warn.  Set CLAUDE_HANDOFF_FLAT_OK=1 for a caller that means the flat path on
#   purpose (flat-layout cleanup sweeps, migration tooling).
#   Decision record: .claude/reference/handoff-missing-owner-repo-decision.md
#
# USAGE
#   handoff-state.sh [--owner-repo <owner/repo>] --path   <pr_number>        # print canonical path (no lock)
#   handoff-state.sh [--owner-repo <owner/repo>] --get    <pr_number>        # lock-free read
#   handoff-state.sh [--owner-repo <owner/repo>] --create <pr_number> <json> # locked create/overwrite
#   handoff-state.sh [--owner-repo <owner/repo>] --init   <pr_number> <json> # locked create-if-absent (no-op if exists)
#   handoff-state.sh [--owner-repo <owner/repo>] --set    <pr_number> <jq-path>=<value>
#   handoff-state.sh [--owner-repo <owner/repo>] --append <pr_number> <field> <value>
#   handoff-state.sh [--owner-repo <owner/repo>] --delete <pr_number>        # locked delete
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
# EXIT CODES
#   0  Success.
#   2  Usage error (missing args, unknown flag, malformed path=value).
#   3  Handoff file not found (--get only; other modes create/seed from {}).
#   4  jq parse or evaluation failure. ALSO: --set refuses a value that is an
#      unevaluated jq expression rather than data (issue #1357) — the file is
#      left unmodified. Evaluate the expression first and pass the result.
#   5  Write failure (mktemp / mv).
#   6  Lock timeout (STATE_LOCK_EXIT_TIMEOUT from state-lock.sh).
#
# DEPENDENCIES
#   jq, mktemp, mv (POSIX), .claude/scripts/state-lock.sh (sibling library).

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  >> "${HOME}/.claude/script-usage.log" 2>/dev/null || true

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

# Print the whole leading comment block. Driven by the comment prefix rather
# than a hardcoded line range so adding a header section can never silently
# truncate the usage text (issue #1302 added one).
print_usage() {
  awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

if [[ $# -eq 0 ]]; then
  print_usage >&2; exit 2
fi

# Optional global flag: --owner-repo must come before the mode flag.
# Enables per-repo path scoping: ~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json
# Without it the legacy flat path is used: ~/.claude/handoffs/pr-{N}-handoff.json
if [[ "${1:-}" == "--owner-repo" ]]; then
  OWNER_REPO="${2:-}"
  if [[ -z "$OWNER_REPO" ]]; then
    echo "handoff-state.sh: --owner-repo requires a value (e.g., --owner-repo owner/repo)" >&2; exit 2
  fi
  # Lowercase-normalize immediately so ~/.claude/handoffs/{owner}/{repo}/ paths
  # are always lowercase (issue #704 — mirrors session-state.sh's key contract).
  OWNER_REPO="$(normalize_repo_key "$OWNER_REPO")"
  shift 2
  if [[ $# -eq 0 ]]; then
    echo "handoff-state.sh: --owner-repo requires a mode flag after it" >&2; exit 2
  fi
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

# ---------------------------------------------------------------------------
# Validate and resolve the handoff file path.
#
# With --owner-repo: ~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json
# Without          : ~/.claude/handoffs/pr-{N}-handoff.json (legacy flat)
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

HANDOFF_FILE="$(_resolve_handoff_path "$PR_NUMBER" "$OWNER_REPO")" || exit 2

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

# ---------------------------------------------------------------------------
# Soft flat-path warning for write modes (issue #1302).
#
# Only reached by create/init/set/append/delete — --path and --get returned
# above, so resolving a path stays silent and cheap.
#
# A write that omits --owner-repo lands on the legacy flat path even when the
# caller is standing in a checkout whose scoped path the next phase will read.
# That divergence is invisible today: the wrong-path write succeeds, and the
# reader simply sees an older record. Warn and proceed — refusing would break
# the pre-migration and genuinely repo-less callers the flat path exists for.
# Rationale and rejected designs:
#   .claude/reference/handoff-missing-owner-repo-decision.md
# ---------------------------------------------------------------------------
_warn_flat_path_when_repo_resolvable() {
  [[ -n "$OWNER_REPO" ]] && return 0
  [[ "${CLAUDE_HANDOFF_FLAT_OK:-0}" == "1" ]] && return 0

  # repo_identity()/is_owner_repo_identity() live in the polling gate's scope
  # resolver. Treat it as optional: a checkout without the library keeps the
  # pre-#1302 silent behavior rather than failing a write over a missing warning.
  local resolver="${SCRIPT_DIR}/lib/pr-scope-resolver.sh"
  [[ -f "$resolver" ]] || return 0
  # shellcheck source=./lib/pr-scope-resolver.sh
  source "$resolver" 2>/dev/null || return 0

  local identity scoped
  identity="$(repo_identity "$PWD" 2>/dev/null || true)"
  # gitdir:/path:/_unknown/empty all mean "no owner/repo here" — stay silent.
  is_owner_repo_identity "$identity" || return 0
  scoped="$(_resolve_handoff_path "$PR_NUMBER" "$identity" 2>/dev/null)" || return 0

  echo "handoff-state.sh: WARNING: --${MODE} without --owner-repo targets the legacy flat path $HANDOFF_FILE, but this checkout resolves to '$identity', whose scoped path is $scoped — later phases read the scoped path, so pass --owner-repo $identity (set CLAUDE_HANDOFF_FLAT_OK=1 if the flat path is intended)" >&2
}
_warn_flat_path_when_repo_resolvable

# ---------------------------------------------------------------------------
# All write modes: ensure the directory exists, then acquire the lock.
# ---------------------------------------------------------------------------
_file_dir="$(dirname "$HANDOFF_FILE")"
mkdir -p "$_file_dir"

state_lock_acquire "$HANDOFF_FILE" || exit "$STATE_LOCK_EXIT_TIMEOUT"

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
    #      input is read.
    # Anything short of all three keeps the pre-existing store-as-string
    # behavior, so an unrecognized expression degrades to today's semantics
    # rather than to a new failure.
    #
    # A jq comment runs to end of line, and both defences below exist because
    # of that (CodeAnt, PR #1378 / issue #1357):
    #
    #   * The probe is assembled across FOUR LINES — the value gets a line of
    #     its own; the `;` terminator and `empty` get theirs. On one line, a
    #     value ending in `#` swallows the terminator and promotes its OWN
    #     tail to top-level expression, which jq then EXECUTES during what is
    #     supposed to be a compile: `.a + 1; def g: 1; last(repeat(1)) #` hung
    #     a single-line probe indefinitely while this script held the state
    #     lock, blocking every sibling pipeline. Confined to its own line, a
    #     comment can no longer reach the terminator, so the top-level
    #     expression is always the standalone `empty` and nothing evaluates.
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
    _JQ_EXPR_START='^[[:space:]]*\(?[[:space:]]*\.[A-Za-z_]'
    _JQ_EXPR_OPS='(\||//|\+|map\(|select\()'
    _JQ_PROBE="def _handoff_set_probe:
${JQ_VAL}
;
empty"
    if [[ "$JQ_VAL" != *'#'* ]] \
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
