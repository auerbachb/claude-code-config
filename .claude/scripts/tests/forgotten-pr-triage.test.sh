#!/usr/bin/env bash
# Offline tests for forgotten-pr-triage.sh (issue #657).
# Stubs `gh` with fixture JSON/values; runs inside a real temp git repo with a
# file-based `origin` remote carrying refs/pull/<N>/head refs, so the
# supersession ("already in main") check exercises the real `git fetch` +
# `git cherry` path. Requires jq, git. Run from repo root:
#   bash .claude/scripts/tests/forgotten-pr-triage.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/forgotten-pr-triage.sh"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
REMOTE_DIR="$TMP/origin.git"
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

check_line() {
  # Exact whole-line match (anchored) — stronger than substring check_contains.
  local desc="$1" line="$2" hay="$3"
  if printf '%s\n' "$hay" | grep -Fxq "$line"; then
    pass "$desc"
  else
    fail "$desc (missing exact line '$line')"
  fi
}

days_ago_iso() {
  # Portable N-days-ago ISO-8601 (…Z). BSD date first, GNU date fallback.
  local n="$1"
  date -u -v-"${n}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "${n} days ago" +%Y-%m-%dT%H:%M:%SZ
}

# ---------------------------------------------------------------------------
# Build a bare "origin" and a working repo wired to it.
#   main:    base
#   pr-101:  base + C   (superseded — C is cherry-picked onto main as C')
#   pr-102:  base + D   (net-new → merge)
#   pr-103:  base + E   (body "Closes #55"; issue #55 CLOSED → close)
#   pr-105:  base + F   (body "Closes #66"; issue #66 OPEN  → merge)
#   #104:    fresh (updatedAt = now) → filtered out by age, never fetched
# ---------------------------------------------------------------------------
git init -q --bare "$REMOTE_DIR"
git -c init.defaultBranch=main init -q "$REPO_DIR"
cd "$REPO_DIR"
git config user.email "test@example.com"
git config user.name "Test"
git branch -M main 2>/dev/null || true

echo base > base.txt
git add base.txt
git commit -q -m "base"
git remote add origin "$REMOTE_DIR"
git push -q origin main
git fetch -q origin

# pr-101 — will be superseded
git checkout -q -b pr-101 main
echo c101 > f101.txt; git add f101.txt; git commit -q -m "change 101"
PR101_SHA="$(git rev-parse HEAD)"
git push -q origin "pr-101:refs/pull/101/head"

# pr-102 — net-new
git checkout -q -b pr-102 main
echo d102 > f102.txt; git add f102.txt; git commit -q -m "feat 102"
git push -q origin "pr-102:refs/pull/102/head"

# pr-103 — linked issue closed
git checkout -q -b pr-103 main
echo e103 > f103.txt; git add f103.txt; git commit -q -m "feat 103"
git push -q origin "pr-103:refs/pull/103/head"

# pr-105 — linked issue open
git checkout -q -b pr-105 main
echo f105 > f105.txt; git add f105.txt; git commit -q -m "feat 105"
git push -q origin "pr-105:refs/pull/105/head"

# Cherry-pick pr-101's commit onto main (equivalent patch already in main),
# then publish — this is what makes pr-101 "superseded / already in main".
git checkout -q main
GIT_EDITOR=true git cherry-pick "$PR101_SHA" >/dev/null
git push -q origin main
git fetch -q origin

# ---------------------------------------------------------------------------
# Fixtures: PR list + per-PR bodies + linked-issue states.
# ---------------------------------------------------------------------------
OLD_ISO="2026-01-01T00:00:00Z"                       # >3 days old, stays so
RECENT_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"          # now → not forgotten

jq -n --arg old "$OLD_ISO" --arg recent "$RECENT_ISO" '
  [ {number:101, title:"PR 101", updatedAt:$old,    headRefName:"pr-101", url:"http://x/101"},
    {number:102, title:"PR 102", updatedAt:$old,    headRefName:"pr-102", url:"http://x/102"},
    {number:103, title:"PR 103", updatedAt:$old,    headRefName:"pr-103", url:"http://x/103"},
    {number:104, title:"PR 104", updatedAt:$recent, headRefName:"pr-104", url:"http://x/104"},
    {number:105, title:"PR 105", updatedAt:$old,    headRefName:"pr-105", url:"http://x/105"} ]
' > "$TMP/prs.json"

