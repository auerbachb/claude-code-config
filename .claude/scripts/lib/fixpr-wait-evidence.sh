#!/bin/bash
# Source-only wait persistence functions. The canonical SKILL loader and tests
# use this file; no operational authority is granted by a stored wait verdict.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "fixpr-wait-evidence.sh: source this library" >&2
  exit 2
fi
WAIT_HANDOFF_LANE=""
WAIT_HANDOFF_BINDING=""
persist_fixpr_wait_evidence() {
  [[ -n "${HANDOFF_STATE_SH:-}" && -n "${OWNER_REPO:-}" ]] || { echo "ERROR: scoped wait evidence unavailable" >&2; return 1; }
  resolve_fixpr_evidence || return 1
  local wait_record wait_class failure_id bundle_arg
  if [[ -z "${WAIT_CAPTURE_DIR:-}" ]]; then
    WAIT_CAPTURE_DIR=$("$RECOVERY_EVIDENCE_SH" new --kind wait --repo "$OWNER_REPO" --pr "$PR_NUMBER") || return 1
    printf '%s' "${WAIT_STATE:-}" > "$WAIT_CAPTURE_DIR/stdout" || return 1
    printf '%s' "${WAIT_EVAL_STDERR:-}" > "$WAIT_CAPTURE_DIR/stderr" || return 1
  fi
  bundle_arg=""
  [[ "${WAIT_FETCH_RC:--1}" == 0 ]] && bundle_arg="${TICK:-}"
  wait_record=$("$RECOVERY_EVIDENCE_SH" record --kind wait --repo "$OWNER_REPO" --pr "$PR_NUMBER" \
    --directory "$WAIT_CAPTURE_DIR" --exit-code "${WAIT_EVAL_RC:--1}" --fetch-exit-code "${WAIT_FETCH_RC:--1}" \
    --head "$WATCH_SHA" --baseline "$WAIT_BASELINE" --bundle "$bundle_arg") || return 1
  wait_class=$(jq -r '.classification' <<<"$wait_record") || return 1
  select_fixpr_wait_handoff || { echo "ERROR: wait handoff unavailable; evidence: $WAIT_CAPTURE_DIR" >&2; return 1; }
  local handoff_flags=(--owner-repo "$OWNER_REPO" --require-existing)
  if [[ "$WAIT_HANDOFF_LANE" == legacy-flat ]]; then
    handoff_flags=(--legacy-flat --require-existing --expect-pr "$PR_NUMBER" --expect-owner "$OWNER_REPO" --expect-head "$WATCH_SHA")
  fi
  # Independent unique map keys use the existing locked literal setter: no
  # read/modify/write race or whole-history replacement. Archive first, so a
  # failed latest write cannot erase either the prior status or this failure.
  if [[ "$(jq -r '.failure' <<<"$wait_record")" == true ]]; then
    failure_id=$(jq -r '.capture_id' <<<"$wait_record") || return 1
    "$HANDOFF_STATE_SH" "${handoff_flags[@]}" \
      --set "$PR_NUMBER" ".fixpr_wait_failures[\"$failure_id\"]=$wait_record" >/dev/null || { echo "ERROR: wait failure index write stopped; evidence: $WAIT_CAPTURE_DIR" >&2; return 1; }
  fi
  "$HANDOFF_STATE_SH" "${handoff_flags[@]}" \
    --set "$PR_NUMBER" ".fixpr_wait=$wait_record" >/dev/null || { echo "ERROR: wait latest write stopped; evidence: $WAIT_CAPTURE_DIR" >&2; return 1; }
  case "$wait_class" in
    valid_clean|valid_pending) return 0 ;;
    *) echo "ERROR: wait evaluation $wait_class; stopped; evidence: $WAIT_CAPTURE_DIR" >&2; return 1 ;;
  esac
}

