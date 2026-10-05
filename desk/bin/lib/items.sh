# shellcheck shell=bash
# desk/bin/lib/items.sh — shared code for the item subcommands (add, bump, get,
# list, show; issue #1775). Sourced by those command files after lib/common.sh
# and lib/db.sh; never executed. Bash 3.2 compatible.
#
# PUBLIC FUNCTIONS
#   hq_item_id VAR VALUE        canonical id (D-43, R-88) into VAR; d-43 is
#                               accepted; exits 4 when malformed
#   hq_parse_id_args CMD ID_VAR JSON_VAR ARGS...
#                               parses `CMD ID [--json]`; exits 4 on anything else
#   hq_check_text FIELD VALUE MAX
#                               VALUE is non-blank, one line, at most MAX
#                               characters; exits 4 naming FIELD otherwise
#   hq_check_timestamp FIELD VALUE
#                               ISO 8601 date and time WITH a time zone (an
#                               offset of at most 14:00 either way), and a
#                               real calendar date; exits 4 otherwise
#   hq_in_list VALUE WORDS      true when VALUE is one of the space-separated WORDS
#   hq_is_kind / hq_is_status / hq_is_impact VALUE
#                               true when VALUE is in 001's value set
#   hq_flag_name ARG            prints "option '--flag'" when ARG looks like a
#                               flag, else "argument": a stray value (which may
#                               be free text) is never echoed into a message
#   hq_sql_render_item          SQL expression rendering the items row `i`
#   hq_sql_render_events        SQL expression rendering the events of `i`
#   hq_sql_events_json          SQL expression: the events of `i` as JSON
#   hq_sql_item_order           ORDER BY list: parked, then impact, then age
#
# Lengths are checked with ${#value}: characters under a UTF-8 locale, bytes
# under bash 3.2 or a C locale. Bytes are never fewer than characters, so the
# CLI is at most stricter than the database's own CHECK constraints.

# The value sets of 001's CHECK constraints, mirrored so input is refused
# before any connection attempt.
HQ_ITEM_KINDS="decision review"
HQ_ITEM_STATUSES="open answered acknowledged reviewed flagged closed"
HQ_ITEM_IMPACTS="low medium high"

hq_is_kind()   { hq_in_list "$1" "$HQ_ITEM_KINDS"; }
hq_is_status() { hq_in_list "$1" "$HQ_ITEM_STATUSES"; }
hq_is_impact() { hq_in_list "$1" "$HQ_ITEM_IMPACTS"; }

hq_in_list() {
  case "$1" in
    ''|*[[:space:]]*) return 1 ;;
  esac
  case " $2 " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

hq_flag_name() {
  case "$1" in
    --[a-z]*)
      if [ "${#1}" -le 32 ] && [[ $1 =~ ^--[a-z][a-z-]*$ ]]; then
        printf "option '%s'" "$1"
        return 0
      fi
      ;;
  esac
  printf 'argument'
}

hq_item_id() {
  local hq__v="$2" hq__n
  case "$hq__v" in
    [DdRr]-[1-9]*) ;;
    *) hq_die_validation "invalid item id (expected D-<n> or R-<n>, for example D-43)" ;;
  esac
  hq__n="${hq__v#??}"
  # No length cap: 001's CHECK (^[DR]-[1-9][0-9]*$) has none, the sequences
  # reach 19 digits (bigint), and the id only ever travels as text.
  case "$hq__n" in
    *[!0-9]*) hq_die_validation "invalid item id (expected D-<n> or R-<n>, for example D-43)" ;;
  esac
  case "$hq__v" in
    [Dd]*) printf -v "$1" 'D-%s' "$hq__n" ;;
    *) printf -v "$1" 'R-%s' "$hq__n" ;;
  esac
}

# hq_parse_id_args CMD ID_VAR JSON_VAR ARGS... — the `CMD ID [--json]` shape
# shared by get and show. Stores the canonical id in ID_VAR and 0/1 in
# JSON_VAR; exits 4 on anything else. -h/--help anywhere prints the calling
# command's cmd_usage. Locals carry an hq__ prefix so the caller's variable
# names can never be shadowed.
hq_parse_id_args() {
  local hq__cmd="$1" hq__idvar="$2" hq__jsonvar="$3" hq__raw="" hq__have=0 hq__json=0
  shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --json)
        hq__json=1
        ;;
      -*) hq_die_validation "$hq__cmd: unknown $(hq_flag_name "$1") (run human-queue.sh $hq__cmd --help)" ;;
      *)
        if [ "$hq__have" -eq 1 ]; then hq_die_validation "$hq__cmd: takes one item id"; fi
        hq__have=1
        hq__raw="$1"
        ;;
    esac
    shift
  done
  if [ "$hq__have" -eq 0 ]; then
    hq_die_validation "$hq__cmd: missing item id (run human-queue.sh $hq__cmd --help)"
  fi
  hq_item_id "$hq__idvar" "$hq__raw"
  printf -v "$hq__jsonvar" '%s' "$hq__json"
}

