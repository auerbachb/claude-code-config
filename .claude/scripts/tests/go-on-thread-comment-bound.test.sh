#!/usr/bin/env bash
# /go-on Step 7 bot-thread count fails closed on a truncated thread (issue #1953).
# catalog: tests — Runs `/go-on` Step 7's real bot-thread count filter (anchor `go-on-bot-thread-count`) on fixtures — a thread whose comments exceed the 100 returned always counts and is flagged truncated, exact bot-login membership, resolved and human-only threads excluded, null authors safe, one count per thread
#
# WHAT IS UNDER TEST
#   The fenced bash under `<!-- test-anchor: go-on-bot-thread-count -->` in
#   `.claude/skills/go-on/SKILL.md`, extracted at run time by lib/skill-bash.sh
#   and fed thread-node arrays on stdin. Nothing here is a transcription.
#
# WHY (issue #1953)
#   Step 7 reads `comments(first: 100)` per thread. A bot comment after the
#   100th was invisible, so a long human-opened thread a bot later replied in
#   dropped out of the count. The filter now counts any unresolved thread whose
#   `totalCount` exceeds the returned nodes. The comment-101 case below fails
#   against the pre-#1953 any-returned-comment predicate.
#
# Requires: bash 3.2+, jq. Offline.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
GO_ON="$REPO_ROOT/.claude/skills/go-on/SKILL.md"
# shellcheck source=lib/skill-bash.sh
source "$TEST_DIR/lib/skill-bash.sh"

PASS=0
FAIL=0
check_eq() {
  if [[ "$3" == "$2" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $1"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $1 (expected '$2', got '$3')"
  fi
}

BLOCK="$(extract_skill_bash "$GO_ON" go-on-bot-thread-count)" || exit 1
case "$BLOCK" in
  *totalCount*) check_eq "premise: extracted block reads totalCount" yes yes ;;
  *) check_eq "premise: extracted block reads totalCount" yes no ;;
esac

run() { printf '%s' "$1" | bash -c "$BLOCK"; }

# thread <id> <isResolved> <totalCount> <logins...> — one thread node; a login
# of "null" writes a comment whose author is null (a deleted account).
thread() {
  local id="$1" resolved="$2" total="$3"; shift 3
  local logins
  logins=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
  jq -nc --arg id "$id" --argjson r "$resolved" --argjson t "$total" --argjson ls "$logins" \
    '{id: $id, isResolved: $r,
      comments: {totalCount: $t,
                 nodes: [$ls[] | if . == "null" then {body: "x", author: null}
                                 else {body: "x", author: {login: .}} end]}}'
}

T_BOT=$(thread T1 false 2 alice coderabbitai)
T_HUMAN=$(thread T2 false 2 alice bob)
T_LONG=$(thread T3 false 150 alice bob)
T_RESOLVED=$(thread T4 true 1 cursor)
T_NULL=$(thread T5 false 2 null alice)
T_TWO=$(thread T6 false 2 cursor codeant-ai)
T_LIKE=$(thread T7 false 1 coderabbitai-fan)
T_GRAPHITE=$(thread T8 false 1 graphite-app)

out=$(run "[$T_BOT]")
check_eq "unresolved thread with a returned bot comment counts" 1 "$(jq -r .count <<<"$out")"
check_eq "  ...and is not flagged truncated" false "$(jq -r '.threads[0].truncated' <<<"$out")"

out=$(run "[$T_HUMAN]")
check_eq "human-only thread with every comment returned does not count" 0 "$(jq -r .count <<<"$out")"

out=$(run "[$T_LONG]")
check_eq "comment-101 case: totalCount 150 > 2 returned counts (fail closed)" 1 "$(jq -r .count <<<"$out")"
check_eq "  ...flagged truncated" true "$(jq -r '.threads[0].truncated' <<<"$out")"
check_eq "  ...by its thread id" T3 "$(jq -r '.threads[0].id' <<<"$out")"

out=$(run "[$T_RESOLVED]")
check_eq "resolved thread with a bot comment does not count" 0 "$(jq -r .count <<<"$out")"

out=$(run "[$T_NULL]" 2>&1); rc=$?
check_eq "null author is not an error" 0 "$rc"
check_eq "  ...and a null-author human thread does not count" 0 "$(jq -r .count <<<"$out")"

