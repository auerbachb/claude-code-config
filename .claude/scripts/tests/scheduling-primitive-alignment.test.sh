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
require_text .claude/skills/babysit-pr-stop/SKILL.md 'keep `active=true`' \
  'babysit-pr-stop must block duplicate arming until exact teardown succeeds'
require_text .claude/skills/babysit-pr-stop/SKILL.md \
  'last_cron_action={\"type\":\"delete\",\"interval\":\"paused\"' \
  'babysit-pr-stop must suppress stale polling-backoff guidance after exact teardown'
require_text .claude/skills/babysit-pr/SKILL.md 'refuses re-arm regardless of tick age' \
  'babysit-pr stale reclaim must not reopen an incomplete teardown'
require_text .claude/skills/babysit-pr/SKILL.md \
  'a stale reclaim **must stop the exact `$RETAINED_TASK_ID` with `TaskStop`**' \
  'babysit-pr stale reclaim must stop the identified silent Monitor before re-arming'
require_text .claude/skills/babysit-pr/SKILL.md \
  'Before comparing cadences, read the exact' \
  'babysit-pr must validate Monitor identity even when the cadence is unchanged'
require_text .claude/skills/babysit-pr/SKILL.md 'If that task-ID publication fails' \
  'babysit-pr initial Monitor arm must handle task-ID publication failure'
require_text .claude/skills/babysit-pr/SKILL.md \
  'if (( STREAK >= 3 )); then EFFECTIVE_MIN=$WIDE_MIN; else EFFECTIVE_MIN=$BASE_MIN; fi' \
  'babysit-pr must derive the effective cadence before persisting or re-arming it'
require_text .claude/skills/babysit-pr/SKILL.md \
  'monitor_task_id=$NEW_MONITOR_TASK_ID' \
  'babysit-pr must publish replacement identity with its effective cadence'
require_text .claude/skills/babysit-pr/SKILL.md \
  '--monitor-generation $MONITOR_GENERATION' \
  'babysit-pr Monitor events must carry their arm generation'
require_text .claude/skills/babysit-pr/SKILL.md \
  '"$TICK_GENERATION" != "$RECORDED_GENERATION"' \
  'babysit-pr must reject queued events from an older Monitor generation'
require_text .claude/skills/babysit-pr/SKILL.md \
  'TICK_GENERATION="$_BABYSIT_ARG"' \
  'babysit-pr must parse the generation carried by Monitor-emitted ticks'
require_text .claude/skills/babysit-pr/SKILL.md \
  'if [[ "$BABYSIT_INTERNAL_TICK" == true ]]; then' \
  'babysit-pr must apply generation validation to the parsed internal tick mode'
require_text .claude/skills/babysit-pr/SKILL.md \
  'babysit.monitor_generation=\"$NEW_MONITOR_GENERATION\"' \
  'babysit-pr must publish replacement task ID and generation together'
require_text .claude/skills/babysit-pr/SKILL.md \
  'Before that stop, atomically set `stop_requested=true`' \
  'babysit-pr cadence re-arm must guard against queued old-generation events before TaskStop'
require_text .claude/skills/babysit-pr/SKILL.md \
  'known-stopped old identity and set `active=false`, `stop_requested=false`' \
  'babysit-pr must clear its cadence guard after verified rollback teardown'
require_text .claude/skills/babysit-pr/SKILL.md \
  'TASK_STOP_SUCCEEDED=true only when that exact tool call succeeds' \
  'babysit-pr stale reclaim must execute exact TaskStop before A3 overwrites identity'
require_text .claude/hooks/polling-backoff-warn.sh \
  'atomically clear its monitor_task_id + monitor_generation only after success' \
  'backoff stop guidance must clear the Monitor identity pair atomically'
require_text .claude/hooks/polling-backoff-warn.sh \
  'atomically persist the new monitor_task_id + monitor_generation + effective cadence' \
  'backoff widen guidance must publish replacement identity and cadence atomically'

require_text .claude/skills/pr-monitor-and-manage/SKILL.md '.pmm_monitor_task_id' \
  'fleet monitoring must persist its main Monitor task ID'
reject_text .claude/skills/pr-monitor-and-manage/SKILL.md '$SESSION_STATE_SH" --get' \
  'fleet monitoring must not use an undefined state-helper variable'
require_text .claude/skills/pr-monitor-and-manage/references/pmm-lifecycle.md \
  '.pmm.auto_wake_monitor_task_id' \
  'fleet auto-wake must persist its Monitor task ID'
require_text .claude/skills/pr-monitor-and-manage-wake/SKILL.md \
  'successfully stopped ID and generation immediately' \
  'fleet resume retries must not retain IDs for already-stopped tasks'
require_text .claude/skills/pr-monitor-and-manage-wake/SKILL.md \
  'retain that failed identity pair' \
  'fleet resume must abort with a potentially-live failed task ID retained'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  'Ignoring a queued Monitor tick after pause/stop' \
  'fleet Monitor ticks must not restart after pause or stop'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  '/pr-monitor-and-manage --tick --monitor-generation $NEW_MONITOR_GENERATION <original user args>' \
  'fleet Monitor events must be distinguishable from direct user starts'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  "RECORDED_MONITOR_GENERATION=\$(.claude/scripts/session-state.sh --get '.pmm_monitor_generation'" \
  'fleet ticks must read the currently published Monitor generation'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  '"$PMM_TICK_GENERATION" != "$RECORDED_MONITOR_GENERATION"' \
  'fleet ticks must reject queued events from an older Monitor generation'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  'PMM_TICK_GENERATION="$_PMM_ARG"' \
  'fleet ticks must parse the generation carried by Monitor-emitted events'
