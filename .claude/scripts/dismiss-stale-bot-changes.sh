#!/usr/bin/env bash
# dismiss-stale-bot-changes.sh — Dismiss stale bot CHANGES_REQUESTED PR reviews (wrong commit vs HEAD).
#
# Used by /fixpr after every push so GitHub reviewDecision is not stuck on obsolete bot requests.
# Never dismisses humans: requires GitHub user.type == "Bot" AND login in the repo allowlist.
#
# Usage:
#   dismiss-stale-bot-changes.sh <pr_number> [--handoff-file <path>]
#   dismiss-stale-bot-changes.sh --help
#
# Exit codes:
#   0 — finished (individual dismissals may skip with a log line; idempotent)
#   2 — usage error
#   3 — could not resolve PR / HEAD
#   4 — gh / network error fetching reviews

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" >> "${HOME}/.claude/script-usage.log" 2>/dev/null || true

print_usage() {
  awk 'NR == 1 { next } /^$/ { exit } { print }' "$0"
}

PR_NUMBER=""
HANDOFF_FILE=""

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

mapfile -t DISMISS_IDS < <(
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
MESSAGE="Superseded by fixes on ${HEAD_SHA}"

for rid in "${DISMISS_IDS[@]:-}"; do
  if [[ -z "$rid" ]]; then
    continue
  fi
  # Idempotent: duplicate dismiss may 422 — treat as success with a note.
  if gh api -X PUT \
    "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews/$rid/dismissals" \
    -f message="$MESSAGE" >/dev/null 2>&1; then
    echo "[DISMISS-STALE] dismissed stale bot CHANGES_REQUESTED review_id=$rid (HEAD ${HEAD_SHA:0:7})"
    DISMISSED_IDS+=("$rid")
  else
    # Re-fetch single review: if already dismissed / not dismissible, do not fail the run.
    meta=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews/$rid" 2>/dev/null || true)
    st=$(echo "$meta" | jq -r '.state // empty')
    if [[ "$st" == "DISMISSED" ]]; then
      echo "[DISMISS-STALE] skip review_id=$rid — already DISMISSED"
    else
      echo "[DISMISS-STALE] WARN: could not dismiss review_id=$rid (state=${st:-unknown}) — may lack permission or review not dismissible; continuing" >&2
    fi
  fi
done

if [[ ${#DISMISS_IDS[@]:-} -eq 0 ]]; then
  echo "[DISMISS-STALE] no stale bot CHANGES_REQUESTED reviews for PR #$PR_NUMBER (HEAD ${HEAD_SHA:0:7})"
fi

if [[ -n "$HANDOFF_FILE" && ${#DISMISSED_IDS[@]:-} -gt 0 ]]; then
  ids_json=$(printf '%s\n' "${DISMISSED_IDS[@]}" | jq -R . | jq -cs '.')
  tmp=$(mktemp)
  if [[ -f "$HANDOFF_FILE" ]] && jq -e . "$HANDOFF_FILE" >/dev/null 2>&1; then
    jq --argjson new_ids "$ids_json" '
      .stale_bot_reviews_dismissed = ((.stale_bot_reviews_dismissed // []) + $new_ids | unique)
    ' "$HANDOFF_FILE" >"$tmp" && mv "$tmp" "$HANDOFF_FILE"
  else
    jq -n \
      --argjson new_ids "$ids_json" \
      --arg sha "$HEAD_SHA" \
      --arg prn "$PR_NUMBER" \
      '{
        schema_version: "1.0",
        pr_number: ($prn | tonumber),
        head_sha: $sha,
        stale_bot_reviews_dismissed: $new_ids
      }' >"$HANDOFF_FILE"
  fi
  echo "[DISMISS-STALE] appended review IDs to handoff file: $HANDOFF_FILE"
fi

exit 0
