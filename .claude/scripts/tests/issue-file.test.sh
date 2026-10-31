#!/usr/bin/env bash
# Offline tests for issue-file.sh, the shared one-shot filing script (issue #1766).
# catalog: tests — Exercises issue-file.sh's section, footer, title, and label checks against a stubbed gh, and the /issue-maker create block that calls it
#
# WHAT IS UNDER TEST
#   1. `.claude/scripts/issue-file.sh` against a gh stub (ISSUE_FILE_GH):
#      a valid body files and prints the URL; each check (a missing or
#      out-of-order section, a footer that is not the last line, a long,
#      blank, or multi-line title) exits 3 with NO gh call at all; labels
#      the repo lacks and the four /pm skips are dropped and named; every gh
#      call carries --repo and none carries --assignee; a gh failure and a URL
#      for another repo exit 4 with nothing on stdout; --dry-run creates
#      nothing; --template passes its own checks.
#   2. The REAL `issue-maker-create` block from /issue-maker's create/file.md module
#      (extracted by lib/skill-bash.sh), run with HOME pointing at a scratch
#      tree whose skills-worktree holds this repo's issue-file.sh: it files
#      through the script, refreshes ACCEPTED_LABELS from what was applied,
#      and on a failure leaves ISSUE_URL empty.
#   3. The shared-entry contract (AC 4.1): the desk's `desk-idea-file` block
#      calls the same script, and both skills point at
#      references/one-shot-filing.md.
#
# Requires: bash 3.2+, jq. Offline: no network, no real gh.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.claude/scripts/tests/lib/skill-bash.sh
. "$TEST_DIR/lib/skill-bash.sh"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
SCRIPT="$SCRIPTS_DIR/issue-file.sh"
SKILL_MD="$REPO_ROOT/.claude/skills/issue-maker/modules/create/file.md"
REFLECT_MD="$REPO_ROOT/.claude/skills/issue-maker/modules/create/reflect-and-draft.md"
ONE_SHOT="$REPO_ROOT/.claude/skills/issue-maker/references/one-shot-filing.md"
IDEAS_MD="$REPO_ROOT/desk/skill/ideas.md"

PASS=0
FAIL=0
pass() { echo "ok   — $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL — $1" >&2; FAIL=$((FAIL + 1)); }
check_eq() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
check_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (expected to contain '$2', got '$3')" ;; esac; }
check_not_contains() { case "$3" in *"$2"*) fail "$1 (expected NOT to contain '$2')" ;; *) pass "$1" ;; esac; }

# Negative control: helpers that cannot fail are not assertions.
check_eq "negative control" "a" "b" >/dev/null 2>&1
check_contains "negative control" "needle" "haystack" >/dev/null 2>&1
check_not_contains "negative control" "hay" "haystack" >/dev/null 2>&1
if [ "$FAIL" -ne 3 ] || [ "$PASS" -ne 0 ]; then
  echo "FAIL — negative control: helpers did not register 3 failures (got $FAIL/$PASS)" >&2
  exit 1