mkdir -p "$TMP/pr_body" "$TMP/issue_state"
echo "just a change, no closing keyword"  > "$TMP/pr_body/101.txt"
echo "another change, no closing keyword" > "$TMP/pr_body/102.txt"
echo "feature work. Closes #55"           > "$TMP/pr_body/103.txt"
echo "some fresh work"                    > "$TMP/pr_body/104.txt"
echo "feature work. Closes #66"           > "$TMP/pr_body/105.txt"
echo "CLOSED" > "$TMP/issue_state/55.txt"
echo "OPEN"   > "$TMP/issue_state/66.txt"

# ---------------------------------------------------------------------------
# gh stub — handles the three call shapes this feature makes:
#   pr list ...                         → the PR-list fixture (no --jq)
#   pr view <N> --json body --jq ...    → that PR's body text (pr-issue-ref.sh)
#   issue view <N> --json state --jq ...→ that issue's state (OPEN/CLOSED)
# ---------------------------------------------------------------------------
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
args="\$*"
case "\$args" in
  "pr list "*)
    cat "$TMP/prs.json"
    ;;
  "pr view "*)
    n=\$(echo "\$args" | sed -n 's/^pr view \([0-9]*\).*/\1/p')
    if [ -f "$TMP/pr_body/\${n}.txt" ]; then cat "$TMP/pr_body/\${n}.txt"; else echo ""; fi
    ;;
  "issue view "*)
    n=\$(echo "\$args" | sed -n 's/^issue view \([0-9]*\).*/\1/p')
    if [ -f "$TMP/issue_state/\${n}.txt" ]; then cat "$TMP/issue_state/\${n}.txt"; else echo ""; fi
    ;;
  *)
    echo "gh stub: unhandled args: \$args" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

# ---------------------------------------------------------------------------
# Test 1: full fixture, --json — classifications + age filter + exit 0
# ---------------------------------------------------------------------------
OUT="$(cd "$REPO_DIR" && bash "$SCRIPT" --days 3 --json 2>"$TMP/t1.err")"
RC=$?
[[ "$RC" == "0" ]] && pass "Test1: exit 0 on full fixture" || fail "Test1: exit code ($RC)"
check_json_has "Test1a: #101 → close (superseded / already in main)" "$OUT" \
  '[.[] | select(.number==101 and .recommendation=="close" and .rationale=="superseded / already in main")] | length == 1'
check_json_has "Test1b: #102 → merge (net-new commits)" "$OUT" \
  '[.[] | select(.number==102 and .recommendation=="merge")] | length == 1'
check_json_has "Test1c: #103 → close (linked issue #55 closed)" "$OUT" \
  '[.[] | select(.number==103 and .recommendation=="close" and .rationale=="linked issue #55 closed")] | length == 1'
check_json_has "Test1d: #105 → merge (linked issue #66 open)" "$OUT" \
  '[.[] | select(.number==105 and .recommendation=="merge")] | length == 1'
check_json_has "Test1e: #104 excluded — newer than threshold" "$OUT" \
  '[.[] | select(.number==104)] | length == 0'
check_json_has "Test1f: exactly 4 forgotten PRs" "$OUT" 'length == 4'
check_json_has "Test1g: merge rationale is empty" "$OUT" \
  '[.[] | select(.recommendation=="merge" and .rationale != "")] | length == 0'

# ---------------------------------------------------------------------------
# Test 2: default (TSV) output shape — exact records, exact count
# ---------------------------------------------------------------------------
OUT="$(cd "$REPO_DIR" && bash "$SCRIPT" --days 3 2>/dev/null)"
N_LINES="$(printf '%s\n' "$OUT" | grep -c . || true)"
[[ "$N_LINES" == "4" ]] && pass "Test2: exactly 4 TSV records" || fail "Test2: expected 4 TSV records, got $N_LINES"
# @tsv of a "merge" record has an empty 3rd field → a trailing tab.
check_line "Test2a: exact TSV line for #101 close" "$(printf '101\tclose\tsuperseded / already in main')" "$OUT"
check_line "Test2b: exact TSV line for #102 merge" "$(printf '102\tmerge\t')" "$OUT"

# ---------------------------------------------------------------------------
# Test 3: threshold — nothing forgotten → [] exit 0 (empty is valid)
# ---------------------------------------------------------------------------
OUT="$(cd "$REPO_DIR" && bash "$SCRIPT" --days 100000 --json 2>/dev/null)"
RC=$?
[[ "$RC" == "0" ]] && pass "Test3a: huge --days exits 0" || fail "Test3a: exit code ($RC)"
[[ "$OUT" == "[]" ]] && pass "Test3b: huge --days emits []" || fail "Test3b: output ($OUT)"

