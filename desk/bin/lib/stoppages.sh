# shellcheck shell=bash
# desk/bin/lib/stoppages.sh — helpers for `human-queue.sh stoppage` (issue
# #2292): validation, the local keep-and-retry spool, and the database writes.
# Sourced after lib/common.sh, lib/db.sh, lib/github.sh (hq_jq) and
# lib/secrets.sh; never executed. Bash 3.2 compatible.
#
# THE SPOOL
#   When the database cannot be reached, an operation is kept as one JSON file
#   in a private directory and sent on a later call that does reach the
#   database. The directory is ${HUMAN_QUEUE_STOPPAGE_DIR:-~/.claude/
#   desk-stoppages}: under the user's own ~/.claude, never inside a worktree or
#   this repository. Each file holds one operation (record, resume, or correct)
#   and only the entry's own fields: no transcript text and no connection
#   string. Files replay in name order (epoch first), so a resume kept before
#   its record was sent still lands after it. A record carries a dedupe key, so
#   a replay that half-succeeded can never store an entry twice.
#
# PUBLIC FUNCTIONS
#   hq_stp_check_cause VAR VALUE        VALUE into VAR when it is on the fixed
#                                       cause list, else `unknown`
#   hq_stp_check_text CMD LABEL VALUE MAX   one line, at most MAX characters,
#                                       no control characters, not a secret
#   hq_stp_check_time CMD LABEL VALUE   UTC ISO 8601 with a trailing Z
#   hq_stp_now VAR                      the local clock, UTC ISO 8601
#   hq_stp_key VAR THREAD STOPPED_AT    the dedupe key (32 hex characters)
#   hq_stp_spool_dir VAR                the spool directory (not created)
#   hq_stp_spool_put JSON               keep one operation locally; exits 1
#                                       when it cannot be written
#   hq_stp_try VAR JSON                 apply one operation to the database in
#                                       a subshell; VAR gets its stdout. Returns
#                                       0, or the failing exit code (7 database
#                                       unreachable, 1 store error, 4 refused)
#                                       with the one-line message in HQ_STP_ERR
#   hq_stp_pending                      true when an operation is kept locally
#   hq_stp_apply_ordered VAR JSON       hq_stp_try behind the kept backlog
#   hq_stp_flush                        send every kept operation; stops at the
#                                       first one the database cannot take.
#                                       Never fails; sets HQ_STP_SENT

HQ_STP_CAUSES="out_of_work waiting_on_review waiting_on_operator usage_limit token_exhaustion blocked_by_error crash unknown"
HQ_STP_ERR=""
HQ_STP_SENT=0

hq_stp_check_cause() {
  local hq__var="$1" hq__v="${2:-}" hq__c
  for hq__c in $HQ_STP_CAUSES; do
    if [ "$hq__v" = "$hq__c" ]; then
      printf -v "$hq__var" '%s' "$hq__v"
      return 0
    fi
  done
  printf -v "$hq__var" '%s' unknown
  return 0
}

hq_stp_check_text() {
  local hq__cmd="$1" hq__label="$2" hq__v="$3" hq__max="$4" hq__re
  hq__re='[[:cntrl:]]'
  if [[ $hq__v =~ $hq__re ]]; then
    hq_die_validation "$hq__cmd: $hq__label must be one line with no control characters"
  fi
  if [ "${#hq__v}" -gt "$hq__max" ]; then
    hq_die_validation "$hq__cmd: $hq__label is longer than $hq__max characters"
  fi
  hq_refuse_secret "$hq__label" "$hq__v"
}

