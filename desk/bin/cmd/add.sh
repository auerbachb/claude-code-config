# shellcheck shell=bash
# summary: add a Decision or Review (an open repeat of the same question is bumped instead)
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh add — put a Decision or a Review into the queue.

USAGE
  human-queue.sh add --kind decision|review --repo OWNER/NAME --key KEY
                     --question TEXT [OPTIONS]

REQUIRED (checked in this order; the first one missing is named, exit 4)
  --kind decision|review    decision: needs the operator and holds an agent (D-n)
                            review: landed work to look at (R-n)
  --repo OWNER/NAME         the repository the item belongs to
  --key KEY                 the PR or issue within the repo, for example pr-1775
                            (sessions die, PRs persist); one line, <= 200 chars
  --question TEXT           one sentence on one line, <= 500 characters;
                            printed in bold

OPTIONS
  --session ID              return address of the asking session (<= 200 chars)
  --context LINE            repeatable, up to 3; one line each, 600 characters
                            in total; printed as a numbered list
  --option TEXT             repeatable, up to 26, distinct; answered by letter
  --default TEXT            the recommended answer; must be one of the --option
                            values when options are given
  --default-at TIME         when the agent takes the default: ISO 8601 with a
                            time zone (offset at most 14:00 either way), for
                            example 2026-10-05T18:00Z (needs --default)
  --impact low|medium|high  declared impact
  --parked                  the asking agent is parked waiting on this item
  --cost TEXT               operator effort to answer, for example "~10 min"
  --focus TEXT              attention it needs, for example "no deep focus"
  Every flag except --context and --option may be given once.

DEDUPE
  When an OPEN item already has the same kind, repo, key, and question
  (compared ignoring case and runs of whitespace), add bumps it instead of
  creating a second item: the id is reused, a `bumped` event is recorded
  instead of `asked`, and the fields given on this call replace the stored
  ones (the session becomes the new return address); fields not given keep
  their values, except that new --option values without --default clear a
  stored default that is not among them (and its --default-at). The id and
  the question text never change. A question asked again after it was
  answered or closed is a new item.
  Concurrent adds are safe: id allocation and dedupe are serialized by the
  database (an advisory lock per question, backed by a unique index).

SECRETS
  Every value is checked for secret shapes before anything is sent: private
  keys; AWS, Google, Slack, GitHub, Stripe, sk-..., and Neon npg_... keys and
  tokens; JSON Web Tokens; bearer values; URLs with user:password@; labeled
  values such as password=... or token: ... . A match exits 5 naming the flag,
  never the value. This is a heuristic and cannot recognize every secret:
  never put one in the queue.

OUTPUT
  The item id (D-43, R-88) on stdout, for a new item and for a bump alike.
  Nothing on stderr on success. Events record state changes only (asked,
  bumped), never transcripts or diffs.

EXIT CODES
  0  ok
  1  unexpected database failure (for example the store is not migrated:
     run human-queue.sh migrate)
  4  validation error, reported before any connection attempt
  5  secret refused, before any connection attempt
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# hq__add_required FLAG VALUE — exits 4 when VALUE is empty or blank.
hq__add_required() {
  case "$2" in
    *[![:space:]]*) ;;
    *) hq_die_validation "add: missing required $1 (run human-queue.sh add --help)" ;;
  esac
}

# hq__sql_text_array PREFIX COUNT — SQL for a text[] built from the psql
# variables PREFIX_1 .. PREFIX_COUNT: ARRAY[:'p_1', :'p_2']::text[], or an
# empty array. Only variable references are generated; values never enter the
# SQL text.
hq__sql_text_array() {
  local i=1 refs=""
  if [ "$2" -eq 0 ]; then
    printf '%s' "'{}'::text[]"
    return 0
  fi
  while [ "$i" -le "$2" ]; do
    refs="$refs${refs:+, }:'$1_$i'"
    i=$((i + 1))
  done
  printf 'ARRAY[%s]::text[]' "$refs"
}