# ---------------------------------------------------------------------------
# Test 4: --days validation fallback (non-numeric, non-positive) — warning AND
# the effective threshold after fallback is exactly 3 days.
# ---------------------------------------------------------------------------
ERR="$(cd "$REPO_DIR" && bash "$SCRIPT" --days abc --json 2>&1 >/dev/null)"
check_contains "Test4a: non-numeric --days warns and defaults to 3" "defaulting to 3 days" "$ERR"
ERR="$(cd "$REPO_DIR" && bash "$SCRIPT" --days 0 --json 2>&1 >/dev/null)"
check_contains "Test4b: non-positive --days warns and defaults to 3" "defaulting to 3 days" "$ERR"

# Boundary: after fallback, threshold is exactly 3 — a PR 4 days idle is
# forgotten, a PR 2 days idle is not. Uses a dedicated 2-PR fixture (restored
# afterward) so it never perturbs the shared 5-PR fixture the other tests use.
ISO_2D="$(days_ago_iso 2)"
ISO_4D="$(days_ago_iso 4)"
cp "$TMP/prs.json" "$TMP/prs.orig.json"
jq -n --arg d2 "$ISO_2D" --arg d4 "$ISO_4D" '
  [ {number:201, title:"PR 201", updatedAt:$d2, headRefName:"pr-201", url:"http://x/201"},
    {number:202, title:"PR 202", updatedAt:$d4, headRefName:"pr-202", url:"http://x/202"} ]
' > "$TMP/prs.json"
OUT="$(cd "$REPO_DIR" && bash "$SCRIPT" --days abc --json 2>/dev/null)"
check_json_has "Test4c: 4-days-idle #202 IS forgotten at fallback threshold 3" "$OUT" \
  '[.[] | select(.number==202)] | length == 1'
check_json_has "Test4d: 2-days-idle #201 NOT forgotten at fallback threshold 3" "$OUT" \
  '[.[] | select(.number==201)] | length == 0'
cp "$TMP/prs.orig.json" "$TMP/prs.json"

# ---------------------------------------------------------------------------
# Test 5: usage error on unknown flag
# ---------------------------------------------------------------------------
(cd "$REPO_DIR" && bash "$SCRIPT" --bogus >/dev/null 2>&1)
[[ "$?" == "2" ]] && pass "Test5: unknown flag exits 2" || fail "Test5: unknown flag exit code"

# ---------------------------------------------------------------------------
# Test 6: read-only — HEAD, branch, and worktree/index all untouched after a run
# ---------------------------------------------------------------------------
git -C "$REPO_DIR" checkout -q main
BEFORE="$(git -C "$REPO_DIR" rev-parse HEAD)"
BEFORE_BRANCH="$(git -C "$REPO_DIR" symbolic-ref --quiet --short HEAD)"
BEFORE_STATUS="$(git -C "$REPO_DIR" status --porcelain)"
# Full ref snapshot — proves fetches never mutate persistent refs
# (e.g. refs/remotes/origin/main), only FETCH_HEAD + the object store.
BEFORE_REFS="$(git -C "$REPO_DIR" show-ref)"
(cd "$REPO_DIR" && bash "$SCRIPT" --days 3 --json >/dev/null 2>&1)
AFTER="$(git -C "$REPO_DIR" rev-parse HEAD)"
AFTER_BRANCH="$(git -C "$REPO_DIR" symbolic-ref --quiet --short HEAD)"
AFTER_STATUS="$(git -C "$REPO_DIR" status --porcelain)"
AFTER_REFS="$(git -C "$REPO_DIR" show-ref)"
[[ "$BEFORE" == "$AFTER" ]] && pass "Test6: HEAD unchanged (read-only)" || fail "Test6: HEAD moved"
[[ "$BEFORE_BRANCH" == "$AFTER_BRANCH" ]] && pass "Test6: branch unchanged" || fail "Test6: branch changed"
[[ "$BEFORE_STATUS" == "$AFTER_STATUS" ]] && pass "Test6: worktree/index unchanged" || fail "Test6: worktree changed"
[[ "$BEFORE_REFS" == "$AFTER_REFS" ]] && pass "Test6: refs unchanged (no origin/main mutation)" || fail "Test6: refs mutated"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: forgotten-pr-triage.sh — all fixtures passed (issue #657)"
