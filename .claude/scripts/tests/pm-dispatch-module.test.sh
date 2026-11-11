#!/usr/bin/env bash
# catalog: tests — Checks path-only PM day module resolution and installed-first discovery.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
skill="$root/.claude/skills/pm"
dispatcher="$skill/scripts/dispatch-module.sh"
source "$root/.claude/scripts/tests/lib/skill-bash.sh"
resolver=$(extract_skill_bash "$skill/SKILL.md" pm-day-module-resolver)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/pm-day-module-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

for phase in preconditions arm tick teardown recovery park-reactive park-preemptive probe-wake; do
  expected=$phase
  [[ "$phase" != probe-wake ]] || expected=park-preemptive
  chosen=$("$BASH" "$dispatcher" day "$phase")
  [[ "$chosen" == "$skill/modules/day-$expected.md" && -f "$chosen" ]]
done

status=0
"$BASH" "$dispatcher" day '../tick' > "$scratch/out" 2> "$scratch/error" || status=$?
[[ "$status" == 2 && ! -s "$scratch/out" && -s "$scratch/error" ]]

mkdir -p "$scratch/partial/scripts" "$scratch/partial/modules"
cp "$dispatcher" "$scratch/partial/scripts/"
status=0
"$BASH" "$scratch/partial/scripts/dispatch-module.sh" day tick > "$scratch/out" 2> "$scratch/error" || status=$?
[[ "$status" == 3 && ! -s "$scratch/out" ]]
grep -Fq 'required module unreadable:' "$scratch/error"

mkdir -p "$scratch/home/.claude/skills-worktree/.claude/skills" "$scratch/project"
ln -s "$skill" "$scratch/home/.claude/skills-worktree/.claude/skills/pm"
trace="$resolver"$'\nprintf "%s\\n" "$PM_DAY_DISPATCH"\n'
selected=$(cd "$scratch/project" && HOME="$scratch/home" "$BASH" -eu -c "$trace")
[[ "$selected" == "$scratch/home/.claude/skills-worktree/.claude/skills/pm/scripts/dispatch-module.sh" ]]
[[ "$("$BASH" "$selected" day tick)" == "$skill/modules/day-tick.md" ]]
selected=$(cd "$root" && env -u HOME "$BASH" -eu -c "$trace")
[[ "$selected" == '.claude/skills/pm/scripts/dispatch-module.sh' ]]

grep -Fq 'Ordinary cold start and resume without day state read no day modules.' "$skill/SKILL.md"
! grep -qE '^### 2D\.[1-7]:' "$skill/SKILL.md"
printf '%s\n' 'PM module routes: 8 paths, invalid/missing guards, installed symlink and unset-HOME fallback'
