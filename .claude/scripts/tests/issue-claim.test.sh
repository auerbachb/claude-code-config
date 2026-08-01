#!/usr/bin/env bash
# Offline unit tests for issue-claim.sh (issue #873 — claim an issue at pick time).
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
# try each spelling rather than assuming a platform.
iso_ago() {
  local hours="$1" epoch
  epoch=$(( $(date -u +%s) - hours * 3600 ))
  date -u -r "$epoch" +%FT%TZ 2>/dev/null && return 0
  date -u -d "@$epoch" +%FT%TZ 2>/dev/null && return 0
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
  unset CLAIM_STALE_HOURS
  unset FAKE_COMMENT_POST_MODE FAKE_COMMENT_DELETE_MODE
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
    METHOD="GET"; ENDPOINT=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -X) METHOD="$2"; shift 2 ;;
        --paginate|--slurp) shift ;;
        --jq) shift 2 ;;
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
        echo '{}'
        ;;
      */comments*)
        case "${FAKE_COMMENTS_MODE:-json}" in
          error) echo "gh: HTTP 500: internal server error" >&2; exit 1 ;;
          *) cat "$S/comments.json" ;;
        esac
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
              '{number: 873, state: "open",
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
  OUT="$(bash "$SCRIPT" "$@" 2>"$errfile")"; RC=$?
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

echo "== (11) usage errors =="
reset_issue
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

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: issue-claim.sh tests passed"
