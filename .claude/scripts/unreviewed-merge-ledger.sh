#!/usr/bin/env bash
# unreviewed-merge-ledger.sh — durable cross-session, cross-repo ledger of PRs merged
# through the no-review override (issue #1899); read by the overnight backfill (#1900).
# catalog: merge-gate-sequencing — Record, list, and mark backfill status of merges made without an AI review
#
# USAGE
#   unreviewed-merge-ledger.sh record --pr N [--repo owner/name] --gate-json <file|->
#   unreviewed-merge-ledger.sh list [--repo owner/name] [--pending]
#   unreviewed-merge-ledger.sh backfill --pr N --sha <head_sha> --status <s> [--repo owner/name]
#                                       [--detail-json <file|->]
#   unreviewed-merge-ledger.sh --help
#
# FILE
#   $HOME/.claude/unreviewed-merges.json — {schema_version: 1, entries: [...]}.
#   Every write holds the state-lock.sh lock across the whole read-modify-write
#   and commits with temp + rename. One entry per (repo, pr, head_sha); a
#   repeated `record` is a no-op (exit 0). Repo keys are lowercase owner/name.
#
# record
#   Run AFTER the merge, with the merge-gate.sh JSON that authorized it. Refuses
#   (exit 4, nothing written) unless the gate JSON shows
#   `met == true` and `no_review_override.applied == true`, AND GitHub confirms
#   the PR is MERGED with headRefOid == the gate's head_sha (3 tries, 2s apart).
#   Then applies the `merged-unreviewed` label (creating it if absent). A label
#   failure is NOT fatal: the row is written with label_applied:false and one
#   stderr warning. Row fields: repo, pr, title, url, head_sha,
#   merge_commit_sha, merged_at, recorded_at, window_seconds, head_anchor_ts,
#   anchor_source, elapsed_seconds, missing_reviewers[{reviewer,reason}],
#   waived_reasons[], excluded_reviewer_checks[], label_applied,
#   backfill_status ("pending").
#   Prints `recorded` or `already-recorded` on stdout.
#
# list
#   Prints the entries as one JSON array (oldest first). --repo filters to one
#   repo; --pending keeps backfill_status == "pending". A missing ledger is [].
#
# backfill
#   Sets backfill_status (backfill-review.sh writes pending, reviewed-clean,
#   issues-filed, or skipped) and backfill_updated_at on one entry — the hook
#   Issue #1900's backfill uses. --detail-json stores a JSON object as the
#   entry's `backfill` field (replacing any earlier one): channel, main_sha,
#   reviewed_at, findings[], issues[], skip_reason, label_synced. Exit 4 when
#   no such entry exists or the detail is not a JSON object.
#
# EXIT CODES (session-state.sh convention)
#   0 ok · 2 usage · 4 refused / invalid input / no such entry · 5 write failure
#   6 lock timeout · 8 HOME unset
#
# Mechanism: .claude/reference/no-review-override.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="merged-unreviewed"
CONFIRM_TRIES=3
CONFIRM_SLEEP=2

print_usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { local rc="$1"; shift; echo "unreviewed-merge-ledger.sh: $*" >&2; exit "$rc"; }

CMD="${1:-}"
case "$CMD" in
  -h|--help) print_usage; exit 0 ;;
  record|list|backfill) shift ;;
  "") print_usage >&2; exit 2 ;;
  *) die 2 "unknown subcommand: $CMD" ;;
esac

[[ -n "${HOME:-}" ]] || die 8 "HOME is unset"
LEDGER="$HOME/.claude/unreviewed-merges.json"

PR="" REPO="" GATE_SRC="" PENDING=0 SHA="" STATUS="" DETAIL_SRC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) PR="${2:-}"; shift 2 || die 2 "--pr needs a value" ;;
    --repo) REPO="${2:-}"; shift 2 || die 2 "--repo needs a value" ;;
    --gate-json) GATE_SRC="${2:-}"; shift 2 || die 2 "--gate-json needs a value" ;;
    --sha) SHA="${2:-}"; shift 2 || die 2 "--sha needs a value" ;;
    --status) STATUS="${2:-}"; shift 2 || die 2 "--status needs a value" ;;
    --detail-json) DETAIL_SRC="${2:-}"; shift 2 || die 2 "--detail-json needs a value" ;;
    --pending) PENDING=1; shift ;;
    *) die 2 "unknown flag: $1" ;;
  esac
