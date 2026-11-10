# shellcheck shell=bash
# summary: note that the desk filed an issue, so its Review records it (filed OWNER/NAME NUMBER)
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/filings.sh
. "$HQ_BIN_DIR/lib/filings.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh filed — note that the desk filed an issue, so its Review
records it.

USAGE
  human-queue.sh filed OWNER/NAME NUMBER [--json]

ARGUMENTS
  OWNER/NAME  the repository the issue was filed in
  NUMBER      the new issue's number

BEHAVIOR
  The desk runs this right after its `idea:` intent files an issue
  (desk/skill/ideas.md). The issue comes back as a Review once sync-reviews
  finds it by its `_Captured via /issue-maker._` footer; this records that
  the desk filed it, as one `commented` event, note `filed from the desk`,
  on that Review.
  - Review already there: the event is recorded now.
  - Not yet: a pending filing is stored (the state key
    filed:<owner/name>:issue-<N>, lowercased), and sync-reviews records the
    event when it adds the Review, then deletes the key.
  Running it again is safe: a Review that already carries the event gets
  no second one, and a pending filing is stored once.

OUTPUT
  `noted R-12` (the event is on Review R-12) or `pending` (it waits for the
  Review). --json prints {"repo", "number", "status", "review"}, where
  status is "noted" or "pending" and review is the Review id or null.

EXIT CODES
  0  ok
  1  unexpected database failure
  4  a malformed OWNER/NAME or NUMBER, a missing or stray argument (before
     any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# The pending filing is inserted unless its Review already carries the event
# (a re-run after the note landed must not add a second one). Then every
# pending filing whose Review exists is consumed (one count line), and the
# last line says where this one stands: `pending`, or the Review's id.
hq__filed_sql() {
  cat <<'SQL'
INSERT INTO state (key, value)
SELECT 'filed:' || lower(:'hq_repo') || ':issue-' || :'hq_num',
       to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
 WHERE NOT EXISTS (
   SELECT 1 FROM items i JOIN events e ON e.item_id = i.id
    WHERE i.kind = 'review' AND lower(i.repo) = lower(:'hq_repo')
      AND i.key = 'issue-' || :'hq_num'
      AND e.kind = 'commented' AND e.note = 'filed from the desk')
ON CONFLICT (key) DO NOTHING;
SQL
  hq_sql_consume_filings
  cat <<'SQL'
SELECT coalesce(
  (SELECT 'pending' FROM state
    WHERE key = 'filed:' || lower(:'hq_repo') || ':issue-' || :'hq_num'),
  (SELECT id FROM items
    WHERE kind = 'review' AND lower(repo) = lower(:'hq_repo')
      AND key = 'issue-' || :'hq_num'),
  '!no pending filing or Review for that issue');
SQL
}

cmd_run() {
  local repo="" num="" json=0 n=0 errf out rc status review
  local repo_re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' num_re='^[1-9][0-9]{0,9}$'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --json)
        json=1
        ;;
      -*)
        hq_die_validation "filed: unknown $(hq_flag_name "$1") (run human-queue.sh filed --help)"
        ;;
      *)
        n=$((n + 1))
        case "$n" in
          1) repo="$1" ;;
          2) num="$1" ;;
          *) hq_die_validation "filed: too many arguments (expected OWNER/NAME NUMBER)" ;;
        esac
        ;;
    esac
    shift
  done
  if [ "$n" -lt 2 ]; then
    hq_die_validation "filed: expected OWNER/NAME NUMBER"
  fi
  if [ "${#repo}" -gt 140 ] || ! [[ $repo =~ $repo_re ]]; then
    hq_die_validation "filed: the repository must be OWNER/NAME"
  fi
  if ! [[ $num =~ $num_re ]]; then
    hq_die_validation "filed: the issue number must be a positive whole number"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__filed_sql | hq_db_script -At -v "hq_repo=$repo" -v "hq_num=$num" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "filed: nothing was recorded"
  fi
  # Two lines: the consumed count, then this filing's standing.
  status=$(printf '%s\n' "$out" | sed -n '$p')
  case "$status" in
    '!'*) hq_die_error "filed: ${status#!}" ;;
    pending) review="" ;;
    R-[0-9]*) review="$status"; status=noted ;;
    *) hq_die_error "filed: the store returned no standing for that issue" ;;
  esac
  if [ "$json" -eq 1 ]; then
    if [ -n "$review" ]; then review="\"$review\""; else review=null; fi
    printf '{"repo":"%s","number":%s,"status":"%s","review":%s}\n' "$repo" "$num" "$status" "$review"
    return 0
  fi
  if [ "$status" = noted ]; then
    printf 'noted %s\n' "${review}"
  else
    printf 'pending\n'
  fi
}