# hq__add_sql SEQUENCE PREFIX N_CONTEXT N_OPTIONS — the add transaction.
#   1. An advisory lock on (schema, kind, repo, key, question hash) serializes
#      concurrent adds of the same question.
#   2. The lookup is a NEW statement, so under READ COMMITTED it sees whatever
#      the previous lock holder committed.
#   3. New: allocate from the kind's sequence, insert the item and its `asked`
#      event. Existing open item: refresh the given fields and record `bumped`.
#      When the call replaces the options without giving --default, a stored
#      default that is not among the new options is cleared, with its time,
#      so the default always names an option it can be answered with.
# SEQUENCE and PREFIX come from a fixed mapping of the validated kind; every
# value travels as a psql variable.
hq__add_sql() {
  local seq="$1" prefix="$2" ctx_sql opt_sql ctx_set="" opt_set="" def_set
  ctx_sql=$(hq__sql_text_array hq_ctx "$3")
  opt_sql=$(hq__sql_text_array hq_opt "$4")
  if [ "$3" -gt 0 ]; then ctx_set="context = $ctx_sql,"; fi
  if [ "$4" -gt 0 ]; then
    opt_set="options = $opt_sql,"
    # In SET, default_option and default_at on the right are the stored values.
    # Every cast stays behind nullif: the planner folds constants even in a
    # CASE branch that never runs, so a bare ''::timestamptz would fail.
    def_set="default_option  = CASE WHEN nullif(:'hq_default', '') IS NOT NULL
                             OR default_option = ANY($opt_sql)
                           THEN coalesce(nullif(:'hq_default', ''), default_option) END,
    default_at      = CASE WHEN nullif(:'hq_default', '') IS NOT NULL
                             OR default_option = ANY($opt_sql)
                           THEN coalesce(nullif(:'hq_default_at', '')::timestamptz, default_at) END,"
  else
    def_set="default_option  = coalesce(nullif(:'hq_default', ''), default_option),
    default_at      = coalesce(nullif(:'hq_default_at', '')::timestamptz, default_at),"
  fi

  cat <<'SQL'
SET LOCAL lock_timeout TO '30s';
SELECT pg_advisory_xact_lock(hashtextextended(concat_ws(E'\x1f',
         'human-queue:add', :'hq_schema', :'hq_kind', :'hq_repo', :'hq_key',
         item_question_hash(:'hq_question')), 0)) AS hq_locked \gset
SELECT coalesce((SELECT id FROM items
                  WHERE kind = :'hq_kind' AND repo = :'hq_repo' AND key = :'hq_key'
                    AND item_question_hash(question) = item_question_hash(:'hq_question')
                    AND status = 'open'
                  LIMIT 1
                  FOR UPDATE), '') AS hq_found \gset
SELECT :'hq_found' = '' AS hq_is_new \gset
\if :hq_is_new
WITH new_item AS (
  INSERT INTO items (id, kind, repo, key, session_id, question, context, options,
                     default_option, default_at, impact_declared, parked, cost, focus)
  VALUES (
SQL
  printf "    '%s-' || nextval('%s'),\n" "$prefix" "$seq"
  printf '%s\n' "    :'hq_kind', :'hq_repo', :'hq_key', nullif(:'hq_session', ''), :'hq_question',"
  printf '    %s,\n    %s,\n' "$ctx_sql" "$opt_sql"
  cat <<'SQL'
    nullif(:'hq_default', ''), nullif(:'hq_default_at', '')::timestamptz,
    nullif(:'hq_impact', ''), :'hq_parked'::boolean,
    nullif(:'hq_cost', ''), nullif(:'hq_focus', ''))
  RETURNING id
), asked AS (
  INSERT INTO events (item_id, kind) SELECT id, 'asked' FROM new_item
)
SELECT id FROM new_item;
\else
WITH bumped AS (
  UPDATE items SET
SQL
  printf '    %s\n    %s\n    %s\n' "$ctx_set" "$opt_set" "$def_set"
  cat <<'SQL'
    session_id      = coalesce(nullif(:'hq_session', ''), session_id),
    impact_declared = coalesce(nullif(:'hq_impact', ''), impact_declared),
    cost            = coalesce(nullif(:'hq_cost', ''), cost),
    focus           = coalesce(nullif(:'hq_focus', ''), focus),
    parked          = parked OR :'hq_parked'::boolean
  WHERE id = :'hq_found'
  RETURNING id
), bump AS (
  INSERT INTO events (item_id, kind) SELECT id, 'bumped' FROM bumped
)
SELECT id FROM bumped;
\endif
SQL
}

