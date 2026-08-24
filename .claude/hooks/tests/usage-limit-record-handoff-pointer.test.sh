#!/usr/bin/env bash
# Portable-handoff-pointer tests for usage-limit-record.sh (split from the
# monolith by Issue #1071). Covers the enrichment layer that names the most
# recent /stop handoff in the breadcrumb (issue #901).
#
# Self-contained — defines its own helpers. No shared harness.
# Sub-case labels 15a-15k are preserved from the original file for
# searchability in issue and review history.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/usage-limit-record.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# --- 15. Portable handoff pointer (issue #901) ---------------------------
# The breadcrumb should name the document /stop already wrote, when there is
# one. This is a filesystem lookup only — see the code-body grep in case 8,
# which also covers the lines added for this.
BASE_HINT="Turn ended on an Anthropic usage limit. Reconstruct in-flight state from the transcript above, then resume; see .claude/reference/usage-limit-signal-audit-2026-07.md."

# Fixture mtimes MUST be derived from the current clock. The hook filters with
# `find -mtime -N`, which is relative to now, so a hard-coded calendar date is a
# time bomb: fine on the day it is written, then silently future-dated before it
# and aged out after it. `date -r` is BSD, `date -d @` is GNU.
stamp_ago() { # $1 = seconds before now -> YYYYMMDDhhmm for `touch -t`
  local epoch=$(( $(date -u +%s) - $1 ))
  date -u -r "$epoch" +%Y%m%d%H%M 2>/dev/null && return 0
  date -u -d "@$epoch" +%Y%m%d%H%M 2>/dev/null && return 0
  return 1
}
touch_ago() { local when; when=$(stamp_ago "$2") || fail "cannot compute a relative timestamp on this platform"; touch -t "$when" "$1"; }

# 15a. No handoff on disk: byte-identical to the hint this hook always wrote.
# Asserted as full equality, not a substring — an appended sentence in the
# no-handoff case is exactly the regression this pins down.
NONE_DIR="$TMP_DIR/handoff-none"
mkdir -p "$NONE_DIR"
printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"none"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$NONE_DIR" CLAUDE_HANDOFF_DIR="$NONE_DIR/handoffs" bash "$HOOK"
NONE_LAST="$NONE_DIR/usage-limit-last.json"
[[ -f "$NONE_LAST" ]] || fail "no-handoff case produced no record"
GOT_HINT=$(jq -r '.resume_hint' "$NONE_LAST")
[[ "$GOT_HINT" == "$BASE_HINT" ]] \
  || fail "resume_hint changed when no portable handoff exists:"$'\n'"got:  $GOT_HINT"$'\n'"want: $BASE_HINT"
jq -e '.portable_handoff == null' "$NONE_LAST" >/dev/null \
  || fail "portable_handoff should be null when none is on disk"

# 15b. An empty handoffs directory is the same as no directory at all.
EMPTY_DIR="$TMP_DIR/handoff-empty"
mkdir -p "$EMPTY_DIR/handoffs"
printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"empty"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$EMPTY_DIR" CLAUDE_HANDOFF_DIR="$EMPTY_DIR/handoffs" bash "$HOOK"
[[ "$(jq -r '.resume_hint' "$EMPTY_DIR/usage-limit-last.json")" == "$BASE_HINT" ]] \
  || fail "an empty handoffs/ directory must not alter resume_hint"

# 15c. With handoffs present, the NEWEST by mtime is named. The newer file is
# given the LEXICALLY SMALLER name on purpose: with the name-based tie-break in
# play, naming the newer file `zzz` would let this pass even if mtime ordering
# were broken entirely.
SOME_DIR="$TMP_DIR/handoff-some"
mkdir -p "$SOME_DIR/handoffs"
OLDER="$SOME_DIR/handoffs/portable-handoff-zzz-older.md"
NEWER="$SOME_DIR/handoffs/portable-handoff-aaa-newer.md"
DECOY="$SOME_DIR/handoffs/issue-maker-zzz-log.json"
printf 'older\n' >"$OLDER"
printf 'newer\n' >"$NEWER"
printf '{}\n' >"$DECOY"
touch_ago "$OLDER" 7200    # 2h ago
touch_ago "$NEWER" 3600    # 1h ago — newer mtime, smaller name
touch_ago "$DECOY" 60      # newest file in the dir, but not a handoff

printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"some"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$SOME_DIR" CLAUDE_HANDOFF_DIR="$SOME_DIR/handoffs" bash "$HOOK"
SOME_LAST="$SOME_DIR/usage-limit-last.json"

jq -e --arg p "$NEWER" '.portable_handoff == $p' "$SOME_LAST" >/dev/null \
  || fail "portable_handoff is not the newest handoff by mtime (got $(jq -r '.portable_handoff' "$SOME_LAST"))"
jq -e --arg p "$NEWER" '.resume_hint | contains($p)' "$SOME_LAST" >/dev/null \
  || fail "resume_hint does not name the portable handoff"
jq -e --arg p "$OLDER" '.resume_hint | contains($p) | not' "$SOME_LAST" >/dev/null \
  || fail "resume_hint names the older handoff"
jq -e --arg h "$BASE_HINT" '.resume_hint | startswith($h)' "$SOME_LAST" >/dev/null \
  || fail "the handoff pointer replaced the base hint instead of extending it"

# 15d. Only portable-handoff-*.md is eligible — a newer unrelated file in the
# same directory must not be advertised as a handoff. The in-progress temp file
# /stop stages before its atomic rename is deliberately dot-prefixed and
# suffix-less for exactly this reason: an unverified draft must never be
# advertised as a finished handoff.
DRAFT="$SOME_DIR/handoffs/.portable-handoff.aBcDeF"
printf 'half-written\n' >"$DRAFT"
touch_ago "$DRAFT" 30
printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"draft"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$SOME_DIR" CLAUDE_HANDOFF_DIR="$SOME_DIR/handoffs" bash "$HOOK"
jq -e '.portable_handoff | test("issue-maker") | not' "$SOME_LAST" >/dev/null \
  || fail "a non-handoff file in handoffs/ was picked up as the pointer"
jq -e --arg p "$NEWER" '.portable_handoff == $p' "$SOME_LAST" >/dev/null \
  || fail "an in-progress temp draft was advertised as the handoff"

# 15e. Equal mtimes resolve deterministically to the lexically greater name.
# This pins DETERMINISM, not chronology: two handoffs written in the same second
# carry the same embedded timestamp, so nothing about their names identifies the
# later one. Without the tie-break the winner would vary with directory
# iteration order, which is the actual defect being guarded against.
TIE_EARLIER="$SOME_DIR/handoffs/portable-handoff-ccc-tie.md"
TIE_LATER="$SOME_DIR/handoffs/portable-handoff-ddd-tie.md"
printf 'earlier\n' >"$TIE_EARLIER"
printf 'later\n' >"$TIE_LATER"
TIE_STAMP=$(stamp_ago 600) || fail "cannot compute a relative timestamp"
touch -t "$TIE_STAMP" "$TIE_EARLIER" "$TIE_LATER"
printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"tie"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$SOME_DIR" CLAUDE_HANDOFF_DIR="$SOME_DIR/handoffs" bash "$HOOK"
jq -e --arg p "$TIE_LATER" '.portable_handoff == $p' "$SOME_LAST" >/dev/null \
  || fail "equal-mtime handoffs did not use the lexical tie-breaker (got $(jq -r '.portable_handoff' "$SOME_LAST"))"
jq -e --arg p "$TIE_LATER" '.resume_hint | contains($p)' "$SOME_LAST" >/dev/null \
  || fail "resume_hint does not name the tie-break winner"

# 15f. The handoff directory is its OWN concept, not a subdirectory of this
# hook's output dir. /stop writes to ~/.claude/handoffs regardless of where the
# recorder keeps its records, so deriving one from the other would point the
# lookup at a directory no handoff is ever written to.
SPLIT_REC="$TMP_DIR/split-records"     # where the recorder writes
SPLIT_HAND="$TMP_DIR/split-handoffs"   # where handoffs actually live
mkdir -p "$SPLIT_REC/handoffs" "$SPLIT_HAND"
DECOY_UNDER_RECORDS="$SPLIT_REC/handoffs/portable-handoff-decoy-20260801T235959Z.md"
REAL_HANDOFF="$SPLIT_HAND/portable-handoff-real-20260801T090000Z.md"
printf 'decoy\n' >"$DECOY_UNDER_RECORDS"   # newer name, wrong directory
printf 'real\n'  >"$REAL_HANDOFF"
printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"split"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$SPLIT_REC" CLAUDE_HANDOFF_DIR="$SPLIT_HAND" bash "$HOOK"
jq -e --arg p "$REAL_HANDOFF" '.portable_handoff == $p' "$SPLIT_REC/usage-limit-last.json" >/dev/null \
  || fail "handoff lookup did not use the handoff dir (got $(jq -r '.portable_handoff' "$SPLIT_REC/usage-limit-last.json"))"

