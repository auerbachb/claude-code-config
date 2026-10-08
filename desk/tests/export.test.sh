#!/usr/bin/env bash
# desk/tests/export.test.sh — live tests for `human-queue.sh export`, the
# numbered paper copy of a batch (issue #1759), against the database in
# HUMAN_QUEUE_DATABASE_URL.
#
# ISOLATION: that database is the live queue both machines share, so nothing
# here touches its default schema. Every run creates a throwaway schema named
# hq_test_<pid>_<random>_export, points the CLI at it with HUMAN_QUEUE_SCHEMA,
# and drops it on exit; the number of tables in `public` is asserted
# unchanged. Every file is written under a private temp directory.
#
# Skips with a notice (exit 0) when HUMAN_QUEUE_DATABASE_URL is unset or jq is
# missing. With the URL set, an unreachable database FAILS the suite.
#
# Asserts (issue #1759):
#   5.1  three fixture Decisions export to a PDF with three sections, and
#        `pdftotext` finds all three ids (needs pdftotext and a renderer: on a
#        machine with neither, those checks skip with a notice and the rest
#        still run); the file is owner-only; a new set numbers them in list
#        order, with one `shown` and one `exported` event each; the cupsfilter
#        route on macOS gives a PDF the same ids are found in
#   5.2  with no renderer, the Markdown is written next to the requested path,
#        exit 0, and the one warning line names it
#   4.1  --set re-exports a set at its own numbers (no new set); --ids keeps
#        its order; --kind reviews at level 2 and 1, --today; a dry run opens
#        and records nothing; at most 99 items (`more`); an empty batch writes
#        nothing; an unknown id or set exits 4 having recorded nothing; a file
#        that cannot be written after the export was recorded undoes the
#        record (a new set and its events; with --set, only this export's
#        events); a store before migration 013 exits 1 naming migrate,
#        nothing recorded
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

hq_t_require_db "export.test.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: export.test.sh — jq is not installed (export needs it)"
  exit 0
fi

HQ_BIN_DIR="$HQ_T_DESK_DIR/bin"
# shellcheck source=../bin/lib/common.sh
. "$HQ_BIN_DIR/lib/common.sh"
# shellcheck source=../bin/lib/db.sh
. "$HQ_BIN_DIR/lib/db.sh"
HUMAN_QUEUE_SCHEMA=public hq_db_connect

S="hq_test_$$_$(printf '%05d' "$RANDOM")_export"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-export-test.XXXXXX")
mkdir -p "$TMP/out"

PDFTOTEXT=""
for c in /opt/homebrew/bin/pdftotext /usr/local/bin/pdftotext /usr/bin/pdftotext; do
  if [ -x "$c" ]; then PDFTOTEXT="$c"; break; fi
done

admin_sql() { hq_psql -At -c "$1"; }
cleanup() {
  admin_sql "DROP SCHEMA IF EXISTS $S CASCADE;" >/dev/null 2>&1 \
    || echo "WARN: could not drop scratch schema $S — drop it by hand" >&2
  rm -rf "$TMP"
  hq__cleanup_tmp
}
trap cleanup EXIT

sql_in() { hq_psql -At -c "SET search_path TO $S; $1" 2>&1; }

# hq ARGS... — the CLI in the scratch schema; sets OUT, ERR, RC.
hq() {
  RC=0
  HUMAN_QUEUE_SCHEMA="$S" bash "$HQ_T_CLI" "$@" >"$TMP/stdout" 2>"$TMP/stderr" </dev/null || RC=$?
  OUT=$(cat "$TMP/stdout")
  ERR=$(cat "$TMP/stderr")
}
# hq_none ARGS... — the CLI with no PDF renderer at all.
hq_none() {
  RC=0
  HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_PANDOC="" HUMAN_QUEUE_CHROME="" HUMAN_QUEUE_CUPSFILTER="" \
    bash "$HQ_T_CLI" "$@" >"$TMP/stdout" 2>"$TMP/stderr" </dev/null || RC=$?
  OUT=$(cat "$TMP/stdout")
  ERR=$(cat "$TMP/stderr")
}
jqo() { printf '%s' "$OUT" | jq -S -c "$1"; }
events() { sql_in "SELECT coalesce(string_agg(item_id || ' ' || kind || ' ' || coalesce(note, ''), '|' ORDER BY id), '') FROM events WHERE kind IN ('shown', 'exported') AND id > $1"; }
max_event() { sql_in "SELECT coalesce(max(id), 0) FROM events"; }
nsets() { sql_in "SELECT count(DISTINCT set_id) FROM sets"; }
mode_of() { ls -l "$1" 2>/dev/null | cut -c1-10; }

