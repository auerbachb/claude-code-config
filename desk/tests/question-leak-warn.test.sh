#!/usr/bin/env bash
# desk/tests/question-leak-warn.test.sh — offline tests for the prose-question
# nudge (issue #1778): desk/hooks/question-leak-warn.sh, run through its
# registered symlink .claude/hooks/question-leak-warn.sh. Needs no database.
# Runs in CI through .github/scripts/run-hook-tests.sh.
#
# Every hook run gets ONLY the environment written here (env -i), the way the
# desktop app starts hooks without sourcing a shell profile.
#
# Asserts:
#   registration  global-settings.json has one Stop entry with the
#                 placeholder command and timeout 5, and no other entry; the
#                 .claude/hooks entry is a relative symlink to
#                 desk/hooks/question-leak-warn.sh, which is executable
#   4.3 / 5.1     fixture transcripts (transcript_path): a prose question
#                 warns; the same question with a receipt line does not; a
#                 question only inside a code block does not; a question in
#                 an earlier message of the turn does not; malformed lines
#                 are skipped
#   4.2           the same cases through last_assistant_message, plus the
#                 false-positive guards (inline code, URL, heading,
#                 blockquote, quoted question, same-line answer, table row,
#                 tilde / long / unclosed fences, a fence that opens a list
#                 item, a blockquote or heading nested in a list item),
#                 plural and decorated receipts, a
#                 fenced or blockquoted receipt (an example or a quote: still
#                 warns, list-nested too), a question after the receipt (next
#                 line or same line), one warning for many questions, the
#                 quote truncated, a question line longer than one exec
#                 argument may be
#   once per turn a warning leaves a per-session marker; a continued turn
#                 (stop_hook_active) it warned in stays silent; one another
#                 hook continued still warns, once; a new turn clears the
#                 marker; no session id or an unwritable TMPDIR never loops
#   warning       one Stop additionalContext object naming the fix: the
#                 question tool, the exact receipt, the live-desk condition,
#                 human-queue.md; never decision: block, never continue: false
#   5.2           exit 0 in every case; empty stdin, malformed payloads, a
#                 missing or unreadable transcript, and no jq print nothing
#
# Cases run under `bash` and, when /bin/bash is 3.x (macOS), under /bin/bash.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"

REPO_ROOT=$(dirname "$HQ_T_DESK_DIR")
HOOK="$REPO_ROOT/.claude/hooks/question-leak-warn.sh"
SETTINGS="$REPO_ROOT/global-settings.json"
FIX="$TESTS_DIR/fixtures/question-leak"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: question-leak-warn.test.sh — jq is not installed (the hook fails open without it)"
  exit 0
fi
JQ=$(command -v jq)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-question-leak.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# jq's own directory first: the hook must find it the way it does in the app.
MINPATH="$(dirname "$JQ"):/usr/bin:/bin"
HOMEDIR="$TMP/home"
mkdir -p "$HOMEDIR"

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi

# hook SHELL INPUT [VAR=VALUE...] — runs the hook through its symlink with only
# the given environment; sets OUT, ERR, RC.
hook() {
  local sh="$1" input="$2"
  shift 2
  RC=0
  printf '%s' "$input" >"$TMP/in"
  env -i HOME="$HOMEDIR" PATH="$MINPATH" TMPDIR="$TMP" "$@" \
    "$sh" "$HOOK" >"$TMP/out" 2>"$TMP/err" <"$TMP/in" || RC=$?
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# msg TEXT [ACTIVE] [SESSION] — a Stop payload carrying last_assistant_message.
# SESSION defaults to s-1; "-" leaves session_id out.
msg() {
  QLW_T_MSG="$1" QLW_T_ACTIVE="${2:-false}" QLW_T_SID="${3:-s-1}" "$JQ" -cn \
    '{session_id: env.QLW_T_SID, transcript_path: "/nonexistent/transcript.jsonl", cwd: "/tmp",
      hook_event_name: "Stop", stop_hook_active: (env.QLW_T_ACTIVE == "true"),
      last_assistant_message: env.QLW_T_MSG, stop_reason: "end_turn"}
     | if .session_id == "-" then del(.session_id) else . end'
}

