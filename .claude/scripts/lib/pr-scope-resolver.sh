#!/usr/bin/env bash
# lib/pr-scope-resolver.sh — Repo identity and per-PR scope resolution for
# polling-state-gate.sh (issue #971).
#
# Source this file (do NOT execute it directly) from polling-state-gate.sh.
#
# PROBLEM SOLVED
#   The polling gate's repo-scoping seam accumulated five correctness fixes in
#   two weeks: per-repo state lanes, legacy `_unknown` fallback, normalized repo
#   identities, same-number PR isolation, and stale inherited-scope precedence.
#   Keeping that seam inline made an 881-line entry point the only place to
#   understand or change two related decisions: which repo scope owns a PR, and
#   whether the invoking checkout may act on it.
#
# CONTRACT
#   This library preserves those as distinct mechanisms:
#     * resolve_pr_scope() chooses the active repo's lane, then `_unknown`, and
#       never selects another named repo merely because it has the same PR number.
#     * validate_root_match() compares the chosen lane's per-PR identity with the
#       checkout being operated on and refuses genuine contradictions.
#   Every session-state read is delegated to STATE_HELPER (`session-state.sh`).
#   This library never reads or writes session-state.json or handoff JSON
#   directly, and it performs no state mutation.
#
# USAGE
#   polling-state-gate.sh must define these caller-owned values before sourcing:
#     STATE_HELPER STATE_FILE STATE_READ_DIR PR_NUMBER
#     ACTIVE_REPO_KEY PR_SCOPE PR_SCOPE_RESOLVED
#   Before validate_root_match() runs it must also define REPO_KEY_DECLARED.
#   normalize_repo_key() must already be available from lib/repo-normalizer.sh.
#
#   source "$SCRIPT_DIR/lib/pr-scope-resolver.sh"
#   scope="$(resolve_pr_scope)"
#   validate_root_match "$resolved_root"          # ordinary validation
#   validate_root_match "$resolved_root" quiet    # --ensure-session only

# Guard against direct execution. Running a definition-only library would
# otherwise report success while doing nothing.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  echo "pr-scope-resolver.sh: source this file, do not execute it directly" >&2
  exit 2
fi

# Every named scope holding this PR number, newline-separated. `--raw-path`
# addresses the document root, so this sees all scopes while preserving
# session-state.sh's migration and locking boundary.
_pr_holders() {
  ( cd "$STATE_READ_DIR" 2>/dev/null && "$STATE_HELPER" --raw-path --get \
    "[(.repos // {}) | to_entries[] | select(.value.prs[\"$PR_NUMBER\"] != null) | .key] | join(\"\n\")" \
    2>/dev/null || true )
}

active_scope_key() {
  local active="$ACTIVE_REPO_KEY"
  if [[ -z "$active" ]]; then
    active="$(cd "$STATE_READ_DIR" 2>/dev/null && "$STATE_HELPER" --repo-key 2>/dev/null || true)"
  fi
  printf '%s' "$active"
}

resolve_pr_scope() {
  if [[ "$PR_SCOPE_RESOLVED" -eq 1 ]]; then
    printf '%s' "$PR_SCOPE"
    return 0
  fi
  PR_SCOPE_RESOLVED=1
  PR_SCOPE=""
  [[ -f "$STATE_FILE" ]] || { printf '%s' ""; return 0; }
  local active holder
  active="$(active_scope_key)"
  while IFS= read -r holder; do
    [[ -n "$holder" && "$holder" != "null" ]] || continue
    if [[ -n "$active" && "$holder" == "$active" ]]; then
      PR_SCOPE="$holder"
      break
    fi
    # Remember `_unknown`, but keep looking because the active scope wins.
    [[ "$holder" == "_unknown" && -z "$PR_SCOPE" ]] && PR_SCOPE="_unknown"
  done < <(_pr_holders)
  printf '%s' "$PR_SCOPE"
}

# Named scopes other than the active one and `_unknown` that hold the same PR
# number. Diagnostics only; these values are never candidates for reading.
foreign_pr_scopes() {
  [[ -f "$STATE_FILE" ]] || return 0
  local active holder
  active="$(active_scope_key)"
  while IFS= read -r holder; do
    [[ -n "$holder" && "$holder" != "null" ]] || continue
    [[ "$holder" == "_unknown" ]] && continue
    [[ -n "$active" && "$holder" == "$active" ]] && continue
    printf '%s\n' "$holder"
  done < <(_pr_holders)
}