PUBLIC_BEFORE=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")

hq migrate
check "migrate the scratch schema" "$RC" "0"
if [ "$RC" -ne 0 ]; then
  printf 'migrate failed: %s\n' "$ERR"
  hq_t_finish "export.test.sh"
  exit 1
fi
check_contains "migrate applies 013_exported_event.sql" "$OUT" "applied 013_exported_event.sql"
check_contains "013: exported is an event kind" \
  "$(sql_in "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'events_kind_check' AND conrelid = 'events'::regclass")" \
  "'exported'"

# --- fixtures ----------------------------------------------------------------
# Open Decisions in list order: D-3 (parked), D-1 (high), D-2. D-4 is answered.
# Reviews: R-1 (today, both summaries), R-2 (two days ago, none), R-3 reviewed.
FIXTURE=$(sql_in "
INSERT INTO items (id, kind, repo, key, session_id, question, context, options, default_option,
                   impact_declared, parked, cost, status, answer, created_at) VALUES
  ('D-1', 'decision', 'acme/widgets', 'pr-12',    'worker-a', 'Retry the flaky upload test once?',
   ARRAY['The upload test failed twice on CI.'], ARRAY['Yes', 'No'], 'Yes', 'high', false, '~2 min', 'open', NULL, now() - interval '3 hours'),
  ('D-2', 'decision', 'acme/widgets', 'issue-11', 'worker-a', 'Ship the migration first?',
   ARRAY[]::text[], ARRAY['Yes', 'No', 'Split it'], NULL, NULL, false, NULL, 'open', NULL, now() - interval '2 hours'),
  ('D-3', 'decision', 'acme/gadgets', 'issue-13', 'worker-b', 'How should the importer handle partial rows?',
   ARRAY[]::text[], ARRAY[]::text[], NULL, NULL, true, '1h', 'open', NULL, now() - interval '1 hour'),
  ('D-4', 'decision', 'acme/gadgets', 'issue-14', 'worker-b', 'Already settled?',
   ARRAY[]::text[], ARRAY['Yes', 'No'], NULL, NULL, false, NULL, 'answered', 'A', now() - interval '5 hours');
INSERT INTO items (id, kind, repo, key, question, context, status, summary_l1, summary_l2, created_at) VALUES
  ('R-1', 'review', 'acme/gadgets', 'pr-283', 'Procedures can be versioned',
   ARRAY['https://github.com/acme/gadgets/pull/283', 'Merged 2026-10-07 15:00 UTC'], 'open',
   'Procedures can be instantiated and moved to a new version.',
   E'**Procedures can be instantiated and moved to a new version.**\n1. What changed: a procedure has versions.\n2. Tests: procedures.test.ts.',
   now()),
  ('R-2', 'review', 'acme/gadgets', 'issue-202', 'Idea: export gadgets',
   ARRAY['https://github.com/acme/gadgets/issues/202', 'Filed 2026-10-05 12:00 UTC'], 'open', NULL, NULL,
   now() - interval '2 days'),
  ('R-3', 'review', 'acme/gadgets', 'pr-284', 'Already reviewed',
   ARRAY['https://github.com/acme/gadgets/pull/284', 'Merged 2026-10-06 15:00 UTC'], 'reviewed', NULL, NULL,
   now() - interval '1 day');
")
check "setup: the fixtures load (no error)" "$FIXTURE" ""

# --- 5.1 three Decisions to a PDF ----------------------------------------------
E0=$(max_event)
SETS0=$(nsets)
hq export --kind decisions --out "$TMP/out/decisions.pdf" --json
check "5.1 export --kind decisions: exit 0" "$RC" "0"
FORMAT=$(jqo '.format' | tr -d '"')
SET1=$(jqo '.set_id')
check "5.1 the batch: three open Decisions in list order, a new set" \
  "$(jqo '[.count, .more, .new_set, [.items[] | [.n, .id]]]')" '[3,0,true,[[1,"D-3"],[2,"D-1"],[3,"D-2"]]]'
check "5.1 the set numbers them 1 to 3" \
  "$(sql_in "SELECT string_agg(position || ':' || item_id, ' ' ORDER BY position) FROM sets WHERE set_id = $SET1")" "1:D-3 2:D-1 3:D-2"
check "5.1 one shown and one exported event per item, at its number" "$(events "$E0")" \
  "D-3 shown set $SET1 #1|D-1 shown set $SET1 #2|D-2 shown set $SET1 #3|D-3 exported set $SET1 #1|D-1 exported set $SET1 #2|D-2 exported set $SET1 #3"
if [ "$FORMAT" = pdf ]; then
  check "5.1 the path printed is the PDF's, absolute" "$(jqo '.path' | tr -d '"')" "$(cd -P "$TMP/out" && pwd)/decisions.pdf"
  check "5.1 the PDF is owner-only" "$(mode_of "$TMP/out/decisions.pdf")" "-rw-------"
  check "5.1 the file is a PDF" "$(head -c 5 "$TMP/out/decisions.pdf")" "%PDF-"
  check "5.1 no warning" "$ERR" ""
  if [ -n "$PDFTOTEXT" ]; then
    TEXT=$("$PDFTOTEXT" -layout "$TMP/out/decisions.pdf" - 2>/dev/null | tr -d '\f')
    for id in D-1 D-2 D-3; do check_contains "5.1 pdftotext finds $id" "$TEXT" "$id ·"; done
    check "5.1 three sections, one heading each" "$(printf '%s\n' "$TEXT" | grep -cE '^ *[0-9]+ +D-[0-9]+ ·')" "3"
    check_contains "5.1 options numbered n.k with their letter" "$TEXT" "2.2"
    check_contains "5.1 the footer carries the export time" "$TEXT" "Exported "
  else
    echo "NOTICE: pdftotext not found — 5.1's text checks skipped"
  fi
else
  echo "NOTICE: no PDF renderer on this machine ($(jqo '.warning')) — 5.1's PDF checks skipped"
fi

# The macOS print system, on its own.
if [ "$(uname -s)" = Darwin ] && [ -x /usr/sbin/cupsfilter ] && [ -n "$PDFTOTEXT" ]; then
  RC=0
  HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_EXPORT_RENDERER=cupsfilter \
    bash "$HQ_T_CLI" export --set "$SET1" --out "$TMP/out/cups.pdf" --json >"$TMP/stdout" 2>"$TMP/stderr" </dev/null || RC=$?
  OUT=$(cat "$TMP/stdout")
  check "5.1 cupsfilter: exit 0" "$RC" "0"
  check "5.1 cupsfilter: a PDF from cupsfilter" "$(jqo '[.format, .renderer]')" '["pdf","cupsfilter"]'
  TEXT=$("$PDFTOTEXT" "$TMP/out/cups.pdf" - 2>/dev/null | tr -d '\f')
  for id in D-1 D-2 D-3; do check_contains "5.1 cupsfilter: pdftotext finds $id" "$TEXT" "$id"; done
fi

# --- 5.2 no renderer: the Markdown, next to the requested path ------------------
E0=$(max_event)
hq_none export --set "$SET1" --out "$TMP/out/paper.pdf"
check "5.2 no renderer: exit 0" "$RC" "0"
MD="$(cd -P "$TMP/out" && pwd)/paper.md"
check "5.2 no renderer: the path printed is the Markdown's" "$OUT" "$MD"
check "5.2 no renderer: one warning line" "$(hq_t_lines "$ERR")" "1"
check_contains "5.2 the warning names the Markdown" "$ERR" "wrote the Markdown instead: $MD"
check_contains "5.2 the warning says what each renderer did" "$ERR" "pandoc: not installed; chrome: not installed; cupsfilter: not installed"
check "5.2 no PDF was written" "$([ -e "$TMP/out/paper.pdf" ] && echo yes || echo no)" "no"
check "5.2 the Markdown is owner-only" "$(mode_of "$MD")" "-rw-------"
check "5.2 the Markdown holds the three sections at the set's numbers" \
  "$(grep -E '^## ' "$MD" 2>/dev/null | sed 's/ ·.*//')" "## 1  D-3
## 2  D-1
## 3  D-2"
check_contains "5.2 options as n.k with their letter" "$(cat "$MD")" "3.3  C. Split it"
check_contains "5.2 a blank answer line" "$(cat "$MD")" "Answer: ____"
check_contains "5.2 the footer" "$(cat "$MD")" "· set $SET1 · 3 items"

# --- 4.1 --set keeps its numbers, opens nothing ----------------------------------
check "4.1 --set opened no set (only 5.1's)" "$(nsets)" "$((SETS0 + 1))"
check "4.1 --set recorded one exported event per item, at the set's numbers" "$(events "$E0")" \
  "D-3 exported set $SET1 #1|D-1 exported set $SET1 #2|D-2 exported set $SET1 #3"
hq export --set "$SET1" --dry-run --json
check "4.1 --set --dry-run: the set, not new" "$(jqo '[.set_id, .new_set, .dry_run, .path]')" "[$SET1,false,true,null]"

# --- --ids, Reviews, levels --------------------------------------------------------
E0=$(max_event)
hq_none export --ids r-2 D-2 R-1 --out "$TMP/out/ids.pdf" --json
check "--ids: exit 0" "$RC" "0"
check "--ids: in the given order, a new set" "$(jqo '[.new_set, [.items[] | [.n, .id]]]')" '[true,[[1,"R-2"],[2,"D-2"],[3,"R-1"]]]'
check "--ids: a Review with no level-2 summary is named" "$(jqo '.missing_summary')" '["R-2"]'
check "--ids: the Markdown fallback in --json" "$(jqo '[.format, .renderer, (.warning | type)]')" '["markdown",null,"string"]'
IDS_MD=$(cat "$TMP/out/ids.md" 2>/dev/null)
check_contains "--ids level 2: R-1's twenty-line summary" "$IDS_MD" "1. What changed: a procedure has versions."
check_contains "--ids level 2: R-2 marked not summarized" "$IDS_MD" "(title; not summarized yet)"
check_contains "--ids: a Review's answer line" "$IDS_MD" "Reviewed [ ]   Flag, and why:"

hq_none export --kind reviews --level 1 --out "$TMP/out/reviews.pdf" --json
check "--kind reviews: the unreviewed, oldest first" "$(jqo '[.items[] | .id]')" '["R-2","R-1"]'
check "--kind reviews --level 1: R-2 has no line" "$(jqo '.missing_summary')" '["R-2"]'
REV_MD=$(cat "$TMP/out/reviews.md" 2>/dev/null)
check_contains "--level 1: R-1's line" "$REV_MD" "Procedures can be instantiated and moved to a new version."
check_absent "--level 1: not its level-2 points" "$REV_MD" "1. What changed"
hq export --kind reviews --today --dry-run --json
check "--kind reviews --today: only today's" "$(jqo '[.items[] | .id]')" '["R-1"]'
hq export --ids D-1 R-1 --dry-run
check "--dry-run text: one line per item" "$OUT" "1. D-1
2. R-1"

# --- a dry run records nothing ---------------------------------------------------
E0=$(max_event)
SETS1=$(nsets)
hq export --kind decisions --dry-run --json
check "--dry-run: exit 0" "$RC" "0"
check "--dry-run: no set, no path" "$(jqo '[.set_id, .new_set, .dry_run, .path, .count]')" '[null,false,true,null,3]'
check "--dry-run: no event" "$(events "$E0")" ""
check "--dry-run: no set opened" "$(nsets)" "$SETS1"

# --- refusals after connecting record nothing ------------------------------------
hq export --ids D-1 D-99 --out "$TMP/out/x.pdf"
check "an unknown id: exit 4" "$RC" "4"
check_contains "an unknown id is named" "$ERR" "no item D-99; nothing was exported"
hq export --set 999999 --out "$TMP/out/x.pdf"
check "an unknown set: exit 4" "$RC" "4"
check_contains "an unknown set is named" "$ERR" "no set 999999"
check "refusals recorded nothing" "$(events "$E0")" ""
check "refusals opened no set" "$(nsets)" "$SETS1"
check "refusals wrote nothing" "$([ -e "$TMP/out/x.pdf" ] || [ -e "$TMP/out/x.md" ] && echo yes || echo no)" "no"

# --- a file that cannot be written: the record is undone --------------------------
# A Chrome stand-in that makes the output directory read-only, then writes its
# PDF: the export is recorded, and then the file cannot be placed.
mkdir -p "$TMP/ro"
cat > "$TMP/lock-chrome" <<'EOF'
#!/usr/bin/env bash
chmod 555 "$LOCK_DIR"
out=""
for a in "$@"; do case "$a" in --print-to-pdf=*) out="${a#--print-to-pdf=}" ;; esac; done
printf '%%PDF-1.4 stub\n' > "$out"
echo "16 bytes written to file $out" >&2
exec sleep 30
EOF
chmod +x "$TMP/lock-chrome"
# hq_locked ARGS... — the CLI with that stand-in as its only renderer.
hq_locked() {
  RC=0
  chmod 755 "$TMP/ro"
  HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_EXPORT_RENDERER=chrome HUMAN_QUEUE_CHROME="$TMP/lock-chrome" LOCK_DIR="$TMP/ro" \
    bash "$HQ_T_CLI" "$@" >"$TMP/stdout" 2>"$TMP/stderr" </dev/null || RC=$?
  chmod 755 "$TMP/ro"
  OUT=$(cat "$TMP/stdout")
  ERR=$(cat "$TMP/stderr")
}
exported_count() { sql_in "SELECT count(*) FROM events WHERE kind = 'exported'"; }

