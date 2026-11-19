-- 013_exported_event.sql — an item went to paper (issue #1759).
--
-- Applied by `human-queue.sh migrate` inside one transaction together with its
-- schema_migrations row; no BEGIN/COMMIT. Names are unqualified so
-- HUMAN_QUEUE_SCHEMA (search_path) picks the schema. Never edit this file after
-- it merges: add a new NNN_<name>.sql instead.
--
-- `human-queue.sh export` writes a numbered PDF of a batch for the operator to
-- answer on paper, and records one `exported` event per item it printed (note:
-- `set N #k`, the set and number the paper shows). Like `shown`, it annotates
-- an item without changing its row, so `tick` does not report the item again.
-- The weekly report does not count it as a desk event.
--
-- The kind is added to whatever the constraint allows now rather than by
-- restating 006's list, so a migration from a parallel branch that extended it
-- first (they may apply in any order, as 010 does for the to-do kinds) keeps
-- its kinds. The current list is read from the constraint's own definition.
DO $$
DECLARE
  def   text;
  kinds text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO def
    FROM pg_constraint c
   WHERE c.conrelid = 'events'::regclass AND c.conname = 'events_kind_check';
  IF def IS NULL OR def NOT LIKE 'CHECK ((kind = ANY (ARRAY[%' THEN
    -- One line: migrate reports only the first ERROR line psql prints.
    RAISE EXCEPTION 'events_kind_check is missing or not a list of kinds (%); cannot add the exported event kind',
      coalesce(def, 'none');
  END IF;
  SELECT string_agg(quote_literal(k), ', ' ORDER BY ord) INTO kinds
    FROM (SELECT k, min(ord) AS ord
            FROM (SELECT r.m[1] AS k, r.n AS ord
                    FROM regexp_matches(def, '''([^'']+)''', 'g') WITH ORDINALITY AS r(m, n)
                  UNION ALL
                  SELECT 'exported', 1000) every_kind
           GROUP BY k) d;
  ALTER TABLE events DROP CONSTRAINT events_kind_check;
  EXECUTE format('ALTER TABLE events ADD CONSTRAINT events_kind_check CHECK (kind IN (%s))', kinds);
END;
$$;
