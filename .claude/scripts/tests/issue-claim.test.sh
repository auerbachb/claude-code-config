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
  rm -f "$STATE/hook_done" "$STATE/issue_state"
  unset CLAIM_STALE_HOURS CLAIM_RENEW_MINUTES
  unset FAKE_COMMENT_POST_MODE FAKE_COMMENT_DELETE_MODE
  unset FAKE_COMMENTS_FAIL_AFTER FAKE_AFTER_POST_HOOK
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
        echo '{}'
        ;;
      */comments*)
        if [[ "$METHOD" == "POST" ]]; then
          # Renewal write path (#1914): returns the new comment like GitHub does.
          if [[ "${FAKE_COMMENT_POST_MODE:-ok}" == "error" ]]; then
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

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: issue-claim.sh tests passed"