require_text .claude/skills/pr-monitor-and-manage-stop/SKILL.md \
  'marker until exact teardown is complete.' \
  'fleet stop must block start/resume until every required task is stopped'
require_text .claude/skills/pr-monitor-and-manage-stop/SKILL.md \
  'Never treat a second' \
  'fleet stop retry must not forget an unrecorded task after publishing inactive'
require_text .claude/skills/pr-monitor-and-manage-wake/SKILL.md \
  'If `$STOP_PENDING` is `true`' \
  'fleet wake must refuse an incomplete stop transaction'
require_text .claude/skills/pr-monitor-and-manage/references/pmm-lifecycle.md \
  'Publishing inactive' \
  'fleet pause must make queued ticks inert before exact teardown'
require_text .claude/skills/pr-monitor-and-manage/references/pmm-lifecycle.md \
  'leave the pause marker intact' \
  'direct PMM resume must publish state transactionally'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  'treat the prior digest values as null in shell' \
  'direct PMM resume must render its first table without clearing durable state early'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  'A failed stop retains the old ID and aborts the re-arm.' \
  'fleet cadence re-arm must fail closed on exact TaskStop'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  'first set `.pmm.stop_requested=true`' \
  'fleet cadence re-arm must guard against queued old-generation events before TaskStop'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  'known-stopped old identity and set `pmm_active=false`, `.pmm.stop_requested=false`' \
  'fleet cadence re-arm must clear its guard after verified rollback teardown'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  "CURRENT_MONITOR_CADENCE=\$(.claude/scripts/session-state.sh --get '.pmm_cadence'" \
  'fleet monitoring must compare the recorded Monitor cadence before deciding to keep it'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  'Keep the existing task only when both pieces of its recorded identity are present and its cadence' \
  'fleet monitoring must replace an existing Monitor on a tier crossing'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  'A missing ID or generation' \
  'fleet monitoring must not arm beside an active task whose identity was lost'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  'This guard runs even' \
  'fleet monitoring must validate task identity before empty/idle pause routing'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  'WIDE_CADENCE_MIN=$(( BASE_CADENCE_MIN * 3 ))' \
  'fleet monitoring backoff must derive its widened cadence from the configured base'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  'Stable-state freeze** — `STREAK >= 9` → **Pause**' \
  'fleet monitoring must stop its Monitor at the shared stable-state ceiling'
reject_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  'then EFFECTIVE_CADENCE="15m"' \
  'fleet monitoring must not hard-code a widened cadence that can be faster than the base'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  'pmm_monitor_generation=\"$MONITOR_GENERATION\"' \
  'fleet monitoring must publish its task ID and generation together'
require_text .claude/skills/pr-monitor-and-manage/SKILL.md \
  'MONITOR_GENERATION="$NEW_MONITOR_GENERATION"' \
  'fleet monitoring must publish the generation embedded in the newly armed task'
require_text .claude/skills/pr-monitor-and-manage-wake/SKILL.md \
  'with `.pmm.auto_wake_monitor_generation`' \
  'auto-wake must reject queued events from an older re-scan generation'
require_text .claude/skills/pr-monitor-and-manage-wake/SKILL.md \
  'AUTO_CHECK_GENERATION="$_WAKE_ARG"' \
  'auto-wake must parse the generation carried by Monitor-emitted scans'
require_text .claude/skills/pr-monitor-and-manage-wake/SKILL.md \
  '"$AUTO_CHECK_GENERATION" != "$RECORDED_AUTO_CHECK_GENERATION"' \
  'auto-wake must execute its stale-generation comparison before scanning the fleet'
require_text .claude/skills/pr-monitor-and-manage/references/pmm-lifecycle.md \
  '/pr-monitor-and-manage-wake --auto-check --monitor-generation $AUTO_WAKE_MONITOR_GENERATION' \
  'auto-wake Monitor events must carry their arm generation'
require_text .claude/skills/wrap/SKILL.md \
  'monitor_task_id=null`, and `monitor_generation=null`' \
  'wrap must clear the complete babysit Monitor identity after exact teardown'

require_text .claude/reference/session-state-schema.json '"monitoring_mode": "monitor"' \
  'session-state examples must identify Monitor as the recurring polling primitive'
require_text .claude/reference/session-state-schema.json '"action": "MonitorRearm"' \
  'session-state backoff examples must not describe removed CronUpdate actions'
require_text .claude/reference/session-state-schema.json '"action": "TaskStop"' \
  'session-state stop examples must use exact Monitor teardown'
require_text .claude/reference/session-state-schema.json '"monitor_generation": "babysit-generation-619"' \
  'session-state examples must document babysit Monitor generations'
require_text .claude/reference/session-state-schema.json '"pmm_monitor_generation": null' \
  'session-state examples must document main fleet Monitor generations'
require_text .claude/reference/session-state-schema.json '"auto_wake_monitor_generation": null' \
  'session-state examples must document auto-wake Monitor generations'
require_text .claude/reference/session-state-schema.json \
  'auto_wake_monitor_task_id and auto_wake_monitor_generation are one runtime identity pair' \
  'session-state docs must define auto-wake task ID and generation as one identity'

ok 'recurring scheduling guidance and watcher lifecycles agree on Monitor'
