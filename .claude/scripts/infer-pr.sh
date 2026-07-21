#!/usr/bin/env bash
# infer-pr.sh — Shared PR inference helper for /wrap and /fixpr (issues #448, #447).
#
# PURPOSE
#   Two related jobs behind one contract so /wrap and /fixpr stay in sync:
#
#     1. --explicit <ref>  Normalize an explicitly provided PR reference
#                          (URL, owner/repo#N, #N, or bare N) into a
#                          structured {number, owner_repo} record. This lets a
#                          skill accept `/wrap <URL>` / `/fixpr <N>` and route
#                          it through the same output shape as inferred PRs.
#
#     2. (no --explicit)   Infer candidate PR(s) from session-state when the
#                          current branch has no PR. Reads the per-PR map from
#                          ~/.claude/session-state.json (via session-state.sh
#                          --get when available, else a direct read), optionally
#                          filters to a single repo with --root-repo, and sorts
#                          by last activity (`last_cron_action.at`) so the most
#                          recently touched PR sorts first.
#
#   The skill layer (wrap/SKILL.md) owns the merge-safety judgment — thread
#   scanning, the "most-recent-unambiguous within N minutes" rule, and the
#   [INFERRED] log line. This script only supplies normalized, recency-ranked
#   candidates plus an exit code that says how ambiguous the session-state
#   signal is.
#
# USAGE
#   infer-pr.sh --explicit <URL_or_N>
#   infer-pr.sh [--root-repo <path>]
#   infer-pr.sh --help | -h
#
# OUTPUT (stdout, single JSON object)
#   {
#     "candidates": [ {"number": 618, "owner_repo": "org/repo", "last_activity": "2026-..."} ],
#     "most_recent": {"number": 618, "owner_repo": "org/repo", "last_activity": "2026-..."},
#     "source": "explicit" | "session-state"
#   }
#   `owner_repo` is null when unknown; `last_activity` is null for explicit refs
#   and for session-state entries without a `last_cron_action.at` timestamp.
#   `most_recent` is null only when there are no candidates.
#
# EXIT CODES
#   0  Exactly one candidate (unambiguous) — or a valid --explicit ref.
#   1  Multiple candidates (output lists all, most_recent = newest by activity).
#   2  No candidates found (session-state empty / no match for --root-repo).
#   3  --explicit ref could not be parsed/validated.
#   4  Internal error (jq failure, unreadable state file that exists but is
#      not valid JSON, etc.).
#   2 (usage) is intentionally NOT used so callers can rely on 0/1/2/3 having
#   the candidate-cardinality meaning above; a usage error prints help and
#   exits 64 instead.
#
# DEPENDENCIES
#   - jq
#   - session-state.sh (optional — falls back to a direct read of
#     ~/.claude/session-state.json when the helper is not on any known path)
#
# EXAMPLES
#   infer-pr.sh --explicit https://github.com/auerbachb/skingod/pull/462
#   infer-pr.sh --root-repo "$(git rev-parse --show-toplevel)"
#   CANDS=$(infer-pr.sh --root-repo "$ROOT"); RC=$?

set -uo pipefail
# Best-effort usage log. The braces ensure a failed redirect target (e.g. a
# missing ~/.claude dir) is swallowed too, not just printf's own stderr.
{ printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "$HOME/.claude/script-usage.log"; } 2>/dev/null || true

STATE_FILE="${HOME}/.claude/session-state.json"

# Distinct from the candidate-cardinality exit codes (0/1/2/3) so a malformed
# invocation can never be mistaken for "no candidates" or a bad explicit ref.
EXIT_USAGE=64

