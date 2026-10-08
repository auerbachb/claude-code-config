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
#   api [FLAGS] repos/O/R/pulls/N
#                         -> pull-N.json (the PR drill-down, issue #1768)
#   api [FLAGS] repos/O/R/pulls/N/files...
#                         -> pull-N-files.json
#   api [FLAGS] repos/O/R/git/blobs/SHA
#                         -> blob-SHA (the file's raw content)
#   issue create ...      -> issue-create.txt (the new issue's URL); the file
#                            given to --body-file is copied to
#                            issue-create.body
# For a fixture NAME.EXT, an optional NAME.rc holds the exit code to return
# after printing it (GitHub's NOT_FOUND answer comes with exit 1, for
# example) and NAME.err the text to print on stderr. NAME.EXT.then1,
# .then2, ... are the answers to later calls: after each call the next one
# replaces NAME.EXT (a PR pushed to between two reads). A file `sleep` delays
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
  "api "*)
    # The REST reads the PR drill-down makes (issue #1768): the endpoint is
    # the one argument that starts with repos/, whatever flags come first.
    for a in "$@"; do
      case "$a" in
        repos/*/*/pulls/*/files*)
          a="${a%/files*}"
          name="pull-${a##*/}-files.json"
          ;;
        repos/*/*/pulls/*) name="pull-${a##*/}.json" ;;
        repos/*/*/git/blobs/*) name="blob-${a##*/}" ;;
      esac
    done
    ;;
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
if [ -f "$dir/$name.then1" ]; then
  mv "$dir/$name.then1" "$dir/$name"
  k=2
  while [ -f "$dir/$name.then$k" ]; do
    mv "$dir/$name.then$k" "$dir/$name.then$((k - 1))"
    k=$((k + 1))
  done
fi
base="${name%.*}"
if [ -f "$dir/$base.err" ]; then
  cat "$dir/$base.err" >&2
fi
if [ -f "$dir/$base.rc" ]; then
  exit "$(cat "$dir/$base.rc")"
fi
exit 0
