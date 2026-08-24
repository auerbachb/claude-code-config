#!/usr/bin/env bash
# Offline tests for portable-handoff-context.sh (issue #1311).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/.claude/scripts/portable-handoff-context.sh"
TMP=$(mktemp -d)
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

passed=0
failed=0
check() {
  local name="$1"; shift
  if "$@"; then echo "ok   — $name"; passed=$((passed + 1));
  else echo "FAIL — $name"; failed=$((failed + 1)); fi
}

MAIN="$TMP/repository with spaces"
mkdir -p "$MAIN"
MAIN=$(cd "$MAIN" && pwd -P)
git init -q -b main "$MAIN"
git -C "$MAIN" config user.email test@example.com
git -C "$MAIN" config user.name Test
printf 'seed\n' >"$MAIN/tracked.txt"
git -C "$MAIN" add tracked.txt
git -C "$MAIN" commit -qm seed
git -C "$MAIN" remote add origin 'https://ghp_DO_NOT_LEAK@example.invalid/decoy.git'
git -C "$MAIN" remote set-url origin 'https://ghp_DO_NOT_LEAK@github.com/Test/Portable.git'
git -C "$MAIN" checkout -qb issue-1311-context
git -C "$MAIN" update-ref refs/remotes/origin/issue-1311-context HEAD
git -C "$MAIN" branch --set-upstream-to origin/issue-1311-context >/dev/null
printf 'changed\n' >>"$MAIN/tracked.txt"
printf 'new\n' >"$MAIN/untracked file.txt"

STATE="$TMP/session-state.json"
cat >"$STATE" <<'JSON'
{
  "repos": {
    "test/portable": {
      "background_tasks": [
        {
          "task_id": "task-42",
          "name": "review watcher token=super-secret-name",
          "type": "monitor",
          "session_id": "session-1",
          "status": "stopped",
          "work_item": "watch pull request 42 token=super-secret-value",
          "output_file": "/tmp/token=super-secret-output/review-output.txt",
          "checkpoint_path": "/tmp/api_key=super-secret-checkpoint/review-checkpoint.json",
          "recovery_path": "/tmp/password=super-secret-recovery/recover-review",
          "started_at": "2026-08-24T12:00:00Z",
          "updated_at": "2026-08-24T12:01:00Z"
        }
      ]
    },
    "_unknown": {
      "background_tasks": [
        {
          "task_id": "originless-task",
          "name": "local worker",
          "type": "agent",
          "session_id": "session-1",
          "status": "stopped",
          "recovery_path": "/tmp/originless-worktree",
          "started_at": "2026-08-24T12:00:00Z",
          "updated_at": "2026-08-24T12:01:00Z"
        }
      ]
    }
  }
}
JSON

DOC=$(CLAUDE_SESSION_STATE_FILE="$STATE" "$SUT" --cwd "$MAIN" --session session-1 --no-remote)
check "main checkout repository identity is sanitized" test "$(jq -r '.repository.identity' <<<"$DOC")" = test/portable
check "credential-bearing remote is never emitted" sh -c '! printf "%s" "$1" | grep -q ghp_DO_NOT_LEAK' _ "$DOC"
check "main checkout is classified" test "$(jq -r '.working_copy.condition' <<<"$DOC")" = "main worktree"
check "active checkout path is absolute and space-safe" test "$(jq -r '.working_copy.path' <<<"$DOC")" = "$MAIN"
check "full HEAD is recorded" sh -c 'printf "%s\n" "$1" | grep -Eq "^[0-9a-f]{40}$"' _ "$(jq -r '.working_copy.head' <<<"$DOC")"
check "tracking branch is recorded separately" test "$(jq -r '.working_copy.upstream' <<<"$DOC")" = origin/issue-1311-context
check "same-branch upstream is not invented as the merge base" test "$(jq -r '.working_copy.base_branch' <<<"$DOC")" = unknown
check "tracked dirt stays distinct" jq -e '.working_copy.tracked_changes == ["tracked.txt"]' >/dev/null <<<"$DOC"
check "untracked dirt stays distinct" jq -e '.working_copy.untracked_changes == ["untracked file.txt"]' >/dev/null <<<"$DOC"
check "exact issue branch token becomes a link" test "$(jq -r '.linkage.issue.url' <<<"$DOC")" = "https://github.com/test/portable/issues/1311"
check "terminal task metadata is preserved" jq -e '.background_tasks.items[0] | .task_id == "task-42" and .type == "monitor" and .status == "stopped"' >/dev/null <<<"$DOC"
check "task descriptions redact secret-shaped values" jq -e '.background_tasks.items[0].work_item == "watch pull request 42 [REDACTED]"' >/dev/null <<<"$DOC"
check "all task metadata strings redact secret-shaped values" jq -e '.background_tasks.items[0] | .name == "review watcher [REDACTED]" and .output_file == "/tmp/[REDACTED]" and .checkpoint_path == "/tmp/[REDACTED]" and .recovery_path == "/tmp/[REDACTED]"' >/dev/null <<<"$DOC"
check "raw task secrets are never emitted" sh -c '! printf "%s" "$1" | grep -q super-secret' _ "$DOC"

