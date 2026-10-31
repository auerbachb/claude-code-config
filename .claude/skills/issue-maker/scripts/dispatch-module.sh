#!/usr/bin/env bash
# Resolve the one issue-maker module required by the current operation phase.
# The caller reads only the emitted path; this script never reads module files.
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: dispatch-module.sh <operation> <phase>

Operations and phases:
  session  state
  create   reflect | increment-draft | dedup | file | crossrefs | postfile
  batch    chain
  update   edit
  retract  close
  export   prompt
  offer    handoff
  report   status

Output: one absolute module path relative to the installed skill root. Exit 2 means invalid input;
exit 3 means a required module is missing. The caller must not scan siblings.
HELP
}

[[ $# -eq 2 ]] || { usage >&2; exit 2; }
operation=$1
phase=$2
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
case "$operation:$phase" in
  session:state) relative='modules/session-state.md' ;;
  session:mode) relative='modules/session-mode.md' ;;
  create:reflect) relative='modules/create/reflect-and-draft.md' ;;
  create:increment-draft) relative='modules/create/increment-draft.md' ;;
  create:dedup) relative='modules/create/dedup.md' ;;
  create:file) relative='modules/create/file.md' ;;
  create:crossrefs) relative='modules/create/crossrefs.md' ;;
  create:postfile) relative='modules/create/postfile.md' ;;
  batch:chain) relative='modules/batch.md' ;;
  update:edit) relative='modules/update.md' ;;
  retract:close) relative='modules/retract.md' ;;
  offer:handoff) relative='modules/handoff.md' ;;
  report:status) relative='modules/create/postfile.md' ;;
  export:prompt) relative='modules/portable-prompt.md' ;;
  *) echo "dispatch-module.sh: unsupported operation/phase: $operation:$phase" >&2; exit 2 ;;
esac
path="$SKILL_ROOT/$relative"
[[ -r "$path" ]] || { echo "dispatch-module.sh: required module missing: $path" >&2; exit 3; }
printf '%s\n' "$path"
