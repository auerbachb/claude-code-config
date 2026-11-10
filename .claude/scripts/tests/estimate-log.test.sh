#!/usr/bin/env bash
# Offline tests for estimate claim timestamps and rollup reporting (#1927, #2027).
# catalog: tests — Tests claim timestamps, parsed repo rollups, empty/error paths and preservation of the input ledger
#
# A renewed claim (issue #1914) posts a NEW marker whose GitHub `created_at` is
# the renewal time, and carries the original pickup time as payload `since`.
# Reading `created_at` alone would shorten every renewed pipeline's measured
# duration. These cases run the real CLI (`--append`, `--rollup`) against a
# fail-on-unexpected-call `gh` stub and assert the written JSONL row, not just
# the exit status.
#
# Run from repo root: bash .claude/scripts/tests/estimate-log.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="${ESTIMATE_LOG_TEST_SOURCE:-$REPO_ROOT/.claude/scripts/estimate-log.sh}"
ESTIMATE_TEST_SHELL="${ESTIMATE_TEST_SHELL:-$BASH}"
REPO="acme/widgets"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude/scripts" "$TMP/bin" "$TMP/fix"

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

# The fault hits the selection process in both old and new implementations.
ESTIMATE_TEST_REAL_JQ=$(command -v jq)
cat > "$TMP/bin/jq" <<JQ_STUB
#!/usr/bin/env bash
if [ "\${ESTIMATE_TEST_JQ_FAIL:-0}" = 1 ]; then
  for arg in "\$@"; do
    case "\$arg" in
      *".actual_min"*)
        case "\$arg" in *".outlier"*) echo 'injected selection process failure' >&2; exit 7 ;; esac ;;
    esac
  done
fi
exec "$ESTIMATE_TEST_REAL_JQ" "\$@"
JQ_STUB
chmod +x "$TMP/bin/jq"

# --- stubs ------------------------------------------------------------------
# gh: serves fixtures for the three calls build_row makes; anything else is
# recorded and fails, so a new unmocked call cannot pass silently.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
fix="$ESTIMATE_TEST_FIX"
case "$1 $2" in
  "api repos/acme/widgets/pulls/"*)       cat "$fix/pr.json" ;;
  "api repos/acme/widgets/issues/77/comments") cat "$fix/comments.json" ;;
  "api repos/acme/widgets/issues/77")     printf '{"body":"Estimate: 10-20 min, plan on 20"}' ;;
  *) printf '%s\n' "$*" >> "$fix/unexpected.log"; exit 99 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
# pr-issue-ref.sh: resolved by estimate-log through $HOME/.claude/scripts.
printf '#!/usr/bin/env bash\necho 77\n' > "$HOME/.claude/scripts/pr-issue-ref.sh"
chmod +x "$HOME/.claude/scripts/pr-issue-ref.sh"
export PATH="$TMP/bin:$PATH"
export ESTIMATE_TEST_FIX="$TMP/fix"

PR_CREATED="2026-09-01T11:00:00Z"
MERGED="2026-09-01T14:00:00Z"
printf '{"merged_at":"%s","state":"closed","created_at":"%s","commits":2}' \
  "$MERGED" "$PR_CREATED" > "$TMP/fix/pr.json"

# marker <created_at> <payload-json>: one claim comment object.
marker() {
  jq -cn --arg c "$1" --arg p "$2" \
    '{id: 1, created_at: $c, body: ("🔒 Claimed by `me` for active work.\n\n<!-- claude-claim: " + $p + " -->")}'
}

# run_case <comments-json-pages...> ; prints "<actual_min> <start_source>".
# It runs inside $(...), so the per-case counter lives in a file, not a
# variable: each case needs its own log and PR number because --append dedupes.
echo 0 > "$TMP/n"
run_case() {
  local N
  N=$(( $(cat "$TMP/n") + 1 )); echo "$N" > "$TMP/n"
  : > "$TMP/fix/comments.json"
  local page
  for page in "$@"; do printf '%s\n' "$page" >> "$TMP/fix/comments.json"; done
  export ESTIMATE_LOG_FILE="$TMP/log-$N.jsonl"
  "$ESTIMATE_TEST_SHELL" "$SCRIPT" --append "$((100 + N))" --repo "$REPO" >/dev/null 2>&1
  jq -r '"\(.actual_min | floor) \(.start_source)"' "$ESTIMATE_LOG_FILE" 2>/dev/null || echo "no-row"
}

