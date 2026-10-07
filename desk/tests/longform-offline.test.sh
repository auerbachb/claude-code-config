#!/usr/bin/env bash
# desk/tests/longform-offline.test.sh — offline tests for the desk's
# long-form, multipart, and discuss increment (issue #1780). Needs no
# database: desk.jq runs on fixtures, `answer` runs against a TEST-NET
# address (a refusal must come before any connection attempt), and the
# skill's own bash blocks run against a stub CLI.
#
# Asserts:
#   classify  menu_shaped is true for 2 to 4 options and a cost in minutes
#             (or none); no options, one, five, or a cost in hours, days, or
#             weeks (2h, 1h30, 2 hrs, an hour, half a day, 3 days, a week)
#             is long-form
#   split     desk_split keeps open Decisions only; simple ids in list
#             order; long-form ids grouped by repo + key + return address (a
#             multipart item), parts in list order, groups by their first
#             part; an id filter keeps the named ids, and a named
#             long-form part brings its whole open group (a tick can land
#             between two parts of one ask)
#   render    the long-form card is one blockquote: the id, `long-form` or
#             `part k of m`, the question, numbered context, the options
#             with the default marked once, the default's time in UTC,
#             impact and cost, the link, and where the answer goes; no line
#             outside the quote ends in `?` (#1778's nudge test); an
#             answered item renders as a one-line skip notice
#   discuss   the discussion card carries the status, the asked time, the
#             context, the options, the link, and the answer so far (every
#             line of a multi-line answer quoted)
#   links     pr-N, issue-N, and branch:NAME (segments URI-encoded) link to
#             GitHub; local/ repos, session: keys, and shortened keys do not
#   utc       offsets and fractions convert to UTC; anything else passes
#             through unchanged
#   answer    --stdin and --json: both answer forms at once, an empty
#             stdin, a NUL byte, an escape, more than 16000 bytes, repeated
#             flags, and a secret (never echoed) are refused before any
#             connection; valid input reaches the database step; --help
#             documents both flags; a positional answer starting with a
#             dash still works
#   skill     the anchored blocks run against a stub CLI: desk-split,
#             desk-longform-render, and desk-discuss-card print what desk.jq
#             prints, or `exit=<n>` when list or get fails (never an empty
#             card hiding the failure), and desk-longform-answer hands the operator's message
#             to `answer --stdin --json` byte for byte (quotes, $(...),
#             backticks, backslashes, `2: B` lines, tabs, Unicode) under
#             bash, /bin/bash 3.2, and zsh, running none of it; the skill
#             files carry the contract (word for word, never a menu, the
#             exit words, nothing stored during discussion, the deferred
#             commands of #1781)
#
# Every jq found (PATH and /usr/bin/jq) runs the desk.jq cases.
set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/testlib.sh
. "$TESTS_DIR/lib/testlib.sh"
# shellcheck source=lib/skill-block.sh
. "$TESTS_DIR/lib/skill-block.sh"

SKILL_DIR="$HQ_T_DESK_DIR/skill"

JQS=""
for j in "$(command -v jq 2>/dev/null || true)" /usr/bin/jq /opt/homebrew/bin/jq; do
  [ -n "$j" ] && [ -x "$j" ] || continue
  case " $JQS " in *" $j "*) continue ;; esac
  JQS="$JQS $j"
done
if [ -z "$JQS" ]; then
  echo "SKIP: longform-offline.test.sh — jq is not installed (the desk skill needs it)"
  exit 0
fi
if ! command -v perl >/dev/null 2>&1; then
  echo "SKIP: longform-offline.test.sh — perl is not installed (the test clock needs it)"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/hq-longform-offline.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

SHELLS="bash"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = "3" ]; then
  SHELLS="bash /bin/bash"
fi
BLOCK_SHELLS="$SHELLS"
if command -v zsh >/dev/null 2>&1; then BLOCK_SHELLS="$BLOCK_SHELLS zsh"; fi

BLACKHOLE_URL="postgresql://u:pw@192.0.2.1:5432/db?sslmode=require"
ALNUM36="abcdefghijklmnopqrstuvwxyz0123456789"
FAKE_GH="gh""p_$ALNUM36"

