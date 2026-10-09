#!/usr/bin/env bash
# Unit test for the canonical `pr-state-unmarked-replies.jq` program invoked by
# catalog: tests — Tests the advisory `unmarked_replies` count `pr-state.sh` adds to its bundle
# `pr-state.sh` (issue #1842).
#
# What it pins:
#   1. Two User replies to a review-bot root, one marked and one not -> 1;
#      both marked -> 0.
#   2. A reply to a human root is excluded; a bot-authored reply is excluded.
#   3. A quoted, inline-code, or fenced-block marker does not count as a marker.
#   4. An empty or null inventory -> 0.
#   5. The filter's review-bot list equals pr-state.sh's `$botlist`.
#   6. pr-state.sh wires the filter into a top-level `unmarked_replies` field.
#
# Strategy (same as pr-state-check-runs.test.sh): execute the canonical jq file
# used by pr-state.sh, so the test cannot drift from production behavior.
#
# Requires: jq, bash 3.2+ (macOS-compatible). Offline: no gh, git, or network.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../pr-state.sh"
FILTER="$TEST_DIR/../lib/pr-state-unmarked-replies.jq"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

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

FILTER_OK="yes"
[[ -r "$FILTER" ]] || FILTER_OK="not readable"
if [[ "$FILTER_OK" == "yes" ]] && ! jq -e -f "$FILTER" <<<'[]' >/dev/null 2>&1; then
  FILTER_OK="invalid jq"
fi
check_eq "canonical unmarked-replies filter is readable jq" "yes" "$FILTER_OK"
if [[ "$FILTER_OK" != "yes" ]]; then
  echo "== summary: $PASS passed, $FAIL failed ==" >&2
  exit 1
fi

# count <fixture-file> — run the production filter, print its integer (or ERR).
count() { jq -f "$FILTER" "$1" 2>/dev/null || echo ERR; }

MARK='<!-- review-verdict: fixed defect=real agent=claude-code -->'

# Build a fixture with jq so every body's newlines are real JSON escapes.
# Args: output file, then one body per agent reply to the bot root (id 1).
mk_fixture() {
  local out="$1"; shift
  local bodies
  bodies=$(printf '%s\0' "$@" | jq -Rs 'split("\u0000") | .[:-1]')
  jq -n --argjson bodies "$bodies" '
    [ {id: 1, in_reply_to_id: null, user: {login: "coderabbitai[bot]", type: "Bot", id: 9},
       body: "Potential issue: off-by-one."} ]
    + [ range(0; $bodies | length) as $i
        | {id: (100 + $i), in_reply_to_id: 1, user: {login: "agent-owner", type: "User", id: 7},
           body: $bodies[$i]} ]' > "$out"
}

