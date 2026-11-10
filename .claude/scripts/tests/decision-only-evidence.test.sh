#!/usr/bin/env bash
# catalog: tests — Exercise the real quiet-wait and watch-posture evidence writes, including failed persistence
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
source "$TEST_DIR/lib/skill-bash.sh"
TMP_TEST="$(mktemp -d)"
trap 'rm -rf "$TMP_TEST"' EXIT
export HOME="$TMP_TEST/home"
export CLAUDE_SESSION_REPO="auerbachb/claude-code-config"
mkdir -p "$HOME/.claude"
export OWNER_REPO="$CLAUDE_SESSION_REPO" PR_NUMBER=1972
export HANDOFF_STATE_SH="$REPO_ROOT/.claude/scripts/handoff-state.sh"
export SESSION_STATE_SH="$REPO_ROOT/.claude/scripts/session-state.sh"
export RECOVERY_EVIDENCE_SH="$REPO_ROOT/.claude/scripts/recovery-evidence.sh"
export WAIT_EVAL_RC=0 WAIT_FETCH_RC=0 GATE_RC=1
WAIT_BLOCK=$(extract_skill_bash "$REPO_ROOT/.claude/skills/fixpr/SKILL.md" fixpr-persist-wait-evidence)
POSTURE_BLOCK=$(extract_skill_bash "$REPO_ROOT/.claude/skills/pr-monitor-and-manage/SKILL.md" pmm-persist-watch-posture)
printf '%s\n' "$WAIT_BLOCK" > "$TMP_TEST/wait.sh"
printf '%s\n' "$POSTURE_BLOCK" > "$TMP_TEST/posture.sh"
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --init "$PR_NUMBER" '{}' >/dev/null
export WAIT_STATE='{"bots_pending":[],"ci_pending":[],"ci_failing":[{"name":"build","conclusion":"failure"}],"new_findings":1,"head_moved":false}'
export WATCH_SHA=abcdef123456 WAIT_BASELINE=2026-11-07T17:00:00Z TICK="$TMP_TEST/raw-bundle.json"
printf '%s\n' '{"diagnostic":"full raw capture retained"}' > "$TICK"
bash -c 'source "$1"; persist_fixpr_wait_evidence' _ "$TMP_TEST/wait.sh" > "$TMP_TEST/stdout"
test ! -s "$TMP_TEST/stdout"
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --get "$PR_NUMBER" | jq -e --arg bundle "$TICK" '.fixpr_wait.head_sha=="abcdef123456" and .fixpr_wait.bundle_path==$bundle and .fixpr_wait.verdict.ci_failing[0].conclusion=="failure" and .fixpr_wait.verdict.new_findings==1 and (.fixpr_wait.observed_at|length>0)' >/dev/null
jq -e '.diagnostic=="full raw capture retained"' "$TICK" >/dev/null
# Exercise the documented isolated-child boundary: no inherited helper or scope.
# The child receives explicit inputs and the real helper definition in its file.
printf '%s\n' "$WAIT_BLOCK" > "$TMP_TEST/isolated-wait.sh"
printf '%s\n' 'HANDOFF_STATE_SH=$1; OWNER_REPO=$2; persist_fixpr_wait_evidence' >> "$TMP_TEST/isolated-wait.sh"
env -u HANDOFF_STATE_SH -u OWNER_REPO bash "$TMP_TEST/isolated-wait.sh" "$HANDOFF_STATE_SH" "$OWNER_REPO"
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --get "$PR_NUMBER" | jq -e '.fixpr_wait.verdict.ci_failing[0].conclusion=="failure"' >/dev/null
# A later clean snapshot replaces the failure status; the raw evidence is not deleted.
export WAIT_STATE='{"bots_pending":[],"ci_pending":[],"ci_failing":[],"new_findings":0,"head_moved":false}'
bash -c 'source "$1"; persist_fixpr_wait_evidence' _ "$TMP_TEST/wait.sh"
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --get "$PR_NUMBER" | jq -e '.fixpr_wait.verdict.ci_failing==[]' >/dev/null
test -s "$TICK"
# Failed writes propagate a failure, never a silent clean result.
if HANDOFF_STATE_SH=/usr/bin/false bash -c 'source "$1"; persist_fixpr_wait_evidence' _ "$TMP_TEST/wait.sh"; then
  echo 'FAIL: failed wait evidence write returned success' >&2; exit 1
