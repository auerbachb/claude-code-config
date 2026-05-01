#!/usr/bin/env bash
# polling-state-gate.sh — Procedural gate for CodeRabbit polling (issue #315).
#
# Enforces before and during polling:
#   1) Handoff file exists at ~/.claude/handoffs/pr-{N}-handoff.json (parent agent
#      owns creation/refresh for the polling loop; Phase A/B subagents use the same
#      path for phase handoffs — see handoff-files.md).
#   2) PR is registered in ~/.claude/session-state.json with a correct root_repo
#      (top-level .root_repo and per-PR .prs["N"].root_repo when multiple repos).
#   3) Each poll cycle evaluates exit via .claude/scripts/merge-gate.sh (not inline
#      paraphrase of cr-merge-gate.md).
#
# Usage:
#   polling-state-gate.sh <pr_number> --ensure-session [--root-repo <path>]
#   polling-state-gate.sh <pr_number> [--root-repo <path>]
#   polling-state-gate.sh <pr_number> --verify-state [--root-repo <path>]
#
# Modes:
#   --ensure-session  Run once before the first poll tick: write/update session-state,
#                      create handoff if missing, set root_repo. Exits 0 on success.
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
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
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

resolve_root_repo() {
  local from_arg="$1"
  local from_state_pr=""
  local from_state_top=""
  if [[ -f "$STATE_FILE" ]]; then
    from_state_pr=$(jq -r --arg pr "$PR_NUMBER" '.prs[$pr].root_repo // empty' "$STATE_FILE" 2>/dev/null || true)
    from_state_top=$(jq -r '.root_repo // empty' "$STATE_FILE" 2>/dev/null || true)
  fi
  local chosen=""
  if [[ -n "$from_arg" ]]; then
    chosen="$from_arg"
  elif [[ -n "$from_state_pr" && "$from_state_pr" != "null" ]]; then
    chosen="$from_state_pr"
  elif [[ -n "$from_state_top" && "$from_state_top" != "null" ]]; then
    chosen="$from_state_top"
  else
    chosen="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  if [[ -z "$chosen" || ! -d "$chosen" ]]; then
    echo "polling-state-gate.sh: could not resolve root repo path (set --root-repo or .root_repo in session-state)" >&2
    return 1
  fi
  local canon
  canon="$(cd "$chosen" && git rev-parse --show-toplevel 2>/dev/null || echo "$chosen")"
  echo "$canon"
}

validate_root_match() {
  local resolved="$1"
  local from_state_pr=""
  local from_state_top=""
  if [[ -f "$STATE_FILE" ]]; then
    from_state_pr=$(jq -r --arg pr "$PR_NUMBER" '.prs[$pr].root_repo // empty' "$STATE_FILE" 2>/dev/null || true)
    from_state_top=$(jq -r '.root_repo // empty' "$STATE_FILE" 2>/dev/null || true)
  fi
  local canon
  canon=$(cd "$resolved" && git rev-parse --show-toplevel 2>/dev/null || echo "$resolved")
  if [[ -n "$from_state_pr" && "$from_state_pr" != "null" && "$from_state_pr" != "" ]]; then
    local canon_pr
    canon_pr=$(cd "$from_state_pr" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "$from_state_pr")
    if [[ "$canon_pr" != "$canon" ]]; then
      echo "polling-state-gate.sh: session-state .prs[\"$PR_NUMBER\"].root_repo ($from_state_pr) does not match active root ($canon) — multi-repo hazard" >&2
      return 1
    fi
  fi
  if [[ -n "$from_state_top" && "$from_state_top" != "null" && "$from_state_top" != "" ]]; then
    local canon_top
    canon_top=$(cd "$from_state_top" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "$from_state_top")
    if [[ "$canon_top" != "$canon" ]]; then
      echo "polling-state-gate.sh: session-state .root_repo ($from_state_top) does not match active root ($canon) — refuse to poll from wrong checkout" >&2
      return 1
    fi
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
  if ! validate_root_match "$resolved"; then
    exit 4
  fi
  local canon
  canon="$(cd "$resolved" && git rev-parse --show-toplevel)"
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
  local reviewer="cr"
  if [[ -f "$STATE_FILE" ]]; then
    local r
    r="$(jq -r --arg pr "$PR_NUMBER" '.prs[$pr].reviewer // "cr"' "$STATE_FILE" 2>/dev/null || echo cr)"
    reviewer="$r"
  fi

  # Single atomic write — session-state.sh merges multiple --set in one transaction.
  if [[ -n "$owner_repo" ]]; then
    "$STATE_HELPER" \
      --set ".root_repo=\"$canon\"" \
      --set ".prs[\"$PR_NUMBER\"].root_repo=\"$canon\"" \
      --set ".prs[\"$PR_NUMBER\"].head_sha=\"$head_sha\"" \
      --set ".prs[\"$PR_NUMBER\"].owner_repo=\"$owner_repo\""
  else
    "$STATE_HELPER" \
      --set ".root_repo=\"$canon\"" \
      --set ".prs[\"$PR_NUMBER\"].root_repo=\"$canon\"" \
      --set ".prs[\"$PR_NUMBER\"].head_sha=\"$head_sha\""
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
  local handoff_path="${HANDOFF_DIR}/pr-${PR_NUMBER}-handoff.json"
  if [[ ! -f "$handoff_path" ]]; then
    echo "polling-state-gate.sh: missing handoff $handoff_path — run: polling-state-gate.sh $PR_NUMBER --ensure-session" >&2
    exit 4
  fi
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "polling-state-gate.sh: missing $STATE_FILE — run --ensure-session first" >&2
    exit 4
  fi
  if ! jq -e --arg pr "$PR_NUMBER" '.prs[$pr] != null' "$STATE_FILE" >/dev/null 2>&1; then
    echo "polling-state-gate.sh: PR $PR_NUMBER not registered in session-state — run --ensure-session first" >&2
    exit 4
  fi
  local top rr state_sha handoff_sha handoff_pr canon live_head
  top=$(jq -r '.root_repo // empty' "$STATE_FILE")
  rr=$(jq -r --arg pr "$PR_NUMBER" '.prs[$pr].root_repo // empty' "$STATE_FILE")
  state_sha=$(jq -r --arg pr "$PR_NUMBER" '.prs[$pr].head_sha // empty' "$STATE_FILE")
  handoff_sha=$(jq -r '.head_sha // empty' "$handoff_path")
  handoff_pr=$(jq -r 'if .pr_number == null then "" else (.pr_number | tostring) end' "$handoff_path")
  if [[ -z "$top" || "$top" == "null" ]]; then
    echo "polling-state-gate.sh: session-state missing top-level .root_repo" >&2
    exit 4
  fi
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