RENEWED_AT="2026-09-01T13:00:00Z"   # renewal marker created 1h before merge
SINCE="2026-09-01T12:00:00Z"        # original pickup 2h before merge

PAYLOAD_WITH_SINCE=$(jq -cn --arg since "$SINCE" '{holder:"h",login:"me",since:$since}')
PAYLOAD_POST_MERGE=$(jq -cn --arg since "$SINCE" '{holder:"h",since:$since}')

# 1. Renewed marker with a valid earlier `since` -> duration from `since`.
#    Two pages, the first holding an unrelated comment, to exercise --paginate.
got=$(run_case \
  '[{"id":9,"created_at":"2026-09-01T11:30:00Z","body":"unrelated"}]' \
  "[$(marker "$RENEWED_AT" "$PAYLOAD_WITH_SINCE")]")
check_eq "renewed marker: start from payload since" "120 claim_comment" "$got"

# 2. Marker without `since` -> created_at.
got=$(run_case "[$(marker "$RENEWED_AT" '{"holder":"h","login":"me"}')]")
check_eq "no since: start from created_at" "60 claim_comment" "$got"

# 3. Malformed `since` (date only) -> created_at, never a 0-minute row.
got=$(run_case "[$(marker "$RENEWED_AT" '{"holder":"h","since":"2026-09-01"}')]")
check_eq "malformed since: falls back to created_at" "60 claim_comment" "$got"

# 4. Non-string `since` -> created_at.
got=$(run_case "[$(marker "$RENEWED_AT" '{"holder":"h","since":1756728000}')]")
check_eq "non-string since: falls back to created_at" "60 claim_comment" "$got"

# 5. `since` later than the marker's own created_at -> created_at.
got=$(run_case "[$(marker "$RENEWED_AT" '{"holder":"h","since":"2026-09-01T13:30:00Z"}')]")
check_eq "since after created_at: falls back to created_at" "60 claim_comment" "$got"

# 6. A genuine but unreadable newest record cannot supply a pickup time.
got=$(run_case "[$(marker "$RENEWED_AT" '{"holder":')]")
check_eq "malformed newest marker falls back to PR creation" "180 pr_created" "$got"

# 7. A marker created after merge is excluded -> pr_created fallback.
got=$(run_case "[$(marker "2026-09-01T15:00:00Z" "$PAYLOAD_POST_MERGE")]")
check_eq "post-merge marker excluded: pr_created" "180 pr_created" "$got"

# 8. No marker at all -> pr_created.
got=$(run_case '[]')
check_eq "no marker: pr_created" "180 pr_created" "$got"

# Quoted examples are not protocol records, even when newer than the real
# pickup or when the JSON in the example would otherwise be valid.
quote='{"id":22,"created_at":"2026-09-01T13:30:00Z","body":"A planning reply describes a `<!-- claude-claim: … -->` marker."}'
got=$(run_case "[$(marker "$RENEWED_AT" "$PAYLOAD_WITH_SINCE"),$quote]")
check_eq "newer quoted example cannot replace the renewed pickup" "120 claim_comment" "$got"
got=$(run_case "[$quote]")
check_eq "a quote alone is not a claim" "180 pr_created" "$got"
got=$(run_case "[$(marker "$SINCE" '{"holder":"older"}'),$(marker "$RENEWED_AT" '{"holder":')]")
check_eq "genuinely unreadable newest record does not borrow an older pickup" "180 pr_created" "$got"
got=$(run_case "[$(marker "$RENEWED_AT" "$PAYLOAD_WITH_SINCE"),$(marker "2026-09-01T15:00:00Z" "$PAYLOAD_POST_MERGE")]")
check_eq "post-merge marker does not shadow an earlier eligible record" "120 claim_comment" "$got"

historic=$(jq -cn --arg c "$RENEWED_AT" --arg p "$PAYLOAD_WITH_SINCE" \
  '{id:2,created_at:$c,body:("🔒 Claimed by `me` for active work. It will be released when this issue\u0027s PR merges, when the issue closes, or automatically after 4h of no activity.\n\n<!-- claude-claim: "+$p+" -->")}')
got=$(run_case "[$historic]")
check_eq "historical notice supplies the same renewal provenance" "120 claim_comment" "$got"
bare=$(jq -cn --arg c "$RENEWED_AT" --arg p "$PAYLOAD_WITH_SINCE" \
  '{id:3,created_at:$c,body:("<!-- claude-claim: "+$p+" -->")}')
