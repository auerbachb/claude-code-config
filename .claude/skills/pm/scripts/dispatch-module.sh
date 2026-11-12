#!/usr/bin/env bash
# Return the one module path for the selected PM operation and phase.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf '%s\n' \
    'Usage: dispatch-module.sh day preconditions|arm|tick|teardown|recovery|park-reactive|park-preemptive|probe-wake' \
    '       dispatch-module.sh resume load|fetch|present' \
    '       dispatch-module.sh rank load|fetch|score|present' \
    '       dispatch-module.sh shared priority|window-fit|ownership' \
    '       dispatch-module.sh flow cleanup|forgotten-prs|monitor|launch|track|progress|refill|handoff' >&2
  exit 2
fi

case "$1:$2" in
  day:preconditions) module=day-preconditions.md ;;
  day:arm) module=day-arm.md ;;
  day:tick) module=day-tick.md ;;
  day:teardown) module=day-teardown.md ;;
  day:recovery) module=day-recovery.md ;;
  day:park-reactive) module=day-park-reactive.md ;;
  day:park-preemptive|day:probe-wake) module=day-park-preemptive.md ;;
  resume:load) module=resume/load.md ;;
  resume:fetch) module=resume/fetch.md ;;
  resume:present) module=resume/present.md ;;
  rank:load) module=rank/load.md ;;
  rank:fetch) module=rank/fetch.md ;;
  rank:score) module=rank/score.md ;;
  rank:present) module=rank/present.md ;;
  shared:priority) module=shared/priority.md ;;
  shared:window-fit) module=shared/window-fit.md ;;
  shared:ownership) module=shared/ownership.md ;;
  flow:cleanup) module=flow/cleanup.md ;;
  flow:forgotten-prs) module=flow/forgotten-prs.md ;;
  flow:monitor) module=flow/monitor.md ;;
  flow:launch) module=flow/launch.md ;;
  flow:track) module=flow/track.md ;;
  flow:progress) module=flow/progress.md ;;
  flow:refill) module=flow/refill.md ;;
  flow:handoff) module=flow/handoff.md ;;
  *) printf 'dispatch-module.sh: unsupported operation/phase: %s:%s\n' "$1" "$2" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
module_path="$SKILL_ROOT/modules/$module"
module_dir=${module_path%/*}
physical_dir=$(cd -- "$module_dir" 2>/dev/null && pwd -P) || physical_dir=""
if [[ "$physical_dir" != "$module_dir" || -L "$module_path" || ! -f "$module_path" || ! -r "$module_path" ]]; then
  printf 'dispatch-module.sh: required module unreadable: %s\n' "$module_path" >&2
  exit 3
fi
printf '%s\n' "$module_path"
