#!/usr/bin/env bash
# desk/tests/ideas-offline.test.sh — offline tests for the desk's `idea:` /
# `file:` / `repo:` intent (issue #1766). No database, no network: GitHub is a
# stub (HUMAN_QUEUE_GH, ISSUE_FILE_GH) and the store is a stub CLI
# (HUMAN_QUEUE_CLI) that keeps `state` in a file.
#
# Asserts:
#   idea-target.sh  a repository named in the text wins over the session's
#                   default (as `owner/name` or a GitHub link, any prefix
#                   case); the default is used when the text names none; with
#                   neither it exits 3 with the current directory's repository
#                   as the suggestion (the one question); `repo:` checks and
#                   saves the default, after which an idea needs no question;
#                   the default is checked again for every idea, and one that
#                   lost access or is not OWNER/NAME is not used (exit 3);
#                   a path-like word that is not a repository you can file in
#                   stays in the text, with a note; read-only and
#                   issues-off repositories are refused; an unreachable store
#                   is a note, never a lost repo; the text survives quotes,
#                   $(...), and backticks byte for byte; usage errors exit 4
#   skill blocks    `desk-idea-target` runs as written with the message in
#                   its here-document; `desk-idea-file` files through
#                   issue-file.sh (the desk checkout's own) and then records
#                   `filed OWNER/NAME N`, and on a gh failure records nothing;
#                   it prints `attempt-started`, which the exit-4 recovery
#                   check compares with each candidate's createdAt
#   filed / state   `filed` validates before connecting (exit 4) and reaches
#                   the database step with valid input (exit 7, URL unset);
#                   `state set filed:...` is refused offline
#   layout          SKILL.md routes idea:/file:/repo: to ideas.md; longform.md
#                   and discuss.md let it through; ideas.md asks in plain text
#                   and closes on the URL
# Cases run under `bash` and, when /bin/bash is 3.x (macOS), under /bin/bash.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

REPO_ROOT=$(dirname "$HQ_T_DESK_DIR")
BIN="$HQ_T_DESK_DIR/bin"
SKILL_DIR="$HQ_T_DESK_DIR/skill"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: ideas-offline.test.sh — jq is not installed"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-ideas-offline.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
# issue-file.sh appends each call to $HOME/.claude/script-usage.log: a scratch
# HOME keeps the test's calls out of the developer's real log.
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi

# --- stubs -------------------------------------------------------------------
# gh: `repo view [OWNER/NAME] --json ...` from a small table; `label list` and
# `issue create` for issue-file.sh. Every call is logged.
cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/gh.log"
case "$1 $2" in
  "repo view")
    target="${3:-}"
    case "$target" in
      --json|'') target="<cwd>" ;;
    esac
    case "$target" in
      "<cwd>"|acme/widgets|ACME/Widgets)
        echo '{"nameWithOwner":"acme/widgets","hasIssuesEnabled":true,"viewerPermission":"WRITE"}' ;;
      acme/gadgets) echo '{"nameWithOwner":"acme/gadgets","hasIssuesEnabled":true,"viewerPermission":"ADMIN"}' ;;
      acme/readonly) echo '{"nameWithOwner":"acme/readonly","hasIssuesEnabled":true,"viewerPermission":"READ"}' ;;
      acme/noissues) echo '{"nameWithOwner":"acme/noissues","hasIssuesEnabled":false,"viewerPermission":"ADMIN"}' ;;
      *) echo "GraphQL: Could not resolve to a Repository with the name '$target'." >&2; exit 1 ;;
    esac
    ;;
  "label list") echo '[{"name":"enhancement"},{"name":"skill"}]' ;;
  "issue create")
    if [ "${STUB_CREATE:-ok}" = fail ]; then echo "HTTP 502: Server Error" >&2; exit 1; fi
    echo "https://github.com/acme/widgets/issues/4242"
    ;;
  *) echo "gh-stub: unexpected: $*" >&2; exit 64 ;;
esac
EOF
# The store: `state get|set` in a file (tab-separated), `filed` logged; with
# STUB_STORE=down every call exits 7 as the real CLI does.
cat > "$TMP/cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/cli.log"
if [ "${STUB_STORE:-up}" = down ]; then echo "human-queue: the database is unreachable" >&2; exit 7; fi
f="$STUB_DIR/state.tsv"
touch "$f"
case "$1 ${2:-}" in
  "state get")
    v=$(awk -F '\t' -v k="$3" '$1 == k { v = $2 } END { print v }' "$f")
    if [ -z "$v" ]; then echo "human-queue: state get: no value is set for $3" >&2; exit 4; fi
    printf '%s\n' "$v"
    ;;
  "state set")
    grep -v "^$3	" "$f" > "$f.new"; printf '%s\t%s\n' "$3" "$4" >> "$f.new"; mv "$f.new" "$f"
    ;;
  "filed "*) echo pending ;;
  *) echo "cli-stub: unexpected: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$TMP/gh" "$TMP/cli"
STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR"
export STUB_DIR HUMAN_QUEUE_GH="$TMP/gh" ISSUE_FILE_GH="$TMP/gh" HUMAN_QUEUE_CLI="$TMP/cli"
# desk-cli.sh runs the CLI directly when a URL is in the environment; the stub
# never reads it.
export HUMAN_QUEUE_DATABASE_URL="postgres://stub@db.invalid/hq"

reset_stub() { rm -f "$STUB_DIR"/*.log "$STUB_DIR/state.tsv"; }

# target SHELL SID MESSAGE — runs idea-target.sh with MESSAGE on stdin; sets
# OUT (the JSON), RC, and J_* fields.
target() {
  RC=0
  printf '%s' "$3" | "$1" "$BIN/idea-target.sh" --session "$2" >"$TMP/out" 2>"$TMP/err" || RC=$?
  OUT=$(cat "$TMP/out")
  J_REPO=$(printf '%s' "$OUT" | jq -r '.repo // "null"' 2>/dev/null)
  J_SOURCE=$(printf '%s' "$OUT" | jq -r '.source // "null"' 2>/dev/null)
  J_TEXT=$(printf '%s' "$OUT" | jq -r '.text' 2>/dev/null)
  J_SUGGEST=$(printf '%s' "$OUT" | jq -r '.suggest // "null"' 2>/dev/null)
  J_SAVED=$(printf '%s' "$OUT" | jq -r '.saved' 2>/dev/null)
  J_NOTES=$(printf '%s' "$OUT" | jq -r '.notes | join(" | ")' 2>/dev/null)
  J_VERB=$(printf '%s' "$OUT" | jq -r '.verb' 2>/dev/null)
}

for SH in $SHELLS; do
  printf '== idea-target.sh [%s]\n' "$SH"
  reset_stub
  # No default yet: the one question, with the cwd's repo as the suggestion.
  target "$SH" sess-1 "idea: add a pricing page"
  check "[$SH] no repo yet: exit 3" "$RC" "3"
  check "[$SH] no repo yet: repo null, suggestion from the cwd" "$J_REPO|$J_SUGGEST" "null|acme/widgets"
  check "[$SH] no repo yet: the text is the idea" "$J_TEXT" "add a pricing page"
  check "[$SH] no repo yet: the default was looked up" "$(cat "$STUB_DIR/cli.log")" "state get idea_repo:sess-1"

  # repo: saves the default; then an idea goes there without a question.
  target "$SH" sess-1 "repo: acme/gadgets"
  check "[$SH] repo: exit 0, saved" "$RC|$J_VERB|$J_REPO|$J_SOURCE|$J_SAVED" "0|repo|acme/gadgets|reply|true"
  check "[$SH] repo: stored for this session" "$(cat "$STUB_DIR/state.tsv")" "idea_repo:sess-1	acme/gadgets"
  target "$SH" sess-1 "idea: add a pricing page"
  check "[$SH] after repo:, an idea uses the default" "$RC|$J_REPO|$J_SOURCE" "0|acme/gadgets|default"
  target "$SH" sess-2 "idea: add a pricing page"
  check "[$SH] another desk session has no default" "$RC" "3"

  # A repository named in the text wins over the default.
  : > "$STUB_DIR/cli.log"
  target "$SH" sess-1 "idea: acme/widgets add a pricing page"
  check "[$SH] text-named repo: exit 0" "$RC" "0"
  check "[$SH] text-named repo wins over the default" "$J_REPO|$J_SOURCE" "acme/widgets|text"
  check "[$SH] text-named repo leaves the text" "$J_TEXT" "add a pricing page"
  check "[$SH] text-named repo: the default is not read" "$(cat "$STUB_DIR/cli.log")" ""
  target "$SH" sess-1 "FILE: https://github.com/ACME/Widgets fix the export"
  check "[$SH] a GitHub link, upper-case prefix, GitHub's spelling" "$RC|$J_REPO|$J_TEXT" "0|acme/widgets|fix the export"
  target "$SH" sess-1 "idea: acme/widgets: tidy the README"
  check "[$SH] a repo word with a trailing colon" "$RC|$J_REPO|$J_TEXT" "0|acme/widgets|tidy the README"

  # A path-like word that is not a repository stays in the text.
  target "$SH" sess-1 "idea: desk/skill should load faster"
  check "[$SH] a path stays in the text; the default is used" "$RC|$J_REPO|$J_SOURCE|$J_TEXT" \
    "0|acme/gadgets|default|desk/skill should load faster"
  check_contains "[$SH] a path: noted" "$J_NOTES" "desk/skill was read as part of the idea"
  target "$SH" sess-1 "idea: acme/readonly a thought"
  check "[$SH] a read-only repo is not a target" "$J_REPO|$J_TEXT" "acme/gadgets|acme/readonly a thought"
  check_contains "[$SH] a read-only repo: says why" "$J_NOTES" "you cannot file issues there"

  # repo: refuses what it cannot use, and keeps the old default.
  target "$SH" sess-1 "repo: acme/noissues"
  check "[$SH] repo: issues off: exit 4" "$RC" "4"
  check_contains "[$SH] repo: issues off: says why" "$J_NOTES" "issues are turned off"
  target "$SH" sess-1 "repo: two words"
  check "[$SH] repo: two words: exit 4" "$RC" "4"
  check "[$SH] a refused repo: keeps the default" "$(cat "$STUB_DIR/state.tsv")" "idea_repo:sess-1	acme/gadgets"

  # The saved default is checked again for every idea: one that can no longer
  # take issues is not used, and the desk asks again.
  : > "$STUB_DIR/gh.log"
  target "$SH" sess-1 "idea: add a pricing page"
  check_contains "[$SH] the default is checked again" "$(cat "$STUB_DIR/gh.log")" "repo view acme/gadgets"
  printf 'idea_repo:sess-3\tacme/readonly\n' >> "$STUB_DIR/state.tsv"
  target "$SH" sess-3 "idea: add a pricing page"
  check "[$SH] a default that lost access: exit 3, not used" "$RC|$J_REPO|$J_SUGGEST" "3|null|acme/widgets"
  check_contains "[$SH] a default that lost access: says why" "$J_NOTES" \
    "default repo acme/readonly cannot take ideas now (you cannot file issues there"
  printf 'idea_repo:sess-4\t--jq=.\n' >> "$STUB_DIR/state.tsv"
  : > "$STUB_DIR/gh.log"
  target "$SH" sess-4 "idea: add a pricing page"
  check "[$SH] a malformed default: exit 3, not used" "$RC|$J_REPO" "3|null"
  check_contains "[$SH] a malformed default: says why" "$J_NOTES" "cannot take ideas now (not OWNER/NAME)"
  check_absent "[$SH] a malformed default never reaches gh" "$(cat "$STUB_DIR/gh.log")" "--jq=."

  # The store unreachable: a note, never a lost repo.
  STUB_STORE=down target "$SH" sess-1 "repo: acme/widgets"
  check "[$SH] store down, repo: exit 0, not saved" "$RC|$J_REPO|$J_SAVED" "0|acme/widgets|false"
  check_contains "[$SH] store down, repo: says so" "$J_NOTES" "the store is unreachable"
  STUB_STORE=down target "$SH" sess-1 "idea: something"
  check "[$SH] store down, idea: asks (exit 3)" "$RC|$J_SUGGEST" "3|acme/widgets"
  check_contains "[$SH] store down, idea: says the default could not be read" "$J_NOTES" "could not be read"

  # Text arrives byte for byte.
  RAW='idea: acme/widgets keep "quotes", $(not run), `ticks` and \back\slashes'
  target "$SH" sess-1 "$RAW"
  check "[$SH] metacharacters survive" "$J_TEXT" 'keep "quotes", $(not run), `ticks` and \back\slashes'

  # Usage.
  target "$SH" sess-1 "just a thought"
  check "[$SH] no prefix: exit 4" "$RC" "4"
  target "$SH" sess-1 "idea:   "
  check "[$SH] empty idea: exit 4" "$RC" "4"
  target "$SH" sess-1 "idea: acme/widgets"
  check "[$SH] only a repo: exit 4" "$RC" "4"
  RC=0
  printf 'idea: x' | "$SH" "$BIN/idea-target.sh" >/dev/null 2>&1 || RC=$?
  check "[$SH] no --session: exit 4" "$RC" "4"
done

# --- the skill's blocks --------------------------------------------------------
printf '== skill blocks\n'
block() {
  local out rc=0
  out=$(hq_t_skill_block "$SKILL_DIR/$1" "$2" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "anchor $2 extracts (rc=$rc: $out)"
    return 1
  fi
  printf '%s\n' "$out" > "$TMP/block-$2.sh"
}
literal() { FROM="$2" TO="$3" perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$1"; }
# with_file BLOCK PLACEHOLDER FILE — the placeholder line replaced by FILE.
with_file() {
  awk -v ph="$2" -v rf="$3" '$0 == ph { while ((getline l < rf) > 0) print l; next } { print }' "$1"
}
run_block() {
  (cd "$TMP" && env DESK="$HQ_T_DESK_DIR" HQ="$TMP/hq" SID=sess-9 bash "$1") 2>&1
}

block ideas.md desk-idea-target
block ideas.md desk-idea-file
reset_stub
printf '%s' 'idea: acme/widgets a $(quoted) idea' > "$TMP/msg"
with_file "$TMP/block-desk-idea-target.sh" "<the operator's message, exactly as typed>" "$TMP/msg" > "$TMP/t.sh"
OUT=$(run_block "$TMP/t.sh")
check "desk-idea-target: the JSON, then exit=0" "$(printf '%s\n' "$OUT" | sed -n 2p)" "exit=0"
check "desk-idea-target: repo and text from the here-document" \
  "$(printf '%s\n' "$OUT" | sed -n 1p | jq -r '"\(.repo)|\(.text)"')" 'acme/widgets|a $(quoted) idea'

# desk-idea-file: HQ is a stub that logs `filed`.
cat > "$TMP/hq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/hq.log"
echo pending
EOF
chmod +x "$TMP/hq"
"$REPO_ROOT/.claude/scripts/issue-file.sh" --template > "$TMP/body.md"
printf '%s\n' "Desk: export \"widgets\" as CSV" > "$TMP/title.txt"
literal "$TMP/block-desk-idea-file.sh" "<owner/name>" "acme/widgets" \
  | literal /dev/stdin "<the labels>" "--label 'skill' --label 'nope'" > "$TMP/f1.sh"
with_file "$TMP/f1.sh" "<the title>" "$TMP/title.txt" > "$TMP/f2.sh"
with_file "$TMP/f2.sh" "<the body>" "$TMP/body.md" > "$TMP/file.sh"
reset_stub
OUT=$(run_block "$TMP/file.sh")
check_contains "desk-idea-file: issue-file.sh succeeded" "$OUT" "file-exit=0"
check "desk-idea-file: the JSON names the URL and labels" \
  "$(printf '%s\n' "$OUT" | grep '^{' | jq -r '"\(.url)|\(.labels | join(","))|\(.dropped_labels[0].label)"')" \
  "https://github.com/acme/widgets/issues/4242|skill|nope"
check "desk-idea-file: then records the filing" "$(cat "$STUB_DIR/hq.log" 2>/dev/null)" "filed acme/widgets 4242"
check_contains "desk-idea-file: filed-exit=0" "$OUT" "filed-exit=0"
STARTED=$(printf '%s\n' "$OUT" | sed -n 's/^attempt-started=//p')
check "desk-idea-file: prints when the attempt began (UTC, ISO 8601)" \
  "$(printf '%s\n' "$STARTED" | grep -c '^[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$')" "1"
NOW_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RECENT_UTC=$(date -u -d '45 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-45S +%Y-%m-%dT%H:%M:%SZ)
# The real start, not backdated: no later than now, and within the last 45 s.
if [[ ! "$STARTED" > "$NOW_UTC" ]] && [[ ! "$STARTED" < "$RECENT_UTC" ]]; then
  ok "desk-idea-file: attempt-started is the real start time"
else
  bad "desk-idea-file: attempt-started '$STARTED' is outside [$RECENT_UTC, $NOW_UTC]"
fi
check_contains "desk-idea-file: the title reached gh whole" "$(cat "$STUB_DIR/gh.log")" '--title=Desk: export "widgets" as CSV'
reset_stub
OUT=$(STUB_CREATE=fail run_block "$TMP/file.sh")
check_contains "desk-idea-file, gh fails: file-exit=4" "$OUT" "file-exit=4"
check "desk-idea-file, gh fails: nothing recorded" "$(cat "$STUB_DIR/hq.log" 2>/dev/null)" ""
check_absent "desk-idea-file, gh fails: no URL printed" "$OUT" "https://github.com/acme/widgets/issues/4242"
OUT=$(cd "$TMP" && env DESK="$TMP/no-desk" HQ="$TMP/hq" HOME="$TMP/no-home" bash "$TMP/file.sh" 2>&1)
check_contains "desk-idea-file: no issue-file.sh is one ERROR line" "$OUT" "ERROR: issue-file.sh not found"

# --- filed and state, offline ----------------------------------------------------
BLACKHOLE_URL="postgresql://u:pw@192.0.2.1:5432/db?sslmode=require"
# expect_4 SHELL ARGS... — exit 4 with one stderr line, before connecting (the
# black-hole address would take seconds to time out).
expect_4() {
  local sh="$1" start end rc=0
  shift
  start=$(hq_t_now)
  env HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" "$sh" "$HQ_T_CLI" "$@" >"$TMP/out" 2>"$TMP/err" </dev/null || rc=$?
  end=$(hq_t_now)
  check "[$sh] '$*' exits 4" "$rc" "4"
  check "[$sh] '$*': one stderr line" "$(hq_t_lines "$(cat "$TMP/err")")" "1"
  if hq_t_elapsed_under "$start" "$end" 1.0; then ok "[$sh] '$*': no connection attempt"; else bad "[$sh] '$*' tried to connect"; fi
}
for SH in $SHELLS; do
  printf '== filed / state validation [%s]\n' "$SH"
  expect_4 "$SH" filed
  expect_4 "$SH" filed acme/widgets
  expect_4 "$SH" filed "acme widgets" 3
  expect_4 "$SH" filed acme/widgets 0
  expect_4 "$SH" filed acme/widgets 12x
  expect_4 "$SH" filed acme/widgets 3 4
  expect_4 "$SH" filed acme/widgets 3 --bogus
  expect_4 "$SH" state set filed:acme/widgets:issue-3 x
  RC=0
  env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" filed acme/widgets 3 --json >/dev/null 2>&1 || RC=$?
  check "[$SH] valid filed reaches the database step (exit 7, URL unset)" "$RC" "7"
  RC=0
  env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" filed --help >"$TMP/out" 2>/dev/null || RC=$?
  check "[$SH] filed --help is offline" "$RC" "0"
  check_contains "[$SH] filed --help names the event" "$(cat "$TMP/out")" "filed from the desk"
done
check_contains "human-queue.sh --help lists filed" "$(env -u HUMAN_QUEUE_DATABASE_URL bash "$HQ_T_CLI" --help 2>&1)" "filed"

# --- layout ----------------------------------------------------------------------
printf '== layout\n'
SKILL=$(cat "$SKILL_DIR/SKILL.md")
IDEAS=$(cat "$SKILL_DIR/ideas.md")
check_contains "SKILL.md: ideas.md in the table" "$SKILL" '| `ideas.md` |'
check_contains "SKILL.md: idea:/file:/repo: route to ideas.md" "$SKILL" '**`idea: …`**, **`file: …`**, or **`repo: …`** (any case) → load `ideas.md`'
check_contains "longform.md: idea: is not a long-form answer" "$(cat "$SKILL_DIR/longform.md")" '`ideas.md`, then print this part'"'"'s card again'
check_contains "discuss.md: idea: during a discussion" "$(cat "$SKILL_DIR/discuss.md")" '`ideas.md`, then go on discussing'
check_contains "ideas.md: never the menu tool" "$IDEAS" "plain text, never AskUserQuestion"
check_contains "ideas.md: the URL is the closing line" "$IDEAS" "The issue URL as the closing line"
check_contains "ideas.md: no capture mode" "$IDEAS" "There is no capture mode"
check_contains "ideas.md: records the filing" "$IDEAS" '"$HQ" filed "$IDEA_REPO"'
check_contains "ideas.md: the exit-4 check reads createdAt" "$IDEAS" '--json number,title,url,createdAt'
check_contains "ideas.md: the exit-4 check compares with attempt-started" "$IDEAS" 'against the block'"'"'s `attempt-started`'
check_contains "ideas.md: only an issue created at or after the start is recorded" "$IDEAS" '`createdAt` at or after it → it was filed'
check_contains "ideas.md: a match just before the start is uncertain, never recorded" "$IDEAS" '`createdAt` in the minute before it → **uncertain**'
check_contains "ideas.md: an uncertain match can be confirmed" "$IDEAS" 'Reply idea: yes if it is this idea'
check_contains "ideas.md: idea: yes records the confirmed issue" "$IDEAS" '`yes` → only after a `Possibly filed as #N` card'
check_absent "ideas.md: no bare repo-relative script path" "$IDEAS" '".claude/scripts/'

hq_t_finish "ideas-offline.test.sh"
