-- 010_todo_layer.sql — the operator's personal to-do layer on items: tags,
-- a note, a snooze, and a personal priority (issue #1769).
--
-- Applied by `human-queue.sh migrate` inside one transaction together with its
-- schema_migrations row; no BEGIN/COMMIT. Names are unqualified so
-- HUMAN_QUEUE_SCHEMA (search_path) picks the schema. Never edit this file after
-- it merges: add a new NNN_<name>.sql instead.
--
-- A layer on items, not a second task system: four item fields, written by
-- `tag`/`untag`, `note`, `snooze`/`unsnooze`, and `mine`, each change one
-- event; `my list` reads them. The `my_` prefix keeps them apart from the
-- interrupt-tuning feedback tags (`feedback` events, issue #1783) and from
-- the events' own `note` column.

ALTER TABLE items ADD COLUMN my_tags text[] NOT NULL DEFAULT '{}';
ALTER TABLE items ADD COLUMN my_note text;
ALTER TABLE items ADD COLUMN my_priority smallint;
ALTER TABLE items ADD COLUMN snoozed_until timestamptz;

-- Tags: at most ten lowercase words joined by single hyphens, each at most 32
-- characters and holding a letter (an all-digit tag would read as an issue
-- number). Order is the order they were added; `tag` never adds one twice.
ALTER TABLE items ADD CONSTRAINT items_my_tags_check
  CHECK (
    cardinality(my_tags) <= 10
    AND (cardinality(my_tags) = 0 OR array_ndims(my_tags) = 1)
    AND array_position(my_tags, NULL) IS NULL
    AND (cardinality(my_tags) = 0
         OR (array_to_string(my_tags, ',') ~ '^[a-z0-9]+(-[a-z0-9]+)*(,[a-z0-9]+(-[a-z0-9]+)*)*$'
             AND array_to_string(my_tags, ',') !~ '[^,]{33}'
             AND array_to_string(my_tags, ',') !~ '(^|,)[0-9-]+(,|$)'))
  );

-- The note: one line, printed raw by `my list` and the item renderer.
ALTER TABLE items ADD CONSTRAINT items_my_note_check
  CHECK (my_note IS NULL OR (char_length(my_note) BETWEEN 1 AND 1000 AND my_note !~ '[\r\n]'));

-- Personal priority: 1 (highest) to 5.
ALTER TABLE items ADD CONSTRAINT items_my_priority_check
  CHECK (my_priority IS NULL OR my_priority BETWEEN 1 AND 5);

COMMENT ON COLUMN items.my_tags IS 'The operator''s own tags (issue #1769): lowercase hyphenated words, at most ten. Not the interrupt-tuning feedback tags, which are events.';
COMMENT ON COLUMN items.my_note IS 'The operator''s own note on the item (issue #1769), one line; shown by `my list`, the item renderer, and the paper copy.';
COMMENT ON COLUMN items.my_priority IS 'The operator''s personal priority, 1 (highest) to 5 (issue #1769); orders `my list`. Unrelated to /pm''s backlog order (pm-priority.json).';
COMMENT ON COLUMN items.snoozed_until IS 'While in the future, `my list` hides the item (issue #1769). The queue itself (tick, sets, the sweep) is unchanged.';

-- Six event kinds, one per kind of change. Added to whatever the constraint
-- allows now rather than by restating 006's list, so a migration from a
-- parallel branch that extended it first (they may apply in any order) keeps
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
    RAISE EXCEPTION 'events_kind_check is missing or not a list of kinds (%); cannot add the to-do event kinds',
      coalesce(def, 'none');
  END IF;
  SELECT string_agg(quote_literal(k), ', ' ORDER BY ord) INTO kinds
    FROM (SELECT k, min(ord) AS ord
            FROM (SELECT r.m[1] AS k, r.n AS ord
                    FROM regexp_matches(def, '''([^'']+)''', 'g') WITH ORDINALITY AS r(m, n)
                  UNION ALL
                  SELECT a.k, 1000 + a.n
                    FROM unnest(ARRAY['tagged', 'untagged', 'noted', 'snoozed', 'unsnoozed',
                                      'prioritized']) WITH ORDINALITY AS a(k, n)) every_kind
           GROUP BY k) d;
  ALTER TABLE events DROP CONSTRAINT events_kind_check;
  EXECUTE format('ALTER TABLE events ADD CONSTRAINT events_kind_check CHECK (kind IN (%s))', kinds);
END;
$$;

-- 004 and 007 keep an update that changes only a cached summary out of
-- `tick`. The to-do fields are the same kind of annotation, written from the
-- desk while the operator reads: tagging an open Decision must not make the
-- next tick show it again as new. So an UPDATE that changes at least one
-- annotation column (summary_l1, summary_l2, my_tags, my_note, my_priority,
-- snoozed_until) and nothing else (updated_at aside, which a trigger owns)
-- keeps the row's change marker. Any other write, including a bump, which
-- changes no column a caller sets, is stamped exactly as before.
CREATE OR REPLACE FUNCTION items_mark_change() RETURNS trigger
  LANGUAGE plpgsql AS $$
DECLARE
  own CONSTANT text[] := ARRAY['change_xid', 'updated_at'];
  annotations CONSTANT text[] := ARRAY['summary_l1', 'summary_l2', 'my_tags', 'my_note',
                                       'my_priority', 'snoozed_until'];
BEGIN
  IF TG_OP = 'UPDATE'
     AND to_jsonb(NEW) - own <> to_jsonb(OLD) - own
     AND to_jsonb(NEW) - (own || annotations) = to_jsonb(OLD) - (own || annotations) THEN
    NEW.change_xid := OLD.change_xid;
    RETURN NEW;
  END IF;
  NEW.change_xid := pg_current_xact_id();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION items_mark_change() IS 'Stamps items.change_xid with the writing transaction (tick reads it), except on an update that changes only annotations the desk writes (the cached summaries and the operator''s to-do fields): those are not changes tick reports.';
