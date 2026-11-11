-- psql variables come from the validated proposal. Recheck under item locks
-- in a fresh snapshot so a competing answer or import cannot slip through.
\if :hq_apply
  SET LOCAL lock_timeout TO '30s';
  SELECT count(*) AS hq_locked FROM (
    SELECT id FROM items
     WHERE id IN (SELECT e->>'id' FROM jsonb_array_elements(:'hq_data'::jsonb->'entries') e)
     ORDER BY id FOR UPDATE
  ) locked \gset
\endif

WITH input AS (
  SELECT e.*, count(*) OVER (PARTITION BY e.id) AS copies
  FROM jsonb_to_recordset(:'hq_data'::jsonb->'entries') AS e(
    id text, page integer, position integer, option integer, printed_option text,
    comment text, unreadable boolean)
), checked AS (
  SELECT e.id, e.page, e.option, e.comment, i.options[e.option] AS answer,
         i.xmin::text AS version,
         CASE WHEN e.copies > 1 THEN 'multiple marks for this item'
              WHEN e.unreadable THEN 'ambiguous or illegible handwriting'
              WHEN s.item_id IS NULL THEN 'item number does not match this export set'
              WHEN r.item_id IS NOT NULL THEN 'already imported from this scan'
              WHEN e.option IS NOT NULL AND i.status <> 'open' THEN 'item is no longer open'
              WHEN e.option IS NOT NULL AND
                   (i.kind <> 'decision' OR btrim(regexp_replace(i.options[e.option], '[[:space:]]+', ' ', 'g'))
                     IS DISTINCT FROM btrim(regexp_replace(e.printed_option, '[[:space:]]+', ' ', 'g')))
                THEN 'printed choice does not match the current Decision'
          END AS reason
  FROM input e
  LEFT JOIN sets s ON s.set_id = (:'hq_data'::jsonb->>'set_id')::bigint
                  AND s.position = e.position AND s.item_id = e.id
  LEFT JOIN items i ON i.id = s.item_id
  LEFT JOIN scan_import_receipts r ON r.scan_sha = :'hq_data'::jsonb->>'scan_sha' AND r.item_id = e.id
)
SELECT jsonb_agg(
         CASE WHEN reason IS NULL THEN jsonb_build_object(
           'id', id, 'page', page, 'option', option, 'answer', answer, 'comment', comment, 'version', version)
         ELSE jsonb_build_object('id', id, 'page', page, 'reason', reason) END
         ORDER BY page, id, reason) AS hq_preview
FROM checked \gset

-- Bind confirmation to the scan, proposal, resolved values and item versions.
SELECT encode(sha256(convert_to(:'hq_data' || :'hq_preview', 'UTF8')), 'hex') AS hq_token \gset

\if :hq_apply
  -- psql runs the fixed command locally. The path stays in its environment,
  -- and the second hash is captured after the transaction has locked the rows.
  \set hq_current_sha `unset PGPASSWORD; test -f "$HQ_IMPORT_SCAN" && shasum -a 256 < "$HQ_IMPORT_SCAN" | cut -d ' ' -f 1`
  SELECT :'hq_current_sha' = (:'hq_data'::jsonb->>'scan_sha') AS hq_same_scan \gset
  SELECT :'hq_same_scan'::boolean AND :'hq_token' = :'hq_confirmation' AS hq_confirmed \gset
  \if :hq_confirmed
    WITH approved AS (
      SELECT * FROM jsonb_to_recordset(:'hq_preview'::jsonb) AS e(
        id text, page integer, option integer, answer text, comment text, reason text)
      WHERE reason IS NULL
    ), receipts AS (
      INSERT INTO scan_import_receipts (scan_sha, item_id, page)
      SELECT :'hq_data'::jsonb->>'scan_sha', id, page FROM approved
    ), answered AS (
      UPDATE items i SET answer = a.answer, status = 'answered'
      FROM approved a WHERE i.id = a.id AND a.option IS NOT NULL
      RETURNING i.id, i.answer, i.session_id, a.option
    ), events_written AS (
      INSERT INTO events (item_id, kind, note)
      SELECT id, 'answered', 'option ' || chr(64 + option) FROM answered
      UNION ALL
      SELECT id, 'commented', comment FROM approved WHERE comment IS NOT NULL
    )
    SELECT jsonb_build_object(
      'answers', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', id, 'answer', answer, 'session', session_id, 'changed', true) ORDER BY id) FROM answered), '[]'),
      'comments', coalesce((SELECT jsonb_agg(id ORDER BY id) FROM approved WHERE comment IS NOT NULL), '[]'));
  \else
    SELECT '!scan, proposal, or queue changed since preview; nothing was recorded';
  \endif
\else
  SELECT jsonb_build_object('confirmation', :'hq_token', 'entries',
    (SELECT jsonb_agg(e - 'version' ORDER BY ord)
     FROM jsonb_array_elements(:'hq_preview'::jsonb) WITH ORDINALITY AS rows(e, ord)));
\endif