fi
if PR_NUMBER=999999 bash -c 'source "$1"; persist_fixpr_wait_evidence' _ "$TMP_TEST/wait.sh" 2>/dev/null; then
  echo 'FAIL: missing handoff returned success' >&2; exit 1
fi
for horizon in approaching unknown; do
  HORIZON_STATUS="$horizon" WATCH_IDLE_REASON="held: $horizon" WATCH_LAUNCH_OK=false WATCH_FINISH_OK=true \
    bash "$TMP_TEST/posture.sh" > "$TMP_TEST/stdout"
  test ! -s "$TMP_TEST/stdout"
  "$SESSION_STATE_SH" --get-json '.pmm.watch_posture' | jq -e --arg status "$horizon" '.status==$status and .reason==("held: "+$status) and .launch_allowed==false and .finish_allowed==true and (.observed_at|length>0)' >/dev/null
done
HORIZON_STATUS=clear WATCH_IDLE_REASON='' WATCH_LAUNCH_OK=true WATCH_FINISH_OK=true bash "$TMP_TEST/posture.sh"
"$SESSION_STATE_SH" --get-json '.pmm.watch_posture' | jq -e '.status=="clear" and .reason=="" and .launch_allowed==true' >/dev/null
if HORIZON_STATUS=unknown WATCH_IDLE_REASON=unreadable WATCH_LAUNCH_OK=false WATCH_FINISH_OK=true SESSION_STATE_SH=/usr/bin/false \
  bash "$TMP_TEST/posture.sh" 2>/dev/null; then
  echo 'FAIL: failed watch posture write returned success' >&2; exit 1
fi
"$SESSION_STATE_SH" --get-json '.repos["auerbachb/claude-code-config"].day' | jq -e '.==null' >/dev/null
WRAP_BLOCK=$(extract_skill_bash "$REPO_ROOT/.claude/skills/wrap/SKILL.md" wrap-persist-recovery-audit)
printf '%s\n' "$WRAP_BLOCK" > "$TMP_TEST/wrap.sh"
export WRAP_AUDIT_STATE_SH="$SESSION_STATE_SH" PR_NUM=1972 CURRENT_REPO="$OWNER_REPO"
export WRAP_RECOVERY_AUDIT=$'cycle 1: CI failed; retry "build"\ncycle 2: owner-only blocker remains'
export GATE_JSON='{"met":false,"missing":["human CHANGES_REQUESTED"],"head_sha":"abcdef123456"}'
CLAUDE_SESSION_REPO=example/other bash "$TMP_TEST/wrap.sh" > "$TMP_TEST/stdout"
test ! -s "$TMP_TEST/stdout"
"$SESSION_STATE_SH" --get-json '.prs["1972"].wrap_sweep.recovery_audit' | jq -e --arg cycles "$WRAP_RECOVERY_AUDIT" '.cycles==$cycles and .last_gate.met==false and .last_gate.missing==["human CHANGES_REQUESTED"] and (.observed_at|length>0)' >/dev/null
"$SESSION_STATE_SH" --repo example/other --get-json '.prs["1972"].wrap_sweep.recovery_audit' | jq -e '.==null' >/dev/null
if CURRENT_REPO='' bash "$TMP_TEST/wrap.sh" 2>/dev/null; then
  echo 'FAIL: missing verified repo returned success' >&2; exit 1
fi
# Later sweep bookkeeping cannot replace the recovery evidence.
"$SESSION_STATE_SH" --set '.prs["1972"].wrap_sweep.filed_issues=[]'
"$SESSION_STATE_SH" --get-json '.prs["1972"].wrap_sweep.recovery_audit' | jq -e '.last_gate.head_sha=="abcdef123456"' >/dev/null
if WRAP_AUDIT_STATE_SH=/usr/bin/false bash "$TMP_TEST/wrap.sh" 2>/dev/null; then
  echo 'FAIL: failed recovery-audit write returned success' >&2; exit 1
fi
printf '%s\n' 'PASS: quiet snapshots, hold reasons and recovery audit survive; failed writes stop; raw evidence and shared park preserved'