got=$(run_case "[$bare]")
check_eq "bare record remains supported" "120 claim_comment" "$got"

# The shared reader is a pure stdin mode: no HOME, issue mutations, or
# additional authenticated requests are needed to parse these comments.
pure=$(
  unset HOME
  printf '%s\n' "[$bare,$quote]" |
    "$ESTIMATE_TEST_SHELL" "$REPO_ROOT/.claude/scripts/issue-claim.sh" --pickup-time "$MERGED"
)
check_eq "data-only mode works with HOME unset" "$SINCE" "$pure"

# 9. Rollup output carries the start-time sentence.
OUT="$TMP/actuals.md"
ESTIMATE_LOG_FILE="$TMP/log-1.jsonl" "$ESTIMATE_TEST_SHELL" "$SCRIPT" --rollup --repo "$REPO" --output "$OUT" >/dev/null 2>&1
if grep -q "payload \`since\` when valid" "$OUT" 2>/dev/null; then
  PASS=$((PASS + 1)); echo "ok   — rollup documents the since start-time rule"
else
  FAIL=$((FAIL + 1)); echo "FAIL — rollup output lacks the since start-time sentence"
fi

# 10. The checked-in reference carries the same sentence as the generator.
if grep -q "payload \`since\` when valid" "$REPO_ROOT/.claude/reference/estimate-actuals.md"; then
  PASS=$((PASS + 1)); echo "ok   — estimate-actuals.md carries the since sentence"
else
  FAIL=$((FAIL + 1)); echo "FAIL — estimate-actuals.md lacks the since sentence"
fi

# Parsed rollups preserve the ledger and are independent of JSON whitespace.
ROLLUP_DIR="$TMP/rollup"
mkdir -p "$ROLLUP_DIR"
python3 - "$ROLLUP_DIR" "$REPO" <<'ROLLUP_FIXTURES'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]);repo=sys.argv[2]
def row(pr,actual,rounds,tier='Light',outlier=False):
    return dict(pr=pr,issue=77,tier=tier,est_lo=60 if tier=='Light' else 120,est_hi=90 if tier=='Light' else 180,est_bound=90 if tier=='Light' else 180,claim_ts='2026-11-08T07:00:00Z',merge_ts='2026-11-08T12:%02d:00Z'%(pr*10),actual_min=actual,rounds=rounds,start_source='claim_comment',repo=repo,outlier=outlier)
valid=[row(1,10,1),row(2,400,3,outlier=True),row(3,60,None,tier='Standard')]
foreign=dict(valid[0],repo='other/repo',metadata={'repo':repo})
invalid=[None,[],False,42,'not an object',dict(valid[0],actual_min='10'),dict(valid[0],outlier='false'),dict(valid[0],repo=repo.upper()),foreign]
for layout in ('compact','spaced','tabs','crlf','escaped','sorted','no-newline'):
    separators=(',',':') if layout in ('compact','escaped','no-newline') else (',\t',':\t') if layout=='tabs' else (', ',': ')
    def encode(v):
        text=json.dumps(v,separators=separators,sort_keys=layout=='sorted')
        return text.replace(repo,repo.replace('/',r'\u002f')) if layout=='escaped' else text
    lines=['{"repo":"'+repo+'","actual_min":']+[encode(x) for x in invalid]
    lines += [encode(valid[0])+' '+encode(valid[1])]+[encode(x) for x in valid]
    ending='\r\n' if layout=='crlf' else '\n'
    text=ending.join(lines)+('' if layout=='no-newline' else ending)
    (root/(layout+'.jsonl')).write_bytes(text.encode())
(root/'empty.jsonl').write_bytes(b'')
(root/'blank.jsonl').write_bytes(b'\r\n\t \n')
(root/'foreign.jsonl').write_text(json.dumps(foreign,separators=(',',':'))+'\n')
(root/'malformed.jsonl').write_text('{bad\nnull\n[]\nfalse\n42\n')
(root/'native.jsonl').write_text(''.join(json.dumps(x,separators=(',',':'))+'\n' for x in valid))
ROLLUP_FIXTURES

