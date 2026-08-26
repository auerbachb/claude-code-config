#!/usr/bin/env bash
# dismiss-stale-bot-changes.sh — Dismiss stale bot CHANGES_REQUESTED PR reviews (wrong commit vs HEAD).
#
# Used by /fixpr after every push so GitHub reviewDecision is not stuck on obsolete bot requests.
# Never dismisses humans: requires GitHub user.type == "Bot" AND login in the repo allowlist.
#
# Usage:
#   dismiss-stale-bot-changes.sh <pr_number> [--handoff-file <path>] [--owner-repo <owner/repo>]
#   dismiss-stale-bot-changes.sh --help
#
# --owner-repo scopes the handoff APPEND only (issue #1302). Without it the
# append fell through to handoff-state.sh's flat path even when --handoff-file
# named a scoped file, so the IDs landed somewhere the next phase never reads.
# Dismissal targeting still comes from `gh repo view`; this flag never changes
# which repo's reviews are dismissed. Defaults to the `gh repo view` value.
#
# Exit codes:
#   0 — finished (dismissals applied or no work; handoff optional skip)
#   2 — usage error
#   3 — could not resolve PR / HEAD
#   4 — gh / network error, real dismissal failure, invalid handoff JSON, or handoff merge failure

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "${HOME}/.claude/script-usage.log" 2>/dev/null || true

print_usage() {
  awk 'NR == 1 { next } /^$/ { exit } { print }' "$0"
}

PR_NUMBER=""
HANDOFF_FILE=""
OWNER_REPO_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_usage
      exit 0
      ;;
    --handoff-file)
      HANDOFF_FILE="${2:-}"
      if [[ -z "$HANDOFF_FILE" ]]; then
        echo "ERROR: --handoff-file requires a path" >&2
        exit 2
      fi
      shift 2
      ;;
    --owner-repo)
      OWNER_REPO_ARG="${2:-}"
      if [[ -z "$OWNER_REPO_ARG" ]]; then
        echo "ERROR: --owner-repo requires a value (e.g., --owner-repo owner/repo)" >&2
        exit 2
      fi
      # Reject anything that is not exactly one owner/repo pair, so a malformed
      # value can never be handed to handoff-state.sh as a path component.
      if [[ "$OWNER_REPO_ARG" != */* || "$OWNER_REPO_ARG" == */*/* \
            || "${OWNER_REPO_ARG%%/*}" == "" || "${OWNER_REPO_ARG#*/}" == "" ]]; then
        echo "ERROR: --owner-repo must be <owner>/<repo> (got: $OWNER_REPO_ARG)" >&2
        exit 2
      fi
      shift 2
      ;;
    -*)
      echo "ERROR: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$PR_NUMBER" ]]; then
        echo "ERROR: unexpected argument: $1" >&2
        exit 2
      fi
      PR_NUMBER="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR_NUMBER" ]]; then
  echo "ERROR: <pr_number> is required" >&2
  print_usage >&2
  exit 2
fi

if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "ERROR: <pr_number> must be a positive integer (got: $PR_NUMBER)" >&2
  exit 2
fi

OWNER_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
if [[ -z "$OWNER_REPO" ]]; then
  echo "ERROR: gh repo view failed — not in a git repo or no remote" >&2
  exit 3
fi
OWNER="${OWNER_REPO%/*}"
REPO="${OWNER_REPO#*/}"

