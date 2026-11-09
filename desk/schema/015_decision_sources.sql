-- External Decision captures are replay-safe even after the item is answered.
-- Their identity is separate from the historical question dedupe, so two
-- tools never replace each other's return address for the same question.
ALTER TABLE items
  ADD COLUMN source_tool text,
  ADD COLUMN source_account text,
  ADD COLUMN return_route text,
  ADD COLUMN capture_key text,
  ADD CONSTRAINT items_external_decision_source_check CHECK (
    (source_tool IS NULL AND source_account IS NULL AND return_route IS NULL
      AND capture_key IS NULL)
    OR (kind = 'decision' AND source_tool IS NOT NULL
        AND source_tool IN ('codex', 'cursor', 'local')
        AND source_account IS NOT NULL AND char_length(source_account) BETWEEN 1 AND 32
        AND source_account !~ '[[:cntrl:]]'
        AND capture_key IS NOT NULL AND capture_key ~ '^[0-9a-f]{64}$'
        AND ((return_route IS NULL AND session_id IS NULL)
             OR (source_tool = 'codex' AND return_route IS NOT NULL
                 AND return_route ~ '^[0-9a-f]{64}$' AND session_id IS NOT NULL
                 AND session_id ~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')))
  );

DROP INDEX items_open_question_key;
CREATE UNIQUE INDEX items_open_question_key
  ON items (kind, repo, key, item_question_hash(question))
  WHERE status = 'open' AND capture_key IS NULL;
CREATE UNIQUE INDEX items_external_capture_key
  ON items (capture_key) WHERE capture_key IS NOT NULL;
