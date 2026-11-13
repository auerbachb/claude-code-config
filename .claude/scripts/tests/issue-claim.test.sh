#!/usr/bin/env bash
# Offline unit tests for issue-claim.sh (issue #873 — claim an issue at pick time).
# catalog: tests — Tests for `issue-claim.sh` against a stateful `gh` stub, so a claim written by one run is read back by the next
#
# Stubs `gh` on PATH with a STATEFUL fake issue (labels, assignees, comments,
# timeline) so a claim written by one run is read back by the next — that
# round trip is the whole point of the feature, and a stateless stub would
# assert nothing about it. No network or auth is needed. Requires jq.
#
# Run from repo root:
#   bash .claude/scripts/tests/issue-claim.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/issue-claim.sh"
# Exercise the actual helper with the selected outer Bash, including macOS 3.2.
CLAIM_TEST_SHELL="${CLAIM_TEST_SHELL:-$BASH}"

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

# ---- portable ISO-8601 timestamp N hours in the past --------------------------
# GNU and BSD date disagree on both the offset and the epoch-to-string flags, so
# try each spelling rather than assuming a platform. GNU is tried FIRST and the
# order is load-bearing: GNU `date -r` reads its argument as a FILE, so a
# BSD-first chain silently emits a file's mtime whenever one happens to be named
# for the epoch (issue #1587). Both arms stay — GNU alone strands macOS.
iso_ago() {
  local hours="$1" epoch
  epoch=$(( $(date -u +%s) - hours * 3600 ))
  date -u -d "@$epoch" +%FT%TZ 2>/dev/null && return 0
  date -u -r "$epoch" +%FT%TZ 2>/dev/null && return 0
  echo "iso_ago: no usable date(1) spelling" >&2
  return 1
}

# ---- stateful fake-issue store ------------------------------------------------
STATE="$TMP/state"
mkdir -p "$STATE"
export FAKE_STATE="$STATE"

reset_issue() {
  : > "$STATE/labels"
  : > "$STATE/assignees"
  echo '[]' > "$STATE/comments.json"
  echo '[]' > "$STATE/timeline.json"
  printf 'bug\nenhancement\n' > "$STATE/repo_labels"
  echo 0 > "$STATE/next_id"
  export FAKE_VIEWER="alice"
  export FAKE_ISSUE_MODE="json"
  export FAKE_COMMENTS_MODE="json"
  echo 0 > "$STATE/comment_reads"
  echo 0 > "$STATE/edit_calls"
  rm -f "$STATE/delete_hook_done" "$STATE/hook_done" "$STATE/issue_state" "$STATE/edit_hook_done" "$STATE/read_hook_done"
  unset CLAIM_STALE_HOURS CLAIM_RENEW_MINUTES
  unset FAKE_COMMENT_POST_MODE FAKE_COMMENT_DELETE_MODE FAKE_AFTER_DELETE_HOOK
  unset FAKE_COMMENTS_FAIL_AFTER FAKE_AFTER_POST_HOOK
  unset FAKE_EDIT_FAIL_AT FAKE_AFTER_EDIT_HOOK FAKE_AFTER_EDIT_AT
  unset FAKE_AFTER_COMMENTS_READ_HOOK FAKE_AFTER_COMMENTS_READ_AT
}

# ---- stub gh on PATH ----------------------------------------------------------
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
S="$FAKE_STATE"

json_array_of_lines() { # file -> ["a","b"]
  jq -Rn --rawfile f "$1" '($f | split("\n") | map(select(length > 0)))'
}