run_rollup() {
  ROLLUP_RC=0
  ROLLUP_STDOUT=$(ESTIMATE_LOG_FILE="$1" "$ESTIMATE_TEST_SHELL" "$SCRIPT" --rollup --repo "$REPO" --output "$2" 2>"$TMP/rollup.err") || ROLLUP_RC=$?
  ROLLUP_ERR=$(cat "$TMP/rollup.err")
}
report_line() {
  if grep -Fqx -- "$1" "$2"; then printf 'yes\n'; else printf 'no\n'; fi
}
unchanged_file() {
  if cmp -s "$1" "$2"; then printf 'yes\n'; else printf 'no\n'; fi
}
REPORT="$TMP/parsed-actuals.md"
EXPECTED_SOURCE=$(cat <<'ROLLUP_SOURCE'
> Source: `~/.claude/estimate-log.jsonl` (3 rows for `acme/widgets`).
ROLLUP_SOURCE
)
for layout in compact spaced tabs crlf escaped sorted no-newline; do
  LEDGER="$ROLLUP_DIR/$layout.jsonl"
  cp "$LEDGER" "$TMP/input-before"
  run_rollup "$LEDGER" "$REPORT"
  check_eq "rollup $layout: status" 0 "$ROLLUP_RC"
  check_eq "rollup $layout: stdout is empty" "" "$ROLLUP_STDOUT"
  check_eq "rollup $layout: ledger bytes preserved" yes "$(unchanged_file "$LEDGER" "$TMP/input-before")"
  check_eq "rollup $layout: exactly three matching valid rows" yes "$(report_line "$EXPECTED_SOURCE" "$REPORT")"
  check_eq "rollup $layout: Light statistics and rounds" yes "$(report_line '| Light | 205 min | 361 min | 2 | 2.8 | 2 | 2 | 1 |' "$REPORT")"
  check_eq "rollup $layout: legacy rows keep minute counts without rounds" yes "$(report_line '| Standard | 60 min | 60 min | — | — | 1 | 0 | 0 |' "$REPORT")"
  grep -v '^> Auto-generated by' "$REPORT" > "$TMP/normalized-report"
  if [ "$layout" = compact ]; then cp "$TMP/normalized-report" "$TMP/expected-report"; fi
  check_eq "rollup $layout: equivalent report statistics" yes "$(unchanged_file "$TMP/normalized-report" "$TMP/expected-report")"
  run_rollup "$LEDGER" "$REPORT"
  check_eq "rollup $layout: repeat status" 0 "$ROLLUP_RC"
  check_eq "rollup $layout: repeat preserves ledger bytes" yes "$(unchanged_file "$LEDGER" "$TMP/input-before")"
done

for empty_case in empty blank foreign malformed missing; do
  printf 'existing-report\n' > "$REPORT"
  cp "$REPORT" "$TMP/report-before"
  run_rollup "$ROLLUP_DIR/$empty_case.jsonl" "$REPORT"
  check_eq "rollup $empty_case: single no-row exit" 1 "$ROLLUP_RC"
  check_eq "rollup $empty_case: no stdout fallback arrays" "" "$ROLLUP_STDOUT"
  check_eq "rollup $empty_case: existing report preserved" yes "$(unchanged_file "$REPORT" "$TMP/report-before")"
  check_eq "rollup $empty_case: no arithmetic diagnostics" 0 "$(printf '%s' "$ROLLUP_ERR" | grep -Eic 'syntax error|integer expression|arithmetic|too many arguments' || true)"
done

# Genuine selection/IO failures remain errors and cannot replace a report.
printf 'existing-report\n' > "$REPORT"
cp "$REPORT" "$TMP/report-before"
cp "$ROLLUP_DIR/native.jsonl" "$TMP/input-before"
export ESTIMATE_TEST_JQ_FAIL=1
run_rollup "$ROLLUP_DIR/native.jsonl" "$REPORT"
unset ESTIMATE_TEST_JQ_FAIL
check_eq "rollup selection process failure: file-error exit" 5 "$ROLLUP_RC"
check_eq "rollup selection process failure: report preserved" yes "$(unchanged_file "$REPORT" "$TMP/report-before")"
check_eq "rollup selection process failure: ledger preserved" yes "$(unchanged_file "$ROLLUP_DIR/native.jsonl" "$TMP/input-before")"
mkdir -p "$ROLLUP_DIR/directory-input"
run_rollup "$ROLLUP_DIR/directory-input" "$REPORT"
check_eq "rollup directory input: file-error exit" 5 "$ROLLUP_RC"
check_eq "rollup directory input: report preserved" yes "$(unchanged_file "$REPORT" "$TMP/report-before")"