# 15g. Handoffs age out. A document from a different project weeks ago must not
# stay advertised as the resume pointer — a stale pointer presented as current
# reads as an answer and is worse than no pointer at all.
AGED_DIR="$TMP_DIR/aged"
mkdir -p "$AGED_DIR/handoffs"
STALE_HANDOFF="$AGED_DIR/handoffs/portable-handoff-ancient.md"
printf 'ancient\n' >"$STALE_HANDOFF"
touch_ago "$STALE_HANDOFF" 2592000   # 30 days ago — well outside the 7-day window
printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"aged"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$AGED_DIR" CLAUDE_HANDOFF_DIR="$AGED_DIR/handoffs" bash "$HOOK"
AGED_LAST="$AGED_DIR/usage-limit-last.json"
jq -e '.portable_handoff == null' "$AGED_LAST" >/dev/null \
  || fail "a handoff far past the age bound was still advertised"
[[ "$(jq -r '.resume_hint' "$AGED_LAST")" == "$BASE_HINT" ]] \
  || fail "an aged-out handoff must leave resume_hint at its unchanged base value"

# A fresh handoff in that same directory is still found — the bound filters by
# age, it does not disable the lookup.
FRESH_HANDOFF="$AGED_DIR/handoffs/portable-handoff-fresh.md"
printf 'fresh\n' >"$FRESH_HANDOFF"
touch_ago "$FRESH_HANDOFF" 300       # 5 minutes ago
printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"aged2"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$AGED_DIR" CLAUDE_HANDOFF_DIR="$AGED_DIR/handoffs" bash "$HOOK"
jq -e --arg p "$FRESH_HANDOFF" '.portable_handoff == $p' "$AGED_LAST" >/dev/null \
  || fail "the age bound suppressed a fresh handoff too"

# 15h. A bad age setting must not cost the user the pointer. Passed straight to
# `find`, a non-numeric value makes it fail — and its stderr is discarded, so a
# perfectly good handoff would vanish from the breadcrumb with no trace.
BADAGE_DIR="$TMP_DIR/bad-age"
mkdir -p "$BADAGE_DIR/handoffs"
BADAGE_HANDOFF="$BADAGE_DIR/handoffs/portable-handoff-present.md"
printf 'present\n' >"$BADAGE_HANDOFF"
touch_ago "$BADAGE_HANDOFF" 300
for bad in "not-a-number" "" "-3" "7; rm -rf /" "0"; do
  printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"badage"}' \
    | CLAUDE_USAGE_LIMIT_DIR="$BADAGE_DIR" CLAUDE_HANDOFF_DIR="$BADAGE_DIR/handoffs" \
      CLAUDE_HANDOFF_MAX_AGE_DAYS="$bad" bash "$HOOK"
  jq -e --arg p "$BADAGE_HANDOFF" '.portable_handoff == $p' "$BADAGE_DIR/usage-limit-last.json" >/dev/null \
    || fail "a fresh handoff was lost with CLAUDE_HANDOFF_MAX_AGE_DAYS='$bad'"
done
[[ -e / ]] || fail "the injection fixture did something catastrophic"

# 15i. The durable record is written BEFORE the pointer lookup, so no amount of
# slowness in the optional enrichment can cost the user the record. Assert the
# ordering structurally: the events append must appear before the lookup call.
APPEND_LINE=$(grep -n '>>"\$EVENTS_LOG"' "$HOOK" | head -1 | cut -d: -f1)
LOOKUP_LINE=$(grep -n '^PORTABLE_HANDOFF=' "$HOOK" | head -1 | cut -d: -f1)
[[ -n "$APPEND_LINE" && -n "$LOOKUP_LINE" ]] \
  || fail "could not locate the append and lookup lines to check their ordering"
(( APPEND_LINE < LOOKUP_LINE )) \
  || fail "the handoff lookup (line $LOOKUP_LINE) runs before the durable append (line $APPEND_LINE) — a slow lookup could consume the hook's timeout and lose the record"

