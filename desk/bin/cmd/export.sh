# shellcheck shell=bash
# summary: write a numbered PDF of a batch (pending Decisions, unreviewed Reviews, a set, or ids) to review on paper
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR and HQ_DESK_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"
# shellcheck source=../lib/github.sh
. "$HQ_BIN_DIR/lib/github.sh"
# shellcheck source=../lib/export.sh
. "$HQ_BIN_DIR/lib/export.sh"

# The most an export holds: set-open numbers at most 99 items.
HQ_EXPORT_MAX=99

cmd_usage() {
  cat <<'EOF'
human-queue.sh export — a numbered PDF of a batch, to answer on paper (issue #1759).

USAGE
  human-queue.sh export --out FILE.pdf --kind decisions|reviews [--today] [--level 1|2] [--json]
  human-queue.sh export --out FILE.pdf --ids ID [ID...] [--kind ...] [--level 1|2] [--json]
  human-queue.sh export --out FILE.pdf --set N [--level 1|2] [--json]
  human-queue.sh export (any of the above) --dry-run [--json]    (--out optional)

WHAT IT EXPORTS (exactly one of)
  --kind decisions  the pending batch: every open Decision, parked first, then
                    impact, then age (decision is accepted too)
  --kind reviews    every unreviewed Review, oldest first (review is accepted
                    too); --today keeps those synced today (America/New_York)
  --ids ID...       those items, in that order (d-43 is accepted; ids may
                    also be comma-separated). With --kind, every id must be
                    of that kind
  --set N           the items of set N (as set-open printed it) at their own
                    numbers: the end-of-day sweep exports its set this way
  At most 99 items; the rest are counted as `more`.

OPTIONS
  --out FILE.pdf    where to write it: a name ending in .pdf in an existing,
                    writable directory. Replaced if it exists. Written
                    owner-only (0600: it holds open questions)
  --level 1|2       how much of each Review: 2 (the default) its cached
                    twenty-line summary, 1 its cached line. A Review without
                    one shows the next level down, marked
  --dry-run         select and report only: no set is opened, nothing is
                    recorded, nothing is written
  --json            print the result as one JSON object (OUTPUT)

NUMBERING
  The paper's numbers are a set's, so a reply typed from paper (`2: B`)
  resolves through set-resolve --set N. --kind and --ids open a new set, as
  set-open does (one `shown` event per item); --set opens nothing. Item ids
  print in every heading, so `D-43: B` works whatever set is current.

LAYOUT (ISO 2145)
  A title, the set, the count, and the export time. One section per item,
  headed `n  D-43 · the question` (a Review: `n  R-9 · PR #283`): its repo
  and key and triage facts, its context, a Review's summary, its options as
  `n.1  A. Yes (Recommended)`, `n.2  B. No`, the default and when it applies,
  the operator's own priority, tags, and note when it carries them (#1769),
  its link, and a blank answer line (an item answered since: its answer).
  A footer with the export time (from headless Chrome on every page, with
  page numbers; from pandoc or cupsfilter once, at the end).

RENDERERS
  The first that produces a PDF: pandoc (the Markdown), headless Google
  Chrome (the HTML), the macOS print system (cupsfilter, the plain text).
  With none, the Markdown is written next to FILE (FILE with .md for .pdf),
  the exit is still 0, and one warning line on stderr names it.
  HUMAN_QUEUE_EXPORT_RENDERER (auto, pandoc, chrome, cupsfilter, markdown)
  picks one; HUMAN_QUEUE_PANDOC, HUMAN_QUEUE_CHROME, and
  HUMAN_QUEUE_CUPSFILTER name their binaries (set to anything that is not
  an executable file, that renderer counts as not installed);
  HUMAN_QUEUE_EXPORT_TIMEOUT caps each one's run in seconds, 1 to 86400
  (defaults: pandoc 120, Chrome 60, cupsfilter 30; any other value keeps
  them). Headless Chrome, which can keep
  running after it writes its PDF, is stopped once it reports the file; it
  runs offline. Each renderer's temp files stay in a private scratch
  directory removed on exit, and an export interrupted mid-render stops its
  renderer.

RECORDING
  One `exported` event per item (note `set N #k`), in the transaction that
  reads the items (migration 013). If the file then cannot be written, that
  record is removed again (the set it opened, its `shown` and `exported`
  events) and export exits 1 saying `nothing was recorded`; an export
  stopped before its file is in place (SIGTERM, SIGINT) removes it too. Before 013 is
  applied, export exits 1 naming `migrate`; --dry-run records nothing and
  needs no migration.

OUTPUT
  The written file's absolute path, one line. An empty batch writes no file
  and opens no set, and prints `nothing to export`. --json:
  {"path", "format": "pdf"|"markdown", "renderer", "dry_run", "set_id",
  "new_set", "count", "more", "items": [{"n", "id"}], "missing_summary":
  [Review ids with no summary at --level], "warning"}; path, format, and
  renderer are null on a dry run or an empty batch. Without --json, a dry
  run prints `1. D-43` per item (a Review missing its summary: `· no level-2
  summary`). Warnings (the Markdown fallback, items past 99) are one line
  each on stderr.

EXIT CODES
  0  ok (including an empty batch and the Markdown fallback)
  1  unexpected failure: the database, a store before migration 013 (run
     human-queue.sh migrate), jq missing, or the file could not be written
  4  a bad or missing argument, an unwritable --out (before any connection
     attempt); an id with no item or a set that does not exist (after
     connecting, nothing recorded)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# hq__export_sql SOURCE NIDS — the selection, its problems, the set, the
# events, and the model as one JSON object. Variables: hq_source, hq_set_id
# (the set for --set, else empty), hq_new (1: open a set), hq_dry, hq_level,
# hq_tz, hq_today, hq_id_1 .. hq_id_NIDS. Only variable references are
# generated, never values. The selection is read once and carried as two
# comma lists (ids and their numbers), so every later statement sees the same
# batch.
hq__export_sql() {
  local source="$1" nids="$2" k=1 rows=""
  printf '%s\n' "SET LOCAL lock_timeout TO '30s';"
  case "$source" in
    ids)
      while [ "$k" -le "$nids" ]; do
        rows="$rows${rows:+, }($k, :'hq_id_$k'::text)"
        k=$((k + 1))
      done
      printf 'WITH input(n, id) AS (VALUES %s)\n' "$rows"
      cat <<'SQL'
SELECT coalesce(string_agg(inp.id, ',' ORDER BY inp.n), '') AS hq_sel_ids,
       coalesce(string_agg(inp.n::text, ',' ORDER BY inp.n), '') AS hq_sel_ns,
       count(*) AS hq_total,
       coalesce('no item ' || string_agg(inp.id, ', ' ORDER BY inp.n) FILTER (WHERE i.id IS NULL)
                || '; nothing was exported', '') AS hq_problem
  FROM input inp LEFT JOIN items i ON i.id = inp.id \gset
SQL
      ;;
    set)
      cat <<'SQL'
SELECT coalesce(string_agg(s.item_id, ',' ORDER BY s.position), '') AS hq_sel_ids,
       coalesce(string_agg(s.position::text, ',' ORDER BY s.position), '') AS hq_sel_ns,
       count(*) AS hq_total,
       CASE WHEN count(*) = 0 THEN 'no set ' || :'hq_set_id' || '; nothing was exported' ELSE '' END AS hq_problem
  FROM sets s WHERE s.set_id = :'hq_set_id'::bigint \gset
SQL
      ;;
    decisions|reviews)
      printf '%s\n' "WITH c AS ("
      printf '%s\n' "  SELECT i.id, row_number() OVER (ORDER BY"
      if [ "$source" = decisions ]; then
        hq_sql_item_order
        printf '%s\n' "  ) AS ord FROM items i WHERE i.kind = 'decision' AND i.status = 'open'"
      else
        printf '%s\n' "  i.created_at, i.id) AS ord FROM items i WHERE i.kind = 'review' AND i.status = 'open'"
        printf '%s\n' "    AND (:'hq_today' = '0'"
        printf '%s\n' "         OR (i.created_at AT TIME ZONE :'hq_tz')::date = (now() AT TIME ZONE :'hq_tz')::date)"
      fi
      printf '%s\n' ")"
      cat <<SQL
