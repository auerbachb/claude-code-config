-- A scan can be re-previewed, but its annotations apply to each item only once.
CREATE TABLE scan_import_receipts (
  scan_sha text NOT NULL CHECK (scan_sha ~ '^[0-9a-f]{64}$'),
  item_id text NOT NULL REFERENCES items (id) ON DELETE CASCADE,
  page integer NOT NULL CHECK (page > 0),
  PRIMARY KEY (scan_sha, item_id)
);