print_usage() {
  cat <<'EOF'
Usage: infer-pr.sh --explicit <URL_or_N>
       infer-pr.sh [--root-repo <path>]
       infer-pr.sh --help | -h

Normalize an explicit PR reference, or infer candidate PR(s) from
~/.claude/session-state.json (most recently active first).

Flags:
  --explicit <ref>   Normalize a PR reference. Accepts:
                       https://github.com/owner/repo/pull/N (with optional
                       trailing /files, #anchor, ?query, or slash),
                       github.com/owner/repo/pull/N, owner/repo#N, #N, or N.
  --root-repo <path> Filter session-state candidates to PRs recorded against
                     this repo path (entries without a recorded root_repo are
                     kept, since their repo is simply unknown).

Output: a single JSON object on stdout (see header for shape).

Exit codes:
  0  exactly one candidate (or a valid --explicit ref)
  1  multiple candidates (most_recent = newest by last activity)
  2  no candidates found
  3  --explicit ref could not be parsed
  4  internal error (jq / unreadable JSON state file)
  64 usage error
EOF
}

# --- arg parsing ---
EXPLICIT=""
HAVE_EXPLICIT=0
ROOT_REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    --explicit)
      if [[ $# -lt 2 ]]; then
        echo "Error: --explicit requires a value" >&2
        print_usage >&2
        exit "$EXIT_USAGE"
      fi
      EXPLICIT="$2"
      HAVE_EXPLICIT=1
      shift 2
      ;;
    --root-repo)
      if [[ $# -lt 2 ]]; then
        echo "Error: --root-repo requires a value" >&2
        print_usage >&2
        exit "$EXIT_USAGE"
      fi
      ROOT_REPO="$2"
      shift 2
      ;;
    -*)
      echo "Error: unknown flag: $1" >&2
      print_usage >&2
      exit "$EXIT_USAGE"
      ;;
    *)
      echo "Error: unexpected positional argument: $1" >&2
      print_usage >&2
      exit "$EXIT_USAGE"
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: 'jq' not found on PATH" >&2
  exit 4
fi

# --------------------------------------------------------------------------
# Mode 1: --explicit — parse + normalize a single PR reference.
# --------------------------------------------------------------------------
if [[ "$HAVE_EXPLICIT" -eq 1 ]]; then
  ref="$EXPLICIT"
  # Trim surrounding whitespace.
  ref="${ref#"${ref%%[![:space:]]*}"}"
  ref="${ref%"${ref##*[![:space:]]}"}"

  num=""
  owner_repo=""

  if [[ "$ref" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    owner_repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    num="${BASH_REMATCH[3]}"
  elif [[ "$ref" =~ ^([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)#([0-9]+)$ ]]; then
    owner_repo="${BASH_REMATCH[1]}"
    num="${BASH_REMATCH[2]}"
  elif [[ "$ref" =~ ^#?([0-9]+)$ ]]; then
    num="${BASH_REMATCH[1]}"
  else
    echo "Error: could not parse PR reference: '$EXPLICIT'" >&2
    exit 3
  fi

  # Reject a leading-zero / zero PR number — GitHub PRs are positive integers.
  if ! [[ "$num" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: invalid PR number in reference: '$EXPLICIT'" >&2
    exit 3
  fi

  if ! OUT=$(jq -cn \
      --argjson number "$num" \
      --arg owner_repo "$owner_repo" \
      '{number: $number,
        owner_repo: (if $owner_repo == "" then null else $owner_repo end),
        last_activity: null} as $c
       | {candidates: [$c], most_recent: $c, source: "explicit"}'); then
    echo "Error: failed to build explicit output JSON" >&2
    exit 4
  fi
  printf '%s\n' "$OUT"
  exit 0
fi

# --------------------------------------------------------------------------
# Mode 2: infer from session-state.
# --------------------------------------------------------------------------

# Read the .prs map. A missing state file simply means "no candidates" — check
# that first so we never depend on a helper's exact missing-file exit code.
# When the file exists, prefer session-state.sh --get for consistency with the
# rest of the toolchain; fall back to a direct jq read on any helper failure.
PRS_JSON=""
if [[ ! -f "$STATE_FILE" ]]; then
  PRS_JSON="{}"
else
  SESSION_STATE_SH=""
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for candidate in \
    "$HOME/.claude/skills-worktree/.claude/scripts/session-state.sh" \
    "$HOME/.claude/scripts/session-state.sh" \
    "$SELF_DIR/session-state.sh" \
    ".claude/scripts/session-state.sh"; do
    if [[ -x "$candidate" ]]; then
      SESSION_STATE_SH="$candidate"
      break
    fi
  done

  if [[ -n "$SESSION_STATE_SH" ]] && PRS_JSON=$("$SESSION_STATE_SH" --get '.prs // {}' 2>/dev/null); then
    :
  elif ! PRS_JSON=$(jq -c '.prs // {}' "$STATE_FILE" 2>/dev/null); then
    echo "Error: could not parse $STATE_FILE as JSON" >&2
    exit 4
  fi
fi

# session-state.sh --get prints the literal "null" string when the path is
# absent on a valid object; normalize that to an empty map.
if [[ -z "$PRS_JSON" || "$PRS_JSON" == "null" ]]; then
  PRS_JSON="{}"
fi

# Defense in depth (issue #640): session-state.sh's per-PR field-type guard
# rejects new writes that would leave `last_cron_action` as anything but an
# object, but state files written before that guard existed can still carry
# a malformed value (the exact corruption found in PRs #542/#544 — a bare
# string where every consumer expects `{type, at, interval}`). Warn and
# degrade rather than let the jq pipeline below hard-error when it indexes
# `.last_cron_action.at`.
MALFORMED_CRON_ACTION_KEYS="$(jq -r '
  to_entries[]
  | select(.value.last_cron_action != null and (.value.last_cron_action | type) != "object")
  | .key
' <<<"$PRS_JSON" 2>/dev/null || true)"
if [[ -n "$MALFORMED_CRON_ACTION_KEYS" ]]; then
  while IFS= read -r bad_pr_key; do
    [[ -z "$bad_pr_key" ]] && continue
    echo "infer-pr.sh: warning: PR #$bad_pr_key has a malformed last_cron_action (not an object) — ranking it as if last activity were unset (see issue #640)" >&2
  done <<<"$MALFORMED_CRON_ACTION_KEYS"
fi

# Build the candidate list:
#   - one record per PR key
#   - filter to --root-repo when provided (keep entries whose recorded
#     root_repo matches, plus entries with no recorded root_repo — their repo
#     is simply unknown, and dropping them would hide legitimately-tracked PRs)
#   - sort by last_cron_action.at descending (missing timestamp sorts last)
# `.last_cron_action.at?` uses jq's `?` postfix to suppress the "Cannot index
# string with \"at\"" error a malformed (non-object) last_cron_action would
# otherwise raise, falling through to the `// null` default instead.
if ! RESULT=$(jq -c \
    --arg root_repo "$ROOT_REPO" \
    '
    ( . // {} )
    | to_entries
    | map(
        ( .key | tonumber? ) as $n
        | select($n != null)
        | {
            number: $n,
            owner_repo: ( .value.owner_repo // null ),
            last_activity: ( .value.last_cron_action.at? // null ),
            _root: ( .value.root_repo // null )
          }
      )
    | map(
        select(
          $root_repo == ""
          or ._root == null
          or ._root == $root_repo
        )
      )
    | sort_by( .last_activity // "" ) | reverse
    | map( del(._root) )
    | { candidates: .,
        most_recent: ( if length > 0 then .[0] else null end ),
        source: "session-state" }
    ' <<<"$PRS_JSON"); then
  echo "Error: jq failed to process session-state PR map" >&2
  exit 4
fi

printf '%s\n' "$RESULT"

COUNT=$(jq -r '.candidates | length' <<<"$RESULT" 2>/dev/null || echo 0)
case "$COUNT" in
  0) exit 2 ;;
  1) exit 0 ;;
  *) exit 1 ;;
esac
