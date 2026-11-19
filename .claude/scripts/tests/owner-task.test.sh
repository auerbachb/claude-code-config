#!/usr/bin/env bash
# Offline tests for owner-task.sh (issue #2538 — one list per repo of human tasks).
# catalog: tests — Tests for `owner-task.sh` against a stateful `gh` stub: add/list/done, the pinned `list --json` shape, two concurrent adds losing nothing, the done-without-proof refusal, the public-repo redirect to a private bucket, the missing-pointer and public-bucket refusals, the secret refusal and missing checker, and exit 4 on an unreadable source
# covers: .claude/scripts/owner-task.sh desk/bin/lib/secrets.sh .claude/reference/owner-tasks.md
#
# `gh` is a Python stub holding repos, issues and comments in a JSON file under
# a lock, so a task written by one run is read back by the next and two
# concurrent runs race the way they would on GitHub. Nothing touches the
# network. Requires jq and python3.
#
# Run from repo root:
#   bash .claude/scripts/tests/owner-task.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/owner-task.sh"
STUB_SRC="$REPO_ROOT/.claude/scripts/tests/lib/owner-task-gh-stub.py"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   — $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }
check_eq() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
check_contains() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1 (expected to contain '$2', got '$3')"; fi; }
check_absent() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1 (must not contain '$2')"; fi; }

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cp "$STUB_SRC" "$STUB_BIN/gh"
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

export FAKE_STATE="$TMP/state"
export OWNER_TASK_POINTER_FILE="$HOME/.claude/owner-tasks-pointer.json"
PRIV="me/private-app"
PUB="me/public-app"
BUCKET="me/task-bucket"
OPENB="me/open-bucket"

reset_db() {
  rm -rf "$FAKE_STATE"
  mkdir -p "$FAKE_STATE"
  jq -n --arg priv "$PRIV" --arg pub "$PUB" --arg bucket "$BUCKET" --arg openb "$OPENB" '{
    repos: {($priv): "private", ($pub): "public", ($bucket): "private", ($openb): "public",
            "me/other-private": "private"},
    issues: {}, comments: {}, next_issue: 100, next_comment: 5000}' > "$FAKE_STATE/db.json"
  : > "$FAKE_STATE/writes.log"
  rm -f "$OWNER_TASK_POINTER_FILE"
  unset FAKE_FAIL_READ FAKE_FAIL_SEARCH FAKE_SLOW
  export FAKE_CURRENT_REPO="$PRIV"
}
db() { jq -c "$1" "$FAKE_STATE/db.json"; }
writes() { cat "$FAKE_STATE/writes.log"; }

run() { # sets OUT, ERR, RC
  OUT="$("$SCRIPT" "$@" 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
}

# ---- help -----------------------------------------------------------------------
run --help
check_eq "--help exits 0" 0 "$RC"
check_contains "--help documents exit 4" "4  a source could not be read" "$OUT"
check_contains "--help documents the proof refusal" "6  done refused" "$OUT"

# ---- private repo: add, tracker, list ----------------------------------------------
reset_db
run list --json
check_eq "empty list --json exits 0" 0 "$RC"
check_eq "empty list --json prints []" "[]" "$OUT"

run add --what "Fill in STRIPE_PUBLISHABLE in .env" --why "only the operator holds the dashboard login" --source "https://github.com/me/private-app/pull/7"
check_eq "add exits 0" 0 "$RC"
ID1="$OUT"
if [[ "$ID1" =~ ^ht-[0-9a-f]{8}$ ]]; then ok "add prints a task id"; else bad "add prints a task id (got '$ID1')"; fi
check_eq "add creates one tracker in the private repo" 1 "$(db ".issues[\"$PRIV\"] | length")"
check_eq "tracker is titled Human tasks" '"Human tasks"' "$(db ".issues[\"$PRIV\"][0].title")"
check_eq "tracker carries the human-tasks label" '["human-tasks"]' "$(db ".issues[\"$PRIV\"][0].labels | map(.name)")"
check_absent "tracker body has no /issue-maker footer" "Captured via /issue-maker" "$(db ".issues[\"$PRIV\"][0].body")"
check_eq "one comment per task" 1 "$(db ".comments[\"$PRIV#101\"] | length")"

