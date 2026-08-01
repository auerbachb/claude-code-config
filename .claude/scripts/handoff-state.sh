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
#   4  jq parse or evaluation failure.
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

print_usage() {
  sed -n '2,67p' "$0" | sed 's/^# \{0,1\}//'
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
    UPDATED="$(printf '%s\n' "$CURRENT" | jq --arg v "$JQ_VAL" "${JQ_PATH} = \$v")" || {
      echo "handoff-state.sh: jq --set (string) failed on path $JQ_PATH" >&2
      state_lock_release; exit 4
    }
  fi
  _atomic_write "$UPDATED"
  state_lock_release; exit 0
fi

if [[ "$MODE" == "append" ]]; then
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
