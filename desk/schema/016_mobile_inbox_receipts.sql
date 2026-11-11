-- Idempotence and wake recovery for explicitly imported mobile replies.
-- Store provider identifiers and event references, never the remote comment.
CREATE TABLE mobile_inbox_receipts (
  mirror_repo_id bigint NOT NULL CHECK (mirror_repo_id > 0),
  remote_comment_id bigint NOT NULL CHECK (remote_comment_id > 0),
  item_id text NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  action text NOT NULL CHECK (action IN ('answer', 'reviewed')),
  item_event_id bigint NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  PRIMARY KEY (mirror_repo_id, remote_comment_id),
  UNIQUE (item_event_id)
);