# The fixture queue: a menu question, a single long-form question, a
# three-part group (issue-90, sess-b) with a menu question of the same thread
# between its parts, a cost-in-hours question with options, a one-option
# question, an answered item, and a Review. Order is the list's order.
cat > "$TMP/items.json" <<'JSON'
[
  {"id":"D-43","kind":"decision","status":"open","repo":"acme/widgets","key":"pr-318","session_id":"11111111-2222-3333-4444-555555555555","question":"Two cadence tests fail on the DST boundary. Skip them, fix the window math, or relax the assertion?","context":["The quiet-hours window is computed in UTC and compared in local time.","The failing tests are correct about the behaviour.","Fixing touches one function and two tests."],"options":["Skip the two tests for now","Fix the window math (Recommended)","Relax the assertion to ±1 hour"],"default_option":"Fix the window math (Recommended)","default_at":"2026-10-05T16:15:00-04:00","impact_declared":"medium","parked":false,"cost":"~10 min","focus":"no deep focus","answer":null,"created_at":"2026-10-05T14:04:00.123456+00:00"},
  {"id":"D-45","kind":"decision","status":"open","repo":"acme/widgets","key":"issue-77","session_id":"sess-a","question":"What should the onboarding email say about pricing?","context":[],"options":[],"default_option":null,"default_at":null,"impact_declared":"high","parked":true,"cost":null,"focus":null,"answer":null,"created_at":"2026-10-05T14:10:00+00:00"},
  {"id":"D-47","kind":"decision","status":"open","repo":"acme/widgets","key":"issue-90","session_id":"sess-b","question":"Which region should the staging database live in?","context":["Latency to the CI runners matters most."],"options":[],"default_option":null,"default_at":null,"impact_declared":"medium","parked":false,"cost":null,"focus":null,"answer":null,"created_at":"2026-10-05T14:20:00+00:00"},
  {"id":"D-48","kind":"decision","status":"open","repo":"acme/widgets","key":"issue-90","session_id":"sess-b","question":"Who signs off on the staging budget?","context":[],"options":[],"default_option":null,"default_at":null,"impact_declared":"medium","parked":false,"cost":null,"focus":null,"answer":null,"created_at":"2026-10-05T14:21:00+00:00"},
  {"id":"D-49","kind":"decision","status":"open","repo":"acme/widgets","key":"issue-90","session_id":"sess-b","question":"Seed the staging database from production?","context":[],"options":["Yes","No"],"default_option":"No","default_at":null,"impact_declared":null,"parked":false,"cost":"~5 min","focus":null,"answer":null,"created_at":"2026-10-05T14:22:00+00:00"},
  {"id":"D-50","kind":"decision","status":"open","repo":"acme/widgets","key":"branch:feat/x y","session_id":null,"question":"Rewrite the importer or patch it?","context":[],"options":["Rewrite","Patch"],"default_option":"Patch","default_at":null,"impact_declared":"low","parked":false,"cost":"1h30","focus":null,"answer":null,"created_at":"2026-10-05T14:30:00+00:00"},
  {"id":"D-51","kind":"decision","status":"open","repo":"local/scratch","key":"session:abc","session_id":"sess-c","question":"Pick one","context":[],"options":["Only"],"default_option":null,"default_at":null,"impact_declared":null,"parked":false,"cost":null,"focus":null,"answer":null,"created_at":"2026-10-05T14:31:00+00:00"},
  {"id":"D-52","kind":"decision","status":"answered","repo":"acme/widgets","key":"pr-1","session_id":"sess-d","question":"Done already","context":[],"options":[],"default_option":null,"default_at":null,"impact_declared":null,"parked":false,"cost":null,"focus":null,"answer":"yes\nand a second line","created_at":"2026-10-05T14:32:00+00:00"},
  {"id":"R-88","kind":"review","status":"open","repo":"acme/widgets","key":"pr-2","session_id":null,"question":"Merged: the importer patch","context":[],"options":[],"default_option":null,"default_at":null,"impact_declared":null,"parked":false,"cost":null,"focus":null,"answer":null,"created_at":"2026-10-05T14:33:00+00:00"},
  {"id":"D-53","kind":"decision","status":"open","repo":"acme/widgets","key":"issue-90","session_id":"sess-b","question":"How should the staging data be anonymised?","context":[],"options":[],"default_option":null,"default_at":null,"impact_declared":null,"parked":false,"cost":"half a day","focus":null,"answer":null,"created_at":"2026-10-05T14:40:00+00:00"}
]
JSON

# dj JQ ARGS... FILTER — desk.jq's functions through JQ, on stdin.
dj() {
  local j="$1"
  shift
  "$j" -L "$SKILL_DIR" "$@"
}
FIRST_JQ="${JQS# }"
FIRST_JQ="${FIRST_JQ%% *}"
item() { "$FIRST_JQ" -c --arg id "$1" ".[] | select(.id == \$id)" "$TMP/items.json"; }
# The jq programs the skill runs; $k and $m are jq's, hence the escapes.
P_PROMPT="include \"desk\"; longform_prompt(\$k; \$m)"
P_RENDER="include \"desk\"; render_longform(\$k; \$m)"

