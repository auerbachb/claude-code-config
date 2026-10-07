#!/usr/bin/env bash
# desk/tests/longform.test.sh — live tests for the desk's long-form,
# multipart, and discuss increment (issue #1780), against the database in
# HUMAN_QUEUE_DATABASE_URL, through the skill's own bash blocks.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. Every run creates a throwaway schema named
# hq_test_<pid>_<random>_longform, points the CLI at it with
# HUMAN_QUEUE_SCHEMA, and drops it on exit. No control session is registered
# and no wake-up is sent. The suite asserts that the number of tables in
# `public` is unchanged.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset or jq is
# missing. With the URL set, an unreachable database FAILS the suite.
#
# Asserts (issue #1780):
#   split  the desk-split block over the real `list --json` keeps the menu
#          question for a menu, and groups the long-form ones: a parked
#          single question first, a two-part ask (one thread, one issue) as
#          one multipart item, a cost-in-hours question with options alone
#   5.1    the desk-longform-render block renders the single long-form item
#          alone as a quoted text card; the desk-longform-answer block
#          stores the operator's reply (quotes, $(...), backticks,
#          backslashes, `2: B` lines, tabs, Unicode) byte for byte through
#          desk-cli.sh and `answer --stdin --json`, returns changed and the
#          asking session, records one `answered` event, and runs nothing
#          from the reply; the same reply again changes nothing; a lone
#          letter on an item with options stores that option's text; an
#          answered item renders as a skip notice
#   5.2    set-open numbers the multipart item's parts 1 and 2, so `discuss
#          2` resolves to part 2 through the set; the desk-discuss-card
#          block loads part 2's question, context, and link (what a
#          follow-up is answered from) and writes nothing; part 2 is then
#          presented again as `part 2 of 2` and answered (whatever shells
#          exist), and part 1 is answered once under each block shell
# The answer block runs under bash, /bin/bash 3.2 (macOS), and zsh when
# present.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

hq_t_require_db "longform.test.sh"
JQ=$(command -v jq 2>/dev/null || true)
if [ -z "$JQ" ]; then
  echo "SKIP: longform.test.sh — jq is not installed (the desk skill needs it)"
  exit 0
fi

HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

S="hq_test_$$_$(printf '%05d' "$RANDOM")_longform"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-longform-test.XXXXXX")
SKILL_DIR="$HQ_T_DESK_DIR/skill"

admin_sql() { hq_psql -At -c "$1"; }
cleanup() {
  admin_sql "DROP SCHEMA IF EXISTS $S CASCADE;" >/dev/null 2>&1 \
    || echo "WARN: could not drop scratch schema $S — drop it by hand" >&2
  rm -rf "$TMP"
  hq__cleanup_tmp
}
trap cleanup EXIT

sql_in() { hq_psql -At -c "SET search_path TO $S; $1" 2>&1; }
events_of() { sql_in "SELECT string_agg(kind, ',' ORDER BY id) FROM events WHERE item_id = '$1'"; }

BLOCK_SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  BLOCK_SHELLS="$BLOCK_SHELLS /bin/bash"
fi
if command -v zsh >/dev/null 2>&1; then BLOCK_SHELLS="$BLOCK_SHELLS zsh"; fi

