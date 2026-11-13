# shellcheck shell=bash
# summary: log unplanned work stoppages (record, resume, why, correct, list, flush) in the desk database
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_BIN_DIR.

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/github.sh
. "$HQ_BIN_DIR/lib/github.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"
# shellcheck source=../lib/stoppages.sh
. "$HQ_BIN_DIR/lib/stoppages.sh"

cmd_usage() {
  cat <<'EOF'
human-queue.sh stoppage — one short entry for every unplanned work stoppage
(issue #2292). The entries live in the desk's private database only; nothing
is written to GitHub or to any file in a repository.

USAGE
  human-queue.sh stoppage record  --thread ID [--repo OWNER/NAME] [--ref issue#N|pr#N]
                                  [--cause CAUSE] [--evidence TEXT] [--at TIME]
                                  [--source hook|go-on|manual] [--json]
  human-queue.sh stoppage resume  --thread ID [--at TIME]
  human-queue.sh stoppage why     [--thread ID] [--json]
  human-queue.sh stoppage correct (ID | --thread ID) --cause CAUSE [--note TEXT]
  human-queue.sh stoppage list    [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--json]
  human-queue.sh stoppage flush

ENTRY FIELDS
  stop time, thread (a session id), repo, issue or PR, cause, one line of
  evidence (at most 200 characters, never transcript text), and the idle time,
  added by `resume` when the work picks up again. Nothing else is stored.
  CAUSE is one of: out_of_work, waiting_on_review, waiting_on_operator,
  usage_limit, token_exhaustion, blocked_by_error, crash, unknown. A missing
  or unrecognised cause is stored as `unknown`, never dropped.

WHAT IS A STOPPAGE
  A turn that ends with nothing running, nothing armed to wake it, and the
  assigned work not finished. A planned stop (/pause, /end, a declared leave
  time) is not one: the Stop hook (desk/hooks/stoppage.sh) never records it.
  The hook infers the causes it can see; an orchestrator or `/go-on` records
  the rest (`out_of_work`, `crash`) with `record --cause`.

COMMANDS
  record   store one entry. TIME defaults to now (UTC, like 2026-11-13T09:30:00Z).
           The same thread and time again stores nothing new. When the
           database cannot be reached the entry is kept in
           ~/.claude/desk-stoppages (HUMAN_QUEUE_STOPPAGE_DIR) and sent by a
           later call; this never fails the caller. Prints `stored ID`, or
           `kept locally` with the reason.
  resume   the thread's work started again: closes its open entries with the
           idle time from stop to TIME. Kept locally the same way.
  why      the thread's latest entry (default thread: $CLAUDE_SESSION_ID), the
           answer to "why weren't you working?". An entry still only kept
           locally is shown and marked.
  correct  save the operator's correction against an entry, by id or the
           thread's latest. The original cause is kept; list counts the
           correction.
  list     entries from FROM to TO inclusive (the desk's calendar,
           America/New_York; default: the last 7 days), grouped by cause with
           idle time totalled, for the weekly review. An entry not yet resumed
           counts as a stoppage and adds no idle time. --json prints the
           grouped object.
  flush    send every kept entry now.

ENVIRONMENT
  HUMAN_QUEUE_STOPPAGE_DIR  where unsent entries are kept
                            (default ~/.claude/desk-stoppages)

EXIT CODES
  0  ok (record and resume also when the entry was kept locally)
  1  unexpected database failure (list, why-less reads, correct; for example
     the store is not migrated: run human-queue.sh migrate)
  4  bad or missing argument, or no entry to correct (before any change)
  5  secret refused (evidence or note looks like a credential)
  7  database unset or unreachable (list and correct; within two seconds,
     one line on stderr)
EOF
}

# hq__stp_need VALUE_COUNT NAME — an option's value must be present.
hq__stp_need() {
  if [ "$1" -lt 2 ]; then
    hq_die_validation "stoppage: $2 needs a value (run human-queue.sh stoppage --help)"
  fi
}

hq__stp_check_thread() {
  local hq__re='^[A-Za-z0-9_.:-]{1,200}$'
  if ! [[ ${1:-} =~ $hq__re ]]; then
    hq_die_validation "stoppage: --thread must be a session id (letters, digits, and _ . : -)"
  fi
}

hq__stp_check_ref() {
  local hq__re='^(issue|pr)#[1-9][0-9]{0,8}$'
  if [ -n "$1" ] && ! [[ $1 =~ $hq__re ]]; then
    hq_die_validation "stoppage: --ref must look like issue#2292 or pr#2300"
  fi
}

hq__stp_check_repo() {
  local hq__re='^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$'
  if [ "$1" != "unknown" ] && ! [[ $1 =~ $hq__re ]]; then
    hq_die_validation "stoppage: --repo must look like owner/name"
  fi
}

hq__stp_record() {
  local thread="${CLAUDE_SESSION_ID:-}" repo="unknown" ref="" cause="" ev="" at="" src="manual" json=0
  local cause_in="" key out rc=0 payload note=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --thread) hq__stp_need "$#" --thread; thread="$2"; shift 2 ;;
      --repo) hq__stp_need "$#" --repo; repo="$2"; shift 2 ;;
      --ref) hq__stp_need "$#" --ref; ref="$2"; shift 2 ;;
      --cause) hq__stp_need "$#" --cause; cause_in="$2"; shift 2 ;;
      --evidence) hq__stp_need "$#" --evidence; ev="$2"; shift 2 ;;
      --at) hq__stp_need "$#" --at; at="$2"; shift 2 ;;
      --source) hq__stp_need "$#" --source; src="$2"; shift 2 ;;
      -*) hq_die_validation "stoppage record: unknown $(hq_flag_name "$1") (run human-queue.sh stoppage --help)" ;;
      *) hq_die_validation "stoppage record: takes options only (run human-queue.sh stoppage --help)" ;;
    esac
  done
  hq__stp_check_thread "$thread"
  hq__stp_check_repo "$repo"
  hq__stp_check_ref "$ref"
  case "$src" in
    hook|go-on|manual) ;;
    *) hq_die_validation "stoppage: --source must be hook, go-on, or manual" ;;
  esac
  if [ -z "$at" ]; then hq_stp_now at; fi
  hq_stp_check_time "stoppage" "--at" "$at"
  hq_stp_check_cause cause "$cause_in"
  if [ -n "$cause_in" ] && [ "$cause" = unknown ] && [ "$cause_in" != unknown ]; then
    # Never drop an entry over its cause: keep it as `unknown` and say why.
    note="unrecognised cause; "
  fi
  if [ -z "$ev" ]; then ev="no evidence given"; fi
  hq_stp_check_text "stoppage" "--evidence" "$ev" 200
  ev="${note}${ev}"
  ev="${ev:0:200}"
  hq_stp_key key "$thread" "$at"
  hq_jq_find || hq_die_error "stoppage: jq not found (PATH, /opt/homebrew/bin/jq, or /usr/bin/jq)"
  payload=$(hq_jq -cn --arg key "$key" --arg at "$at" --arg thread "$thread" --arg repo "$repo" \
    --arg ref "$ref" --arg cause "$cause" --arg evidence "$ev" --arg source "$src" \
    '{op: "record", key: $key, at: $at, thread: $thread, repo: $repo, ref: $ref,
      cause: $cause, evidence: $evidence, source: $source}') || hq_die_error "stoppage: cannot build the entry"
  hq_stp_try out "$payload" || rc=$?
  case "$rc" in
    0)
      if [ "$json" -eq 1 ]; then
        hq_jq -cn --arg id "$out" --arg cause "$cause" --arg key "$key" '{id: ($id | tonumber), cause: $cause, key: $key, stored: true}'
      else
        printf 'stored %s\n' "$out"
      fi
      hq_stp_flush
      ;;
    1|7)
      hq_stp_spool_put "$payload"
      if [ "$json" -eq 1 ]; then
        hq_jq -cn --arg cause "$cause" --arg key "$key" '{id: null, cause: $cause, key: $key, stored: false}'
      else
        printf 'kept locally (%s); it will be sent when the database answers\n' "${HQ_STP_ERR:-database unreachable}"
      fi
      ;;
    *)
      printf 'human-queue: %s\n' "$HQ_STP_ERR" >&2
      exit "$rc"
      ;;
  esac
}

