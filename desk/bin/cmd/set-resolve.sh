# shellcheck shell=bash
# summary: map a reply such as "2: B" or "1: A, 2: C" to the items of a set and answer them
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
human-queue.sh set-resolve — answer the items of a set by number.

USAGE
  human-queue.sh set-resolve REPLY [--set ID] [--json]

ARGUMENTS
  REPLY     the operator's reply, quoted: one or more `N: ANSWER` pairs,
            where N is an item's number in the set. Examples:
              "2: B"
              "1: A, 2: C"
              "1: yes, but after CI; 3: use the staging database"
            A new pair starts at the beginning, or after a comma, semicolon,
            or line break that is followed by `N:`. Any other text continues
            the answer before it, so commas and line breaks inside an answer
            are kept. Each ANSWER is what `answer` takes: a letter naming one
            of the item's options, or free text (<= 4000 characters).
  --set ID  the set to resolve against (as set-open printed it). Default: the
            latest set. A caller that holds a set id should pass it.
  --json    print {"set_id": N, "answers": [{"n", "id", "answer",
            "changed"}, ...]}

BEHAVIOR
  Every pair is checked before anything is written: each number must be in
  the set, and each item must be a Decision with the option a letter names.
  Then all answers are written in ONE transaction, exactly as `answer`
  writes them (one `answered` event per item that changed, note
  `set N #k`). If any pair is wrong, nothing is written. A pair that repeats
  the answer an item already holds changes nothing.

OUTPUT
  One line per pair: `2. D-43 answered`, or `... unchanged (...)`. Nothing
  on stderr on success.

EXIT CODES
  0  ok
  1  unexpected database failure
  4  a malformed reply, a number given twice, a blank or over-long answer,
     or a bad argument (before any connection attempt); no set, a number not
     in the set, a Review, or a letter that is not one of the options (after
     connecting, nothing written)
  5  an answer looks like a secret (before any connection attempt)
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# hq__sr_parse REPLY — splits REPLY into HQ_SR_POS[] / HQ_SR_ANS[] (the
# answers trimmed). Splits only at `,` `;` or a newline; each segment that
# starts with `N:` opens a pair, any other segment continues the answer
# before it (with its separator), and a blank segment is dropped. Parameter
# expansion, not a per-character loop, so a 4000-character reply stays fast
# on bash 3.2. Exits 4 on malformed input; the reply is never echoed.
HQ_SR_POS=()
HQ_SR_ANS=()
hq__sr_parse() {
  local rest="$1" seg sep="" next nl=$'\n' more n=0 pos k ans
  local re='^[[:space:]]*([0-9]+)[[:space:]]*:(.*)$'
  HQ_SR_POS=()
  HQ_SR_ANS=()
  while :; do
    seg="${rest%%[,;"$nl"]*}"
    if [ "${#seg}" -lt "${#rest}" ]; then
      next="${rest:${#seg}:1}"
      rest="${rest:$((${#seg} + 1))}"
      more=1
    else
      next=""
      rest=""
      more=0
    fi
    if [[ $seg =~ $re ]]; then
      pos="${BASH_REMATCH[1]}"
      # Leading zeros are dropped; more than two digits can never be a number
      # in a set of at most 99.
      while [ "${#pos}" -gt 1 ] && [ "${pos#0}" != "$pos" ]; do pos="${pos#0}"; done
      if [ "${#pos}" -gt 2 ] || [ "$pos" -lt 1 ]; then
        hq_die_validation "set-resolve: item numbers run from 1 to 99"
      fi
      k=0
      while [ "$k" -lt "$n" ]; do
        if [ "${HQ_SR_POS[k]}" = "$pos" ]; then
          hq_die_validation "set-resolve: number $pos is answered twice"
        fi
        k=$((k + 1))
      done
      HQ_SR_POS[n]="$pos"
      HQ_SR_ANS[n]="${BASH_REMATCH[2]}"
      n=$((n + 1))
    else
      case "$seg" in
        *[![:space:]]*)
          if [ "$n" -eq 0 ]; then
            hq_die_validation "set-resolve: expected a reply such as '2: B' or '1: A, 2: C'"
          fi
          HQ_SR_ANS[n-1]="${HQ_SR_ANS[n-1]}$sep$seg"
          ;;
      esac
    fi
    sep="$next"
    [ "$more" -eq 1 ] || break
  done
  if [ "$n" -eq 0 ]; then
    hq_die_validation "set-resolve: expected a reply such as '2: B' or '1: A, 2: C'"
  fi
  k=0
  while [ "$k" -lt "$n" ]; do
    hq_trim ans "${HQ_SR_ANS[k]}"
    HQ_SR_ANS[k]="$ans"
    hq_check_answer "set-resolve: the answer to $((HQ_SR_POS[k]))" "${HQ_SR_ANS[k]}"
    hq_refuse_secret "set-resolve: the answer to $((HQ_SR_POS[k]))" "${HQ_SR_ANS[k]}"
    k=$((k + 1))
  done
}

cmd_run() {
  local reply="" have=0 set_arg="" have_set=0 json=0 k errf out rc
  local -a pv=()

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
      --set)
        if [ "$have_set" -eq 1 ]; then hq_die_validation "set-resolve: --set given more than once"; fi
        if [ "$#" -lt 2 ]; then hq_die_validation "set-resolve: --set needs a value"; fi
        have_set=1
        set_arg="$2"
        shift 2
        ;;
      -*) hq_die_validation "set-resolve: unknown $(hq_flag_name "$1") (run human-queue.sh set-resolve --help)" ;;
      *)
        if [ "$have" -eq 1 ]; then
          hq_die_validation "set-resolve: takes one reply (quote it: \"1: A, 2: C\")"
        fi
        have=1
        reply="$1"
        shift
        ;;
    esac
  done
  if [ "$have" -eq 0 ]; then
    hq_die_validation "set-resolve: missing reply (run human-queue.sh set-resolve --help)"
  fi
  if [ "$have_set" -eq 1 ]; then
    case "$set_arg" in
      [1-9]*) ;;
      *) hq_die_validation "set-resolve: --set must be a set id such as 12" ;;
    esac
    case "$set_arg" in
      *[!0-9]*) hq_die_validation "set-resolve: --set must be a set id such as 12" ;;
    esac
    if [ "${#set_arg}" -gt 18 ]; then
      hq_die_validation "set-resolve: --set is not a set id"
    fi
  fi
  hq__sr_parse "$reply"

  pv=(-v "hq_set=$set_arg")
  k=0
  while [ "$k" -lt "${#HQ_SR_POS[@]}" ]; do
    pv[${#pv[@]}]=-v
    pv[${#pv[@]}]="hq_pos_$((k + 1))=${HQ_SR_POS[k]}"
    pv[${#pv[@]}]=-v
    pv[${#pv[@]}]="hq_reply_$((k + 1))=${HQ_SR_ANS[k]}"
    k=$((k + 1))
  done

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq_sql_answer set "${#HQ_SR_POS[@]}" "$json" \
    | hq_db_script -At "${pv[@]}" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "set-resolve: nothing was recorded"
  fi
  hq_problem_check set-resolve "$out" "; no answer was written"
  if [ -z "$out" ]; then
    hq_die_error "set-resolve: the store returned nothing"
  fi
  printf '%s\n' "$out"
}
