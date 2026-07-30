#!/usr/bin/env bash
# reviewer-activity.sh — Detect whether each conditionally-triggered reviewer has
# already posted activity on a specific pushed SHA.
#
# Extracted from /fixpr Step 3b (Issue #788 hotspot extraction).
# The trigger rate-cap / @coderabbitai full review decision logic stays in the
# caller (fixpr/SKILL.md) — that logic involves judgment about per-PR state and
# the 2/hour cap, and is deliberately in-turn.
#
# Usage:
#   reviewer-activity.sh <PR_NUMBER> <PUSHED_SHA> <PUSHED_AT>
#
#   PR_NUMBER  — integer PR number
#   PUSHED_SHA — full 40-char SHA that was just pushed
#   PUSHED_AT  — ISO-8601 timestamp captured before git push (avoids race)
#
# Output: JSON object on stdout —
#   { "coderabbit": <bool>, "graphite": <bool>, "codeant": <bool> }
#   true  = reviewer auto-triggered activity on PUSHED_SHA since PUSHED_AT
#   false = no activity detected; caller should post a trigger comment
#
# Conversation-level comments do not expose a commit_id, so they only count as
# activity on the pushed SHA when the body mentions the full SHA or short SHA.
# SHA-scoped reviews, inline comments, and check-runs are used for the other
# endpoints to avoid treating a late summary from the previous SHA as coverage
# for the new one.
#
# Exit codes:
#   0  OK (JSON written to stdout)
#   1  usage error
#   2  gh/network error (stderr carries the gh output)

set -euo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" \
  >> "$HOME/.claude/script-usage.log" 2>/dev/null || true

if [[ $# -ne 3 ]]; then
  echo "Usage: reviewer-activity.sh <PR_NUMBER> <PUSHED_SHA> <PUSHED_AT>" >&2
  exit 1
fi

PR_NUMBER="$1"
PUSHED_SHA="$2"
PUSHED_AT="$3"

# Resolve owner/repo: respect GH_REPO override (same as gh CLI) then fall back
# to the git remote, matching the pattern used by other scripts in this directory.
if [[ -n "${GH_REPO:-}" ]]; then
  OWNER_REPO="$GH_REPO"
  OWNER="${OWNER_REPO%%/*}"
  REPO="${OWNER_REPO##*/}"
else
  _remote_url=$(git remote get-url origin 2>/dev/null || echo "")
  if [[ -z "$_remote_url" ]]; then
    echo "ERROR: could not resolve owner/repo from git remote" >&2
    exit 2
  fi
  _remote_url="${_remote_url%.git}"
  OWNER_REPO="${_remote_url##*github.com[:/]}"
  OWNER="${OWNER_REPO%%/*}"
  REPO="${OWNER_REPO##*/}"
fi

# Fetch all three PR comment endpoints + check-runs for the pushed SHA.
# Using || exit 2 to map gh failures to the documented error code.
REVIEWS=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews?per_page=100" \
  | jq -s 'add // []') || exit 2
INLINE=$(gh api --paginate "repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments?per_page=100" \
  | jq -s 'add // []') || exit 2
CONVO=$(gh api --paginate "repos/$OWNER/$REPO/issues/$PR_NUMBER/comments?per_page=100" \
  | jq -s 'add // []') || exit 2
CHECK_RUNS=$(gh api --paginate "repos/$OWNER/$REPO/commits/$PUSHED_SHA/check-runs?per_page=100" \
  --jq '.check_runs[]' | jq -s '.') || exit 2

# Evaluate the activity map.
# Each reviewer is true when ANY of the following holds since PUSHED_AT:
#   - A review object pinned to PUSHED_SHA (by commit_id)
#   - An inline comment on PUSHED_SHA (by commit_id or original_commit_id)
#   - A conversation-level comment that explicitly mentions the full or short SHA
#   - A check-run from that reviewer's app started/completed since PUSHED_AT
jq -n \
  --arg pushed_at "$PUSHED_AT" \
  --arg sha "$PUSHED_SHA" \
  --argjson reviews "$REVIEWS" \
  --argjson inline "$INLINE" \
  --argjson convo "$CONVO" \
  --argjson checks "$CHECK_RUNS" \
  '
  def recent($ts): ($ts // "") >= $pushed_at;
  def matches_any($value; $needles):
    ($value // "" | ascii_downcase) as $haystack
    | any($needles[]; (. | ascii_downcase) as $needle | $haystack | contains($needle));
  def check_by($names):
    any($checks[]?;
      (((.name // "") as $name
        | (.app.slug // "") as $slug
        | (.app.name // "") as $app
        | (matches_any($name; $names) or matches_any($slug; $names) or matches_any($app; $names))))
      and recent(.started_at // .created_at // .completed_at));
  def convo_by($login):
    any($convo[]?;
      .user.login == $login
      and recent(.created_at)
      and (((.body // "") | contains($sha)) or ((.body // "") | contains($sha[0:7]))));
  {
    coderabbit:
      (any($reviews[]?; .user.login == "coderabbitai[bot]" and .commit_id == $sha and recent(.submitted_at))
       or any($inline[]?; .user.login == "coderabbitai[bot]" and ((.commit_id // .original_commit_id // "") == $sha) and recent(.created_at))
       or convo_by("coderabbitai[bot]")
       or check_by(["CodeRabbit", "coderabbitai"])),
    graphite:
      (any($reviews[]?; .user.login == "graphite-app[bot]" and .commit_id == $sha and recent(.submitted_at))
       or any($inline[]?; .user.login == "graphite-app[bot]" and ((.commit_id // .original_commit_id // "") == $sha) and recent(.created_at))
       or convo_by("graphite-app[bot]")
       or check_by(["Graphite", "graphite-app"])),
    codeant:
      (any($reviews[]?; .user.login == "codeant-ai[bot]" and .commit_id == $sha and recent(.submitted_at))
       or any($inline[]?; .user.login == "codeant-ai[bot]" and ((.commit_id // .original_commit_id // "") == $sha) and recent(.created_at))
       or convo_by("codeant-ai[bot]")
       or check_by(["CodeAnt", "codeant-ai"]))
  }
  '
