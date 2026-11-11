#!/usr/bin/env bash
# Disposable PostgreSQL tests for confirmed scan imports and quiz sources.
set -euo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
hq_t_require_db "review-tools.test.sh"
command -v jq >/dev/null || { echo 'SKIP: jq unavailable'; exit 0; }

HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect
export HUMAN_QUEUE_SCHEMA="hq_test_$$_${RANDOM}_review_tools"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/hq-review-tools.XXXXXX")
sql() { hq_psql -At -c "SET search_path TO $HUMAN_QUEUE_SCHEMA; $1"; }
cleanup() {
  hq_psql -At -c "DROP SCHEMA IF EXISTS $HUMAN_QUEUE_SCHEMA CASCADE;" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  hq__cleanup_tmp
}
trap cleanup EXIT
hq() { "$HQ_T_CLI" "$@"; }

hq migrate >/dev/null
for i in 1 2 3 4; do
  hq add --kind decision --repo owner/fixture --key "issue-$i" --session worker \
    --question "Decision $i?" --option Yes --option No >/dev/null
  hq add --kind review --repo owner/fixture --key "pr-$i" --question "Review $i" >/dev/null
done
sql "INSERT INTO sets (set_id, position, item_id)
     SELECT 31, n, 'D-' || n FROM generate_series(1, 4) n;" >/dev/null
scan="$TESTS_DIR/fixtures/export/marked-scan.pdf"
proposal="$tmp/proposal.json"
sha=$(shasum -a 256 < "$scan")
note=$'  Recheck the retry window.\nKeep the current limit.  \n'
jq -n --arg hash "${sha%% *}" --arg note "$note" '{
  scan_sha:$hash, set_id:"31",
  entries:[range(1;5) as $n | {
    id:"D-\($n)", page:1, position:$n,
    option:(if $n == 4 then null elif $n == 2 then 2 else 1 end),
    printed_option:(if $n == 4 then null elif $n == 2 then "No" else "Yes" end),
    unreadable:($n == 4), comment:(if $n == 2 then $note else null end)
  }]
}' > "$proposal"

# Check that a changed option and a mark copied under another section are refused.
jq '.entries[0].printed_option = "Old choice" | .entries[2].position = 2' "$proposal" > "$tmp/invalid.json"
invalid=$(hq import preview "$scan" "$tmp/invalid.json")
check "bad option and section are refused" "$(jq '[.entries[]|select(.reason)]|length' <<< "$invalid")" 3
preview=$(hq import preview "$scan" "$proposal")
token=$(jq -er .confirmation <<< "$preview")
check "three choices resolve from the scan" "$(jq -c '[.entries[].answer | strings]' <<< "$preview")" '["Yes","No","Yes"]'
check "unreadable item lists its id and page" "$(jq -c '.entries[] | select(.reason) | [.id,.page]' <<< "$preview")" '["D-4",1]'
check "preview leaves every Decision open" "$(sql "SELECT count(*) FROM items WHERE kind='decision' AND status='open'")" 4
check "preview writes no answers or comments" "$(sql "SELECT count(*) FROM events WHERE kind IN ('answered','commented')")" 0

cp "$scan" "$tmp/changed.pdf"
printf '\n%% extra scan content\n' >> "$tmp/changed.pdf"
rc=0; hq import apply "$tmp/changed.pdf" "$proposal" "$token" >/dev/null 2>&1 || rc=$?
check "changed scan is refused" "$rc" 4
hq bump D-3 >/dev/null
rc=0; hq import apply "$scan" "$proposal" "$token" >/dev/null 2>&1 || rc=$?
check "changed item invalidates confirmation" "$rc" 4
check "stale batch writes nothing" "$(sql 'SELECT count(*) FROM scan_import_receipts')" 0

token=$(hq import preview "$scan" "$proposal" | jq -er .confirmation)
# Exactly one concurrent confirmation can record answers and comments.
(hq import apply "$scan" "$proposal" "$token" > "$tmp/first" 2>"$tmp/first.err") &
first=$!
(hq import apply "$scan" "$proposal" "$token" > "$tmp/second" 2>"$tmp/second.err") &
second=$!
applied=0
if wait "$first"; then applied=$((applied + 1)); fi
if wait "$second"; then applied=$((applied + 1)); fi
check "concurrent confirmation applies only once" "$applied" 1
check "answer result contains the three wake pointers" "$(cat "$tmp/first" "$tmp/second" | jq -c '[.answers[].session]')" \
  '["worker","worker","worker"]'
check "import stores three answers and leaves illegible item open" \
  "$(sql "SELECT string_agg(status, ',' ORDER BY id) FROM items WHERE kind='decision'")" 'answered,answered,answered,open'
check "comment is stored verbatim" \
  "$(sql "SELECT to_json(note) FROM events WHERE kind='commented'")" "$(jq -cn --arg note "$note" '$note')"
check "one receipt per changed item" "$(sql 'SELECT count(*) FROM scan_import_receipts')" 3

for i in 1 2 3 4; do hq review "R-$i" >/dev/null; done
sql "UPDATE items SET summary_l2 = CASE id
     WHEN 'R-1' THEN 'Retries run every five minutes.'
     WHEN 'R-2' THEN 'The cache key is the commit SHA.'
     WHEN 'R-3' THEN 'Pandoc falls through to Chrome.'
     END WHERE kind = 'review';" >/dev/null
sources=$(hq quiz sources R-4 R-3 R-2 R-3 R-1)
check "three cached summaries in batch order with their own source" \
  "$(jq -c '[.[]|[.id,.key,.summary_l2]]' <<< "$sources")" \
  '[["R-3","pr-3","Pandoc falls through to Chrome."],["R-2","pr-2","The cache key is the commit SHA."],["R-1","pr-1","Retries run every five minutes."]]'
check "a cache question miss points to the cache Review's PR" \
  "$(jq -r '.[] | select(.id == "R-2") | .link.url' <<< "$sources")" 'https://github.com/owner/fixture/pull/2'
check "looking up quiz sources writes nothing" "$(sql "SELECT count(*) FROM state WHERE key LIKE 'quiz_count:%'")" 0
check "completed quiz advances today's count" "$(hq quiz complete)" 1
check "another completed quiz advances the same count" "$(hq quiz complete)" 2
check "quiz stores only one daily counter" "$(sql "SELECT count(*) FROM state WHERE key LIKE 'quiz_count:%'")" 1

hq_t_finish "review-tools.test.sh"
