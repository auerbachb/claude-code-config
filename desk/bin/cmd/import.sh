# shellcheck shell=bash
# summary: preview or apply confirmed answers and comments from an annotated desk export

# shellcheck source=../lib/items.sh
. "$HQ_BIN_DIR/lib/items.sh"
# shellcheck source=../lib/secrets.sh
. "$HQ_BIN_DIR/lib/secrets.sh"
# shellcheck source=../lib/github.sh
. "$HQ_BIN_DIR/lib/github.sh"
# shellcheck source=../lib/lifecycle.sh
. "$HQ_BIN_DIR/lib/lifecycle.sh"

cmd_usage() {
  cat <<'USAGE'
human-queue.sh import — validate transcribed marks against a numbered desk export.

  human-queue.sh import preview SCAN.pdf PROPOSAL.json
  human-queue.sh import apply SCAN.pdf PROPOSAL.json CONFIRMATION

Both commands return JSON. Preview reads only. Apply requires the confirmation
token from the preview approved by the operator. If the scan, proposal, or any
approved queue item changed, apply records nothing. Each item can be imported
only once per scan. Comments are stored verbatim, up to 200 characters.

Proposal: {"scan_sha":"<sha256>","set_id":"31","entries":[
  {"id":"D-43","page":1,"position":2,"option":1,"printed_option":"Yes",
   "comment":null,"unreadable":false}
]}
Use null for absent values. Unreadable rows carry their ID and scan page.
USAGE
}

cmd_run() {
  local apply confirmation="" proposal sha signature comment out errf rc=0
  case "$#:${1:-}" in
    3:preview) apply=false ;;
    4:apply)
      apply=true
      confirmation="$4"
      [[ "$confirmation" =~ ^[0-9a-f]{64}$ ]] || hq_die_validation "import: invalid confirmation token"
      ;;
    *) hq_die_validation "import: expected preview or apply (run human-queue.sh import --help)" ;;
  esac

  [ -f "$2" ] && [ -r "$2" ] || hq_die_validation "import: scan is not a readable file"
  [ -f "$3" ] && [ -r "$3" ] || hq_die_validation "import: proposal is not a readable file"
  signature=$(head -c 5 < "$2") || hq_die_validation "import: scan could not be read"
  [ "$signature" = '%PDF-' ] || hq_die_validation "import: scan must be a PDF"
  sha=$(shasum -a 256 < "$2") || hq_die_error "import: could not hash the scan"
  sha=${sha%% *}

  hq_jq_find || hq_die_error "import: jq not found"
  # Cap the payload before reading or binding it to the psql process.
  proposal=$(head -c 100001 < "$3") || hq_die_validation "import: proposal could not be read"
  if [ "$(printf '%s' "$proposal" | wc -c)" -gt 100000 ]; then
    hq_die_validation "import: proposal exceeds 100000 bytes"
  fi
  proposal=$(printf '%s' "$proposal" | hq_jq -cesS -f "$HQ_BIN_DIR/lib/import.jq" 2>/dev/null) \
    || hq_die_validation "import: malformed proposal"
  [ "$(printf '%s' "$proposal" | hq_jq -r .scan_sha)" = "$sha" ] \
    || hq_die_validation "import: scan has changed since transcription"

  while IFS= read -r comment; do
    comment=$(printf '%s' "$comment" | hq_jq -r '. + "x"')
    comment="${comment%x}"
    hq_refuse_control "import: comment" "$comment" newline
    hq_refuse_secret "import: comment" "$comment"
  done < <(printf '%s' "$proposal" | hq_jq -c '.entries[] | select(.unreadable | not) | .comment | strings')

  hq_db_connect
  hq_mktemp errf
  out=$(hq_db_script -At -v "hq_apply=$apply" -v "hq_data=$proposal" -v "hq_confirmation=$confirmation" \
    < "$HQ_BIN_DIR/lib/import.sql" 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then hq_db_fail "$rc" "$errf" "import: transaction failed"; fi
  hq_problem_check import "$out"
  printf '%s\n' "$out"
}