E0=$(max_event)
SETS1=$(nsets)
hq_locked export --kind decisions --out "$TMP/ro/locked.pdf"
check "unwritable after recording: exit 1" "$RC" "1"
check_contains "unwritable after recording: nothing was recorded" "$ERR" "could not write the PDF; nothing was recorded"
check "unwritable after recording: its set and its events are removed" "$(nsets):$(events "$E0")" "$SETS1:"
check "unwritable after recording: no file" "$(find "$TMP/ro" -mindepth 1 | wc -l | tr -d ' ')" "0"

EXPORTED0=$(exported_count)
POSITIONS0=$(sql_in "SELECT string_agg(position || ':' || item_id, ' ' ORDER BY position) FROM sets WHERE set_id = $SET1")
hq_locked export --set "$SET1" --out "$TMP/ro/locked.pdf"
check "unwritable, --set: exit 1, nothing recorded" "$RC:$(events "$E0")" "1:"
check "unwritable, --set: the set itself is kept" \
  "$(sql_in "SELECT string_agg(position || ':' || item_id, ' ' ORDER BY position) FROM sets WHERE set_id = $SET1")" "$POSITIONS0"
check "unwritable, --set: the set's earlier exports are kept" "$(exported_count)" "$EXPORTED0"

# --- stopped mid-render: the record is taken back ----------------------------------
# A Chrome stand-in that never finishes; the export is stopped (SIGTERM) while
# it waits on it, after the record committed and before any file.
cat > "$TMP/hang-chrome" <<'EOF'
#!/usr/bin/env bash
echo "$$" > "$HANG_PID_FILE"
exec sleep 30
EOF
chmod +x "$TMP/hang-chrome"
E0=$(max_event)
SETS1=$(nsets)
rm -f "$TMP/hang.pid"
HUMAN_QUEUE_SCHEMA="$S" HUMAN_QUEUE_EXPORT_RENDERER=chrome HUMAN_QUEUE_CHROME="$TMP/hang-chrome" \
  HANG_PID_FILE="$TMP/hang.pid" bash "$HQ_T_CLI" export --kind decisions --out "$TMP/out/halted.pdf" \
  >"$TMP/stdout" 2>"$TMP/stderr" </dev/null &