# Reject direct, symbolic-link and hard-link aliases before opening output.
LEDGER="$ROLLUP_DIR/alias-input.jsonl"
cp "$ROLLUP_DIR/native.jsonl" "$LEDGER"
ln -s "$LEDGER" "$ROLLUP_DIR/alias-symbolic.md"
ln "$LEDGER" "$ROLLUP_DIR/alias-hard.md"
for alias_kind in direct symbolic hard; do
  cp "$ROLLUP_DIR/native.jsonl" "$LEDGER"
  cp "$LEDGER" "$TMP/input-before"
  case "$alias_kind" in
    direct) ALIAS="$LEDGER" ;;
    symbolic) ALIAS="$ROLLUP_DIR/alias-symbolic.md" ;;
    hard) ALIAS="$ROLLUP_DIR/alias-hard.md" ;;
  esac
  run_rollup "$LEDGER" "$ALIAS"
  check_eq "rollup $alias_kind output alias: refused as file error" 5 "$ROLLUP_RC"
  check_eq "rollup $alias_kind output alias: ledger bytes preserved" yes "$(unchanged_file "$LEDGER" "$TMP/input-before")"
  check_eq "rollup $alias_kind output alias: no stdout" "" "$ROLLUP_STDOUT"
done

# Swap the destination to a ledger link after the alias check, at the real
# output-directory creation boundary. Publication must replace the link entry.
ESTIMATE_REAL_MKDIR=$(command -v mkdir)
ESTIMATE_REAL_MKTEMP=$(command -v mktemp)
ESTIMATE_REAL_MV=$(command -v mv)
ESTIMATE_REAL_PYTHON=$(command -v python3)
export ESTIMATE_REAL_MKDIR ESTIMATE_REAL_MKTEMP ESTIMATE_REAL_MV ESTIMATE_REAL_PYTHON
export ESTIMATE_RACE_OUTPUT="$ROLLUP_DIR/race.md"
export ESTIMATE_RACE_LEDGER="$ROLLUP_DIR/native.jsonl"
export ESTIMATE_RACE_MARKER="$TMP/race-fired"
cat > "$TMP/bin/mkdir" <<'STUB'
#!/usr/bin/env bash
"$ESTIMATE_REAL_MKDIR" "$@" || exit "$?"
if [[ "${ESTIMATE_PUBLICATION_FAULT:-}" == race && "$*" == "-p $(dirname "$ESTIMATE_RACE_OUTPUT")" ]]; then
  ln -sf "$ESTIMATE_RACE_LEDGER" "$ESTIMATE_RACE_OUTPUT"
  : > "$ESTIMATE_RACE_MARKER"
fi
if [[ "$*" == "-p $(dirname "$ESTIMATE_RACE_OUTPUT")" ]]; then
  case "${ESTIMATE_PUBLICATION_FAULT:-}" in
    directory-race)
      rm -f "$ESTIMATE_RACE_OUTPUT"
      "$ESTIMATE_REAL_MKDIR" "$ESTIMATE_RACE_OUTPUT"
      : > "$ESTIMATE_RACE_MARKER" ;;
    directory-link-race)
      rm -f "$ESTIMATE_RACE_OUTPUT"
      ln -s "$ESTIMATE_RACE_TARGET" "$ESTIMATE_RACE_OUTPUT"
      : > "$ESTIMATE_RACE_MARKER" ;;
  esac
