#!/usr/bin/env bash
# Offline tests for pm-rank-cache.sh and /pm Step 1B.4c (issue #1760).
# catalog: tests — Tests for `pm-rank-cache.sh` and `/pm` 1B.4c: write/read round trip, lowercase file name, the 24-hour boundary, future/malformed/mismatched/missing files, unranked issues, bad input that keeps the old file, no HOME, and the skill's anchored persist block
# Run from anywhere: bash .claude/scripts/tests/pm-rank-cache.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO_ROOT/.claude/scripts/pm-rank-cache.sh"
PM_SKILL="$REPO_ROOT/.claude/skills/pm/SKILL.md"
# shellcheck source=lib/skill-bash.sh
source "$REPO_ROOT/.claude/scripts/tests/lib/skill-bash.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
unset PM_RANK_DIR

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }
check_eq() {
  if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
check_contains() {
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1 (missing '$2' in: $3)"; fi
}

FILE="$HOME/.claude/pm-rank/acme-widgets.json"
read_issue() {  # read_issue ISSUE [ARGS...] — "status reason rank tier"
  local n="$1"
  shift
  "$SCRIPT" read Acme/Widgets "$n" "$@" | jq -r '"\(.status) \(.reason) \(.issues[0].rank) \(.issues[0].tier)"'
}
# age_file SECONDS — rewrite the file's timestamp SECONDS in the past.
age_file() {
  local at
  at=$(jq -n -r --argjson a "$1" '(now | floor) - $a | todate')
  jq -c --arg at "$at" '.generated_at = $at' "$FILE" > "$TMP/aged.json" && mv "$TMP/aged.json" "$FILE"
}

# ---- write, then read -------------------------------------------------------
OUT=$(printf '%s\n' '#42 critical' '38 High' '' '  7  ' '42 Low' | "$SCRIPT" write Acme/Widgets)
check_eq "write prints the lowercased path under ~/.claude/pm-rank" "$FILE" "$OUT"
check_eq "the file: version, repo, ranking in order, a repeat keeps its first place, tiers capitalized" \
  '1|acme/widgets|[{"rank":1,"number":42,"tier":"Critical"},{"rank":2,"number":38,"tier":"High"},{"rank":3,"number":7,"tier":null}]' \
  "$(jq -c -r '"\(.version)|\(.repo)|\(.ranking | tojson)"' "$FILE")"
check_contains "generated_at is ISO 8601 UTC" "Z" "$(jq -r .generated_at "$FILE")"
check_eq "the file is private" "600" "$(stat -c %a "$FILE" 2>/dev/null || stat -f %Lp "$FILE")"
check_eq "read: a ranked issue" "fresh null 1 Critical" "$(read_issue 42)"
check_eq "read: an untiered issue" "fresh null 3 null" "$(read_issue 7)"
check_eq "read: a fresh ranking without the issue — not ranked" "fresh null null null" "$(read_issue 99)"
check_eq "read: ranked count and every issue asked, in order" "3 42,7,99" \
  "$("$SCRIPT" read acme/widgets 42 7 '#99' | jq -r '"\(.ranked) \([.issues[].issue] | join(","))"')"
check_eq "path names the same file" "$FILE" "$("$SCRIPT" path ACME/widgets)"

# ---- the 24-hour boundary ---------------------------------------------------
age_file 86340
check_eq "a minute under 24 hours: fresh" "fresh null 1 Critical" "$(read_issue 42)"
age_file 86400
check_eq "24 hours: unknown (stale), no rank" "unknown stale null null" "$(read_issue 42)"
check_eq "--ttl-seconds widens it" "fresh null 1 Critical" "$(read_issue 42 --ttl-seconds 90000)"
age_file -600
check_eq "a timestamp in the future: unknown" "unknown future null null" "$(read_issue 42)"

# ---- unknown shapes -----------------------------------------------------------
GOOD=$(printf '%s\n' 42 | "$SCRIPT" write acme/widgets >/dev/null && cat "$FILE")
printf 'not json' > "$FILE"
check_eq "malformed JSON: unknown" "unknown malformed null null" "$(read_issue 42)"
printf '%s' "$GOOD" | jq -c '.repo = "acme-widgets/x"' > "$FILE"
check_eq "another repo's file (a name collision): unknown" "unknown repo-mismatch null null" "$(read_issue 42)"
printf '%s' "$GOOD" | jq -c 'del(.generated_at)' > "$FILE"
check_eq "no timestamp: unknown" "unknown no-timestamp null null" "$(read_issue 42)"
printf '%s' "$GOOD" | jq -c '.generated_at = "yesterday"' > "$FILE"
check_eq "an unparseable timestamp: unknown" "unknown no-timestamp null null" "$(read_issue 42)"
rm -f "$FILE"
check_eq "no file: unknown (missing)" "unknown missing null null" "$(read_issue 42)"
RC=0; "$SCRIPT" read acme/widgets 42 >/dev/null || RC=$?
check_eq "an unknown rank still exits 0" "0" "$RC"

# ---- bad input never replaces a good file -------------------------------------
printf '%s\n' 42 38 | "$SCRIPT" write acme/widgets >/dev/null
BEFORE=$(cat "$FILE")
for bad in "forty-two" "42 Urgent" "42 High extra" "0" "-3"; do
  RC=0; printf '%s\n' 7 "$bad" | "$SCRIPT" write acme/widgets >/dev/null 2>&1 || RC=$?
  check_eq "write rejects '$bad' (exit 2)" "2" "$RC"
done
check_eq "... and the existing file is untouched" "$BEFORE" "$(cat "$FILE")"
printf '' | "$SCRIPT" write acme/widgets >/dev/null
check_eq "an empty order is a valid ranking: nothing ranked" "fresh 0 null" \
  "$("$SCRIPT" read acme/widgets 42 | jq -r '"\(.status) \(.ranked) \(.issues[0].rank)"')"
check_eq "no temp file is left behind" "" "$(find "$HOME/.claude/pm-rank" -name '.pm-rank.*')"

# ---- PM_RANK_DIR and no HOME ----------------------------------------------------
check_eq "PM_RANK_DIR moves the file" "$TMP/other/acme-widgets.json" \
  "$(printf '1\n' | PM_RANK_DIR="$TMP/other/" "$SCRIPT" write acme/widgets)"
RC=0; printf '1\n' | env -u HOME -u PM_RANK_DIR "$SCRIPT" write acme/widgets >/dev/null 2>&1 || RC=$?
check_eq "no HOME and no PM_RANK_DIR: write refuses (exit 5)" "5" "$RC"
check_eq "... and read reports unknown (no-home)" "unknown no-home" \
  "$(env -u HOME -u PM_RANK_DIR "$SCRIPT" read acme/widgets 1 | jq -r '"\(.status) \(.reason)"')"
check_eq "nothing was written into /.claude" "no" "$([ -e /.claude/pm-rank/acme-widgets.json ] && echo yes || echo no)"

# ---- usage -----------------------------------------------------------------------
for args in "" "bogus acme/widgets" "read" "read widgets 1" "read acme/widgets x" "write acme/widgets 3" \
  "read acme/widgets 1 --ttl-seconds" "read acme/widgets 1 --ttl-seconds 0" "write acme/widgets --ttl-seconds 5" \
  "read acme/widgets --bogus"; do
  RC=0
  # shellcheck disable=SC2086 # deliberate splitting of each case's arguments
  "$SCRIPT" $args </dev/null >/dev/null 2>&1 || RC=$?
  check_eq "usage: '$args' exits 2" "2" "$RC"
done
check_contains "--help documents the 24-hour rule" "between" "$("$SCRIPT" --help)"

# ---- /pm 1B.4c: the skill's own block --------------------------------------------
BLOCK="$(extract_skill_bash "$PM_SKILL" pm-1b4c-rank-cache)" || { fail "anchor pm-1b4c-rank-cache missing"; BLOCK=""; }
mkdir -p "$TMP/stubbin"
cat > "$TMP/stubbin/session-state.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--repo-key" ] && { echo "acme/gadgets"; exit 0; }
exit 2
EOF
cat > "$TMP/stubbin/gh" <<'EOF'
#!/usr/bin/env bash
echo "acme/fromgh"
EOF
chmod +x "$TMP/stubbin/session-state.sh" "$TMP/stubbin/gh"
run_block() {  # run_block SESSION_STATE_SH PM_RANK_CACHE_SH — FINAL_ORDER is three rows
  PATH="$TMP/stubbin:$PATH" SESSION_STATE_SH="$1" PM_RANK_CACHE_SH="$2" bash -c 'FINAL_ORDER=("12 Critical" "4 High" "9 Low")
'"$BLOCK" 2>&1
}
OUT=$(run_block "$TMP/stubbin/session-state.sh" "$SCRIPT")
check_eq "1B.4c: a successful write prints nothing" "" "$OUT"
check_eq "1B.4c: the order lands under the session's repo key" "1 2 Low" \
  "$("$SCRIPT" read acme/gadgets 12 4 9 | jq -r '"\(.issues[0].rank) \(.issues[1].rank) \(.issues[2].tier)"')"
