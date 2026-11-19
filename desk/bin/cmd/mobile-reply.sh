# shellcheck shell=bash
# summary: apply a guarded mobile reply or list the resulting wake pointers

# Reuse the normal answer parser, secret check, and SQL. The two functions
# below define this command's own entry points after sourcing the helpers.
# shellcheck source=answer.sh
. "$HQ_BIN_DIR/cmd/answer.sh"

cmd_usage() {
  cat <<'USAGE'
human-queue.sh mobile-reply snapshot SESSION
human-queue.sh mobile-reply pending SESSION
human-queue.sh mobile-reply apply SESSION REPO_ID COMMENT_ID ITEM VERSION answer|reviewed

The registered desk may apply a reply only to the exact open queue version
that was shown on the phone. Decision reply text is read from stdin.
Output: applied, replay, or stale. The pending form emits the Decision ids
whose accepted mobile reply still needs the existing desk wake flow.
USAGE
}

hq__mobile_snapshot_sql() {
  cat <<'SQL'
SELECT coalesce(jsonb_agg(jsonb_build_object(
         'id', i.id, 'kind', i.kind, 'status', i.status, 'version', i.change_xid::text,
         'question', i.question, 'options', i.options, 'default_option', i.default_option)
         ORDER BY i.id), '[]'::jsonb)
  FROM items i
 WHERE i.status = 'open'
   AND EXISTS (SELECT 1 FROM state WHERE key = 'control_session' AND value = :'hq_control');
SQL
}

hq__mobile_pending_sql() {
  cat <<'SQL'
SELECT coalesce(jsonb_agg(r.item_id ORDER BY r.item_event_id), '[]'::jsonb)
  FROM mobile_inbox_receipts r
  JOIN items i ON i.id = r.item_id AND i.status = 'answered'
 WHERE r.action = 'answer'
   AND EXISTS (SELECT 1 FROM state WHERE key = 'control_session' AND value = :'hq_control')
   AND r.item_event_id = (SELECT max(e.id) FROM events e WHERE e.item_id = i.id AND e.kind = 'answered')
   AND NOT EXISTS (SELECT 1 FROM events e WHERE e.item_id = i.id
                    AND e.id > r.item_event_id AND e.kind IN ('woken','wake-failed'));
SQL
}

hq__mobile_apply_sql() {
  cat <<'SQL'
SET LOCAL lock_timeout TO '30s';
SELECT pg_advisory_xact_lock(hashtextextended('human-queue:control:' || :'hq_schema', 0)) AS hq_guard \gset
SQL
  hq_sql_lock_item UPDATE
  cat <<'SQL'
SELECT EXISTS (SELECT 1 FROM state WHERE key = 'control_session' AND value = :'hq_control') AS hq_current,
       EXISTS (SELECT 1 FROM mobile_inbox_receipts
                WHERE mirror_repo_id = :'hq_mirror'::bigint AND remote_comment_id = :'hq_comment'::bigint) AS hq_seen,
       EXISTS (SELECT 1 FROM items
                WHERE id = :'hq_id' AND status = 'open' AND change_xid = :'hq_version'::xid8) AS hq_exact \gset
\if :hq_current
  \if :hq_seen
    SELECT 'replay';
  \elif :hq_exact
SQL
  if [ "$1" = answer ]; then
    hq_sql_answer id 1 0
    printf '%s\n' '\if :hq_ok'
  else
    cat <<'SQL'
WITH updated AS (
  UPDATE items SET status = 'reviewed'
   WHERE id = :'hq_id' AND kind = 'review' AND status = 'open'
  RETURNING id
)
INSERT INTO events (item_id, kind) SELECT id, 'reviewed' FROM updated;
SQL
  fi
  cat <<'SQL'
INSERT INTO mobile_inbox_receipts (mirror_repo_id, remote_comment_id, item_id, action, item_event_id)
VALUES (:'hq_mirror'::bigint, :'hq_comment'::bigint, :'hq_id', :'hq_action',
        (SELECT max(id) FROM events
          WHERE item_id = :'hq_id'
            AND kind = CASE WHEN :'hq_action' = 'answer' THEN 'answered' ELSE 'reviewed' END));
INSERT INTO state (key, value)
SELECT 'mobile_answers_imported', '1' WHERE :'hq_action' = 'answer'
ON CONFLICT (key) DO NOTHING;
SELECT 'applied';
SQL
  if [ "$1" = answer ]; then
    printf '%s\n' '\endif'
  fi
  cat <<'SQL'
  \else
    SELECT 'stale';
  \endif
\else
  SELECT 'stale';
\endif
SQL
}

cmd_run() {
  local mode="${1:-}" control="${2:-}" id mirror comment version action reply="" errf out query rc=0
  hq_check_text "mobile-reply: session" "$control" 200
  case "$mode" in
    pending|snapshot)
      [ "$#" -eq 2 ] || hq_die_validation "mobile-reply: $mode takes one session"
      query="hq__mobile_${mode}_sql"
      hq_db_connect
      hq_mktemp errf
      out=$("$query" | hq_db_script -At -v "hq_control=$control" 2>"$errf") || rc=$?
      ;;
    apply)
      [ "$#" -eq 7 ] || hq_die_validation "mobile-reply: apply needs session, repo id, comment id, item, version, and action"
      mirror="$3"; comment="$4"; version="$6"; action="$7"
      [[ $mirror =~ ^[1-9][0-9]{0,17}$ && $comment =~ ^[1-9][0-9]{0,17}$ ]] \
        || hq_die_validation "mobile-reply: invalid repository or comment id"
      hq_item_id id "$5"
      [[ $version =~ ^[1-9][0-9]{0,19}$ ]] \
        || hq_die_validation "mobile-reply: invalid queue version"
      case "$action" in
        answer)
          hq_require_kind mobile-reply "$id" decision
          hq__answer_read_stdin reply
          hq_trim reply "$reply"
          hq_check_answer "mobile-reply: answer" "$reply"
          hq_refuse_secret "mobile-reply: answer" "$reply"
          ;;
        reviewed) hq_require_kind mobile-reply "$id" review ;;
        *) hq_die_validation "mobile-reply: unsupported action" ;;
      esac
      hq_db_connect
      hq_mktemp errf
      out=$(hq__mobile_apply_sql "$action" | hq_db_script -At \
        -v "hq_control=$control" -v "hq_mirror=$mirror" -v "hq_comment=$comment" -v "hq_id=$id" \
        -v "hq_version=$version" -v "hq_action=$action" -v "hq_id_1=$id" -v "hq_reply_1=$reply" \
        2>"$errf") || rc=$?
      ;;
    *) hq_die_validation "mobile-reply: expected snapshot, pending or apply" ;;
  esac
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "mobile-reply: operation failed"
  fi
  hq_problem_check mobile-reply "$out"
  printf '%s\n' "${out##*$'\n'}"
}