# The once-per-turn marker the hook keeps under TMPDIR, per session.
marker() { printf '%s/claude-question-leak-warn-%s' "$TMP" "$1"; }
reset_markers() { rm -rf "$TMP"/claude-question-leak-warn-*; }

# tr_payload PATH [MESSAGE] — a Stop payload without last_assistant_message,
# or with MESSAGE as one when a second argument is given.
tr_payload() {
  if [ "$#" -ge 2 ]; then
    QLW_T_PATH="$1" QLW_T_MSG="$2" "$JQ" -cn \
      '{session_id: "s-1", transcript_path: env.QLW_T_PATH, hook_event_name: "Stop",
        stop_hook_active: false, last_assistant_message: env.QLW_T_MSG}'
  else
    QLW_T_PATH="$1" "$JQ" -cn \
      '{session_id: "s-1", transcript_path: env.QLW_T_PATH, cwd: "/tmp",
        hook_event_name: "Stop", stop_hook_active: false}'
  fi
}

# n_objects — how many JSON values are on stdout (0 when none or not JSON).
n_objects() {
  if [ -z "$OUT" ]; then printf '0\n'; return 0; fi
  printf '%s' "$OUT" | "$JQ" -s 'length' 2>/dev/null || printf 'not-json\n'
}

# field JQ-PATH — one field of the stdout object ("" when absent).
field() {
  printf '%s' "$OUT" | "$JQ" -r "$1 // \"\"" 2>/dev/null || printf '\n'
}

# expect_silent LABEL — exit 0, nothing on stdout or stderr.
expect_silent() {
  check "$1: exit 0" "$RC" "0"
  check "$1: nothing on stdout" "$OUT" ""
  check "$1: nothing on stderr" "$ERR" ""
}

# expect_warn LABEL QUOTED — exit 0, exactly one Stop additionalContext object
# that quotes QUOTED and names the fix, nothing that blocks, nothing on stderr.
expect_warn() {
  local ctx
  check "$1: exit 0" "$RC" "0"
  check "$1: nothing on stderr" "$ERR" ""
  check "$1: exactly one JSON object on stdout" "$(n_objects)" "1"
  check "$1: hookEventName is Stop" "$(field '.hookSpecificOutput.hookEventName')" "Stop"
  check "$1: never blocks (no decision)" "$(field 'has("decision") | tostring')" "false"
  check "$1: never stops the session (no continue)" "$(field 'has("continue") | tostring')" "false"
  ctx=$(field '.hookSpecificOutput.additionalContext')
  check_contains "$1: quotes the line" "$ctx" "\"$2\""
  check_contains "$1: says what it is" "$ctx" "PROSE QUESTION WARNING"
  check_contains "$1: names the rule" "$ctx" "human-queue.md"
  check_contains "$1: names the fix" "$ctx" "question tool (AskUserQuestion)"
  check_contains "$1: names the exact receipt" "$ctx" "(question D-<n> sent to human queue)"
  check_contains "$1: says the queue needs a live desk" "$ctx" "While a live desk exists the capture hook queues it"
}