# unquoted_questions TEXT — lines outside the blockquote that end in `?` once
# trailing whitespace and emphasis are stripped: what #1778's nudge flags.
unquoted_questions() {
  printf '%s\n' "$1" | grep -v '^>' | sed -E 's/[[:space:]*_~]+$//' | grep -c '?$' || true
}

for J in $JQS; do
  echo "=== jq: $J — $("$J" --version 2>&1)"

  # --- classify ---------------------------------------------------------------
  shape() { printf '%s' "$1" | dj "$J" -r 'include "desk"; menu_shaped' 2>&1; }
  check "[$J] no options: long-form" "$(shape '{"options":[]}')" "false"
  check "[$J] one option: long-form" "$(shape '{"options":["A"]}')" "false"
  check "[$J] five options: long-form" "$(shape '{"options":["A","B","C","D","E"]}')" "false"
  check "[$J] options missing: long-form" "$(shape '{}')" "false"
  check "[$J] three options, no cost: menu" "$(shape '{"options":["A","B","C"]}')" "true"
  for c in '~10 min' '45 minutes' '5m' 'no deep focus' 'before Thursday' 'after the holidays'; do
    check "[$J] two options, cost '$c': menu" "$(shape "{\"options\":[\"A\",\"B\"],\"cost\":\"$c\"}")" "true"
  done
  for c in '2h' '1h30' '2 hrs' '2hrs' 'an hour' '~3 hours' 'half a day' '3 days' '2days' 'a week' '3 weeks' '2 wks'; do
    check "[$J] two options, cost '$c': long-form" "$(shape "{\"options\":[\"A\",\"B\"],\"cost\":\"$c\"}")" "false"
  done

  # --- split -------------------------------------------------------------------
  OUT=$(dj "$J" -c 'include "desk"; desk_split("")' "$TMP/items.json" 2>&1)
  check "[$J] desk_split: open Decisions, simple and grouped long-form" "$OUT" \
    '{"simple":["D-43","D-49"],"longform":[["D-45"],["D-47","D-48","D-53"],["D-50"],["D-51"]]}'
  OUT=$(dj "$J" -c 'include "desk"; desk_split("D-48 D-50 D-52 R-88 D-99")' "$TMP/items.json" 2>&1)
  check "[$J] desk_split with ids: those, a part with its group (answered, Reviews, unknown dropped)" "$OUT" \
    '{"simple":[],"longform":[["D-47","D-48","D-53"],["D-50"]]}'
  # A tick that lands between two of the capture hook's adds reports the
  # later part alone; it still comes as its whole group, never part 1 of 1.
  OUT=$(dj "$J" -c 'include "desk"; desk_split("D-53")' "$TMP/items.json" 2>&1)
  check "[$J] desk_split: a later part named alone brings its open group" "$OUT" \
    '{"simple":[],"longform":[["D-47","D-48","D-53"]]}'
  OUT=$(dj "$J" -c 'include "desk"; desk_split("D-49")' "$TMP/items.json" 2>&1)
  check "[$J] desk_split: a named menu question brings no long-form siblings" "$OUT" \
    '{"simple":["D-49"],"longform":[]}'
  OUT=$(dj "$J" -c 'include "desk"; desk_split("  D-43   D-49 ")' "$TMP/items.json" 2>&1)
  check "[$J] desk_split ignores extra spaces in the ids" "$OUT" '{"simple":["D-43","D-49"],"longform":[]}'
  OUT=$(printf '[]' | dj "$J" -c 'include "desk"; desk_split("")' 2>&1)
  check "[$J] desk_split of an empty list" "$OUT" '{"simple":[],"longform":[]}'

  # --- render ------------------------------------------------------------------
  OUT=$(item D-45 | dj "$J" -r --argjson k 1 --argjson m 1 "$P_PROMPT" 2>&1)
  check "[$J] single long-form card: header" "$(printf '%s\n' "$OUT" | sed -n 1p)" \
    '> **D-45** · long-form · acme/widgets · issue-77'
  check "[$J] single long-form card: bold question" "$(printf '%s\n' "$OUT" | sed -n 2p)" \
    '> **What should the onboarding email say about pricing?**'
  check_contains "[$J] single long-form card: parked, impact" "$OUT" '> Impact: high · Parked: the thread waits for this answer'
  check_contains "[$J] single long-form card: link" "$OUT" '> Link: Issue #77 — https://github.com/acme/widgets/issues/77'
  check_contains "[$J] single long-form card: return address" "$OUT" "woken with \`human-queue: D-45 answered\`"
  check_contains "[$J] single long-form card: the reply contract" "$OUT" \
    "Write your answer. Your next message is stored as D-45's answer, word for word. \`skip\` leaves it open; \`discuss\` talks it through first."
  check_absent "[$J] single long-form card: no options line" "$OUT" 'Options:'
  check "[$J] single long-form card: no unquoted line ends in ?" "$(unquoted_questions "$OUT")" "0"
  CARD_LINES=$(printf '%s\n' "$OUT" | sed '/^$/,$d')
  check "[$J] single long-form card: every card line is quoted" \
    "$(printf '%s\n' "$CARD_LINES" | grep -vc '^>' || true)" "0"

  OUT=$(item D-48 | dj "$J" -r --argjson k 2 --argjson m 3 "$P_PROMPT" 2>&1)
  check_contains "[$J] multipart card: part 2 of 3" "$OUT" '> **D-48** · part 2 of 3 · acme/widgets · issue-90'

  OUT=$(item D-43 | dj "$J" -r --argjson k 1 --argjson m 1 "$P_RENDER" 2>&1)
  check_contains "[$J] card with context: numbered" "$OUT" '> 2. The failing tests are correct about the behaviour.'
  check_contains "[$J] card with options: default first marked once" "$OUT" \
    '> Options: A. Skip the two tests for now · B. Fix the window math (Recommended) · C. Relax the assertion to ±1 hour'
  check "[$J] card with options: (Recommended) appears once" \
    "$(printf '%s\n' "$OUT" | grep -o 'Recommended' | grep -c . || true)" "1"
  check_contains "[$J] card with options: default and its time in UTC" "$OUT" \
    '> Default: B. Fix the window math — the thread takes it at 2026-10-05 20:15 UTC if unanswered'
  check_contains "[$J] card with options: impact, cost, focus" "$OUT" '> Impact: medium · Cost: ~10 min · Focus: no deep focus'
  check_contains "[$J] card with options: session shortened" "$OUT" 'the asking thread (session 11111111…)'
  check_contains "[$J] card with options: letter or text" "$OUT" 'Reply with a letter to pick an option, or write your own answer.'

  OUT=$(item D-50 | dj "$J" -r --argjson k 1 --argjson m 1 "$P_PROMPT" 2>&1)
  check_contains "[$J] card without a return address" "$OUT" '> Answer goes to: the store only (no return address)'
  check_contains "[$J] card: default without a time" "$OUT" '> Default: B. Patch'
  check_absent "[$J] card: no time when none is set" "$OUT" 'takes it at'

  OUT=$(item D-52 | dj "$J" -r --argjson k 1 --argjson m 1 "$P_PROMPT" 2>&1)
  check "[$J] an answered item is skipped, not asked again" "$OUT" "D-52 is answered now, so it is skipped."

  # --- discuss card ------------------------------------------------------------
  OUT=$(item D-43 | dj "$J" -r 'include "desk"; discuss_card' 2>&1)
  check "[$J] discuss card: header" "$(printf '%s\n' "$OUT" | sed -n 1p)" \
    '> Discussing **D-43** · open · acme/widgets · pr-318 · asked 2026-10-05 14:04 UTC'
  for needle in '> 1. The quiet-hours window' '> Options: A. Skip' '> Link: PR #318 — https://github.com/acme/widgets/pull/318' \
                '> Default: B. Fix the window math'; do
    check_contains "[$J] discuss card: $needle" "$OUT" "$needle"
  done
  check "[$J] discuss card: every line quoted" "$(printf '%s\n' "$OUT" | grep -vc '^>' || true)" "0"
  check "[$J] discuss card: no unquoted line ends in ?" "$(unquoted_questions "$OUT")" "0"
  OUT=$(item D-52 | dj "$J" -r 'include "desk"; discuss_card' 2>&1)
  check_contains "[$J] discuss card: a multi-line answer, every line quoted" "$OUT" \
    "$(printf '> Answer so far: yes\n> and a second line')"
  check_contains "[$J] discuss card: an answered item says so" "$OUT" '> Discussing **D-52** · answered'

  # --- links -------------------------------------------------------------------
  link() { printf '%s' "$1" | dj "$J" -c 'include "desk"; item_link' 2>&1; }
  check "[$J] link: pr-N" "$(link '{"repo":"o/r","key":"pr-12"}')" '{"label":"PR #12","url":"https://github.com/o/r/pull/12"}'
  check "[$J] link: issue-N" "$(link '{"repo":"o/r","key":"issue-7"}')" '{"label":"Issue #7","url":"https://github.com/o/r/issues/7"}'
  check "[$J] link: branch, segments encoded" "$(link '{"repo":"o/r","key":"branch:feat/a b#1"}')" \
    '{"label":"branch feat/a b#1","url":"https://github.com/o/r/tree/feat/a%20b%231"}'
  check "[$J] link: none for local/ repos" "$(link '{"repo":"local/x","key":"pr-1"}')" "null"
  check "[$J] link: none for session: keys" "$(link '{"repo":"o/r","key":"session:abc"}')" "null"
  check "[$J] link: none for a shortened key" "$(link '{"repo":"o/r","key":"branch:very-long~0123456789ab"}')" "null"
  check "[$J] link: none for pr-0" "$(link '{"repo":"o/r","key":"pr-0"}')" "null"

  # --- utc ---------------------------------------------------------------------
  t() { printf '%s' "$1" | dj "$J" -r 'include "desk"; utc' 2>&1; }
  check "[$J] utc: +00:00" "$(t '"2026-10-05T18:00:00+00:00"')" "2026-10-05 18:00 UTC"
  check "[$J] utc: Z" "$(t '"2026-10-05T18:00:00Z"')" "2026-10-05 18:00 UTC"
  check "[$J] utc: fraction and a half-hour offset across midnight" "$(t '"2026-10-05T23:30:00.5-05:30"')" "2026-10-06 05:00 UTC"
  check "[$J] utc: +0530 without a colon" "$(t '"2026-10-05T05:30:00+0530"')" "2026-10-05 00:00 UTC"
  check "[$J] utc: hours-only offset" "$(t '"2026-10-05T12:00:00+02"')" "2026-10-05 10:00 UTC"
  check "[$J] utc: anything else passes through" "$(t '"next Tuesday"')" "next Tuesday"
  check "[$J] utc: null stays null" "$(t 'null')" "null"
