#!/usr/bin/env bash
# Tests /pm Step 1B.2's new-issue block: an issue filed since the last backlog scan is named (issue #1766).
# catalog: tests — Runs the real `/pm` Step 1B.2 `pm-1b2-new-issues` block against a stubbed gh and the real session-state.sh, proving a freshly filed issue lands in NEW_ISSUES on the next scan
#
# WHAT IS UNDER TEST
#   The REAL fenced bash in `.claude/skills/pm/SKILL.md` under
#   `<!-- test-anchor: pm-1b2-new-issues -->`, extracted at run time by
#   `lib/skill-bash.sh`, run against a `gh` stub on PATH (serving a backlog
#   fixture per call, logging every call) and the REAL `session-state.sh`
#   pointed at a scratch state file.
#
# WHY (issue #1766, AC 4.3 "verified, not assumed")
#   An idea filed from the desk must appear in the PM thread's next backlog
#   ranking with no extra step. The 1B.3 shortlist (~20 by fast signals) and
#   the 1B.5 top 3–5 cannot promise that for a new, quiet issue; this block
#   is what `/pm` adds to every shortlist and names in its output.
#
# CASES
#   first scan     no baseline: the last 24 h; an issue shaped like
#                  issue-file.sh's output (unassigned, ordinary labels) is new;
#                  assigned, excluded-label, and older issues are not; the
#                  baseline is written
#   next scan      a fresh `gh issue list` (never a saved list): an issue
#                  filed after the baseline is new, the earlier one no longer
#   gh fails       DEGRADED line, NEW_ISSUES=[], baseline unchanged
#   label case     `On-Hold` / `Duplicate` excluded whatever their case
#   a full page    500 rows all newer than the baseline may be cut short:
#                  DEGRADED line, baseline unchanged; 500 rows reaching past
#                  it are complete, and the baseline moves
#   no state       without session-state.sh: the last 24 h, no --repo, no
#                  baseline kept
#
# Requires: bash 3.2+, jq. Offline: no network, no real gh.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.claude/scripts/tests/lib/skill-bash.sh
. "$TEST_DIR/lib/skill-bash.sh"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)"
SKILL_MD="$SCRIPTS_DIR/../skills/pm/SKILL.md"

PASS=0
FAIL=0
pass() { echo "ok   — $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL — $1" >&2; FAIL=$((FAIL + 1)); }
check_eq() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
check_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (expected to contain '$2', got '$3')" ;; esac; }

check_eq "negative control" "a" "b" >/dev/null 2>&1
check_contains "negative control" "needle" "haystack" >/dev/null 2>&1
if [ "$FAIL" -ne 2 ] || [ "$PASS" -ne 0 ]; then
  echo "FAIL — negative control: helpers did not register 2 failures (got $FAIL/$PASS)" >&2
  exit 1
fi
FAIL=0; PASS=0

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required" >&2; exit 1; }
BLOCK=$(extract_skill_bash "$SKILL_MD" pm-1b2-new-issues) || { echo "FATAL: could not extract pm-1b2-new-issues" >&2; exit 1; }
case "$BLOCK" in
  *"gh issue list"*) ;;
  *) echo "FATAL: the block does not fetch with gh issue list — anchor drifted?" >&2; exit 1 ;;
esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pm-new-issue-test.XXXXXX")
TMP_HOME=$(mktemp -d "${TMPDIR:-/tmp}/pm-new-issue-home.XXXXXX")
trap 'rm -rf "$TMP" "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"
printf '%s\n' "$BLOCK" > "$TMP/block.sh"

STUB_SCRIPTS="$TMP/scripts"
mkdir -p "$STUB_SCRIPTS/lib" "$TMP/bin"
cp "$SCRIPTS_DIR/session-state.sh" "$STUB_SCRIPTS/session-state.sh"
cp "$SCRIPTS_DIR/state-lock.sh" "$STUB_SCRIPTS/state-lock.sh"
cp "$SCRIPTS_DIR/lib/repo-normalizer.sh" "$STUB_SCRIPTS/lib/repo-normalizer.sh"
chmod +x "$STUB_SCRIPTS/session-state.sh" "$STUB_SCRIPTS/state-lock.sh"
# The field-type contract too, so the new baseline field is written under the
# same type guard production runs with.
mkdir -p "$TMP/reference"
cp "$SCRIPTS_DIR/../reference/session-state-schema.json" "$TMP/reference/session-state-schema.json"
export CLAUDE_SESSION_STATE_FILE="$HOME/.claude/session-state.json"
echo '{"schema_version":2,"repos":{}}' > "$CLAUDE_SESSION_STATE_FILE"
export CLAUDE_SESSION_REPO="acme/widgets"
export SESSION_STATE_SH="$STUB_SCRIPTS/session-state.sh"