select_fixpr_wait_handoff() {
  local binding="$OWNER_REPO:$PR_NUMBER:$WATCH_SHA" scoped selected lane path expected candidate
  if [[ -n "$WAIT_HANDOFF_LANE" ]]; then
    [[ "$WAIT_HANDOFF_BINDING" == "$binding" ]] || { echo "ERROR: wait handoff binding changed; restart the wait" >&2; return 1; }
    return 0
  fi
  scoped=$("$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --path "$PR_NUMBER") || return 1
  if [[ -f "$scoped" ]]; then
    WAIT_HANDOFF_LANE=scoped
  else
    if [[ -z "${POLLING_STATE_GATE_SH:-}" ]]; then
      for candidate in "$HOME/.claude/skills-worktree/.claude/scripts/polling-state-gate.sh" \
        "$HOME/.claude/scripts/polling-state-gate.sh" ".claude/scripts/polling-state-gate.sh"; do
        if [[ -x "$candidate" ]]; then POLLING_STATE_GATE_SH="$candidate"; break; fi
      done
    fi
    [[ -n "${POLLING_STATE_GATE_SH:-}" ]] || { echo "ERROR: selected wait handoff reader unavailable; no clean verdict" >&2; return 1; }
    selected=$("$POLLING_STATE_GATE_SH" "$PR_NUMBER" --resolve-handoff --repo "$OWNER_REPO" --root-repo "$(pwd -P)") || return 1
    jq -e --argjson pr "$PR_NUMBER" --arg owner "$OWNER_REPO" --arg head "$WATCH_SHA" \
      '.schema=="selected-handoff/v1" and .pr_number==$pr and (.owner_repo|ascii_downcase)==($owner|ascii_downcase) and .head_sha==$head
       and (.scope=="scoped" or .scope=="legacy-flat") and (.path|type=="string")' <<<"$selected" >/dev/null || return 1
    lane=$(jq -r '.scope' <<<"$selected") || return 1
    path=$(jq -r '.path' <<<"$selected") || return 1
    if [[ "$lane" == legacy-flat ]]; then
      expected=$("$HANDOFF_STATE_SH" --legacy-flat --path "$PR_NUMBER") || return 1
    else
      expected="$scoped"
    fi
    [[ "$path" == "$expected" ]] || { echo "ERROR: selected wait handoff path changed; no clean verdict" >&2; return 1; }
    WAIT_HANDOFF_LANE="$lane"
  fi
  WAIT_HANDOFF_BINDING="$binding"
}

resolve_fixpr_evidence() {
  if [[ -z "${RECOVERY_EVIDENCE_SH:-}" ]]; then
    local candidate
    for candidate in "$HOME/.claude/skills-worktree/.claude/scripts/recovery-evidence.sh" \
      "$HOME/.claude/scripts/recovery-evidence.sh" ".claude/scripts/recovery-evidence.sh"; do
      if [[ -x "$candidate" ]]; then RECOVERY_EVIDENCE_SH="$candidate"; break; fi
    done
  fi
  [[ -n "${RECOVERY_EVIDENCE_SH:-}" ]] || { echo "ERROR: raw wait capture unavailable; no clean verdict" >&2; return 1; }
}

capture_fixpr_wait_evidence() {
  [[ -n "${OWNER_REPO:-}" ]] || { echo "ERROR: verified wait repository unavailable" >&2; return 1; }
  resolve_fixpr_evidence || return 1
  WAIT_CAPTURE_DIR=$("$RECOVERY_EVIDENCE_SH" new --kind wait --repo "$OWNER_REPO" --pr "$PR_NUMBER") || return 1
  WAIT_FETCH_RC=0
  "$SCRIPT" --pr "$PR_NUMBER" --since "$WAIT_BASELINE" > "$WAIT_CAPTURE_DIR/fetch.stdout" \
    2> "$WAIT_CAPTURE_DIR/fetch.stderr" || WAIT_FETCH_RC=$?
  TICK=$(cat "$WAIT_CAPTURE_DIR/fetch.stdout") || return 1
  WAIT_EVAL_RC=0
  if [[ "$WAIT_FETCH_RC" == 0 ]]; then
    "$SCRIPT" --wait-state-eval "$WATCH_SHA" "$TICK" > "$WAIT_CAPTURE_DIR/stdout" \
      2> "$WAIT_CAPTURE_DIR/stderr" || WAIT_EVAL_RC=$?
  else
    WAIT_EVAL_RC="$WAIT_FETCH_RC"
  fi
  WAIT_STATE=$(cat "$WAIT_CAPTURE_DIR/stdout") || return 1
  persist_fixpr_wait_evidence
}