done

# --- #1778's prose-question nudge stays quiet on the desk's cards -------------
# The desk prints these cards in its own session; the Stop hook must read them
# as quotations. A bare bold question is the negative control: it must warn.
NUDGE="$HQ_T_DESK_DIR/hooks/question-leak-warn.sh"
if [ -f "$NUDGE" ]; then
  nudge() {
    "$FIRST_JQ" -n --arg m "$1" --arg s "longform-offline-$$-$2" \
      "{session_id: \$s, stop_hook_active: false, last_assistant_message: \$m}" \
      | bash "$NUDGE" 2>/dev/null
  }
  for id in D-43 D-45 D-48; do
    check "the nudge is silent on $id's long-form card" \
      "$(nudge "$(item "$id" | "$FIRST_JQ" -r -L "$SKILL_DIR" --argjson k 1 --argjson m 1 "$P_RENDER")" "lf-$id")" ""
    check "the nudge is silent on $id's discussion card" \
      "$(nudge "$(item "$id" | "$FIRST_JQ" -r -L "$SKILL_DIR" 'include "desk"; discuss_card')" "dc-$id")" ""
  done
  check_contains "negative control: the nudge warns on a bare bold question" \
    "$(nudge '**Which region should staging use?**' neg)" "PROSE QUESTION WARNING"