OUT=$(run_block "" "$SCRIPT")
check_eq "1B.4c: without session-state.sh, gh names the repo" "fresh 2" \
  "$(printf '%s' "$OUT"; "$SCRIPT" read acme/fromgh 4 | jq -r '"\(.status) \(.issues[0].rank)"')"
OUT=$(run_block "$TMP/stubbin/session-state.sh" "$TMP/stubbin/no-such-script")
check_contains "1B.4c: a failed write is one DEGRADED line, never a stop" "DEGRADED: the ranking was not cached" "$OUT"
OUT=$(run_block "$TMP/stubbin/session-state.sh" "")
check_eq "1B.4c: no helper resolved (Step 0's DEGRADED case) — the block does nothing" "" "$OUT"
SKILL_TEXT=$(cat "$PM_SKILL")
line_of() { grep -n -F -- "$1" "$PM_SKILL" | head -1 | cut -d: -f1; }
b4b=$(line_of '### 1B.4b: Judgment check'); b4c=$(line_of '### 1B.4c: Persist the ranking'); b5=$(line_of '### 1B.5: Present recommendations')
if [[ -n "$b4b" && -n "$b4c" && -n "$b5" && "$b4b" -lt "$b4c" && "$b4c" -lt "$b5" ]]; then
  pass "1B.4c sits between the judgment check and the presentation"
else
  fail "1B.4c is not between 1B.4b ($b4b) and 1B.5 ($b5): line $b4c"
fi
check_contains "Step 0 resolves pm-rank-cache.sh" 'PM_RANK_CACHE_SH=$(resolve_script pm-rank-cache.sh || true)' "$SKILL_TEXT"
check_contains "Step 0 resolves issue-deps.sh" 'ISSUE_DEPS_SH=$(resolve_script issue-deps.sh || true)' "$SKILL_TEXT"
check_contains "re-prioritize persists the new order" "then persist the new order (1B.4c)" "$SKILL_TEXT"
check_contains "every 3.4 re-scan persists it" "Then persist the new order (1B.4c), so the desk's derived impact reads this re-scan's ranks." "$SKILL_TEXT"
check_contains "1B.3 names the canonical parser" "**\`issue-deps.sh\` is the canonical reading of these markers**" "$SKILL_TEXT"

echo
echo "pm-rank-cache.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
