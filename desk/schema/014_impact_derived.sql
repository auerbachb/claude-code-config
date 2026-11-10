-- 014_impact_derived.sql — impact derived from what an item really unblocks,
-- stored beside the impact its asker declared (issue #1760).
--
-- Applied by `human-queue.sh migrate` inside one transaction together with its
-- schema_migrations row; no BEGIN/COMMIT. Names are unqualified so
-- HUMAN_QUEUE_SCHEMA (search_path) picks the schema. Never edit this file after
-- it merges: add a new NNN_<name>.sql instead.
--
-- `human-queue.sh impact` derives an item's impact from the /pm backlog rank
-- of its issue (while that ranking is under a day old), how many open issues
-- depend on the issue, and whether the asking agent is parked. The derived
-- value wins wherever impact orders items (tick, list, sets, the day plan's
-- clear-first batch, the end-of-day sweep); impact_declared stays as the
-- asker wrote it. Additive only: no existing column, constraint, or event
-- kind changes, so it applies in any order with the other in-flight
-- migrations.

ALTER TABLE items ADD COLUMN impact_derived text;
ALTER TABLE items ADD COLUMN impact_basis text;
ALTER TABLE items ADD COLUMN impact_derived_at timestamptz;

-- The derived scale is the declared one with critical-path on top: an item
-- whose issue heads a dependent chain or sits at the top of the backlog.
ALTER TABLE items ADD CONSTRAINT items_impact_derived_check
  CHECK (impact_derived IS NULL OR impact_derived IN ('critical-path', 'high', 'medium', 'low'));

-- The inputs in words ("2 open dependents, backlog rank unknown"): one line,
-- built from numbers and fixed words only, printed by the item renderers.
ALTER TABLE items ADD CONSTRAINT items_impact_basis_check
  CHECK (impact_basis IS NULL OR (char_length(impact_basis) BETWEEN 1 AND 200 AND impact_basis !~ '[\r\n]'));

-- A derived value always says when it was derived.
ALTER TABLE items ADD CONSTRAINT items_impact_derived_at_check
  CHECK (impact_derived IS NULL OR impact_derived_at IS NOT NULL);

COMMENT ON COLUMN items.impact_declared IS 'Impact as declared by the asker (low, medium, high). impact_derived (issue #1760) wins over it where present.';
COMMENT ON COLUMN items.impact_derived IS 'Impact derived by `impact` (issue #1760) from the issue''s /pm backlog rank, its open dependents, and the parked flag: critical-path, medium, or low (high is the declared scale''s). Orders items ahead of impact_declared.';
COMMENT ON COLUMN items.impact_basis IS 'The inputs behind impact_derived, in words, one line (issue #1760).';
COMMENT ON COLUMN items.impact_derived_at IS 'When impact was last derived for this item (issue #1760); `impact --open` re-derives after its --max-age.';

-- A derivation is the desk's own bookkeeping, like the cached summaries
-- (004, 007) and the operator's to-do fields (010): re-deriving an open
-- Decision must not make the next tick show it again as new. So an UPDATE
-- that changes at least one annotation column and nothing else (updated_at
-- aside, which a trigger owns) keeps the row's change marker. The list keeps
-- every annotation 010 named and adds the three impact columns; any other
-- write, including a bump, is stamped exactly as before.
CREATE OR REPLACE FUNCTION items_mark_change() RETURNS trigger
  LANGUAGE plpgsql AS $$
DECLARE
  own CONSTANT text[] := ARRAY['change_xid', 'updated_at'];
  annotations CONSTANT text[] := ARRAY['summary_l1', 'summary_l2', 'my_tags', 'my_note',
                                       'my_priority', 'snoozed_until',
                                       'impact_derived', 'impact_basis', 'impact_derived_at'];
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

COMMENT ON FUNCTION items_mark_change() IS 'Stamps items.change_xid with the writing transaction (tick reads it), except on an update that changes only annotations the desk writes (the cached summaries, the operator''s to-do fields, and the derived impact): those are not changes tick reports.';