done

normalize_repo() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's#^https://github.com/##' -e 's#\.git$##'; }

read_ledger() { # prints the ledger document, or a fresh one
  if [[ -s "$LEDGER" ]]; then
    jq -ce 'select(type == "object" and (.entries | type == "array"))' "$LEDGER" 2>/dev/null \
      || die 4 "ledger at $LEDGER is not a {schema_version, entries[]} document — refusing to overwrite it"
  else
    printf '%s\n' '{"schema_version":1,"entries":[]}'
  fi
}

# write_ledger <new-document-json> — caller holds the lock.
write_ledger() {
  local tmp
  tmp="$(mktemp "$LEDGER.tmp.XXXXXX")" || die 5 "cannot create a temp file next to $LEDGER"
  printf '%s\n' "$1" > "$tmp" || { rm -f "$tmp"; die 5 "cannot write $tmp"; }
  state_lock_commit "$tmp" "$LEDGER"
}

with_lock() {
  mkdir -p "$HOME/.claude" || die 5 "cannot create $HOME/.claude"
  # shellcheck source=state-lock.sh
  source "$SCRIPT_DIR/state-lock.sh" || die 5 "state-lock.sh unavailable"
  state_lock_acquire "$LEDGER" || die 6 "lock timeout on $LEDGER"
  trap 'state_lock_release' EXIT
}

if [[ "$CMD" == list ]]; then
  [[ -n "$REPO" ]] && REPO="$(normalize_repo "$REPO")"
  DOC="$(read_ledger)" || exit $?
  jq -c --arg repo "$REPO" --argjson pending "$PENDING" '
    [.entries[] | select($repo == "" or .repo == $repo)
                | select($pending == 0 or .backfill_status == "pending")]' <<<"$DOC"
  exit 0
fi

[[ "$PR" =~ ^[0-9]+$ ]] || die 2 "--pr N is required"
if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || REPO=""
  [[ -n "$REPO" ]] || die 2 "--repo owner/name is required outside a GitHub checkout"
fi
REPO_RAW="$REPO"
REPO="$(normalize_repo "$REPO")"

if [[ "$CMD" == backfill ]]; then
  [[ -n "$SHA" && -n "$STATUS" ]] || die 2 "backfill needs --sha and --status"
  DETAIL='null'
  if [[ -n "$DETAIL_SRC" ]]; then
    if [[ "$DETAIL_SRC" == "-" ]]; then DETAIL="$(cat)"; else DETAIL="$(cat "$DETAIL_SRC" 2>/dev/null)" || die 4 "cannot read $DETAIL_SRC"; fi
    # Exactly one value, and it an object: `{} {}` passes a per-value check.
    printf '%s' "$DETAIL" | jq -se 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 \
      || die 4 "--detail-json is not a single JSON object"
    DETAIL="$(printf '%s' "$DETAIL" | jq -c .)"
  fi
  with_lock
  DOC="$(read_ledger)" || exit $?
  [[ "$(jq -r --arg r "$REPO" --argjson p "$PR" --arg s "$SHA" \
      '[.entries[] | select(.repo == $r and .pr == $p and .head_sha == $s)] | length' <<<"$DOC")" -gt 0 ]] \
    || die 4 "no ledger entry for $REPO PR #$PR at $SHA"
  NEW="$(jq -c --arg r "$REPO" --argjson p "$PR" --arg s "$SHA" --arg st "$STATUS" \
      --argjson detail "$DETAIL" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .entries |= map(if .repo == $r and .pr == $p and .head_sha == $s
                    then .backfill_status = $st | .backfill_updated_at = $now
                         | (if $detail == null then . else .backfill = $detail end)
                    else . end)' <<<"$DOC")" || die 5 "could not build the updated ledger"
  write_ledger "$NEW" || exit $?
  echo "updated"
  exit 0
