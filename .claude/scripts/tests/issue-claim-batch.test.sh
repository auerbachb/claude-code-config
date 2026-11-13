#!/usr/bin/env bash
# Offline tests for issue-claim-batch.sh and the --batch marker flags of issue-claim.sh (issue #2286).
# catalog: tests — Tests for `issue-claim-batch.sh`: mixed batch, truncated label index, batch markers, renewal and release on drop, bounded API calls
#
# Runs the REAL issue-claim.sh and issue-claim-batch.sh against a stateful,
# multi-issue `gh` stub on PATH (one directory of state per issue number), so a
# claim written by one run is read back by the next. Every gh invocation is
# logged so the API-call count of a 50-issue batch check is measured, not
# guessed. No network or auth is needed. Requires jq.
#
# Run from repo root:
#   bash .claude/scripts/tests/issue-claim-batch.test.sh
# BATCH_TEST_SCRIPT_DIR points the test at another copy of the two scripts
# (used to show the regression cases fail on the pre-change scripts).
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT_DIR="${BATCH_TEST_SCRIPT_DIR:-$REPO_ROOT/.claude/scripts}"
BATCH="$SCRIPT_DIR/issue-claim-batch.sh"
SINGLE="$SCRIPT_DIR/issue-claim.sh"
TEST_SHELL="${CLAIM_TEST_SHELL:-$BASH}"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP" "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
check_eq() {
  if [[ "$3" == "$2" ]]; then PASS=$((PASS + 1)); echo "ok   - $1"
  else FAIL=$((FAIL + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}
check_contains() {
  if [[ "$3" == *"$2"* ]]; then PASS=$((PASS + 1)); echo "ok   - $1"
  else FAIL=$((FAIL + 1)); echo "FAIL - $1 (expected to contain '$2', got '$3')"; fi
}
check_lt() {
  if (( $2 < $3 )); then PASS=$((PASS + 1)); echo "ok   - $1 ($2 < $3)"
  else FAIL=$((FAIL + 1)); echo "FAIL - $1 (expected $2 < $3)"; fi
}

iso_ago() {
  local hours="$1" epoch
  epoch=$(( $(date -u +%s) - hours * 3600 ))
  date -u -d "@$epoch" +%FT%TZ 2>/dev/null && return 0
  date -u -r "$epoch" +%FT%TZ 2>/dev/null && return 0
  echo "iso_ago: no usable date(1) spelling" >&2; return 1
}

# ---- stateful multi-issue gh stub ---------------------------------------------
STATE="$TMP/state"
mkdir -p "$STATE"
export FAKE_STATE="$STATE"

reset_state() {
  rm -rf "$STATE"; mkdir -p "$STATE"
  echo 0 > "$STATE/next_id"
  : > "$STATE/calls.log"
  printf 'bug\n' > "$STATE/repo_labels"
  export FAKE_VIEWER="alice"
  unset FAKE_SWAP_ISSUE FAKE_INDEX_MODE FAKE_BAD_ISSUE FAKE_MISSING_ISSUE FAKE_CLOSED_ISSUE FAKE_GRAPHQL_MODE CLAIM_STALE_HOURS CLAIM_RENEW_MINUTES
}

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
S="$FAKE_STATE"
printf '%s\n' "$*" >> "$S/calls.log"

issue_dir() { mkdir -p "$S/i$1"; [[ -f "$S/i$1/comments.json" ]] || echo '[]' > "$S/i$1/comments.json"; touch "$S/i$1/labels" "$S/i$1/assignees"; printf '%s' "$S/i$1"; }
lines_json() { jq -Rn --rawfile f "$1" '($f | split("\n") | map(select(length > 0)))'; }

case "${1:-}" in
  api)
    shift
    METHOD="GET"; ENDPOINT=""; BODY=""; QUERY=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -X) METHOD="$2"; shift 2 ;;
        --paginate|--slurp) shift ;;
        --jq) shift 2 ;;
        -f|-F|--raw-field|--field) [[ "$2" == body=* ]] && BODY="${2#body=}"; [[ "$2" == query=* ]] && QUERY="${2#query=}"; shift 2 ;;
        *) [[ -z "$ENDPOINT" ]] && ENDPOINT="$1"; shift ;;
      esac
    done
    case "$ENDPOINT" in
      user) printf '%s\n' "${FAKE_VIEWER:-}" ;;
      graphql)
        # Existence/state read: one aliased issue(number: N) per issue. Mirrors gh:
        # a missing issue is null with a NOT_FOUND error, and gh exits 1 with the body.
        case "${FAKE_GRAPHQL_MODE:-ok}" in error) echo "gh: HTTP 502: bad gateway" >&2; exit 1 ;; esac
        data='{}'; errs='[]'
        for n in $(printf '%s' "$QUERY" | grep -oE 'i[0-9]+: issue\(number: [0-9]+\)' | grep -oE '[0-9]+\)' | tr -d ')'); do
          if [[ "${FAKE_MISSING_ISSUE:-}" == "$n" ]]; then
            data="$(jq -c --arg a "i$n" '. + {($a): null}' <<<"$data")"
            errs="$(jq -c --arg a "i$n" '. + [{type: "NOT_FOUND", path: ["repository", $a]}]' <<<"$errs")"
          elif [[ "${FAKE_CLOSED_ISSUE:-}" == "$n" ]]; then
            data="$(jq -c --arg a "i$n" --argjson n "$n" '. + {($a): {number: $n, state: "CLOSED"}}' <<<"$data")"
          else
            data="$(jq -c --arg a "i$n" --argjson n "$n" '. + {($a): {number: $n, state: "OPEN"}}' <<<"$data")"
          fi
        done
        jq -cn --argjson d "$data" --argjson e "$errs" 'if ($e | length) > 0 then {data: {repository: $d}, errors: $e} else {data: {repository: $d}} end'
        [[ "$(jq 'length' <<<"$errs")" -gt 0 ]] && exit 1
        exit 0 ;;
      */issues\?*)
        case "${FAKE_INDEX_MODE:-ok}" in
          error) echo "gh: HTTP 502: bad gateway" >&2; exit 1 ;;
          truncated) echo '[{"number": 1}]'; echo "gh: HTTP 502: bad gateway on page 2" >&2; exit 1 ;;
          empty) exit 0 ;;
          garbage) echo '{"message":"API rate limit exceeded"}'; exit 0 ;;
        esac
        out='[]'
        for d in "$S"/i*; do
          [[ -d "$d" ]] || continue
          grep -qxF in-progress "$d/labels" && out="$(jq -c --argjson n "${d##*/i}" '. + [{number: $n}]' <<<"$out")"
        done
        echo "$out" ;;
      */issues/comments/*)
        CID="${ENDPOINT##*/}"
        for d in "$S"/i*; do
          [[ -d "$d" ]] || continue
          jq --argjson id "$CID" '[ .[] | select(.id != $id) ]' "$d/comments.json" > "$d/c.tmp" && mv "$d/c.tmp" "$d/comments.json"
        done
        echo '{}' ;;
      */issues/*/comments*)
        N="${ENDPOINT#*/issues/}"; N="${N%%/*}"; D="$(issue_dir "$N")"
        if [[ "$METHOD" == POST ]]; then
          ID=$(( $(cat "$S/next_id") + 1 )); echo "$ID" > "$S/next_id"
          AT="$(date -u +%FT%TZ)"
          jq --argjson id "$ID" --arg body "$BODY" --arg login "${FAKE_VIEWER:-}" --arg at "$AT" \
            '. + [{id: $id, body: $body, created_at: $at, user: {login: $login}}]' "$D/comments.json" > "$D/c.tmp" && mv "$D/c.tmp" "$D/comments.json"
          jq -n --argjson id "$ID" --arg at "$AT" '{id: $id, created_at: $at}'
        else
          [[ "${FAKE_BAD_ISSUE:-}" == "$N" ]] && { echo "gh: HTTP 500: internal server error" >&2; exit 1; }
          cat "$D/comments.json"
        fi ;;
      */issues/*/timeline*) echo '[]' ;;
      */issues/*)
        N="${ENDPOINT##*/}"; D="$(issue_dir "$N")"
        [[ "${FAKE_BAD_ISSUE:-}" == "$N" ]] && { echo "gh: HTTP 500: internal server error" >&2; exit 1; }
        [[ "${FAKE_MISSING_ISSUE:-}" == "$N" ]] && { echo "gh: HTTP 404: Not Found" >&2; exit 1; }
        jq -n --argjson n "$N" --argjson labels "$(lines_json "$D/labels")" --argjson assignees "$(lines_json "$D/assignees")" \
          '{number: $n, state: "open", labels: ($labels | map({name: .})), assignees: ($assignees | map({login: .}))}' ;;
      *) echo "unexpected endpoint: $ENDPOINT" >&2; exit 99 ;;
    esac ;;
  issue)
    sub="${2:-}"; N="${3:-}"; shift 3; D="$(issue_dir "$N")"
    case "$sub" in
      edit)
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --add-label) grep -qxF "$2" "$D/labels" || echo "$2" >> "$D/labels"; shift 2 ;;
            --remove-label) grep -vxF "$2" "$D/labels" > "$D/l.tmp" || true; mv "$D/l.tmp" "$D/labels"; shift 2 ;;
            --add-assignee) who="$2"; [[ "$who" == "@me" ]] && who="${FAKE_VIEWER:-}"; grep -qxF "$who" "$D/assignees" || echo "$who" >> "$D/assignees"; shift 2 ;;
            --remove-assignee) grep -vxF "$2" "$D/assignees" > "$D/a.tmp" || true; mv "$D/a.tmp" "$D/assignees"; shift 2 ;;
            *) shift ;;
          esac
        done
        echo edited ;;
      comment)
        B=""
        while [[ $# -gt 0 ]]; do case "$1" in --body) B="$2"; shift 2 ;; *) shift ;; esac; done
        ID=$(( $(cat "$S/next_id") + 1 )); echo "$ID" > "$S/next_id"
        jq --argjson id "$ID" --arg body "$B" --arg login "${FAKE_VIEWER:-}" --arg at "$(date -u +%FT%TZ)" \
          '. + [{id: $id, body: $body, created_at: $at, user: {login: $login}}]' "$D/comments.json" > "$D/c.tmp" && mv "$D/c.tmp" "$D/comments.json"
        echo commented ;;
      *) echo "unexpected issue subcommand: $sub" >&2; exit 99 ;;
    esac ;;
  label)
    sub="${2:-}"; shift 2
    case "$sub" in
      list) lines_json "$S/repo_labels" | jq '[ .[] | {name: .} ]' ;;
      create) grep -qxF "$1" "$S/repo_labels" && { echo "gh: label already exists" >&2; exit 1; }; echo "$1" >> "$S/repo_labels"; echo created ;;
      *) echo "unexpected label subcommand: $sub" >&2; exit 99 ;;
    esac ;;
  *) echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