LINKED="$TMP/linked worktree"
git -C "$MAIN" worktree add -q -b issue-1311-linked "$LINKED" HEAD
LINKED=$(cd "$LINKED" && pwd -P)
LINKED_DOC=$(CLAUDE_SESSION_STATE_FILE="$STATE" "$SUT" --cwd "$LINKED" --session session-1 --no-remote)
check "linked checkout is classified" test "$(jq -r '.working_copy.condition' <<<"$LINKED_DOC")" = "linked worktree"
check "linked checkout records the main root" test "$(jq -r '.repository.root' <<<"$LINKED_DOC")" = "$MAIN"
check "linked checkout records its own path" test "$(jq -r '.working_copy.path' <<<"$LINKED_DOC")" = "$LINKED"

NON_REPO="$TMP/not a repository"
mkdir -p "$NON_REPO"
NON_REPO=$(cd "$NON_REPO" && pwd -P)
NON_DOC=$("$SUT" --cwd "$NON_REPO" --session session-1 --no-remote)
check "non-repository condition is explicit" test "$(jq -r '.working_copy.condition' <<<"$NON_DOC")" = "not a git checkout"
check "non-repository path remains useful" test "$(jq -r '.working_copy.path' <<<"$NON_DOC")" = "$NON_REPO"
check "non-repository metadata is honest" jq -e '.repository.identity == "unknown" and .working_copy.head == "unknown" and .background_tasks.items == []' >/dev/null <<<"$NON_DOC"

UNBORN="$TMP/unborn repository"
git init -q -b main "$UNBORN"
printf 'staged\n' >"$UNBORN/staged.txt"
git -C "$UNBORN" add staged.txt
UNBORN_DOC=$(CLAUDE_SESSION_STATE_FILE="$STATE" "$SUT" --cwd "$UNBORN" --session session-1 --no-remote)
check "unborn checkout keeps its initialized branch" test "$(jq -r '.working_copy.branch' <<<"$UNBORN_DOC")" = main
check "unborn checkout reports no commit" test "$(jq -r '.working_copy.head' <<<"$UNBORN_DOC")" = unknown
check "unborn checkout preserves staged tracked work" jq -e '.working_copy.tracked_changes == ["staged.txt"]' >/dev/null <<<"$UNBORN_DOC"
check "originless checkout preserves unknown-scope tasks" jq -e '.background_tasks.items[0] | .task_id == "originless-task" and .recovery_path == "/tmp/originless-worktree"' >/dev/null <<<"$UNBORN_DOC"

printf 'second\n' >"$MAIN/another-untracked.txt"
CAPPED=$(CLAUDE_HANDOFF_MAX_ITEMS=1 CLAUDE_SESSION_STATE_FILE="$STATE" "$SUT" --cwd "$MAIN" --session session-1 --no-remote)
check "dirty lists are bounded" jq -e '.working_copy.untracked_changes | length == 1' >/dev/null <<<"$CAPPED"
check "bounded lists retain the complete streaming count" jq -e '.working_copy.untracked_change_count == 2' >/dev/null <<<"$CAPPED"
check "truncation is reported" jq -e '.working_copy.lists_truncated == true' >/dev/null <<<"$CAPPED"

printf '\npassed: %d   failed: %d\n' "$passed" "$failed"
(( failed == 0 ))