# Read a per-PR field from the resolved scope so a same-numbered PR in another
# repo can never answer for this one.
state_pr_field() {
  local field="$1" scope out=""
  scope="$(resolve_pr_scope)"
  [[ -n "$scope" ]] || { printf '%s' ""; return 0; }
  out="$(cd "$STATE_READ_DIR" 2>/dev/null && "$STATE_HELPER" --raw-path --get \
    ".repos[\"$scope\"].prs[\"$PR_NUMBER\"].$field" 2>/dev/null || true)"
  [[ "$out" == "null" ]] && out=""
  printf '%s' "$out"
}

# repo_identity <path> — stable identity for the repo a checkout belongs to.
# Prefer normalized `origin` owner/repo so worktrees and clones compare equal.
# Fall back to the shared git common dir, then the raw path.
repo_identity() {
  local path="$1"
  [[ -n "$path" && -d "$path" ]] || { printf 'path:%s\n' "$path"; return 0; }
  local url id owner repo
  url="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$url" ]]; then
    id="${url%.git}"
    id="${id%/}"
    id="${id#*://}"
    id="${id#*@}"
    id="${id/:/\/}"
    if [[ "$id" == */* ]]; then
      repo="${id##*/}"
      id="${id%/*}"
      owner="${id##*/}"
      if [[ -n "$owner" && -n "$repo" ]]; then
        printf '%s\n' "$(normalize_repo_key "${owner}/${repo}")"
        return 0
      fi
    fi
  fi
  local common=""
  common="$(cd "$path" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null || true)"
  if [[ -n "$common" ]]; then
    common="$(cd "$path" && cd "$common" 2>/dev/null && pwd -P || true)"
  fi
  if [[ -n "$common" ]]; then
    printf 'gitdir:%s\n' "$common"
  else
    printf 'path:%s\n' "$path"
  fi
}