run_batch() { # run_batch <args...> -> OUT (stdout) ERR (stderr) RC
  OUT="$("$TEST_SHELL" "$BATCH" "$@" 2>"$TMP/err")"; RC=$?
}
run_single() {
  OUT="$("$TEST_SHELL" "$SINGLE" "$@" 2>"$TMP/err")"; RC=$?
}
verdict_of() { printf '%s\n' "$OUT" | jq -r --argjson n "$1" 'select(.issue == $n) | .verdict'; }
field_of() { printf '%s\n' "$OUT" | jq -r --argjson n "$1" --arg f "$2" 'select(.issue == $n) | .[$f] // "null"'; }
gh_calls() { wc -l < "$STATE/calls.log" | tr -d ' '; }
comment_bodies() { jq -r '.[].body' "$STATE/i$1/comments.json" 2>/dev/null; }
marker_count() {
  [[ -f "$STATE/i$1/comments.json" ]] || { echo 0; return; }
  jq '[ .[] | select(.body | contains("<!-- claude-claim:")) ] | length' "$STATE/i$1/comments.json"
}
has_label() { grep -qxF in-progress "$STATE/i$1/labels" 2>/dev/null && echo yes || echo no; }

# Another holder's claim: same login, different holder, a named provider/device.
claim_as_other() { # <issue>
  "$TEST_SHELL" "$SINGLE" "$1" --claim --holder otherThread --provider codex --device studio --label overnight-run >/dev/null 2>&1
}