SELECT coalesce(string_agg(id, ',' ORDER BY ord) FILTER (WHERE ord <= $HQ_EXPORT_MAX), '') AS hq_sel_ids,
       coalesce(string_agg(ord::text, ',' ORDER BY ord) FILTER (WHERE ord <= $HQ_EXPORT_MAX), '') AS hq_sel_ns,
       count(*) AS hq_total,
       '' AS hq_problem
  FROM c \gset
SQL
      ;;
  esac
  cat <<'SQL'
SELECT :'hq_problem' = '' AS hq_ok,
       :'hq_sel_ids' <> '' AND :'hq_dry' = '0' AS hq_record,
       :'hq_sel_ids' <> '' AND :'hq_dry' = '0' AND :'hq_new' = '1' AS hq_open_set \gset
\if :hq_ok
\set hq_shown_ids ''
\set hq_exported_ids ''
\if :hq_open_set
SELECT nextval('sets_set_id_seq') AS hq_set_id \gset
WITH s AS (
  SELECT u.id, u.n FROM unnest(string_to_array(:'hq_sel_ids', ','), string_to_array(:'hq_sel_ns', ',')::int[]) AS u(id, n)
), ins AS (
  INSERT INTO sets (set_id, position, item_id)
  SELECT :'hq_set_id'::bigint, s.n, s.id FROM s
  RETURNING position
), ev AS (
  INSERT INTO events (item_id, kind, note)
  SELECT s.id, 'shown', 'set ' || :'hq_set_id' || ' #' || s.n FROM s ORDER BY s.n
  RETURNING id
)
SELECT coalesce(string_agg(id::text, ',' ORDER BY id), '') AS hq_shown_ids FROM ev \gset
\endif
\if :hq_record
WITH ev AS (
  INSERT INTO events (item_id, kind, note)
  SELECT u.id, 'exported', 'set ' || :'hq_set_id' || ' #' || u.n
    FROM unnest(string_to_array(:'hq_sel_ids', ','), string_to_array(:'hq_sel_ns', ',')::int[]) AS u(id, n)
   ORDER BY u.n
  RETURNING id
)
SELECT coalesce(string_agg(id::text, ',' ORDER BY id), '') AS hq_exported_ids FROM ev \gset
\endif
SELECT jsonb_build_object(
         'source', :'hq_source',
         'event_ids', to_jsonb(array_remove(string_to_array(:'hq_shown_ids' || ',' || :'hq_exported_ids', ','), '')::bigint[]),
         'set_id', nullif(:'hq_set_id', '')::bigint,
         'new_set', :'hq_open_set'::boolean,
         'dry_run', :'hq_dry' = '1',
         'level', :'hq_level'::int,
         'today', to_char(now() AT TIME ZONE :'hq_tz', 'YYYY-MM-DD'),
         'exported_at', now(),
         'exported_local', to_char(now() AT TIME ZONE :'hq_tz', 'Dy YYYY-MM-DD HH24:MI'),
         'count', coalesce(cardinality(string_to_array(nullif(:'hq_sel_ids', ''), ',')), 0),
         'more', greatest(:'hq_total'::int - coalesce(cardinality(string_to_array(nullif(:'hq_sel_ids', ''), ',')), 0), 0),
         'items', coalesce((
           SELECT jsonb_agg((to_jsonb(i) - 'change_xid') || jsonb_build_object('n', u.n) ORDER BY u.n)
             FROM unnest(string_to_array(:'hq_sel_ids', ','), string_to_array(:'hq_sel_ns', ',')::int[]) AS u(id, n)
             JOIN items i ON i.id = u.id), '[]'::jsonb));
