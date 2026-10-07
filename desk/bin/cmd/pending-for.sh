# shellcheck shell=bash
# summary: list the answered Decisions a session asked, or answers parked for a PR or issue, not yet acknowledged
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh pending-for — answers waiting for a thread to read them.

USAGE
  human-queue.sh pending-for SESSION [--json]
  human-queue.sh pending-for --repo OWNER/NAME --key KEY [--json]
  human-queue.sh pending-for SESSION --repo OWNER/NAME --key KEY [--json]

ARGUMENTS
  SESSION           the asking session's id, as given to add --session (one
                    line, <= 200 characters)
  --repo OWNER/NAME the PR or issue a thread is working on, with --key: the
  --key KEY         same repo and key the capture hook stores (for example
                    issue-1781 or pr-1797). Both or neither.
  --json            print one JSON array of item objects instead ([] when
                    none)

BEHAVIOR
  SESSION lists the Decisions whose return address is SESSION and whose
  status is `answered` or `answer-parked`: answered and not yet
  acknowledged. --repo and --key list the Decisions of that PR or issue
  whose status is `answer-parked`, whoever asked them: answers the desk
  could not deliver because the asking thread had ended (issue #1781), kept
  for the next thread on that work. Given both, the two lists are merged,
  each item once.
  The thread reads each answer, acts on it, then runs `ack ID` (ideally
  `ack ID --answer TEXT`); an acknowledged item no longer appears. An item
  answered again after it was acknowledged appears again. Oldest answer
  first. Reading records no event.

OUTPUT
  Each item exactly as `get` prints it (the question in bold, the context as
  a numbered list, then `Answer: ...`), separated by blank lines; nothing at
  all when no answer is waiting.

EXIT CODES
  0  ok (including when nothing is waiting)
  1  unexpected database failure
  4  no session and no --repo/--key, an invalid session, repo, or key, only
     one of --repo and --key, or a stray argument (before any connection
     attempt)
  5  the session id or key looks like a secret (before any connection
     attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# Unacknowledged answers of one session (parked ones included), and the
# parked answers of one PR or issue; the latest `answered` event orders them,
# oldest first. An empty :'hq_session' or :'hq_key' matches nothing: 001's
# CHECKs keep both non-empty in every row.
hq__pending_where() {
  printf '%s' "i.kind = 'decision' AND ("
  printf '%s' "(i.session_id = :'hq_session' AND i.status IN ('answered', 'answer-parked'))"
  printf '%s' " OR (i.repo = :'hq_repo' AND i.key = :'hq_key' AND i.status = 'answer-parked'))"
}

hq__pending_order() {
  cat <<'SQL'
(SELECT max(e.id) FROM events e WHERE e.item_id = i.id AND e.kind = 'answered') NULLS FIRST,
i.created_at, i.id
SQL
}

hq__pending_sql() {
  if [ "$1" -eq 1 ]; then
    printf 'SELECT coalesce(jsonb_agg(%s ORDER BY\n' "$(hq_sql_item_json)"
    hq__pending_order
    printf "), '[]'::jsonb) FROM items i WHERE %s;\n" "$(hq__pending_where)"
  else
    printf '%s\n' "SELECT string_agg(r.rendered, E'\\n\\n' ORDER BY r.n) FROM ("
    printf '%s\n' "  SELECT"
    hq_sql_render_item
    printf '%s\n' "  AS rendered, row_number() OVER (ORDER BY"
    hq__pending_order
    printf '  ) AS n FROM items i WHERE %s\n' "$(hq__pending_where)"
    printf '%s\n' ") r HAVING count(*) > 0;"
  fi
}

cmd_run() {
  local session="" have=0 json=0 repo="" key="" have_repo=0 have_key=0 errf out rc

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --json)
        json=1
        shift
        ;;
      --repo|--key)
        if [ "$#" -lt 2 ]; then hq_die_validation "pending-for: $1 needs a value"; fi
        if [ "$1" = --repo ]; then
          if [ "$have_repo" -eq 1 ]; then hq_die_validation "pending-for: --repo given more than once"; fi
          have_repo=1
          repo="$2"
        else
          if [ "$have_key" -eq 1 ]; then hq_die_validation "pending-for: --key given more than once"; fi
          have_key=1
          key="$2"
        fi
        shift 2
        ;;
      -*) hq_die_validation "pending-for: unknown $(hq_flag_name "$1") (run human-queue.sh pending-for --help)" ;;
      *)
        if [ "$have" -eq 1 ]; then hq_die_validation "pending-for: takes one session id"; fi
        have=1
        session="$1"
        shift
        ;;
    esac
  done
  if [ "$have_repo" -ne "$have_key" ]; then
    hq_die_validation "pending-for: --repo and --key go together (the PR or issue a thread is working on)"
  fi
  if [ "$have" -eq 0 ] && [ "$have_repo" -eq 0 ]; then
    hq_die_validation "pending-for: missing session id or --repo/--key (run human-queue.sh pending-for --help)"
  fi
  if [ "$have" -eq 1 ]; then
    hq_check_text "pending-for: the session id" "$session" 200
    # The session id reaches psql's argv: a secret-shaped one stops here.
    hq_refuse_secret "pending-for: the session id" "$session"
  fi
  if [ "$have_repo" -eq 1 ]; then
    if [ "${#repo}" -gt 200 ] || ! [[ $repo =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
      hq_die_validation "pending-for: --repo must be OWNER/NAME (one slash, no spaces, <= 200 characters)"
    fi
    hq_refuse_control "pending-for: --repo" "$repo"
    hq_check_text "pending-for: --key" "$key" 200
    hq_refuse_secret "pending-for: --repo" "$repo"
    hq_refuse_secret "pending-for: --key" "$key"
  fi

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__pending_sql "$json" | hq_db_script -At -v "hq_session=$session" \
    -v "hq_repo=$repo" -v "hq_key=$key" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "pending-for"
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
}
