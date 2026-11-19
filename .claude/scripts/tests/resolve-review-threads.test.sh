#!/usr/bin/env bash
# Offline regression tests for resolve-review-threads.sh explicit-ID handling
# (issue #2431): already-resolved threads are an idempotent success, and
# non-thread IDs (comment node IDs, numeric databaseIds, other node types) are
# refused with exit 2 before any mutation.
# covers: .claude/scripts/resolve-review-threads.sh
# covers: .claude/reference/graphql-thread-resolution.md
# catalog: tests — Tests for `resolve-review-threads.sh` already-resolved and non-thread-ID handling
#
# Strategy: a fake `gh` first on PATH serves the review-thread inventory from a
# state file, answers node(id:) lookups from a fixture type map, flips a thread
# to resolved on resolveReviewThread, and logs every mutation. Any other route
# exits 99. Bash 3.2 compatible. Run from repo root:
#   bash .claude/scripts/tests/resolve-review-threads.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/resolve-review-threads.sh"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected '$expected', got '$actual')"
  fi
}
check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected to contain '$needle', got '$haystack')"
  fi
}
check_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected NOT to contain '$needle', got '$haystack')"
  fi
}

# ---- fake gh ----------------------------------------------------------------
# State files (reset per case):
#   $TMP/threads.json   inventory: array of reviewThreads nodes
#   $TMP/nodes.json     node(id:) fixture: {"<id>": "<__typename>" | "__NOT_FOUND__" | "__FAIL__"}
#   $TMP/mutations.log  one line per resolveReviewThread / minimizeComment call
#   $TMP/lookups.log    one line per node(id:) lookup
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
STATE="$FAKE_STATE"
if [[ "$1 $2" == "repo view" ]]; then
  printf '%s\n' '{"owner":{"login":"fixture"},"name":"repo"}'
  exit 0
fi
if [[ "$1 $2" != "api graphql" ]]; then
  echo "fake gh: unexpected route: $*" >&2
  exit 99
fi
shift 2
query="" thread_id="" subject_id="" node_id=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|-F)
      case "$2" in
        query=*) query="${2#query=}" ;;
        threadId=*) thread_id="${2#threadId=}" ;;
        subjectId=*) subject_id="${2#subjectId=}" ;;
        id=*) node_id="${2#id=}" ;;
      esac
      shift 2 ;;
    *) shift ;;
  esac
done
case "$query" in
  *resolveReviewThread*)
    printf 'resolveReviewThread %s\n' "$thread_id" >> "$STATE/mutations.log"
    jq --arg id "$thread_id" 'map(if .id == $id then .isResolved = true else . end)' \
      "$STATE/threads.json" > "$STATE/threads.tmp" && mv "$STATE/threads.tmp" "$STATE/threads.json"
    printf '%s\n' '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
    ;;
  *minimizeComment*)
    printf 'minimizeComment %s\n' "$subject_id" >> "$STATE/mutations.log"
    printf '%s\n' '{"data":{"minimizeComment":{"minimizedComment":{"isMinimized":true}}}}'
    ;;
  *'node(id:'*)
    printf '%s\n' "$node_id" >> "$STATE/lookups.log"
    kind=$(jq -r --arg id "$node_id" '.[$id] // "__NOT_FOUND__"' "$STATE/nodes.json")
    case "$kind" in
      __FAIL__) echo "error connecting to api.github.com" >&2; exit 1 ;;
      __NOT_FOUND__)
        printf '%s\n' "{\"data\":{\"node\":null},\"errors\":[{\"type\":\"NOT_FOUND\",\"message\":\"Could not resolve to a node with the global id of '$node_id'\"}]}"
        exit 1 ;;
      *) jq -cn --arg id "$node_id" --arg t "$kind" '{data:{node:{__typename:$t,id:$id}}}' ;;
    esac
    ;;
  *reviewThreads*)
    jq -c '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false,endCursor:null},nodes:.}}}}}' \
      "$STATE/threads.json"
    ;;
  *)
    echo "fake gh: unexpected graphql query" >&2
    exit 99 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"