fi

# ---- record ----------------------------------------------------------------
[[ -n "$GATE_SRC" ]] || die 2 "--gate-json <file|-> is required"
if [[ "$GATE_SRC" == "-" ]]; then GATE="$(cat)"; else GATE="$(cat "$GATE_SRC" 2>/dev/null)" || die 4 "cannot read $GATE_SRC"; fi
printf '%s' "$GATE" | jq -e 'type == "object"' >/dev/null 2>&1 || die 4 "gate JSON is not an object"
printf '%s' "$GATE" | jq -e '.met == true and .no_review_override.applied == true' >/dev/null 2>&1 \
  || die 4 "refused: the gate JSON does not show a met no-review override (normal-path merges are never logged here)"
GATE_SHA="$(printf '%s' "$GATE" | jq -r '.head_sha // ""')"
[[ -n "$GATE_SHA" ]] || die 4 "gate JSON has no head_sha"

PRV=""
for (( try = 1; try <= CONFIRM_TRIES; try++ )); do
  PRV="$(gh pr view "$PR" --repo "$REPO_RAW" --json state,headRefOid,mergeCommit,mergedAt,title,url 2>/dev/null)" || PRV=""
  if [[ -n "$PRV" && "$(printf '%s' "$PRV" | jq -r '.state // ""')" == MERGED ]]; then break; fi
  (( try < CONFIRM_TRIES )) && sleep "$CONFIRM_SLEEP"
done
[[ -n "$PRV" && "$(printf '%s' "$PRV" | jq -r '.state // ""')" == MERGED ]] \
  || die 4 "refused: GitHub does not report $REPO PR #$PR as MERGED — nothing recorded"
[[ "$(printf '%s' "$PRV" | jq -r '.headRefOid // ""')" == "$GATE_SHA" ]] \
  || die 4 "refused: merged head $(printf '%s' "$PRV" | jq -r '.headRefOid // "?"') is not the gate's head_sha $GATE_SHA"

LABEL_APPLIED=true
gh label create "$LABEL" --repo "$REPO_RAW" --color "d93f0b" \
  --description "Merged by the no-review override (issue #1899) — awaiting backfill review" >/dev/null 2>&1 || true
if ! gh pr edit "$PR" --repo "$REPO_RAW" --add-label "$LABEL" >/dev/null 2>&1; then
  LABEL_APPLIED=false
  echo "unreviewed-merge-ledger.sh: WARNING — could not apply the $LABEL label to $REPO PR #$PR; recording the row with label_applied:false" >&2
fi

ROW="$(jq -cn --argjson g "$GATE" --argjson v "$PRV" --arg repo "$REPO" --argjson pr "$PR" \
    --argjson label "$LABEL_APPLIED" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  ($g.no_review_override) as $o
  | {repo: $repo, pr: $pr, title: ($v.title // ""), url: ($v.url // ""),
     head_sha: $g.head_sha, merge_commit_sha: ($v.mergeCommit.oid // null),
     merged_at: ($v.mergedAt // null), recorded_at: $now,
     window_seconds: $o.window_seconds, head_anchor_ts: $o.head_anchor_ts,
     anchor_source: $o.anchor_source, elapsed_seconds: $o.elapsed_seconds,
     missing_reviewers: ($o.missing_reviewers // []), waived_reasons: ($o.waived_reasons // []),
     excluded_reviewer_checks: ($o.excluded_reviewer_checks // []),
     label_applied: $label, backfill_status: "pending"}')" || die 4 "could not build the ledger row"

with_lock
DOC="$(read_ledger)" || exit $?
if [[ "$(jq -r --arg r "$REPO" --argjson p "$PR" --arg s "$GATE_SHA" \
    '[.entries[] | select(.repo == $r and .pr == $p and .head_sha == $s)] | length' <<<"$DOC")" -gt 0 ]]; then
  echo "already-recorded"
  exit 0
fi
NEW="$(jq -c --argjson row "$ROW" '.schema_version = 1 | .entries += [$row]' <<<"$DOC")" || die 5 "could not append the row"
write_ledger "$NEW" || exit $?
echo "recorded"