hq__stp_resume() {
  local thread="${CLAUDE_SESSION_ID:-}" at="" payload out rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --thread) hq__stp_need "$#" --thread; thread="$2"; shift 2 ;;
      --at) hq__stp_need "$#" --at; at="$2"; shift 2 ;;
      -*) hq_die_validation "stoppage resume: unknown $(hq_flag_name "$1") (run human-queue.sh stoppage --help)" ;;
      *) hq_die_validation "stoppage resume: takes options only (run human-queue.sh stoppage --help)" ;;
    esac
  done
  hq__stp_check_thread "$thread"
  if [ -z "$at" ]; then hq_stp_now at; fi
  hq_stp_check_time "stoppage" "--at" "$at"
  hq_jq_find || hq_die_error "stoppage: jq not found (PATH, /opt/homebrew/bin/jq, or /usr/bin/jq)"
  payload=$(hq_jq -cn --arg thread "$thread" --arg at "$at" '{op: "resume", thread: $thread, at: $at}') \
    || hq_die_error "stoppage: cannot build the entry"
  hq_stp_apply_ordered out "$payload" || rc=$?
  case "$rc" in
    0)
      printf 'closed %s\n' "$(hq__stp_count "$out")"
      ;;
    100)
      printf 'kept locally (%s)\n' "$HQ_STP_ERR"
      ;;
    1|7)
      hq_stp_spool_put "$payload"
      printf 'kept locally (%s); it will be sent when the database answers\n' "${HQ_STP_ERR:-database unreachable}"
      ;;
    *)
      printf 'human-queue: %s\n' "$HQ_STP_ERR" >&2
      exit "$rc"
      ;;
  esac
}