hq_stp_check_time() {
  local hq__cmd="$1" hq__label="$2" hq__v="$3" hq__re hq__y hq__mo hq__d hq__h hq__mi hq__sec hq__max
  hq__re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  if ! [[ $hq__v =~ $hq__re ]]; then
    hq_die_validation "$hq__cmd: $hq__label must be a UTC time like 2026-11-13T09:30:00Z"
  fi
  hq__y=$((10#${hq__v:0:4})); hq__mo=$((10#${hq__v:5:2})); hq__d=$((10#${hq__v:8:2}))
  hq__h=$((10#${hq__v:11:2})); hq__mi=$((10#${hq__v:14:2})); hq__sec=$((10#${hq__v:17:2}))
  case "$hq__mo" in
    1|3|5|7|8|10|12) hq__max=31 ;;
    4|6|9|11) hq__max=30 ;;
    2)
      hq__max=28
      if [ $((hq__y % 4)) -eq 0 ] && { [ $((hq__y % 100)) -ne 0 ] || [ $((hq__y % 400)) -eq 0 ]; }; then hq__max=29; fi
      ;;
    *) hq__max=0 ;;
  esac
  if [ "$hq__y" -lt 2000 ] || [ "$hq__d" -lt 1 ] || [ "$hq__d" -gt "$hq__max" ] \
     || [ "$hq__h" -gt 23 ] || [ "$hq__mi" -gt 59 ] || [ "$hq__sec" -gt 59 ]; then
    hq_die_validation "$hq__cmd: $hq__label is not a real time"
  fi
}

hq_stp_now() {
  local hq__t
  hq__t=$(date -u +%Y-%m-%dT%H:%M:%SZ) || hq_die_error "stoppage: cannot read the clock"
  printf -v "$1" '%s' "$hq__t"
}

hq_stp_key() {
  local hq__var="$1" hq__sum=""
  if command -v shasum >/dev/null 2>&1; then
    hq__sum=$(printf '%s|%s' "$2" "$3" | shasum -a 256 2>/dev/null) || hq__sum=""
  elif command -v sha256sum >/dev/null 2>&1; then
    hq__sum=$(printf '%s|%s' "$2" "$3" | sha256sum 2>/dev/null) || hq__sum=""
  fi
  hq__sum="${hq__sum%% *}"
  if [ "${#hq__sum}" -ne 64 ]; then
    hq_die_error "stoppage: no sha256 tool (shasum or sha256sum) to make the entry key"
  fi
  printf -v "$hq__var" '%s' "${hq__sum:0:32}"
}

hq_stp_spool_dir() {
  local hq__d="${HUMAN_QUEUE_STOPPAGE_DIR:-}"
  if [ -z "$hq__d" ]; then
    if [ -z "${HOME:-}" ]; then
      hq_die_error "stoppage: HOME is unset, so there is nowhere to keep an entry locally"
    fi
    hq__d="$HOME/.claude/desk-stoppages"
  fi
  printf -v "$1" '%s' "${hq__d%/}"
}

# hq__stp_stamp — microseconds since the epoch, 16 digits, so file names sort in
# the order operations were kept. perl's Time::HiRes where there is one, else
# whole seconds padded to the same width.
hq__stp_stamp() {
  local hq__t=""
  hq__t=$(perl -MTime::HiRes=time -e 'printf "%016d", time * 1000000' 2>/dev/null) || hq__t=""
  case "$hq__t" in
    ''|*[!0-9]*) hq__t="$(date -u +%s)000000" ;;
  esac
  printf '%s' "$hq__t"
}

hq_stp_spool_put() {
  local hq__json="$1" hq__dir hq__tmp hq__name hq__stamp
  hq_stp_spool_dir hq__dir
  ( umask 077; mkdir -p "$hq__dir" ) 2>/dev/null || hq_die_error "stoppage: cannot create the local keep directory"
  hq__tmp=$( umask 077; mktemp "$hq__dir/.put.XXXXXX" 2>/dev/null ) || hq_die_error "stoppage: cannot write in the local keep directory"
  if ! printf '%s\n' "$hq__json" >"$hq__tmp" 2>/dev/null; then
    rm -f "$hq__tmp"
    hq_die_error "stoppage: cannot write in the local keep directory"
  fi
  hq__stamp=$(hq__stp_stamp)
  hq__name="${hq__stamp}-$$.json"
  if ! mv "$hq__tmp" "$hq__dir/$hq__name" 2>/dev/null; then
    rm -f "$hq__tmp"
    hq_die_error "stoppage: cannot write in the local keep directory"
  fi
}

# The SQL lives in functions, not heredocs inside $(...): bash 3.2's
# command-substitution scanner does not understand here-documents.

