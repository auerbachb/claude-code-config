#!/usr/bin/env bash
# polling-state-gate.sh — Procedural gate for CodeRabbit polling (issue #315).
#
# Enforces before and during polling:
#   1) Handoff file exists at ~/.claude/handoffs/pr-{N}-handoff.json (parent agent
#      owns creation/refresh for the polling loop; Phase A/B subagents use the same
#      path for phase handoffs — see handoff-files.md).
#   2) PR is registered in ~/.claude/session-state.json and scoped to this repo via
#      per-PR owner_repo / root_repo (issue #647), read from this repo's own
#      scope in session-state (`.repos["<owner>/<name>"].prs["N"]`, issue #638).
#   3) Each poll cycle evaluates exit via .claude/scripts/merge-gate.sh (not inline
#      paraphrase of cr-merge-gate.md).
#
# Repo scoping (issue #647): ~/.claude/session-state.json is shared by every
# concurrent session, so the single global .root_repo is owned by whichever session
# wrote last and is NEVER a refusal signal. Scoping is validated per PR, by repo
# *identity* (normalized `origin` remote, falling back to the shared git common dir
# so sibling worktrees of one repo agree) rather than by checkout path:
#   a) .prs["N"].owner_repo present -> must equal the active checkout's identity
#   b) else .prs["N"].root_repo present -> its identity must equal the active one
#   c) scoping recorded but not comparable (no `origin`, stale path) -> refuse
#   d) else (state from an older version) -> notice on stderr, then pass
# A genuine cross-repo mismatch is still refused, naming the PR and both repos.
#
# Usage:
#   polling-state-gate.sh <pr_number> --ensure-session [--root-repo <path>]
#   polling-state-gate.sh <pr_number> [--root-repo <path>]
#   polling-state-gate.sh <pr_number> --verify-state [--root-repo <path>]
#
# Modes:
#   --ensure-session  Run once before the first poll tick: write/update session-state,
#                      create handoff if missing, record per-PR repo scoping
#                      (owner_repo + root_repo). Exits 0 on success.
#                      Does not require the merge gate to be met.
#   --verify-state     Offline recovery check: confirm handoff + session-state and
#                      root_repo consistency (no gh, no merge-gate). Exit 0 if OK.
#   (default)         Validate handoff + session-state, cd to resolved root_repo, run
#                      merge-gate.sh. Exit 0 iff merge gate is met (same as merge-gate).
#
# Exit codes (default mode): same as merge-gate.sh (0 met, 1 not met, 2 usage, 3 PR, 4 error)
# --ensure-session: 0 success, 2 usage, 4 state/gh failure
# --verify-state: 0 valid, 2 usage, 4 invalid/missing
#
set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_HELPER="${SCRIPT_DIR}/session-state.sh"
MERGE_GATE="${SCRIPT_DIR}/merge-gate.sh"
STATE_FILE="${HOME}/.claude/session-state.json"
HANDOFF_DIR="${HOME}/.claude/handoffs"

PR_NUMBER=""
MODE="cycle"
ROOT_REPO_ARG=""

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --ensure-session)
      MODE="ensure"
      shift
      ;;
    --verify-state)
      MODE="verify"
      shift
      ;;
    --root-repo)
      ROOT_REPO_ARG="${2:-}"
      if [[ -z "$ROOT_REPO_ARG" ]]; then
        echo "polling-state-gate.sh: --root-repo requires a path" >&2
        exit 2
      fi
      # An explicit repo also decides which repo's scope we read (issue #638).
      [[ -d "$ROOT_REPO_ARG" ]] && STATE_READ_DIR="$ROOT_REPO_ARG"
      shift 2
      ;;
    -*)
      echo "polling-state-gate.sh: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$PR_NUMBER" ]]; then
        echo "polling-state-gate.sh: unexpected argument: $1" >&2
        exit 2
      fi
      PR_NUMBER="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUMBER" ]] || ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "polling-state-gate.sh: positive integer <pr_number> is required" >&2
  exit 2
