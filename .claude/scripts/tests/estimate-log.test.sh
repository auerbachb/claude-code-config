#!/usr/bin/env bash
# Offline tests for estimate-log.sh claim start-time selection (issue #1927).
# catalog: tests — Tests for `estimate-log.sh`: a renewed claim marker's payload `since` sets the start time; invalid values fall back to `created_at`
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
SCRIPT="$REPO_ROOT/.claude/scripts/estimate-log.sh"
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
    '{id: 1, created_at: $c, body: ("🔒 Claimed\n\n<!-- claude-claim: " + $p + " -->")}'
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
  bash "$SCRIPT" --append "$((100 + N))" --repo "$REPO" >/dev/null 2>&1
  jq -r '"\(.actual_min | floor) \(.start_source)"' "$ESTIMATE_LOG_FILE" 2>/dev/null || echo "no-row"
}

RENEWED_AT="2026-09-01T13:00:00Z"   # renewal marker created 1h before merge
SINCE="2026-09-01T12:00:00Z"        # original pickup 2h before merge

# 1. Renewed marker with a valid earlier `since` -> duration from `since`.
#    Two pages, the first holding an unrelated comment, to exercise --paginate.
got=$(run_case \
  '[{"id":9,"created_at":"2026-09-01T11:30:00Z","body":"unrelated"}]' \
  "[$(marker "$RENEWED_AT" "{\"holder\":\"h\",\"login\":\"me\",\"since\":\"$SINCE\"}")]")
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

# 6. Malformed marker JSON -> the comment still counts, via created_at.
got=$(run_case "[$(marker "$RENEWED_AT" '{"holder":')]")
check_eq "malformed marker JSON: falls back to created_at" "60 claim_comment" "$got"

# 7. A marker created after merge is excluded -> pr_created fallback.
got=$(run_case "[$(marker "2026-09-01T15:00:00Z" "{\"holder\":\"h\",\"since\":\"$SINCE\"}")]")
check_eq "post-merge marker excluded: pr_created" "180 pr_created" "$got"

# 8. No marker at all -> pr_created.
got=$(run_case '[]')
check_eq "no marker: pr_created" "180 pr_created" "$got"

# 9. Rollup output carries the start-time sentence.
OUT="$TMP/actuals.md"
ESTIMATE_LOG_FILE="$TMP/log-1.jsonl" bash "$SCRIPT" --rollup --repo "$REPO" --output "$OUT" >/dev/null 2>&1
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

if [[ -s "$TMP/fix/unexpected.log" ]]; then
  FAIL=$((FAIL + 1)); echo "FAIL — unexpected gh calls:"; sed 's/^/       /' "$TMP/fix/unexpected.log"
fi

echo
echo "estimate-log.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