hq__stp_sql_record() {
  cat <<'SQL'
WITH ins AS (
  INSERT INTO stoppages (dedupe_key, stopped_at, thread, repo, ref, cause, evidence, source)
  VALUES (:'hq_key', :'hq_at'::timestamptz, :'hq_thread', :'hq_repo',
          nullif(:'hq_ref', ''), :'hq_cause', :'hq_evidence', :'hq_source')
  ON CONFLICT (dedupe_key) DO NOTHING
  RETURNING id)
SELECT id FROM ins
UNION ALL
SELECT id FROM stoppages WHERE dedupe_key = :'hq_key'
LIMIT 1;
SQL
}

hq__stp_sql_resume() {
  cat <<'SQL'
UPDATE stoppages
   SET resumed_at = :'hq_at'::timestamptz,
       idle_seconds = greatest(0, floor(extract(epoch FROM (:'hq_at'::timestamptz - stopped_at))))::integer
 WHERE thread = :'hq_thread' AND resumed_at IS NULL
   AND stopped_at <= :'hq_at'::timestamptz
RETURNING id;
SQL
}

hq__stp_sql_correct() {
  cat <<'SQL'
UPDATE stoppages
   SET corrected_cause = :'hq_cause', correction_note = nullif(:'hq_note', ''),
       corrected_at = statement_timestamp()
 WHERE id = CASE WHEN :'hq_id' <> ''
                 THEN (SELECT id FROM stoppages WHERE id = nullif(:'hq_id', '')::bigint)
                 ELSE (SELECT id FROM stoppages WHERE thread = :'hq_thread'
                        ORDER BY stopped_at DESC, id DESC LIMIT 1) END
RETURNING id;
SQL
}

# hq__stp_fields JSON FILTER — the filter's array of strings, one per line,
# through jq; the caller reads them with `read`.
hq__stp_fields() {
  printf '%s' "$1" | hq_jq -r "$2" || hq_die_error "stoppage: an operation is not valid JSON"
}

# hq__stp_do JSON — the database write for one operation; runs in the subshell
# hq_stp_try makes (it exits on failure). Prints what the operation affected:
# the entry id for record and correct, one id per closed entry for resume.
hq__stp_do() {
  local hq__json="$1" hq__op hq__errf hq__rc=0 hq__out
  local hq__key="" hq__at="" hq__thread="" hq__repo="" hq__ref="" hq__cause="" hq__ev="" hq__src=""
  local hq__id="" hq__note=""
  hq_jq_find || hq_die_error "stoppage: jq not found (PATH, /opt/homebrew/bin/jq, or /usr/bin/jq)"
  hq__op=$(hq__stp_fields "$hq__json" '.op // ""')
  case "$hq__op" in
    record)
      { IFS= read -r hq__key; IFS= read -r hq__at; IFS= read -r hq__thread; IFS= read -r hq__repo
        IFS= read -r hq__ref; IFS= read -r hq__cause; IFS= read -r hq__ev; IFS= read -r hq__src; } <<EOF
$(hq__stp_fields "$hq__json" '.key, .at, .thread, .repo, (.ref // ""), .cause, .evidence, .source')
EOF
      ;;
    resume)
      { IFS= read -r hq__thread; IFS= read -r hq__at; } <<EOF
$(hq__stp_fields "$hq__json" '.thread, .at')
EOF
      ;;
    correct)
      { IFS= read -r hq__id; IFS= read -r hq__thread; IFS= read -r hq__cause; IFS= read -r hq__note; } <<EOF
$(hq__stp_fields "$hq__json" '(.id // ""), (.thread // ""), .cause, (.note // "")')
EOF
      ;;
    *) hq_die_error "stoppage: an operation has an unknown kind" ;;
  esac
  hq_db_connect
  hq_mktemp hq__errf
  hq__out=$("hq__stp_sql_$hq__op" | hq_db_script -At \
    -v "hq_key=$hq__key" -v "hq_at=$hq__at" -v "hq_thread=$hq__thread" \
    -v "hq_repo=$hq__repo" -v "hq_ref=$hq__ref" -v "hq_cause=$hq__cause" \
    -v "hq_evidence=$hq__ev" -v "hq_source=$hq__src" \
    -v "hq_id=$hq__id" -v "hq_note=$hq__note" 2>"$hq__errf") || hq__rc=$?
  if [ "$hq__rc" -ne 0 ]; then
    if [ "$hq__rc" -ne 2 ] && [ "$hq__rc" -ne 143 ] \
      && grep -q 'stoppages' "$hq__errf" && grep -q 'does not exist' "$hq__errf"; then
      hq_die_error "stoppage: the store is not migrated (run human-queue.sh migrate)"
    fi
    hq_db_fail "$hq__rc" "$hq__errf" "stoppage"
  fi
  if [ -z "$hq__out" ] && [ "$hq__op" != "resume" ]; then
    if [ "$hq__op" = "correct" ]; then
      hq_die_validation "stoppage: no entry to correct"
    fi
    hq_die_error "stoppage: the store returned no entry"
  fi
  if [ -n "$hq__out" ]; then printf '%s\n' "$hq__out"; fi
}