fi
STUB
cat > "$TMP/bin/mktemp" <<'STUB'
#!/usr/bin/env bash
if [[ "${ESTIMATE_PUBLICATION_FAULT:-}" == allocate && "$*" == *'.estimate-rollup-'* ]]; then exit 91; fi
exec "$ESTIMATE_REAL_MKTEMP" "$@"
STUB
cat > "$TMP/bin/python3" <<'STUB'
#!/usr/bin/env bash
if [[ "${ESTIMATE_PUBLICATION_FAULT:-}" == rename && "$*" == *'os.replace('* ]]; then exit 92; fi
exec "$ESTIMATE_REAL_PYTHON" "$@"
STUB
# Keep the existing selection-failure fixture intact; layer rendering failure
# on its exact jq table-render filter, after selection and temp allocation.
mv "$TMP/bin/jq" "$TMP/bin/jq-selection"
cat > "$TMP/bin/jq" <<'STUB'
#!/usr/bin/env bash
if [[ "${ESTIMATE_PUBLICATION_FAULT:-}" == render && "$*" == *'def fmt(x)'* ]]; then exit 93; fi
exec "$(dirname "$0")/jq-selection" "$@"
STUB
chmod +x "$TMP/bin/mkdir" "$TMP/bin/mktemp" "$TMP/bin/python3" "$TMP/bin/jq"
cp "$ESTIMATE_RACE_LEDGER" "$TMP/input-before"
for publication_case in race allocate render rename; do
  rm -f "$ESTIMATE_RACE_OUTPUT"
  printf 'existing-report\n' > "$ESTIMATE_RACE_OUTPUT"
  cp "$ESTIMATE_RACE_OUTPUT" "$TMP/report-before"
  export ESTIMATE_PUBLICATION_FAULT="$publication_case"
  run_rollup "$ESTIMATE_RACE_LEDGER" "$ESTIMATE_RACE_OUTPUT"
  unset ESTIMATE_PUBLICATION_FAULT
  check_eq "rollup $publication_case publication: ledger preserved" yes "$(unchanged_file "$ESTIMATE_RACE_LEDGER" "$TMP/input-before")"
  check_eq "rollup $publication_case publication: temp removed" 0 "$(find "$ROLLUP_DIR" -name '.estimate-rollup-*' | wc -l | tr -d ' ')"
  if [[ "$publication_case" == race ]]; then
    check_eq 'rollup publication race: boundary reached' yes "$([[ -f "$ESTIMATE_RACE_MARKER" ]] && echo yes)"
    check_eq 'rollup publication race: status' 0 "$ROLLUP_RC"
    check_eq 'rollup publication race: output no longer a link' yes "$([[ ! -L "$ESTIMATE_RACE_OUTPUT" ]] && echo yes)"
    check_eq 'rollup publication race: report complete' yes "$(report_line "$EXPECTED_SOURCE" "$ESTIMATE_RACE_OUTPUT")"
  else
    check_eq "rollup $publication_case publication: file-error exit" 5 "$ROLLUP_RC"
    check_eq "rollup $publication_case publication: old report preserved" yes "$(unchanged_file "$ESTIMATE_RACE_OUTPUT" "$TMP/report-before")"
  fi
done

# Atomic replacement preserves the redirect's prior permission contract.
file_mode() {
  python3 - "$1" <<'MODE_PY'
import os, stat, sys
print(f'{stat.S_IMODE(os.stat(sys.argv[1]).st_mode):03o}')
MODE_PY
}
SAVED_UMASK=$(umask)
for output_mask in 0022 0027 0077 0002; do
  MODE_REPORT="$ROLLUP_DIR/mode-new-$output_mask.md"
  umask "$output_mask"
  run_rollup "$ROLLUP_DIR/native.jsonl" "$MODE_REPORT"
  umask "$SAVED_UMASK"
  check_eq "rollup new report umask $output_mask: status" 0 "$ROLLUP_RC"
  case "$output_mask" in 0022) EXPECTED_MODE=644 ;; 0027) EXPECTED_MODE=640 ;; 0077) EXPECTED_MODE=600 ;; 0002) EXPECTED_MODE=664 ;; esac
  check_eq "rollup new report umask $output_mask: permissions" "$EXPECTED_MODE" "$(file_mode "$MODE_REPORT")"
done
for output_mode in 000 001 010 600 640 644 664 1001 1777 7777; do
  MODE_REPORT="$ROLLUP_DIR/mode-existing-$output_mode.md"
  printf 'existing\n' > "$MODE_REPORT"
  chmod "$output_mode" "$MODE_REPORT"
  run_rollup "$ROLLUP_DIR/native.jsonl" "$MODE_REPORT"
  check_eq "rollup existing mode $output_mode: status" 0 "$ROLLUP_RC"
  check_eq "rollup existing mode $output_mode: permissions" "$output_mode" "$(file_mode "$MODE_REPORT")"
  chmod 600 "$MODE_REPORT"
  check_eq "rollup existing mode $output_mode: complete report" yes "$(report_line "$EXPECTED_SOURCE" "$MODE_REPORT")"
done