else
  printf 'skip — the prose-question nudge (%s) is not in this checkout\n' "${NUDGE#"$HQ_T_DESK_DIR"/}"
fi

# --- answer --stdin / --json ---------------------------------------------------
# ans SHELL STDIN ARGS... — `answer ARGS` against the black-hole URL with the
# file STDIN on standard input; sets OUT, ERR, RC, and whether it returned
# within a second (no connection attempt).
ans() {
  local sh="$1" in="$2" start end
  shift 2
  start=$(hq_t_now)
  RC=0
  env HUMAN_QUEUE_DATABASE_URL="$BLACKHOLE_URL" "$sh" "$HQ_T_CLI" answer "$@" \
    <"$in" >"$TMP/out" 2>"$TMP/err" || RC=$?
  end=$(hq_t_now)
  FAST=0
  if hq_t_elapsed_under "$start" "$end" 1.0; then FAST=1; fi
  OUT=$(cat "$TMP/out")
  ERR=$(cat "$TMP/err")
}

# refused SHELL CODE LABEL NEEDLE STDIN ARGS...
refused() {
  local sh="$1" code="$2" label="$3" needle="$4" in="$5"
  shift 5
  ans "$sh" "$in" "$@"
  check "[$sh] $label: exit $code" "$RC" "$code"
  check "[$sh] $label: one stderr line" "$(hq_t_lines "$ERR")" "1"
  check "[$sh] $label: nothing on stdout" "$OUT" ""
  check_contains "[$sh] $label: names it" "$ERR" "$needle"
  check "[$sh] $label: no connection attempt" "$FAST" "1"
}

# reaches_db SHELL LABEL STDIN ARGS... — valid input: with the URL unset, exit 7.
reaches_db() {
  local sh="$1" label="$2" in="$3" rc=0
  shift 3
  env -u HUMAN_QUEUE_DATABASE_URL "$sh" "$HQ_T_CLI" answer "$@" <"$in" >/dev/null 2>"$TMP/err" || rc=$?
  check "[$sh] $label passes validation (exit 7, URL unset)" "$rc" "7"
}

