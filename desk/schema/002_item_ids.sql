-- 002_item_ids.sql — id allocation and dedupe support for `add` (issue #1775).
--
-- Applied by `human-queue.sh migrate` inside one transaction together with its
-- schema_migrations row; no BEGIN/COMMIT. Names are unqualified so
-- HUMAN_QUEUE_SCHEMA (search_path) picks the schema. Never edit this file after
-- it merges: add a new NNN_<name>.sql instead.

-- One sequence per kind: D-1, D-2, ... and R-1, R-2, ... nextval never blocks
-- and never returns the same value twice, so parallel `add` calls get distinct
-- ids. A value taken by a transaction that rolls back is skipped: ids stay
-- short and unique, not gap-free.
CREATE SEQUENCE items_decision_seq AS bigint MINVALUE 1;
CREATE SEQUENCE items_review_seq AS bigint MINVALUE 1;

COMMENT ON SEQUENCE items_decision_seq IS 'Numbers Decision ids (D-n); read only by human-queue.sh add.';
COMMENT ON SEQUENCE items_review_seq IS 'Numbers Review ids (R-n); read only by human-queue.sh add.';

-- Start each sequence past any id already in the table, so rows written before
-- this migration can never collide with a new one. A DO block, not a SELECT:
-- migrate prints whatever a migration's statements return.
DO $$
DECLARE
  max_decision numeric;
  max_review   numeric;
BEGIN
  SELECT max(substring(id FROM 3)::numeric) INTO max_decision FROM items WHERE kind = 'decision';
  SELECT max(substring(id FROM 3)::numeric) INTO max_review FROM items WHERE kind = 'review';
  IF max_decision IS NOT NULL THEN
    PERFORM setval('items_decision_seq', max_decision::bigint);
  END IF;
  IF max_review IS NOT NULL THEN
    PERFORM setval('items_review_seq', max_review::bigint);
  END IF;
END;
$$;

-- The dedupe key for a question: runs of whitespace collapsed to one space,
-- the ends trimmed, and case folded, so "Ship it?" and "  ship   IT? " are the
-- same question. md5 serves as a compact equality key here, not as a security
-- boundary. IMMUTABLE so it can back an index; the CLI's lookup calls this same
-- function, so the index and the lookup can never normalize differently.
CREATE FUNCTION item_question_hash(question text) RETURNS text
  LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
  RETURN md5(lower(btrim(regexp_replace(question, '\s+', ' ', 'g'))));

COMMENT ON FUNCTION item_question_hash(text) IS 'Dedupe key of an item question: whitespace-collapsed, trimmed, lowercased, md5.';

-- At most one OPEN item per (kind, repo, key, question). `add` serializes on
-- an advisory lock and bumps the open item instead of inserting a second one;
-- this index is the backstop that makes a duplicate impossible even if a
-- writer skipped that lock. An answered or closed question asked again becomes
-- a new item, so the predicate is status = 'open' only.
CREATE UNIQUE INDEX items_open_question_key
  ON items (kind, repo, key, item_question_hash(question))
  WHERE status = 'open';