run add --what "Accept the Vercel team invite --> then reply" --why "needs his email inbox" --source "thread 407c"
ID2="$OUT"
check_eq "second add reuses the tracker" 1 "$(db ".issues[\"$PRIV\"] | length")"
check_eq "second add is a second comment" 2 "$(db ".comments[\"$PRIV#101\"] | length")"

run list --json
check_eq "list --json exits 0" 0 "$RC"
check_eq "list --json has both tasks" 2 "$(jq length <<<"$OUT")"
check_eq "list --json element keys are the pinned contract" \
  '["created_at","done_at","id","proof","repo","source","state","what","why"]' \
  "$(jq -c '.[0] | keys' <<<"$OUT")"
check_eq "open task: state open, done_at and proof null" '["open",null,null]' \
  "$(jq -c --arg id "$ID1" '.[] | select(.id == $id) | [.state, .done_at, .proof]' <<<"$OUT")"
check_eq "task records repo, what, why, source" \
  "[\"$PRIV\",\"Fill in STRIPE_PUBLISHABLE in .env\",\"only the operator holds the dashboard login\",\"https://github.com/me/private-app/pull/7\"]" \
  "$(jq -c --arg id "$ID1" '.[] | select(.id == $id) | [.repo, .what, .why, .source]' <<<"$OUT")"
if jq -e 'all(.[]; .created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' <<<"$OUT" >/dev/null; then
  ok "created_at is ISO-8601 UTC"; else bad "created_at is ISO-8601 UTC ($OUT)"; fi
check_eq "'-->' in task text round-trips" "Accept the Vercel team invite --> then reply" \
  "$(jq -r --arg id "$ID2" '.[] | select(.id == $id) | .what' <<<"$OUT")"

run list
check_contains "human list shows the task" "Fill in STRIPE_PUBLISHABLE" "$OUT"
check_contains "human list shows the why" "only the operator holds the dashboard login" "$OUT"

run where
check_eq "where exits 0 on a private repo" 0 "$RC"
check_contains "where names the repo tracker" "$PRIV#101 (repo)" "$OUT"

# ---- done ---------------------------------------------------------------------------
BEFORE="$(db ".comments[\"$PRIV#101\"][0].body")"
: > "$FAKE_STATE/writes.log"
run "done" "$ID1"
check_eq "done without --proof exits 6" 6 "$RC"
check_contains "done refusal names --proof" "--proof" "$ERR"
check_eq "refused done leaves the comment unchanged" "$BEFORE" "$(db ".comments[\"$PRIV#101\"][0].body")"
check_eq "refused done writes nothing" "" "$(writes)"

run "done" "$ID1" --by robot
check_eq "done --by with an unknown value is a usage error" 2 "$RC"

run "done" "$ID1" --proof "grep STRIPE_PUBLISHABLE .env found a value"
check_eq "done --proof exits 0" 0 "$RC"
run list --json
check_eq "done task drops out of the open list" 1 "$(jq length <<<"$OUT")"
run list --json --all
check_eq "--all includes done tasks" 2 "$(jq length <<<"$OUT")"
check_eq "done task carries state, done_at and proof" '["done",true,"grep STRIPE_PUBLISHABLE .env found a value"]' \
  "$(jq -c --arg id "$ID1" '.[] | select(.id == $id) | [.state, (.done_at | test("Z$")), .proof]' <<<"$OUT")"
check_contains "done comment shows Done in its readable text" "**Done:**" "$(db ".comments[\"$PRIV#101\"][0].body")"

run "done" "$ID2" --by operator
check_eq "done --by operator needs no proof" 0 "$RC"
run "done" ht-00000000 --proof "x"
check_eq "done on an unknown id exits 1" 1 "$RC"

# ---- repo names are case-insensitive ------------------------------------------------------
reset_db
run add --repo ME/Private-App --what "Case task" --why "w" --source "s"
CID="$OUT"
run add --repo me/private-app --what "Case task two" --why "w" --source "s"
check_eq "two spellings share one tracker" 1 "$(db ".issues[\"$PRIV\"] | length")"
run list --json --repo ME/PRIVATE-APP
check_eq "list with another spelling finds both tasks" 2 "$(jq length <<<"$OUT")"
run "done" "$CID" --repo Me/Private-app --proof "checked"
check_eq "done with another spelling finds the task" 0 "$RC"

