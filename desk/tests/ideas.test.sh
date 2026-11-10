#!/usr/bin/env bash
# desk/tests/ideas.test.sh — live tests for the desk's filing record (issue
# #1766): `filed OWNER/NAME N` and how `sync-reviews` turns a pending filing
# into one `filed from the desk` event on the issue's Review (AC 4.4),
# against the database in HUMAN_QUEUE_DATABASE_URL. GitHub is the stub
# tests/lib/gh-stub.sh, serving search results this suite writes.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. The run creates one throwaway schema named
# hq_test_<pid>_<random>_ideas, points the CLI at it with HUMAN_QUEUE_SCHEMA,
# drops it on exit, and asserts the number of tables in `public` is unchanged.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset. With
# the URL set, an unreachable database FAILS the suite.
#
# Asserts:
#   pending   `filed` before the Review exists stores one pending filing
#             (state key filed:<owner/name>:issue-<N>, lowercased) and prints
#             `pending`; again, still one; `state get` reads it
#   sync      the next sync adds the Review (its `asked` event) and turns the
#             pending filing into one `commented` event `filed from the desk`,
#             whatever the repository's case; the key is gone; the tally
#             says so and --json carries desk_filings_noted
#   noted     `filed` after the Review exists records the event at once
#             (`noted R-n`); again, no second event; --json shape
#   race      a pending key re-inserted after the Review was noted (what an
#             overlapping `filed` leaves) is consumed by sync or `filed`
#             without a second event, and the tally counts it as 0
#   waiting   a pending filing whose issue has not synced survives a sync
#   reserved  `state set filed:...` is refused
# On macOS, a share of the calls run under /bin/bash 3.2.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

hq_t_require_db "ideas.test.sh"

HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

S="hq_test_$$_$(printf '%05d' "$RANDOM")_ideas"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-ideas-test.XXXXXX")
STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR"
export HUMAN_QUEUE_GH="$TESTS_DIR/lib/gh-stub.sh" HQ_GH_STUB_DIR="$STUB_DIR"

admin_sql() { hq_psql -At -c "$1"; }
cleanup() {
  admin_sql "DROP SCHEMA IF EXISTS $S CASCADE;" >/dev/null 2>&1 \
    || echo "WARN: could not drop scratch schema $S — drop it by hand" >&2
  rm -rf "$TMP"
  hq__cleanup_tmp
}
trap cleanup EXIT

sql() { hq_psql -At -c "SET search_path TO $S; $1" 2>&1; }

OLD_BASH=bash
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  OLD_BASH=/bin/bash
fi

# hq SHELL ARGS... — runs the CLI in the scratch schema; sets OUT, ERR, RC.
hq() {
  local sh="$1"
  shift
  RC=0
  HUMAN_QUEUE_SCHEMA="$S" "$sh" "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

events_of() { sql "SELECT string_agg(kind || coalesce(':' || note, ''), ',' ORDER BY id) FROM events WHERE item_id = '$1'"; }
id_of() { sql "SELECT id FROM items WHERE kind = 'review' AND lower(repo) = lower('$1') AND key = '$2'"; }
pending() { sql "SELECT coalesce(string_agg(key, ',' ORDER BY key), '<none>') FROM state WHERE key LIKE 'filed:%'"; }

FOOTER='_Captured via /issue-maker._'
issue_row() {
  printf '{"repository":{"name":"%s","nameWithOwner":"%s"},"number":%s,"title":"%s","url":"https://github.com/%s/issues/%s","createdAt":"%s","body":"## Background\\n\\nAn idea.\\n\\n%s"}' \
    "${1#*/}" "$1" "$2" "$3" "$1" "$2" "$4" "$FOOTER"
}
set_search() {
  local f="$STUB_DIR/$1" first=1
  shift
  {
    printf '['
    for r in "$@"; do
      if [ "$first" -eq 0 ]; then printf ','; fi
      first=0
      printf '%s' "$r"
    done
    printf ']\n'
  } >"$f"
}

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

hq bash migrate
check "migrate $S" "$RC" "0"
if [ "$RC" -ne 0 ]; then
  printf '%s\n' "$ERR"
  hq_t_finish "ideas.test.sh"
  exit 1
fi
echo "scratch schema: $S (old shell: $OLD_BASH)"

# --- pending: filed before the Review exists ------------------------------------
hq "$OLD_BASH" filed Acme/Widgets 501
check "pending: exit 0" "$RC" "0"
check "pending: prints pending" "$OUT" "pending"
check "pending: silent on stderr" "$ERR" ""
check "pending: one key, lowercased" "$(pending)" "filed:acme/widgets:issue-501"
hq bash filed acme/widgets 501
check "pending again: still pending" "$RC|$OUT" "0|pending"
check "pending again: still one key" "$(pending)" "filed:acme/widgets:issue-501"
hq bash state get filed:acme/widgets:issue-501
case "$OUT" in
  [0-9][0-9][0-9][0-9]-*Z) ok "state get reads the pending filing ($OUT)" ;;
  *) bad "state get did not read the pending filing (rc=$RC, '$OUT')" ;;
