#!/usr/bin/env bash
# Offline tests for backlog-staleness.sh (issue #598).
# Stubs `gh` with fixture JSON; runs inside a real temp git repo so the
# superseded/inactive commit-reference checks exercise real `git log`.
# Requires jq, git. Run from repo root: bash .claude/scripts/tests/backlog-staleness.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/backlog-staleness.sh"
GH_WINDOW="$REPO_ROOT/.claude/scripts/gh-window.sh"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
REPO_DIR="$TMP/repo"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }

check_json_has() {
  # $1 desc, $2 json, $3 jq boolean expr (applied to the array)
  local desc="$1" json="$2" expr="$3"
  if echo "$json" | jq -e "$expr" >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc (missing '$needle')"
  fi
}

# ---- build a real temp git repo (superseded/commit-ref checks use real git log) ----
mkdir -p "$REPO_DIR"
cd "$REPO_DIR"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
mkdir -p src
echo "v1" > src/parser.ts
git add src/parser.ts
GIT_AUTHOR_DATE="2026-01-01T00:00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:00" git commit -q -m "init parser"
for i in 1 2 3 4 5; do
  echo "v$i" >> src/parser.ts
  GIT_AUTHOR_DATE="2026-02-0${i}T00:00:00" GIT_COMMITTER_DATE="2026-02-0${i}T00:00:00" git commit -q -am "touch parser $i"
done
echo "dupe commit" > DUMMY.md
git add DUMMY.md
GIT_AUTHOR_DATE="2026-02-10T00:00:00" GIT_COMMITTER_DATE="2026-02-10T00:00:00" git commit -q -m "unrelated #90 fix, see #90"

# ---- stub gh ----------------------------------------------------------------
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
args="\$*"
case "\$args" in
  "issue list --state open"*)
    cat "$TMP/open.json"
    ;;
  "pr list --state merged"*)
    cat "$TMP/merged.json"
    ;;
  "pr list --state open"*)
    cat "$TMP/openprs.json"
    ;;
  *"issues?state=closed"*"&page=1"*)
    cat "$TMP/closed_page1.json"
    ;;
  *"issues?state=closed"*"&page=2"*)
    echo "[]"
    ;;
  *"/comments"*)
    num=\$(echo "\$args" | grep -oE 'issues/[0-9]+/comments' | grep -oE '[0-9]+')
    file="$TMP/comments/\${num}.txt"
    if [ -f "\$file" ]; then
      cat "\$file"
    else
      echo "null"
    fi
    ;;
  *)
    echo "gh stub: unhandled args: \$args" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"
mkdir -p "$TMP/comments"

NOW_ISO="2026-07-16T00:00:00Z"
OLD_ISO="2026-04-01T00:00:00Z"   # >30 days before "now" per fixture design

# ---------------------------------------------------------------------------
# Test 1: empty backlog → empty result, exit 0
# ---------------------------------------------------------------------------
echo "[]" > "$TMP/open.json"
echo "[]" > "$TMP/merged.json"
echo "[]" > "$TMP/openprs.json"
echo "[]" > "$TMP/closed_page1.json"

OUT=$(bash "$SCRIPT" --json 2>"$TMP/empty.err")
RC=$?
[[ "$RC" == "0" ]] && pass "Test1: empty backlog exits 0" || fail "Test1: empty backlog exit code ($RC)"
[[ "$OUT" == "[]" ]] && pass "Test1: empty backlog emits []" || fail "Test1: empty backlog output ($OUT)"

# ---------------------------------------------------------------------------
# Test 2: --days validation fallback (non-numeric, non-positive)
# ---------------------------------------------------------------------------
ERR=$(bash "$SCRIPT" --days abc --json 2>&1 >/dev/null)
check_contains "Test2a: non-numeric --days warns and defaults to 30" "defaulting to 30 days" "$ERR"
ERR=$(bash "$SCRIPT" --days 0 --json 2>&1 >/dev/null)
check_contains "Test2b: non-positive --days warns and defaults to 30" "defaulting to 30 days" "$ERR"

# ---------------------------------------------------------------------------
# Test 3: solved-by-pr — merged PR body closes an open issue
# ---------------------------------------------------------------------------
jq -n --arg u "$NOW_ISO" '[{number: 42, title: "Add retry logic", labels: [], assignees: [],
  createdAt: $u, updatedAt: $u, body: "some body"}]' > "$TMP/open.json"
jq -n --arg u "$NOW_ISO" '[{number: 88, title: "Fix retries", body: "Closes #42", mergedAt: $u, headRefName: "issue-42-retries"}]' > "$TMP/merged.json"
echo "[]" > "$TMP/openprs.json"
echo "[]" > "$TMP/closed_page1.json"

OUT=$(bash "$SCRIPT" --json)
check_json_has "Test3: solved-by-pr flags issue #42 via closing keyword" "$OUT" '[.[] | select(.number==42 and .category=="solved-by-pr" and .pr==88)] | length >= 1'

# ---------------------------------------------------------------------------
# Test 4: inactive — no comments, no PR ref, no commit ref, old updatedAt
# ---------------------------------------------------------------------------
jq -n --arg u "$OLD_ISO" '[{number: 100, title: "Old stale issue about widgets", labels: [], assignees: [],
  createdAt: $u, updatedAt: $u, body: "nothing interesting here"}]' > "$TMP/open.json"
echo "[]" > "$TMP/merged.json"
echo "[]" > "$TMP/openprs.json"
echo "[]" > "$TMP/closed_page1.json"

OUT=$(bash "$SCRIPT" --json)
check_json_has "Test4a: inactive flags issue #100" "$OUT" '[.[] | select(.number==100 and .category=="inactive")] | length == 1'