hq_stp_try() {
  local hq__var="$1" hq__json="$2" hq__errf hq__rc=0 hq__out
  # A plain mktemp, not hq_mktemp: the subshell below runs the shared EXIT
  # cleanup, which would delete every temp file the parent registered — this
  # one included — before the message in it is read.
  hq__errf=$(mktemp "${TMPDIR:-/tmp}/human-queue.XXXXXX") || hq_die_error "stoppage: cannot create a temp file"
  hq__out=$( ( trap hq__cleanup_tmp EXIT; hq__stp_do "$hq__json" ) 2>"$hq__errf" ) || hq__rc=$?
  HQ_STP_ERR=$(sed -n '1p' "$hq__errf" 2>/dev/null) || HQ_STP_ERR=""
  rm -f "$hq__errf"
  HQ_STP_ERR="${HQ_STP_ERR#human-queue: }"
  if [ -n "$hq__var" ]; then printf -v "$hq__var" "%s" "$hq__out"; fi
  return "$hq__rc"
}

# hq__stp_lock / hq__stp_unlock — one flusher at a time, so two processes never
# replay the same kept operation (a stale correction must not land after a newer
# one). A lock older than five minutes belongs to a killed process and is taken.
hq__stp_lock() {
  local hq__dir="$1"
  if mkdir "$hq__dir/.flush.lock" 2>/dev/null; then return 0; fi
  if [ -n "$(find "$hq__dir/.flush.lock" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
    rmdir "$hq__dir/.flush.lock" 2>/dev/null || true
    if mkdir "$hq__dir/.flush.lock" 2>/dev/null; then return 0; fi
  fi
  return 1
}
hq__stp_unlock() { rmdir "$1/.flush.lock" 2>/dev/null || true; }

hq_stp_pending() {
  local hq__dir hq__f
  hq_stp_spool_dir hq__dir
  [ -d "$hq__dir" ] || return 1
  for hq__f in "$hq__dir"/[0-9]*.json; do
    if [ -f "$hq__f" ]; then return 0; fi
  done
  return 1
}

hq_stp_flush() {
  local hq__dir hq__f hq__json hq__rc LC_ALL=C
  HQ_STP_SENT=0
  hq_stp_spool_dir hq__dir
  [ -d "$hq__dir" ] || return 0
  hq__stp_lock "$hq__dir" || return 0
  for hq__f in "$hq__dir"/[0-9]*.json; do
    [ -f "$hq__f" ] || continue
    hq__json=$(cat "$hq__f" 2>/dev/null) || break
    hq__rc=0
    hq_stp_try "" "$hq__json" || hq__rc=$?
    case "$hq__rc" in
      0)
        rm -f "$hq__f"
        HQ_STP_SENT=$((HQ_STP_SENT + 1))
        ;;
      4|5)
        # The store refused this one operation (for example a correction for
        # an entry that does not exist): it can never succeed, so it must not
        # hold up the ones behind it.
        rm -f "$hq__f"
        ;;
      *) break ;;
    esac
  done
  hq__stp_unlock "$hq__dir"
  return 0
}

# hq_stp_apply_ordered VAR JSON — for operations whose meaning depends on the
# ones before them (resume, correct): the kept backlog goes first, and when any
# of it cannot be sent this operation is kept behind it, unapplied. Returns 0
# applied; 100 kept behind the backlog (already written); otherwise
# hq_stp_try's code (the caller keeps the operation on 1 or 7).
hq_stp_apply_ordered() {
  hq_stp_flush
  if hq_stp_pending; then
    hq_stp_spool_put "$2"
    HQ_STP_ERR="earlier entries are still waiting to be sent"
    return 100
  fi
  hq_stp_try "$1" "$2"
}
