#!/usr/bin/env bash
# handoff-migrate.sh — Migrate flat handoff files to per-repo scoped paths (issue #655).
#
# Background
#   Before issue #655, every handoff file lived at a flat path:
#     ~/.claude/handoffs/pr-{N}-handoff.json
#   Two repos at the same PR number therefore shared one file.  The fix
#   (implemented in handoff-state.sh) stores files under a per-repo subdirectory:
#     ~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json
#
#   This script moves existing flat files into the new layout.  It NEVER deletes
#   flat files — it only moves/renames (cp + rm after verify, effectively).
#
# Attribution strategy (per spawn-prompt design)
#   1. Read the file's own `owner_repo` field (written by new polling-state-gate.sh).
#   2. If absent, check ~/.claude/session-state.json for a PR entry that names a
#      `owner_repo` whose PR number matches the filename.
#   3. If still unattributable → move to ~/.claude/handoffs/_unknown/pr-{N}-handoff.json.
#      Never delete; never overwrite an existing destination.
#
# Safety
#   - Dry-run by default; pass --apply to execute moves.
#   - Idempotent: re-running on already-migrated files is a no-op (source absent →
#     skip; destination already exists → skip with a notice).
#   - Never deletes any file (source or destination).
#   - Never writes to the root repo — all output goes to ~/.claude/handoffs/.
#
# Usage
#   handoff-migrate.sh [--apply] [--verbose]
#
# Exit codes
#   0   All files processed (including dry-run).
#   1   One or more files could not be moved (--apply only; dry-run always exits 0).
#
set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  >> "${HOME}/.claude/script-usage.log" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Shared case-normalizer (issue #704): lowercase owner_repo values before
# building destination paths so a mixed-case embedded owner_repo field
# (e.g. "AuerbachB/Skingod") doesn't produce a differently-cased directory
# than the lowercase path session-state.sh and handoff-state.sh would use.
# Use the library when available; fall back to inline so the script is
# self-contained in environments without the lib (e.g. pre-#704 worktrees).
_NORMALIZER_LIB="${SCRIPT_DIR}/lib/repo-normalizer.sh"
if [[ -f "$_NORMALIZER_LIB" ]]; then
  # shellcheck source=./lib/repo-normalizer.sh
  source "$_NORMALIZER_LIB"
else
  normalize_repo_key() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
fi
unset _NORMALIZER_LIB

HANDOFF_DIR="${HOME}/.claude/handoffs"
STATE_FILE="${HOME}/.claude/session-state.json"
APPLY=0
VERBOSE=0
ERRORS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)   APPLY=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "handoff-migrate.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

log() { echo "$*"; }
verbose() { [[ "$VERBOSE" -eq 1 ]] && echo "$*" || true; }

# ---------------------------------------------------------------------------
# Build a lookup file: pr_number<TAB>owner_repo from session-state.json,
# so files that lack an embedded owner_repo can still be attributed.
# Written to a temp file (no declare -A; bash 3.2 compat).
# ---------------------------------------------------------------------------
STATE_LOOKUP_FILE=""
STATE_LOOKUP_FILE="$(mktemp "${HANDOFF_DIR}/.migrate-lookup.XXXXXX" 2>/dev/null \
  || mktemp /tmp/.migrate-lookup.XXXXXX)"
_cleanup_lookup() { rm -f "$STATE_LOOKUP_FILE" 2>/dev/null || true; }
trap _cleanup_lookup EXIT

