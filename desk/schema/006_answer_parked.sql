-- 006_answer_parked.sql — an answer whose thread never woke waits for the
-- next thread on its PR or issue (issue #1781).
--
-- Applied by `human-queue.sh migrate` inside one transaction together with its
-- schema_migrations row; no BEGIN/COMMIT. Names are unqualified so
-- HUMAN_QUEUE_SCHEMA (search_path) picks the schema. Never edit this file after
-- it merges: add a new NNN_<name>.sql instead.
--
-- After the operator answers, /desk wakes the asking thread and records the
-- result (`woken` / `wake-failed`, migration 005). A failed wake-up is retried
-- on the next three ticks; the retry count is the number of `wake-failed`
-- events since the item's latest `answered` event, so no counter column is
-- needed. When the third retry fails (or at once, for an item with no return
-- address), `human-queue.sh wake` sets the status `answer-parked` and records
-- one `answer-parked` event, in the same transaction: the answer stays in the
-- store for the next thread on that PR or issue (`pending-for --repo --key`),
-- and `ack` acknowledges it like any answer.
ALTER TABLE items DROP CONSTRAINT items_status_check;

ALTER TABLE items ADD CONSTRAINT items_status_check
  CHECK (status IN ('open', 'answered', 'acknowledged', 'reviewed', 'flagged', 'closed',
                    'answer-parked'));

ALTER TABLE events DROP CONSTRAINT events_kind_check;

ALTER TABLE events ADD CONSTRAINT events_kind_check
  CHECK (kind IN ('asked', 'bumped', 'shown', 'answered', 'acknowledged',
                  'reviewed', 'flagged', 'feedback', 'commented',
                  'woken', 'wake-failed', 'answer-parked'));
