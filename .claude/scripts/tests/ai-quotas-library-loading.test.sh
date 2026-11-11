#!/usr/bin/env bash
# catalog: tests — Verifies quota reader library loading through installed symlinks and fails closed on a missing or broken library.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
RUNTIME="$FIXTURE/runtime with spaces"
TEST_HOME="$FIXTURE/home"
mkdir -p "$RUNTIME/.claude/scripts" "$TEST_HOME/.claude/scripts" "$FIXTURE/links"

# Copy the entry and its siblings so the negative controls cannot change the
# real checkout or the installed skills. Both symlink forms share this copy.
cp "$SCRIPTS"/ai-quotas.sh "$SCRIPTS"/quotas-{cheapest-next,forecast}.sh "$RUNTIME/.claude/scripts/"
cp -R "$SCRIPTS/lib" "$RUNTIME/.claude/scripts/"
ln -s "$RUNTIME" "$TEST_HOME/.claude/skills-worktree"
ln -s "$RUNTIME/.claude/scripts/ai-quotas.sh" "$FIXTURE/links/ai-quotas.sh"
ln -s ../../../links/ai-quotas.sh "$TEST_HOME/.claude/scripts/ai-quotas.sh"

export HOME="$TEST_HOME"
export AI_QUOTAS_CONFIG="$FIXTURE/accounts.json"
export AI_QUOTAS_HISTORY="$FIXTURE/history.jsonl"
export AI_QUOTAS_NOW=1794390000
export AI_QUOTAS_CLAUDE_VERSION=1.0.0
printf '%s\n' '{"schema_version":"1.0","accounts":[]}' > "$AI_QUOTAS_CONFIG"
cd "$FIXTURE"
DIRECT="$RUNTIME/.claude/scripts/ai-quotas.sh"
INSTALLED="$TEST_HOME/.claude/scripts/ai-quotas.sh"
WORKTREE="$TEST_HOME/.claude/skills-worktree/.claude/scripts/ai-quotas.sh"

"$BASH" "$DIRECT" --json > direct.out 2> direct.err
jq -e '.rows == []' direct.out >/dev/null
"$BASH" "$DIRECT" --help > direct.help
for reader in "$INSTALLED" "$WORKTREE"; do
  "$BASH" "$reader" --json > linked.out 2> linked.err
  cmp direct.out linked.out
  cmp direct.err linked.err
  "$BASH" "$reader" --help > linked.help
  cmp direct.help linked.help
done
printf '%s\n' 'PASS: both installed symlink layouts preserve stdout, stderr and help'

# An invalid registry shows the library guard runs before account acquisition.
printf '%s\n' 'broken registry' > "$AI_QUOTAS_CONFIG"
assert_load_failure() {
  local reader="$1" name="$2" result=0
  "$BASH" "$reader" --json > failed.out 2> failed.err || result=$?
  [[ "$result" -eq 5 && ! -s failed.out ]]
  grep -Fxq "ai-quotas.sh: required quota library could not load: lib/$name" failed.err
}

for module in claude codex cursor forecast report; do
  library="ai-quotas-$module.sh"
  path="$RUNTIME/.claude/scripts/lib/$library"
  mv "$path" "$path.saved"
  assert_load_failure "$INSTALLED" "$library"
  assert_load_failure "$WORKTREE" "$library"
  "$BASH" "$INSTALLED" --help > linked.help
  cmp direct.help linked.help
  mv "$path.saved" "$path"
done
printf '%s\n' 'PASS: every missing module fails before acquisition on both paths and help still works'

library=ai-quotas-forecast.sh
printf '%s\n' 'unfinished() {' > "$RUNTIME/.claude/scripts/lib/$library"
assert_load_failure "$INSTALLED" "$library"
printf '%s\n' 'PASS: a library that cannot be sourced fails closed'