: > "$TMP/empty"
printf 'a fine answer\n' > "$TMP/fine"
printf '   \n\n\t \n' > "$TMP/blank"
printf 'before\000after\n' > "$TMP/nul"
printf 'yes\033]52;c;eA==\007\n' > "$TMP/escape"
printf 'fine\rFORGED\n' > "$TMP/cr"
printf 'use %s now\n' "$FAKE_GH" > "$TMP/secret"
head -c 16001 /dev/zero | tr '\000' x > "$TMP/over-cap"
head -c 4001 /dev/zero | tr '\000' x > "$TMP/over-4000"
head -c 4000 /dev/zero | tr '\000' x > "$TMP/at-4000"
{ head -c 4000 /dev/zero | tr '\000' x; printf '\n\n\n  \n'; } > "$TMP/at-4000-trailing"
printf -- '--json\n' > "$TMP/flag-word"

for SH in $SHELLS; do
  echo "=== shell: $SH — $("$SH" --version 2>&1 | sed -n 1p)"
  RC=0
  HELP=$(env -u HUMAN_QUEUE_DATABASE_URL "$SH" "$HQ_T_CLI" answer --help 2>&1) || RC=$?
  check "[$SH] answer --help exits 0" "$RC" "0"
  for needle in 'answer ID --stdin [--json]' '--stdin  read the answer from standard input' \
                '"changed": true' '16000 bytes'; do
    check_contains "[$SH] answer --help documents: $needle" "$HELP" "$needle"
  done

  refused "$SH" 4 "an answer given both ways" "as an argument or with --stdin, not both" "$TMP/fine" D-1 yes --stdin
  refused "$SH" 4 "an empty stdin" "the answer is empty" "$TMP/empty" D-1 --stdin
  refused "$SH" 4 "a blank stdin" "the answer is empty" "$TMP/blank" D-1 --stdin
  refused "$SH" 4 "a NUL byte" "contains a control character" "$TMP/nul" D-1 --stdin
  refused "$SH" 4 "a terminal escape" "contains a control character" "$TMP/escape" D-1 --stdin
  check_absent "[$SH] the escape is not echoed" "$OUT$ERR" "$(printf '\033')"
  refused "$SH" 4 "a carriage return" "contains a control character" "$TMP/cr" D-1 --stdin
  refused "$SH" 4 "more than 16000 bytes" "longer than 4000 characters" "$TMP/over-cap" D-1 --stdin
  refused "$SH" 4 "4001 characters" "longer than 4000 characters" "$TMP/over-4000" D-1 --stdin
  refused "$SH" 5 "a secret on stdin" "the answer looks like a GitHub token" "$TMP/secret" D-1 --stdin --json
  check_absent "[$SH] the secret is not echoed" "$OUT$ERR" "$FAKE_GH"
  refused "$SH" 4 "--json twice" "--json given more than once" "$TMP/empty" D-1 yes --json --json
  refused "$SH" 4 "--stdin twice" "--stdin given more than once" "$TMP/fine" D-1 --stdin --stdin
  refused "$SH" 4 "--stdin without an id" "missing item id" "$TMP/fine" --stdin
  refused "$SH" 4 "--stdin for a Review" "R-3 is a Review" "$TMP/fine" R-3 --stdin
  refused "$SH" 4 "an unknown flag before the id" "unknown option '--fast'" "$TMP/fine" --fast D-1 --stdin
  refused "$SH" 4 "a third word" "one item id and one answer" "$TMP/empty" D-1 yes please --json

  reaches_db "$SH" "--stdin" "$TMP/fine" D-1 --stdin
  reaches_db "$SH" "--stdin --json, flags first" "$TMP/fine" --json --stdin d-1
  reaches_db "$SH" "4000 characters on stdin" "$TMP/at-4000" D-1 --stdin
  reaches_db "$SH" "4000 characters and trailing blank lines" "$TMP/at-4000-trailing" D-1 --stdin
  reaches_db "$SH" "the word --json as an answer, through --stdin" "$TMP/flag-word" D-1 --stdin
  reaches_db "$SH" "a positional answer with --json" "$TMP/empty" D-1 "Ship it" --json
  reaches_db "$SH" "a positional answer starting with a dash" "$TMP/empty" D-1 "-- not now"
done