############################################################################
echo "== (1) mixed batch check: free, mine, claimed, unknown =="
reset_state
"$TEST_SHELL" "$SINGLE" 12 --claim --holder H1 >/dev/null 2>&1          # 12 is mine
claim_as_other 13                                                       # 13 is held by another holder
mkdir -p "$STATE/i14"; echo in-progress > "$STATE/i14/labels"             # 14: labeled, but its reads fail
export FAKE_BAD_ISSUE=14
run_batch --check 11 12 13 14 15 --holder H1
check_eq "exit 4 (an issue is unknown)" 4 "$RC"
check_eq "11 free reads unclaimed" unclaimed "$(verdict_of 11)"
check_eq "12 reads mine" mine "$(verdict_of 12)"
check_eq "13 reads claimed" claimed "$(verdict_of 13)"
check_eq "14 reads unknown" unknown "$(verdict_of 14)"
check_eq "15 free reads unclaimed" unclaimed "$(verdict_of 15)"
check_eq "one JSON object per issue" 5 "$(printf '%s\n' "$OUT" | jq -s 'length')"
check_eq "output keeps the order given" "11 12 13 14 15" "$(printf '%s\n' "$OUT" | jq -r '.issue' | tr '\n' ' ' | sed 's/ $//')"
check_eq "13 names the holder's provider" codex "$(field_of 13 provider)"
check_eq "13 names the holder's device" studio "$(field_of 13 device)"
check_eq "13 names the holder's run label" overnight-run "$(field_of 13 label)"
check_eq "13 names the holder token" otherThread "$(field_of 13 claimant_holder)"
check_eq "check writes nothing: still one marker on 12" 1 "$(marker_count 12)"
check_eq "check writes nothing: 11 has no marker" 0 "$(marker_count 11)"
unset FAKE_BAD_ISSUE
run_batch --check 11 12 13 15 --holder H1
check_eq "claimed without unknown: exit 1" 1 "$RC"
run_batch --check 11 12 15 --holder H1
check_eq "all proceedable: exit 0" 0 "$RC"
export FAKE_MISSING_ISSUE=12
run_batch --check 11 12 15 --holder H1
check_eq "an issue that no longer exists reads unknown, never free" unknown "$(verdict_of 12)"
check_eq "a missing issue makes the batch exit 4" 4 "$RC"
unset FAKE_MISSING_ISSUE

