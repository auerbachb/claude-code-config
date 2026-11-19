#!/usr/bin/env bash
# catalog: backlog-pm — Publish a private read-only project board from verified PM evidence.
set -euo pipefail

# Resolve file symlinks as well as installed directory symlinks.
source_path="${BASH_SOURCE[0]}"
links=0
while [[ -L "$source_path" ]]; do
  links=$((links + 1))
  if (( links > 40 )); then
    printf '%s\n' 'pm-board-page: too many script symlinks' >&2
    exit 2
  fi
  source_dir="$(cd -P "$(dirname "$source_path")" && pwd -P)"
  source_path="$(readlink "$source_path")"
  [[ "$source_path" == /* ]] || source_path="$source_dir/$source_path"
done
source_dir="$(cd -P "$(dirname "$source_path")" && pwd -P)"
exec python3 "$source_dir/lib/pm-board-page.py" "$@"