hq_check_text() {
  local field="$1" value="$2" max="$3"
  case "$value" in
    *$'\n'*|*$'\r'*) hq_die_validation "$field must be a single line" ;;
  esac
  case "$value" in
    *[![:space:]]*) ;;
    *) hq_die_validation "$field is empty" ;;
  esac
  if [ "${#value}" -gt "$max" ]; then
    hq_die_validation "$field is longer than $max characters"
  fi
}

hq_check_timestamp() {
  local field="$1" v="$2" re y mo d h mi s tz oh om dim
  re='^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt ]([0-9]{2}):([0-9]{2})(:([0-9]{2})(\.[0-9]{1,6})?)?([Zz]|[+-][0-9]{2}(:?[0-9]{2})?)$'
  if ! [[ $v =~ $re ]]; then
    hq_die_validation "$field must be an ISO 8601 time with a time zone, for example 2026-10-05T18:00Z or 2026-10-05T14:00-04:00"
  fi
  y=$((10#${BASH_REMATCH[1]}))
  mo=$((10#${BASH_REMATCH[2]}))
  d=$((10#${BASH_REMATCH[3]}))
  h=$((10#${BASH_REMATCH[4]}))
  mi=$((10#${BASH_REMATCH[5]}))
  s="${BASH_REMATCH[7]}"
  tz="${BASH_REMATCH[9]}"
  s=$((10#${s:-0}))
  case "$mo" in
    2)
      dim=28
      if [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; }; then
        dim=29
      fi
      ;;
    4|6|9|11) dim=30 ;;
    *) dim=31 ;;
  esac
  if [ "$y" -lt 1 ] || [ "$mo" -lt 1 ] || [ "$mo" -gt 12 ] || [ "$d" -lt 1 ] || [ "$d" -gt "$dim" ] \
    || [ "$h" -gt 23 ] || [ "$mi" -gt 59 ] || [ "$s" -gt 59 ]; then
    hq_die_validation "$field is not a real date and time"
  fi
  case "$tz" in
    [Zz]) ;;
    *)
      oh=$((10#${tz:1:2}))
      om="${tz:3}"
      om="${om#:}"
      om=$((10#${om:-0}))
      # Real offsets span -12:00 to +14:00; accept up to 14:00 either way.
      if [ "$om" -gt 59 ] || [ $((oh * 60 + om)) -gt 840 ]; then
        hq_die_validation "$field has an out-of-range time-zone offset"
      fi
      ;;
  esac
}

# The SQL below lives in functions (not heredocs inside $(...)) because bash
# 3.2's command-substitution scanner does not understand here-documents.

# One item, as the operator reads it: a header line, the question in bold, the
# context as a numbered list, lettered options, the default and when it
# applies, one line of triage facts, and the answer once there is one. Lines
# with nothing to say are left out (concat_ws skips NULLs). Times are UTC.
hq_sql_render_item() {
  cat <<'SQL'
concat_ws(E'\n',
  concat_ws(' · ', i.id, i.kind, i.status, i.repo, i.key),
  '**' || i.question || '**',
  (SELECT string_agg(c.n || '. ' || c.line, E'\n' ORDER BY c.n)
     FROM unnest(i.context) WITH ORDINALITY AS c(line, n)),
  (SELECT 'Options: ' || string_agg(chr(64 + o.n::int) || '. ' || o.opt, ' · ' ORDER BY o.n)
     FROM unnest(i.options) WITH ORDINALITY AS o(opt, n)),
  CASE WHEN i.default_option IS NOT NULL OR i.default_at IS NOT NULL THEN
    'Default: ' || concat_ws(', at ',
      coalesce(chr(64 + array_position(i.options, i.default_option)) || '. ', '') || i.default_option,
      to_char(i.default_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'))
  END,
  concat_ws(' · ',
    'Asked ' || to_char(i.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'),
    'Impact: ' || i.impact_declared,
    'Cost: ' || i.cost,
    'Focus: ' || i.focus,
    CASE WHEN i.parked THEN 'Parked' END,
    'Session: ' || i.session_id),
  'Answer: ' || i.answer
)
SQL
}

# The events of item `i`, oldest first, one "- <time> <kind> — <note>" line each.
hq_sql_render_events() {
  cat <<'SQL'
(SELECT string_agg(
          '- ' || to_char(e.at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS "UTC"')
          || '  ' || e.kind || coalesce(' — ' || e.note, ''),
          E'\n' ORDER BY e.at, e.id)
   FROM events e
  WHERE e.item_id = i.id)
SQL
}

# The order items are listed in, per desk/DESIGN.md 4.2.5: parked agents
# first, then declared impact, then age.
hq_sql_item_order() {
  cat <<'SQL'
i.parked DESC,
CASE i.impact_declared WHEN 'high' THEN 0 WHEN 'medium' THEN 1 WHEN 'low' THEN 2 ELSE 3 END,
i.created_at, i.id
SQL
}

# The events of item `i` as a JSON array, oldest first.
hq_sql_events_json() {
  cat <<'SQL'
coalesce((SELECT jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.at, 'note', e.note)
                           ORDER BY e.at, e.id)
            FROM events e
           WHERE e.item_id = i.id), '[]'::jsonb)
SQL
}