# hq__stp_count TEXT — the number of non-empty lines in TEXT.
hq__stp_count() {
  if [ -z "$1" ]; then printf '0'; return 0; fi
  printf '%s\n' "$1" | grep -c .
}

hq__stp_correct() {
  local thread="" id="" cause="" note="" have_cause=0 payload out rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --thread) hq__stp_need "$#" --thread; thread="$2"; shift 2 ;;
      --cause) hq__stp_need "$#" --cause; cause="$2"; have_cause=1; shift 2 ;;
      --note) hq__stp_need "$#" --note; note="$2"; shift 2 ;;
      -*) hq_die_validation "stoppage correct: unknown $(hq_flag_name "$1") (run human-queue.sh stoppage --help)" ;;
      *)
        if [ -n "$id" ]; then hq_die_validation "stoppage correct: takes one entry id"; fi
        id="$1"
        shift
        ;;
    esac
  done
  if [ -n "$id" ]; then
    case "$id" in
      *[!0-9]*|0*) hq_die_validation "stoppage correct: the id must be a whole number from \`stoppage why\`" ;;
    esac
    if [ "${#id}" -gt 18 ]; then hq_die_validation "stoppage correct: the id is too long"; fi
  fi
  if [ -n "$id" ] && [ -n "$thread" ]; then
    hq_die_validation "stoppage correct: give an id or --thread, not both"
  fi
  if [ -z "$id" ]; then
    if [ -z "$thread" ]; then thread="${CLAUDE_SESSION_ID:-}"; fi
    hq__stp_check_thread "$thread"
  fi
  if [ "$have_cause" -eq 0 ]; then hq_die_validation "stoppage correct: --cause is required"; fi
  case " $HQ_STP_CAUSES " in
    *" $cause "*) ;;
    *) hq_die_validation "stoppage correct: --cause must be one of: $HQ_STP_CAUSES" ;;
  esac
  hq_stp_check_text "stoppage" "--note" "$note" 300
  hq_jq_find || hq_die_error "stoppage: jq not found (PATH, /opt/homebrew/bin/jq, or /usr/bin/jq)"
  payload=$(hq_jq -cn --arg id "$id" --arg thread "$thread" --arg cause "$cause" --arg note "$note" \
    '{op: "correct", id: $id, thread: $thread, cause: $cause, note: $note}') \
    || hq_die_error "stoppage: cannot build the correction"
  hq_stp_apply_ordered out "$payload" || rc=$?
  case "$rc" in
    0)
      printf 'corrected %s\n' "$out"
      ;;
    100)
      printf 'kept locally (%s)\n' "$HQ_STP_ERR"
      ;;
    1|7)
      # The one failure a correction can wait out; keep it and say so.
      hq_stp_spool_put "$payload"
      printf 'kept locally (%s); it will be sent when the database answers\n' "${HQ_STP_ERR:-database unreachable}"
      ;;
    *)
      printf 'human-queue: %s\n' "$HQ_STP_ERR" >&2
      exit "$rc"
      ;;
  esac
}

hq__stp_sql_why() {
  cat <<'SQL'
SELECT coalesce((SELECT to_jsonb(r)::text FROM (
  SELECT id, to_char(stopped_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS stopped_at,
         thread, repo, ref, cause, evidence, source, idle_seconds, corrected_cause, correction_note
    FROM stoppages WHERE thread = :'hq_thread'
   ORDER BY stopped_at DESC, id DESC LIMIT 1) r), 'null');
SQL
}

hq__stp_sql_list() {
  cat <<'SQL'
SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.stopped_at, r.id)::text, '[]') FROM (
  SELECT id, to_char(stopped_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS stopped_at,
         thread, repo, ref, cause, corrected_cause, idle_seconds
    FROM stoppages
   WHERE (stopped_at AT TIME ZONE :'hq_tz')::date
         BETWEEN coalesce(nullif(:'hq_from', '')::date, (statement_timestamp() AT TIME ZONE :'hq_tz')::date - 6)
             AND coalesce(nullif(:'hq_to', '')::date, (statement_timestamp() AT TIME ZONE :'hq_tz')::date)
) r;
SQL
}

