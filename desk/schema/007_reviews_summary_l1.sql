-- 007_reviews_summary_l1.sql — a Review's one-line (level-1) summary, cached
-- once like level 2 and, like it, not a change `tick` reports (issue #1782).
--
-- Applied by `human-queue.sh migrate` inside one transaction together with its
-- schema_migrations row; no BEGIN/COMMIT. Names are unqualified so
-- HUMAN_QUEUE_SCHEMA (search_path) picks the schema. Never edit this file after
-- it merges: add a new NNN_<name>.sql instead.
--
-- The desk's Reviews view prints one line per unreviewed item. The line is
-- written by the desk the first time the item is listed, from
-- pr-summary-material.sh --level 1, and cached here (`summary set ID --level
-- 1`), so it is generated once and never at wrap time.
ALTER TABLE items ADD COLUMN summary_l1 text;

ALTER TABLE items ADD CONSTRAINT items_summary_l1_check
  CHECK (summary_l1 IS NULL
         OR (char_length(summary_l1) BETWEEN 1 AND 200 AND summary_l1 !~ '[\r\n]'));

COMMENT ON COLUMN items.summary_l1 IS 'One-line summary of a Review (the Reviews view''s line), generated once by the desk and cached.';

-- 004 keeps an update that changes only summary_l2 out of `tick`. Caching the
-- one-line summary is the same kind of annotation, so an UPDATE that changes
-- summary_l1, summary_l2, or both, and nothing else (updated_at aside, which
-- a trigger owns), keeps the row's change marker. Any other write, including
-- a bump, which changes no column a caller sets, is stamped exactly as before.
CREATE OR REPLACE FUNCTION items_mark_change() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND (NEW.summary_l1 IS DISTINCT FROM OLD.summary_l1
          OR NEW.summary_l2 IS DISTINCT FROM OLD.summary_l2)
     AND to_jsonb(NEW) - ARRAY['summary_l1', 'summary_l2', 'change_xid', 'updated_at']
       = to_jsonb(OLD) - ARRAY['summary_l1', 'summary_l2', 'change_xid', 'updated_at'] THEN
    NEW.change_xid := OLD.change_xid;
    RETURN NEW;
  END IF;
  NEW.change_xid := pg_current_xact_id();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION items_mark_change() IS 'Stamps items.change_xid with the writing transaction (tick reads it), except on an update that changes only the cached summaries (summary_l1, summary_l2): a cached summary is not a change tick reports.';