fi
FAIL=0; PASS=0

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required" >&2; exit 1; }
[ -x "$SCRIPT" ] || { echo "FATAL: $SCRIPT is not executable" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/issue-file-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
# issue-file.sh appends each call to $HOME/.claude/script-usage.log: a scratch
# HOME keeps the test's calls out of the developer's real log.
export HOME="$TMP/test-home"
mkdir -p "$HOME/.claude"
mkdir -p "$TMP/bin"

# --- the gh stub -----------------------------------------------------------
# STUB_MODE: ok (default) | create-fail | wrong-repo | labels-fail
GH_STUB="$TMP/gh"
cat > "$GH_STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1 $2" in
  "label list")
    if [ "${STUB_MODE:-ok}" = labels-fail ]; then echo "HTTP 502" >&2; exit 1; fi
    printf '[{"name":"enhancement"},{"name":"Skill"},{"name":"blocked"},{"name":"docs"}]\n'
    ;;
  "issue create")
    # Preserve the attempted body for the lost-response fixture below.
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--body-file" ]; then cp "$a" "$STUB_BODY"; fi
      prev="$a"
    done
    case "${STUB_MODE:-ok}" in
      create-fail) echo "GraphQL: Could not resolve to a Repository" >&2; exit 1 ;;
      create-uncertain) echo "connection dropped after create" >&2; exit 1 ;;
      wrong-repo) echo "https://github.com/someone/else/issues/9" ;;
      *) echo "Creating issue in acme/widgets"; echo "https://github.com/acme/widgets/issues/4242" ;;
    esac
    # Keep the body the script sent, to check it arrived whole.
    prev=""
    for a in "$@"; do
      case "$a" in --body-file=*) cp "${a#--body-file=}" "$STUB_BODY" ;; esac
      if [ "$prev" = "--body-file" ]; then cp "$a" "$STUB_BODY"; fi
      prev="$a"
    done
    ;;
  "issue list")
    if [ "${STUB_MODE:-ok}" = create-uncertain ]; then
      jq -nc --rawfile body "$STUB_BODY" --arg created "2099-01-01T00:00:01Z" \
        '[{number:4242,url:"https://github.com/acme/widgets/issues/4242",title:"An idea",body:$body,createdAt:$created,labels:[{name:"Skill"}]}]'
    else
      printf '[]\n'
    fi
    ;;
  *) echo "gh-stub: unexpected: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$GH_STUB"
ln -s "$GH_STUB" "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export STUB_LOG="$TMP/calls.log" STUB_BODY="$TMP/sent-body.md" ISSUE_FILE_GH="$GH_STUB"

# run ARGS... — sets OUT, ERR, RC; the stub log starts empty each time.
run() {
  : > "$STUB_LOG"
  rm -f "$STUB_BODY"
  RC=0
  "$SCRIPT" "$@" >"$TMP/out" 2>"$TMP/err" || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
  CALLS=$(cat "$STUB_LOG")
}

VALID="$TMP/valid.md"
"$SCRIPT" --template > "$VALID"
check_eq "--template exits 0" "0" "$?"
check_eq "--template ends with the footer" "_Captured via /issue-maker._" "$(tail -n 1 "$VALID")"

# --- 1. a valid filing --------------------------------------------------------
STUB_MODE=ok run --repo acme/widgets --title "Desk — file an idea from anywhere" --body-file "$VALID"
check_eq "valid: exit 0" "0" "$RC"
check_eq "valid: stdout is the URL alone" "https://github.com/acme/widgets/issues/4242" "$OUT"
check_eq "valid: one gh call (no labels asked for)" "1" "$(printf '%s\n' "$CALLS" | grep -c .)"
check_contains "valid: created with --repo" "issue create --repo acme/widgets" "$CALLS"
check_contains "valid: title as one --title= argument" "--title=Desk — file an idea from anywhere" "$CALLS"
check_eq "valid: the body arrived whole" "$(cat "$VALID")" "$(cat "$STUB_BODY" 2>/dev/null)"

STUB_MODE=ok run --repo acme/widgets --title "Labels" --body-file "$VALID" \
  --label skill --label nope --label Blocked --label enhancement --label SKILL --json
check_eq "labels: exit 0" "0" "$RC"
check_eq "labels: applied in the repo's spelling, deduplicated" '["Skill","enhancement"]' "$(printf '%s' "$OUT" | jq -c '.labels')"
check_eq "labels: dropped with reasons" \
  '[{"label":"Blocked","reason":"hides the issue from /pm"},{"label":"nope","reason":"not a label in acme/widgets"}]' \
  "$(printf '%s' "$OUT" | jq -c '.dropped_labels | sort_by(.label)')"
check_eq "labels: --json number and url" "4242 https://github.com/acme/widgets/issues/4242" \
  "$(printf '%s' "$OUT" | jq -r '"\(.number) \(.url)"')"