# Negative: same issue but with a recent comment → not flagged
echo "2026-07-15T00:00:00Z" > "$TMP/comments/100.txt"
OUT=$(bash "$SCRIPT" --json)
check_json_has "Test4b: recent comment suppresses inactive flag" "$OUT" '[.[] | select(.number==100 and .category=="inactive")] | length == 0'
rm -f "$TMP/comments/100.txt"

# ---------------------------------------------------------------------------
# Test 5: label-skip — pinned issue is never flagged inactive
# ---------------------------------------------------------------------------
jq -n --arg u "$OLD_ISO" '[{number: 101, title: "Pinned stale issue", labels: [{name:"pinned"}], assignees: [],
  createdAt: $u, updatedAt: $u, body: "nothing"}]' > "$TMP/open.json"
OUT=$(bash "$SCRIPT" --json)
check_json_has "Test5: pinned label suppresses inactive flag" "$OUT" '[.[] | select(.number==101)] | length == 0'

# ---------------------------------------------------------------------------
# Test 6: superseded — 5+ commits on a single referenced file (strong evidence)
# ---------------------------------------------------------------------------
jq -n --arg u "$NOW_ISO" '[{number: 200, title: "Parser needs cleanup", labels: [], assignees: [],
  createdAt: "2026-01-01T00:00:00Z", updatedAt: $u, body: "See src/parser.ts for the issue."}]' > "$TMP/open.json"
echo "[]" > "$TMP/merged.json"
echo "[]" > "$TMP/openprs.json"
echo "[]" > "$TMP/closed_page1.json"

OUT=$(bash "$SCRIPT" --json)
check_json_has "Test6: superseded flags issue #200 (5+ commits on src/parser.ts)" "$OUT" '[.[] | select(.number==200 and .category=="superseded" and .path=="src/parser.ts")] | length == 1'

# ---------------------------------------------------------------------------
# Test 7: potential-duplicate — title overlap vs. a resolved closed issue
# ---------------------------------------------------------------------------
jq -n --arg u "$NOW_ISO" '[{number: 300, title: "Improve backlog cleanup automation logic", labels: [], assignees: [],
  createdAt: $u, updatedAt: $u, body: "no cross reference here"}]' > "$TMP/open.json"
jq -n --arg u "$NOW_ISO" '[{number: 250, title: "Backlog cleanup automation logic rework", body: "", closed_at: $u, state_reason: "completed"}]' > "$TMP/closed_page1.json"
echo "[]" > "$TMP/merged.json"
echo "[]" > "$TMP/openprs.json"

OUT=$(bash "$SCRIPT" --json)
check_json_has "Test7a: potential-duplicate flags #300 vs resolved closed #250" "$OUT" '[.[] | select(.number==300 and .category=="potential-duplicate" and .closed_issue==250)] | length == 1'

# Negative: cross-reference suppression ("related to #250") should not flag
jq -n --arg u "$NOW_ISO" '[{number: 301, title: "Improve backlog cleanup automation logic", labels: [], assignees: [],
  createdAt: $u, updatedAt: $u, body: "related to #250, intentionally separate"}]' > "$TMP/open.json"
OUT=$(bash "$SCRIPT" --json)
check_json_has "Test7b: cross-reference suppression skips #301" "$OUT" '[.[] | select(.number==301)] | length == 0'

# Negative: closed issue not resolved (not_planned) should not count as duplicate source
jq -n --arg u "$NOW_ISO" '[{number: 302, title: "Improve backlog cleanup automation logic", labels: [], assignees: [],
  createdAt: $u, updatedAt: $u, body: ""}]' > "$TMP/open.json"
jq -n --arg u "$NOW_ISO" '[{number: 251, title: "Backlog cleanup automation logic rework", body: "", closed_at: $u, state_reason: "not_planned"}]' > "$TMP/closed_page1.json"
OUT=$(bash "$SCRIPT" --json)
check_json_has "Test7c: not_planned closed issue is not a duplicate source" "$OUT" '[.[] | select(.number==302)] | length == 0'

# ---------------------------------------------------------------------------
# Test 8: performance cap — only the 50 oldest inactive candidates get flagged
# ---------------------------------------------------------------------------
jq -n --arg u "$OLD_ISO" '[range(1;56) | {number: (400 + .), title: ("Stale issue " + (. | tostring)),
  labels: [], assignees: [], createdAt: $u, updatedAt: $u, body: "nothing"}]' > "$TMP/open.json"
echo "[]" > "$TMP/merged.json"
echo "[]" > "$TMP/openprs.json"
echo "[]" > "$TMP/closed_page1.json"

OUT=$(bash "$SCRIPT" --json 2>"$TMP/cap.err")
FLAGGED_COUNT=$(echo "$OUT" | jq '[.[] | select(.category=="inactive")] | length')
[[ "$FLAGGED_COUNT" == "50" ]] && pass "Test8a: performance cap flags exactly 50 of 55 candidates" || fail "Test8a: expected 50, got $FLAGGED_COUNT"
check_contains "Test8b: performance cap note on stderr" "not fully checked" "$(cat "$TMP/cap.err")"

# ---------------------------------------------------------------------------
# Text-mode (non-JSON) output sanity check
# ---------------------------------------------------------------------------
jq -n --arg u "$OLD_ISO" '[{number: 500, title: "Text mode check", labels: [], assignees: [],
  createdAt: $u, updatedAt: $u, body: "nothing"}]' > "$TMP/open.json"
echo "[]" > "$TMP/merged.json"
echo "[]" > "$TMP/openprs.json"
echo "[]" > "$TMP/closed_page1.json"
OUT=$(bash "$SCRIPT")
check_contains "Test9: default text mode emits tab-separated line" "$(printf '500\tinactive')" "$OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: backlog-staleness.sh — all fixtures passed (issue #598)"
