# shellcheck shell=bash
# summary: record the operator's answer to a Decision (an `answered` event)
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh answer — record the answer to a Decision.

USAGE
  human-queue.sh answer ID ANSWER [--json]
  human-queue.sh answer ID --stdin [--json]

ARGUMENTS
  ID       a Decision id, for example D-43 (d-43 is accepted). Reviews (R-n)
           are not answered: use review or flag.
  ANSWER   the answer: a single letter naming one of the item's options
           (A = the first, case-insensitive), or free text. Free text may
           span several lines, at most 4000 characters, with no other
           control characters (tab aside); leading and trailing whitespace
           is dropped. Quote it.
  --stdin  read the answer from standard input instead (issue #1780): the
           text never passes through the caller's command line, so quotes,
           `$(...)`, backticks, and lines such as `2: B` arrive exactly as
           written.
           Same rules as ANSWER; input past 16000 bytes (4000 characters of
           at most four bytes each) or holding a NUL byte is refused. An
           answer that is exactly --json or --stdin goes this way, since
           both words are flags.
  --json   print {"id": "D-43", "answer": "...", "changed": true,
           "session": "..."} instead of the id: the stored answer (an
           option's text for a letter), whether this call changed it, and
           the item's return address (null when it has none), the session
           the desk wakes

BEHAVIOR
  A letter that names an option stores that option's text, so the asking
  thread reads the answer it offered; a letter past the last option exits 4.
  The item's status becomes `answered`, and one `answered` event is recorded
  (its note is `option B` when the answer was given by letter), in one
  transaction. The last answer wins: answering again replaces the answer and
  returns an acknowledged item to `answered`, so the asking thread sees the
  new answer in pending-for. Sending the answer the item already holds
  changes nothing and records nothing ("changed": false).

SECRETS
  The answer is checked for secret shapes before anything is sent; a match
  exits 5 and the text is never echoed.

OUTPUT
  The canonical item id on stdout (one JSON object with --json). Nothing on
  stderr on success.

EXIT CODES
  0  ok (including an unchanged answer)
  1  unexpected database failure, or --stdin could not read standard input
     (nothing recorded)
  4  invalid id, a Review id, or a missing, blank, over-long, or doubly
     given answer (before any connection attempt); no item has that id, or
     a letter is not one of its options (after connecting, nothing written)
  5  the answer looks like a secret (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# hq__answer_bytes TEXT — TEXT's length in bytes, whatever the locale.
hq__answer_bytes() {
  local LC_ALL=C
  printf '%s' "${#1}"
}

# hq__answer_read_stdin VAR — the answer from standard input into VAR. Read
# straight into the variable through a pipe, never a file, so a secret pasted
# by mistake is refused (exit 5) without having been written to disk. At most
# one byte past the cap is read: 4000 characters take at most 16000 bytes in
# UTF-8, so anything longer is too long whatever its encoding, and a runaway
# producer cannot fill memory. A NUL byte cannot live in a shell variable
# (bash would drop it silently), so it becomes \001, which hq_check_answer
# refuses as a control character. The trailing `x` keeps trailing newlines
# through the command substitution; hq_trim drops them afterwards. The
# substitution exits with the read's own status (pipefail covers head as well
# as tr), so a read that fails partway stores nothing rather than a truncated
# answer. Their own messages are dropped: the refusal below is the one line.
hq__answer_read_stdin() {
  local hq__v hq__cap=$((HQ_ANSWER_MAX * 4)) hq__rc=0
  hq__v=$(set -o pipefail
          head -c "$((hq__cap + 1))" 2>/dev/null | LC_ALL=C tr '\000' '\001' 2>/dev/null
          hq__s=$?
          printf x
          exit "$hq__s") || hq__rc=$?
  if [ "$hq__rc" -ne 0 ]; then
    hq_die_error "answer: standard input could not be read (exit $hq__rc); nothing was recorded"
  fi
  hq__v="${hq__v%x}"
  if [ "$(hq__answer_bytes "$hq__v")" -gt "$hq__cap" ]; then
    hq_die_validation "answer: the answer is longer than $HQ_ANSWER_MAX characters"
  fi
  printf -v "$1" '%s' "$hq__v"
}

cmd_run() {
  local id="" raw="" have_id=0 reply="" have_reply=0 stdin=0 json=0 a errf out rc

  for a in "$@"; do
    case "$a" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
    esac
  done
  # --json and --stdin are flags wherever they appear. Before the id any other
  # dash word is an unknown option; after it, it is the answer, so "-- not
  # now" is still an answer.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json)
        if [ "$json" -eq 1 ]; then hq_die_validation "answer: --json given more than once"; fi
        json=1
        ;;
      --stdin)
        if [ "$stdin" -eq 1 ]; then hq_die_validation "answer: --stdin given more than once"; fi
        stdin=1
        ;;
      *)
        if [ "$have_id" -eq 0 ]; then
          case "$1" in
            -*) hq_die_validation "answer: unknown $(hq_flag_name "$1") (run human-queue.sh answer --help)" ;;
          esac
          raw="$1"
          have_id=1
        elif [ "$have_reply" -eq 0 ]; then
          reply="$1"
          have_reply=1
        else
          hq_die_validation "answer: takes one item id and one answer (quote an answer that has spaces)"
        fi
        ;;
    esac
    shift
  done
  if [ "$have_id" -eq 0 ]; then
    hq_die_validation "answer: missing item id (run human-queue.sh answer --help)"
  fi
  if [ "$stdin" -eq 1 ] && [ "$have_reply" -eq 1 ]; then
    hq_die_validation "answer: give the answer as an argument or with --stdin, not both"
  fi
  if [ "$stdin" -eq 0 ] && [ "$have_reply" -eq 0 ]; then
    hq_die_validation "answer: missing answer (run human-queue.sh answer --help)"
  fi
  hq_item_id id "$raw"
  hq_require_kind answer "$id" decision
  if [ "$stdin" -eq 1 ]; then
    hq__answer_read_stdin reply
  fi
  hq_trim reply "$reply"
  hq_check_answer "answer: the answer" "$reply"
  hq_refuse_secret "answer: the answer" "$reply"

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq_sql_answer id 1 "$json" \
    | hq_db_script -At -v "hq_id_1=$id" -v "hq_reply_1=$reply" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "answer: nothing was recorded"
  fi
  hq_problem_check answer "$out"
  if [ "$json" -eq 1 ]; then
    case "$out" in
      '{'*) ;;
      *) hq_die_error "answer: the store returned no item" ;;
    esac
  elif [ "$out" != "$id" ]; then
    hq_die_error "answer: the store returned no item id"
  fi
  printf '%s\n' "$out"
}