############################################################################
echo "== (2) batch claim: four free + one held elsewhere =="
reset_state
claim_as_other 25
run_batch --claim 21 22 23 24 25 --holder H1 --batch round-7 --provider claude-code --device laptop
check_eq "exit 1 (one claimed)" 1 "$RC"
for n in 21 22 23 24; do check_eq "$n comes back mine" mine "$(verdict_of $n)"; done
check_eq "25 comes back claimed" claimed "$(verdict_of 25)"
check_eq "25 names the other holder's provider" codex "$(field_of 25 provider)"
check_eq "25 names the other holder's device" studio "$(field_of 25 device)"
check_eq "25 was not touched: still one marker" 1 "$(marker_count 25)"
check_eq "21 carries the batch label" round-7 "$(field_of 21 batch)"
check_eq "21 carries the batch size (admitted issues)" 4 "$(field_of 21 batch_size)"
check_eq "21 has the in-progress label" yes "$(has_label 21)"
check_contains "21 visible comment names the batch" "One of 4 claimed together (batch round-7)" "$(comment_bodies 21)"
check_contains "21 visible comment keeps the holder facts" "Held by claude-code on device laptop" "$(comment_bodies 21)"
run_single 21 --check --holder H1 --json
check_eq "the batch marker still reads mine to a single check" mine "$(jq -r .verdict <<<"$OUT")"
check_eq "a single check reports batch" round-7 "$(jq -r .batch <<<"$OUT")"
check_eq "a single check reports batch_size" 4 "$(jq -r .batch_size <<<"$OUT")"
run_batch --check 21 22 --holder H2
check_eq "another holder sees the whole batch as claimed" "claimed claimed" "$(printf '%s\n' "$OUT" | jq -r '.verdict' | tr '\n' ' ' | sed 's/ $//')"
check_eq "and sees the batch in the claimant facts" round-7 "$(field_of 22 batch)"
run_batch --claim 21 22 --holder H1
check_eq "re-claiming your own batch is a no-op: exit 0" 0 "$RC"
check_eq "no second marker was written" 1 "$(marker_count 21)"
reset_state
run_batch --claim 31 32 33
check_eq "default batch label is generated (all mine, exit 0)" 0 "$RC"
check_eq "default label starts with b-" "b-" "$(field_of 31 batch | cut -c1-2)"
check_eq "all three share one label" 1 "$(printf '%s\n' "$OUT" | jq -s '[.[].batch] | unique | length')"
check_eq "size 3" 3 "$(field_of 33 batch_size)"