esac
hq bash state set filed:acme/widgets:issue-501 x
check "state set filed:... is refused" "$RC" "4"
check_contains "state set filed:...: says who writes it" "$ERR" "only filed writes them"

# A filing whose issue never shows up in the search.
hq bash filed acme/widgets 999
check "a second pending filing" "$(pending)" "filed:acme/widgets:issue-501,filed:acme/widgets:issue-999"

# --- sync: the Review arrives and takes the event -------------------------------
set_search search-prs.json
set_search search-issues.json "$(issue_row ACME/widgets 501 "Desk: export widgets" 2026-10-07T15:00:00Z)"
hq "$OLD_BASH" sync-reviews --since 2026-10-07
check "sync: exit 0" "$RC" "0"
R501=$(id_of acme/widgets issue-501)
check "sync: the Review exists" "$([ -n "$R501" ] && echo yes)" "yes"
check "sync: asked, then filed from the desk" "$(events_of "$R501")" "asked:synced from GitHub,commented:filed from the desk"
check "sync: the pending filing is consumed; the unsynced one waits" "$(pending)" "filed:acme/widgets:issue-999"
check_contains "sync: the tally says so" "$(printf '%s\n' "$OUT" | tail -n 1)" "; 1 desk filing(s) noted on their Reviews"

hq bash sync-reviews --json
check "sync again: exit 0" "$RC" "0"
check "sync again --json: nothing new, nothing noted" "$(printf '%s' "$OUT" | jq -r '"\(.created | length) \(.desk_filings_noted)"')" "0 0"
check "sync again: still one filing event" "$(events_of "$R501")" "asked:synced from GitHub,commented:filed from the desk"

# --- noted: filed after the Review exists ---------------------------------------
hq bash filed acme/widgets 501
check "after the note: filed again is noted, no second event" "$RC|$OUT|$(events_of "$R501")" \
  "0|noted $R501|asked:synced from GitHub,commented:filed from the desk"
check "after the note: no new pending key" "$(pending)" "filed:acme/widgets:issue-999"

set_search search-issues.json "$(issue_row acme/gadgets 7 "Idea: gadgets" 2026-10-07T16:00:00Z)"
hq bash sync-reviews
check "a Review synced before any filing: exit 0" "$RC" "0"
R7=$(id_of acme/gadgets issue-7)
check "a Review synced before any filing: no event yet" "$(events_of "$R7")" "asked:synced from GitHub"
hq "$OLD_BASH" filed acme/gadgets 7 --json
check "filed after sync: noted at once" "$RC|$(printf '%s' "$OUT" | jq -c .)" \
  "0|{\"repo\":\"acme/gadgets\",\"number\":7,\"status\":\"noted\",\"review\":\"$R7\"}"
check "filed after sync: one event" "$(events_of "$R7")" "asked:synced from GitHub,commented:filed from the desk"
check "filed after sync: nothing left pending for it" "$(pending)" "filed:acme/widgets:issue-999"
# --- race: a key re-inserted after the note ---------------------------------------
# An overlapping `filed` can re-insert a pending key just after another run's
# transaction noted the Review (its insert waits on the key, then finds the
# row gone). Consuming that key must add nothing. The end state, built here.
RACE_KEY="INSERT INTO state (key, value) VALUES ('filed:acme/gadgets:issue-7', '2026-10-07T16:30:00Z')"
sql "$RACE_KEY" >/dev/null
hq bash sync-reviews --json
check "race, sync: exit 0" "$RC" "0"
check "race, sync: the key is consumed, nothing noted" "$(printf '%s' "$OUT" | jq -r '.desk_filings_noted')" "0"
check "race, sync: still one filing event" "$(events_of "$R7")" "asked:synced from GitHub,commented:filed from the desk"
check "race, sync: nothing left pending for it" "$(pending)" "filed:acme/widgets:issue-999"
sql "$RACE_KEY" >/dev/null
hq "$OLD_BASH" filed acme/gadgets 7
check "race, filed: noted, no second event" "$RC|$OUT|$(events_of "$R7")" \
  "0|noted $R7|asked:synced from GitHub,commented:filed from the desk"
check "race, filed: nothing left pending for it" "$(pending)" "filed:acme/widgets:issue-999"

hq bash filed acme/widgets 999 --json
check "--json while pending" "$(printf '%s' "$OUT" | jq -c .)" '{"repo":"acme/widgets","number":999,"status":"pending","review":null}'

# The Reviews themselves are untouched by the note: still open, still unreviewed.
check "the notes leave the Reviews open" "$(sql "SELECT string_agg(status, ',') FROM items WHERE id IN ('$R501', '$R7')")" "open,open"

check "public schema unchanged" "$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")" "$PUBLIC_BEFORE"

hq_t_finish "ideas.test.sh"