# hq__stp_render_why JSON — one entry as a sentence.
hq__stp_render_why() {
  printf '%s' "$1" | hq_jq -r '
    def dur: . as $s | ($s / 3600 | floor) as $h | (($s % 3600) / 60 | floor) as $m
      | if $h > 0 then "\($h)h \($m)m" else "\($m)m" end;
    (if .id == null then "pending" else "#\(.id)" end) as $id
    | "stoppage \($id): stopped \(.stopped_at) · \(.corrected_cause // .cause)"
      + (if .corrected_cause != null and .corrected_cause != .cause then " (corrected from \(.cause))" else "" end)
      + (if .ref != null and .ref != "" then " · \(.ref)" else "" end)
      + " · \(.repo) · evidence: \(.evidence)"
      + (if .idle_seconds == null then " · still stopped" else " · idle \(.idle_seconds | dur)" end)
      + (if .correction_note != null then " · operator note: \(.correction_note)" else "" end)
      + (if .id == null then " · not stored yet (database unreachable)" else "" end)'
}

# hq__stp_kept_latest VAR THREAD — the latest locally kept record for THREAD, in
# the shape `why` prints, or empty. Reads only this machine's kept files.
hq__stp_kept_latest() {
  local hq__var="$1" hq__thread="$2" hq__dir hq__f hq__best="" LC_ALL=C
  printf -v "$hq__var" '%s' ""
  hq_stp_spool_dir hq__dir
  [ -d "$hq__dir" ] || return 0
  for hq__f in "$hq__dir"/[0-9]*.json; do
    [ -f "$hq__f" ] || continue
    hq__best=$(hq_jq -c --arg t "$hq__thread" 'select(.op == "record" and .thread == $t)
        | {id: null, stopped_at: .at, thread, repo, ref, cause, evidence, source,
           idle_seconds: null, corrected_cause: null, correction_note: null}' "$hq__f" 2>/dev/null) || hq__best=""
    if [ -n "$hq__best" ]; then printf -v "$hq__var" '%s' "$hq__best"; fi
  done
  return 0
}

# hq__stp_why_query THREAD — the thread's latest entry as JSON text, or `null`.
# Runs in a command substitution, so it carries its own temp-file cleanup.
hq__stp_why_query() {
  local errf2 rc=0
  trap hq__cleanup_tmp EXIT
  hq_db_connect
  hq_mktemp errf2
  hq__stp_sql_why | hq_db_script -At -v "hq_thread=$1" 2>"$errf2" || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf2" "stoppage why"
  fi
}

hq__stp_why() {
  local thread="${CLAUDE_SESSION_ID:-}" json=0 out rc=0 errf kept=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --thread) hq__stp_need "$#" --thread; thread="$2"; shift 2 ;;
      -*) hq_die_validation "stoppage why: unknown $(hq_flag_name "$1") (run human-queue.sh stoppage --help)" ;;
      *) hq_die_validation "stoppage why: takes options only (run human-queue.sh stoppage --help)" ;;
    esac
  done
  hq__stp_check_thread "$thread"
  hq_jq_find || hq_die_error "stoppage: jq not found (PATH, /opt/homebrew/bin/jq, or /usr/bin/jq)"
  hq_stp_flush
  errf=$(mktemp "${TMPDIR:-/tmp}/human-queue.XXXXXX") || hq_die_error "stoppage why: cannot create a temp file"
  out=$(hq__stp_why_query "$thread" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq__stp_kept_latest kept "$thread"
    if [ -n "$kept" ]; then
      out="$kept"
    else
      sed -n '1p' "$errf" >&2
      rm -f "$errf"
      exit "$rc"
    fi
  fi
  rm -f "$errf"
  if [ "$out" = "null" ] || [ -z "$out" ]; then
    if [ "$json" -eq 1 ]; then printf 'null\n'; else printf 'no stoppage entry for this thread\n'; fi
    return 0
  fi
  if [ "$json" -eq 1 ]; then printf '%s\n' "$out"; else hq__stp_render_why "$out"; fi
}