############################################################################
echo "== (3) a failed or truncated label index never reads as nothing claimed =="
reset_state
claim_as_other 41
for mode in error truncated garbage empty; do
  export FAKE_INDEX_MODE="$mode"
  run_batch --check 41 42 43 --holder H1
  check_eq "$mode: exit 4" 4 "$RC"
  check_eq "$mode: every issue unknown" "unknown unknown unknown" "$(printf '%s\n' "$OUT" | jq -r '.verdict' | tr '\n' ' ' | sed 's/ $//')"
  check_eq "$mode: a claimed issue is not reported unclaimed" 0 "$(printf '%s\n' "$OUT" | jq -s '[.[] | select(.verdict == "unclaimed")] | length')"
done
export FAKE_INDEX_MODE=error
run_batch --claim 42 43 --holder H1
check_eq "claim with an unreadable index: exit 4" 4 "$RC"
check_eq "claim with an unreadable index writes nothing (42)" 0 "$(marker_count 42)"
check_eq "claim with an unreadable index writes nothing (43)" 0 "$(marker_count 43)"
unset FAKE_INDEX_MODE
FAKE_VIEWER="__none__"
export FAKE_VIEWER=""
run_batch --check 42 --holder H1
check_eq "an unresolvable user is unknown, exit 4" "4 unknown" "$RC $(verdict_of 42)"
export FAKE_VIEWER=alice

############################################################################
echo "== (4) release on drop: an issue removed from the plan is released at once =="
reset_state
run_batch --claim 51 52 53 --holder H1 --batch drop-test
check_eq "claimed" 0 "$RC"
run_batch --release 52 --holder H1
check_eq "release exit 0" 0 "$RC"
check_eq "52 reads unclaimed in the same step" unclaimed "$(verdict_of 52)"
check_eq "52 marker gone" 0 "$(marker_count 52)"
check_eq "52 label gone" no "$(has_label 52)"
check_eq "51 untouched" 1 "$(marker_count 51)"
check_eq "53 untouched" yes "$(has_label 53)"
run_batch --check 51 52 53 --holder H2
check_eq "another holder can now take the dropped issue" "claimed unclaimed claimed" "$(printf '%s\n' "$OUT" | jq -r '.verdict' | tr '\n' ' ' | sed 's/ $//')"
run_batch --release 51 --holder H2
check_eq "another holder's batch release leaves the claim alone: exit 0" 0 "$RC"
check_eq "and reports it claimed" claimed "$(verdict_of 51)"
check_eq "51 marker and label survive" "1 yes" "$(marker_count 51) $(has_label 51)"
run_batch --release 52 --holder H1
check_eq "releasing again is idempotent" 0 "$RC"