out=$(run "[]")
check_eq "empty thread list counts 0" 0 "$(jq -r .count <<<"$out")"

out=$(run "[$T_TWO]")
check_eq "two bot comments in one thread count once" 1 "$(jq -r .count <<<"$out")"

out=$(run "[$T_LIKE]")
check_eq "login merely containing a bot name does not count (exact membership)" 0 "$(jq -r .count <<<"$out")"

out=$(run "[$T_GRAPHITE]")
check_eq "retired graphite-app comment still counts (App still posts)" 1 "$(jq -r .count <<<"$out")"

out=$(run "[$T_BOT,$T_HUMAN,$T_LONG,$T_RESOLVED,$T_NULL,$T_TWO]")
check_eq "mixed set: count and ids derive from one selection" "3 T1,T3,T6" \
  "$(jq -r '"\(.count) \([.threads[].id] | join(","))"' <<<"$out")"

# The cleanup inventory above can include retired-app threads. The resolver
# only targets one after its exact ID is supplied (issue #2192).
resolve_fixture() (
  export THREAD_FIXTURE="$(jq -cn --argjson nodes "[$T_TWO,$T_GRAPHITE]" \
    '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false,endCursor:null},
       nodes:($nodes | map(.id as $id | .comments.nodes[0].id = ("C"+$id)))}}}}}')"
  gh() {
    case "$1 $2" in
      'repo view') printf '%s\n' '{"owner":{"login":"fixture"},"name":"repo"}' ;;
      'api graphql')
        case "$*" in *mutation*) return 4 ;; esac
        printf '%s\n' "$THREAD_FIXTURE" ;;
      *) return 4 ;;
    esac
  }
  export -f gh
  "$BASH" "$REPO_ROOT/.claude/scripts/resolve-review-threads.sh" 1 --dry-run "$@"
)
out=$(resolve_fixture)
check_eq "default resolver keeps active reviewer threads" 1 "$(grep -c 'T6  (cursor)' <<<"$out")"
check_eq "default resolver excludes retired Graphite threads" 0 "$(grep -c 'T8  (graphite-app)' <<<"$out")"
out=$(resolve_fixture --thread-ids T8)
check_eq "explicit handled ID includes the retired Graphite thread" 1 "$(grep -c 'T8  (graphite-app)' <<<"$out")"

# A failed native resolve may minimize only a verified bot's opening comment.
fallback_fixture() (
  export THREAD_FIXTURE
  THREAD_FIXTURE=$(jq -cn --argjson nodes "[$T_BOT,$T_TWO,$T_NULL]" '
    {data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false},
      nodes:($nodes | map(.id as $id | .comments.nodes[0] |= (
        .id = ("C"+$id) | .url = ("https://example.invalid/"+$id)
        | if .author.login == "alice" then .author.__typename = "User"
          elif .author.login == "cursor" then .author.__typename = "Bot" else . end
      )))}}}}}')
  gh() {
    case "$1 $2" in
      'repo view') printf '%s\n' '{"owner":{"login":"fixture"},"name":"repo"}' ;;
      'api graphql')
        case "$*" in
          *resolveReviewThread*) printf 'native resolution failed\n' >&2; return 1 ;;
          *minimizeComment*)
            printf '%s\n' "$*" >> "$FALLBACK_LOG"
            printf '%s\n' '{"data":{"minimizeComment":{"minimizedComment":{"isMinimized":true}}}}'
            ;;
          *) printf '%s\n' "$THREAD_FIXTURE" ;;
        esac ;;
      *) return 4 ;;
    esac
  }
  export -f gh
  "$BASH" "$REPO_ROOT/.claude/scripts/resolve-review-threads.sh" 1 \
    --thread-ids T1,T5,T6 --max-attempts 1
)
FALLBACK_LOG=$(mktemp)
export FALLBACK_LOG
trap 'rm -f "$FALLBACK_LOG"' EXIT
status=0
out=$(fallback_fixture 2>&1) || status=$?
check_eq "unresolved threads remain a failure even after the fallback" 1 "$status"
check_eq "bot opener gets one fallback mutation" 1 "$(grep -c 'subjectId=CT6' "$FALLBACK_LOG")"
check_eq "human and unknown openers get no fallback mutation" 0 "$(grep -cE 'subjectId=CT[15]' "$FALLBACK_LOG")"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
