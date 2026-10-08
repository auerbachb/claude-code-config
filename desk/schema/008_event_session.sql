-- 008_event_session.sql — a feedback tag records the thread that asked
-- (issue #1783).
--
-- Applied by `human-queue.sh migrate` inside one transaction together with its
-- schema_migrations row; no BEGIN/COMMIT. Names are unqualified so
-- HUMAN_QUEUE_SCHEMA (search_path) picks the schema. Never edit this file after
-- it merges: add a new NNN_<name>.sql instead.
--
-- The operator tunes the desk's interrupts down item by item: `2: not
-- important`, `2: should have defaulted`, `2: good interrupt` write one
-- `feedback` event each (note: the tag). The tuning and the weekly attention
-- report (#1771) read which thread's question it was, so `feedback` copies the
-- item's return address (items.session_id, the asking thread) into the event
-- as it writes it: a later repeated `add` from another thread can move the
-- item's return address, and the event keeps the one it judged. NULL for an
-- item with no return address (a Review) and for every other kind of event.
-- Like the rest of an event, it is a dozen bytes of state, never a transcript.
ALTER TABLE events ADD COLUMN session_id text;

ALTER TABLE events ADD CONSTRAINT events_session_id_check
  CHECK (session_id IS NULL OR char_length(session_id) BETWEEN 1 AND 200);

COMMENT ON COLUMN events.session_id IS 'The asking thread (items.session_id) when the event was written; set by feedback events (issue #1783), NULL otherwise.';