############################################################################
echo "== (5) renewal keeps every held claim fresh and keeps the batch =="
reset_state
run_batch --claim 61 62 63 --holder H1 --batch renew-test
OLD="$(iso_ago 3)"
for n in 61 62 63; do
  jq --arg at "$OLD" '.[].created_at = $at' "$STATE/i$n/comments.json" > "$STATE/c.tmp" && mv "$STATE/c.tmp" "$STATE/i$n/comments.json"
done
run_batch --renew 61 62 63 --holder H1
check_eq "renew exit 0" 0 "$RC"
check_eq "all three renewed" "true true true" "$(printf '%s\n' "$OUT" | jq -r '.renewed' | tr '\n' ' ' | sed 's/ $//')"
check_eq "the batch label survives renewal" renew-test "$(field_of 62 batch)"
check_eq "the batch size survives renewal" 3 "$(field_of 62 batch_size)"
check_contains "the renewed comment still names the batch" "One of 3 claimed together (batch renew-test)" "$(comment_bodies 62)"
check_eq "one marker per issue after renewal" "1 1 1" "$(marker_count 61) $(marker_count 62) $(marker_count 63)"
run_batch --renew 61 62 63 --holder H1
check_eq "a not-due renewal writes nothing" "false false false" "$(printf '%s\n' "$OUT" | jq -r '.renewed' | tr '\n' ' ' | sed 's/ $//')"
run_batch --renew 61 99 --holder H1
check_eq "renewing an issue you do not hold: exit 5" 5 "$RC"
check_eq "and the held one is still renewed/ok" mine "$(verdict_of 61)"

############################################################################
echo "== (6) API cost: a 50-issue batch check is bounded, not three calls per issue =="
reset_state
ISSUES50=()
while IFS= read -r n; do ISSUES50+=("$n"); done < <(seq 101 150)
: > "$STATE/calls.log"
run_batch --check "${ISSUES50[@]}" --holder H1
BATCH_CALLS="$(gh_calls)"
check_eq "50 free issues: exit 0" 0 "$RC"
check_eq "50 JSON lines" 50 "$(printf '%s\n' "$OUT" | jq -s 'length')"
check_eq "50 verdicts all unclaimed" 50 "$(printf '%s\n' "$OUT" | jq -s '[.[] | select(.verdict == "unclaimed")] | length')"
echo "     measured: batch check of 50 unclaimed issues = $BATCH_CALLS gh call(s)"
: > "$STATE/calls.log"
for n in "${ISSUES50[@]}"; do "$TEST_SHELL" "$SINGLE" "$n" --check --holder H1 >/dev/null 2>&1; done
LOOP_CALLS="$(gh_calls)"
echo "     measured: 50 single-issue checks              = $LOOP_CALLS gh call(s)"
check_eq "batch check uses 3 calls (user + one index page + one existence read)" 3 "$BATCH_CALLS"
check_lt "batch check is far below the per-issue loop" "$BATCH_CALLS" "$LOOP_CALLS"
# With a few claimed issues the cost grows by the usual three reads each, not by N.
claim_as_other 110; claim_as_other 120
: > "$STATE/calls.log"
run_batch --check "${ISSUES50[@]}" --holder H1
check_eq "two labeled issues add 3 reads each: 3 + 6 calls" 9 "$(gh_calls)"
check_eq "and they read claimed" "claimed claimed" "$(printf '%s\n' "$OUT" | jq -r 'select(.verdict == "claimed") | .verdict' | tr '\n' ' ' | sed 's/ $//')"