# gh stub: `gh issue list` prints $BACKLOG_FILE (exit $GH_RC); every call is logged.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "issue list")
    if [ "${GH_RC:-0}" -ne 0 ]; then echo "HTTP 502" >&2; exit "$GH_RC"; fi
    cat "$BACKLOG_FILE"
    ;;
  *) echo "gh-stub: unexpected: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log" BACKLOG_FILE="$TMP/backlog.json"

iso_ago() { # iso_ago MINUTES — UTC time MINUTES ago, GitHub's shape
  date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ
}
# issue N TITLE CREATED ASSIGNEES_JSON LABELS_CSV
issue() {
  jq -nc --argjson n "$1" --arg t "$2" --arg c "$3" --argjson a "$4" --arg l "$5" \
    '{number: $n, title: $t, createdAt: $c, updatedAt: $c, assignees: $a,
      labels: ($l | split(",") | map(select(length > 0) | {name: .}))}'
}
backlog() { printf '%s\n' "$@" | jq -s . > "$BACKLOG_FILE"; }

run_block() {
  : > "$GH_LOG"
  OUT=$(cd "$TMP" && bash -c '. ./block.sh; printf "JSON=%s\n" "$NEW_ISSUES"' 2>&1)
  NEW=$(printf '%s\n' "$OUT" | sed -n 's/^JSON=//p' | jq -r 'map(.number) | join(",")')
}
baseline() { "$SESSION_STATE_SH" --get '.repos["acme/widgets"].pm_backlog_scan_at' 2>/dev/null; }

# --- first scan: no baseline, so the last 24 h ---------------------------------
OLD=$(issue 10 "An old idea" "$(iso_ago 3000)" '[]' "enhancement")
FILED=$(issue 11 "Desk: an idea filed an hour ago" "$(iso_ago 60)" '[]' "enhancement,skill")
MINE=$(issue 12 "Assigned already" "$(iso_ago 50)" '[{"login":"someone"}]' "")
HELD=$(issue 13 "Parked" "$(iso_ago 40)" '[]' "On-Hold")
DUP=$(issue 14 "Same as #11" "$(iso_ago 30)" '[]' "Duplicate,bug")
backlog "$OLD" "$FILED" "$MINE" "$HELD" "$DUP"
run_block
check_eq "first scan: only the unassigned, unexcluded issue from the last 24 h is new" "11" "$NEW"
check_contains "first scan: says where the window came from" "the last 24 h (no earlier scan recorded)" "$OUT"
check_contains "first scan: names the new issue" "#11 Desk: an idea filed an hour ago" "$OUT"
check_contains "first scan: one fresh gh issue list, for the repo whose baseline it keeps" \
  "issue list --repo acme/widgets --state open --json number,title,labels,assignees,createdAt --limit 500" "$(cat "$GH_LOG")"
B1=$(baseline)
case "$B1" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) pass "first scan: the baseline is written ($B1)" ;;
  *) fail "first scan: no baseline written (got '$B1')" ;;
esac

# --- next scan: a fresh fetch, judged against the baseline ----------------------
# Backdate the baseline so an issue "filed after it" is unambiguous.
"$SESSION_STATE_SH" --set ".repos[\"acme/widgets\"].pm_backlog_scan_at=\"$(iso_ago 20)\"" >/dev/null
NEWER=$(issue 15 "Desk: filed after the last scan" "$(iso_ago 10)" '[]' "enhancement")
backlog "$OLD" "$FILED" "$MINE" "$HELD" "$DUP" "$NEWER"
run_block
check_eq "next scan: only the issue filed after the baseline is new" "15" "$NEW"
check_contains "next scan: judged against the last scan" "(the last scan)" "$OUT"
check_eq "next scan: gh issue list ran again" "1" "$(grep -c '^issue list' "$GH_LOG")"
B2=$(baseline)
if [ "$B2" \> "$(iso_ago 20)" ]; then pass "next scan: the baseline moved forward"; else fail "next scan: the baseline did not move (got '$B2')"; fi

