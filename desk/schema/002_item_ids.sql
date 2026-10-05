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
-- migrate prints whatever a migration's statements return. 001 allows ids of
-- any length, but a sequence only reaches bigint's maximum: an id beyond it can
-- never collide with a value the sequence hands out, so it is left out rather
-- than cast (a cast would fail and roll this migration back). The test is on
-- the digits as text, before any cast: 001's CHECK rules out leading zeros, so
-- fewer than 19 digits always fit, and 19 digits fit when they sort at or
-- below bigint's maximum (byte order, so collation cannot change it). CASE
-- keeps the cast from running on a row that fails the test.
DO $$
DECLARE
  max_decision bigint;
  max_review   bigint;
BEGIN
  SELECT max(CASE WHEN length(id) < 21
                    OR (length(id) = 21 AND substring(id FROM 3) COLLATE "C" <= '9223372036854775807')
                  THEN substring(id FROM 3)::bigint END)
    INTO max_decision FROM items WHERE kind = 'decision';
  SELECT max(CASE WHEN length(id) < 21
                    OR (length(id) = 21 AND substring(id FROM 3) COLLATE "C" <= '9223372036854775807')
                  THEN substring(id FROM 3)::bigint END)
    INTO max_review FROM items WHERE kind = 'review';
  IF max_decision IS NOT NULL THEN
    PERFORM setval('items_decision_seq', max_decision);
  END IF;
  IF max_review IS NOT NULL THEN
    PERFORM setval('items_review_seq', max_review);
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
--
-- Rows written before this migration were never deduplicated. If two open
-- items already share a key, building the index would fail with a bare
-- unique-violation; stop first with a message naming the ids instead. Nothing
-- is closed or merged automatically: which copy to keep is the operator's
-- call, and the whole migration rolls back, so it can simply run again.
DO $$
DECLARE
  groups text;
BEGIN
  SELECT string_agg(ids, '; ' ORDER BY ids) INTO groups
    FROM (SELECT string_agg(id, ', ' ORDER BY id) AS ids
            FROM items
           WHERE status = 'open'
           GROUP BY kind, repo, key, item_question_hash(question)
          HAVING count(*) > 1) g;
  IF groups IS NOT NULL THEN
    -- One line: migrate reports only the first ERROR line psql prints.
    RAISE EXCEPTION 'open items repeat the same question (%); close all but one of each group, then run migrate again', groups;
  END IF;
END;
$$;

CREATE UNIQUE INDEX items_open_question_key
  ON items (kind, repo, key, item_question_hash(question))
  WHERE status = 'open';