# ---- a tracker GitHub created without its label -----------------------------------------
reset_db
export FAKE_DROP_LABELS=1
run add --what "Unlabelled" --why "w" --source "s"
unset FAKE_DROP_LABELS
check_eq "a silently dropped label fails the add (exit 1)" 1 "$RC"
check_contains "the failure names the created issue" "$PRIV#101" "$ERR"
check_eq "no task is posted to an unlabelled tracker" 0 "$(db ".comments[\"$PRIV#101\"] // [] | length")"

# ---- a title-only tracker (no marker) still counts -------------------------------------
reset_db
jq --arg r "$PRIV" '.issues[$r] = [{number: 7, title: "Human tasks", body: "hand-made", state: "open",
                                    labels: [{name: "human-tasks"}]}]' \
  "$FAKE_STATE/db.json" > "$TMP/db" && mv "$TMP/db" "$FAKE_STATE/db.json"
run add --what "Into the hand-made tracker" --why "w" --source "s"
check_eq "add reuses a title-only tracker" 1 "$(db ".issues[\"$PRIV\"] | length")"
check_eq "the task lands on the title-only tracker" 1 "$(db ".comments[\"$PRIV#7\"] | length")"
run list --json
check_eq "list reads a title-only tracker" '["Into the hand-made tracker"]' "$(jq -c 'map(.what)' <<<"$OUT")"

# ---- a long list stays off jq's argument list ------------------------------------------
# 150 done tasks of ~2 KB each (~300 KB) exceed Linux's 128 KiB per-argument
# limit; the records must travel on stdin.
reset_db
run add --what "Seed" --why "w" --source "s"
jq --arg r "$PRIV" '
  ("x" * 2000) as $long
  | .comments["\($r)#101"] += [range(0; 150) as $k
      | {id: (9000 + $k),
         body: ("<!-- owner-task: " + ({v: 1, id: ("ht-" + ("0000000" + ($k | tostring))[-8:]), repo: $r,
                what: $long, why: "w", source: "s", created_at: "2026-01-01T00:00:00Z",
                state: "done", done_at: "2026-01-02T00:00:00Z", proof: "p"} | tojson) + " -->")}]' \
  "$FAKE_STATE/db.json" > "$TMP/db" && mv "$TMP/db" "$FAKE_STATE/db.json"
run list --json --all
check_eq "a list past the argument limit still reads (exit 0)" 0 "$RC"
check_eq "a list past the argument limit returns every task" 151 "$(jq length <<<"$OUT" 2>/dev/null)"

# ---- concurrency ----------------------------------------------------------------------
reset_db
export FAKE_SLOW=0.3
"$SCRIPT" add --what "task A" --why "w" --source "s" >"$TMP/a.out" 2>"$TMP/a.err" &
PA=$!
"$SCRIPT" add --what "task B" --why "w" --source "s" >"$TMP/b.out" 2>"$TMP/b.err" &
PB=$!
wait "$PA"; RA=$?
wait "$PB"; RB=$?
unset FAKE_SLOW
check_eq "concurrent adds both succeed" "0 0" "$RA $RB"
run list --json
check_eq "concurrent adds lose neither task" '["task A","task B"]' "$(jq -c 'map(.what) | sort' <<<"$OUT")"
check_eq "concurrent first-use adds leave one open tracker" 1 \
  "$(db ".issues[\"$PRIV\"] | map(select(.state == \"open\")) | length")"

# ---- public repo ----------------------------------------------------------------------
reset_db
export FAKE_CURRENT_REPO="$PUB"
run add --what "Sign in to Railway" --why "interactive login" --source "PR #9"
check_eq "public repo with no pointer: add exits 3" 3 "$RC"
check_contains "missing pointer gives a one-line instruction" "$OWNER_TASK_POINTER_FILE" "$ERR"
check_eq "missing pointer: one line on stderr" 1 "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')"
check_eq "missing pointer writes nothing" "" "$(writes)"
run where
check_eq "where on a public repo with no pointer exits 3" 3 "$RC"