# Leading-dash relative names retain their exact destination and alias safety.
ROLLUP_SAVED_CWD=$(pwd)
cd "$ROLLUP_DIR" || exit 1
for output_kind in existing new; do
  DASH_REPORT="-$output_kind-report.md"
  if [[ "$output_kind" == existing ]]; then
    printf 'old report\n' > "$DASH_REPORT"
    chmod 640 "./$DASH_REPORT"
  fi
  cp "$ROLLUP_DIR/native.jsonl" "$TMP/input-before"
  run_rollup "$ROLLUP_DIR/native.jsonl" "$DASH_REPORT"
  check_eq "rollup $output_kind dash name: status" 0 "$ROLLUP_RC"
  check_eq "rollup $output_kind dash name: exact report entry" yes "$(report_line "$EXPECTED_SOURCE" "./$DASH_REPORT")"
  if [[ "$output_kind" == existing ]]; then
    check_eq 'rollup existing dash name: permissions' 640 "$(file_mode "./$DASH_REPORT")"
  fi
  check_eq "rollup $output_kind dash name: ledger preserved" yes "$(unchanged_file "$ROLLUP_DIR/native.jsonl" "$TMP/input-before")"
  check_eq "rollup $output_kind dash name: no temporary artifact" 0 "$(find "$ROLLUP_DIR" -name '.estimate-rollup-*' | wc -l | tr -d ' ')"
done
ln -s "$ROLLUP_DIR/native.jsonl" ./-ledger-alias.md
run_rollup "$ROLLUP_DIR/native.jsonl" -ledger-alias.md
check_eq 'rollup dash alias: refused before mutation' 5 "$ROLLUP_RC"
check_eq 'rollup dash alias: ledger preserved' yes "$(unchanged_file "$ROLLUP_DIR/native.jsonl" "$TMP/input-before")"
cd "$ROLLUP_SAVED_CWD" || exit 1

# Permission failures must not publish or hide malformed mode output.
ESTIMATE_REAL_STAT=$(command -v stat)
ESTIMATE_REAL_CHMOD=$(command -v chmod)
export ESTIMATE_REAL_STAT ESTIMATE_REAL_CHMOD
cat > "$TMP/bin/stat" <<'STAT_STUB'
#!/usr/bin/env bash
case "${ESTIMATE_STAT_FAULT:-}" in
  missing) : > "$ESTIMATE_PERMISSION_MARKER"; exit 127 ;;
  malformed) : > "$ESTIMATE_PERMISSION_MARKER"; printf '%s\n' "$ESTIMATE_BAD_MODE"; exit 0 ;;
esac
exec "$ESTIMATE_REAL_STAT" "$@"
STAT_STUB
cat > "$TMP/bin/chmod" <<'CHMOD_STUB'
#!/usr/bin/env bash
if [[ "${ESTIMATE_CHMOD_FAULT:-}" == missing && "$*" == *'.estimate-rollup-'* ]]; then
  : > "$ESTIMATE_PERMISSION_MARKER"; exit 127
fi
exec "$ESTIMATE_REAL_CHMOD" "$@"
CHMOD_STUB
chmod +x "$TMP/bin/stat" "$TMP/bin/chmod"
export ESTIMATE_PERMISSION_MARKER="$TMP/permission-fault-fired"
MODE_REPORT="$ROLLUP_DIR/permission-failure.md"
for permission_fault in stat-missing chmod-missing mode-invalid mode-long mode-space mode-multiple; do
  printf 'original report\n' > "$MODE_REPORT"
  cp "$MODE_REPORT" "$TMP/report-before"
  rm -f "$ESTIMATE_PERMISSION_MARKER"
  case "$permission_fault" in
    stat-missing) export ESTIMATE_STAT_FAULT=missing ;;
    chmod-missing) export ESTIMATE_CHMOD_FAULT=missing ;;
    *) export ESTIMATE_STAT_FAULT=malformed
       case "$permission_fault" in
         mode-invalid) ESTIMATE_BAD_MODE=8 ;;
         mode-long) ESTIMATE_BAD_MODE=00000 ;;
         mode-space) ESTIMATE_BAD_MODE=' 600' ;;
         mode-multiple) ESTIMATE_BAD_MODE=$'600\n640' ;;
       esac
       export ESTIMATE_BAD_MODE ;;
  esac
  run_rollup "$ROLLUP_DIR/native.jsonl" "$MODE_REPORT"
  unset ESTIMATE_STAT_FAULT ESTIMATE_CHMOD_FAULT ESTIMATE_BAD_MODE
  check_eq "rollup $permission_fault: file-error exit" 5 "$ROLLUP_RC"
  check_eq "rollup $permission_fault: real boundary reached" yes "$([[ -f "$ESTIMATE_PERMISSION_MARKER" ]] && echo yes)"
  check_eq "rollup $permission_fault: report bytes preserved" yes "$(unchanged_file "$MODE_REPORT" "$TMP/report-before")"
  check_eq "rollup $permission_fault: ledger bytes preserved" yes "$(unchanged_file "$ROLLUP_DIR/native.jsonl" "$TMP/input-before")"
  check_eq "rollup $permission_fault: no temporary artifact" 0 "$(find "$ROLLUP_DIR" -name '.estimate-rollup-*' | wc -l | tr -d ' ')"
