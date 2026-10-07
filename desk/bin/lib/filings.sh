# shellcheck shell=bash
# desk/bin/lib/filings.sh — the desk's pending filings (issue #1766). Sourced
# by cmd/filed.sh and cmd/sync-reviews.sh after lib/common.sh and lib/db.sh;
# never executed. Bash 3.2 compatible.
#
# When the desk files an idea as an issue, `filed OWNER/NAME N` records a
# pending filing as one row of operator state:
#
#   key    filed:<owner/name, lowercased>:issue-<N>
#   value  when it was recorded (UTC ISO 8601)
#
# The issue reaches Reviews later, when `sync-reviews` finds it by its
# `_Captured via /issue-maker._` footer. Once a Review for that repo and
# `issue-<N>` exists, the pending filing becomes ONE `commented` event, note
# `filed from the desk`, on the Review, and the key is deleted. `filed` does
# that at once when the Review is already there; otherwise `sync-reviews`
# does it after its inserts. Consuming is DELETE ... RETURNING, so two
# consumers running at once record the event once. `state set` refuses keys
# that start with `filed:`; `state get` reads them.

# hq_sql_consume_filings — SQL: turns every pending filing whose Review
# exists into its event and deletes the key. Prints one line: how many it
# consumed. The note, `filed from the desk`, is a literal here and in
# cmd/filed.sh's re-run guard; keep the two in step.
hq_sql_consume_filings() {
  cat <<'SQL'
WITH done AS (
  DELETE FROM state s
   USING items i
   WHERE s.key LIKE 'filed:%'
     AND i.kind = 'review'
     AND s.key = 'filed:' || lower(i.repo) || ':' || i.key
  RETURNING i.id
),
ev AS (
  INSERT INTO events (item_id, kind, note)
  SELECT id, 'commented', 'filed from the desk' FROM done
)
SELECT count(*) FROM done;
SQL
}
