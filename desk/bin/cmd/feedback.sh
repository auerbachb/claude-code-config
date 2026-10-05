# shellcheck shell=bash
# summary: tag how an item's interrupt landed, to tune the desk (a `feedback` event)
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh feedback — tag how an item's interrupt landed.

USAGE
  human-queue.sh feedback ID TAG

ARGUMENTS
  ID   any item id, for example D-43 or R-88 (d-43 is accepted)
  TAG  a lowercase tag of words joined by hyphens, <= 60 characters. The
       starting tags are:
         not-important           this should not have interrupted me
         should-have-defaulted   the agent should have taken its default
         good-interrupt          this was worth the interruption
       Others are accepted, so the set can grow without a change here.

BEHAVIOR
  Records one `feedback` event whose note is TAG. The desk reads these to
  tune when items reach the operator; the item itself is not changed and
  `tick` does not report it again. Giving an item a tag it already has
  changes nothing and records nothing; an item can carry several tags.

OUTPUT
  The canonical item id on stdout. Nothing on stderr on success.

EXIT CODES
  0  ok (including a tag the item already has)
  1  unexpected database failure
  4  invalid id, a missing or malformed tag, or a stray argument (before
     any connection attempt); no item has that id (after connecting)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

hq__feedback_sql() {
  hq_sql_lock_item "NO KEY UPDATE"
  cat <<'SQL'
SELECT EXISTS (SELECT 1 FROM events
                WHERE item_id = :'hq_id' AND kind = 'feedback' AND note = :'hq_tag') AS hq_dup \gset
WITH ev AS (
  INSERT INTO events (item_id, kind, note)
  SELECT id, 'feedback', :'hq_tag' FROM items
   WHERE id = :'hq_id' AND NOT :'hq_dup'::boolean
)
SELECT CASE WHEN :hq_n = 0 THEN '!no item ' || :'hq_id' ELSE :'hq_id' END;
SQL
}

# hq__feedback_tag_ok TAG — lowercase ASCII words joined by single hyphens.
# LC_ALL=C so [a-z] is a byte range, never a locale's collation range.
hq__feedback_tag_ok() {
  local LC_ALL=C re='^[a-z][a-z0-9]*(-[a-z0-9]+)*$'
  [ "${#1}" -le 60 ] && [[ $1 =~ $re ]]
}

cmd_run() {
  local id="" tag="" errf out rc
  hq_parse_id_value feedback id tag tag "$@"
  if ! hq__feedback_tag_ok "$tag"; then
    hq_die_validation "feedback: the tag must be lowercase words joined by hyphens, <= 60 characters (for example should-have-defaulted)"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__feedback_sql | hq_db_script -At -v "hq_id=$id" -v "hq_tag=$tag" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "feedback: nothing was recorded"
  fi
  hq_problem_check feedback "$out"
  if [ "$out" != "$id" ]; then
    hq_die_error "feedback: the store returned no item id"
  fi
  printf '%s\n' "$out"
}