\else
SELECT '!' || :'hq_problem';
\endif
SQL
}

# hq__export_out_check PATH — exits 4 unless PATH can be written: a name
# ending in .pdf, not a directory, in an existing writable directory, whose
# Markdown sibling is not a directory either. The path is never echoed.
hq__export_out_check() {
  local p="$1" dir base
  hq_refuse_control "export: --out" "$p"
  case "$p" in
    '') hq_die_validation "export: --out is empty" ;;
    *.[pP][dD][fF]) ;;
    *) hq_die_validation "export: --out must name a .pdf file" ;;
  esac
  base="${p##*/}"
  case "$base" in
    .[pP][dD][fF]) hq_die_validation "export: --out must name a .pdf file, not just the extension" ;;
  esac
  case "$p" in
    */*) dir="${p%/*}"; dir="${dir:-/}" ;;
    *) dir="." ;;
  esac
  if [ ! -d "$dir" ]; then hq_die_validation "export: --out's directory does not exist"; fi
  if [ ! -w "$dir" ]; then hq_die_validation "export: --out's directory is not writable"; fi
  if [ -d "$p" ] || [ -d "${p%.*}.md" ]; then hq_die_validation "export: --out names a directory"; fi
}

# HQ_EXPORT_WORK: the private scratch directory (the three renderings, the
# renderers' own files and temp files, Chrome's throwaway profile); removed
# on exit, after any renderer still running (an interrupted export) is
# stopped. HQ_EXPORT_PENDING: the store's JSON for a recorded export whose
# file is not placed yet; an exit with it still set (SIGTERM, SIGINT, SIGHUP
# mid-render) takes the record back, as hq__export_fail does, so no unseen
# set outlives the export. Cleared once the file is in place.
HQ_EXPORT_WORK=""
HQ_EXPORT_PENDING=""
hq__export_cleanup() {
  local hq__pending="$HQ_EXPORT_PENDING"
  hq_export_stop_renderer
  if [ -n "$hq__pending" ]; then
    HQ_EXPORT_PENDING=""
    if hq__export_undo "$hq__pending"; then
      printf 'human-queue: export: stopped before the file was written; nothing was recorded\n' >&2
    else
      printf 'human-queue: export: stopped before the file was written (and could not undo the record: the items stay recorded as exported)\n' >&2
    fi
  fi
  case "$HQ_EXPORT_WORK" in
    */human-queue-export.*) rm -rf "$HQ_EXPORT_WORK" 2>/dev/null || true ;;
  esac
  hq__cleanup_tmp
}

