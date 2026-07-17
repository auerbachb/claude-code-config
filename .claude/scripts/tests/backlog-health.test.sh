#!/usr/bin/env bash
# Offline tests for backlog-health.sh (issue #598).
# Stubs `gh` with fixture JSON. backlog-health.sh shells out to the real
# backlog-staleness.sh, so this test exercises that composition end-to-end
# rather than mocking it out — both scripts share the same gh stub.
# Requires jq, git, awk. Run from repo root:
#   bash .claude/scripts/tests/backlog-health.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/backlog-health.sh"

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

check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$desc"
  else
    fail "$desc (expected '$expected', got '$actual')"
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

mkdir -p "$REPO_DIR"
cd "$REPO_DIR"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
git commit -q --allow-empty -m "init"

# ---- date helpers (same date binary used by gh-window.sh under test) -------
days_ago_iso() {
  local n="$1"
  date -v-"${n}"d -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${n} days ago" +%Y-%m-%dT%H:%M:%SZ
}

D3="$(days_ago_iso 3)"
D5="$(days_ago_iso 5)"
D20="$(days_ago_iso 20)"
D35="$(days_ago_iso 35)"
D40="$(days_ago_iso 40)"

# ---- stub gh ----------------------------------------------------------------
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
args="\$*"
case "\$args" in
  *"issue list --state open"*)
    cat "$TMP/open.json"
    ;;
  *"issue list --state closed"*"--search"*)
    since=\$(echo "\$args" | grep -oE 'closed:>=[0-9-]+' | sed 's/closed:>=//')
    jq --arg since "\$since" '[.[] | select(.closedAt >= \$since)]' "$TMP/closed.json"
    ;;
  "pr list --state merged"*)
    echo "[]"
    ;;
  "pr list --state open"*)
    echo "[]"
    ;;
  *"issues?state=closed"*"&page=1"*)
    echo "[]"
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

# ---------------------------------------------------------------------------
# Scenario A: mixed backlog — verifies age split, candidate/age intersection,
# actionable backlog, throughput counts, and a "weeks" estimate.
# ---------------------------------------------------------------------------
jq -n --arg d1 "$D40" --arg d2 "$D5" --arg d3 "$D40" --arg d4 "$(days_ago_iso 2)" --arg d5 "$D35" '
[
  {number: 1, title: "Old stale issue about parsers", labels: [], assignees: [], createdAt: $d1, updatedAt: $d1, body: ""},
  {number: 2, title: "Recent issue", labels: [], assignees: [], createdAt: $d2, updatedAt: $d2, body: ""},
  {number: 3, title: "Old but recently commented issue", labels: [], assignees: [], createdAt: $d3, updatedAt: $d3, body: ""},
  {number: 4, title: "Very recent issue", labels: [], assignees: [], createdAt: $d4, updatedAt: $d4, body: ""},
  {number: 5, title: "Another old stale issue", labels: [], assignees: [], createdAt: $d5, updatedAt: $d5, body: ""}
]' > "$TMP/open.json"

echo "$D5" > "$TMP/comments/3.txt"   # issue #3 has a recent comment -> not inactive

jq -n --arg d1 "$D3" --arg d2 "$D3" --arg d3 "$D20" --arg d4 "$D40" '
[
  {number: 900, closedAt: $d1},
  {number: 901, closedAt: $d2},
  {number: 902, closedAt: $d3},
  {number: 903, closedAt: $d4}
]' > "$TMP/closed.json"

OUT=$(bash "$SCRIPT" --json)
RC=$?
[[ "$RC" == "0" ]] || fail "ScenarioA: exits 0 (got $RC)"

check_eq "ScenarioA: total_open" "5" "$(echo "$OUT" | jq '.total_open')"
check_eq "ScenarioA: opened_last_N_days (createdAt within 30d: #2, #4)" "2" "$(echo "$OUT" | jq '.opened_last_N_days')"
check_eq "ScenarioA: older_than_N_days" "3" "$(echo "$OUT" | jq '.older_than_N_days')"
check_eq "ScenarioA: candidate_count (only #1 and #5 — #3 has a recent comment)" "2" "$(echo "$OUT" | jq '.candidate_count')"
check_eq "ScenarioA: actionable_backlog" "3" "$(echo "$OUT" | jq '.actionable_backlog')"
check_eq "ScenarioA: closed_last_recent_days (7d window: 2 closures)" "2" "$(echo "$OUT" | jq '.closed_last_recent_days')"
check_eq "ScenarioA: closed_last_N_days (30d window: 3 closures)" "3" "$(echo "$OUT" | jq '.closed_last_N_days')"
check_eq "ScenarioA: estimate unit is weeks (actionable=3, rate=0.1/day -> 30 days)" "weeks" "$(echo "$OUT" | jq -r '.estimate.unit')"
check_eq "ScenarioA: estimate value ~4 weeks" "4" "$(echo "$OUT" | jq '.estimate.value')"
check_eq "ScenarioA: estimate_message is null when rate is non-zero" "null" "$(echo "$OUT" | jq '.estimate_message')"

# ---------------------------------------------------------------------------
# Scenario B: zero 30-day closure rate — graceful degradation, no div-by-zero
# ---------------------------------------------------------------------------
echo "[]" > "$TMP/closed.json"
OUT=$(bash "$SCRIPT" --json)
check_eq "ScenarioB: closure_rate_per_day is null when nothing closed" "null" "$(echo "$OUT" | jq '.closure_rate_per_day')"
check_eq "ScenarioB: estimate is null when rate is zero" "null" "$(echo "$OUT" | jq '.estimate')"
check_eq "ScenarioB: estimate_message present when rate is zero" '"cadence too low to estimate"' "$(echo "$OUT" | jq '.estimate_message')"
check_contains "ScenarioB: text mode shows graceful message" "cadence too low to estimate" "$(bash "$SCRIPT")"

# ---------------------------------------------------------------------------
# Scenario C: empty backlog — no divide-by-zero on actionable_backlog=0 either
# ---------------------------------------------------------------------------
echo "[]" > "$TMP/open.json"
OUT=$(bash "$SCRIPT" --json)
RC=$?
[[ "$RC" == "0" ]] && pass "ScenarioC: empty backlog exits 0" || fail "ScenarioC: empty backlog exit code ($RC)"
check_eq "ScenarioC: total_open is 0" "0" "$(echo "$OUT" | jq '.total_open')"
check_eq "ScenarioC: candidate_count is 0" "0" "$(echo "$OUT" | jq '.candidate_count')"
check_eq "ScenarioC: actionable_backlog is 0" "0" "$(echo "$OUT" | jq '.actionable_backlog')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: backlog-health.sh — all fixtures passed (issue #598)"
