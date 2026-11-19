## Environment

| Variable | Meaning |
|----------|---------|
| `HUMAN_QUEUE_DATABASE_URL` | `postgres://` URL of the store. Required; secret |
| `HUMAN_QUEUE_SCHEMA` | Schema every statement runs in (default `public`) for the raw `human-queue.sh` CLI, applied with `SET LOCAL search_path` inside each transaction. The desk entry points (`desk-cli.sh`, the capture hook) honor it only when it names a throwaway `hq_test_*` schema; any other value is ignored and the account's binding governs (see "Account bindings") |
| `HUMAN_QUEUE_BINDINGS_FILE` | The account registry file (default `${XDG_CONFIG_HOME:-~/.config}/human-queue/bindings.tsv`); tests point it at a temp file |
| `HUMAN_QUEUE_PSQL` | `psql` 15+ binary to use (installed Homebrew PostgreSQL 17/16/15 kegs preferred, then `PATH`, libpq kegs and linked Homebrew; explicit override wins) |
| `HUMAN_QUEUE_EXPORT_RENDERER` | `export`'s PDF renderer: `auto` (default: pandoc, then headless Chrome, then cupsfilter), one of those three, or `markdown` (none) |
| `HUMAN_QUEUE_PANDOC`, `HUMAN_QUEUE_CHROME`, `HUMAN_QUEUE_CUPSFILTER` | That renderer's binary; set to anything that is not an executable file, it counts as not installed (tests) |
| `HUMAN_QUEUE_EXPORT_TIMEOUT` | Seconds each `export` renderer may run, 1 to 86400 (defaults: pandoc 120, Chrome 60, cupsfilter 30; any other value keeps them) |