if [[ -f "$STATE_FILE" ]]; then
  # Flatten all per-repo PR entries to "pr_number\towner_repo" lines.
  # session-state.json shape: .repos["owner/repo"].prs["N"].owner_repo
  # We also accept the flat (pre-#638) .prs["N"].owner_repo.
  {
    jq -r '
      (.repos // {}) | to_entries[] |
      (.value.prs // {}) | to_entries[] |
      select((.value.owner_repo? // "") != "") |
      [.key, .value.owner_repo] | @tsv
    ' "$STATE_FILE" 2>/dev/null || true
    jq -r '
      (.prs // {}) | to_entries[] |
      select((.value.owner_repo? // "") != "") |
      [.key, .value.owner_repo] | @tsv
    ' "$STATE_FILE" 2>/dev/null || true
  } | sort -u > "$STATE_LOOKUP_FILE"
fi

# Lookup helper: given a PR number, return the first matching owner_repo or "".
_lookup_owner_repo() {
  local pr="$1"
  if [[ -s "$STATE_LOOKUP_FILE" ]]; then
    grep -E "^${pr}	" "$STATE_LOOKUP_FILE" | head -1 | cut -f2 || true
  fi
}

# ---------------------------------------------------------------------------
# Helper: validate owner/repo — same rules as handoff-state.sh.
# ---------------------------------------------------------------------------
_valid_owner_repo() {
  local or="$1"
  local owner="${or%%/*}"
  local repo="${or#*/}"
  [[ -z "$owner" || -z "$repo" || "$owner" == "$or" ]] && return 1
  [[ "$owner" == ".."* || "$repo" == ".."* || "$owner" == *"/"* || "$repo" == *"/"* ]] && return 1
  return 0
}

# ---------------------------------------------------------------------------
# Process each flat handoff file.
# ---------------------------------------------------------------------------
shopt -s nullglob
FLAT_FILES=("${HANDOFF_DIR}"/pr-*.json)
shopt -u nullglob

if [[ ${#FLAT_FILES[@]} -eq 0 ]]; then
  log "handoff-migrate.sh: no flat handoff files found in $HANDOFF_DIR"
  exit 0
fi

log "handoff-migrate.sh: found ${#FLAT_FILES[@]} flat handoff file(s) in $HANDOFF_DIR"
[[ "$APPLY" -eq 0 ]] && log "handoff-migrate.sh: DRY RUN — pass --apply to execute moves"

for src in "${FLAT_FILES[@]}"; do
  basename_file="$(basename "$src")"
  pr_number="${basename_file#pr-}"
  pr_number="${pr_number%-handoff.json}"

  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    verbose "  SKIP $basename_file (cannot parse PR number)"
    continue
  fi

  # --- Determine owner_repo ---
  # 1. Embedded in the file itself.
  file_owner_repo="$(jq -r '.owner_repo // ""' "$src" 2>/dev/null || true)"

  # 2. Derive from session-state lookup file.
  state_owner_repo="$(_lookup_owner_repo "$pr_number")"

  owner_repo="${file_owner_repo:-$state_owner_repo}"
  # Lowercase-normalize before building the destination path (issue #704):
  # a stored owner_repo like "AuerbachB/Skingod" must land in
  # auerbachb/skingod/ not a separately-cased directory.
  [[ -n "$owner_repo" ]] && owner_repo="$(normalize_repo_key "$owner_repo")"

  # 3. Unattributable → _unknown.
  local_dest_dir="$HANDOFF_DIR/_unknown"
  if [[ -n "$owner_repo" ]] && _valid_owner_repo "$owner_repo"; then
    local_dest_dir="${HANDOFF_DIR}/${owner_repo}"
    verbose "  $basename_file -> ${owner_repo}/pr-${pr_number}-handoff.json"
  else
    verbose "  $basename_file -> _unknown/pr-${pr_number}-handoff.json (no owner_repo)"
  fi

  dest="${local_dest_dir}/pr-${pr_number}-handoff.json"

  if [[ "$src" == "$dest" ]]; then
    verbose "  SKIP $basename_file (already at destination)"
    continue
  fi

  if [[ -f "$dest" ]]; then
    log "  SKIP $basename_file — destination already exists: $dest"
    continue
  fi

  if [[ "$APPLY" -eq 1 ]]; then
    if ! mkdir -p "$local_dest_dir"; then
      log "  ERROR: could not create directory $local_dest_dir" >&2
      ERRORS=$((ERRORS + 1))
      continue
    fi
    # Copy first, verify, then remove source — safer than mv across potential
    # filesystem boundaries (e.g., ~/.claude on a different mount point).
    if cp "$src" "$dest" && [[ -f "$dest" ]]; then
      # Verify content is identical.
      if cmp -s "$src" "$dest"; then
        rm -f "$src" 2>/dev/null || {
          log "  WARNING: copied to $dest but could not remove $src" >&2
        }
        log "  MOVED $basename_file -> $dest"
      else
        rm -f "$dest" 2>/dev/null || true
        log "  ERROR: copy verification failed for $basename_file (source preserved)" >&2
        ERRORS=$((ERRORS + 1))
      fi
    else
      log "  ERROR: cp failed for $basename_file" >&2
      ERRORS=$((ERRORS + 1))
    fi
  else
    # Dry-run: just report what would happen.
    log "  WOULD MOVE $basename_file -> $dest"
  fi
done

if [[ "$APPLY" -eq 1 ]]; then
  if [[ "$ERRORS" -gt 0 ]]; then
    log "handoff-migrate.sh: completed with $ERRORS error(s)"
    exit 1
  else
    log "handoff-migrate.sh: migration complete"
  fi
else
  log "handoff-migrate.sh: dry-run complete — pass --apply to execute"
fi
exit 0