# --- the skill's own blocks, against a stub CLI ------------------------------
STUB_DIR="$TMP/stub"
mkdir -p "$STUB_DIR"
cp "$TMP/items.json" "$STUB_DIR/items.json"
STUB="$STUB_DIR/cli.sh"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
# A stand-in for desk-cli.sh: records its arguments and standard input.
# STUB_EXIT=<n> makes list and get fail the way an unreachable store does.
d="$STUB_DIR"
printf '%s\n' "\$@" > "\$d/args"
if [ -n "\${STUB_EXIT:-}" ] && { [ "\$1" = list ] || [ "\$1" = get ]; }; then
  echo "stub: the store is unreachable" >&2
  exit "\$STUB_EXIT"
fi
case "\$1" in
  list) cat "\$d/items.json" ;;
  get)
    item=\$("$FIRST_JQ" -c --arg id "\$2" '.[] | select(.id == \$id)' "\$d/items.json")
    if [ -z "\$item" ]; then echo "human-queue.sh get: no item \$2" >&2; exit 4; fi
    printf '%s\n' "\$item"
    ;;
  answer) cat > "\$d/stdin"; printf '{"id": "%s", "answer": "stub", "changed": true, "session": "sess-b"}\n' "\$2" ;;
  *) echo "stub: unexpected \$1" >&2; exit 1 ;;
esac
EOF
chmod +x "$STUB"

