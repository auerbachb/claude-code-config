#!/usr/bin/env bash
# no-review-override-apply.sh — merge-gate.sh's glue to no-review-override.sh
# (issue #1899). *(library — sourced by merge-gate.sh, do not execute)*
#
# Kept out of merge-gate.sh so the gate's own diff stays a few marker lines.
# nro_apply reads merge-gate.sh's globals and, ONLY when the helper reports
# `applied: true`, rewrites MISSING[]:
#   [0, CI_MISSING_FROM)                   hard stops before CI   — kept
#   [CI_MISSING_FROM, CI_MISSING_TO)       CI reasons             — re-derived from
#                                          ci-status.sh --exclude-reviewers, so a
#                                          PENDING reviewer check-run cannot hold
#                                          the merge (a completed one is a verdict,
#                                          and the override never applies then)
#   [CI_MISSING_TO, REVIEW_BLOCKER_START)  remaining hard stops   — kept
#   [REVIEW_BLOCKER_START, end)            reviewer coverage      — waived
# While the window is still running it appends the helper's pending_reason.
# Any failure — helper missing, non-zero exit, unparseable output, CI re-read
# failing — leaves MISSING[] exactly as the normal gate built it.
# Sets NRO_JSON (the gate's `no_review_override` output field).

# nro_review_evidence — run review-substance.sh over the gate's fetched payloads
# (same input shape merge-gate.sh builds) for paths where the gate skipped it.
# Prints the evidence object; non-zero on any failure, so the caller keeps
# hollow=[] (no approval discounted — the override cannot fire on it).
nro_review_evidence() {
  local evaluator="$SCRIPT_DIR/review-substance.sh" ev
  [[ -x "$evaluator" ]] || return 1
  ev=$(printf '%s\n%s\n%s\n%s\n' "${REVIEWS_JSON:-[]}" "${PR_COMMENTS_JSON:-[]}" "${ISSUE_COMMENTS_JSON:-[]}" "${RESOLVED_COMMENT_IDS:-[]}" \
    | jq -cs --arg sha "$HEAD_SHA" --arg push "${LAST_COMMIT_TS:-}" \
        '{head_sha: $sha, push_ts: $push, reviews: .[0], pr_comments: .[1], issue_comments: .[2],
          resolved_comment_ids: .[3]}' 2>/dev/null \
    | "$evaluator" 2>/dev/null) || return 1
  printf '%s' "$ev" | jq -e 'type == "object" and (.reviewers | type == "object")' >/dev/null 2>&1 || return 1
  printf '%s' "$ev"
}

