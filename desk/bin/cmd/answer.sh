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
  human-queue.sh answer ID ANSWER

ARGUMENTS
  ID      a Decision id, for example D-43 (d-43 is accepted). Reviews (R-n)
          are not answered: use review or flag.
  ANSWER  the answer: a single letter naming one of the item's options
          (A = the first, case-insensitive), or free text. Free text may span
          several lines, at most 4000 characters, with no other control
          characters (tab aside); leading and trailing whitespace is
          dropped. Quote it.

BEHAVIOR
  A letter that names an option stores that option's text, so the asking
  thread reads the answer it offered; a letter past the last option exits 4.
  The item's status becomes `answered`, and one `answered` event is recorded
  (its note is `option B` when the answer was given by letter), in one
  transaction. The last answer wins: answering again replaces the answer and
  returns an acknowledged item to `answered`, so the asking thread sees the
  new answer in pending-for. Sending the answer the item already holds
  changes nothing and records nothing.

SECRETS
  The answer is checked for secret shapes before anything is sent; a match
  exits 5 and the text is never echoed.

OUTPUT
  The canonical item id on stdout. Nothing on stderr on success.

EXIT CODES
  0  ok (including an unchanged answer)
  1  unexpected database failure
  4  invalid id, a Review id, or a missing or blank answer (before any
     connection attempt); no item has that id, or a letter is not one of its
     options (after connecting, nothing written)
  5  the answer looks like a secret (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

cmd_run() {
  local id="" reply="" errf out rc
  hq_parse_id_value answer id reply answer "$@"
  hq_require_kind answer "$id" decision
  hq_trim reply "$reply"
  hq_check_answer "answer: the answer" "$reply"
  hq_refuse_secret "answer: the answer" "$reply"

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq_sql_answer id 1 0 \
    | hq_db_script -At -v "hq_id_1=$id" -v "hq_reply_1=$reply" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "answer: nothing was recorded"
  fi
  hq_problem_check answer "$out"
  if [ "$out" != "$id" ]; then
    hq_die_error "answer: the store returned no item id"
  fi
  printf '%s\n' "$out"
}