# Write-path cost, per issue, so the renewal cadence can be judged against the
# shared API allowance (recorded in issue-claim.md; informational, not a bound).
reset_state
: > "$STATE/calls.log"
run_batch --claim 201 202 203 204 --holder H1 --batch cost
echo "     measured: batch claim of 4 free issues         = $(gh_calls) gh call(s) ($(( $(gh_calls) / 4 )) per issue after the shared 3)"
: > "$STATE/calls.log"
run_batch --renew 201 202 203 204 --holder H1
echo "     measured: renew of 4 held issues, none due     = $(gh_calls) gh call(s) ($(( $(gh_calls) / 4 )) per issue)"
check_eq "a not-due renewal reads three endpoints per issue" 12 "$(gh_calls)"
OLD="$(iso_ago 3)"
for n in 201 202 203 204; do
  jq --arg at "$OLD" '.[].created_at = $at' "$STATE/i$n/comments.json" > "$STATE/c.tmp" && mv "$STATE/c.tmp" "$STATE/i$n/comments.json"
done
: > "$STATE/calls.log"
run_batch --renew 201 202 203 204 --holder H1
echo "     measured: renew of 4 held issues, all due      = $(gh_calls) gh call(s) ($(( $(gh_calls) / 4 )) per issue)"

############################################################################
echo "== (7) single-issue output and exit codes are unchanged =="
reset_state
run_single 71 --claim --holder H1 --json
check_eq "single claim: no batch key in the JSON" false "$(jq 'has("batch") or has("batch_size")' <<<"$OUT")"
check_eq "single claim: exit 0" 0 "$RC"
check_eq "single claim: comment has no batch sentence" 0 "$(comment_bodies 71 | grep -c 'claimed together')"
run_single 71 --check --holder H1 --json
check_eq "single check: no batch key" false "$(jq 'has("batch")' <<<"$OUT")"
run_single 72 --claim --holder H1 --batch only-label
check_eq "--batch without --batch-size is a usage error" 2 "$RC"
run_single 72 --check --holder H1 --batch x --batch-size 3
check_eq "--batch on --check is a usage error" 2 "$RC"
run_single 72 --claim --holder H1 --batch "a/b" --batch-size 3
check_eq "a batch label with a path separator is a usage error" 2 "$RC"
run_single 72 --claim --holder H1 --batch ok --batch-size 0
check_eq "batch size 0 is a usage error" 2 "$RC"
run_batch --claim 72 --allow-claimed
check_eq "batch mode refuses --allow-claimed" 2 "$RC"
run_batch --check
check_eq "no issue numbers is a usage error" 2 "$RC"
run_batch --check 99999999999999999999 --holder H1
check_eq "an issue number beyond 9 digits is a usage error" 2 "$RC"
run_batch --check abc
check_eq "a non-numeric issue is a usage error" 2 "$RC"
run_batch --check 72 --batch x
check_eq "--batch on a batch --check is a usage error" 2 "$RC"
run_batch --claim 73 73 73 --holder H1
check_eq "duplicates are collapsed to one result" 1 "$(printf '%s\n' "$OUT" | jq -s 'length')"
run_batch --help
check_eq "--help exits 0" 0 "$RC"
check_contains "--help documents the exit codes" "EXIT STATUS" "$OUT"