# ---------------------------------------------------------------- registration
printf '== registration\n'
REG=$("$JQ" -r '
  [.hooks // {} | to_entries[] | {event: .key, hook: (.value[] | .hooks[]?)}
   | select((.hook.command // "") | endswith("/question-leak-warn.sh"))
   | "\(.event) \(.hook.type) \(.hook.command) \(.hook.timeout)"] | join(";")' "$SETTINGS" 2>&1)
check "global-settings.json: one Stop entry, nowhere else" "$REG" \
  "Stop command /path/to/claude-code-config/.claude/hooks/question-leak-warn.sh 5"
if [ -L "$HOOK" ]; then ok "the .claude/hooks entry is a symlink"; else bad "the .claude/hooks entry is not a symlink"; fi
check "the symlink is relative and points into desk/hooks" "$(readlink "$HOOK")" "../../desk/hooks/question-leak-warn.sh"
if [ -x "$HQ_T_DESK_DIR/hooks/question-leak-warn.sh" ]; then ok "desk/hooks/question-leak-warn.sh is executable"; else bad "desk/hooks/question-leak-warn.sh is not executable"; fi

# Messages for the last_assistant_message cases.
Q_MERGE="Should I merge PR #5 now, or wait for CR?"
M_PROSE="CI is green on the branch.

$Q_MERGE"
M_RECEIPT="Open call: should I merge PR #5 now, or wait for CR?

question D-43 sent to human queue

Proceeding on the recommended default."
M_PLURAL="Should I merge PR #5 now?
Which region should the store use?

questions D-43, D-44 sent to human queue"
M_DECORATED="Ship the migration before the CLI?

- **\`Question D-7 sent to human queue.\`**"
M_AFTER="question D-43 sent to human queue

Also, should I close the stale issue too?"
M_SAME_LINE_AFTER='Done.

question D-43 sent to human queue - should I also close Issue #9?'
M_SAME_LINE_BEFORE='Ship now? question D-43 sent to human queue.'
M_QUOTED_RECEIPT='Should I retry the deploy?

The denial said:
> Print exactly: question D-43 sent to human queue.'
M_FENCED_RECEIPT='Should I add the receipt format to the README?

The receipt looks like this:

```
question D-43 sent to human queue
```'
M_FENCED='Here is the prompt the CLI prints:

```
Continue with the migration?
```

That is all.'
M_TILDE='The fixture:

~~~text
Ship now?
~~~'
M_LONGFENCE='A fence that shows a fence:

````markdown
```
Proceed?
```
Still inside?
````'
M_UNCLOSED='Example output:

```
Overwrite the file?'
# (Single quotes, not a heredoc in $(...): bash 3.2 scans that for backticks.)
M_ITEM_FENCE='Steps:

1. ```bash
   Continue with the migration?
   ```
- ~~~
  Overwrite the file?
  ~~~'
M_ITEM_FENCE_THEN_Q="$M_ITEM_FENCE

Should I run it on staging first?"
M_FENCE_ITEM_LINE='````text
- ```
Still inside?
````'
M_INLINE_FENCE=$(cat <<'EOF'
```x``` is inline code, not a fence.
Should I keep it?
EOF
)
M_LIST_FENCE='1. Run the check:

   ```
   Continue?
   ```
2. Done.'
M_INLINE=$(cat <<'EOF'
The pattern is `colou?r` and the flag is `--dry-run?`
A `?` in `a?b` and `c?`
EOF
)
M_INLINE_Q="Should I run \`make test\` first?"
M_URL='Search results:
https://example.com/search?
- https://example.com/other?'
M_URL_Q='Can you check https://example.com/status?'
M_HEADING='## Why did the test fail?

The token expired before the retry.'
M_QUOTE='> Can we ship this today?

Shipped.'
M_QUOTED='The issue asks "is the cache warm?"
You asked (why the delay?)'
M_SAME_LINE='Why did it fail? The token expired.'
M_TABLE='| Ready? | yes |
|---|---|'
M_LIST_QUOTE='The issue body says:

- > Should we deploy on Friday?
1. ## Why did the cache miss?'
M_LIST_QUOTED_RECEIPT='Should I retry the deploy?

- > question D-43 sent to human queue'
M_BOLD='Two options are open.

**Ship now or wait for review?**'
M_LIST='Open questions:
- Merge PR #5 now?
- Close Issue #9?'
M_PUNCT='???
?'
M_NONE='All done. The branch is merged.'
M_CRLF=$(printf 'Done.\r\nProceed with the deploy?\r\n')
M_EMPH='_Proceed with the deploy?_   '
LONGQ="Should I rewrite the whole capture path so it batches every question from one call into a single store transaction, or keep one add per question?"
# A 1.2 MB question line, built through a file: it is too long to pass to jq
# as an argument or an environment variable.
{
  printf 'Should I keep this line '
  head -c 1200000 /dev/zero | tr '\0' 'a'
  printf '?'
} >"$TMP/huge-question.txt"
HUGE_Q=$(head -c 200 "$TMP/huge-question.txt")
HUGE_PAYLOAD=$("$JQ" -cRs '{session_id: "s-huge", hook_event_name: "Stop",
  stop_hook_active: false, last_assistant_message: .}' <"$TMP/huge-question.txt")

for SH in $SHELLS; do
  printf '== %s: fixture transcripts\n' "$SH"

  hook "$SH" "$(tr_payload "$FIX/prose-question.jsonl")"
  expect_warn "[$SH] transcript: prose question" \
    "Should I ship the migration before the CLI, or wait for review?"

  hook "$SH" "$(tr_payload "$FIX/receipt.jsonl")"
  expect_silent "[$SH] transcript: question with a receipt line"

  hook "$SH" "$(tr_payload "$FIX/fenced-question.jsonl")"
  expect_silent "[$SH] transcript: questions only inside code blocks"

  hook "$SH" "$(tr_payload "$FIX/earlier-question.jsonl")"
  expect_silent "[$SH] transcript: a question in an earlier message only"

  hook "$SH" "$(tr_payload "$FIX/malformed.jsonl")"
  expect_warn "[$SH] transcript: malformed lines skipped" "OK to merge it now?"

  printf 'garbage?\n{"type":\n' >"$TMP/garbage.jsonl"
  hook "$SH" "$(tr_payload "$TMP/garbage.jsonl")"
  expect_silent "[$SH] transcript: nothing parseable"

  hook "$SH" "$(tr_payload "$TMP/no-such-transcript.jsonl")"
  expect_silent "[$SH] transcript: missing file"

  hook "$SH" "$(tr_payload "$TMP")"
  expect_silent "[$SH] transcript: a directory"

  cp "$FIX/prose-question.jsonl" "$TMP/unreadable.jsonl"
  chmod 000 "$TMP/unreadable.jsonl"
  if [ -r "$TMP/unreadable.jsonl" ]; then
    ok "[$SH] transcript: unreadable file (skipped: running as root)"
  else
    hook "$SH" "$(tr_payload "$TMP/unreadable.jsonl")"
    expect_silent "[$SH] transcript: unreadable file"
  fi
  chmod 600 "$TMP/unreadable.jsonl"

  # last_assistant_message wins when present, even empty.
  hook "$SH" "$(tr_payload "$FIX/prose-question.jsonl" "")"
  expect_silent "[$SH] empty last_assistant_message: the transcript is not read"

  printf '== %s: last_assistant_message\n' "$SH"

  hook "$SH" "$(msg "$M_PROSE")"
  expect_warn "[$SH] prose question" "$Q_MERGE"

  hook "$SH" "$(msg "$M_RECEIPT")"
  expect_silent "[$SH] question with a receipt line"

  hook "$SH" "$(msg "$M_PLURAL")"
  expect_silent "[$SH] plural receipt"

  hook "$SH" "$(msg "$M_DECORATED")"
  expect_silent "[$SH] receipt in a bullet, bold, code, other case"

  hook "$SH" "$(msg "$M_AFTER")"
  expect_warn "[$SH] question after the receipt" "Also, should I close the stale issue too?"

  hook "$SH" "$(msg "$M_SAME_LINE_AFTER")"
  expect_warn "[$SH] a question after the receipt on the same line" \
    "question D-43 sent to human queue - should I also close Issue #9?"

  hook "$SH" "$(msg "$M_SAME_LINE_BEFORE")"
  expect_silent "[$SH] a question before the receipt on the same line"

  hook "$SH" "$(msg "$M_QUOTED_RECEIPT")"
  expect_warn "[$SH] a receipt inside a blockquote is a quote, not a receipt" \
    "Should I retry the deploy?"

  hook "$SH" "$(msg "$M_FENCED_RECEIPT")"
  expect_warn "[$SH] a receipt inside a code block is an example, not a receipt" \
    "Should I add the receipt format to the README?"

  hook "$SH" "$(msg "$M_FENCED")"
  expect_silent "[$SH] question inside a code block"

  hook "$SH" "$(msg "$M_TILDE")"
  expect_silent "[$SH] question inside a tilde fence"

  hook "$SH" "$(msg "$M_LONGFENCE")"
  expect_silent "[$SH] a shorter fence does not close a longer one"

  hook "$SH" "$(msg "$M_UNCLOSED")"
  expect_silent "[$SH] question inside an unclosed fence"

  hook "$SH" "$(msg "$M_LIST_FENCE")"
  expect_silent "[$SH] question inside an indented fence"

  hook "$SH" "$(msg "$M_ITEM_FENCE")"
  expect_silent "[$SH] question inside a fence that opens a list item"

  hook "$SH" "$(msg "$M_ITEM_FENCE_THEN_Q")"
  expect_warn "[$SH] a list-item fence closes: a question after it warns" \
    "Should I run it on staging first?"

  hook "$SH" "$(msg "$M_FENCE_ITEM_LINE")"
  expect_silent "[$SH] a list-marker fence line inside a fence closes nothing"

  hook "$SH" "$(msg "$M_INLINE_FENCE")"
  expect_warn "[$SH] a backtick run with a backtick after it opens no fence" "Should I keep it?"

  hook "$SH" "$(msg "$M_INLINE")"
  expect_silent "[$SH] ? inside inline code"

  hook "$SH" "$(msg "$M_INLINE_Q")"
  expect_warn "[$SH] inline code does not hide a real question" "$M_INLINE_Q"

  hook "$SH" "$(msg "$M_URL")"
  expect_silent "[$SH] a bare URL ending in ?"

  hook "$SH" "$(msg "$M_URL_Q")"
  expect_warn "[$SH] a question that ends in a URL" "$M_URL_Q"

  hook "$SH" "$(msg "$M_HEADING")"
  expect_silent "[$SH] heading"

  hook "$SH" "$(msg "$M_QUOTE")"
  expect_silent "[$SH] blockquote"

  hook "$SH" "$(msg "$M_QUOTED")"
  expect_silent "[$SH] quoted and bracketed questions"

  hook "$SH" "$(msg "$M_SAME_LINE")"
  expect_silent "[$SH] question answered on the same line"

  hook "$SH" "$(msg "$M_TABLE")"
  expect_silent "[$SH] table row"

  hook "$SH" "$(msg "$M_LIST_QUOTE")"
  expect_silent "[$SH] blockquote and heading nested in a list item"

  hook "$SH" "$(msg "$M_LIST_QUOTED_RECEIPT")"
  expect_warn "[$SH] a receipt in a list-nested blockquote is a quote, not a receipt" \
    "Should I retry the deploy?"

  hook "$SH" "$(msg "$M_BOLD")"
  expect_warn "[$SH] bold question" "**Ship now or wait for review?**"

  hook "$SH" "$(msg "$M_LIST")"
  expect_warn "[$SH] several questions: one warning, the first quoted" "- Merge PR #5 now?"

  hook "$SH" "$(msg "$M_PUNCT")"
  expect_silent "[$SH] punctuation only"

  hook "$SH" "$(msg "$M_NONE")"
  expect_silent "[$SH] no question mark at all"

  hook "$SH" "$(msg "$M_CRLF")"
  expect_warn "[$SH] CRLF line endings" "Proceed with the deploy?"

  hook "$SH" "$(msg "$M_EMPH")"
  expect_warn "[$SH] emphasis and trailing spaces (trimmed in the quote)" "_Proceed with the deploy?_"

  hook "$SH" "$(msg "$LONGQ")"
  expect_warn "[$SH] a long line is truncated" "$(printf '%s' "$LONGQ" | cut -c1-117)..."

  # A question line longer than one exec argument may be (ARG_MAX on macOS,
  # MAX_ARG_STRLEN on Linux) still warns: the hook cuts it before jq sees it.
  hook "$SH" "$HUGE_PAYLOAD"
  expect_warn "[$SH] a question line over the argument limit still warns" \
    "$(printf '%s' "$HUGE_Q" | cut -c1-117)..."

  printf '== %s: once per turn\n' "$SH"

  reset_markers
  hook "$SH" "$(msg "$M_PROSE")"
  expect_warn "[$SH] turn A, first Stop" "$Q_MERGE"
  if [ -d "$(marker s-1)" ]; then ok "[$SH] the warning left its marker"; else bad "[$SH] the warning left no marker"; fi
  hook "$SH" "$(msg "$M_PROSE" true)"
  expect_silent "[$SH] turn A, continued (stop_hook_active): no second warning"
  hook "$SH" "$(msg "$M_PROSE" true)"
  expect_silent "[$SH] turn A, continued again: still no second warning"

  hook "$SH" "$(msg "$M_PROSE")"
  expect_warn "[$SH] turn B, first Stop: a new turn warns again" "$Q_MERGE"

  hook "$SH" "$(msg "$M_NONE")"
  expect_silent "[$SH] turn C, first Stop: no question"
  if [ -d "$(marker s-1)" ]; then bad "[$SH] a new turn did not clear the marker"; else ok "[$SH] a new turn clears the marker"; fi
  hook "$SH" "$(msg "$M_PROSE" true)"
  expect_warn "[$SH] turn C, continued by another hook: the new question warns" "$Q_MERGE"
  hook "$SH" "$(msg "$M_PROSE" true)"
  expect_silent "[$SH] turn C, continued again: no second warning"

  hook "$SH" "$(msg "$M_PROSE" false s-2)"
  expect_warn "[$SH] another session keeps its own marker" "$Q_MERGE"

  reset_markers
  hook "$SH" "$(msg "$M_PROSE" true -)"
  expect_silent "[$SH] continued turn, no session id: silent (cannot tell)"
  hook "$SH" "$(msg "$M_PROSE" false -)"
  expect_warn "[$SH] first Stop, no session id: warns" "$Q_MERGE"

  hook "$SH" "$(msg "$M_PROSE" false '../../x y')"
  expect_warn "[$SH] an odd session id" "$Q_MERGE"
  if [ -d "$(marker xy)" ]; then ok "[$SH] the session id is reduced to a safe name"; else bad "[$SH] no marker named for the reduced session id"; fi

  mkdir -p "$TMP/readonly"
  chmod 555 "$TMP/readonly"
  if [ -w "$TMP/readonly" ]; then
    ok "[$SH] unwritable TMPDIR (skipped: running as root)"
  else
    hook "$SH" "$(msg "$M_PROSE")" TMPDIR="$TMP/readonly"
    expect_warn "[$SH] unwritable TMPDIR, first Stop: still warns" "$Q_MERGE"
    hook "$SH" "$(msg "$M_PROSE" true)" TMPDIR="$TMP/readonly"
    expect_silent "[$SH] unwritable TMPDIR, continued turn: silent (no loop)"
  fi
  chmod 755 "$TMP/readonly"
  reset_markers

  printf '== %s: fail open\n' "$SH"

  hook "$SH" ""
  expect_silent "[$SH] empty stdin"

  hook "$SH" "not json?"
  expect_silent "[$SH] stdin is not JSON"

  hook "$SH" '["Should I merge?"]'
  expect_silent "[$SH] stdin is a JSON array"

  hook "$SH" '"Should I merge?"'
  expect_silent "[$SH] stdin is a JSON string"

  hook "$SH" '{"hook_event_name": "Stop"}'
  expect_silent "[$SH] no message and no transcript"

  hook "$SH" "$(msg "$M_PROSE")" QUESTION_LEAK_WARN_JQ="$TMP/no-such-jq"
  expect_silent "[$SH] no jq"

  printf '#!/bin/sh\nexit 3\n' >"$TMP/broken-jq"
  chmod +x "$TMP/broken-jq"
  hook "$SH" "$(msg "$M_PROSE")" QUESTION_LEAK_WARN_JQ="$TMP/broken-jq"
  expect_silent "[$SH] a jq that fails"
done

# ---------------------------------------------------------------- speed
printf '== speed\n'
BIG=""
i=0
while [ "$i" -lt 200 ]; do
  BIG="${BIG}Line $i of a long report, with a question mark? in the middle of it.
"
  i=$((i + 1))
done
BIG="${BIG}$Q_MERGE"
T0=$(hq_t_now)
hook bash "$(msg "$BIG")"
T1=$(hq_t_now)
expect_warn "a 200-line message" "$Q_MERGE"
if hq_t_elapsed_under "$T0" "$T1" 2; then
  ok "a 200-line message is scanned in under 2 s ($(hq_t_elapsed "$T0" "$T1") s)"
else
  bad "a 200-line message took $(hq_t_elapsed "$T0" "$T1") s"
fi

hq_t_finish "question-leak-warn.test.sh"
