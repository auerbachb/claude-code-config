#!/usr/bin/env bash
# Regression coverage for Issue #924: recurring polls use Monitor end to end.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok   — %s\n' "$*"; }

require_text() {
  local file=$1 text=$2 message=$3
  grep -Fq -- "$text" "$ROOT/$file" || fail "$message"
}

reject_text() {
  local file=$1 text=$2 message=$3
  if grep -Fq -- "$text" "$ROOT/$file"; then
    fail "$message"
  fi
}

require_text CLAUDE.md '**`Monitor` for recurring polls.**' \
  'CLAUDE.md must route recurring polls to Monitor'
require_text .claude/rules/scheduling-reliability.md \
  '> **Always:** Use a persistent `Monitor` for user-facing "poll every N" requests' \
  'the scheduling rule must make Monitor authoritative'
require_text .claude/reference/scheduling-failure-modes.md \
  '| dynamic `/loop` / recurring `ScheduleWakeup` | PR #937 and PR #944 stopped until a manual turn | **negative** |' \
  'Pattern 7 must preserve the negative dynamic-loop evidence'
require_text .claude/reference/scheduling-failure-modes.md \
  '| persistent `Monitor` | The silence ceiling fired out of turn during the #914 controlled probe | **positive** |' \
  'Pattern 7 must preserve the positive Monitor evidence'

require_text .claude/skills/babysit-pr/SKILL.md 'babysit.monitor_task_id' \
  'babysit-pr must persist its Monitor task ID'
require_text .claude/skills/babysit-pr/SKILL.md 'stop the exact current Monitor' \
  'babysit-pr cadence changes must stop the prior Monitor'
require_text .claude/skills/babysit-pr/SKILL.md 'Run that atomic cleanup only after `TaskStop` succeeds.' \
  'babysit-pr terminal cleanup must retain a failed Monitor task ID'
reject_text .claude/skills/babysit-pr/SKILL.md 'arm_loop ' \
  'babysit-pr must not retain the dynamic-loop arm path'
require_text .claude/skills/babysit-pr-stop/SKILL.md 'call `TaskStop` for that exact task' \
  'babysit-pr-stop must stop the recorded Monitor task'

require_text .claude/skills/pr-monitor-and-manage/SKILL.md '.pmm_monitor_task_id' \
  'fleet monitoring must persist its main Monitor task ID'
reject_text .claude/skills/pr-monitor-and-manage/SKILL.md '$SESSION_STATE_SH" --get' \
  'fleet monitoring must not use an undefined state-helper variable'
require_text .claude/skills/pr-monitor-and-manage/references/pmm-lifecycle.md \
  '.pmm.auto_wake_monitor_task_id' \
  'fleet auto-wake must persist its Monitor task ID'
require_text .claude/skills/pr-monitor-and-manage-wake/SKILL.md \
  'If either present ID cannot be stopped, abort the resume' \
  'fleet resume must abort when the recorded auto-wake task cannot be stopped'
require_text .claude/skills/pr-monitor-and-manage/references/pmm-lifecycle.md \
  'leave the pause marker intact' \
  'direct PMM resume must publish state transactionally'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  'treat the prior digest values as null in shell' \
  'direct PMM resume must render its first table without clearing durable state early'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  'A failed stop retains the old ID and aborts the re-arm.' \
  'fleet cadence re-arm must fail closed on exact TaskStop'

ok 'recurring scheduling guidance and watcher lifecycles agree on Monitor'