check_eq "labels: dry_run false" "false" "$(printf '%s' "$OUT" | jq -r '.dry_run')"
check_contains "labels: the excluded label is named on stderr" "label 'Blocked' dropped: hides the issue from /pm" "$ERR"
check_contains "labels: the missing label is named on stderr" "label 'nope' dropped: not a label in acme/widgets" "$ERR"
check_contains "labels: passed to gh" "--label Skill --label enhancement" "$CALLS"
check_not_contains "labels: the excluded label never reaches gh issue create" "--label Blocked" "$CALLS"
N_CALLS=$(printf '%s\n' "$CALLS" | grep -c .)
N_REPO=$(printf '%s\n' "$CALLS" | grep -c -- '--repo acme/widgets')
check_eq "every gh call carries --repo" "$N_CALLS" "$N_REPO"
check_not_contains "no gh call carries --assignee" "--assignee" "$CALLS"

# macOS ships bash 3.2 as /bin/bash: the same filing, labels and all, under it.
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  : > "$STUB_LOG"
  RC=0
  OUT=$(STUB_MODE=ok /bin/bash "$SCRIPT" --repo acme/widgets --title "Labels" --body-file "$VALID" \
    --label skill --label nope --json 2>/dev/null) || RC=$?
  check_eq "bash 3.2: files with labels" '0|["Skill"]|4242' "$RC|$(printf '%s' "$OUT" | jq -c '.labels')|$(printf '%s' "$OUT" | jq -r '.number')"
  RC=0
  /bin/bash "$SCRIPT" --repo acme/widgets --title T --body-file "$VALID" --dry-run >/dev/null 2>&1 || RC=$?
  check_eq "bash 3.2: a dry run with no labels" "0" "$RC"
fi

# --- 1b. checks that send nothing (exit 3) --------------------------------------
expect_3() {
  local label="$1" needle="$2"
  shift 2
  STUB_MODE=ok run "$@"
  check_eq "$label: exit 3" "3" "$RC"
  check_eq "$label: no gh call" "" "$CALLS"
  check_eq "$label: nothing on stdout" "" "$OUT"
  check_contains "$label: names the problem" "$needle" "$ERR"
}
grep -v '^## Test Plan$' "$VALID" > "$TMP/missing.md"
expect_3 "missing section" "missing section: ## Test Plan" --repo acme/widgets --title T --body-file "$TMP/missing.md"
awk '/^## Problem$/ { print "## Proposed solution"; next } /^## Proposed solution$/ { print "## Problem"; next } { print }' "$VALID" > "$TMP/order.md"
expect_3 "sections out of order" "section out of order: ## Proposed solution" --repo acme/widgets --title T --body-file "$TMP/order.md"
grep -v '^_Captured via /issue-maker._$' "$VALID" > "$TMP/nofooter.md"
expect_3 "no footer" "last line must be exactly _Captured via /issue-maker._" --repo acme/widgets --title T --body-file "$TMP/nofooter.md"
{ cat "$VALID"; printf '\nOne more line.\n'; } > "$TMP/notlast.md"
expect_3 "footer not last" "last line must be exactly" --repo acme/widgets --title T --body-file "$TMP/notlast.md"
LONG_TITLE="An idea whose title runs on and on, well past the seventy-character limit set for titles"
check_eq "the long title is over 70 characters" "1" "$(printf '%s' "$LONG_TITLE" | jq -Rs 'if length > 70 then 1 else 0 end')"
expect_3 "title over 70" "the limit is 70" --repo acme/widgets --title "$LONG_TITLE" --body-file "$VALID"
expect_3 "blank title" "the title is blank" --repo acme/widgets --title "   " --body-file "$VALID"
expect_3 "two-line title" "the title must be one line" --repo acme/widgets --title "$(printf 'one\ntwo')" --body-file "$VALID"