HEAD_SHA=$(gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid // empty' 2>/dev/null || true)
if [[ -z "$HEAD_SHA" ]]; then
  echo "ERROR: could not read HEAD SHA for PR #$PR_NUMBER" >&2
  exit 3
fi

# Literal bot logins — must match dismiss targets; humans never appear here.
ALLOWLIST_JSON='["coderabbitai[bot]","cursor[bot]","greptile-apps[bot]","codeant-ai[bot]","graphite-app[bot]"]'

if ! REVIEWS_RAW=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews?per_page=100" 2>/dev/null); then
  echo "ERROR: gh api failed while listing PR reviews" >&2
  exit 4
fi

REVIEWS_JSON=$(echo "$REVIEWS_RAW" | jq -s 'add // []')
if [[ -z "$REVIEWS_JSON" ]] || ! echo "$REVIEWS_JSON" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: could not parse reviews JSON" >&2
  exit 4
fi

# Read loop, not mapfile — macOS ships bash 3.2, which has no mapfile/readarray.
DISMISS_IDS=()
while IFS= read -r rid; do
  [[ -n "$rid" ]] && DISMISS_IDS+=("$rid")
done < <(
  echo "$REVIEWS_JSON" | jq -r --arg sha "$HEAD_SHA" --argjson allow "$ALLOWLIST_JSON" '
    [.[]?
      | select(.state == "CHANGES_REQUESTED")
      | select((.commit_id // "") != "" and .commit_id != $sha)
      | select((.user.type // "") == "Bot")
      | select((.user.login // "") != "")
      | select(.user.login as $l | ($allow | index($l)))
      | .id]
    | unique
    | .[]
    | tostring
  '
)

DISMISSED_IDS=()
DISMISS_FAILURE_IDS=()
MESSAGE="Superseded by fixes on ${HEAD_SHA}"

# ${arr[@]+...} guard: bash 3.2 treats "${arr[@]}" on an empty array as unbound under set -u.
for rid in ${DISMISS_IDS[@]+"${DISMISS_IDS[@]}"}; do
  # Idempotent: duplicate dismiss may fail — refetch to confirm DISMISSED.
  if gh api -X PUT \
    "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews/$rid/dismissals" \
    -f message="$MESSAGE" >/dev/null 2>&1; then
    echo "[DISMISS-STALE] dismissed stale bot CHANGES_REQUESTED review_id=$rid (HEAD ${HEAD_SHA:0:7})"
    DISMISSED_IDS+=("$rid")
  else
    meta=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews/$rid" 2>/dev/null || true)
    st=$(echo "$meta" | jq -r '.state // empty')
    if [[ "$st" == "DISMISSED" ]]; then
      echo "[DISMISS-STALE] skip review_id=$rid — already DISMISSED"
    else
      echo "[DISMISS-STALE] WARN: could not dismiss review_id=$rid (state=${st:-unknown})" >&2
      DISMISS_FAILURE_IDS+=("$rid")
    fi
  fi
done

if [[ ${#DISMISS_FAILURE_IDS[@]} -gt 0 ]]; then
  echo "[DISMISS-STALE] ERROR: failed to dismiss review_id(s): ${DISMISS_FAILURE_IDS[*]} — exit 4" >&2
  exit 4
fi

if [[ ${#DISMISS_IDS[@]} -eq 0 ]]; then
  echo "[DISMISS-STALE] no stale bot CHANGES_REQUESTED reviews for PR #$PR_NUMBER (HEAD ${HEAD_SHA:0:7})"
fi

if [[ -n "$HANDOFF_FILE" && ${#DISMISSED_IDS[@]} -gt 0 ]]; then
  if [[ -e "$HANDOFF_FILE" ]]; then
    if ! jq -e . "$HANDOFF_FILE" >/dev/null 2>&1; then
      echo "[DISMISS-STALE] ERROR: handoff file is not valid JSON: $HANDOFF_FILE (PR #$PR_NUMBER, HEAD $HEAD_SHA)" >&2
      exit 4
    fi
    # Route through handoff-state.sh --append so the whole RMW cycle is serialized
    # under the shared state-lock.sh advisory lock (issue #682 — mirrors #639 fix on
    # session-state.json). The old code used bare mktemp (cross-filesystem temp) with
    # no lock around the read-modify-write, allowing concurrent orchestrators to
    # silently lose each other's dismissed-review-ID appends.
    _ds_script_dir="$(cd "$(dirname "$0")" && pwd)"
    _ds_handoff_helper="${_ds_script_dir}/handoff-state.sh"

    # Scope the append to the same file --handoff-file names (issue #1302).
    # Same flat-vs-scoped gating polling-state-gate.sh uses: pass --owner-repo
    # only when the resolved handoff is NOT the legacy flat path, so a caller
    # deliberately refreshing a flat file still appends to that file rather than
    # silently seeding a second, scoped one.
    _ds_owner_repo="${OWNER_REPO_ARG:-$OWNER_REPO}"
    _ds_flat_path="${HOME}/.claude/handoffs/pr-${PR_NUMBER}-handoff.json"
    _ds_or_flag=()
    _ds_target="$_ds_flat_path"
    if [[ -n "$_ds_owner_repo" && "$HANDOFF_FILE" != "$_ds_flat_path" ]]; then
      _ds_or_flag=(--owner-repo "$_ds_owner_repo")
      _ds_target="$("$_ds_handoff_helper" --owner-repo "$_ds_owner_repo" --path "$PR_NUMBER" 2>/dev/null || echo "$HANDOFF_FILE")"
    fi

    # Report the file actually written, not the one that was requested. A
    # divergence here means the append and the reader disagree — the exact
    # split-brain issue #1302 is about — so name both instead of claiming
    # success against a path nothing was written to.
    if [[ "$_ds_target" != "$HANDOFF_FILE" ]]; then
      echo "[DISMISS-STALE] WARN: appending to $_ds_target (resolved from owner/repo '$_ds_owner_repo'), not the requested --handoff-file $HANDOFF_FILE" >&2
    fi

    for id in "${DISMISSED_IDS[@]}"; do
      id_json="$(jq -n --arg x "$id" '$x')"
      if ! "$_ds_handoff_helper" ${_ds_or_flag[@]+"${_ds_or_flag[@]}"} --append "$PR_NUMBER" "stale_bot_reviews_dismissed" "$id_json"; then
        echo "[DISMISS-STALE] ERROR: failed to update handoff file for review_id=$id" >&2
        exit 4
      fi
    done
    echo "[DISMISS-STALE] appended review IDs to handoff file: $_ds_target"
  else
    echo "[DISMISS-STALE] WARN: handoff file missing; skipping append (create full handoff first): $HANDOFF_FILE" >&2
  fi
fi

exit 0