# 1. Mixed: one marked, one not -> 1.
mk_fixture "$TMP/mixed.json" "Fixed in \`abc1234\`: guarded the index.
$MARK" "Fixed in \`abc1234\`: renamed the variable."
check_eq "one marked + one unmarked agent reply -> 1" "1" "$(count "$TMP/mixed.json")"

# 1b. Both marked -> 0.
mk_fixture "$TMP/both.json" "Fixed in \`abc1234\`: guarded the index.
$MARK" "Declined: style only.
<!-- review-verdict: declined defect=not agent=claude-code -->"
check_eq "both agent replies marked -> 0" "0" "$(count "$TMP/both.json")"

# 1c. A deferred marker counts as marked too.
mk_fixture "$TMP/deferred.json" "Deferred to #42.
<!-- review-verdict: deferred defect=real agent=claude-code -->"
check_eq "deferred marker counts as marked -> 0" "0" "$(count "$TMP/deferred.json")"

# 2. Reply to a human root is excluded; a bot reply on a bot root is excluded.
jq -n '[
  {id: 1, in_reply_to_id: null, user: {login: "a-human", type: "User", id: 5}, body: "Nit?"},
  {id: 2, in_reply_to_id: 1, user: {login: "agent-owner", type: "User", id: 7}, body: "Fixed in abc1234."},
  {id: 3, in_reply_to_id: null, user: {login: "cursor[bot]", type: "Bot", id: 8}, body: "Bug: null deref."},
  {id: 4, in_reply_to_id: 3, user: {login: "coderabbitai[bot]", type: "Bot", id: 9}, body: "Agreed."},
  {id: 5, in_reply_to_id: 3, user: {login: "some-app[bot]", type: "User", id: 6}, body: "Ack."}
]' > "$TMP/excluded.json"
check_eq "human-root reply and bot-authored replies excluded -> 0" "0" "$(count "$TMP/excluded.json")"

# 2b. Every review-bot root is covered (not only CodeRabbit).
jq -n '[
  ({id: 1, login: "cursor[bot]"}, {id: 2, login: "codeant-ai[bot]"}, {id: 3, login: "greptile-apps[bot]"},
   {id: 4, login: "graphite-app[bot]"}, {id: 5, login: "coderabbitai[bot]"})
  | {id, in_reply_to_id: null, user: {login, type: "Bot", id: 1}, body: "finding"}
] + [ range(1; 6) as $r
      | {id: (10 + $r), in_reply_to_id: $r, user: {login: "agent-owner", type: "User", id: 7}, body: "Fixed in abc1234."} ]' \
  > "$TMP/allbots.json"
check_eq "unmarked replies to each of the five review bots -> 5" "5" "$(count "$TMP/allbots.json")"

# 3. Quoted, inline-code and fenced markers do not count.
mk_fixture "$TMP/fakes.json" "> $MARK
Fixed in abc1234." "Fixed; see \`$MARK\`." "Example:
\`\`\`text
$MARK
\`\`\`"
check_eq "quoted / inline-code / fenced markers stay unmarked -> 3" "3" "$(count "$TMP/fakes.json")"

# 3b. A marker after a closed fence counts (the helper closes an open fence first).
mk_fixture "$TMP/after-fence.json" "Fixed:
\`\`\`bash
echo ok
\`\`\`
$MARK"
check_eq "marker after a closed fence counts as marked -> 0" "0" "$(count "$TMP/after-fence.json")"

# 3c. A CRLF body still matches its marker line.
CRLF_BODY=$(printf 'Fixed in abc1234.\r\n%s\r\n' "$MARK")
mk_fixture "$TMP/crlf.json" "$CRLF_BODY"
check_eq "CRLF body with marker counts as marked -> 0" "0" "$(count "$TMP/crlf.json")"

# 4. Empty / null inventory -> 0.
echo '[]' > "$TMP/empty.json"
check_eq "empty inventory -> 0" "0" "$(count "$TMP/empty.json")"
echo 'null' > "$TMP/null.json"
check_eq "null inventory -> 0" "0" "$(count "$TMP/null.json")"

# 5. Parity: the filter's bot list equals pr-state.sh's $botlist.
BOTLIST=$(grep -oE '\[("[^"]*"[[:space:]]*,?[[:space:]]*)+\][[:space:]]+as[[:space:]]+\$botlist' "$SCRIPT" \
  | sed -E 's/[[:space:]]+as[[:space:]]+\$botlist$//' || true)
FILTER_BOTS=$(jq -nc -L "$(dirname "$FILTER")" "$(sed -n '/^def review_bot_logins:/,/;$/p' "$FILTER") review_bot_logins" 2>/dev/null || true)
if [[ -z "$BOTLIST" || -z "$FILTER_BOTS" ]]; then
  check_eq "parity — parsed both bot lists" "parsed" "botlist='$BOTLIST' filter='$FILTER_BOTS'"
else
  PARITY=$(jq -nr --argjson a "$BOTLIST" --argjson b "$FILTER_BOTS" '($a | sort) == ($b | sort)')
  check_eq "parity — filter review_bot_logins equals pr-state.sh \$botlist" "true" "$PARITY"
fi

# 6. pr-state.sh wires the filter into a top-level unmarked_replies integer.
WIRED="no"
if grep -q 'pr-state-unmarked-replies.jq' "$SCRIPT" \
   && grep -qE 'unmarked_replies:[[:space:]]*\$unmarked_replies' "$SCRIPT"; then
  WIRED="yes"
fi
check_eq "pr-state.sh emits top-level unmarked_replies from the filter" "yes" "$WIRED"

echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]]
