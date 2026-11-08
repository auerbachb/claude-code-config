#!/usr/bin/env bash
# catalog: trust-worktree-repo — Validate an explicit physical clone binding against a GitHub PR URL before post-merge mutations
# Read-only: missing/invalid bindings never fall back to the current directory.
# Exit 0 prints the physical main-worktree root; 1 invalid/mismatched binding;
# 2 usage; 3 timeout; 4 required helper/read unavailable.
set -uo pipefail
repo_path=""; pr_url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-path|--pr-url)
      [[ $# -ge 2 ]] || exit 2
      case "$1" in --repo-path) repo_path="$2" ;; --pr-url) pr_url="$2" ;; esac
      shift 2 ;;
    --help|-h)
      echo 'Usage: merge-target-root.sh --repo-path ABSOLUTE_PATH --pr-url https://HOST/OWNER/REPO/pull/N'
      exit 0 ;;
    *) exit 2 ;;
  esac
done
refuse() { echo "merge-target-root: $1; local mutation skipped" >&2; exit "${2:-1}"; }
[[ "$repo_path" == /* && "$repo_path" != *$'\n'* && -d "$repo_path" ]] || refuse 'explicit clone path missing or invalid'
if [[ "$pr_url" =~ ^https://([A-Za-z0-9.-]+)/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)$ ]]; then
  expected_host="${BASH_REMATCH[1]}"
  expected_repo="${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
else
  refuse 'canonical PR URL missing or invalid'
fi
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 4
[[ -x "$script_dir/repo-root.sh" && -r "$script_dir/lib/bounded-run.sh" ]] || refuse 'required root/bound helper unavailable' 4
root_rc=0
root=$("$script_dir/repo-root.sh" "$repo_path" 2>/dev/null) || root_rc=$?
[[ "$root_rc" -eq 0 ]] || refuse 'explicit clone root could not be resolved' "$root_rc"
[[ "$root" == /* && "$root" != *$'\n'* && -d "$root" ]] || refuse 'resolved clone root missing or invalid'
root=$(cd "$root" && pwd -P) || refuse 'physical clone root unreadable' 4
CAPTURE=""; CAPTURE_ERR=""
cleanup() {
  [[ -z "$CAPTURE" ]] || rm -f "$CAPTURE"
  [[ -z "$CAPTURE_ERR" ]] || rm -f "$CAPTURE_ERR"
}
trap cleanup EXIT
CAPTURE=$(mktemp "${TMPDIR:-/tmp}/merge-target-out.XXXXXX") || refuse 'capture unavailable' 4
CAPTURE_ERR=$(mktemp "${TMPDIR:-/tmp}/merge-target-err.XXXXXX") || refuse 'capture unavailable' 4
# shellcheck source=lib/bounded-run.sh
source "$script_dir/lib/bounded-run.sh"
BOUNDED_REQUIRE_OUTPUT=1
rc=0
run_bounded 10 git -C "$root" remote get-url origin || rc=$?
[[ "$BOUNDED_TIMED_OUT" -eq 0 ]] || refuse 'clone identity read timed out' 3
[[ "$rc" -eq 0 ]] || refuse 'clone identity unreadable' 4
remote=$(cat "$CAPTURE") || refuse 'clone identity capture unreadable' 4
[[ "$remote" != *$'\n'* ]] || refuse 'ambiguous clone identity'
# Accept ordinary URL and scp-style Git remotes, without printing credentials.
case "$remote" in
  https://*|http://*|ssh://*|git://*)
    address="${remote#*://}"; address="${address##*@}"
    host="${address%%/*}"; remote_repo="${address#*/}"
    host="${host%%:*}" ;;
  *@*:*|*:*/*)
    address="${remote##*@}"; host="${address%%:*}"; remote_repo="${address#*:}" ;;
  *) refuse 'unsupported clone remote identity' ;;
esac
remote_repo="${remote_repo%/}"; remote_repo="${remote_repo%.git}"
[[ "$host" =~ ^[A-Za-z0-9.-]+$ && "$remote_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || refuse 'invalid clone remote identity'
expected=$(printf '%s/%s' "$expected_host" "$expected_repo" | tr '[:upper:]' '[:lower:]') || exit 4
actual=$(printf '%s/%s' "$host" "$remote_repo" | tr '[:upper:]' '[:lower:]') || exit 4
[[ "$actual" == "$expected" ]] || refuse 'clone remote does not match the bound PR'
printf '%s\n' "$root"