jq -n --arg pub "$PUB" --arg b "$OPENB" '{repos: {($pub): $b}}' > "$OWNER_TASK_POINTER_FILE"
run add --what "Sign in to Railway" --why "interactive login" --source "PR #9"
check_eq "a public bucket is refused (exit 3)" 3 "$RC"
check_eq "public bucket: nothing written" "" "$(writes)"

jq -n --arg pub "$PUB" --arg b "$BUCKET" '{repos: {($pub): $b}}' > "$OWNER_TASK_POINTER_FILE"
run add --what "Sign in to Railway" --why "interactive login" --source "PR #9"
check_eq "public repo with a pointer: add exits 0" 0 "$RC"
PUBID="$OUT"
check_eq "nothing is written to the public repo" "" "$(grep "repos/$PUB" "$FAKE_STATE/writes.log" || true)"
check_eq "the public repo has no tracker" 0 "$(db ".issues[\"$PUB\"] // [] | length")"
check_eq "the bucket holds a per-source-repo tracker" "\"Human tasks: $PUB\"" "$(db ".issues[\"$BUCKET\"][0].title")"
run list --json
check_eq "list on the public repo reads the bucket" "[\"$PUBID\",\"$PUB\"]" "$(jq -c '.[0] | [.id, .repo]' <<<"$OUT")"
run where
check_contains "where names the bucket" "$BUCKET#" "$OUT"
check_contains "where says why" "is public" "$OUT"
run "done" "$PUBID" --proof "railway whoami printed the account"
check_eq "done works on a bucket task" 0 "$RC"

# ---- --all-repos ----------------------------------------------------------------------
export FAKE_CURRENT_REPO="$PRIV"
run add --what "Private task" --why "w" --source "s"
"$SCRIPT" add --repo me/other-private --what "Other task" --why "w" --source "s" >/dev/null 2>&1
run list --json --all-repos --all
check_eq "--all-repos covers repo trackers and bucket trackers" \
  "[\"me/other-private\",\"$PRIV\",\"$PUB\"]" "$(jq -c 'map(.repo) | sort' <<<"$OUT")"
run list --json --all-repos --repo "$PRIV"
check_eq "--all-repos with --repo is a usage error" 2 "$RC"

# Pagination: a second source repo's tracker in the same bucket sits on page 2.
jq -n --arg pub "$PUB" --arg b "$BUCKET" '{repos: {($pub): $b, "me/public-two": $b}}' > "$OWNER_TASK_POINTER_FILE"
jq '.repos["me/public-two"] = "public"' "$FAKE_STATE/db.json" > "$TMP/db" && mv "$TMP/db" "$FAKE_STATE/db.json"
"$SCRIPT" add --repo me/public-two --what "Page two task" --why "w" --source "s" >/dev/null 2>&1
export FAKE_PAGE_SIZE=1
run list --json --repo me/public-two
check_eq "a tracker past the first page is still read" '["Page two task"]' "$(jq -c 'map(.what)' <<<"$OUT")"
run add --repo me/public-two --what "Second page-two task" --why "w" --source "s"
check_eq "add past the first page reuses the tracker" 2 "$(db ".issues[\"$BUCKET\"] | map(select(.state == \"open\")) | length")"
run list --json --all-repos
check_contains "--all-repos reads every page" "Second page-two task" "$OUT"
unset FAKE_PAGE_SIZE

# A bucket that turned public after a task was written: done refuses to write.
run add --what "Bucket task" --why "w" --source "s" --repo "$PUB"
BID="$OUT"
jq --arg b "$BUCKET" '.repos[$b] = "public"' "$FAKE_STATE/db.json" > "$TMP/db" && mv "$TMP/db" "$FAKE_STATE/db.json"
: > "$FAKE_STATE/writes.log"
run "done" "$BID" --repo "$PUB" --proof "checked"
check_eq "done on a now-public host exits 3" 3 "$RC"
check_eq "done on a now-public host writes nothing" "" "$(writes)"
jq --arg b "$BUCKET" '.repos[$b] = "private"' "$FAKE_STATE/db.json" > "$TMP/db" && mv "$TMP/db" "$FAKE_STATE/db.json"