case "${1:-}" in
  api)
    shift
    METHOD="GET"; ENDPOINT=""; FIELD_BODY=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -X) METHOD="$2"; shift 2 ;;
        --paginate|--slurp) shift ;;
        --jq) shift 2 ;;
        -f|-F|--raw-field|--field)
          [[ "$2" == body=* ]] && FIELD_BODY="${2#body=}"; shift 2 ;;
        *) [[ -z "$ENDPOINT" ]] && ENDPOINT="$1"; shift ;;
      esac
    done
    case "$ENDPOINT" in
      user)
        if [[ "${FAKE_VIEWER:-}" == "__FAIL__" ]]; then
          echo "gh: could not authenticate to github.com" >&2; exit 1
        fi
        printf '%s\n' "${FAKE_VIEWER:-}"
        ;;
      */issues/comments/*)
        [[ "$METHOD" == "DELETE" ]] || { echo "unexpected method $METHOD on $ENDPOINT" >&2; exit 99; }
        if [[ "${FAKE_COMMENT_DELETE_MODE:-ok}" == "error" ]]; then
          echo "gh: HTTP 500: could not delete comment" >&2; exit 1
        fi
        CID="${ENDPOINT##*/}"
        jq --argjson id "$CID" '[ .[] | select(.id != $id) ]' "$S/comments.json" > "$S/c.tmp" \
          && mv "$S/c.tmp" "$S/comments.json"
        if [[ -n "${FAKE_AFTER_DELETE_HOOK:-}" && ! -e "$S/delete_hook_done" ]]; then
          : > "$S/delete_hook_done"
          bash "$FAKE_AFTER_DELETE_HOOK"
        fi
        echo '{}'
        ;;
      */comments*)
        if [[ "$METHOD" == "POST" ]]; then
          # Renewal write path (#1914): returns the new comment like GitHub does.
          if [[ "${FAKE_COMMENT_POST_MODE:-ok}" == "error" ]]; then
            # The write did NOT land; a concurrent writer may still act.
            if [[ -n "${FAKE_AFTER_POST_HOOK:-}" && ! -e "$S/hook_done" ]]; then
              : > "$S/hook_done"; NEW_ID="" eval "$FAKE_AFTER_POST_HOOK"
            fi
            echo "gh: HTTP 422: could not create comment" >&2; exit 1
          fi
          ID=$(( $(cat "$S/next_id") + 1 )); echo "$ID" > "$S/next_id"
          CREATED="${FAKE_COMMENT_CREATED_AT:-$(date -u +%FT%TZ)}"
          jq --argjson id "$ID" --arg body "$FIELD_BODY" --arg login "${FAKE_VIEWER:-}" --arg at "$CREATED" \
            '. + [{id: $id, body: $body, created_at: $at, user: {login: $login}}]' \
            "$S/comments.json" > "$S/c.tmp" && mv "$S/c.tmp" "$S/comments.json"
          # Single-use after-post hook: simulates a concurrent writer acting
          # between this POST and the caller's verification re-read.
          if [[ -n "${FAKE_AFTER_POST_HOOK:-}" && ! -e "$S/hook_done" ]]; then
            : > "$S/hook_done"
            NEW_ID="$ID" eval "$FAKE_AFTER_POST_HOOK"
          fi
          if [[ "${FAKE_COMMENT_POST_MODE:-ok}" == "land-error" ]]; then
            echo "gh: HTTP 502: bad gateway" >&2; exit 1   # the write landed anyway
          fi
          jq -n --argjson id "$ID" --arg at "$CREATED" '{id: $id, created_at: $at}'
          exit 0
        fi
        READS=$(( $(cat "$S/comment_reads") + 1 )); echo "$READS" > "$S/comment_reads"
        if [[ -n "${FAKE_COMMENTS_FAIL_AFTER:-}" ]] && (( READS > FAKE_COMMENTS_FAIL_AFTER )); then
          echo "gh: HTTP 500: internal server error" >&2; exit 1
        fi
        case "${FAKE_COMMENTS_MODE:-json}" in
          error) echo "gh: HTTP 500: internal server error" >&2; exit 1 ;;
          *) cat "$S/comments.json" ;;
        esac
        # Single-use hook after the Nth comment read returns (#1933): simulates
        # a concurrent writer acting between that read and the caller's next step.
        if [[ -n "${FAKE_AFTER_COMMENTS_READ_HOOK:-}" && ! -e "$S/read_hook_done" ]] \
           && (( READS == ${FAKE_AFTER_COMMENTS_READ_AT:-1} )); then
          : > "$S/read_hook_done"; eval "$FAKE_AFTER_COMMENTS_READ_HOOK"
        fi
        ;;
      */timeline*)
        cat "$S/timeline.json"
        ;;
      */issues/*)
        case "${FAKE_ISSUE_MODE:-json}" in
          404)   echo "gh: HTTP 404: Not Found (https://api.github.com/$ENDPOINT)" >&2; exit 1 ;;
          error) echo "gh: HTTP 500: internal server error" >&2; exit 1 ;;
          *)
            jq -n \
              --argjson labels "$(json_array_of_lines "$S/labels")" \
              --argjson assignees "$(json_array_of_lines "$S/assignees")" \
              --arg state "$(cat "$S/issue_state" 2>/dev/null || echo open)" \
              '{number: 873, state: $state,
                labels: ($labels | map({name: .})),
                assignees: ($assignees | map({login: .}))}'
            ;;
        esac
        ;;
      *) echo "unexpected endpoint: $ENDPOINT" >&2; exit 99 ;;
    esac
    ;;
  issue)
    sub="${2:-}"; shift 2
    # drop the issue number positional
    [[ "${1:-}" =~ ^[0-9]+$ ]] && shift
    case "$sub" in
      edit)
        # Edit counter + Nth-edit failure switch + single-use after-Nth-edit
        # hook (#1933). A failed edit writes nothing.
        EDITS=$(( $(cat "$S/edit_calls" 2>/dev/null || echo 0) + 1 )); echo "$EDITS" > "$S/edit_calls"
        if [[ -n "${FAKE_EDIT_FAIL_AT:-}" ]] && (( EDITS == FAKE_EDIT_FAIL_AT )); then
          echo "gh: HTTP 502: could not edit issue" >&2; exit 1
        fi
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo) shift 2 ;;
            --add-label)    grep -qxF "$2" "$S/labels"    || echo "$2" >> "$S/labels"; shift 2 ;;
            --remove-label) grep -vxF "$2" "$S/labels" > "$S/l.tmp" || true; mv "$S/l.tmp" "$S/labels"; shift 2 ;;
            --add-assignee)
              who="$2"; [[ "$who" == "@me" ]] && who="${FAKE_VIEWER:-}"
              grep -qxF "$who" "$S/assignees" || echo "$who" >> "$S/assignees"; shift 2 ;;
            --remove-assignee)
              grep -vxF "$2" "$S/assignees" > "$S/a.tmp" || true; mv "$S/a.tmp" "$S/assignees"; shift 2 ;;
            *) shift ;;
          esac
        done
        if [[ -n "${FAKE_AFTER_EDIT_HOOK:-}" && ! -e "$S/edit_hook_done" ]] \
           && (( EDITS == ${FAKE_AFTER_EDIT_AT:-1} )); then
          : > "$S/edit_hook_done"; eval "$FAKE_AFTER_EDIT_HOOK"
        fi
        echo "edited"
        ;;
      comment)
        BODY=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo) shift 2 ;;
            --body) BODY="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        if [[ "${FAKE_COMMENT_POST_MODE:-ok}" == "error" ]]; then
          echo "gh: HTTP 422: could not create comment" >&2; exit 1
        fi
        ID=$(( $(cat "$S/next_id") + 1 )); echo "$ID" > "$S/next_id"
        CREATED="${FAKE_COMMENT_CREATED_AT:-$(date -u +%FT%TZ)}"
        jq --argjson id "$ID" --arg body "$BODY" --arg login "${FAKE_VIEWER:-}" --arg at "$CREATED" \
          '. + [{id: $id, body: $body, created_at: $at, user: {login: $login}}]' \
          "$S/comments.json" > "$S/c.tmp" && mv "$S/c.tmp" "$S/comments.json"
        echo "commented"
        ;;
      *) echo "unexpected issue subcommand: $sub" >&2; exit 99 ;;
    esac
    ;;
  label)
    sub="${2:-}"; shift 2
    case "$sub" in
      list) json_array_of_lines "$S/repo_labels" | jq '[ .[] | {name: .} ]' ;;
      create)
        NAME="$1"
        if grep -qxF "$NAME" "$S/repo_labels"; then
          echo "gh: label already exists" >&2; exit 1
        fi
        echo "$NAME" >> "$S/repo_labels"; echo "created"
        ;;
      *) echo "unexpected label subcommand: $sub" >&2; exit 99 ;;
    esac
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

# The stub's `gh label list --json name --jq EXPR` path ignores --jq, so the
# script's own jq expression never runs against it. Give the real flag shape a
# home by post-filtering here instead: the stub prints the raw JSON and the
# script's --jq is a no-op, which is exactly how a caller-side jq failure would
# look. Verified separately in test (10).

run() {
  # run <args...> ; sets OUT (stdout), ERR (stderr), RC (exit code)
  local errfile="$TMP/err"
  OUT="$("$CLAIM_TEST_SHELL" "$SCRIPT" "$@" 2>"$errfile")"; RC=$?
  ERR="$(cat "$errfile")"
}

claim_comment_count() {
  jq '[ .[] | select(.body | contains("<!-- claude-claim:")) ] | length' "$STATE/comments.json"
}

############################################################################
echo "== (1) claim on an unclaimed issue: writes label + assignee + claim comment =="
reset_issue
run 873 --check --holder threadA
check_eq "unclaimed before" "unclaimed" "$OUT"
check_eq "exit 0 (startable)" 0 "$RC"
run 873 --claim --holder threadA
check_eq "verdict mine" "mine" "$OUT"
check_eq "exit 0" 0 "$RC"
check_eq "in-progress label written" "in-progress" "$(cat "$STATE/labels")"
check_eq "assignee written" "alice" "$(cat "$STATE/assignees")"
check_eq "one claim comment" 1 "$(claim_comment_count)"
check_eq "label created in repo" "true" "$(grep -qxF in-progress "$STATE/repo_labels" && echo true)"

# A repo-relative helper can run without a home. The optional usage ledger
# must not prevent the actual check, write or independent read-back.
reset_issue
OUT=$(env -u HOME "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --check --repo acme/widgets --holder no-home 2>"$TMP/no-home.err"); RC=$?
check_eq "unset HOME: check reaches the native stub" 0 "$RC"
check_eq "unset HOME: unclaimed issue is still startable" unclaimed "$OUT"
check_eq "unset HOME: no unbound-variable error" "" "$(cat "$TMP/no-home.err")"
OUT=$(env -u HOME "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --claim --repo acme/widgets --holder no-home 2>"$TMP/no-home.err"); RC=$?
check_eq "unset HOME: claim succeeds" 0 "$RC"
check_eq "unset HOME: exactly one marker is written" 1 "$(claim_comment_count)"
OUT=$(env -u HOME "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --check --repo acme/widgets --holder no-home 2>"$TMP/no-home.err"); RC=$?
check_eq "unset HOME: claim reads back as mine" "0|mine" "$RC|$OUT"
check_eq "set HOME: usage ledger remains available" true "$(if grep -Fq issue-claim.sh "$HOME/.claude/script-usage.log"; then echo true; else echo false; fi)"
# claimed_at/claimed_since come from the marker's GitHub created_at, not the
# local clock, so they match what every later --check reports.
reset_issue
MARKER_AT="$(iso_ago 1)"
FAKE_COMMENT_CREATED_AT="$MARKER_AT" run 873 --claim --holder threadA --json
check_eq "initial claim: claimed_at is the marker's created_at" "$MARKER_AT" "$(jq -r .claimed_at <<<"$OUT")"
check_eq "initial claim: claimed_since matches" "$MARKER_AT" "$(jq -r .claimed_since <<<"$OUT")"
CLAIM_AT_OUT="$(jq -r .claimed_since <<<"$OUT")"
run 873 --check --holder threadA --json
check_eq "initial claim: --check reports the same pickup time" "$CLAIM_AT_OUT" "$(jq -r .claimed_since <<<"$OUT")"

############################################################################
echo "== (2) a SECOND thread of the same account is blocked — with no PR anywhere =="
# This is the failure the feature exists for: both threads authenticate as the
# same login, so an assignee-only check would answer 'mine' and start anyway.
run 873 --check --holder threadB
check_eq "verdict claimed" "claimed" "$OUT"
check_eq "exit 1 (blocked)" 1 "$RC"
check_contains "names the claim" "already being worked" "$ERR"
run 873 --claim --holder threadB
check_eq "claim refused" "claimed" "$OUT"
check_eq "exit 1 (blocked)" 1 "$RC"
check_eq "still one claim comment" 1 "$(claim_comment_count)"

############################################################################
echo "== (3) re-claim by the SAME holder is a no-op (resume / post-compaction) =="
run 873 --check --holder threadA
check_eq "verdict mine" "mine" "$OUT"
check_eq "exit 0" 0 "$RC"
run 873 --claim --holder threadA
check_eq "verdict mine" "mine" "$OUT"
check_eq "exit 0 (no error)" 0 "$RC"
check_eq "no duplicate marker" 1 "$(claim_comment_count)"
check_eq "assignee not duplicated" "alice" "$(cat "$STATE/assignees")"

############################################################################
echo "== (4) release returns the issue to unclaimed =="
run 873 --release --holder threadA
check_eq "verdict unclaimed" "unclaimed" "$OUT"
check_eq "exit 0" 0 "$RC"
check_eq "label removed" "" "$(cat "$STATE/labels")"
check_eq "assignee removed" "" "$(cat "$STATE/assignees")"
check_eq "claim comment deleted" 0 "$(claim_comment_count)"
run 873 --check --holder threadB
check_eq "startable again for another thread" "unclaimed" "$OUT"
check_eq "exit 0" 0 "$RC"
run 873 --release --holder threadA
check_eq "release is idempotent" 0 "$RC"

############################################################################
echo "== (5) a claim older than CLAIM_STALE_HOURS is stale and STARTABLE =="
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 5)" run 873 --claim --holder threadA
check_eq "claim written" 0 "$RC"
run 873 --check --holder threadB
check_eq "verdict stale" "stale" "$OUT"
check_eq "exit 0 (warning, NOT a block)" 0 "$RC"
check_contains "stale surfaced on stderr" "stale window" "$ERR"
run 873 --check --holder threadB --json
check_eq "json stale flag" "true" "$(jq -r '.stale' <<<"$OUT")"
# A fresher window keeps the very same claim live — proves the boundary is the
# timestamp, not an incidental property of the fixture.
CLAIM_STALE_HOURS=9 run 873 --check --holder threadB
check_eq "not stale under a 9h window" "claimed" "$OUT"
check_eq "exit 1 (blocked)" 1 "$RC"

echo "== (5b) --claim takes over a stale claim and re-stamps it =="
run 873 --claim --holder threadB
check_eq "verdict mine" "mine" "$OUT"
check_eq "exit 0" 0 "$RC"
check_eq "exactly one claim comment after takeover" 1 "$(claim_comment_count)"
run 873 --check --holder threadA
check_eq "original thread is now the blocked one" "claimed" "$OUT"
check_eq "exit 1" 1 "$RC"

############################################################################
echo "== (6) --allow-claimed overrides a fresh foreign claim and SAYS SO =="
reset_issue
run 873 --claim --holder threadA
check_eq "claim held by threadA" 0 "$RC"
run 873 --claim --holder threadB
check_eq "blocked without the override" 1 "$RC"
run 873 --claim --holder threadB --allow-claimed
check_eq "verdict mine" "mine" "$OUT"
check_eq "exit 0 (override authorized)" 0 "$RC"
check_contains "states that it is overriding" "OVERRIDE" "$ERR"
run 873 --check --holder threadB --json
check_eq "override transferred the claim" "mine" "$(jq -r '.verdict' <<<"$OUT")"

############################################################################
echo "== (7) issue not found -> exit 3 =="
reset_issue
FAKE_ISSUE_MODE=404 run 873 --check --holder threadA
check_eq "exit 3 (not found)" 3 "$RC"

############################################################################
echo "== (8) fail-closed: gh errors NEVER read as unclaimed =="
reset_issue
FAKE_ISSUE_MODE=error run 873 --check --holder threadA
check_eq "verdict unknown" "unknown" "$OUT"
check_eq "exit 4 (fail-closed)" 4 "$RC"
FAKE_VIEWER=__FAIL__ run 873 --check --holder threadA
check_eq "unknown on viewer failure" "unknown" "$OUT"
check_eq "exit 4" 4 "$RC"
FAKE_COMMENTS_MODE=error run 873 --check --holder threadA
check_eq "unknown on comment-read failure" "unknown" "$OUT"
check_eq "exit 4" 4 "$RC"
# A failed claim write must not report success.
FAKE_ISSUE_MODE=error run 873 --claim --holder threadA
check_eq "claim fails closed too" 4 "$RC"

############################################################################
echo "== (8b) an unreadable winning marker is not an absent claim =="
reset_issue
jq -n --arg at "$(iso_ago 1)" '[
  {id:1,created_at:$at,user:{login:"bob"},body:"<!-- claude-claim: {\"holder\":\"threadBob\",\"login\":\"bob\"} -->"},
  {id:2,created_at:$at,user:{login:"alice"},body:"<!-- claude-claim: {\"holder\":broken} -->"}
]' > "$STATE/comments.json"
cp "$STATE/comments.json" "$STATE/comments-before-malformed.json"
LABELS_BEFORE=$(cat "$STATE/repo_labels")
for MODE in --check --claim --renew --release; do
  if [[ "$MODE" == --release ]]; then
    run 873 "$MODE" --holder threadA --expect-claim-id none --json
  else
    run 873 "$MODE" --holder threadA --json
  fi
  check_eq "$MODE refuses an unreadable newest marker" 4 "$RC"
  check_eq "$MODE reports unknown, not an older or absent claim" unknown "$(jq -r .verdict <<<"$OUT")"
done
run 873 --claim --holder threadA --allow-claimed --json
check_eq "explicit foreign-claim override cannot interpret corrupt ownership" 4 "$RC"
cmp -s "$STATE/comments-before-malformed.json" "$STATE/comments.json"
check_eq "the markers remain byte-for-byte intact" 0 "$?"
check_eq "no label/assignee edit" 0 "$(cat "$STATE/edit_calls")"
check_eq "no new comment was posted" 0 "$(cat "$STATE/next_id")"
check_eq "no repository label was created" "$LABELS_BEFORE" "$(cat "$STATE/repo_labels")"

jq '.[1].body="<!-- claude-claim: {\"holder\":[],\"login\":\"alice\"} -->"' \
  "$STATE/comments.json" > "$STATE/comments.tmp" && mv "$STATE/comments.tmp" "$STATE/comments.json"
run 873 --check --holder threadA --json
check_eq "a parsed payload with a non-string holder also fails closed" 4 "$RC"
# A well-formed JSON string still must round-trip through the shell without
# changing the holder. These two values previously read as this thread.
for INVALID_HOLDER in '"threadA\u001falice"' '"threadA\u0000"'; do
  jq --argjson holder "$INVALID_HOLDER" \
    '.[1].body=("<!-- claude-claim: " + ({holder:$holder,login:"alice"}|tojson) + " -->")' \
    "$STATE/comments.json" > "$STATE/comments.tmp" && mv "$STATE/comments.tmp" "$STATE/comments.json"
  run 873 --check --holder threadA --json
  check_eq "$INVALID_HOLDER cannot be mistaken for this thread" 4 "$RC"
  check_eq "$INVALID_HOLDER is unreadable" unknown "$(jq -r .verdict <<<"$OUT")"
done
run 873 --claim --holder $'threadA\n' --json
check_eq "trailing newline in the requested holder is rejected before trimming" 2 "$RC"
run 873 --claim --holder $'threadA\x1falice' --json
check_eq "separator in the requested holder is rejected before writing" 2 "$RC"
check_eq "invalid requested holders do not post a marker" 0 "$(cat "$STATE/next_id")"
check_eq "invalid requested holders do not edit ownership" 0 "$(cat "$STATE/edit_calls")"
# Same timestamp: id ordering still allows the newest readable winner.
jq '.[0].id=3' "$STATE/comments.json" > "$STATE/comments.tmp" && mv "$STATE/comments.tmp" "$STATE/comments.json"
run 873 --check --holder threadA --json
check_eq "an older malformed marker does not hide the newer valid claim" claimed "$(jq -r .verdict <<<"$OUT")"
check_eq "the newer foreign claim still blocks normally" 1 "$RC"

############################################################################
echo "== (9) a collaborator's claim is never released or overwritten (#732) =="
reset_issue
export FAKE_VIEWER="bob"
run 873 --claim --holder threadBob
check_eq "bob holds the claim" 0 "$RC"
export FAKE_VIEWER="alice"
run 873 --release --holder threadA
check_eq "release exits 0 (nothing of alice's to drop)" 0 "$RC"
check_eq "collaborator label untouched" "in-progress" "$(cat "$STATE/labels")"
check_eq "collaborator assignee untouched" "bob" "$(cat "$STATE/assignees")"
check_eq "collaborator claim comment untouched" 1 "$(claim_comment_count)"
run 873 --check --holder threadA
check_eq "still blocked for alice" "claimed" "$OUT"
check_eq "exit 1" 1 "$RC"

echo "== (9b) overriding a collaborator's claim never deletes their comment (#732) =="
# The override authorizes starting the work, not editing someone else's writing.
run 873 --claim --holder threadA --allow-claimed
check_eq "override succeeds" 0 "$RC"
check_eq "bob's comment survives alongside alice's" 2 "$(claim_comment_count)"
check_eq "bob's comment specifically is intact" 1 \
  "$(jq '[ .[] | select(.user.login == "bob" and (.body | contains("<!-- claude-claim:"))) ] | length' "$STATE/comments.json")"
# The newest claim comment decides the verdict, so the stale one is inert.
run 873 --check --holder threadA
check_eq "alice now holds it" "mine" "$OUT"
run 873 --check --holder threadB
check_eq "threadB still blocked" "claimed" "$OUT"

############################################################################
echo "== (10) a hand-applied label with no claim comment still blocks =="
reset_issue
echo "in-progress" > "$STATE/labels"
jq -n --arg at "$(iso_ago 1)" '[{event: "labeled", label: {name: "in-progress"}, created_at: $at}]' \
  > "$STATE/timeline.json"
run 873 --check --holder threadA
check_eq "verdict claimed" "claimed" "$OUT"
check_eq "exit 1 (blocked)" 1 "$RC"
# ...and the timeline supplies the timestamp, so it can still age out.
jq -n --arg at "$(iso_ago 6)" '[{event: "labeled", label: {name: "in-progress"}, created_at: $at}]' \
  > "$STATE/timeline.json"
run 873 --check --holder threadA
check_eq "ages out via the labeled timeline event" "stale" "$OUT"
check_eq "exit 0" 0 "$RC"

############################################################################
echo "== (12) a failed claim comment ROLLS BACK the label + assignee =="
# A half-written claim is worse than none: `mine` needs a parsed claim comment,
# so the thread that wrote the label would read its own claim back as foreign.
reset_issue
FAKE_COMMENT_POST_MODE=error run 873 --claim --holder threadA
check_eq "verdict unknown (fail-closed)" "unknown" "$OUT"
check_eq "exit 4" 4 "$RC"
check_eq "label rolled back" "" "$(cat "$STATE/labels")"
check_eq "assignee rolled back" "" "$(cat "$STATE/assignees")"
check_contains "says it rolled back" "rolled back" "$ERR"
run 873 --check --holder threadA
check_eq "issue is startable again" "unclaimed" "$OUT"
check_eq "exit 0" 0 "$RC"
# ...and the SAME holder can now claim for real (the orphan-label trap is gone).
run 873 --claim --holder threadA
check_eq "same holder can claim after rollback" "mine" "$OUT"
check_eq "exit 0" 0 "$RC"

echo "== (12b) rollback preserves a label this run did NOT add =="
# Stale takeover on a hand-labelled issue: rollback must not strip a pre-existing marker.
reset_issue
echo "in-progress" > "$STATE/labels"
jq -n --arg at "$(iso_ago 6)" '[{event:"labeled",label:{name:"in-progress"},created_at:$at}]' > "$STATE/timeline.json"
FAKE_COMMENT_POST_MODE=error run 873 --claim --holder threadA
check_eq "exit 4" 4 "$RC"
check_eq "pre-existing label left intact" "in-progress" "$(cat "$STATE/labels")"

echo "== (13) release removes the comment BEFORE the label =="
# Ordering matters: /wave pre-filters a backlog on the label, so a partial release
# must never leave a claim comment with no label (invisible => reads as unclaimed).
# It may leave a label with no comment (still blocks, and expires on its own).
reset_issue
run 873 --claim --holder threadA
check_eq "claim held" 0 "$RC"
FAKE_COMMENT_DELETE_MODE=error run 873 --release --holder threadA
check_eq "partial release fails closed" 4 "$RC"
check_eq "label still present (comment delete failed first)" "in-progress" "$(cat "$STATE/labels")"
check_eq "claim comment still present" 1 "$(claim_comment_count)"
run 873 --check --holder threadB
check_eq "still blocks another thread" "claimed" "$OUT"
check_eq "exit 1" 1 "$RC"
# A retry with the delete working completes the release.
run 873 --release --holder threadA
check_eq "retry succeeds" 0 "$RC"
check_eq "label gone" "" "$(cat "$STATE/labels")"
check_eq "comment gone" 0 "$(claim_comment_count)"

############################################################################
# Renewal (issue #1914). Default stale window 4h, renewal threshold 120m.
marker_ids() {   # space-joined ids of the claim comments, oldest first
  jq -r '[ .[] | select(.body | contains("<!-- claude-claim:")) | .id ] | map(tostring) | join(" ")' "$STATE/comments.json"
}
newest_marker_field() {  # newest_marker_field <jq-expr on the comment>
  jq -r "[ .[] | select(.body | contains(\"<!-- claude-claim:\")) ] | sort_by(.created_at, .id) | last | $1" "$STATE/comments.json"
}
age_newest_marker() {    # age_newest_marker <hours>: rewrite the newest marker's created_at
  local at; at="$(iso_ago "$1")"
  local nid; nid="$(newest_marker_field .id)"
  jq --argjson id "$nid" --arg at "$at" 'map(if .id == $id then .created_at = $at else . end)' \
    "$STATE/comments.json" > "$STATE/c.tmp" && mv "$STATE/c.tmp" "$STATE/comments.json"
}
posts_made() { cat "$STATE/next_id"; }

echo "== (14) same holder, younger than the renewal threshold: no write =="
reset_issue
run 873 --claim --holder threadA
OLD_ID="$(marker_ids)"; OLD_AT="$(newest_marker_field .created_at)"; POSTS="$(posts_made)"
run 873 --claim --holder threadA --json
check_eq "--claim: verdict mine" "mine" "$(jq -r .verdict <<<"$OUT")"
check_eq "--claim: exit 0" 0 "$RC"
check_eq "--claim: renewed false" "false" "$(jq -r .renewed <<<"$OUT")"
run 873 --renew --holder threadA --json
check_eq "--renew: verdict mine" "mine" "$(jq -r .verdict <<<"$OUT")"
check_eq "--renew: exit 0" 0 "$RC"
check_eq "--renew: renewed false" "false" "$(jq -r .renewed <<<"$OUT")"
check_eq "--renew: claimed_at unchanged" "$OLD_AT" "$(jq -r .claimed_at <<<"$OUT")"
check_eq "marker id unchanged" "$OLD_ID" "$(marker_ids)"
check_eq "no comment posted" "$POSTS" "$(posts_made)"
echo 0 > "$STATE/edit_calls"
run 873 --renew --holder threadA
run 873 --claim --holder threadA
check_eq "not due, label + assignee present: no issue edit (#1933 repair is a no-op)" 0 "$(cat "$STATE/edit_calls")"

echo "== (15) same holder, past the threshold but inside the stale window: renews =="
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
OLD_ID="$(marker_ids)"; OLD_AT="$(newest_marker_field .created_at)"
run 873 --renew --holder threadA --json
check_eq "verdict mine" "mine" "$(jq -r .verdict <<<"$OUT")"
check_eq "exit 0" 0 "$RC"
check_eq "renewed true" "true" "$(jq -r .renewed <<<"$OUT")"
check_contains "reason names the renewal" "renewed" "$(jq -r .reason <<<"$OUT")"
check_eq "exactly one marker remains" 1 "$(claim_comment_count)"
NEW_ID="$(marker_ids)"
check_eq "marker id changed" "true" "$([[ "$NEW_ID" != "$OLD_ID" ]] && echo true)"
check_eq "claimed_at is the new marker's GitHub created_at" "$(newest_marker_field .created_at)" "$(jq -r .claimed_at <<<"$OUT")"
check_eq "previous_claimed_at is the replaced marker" "$OLD_AT" "$(jq -r .previous_claimed_at <<<"$OUT")"
check_eq "claimed_since keeps the original pickup time" "$OLD_AT" "$(jq -r .claimed_since <<<"$OUT")"
check_contains "payload carries since" "\"since\":\"$OLD_AT\"" "$(newest_marker_field .body)"
check_contains "payload carries a per-run nonce" '"run":"' "$(newest_marker_field .body)"
check_contains "visible text says renew, not 'no activity'" "if not renewed within 4h" "$(newest_marker_field .body)"
check_eq "label still present" "in-progress" "$(cat "$STATE/labels")"
check_eq "assignee still present" "alice" "$(cat "$STATE/assignees")"
run 873 --check --holder threadB
check_eq "another holder is blocked by the fresh renewal" "claimed" "$OUT"
# A second renewal keeps the ORIGINAL since, not the first renewal's created_at.
age_newest_marker 3
run 873 --claim --holder threadA --json
check_eq "--claim renews when due" "true" "$(jq -r .renewed <<<"$OUT")"
check_eq "since survives a second renewal" "$OLD_AT" "$(jq -r .claimed_since <<<"$OUT")"
check_eq "still exactly one marker" 1 "$(claim_comment_count)"
run 873 --check --holder threadA --json
check_eq "--check reports claimed_since from the payload" "$OLD_AT" "$(jq -r .claimed_since <<<"$OUT")"
# A custom threshold is honoured: 200m makes a 3h marker not yet due.
age_newest_marker 3
POSTS="$(posts_made)"
CLAIM_RENEW_MINUTES=200 run 873 --renew --holder threadA --json
check_eq "CLAIM_RENEW_MINUTES=200: not due" "false" "$(jq -r .renewed <<<"$OUT")"
check_eq "CLAIM_RENEW_MINUTES=200: no post" "$POSTS" "$(posts_made)"
# A threshold at or past the 4h stale window is rejected: 300m falls back to
# the default 120m (with a warning), so the 3h marker renews instead of
# idling until another holder could read it as stale.
CLAIM_RENEW_MINUTES=300 run 873 --renew --holder threadA --json
check_eq "CLAIM_RENEW_MINUTES=300: exit 0" 0 "$RC"
check_eq "CLAIM_RENEW_MINUTES=300: falls back and renews" "true" "$(jq -r .renewed <<<"$OUT")"
check_contains "CLAIM_RENEW_MINUTES=300: warns" "not below the 4h stale window" "$ERR"
age_newest_marker 3
CLAIM_RENEW_MINUTES=240 run 873 --renew --holder threadA --json
check_eq "CLAIM_RENEW_MINUTES=240 (== window): falls back and renews" "true" "$(jq -r .renewed <<<"$OUT")"
age_newest_marker 3
# Leading zeros are decimal, not octal: `08`/`090` must not break arithmetic.
CLAIM_RENEW_MINUTES=090 run 873 --renew --holder threadA --json
check_eq "CLAIM_RENEW_MINUTES=090: exit 0" 0 "$RC"
check_eq "CLAIM_RENEW_MINUTES=090: 3h marker is due" "true" "$(jq -r .renewed <<<"$OUT")"
CLAIM_STALE_HOURS=08 run 873 --check --holder threadA
check_eq "CLAIM_STALE_HOURS=08: exit 0" 0 "$RC"
check_eq "CLAIM_STALE_HOURS=08: verdict mine" "mine" "$OUT"

echo "== (16) same holder, older than the stale window: renewed-after-expiry =="
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 5)" run 873 --claim --holder threadA
run 873 --renew --holder threadA --json
check_eq "exit 0" 0 "$RC"
check_eq "renewed true" "true" "$(jq -r .renewed <<<"$OUT")"
check_contains "reason renewed-after-expiry" "renewed-after-expiry" "$(jq -r .reason <<<"$OUT")"
check_contains "stderr warns about the expiry gap" "stale window" "$ERR"
check_eq "one marker" 1 "$(claim_comment_count)"
run 873 --check --holder threadB
check_eq "another holder now sees claimed, not stale" "claimed" "$OUT"
check_eq "exit 1" 1 "$RC"

echo "== (17) --renew never acquires or takes over =="
reset_issue
run 873 --claim --holder threadA
POSTS="$(posts_made)"; IDS="$(marker_ids)"
run 873 --renew --holder threadB
check_eq "fresh foreign: verdict claimed" "claimed" "$OUT"
check_eq "fresh foreign: exit 5" 5 "$RC"
check_contains "fresh foreign: not-held" "not-held" "$ERR"
check_eq "fresh foreign: nothing posted" "$POSTS" "$(posts_made)"
check_eq "fresh foreign: markers unchanged" "$IDS" "$(marker_ids)"
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 5)" run 873 --claim --holder threadA
IDS="$(marker_ids)"
run 873 --renew --holder threadB
check_eq "stale foreign: verdict stale" "stale" "$OUT"
check_eq "stale foreign: exit 5 (no takeover)" 5 "$RC"
check_eq "stale foreign: markers unchanged" "$IDS" "$(marker_ids)"
check_eq "stale foreign: holder unchanged" "threadA" "$(newest_marker_field '.body | capture("claude-claim: (?<p>.*) -->").p | fromjson | .holder')"
run 873 --claim --holder threadB
check_eq "stale --claim takeover still works for dead work" "mine" "$OUT"
check_eq "takeover exit 0" 0 "$RC"
reset_issue
run 873 --renew --holder threadA
check_eq "unclaimed: verdict unclaimed" "unclaimed" "$OUT"
check_eq "unclaimed: exit 5" 5 "$RC"
check_eq "unclaimed: no label written" "" "$(cat "$STATE/labels")"
check_eq "unclaimed: no comment written" 0 "$(claim_comment_count)"

echo "== (18) a collaborator's marker with the same holder token is never renewed =="
reset_issue
export FAKE_VIEWER="bob"
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder shared
export FAKE_VIEWER="alice"
POSTS="$(posts_made)"; IDS="$(marker_ids)"
run 873 --renew --holder shared
check_eq "--renew: exit 5" 5 "$RC"
check_contains "--renew: renew-not-authorized" "renew-not-authorized" "$ERR"
run 873 --claim --holder shared
check_eq "--claim: still mine/0 (old behaviour)" "mine" "$OUT"
check_eq "--claim: exit 0" 0 "$RC"
check_contains "--claim: warns renew-not-authorized" "renew-not-authorized" "$ERR"
check_eq "nothing posted" "$POSTS" "$(posts_made)"
check_eq "bob's marker intact" "$IDS" "$(marker_ids)"
check_eq "bob's assignment intact, alice not added" "bob" "$(cat "$STATE/assignees")"

echo "== (19) failed and ambiguous renewal writes =="
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
IDS="$(marker_ids)"
FAKE_COMMENT_POST_MODE=error run 873 --renew --holder threadA
check_eq "post failure: unknown" "unknown" "$OUT"
check_eq "post failure: exit 4" 4 "$RC"
check_contains "post failure: renew-failed" "renew-failed" "$ERR"
check_eq "post failure: old marker kept" "$IDS" "$(marker_ids)"
check_eq "post failure: label kept" "in-progress" "$(cat "$STATE/labels")"
run 873 --check --holder threadB
check_eq "post failure: the old fresh claim still blocks" "claimed" "$OUT"
check_eq "exit 1" 1 "$RC"

FAKE_COMMENT_POST_MODE=land-error run 873 --renew --holder threadA --json
check_eq "landed-but-failed post: reconciled as renewal" "true" "$(jq -r .renewed <<<"$OUT")"
check_eq "landed-but-failed post: exit 0" 0 "$RC"
check_eq "landed-but-failed post: one marker" 1 "$(claim_comment_count)"
check_eq "landed-but-failed post: old marker gone" "true" "$([[ "$(marker_ids)" != "$IDS" ]] && echo true)"

age_newest_marker 3
FAKE_COMMENT_DELETE_MODE=error run 873 --renew --holder threadA --json
check_eq "cleanup failure: still renewed" "true" "$(jq -r .renewed <<<"$OUT")"
check_eq "cleanup failure: exit 0" 0 "$RC"
check_contains "cleanup failure: warns about the duplicate" "duplicate" "$ERR"
check_eq "cleanup failure: duplicate left behind" 2 "$(claim_comment_count)"
age_newest_marker 3
run 873 --renew --holder threadA
check_eq "a later renewal succeeds" 0 "$RC"
check_eq "a later renewal leaves exactly one marker" 1 "$(claim_comment_count)"

age_newest_marker 3
IDS="$(marker_ids)"
echo 0 > "$STATE/comment_reads"
FAKE_COMMENTS_FAIL_AFTER=1 run 873 --renew --holder threadA
check_eq "verify-read failure: unknown" "unknown" "$OUT"
check_eq "verify-read failure: exit 4" 4 "$RC"
check_contains "verify-read failure: renew-unverified" "renew-unverified" "$ERR"
check_eq "verify-read failure: no old marker deleted" 2 "$(claim_comment_count)"
check_contains "verify-read failure: old marker still present" "$IDS" "$(marker_ids)"

echo "== (20) concurrent takeover during a renewal =="
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
OLD_IDS="$(marker_ids)"
# Between our POST and our verification read, threadB posts a newer marker
# (same created_at second as ours; the higher id wins the tie).
# The winner is itself a renewal: its payload `since` is threadB's pickup time.
W_PICKUP="$(iso_ago 2)"
jq -n --arg at "$(date -u +%FT%TZ)" --arg since "$W_PICKUP" '{id: 999999, created_at: $at, user: {login: "alice"},
  body: ("<!-- claude-claim: " + ({holder: "threadB", login: "alice", since: $since} | tojson) + " -->")}' \
  > "$STATE/inject.json"
FAKE_COMMENT_CREATED_AT="$(jq -r .created_at "$STATE/inject.json")" \
FAKE_AFTER_POST_HOOK='
  jq --slurpfile x "$S/inject.json" ". + \$x" "$S/comments.json" > "$S/h.tmp" \
    && mv "$S/h.tmp" "$S/comments.json"
  echo "$NEW_ID" > "$S/our_new_id"' \
  run 873 --renew --holder threadA --json
check_eq "superseded: exit 5" 5 "$RC"
check_eq "superseded: verdict claimed" "claimed" "$(jq -r .verdict <<<"$OUT")"
check_contains "superseded: reason" "superseded" "$(jq -r .reason <<<"$OUT")"
check_eq "superseded: reports the winner" "threadB" "$(jq -r .claimant_holder <<<"$OUT")"
check_eq "superseded: claimed_since is the winner's pickup, not its renewal" "$W_PICKUP" "$(jq -r .claimed_since <<<"$OUT")"
OUR_NEW="$(cat "$STATE/our_new_id")"
check_eq "superseded: our new marker was removed" "" \
  "$(jq -r --argjson id "$OUR_NEW" '.[] | select(.id == $id) | .id' "$STATE/comments.json")"
check_eq "superseded: foreign marker kept" "threadB" "$(newest_marker_field '.body | capture("claude-claim: (?<p>.*) -->").p | fromjson | .holder')"
check_contains "superseded: old marker not deleted" "$OLD_IDS" "$(marker_ids)"
run 873 --check --holder threadA
check_eq "superseded: threadA is now blocked" "claimed" "$OUT"

# Errored-but-landed POST while a foreign marker wins: the POST returns no id,
# yet this run's marker must still be removed so it cannot resurface later.
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
OLD_IDS="$(marker_ids)"
jq -n --arg at "$(date -u +%FT%TZ)" '{id: 999999, created_at: $at, user: {login: "alice"},
  body: ("<!-- claude-claim: " + ({holder: "threadB", login: "alice"} | tojson) + " -->")}' \
  > "$STATE/inject.json"
FAKE_COMMENT_POST_MODE=land-error \
FAKE_COMMENT_CREATED_AT="$(jq -r .created_at "$STATE/inject.json")" \
FAKE_AFTER_POST_HOOK='
  jq --slurpfile x "$S/inject.json" ". + \$x" "$S/comments.json" > "$S/h.tmp" \
    && mv "$S/h.tmp" "$S/comments.json"
  echo "$NEW_ID" > "$S/our_new_id"' \
  run 873 --renew --holder threadA --json
check_eq "landed+superseded: exit 5" 5 "$RC"
check_contains "landed+superseded: reason" "superseded" "$(jq -r .reason <<<"$OUT")"
OUR_NEW="$(cat "$STATE/our_new_id")"
check_eq "landed+superseded: the landed marker was removed" "" \
  "$(jq -r --argjson id "$OUR_NEW" '.[] | select(.id == $id) | .id' "$STATE/comments.json")"
check_contains "landed+superseded: old marker not deleted" "$OLD_IDS" "$(marker_ids)"
check_eq "landed+superseded: foreign marker kept" "999999" \
  "$(jq -r '.[] | select(.id == 999999) | .id' "$STATE/comments.json")"

reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
FAKE_AFTER_POST_HOOK='
  jq --argjson id "$NEW_ID" "[ .[] | select(.id != \$id) ]" "$S/comments.json" > "$S/h.tmp" \
    && mv "$S/h.tmp" "$S/comments.json"' \
  run 873 --renew --holder threadA
check_eq "new marker vanished: unknown" "unknown" "$OUT"
check_eq "new marker vanished: exit 4" 4 "$RC"
check_eq "new marker vanished: old marker kept" 1 "$(claim_comment_count)"

echo "== (21) concurrent release during a renewal never resurrects the claim =="
# Between our POST and our verification read, a --release (e.g. /wrap after
# merge) deletes the old marker and removes the label + assignee.
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
OLD_IDS="$(marker_ids)"
FAKE_AFTER_POST_HOOK='
  jq --argjson old "'"$OLD_IDS"'" "[ .[] | select(.id != \$old) ]" "$S/comments.json" > "$S/h.tmp" \
    && mv "$S/h.tmp" "$S/comments.json"
  : > "$S/labels"; : > "$S/assignees"' \
  run 873 --renew --holder threadA --json
check_eq "released: exit 5" 5 "$RC"
check_eq "released: verdict unclaimed" "unclaimed" "$(jq -r .verdict <<<"$OUT")"
check_contains "released: reason" "released" "$(jq -r .reason <<<"$OUT")"
check_eq "released: our new marker withdrawn" 0 "$(claim_comment_count)"
check_eq "released: label not re-added" "" "$(cat "$STATE/labels")"
check_eq "released: assignee not re-added" "" "$(cat "$STATE/assignees")"
run 873 --check --holder threadB
check_eq "released: issue reads unclaimed afterwards" "unclaimed" "$OUT"

# Same race, but the POST errored after landing (no id returned).
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
OLD_IDS="$(marker_ids)"
FAKE_COMMENT_POST_MODE=land-error \
FAKE_AFTER_POST_HOOK='
  jq --argjson old "'"$OLD_IDS"'" "[ .[] | select(.id != \$old) ]" "$S/comments.json" > "$S/h.tmp" \
    && mv "$S/h.tmp" "$S/comments.json"
  : > "$S/labels"; : > "$S/assignees"' \
  run 873 --renew --holder threadA
check_eq "released+landed: exit 5" 5 "$RC"
check_eq "released+landed: landed marker withdrawn" 0 "$(claim_comment_count)"
check_eq "released+landed: label not re-added" "" "$(cat "$STATE/labels")"

# Two same-holder renewals race (heartbeat --renew + resume --claim): sibling
# renewal A verifies first, deletes the old marker AND this run's new marker,
# and keeps its own. This run must not mistake that for a release and delete
# A's live marker.
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
OLD_IDS="$(marker_ids)"
jq -n --arg at "$(date -u +%FT%TZ)" '{id: 999999, created_at: $at, user: {login: "alice"},
  body: ("<!-- claude-claim: " + ({holder: "threadA", login: "alice"} | tojson) + " -->")}' \
  > "$STATE/inject.json"
FAKE_AFTER_POST_HOOK='
  jq --argjson old "'"$OLD_IDS"'" --argjson new "$NEW_ID" --slurpfile x "$S/inject.json" \
    "[ .[] | select(.id != \$old and .id != \$new) ] + \$x" "$S/comments.json" > "$S/h.tmp" \
    && mv "$S/h.tmp" "$S/comments.json"' \
  run 873 --renew --holder threadA --json
check_eq "concurrent same-holder: exit 0" 0 "$RC"
check_eq "concurrent same-holder: verdict mine" "mine" "$(jq -r .verdict <<<"$OUT")"
check_eq "concurrent same-holder: sibling's marker kept" "999999" "$(marker_ids)"
check_eq "concurrent same-holder: label kept" "in-progress" "$(cat "$STATE/labels")"
run 873 --check --holder threadB
check_eq "concurrent same-holder: other holders still blocked" "claimed" "$OUT"

# Errored-but-landed POST while a release is mid-flight (old marker already
# deleted, label not yet removed): the landed marker is this run's own, not a
# sibling renewal's, so it must be withdrawn and the label never re-asserted.
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
OLD_IDS="$(marker_ids)"
: > "$STATE/assignees"
FAKE_COMMENT_POST_MODE=land-error \
FAKE_AFTER_POST_HOOK='
  jq --argjson old "'"$OLD_IDS"'" "[ .[] | select(.id != \$old) ]" "$S/comments.json" > "$S/h.tmp" \
    && mv "$S/h.tmp" "$S/comments.json"' \
  run 873 --renew --holder threadA --json
check_eq "landed+mid-release: exit 5" 5 "$RC"
check_contains "landed+mid-release: reason released" "released" "$(jq -r .reason <<<"$OUT")"
check_eq "landed+mid-release: landed marker withdrawn" 0 "$(claim_comment_count)"
check_eq "landed+mid-release: assignee not re-added" "" "$(cat "$STATE/assignees")"

# POST failed WITHOUT landing while a sibling same-holder renewal won (it
# replaced the old marker with its own): the sibling's marker must never be
# mistaken for this run's — no reconcile by holder, nothing deleted, exit 4.
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
OLD_IDS="$(marker_ids)"
jq -n --arg at "$(date -u +%FT%TZ)" '{id: 999999, created_at: $at, user: {login: "alice"},
  body: ("<!-- claude-claim: " + ({holder: "threadA", login: "alice", run: "sibling-run"} | tojson) + " -->")}' \
  > "$STATE/inject.json"
FAKE_COMMENT_POST_MODE=error \
FAKE_AFTER_POST_HOOK='
  jq --argjson old "'"$OLD_IDS"'" --slurpfile x "$S/inject.json" \
    "[ .[] | select(.id != \$old) ] + \$x" "$S/comments.json" > "$S/h.tmp" \
    && mv "$S/h.tmp" "$S/comments.json"' \
  run 873 --renew --holder threadA
check_eq "failed POST + sibling won: exit 4" 4 "$RC"
check_contains "failed POST + sibling won: renew-failed" "renew-failed" "$ERR"
check_eq "failed POST + sibling won: sibling's marker kept" "999999" "$(marker_ids)"
check_eq "failed POST + sibling won: label kept" "in-progress" "$(cat "$STATE/labels")"

# The issue closes mid-renewal (merge), old marker still present.
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
OLD_IDS="$(marker_ids)"
FAKE_AFTER_POST_HOOK='echo closed > "$S/issue_state"' \
  run 873 --renew --holder threadA
check_eq "closed mid-renewal: exit 5" 5 "$RC"
check_contains "closed mid-renewal: reason" "released" "$ERR"
check_eq "closed mid-renewal: only the old marker remains" "$OLD_IDS" "$(marker_ids)"

# Already closed before the renewal: nothing is written at all.
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
echo closed > "$STATE/issue_state"
POSTS="$(posts_made)"
run 873 --renew --holder threadA
check_eq "closed issue: exit 5" 5 "$RC"
check_contains "closed issue: not-held" "closed" "$ERR"
check_eq "closed issue: nothing posted" "$POSTS" "$(posts_made)"

reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 5)" run 873 --claim --holder threadA
run 873 --claim --holder threadB
check_eq "sequential: threadB took over the stale claim" "mine" "$OUT"
run 873 --renew --holder threadA
check_eq "sequential: original holder's --renew exits 5" 5 "$RC"
run 873 --claim --holder threadA
check_eq "sequential: original holder's --claim is blocked" 1 "$RC"
check_eq "sequential: threadB's claim intact" "threadB" "$(newest_marker_field '.body | capture("claude-claim: (?<p>.*) -->").p | fromjson | .holder')"

echo "== (22) residual renew/release races (issue #1933) =="
# Zero the per-run counters the stub's Nth-call switches key on.
arm_counters() { echo 0 > "$STATE/comment_reads"; echo 0 > "$STATE/edit_calls"; }
iso_ago_min() {
  local epoch=$(( $(date -u +%s) - $1 * 60 ))
  date -u -d "@$epoch" +%FT%TZ 2>/dev/null && return 0
  date -u -r "$epoch" +%FT%TZ 2>/dev/null && return 0
  return 1
}

# Item 1: a release lands AFTER the verification read (comment read #2) and
# before the issue re-read — every marker deleted, label + assignee removed.
# The verify snapshot still shows the old marker, so only the final re-read
# can see it. Before #1933 this re-added the label and reported `mine`/0.
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
arm_counters
FAKE_AFTER_COMMENTS_READ_AT=2 \
FAKE_AFTER_COMMENTS_READ_HOOK='echo "[]" > "$S/comments.json"; : > "$S/labels"; : > "$S/assignees"' \
  run 873 --renew --holder threadA --json
check_eq "item 1: exit 5" 5 "$RC"
check_eq "item 1: verdict unclaimed" "unclaimed" "$(jq -r .verdict <<<"$OUT")"
check_contains "item 1: reason released" "released" "$(jq -r .reason <<<"$OUT")"
check_contains "item 1: says the re-added label was rolled back" "rolled back" "$(jq -r .reason <<<"$OUT")"
check_eq "item 1: renewed false" "false" "$(jq -r .renewed <<<"$OUT")"
check_eq "item 1: no marker left" 0 "$(claim_comment_count)"
check_eq "item 1: label not resurrected" "" "$(cat "$STATE/labels")"
check_eq "item 1: assignee not resurrected" "" "$(cat "$STATE/assignees")"
run 873 --check --holder threadB
check_eq "item 1: issue reads unclaimed afterwards" "unclaimed" "$OUT"

# Item 1, closed variant: the issue closes after the label re-assert.
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
arm_counters
FAKE_AFTER_EDIT_HOOK='echo closed > "$S/issue_state"' \
  run 873 --renew --holder threadA
check_eq "item 1 closed after re-assert: exit 5" 5 "$RC"
check_contains "item 1 closed after re-assert: released" "released" "$ERR"
check_eq "item 1 closed after re-assert: this run's marker withdrawn" 0 "$(claim_comment_count)"

# Item 2: the label re-assert fails after a renewal POST on an issue that had
# lost its label. fail_closed keeps the new marker; the next not-due call must
# put the label back so /wave (which filters on it) can see the claim.
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
: > "$STATE/labels"; : > "$STATE/assignees"
arm_counters
FAKE_EDIT_FAIL_AT=1 run 873 --renew --holder threadA
check_eq "item 2: re-assert failure is unknown" "unknown" "$OUT"
check_eq "item 2: exit 4" 4 "$RC"
check_contains "item 2: stderr names the repair path" "next --renew or --claim re-adds the label" "$ERR"
check_eq "item 2: label still absent after the failure" "" "$(cat "$STATE/labels")"
POSTS="$(posts_made)"
run 873 --renew --holder threadA --json
check_eq "item 2 retry: exit 0" 0 "$RC"
check_eq "item 2 retry: verdict mine" "mine" "$(jq -r .verdict <<<"$OUT")"
check_eq "item 2 retry: not a renewal" "false" "$(jq -r .renewed <<<"$OUT")"
check_eq "item 2 retry: no new comment" "$POSTS" "$(posts_made)"
check_eq "item 2 retry: label restored" "in-progress" "$(cat "$STATE/labels")"
check_eq "item 2 retry: assignee restored" "alice" "$(cat "$STATE/assignees")"
# Same repair through a not-due --claim.
: > "$STATE/labels"
run 873 --claim --holder threadA
check_eq "item 2 via --claim: exit 0" 0 "$RC"
check_eq "item 2 via --claim: label restored" "in-progress" "$(cat "$STATE/labels")"
# A failing repair warns but keeps mine/0 and writes no comment.
: > "$STATE/labels"
arm_counters
POSTS="$(posts_made)"
FAKE_EDIT_FAIL_AT=1 run 873 --renew --holder threadA
check_eq "item 2 failed repair: still mine" "mine" "$OUT"
check_eq "item 2 failed repair: exit 0" 0 "$RC"
check_contains "item 2 failed repair: warns" "may not see the claim" "$ERR"
check_eq "item 2 failed repair: no comment posted" "$POSTS" "$(posts_made)"
# The issue closes after the startup snapshot but before the repair edit: the
# fresh pre-edit read sees it closed, so nothing is re-labelled.
: > "$STATE/labels"; : > "$STATE/assignees"; rm -f "$STATE/read_hook_done" "$STATE/edit_hook_done"
arm_counters
FAKE_AFTER_COMMENTS_READ_HOOK='echo closed > "$S/issue_state"' \
  run 873 --renew --holder threadA
check_eq "item 2 closed before repair: exit 0 (startup snapshot was open)" 0 "$RC"
check_eq "item 2 closed before repair: no issue edit" 0 "$(cat "$STATE/edit_calls")"
check_eq "item 2 closed before repair: label stays absent" "" "$(cat "$STATE/labels")"
echo open > "$STATE/issue_state"
# The issue closes right after the repair edit: the post-edit read rolls it back.
: > "$STATE/labels"; : > "$STATE/assignees"; rm -f "$STATE/read_hook_done" "$STATE/edit_hook_done"
arm_counters
FAKE_AFTER_EDIT_HOOK='echo closed > "$S/issue_state"' \
  run 873 --renew --holder threadA --json
check_eq "item 2 closed during repair: exit 0" 0 "$RC"
check_contains "item 2 closed during repair: rolled back" "rolled back" "$(jq -r .reason <<<"$OUT")"
check_eq "item 2 closed during repair: label removed again" "" "$(cat "$STATE/labels")"
check_eq "item 2 closed during repair: assignee removed again" "" "$(cat "$STATE/assignees")"
echo open > "$STATE/issue_state"
# An unauthorized same-holder --claim (bob's marker) is never repaired.
reset_issue
export FAKE_VIEWER="bob"
run 873 --claim --holder shared
export FAKE_VIEWER="alice"
: > "$STATE/labels"
arm_counters
run 873 --claim --holder shared
check_eq "item 2: unauthorized same-holder --claim makes no edit" 0 "$(cat "$STATE/edit_calls")"

# Item 3: a release whose comment read predates the POST deletes the OLD
# marker and removes the label AFTER this renewal re-asserted it (edit #1).
# The renewed marker survives; the final check must put the label back.
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
OLD_IDS="$(marker_ids)"
arm_counters
FAKE_AFTER_EDIT_HOOK='
  jq --argjson old "'"$OLD_IDS"'" "[ .[] | select(.id != \$old) ]" "$S/comments.json" > "$S/h.tmp" \
    && mv "$S/h.tmp" "$S/comments.json"
  : > "$S/labels"; : > "$S/assignees"' \
  run 873 --renew --holder threadA --json
check_eq "item 3: exit 0" 0 "$RC"
check_eq "item 3: renewed true" "true" "$(jq -r .renewed <<<"$OUT")"
check_eq "item 3: one marker" 1 "$(claim_comment_count)"
check_eq "item 3: label follows the surviving marker" "in-progress" "$(cat "$STATE/labels")"
check_eq "item 3: assignee follows the surviving marker" "alice" "$(cat "$STATE/assignees")"
# ...and when that second re-assert fails, the run fails closed.
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
arm_counters
FAKE_EDIT_FAIL_AT=2 \
FAKE_AFTER_EDIT_HOOK=': > "$S/labels"' \
  run 873 --renew --holder threadA
check_eq "item 3 second re-assert fails: exit 4" 4 "$RC"
check_contains "item 3 second re-assert fails: renew-failed" "renew-failed" "$ERR"

# A foreign marker that lands after verification supersedes this run.
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
FUTURE_EPOCH=$(( $(date -u +%s) + 5 ))
FUTURE_AT="$(date -u -d "@$FUTURE_EPOCH" +%FT%TZ 2>/dev/null || date -u -r "$FUTURE_EPOCH" +%FT%TZ)"
jq -n --arg at "$FUTURE_AT" '{id: 999999, created_at: $at, user: {login: "alice"},
  body: ("<!-- claude-claim: " + ({holder: "threadB", login: "alice"} | tojson) + " -->")}' > "$STATE/inject.json"
arm_counters
FAKE_AFTER_EDIT_HOOK='jq --slurpfile x "$S/inject.json" ". + \$x" "$S/comments.json" > "$S/h.tmp" && mv "$S/h.tmp" "$S/comments.json"' \
  run 873 --renew --holder threadA --json
check_eq "late foreign marker: exit 5" 5 "$RC"
check_contains "late foreign marker: superseded" "superseded" "$(jq -r .reason <<<"$OUT")"
check_eq "late foreign marker: only the foreign marker remains" "999999" "$(marker_ids)"
check_eq "late foreign marker: label left for the winner" "in-progress" "$(cat "$STATE/labels")"

# An unreadable winner is not absence at any later claim read either.
seed_unreadable_claim() {
  local at="$1"
  jq -n --arg at "$at" '{id:999999,created_at:$at,user:{login:"alice"},
    body:("<!-- claude-claim: " + ({holder:"threadA\u001falice",login:"alice"}|tojson) + " -->")}' > "$STATE/inject.json"
}
UNREADABLE_APPEND="jq --slurpfile x \"\$S/inject.json\" '. + \$x' \"\$S/comments.json\" > \"\$S/h.tmp\" && mv \"\$S/h.tmp\" \"\$S/comments.json\""
UNREADABLE_EPOCH=$(( $(date -u +%s) + 300 ))
UNREADABLE_AT="$(date -u -d "@$UNREADABLE_EPOCH" +%FT%TZ 2>/dev/null || date -u -r "$UNREADABLE_EPOCH" +%FT%TZ)"
reset_issue
seed_unreadable_claim "$UNREADABLE_AT"
FAKE_AFTER_COMMENTS_READ_HOOK="$UNREADABLE_APPEND" run 873 --claim --holder threadA --json
check_eq "first claim post-read: unreadable winner stops dispatch" 4 "$RC"
check_eq "first claim post-read: reports unknown" unknown "$(jq -r .verdict <<<"$OUT")"
check_eq "first claim post-read: preserves both markers" 2 "$(claim_comment_count)"
check_eq "first claim post-read: preserves index" in-progress "$(cat "$STATE/labels")"

reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
seed_unreadable_claim "$UNREADABLE_AT"
arm_counters
FAKE_AFTER_COMMENTS_READ_HOOK="$UNREADABLE_APPEND" run 873 --renew --holder threadA --json
check_eq "renewal verification: unreadable winner is unknown" 4 "$RC"
check_eq "renewal verification: no marker removed" 3 "$(claim_comment_count)"
check_eq "renewal verification: no metadata edit" 0 "$(cat "$STATE/edit_calls")"

reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
seed_unreadable_claim "$UNREADABLE_AT"
arm_counters
FAKE_AFTER_EDIT_HOOK="$UNREADABLE_APPEND" run 873 --renew --holder threadA --json
check_eq "final read: unreadable winner stops renewal" 4 "$RC"
check_eq "final read: reports unknown" unknown "$(jq -r .verdict <<<"$OUT")"
check_eq "final read: retains the posted renewal and the unreadable marker" 2 "$(claim_comment_count)"
check_eq "final read: only the verified earlier re-assert edit" 1 "$(cat "$STATE/edit_calls")"

reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
seed_unreadable_claim "$UNREADABLE_AT"
: > "$STATE/labels"; : > "$STATE/assignees"
arm_counters
FAKE_AFTER_EDIT_HOOK="jq -s '.' \"\$S/inject.json\" > \"\$S/comments.json\"" run 873 --renew --holder threadA --json
check_eq "final read with only the unreadable marker: stops renewal" 4 "$RC"
check_eq "final read with only the unreadable marker: reports unknown" unknown "$(jq -r .verdict <<<"$OUT")"
check_eq "final read with only the unreadable marker: retains index" in-progress "$(cat "$STATE/labels")"
check_eq "final read with only the unreadable marker: retains assignee" alice "$(cat "$STATE/assignees")"

reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
seed_unreadable_claim "$(iso_ago 1)"
: > "$STATE/labels"; : > "$STATE/assignees"
arm_counters
FAKE_AFTER_EDIT_HOOK="$UNREADABLE_APPEND; echo closed > \"\$S/issue_state\"" run 873 --renew --holder threadA --json
check_eq "remaining marker after proven closed: reports unknown" 4 "$RC"
check_eq "remaining marker after proven closed: retains the unreadable marker" 999999 "$(marker_ids)"
check_eq "remaining marker after proven closed: retains index" in-progress "$(cat "$STATE/labels")"

# Control: a failed final re-read keeps the verified renewal.
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA
arm_counters
FAKE_COMMENTS_FAIL_AFTER=2 run 873 --renew --holder threadA --json
check_eq "final re-read failure: exit 0" 0 "$RC"
check_eq "final re-read failure: renewed" "true" "$(jq -r .renewed <<<"$OUT")"
check_contains "final re-read failure: warns" "final consistency re-read failed" "$ERR"

# Item 4 (documented, not changed): CLAIM_STALE_HOURS=0 skips the renew clamp.
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago_min 30)" run 873 --claim --holder threadA
POSTS="$(posts_made)"
CLAIM_STALE_HOURS=0 CLAIM_RENEW_MINUTES=60 run 873 --renew --holder threadA
check_eq "item 4: stale=0 + renew=60, 30m marker: not due, exit 0" 0 "$RC"
check_eq "item 4: no clamp warning" "" "$ERR"
check_eq "item 4: nothing posted" "$POSTS" "$(posts_made)"
CLAIM_STALE_HOURS=0 CLAIM_RENEW_MINUTES=60 run 873 --check --holder threadB
check_eq "item 4: a foreign holder reads it stale" "stale" "$OUT"
check_eq "item 4: --check is not a usage error" 0 "$RC"

# Item 5: a NOT-due --renew on a closed issue reports not-held/5, not mine/0.
reset_issue
run 873 --claim --holder threadA
echo closed > "$STATE/issue_state"
IDS="$(marker_ids)"; POSTS="$(posts_made)"
arm_counters
run 873 --renew --holder threadA
check_eq "item 5: stdout mine" "mine" "$OUT"
check_eq "item 5: exit 5" 5 "$RC"
check_contains "item 5: stderr not-held" "not-held" "$ERR"
check_contains "item 5: stderr names closed" "closed" "$ERR"
run 873 --renew --holder threadA --json
check_eq "item 5 json: verdict mine" "mine" "$(jq -r .verdict <<<"$OUT")"
check_eq "item 5 json: reason starts not-held" "true" "$(jq -r '.reason | startswith("not-held")' <<<"$OUT")"
check_eq "item 5 json: renewed false" "false" "$(jq -r .renewed <<<"$OUT")"
check_eq "item 5: markers unchanged" "$IDS" "$(marker_ids)"
check_eq "item 5: nothing posted" "$POSTS" "$(posts_made)"
check_eq "item 5: no issue edit" 0 "$(cat "$STATE/edit_calls")"
: > "$STATE/labels"
run 873 --claim --holder threadA
check_eq "item 5 control: not-due --claim on closed stays mine/0" 0 "$RC"
check_eq "item 5 control: closed issue never re-labelled" "" "$(cat "$STATE/labels")"

echo "== (11) usage errors =="
reset_issue
run 873 --renew --allow-claimed --holder threadA
check_eq "--allow-claimed rejected with --renew" 2 "$RC"
run 873 --renew --check
check_eq "--renew is exclusive with other actions" 2 "$RC"
CLAIM_RENEW_MINUTES=abc run 873 --renew --holder threadA
check_eq "invalid CLAIM_RENEW_MINUTES" 2 "$RC"
run 873 --check --allow-claimed --holder threadA
check_eq "--allow-claimed rejected outside --claim" 2 "$RC"
run abc --check
check_eq "non-numeric issue" 2 "$RC"
run 873
check_eq "no action flag" 2 "$RC"
run 873 --check --claim
check_eq "two action flags" 2 "$RC"
run 873 --check --repo not-a-repo
check_eq "malformed --repo" 2 "$RC"

# Scoped cleanup observes a concrete comment ID before a potentially long wait.
reset_issue
run 873 --claim --holder threadA
run 873 --check --holder threadA --json
OBSERVED_CLAIM_ID=$(jq -r .claim_comment_id <<<"$OUT")
check_eq "scoped receipt exposes the actual marker ID" "$(jq -r '.[-1].id' "$STATE/comments.json")" "$OBSERVED_CLAIM_ID"
run 873 --release --expect-claim-id "$((OBSERVED_CLAIM_ID + 1))"
check_eq "changed observed ID refuses release" 5 "$RC"
check_eq "changed observed ID retains marker" 1 "$(claim_comment_count)"
check_eq "changed observed ID retains label" in-progress "$(cat "$STATE/labels")"
check_eq "changed observed ID retains assignee" alice "$(cat "$STATE/assignees")"
run 873 --release --expect-claim-id none
check_eq "observed absence cannot release a present marker" 5 "$RC"
check_eq "absence mismatch still retains marker" 1 "$(claim_comment_count)"
run 873 --release --expect-claim-id "$OBSERVED_CLAIM_ID"
check_eq "matching observed ID permits cleanup" 0 "$RC"
check_eq "matching observed ID deletes observed marker" 0 "$(claim_comment_count)"
check_eq "matching observed ID removes label" "" "$(cat "$STATE/labels")"
check_eq "matching observed ID removes assignee" "" "$(cat "$STATE/assignees")"
run 873 --check --expect-claim-id none
check_eq "expected marker precondition is release-only" 2 "$RC"
run 873 --release --expect-claim-id bogus
check_eq "invalid expected marker ID is usage error" 2 "$RC"

reset_issue
printf 'in-progress\n' > "$STATE/labels"
printf 'alice\n' > "$STATE/assignees"
run 873 --release --expect-claim-id none
check_eq "observed label-only claim can be released" 0 "$RC"
check_eq "label-only cleanup clears index" "" "$(cat "$STATE/labels")"
check_eq "label-only cleanup clears assignee" "" "$(cat "$STATE/assignees")"

# A new marker appearing after deletion is never in the captured deletion set.
reset_issue
run 873 --claim --holder threadA
run 873 --check --holder threadA --json
OBSERVED_CLAIM_ID=$(jq -r .claim_comment_id <<<"$OUT")
cat > "$TMP/publish-after-delete.sh" <<'AFTER_DELETE'
#!/usr/bin/env bash
jq -n --arg at "$(date -u +%FT%TZ)" \
  '[{id:123,created_at:$at,user:{login:"alice"},body:"<!-- claude-claim: {\"holder\":\"threadB\",\"login\":\"alice\"} -->"}]' \
  > "$FAKE_STATE/comments.json"
AFTER_DELETE
export FAKE_AFTER_DELETE_HOOK="$TMP/publish-after-delete.sh"
run 873 --release --expect-claim-id "$OBSERVED_CLAIM_ID"
check_eq "late marker stops scoped metadata cleanup" 5 "$RC"
check_eq "late marker survives the captured delete set" 123 "$(jq -r '.[0].id' "$STATE/comments.json")"
check_eq "late marker keeps its label index" in-progress "$(cat "$STATE/labels")"
check_eq "late marker keeps its assignee" alice "$(cat "$STATE/assignees")"

# A failed final read preserves metadata and can be retried as label-only.
reset_issue
run 873 --claim --holder threadA
run 873 --check --holder threadA --json
OBSERVED_CLAIM_ID=$(jq -r .claim_comment_id <<<"$OUT")
export FAKE_COMMENTS_FAIL_AFTER=$(( $(cat "$STATE/comment_reads") + 1 ))
run 873 --release --expect-claim-id "$OBSERVED_CLAIM_ID"
check_eq "unreadable scoped verification reports unknown" 4 "$RC"
check_eq "unreadable scoped verification already removed only its marker" 0 "$(claim_comment_count)"
check_eq "unreadable scoped verification retains the index" in-progress "$(cat "$STATE/labels")"
unset FAKE_COMMENTS_FAIL_AFTER
run 873 --release --expect-claim-id none
check_eq "scoped cleanup retry completes" 0 "$RC"
check_eq "scoped cleanup retry clears the index" "" "$(cat "$STATE/labels")"

# Prose can quote the protocol without publishing a record. These comments
# sort after the authentic marker and include same-account examples so an
# overbroad renewal or release would actually try to delete them.
seed_claim_examples() {
  local at="$1"
  jq --arg at "$at" '. + [
    {id:901,created_at:$at,user:{login:"review-bot"},body:"The helper writes a `<!-- claude-claim: … -->` marker."},
    {id:902,created_at:$at,user:{login:"alice"},body:("Example:\n\n````markdown\n```\n<!-- claude-claim: {\"holder\":\"threadA\",\"login\":\"alice\"} -->\n````")},
    {id:903,created_at:$at,user:{login:"alice"},body:("> <!-- claude-claim: {\"holder\":\"threadA\",\"login\":\"alice\"} -->")},
    {id:904,created_at:$at,user:{login:"alice"},body:("    <!-- claude-claim: {\"holder\":\"threadA\",\"login\":\"alice\"} -->")},
    {id:905,created_at:$at,user:{login:"alice"},body:("   ~~~\n<!-- claude-claim: {\"holder\":\"threadA\",\"login\":\"alice\"} -->\n   ~~~~")},
    {id:906,created_at:$at,user:{login:"alice"},body:("- ```markdown\n  <!-- claude-claim: {\"holder\":\"threadA\",\"login\":\"alice\"} -->\n  ```")},
    {id:907,created_at:$at,user:{login:"alice"},body:("An example `opens\n<!-- claude-claim: {\"holder\":\"threadA\",\"login\":\"alice\"} -->\nand closes`.")}
  ]' "$STATE/comments.json" > "$TMP/with-examples.json"
  mv "$TMP/with-examples.json" "$STATE/comments.json"
}
claim_examples() { jq -c '[.[] | select(.id >= 901)]' "$STATE/comments.json"; }

for example_id in 906 907; do
  reset_issue
  seed_claim_examples "$(date -u +%FT%TZ)"
  jq --argjson id "$example_id" '[.[] | select(.id == $id)]' "$STATE/comments.json" > "$TMP/nested-example.json"
  mv "$TMP/nested-example.json" "$STATE/comments.json"
  run 873 --check --holder threadA --json
  check_eq "nested code example $example_id never becomes a claim" unclaimed "$(jq -r .verdict <<<"$OUT")"
done

reset_issue
seed_claim_examples "$(date -u +%FT%TZ)"
jq '[.[] | select(.id == 901)]' "$STATE/comments.json" > "$TMP/inline-example.json"
mv "$TMP/inline-example.json" "$STATE/comments.json"
run 873 --check --holder threadA --json
check_eq "inline CodeRabbit-style prose is startable" 0 "$RC"
check_eq "inline prose does not create a claim" unclaimed "$(jq -r .verdict <<<"$OUT")"

reset_issue
seed_claim_examples "$(date -u +%FT%TZ)"
run 873 --check --holder threadA --json
check_eq "quoted examples alone are unclaimed" 0 "$RC"
check_eq "quoted examples alone are not protocol candidates" unclaimed "$(jq -r .verdict <<<"$OUT")"

reset_issue
run 873 --claim --holder threadA --json
check_eq "record-classification fixture claimed" 0 "$RC"
run 873 --check --holder threadA --json
AUTHENTIC_ID=$(jq -r .claim_comment_id <<<"$OUT")
age_newest_marker 3
seed_claim_examples "$(date -u +%FT%TZ)"
EXAMPLES_BEFORE=$(claim_examples)
run 873 --check --holder threadA --json
check_eq "newer examples do not shadow authentic claim" 0 "$RC"
check_eq "check returns the authentic claim ID" "$AUTHENTIC_ID" "$(jq -r .claim_comment_id <<<"$OUT")"
run 873 --renew --holder threadA --json
check_eq "renewal ignores quoted marker examples" 0 "$RC"
check_eq "authentic claim is renewed when due" true "$(jq -r .renewed <<<"$OUT")"
check_eq "renewal cleanup preserves all examples" "$EXAMPLES_BEFORE" "$(claim_examples)"
run 873 --check --holder threadA --json
OBSERVED_CLAIM_ID=$(jq -r .claim_comment_id <<<"$OUT")
[[ "$OBSERVED_CLAIM_ID" != "$AUTHENTIC_ID" ]] || check_eq "renewed claim has new ID" different same
run 873 --release --holder threadA --expect-claim-id "$OBSERVED_CLAIM_ID" --json
check_eq "guarded release ignores quoted marker examples" 0 "$RC"
check_eq "release preserves all examples" "$EXAMPLES_BEFORE" "$(claim_examples)"
run 873 --check --holder threadA --json
check_eq "release leaves the issue unclaimed despite prose" unclaimed "$(jq -r .verdict <<<"$OUT")"

reset_issue
run 873 --claim --holder threadA
age_newest_marker 3
jq --arg at "$(date -u +%FT%TZ)" '. + [{id:901,created_at:$at,user:{login:"alice"},body:"<!-- claude-claim: incomplete"}]' \
  "$STATE/comments.json" > "$TMP/newest-incomplete.json"
mv "$TMP/newest-incomplete.json" "$STATE/comments.json"
run 873 --check --holder threadA --json
check_eq "newer standalone incomplete marker remains unreadable" 4 "$RC"
check_eq "genuine unreadable candidate does not expose older owner" unknown "$(jq -r .verdict <<<"$OUT")"

reset_issue
jq -n --arg at "$(date -u +%FT%TZ)" '[{id:901,created_at:$at,user:{login:"alice"},
  body:("🔒 Claimed by `alice` for active work. It will be released when this issue\u0027s PR merges, when the issue closes, or automatically after 4h of no activity.\r\n\r\n" +
        "<!-- claude-claim: {\"holder\":\"threadA\",\"login\":\"alice\"} -->\r\n")}]' > "$STATE/comments.json"
run 873 --check --holder threadA --json
check_eq "historic claim notice with CRLF still identifies the owner" mine "$(jq -r .verdict <<<"$OUT")"
check_eq "historic notice preserves exact marker identity" 901 "$(jq -r .claim_comment_id <<<"$OUT")"

reset_issue
run 873 --claim --holder threadA
jq '.[0].body = (.[0].body + "\n<!-- claude-claim: {\"holder\":\"threadB\",\"login\":\"alice\"} -->")' \
  "$STATE/comments.json" > "$TMP/ambiguous-standalone.json"
mv "$TMP/ambiguous-standalone.json" "$STATE/comments.json"
run 873 --check --holder threadA --json
check_eq "two standalone records in one comment are ambiguous" 4 "$RC"
check_eq "ambiguous standalone records remain fail closed" unknown "$(jq -r .verdict <<<"$OUT")"

echo
echo "== Form A launch keeps one holder across a checkout change and resume =="
# shellcheck source=lib/skill-bash.sh
source "$REPO_ROOT/.claude/scripts/tests/lib/skill-bash.sh"
FORM_A_BLOCK=$(extract_skill_bash "$REPO_ROOT/.claude/reference/chip-launching.md" chip-form-a-claim)
RECEIPT="$REPO_ROOT/.claude/scripts/chip-claim-receipt.sh"
ORIGINAL_CHECKOUT="$TMP/form-a-original"
ALT_CHECKOUT="$TMP/form-a-assigned"
SIBLING_CHECKOUT="$TMP/form-a-sibling"
git init -q "$ORIGINAL_CHECKOUT"
git -C "$ORIGINAL_CHECKOUT" -c user.name=Fixture -c user.email=fixture@example.test \
  -c commit.gpgsign=false commit --allow-empty -qm seed
run_form_a() {
  RC=0
  OUT=$(cd "$ORIGINAL_CHECKOUT" && CLAIM="$SCRIPT" ISSUE=873 ISSUE_REPO=acme/widgets \
    "$CLAIM_TEST_SHELL" -u -c \
    "$FORM_A_BLOCK"$'\n''printf "CLAIM_RESULT=%s\n" "$CLAIM_JSON"' 2>"$TMP/form-a.err") || RC=$?
}
receipt_run() {
  RECEIPT_RC=0
  RECEIPT_OUT=$("$CLAIM_TEST_SHELL" "$RECEIPT" "$@" 2>"$TMP/form-a-receipt.err") || RECEIPT_RC=$?
}

reset_issue
run_form_a
check_eq "fresh Form A acquisition succeeds" 0 "$RC"
FORM_A_JSON="${OUT##*$'\nCLAIM_RESULT='}"
FORM_A_HOLDER=$(jq -er .holder <<<"$FORM_A_JSON")
check_contains "fresh Form A uses an explicit launch holder" chip: "$FORM_A_HOLDER"
check_eq "the acquired marker has the saved holder" "$FORM_A_HOLDER" \
  "$(newest_marker_field '.body | capture("claude-claim: (?<p>.*) -->").p | fromjson | .holder')"
FORM_A_IDS=$(marker_ids)
run_form_a
check_eq "a sibling launch in the same checkout cannot take the claim" 1 "$RC"
check_eq "the sibling did not replace the marker" "$FORM_A_IDS" "$(marker_ids)"

git -C "$ORIGINAL_CHECKOUT" worktree add -qb issue-873 "$ALT_CHECKOUT"
git -C "$ORIGINAL_CHECKOUT" worktree add -qb other-issue-873 "$SIBLING_CHECKOUT"
receipt_run read "$ALT_CHECKOUT" acme/widgets 873
check_eq "missing receipt fails closed before acquisition is bound" 4 "$RECEIPT_RC"
receipt_run save "$ORIGINAL_CHECKOUT" acme/widgets 873 "$FORM_A_HOLDER" <<<"$FORM_A_JSON"
check_eq "primary checkout cannot store a launch receipt" 4 "$RECEIPT_RC"
receipt_run save "$ALT_CHECKOUT" acme/other 873 "$FORM_A_HOLDER" <<<"$FORM_A_JSON"
check_eq "cannot bind acquisition from the wrong repo" 4 "$RECEIPT_RC"
OTHER_HOLDER=chip:fixture:1:2:3:4
receipt_run save "$ALT_CHECKOUT" acme/widgets 873 "$OTHER_HOLDER" <<<"$FORM_A_JSON"
check_eq "a remote result does not authorize a different holder" 4 "$RECEIPT_RC"
receipt_run save "$ALT_CHECKOUT" acme/widgets 873 "$FORM_A_HOLDER" <<<"$FORM_A_JSON"
check_eq "verified acquisition saves before changing checkouts" 0 "$RECEIPT_RC"
check_eq "saving does not print the holder" "" "$RECEIPT_OUT"
RECEIPT_PATH="$(git -C "$ALT_CHECKOUT" rev-parse --absolute-git-dir)/claude-chip-claim.json"
check_eq "receipt is private in Git metadata" "$RECEIPT_PATH" "$(find "$RECEIPT_PATH" -perm 600)"
check_eq "no receipt appears in the worktree status" "" "$(git -C "$ALT_CHECKOUT" status --porcelain)"
receipt_run save "$ALT_CHECKOUT" acme/widgets 873 "$OTHER_HOLDER" \
  <<<"$(jq --arg h "$OTHER_HOLDER" '.holder = $h | .claimant_holder = $h' <<<"$FORM_A_JSON")"
check_eq "another successful result cannot overwrite the receipt" 4 "$RECEIPT_RC"
receipt_run read "$ALT_CHECKOUT" acme/widgets 874
check_eq "wrong issue cannot load a receipt" 4 "$RECEIPT_RC"
receipt_run read "$ALT_CHECKOUT" acme/other 873
check_eq "wrong repo cannot load a receipt" 4 "$RECEIPT_RC"
receipt_run read "$SIBLING_CHECKOUT" acme/widgets 873
check_eq "sibling worktree cannot load a receipt from shared metadata" 4 "$RECEIPT_RC"
cp "$RECEIPT_PATH" "$(git -C "$SIBLING_CHECKOUT" rev-parse --absolute-git-dir)/claude-chip-claim.json"
receipt_run read "$SIBLING_CHECKOUT" acme/widgets 873
check_eq "a copied receipt is bound to its original worktree" 4 "$RECEIPT_RC"
git -C "$ALT_CHECKOUT" switch -qc another-branch
receipt_run read "$ALT_CHECKOUT" acme/widgets 873
check_eq "a different branch cannot load the old receipt" 4 "$RECEIPT_RC"
git -C "$ALT_CHECKOUT" switch -q issue-873
mv "$RECEIPT_PATH" "$RECEIPT_PATH.saved"
ln -s "$RECEIPT_PATH.saved" "$RECEIPT_PATH"
receipt_run read "$ALT_CHECKOUT" acme/widgets 873
check_eq "a symlink is not a valid receipt" 4 "$RECEIPT_RC"
mv -f "$RECEIPT_PATH.saved" "$RECEIPT_PATH"
receipt_run read "$ALT_CHECKOUT" acme/widgets 873
check_eq "a fresh process can reload the exact launch holder" "$FORM_A_HOLDER" "$RECEIPT_OUT"

FORM_A_RENEW=$(
  cd "$ALT_CHECKOUT" || exit 1
  unset CLAUDE_CLAIM_HOLDER CLAUDE_SESSION_ID FORM_A_HOLDER FORM_A_JSON
  run 873 --renew --repo acme/widgets
  printf '%s|%s\n' "$RC" "$OUT"
  restored=$("$CLAIM_TEST_SHELL" "$RECEIPT" read "$PWD" acme/widgets 873) || exit 1
  run 873 --renew --repo acme/widgets --holder "$restored"
  printf '%s|%s\n' "$RC" "$OUT"
)
check_eq "new checkout default loses ownership; recovered holder renews" \
  $'5|claimed\n0|mine' "$FORM_A_RENEW"
check_eq "renewal before due leaves one original marker" "$FORM_A_IDS" "$(marker_ids)"
run 873 --release --repo acme/widgets --holder "$FORM_A_HOLDER"
run 873 --claim --repo acme/widgets --holder "$OTHER_HOLDER"
run 873 --renew --repo acme/widgets --holder "$RECEIPT_OUT"
check_eq "a valid receipt cannot re-acquire a lost claim on resume" 5 "$RC"

############################################################################
echo "== (2284) who holds it: provider / device / label, hidden default holder =="
# Isolate every variable that feeds provider, holder, device or label so the
# defaults are what is under test.
drun() {
  local errfile="$TMP/err"
  OUT="$(env -u CLAUDE_CLAIM_HOLDER -u CLAUDE_SESSION_ID -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
    -u CODEX_SANDBOX -u CODEX_THREAD_ID -u CODEX_HOME -u CURSOR_AGENT -u CURSOR_TRACE_ID \
    -u AGENT_CLAIM_PROVIDER -u AGENT_CLAIM_DEVICE -u AGENT_CLAIM_LABEL \
    "$@" 2>"$errfile")"; RC=$?
  ERR="$(cat "$errfile")"
}
last_payload() { # -> payload JSON of the newest claim comment
  jq -r '[ .[] | select(.body | contains("<!-- claude-claim:")) ] | last | .body
         | capture("<!-- claude-claim: (?<p>.*) -->").p' "$STATE/comments.json"
}
last_body() { jq -r '[ .[] | select(.body | contains("<!-- claude-claim:")) ] | last | .body' "$STATE/comments.json"; }
add_marker() { # add_marker <id> <created_at> <payload-json>
  jq --argjson id "$1" --arg at "$2" --arg p "$3" \
    '. + [{id: $id, created_at: $at, user: {login: "alice"},
           body: ("🔒 Claimed by `alice` for active work. It will be released when this issue'"'"'s PR merges.\n\n<!-- claude-claim: " + $p + " -->")}]' \
    "$STATE/comments.json" > "$STATE/c.tmp" && mv "$STATE/c.tmp" "$STATE/comments.json"
  echo "$1" > "$STATE/next_id"
}
# Stub hostname with a distinctive value so the privacy assertions are
# controlled: the real machine name could be a substring of anything.
REAL_HOST="secret-host-9f3a"
mkdir -p "$TMP/hostbin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "secret-host-9f3a"\n' > "$TMP/hostbin/hostname"
chmod +x "$TMP/hostbin/hostname"
export PATH="$TMP/hostbin:$PATH"

reset_issue
run 873 --claim --holder threadA --provider codex --device studio --label "backlog run" --json
check_eq "fields: claim succeeds" "0|mine" "$RC|$(jq -r .verdict <<<"$OUT")"
check_eq "fields: claim JSON reports provider" "codex" "$(jq -r .provider <<<"$OUT")"
check_eq "fields: payload carries provider" "codex" "$(last_payload | jq -r .provider)"
check_eq "fields: payload carries device" "studio" "$(last_payload | jq -r .device)"
check_eq "fields: payload carries label" "backlog run" "$(last_payload | jq -r .label)"
check_eq "fields: payload keeps holder/login" "threadA|alice" "$(last_payload | jq -r '.holder + "|" + .login')"
check_contains "fields: sentence names provider and device" "Held by codex on device studio (run: backlog run)." "$(last_body)"
run 873 --check --holder threadB --json
check_eq "fields: second holder sees claimed" "1|claimed" "$RC|$(jq -r .verdict <<<"$OUT")"
check_eq "fields: --check --json names the three" "codex|studio|backlog run" \
  "$(jq -r '[.provider, .device, .label] | join("|")' <<<"$OUT")"
run 873 --check --holder threadB
check_contains "fields: human message names provider" "provider codex" "$ERR"
check_contains "fields: human message names device" "device studio" "$ERR"
check_contains "fields: human message names label" "label backlog run" "$ERR"

# resolution order: flag > env > detection > unknown
reset_issue
drun env AGENT_CLAIM_PROVIDER=cursor AGENT_CLAIM_DEVICE=envbox "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --claim --holder h1 --json
check_eq "resolution: env provider/device used" "cursor|envbox" "$(jq -r '[.provider, .device] | join("|")' <<<"$OUT")"
reset_issue
drun env AGENT_CLAIM_PROVIDER=cursor "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --claim --holder h1 --provider codex --json
check_eq "resolution: flag beats env" "codex" "$(jq -r .provider <<<"$OUT")"
reset_issue
drun env CODEX_HOME=/x "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --claim --holder h1 --json
check_eq "resolution: Codex env detected" "codex" "$(jq -r .provider <<<"$OUT")"
reset_issue
drun env CLAUDECODE=1 "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --claim --holder h1 --json
check_eq "resolution: Claude Code env detected" "claude-code" "$(jq -r .provider <<<"$OUT")"
reset_issue
drun env CURSOR_TRACE_ID=1 "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --claim --holder h1 --json
check_eq "resolution: Cursor env detected" "cursor" "$(jq -r .provider <<<"$OUT")"
reset_issue
drun "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --claim --holder h1 --json
check_eq "resolution: nothing known -> unknown" "unknown" "$(jq -r .provider <<<"$OUT")"
check_eq "resolution: no label -> null" "null" "$(jq -r .label <<<"$OUT")"
check_eq "resolution: device is a per-machine nickname" "true" \
  "$(jq -r '.device | test("^device-[0-9a-f]{6}$")' <<<"$OUT")"
printf 'my-laptop\n' > "$HOME/.claude/device-nickname"
reset_issue
drun "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --claim --holder h1 --json
check_eq "resolution: nickname file used" "my-laptop" "$(jq -r .device <<<"$OUT")"
for NICK_CASE in "Bob's MacBook" "Studio (office)" "caf$(printf '\303\251')"; do
  printf '%s\r\n' "$NICK_CASE" > "$HOME/.claude/device-nickname"
  reset_issue
  drun "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --claim --holder h1 --json
  check_eq "resolution: invalid nickname file falls back, no usage error ($NICK_CASE)" "0|true" \
    "$RC|$(jq -r '.device | test("^device-[0-9a-f]{6}$")' <<<"$OUT")"
done
printf 'my-laptop\r\n' > "$HOME/.claude/device-nickname"
reset_issue
drun "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --claim --holder h1 --json
check_eq "resolution: CRLF nickname file trimmed" "my-laptop" "$(jq -r .device <<<"$OUT")"
printf "Bob's MacBook\n" > "$HOME/.claude/device-nickname"
reset_issue
drun "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --claim --holder h1 --device "Bob's MacBook" --json
check_eq "resolution: explicit invalid --device stays strict" "2" "$RC"
rm -f "$HOME/.claude/device-nickname"

# release: the released claim's facts are not reported beside `unclaimed`
reset_issue
drun "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --claim --holder h1 --provider codex --device laptop --json
drun "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --release --holder h1 --json
check_eq "release --json: unclaimed with no leftover facts" "unclaimed|null|null|null" \
  "$(jq -r '[.verdict, .provider, .device, .label] | map(tostring) | join("|")' <<<"$OUT")"

# no SHA-256 tool: the default holder/device id fails closed (no weak checksum)
NOSHA_BIN="$TMP/nosha-bin"
mkdir -p "$NOSHA_BIN"
for t in shasum sha256sum; do printf '#!/bin/sh\nexit 1\n' > "$NOSHA_BIN/$t"; chmod +x "$NOSHA_BIN/$t"; done
reset_issue
drun env PATH="$NOSHA_BIN:$PATH" "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --claim --json
check_eq "no sha tool: default holder claim fails closed (usage)" "2" "$RC"
reset_issue
drun env PATH="$NOSHA_BIN:$PATH" "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --claim --holder h1 --provider codex --json
check_eq "no sha tool: default device fails closed (usage)" "2" "$RC"
reset_issue
drun env PATH="$NOSHA_BIN:$PATH" "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --claim --holder h1 --provider codex --device laptop --json
check_eq "no sha tool: explicit holder+device still claims" "0" "$RC"

# nothing private in the posted comment (default holder, default device)
reset_issue
drun "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --claim --json
check_eq "privacy: default claim succeeds" "0|mine" "$RC|$(jq -r .verdict <<<"$OUT")"
check_eq "privacy: default holder is a digest" "true" "$(last_payload | jq -r '.holder | test("^h-[0-9a-f]{12}$")')"
PRIV_BODY="$(last_body)"
check_eq "privacy: comment has no hostname" "no" "$([[ "$PRIV_BODY" == *"$REAL_HOST"* ]] && echo yes || echo no)"
check_eq "privacy: comment has no checkout path" "no" "$([[ "$PRIV_BODY" == *"$REPO_ROOT"* ]] && echo yes || echo no)"
check_eq "privacy: comment has no HOME path" "no" "$([[ "$PRIV_BODY" == *"$HOME"* ]] && echo yes || echo no)"
drun "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --check
check_eq "privacy: same default holder reads back as mine" "0|mine" "$RC|$OUT"

# old markers: still parse, block, renew, release; the old default token is mine
reset_issue
LEGACY_TOKEN="$REAL_HOST:$REPO_ROOT"
add_marker 1 "$(iso_ago 1)" "$(jq -cn --arg h "$LEGACY_TOKEN" '{holder: $h, login: "alice"}')"
echo in-progress > "$STATE/labels"; echo alice > "$STATE/assignees"
drun "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --check --json
check_eq "legacy: old default token still reads as mine" "mine" "$(jq -r .verdict <<<"$OUT")"
check_eq "legacy: old marker has null provider/device/label" "null|null|null" \
  "$(jq -r '[.provider, .device, .label] | map(tostring) | join("|")' <<<"$OUT")"
run 873 --check --holder other --json
check_eq "legacy: old marker blocks a foreign holder" "1|claimed" "$RC|$(jq -r .verdict <<<"$OUT")"
check_eq "legacy: old marker gives null fields to the foreign reader" "null|null|null" \
  "$(jq -r '[.provider, .device, .label] | map(tostring) | join("|")' <<<"$OUT")"
check_contains "legacy: human message unchanged shape" "claimed by alice (holder $LEGACY_TOKEN)" "$ERR"
# defaulted renewal migrates the old token and keeps exactly one marker
drun env CLAIM_RENEW_MINUTES=30 "$CLAIM_TEST_SHELL" "$SCRIPT" 873 --renew --json
check_eq "legacy: defaulted renewal of an old default claim succeeds" "0|true" "$RC|$(jq -r .renewed <<<"$OUT")"
check_eq "legacy: renewal migrates to the digest holder" "true" "$(last_payload | jq -r '.holder | test("^h-[0-9a-f]{12}$")')"
check_eq "legacy: renewal leaves one marker" 1 "$(claim_comment_count)"
check_eq "legacy: renewal fills the missing fields" "unknown" "$(last_payload | jq -r .provider)"

# an explicit holder on an old marker renews and carries forward
reset_issue
add_marker 1 "$(iso_ago 3)" '{"holder":"threadA","login":"alice"}'
echo in-progress > "$STATE/labels"; echo alice > "$STATE/assignees"
run 873 --renew --holder threadA --provider claude-code --device studio --label oldrun --json
check_eq "old marker: explicit holder renews" "0|true" "$RC|$(jq -r .renewed <<<"$OUT")"
check_eq "old marker: renewal writes the new fields" "claude-code|studio|oldrun" \
  "$(last_payload | jq -r '[.provider, .device, .label] | join("|")')"

# renewal carries the recorded fields forward, even when other values are passed
reset_issue
add_marker 1 "$(iso_ago 3)" '{"holder":"threadA","login":"alice","provider":"codex","device":"studio","label":"backlog run"}'
echo in-progress > "$STATE/labels"; echo alice > "$STATE/assignees"
run 873 --renew --holder threadA --provider cursor --device other --label different --json
check_eq "carry-forward: renewal succeeds" "0|true" "$RC|$(jq -r .renewed <<<"$OUT")"
check_eq "carry-forward: new marker keeps the original fields" "codex|studio|backlog run" \
  "$(last_payload | jq -r '[.provider, .device, .label] | join("|")')"
check_eq "carry-forward: JSON reports the original fields" "codex|studio|backlog run" \
  "$(jq -r '[.provider, .device, .label] | join("|")' <<<"$OUT")"
check_contains "carry-forward: sentence still names them" "Held by codex on device studio (run: backlog run)." "$(last_body)"
run 873 --release --holder threadA
check_eq "carry-forward: release clears it" "0|unclaimed" "$RC|$OUT"

# a verified sibling renewal wins: report ITS facts, not this run's
reset_issue
FAKE_COMMENT_CREATED_AT="$(iso_ago 3)" run 873 --claim --holder threadA --provider codex --device studio --label first
OLD_IDS="$(marker_ids)"
jq -n --arg at "$(date -u +%FT%TZ)" '{id: 999999, created_at: $at, user: {login: "alice"},
  body: ("<!-- claude-claim: " + ({holder: "threadA", login: "alice", provider: "claude-code", device: "laptop", label: "sibling"} | tojson) + " -->")}' \
  > "$STATE/inject.json"
FAKE_AFTER_POST_HOOK='
  jq --argjson old "'"$OLD_IDS"'" --argjson new "$NEW_ID" --slurpfile x "$S/inject.json" \
    "[ .[] | select(.id != \$old and .id != \$new) ] + \$x" "$S/comments.json" > "$S/h.tmp" \
    && mv "$S/h.tmp" "$S/comments.json"' \
  run 873 --renew --holder threadA --provider cursor --device other --label mine --json
check_eq "sibling won: renewal exits 0" 0 "$RC"
check_eq "sibling won: reports the winner's fields" "claude-code|laptop|sibling" \
  "$(jq -r '[.provider, .device, .label] | join("|")' <<<"$OUT")"
run 873 --check --holder threadB --json
check_eq "sibling won: --check agrees" "claude-code|laptop|sibling" \
  "$(jq -r '[.provider, .device, .label] | join("|")' <<<"$OUT")"

# usage errors for the new flags
reset_issue
run 873 --check --provider codex
check_eq "usage: --provider is claim/renew only" 2 "$RC"
run 873 --claim --holder h1 --device "/Users/someone/box"
check_eq "usage: a path is rejected as a device" 2 "$RC"
run 873 --claim --holder h1 --label 'a<b'
check_eq "usage: markup is rejected in a label" 2 "$RC"
run 873 --claim --holder h1 --provider
check_eq "usage: --provider needs a value" 2 "$RC"
run 873 --claim --holder h1 --provider --json
check_eq "usage: a following option is not swallowed as the value" 2 "$RC"
run 873 --claim --holder h1 --device _studio --label "#2284 run" --json
check_eq "usage: leading punctuation in the documented alphabet is accepted" "0|_studio|#2284 run" \
  "$RC|$(jq -r '[.device, .label] | join("|")' <<<"$OUT")"
run 873 --release --holder h1
check_eq "usage: rejected values wrote nothing" 0 "$(claim_comment_count)"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: issue-claim.sh tests passed"