############################################################################
echo "== (8) an issue that does not exist or is closed is never a startable 'unclaimed' =="
reset_state
export FAKE_MISSING_ISSUE=302 FAKE_CLOSED_ISSUE=303
: > "$STATE/calls.log"
run_batch --check 301 302 303 304 --holder H1
check_eq "a missing or closed issue makes the batch exit 4 (not proceedable)" 4 "$RC"
check_eq "open unlabeled issues stay unclaimed" "unclaimed unclaimed" "$(verdict_of 301) $(verdict_of 304)"
check_eq "a nonexistent issue is unknown, not unclaimed" unknown "$(verdict_of 302)"
check_contains "and says it was not found" "not found" "$(field_of 302 reason)"
check_eq "a closed issue is unknown, not unclaimed" unknown "$(verdict_of 303)"
check_contains "and says it is closed" "closed" "$(field_of 303 reason)"
check_eq "existence is one extra bounded read: 3 calls for 4 issues" 3 "$(gh_calls)"
run_batch --claim 301 302 303 304 --holder H1 --batch exist
check_eq "claim exits 4 for the unstartable pair" 4 "$RC"
check_eq "the open issues are still claimed" "mine mine" "$(verdict_of 301) $(verdict_of 304)"
check_eq "nothing is written to a missing or closed issue" "0 0 no no" "$(marker_count 302) $(marker_count 303) $(has_label 302) $(has_label 303)"
check_contains "batch size counts only the admitted issues" "One of 2 claimed together" "$(comment_bodies 301)"
export FAKE_GRAPHQL_MODE=error
run_batch --check 305 306 --holder H1
check_eq "a failed existence read is exit 4" 4 "$RC"
check_eq "and reads unknown, never unclaimed (fail-closed)" "unknown unknown" "$(verdict_of 305) $(verdict_of 306)"
unset FAKE_GRAPHQL_MODE FAKE_MISSING_ISSUE FAKE_CLOSED_ISSUE
reset_state
export FAKE_CLOSED_ISSUE=303
claim_as_other 303
run_batch --check 303 --holder H1
check_eq "a closed issue still in the label index is unknown, not claimed" unknown "$(verdict_of 303)"
check_contains "and says it is closed" "closed" "$(field_of 303 reason)"
unset FAKE_CLOSED_ISSUE

############################################################################
echo "== (9) release: a claim swapped between the check and the release is left alone =="
reset_state
SWAPDIR="$TMP/swapscripts"; mkdir -p "$SWAPDIR"
cp "$BATCH" "$SWAPDIR/issue-claim-batch.sh"
cat > "$SWAPDIR/issue-claim.sh" <<WRAP
#!/usr/bin/env bash
# Test wrapper: runs the real issue-claim.sh, then, right after the batch's
# --check of FAKE_SWAP_ISSUE, replaces the claim with another holder's.
out="\$("$SINGLE" "\$@")"; rc=\$?
printf '%s\n' "\$out"
if [[ "\${1:-}" == "\${FAKE_SWAP_ISSUE:-}" && " \$* " == *" --check "* && ! -f "$TMP/swapped" ]]; then
  : > "$TMP/swapped"
  "$SINGLE" "\$1" --release >/dev/null 2>&1
  "$SINGLE" "\$1" --claim --holder otherThread --provider codex --device studio >/dev/null 2>&1
fi
exit \$rc
WRAP
chmod +x "$SWAPDIR/issue-claim-batch.sh" "$SWAPDIR/issue-claim.sh"
"$TEST_SHELL" "$SINGLE" 401 --claim --holder H1 >/dev/null 2>&1
rm -f "$TMP/swapped"
export FAKE_SWAP_ISSUE=401
OUT="$("$TEST_SHELL" "$SWAPDIR/issue-claim-batch.sh" --release 401 --holder H1 2>"$TMP/err")"; RC=$?
unset FAKE_SWAP_ISSUE
check_eq "the swap actually happened between check and release" yes "$([[ -f "$TMP/swapped" ]] && echo yes || echo no)"
check_eq "release of a swapped claim exits 5 (not held)" 5 "$RC"
check_eq "the new holder's marker survives" 1 "$(marker_count 401)"
check_eq "and so does the label" yes "$(has_label 401)"
check_contains "the survivor is the other holder's" "otherThread" "$(comment_bodies 401)"

echo
echo "== summary: $PASS passed, $FAIL failed =="
if (( FAIL > 0 )); then exit 1; fi
echo "OK: issue-claim-batch.sh tests passed"