# hq__export_place SRC DEST — copies SRC over DEST through a private temp file
# in DEST's directory and a rename, so DEST is never half written and is
# owner-only. Returns 1 on any failure (DEST unchanged).
hq__export_place() {
  local src="$1" dest="$2" dir tmp
  case "$dest" in
    */*) dir="${dest%/*}"; dir="${dir:-/}" ;;
    *) dir="." ;;
  esac
  tmp=$(mktemp "$dir/.human-queue-export.XXXXXX" 2>/dev/null) || return 1
  HQ_TMPFILES="$HQ_TMPFILES
$tmp"
  chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  cat "$src" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dest" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# hq__export_undo DATA — the export was recorded (DATA: the store's JSON) but
# its file could not be written: one more transaction removes what the first
# recorded: the events it inserted (its `exported` events and, when it opened
# the set, their `shown` ones), by the ids that transaction returned
# (`event_ids`), so no other export's events are touched; and the set it
# opened. Returns non-zero when that could not be done.
hq__export_undo() {
  local data="$1" sid new evids
  sid=$(printf '%s' "$data" | hq_jq -r '.set_id // empty' 2>/dev/null) || return 1
  new=$(printf '%s' "$data" | hq_jq -r 'if .new_set then 1 else 0 end' 2>/dev/null) || return 1
  evids=$(printf '%s' "$data" | hq_jq -r '(.event_ids // []) | map(tostring) | join(",")' 2>/dev/null) || return 1
  if [ -z "$sid" ] || [ -z "$evids" ]; then return 1; fi
  hq_db_script -At -v "hq_set_id=$sid" -v "hq_new=$new" -v "hq_event_ids=$evids" \
    >/dev/null 2>&1 <<'SQL'
SET LOCAL lock_timeout TO '30s';
DELETE FROM events WHERE id = ANY (string_to_array(:'hq_event_ids', ',')::bigint[]);
DELETE FROM sets WHERE set_id = :'hq_set_id'::bigint AND :'hq_new' = '1';
SQL
}

# hq__export_fail DATA WHAT — exits 1: WHAT (`write the PDF`) failed after the
# export was recorded. The record is undone first, so the store names no paper
# that does not exist and no unseen set becomes the latest; only when the
# store refuses that too does the message say the items stay recorded.
hq__export_fail() {
  HQ_EXPORT_PENDING=""
  if hq__export_undo "$1"; then
    hq_die_error "export: could not $2; nothing was recorded"
  fi
  hq_die_error "export: could not $2 (and could not undo the record: the items stay recorded as exported)"
}

# hq__export_abs PATH — PATH made absolute (its directory resolved).
hq__export_abs() {
  local p="$1" dir
  case "$p" in
    */*) dir="${p%/*}"; dir="${dir:-/}" ;;
    *) dir="." ;;
  esac
  dir=$(cd -P "$dir" 2>/dev/null && pwd) || { printf '%s' "$p"; return 0; }
  printf '%s/%s' "${dir%/}" "${p##*/}"
}

