#!/usr/bin/env bash
# desk/tests/lib/gh-stub.sh — a stand-in for `gh` in the desk tests (issue
# #1756). The Reviews tools find gh through HUMAN_QUEUE_GH, so a suite points
# that at this file and the GitHub side runs offline, from fixtures.
#
# Serves files from HQ_GH_STUB_DIR:
#   search prs ...        -> search-prs.json
#   search issues ...     -> search-issues.json
#   api graphql ... -F number=N
#                         -> graphql-N.json
#   pr diff N ...         -> pr-N.diff
#   issue create ...      -> issue-create.txt (the new issue's URL); the file
#                            given to --body-file is copied to
#                            issue-create.body
# For a fixture NAME.EXT, an optional NAME.rc holds the exit code to return
# after printing it (GitHub's NOT_FOUND answer comes with exit 1, for
# example) and NAME.err the text to print on stderr. A file `sleep` delays
# every call by that many seconds (for deadline tests). Every call's
# arguments are appended, one call per line (newlines flattened), to
# calls.log. Any other command exits 64, so an unexpected call fails the
# test instead of passing silently.
set -uo pipefail

dir="${HQ_GH_STUB_DIR:?HQ_GH_STUB_DIR is not set}"
args="$*"
printf '%s\n' "${args//$'\n'/ }" >>"$dir/calls.log"

if [ -f "$dir/sleep" ]; then
  sleep "$(cat "$dir/sleep")"
fi

name=""
case "${1:-} ${2:-}" in
  "search prs") name=search-prs.json ;;
  "search issues") name=search-issues.json ;;
  "api graphql")
    prev=""
    for a in "$@"; do
      if [ "$prev" = "-F" ]; then
        case "$a" in number=*) name="graphql-${a#number=}.json" ;; esac
      fi
      prev="$a"
    done
    ;;
  "pr diff") name="pr-${3:-}.diff" ;;
  "issue create")
    # The desk's follow-up issue (issue #1782): keep the body it filed, which
    # the desk's block deletes once gh returns.
    name=issue-create.txt
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--body-file" ] && [ -f "$a" ]; then cp "$a" "$dir/issue-create.body"; fi
      prev="$a"
    done
    ;;
esac

if [ -z "$name" ]; then
  printf 'gh-stub: unexpected call: gh %s\n' "$*" >&2
  exit 64
fi
if [ ! -f "$dir/$name" ]; then
  printf 'gh-stub: no fixture %s\n' "$name" >&2
  exit 1
fi
cat "$dir/$name"
base="${name%.*}"
if [ -f "$dir/$base.err" ]; then
  cat "$dir/$base.err" >&2
fi
if [ -f "$dir/$base.rc" ]; then
  exit "$(cat "$dir/$base.rc")"
fi
exit 0