hq__stp_check_day() {
  local hq__re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$' hq__y hq__m hq__d
  if ! [[ $2 =~ $hq__re ]]; then
    hq_die_validation "stoppage list: $1 must be a date like 2026-11-13"
  fi
  hq__y=$((10#${2:0:4})); hq__m=$((10#${2:5:2})); hq__d=$((10#${2:8:2}))
  if [ "$hq__m" -lt 1 ] || [ "$hq__m" -gt 12 ] || [ "$hq__d" -lt 1 ] || [ "$hq__d" -gt 31 ] || [ "$hq__y" -lt 2000 ]; then
    hq_die_validation "stoppage list: $1 is not a real date"
  fi
}

hq__stp_list() {
  local from="" to="" json=0 out rc=0 errf rows grouped
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --from) hq__stp_need "$#" --from; from="$2"; shift 2 ;;
      --to) hq__stp_need "$#" --to; to="$2"; shift 2 ;;
      -*) hq_die_validation "stoppage list: unknown $(hq_flag_name "$1") (run human-queue.sh stoppage --help)" ;;
      *) hq_die_validation "stoppage list: takes options only (run human-queue.sh stoppage --help)" ;;
    esac
  done
  if [ -n "$from" ]; then hq__stp_check_day "--from" "$from"; fi
  if [ -n "$to" ]; then hq__stp_check_day "--to" "$to"; fi
  if [ -n "$from" ] && [ -n "$to" ] && [[ $from > $to ]]; then
    hq_die_validation "stoppage list: --from is after --to"
  fi
  hq_jq_find || hq_die_error "stoppage: jq not found (PATH, /opt/homebrew/bin/jq, or /usr/bin/jq)"
  hq_stp_flush
  hq_db_connect
  hq_mktemp errf
  rows=$(hq__stp_sql_list | hq_db_script -At -v "hq_from=$from" -v "hq_to=$to" -v "hq_tz=$(hq_desk_tz)" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -ne 2 ] && [ "$rc" -ne 143 ] && grep -q 'stoppages' "$errf" && grep -q 'does not exist' "$errf"; then
      hq_die_error "stoppage list: the store is not migrated (run human-queue.sh migrate)"
    fi
    hq_db_fail "$rc" "$errf" "stoppage list"
  fi
  # The heading names the range; an open range end is today (the desk's calendar).
  if [ -z "$from" ] || [ -z "$to" ]; then
    local today
    today=$(TZ="$(hq_desk_tz)" date +%Y-%m-%d) || hq_die_error "stoppage list: cannot read the clock"
    if [ -z "$to" ]; then to="$today"; fi
    if [ -z "$from" ]; then
      from=$(TZ="$(hq_desk_tz)" date -v-6d +%Y-%m-%d 2>/dev/null) \
        || from=$(TZ="$(hq_desk_tz)" date -d '6 days ago' +%Y-%m-%d 2>/dev/null) \
        || hq_die_error "stoppage list: cannot work out the default range"
    fi
  fi
  grouped=$(printf '%s' "$rows" | hq_jq -c --arg from "$from" --arg to "$to" -f "$HQ_BIN_DIR/lib/stoppages.jq") \
    || hq_die_error "stoppage list: the store returned rows that could not be grouped"
  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$grouped"
  else
    printf '%s' "$grouped" | hq_jq -r -f "$HQ_BIN_DIR/lib/stoppages-text.jq"
  fi
}

hq__stp_flush_cmd() {
  if [ "$#" -gt 0 ]; then
    hq_die_validation "stoppage flush: takes no arguments (run human-queue.sh stoppage --help)"
  fi
  hq_jq_find || hq_die_error "stoppage: jq not found (PATH, /opt/homebrew/bin/jq, or /usr/bin/jq)"
  hq_stp_flush
  printf 'sent %s\n' "$HQ_STP_SENT"
}

cmd_run() {
  local a
  for a in "$@"; do
    case "$a" in
      -h|--help)
        cmd_usage
        exit 0
        ;;
    esac
  done
  if [ "$#" -eq 0 ]; then
    hq_die_validation "stoppage: missing command (run human-queue.sh stoppage --help)"
  fi
  local sub="$1"
  shift
  case "$sub" in
    record) hq__stp_record "$@" ;;
    resume) hq__stp_resume "$@" ;;
    why) hq__stp_why "$@" ;;
    correct) hq__stp_correct "$@" ;;
    list) hq__stp_list "$@" ;;
    flush) hq__stp_flush_cmd "$@" ;;
    *) hq_die_validation "stoppage: unknown command (run human-queue.sh stoppage --help)" ;;
  esac
}
