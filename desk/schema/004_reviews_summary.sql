-- 004_reviews_summary.sql — caching a Review's level-2 summary is not a
-- change `tick` reports (issue #1756).
--
-- Applied by `human-queue.sh migrate` inside one transaction together with its
-- schema_migrations row; no BEGIN/COMMIT. Names are unqualified so
-- HUMAN_QUEUE_SCHEMA (search_path) picks the schema. Never edit this file after
-- it merges: add a new NNN_<name>.sql instead.
--
-- 003's trigger stamps every write with the writing transaction, so `tick`
-- reports it. `summary set` writes items.summary_l2 while the operator reads
-- the item: an annotation the desk writes itself, like comment, feedback, and
-- shown, none of which re-report an item. An UPDATE that changes summary_l2
-- and nothing else (updated_at aside, which a trigger owns) therefore keeps
-- the row's change marker. Any other write, including a bump, which changes
-- no column a caller sets, is stamped exactly as before.
CREATE OR REPLACE FUNCTION items_mark_change() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.summary_l2 IS DISTINCT FROM OLD.summary_l2
     AND to_jsonb(NEW) - ARRAY['summary_l2', 'change_xid', 'updated_at']
       = to_jsonb(OLD) - ARRAY['summary_l2', 'change_xid', 'updated_at'] THEN
    NEW.change_xid := OLD.change_xid;
    RETURN NEW;
  END IF;
  NEW.change_xid := pg_current_xact_id();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION items_mark_change() IS 'Stamps items.change_xid with the writing transaction (tick reads it), except on an update that changes only summary_l2: a cached summary is not a change tick reports.';
