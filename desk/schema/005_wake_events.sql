-- 005_wake_events.sql — the desk records whether it woke the asking thread
-- (issue #1779).
--
-- Applied by `human-queue.sh migrate` inside one transaction together with its
-- schema_migrations row; no BEGIN/COMMIT. Names are unqualified so
-- HUMAN_QUEUE_SCHEMA (search_path) picks the schema. Never edit this file after
-- it merges: add a new NNN_<name>.sql instead.
--
-- After the operator answers a Decision, /desk sends the asking session one
-- pointer message (`human-queue: D-43 answered`) and records what happened:
-- `woken` when the messaging tool confirmed delivery, `wake-failed` (note: why)
-- when it did not. `human-queue.sh wake` writes them. Like comment and
-- feedback they annotate an item without changing its row, so `tick` does not
-- report the item again. The retry policy that counts `wake-failed` events is
-- issue #1781.
ALTER TABLE events DROP CONSTRAINT events_kind_check;

ALTER TABLE events ADD CONSTRAINT events_kind_check
  CHECK (kind IN ('asked', 'bumped', 'shown', 'answered', 'acknowledged',
                  'reviewed', 'flagged', 'feedback', 'commented',
                  'woken', 'wake-failed'));