export FAKE_STATE="$TMP"

# thread <id> <isResolved json> <comment id> — one inventory node (Bot opener).
thread() {
  jq -cn --arg id "$1" --argjson r "$2" --arg cid "$3" \
    '{id:$id, isResolved:$r, comments:{nodes:[{id:$cid, url:("https://example.invalid/"+$id),
      author:{login:"coderabbitai", __typename:"Bot"}}]}}'
}

# reset <threads json array> [nodes json map]
reset() {
  printf '%s\n' "$1" > "$TMP/threads.json"
  local nodes='{}'
  [[ $# -ge 2 ]] && nodes="$2"
  printf '%s\n' "$nodes" > "$TMP/nodes.json"
  : > "$TMP/mutations.log"
  : > "$TMP/lookups.log"
}
mutations() { wc -l < "$TMP/mutations.log" | tr -d ' '; }

run() {
  OUT=$("$BASH" "$SCRIPT" 7 "$@" 2>&1)
  RC=$?
}

T_RES=$(thread PRRT_res true PRRC_res)
T_OPEN=$(thread PRRT_open false PRRC_open)
T_LEGACY=$(thread MDIzOlB1bGxSZXF1ZXN0UmV2aWV3VGhyZWFkMQ== false MDI0OlB1bGxSZXF1ZXN0UmV2aWV3Q29tbWVudDE=)
T_NULL=$(thread PRRT_null null PRRC_null)

# 1. Already-resolved explicit ID: success, clear line, no mutation.
reset "[$T_RES]"
run --thread-ids PRRT_res
check_eq "already-resolved: exit 0" 0 "$RC"
check_contains "already-resolved: [ALREADY-RESOLVED] line" "[ALREADY-RESOLVED] PRRT_res https://example.invalid/PRRT_res (no mutation)" "$OUT"
check_contains "already-resolved: verify line" "[VERIFY] addressed=1 resolved=1 dangling=0" "$OUT"
check_not_contains "already-resolved: no [STUCK]" "[STUCK]" "$OUT"
check_eq "already-resolved: zero mutations" 0 "$(mutations)"

# 2. Mixed set with an inventory opener-comment ID: refused before any mutation.
reset "[$T_RES,$T_OPEN]"
run --thread-ids PRRT_res,PRRT_open,PRRC_open
check_eq "opener comment id: exit 2" 2 "$RC"
check_contains "opener comment id: names expected shape" "PRRT_" "$OUT"
check_contains "opener comment id: refusal names the id" "ERROR: PRRC_open is a PullRequestReviewComment" "$OUT"
check_contains "opener comment id: hints the thread" "thread for this comment: PRRT_open" "$OUT"
check_eq "opener comment id: zero mutations (valid ids untouched too)" 0 "$(mutations)"

# 3. Comment id absent from the inventory, lookup says PullRequestReviewComment.
reset "[$T_OPEN]" '{"PRRC_elsewhere":"PullRequestReviewComment"}'
run --thread-ids PRRT_open,PRRC_elsewhere
check_eq "absent comment id: exit 2" 2 "$RC"
check_contains "absent comment id: kind from lookup" "PRRC_elsewhere is a PullRequestReviewComment" "$OUT"
check_contains "absent comment id: expected shape" "reviewThreads.nodes[].id" "$OUT"
check_eq "absent comment id: zero mutations" 0 "$(mutations)"

# 4. Numeric databaseId: refused without any lookup.
reset "[$T_OPEN]"
run --thread-ids 123456789
check_eq "numeric id: exit 2" 2 "$RC"
check_contains "numeric id: kind" "numeric databaseId" "$OUT"
check_eq "numeric id: zero mutations" 0 "$(mutations)"
check_eq "numeric id: no node lookup" 0 "$(wc -l < "$TMP/lookups.log" | tr -d ' ')"

# 5. --verify-only and --dry-run refuse a comment id too.
reset "[$T_OPEN]"
run --thread-ids PRRC_open --verify-only
check_eq "verify-only comment id: exit 2" 2 "$RC"
check_not_contains "verify-only comment id: no VERIFY line" "[VERIFY]" "$OUT"
reset "[$T_OPEN]"
run --thread-ids PRRC_open --dry-run
check_eq "dry-run comment id: exit 2" 2 "$RC"
check_not_contains "dry-run comment id: no would-resolve listing" "would be resolved" "$OUT"

# 6. Legacy (non-PRRT_) thread id present in the inventory is accepted.
reset "[$T_LEGACY]"
run --thread-ids MDIzOlB1bGxSZXF1ZXN0UmV2aWV3VGhyZWFkMQ==
check_eq "legacy thread id: exit 0" 0 "$RC"
check_contains "legacy thread id: resolved" "[RESOLVED] attempt=1 MDIzOlB1bGxSZXF1ZXN0UmV2aWV3VGhyZWFkMQ==" "$OUT"
check_eq "legacy thread id: one mutation" 1 "$(mutations)"

# 7. Lookup transport failure: exit 4, no mutation.
reset "[$T_OPEN]" '{"PRRT_mystery":"__FAIL__"}'
run --thread-ids PRRT_open,PRRT_mystery
check_eq "lookup failure: exit 4" 4 "$RC"
check_contains "lookup failure: diagnostic" "node-type lookup for PRRT_mystery failed" "$OUT"
check_eq "lookup failure: zero mutations" 0 "$(mutations)"

# 8. Thread on another PR: dangling with a precise reason.
reset "[$T_OPEN]" '{"PRRT_otherpr":"PullRequestReviewThread"}'
run --thread-ids PRRT_otherpr
check_eq "other-PR thread: exit 1" 1 "$RC"
check_contains "other-PR thread: precise [STUCK] reason" "[STUCK] PRRT_otherpr  (-) — thread is not on PR #7" "$OUT"
check_eq "other-PR thread: zero mutations" 0 "$(mutations)"

# 9. Unknown id (NOT_FOUND): dangling, precise reason.
reset "[$T_OPEN]"
run --thread-ids PRRT_gone --verify-only
check_eq "not-found id: exit 1" 1 "$RC"
check_contains "not-found id: precise reason" "node not found or inaccessible" "$OUT"

# 10. isResolved null counts as dangling (strict isResolved == true).
reset "[$T_NULL]"
run --thread-ids PRRT_null --verify-only
check_eq "null isResolved: exit 1" 1 "$RC"
check_contains "null isResolved: verify counts it dangling" "[VERIFY] addressed=1 resolved=0 dangling=1" "$OUT"
check_contains "null isResolved: reason survives field split" "— isResolved=null — https://example.invalid/PRRT_null" "$OUT"

# 11. Dry-run lists already-resolved ids alongside would-resolve ids.
reset "[$T_RES,$T_OPEN]"
run --thread-ids PRRT_res,PRRT_open --dry-run
check_eq "dry-run mixed: exit 0" 0 "$RC"
check_contains "dry-run mixed: already-resolved listed" "[ALREADY-RESOLVED] PRRT_res" "$OUT"
check_contains "dry-run mixed: would-resolve listed" "PRRT_open  (coderabbitai)" "$OUT"
check_eq "dry-run mixed: zero mutations" 0 "$(mutations)"

# 12. Empty explicit set keeps its no-op behavior.
reset "[$T_OPEN]"
printf '\n' > "$TMP/empty-ids"
run --thread-ids-file "$TMP/empty-ids" --verify-only
check_eq "empty verify-only set: exit 0" 0 "$RC"
check_contains "empty verify-only set: zero counts" "[VERIFY] addressed=0 resolved=0 dangling=0" "$OUT"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
