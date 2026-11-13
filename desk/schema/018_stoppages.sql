-- 018_stoppages.sql — one short entry for every unplanned work stoppage
-- (issue #2292).
--
-- Applied by `human-queue.sh migrate` inside one transaction together with its
-- schema_migrations row; no BEGIN/COMMIT. Names are unqualified so
-- HUMAN_QUEUE_SCHEMA (search_path) picks the schema. Never edit this file after
-- it merges: add a new NNN_<name>.sql instead.
--
-- An entry is the stop time, the thread (a session id), the repo, an issue or
-- PR reference, a cause from a fixed list, and one line of evidence. The idle
-- time is added when the work resumes. A correction from the operator is kept
-- beside the original cause, never over it. Nothing else is stored: no
-- transcript text and no secrets. The private database is the only home of
-- these entries; they are never written to GitHub or to a file in the repo.
--
-- dedupe_key makes a retry safe: an entry kept locally while the database was
-- unreachable can be sent again any number of times and lands once.
CREATE TABLE stoppages (
  id bigserial PRIMARY KEY,
  dedupe_key text NOT NULL UNIQUE CHECK (dedupe_key ~ '^[0-9a-f]{32}$'),
  stopped_at timestamptz NOT NULL,
  thread text NOT NULL CHECK (thread ~ '^[A-Za-z0-9_.:-]{1,200}$'),
  repo text NOT NULL CHECK (repo = 'unknown' OR repo ~ '^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$'),
  ref text CHECK (ref ~ '^(issue|pr)#[1-9][0-9]{0,8}$'),
  cause text NOT NULL CHECK (cause IN ('out_of_work', 'waiting_on_review',
                                       'waiting_on_operator', 'usage_limit',
                                       'token_exhaustion', 'blocked_by_error',
                                       'crash', 'unknown')),
  evidence text NOT NULL CHECK (char_length(evidence) BETWEEN 1 AND 200
                                AND evidence !~ '[[:cntrl:]]'),
  source text NOT NULL CHECK (source IN ('hook', 'go-on', 'manual')),
  resumed_at timestamptz,
  idle_seconds integer CHECK (idle_seconds >= 0),
  corrected_cause text CHECK (corrected_cause IN ('out_of_work', 'waiting_on_review',
                                                  'waiting_on_operator', 'usage_limit',
                                                  'token_exhaustion', 'blocked_by_error',
                                                  'crash', 'unknown')),
  correction_note text CHECK (char_length(correction_note) <= 300
                              AND correction_note !~ '[[:cntrl:]]'),
  corrected_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((resumed_at IS NULL) = (idle_seconds IS NULL))
);

CREATE INDEX stoppages_stopped_at_idx ON stoppages (stopped_at);
CREATE INDEX stoppages_thread_idx ON stoppages (thread, stopped_at DESC);
