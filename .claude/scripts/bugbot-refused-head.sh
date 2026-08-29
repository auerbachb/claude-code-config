#!/usr/bin/env bash
# bugbot-refused-head.sh — has BugBot refused THIS HEAD for a Cursor usage/spend limit?
#
# PURPOSE
#   One shared answer for every `@cursor review` trigger path. BugBot is metered
#   against a Cursor usage/spend limit and refused 64% of PRs in the 2026-08
#   audit window (#1199/#1204); a nudge cannot clear a usage limit, so once
#   cursor[bot] has refused on a given HEAD every later nudge on that same HEAD
#   is PR noise. The next push is a new HEAD and starts clean.
#
#   Extracted so `maybe-trigger-ai-review.sh` and `/fixpr` Step 3b share one
#   implementation rather than each carrying a copy (CodeRabbit review, PR #1203).
#
# USAGE
#   bugbot-refused-head.sh <pr_number> <head_sha>
#
# EXIT STATUS
#   0  A refusal is present AND attributable to this commit — suppress the nudge.
#   1  No refusal, not attributable, or anything unreadable — POST the nudge.
#   2  Usage/dependency error.
#
# FAIL-OPEN BY DESIGN
#   Every uncertain case returns 1. bugbot.md calls a duplicate `@cursor review`
#   harmless, while a wrongly-suppressed one costs a whole review — the same cost
#   asymmetry escalate-review.sh applies to this tool (issue #956).
#
# ATTRIBUTION
#   A timestamp alone does not prove a refusal is ABOUT this commit: issue
#   comments carry no SHA, and "created after the HEAD commit date" also matches a
#   run that started before the push landed. So a refusal counts only when BugBot
#   also has a footprint ON this commit — a `Cursor Bugbot` check-run published by
#   the Cursor app (slug scope per issue #956; a same-named run from any other app
#   is not BugBot's).

set -uo pipefail
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(basename "$0")" "${*//$'\n'/ }" 2>/dev/null >> "$HOME/.claude/script-usage.log" || true

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
  awk 'NR == 1 { next } /^$/ { exit } { print }' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

PR_NUMBER="${1-}"
HEAD_SHA="${2-}"
if [[ -z "$PR_NUMBER" || -z "$HEAD_SHA" ]]; then
  echo "bugbot-refused-head.sh: usage: $(basename "$0") <pr_number> <head_sha>" >&2
  exit 2
fi
if ! [[ "$PR_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "bugbot-refused-head.sh: <pr_number> must be a positive integer (got: $PR_NUMBER)" >&2
  exit 2
fi
for dep in gh jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "bugbot-refused-head.sh: '$dep' not found on PATH" >&2; exit 2; }
done

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS_LIB="$SELF_DIR/lib/ts-normalizer.sh"
# The canonical #836/#885 ordering rule. Without it there is no safe compare, so
# decline to suppress rather than invent one.
if [[ ! -r "$TS_LIB" ]] || ! source "$TS_LIB"; then
  echo "bugbot-refused-head.sh: could not load $TS_LIB — cannot order timestamps; not suppressing" >&2
  exit 1
fi

HEAD_TS="$(gh api "repos/{owner}/{repo}/commits/$HEAD_SHA" --jq '.commit.committer.date // empty' 2>/dev/null)" || exit 1
[[ -n "$HEAD_TS" ]] || exit 1

COMMENTS="$(gh api --paginate "repos/{owner}/{repo}/issues/$PR_NUMBER/comments?per_page=100" 2>/dev/null | jq -s 'add // []' 2>/dev/null)" || exit 1
[[ -n "$COMMENTS" ]] || exit 1

# Newest cursor[bot] refusal, raw. Phrase set matches escalate-review.sh's
# is_failure_text so the two agree on what a refusal looks like.
REFUSAL_TS="$(jq -r '
  [ .[]?
    | select((.user.login // "") == "cursor[bot]")
    | select((.body // "") | test("couldn.t run|could not run|usage limit|usage or spend limit"; "i"))
    | (.created_at // "")
    | select(. != "") ]
  | sort | last // ""
' <<<"$COMMENTS" 2>/dev/null)" || exit 1
[[ -n "$REFUSAL_TS" ]] || exit 1

RUNS="$(gh api "repos/{owner}/{repo}/commits/$HEAD_SHA/check-runs?per_page=100" 2>/dev/null)" || exit 1
jq -e '[.check_runs[]? | select((.name // "") == "Cursor Bugbot" and (.app.slug // "") == "cursor")] | length > 0' \
  <<<"$RUNS" >/dev/null 2>&1 || exit 1

[[ ! "$(norm_ts "$REFUSAL_TS")" < "$(norm_ts "$HEAD_TS")" ]]
