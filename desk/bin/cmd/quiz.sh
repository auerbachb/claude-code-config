# shellcheck shell=bash
# summary: read up to three reviewed summaries for a quiz, or increment today's completion count

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/github.sh
. "$HQ_BIN_DIR/lib/github.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"

cmd_usage() {
  cat <<'USAGE'
human-queue.sh quiz — support an operator-requested comprehension check.

  human-queue.sh quiz sources R-ID [R-ID ...]
  human-queue.sh quiz complete

Sources returns up to three reviewed items with cached level-2 summaries
as JSON, in the given batch order. Complete atomically increments the count
for the current America/New_York day. No quiz material is written.
USAGE
}

hq__quiz_sources() {
  # The comma-separated canonical Review IDs contain only R, digits and
  # hyphens. Bind them through the script to avoid a process argument limit.
  printf '%s\n' "\\set hq_ids '$1'"
  cat <<'SQL'
WITH batch AS (
  SELECT id, min(ord) AS ord
  FROM unnest(string_to_array(:'hq_ids', ',')) WITH ORDINALITY AS b(id, ord)
  GROUP BY id
), sources AS (
  SELECT i.id, i.repo, i.key, i.summary_l2, b.ord
  FROM batch b JOIN items i ON i.id = b.id
  WHERE i.kind = 'review' AND i.status = 'reviewed' AND btrim(i.summary_l2) <> ''
  ORDER BY b.ord LIMIT 3
)
SELECT coalesce(jsonb_agg(to_jsonb(s) - 'ord' ORDER BY s.ord), '[]') FROM sources s;
SQL
}

hq__quiz_complete() {
  cat <<'SQL'
INSERT INTO state (key, value)
VALUES ('quiz_count:' || (now() AT TIME ZONE :'hq_tz')::date, '1')
ON CONFLICT (key) DO UPDATE SET value = (state.value::bigint + 1)::text
RETURNING value;
SQL
}

cmd_run() {
  local raw id ids="" out errf rc=0 query
  case "${1:-}" in
    sources)
      shift
      [ "$#" -ge 1 ] || hq_die_validation "quiz: supply at least one reviewed ID"
      for raw in "$@"; do
        hq_item_id id "$raw"
        hq_require_kind quiz "$id" review
        ids="$ids${ids:+,}$id"
      done
      hq_jq_find || hq_die_error "quiz: jq not found"
      query=hq__quiz_sources
      ;;
    complete)
      [ "$#" -eq 1 ] || hq_die_validation "quiz: complete takes no arguments"
      query=hq__quiz_complete
      ;;
    *) hq_die_validation "quiz: expected sources or complete (run human-queue.sh quiz --help)" ;;
  esac

  hq_db_connect
  hq_mktemp errf
  out=$("$query" "$ids" | hq_db_script -At -v "hq_tz=$(hq_desk_tz)" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then hq_db_fail "$rc" "$errf" "quiz: store operation failed"; fi
  if [ "$query" = hq__quiz_sources ]; then
    printf '%s\n' "$out" | hq_jq -c -L "$HQ_DESK_DIR/skill" 'include "desk"; map(. + {link: item_link})'
  else
    printf '%s\n' "$out"
  fi
}