# Exactly 70 characters, two of them multi-byte: characters are counted, not bytes.
T70="Desk — ideas — $(printf 'x%.0s' $(seq 1 55))"
check_eq "the 70-character title is 70 characters" "70" "$(printf '%s' "$T70" | jq -Rs 'length')"
STUB_MODE=ok run --repo acme/widgets --title "$T70" --body-file "$VALID"
check_eq "a 70-character title with em dashes files" "0" "$RC"

# The footer may carry trailing blank lines and CRLF endings.
{ sed 's/$/\r/' "$VALID"; printf '\r\n\r\n'; } > "$TMP/crlf.md"
STUB_MODE=ok run --repo acme/widgets --title T --body-file "$TMP/crlf.md"
check_eq "CRLF body with trailing blank lines files" "0" "$RC"

# Extra sections between the seven are allowed.
awk '/^## Estimate$/ { print "## Related Files"; print ""; print "- a.md"; print "" } { print }' "$VALID" > "$TMP/extra.md"
STUB_MODE=ok run --repo acme/widgets --title T --body-file "$TMP/extra.md"
check_eq "an extra section between the seven files" "0" "$RC"

# --- 1c. gh failures (exit 4, no URL) -------------------------------------------
STUB_MODE=create-fail run --repo acme/widgets --title T --body-file "$VALID"
check_eq "create fails: exit 4" "4" "$RC"
check_eq "create fails: no create URL" "" "$OUT"
check_contains "create fails: gh's message is named" "Could not resolve to a Repository" "$ERR"
check_contains "create fails: says to check before refiling" "check acme/widgets's newest issues before filing again" "$ERR"

STUB_MODE=wrong-repo run --repo acme/widgets --title T --body-file "$VALID" --json
check_eq "a URL for another repo: exit 4" "4" "$RC"
check_eq "a URL for another repo: nothing on stdout" "" "$OUT"
check_contains "a URL for another repo: says to check before refiling" "check acme/widgets's newest issues" "$ERR"

STUB_MODE=labels-fail run --repo acme/widgets --title T --body-file "$VALID" --label skill --json
check_eq "labels unreadable: still files" "0" "$RC"
check_eq "labels unreadable: no label applied" "[]" "$(printf '%s' "$OUT" | jq -c '.labels')"
check_eq "labels unreadable: the reason is named" "the repo's labels could not be read" "$(printf '%s' "$OUT" | jq -r '.dropped_labels[0].reason')"

# --- 1d. dry run and stdin ------------------------------------------------------
STUB_MODE=ok run --repo acme/widgets --title T --body-file "$VALID" --label docs --dry-run --json
check_eq "dry run: exit 0" "0" "$RC"
check_not_contains "dry run: creates nothing" "issue create" "$CALLS"
check_eq "dry run: number and url null, labels checked" 'null null ["docs"] true' \
  "$(printf '%s' "$OUT" | jq -c '[.number, .url, .labels, .dry_run] | map(tojson) | join(" ")' -r)"
STUB_MODE=ok run --repo acme/widgets --title T --body-file "$VALID" --dry-run
check_eq "dry run, text: one line naming the filing" 'dry run: would file "T" in acme/widgets (labels: none)' "$OUT"

: > "$STUB_LOG"
RC=0
OUT=$(STUB_MODE=ok "$SCRIPT" --repo acme/widgets --title T --body-file - < "$VALID" 2>/dev/null) || RC=$?
check_eq "--body-file - reads stdin" "0|https://github.com/acme/widgets/issues/4242" "$RC|$OUT"

# --- 1e. usage (exit 2) ---------------------------------------------------------
expect_2() {
  local label="$1"
  shift
  run "$@"
  check_eq "usage: $label exits 2" "2" "$RC"
  check_eq "usage: $label calls no gh" "" "$CALLS"
}
expect_2 "no arguments"
expect_2 "no --repo" --title T --body-file "$VALID"
expect_2 "no --title" --repo acme/widgets --body-file "$VALID"
expect_2 "no --body-file" --repo acme/widgets --title T
expect_2 "a malformed --repo" --repo "acme widgets" --title T --body-file "$VALID"
expect_2 "an unknown option" --repo acme/widgets --title T --body-file "$VALID" --assignee me
expect_2 "a missing body file" --repo acme/widgets --title T --body-file "$TMP/none.md"
expect_2 "a trailing bare --label" --repo acme/widgets --title T --body-file "$VALID" --label
run --help
check_eq "--help exits 0" "0" "$RC"
check_contains "--help prints the usage" "Usage: issue-file.sh --repo" "$OUT"