cmd_run() {
  local json=0 dry=0 today=0 kind="" level=2 have_level=0 setid="" have_set=0 out="" have_out=0
  local n=0 k id part rest batch new=0 errf data rc warn="" path="" format="" renderer="" mdpath
  local -a ids=() pv=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --json) json=1 ;;
      --dry-run) dry=1 ;;
      --today) today=1 ;;
      --kind|--level|--set|--out)
        if [ "$#" -lt 2 ]; then hq_die_validation "export: $1 needs a value"; fi
        case "$1" in
          --kind)
            if [ -n "$kind" ]; then hq_die_validation "export: --kind given more than once"; fi
            case "$2" in
              decision|decisions) kind=decision ;;
              review|reviews) kind=review ;;
              *) hq_die_validation "export: --kind must be decisions or reviews" ;;
            esac
            ;;
          --level)
            if [ "$have_level" -eq 1 ]; then hq_die_validation "export: --level given more than once"; fi
            have_level=1
            case "$2" in
              1|2) level="$2" ;;
              *) hq_die_validation "export: --level must be 1 or 2" ;;
            esac
            ;;
          --set)
            if [ "$have_set" -eq 1 ]; then hq_die_validation "export: --set given more than once"; fi
            have_set=1
            case "$2" in
              [1-9]|[1-9]*[0-9]) ;;
              *) hq_die_validation "export: --set must be a set id (a positive whole number)" ;;
            esac
            case "$2" in
              *[!0-9]*) hq_die_validation "export: --set must be a set id (a positive whole number)" ;;
            esac
            if ! hq_bigint_ok "$2"; then hq_die_validation "export: --set is out of range"; fi
            setid="$2"
            ;;
          --out)
            if [ "$have_out" -eq 1 ]; then hq_die_validation "export: --out given more than once"; fi
            have_out=1
            out="$2"
            ;;
        esac
        shift
        ;;
      --ids)
        if [ "$#" -lt 2 ]; then hq_die_validation "export: --ids needs at least one item id"; fi
        while [ "$#" -ge 2 ]; do
          case "$2" in -*|'') break ;; esac
          rest="$2,"
          while [ -n "$rest" ]; do
            part="${rest%%,*}"
            rest="${rest#*,}"
            [ -n "$part" ] || continue
            hq_item_id id "$part"
            k=0
            while [ "$k" -lt "$n" ]; do
              if [ "${ids[k]}" = "$id" ]; then hq_die_validation "export: $id is given twice"; fi
              k=$((k + 1))
            done
            ids[n]="$id"
            n=$((n + 1))
            if [ "$n" -gt "$HQ_EXPORT_MAX" ]; then
              hq_die_validation "export: at most $HQ_EXPORT_MAX items per export"
            fi
          done
          shift
        done
        if [ "$n" -eq 0 ]; then hq_die_validation "export: --ids needs at least one item id"; fi
        ;;
      -*) hq_die_validation "export: unknown $(hq_flag_name "$1") (run human-queue.sh export --help)" ;;
      *) hq_die_validation "export: stray argument (item ids follow --ids; run human-queue.sh export --help)" ;;
    esac
    shift
  done

  # What to export: exactly one source.
  if [ "$have_set" -eq 1 ]; then
    if [ -n "$kind" ] || [ "$n" -gt 0 ] || [ "$today" -eq 1 ]; then
      hq_die_validation "export: --set goes alone (not with --kind, --ids, or --today)"
    fi
    batch="set"
  elif [ "$n" -gt 0 ]; then
    if [ "$today" -eq 1 ]; then hq_die_validation "export: --today goes only with --kind reviews"; fi
    if [ -n "$kind" ]; then
      k=0
      while [ "$k" -lt "$n" ]; do
        case "$kind:${ids[k]}" in
          decision:D-*|review:R-*) ;;
          *) hq_die_validation "export: ${ids[k]} is not a $kind" ;;
        esac
        k=$((k + 1))
      done
    fi
    batch="ids"
    new=1
  elif [ -n "$kind" ]; then
    if [ "$today" -eq 1 ] && [ "$kind" != review ]; then
      hq_die_validation "export: --today goes only with --kind reviews"
    fi
    batch="${kind}s"
    new=1
  else
    hq_die_validation "export: say what to export: --kind decisions|reviews, --ids, or --set (run human-queue.sh export --help)"
  fi
  if [ "$dry" -eq 1 ]; then
    new=0
  elif [ "$have_out" -eq 0 ]; then
    hq_die_validation "export: missing --out FILE.pdf"
  fi
  if [ "$have_out" -eq 1 ]; then
    hq__export_out_check "$out"
  fi
  hq_export_check_env
  hq_jq_find || hq_die_error "export: jq not found (PATH, /opt/homebrew/bin/jq, or /usr/bin/jq)"

  k=0
  while [ "$k" -lt "$n" ]; do
    pv[${#pv[@]}]=-v
    pv[${#pv[@]}]="hq_id_$((k + 1))=${ids[k]}"
    k=$((k + 1))
  done

  hq_db_connect
  hq_mktemp errf
  rc=0
  data=$(hq__export_sql "$batch" "$n" | hq_db_script -At \
           -v "hq_source=$batch" -v "hq_set_id=$setid" -v "hq_new=$new" -v "hq_dry=$dry" \
           -v "hq_level=$level" -v "hq_today=$today" -v "hq_tz=$(hq_desk_tz)" \
           ${pv[@]+"${pv[@]}"} 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -ne 2 ] && [ "$rc" -ne 143 ] && grep -q 'events_kind_check' "$errf"; then
      hq_die_error "export: the store is not migrated (run human-queue.sh migrate); nothing was recorded"
    fi
    hq_fail_unmigrated "$rc" "$errf" "export" 'sets_set_id_seq'
  fi
  hq_problem_check export "$data"
  if [ -z "$data" ]; then
    hq_die_error "export: the store returned nothing"
  fi
  if ! printf '%s' "$data" | hq_jq -e 'type == "object" and (.items | type) == "array"' >/dev/null 2>&1; then
    hq_die_error "export: the store returned malformed JSON"
  fi

  k=$(printf '%s' "$data" | hq_jq -r '.more')
  if [ "$k" != 0 ]; then
    printf 'human-queue: export: %s more items were left out (an export holds at most %s)\n' "$k" "$HQ_EXPORT_MAX" >&2
  fi

  if [ "$dry" -eq 0 ] && [ "$(printf '%s' "$data" | hq_jq -r '.count')" != 0 ]; then
    # Recorded, not yet on disk: from here to the file's rename, any exit
    # takes the record back (hq__export_cleanup, hq__export_fail).
    HQ_EXPORT_PENDING="$data"
    trap hq__export_cleanup EXIT
    HQ_EXPORT_WORK=$(mktemp -d "${TMPDIR:-/tmp}/human-queue-export.XXXXXX") \
      || hq__export_fail "$data" "create a scratch directory"
    chmod 700 "$HQ_EXPORT_WORK" 2>/dev/null || true
    if ! printf '%s' "$data" | hq_export_jq -r 'export_markdown' > "$HQ_EXPORT_WORK/export.md" \
       || ! printf '%s' "$data" | hq_export_jq -r 'export_text' > "$HQ_EXPORT_WORK/export.txt" \
       || ! printf '%s' "$data" | hq_export_jq -r 'export_html' > "$HQ_EXPORT_WORK/export.html"; then
      hq__export_fail "$data" "render the batch"
    fi
    path=$(hq__export_abs "$out")
    if hq_export_pdf renderer "$HQ_EXPORT_WORK/export.md" "$HQ_EXPORT_WORK/export.txt" \
         "$HQ_EXPORT_WORK/export.html" "$HQ_EXPORT_WORK/export.pdf" "$HQ_EXPORT_WORK"; then
      format=pdf
      hq__export_place "$HQ_EXPORT_WORK/export.pdf" "$path" \
        || hq__export_fail "$data" "write the PDF"
      HQ_EXPORT_PENDING=""
    else
      format=markdown
      mdpath="${path%.*}.md"
      hq__export_place "$HQ_EXPORT_WORK/export.md" "$mdpath" \
        || hq__export_fail "$data" "write the Markdown"
      HQ_EXPORT_PENDING=""
      warn="no PDF renderer produced a PDF ($HQ_EXPORT_TRIED); wrote the Markdown instead: $mdpath"
      path="$mdpath"
      printf 'human-queue: export: %s\n' "$warn" >&2
    fi
  fi

  if [ "$json" -eq 1 ]; then
    printf '%s' "$data" | hq_export_jq -c \
      --arg path "$path" --arg format "$format" --arg renderer "$renderer" --arg warning "$warn" '
      def orNull: if . == "" then null else . end;
      { path: ($path | orNull), format: ($format | orNull), renderer: ($renderer | orNull),
        dry_run, set_id, new_set, count, more,
        items: [ .items[] | {n, id} ], missing_summary: export_missing,
        warning: ($warning | orNull) }' \
      || hq_die_error "export: could not print the result"
  elif [ "$dry" -eq 1 ]; then
    printf '%s' "$data" | hq_export_jq -r '
      export_missing as $m | .level as $l
      | if .count == 0 then "nothing to export"
        else .items[] | "\(.n). \(.id)" + (if (.id | IN($m[])) then " · no level-\($l) summary" else "" end)
        end' \
      || hq_die_error "export: could not print the result"
  elif [ -z "$path" ]; then
    printf 'nothing to export\n'
  else
    printf '%s\n' "$path"
  fi
}
