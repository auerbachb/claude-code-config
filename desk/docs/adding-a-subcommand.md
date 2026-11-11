## Adding a subcommand

Add `bin/cmd/<name>.sh` (name: `[a-z][a-z0-9-]*`). The dispatcher finds it; do
not edit `human-queue.sh`. The file:

- starts with `# shellcheck shell=bash` and a `# summary: <one line>` header,
  which `human-queue.sh --help` lists;
- defines `cmd_usage` (printed for `<name> --help`) and `cmd_run "$@"`;
- validates its arguments first (exit 4 through `hq_die_validation`), then calls
  `hq_db_connect`, then runs SQL through `hq_db_script` (one transaction in the
  selected schema) or `hq_psql`, mapping failures with `hq_db_fail`;
- sources `lib/items.sh` for ids, input checks, and the item renderer, and
  `lib/secrets.sh` (`hq_refuse_secret`) for any free text it stores; values
  reach SQL only as quoted psql variables (`:'name'`). Pass application bindings as `-v hq_name=value` to `hq_db_script`/`hq_psql`; the shared boundary removes them from argv and uses psql 15+ `\getenv` with exports scoped to the psql child. Never interpolate text into SQL. The client version check shares the connection probe's deadline and fails with exit 7 for older or unreadable clients. The server still requires PostgreSQL 16+.