cmd_run() {
  local kind="" repo="" key="" question="" session="" default="" default_at=""
  local impact="" cost="" focus="" parked=false seen=" " flag i j total
  local seq prefix errf out rc
  local -a ctx=() opts=() pv=()

  while [ "$#" -gt 0 ]; do
    flag="$1"
    case "$flag" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
      --parked|--kind|--repo|--key|--question|--session|--default|--default-at|--impact|--cost|--focus)
        case "$seen" in
          *" $flag "*) hq_die_validation "add: $flag given more than once" ;;
        esac
        seen="$seen$flag "
        ;;
      --context|--option) ;;
      *) hq_die_validation "add: unknown $(hq_flag_name "$flag") (run human-queue.sh add --help)" ;;
    esac
    if [ "$flag" = "--parked" ]; then
      parked=true
      shift
      continue
    fi
    if [ "$#" -lt 2 ]; then
      hq_die_validation "add: $flag needs a value"
    fi
    case "$flag" in
      --kind)       kind="$2" ;;
      --repo)       repo="$2" ;;
      --key)        key="$2" ;;
      --question)   question="$2" ;;
      --session)    session="$2" ;;
      --context)    ctx[${#ctx[@]}]="$2" ;;
      --option)     opts[${#opts[@]}]="$2" ;;
      --default)    default="$2" ;;
      --default-at) default_at="$2" ;;
      --impact)     impact="$2" ;;
      --cost)       cost="$2" ;;
      --focus)      focus="$2" ;;
    esac
    shift 2
  done

  # --- validation (exit 4), before any connection ---------------------------
  hq__add_required --kind "$kind"
  hq__add_required --repo "$repo"
  hq__add_required --key "$key"
  hq__add_required --question "$question"

  case "$kind" in
    decision) seq=items_decision_seq; prefix=D ;;
    review)   seq=items_review_seq;   prefix=R ;;
    *) hq_die_validation "add: --kind must be decision or review" ;;
  esac
  if [ "${#repo}" -gt 200 ] || ! [[ $repo =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
    hq_die_validation "add: --repo must be OWNER/NAME (one slash, no spaces, <= 200 characters)"
  fi
  hq_check_text "add: --key" "$key" 200
  hq_check_text "add: --question" "$question" 500
  if [ -n "$session" ]; then hq_check_text "add: --session" "$session" 200; fi

  if [ "${#ctx[@]}" -gt 3 ]; then
    hq_die_validation "add: --context may be given at most 3 times"
  fi
  total=0
  i=0
  while [ "$i" -lt "${#ctx[@]}" ]; do
    hq_check_text "add: --context $((i + 1))" "${ctx[i]}" 600
    total=$((total + ${#ctx[i]}))
    i=$((i + 1))
  done
  if [ "$total" -gt 600 ]; then
    hq_die_validation "add: --context lines are longer than 600 characters in total"
  fi

  if [ "${#opts[@]}" -gt 26 ]; then
    hq_die_validation "add: --option may be given at most 26 times"
  fi
  i=0
  while [ "$i" -lt "${#opts[@]}" ]; do
    hq_check_text "add: --option $((i + 1))" "${opts[i]}" 500
    j=0
    while [ "$j" -lt "$i" ]; do
      if [ "${opts[j]}" = "${opts[i]}" ]; then
        hq_die_validation "add: --option $((j + 1)) and --option $((i + 1)) are the same"
      fi
      j=$((j + 1))
    done
    i=$((i + 1))
  done

  if [ -n "$default" ]; then
    hq_check_text "add: --default" "$default" 500
    if [ "${#opts[@]}" -gt 0 ]; then
      i=0
      while [ "$i" -lt "${#opts[@]}" ] && [ "${opts[i]}" != "$default" ]; do
        i=$((i + 1))
      done
      if [ "$i" -eq "${#opts[@]}" ]; then
        hq_die_validation "add: --default must be one of the --option values"
      fi
    fi
  fi
  if [ -n "$default_at" ]; then
    if [ -z "$default" ]; then
      hq_die_validation "add: --default-at needs --default"
    fi
    hq_check_timestamp "add: --default-at" "$default_at"
  fi
  if [ -n "$impact" ] && ! hq_is_impact "$impact"; then
    hq_die_validation "add: --impact must be low, medium, or high"
  fi
  if [ -n "$cost" ]; then hq_check_text "add: --cost" "$cost" 200; fi
  if [ -n "$focus" ]; then hq_check_text "add: --focus" "$focus" 200; fi

  # --- secret refusal (exit 5), before any connection -----------------------
  hq_refuse_secret "add: --repo" "$repo"
  hq_refuse_secret "add: --key" "$key"
  hq_refuse_secret "add: --question" "$question"
  hq_refuse_secret "add: --session" "$session"
  i=0
  while [ "$i" -lt "${#ctx[@]}" ]; do
    hq_refuse_secret "add: --context $((i + 1))" "${ctx[i]}"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#opts[@]}" ]; do
    hq_refuse_secret "add: --option $((i + 1))" "${opts[i]}"
    i=$((i + 1))
  done
  hq_refuse_secret "add: --default" "$default"
  hq_refuse_secret "add: --cost" "$cost"
  hq_refuse_secret "add: --focus" "$focus"

  # --- write ----------------------------------------------------------------
  pv=(-v "hq_kind=$kind" -v "hq_repo=$repo" -v "hq_key=$key"
      -v "hq_question=$question" -v "hq_session=$session"
      -v "hq_default=$default" -v "hq_default_at=$default_at"
      -v "hq_impact=$impact" -v "hq_parked=$parked"
      -v "hq_cost=$cost" -v "hq_focus=$focus")
  i=0
  while [ "$i" -lt "${#ctx[@]}" ]; do
    pv[${#pv[@]}]=-v
    pv[${#pv[@]}]="hq_ctx_$((i + 1))=${ctx[i]}"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#opts[@]}" ]; do
    pv[${#pv[@]}]=-v
    pv[${#pv[@]}]="hq_opt_$((i + 1))=${opts[i]}"
    i=$((i + 1))
  done

  hq_db_connect
  hq_mktemp errf
  rc=0
  out=$(hq__add_sql "$seq" "$prefix" "${#ctx[@]}" "${#opts[@]}" \
    | hq_db_script -At "${pv[@]}" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -ne 2 ] && [ "$rc" -ne 143 ] \
      && grep -qE 'item_question_hash|items_(decision|review)_seq' "$errf" \
      && grep -q 'does not exist' "$errf"; then
      hq_die_error "add: the store is not migrated (run human-queue.sh migrate)"
    fi
    hq_db_fail "$rc" "$errf" "add: nothing was stored"
  fi
  if ! [[ $out =~ ^[DR]-[1-9][0-9]*$ ]]; then
    hq_die_error "add: the store returned no item id"
  fi
  printf '%s\n' "$out"
}
