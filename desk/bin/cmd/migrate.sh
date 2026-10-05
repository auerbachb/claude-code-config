# shellcheck shell=bash
# summary: apply desk/schema/NNN_*.sql in lexical order, one transaction per file
#
# Sourced by desk/bin/human-queue.sh, which has already loaded lib/common.sh
# and lib/db.sh and set HQ_DESK_DIR.

cmd_usage() {
  cat <<'EOF'
human-queue.sh migrate — apply pending schema migrations.

USAGE
  human-queue.sh migrate

BEHAVIOR
  Applies desk/schema/NNN_<name>.sql files in lexical (LC_ALL=C) order. Each
  pending file runs in its own transaction together with its ledger row in
  schema_migrations, so a failing file leaves nothing behind. Files are
  recorded by FULL filename: two branches that both add a 002_ file never
  collide. Re-running applies nothing. Concurrent runs serialize on an
  advisory lock; the later one finds the work done.
  Runs in HUMAN_QUEUE_SCHEMA (default public), creating it if missing.

OUTPUT
  One `applied <filename>` line per applied file, or `nothing to apply`.

EXIT CODES
  0  ok
  1  a migration failed (its transaction rolled back) or a schema file is
     misnamed
  4  unexpected argument or invalid HUMAN_QUEUE_SCHEMA
  7  database unset or unreachable (within two seconds, one line on stderr)
EOF
}

# hq__migration_files — prints schema file basenames, LC_ALL=C sorted.
# Exits 1 (in the caller's $(...)) on a misnamed file or an empty directory.
hq__migration_files() {
  local LC_ALL=C f base found=0
  for f in "$HQ_DESK_DIR"/schema/*.sql; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    case "$base" in
      [0-9][0-9][0-9]_*.sql) ;;
      *) hq_die_error "migrate: schema file '$base' is not named NNN_<name>.sql" ;;
    esac
    case "${base#[0-9][0-9][0-9]_}" in
      .sql|*[!a-z0-9_]*.sql)
        hq_die_error "migrate: schema file '$base' must match [0-9]{3}_[a-z0-9_]+.sql"
        ;;
    esac
    found=1
    printf '%s\n' "$base"
  done
  if [ "$found" -eq 0 ]; then
    hq_die_error "migrate: no migrations found in $HQ_DESK_DIR/schema"
  fi
}

# The SQL lives in functions, not in heredocs inside $(...): bash 3.2's
# command-substitution scanner does not understand here-documents.

# Schema + ledger, under the same lock every apply step takes; prints the
# filenames already applied.
hq__sql_bootstrap() {
  cat <<'SQL'
SET LOCAL lock_timeout TO '30s';
SELECT pg_advisory_xact_lock(hashtext('human-queue:migrate:' || :'hq_schema')) AS hq_locked \gset
SELECT NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = :'hq_schema') AS hq_need_schema \gset
\if :hq_need_schema
CREATE SCHEMA :"hq_schema";
SET LOCAL search_path TO :"hq_schema";
\endif
CREATE TABLE IF NOT EXISTS schema_migrations (
  filename   text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
SELECT filename FROM schema_migrations ORDER BY filename;
SQL
}

# One file plus its ledger row. The ledger is re-checked INSIDE the lock, so a
# concurrent run that got there first turns this into a no-op, not a failure.
hq__sql_apply() {
  cat <<'SQL'
SET LOCAL lock_timeout TO '30s';
SELECT pg_advisory_xact_lock(hashtext('human-queue:migrate:' || :'hq_schema')) AS hq_locked \gset
SELECT NOT EXISTS (SELECT 1 FROM schema_migrations WHERE filename = :'hq_file') AS hq_pending \gset
\if :hq_pending
\i :hq_path
INSERT INTO schema_migrations (filename) VALUES (:'hq_file');
\echo applied :hq_file
\endif
SQL
}

cmd_run() {
  local files applied file errf out rc n_applied=0

  if [ "$#" -gt 0 ]; then
    hq_die_validation "migrate: unexpected argument '$1' (run human-queue.sh migrate --help)"
  fi

  files=$(hq__migration_files) || exit "$?"
  hq_db_connect

  hq_mktemp errf

  rc=0
  applied=$(hq__sql_bootstrap | hq_db_script -At 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    hq_db_fail "$rc" "$errf" "migrate: cannot read schema_migrations"
  fi

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if grep -qxF -- "$file" <<<"$applied"; then
      continue
    fi
    rc=0
    out=$(hq__sql_apply | hq_db_script -At \
      -v "hq_file=$file" \
      -v "hq_path=$HQ_DESK_DIR/schema/$file" \
      2>"$errf") || rc=$?
    if [ "$rc" -ne 0 ]; then
      hq_db_fail "$rc" "$errf" "migrate: $file failed and was rolled back"
    fi
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      n_applied=$((n_applied + 1))
    fi
  done <<EOF
$files
EOF

  if [ "$n_applied" -eq 0 ]; then
    printf 'nothing to apply\n'
  fi
}