# --- 2. /issue-maker's create block ---------------------------------------------
BLOCK=$(extract_skill_bash "$SKILL_MD" issue-maker-create) || { echo "FATAL: could not extract issue-maker-create" >&2; exit 1; }
check_contains "issue-maker-create resolves issue-file.sh through the skills worktree" \
  '"$HOME/.claude/skills-worktree/.claude/scripts/issue-file.sh"' "$BLOCK"
check_not_contains "issue-maker-create no longer calls gh issue create itself" "gh issue create" "$BLOCK"
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.claude/skills-worktree/.claude/scripts"
ln -s "$SCRIPT" "$FAKE_HOME/.claude/skills-worktree/.claude/scripts/issue-file.sh"
# The block's placeholder body ("## Background / ... / footer") stands in for
# a drafted one: put the real template in its place.
printf '%s\n' "$BLOCK" | awk -v tf="$VALID" '
  /^## Background$/ && !done { while ((getline l < tf) > 0) print l; skip = 1; next }
  skip && /^_Captured via \/issue-maker\._$/ { skip = 0; done = 1; next }
  skip { next }
  { print }' > "$TMP/create-block.sh"
# Each call starts a clean shell: runtime/install environment must not silently
# satisfy a missing earlier-phase input. Both the extracted module and preferred
# helper are pinned to this checkout, never the developer's installed skill.
run_create() {
  (
    cd "$TMP" || exit 1
    env -i PATH="$PATH" HOME="$FAKE_HOME" TMPDIR="$TMP" \
      DISPATCHER="$REPO_ROOT/.claude/skills/issue-maker/scripts/dispatch-module.sh" \
      REPO=acme/widgets TITLE="An idea" ACCEPTED_LABELS=$'skill\nnope' \
      ISSUE_TIER=Standard DELIVERS="One independently testable change" EST_BOUND=20 \
      IS_INCREMENT=false STUB_MODE="$1" STUB_LOG="$STUB_LOG" STUB_BODY="$STUB_BODY" \
      ISSUE_FILE_GH="$GH_STUB" "${@:2}" \
      bash --noprofile --norc -c '. ./create-block.sh; printf "URL=%s\nNUM=%s\nLABELS=%s\n" "$ISSUE_URL" "$ISSUE_NUMBER" "$(printf "%s" "$ACCEPTED_LABELS" | tr "\n" ",")"'
  ) 2>"$TMP/create.err"
}
: > "$STUB_LOG"
OUT=$(run_create ok)
check_contains "create block: files through issue-file.sh" "FILE_RC=0" "$OUT"
check_contains "create block: ISSUE_URL from the script" "URL=https://github.com/acme/widgets/issues/4242" "$OUT"
check_contains "create block: ISSUE_NUMBER from the script" "NUM=4242" "$OUT"
check_contains "create block: ACCEPTED_LABELS becomes what was applied" "LABELS=Skill" "$OUT"
check_not_contains "create block: a dropped label is not logged" "nope" "$(printf '%s\n' "$OUT" | grep '^LABELS=')"
: > "$STUB_LOG"
OUT=$(run_create create-fail)
check_contains "create block, ambiguous remote result: FILE_RC=6" "FILE_RC=6" "$OUT"
check_eq "create block, gh fails: ISSUE_URL empty" "URL=" "$(printf '%s\n' "$OUT" | grep '^URL=')"
check_not_contains "create block, uncertain failure: no confirmed receipt" 'CREATE_RECEIPT=' "$OUT"
OUT=$(run_create create-uncertain)
check_contains "create block, exact lost-response match recovers: FILE_RC=0" "FILE_RC=0" "$OUT"
check_contains "create block, exact lost-response match recovers URL" "URL=https://github.com/acme/widgets/issues/4242" "$OUT"
check_contains "create block, recovered label metadata" "LABELS=Skill" "$OUT"
check_contains "create block, explains exact recovery" "recovered exact matching issue #4242" "$(cat "$TMP/create.err")"
# Receipt survives the tool-process boundary with the complete drafting context.
OUT=$(run_create ok)
RECEIPT=$(printf '%s\n' "$OUT" | sed -n 's/^CREATE_RECEIPT=//p')
check_eq "create receipt freezes standalone scope and repo" \
  '["acme/widgets","Standard","One independently testable change",20,null,4242,["Skill"]]' \
  "$(printf '%s' "$RECEIPT" | jq -c '[.repo,.tier,.delivers,.bound,.chain,.number,.labels]')"
