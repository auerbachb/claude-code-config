#!/usr/bin/env bash
# Return the one module path for the selected /go-on lane and phase.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf '%s\n' \
    'Usage: dispatch-module.sh kind planned-stop|usage-limit-park|token-exhaustion|unplanned' \
    '       dispatch-module.sh review prepare|publish|respond|merge' >&2
  exit 2
fi

case "$1:$2" in
  kind:planned-stop) module=kinds/planned-stop.md ;;
  kind:usage-limit-park) module=kinds/usage-limit-park.md ;;
  kind:token-exhaustion) module=kinds/token-exhaustion.md ;;
  kind:unplanned) module=kinds/unplanned.md ;;
  review:prepare) module=review/prepare.md ;;
  review:publish) module=review/publish.md ;;
  review:respond) module=review/respond.md ;;
  review:merge) module=review/merge.md ;;
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