nro_apply() {
  NRO_JSON='null'
  local helper="$SCRIPT_DIR/no-review-override.sh"
  local start="${REVIEW_BLOCKER_START:-${#MISSING[@]}}"
  local i blockers runs_raw payload out rc=0 window="${NRO_WINDOW_SECONDS:-}"
  [[ -x "$helper" ]] || {
    echo "[merge-gate] no-review-override.sh not found or not executable at $helper — override unavailable, gate unchanged (issue #1899)" >&2
    return 0
  }
  local review_reasons=()
  for (( i = start; i < ${#MISSING[@]}; i++ )); do review_reasons+=("${MISSING[$i]}"); done
  blockers=$(jq -cn --args '$ARGS.positional | map(select(length > 0))' -- "${review_reasons[@]:-}")
  local evidence="${REVIEW_EVIDENCE:-}" hollow
  [[ -n "$evidence" ]] || evidence='{}'
  # The gate computes review_evidence only on the cr and bugbot paths, so on the
  # Greptile path (or a degraded bugbot one) it is `{}` and every hollow HEAD
  # approval would read as a verdict (issue #1932). Evaluate it here instead.
  # A failure keeps hollow=[] — every approval stays a verdict, override off.
  if ! printf '%s' "$evidence" | jq -e 'type == "object" and (.reviewers | type == "object")' >/dev/null 2>&1; then
    evidence=$(nro_review_evidence) || evidence='{}'
  fi
  hollow=$(printf '%s' "$evidence" | jq -c '(.hollow // []) | if type == "array" then . else [] end' 2>/dev/null) || hollow='[]'
  [[ -n "$hollow" ]] || hollow='[]'
  # Raw (undeduped) runs: the anchor wants every run's started_at.
  runs_raw=$(printf '%s\n' "${CHECK_RUNS_RAW:-}" | jq -cs '[.[]? | .check_runs[]?]' 2>/dev/null) || runs_raw='[]'
  [[ -n "$runs_raw" ]] || runs_raw='[]'
  payload=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' "${REVIEWS_JSON:-[]}" "${PR_COMMENTS_JSON:-[]}" "${ISSUE_COMMENTS_JSON:-[]}" \
      "$runs_raw" "$blockers" "$hollow" \
    | jq -cs --arg owner "$OWNER" --arg repo "$REPO" --arg pr "$PR_NUMBER" --arg sha "$HEAD_SHA" \
        --arg cts "${LAST_COMMIT_TS:-}" --arg win "$window" --arg tier "${REVIEW_TIER_GATE:-}" '
      {owner: $owner, repo: $repo, pr: $pr, head_sha: $sha,
       commit_ts: (if $cts == "" then null else $cts end),
       window_seconds: (if $win == "" then null else ($win | tonumber) end),
       tier_gate: $tier, reviews: .[0], pr_comments: .[1], issue_comments: .[2],
       check_runs_raw: .[3], review_blockers: .[4], hollow: .[5]}' 2>/dev/null) || payload=""
  if [[ -z "$payload" ]]; then
    echo "[merge-gate] could not build the no-review override payload — gate unchanged (issue #1899)" >&2
    return 0
  fi
  out=$(printf '%s' "$payload" | "$helper" 2>/dev/null) || rc=$?
  if [[ "$rc" -ne 0 || -z "$out" ]] || ! printf '%s' "$out" | jq -e 'type == "object" and (.applied | type == "boolean")' >/dev/null 2>&1; then
    echo "[merge-gate] no-review-override.sh failed (exit $rc) — gate unchanged (issue #1899)" >&2
    return 0
  fi
  NRO_JSON=$(printf '%s' "$out" | jq -c .)

  if [[ "$(printf '%s' "$NRO_JSON" | jq -r '.applied')" != true ]]; then
    local pending
    pending=$(printf '%s' "$NRO_JSON" | jq -r '.pending_reason // ""')
    [[ -n "$pending" ]] && MISSING+=("$pending")
    return 0
  fi

  # Applied: re-derive the CI reasons without pending reviewer runs.
  local ci_ex ci_reasons=() n names
  ci_ex=$(printf '%s' "$CHECK_RUNS_JSON" | "$SCRIPT_DIR/ci-status.sh" "$HEAD_SHA" --format json --check-runs-stdin --exclude-reviewers 2>/dev/null || true)
  if [[ -z "$ci_ex" ]] || ! printf '%s' "$ci_ex" | jq -e '(.in_progress | type == "number") and (.failing | type == "number")' >/dev/null 2>&1; then
    NRO_JSON=$(printf '%s' "$NRO_JSON" | jq -c '.applied = false | .waived_reasons = [] | .reason = "ci_recheck_failed"')
    echo "[merge-gate] no-review override: build-CI re-read failed — override not applied (issue #1899)" >&2
    return 0
  fi
  n=$(printf '%s' "$ci_ex" | jq -r '.in_progress')
  if [[ "$n" -gt 0 ]]; then
    names=$(printf '%s' "$ci_ex" | jq -r '(.in_progress_runs // []) | map(.name) | join(", ")')
    ci_reasons+=("CI has $n incomplete check-run(s): ${names:-<none reported yet>}")
  fi
  n=$(printf '%s' "$ci_ex" | jq -r '.failing')
  if [[ "$n" -gt 0 ]]; then
    names=$(printf '%s' "$ci_ex" | jq -r '.blocking | map("\(.name) (\(.conclusion))") | join(", ")')
    ci_reasons+=("CI has $n failing check-run(s): $names")
  fi

  local kept=() r
  local from="${CI_MISSING_FROM:-0}" to="${CI_MISSING_TO:-0}"
  for (( i = 0; i < from; i++ )); do kept+=("${MISSING[$i]}"); done
  for r in "${ci_reasons[@]:-}"; do [[ -n "$r" ]] && kept+=("$r"); done
  for (( i = to; i < start; i++ )); do kept+=("${MISSING[$i]}"); done
  MISSING=()
  for (( i = 0; i < ${#kept[@]}; i++ )); do MISSING+=("${kept[$i]}"); done
  echo "[merge-gate] no-review override applied on HEAD ${HEAD_SHA:0:7}: no AI reviewer verdict after $(printf '%s' "$NRO_JSON" | jq -r '.elapsed_seconds')s (window $(printf '%s' "$NRO_JSON" | jq -r '.window_seconds')s); waived $(printf '%s' "$NRO_JSON" | jq -r '.waived_reasons | length') reviewer-coverage reason(s). Merge must be logged via unreviewed-merge-ledger.sh (issue #1899)." >&2
  return 0
}
