-- 003_lifecycle.sql — set ids, the tick change marker, and the pending-for
-- index for the lifecycle and control subcommands (issue #1776).
--
-- Applied by `human-queue.sh migrate` inside one transaction together with its
-- schema_migrations row; no BEGIN/COMMIT. Names are unqualified so
-- HUMAN_QUEUE_SCHEMA (search_path) picks the schema. Never edit this file after
-- it merges: add a new NNN_<name>.sql instead.

-- Set ids for `set-open`. Seeded past any set already written, so a set made
-- before this migration can never share an id with a new one.
CREATE SEQUENCE sets_set_id_seq AS bigint MINVALUE 1;

COMMENT ON SEQUENCE sets_set_id_seq IS 'Numbers presented batches (sets.set_id); read only by human-queue.sh set-open.';

DO $$
DECLARE
  max_set bigint;
BEGIN
  SELECT max(set_id) INTO max_set FROM sets;
  IF max_set IS NOT NULL THEN
    PERFORM setval('sets_set_id_seq', max_set);
  END IF;
END;
$$;

-- The change marker `tick` reads. updated_at cannot serve: it is now(), the
-- START of the writing transaction, so a write that starts before a tick and
-- commits after it carries a time older than that tick and would be missed
-- for good. change_xid is the writing transaction's id instead; `tick` stores
-- the snapshot it read under (pg_current_snapshot) and later reports exactly
-- the rows whose change_xid that snapshot could not see — every change that
-- committed after it, including one still in flight while it ran, and none it
-- already reported.
--
-- Existing rows take this migration's own transaction id (a stable default is
-- evaluated once), so they read as changed until the first tick, which reports
-- every item anyway.
ALTER TABLE items ADD COLUMN change_xid xid8 NOT NULL DEFAULT pg_current_xact_id();

-- A trigger, not just the default: every INSERT and UPDATE stamps the writing
-- transaction, whatever the writer put in the column. pg_current_xact_id() is
-- the top-level transaction id, the same kind of id a snapshot lists, so a
-- write inside a savepoint is judged by the transaction that commits it.
CREATE FUNCTION items_mark_change() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  NEW.change_xid := pg_current_xact_id();
  RETURN NEW;
END;
$$;

CREATE TRIGGER items_mark_change
  BEFORE INSERT OR UPDATE ON items
  FOR EACH ROW EXECUTE FUNCTION items_mark_change();

COMMENT ON COLUMN items.change_xid IS 'Id of the transaction that last wrote the row (trigger-maintained); tick reports rows whose change_xid its stored snapshot could not see. Internal: left out of the CLI''s JSON.';
COMMENT ON COLUMN items.updated_at IS 'Maintained by trigger: start time of the last writing transaction. For display; tick reads change_xid instead, which is safe under commit order.';

-- pending-for: the answered, not yet acknowledged Decisions of one session.
CREATE INDEX items_pending_for_idx ON items (session_id) WHERE status = 'answered';