fi

# Directory whose repo identity scopes every session-state read below (issue
# #638). Defaults to the active checkout; --root-repo overrides it.
STATE_READ_DIR="${STATE_READ_DIR:-$PWD}"

# Which repo scope holds this PR (issue #638). Resolved once, then reused by
# state_pr_field() so every read below comes from one consistent entry.
#
# Preference order, and why:
#   1. this repo's own scope — the normal case
#   2. the reserved "_unknown" scope — legacy state that predates scoping and
#      could not be attributed. Reading it here is what preserves #647's
#      "state from an older version -> notice, then pass" behavior: those
#      entries still reach validate_root_match() and are judged on their own
#      recorded owner_repo/root_repo exactly as before.
#   3. some other named repo's scope — a genuine cross-repo poll, refused by
#      the caller (never read, so another repo's PR #84 can't answer for ours)
# Empty output means the PR is registered nowhere.
# Identity of the checkout the caller is ACTUALLY standing in, captured before
# resolve_root_repo() can redirect to a recorded path. Without this anchor the
# cross-repo check compares the redirected root against itself and always
# agrees — a poll from repo C for a PR scoped to repo A would silently operate
# on repo A's checkout instead of being refused.
ACTIVE_REPO_KEY=""
PR_SCOPE=""
PR_SCOPE_RESOLVED=0
resolve_pr_scope() {
  if [[ "$PR_SCOPE_RESOLVED" -eq 1 ]]; then
    printf '%s' "$PR_SCOPE"
    return 0
  fi
  PR_SCOPE_RESOLVED=1
  PR_SCOPE=""
  [[ -f "$STATE_FILE" ]] || { printf '%s' ""; return 0; }
  local active="$ACTIVE_REPO_KEY"
  if [[ -z "$active" ]]; then
    active="$(cd "$STATE_READ_DIR" 2>/dev/null && "$STATE_HELPER" --repo-key 2>/dev/null || true)"
  fi
  # `--raw-path` addresses the document root, so this sees every scope at once
  # (the helper still migrates a legacy flat file in memory first).
  PR_SCOPE="$(cd "$STATE_READ_DIR" 2>/dev/null && "$STATE_HELPER" --raw-path --get \
    "[(.repos // {}) | to_entries[] | select(.value.prs[\"$PR_NUMBER\"] != null) | .key] as \$holders
     | ((\$holders | map(select(. == \"$active\")) | first)
        // (\$holders | map(select(. == \"_unknown\")) | first)
        // (\$holders | first) // \"\")" 2>/dev/null || true)"
  [[ "$PR_SCOPE" == "null" ]] && PR_SCOPE=""
  printf '%s' "$PR_SCOPE"
}

# Read a per-PR field from the scope resolved above, so a same-numbered PR in
# another repo can never answer for this one.
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
# Prefers the normalized `origin` remote ("owner/repo", lowercased) so any worktree
# or clone of the same repo compares equal. Falls back to the absolute git common
# dir ("gitdir:<path>", shared by all worktrees of one clone), then to the raw path
# ("path:<path>") when the argument is not a git checkout at all.
repo_identity() {
  local path="$1"
  [[ -n "$path" && -d "$path" ]] || { printf 'path:%s\n' "$path"; return 0; }
  local url id owner repo
  url="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$url" ]]; then
    id="${url%.git}"
    id="${id%/}"
    id="${id#*://}"   # drop scheme (https://, ssh://, git://)
    id="${id#*@}"     # drop user@ (git@github.com:owner/repo)
    id="${id/:/\/}"   # scp-style host:owner/repo -> host/owner/repo
    # Last two segments are owner/repo; a URL with no separator carries no identity.
    if [[ "$id" == */* ]]; then
      repo="${id##*/}"
      id="${id%/*}"
      owner="${id##*/}"
      if [[ -n "$owner" && -n "$repo" ]]; then
        printf '%s/%s\n' "$owner" "$repo" | tr '[:upper:]' '[:lower:]'
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

ACTIVE_REPO_KEY="$(cd "$STATE_READ_DIR" 2>/dev/null && "$STATE_HELPER" --repo-key 2>/dev/null || true)"

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
  # Precedence: explicit arg -> per-PR scoping -> live checkout -> global .root_repo.
  # The global field is shared across concurrent sessions (issue #647), so it must
  # never outrank the checkout the caller is actually standing in.
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

# validate_root_match <resolved_root> — refuse only on a genuine cross-repo mismatch.
# Compares repo identity against PER-PR scoping; the shared global .root_repo is
# never consulted here (issue #647).
validate_root_match() {
  local resolved="$1"
  # Cross-repo short-circuit (issue #638): the PR is registered, but under
  # ANOTHER named repo's scope. That is the collision this scoping exists to
  # catch, and it is decided before any per-PR field is read — reading the
  # other repo's entry is exactly the bug. "_unknown" is not a named repo:
  # those entries are unattributed legacy state and fall through to the
  # recorded-scoping rules below, preserving #647's behavior for them.
  local pr_scope active_id_pre
  pr_scope="$(resolve_pr_scope)"
  active_id_pre="$ACTIVE_REPO_KEY"
  if [[ -n "$pr_scope" && "$pr_scope" != "_unknown" && -n "$active_id_pre" \
        && "$active_id_pre" != gitdir:* && "$active_id_pre" != path:* \
        && "$pr_scope" != "_unknown" && "$pr_scope" != "$active_id_pre" ]]; then
    echo "polling-state-gate.sh: PR #$PR_NUMBER is scoped to repo '$pr_scope' but the active checkout is '$active_id_pre' — refuse to poll from the wrong repo" >&2
    return 1
  fi
  local stored_owner=""
  local stored_root=""
  if [[ -f "$STATE_FILE" ]]; then
    stored_owner="$(state_pr_field owner_repo)"
    stored_root="$(state_pr_field root_repo)"
  fi
  if [[ "$stored_owner" == "null" ]]; then stored_owner=""; fi
  if [[ "$stored_root" == "null" ]]; then stored_root=""; fi

  local canon active_id
  canon=$(cd "$resolved" && git rev-parse --show-toplevel 2>/dev/null || echo "$resolved")
  active_id="$(repo_identity "$canon")"

  # (a) owner/repo scoping — usable only when the active checkout also resolves to
  #     an owner/repo identity (i.e. it has an `origin` remote to compare against).
  if [[ -n "$stored_owner" && "$active_id" == */* && "$active_id" != gitdir:* && "$active_id" != path:* ]]; then
    local stored_owner_lc
    stored_owner_lc="$(printf '%s' "$stored_owner" | tr '[:upper:]' '[:lower:]')"
    if [[ "$stored_owner_lc" != "$active_id" ]]; then
      echo "polling-state-gate.sh: PR #$PR_NUMBER is scoped to repo '$stored_owner' but the active checkout is '$active_id' ($canon) — refuse to poll from the wrong repo" >&2
      return 1
    fi
    return 0
  fi

  # (b) fall back to per-PR checkout path, compared by identity so sibling worktrees
  #     of the same repo agree. A stale/absent path carries no signal.
  if [[ -n "$stored_root" && -d "$stored_root" ]]; then
    local stored_id
    stored_id="$(repo_identity "$stored_root")"
    if [[ "$stored_id" != "$active_id" ]]; then
      echo "polling-state-gate.sh: PR #$PR_NUMBER is scoped to repo '$stored_id' ($stored_root) but the active checkout is '$active_id' ($canon) — refuse to poll from the wrong repo" >&2
      return 1
    fi
    return 0
  fi

  # (c) scoping IS recorded but nothing above could compare it — the active checkout
  #     has no usable `origin` identity and the recorded path is stale/absent. Fail
  #     closed: this is not legacy state, so silently proceeding would validate
  #     nothing. (--ensure-session is exempt; it is about to (re)record the scoping.)
  if [[ -n "$stored_owner" && "${2:-}" != "quiet" ]]; then
    echo "polling-state-gate.sh: PR #$PR_NUMBER is scoped to repo '$stored_owner' but the active checkout ($canon) has no comparable repo identity ('$active_id') — refuse to poll; re-run from a checkout with an 'origin' remote, or: polling-state-gate.sh $PR_NUMBER --ensure-session" >&2
    return 1
  fi

  # (d) state written before per-PR scoping existed: degrade gracefully, never refuse
  #     on the shared global .root_repo.
  if [[ "${2:-}" != "quiet" ]]; then
    echo "polling-state-gate.sh: no per-PR repo scoping recorded for PR #$PR_NUMBER — proceeding with the active checkout ($canon); run: polling-state-gate.sh $PR_NUMBER --ensure-session" >&2
  fi
  return 0
}

write_checkpoint_handoff() {
  local head_sha="$1"
  local reviewer="${2:-cr}"
  local handoff_path="${HANDOFF_DIR}/pr-${PR_NUMBER}-handoff.json"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$HANDOFF_DIR"
  # Atomic write: temp in same directory as handoff (same filesystem for mv)
  local tmp
  tmp="$(mktemp "${HANDOFF_DIR}/.pr-${PR_NUMBER}-handoff-new.XXXXXX")"
  # Minimal valid handoff: parent polling checkpoint (schema handoff-file-schema.json)
  if ! jq -n \
    --argjson pr "$PR_NUMBER" \
    --arg sha "$head_sha" \
    --arg rev "$reviewer" \
    --arg now "$now" \
    '{
      schema_version: "1.0",
      pr_number: $pr,
      head_sha: $sha,
      reviewer: $rev,
      phase_completed: "B",
      created_at: $now,
      findings_fixed: [],
      findings_dismissed: [],
      threads_replied: [],
      threads_resolved: [],
      files_changed: [],
      push_timestamp: $now,
      notes: "Polling checkpoint — written by polling-state-gate.sh --ensure-session; Phase A/B handoffs supersede when present from subagents."
    }' > "$tmp"; then
    rm -f "$tmp"
    echo "polling-state-gate.sh: failed to write handoff JSON: $handoff_path" >&2
    exit 4
  fi
  if ! mv "$tmp" "$handoff_path"; then
    rm -f "$tmp"
    echo "polling-state-gate.sh: could not write handoff: $handoff_path" >&2
    exit 4
  fi
}

ensure_session() {
  local resolved=""
  # Prefer live checkout root unless --root-repo is explicit (avoids stale session-state roots).
  if [[ -n "$ROOT_REPO_ARG" ]]; then
    if ! resolved="$(resolve_root_repo "$ROOT_REPO_ARG")"; then
      exit 4
    fi
  else
    resolved="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "$resolved" ]]; then
      if ! resolved="$(resolve_root_repo "")"; then
        exit 4
      fi
    else
      resolved="$(cd "$resolved" && git rev-parse --show-toplevel)"
    fi
  fi
  if [[ -z "$resolved" || ! -d "$resolved" ]]; then
    echo "polling-state-gate.sh: could not resolve root for --ensure-session" >&2
    exit 4
  fi
  if ! validate_root_match "$resolved" quiet; then
    exit 4
  fi
  local canon
  canon="$(cd "$resolved" && git rev-parse --show-toplevel)"
  # Everything from here reads and writes THIS repo's scope.
  STATE_READ_DIR="$canon"
  local pr_json head_sha owner_repo
  if ! pr_json="$(cd "$canon" && gh pr view "$PR_NUMBER" --json headRefOid,state 2>/dev/null)"; then
    echo "polling-state-gate.sh: gh pr view failed for PR #$PR_NUMBER in $canon" >&2
    exit 4
  fi
  head_sha="$(echo "$pr_json" | jq -r '.headRefOid // empty')"
  local state
  state="$(echo "$pr_json" | jq -r '.state // ""')"
  if [[ "$state" != "OPEN" ]]; then
    echo "polling-state-gate.sh: PR #$PR_NUMBER is not OPEN" >&2
    exit 4
  fi
  if [[ -z "$head_sha" ]]; then
    echo "polling-state-gate.sh: could not read head SHA" >&2
    exit 4
  fi

  owner_repo="$(cd "$canon" && gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
  if [[ -z "$owner_repo" ]]; then
    # gh unavailable/unauthenticated: derive the same owner/repo identity from the
    # `origin` remote so later ticks still have per-PR scoping to validate against.
    local derived
    derived="$(repo_identity "$canon")"
    if [[ "$derived" == */* && "$derived" != gitdir:* && "$derived" != path:* ]]; then
      owner_repo="$derived"
    fi
  fi
  local reviewer="cr"
  if [[ -f "$STATE_FILE" ]]; then
    local r
    r="$(state_pr_field reviewer)"
    [[ -n "$r" ]] && reviewer="$r"
  fi

  # Single atomic write — session-state.sh merges multiple --set in one
  # transaction. Running it from $canon scopes every path to THIS repo
  # (issue #638), so PR #84 here cannot overwrite PR #84 elsewhere.
  # owner_repo stays recorded: it is both #647's scoping signal and the
  # migration key for state written before scoping existed.
  if [[ -n "$owner_repo" ]]; then
    ( cd "$canon" && "$STATE_HELPER" \
        --set ".root_repo=\"$canon\"" \
        --set ".prs[\"$PR_NUMBER\"].root_repo=\"$canon\"" \
        --set ".prs[\"$PR_NUMBER\"].head_sha=\"$head_sha\"" \
        --set ".prs[\"$PR_NUMBER\"].owner_repo=\"$owner_repo\"" )
  else
    ( cd "$canon" && "$STATE_HELPER" \
        --set ".root_repo=\"$canon\"" \
        --set ".prs[\"$PR_NUMBER\"].root_repo=\"$canon\"" \
        --set ".prs[\"$PR_NUMBER\"].head_sha=\"$head_sha\"" )
  fi

  local handoff_path="${HANDOFF_DIR}/pr-${PR_NUMBER}-handoff.json"
  if [[ ! -f "$handoff_path" ]]; then
    write_checkpoint_handoff "$head_sha" "$reviewer"
  else
    # Refresh head_sha only — preserve phase_completed, reviewer, and other Phase A/B fields.
    local tmp
    tmp="$(mktemp "${HANDOFF_DIR}/.pr-${PR_NUMBER}-handoff-refresh.XXXXXX")"
    if ! jq --arg sha "$head_sha" '.head_sha = $sha' "$handoff_path" > "$tmp"; then
      rm -f "$tmp"
      echo "polling-state-gate.sh: failed to refresh handoff JSON: $handoff_path" >&2
      exit 4
    fi
    if ! mv "$tmp" "$handoff_path"; then
      rm -f "$tmp"
      echo "polling-state-gate.sh: could not write handoff: $handoff_path" >&2
      exit 4
    fi
  fi

  exit 0
}

require_handoff_and_state() {
  local resolved="$1"
  local gate_mode="${2:-live}"
  # Pin every scoped read below to the repo we actually resolved to (#638).
  [[ -d "$resolved" ]] && STATE_READ_DIR="$resolved"
  local handoff_path="${HANDOFF_DIR}/pr-${PR_NUMBER}-handoff.json"
  if [[ ! -f "$handoff_path" ]]; then
    echo "polling-state-gate.sh: missing handoff $handoff_path — run: polling-state-gate.sh $PR_NUMBER --ensure-session" >&2
    exit 4
  fi
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "polling-state-gate.sh: missing $STATE_FILE — run --ensure-session first" >&2
    exit 4
  fi
  if [[ -z "$(state_pr_field head_sha)$(state_pr_field root_repo)$(state_pr_field reviewer)" ]]; then
    echo "polling-state-gate.sh: PR $PR_NUMBER not registered in session-state for $(cd "$STATE_READ_DIR" 2>/dev/null && "$STATE_HELPER" --repo-key 2>/dev/null || echo "this repo") — run --ensure-session first" >&2
    exit 4
  fi
  local rr state_sha handoff_sha handoff_pr canon live_head
  rr="$(state_pr_field root_repo)"
  state_sha="$(state_pr_field head_sha)"
  handoff_sha=$(jq -r '.head_sha // empty' "$handoff_path")
  handoff_pr=$(jq -r 'if .pr_number == null then "" else (.pr_number | tostring) end' "$handoff_path")
  # The global .root_repo is deliberately NOT required or validated here (issue #647):
  # it is shared across concurrent sessions, so it says nothing about this PR.
  if [[ -z "$rr" || "$rr" == "null" ]]; then
    echo "polling-state-gate.sh: session-state missing .prs[\"$PR_NUMBER\"].root_repo" >&2
    exit 4
  fi
  if [[ -z "$state_sha" || "$state_sha" == "null" ]]; then
    echo "polling-state-gate.sh: session-state missing .prs[\"$PR_NUMBER\"].head_sha" >&2
    exit 4
  fi
  if [[ -z "$handoff_sha" || "$handoff_sha" == "null" ]]; then
    echo "polling-state-gate.sh: handoff missing .head_sha ($handoff_path)" >&2
    exit 4
  fi
  if [[ -z "$handoff_pr" || "$handoff_pr" == "null" ]]; then
    echo "polling-state-gate.sh: handoff missing .pr_number ($handoff_path)" >&2
    exit 4
  fi
  if [[ "$handoff_pr" != "$PR_NUMBER" ]]; then
    echo "polling-state-gate.sh: handoff .pr_number ($handoff_pr) does not match PR $PR_NUMBER ($handoff_path)" >&2
    exit 4
  fi
  if [[ "$state_sha" != "$handoff_sha" ]]; then
    echo "polling-state-gate.sh: head_sha mismatch between session-state and handoff — run polling-state-gate.sh $PR_NUMBER --ensure-session" >&2
    exit 4
  fi
  canon="$(cd "$resolved" && git rev-parse --show-toplevel)"
  if [[ "$gate_mode" == "live" ]]; then
    if ! live_head="$(cd "$canon" && gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid' 2>/dev/null)"; then
      echo "polling-state-gate.sh: gh pr view failed (cannot verify live HEAD for PR #$PR_NUMBER)" >&2
      exit 4
    fi
    if [[ -z "$live_head" || "$live_head" == "null" ]]; then
      echo "polling-state-gate.sh: could not read live HEAD for PR #$PR_NUMBER" >&2
      exit 4
    fi
    if [[ "$state_sha" != "$live_head" ]]; then
      echo "polling-state-gate.sh: stored head_sha does not match GitHub HEAD — run polling-state-gate.sh $PR_NUMBER --ensure-session" >&2
      exit 4
    fi
  fi
  if ! validate_root_match "$resolved"; then
    exit 4
  fi
}

if [[ "$MODE" == "ensure" ]]; then
  ensure_session
fi

if [[ "$MODE" == "verify" ]]; then
  resolved=""
  if ! resolved="$(resolve_root_repo "$ROOT_REPO_ARG")"; then
    exit 4
  fi
  require_handoff_and_state "$resolved" verify
  exit 0
fi

# --- default: poll cycle -> merge gate ---
resolved=""
if ! resolved="$(resolve_root_repo "$ROOT_REPO_ARG")"; then
  exit 4
fi
require_handoff_and_state "$resolved" live
canon="$(cd "$resolved" && git rev-parse --show-toplevel)"
(cd "$canon" && exec "$MERGE_GATE" "$PR_NUMBER")