EXPORT_PID=$!
i=0
while [ ! -s "$TMP/hang.pid" ] && [ "$i" -lt 300 ]; do sleep 0.2; i=$((i + 1)); done
check "stopped mid-render: the renderer was running" "$([ -s "$TMP/hang.pid" ] && echo yes || echo no)" "yes"
kill -TERM "$EXPORT_PID" 2>/dev/null
wait "$EXPORT_PID" 2>/dev/null
check "stopped mid-render: its set and its events are taken back" "$(nsets):$(events "$E0")" "$SETS1:"
check_contains "stopped mid-render: says so" "$(cat "$TMP/stderr")" "stopped before the file was written; nothing was recorded"
check "stopped mid-render: no file" \
  "$([ -e "$TMP/out/halted.pdf" ] || [ -e "$TMP/out/halted.md" ] && echo yes || echo no)" "no"
check "stopped mid-render: the renderer is stopped too" \
  "$(kill -0 "$(cat "$TMP/hang.pid" 2>/dev/null)" 2>/dev/null && echo running || echo stopped)" "stopped"

# --- at most 99 ------------------------------------------------------------------
MANY=$(sql_in "INSERT INTO items (id, kind, repo, key, question, status)
  SELECT 'D-' || g, 'decision', 'acme/widgets', 'issue-' || g, 'Question ' || g || '?', 'open'
    FROM generate_series(100, 197) g;")
check "setup: 98 more open Decisions" "$MANY" ""
hq export --kind decisions --dry-run --json
check "more than 99: 99 exported, the rest counted" "$(jqo '[.count, .more, (.items | last | .n)]')" '[99,2,99]'
check_contains "more than 99: a warning line" "$ERR" "2 more items were left out"

# --- an empty batch writes nothing ------------------------------------------------
sql_in "UPDATE items SET status = 'reviewed' WHERE kind = 'review'" >/dev/null
E0=$(max_event)
SETS1=$(nsets)
hq export --kind reviews --out "$TMP/out/empty.pdf"
check "an empty batch: exit 0" "$RC" "0"
check "an empty batch: says so" "$OUT" "nothing to export"
check "an empty batch: no file" "$([ -e "$TMP/out/empty.pdf" ] || [ -e "$TMP/out/empty.md" ] && echo yes || echo no)" "no"
check "an empty batch: no set, no event" "$(nsets):$(events "$E0")" "$SETS1:"

# --- before migration 013 ----------------------------------------------------------
OLD=$(sql_in "ALTER TABLE events DROP CONSTRAINT events_kind_check; ALTER TABLE events ADD CONSTRAINT events_kind_check CHECK (kind IN ('asked', 'bumped', 'shown', 'answered', 'acknowledged', 'reviewed', 'flagged', 'feedback', 'commented', 'woken', 'wake-failed', 'answer-parked')) NOT VALID;")
check "setup: a store before 013" "$OLD" ""
E0=$(max_event)
SETS1=$(nsets)
hq_none export --ids D-1 --out "$TMP/out/old.pdf"
check "before 013: exit 1" "$RC" "1"
check_contains "before 013: names migrate" "$ERR" "run human-queue.sh migrate"
check "before 013: nothing recorded, no set" "$(nsets):$(events "$E0")" "$SETS1:"
check "before 013: nothing written" "$([ -e "$TMP/out/old.pdf" ] || [ -e "$TMP/out/old.md" ] && echo yes || echo no)" "no"
hq export --ids D-1 --dry-run
check "before 013: a dry run still works" "$RC:$OUT" "0:1. D-1"

PUBLIC_AFTER=$(admin_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
check "public schema table count unchanged" "$PUBLIC_AFTER" "$PUBLIC_BEFORE"

hq_t_finish "export.test.sh"