# ---- unreadable sources ----------------------------------------------------------------
export FAKE_FAIL_READ="$BUCKET"
FAKE_CURRENT_REPO="$PUB" run list --json
check_eq "unreadable bucket: list exits 4" 4 "$RC"
check_eq "unreadable bucket: nothing on stdout" "" "$OUT"
run list --json --all-repos
check_eq "unreadable source under --all-repos exits 4" 4 "$RC"
check_eq "--all-repos unreadable: nothing on stdout" "" "$OUT"
unset FAKE_FAIL_READ
export FAKE_FAIL_SEARCH=1
run list --json --all-repos
check_eq "failed tracker search exits 4" 4 "$RC"
check_eq "failed search: nothing on stdout" "" "$OUT"
unset FAKE_FAIL_SEARCH
export FAKE_SEARCH_INCOMPLETE=1
run list --json --all-repos
check_eq "an incomplete tracker search exits 4" 4 "$RC"
check_eq "incomplete search: nothing on stdout" "" "$OUT"
unset FAKE_SEARCH_INCOMPLETE
printf 'not json' > "$OWNER_TASK_POINTER_FILE"
run list --json
check_eq "unreadable pointer file exits 4" 4 "$RC"
check_eq "unreadable pointer: nothing on stdout" "" "$OUT"
printf '{"repos": []}' > "$OWNER_TASK_POINTER_FILE"
FAKE_CURRENT_REPO="$PUB" run list --json
check_eq "a pointer with a malformed repos map exits 4" 4 "$RC"
check_eq "malformed repos map: nothing on stdout" "" "$OUT"
printf '{"repos": {"%s": 7}}' "$PUB" > "$OWNER_TASK_POINTER_FILE"
FAKE_CURRENT_REPO="$PUB" run list --json
check_eq "a pointer with a non-string bucket exits 4" 4 "$RC"
printf '{"repos": {"%s": "not-a-repo"}}' "$PUB" > "$OWNER_TASK_POINTER_FILE"
run list --json --all-repos
check_eq "an invalid bucket name under --all-repos exits 4" 4 "$RC"
check_eq "invalid bucket: nothing on stdout" "" "$OUT"
: > "$OWNER_TASK_POINTER_FILE"
FAKE_CURRENT_REPO="$PUB" run list --json
check_eq "an empty pointer file exits 4" 4 "$RC"
check_eq "empty pointer: nothing on stdout" "" "$OUT"

# ---- secret refusal -----------------------------------------------------------------------
reset_db
TOKEN="ghp_$(printf 'A1b2C3d4E5f6G7h8I9j0K1l2M3n4')"
run add --what "Set GH token $TOKEN in CI" --why "w" --source "s"
check_eq "token-shaped text: add exits 5" 5 "$RC"
check_absent "secret refusal never echoes the value" "$TOKEN" "$ERR"
check_eq "secret refusal writes nothing" "" "$(writes)"
check_eq "secret refusal creates no tracker" 0 "$(db ".issues[\"$PRIV\"] // [] | length")"
run add --what "rotate" --why "w" --source "password=Hunter2abc9"
check_eq "a labeled credential in --source is refused" 5 "$RC"

run add --what "real task" --why "w" --source "s"
SID="$OUT"
: > "$FAKE_STATE/writes.log"
run "done" "$SID" --proof "used token $TOKEN"
check_eq "a secret in --proof is refused" 5 "$RC"
check_eq "refused proof writes nothing" "" "$(writes)"

# Secret checker unavailable: a lone copy with no desk/ beside it and no
# skills worktree fails closed.
mkdir -p "$TMP/lone"
cp "$SCRIPT" "$TMP/lone/owner-task.sh"
: > "$FAKE_STATE/writes.log"
OUT="$("$TMP/lone/owner-task.sh" add --what "x" --why "w" --source "s" 2>"$TMP/err")"; RC=$?
check_eq "missing secret checker refuses the write (exit 7)" 7 "$RC"
check_contains "missing checker says so" "secret checker" "$(cat "$TMP/err")"
check_eq "missing checker writes nothing" "" "$(writes)"
OUT="$("$TMP/lone/owner-task.sh" "done" "$SID" --by operator 2>"$TMP/err")"; RC=$?
check_eq "missing checker also refuses an operator done (exit 7)" 7 "$RC"
check_eq "operator done without a checker writes nothing" "" "$(writes)"

echo
echo "owner-task.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