block() {
  local file="$1" name="$2" out rc=0
  out=$(hq_t_skill_block "$file" "$name" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "anchor $name in ${file##*/} extracts (rc=$rc: $out)"
    printf '\n'
    return 1
  fi
  ok "anchor $name in ${file##*/} extracts"
  printf '%s\n' "$out" > "$TMP/block-$name.sh"
}

# literal FILE FROM TO — FILE with every FROM replaced by TO, literally.
literal() { FROM="$2" TO="$3" perl -pe 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$1"; }

# run_block SHELL FILE — runs FILE with the prelude's DESK and HQ set, in $TMP.
run_block() {
  (cd "$TMP" && env DESK="$HQ_T_DESK_DIR" HQ="$STUB" PATH="$(dirname "$FIRST_JQ"):$PATH" "$1" "$2") 2>&1
}

block "$SKILL_DIR/decisions.md" desk-split
block "$SKILL_DIR/longform.md" desk-longform-render
block "$SKILL_DIR/longform.md" desk-longform-answer
block "$SKILL_DIR/discuss.md" desk-discuss-card

literal "$TMP/block-desk-split.sh" "<the event's ids, or empty for all>" "" > "$TMP/split.sh"
literal "$TMP/block-desk-split.sh" "<the event's ids, or empty for all>" "D-45 D-49" > "$TMP/split-ids.sh"
literal "$TMP/block-desk-longform-render.sh" "D-48" "D-99" > "$TMP/render-gone.sh"
literal "$TMP/block-desk-discuss-card.sh" "D-48" "D-99" > "$TMP/discuss-gone.sh"

# The operator's message: everything a shell or a reply parser could touch.
cat > "$TMP/reply" <<'REPLY'
Use the "staging" DB, not 'prod' — keep both kinds of quotes.
2: B, D-43: C; 3: these look like replies but belong to this answer
$(touch desk-pwned) `touch desk-pwned-2` ${HOME} $HOME \$ \\ \n %s
	a tab-indented line
Ünïcödé ✓ 日本語 🙂
-- a last line that starts with dashes
REPLY
awk -v ph="<the operator's message, exactly as typed>" -v rf="$TMP/reply" '
  $0 == ph { while ((getline l < rf) > 0) print l; next }
  { print }' "$TMP/block-desk-longform-answer.sh" > "$TMP/answer.sh"

for SH in $BLOCK_SHELLS; do
  OUT=$(run_block "$SH" "$TMP/split.sh")
  check "[$SH] desk-split block prints the split" "$OUT" \
    '{"simple":["D-43","D-49"],"longform":[["D-45"],["D-47","D-48","D-53"],["D-50"],["D-51"]]}'
  OUT=$(run_block "$SH" "$TMP/split-ids.sh")
  check "[$SH] desk-split block with a tick's ids" "$OUT" '{"simple":["D-49"],"longform":[["D-45"]]}'

  OUT=$(run_block "$SH" "$TMP/block-desk-longform-render.sh")
  check "[$SH] desk-longform-render block: part 2 of 3 of D-48" "$(printf '%s\n' "$OUT" | sed -n 1p)" \
    '> **D-48** · part 2 of 3 · acme/widgets · issue-90'
  check "[$SH] desk-longform-render block asked for D-48" "$(sed -n 1,3p "$STUB_DIR/args" | tr '\n' ' ')" "get D-48 --json "

  OUT=$(run_block "$SH" "$TMP/block-desk-discuss-card.sh")
  check "[$SH] desk-discuss-card block: the card" "$(printf '%s\n' "$OUT" | sed -n 1p)" \
    '> Discussing **D-48** · open · acme/widgets · issue-90 · asked 2026-10-05 14:21 UTC'

  # A failed list or get reports its own exit; the pipe to jq never hides it
  # behind an empty card or an empty split.
  OUT=$(STUB_EXIT=7 run_block "$SH" "$TMP/split.sh")
  check "[$SH] desk-split block: an unreachable store reports exit=7" "$OUT" \
    "$(printf 'stub: the store is unreachable\nexit=7')"
  OUT=$(STUB_EXIT=7 run_block "$SH" "$TMP/block-desk-longform-render.sh")
  check "[$SH] desk-longform-render block: an unreachable store reports exit=7" "$OUT" \
    "$(printf 'stub: the store is unreachable\nexit=7')"
  OUT=$(run_block "$SH" "$TMP/render-gone.sh")
  check "[$SH] desk-longform-render block: a gone item reports exit=4" "$OUT" \
    "$(printf 'human-queue.sh get: no item D-99\nexit=4')"
  OUT=$(STUB_EXIT=7 run_block "$SH" "$TMP/block-desk-discuss-card.sh")
  check "[$SH] desk-discuss-card block: an unreachable store reports exit=7" "$OUT" \
    "$(printf 'stub: the store is unreachable\nexit=7')"
  OUT=$(run_block "$SH" "$TMP/discuss-gone.sh")
  check "[$SH] desk-discuss-card block: a gone item reports exit=4" "$OUT" \
    "$(printf 'human-queue.sh get: no item D-99\nexit=4')"

  rm -f "$STUB_DIR/stdin" "$TMP/desk-pwned" "$TMP/desk-pwned-2"
  OUT=$(run_block "$SH" "$TMP/answer.sh")
  check_contains "[$SH] desk-longform-answer block: exit 0 reported" "$OUT" "exit=0"
  check "[$SH] desk-longform-answer block: answer D-48 --stdin --json" \
    "$(tr '\n' ' ' < "$STUB_DIR/args")" "answer D-48 --stdin --json "
  if [ -f "$STUB_DIR/stdin" ] && cmp -s "$TMP/reply" "$STUB_DIR/stdin"; then
    ok "[$SH] desk-longform-answer block: the message reaches answer byte for byte"
  else
    bad "[$SH] desk-longform-answer block: the message changed on the way (cmp $TMP/reply vs stdin)"
    diff "$TMP/reply" "$STUB_DIR/stdin" 2>&1 | sed -n 1,10p
  fi
  if [ -e "$TMP/desk-pwned" ] || [ -e "$TMP/desk-pwned-2" ]; then
    bad "[$SH] desk-longform-answer block ran a command from the message"
  else
    ok "[$SH] desk-longform-answer block ran nothing from the message"
  fi
done

# --- the skill's written contract --------------------------------------------
SKILL=$(cat "$SKILL_DIR/SKILL.md")
DECISIONS=$(cat "$SKILL_DIR/decisions.md")
LONGFORM=$(cat "$SKILL_DIR/longform.md")
DISCUSS=$(cat "$SKILL_DIR/discuss.md")
# contract FILE_LABEL TEXT — every line of stdin must appear in TEXT. The
# needles come from quoted here-documents, so backticks and `$` stay literal.
contract() {
  local label="$1" text="$2" needle
  while IFS= read -r needle; do
    [ -n "$needle" ] || continue
    check_contains "$label: $needle" "$text" "$needle"
  done
}
contract SKILL.md "$SKILL" <<'NEEDLES'
`longform.md`
`discuss.md`
`desk.jq`
#1781
A long-form prompt waits for its reply
`discuss <n>`, or `discuss D-<id>` → load `discuss.md`
NEEDLES
contract decisions.md "$DECISIONS" <<'NEEDLES'
'include "desk"; desk_split($ids)'
`longform.md`
`discuss.md`
`set-resolve` would split a long answer
NEEDLES
check_absent "decisions.md: no inline copy of the classification" "$DECISIONS" 'def long:'
contract longform.md "$LONGFORM" <<'NEEDLES'
"$HQ" answer D-48 --stdin --json <<'DESK_ANSWER'
word for word
never AskUserQuestion
**`skip`** or **`next`**
`skip all`
Anything else is the answer
set-open D-47 D-48 D-53 --json
Tick events while a prompt waits
is held, not shown
longform_prompt($k; $m)
Wake the asking thread now, before the next part
NEEDLES
contract discuss.md "$DISCUSS" <<'NEEDLES'
**`done`** or **`back`**
Discussion writes nothing
never stored as the answer
never AskUserQuestion
## 5. Present the item again
Never invent.
read-only
## Not in this increment
`answer-parked`
`show D-<n>`
`history`
#1781
discuss_card
NEEDLES

hq_t_finish "longform-offline.test.sh"