# hq ARGS... — the CLI in the scratch schema; sets OUT, ERR, RC.
hq() {
  RC=0
  HUMAN_QUEUE_SCHEMA="$S" bash "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

hq migrate
check "migrate the scratch schema" "$RC" "0"
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$ERR"
  hq_t_finish "longform.test.sh"
  exit 1
fi
echo "scratch schema: $S (block shells: $BLOCK_SHELLS)"

REPO=auerbachb/claude-code-config
# add VAR ARGS... — adds a Decision and stores its id in VAR.
add() {
  local var="$1"
  shift
  hq add --kind decision --repo "$REPO" "$@"
  check "add $var" "$RC" "0"
  printf -v "$var" '%s' "$OUT"
}
add SIMPLE --key issue-501 --session sess-w1 --question "Ship now or wait for review?" \
  --option "Ship now" --option "Wait for review" --default "Wait for review" --cost "~5 min"
add LF --key issue-502 --session sess-w2 --question "What should the release note say about the long-form view?" \
  --context "The release adds long-form questions to the desk." --impact high --parked
add MP1 --key issue-503 --session sess-w3 --question "Which region should the staging database live in?" \
  --context "Latency to the CI runners matters most."
add MP2 --key issue-503 --session sess-w3 --question "Who signs off on the staging budget?" \
  --context "Finance asked for one named owner, not a team."
add HOURS --key pr-504 --session sess-w4 --question "Rewrite the importer or patch it?" \
  --option "Rewrite" --option "Patch" --default "Patch" --cost "~2h"

# The skill's blocks, run with the prelude's DESK and HQ: desk-cli.sh, which
# finds the URL in the environment and runs the CLI in the scratch schema.
block() {
  local name="$2" out rc=0
  out=$(hq_t_skill_block "$SKILL_DIR/$1" "$name" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "anchor $name extracts (rc=$rc: $out)"
    return 1
  fi
  printf '%s\n' "$out" > "$TMP/block-$name.sh"
}
literal() { FROM="$2" TO="$3" perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$1"; }
run_block() {
  (cd "$TMP" && env DESK="$HQ_T_DESK_DIR" HQ="$HQ_BIN_DIR/desk-cli.sh" HUMAN_QUEUE_SCHEMA="$S" "$1" "$2") 2>&1
}
# answer_script ID REPLY_FILE OUT — the desk-longform-answer block for ID with
# the reply file in place of the placeholder line.
answer_script() {
  literal "$TMP/block-desk-longform-answer.sh" "D-48" "$1" \
    | awk -v ph="<the operator's message, exactly as typed>" -v rf="$2" '
        $0 == ph { while ((getline l < rf) > 0) print l; next }
        { print }' > "$3"
}

block decisions.md desk-split
block longform.md desk-longform-render
block longform.md desk-longform-answer
block discuss.md desk-discuss-card

# --- split ---------------------------------------------------------------------
literal "$TMP/block-desk-split.sh" "<the event's ids, or empty for all>" "" > "$TMP/split.sh"
OUT=$(run_block bash "$TMP/split.sh")
check "desk-split over the live list: menu, then long-form groups" "$OUT" \
  "{\"simple\":[\"$SIMPLE\"],\"longform\":[[\"$LF\"],[\"$MP1\",\"$MP2\"],[\"$HOURS\"]]}"

# --- 5.1: a long-form item alone, its reply stored word for word ----------------
literal "$TMP/block-desk-longform-render.sh" "D-48" "$LF" \
  | literal /dev/stdin "--argjson k 2 --argjson m 3" "--argjson k 1 --argjson m 1" > "$TMP/render-lf.sh"
OUT=$(run_block bash "$TMP/render-lf.sh")
check "5.1 the card's header names the item alone" "$(printf '%s\n' "$OUT" | sed -n 1p)" \
  "> **$LF** · long-form · $REPO · issue-502"
check_contains "5.1 the card: the question in bold" "$OUT" \
  "> **What should the release note say about the long-form view?**"
check_contains "5.1 the card: context, impact, parked" "$OUT" \
  "$(printf '> 1. The release adds long-form questions to the desk.\n> Impact: high · Parked: the thread waits for this answer')"
check_contains "5.1 the card: a text prompt, not a menu" "$OUT" \
  "Write your answer. Your next message is stored as $LF's answer, word for word."
check "5.1 the card holds one item" "$(printf '%s\n' "$OUT" | grep -c '^> \*\*D-')" "1"

cat > "$TMP/reply" <<'REPLY'
Lead with what changed for the operator: "long-form questions now come one at a time".
2: B, D-43: C; 3: these look like set replies but are part of this answer
Mention $(whoami), `date`, and $(touch desk-pwned) literally, plus ${HOME}, \n, \\ and a lone \ too.
	Keep this tab-indented line, and the 'single' quotes.
Ünïcödé ✓ 日本語 🙂 — then end here.
REPLY
printf '%s' "$(cat "$TMP/reply")" > "$TMP/expected"

FIRST_SHELL="${BLOCK_SHELLS%% *}"
answer_script "$LF" "$TMP/reply" "$TMP/answer-lf.sh"
rm -f "$TMP/desk-pwned"
OUT=$(run_block "$FIRST_SHELL" "$TMP/answer-lf.sh")
check_contains "5.1 the answer block reports exit 0" "$OUT" "exit=0"
JSON=$(printf '%s\n' "$OUT" | sed -n 1p)
check "5.1 --json: changed" "$(printf '%s' "$JSON" | "$JQ" -r '.changed')" "true"
check "5.1 --json: the asking session, for the wake-up" "$(printf '%s' "$JSON" | "$JQ" -r '.session')" "sess-w2"
check "5.1 --json: the id" "$(printf '%s' "$JSON" | "$JQ" -r '.id')" "$LF"
hq get "$LF" --json
printf '%s' "$OUT" | "$JQ" -j '.answer' > "$TMP/stored"
if cmp -s "$TMP/expected" "$TMP/stored"; then
  ok "5.1 the typed reply is stored verbatim (byte for byte)"
else
  bad "5.1 the stored answer differs from the typed reply"
  diff "$TMP/expected" "$TMP/stored" | sed -n 1,12p
fi
check "5.1 status answered" "$(printf '%s' "$OUT" | "$JQ" -r '.status')" "answered"
check "5.1 one answered event" "$(events_of "$LF")" "asked,answered"
if [ -e "$TMP/desk-pwned" ]; then bad "5.1 the block ran something from the reply"; else ok "5.1 nothing in the reply ran"; fi

OUT=$(run_block "$FIRST_SHELL" "$TMP/answer-lf.sh")
check "5.1 the same reply again: changed false" "$(printf '%s\n' "$OUT" | sed -n 1p | "$JQ" -r '.changed')" "false"
check "5.1 the same reply again: no new event" "$(events_of "$LF")" "asked,answered"

OUT=$(run_block bash "$TMP/render-lf.sh")
check "5.1 an answered item is skipped, not asked again" "$OUT" "$LF is answered now, so it is skipped."

printf 'B\n' > "$TMP/reply-letter"
answer_script "$HOURS" "$TMP/reply-letter" "$TMP/answer-hours.sh"
OUT=$(run_block bash "$TMP/answer-hours.sh")
check "a lone letter on a long-form item with options stores that option" \
  "$(printf '%s\n' "$OUT" | sed -n 1p | "$JQ" -r '.answer')" "Patch"

# --- 5.2: discuss 2 in a multipart item, then part 2 again -----------------------
hq set-open "$MP1" "$MP2" --json
check "5.2 set-open numbers the parts" "$(printf '%s' "$OUT" | "$JQ" -c '[.items[] | [.n, .id]]')" \
  "[[1,\"$MP1\"],[2,\"$MP2\"]]"
SET_ID=$(printf '%s' "$OUT" | "$JQ" -r '.set_id')
check "5.2 discuss 2 resolves to part 2 through the set" \
  "$(sql_in "SELECT item_id FROM sets WHERE set_id = $SET_ID AND position = 2")" "$MP2"

literal "$TMP/block-desk-discuss-card.sh" "D-48" "$MP2" > "$TMP/discuss.sh"
OUT=$(run_block bash "$TMP/discuss.sh")
check_contains "5.2 the card names part 2, open" "$OUT" "> Discussing **$MP2** · open · $REPO · issue-503"
check_contains "5.2 the card holds the question" "$OUT" "> **Who signs off on the staging budget?**"
# The follow-up "did finance want a team or a person?" is answered from this line.
check_contains "5.2 the card holds the context a follow-up is answered from" "$OUT" \
  "> 1. Finance asked for one named owner, not a team."
check_contains "5.2 the card links the issue" "$OUT" \
  "> Link: Issue #503 — https://github.com/$REPO/issues/503"
check "5.2 discussing writes nothing (asked and shown only)" "$(events_of "$MP2")" "asked,shown"

literal "$TMP/block-desk-longform-render.sh" "D-48" "$MP2" \
  | literal /dev/stdin "--argjson m 3" "--argjson m 2" > "$TMP/render-mp2.sh"
OUT=$(run_block bash "$TMP/render-mp2.sh")
check "5.2 part 2 is presented again" "$(printf '%s\n' "$OUT" | sed -n 1p)" \
  "> **$MP2** · part 2 of 2 · $REPO · issue-503"

# Part 2, presented again, is answered whatever shells exist.
answer_script "$MP2" "$TMP/reply" "$TMP/answer-mp2.sh"
OUT=$(run_block "$FIRST_SHELL" "$TMP/answer-mp2.sh")
check_contains "5.2 part 2's answer block reports exit 0" "$OUT" "exit=0"
check "5.2 part 2's answer changed it" "$(printf '%s\n' "$OUT" | sed -n 1p | "$JQ" -r '.changed')" "true"
hq get "$MP2" --json
check "5.2 part 2 is answered" "$(printf '%s' "$OUT" | "$JQ" -r '.status')" "answered"
printf '%s' "$OUT" | "$JQ" -j '.answer' > "$TMP/stored-mp2"
if cmp -s "$TMP/expected" "$TMP/stored-mp2"; then
  ok "5.2 part 2's reply is stored byte for byte"
else
  bad "5.2 part 2's stored answer differs from the typed reply"
fi

# Part 1 under every block shell. Each run adds its own last line, so every
# shell's run writes (changed true) and is compared on its own.
SHELL_N=0
for SH in $BLOCK_SHELLS; do
  SHELL_N=$((SHELL_N + 1))
  { cat "$TMP/reply"; printf 'Answered under %s.\n' "$SH"; } > "$TMP/reply-$SHELL_N"
  printf '%s' "$(cat "$TMP/reply-$SHELL_N")" > "$TMP/expected-$SHELL_N"
  answer_script "$MP1" "$TMP/reply-$SHELL_N" "$TMP/answer-$SHELL_N.sh"
  OUT=$(run_block "$SH" "$TMP/answer-$SHELL_N.sh")
  check_contains "[$SH] the answer block reports exit 0" "$OUT" "exit=0"
  check "[$SH] the answer block changed part 1" "$(printf '%s\n' "$OUT" | sed -n 1p | "$JQ" -r '.changed')" "true"
  hq get "$MP1" --json
  printf '%s' "$OUT" | "$JQ" -j '.answer' > "$TMP/stored-$SHELL_N"
  if cmp -s "$TMP/expected-$SHELL_N" "$TMP/stored-$SHELL_N"; then
    ok "[$SH] the reply is stored byte for byte"
  else
    bad "[$SH] the stored answer differs from the typed reply"
  fi
done

PUBLIC_AFTER=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
check "the public schema is untouched" "$PUBLIC_AFTER" "$PUBLIC_BEFORE"
check "no control session was registered in the scratch schema" \
  "$(sql_in "SELECT count(*) FROM state WHERE key = 'control_session'")" "0"

hq_t_finish "longform.test.sh"