done

# Directory operands must never acquire mv's "move into this directory"
# semantics. A directory created after preflight must also fail safely.
DIRECTORY_TARGET="$ROLLUP_DIR/directory-target"
mkdir "$DIRECTORY_TARGET"
ln -s "$DIRECTORY_TARGET" "$ROLLUP_DIR/directory-link"
for directory_kind in directory-target directory-link; do
  run_rollup "$ROLLUP_DIR/native.jsonl" "$ROLLUP_DIR/$directory_kind"
  check_eq "rollup $directory_kind output: file-error exit" 5 "$ROLLUP_RC"
  check_eq "rollup $directory_kind output: directory stays empty" 0 "$(find "$DIRECTORY_TARGET" -type f | wc -l | tr -d ' ')"
  check_eq "rollup $directory_kind output: ledger preserved" yes "$(unchanged_file "$ROLLUP_DIR/native.jsonl" "$TMP/input-before")"
  check_eq "rollup $directory_kind output: no temporary artifact" 0 "$(find "$ROLLUP_DIR" -name '.estimate-rollup-*' | wc -l | tr -d ' ')"
done
export ESTIMATE_RACE_TARGET="$ROLLUP_DIR/race-directory-target"
mkdir "$ESTIMATE_RACE_TARGET"
for directory_race in directory-race directory-link-race; do
  rm -f "$ESTIMATE_RACE_MARKER"
  export ESTIMATE_RACE_OUTPUT="$ROLLUP_DIR/$directory_race.md"
  printf 'previous-report\n' > "$ESTIMATE_RACE_OUTPUT"
  export ESTIMATE_PUBLICATION_FAULT="$directory_race"
  run_rollup "$ESTIMATE_RACE_LEDGER" "$ESTIMATE_RACE_OUTPUT"
  unset ESTIMATE_PUBLICATION_FAULT
  check_eq "rollup $directory_race: boundary reached" yes "$([[ -f "$ESTIMATE_RACE_MARKER" ]] && echo yes)"
  check_eq "rollup $directory_race: ledger preserved" yes "$(unchanged_file "$ESTIMATE_RACE_LEDGER" "$TMP/input-before")"
  check_eq "rollup $directory_race: target stays empty" 0 "$(find "$ESTIMATE_RACE_TARGET" -type f | wc -l | tr -d ' ')"
  check_eq "rollup $directory_race: no temporary artifact" 0 "$(find "$ROLLUP_DIR" -name '.estimate-rollup-*' | wc -l | tr -d ' ')"
  if [[ "$directory_race" == directory-race ]]; then
    check_eq 'rollup real-directory race: file-error exit' 5 "$ROLLUP_RC"
    check_eq 'rollup real-directory race: directory stays empty' 0 "$(find "$ESTIMATE_RACE_OUTPUT" -type f | wc -l | tr -d ' ')"
  else
    check_eq 'rollup directory-link race: exact path published' 0 "$ROLLUP_RC"
    check_eq 'rollup directory-link race: output is a regular non-link file' yes "$([[ -f "$ESTIMATE_RACE_OUTPUT" && ! -L "$ESTIMATE_RACE_OUTPUT" ]] && echo yes)"
    check_eq 'rollup directory-link race: report complete' yes "$(report_line "$EXPECTED_SOURCE" "$ESTIMATE_RACE_OUTPUT")"
  fi
done

if [[ -s "$TMP/fix/unexpected.log" ]]; then
  FAIL=$((FAIL + 1)); echo "FAIL — unexpected gh calls:"; sed 's/^/       /' "$TMP/fix/unexpected.log"
fi

echo
echo "estimate-log.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