is_owner_repo_identity() {
  case "$1" in
    ""|_unknown|gitdir:*|path:*) return 1 ;;
    */*) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_root_repo() {
  local from_arg="$1"
  local from_state_pr=""
  local from_state_top=""
  if [[ -f "$STATE_FILE" ]]; then
    from_state_pr="$(state_pr_field root_repo)"
    from_state_top="$(cd "$STATE_READ_DIR" 2>/dev/null && "$STATE_HELPER" --get '.root_repo' 2>/dev/null || true)"
    [[ "$from_state_top" == "null" ]] && from_state_top=""
  fi
  local chosen=""
  local live=""
  live="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  # Explicit arg -> per-PR scoping -> live checkout -> scoped remembered root.
  # The remembered path stays last because removed worktrees make it stale.
  if [[ -n "$from_arg" ]]; then
    chosen="$from_arg"
  elif [[ -n "$from_state_pr" && "$from_state_pr" != "null" && -d "$from_state_pr" ]]; then
    chosen="$from_state_pr"
  elif [[ -n "$live" ]]; then
    chosen="$live"
  elif [[ -n "$from_state_top" && "$from_state_top" != "null" ]]; then
    chosen="$from_state_top"
  fi
  if [[ -z "$chosen" || ! -d "$chosen" ]]; then
    echo "polling-state-gate.sh: could not resolve root repo path (set --root-repo or .root_repo in session-state)" >&2
    return 1
  fi
  local canon
  canon="$(cd "$chosen" && git rev-parse --show-toplevel 2>/dev/null || echo "$chosen")"
  echo "$canon"
}

# validate_root_match <resolved_root> [quiet] — refuse only genuine cross-repo
# mismatches. The scope-level `.root_repo` is never authoritative; only per-PR
# owner_repo/root_repo fields participate in the decision. The optional `quiet`
# mode suppresses legacy notices and the scoped-but-incomparable refusal only
# for --ensure-session, which is about to refresh the recorded scoping.
validate_root_match() {
  local resolved="$1"
  local stored_owner=""
  local stored_root=""
  if [[ -f "$STATE_FILE" ]]; then
    stored_owner="$(state_pr_field owner_repo)"
    stored_root="$(state_pr_field root_repo)"
  fi
  if [[ "$stored_owner" == "null" ]]; then stored_owner=""; fi
  if [[ "$stored_root" == "null" ]]; then stored_root=""; fi

  local canon active_id
  canon="$(cd "$resolved" && git rev-parse --show-toplevel 2>/dev/null || echo "$resolved")"
  local checkout_id
  checkout_id="$(repo_identity "$canon")"

  # An explicitly declared repo key may supply an identity an origin-less
  # checkout lacks, but may never override a checkout that identifies itself.
  local declared=""
  if [[ "$REPO_KEY_DECLARED" -eq 1 && -n "$ACTIVE_REPO_KEY" && "$ACTIVE_REPO_KEY" == */* \
        && "$ACTIVE_REPO_KEY" != "_unknown" \
        && "$ACTIVE_REPO_KEY" != gitdir:* && "$ACTIVE_REPO_KEY" != path:* ]]; then
    if ! declared="$(normalize_repo_key "$ACTIVE_REPO_KEY")" || [[ -z "$declared" ]]; then
      echo "polling-state-gate.sh: could not normalize repo key '$ACTIVE_REPO_KEY' (from --repo or \$CLAUDE_SESSION_REPO) — refuse to validate against an unusable repo identity" >&2
      return 1
    fi
  fi
  if [[ -n "$declared" && "$checkout_id" == */* \
        && "$checkout_id" != gitdir:* && "$checkout_id" != path:* \
        && "$declared" != "$checkout_id" ]]; then
    echo "polling-state-gate.sh: repo key '$declared' (from --repo or \$CLAUDE_SESSION_REPO) contradicts the checkout being operated on, which is '$checkout_id' ($canon) — refuse to validate against one repo while acting on another. Drop the override, or point --root-repo at a '$declared' checkout." >&2
    return 1
  fi
  if [[ -n "$declared" ]]; then
    active_id="$declared"
  else
    active_id="$checkout_id"
  fi

  # Prefer owner/repo identity when both sides have one.
  if [[ -n "$stored_owner" && "$active_id" == */* && "$active_id" != gitdir:* && "$active_id" != path:* ]]; then
    local stored_owner_lc
    stored_owner_lc="$(normalize_repo_key "$stored_owner")"
    if [[ "$stored_owner_lc" != "$active_id" ]]; then
      echo "polling-state-gate.sh: PR #$PR_NUMBER is scoped to repo '$stored_owner' but the active checkout is '$active_id' ($canon) — refuse to poll from the wrong repo" >&2
      return 1
    fi
    return 0
  fi

  # Fall back to the per-PR checkout path, compared by repo identity so sibling
  # worktrees of the same clone agree. A stale path carries no signal.
  if [[ -n "$stored_root" && -d "$stored_root" ]]; then
    local stored_id
    stored_id="$(repo_identity "$stored_root")"
    if [[ "$stored_id" != "$active_id" ]]; then
      echo "polling-state-gate.sh: PR #$PR_NUMBER is scoped to repo '$stored_id' ($stored_root) but the active checkout is '$active_id' ($canon) — refuse to poll from the wrong repo" >&2
      return 1
    fi
    return 0
  fi

  # Scoping is recorded but cannot be compared. Fail closed except during
  # --ensure-session, which is about to refresh the recorded scoping.
  if [[ -n "$stored_owner" && "${2:-}" != "quiet" ]]; then
    echo "polling-state-gate.sh: PR #$PR_NUMBER is scoped to repo '$stored_owner' but the active checkout ($canon) has no comparable repo identity ('$active_id') — refuse to poll; re-run from a checkout with an 'origin' remote, or: polling-state-gate.sh $PR_NUMBER --ensure-session" >&2
    return 1
  fi

  # Legacy state without per-PR scoping remains a notice, not a refusal.
  if [[ "${2:-}" != "quiet" ]]; then
    echo "polling-state-gate.sh: no per-PR repo scoping recorded for PR #$PR_NUMBER — proceeding with the active checkout ($canon); run: polling-state-gate.sh $PR_NUMBER --ensure-session" >&2
  fi
  return 0
}