OUT=$(run_create ok IS_INCREMENT=true CHAIN_ID=chain-fixture POSITION=2 TOTAL=3)
RECEIPT=$(printf '%s\n' "$OUT" | sed -n 's/^CREATE_RECEIPT=//p')
check_eq "create receipt freezes increment identity" \
  '{"chain_id":"chain-fixture","position":2,"total":3}' \
  "$(printf '%s' "$RECEIPT" | jq -c '.chain')"
# Missing earlier-phase fields must abort before any external action, regardless
# of what a developer happens to export in the invoking shell.
for field in ISSUE_TIER DELIVERS EST_BOUND; do
  : > "$STUB_LOG"
  CREATE_RC=0
  OUT=$(run_create ok "$field=") || CREATE_RC=$?
  if [ "$CREATE_RC" -ne 0 ]; then pass "create block: missing $field fails"; else fail "create block: missing $field accepted"; fi
  check_eq "create block: missing $field sends no gh call" "" "$(cat "$STUB_LOG")"
  check_not_contains "create block: missing $field emits no receipt" 'CREATE_RECEIPT=' "$OUT"
done
: > "$STUB_LOG"
OUT=$(run_create ok HOME="$TMP/empty-home")
check_contains "create block, script missing: says so" "ERROR: issue-file.sh not found (checked all three paths)" "$(cat "$TMP/create.err")"
check_contains "create block, script missing: FILE_RC=5" "FILE_RC=5" "$OUT"
check_eq "create block, script missing: no gh call" "" "$(cat "$STUB_LOG")"
check_not_contains "create block, script missing: no receipt" 'CREATE_RECEIPT=' "$OUT"

# --- 3. the shared entry (AC 4.1) -----------------------------------------------
if [ -f "$ONE_SHOT" ]; then pass "references/one-shot-filing.md exists"; else fail "references/one-shot-filing.md is missing"; fi
check_contains "one-shot-filing.md creates through issue-file.sh" "issue-file.sh --repo" "$(cat "$ONE_SHOT")"
check_contains "one-shot-filing.md excludes capture mode" "never switches the caller's thread into capture mode" "$(cat "$ONE_SHOT")"
check_contains "issue-maker reflection module names the one-shot entry" "references/one-shot-filing.md" "$(cat "$REFLECT_MD")"
DESK_BLOCK=$(extract_skill_bash "$IDEAS_MD" desk-idea-file) || { echo "FATAL: could not extract desk-idea-file" >&2; exit 1; }
check_contains "the desk's create block calls the same script" '"$ISSUE_FILE" --repo "$IDEA_REPO"' "$DESK_BLOCK"
check_contains "the desk's create block resolves issue-file.sh through the skills worktree" \
  '"$HOME/.claude/skills-worktree/.claude/scripts/issue-file.sh"' "$DESK_BLOCK"
check_contains "ideas.md reads the shared one-shot reference" "references/one-shot-filing.md" "$(cat "$IDEAS_MD")"

echo
echo "issue-file.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
