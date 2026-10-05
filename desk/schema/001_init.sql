-- 001_init.sql — the human-queue store's first schema (issue #1774).
--
-- Applied by `human-queue.sh migrate` inside one transaction together with its
-- schema_migrations row; this file therefore carries no BEGIN/COMMIT. Table
-- names are unqualified so HUMAN_QUEUE_SCHEMA (search_path) picks the schema.
-- Never edit this file after it merges: add a new NNN_<name>.sql instead.
--
-- Item ids (D-n / R-n) and set ids are allocated by the subcommands that write
-- them (issues #1775, #1776), in their own migrations.

-- Decisions (need the operator, hold an agent) and Reviews (landed work),
-- one table, one triage contract.
CREATE TABLE items (
  id              text        PRIMARY KEY,
  kind            text        NOT NULL,
  repo            text        NOT NULL,
  key             text        NOT NULL,
  session_id      text,
  question        text        NOT NULL,
  context         text[]      NOT NULL DEFAULT '{}',
  options         text[]      NOT NULL DEFAULT '{}',
  default_option  text,
  default_at      timestamptz,
  impact_declared text,
  parked          boolean     NOT NULL DEFAULT false,
  cost            text,
  focus           text,
  status          text        NOT NULL DEFAULT 'open',
  answer          text,
  summary_l2      text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT items_kind_check
    CHECK (kind IN ('decision', 'review')),
  -- Short, typeable ids whose prefix matches the kind: D-43, R-88.
  CONSTRAINT items_id_format_check
    CHECK (id ~ '^[DR]-[1-9][0-9]*$'),
  CONSTRAINT items_id_kind_check
    CHECK ((kind = 'decision' AND id LIKE 'D-%') OR (kind = 'review' AND id LIKE 'R-%')),
  CONSTRAINT items_repo_check
    CHECK (repo ~ '^[^/[:space:]]+/[^/[:space:]]+$'),
  CONSTRAINT items_key_check
    CHECK (char_length(key) BETWEEN 1 AND 200),
  CONSTRAINT items_session_id_check
    CHECK (session_id IS NULL OR char_length(session_id) BETWEEN 1 AND 200),
  -- One sentence, rendered in bold on one line.
  CONSTRAINT items_question_check
    CHECK (char_length(question) BETWEEN 1 AND 500 AND question !~ '[\r\n]'),
  -- Context: up to three single-line entries, 600 characters in total.
  CONSTRAINT items_context_check
    CHECK (
      cardinality(context) <= 3
      AND (cardinality(context) = 0 OR array_ndims(context) = 1)
      AND array_position(context, NULL) IS NULL
      AND char_length(array_to_string(context, '')) <= 600
      AND array_to_string(context, '') !~ '[\r\n]'
    ),
  -- Options are answered by letter ("2: B"), so at most 26.
  CONSTRAINT items_options_check
    CHECK (
      cardinality(options) <= 26
      AND (cardinality(options) = 0 OR array_ndims(options) = 1)
      AND array_position(options, NULL) IS NULL
    ),
  CONSTRAINT items_impact_declared_check
    CHECK (impact_declared IS NULL OR impact_declared IN ('low', 'medium', 'high')),
  CONSTRAINT items_status_check
    CHECK (status IN ('open', 'answered', 'acknowledged', 'reviewed', 'flagged', 'closed')),
  CONSTRAINT items_updated_after_created_check
    CHECK (updated_at >= created_at)
);

COMMENT ON TABLE items IS 'Human-queue items: Decisions (D-n) and Reviews (R-n). Keyed on repo + key (PR or issue); session_id is only the return address.';
COMMENT ON COLUMN items.key IS 'The PR or issue the item belongs to within repo; sessions die, PRs persist.';
COMMENT ON COLUMN items.session_id IS 'Return address of the asking session (Decisions); NULL for Reviews.';
COMMENT ON COLUMN items.context IS 'Up to three single-line context entries, 600 characters in total, rendered as a numbered list.';
COMMENT ON COLUMN items.options IS 'Enumerated answer options, answered by letter.';
COMMENT ON COLUMN items.default_option IS 'The recommended default the agent takes if nobody answers.';
COMMENT ON COLUMN items.default_at IS 'When the agent takes default_option.';
COMMENT ON COLUMN items.impact_declared IS 'Impact as declared by the asker (low, medium, high); derived impact is issue #1760.';
COMMENT ON COLUMN items.parked IS 'True while the asking agent is parked waiting on this item.';
COMMENT ON COLUMN items.cost IS 'Operator effort to answer, as declared (for example "~10 min").';
COMMENT ON COLUMN items.focus IS 'Attention the item needs, as declared (for example "no deep focus").';
COMMENT ON COLUMN items.summary_l2 IS 'Twenty-line summary, generated once and cached.';
COMMENT ON COLUMN items.updated_at IS 'Maintained by trigger; tick reads "changed since" from it.';

-- Keep updated_at honest without trusting every writer to set it.
CREATE FUNCTION items_touch_updated_at() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := greatest(now(), NEW.created_at);
  RETURN NEW;
END;
$$;

CREATE TRIGGER items_touch_updated_at
  BEFORE UPDATE ON items
  FOR EACH ROW EXECUTE FUNCTION items_touch_updated_at();

-- State changes only — never transcripts or diffs.
CREATE TABLE events (
  id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  item_id text        NOT NULL REFERENCES items (id) ON DELETE CASCADE,
  kind    text        NOT NULL,
  at      timestamptz NOT NULL DEFAULT now(),
  note    text,

  CONSTRAINT events_kind_check
    CHECK (kind IN ('asked', 'bumped', 'shown', 'answered', 'acknowledged',
                    'reviewed', 'flagged', 'feedback', 'commented')),
  CONSTRAINT events_note_check
    CHECK (note IS NULL OR char_length(note) <= 200)
);

CREATE INDEX events_item_id_at_idx ON events (item_id, at);

COMMENT ON TABLE events IS 'One row per item state change. No transcripts, no diffs.';

-- A presented batch, numbered 1..n, so "2: B" maps back to an item.
CREATE TABLE sets (
  set_id   bigint      NOT NULL,
  position smallint    NOT NULL,
  item_id  text        NOT NULL REFERENCES items (id) ON DELETE CASCADE,
  shown_at timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (set_id, position),
  CONSTRAINT sets_item_once_per_set UNIQUE (set_id, item_id),
  CONSTRAINT sets_set_id_check CHECK (set_id >= 1),
  CONSTRAINT sets_position_check CHECK (position >= 1)
);

COMMENT ON TABLE sets IS 'Numbered batches shown to the operator; position is the 1..n number they reply with.';

-- Operator state and the day plan.
CREATE TABLE state (
  key   text PRIMARY KEY,
  value text NOT NULL,

  CONSTRAINT state_key_check CHECK (char_length(key) BETWEEN 1 AND 200)
);

COMMENT ON TABLE state IS 'Key/value operator state: day plan, tick watermark, control session.';