# And behaviourally: every events-log line carries the BASE record (phase 1),
# while usage-limit-last.json carries the enriched pointer (phase 2).
while IFS= read -r ev_line; do
  [[ -n "$ev_line" ]] || continue
  printf '%s' "$ev_line" | jq -e --arg h "$BASE_HINT" '.resume_hint == $h' >/dev/null \
    || fail "an events-log record carries an enriched hint; phase 1 must write the base record"
  printf '%s' "$ev_line" | jq -e '.portable_handoff == null' >/dev/null \
    || fail "an events-log record carries a handoff pointer; only usage-limit-last.json is refined"
done <"$SOME_DIR/usage-limit-events.jsonl"
jq -e '.portable_handoff != null' "$SOME_LAST" >/dev/null \
  || fail "usage-limit-last.json lost its handoff pointer after the phase split"

# 15j. Concurrency with a handoff present: `last` must still agree with the
# newest event. Splitting the write into two phases opened the door for a slow
# invocation to finish its enrichment after a newer one published and roll
# `last` back to an older session — breaking the one thing that file promises.
# Concurrency is the EXPECTED case here: one account limit fails every active
# session at once.
RACE_DIR="$TMP_DIR/race"
mkdir -p "$RACE_DIR/handoffs"
RACE_HANDOFF="$RACE_DIR/handoffs/portable-handoff-20260801T120000Z-sess.md"
printf 'handoff\n' >"$RACE_HANDOFF"
touch_ago "$RACE_HANDOFF" 300
RACE_N=8
for i in $(seq 1 "$RACE_N"); do
  printf '%s' "{\"hook_event_name\":\"StopFailure\",\"error\":\"rate_limit\",\"session_id\":\"race$i\"}" \
    | CLAUDE_USAGE_LIMIT_DIR="$RACE_DIR" CLAUDE_HANDOFF_DIR="$RACE_DIR/handoffs" bash "$HOOK" &
done
wait

RACE_LOG="$RACE_DIR/usage-limit-events.jsonl"
RACE_COUNT=$(wc -l <"$RACE_LOG" | tr -d ' ')
[[ "$RACE_COUNT" == "$RACE_N" ]] || fail "concurrent writes with a handoff lost records: got $RACE_COUNT, expected $RACE_N"

RACE_LAST_SID=$(jq -r '.session_id' "$RACE_DIR/usage-limit-last.json")
RACE_TAIL_SID=$(tail -1 "$RACE_LOG" | jq -r '.session_id')
[[ "$RACE_LAST_SID" == "$RACE_TAIL_SID" ]] \
  || fail "usage-limit-last.json ($RACE_LAST_SID) disagrees with the newest event ($RACE_TAIL_SID) — an older invocation's phase 2 clobbered a newer record"

# 15k. Newest-by-mtime holds beyond any window: the newest file is given the
# lexically SMALLEST name among many, so a name-ordered scan that truncated
# would miss it. This is the case the removed scan cap got wrong.
MANY_DIR="$TMP_DIR/many"
mkdir -p "$MANY_DIR/handoffs"
# 10# forces base 10: seq -w zero-pads, and bash reads a leading zero as octal,
# so "008" would abort the arithmetic mid-loop.
for i in $(seq -w 1 120); do
  f="$MANY_DIR/handoffs/portable-handoff-2026080$(( 10#$i % 9 + 1 ))T120000Z-s$i.md"
  printf 'x\n' >"$f"
  touch_ago "$f" 7200                # all the decoys are two hours old
done
MANY_NEWEST="$MANY_DIR/handoffs/portable-handoff-00000000T000000Z-aaa.md"
printf 'newest\n' >"$MANY_NEWEST"
touch_ago "$MANY_NEWEST" 60          # newest mtime, lexically SMALLEST name
printf '%s' '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"many"}' \
  | CLAUDE_USAGE_LIMIT_DIR="$MANY_DIR" CLAUDE_HANDOFF_DIR="$MANY_DIR/handoffs" bash "$HOOK"
jq -e --arg p "$MANY_NEWEST" '.portable_handoff == $p' "$MANY_DIR/usage-limit-last.json" >/dev/null \
  || fail "newest-by-mtime lost among many handoffs (got $(jq -r '.portable_handoff' "$MANY_DIR/usage-limit-last.json"))"

echo "PASS: usage-limit-record-handoff-pointer.sh"
