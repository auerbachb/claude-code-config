#!/usr/bin/env bash
# Integration tests for stale-worktree-warn.sh (issue #411).
# Builds a temp repo with two linked worktrees; does not modify the real repo.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/stale-worktree-warn.sh"

hook_payload() {
  local cwd="$1"
  local prompt="$2"
  python3 -c "import json,sys; print(json.dumps({'cwd': sys.argv[1], 'prompt': sys.argv[2]}))" "$cwd" "$prompt" | "$HOOK"
}

additional_context() {
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('hookSpecificOutput',{}).get('additionalContext',''))"
}

TMP_BASE="$(mktemp -d)"
cleanup() { rm -rf "$TMP_BASE"; }
trap cleanup EXIT

BARE="$TMP_BASE/bare.git"
MAIN_WT="$TMP_BASE/main-wt"
LINKED="$TMP_BASE/linked-wt"
CLAUDE_WT="$TMP_BASE/claude-wt"

git init --bare "$BARE" >/dev/null
git clone "$BARE" "$MAIN_WT" >/dev/null
git -C "$MAIN_WT" config user.email "test@example.com"
git -C "$MAIN_WT" config user.name "Test"
echo test >"$MAIN_WT/README.md"
git -C "$MAIN_WT" add README.md
git -C "$MAIN_WT" commit -m init >/dev/null
git -C "$MAIN_WT" push origin HEAD:main >/dev/null

git -C "$MAIN_WT" worktree add -b issue-424-demo "$LINKED" >/dev/null
git -C "$MAIN_WT" worktree add -b claude/xenodochial-brahmagupta-fce5a4 "$CLAUDE_WT" >/dev/null

fail() { echo "FAIL: $*" >&2; exit 1; }

# Linked worktree + issue branch + prompt same issue -> no warning
out="$(hook_payload "$LINKED" 'Fix for #424')"
ctx="$(echo "$out" | additional_context)"
[[ -z "$ctx" ]] || fail "expected no warning on issue-424 branch with #424 prompt, got: $out"

# Linked worktree + issue branch + prompt different issue -> warning
out="$(hook_payload "$LINKED" 'Work on issue #411')"
ctx="$(echo "$out" | additional_context)"
[[ -n "$ctx" ]] || fail "expected warning on issue-424 branch with #411 prompt"
echo "$ctx" | grep -q "issue #424" || fail "message should mention branch issue: $ctx"
echo "$ctx" | grep -q "issue #411" || fail "message should mention prompt issue: $ctx"

# SDK-style claude/* branch + prompt with issue -> no false positive (no issue token in branch)
out="$(hook_payload "$CLAUDE_WT" 'Implement #424 acceptance criteria')"
ctx="$(echo "$out" | additional_context)"
[[ -z "$ctx" ]] || fail "expected no warning on claude/* branch without issue token, got: $ctx"

# Non-issue branch (not claude/*) + prompt issue -> still warn
git -C "$MAIN_WT" worktree add -b feature/misc "$TMP_BASE/misc-wt" >/dev/null
out="$(hook_payload "$TMP_BASE/misc-wt" 'See #424')"
ctx="$(echo "$out" | additional_context)"
[[ -n "$ctx" ]] || fail "expected warning on feature/misc with #424 prompt"

echo "OK: stale-worktree-warn integration tests passed"