if [ "$B2" \< "$(iso_ago 4)" ] && [ "$B2" \> "$(iso_ago 7)" ]; then
  pass "next scan: the baseline is the scan's start less five minutes ($B2)"
else
  fail "next scan: the baseline is not about five minutes back (got '$B2')"
fi

# --- a third scan with nothing new -----------------------------------------------
run_block
check_eq "a scan with nothing new: NEW_ISSUES empty" "" "$NEW"
check_contains "a scan with nothing new: says none" ": none" "$OUT"

# --- the overlap: an issue filed in the last five minutes is named again ---------
RECENT=$(issue 16 "Filed a minute ago" "$(iso_ago 1)" '[]' "")
backlog "$OLD" "$FILED" "$MINE" "$HELD" "$DUP" "$NEWER" "$RECENT"
run_block
check_eq "overlap: named on this scan" "16" "$NEW"
run_block
check_eq "overlap: named on the next scan too (never skipped)" "16" "$NEW"
backlog "$OLD" "$FILED" "$MINE" "$HELD" "$DUP" "$NEWER"

# --- gh fails: degraded, the baseline stays ---------------------------------------
"$SESSION_STATE_SH" --set ".repos[\"acme/widgets\"].pm_backlog_scan_at=\"$(iso_ago 20)\"" >/dev/null
B_BEFORE=$(baseline)
GH_RC=1 run_block
check_eq "gh fails: NEW_ISSUES empty" "" "$NEW"
check_contains "gh fails: one DEGRADED line" "DEGRADED: the new-issue scan failed" "$OUT"
check_eq "gh fails: the baseline did not move" "$B_BEFORE" "$(baseline)"

# --- a full page of new issues: the list may be cut short, so the baseline stays --
"$SESSION_STATE_SH" --set ".repos[\"acme/widgets\"].pm_backlog_scan_at=\"$(iso_ago 20)\"" >/dev/null
B_BEFORE=$(baseline)
jq -n --arg c "$(iso_ago 5)" '[range(500) | {number: (. + 1000), title: "flood", createdAt: $c, updatedAt: $c, assignees: [], labels: []}]' > "$BACKLOG_FILE"
run_block
check_eq "500 new issues: all are named" "500" "$(printf '%s\n' "$OUT" | sed -n 's/^JSON=//p' | jq 'length')"
check_contains "500 new issues: says the list may be cut short" "the list hit its 500-issue cap" "$OUT"
check_eq "500 new issues: the baseline did not move" "$B_BEFORE" "$(baseline)"
# 500 rows of which the oldest predates the baseline: complete, so it moves.
jq -n --arg c "$(iso_ago 5)" --arg o "$(iso_ago 3000)" \
  '[range(499) | {number: (. + 1000), title: "flood", createdAt: $c, assignees: [], labels: []}]
   + [{number: 1, title: "old", createdAt: $o, assignees: [], labels: []}]' > "$BACKLOG_FILE"
run_block
if [ "$(baseline)" \> "$B_BEFORE" ]; then pass "500 rows reaching past the baseline: the baseline moves"; else fail "500 rows reaching past the baseline: the baseline did not move"; fi

# --- no session-state.sh: 24 h window, no baseline kept ---------------------------
backlog "$OLD" "$FILED" "$MINE" "$HELD" "$DUP" "$NEWER"
: > "$GH_LOG"
OUT=$(cd "$TMP" && SESSION_STATE_SH="" HOME="$TMP/nowhere" bash -c '. ./block.sh; printf "JSON=%s\n" "$NEW_ISSUES"' 2>&1)
NEW=$(printf '%s\n' "$OUT" | sed -n 's/^JSON=//p' | jq -r 'map(.number) | join(",")')
check_eq "no session-state.sh: the last 24 h still finds the new issues" "11,15" "$NEW"
check_contains "no session-state.sh: says no baseline is kept" "no baseline is kept" "$OUT"
check_eq "no session-state.sh: the fetch falls back to the current directory's repo" \
  "issue list --state open --json number,title,labels,assignees,createdAt --limit 500" "$(cat "$GH_LOG")"

echo
echo "pm-backlog-new-issue.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
