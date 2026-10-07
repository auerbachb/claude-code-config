# shellcheck shell=bash
# summary: list the answered Decisions whose last wake-up failed and that have a retry left
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh wake-due — the answers due a wake-up retry.

USAGE
  human-queue.sh wake-due [--min-age SECONDS] [--json]

ARGUMENTS
  --min-age SECONDS  only answers whose last failed wake-up is at least this
                     old, on the database's clock (a whole number, 0 to
                     86400; default 0). The desk passes 30 when it handles a
                     retry, so two queued retry events never retry one answer
                     twice.
  --json             print one JSON array instead ([] when none is due)

BEHAVIOR
  Lists the Decisions whose status is `answered`, that have a return
  address, whose latest wake-up since their latest answer was a failure
  (`wake-failed`), and that have a retry left: at most 3 retries follow the
  first attempt (issue #1781). The desk's tick loop runs this after every
  tick and prints `desk-tick GEN retry D-43 ...`; the desk then wakes each
  one again and records the result with `wake`, which parks the answer
  (`answer-parked`) when its last retry fails too. A successful wake-up, an
  acknowledgement, a parked answer, or a new answer (which starts a new
  count) takes an item off this list. Oldest failure first. Read-only:
  records nothing. It sees only recorded wake-ups: an attempt whose `wake`
  record failed is not listed until the desk records it again.

OUTPUT
  One line per answer: `D-43 · retry 2 of 3 · session abc`. Nothing at all
  when none is due. --json: [{"id": "D-43", "session": "abc",
  "failures": 2, "retry": 2}], where retry is the number this attempt
  will be (the failures so far, the first attempt included).

EXIT CODES
  0  ok (including when nothing is due)
  1  unexpected database failure
  4  a bad --min-age or a stray argument (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# hq__wake_due_sql JSON — the answered Decisions with a failed last wake-up
# and a retry left. Every count and the last wake event are taken after the
# item's latest `answered` event, so a new answer starts afresh.
hq__wake_due_sql() {
  cat <<'SQL'
WITH w AS (
  SELECT i.id, i.session_id,
         coalesce((SELECT max(a.id) FROM events a
                    WHERE a.item_id = i.id AND a.kind = 'answered'), 0) AS ans_id
    FROM items i
   WHERE i.kind = 'decision' AND i.status = 'answered' AND i.session_id IS NOT NULL
), x AS (
  SELECT w.id, w.session_id,
         (SELECT count(*) FROM events e
           WHERE e.item_id = w.id AND e.kind = 'wake-failed' AND e.id > w.ans_id)::int AS failures,
         l.kind AS last_kind, l.at AS last_at, l.id AS last_id
    FROM w
    LEFT JOIN LATERAL (
      SELECT e.kind, e.at, e.id FROM events e
       WHERE e.item_id = w.id AND e.kind IN ('woken', 'wake-failed') AND e.id > w.ans_id
       ORDER BY e.id DESC
       LIMIT 1) l ON true
), due AS (
  SELECT x.* FROM x
   WHERE x.last_kind = 'wake-failed'
     AND x.failures BETWEEN 1 AND :hq_retries
     AND x.last_at <= statement_timestamp() - make_interval(secs => :hq_min_age)
)
SQL
  if [ "$1" -eq 1 ]; then
    cat <<'SQL'
SELECT coalesce(jsonb_agg(jsonb_build_object('id', due.id, 'session', due.session_id,
                                             'failures', due.failures, 'retry', due.failures)
                          ORDER BY due.last_id), '[]'::jsonb)
  FROM due;
SQL
  else
    cat <<'SQL'
SELECT string_agg(due.id || ' · retry ' || due.failures || ' of ' || :hq_retries
                  || ' · session ' || due.session_id, E'\n' ORDER BY due.last_id)
  FROM due
HAVING count(*) > 0;
SQL
  fi
}

cmd_run() {
  local json=0 min_age=0 have_age=0 errf out rc

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
      --min-age)
        if [ "$have_age" -eq 1 ]; then hq_die_validation "wake-due: --min-age given more than once"; fi
        if [ "$#" -lt 2 ]; then hq_die_validation "wake-due: --min-age needs a value"; fi
        have_age=1
        min_age="$2"
        shift 2
        ;;
      -*) hq_die_validation "wake-due: unknown $(hq_flag_name "$1") (run human-queue.sh wake-due --help)" ;;
      *) hq_die_validation "wake-due: takes no arguments besides its options (run human-queue.sh wake-due --help)" ;;
    esac
  done
  case "$min_age" in
    ''|*[!0-9]*) hq_die_validation "wake-due: --min-age must be a whole number of seconds from 0 to 86400" ;;
  esac
  if [ "${#min_age}" -gt 5 ] || [ "$((10#$min_age))" -gt 86400 ]; then
    hq_die_validation "wake-due: --min-age must be a whole number of seconds from 0 to 86400"
  fi
  min_age=$((10#$min_age))

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__wake_due_sql "$json" | hq_db_script -At -v "hq_retries=$(hq_wake_retries)" \
    -v "hq_min_age=$min_age" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "wake-due"
  fi
  if [ "$json" -eq 1 ] && [ -z "$out" ]; then
    hq_die_error "wake-due: the store returned nothing"
  fi
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  fi
}
