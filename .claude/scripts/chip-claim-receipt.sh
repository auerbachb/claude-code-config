#!/usr/bin/env bash
# catalog: session-state-locking — Save or recover an acquired Form A claim in its assigned Git worktree
#
# Usage:
#   chip-claim-receipt.sh save WORKTREE OWNER/REPO ISSUE HOLDER < claim-result.json
#   chip-claim-receipt.sh read WORKTREE OWNER/REPO ISSUE
#
# Only a fresh launch saves, from its own successful --claim --json result.
# Only a known resumed launch reads, from its own assigned worktree. A read
# recovers the holder; the caller must still run issue-claim.sh --renew.
# No GitHub calls, discovery of other worktrees, or fallback to a remote marker.
set -euo pipefail
umask 077

fail() {
  printf 'chip-claim-receipt: %s\n' "$1" >&2
  exit 4
}

[[ $# -ge 4 ]] || fail 'expected save/read WORKTREE OWNER/REPO ISSUE [HOLDER]'
action=$1
repo=$3
issue=$4
case "$action:$#" in save:5|read:4) ;; *) fail 'invalid action or arguments' ;; esac
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue" =~ ^[1-9][0-9]*$ ]] ||
  fail 'invalid repository or issue'

worktree=$(cd -- "$2" && pwd -P) || fail 'cannot locate assigned worktree'
[[ -f "$worktree/.git" && ! -L "$worktree/.git" ]] || fail 'expected a linked worktree root'
git_dir=$(git -C "$worktree" rev-parse --absolute-git-dir) || fail 'cannot resolve worktree Git directory'
git_dir=$(cd -- "$git_dir" && pwd -P) || fail 'cannot locate worktree Git directory'
common=$(git -C "$worktree" rev-parse --git-common-dir) || fail 'cannot resolve common Git directory'
common=$(cd -- "$worktree" && cd -- "$common" && pwd -P) || fail 'cannot locate common Git directory'
[[ "${git_dir%/*}" == "$common/worktrees" && -f "$git_dir/gitdir" && ! -L "$git_dir/gitdir" ]] ||
  fail 'not a registered linked worktree'
IFS= read -r backlink < "$git_dir/gitdir" || fail 'cannot read worktree registration'
[[ "$backlink" == */.git ]] || fail 'invalid worktree registration'
case "$backlink" in /*) ;; *) backlink="$git_dir/$backlink" ;; esac
backlink_dir=$(cd -- "${backlink%/*}" && pwd -P) || fail 'cannot locate registered worktree'
[[ "$backlink_dir" == "$worktree" ]] || fail 'worktree registration does not match'
branch=$(git -C "$worktree" symbolic-ref -q HEAD) || fail 'expected a named work branch'
case "$branch" in refs/heads/main|refs/heads/master) fail 'expected a separate work branch' ;; esac
receipt="$git_dir/claude-chip-claim.json"

read_receipt() {
  [[ -f "$receipt" && ! -L "$receipt" && -O "$receipt" ]] || return 1
  jq -ers --arg w "$worktree" --arg b "$branch" --arg r "$repo" --argjson n "$issue" '
    select(length == 1) | .[0] |
    select(.worktree == $w and .branch == $b and .repo == $r and .issue == $n) |
    .holder | select(type == "string" and test("^chip:[A-Za-z0-9_.-]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+$"))
  ' "$receipt"
}

if [[ "$action" == read ]]; then
  read_receipt || fail 'missing or invalid receipt for this worktree, branch, repo and issue'
  exit 0
fi

holder=$5
[[ "$holder" =~ ^chip:[A-Za-z0-9_.-]+:[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]] ||
  fail 'invalid launch holder'
jq -es --arg h "$holder" --arg r "$repo" --argjson n "$issue" '
  length == 1 and (.[0] | .issue == $n and .repo == $r and .verdict == "mine" and
    .holder == $h and .claimant_holder == $h)
' >/dev/null || fail 'claim result does not match this launch'

if [[ -e "$receipt" || -L "$receipt" ]]; then
  existing=$(read_receipt) && [[ "$existing" == "$holder" ]] ||
    fail 'refusing to replace an existing receipt'
  exit 0
fi

tmp=$(mktemp "$git_dir/.claude-chip-claim.XXXXXXXX") || fail 'cannot create private receipt'
trap 'rm -f -- "$tmp"' EXIT
jq -n --arg w "$worktree" --arg b "$branch" --arg r "$repo" --argjson n "$issue" --arg h "$holder" '
  {worktree: $w, branch: $b, repo: $r, issue: $n, holder: $h}
' > "$tmp"
# Link the complete file into place without overwriting another launch's receipt.
ln -n -- "$tmp" "$receipt" || fail 'could not install receipt without replacing an existing file'
