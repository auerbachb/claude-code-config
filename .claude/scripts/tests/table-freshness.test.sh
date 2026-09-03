#!/usr/bin/env bash
# Tests for table-freshness.sh — the hourly floor on "Running now" table
# freshness during active rounds (issue #1580).
#
# ISOLATION
#   HOME is redirected to a temp dir so session-state.sh reads and writes a
#   throwaway session-state.json, and CLAUDE_TABLE_FRESHNESS_MARKER_DIR moves
#   the dedupe marker out of /tmp. The suite never touches real session state.
#
# WHAT IS ASSERTED
#   1. The floor number lives in this script and nowhere else, and the poll /
#      trip points are DERIVED from it so the guarantee survives an override.
#   2. The four --check verdicts, including the two that make the idle
#      exemption and the fail-closed unrecorded-but-active case correct.
#   3. The tick's four silent cases and its one firing case — with a NEGATIVE
#      CONTROL on each, so "the tick printed nothing" is never accepted as a
#      pass from a tick that could not have fired at all.
#   4. Durability: every read goes to disk in a FRESH process, which is what
#      makes the clock survive a context compaction. The suite asserts this by
#      construction — it never passes a timestamp between invocations.
#   5. Session scoping: two sessions in one repo keep independent clocks.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)" || { echo "cannot resolve repo root" >&2; exit 1; }
SCRIPT="$REPO_ROOT/.claude/scripts/table-freshness.sh"
STATE_SH="$REPO_ROOT/.claude/scripts/session-state.sh"

TMP_DIR="$(mktemp -d)"
export HOME="$TMP_DIR/home"
export CLAUDE_TABLE_FRESHNESS_MARKER_DIR="$TMP_DIR/markers"
mkdir -p "$HOME/.claude" "$CLAUDE_TABLE_FRESHNESS_MARKER_DIR"
printf '%s' '{"schema_version":2}' > "$HOME/.claude/session-state.json"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Isolate from a caller-set override — the default-floor assertions below must
# not silently inherit a different number from the environment.
unset CLAUDE_TABLE_FLOOR_S

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   — $*"; }

SID="tf-test-$$-$RANDOM"
REPO="org/table-freshness"

# Relative timestamps (BSD/macOS then GNU date) — never a hard-coded calendar
# date, which flips future/past depending on when the suite runs.
iso_minutes_ago() {
  TZ=UTC date -j -v-"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ
}

# Backdate the RECORDED render without going through --note-rendered, which
# always stamps "now". This is the only way to test an hour-old clock without
# an hour-long test.
backdate() {  # backdate <minutes> [session]
  local mins="$1" sid="${2:-$SID}"
  "$STATE_SH" --set \
    ".repos[\"$REPO\"].table_render[\"$sid\"].last_rendered_at=$(iso_minutes_ago "$mins")" \
    >/dev/null || fail "backdate write failed"
}

# The dedupe marker is keyed by repo AND session: a readable slug (same non-alnum
# squashing the script applies, so `owner/name` cannot walk out of the dir) plus
# a cksum of the raw key, which is what keeps `org/repo` and `org_repo` apart
# after the squash.
# The checksum component is CONDITIONAL in the script (`${REPO_SUM:+-$REPO_SUM}`),
# which degrades to the slug alone when cksum is absent or prints something
# non-numeric. Mirror that exactly: hard-coding the separator built
# `slug--session` here against the script's `slug-session`, so on a host without
# cksum every marker assertion would have checked a path nothing ever creates —
# the dedupe tests would fail while the dedupe itself was fine.
# The SESSION component is slug+checksum too, for the same reason as the repo
# one: squashing alone maps `a/b` and `a_b` onto one marker.
marker_path() {  # marker_path [repo] [session]
  local repo="${1:-$REPO}" sid="${2:-$SID}" sum ssum
  sum="$(printf '%s' "$repo" | cksum 2>/dev/null | cut -d' ' -f1)"
  [[ "$sum" =~ ^[0-9]+$ ]] || sum=""
  ssum="$(printf '%s' "$sid" | cksum 2>/dev/null | cut -d' ' -f1)"
  [[ "$ssum" =~ ^[0-9]+$ ]] || ssum=""
  printf '%s/claude-tablefloor-emitted-%s%s-%s%s' \
    "$CLAUDE_TABLE_FRESHNESS_MARKER_DIR" "${repo//[^[:alnum:]_.-]/_}" \
    "${sum:+-$sum}" "${sid//[^[:alnum:]_.-]/_}" "${ssum:+-$ssum}"
}

# Sets CHECK_OUT (verdict word) and CHECK_RC. Deliberately NOT called through
# command substitution — that runs it in a subshell, where the exit code it
# captures would never reach the assertion.
run_check() {  # run_check [args...]
  CHECK_OUT="$("$SCRIPT" --check --session "$SID" --repo "$REPO" "$@" 2>/dev/null)"
  CHECK_RC=$?
}

# --- 1. The floor number lives here and nowhere else --------------------------
FLOOR=$("$SCRIPT" --floor-seconds)
[[ "$FLOOR" == "3600" ]] || fail "--floor-seconds should be 3600 (60 min), got '$FLOOR'"
ok "--floor-seconds reports the 60-minute floor"

# --- 2. Derived timing invariant: the floor line is always emitted INSIDE the
#        hour, poll granularity included. Trip and poll are derived from the
#        floor, never tuned independently. ---------------------------------------
STATUS=$("$SCRIPT" --status --session "$SID" --repo "$REPO")
TRIP=$(printf '%s' "$STATUS" | jq -r '.trip_s')
POLL=$(printf '%s' "$STATUS" | jq -r '.poll_s')
(( TRIP < FLOOR )) || fail "trip point ($TRIP) must be below the floor ($FLOOR)"
(( TRIP + POLL <= FLOOR )) || \
  fail "worst-case detection ($((TRIP + POLL))s = trip $TRIP + poll $POLL) must not exceed the floor ($FLOOR)"
ok "trip + poll ($((TRIP + POLL))s) stays inside the floor (${FLOOR}s)"

# --- 3. --check with no record and no --active: nothing to measure ------------
run_check; V="$CHECK_OUT"
[[ "$V" == "unrecorded" && "$CHECK_RC" -eq 0 ]] || \
  fail "no record + no --active should be 'unrecorded'/0, got '$V'/$CHECK_RC"
ok "--check reports 'unrecorded' (exit 0) with no record and no declared activity"

# --- 4. --check fails CLOSED: an active round with no recorded render must
#        carry the table. There is no evidence a table was ever printed. -------
run_check --active 2; V="$CHECK_OUT"
[[ "$V" == "stale" && "$CHECK_RC" -eq 1 ]] || \
  fail "no record + --active 2 should fail closed to 'stale'/1, got '$V'/$CHECK_RC"
ok "--check fails closed ('stale', exit 1) for an active round with no recorded render"

# --- 5. Idle exemption: --active 0 is exempt even with no record --------------
run_check --active 0; V="$CHECK_OUT"
[[ "$V" == "idle" && "$CHECK_RC" -eq 0 ]] || \
  fail "--active 0 should be 'idle'/0, got '$V'/$CHECK_RC"
ok "--check exempts an idle thread ('idle', exit 0)"

# --- 6. --note-rendered persists the clock to DISK ----------------------------
"$SCRIPT" --note-rendered --active 2 --surface subagent-heartbeat \
  --session "$SID" --repo "$REPO" || fail "--note-rendered should succeed"
RECORD=$(jq -c ".repos[\"$REPO\"].table_render[\"$SID\"]" "$HOME/.claude/session-state.json")
[[ "$(printf '%s' "$RECORD" | jq -r '.active_pipelines')" == "2" ]] || \
  fail "active_pipelines should be 2, got: $RECORD"
[[ "$(printf '%s' "$RECORD" | jq -r '.surface')" == "subagent-heartbeat" ]] || \
  fail "surface should be recorded, got: $RECORD"
[[ "$(printf '%s' "$RECORD" | jq -r '.last_rendered_at')" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || \
  fail "last_rendered_at should be ISO-8601, got: $RECORD"
ok "--note-rendered writes last_rendered_at / active_pipelines / surface to session state"

# --- 7. Durability across a context compaction. Every read above and below is
#        a FRESH process holding no memory of the render — the timestamp comes
#        from the file or from nowhere. Prove the negative directly: with the
#        state file emptied, the verdict flips, so the reads cannot have been
#        served by anything but the file. -----------------------------------------
run_check; V="$CHECK_OUT"
[[ "$V" == "fresh" ]] || fail "a just-recorded render should read 'fresh', got '$V'"
cp "$HOME/.claude/session-state.json" "$TMP_DIR/state.bak"
printf '%s' '{"schema_version":2}' > "$HOME/.claude/session-state.json"
run_check; V="$CHECK_OUT"
[[ "$V" == "unrecorded" ]] || \
  fail "with the state file emptied the verdict must flip to 'unrecorded', got '$V' — the reads are not hitting disk"
cp "$TMP_DIR/state.bak" "$HOME/.claude/session-state.json"
run_check; V="$CHECK_OUT"
[[ "$V" == "fresh" ]] || fail "restoring the state file should restore 'fresh', got '$V'"
ok "the freshness clock is read from durable state, not from process memory"

# --- 8. tick is silent while the table is fresh (negative control) ------------
OUT=$("$SCRIPT" --tick --session "$SID" --repo "$REPO"); RC=$?
[[ -z "$OUT" && "$RC" -eq 0 ]] || fail "--tick should be silent and exit 0 while fresh, got rc=$RC out='$OUT'"
ok "--tick is silent while the table is fresh"

# --- 9. tick fires once past the hour with work active ------------------------
backdate 90
OUT=$("$SCRIPT" --tick --session "$SID" --repo "$REPO"); RC=$?
[[ "$RC" -eq 0 ]] || fail "--tick must always exit 0 (a watch that exits stops watching), got $RC"
[[ "$OUT" == *"TABLE FLOOR"* ]] || fail "--tick should print the floor line past the hour, got '$OUT'"
[[ "$OUT" == *"90m old"* ]] || fail "the floor line should name the age, got '$OUT'"
[[ "$OUT" == *"2 pipeline(s)"* ]] || fail "the floor line should name the active count, got '$OUT'"
[[ "$OUT" == *"Running now"* ]] || fail "the floor line should point at the canonical table spec, got '$OUT'"
ok "--tick fires the floor line past the hour with active work"

# --- 10. tick dedupes: one line per stale stretch, not one per poll -----------
OUT=$("$SCRIPT" --tick --session "$SID" --repo "$REPO")
[[ -z "$OUT" ]] || fail "--tick should dedupe on the recorded render, got a second line: '$OUT'"
ok "--tick emits one floor line per stale stretch, not one per poll"

# --- 11. A new render re-arms the floor: the marker clears, and the NEXT
#         stale stretch is reportable again. ---------------------------------
"$SCRIPT" --note-rendered --active 2 --session "$SID" --repo "$REPO" || fail "re-render should succeed"
[[ ! -f "$(marker_path)" ]] || \
  fail "--note-rendered should clear the dedupe marker"
OUT=$("$SCRIPT" --tick --session "$SID" --repo "$REPO")
[[ -z "$OUT" ]] || fail "--tick should be silent right after a re-render, got '$OUT'"
backdate 75
OUT=$("$SCRIPT" --tick --session "$SID" --repo "$REPO")
[[ "$OUT" == *"TABLE FLOOR"* ]] || fail "the next stale stretch should be reportable again, got '$OUT'"
ok "a re-render re-arms the floor for the following hour"

# --- 12. Idle rounds emit no hourly pulse. The record is an hour old; only the
#         active count differs from case 9, so this is that case's control. ----
"$SCRIPT" --note-rendered --active 0 --surface round-end --session "$SID" --repo "$REPO" \
  || fail "terminal board render should succeed"
backdate 120
OUT=$("$SCRIPT" --tick --session "$SID" --repo "$REPO"); RC=$?
[[ -z "$OUT" && "$RC" -eq 0 ]] || \
  fail "an idle thread must emit no hourly pulse, got rc=$RC out='$OUT'"
run_check; V="$CHECK_OUT"
[[ "$V" == "idle" && "$CHECK_RC" -eq 0 ]] || \
  fail "a two-hour-old record with active_pipelines=0 should read 'idle', got '$V'/$CHECK_RC"
ok "an idle thread (active_pipelines=0) emits no hourly pulse even two hours on"

# --- 13. An explicit --active outranks a stale recorded count ----------------
run_check --active 3; V="$CHECK_OUT"
[[ "$V" == "stale" && "$CHECK_RC" -eq 1 ]] || \
  fail "--active 3 against a 2h-old render should be 'stale'/1, got '$V'/$CHECK_RC"
ok "an explicit --active outranks the count recorded at the last render"

# --- 14. tick is silent with no record at all (a thread that never rendered
#         is not evidence of an active round) --------------------------------
NOREC_SID="tf-norecord-$$-$RANDOM"
OUT=$("$SCRIPT" --tick --session "$NOREC_SID" --repo "$REPO"); RC=$?
[[ -z "$OUT" && "$RC" -eq 0 ]] || fail "--tick with no record should be silent, got rc=$RC out='$OUT'"
ok "--tick is silent when no render was ever recorded"

# --- 15. Session scoping: two sessions in one repo keep independent clocks ----
OTHER_SID="tf-other-$$-$RANDOM"
"$SCRIPT" --note-rendered --active 1 --session "$OTHER_SID" --repo "$REPO" \
  || fail "second session render should succeed"
backdate 90 "$OTHER_SID"
OUT=$("$SCRIPT" --tick --session "$OTHER_SID" --repo "$REPO")
[[ "$OUT" == *"TABLE FLOOR"* ]] || fail "the second session's own stale clock should fire, got '$OUT'"
[[ "$OUT" == *"1 pipeline(s)"* ]] || fail "the second session should report its OWN count, got '$OUT'"
# The first session is still idle; the second firing must not have disturbed it.
OUT=$("$SCRIPT" --tick --session "$SID" --repo "$REPO")
[[ -z "$OUT" ]] || fail "one session's floor must not fire for another, got '$OUT'"
ok "two sessions in one repo keep independent board clocks"

# --- 16. --arm-command is a persistent Monitor loop, not a cron line ----------
ARM=$("$SCRIPT" --arm-command --session "$SID" --repo "$REPO")
[[ "$ARM" == *"--tick"* ]] || fail "--arm-command must carry the --tick sentinel, got '$ARM'"
[[ "$ARM" == "while true; do "* ]] || fail "--arm-command must be a Monitor loop, got '$ARM'"
[[ "$ARM" == *"$SCRIPT"* ]] || fail "--arm-command must embed the absolute script path, got '$ARM'"
[[ "$ARM" == *"--session '$SID'"* ]] || fail "--arm-command must embed the session id, got '$ARM'"
[[ "$ARM" == *"--repo '$REPO'"* ]] || \
  fail "--arm-command must embed the repo key — the tick runs from an arbitrary cwd, got '$ARM'"
[[ "$ARM" == *"sleep $POLL"* ]] || fail "--arm-command must sleep the derived poll interval, got '$ARM'"
ok "--arm-command emits a persistent Monitor loop carrying session and repo"

# --- 16b. The emitted command is SHELL TEXT, so every interpolated value must
#          be quoted. The session id is sanitised and the repo key is now
#          rejected unless it is a plausible owner/name (19b), which leaves the
#          SCRIPT PATH as the one interpolated value that can still legitimately
#          carry a space or worse — an install under "Application Support", a
#          worktree directory named after a branch. Prove the quoting by RUNNING
#          the generated tick from a directory whose name carries a `;`:
#          unquoted, it executes as a command separator. Substring assertions
#          alone cannot catch that. ------------------------------------------
# The payload is slash-free (a directory NAME, not a path) and the eval below
# runs with cwd = $TMP_DIR, so a `touch` that escapes lands at $TMP_DIR/pwned.
EVIL_DIR="$TMP_DIR/dir; touch pwned"
# A symlink, not a copy: the script resolves session-state.sh as its own
# sibling, and `pwd` keeps the logical (symlinked) path, so SCRIPT_PATH picks up
# the hostile directory name while every dependency still resolves.
ln -s "$(dirname "$SCRIPT")" "$EVIL_DIR" || fail "could not stage the hostile script dir"
EVIL_ARM=$("$EVIL_DIR/table-freshness.sh" --arm-command --session "$SID" --repo "$REPO")
# Strip the loop wrapper down to the single tick invocation and run it once.
EVIL_TICK=${EVIL_ARM#while true; do }
EVIL_TICK=${EVIL_TICK%%; sleep *}
( cd "$TMP_DIR" && eval "$EVIL_TICK" ) >/dev/null 2>&1
[[ ! -e "$TMP_DIR/pwned" ]] || \
  fail "--arm-command interpolated an unquoted script path — the injected command ran"
# Positive control: the same eval must actually have invoked the script, or the
# assertion above passes vacuously for a command that simply failed to run.
EVIL_STATUS=$(cd "$TMP_DIR" && eval "${EVIL_TICK/--tick/--status}" 2>/dev/null)
[[ "$(printf '%s' "$EVIL_STATUS" | jq -r '.repo')" == "$REPO" ]] || \
  fail "the generated command must run and pass its values through, got: $EVIL_STATUS"
ok "--arm-command shell-quotes every value it interpolates"

# --- 16c. One session watching TWO repos keeps two dedupe markers. Sharing one
#          would make each repo's tick overwrite the other's recorded timestamp,
#          so neither would ever match and BOTH would re-emit every poll. ------
REPO_B="org/table-freshness-b"
"$SCRIPT" --note-rendered --active 1 --session "$SID" --repo "$REPO" >/dev/null
"$SCRIPT" --note-rendered --active 1 --session "$SID" --repo "$REPO_B" >/dev/null
"$STATE_SH" --set ".repos[\"$REPO\"].table_render[\"$SID\"].last_rendered_at=$(iso_minutes_ago 90)" >/dev/null
"$STATE_SH" --set ".repos[\"$REPO_B\"].table_render[\"$SID\"].last_rendered_at=$(iso_minutes_ago 80)" >/dev/null
OUT_A=$("$SCRIPT" --tick --session "$SID" --repo "$REPO")
OUT_B=$("$SCRIPT" --tick --session "$SID" --repo "$REPO_B")
[[ "$OUT_A" == *"TABLE FLOOR"* && "$OUT_B" == *"TABLE FLOOR"* ]] || \
  fail "both repos should fire their own first floor line, got A='$OUT_A' B='$OUT_B'"
# The second poll of each must be silent. With a shared marker, repo B's write
# would have clobbered repo A's and this is where the repeater shows up.
OUT_A2=$("$SCRIPT" --tick --session "$SID" --repo "$REPO")
OUT_B2=$("$SCRIPT" --tick --session "$SID" --repo "$REPO_B")
[[ -z "$OUT_A2" && -z "$OUT_B2" ]] || \
  fail "each repo must dedupe independently, got A='$OUT_A2' B='$OUT_B2'"
"$SCRIPT" --clear --session "$SID" --repo "$REPO_B" || fail "clearing repo B should succeed"
ok "two repos watched by one session keep independent dedupe markers"

# --- 16d. Two keys that SANITISE to the same slug must still separate. This is
#          the case a readable-slug-only marker gets wrong: `/` squashes to `_`,
#          and `_` is itself allowed through, so `acme/widget` and `acme_widget`
#          collide back into one marker and the repeater returns for exactly the
#          pair the slug was meant to split. -------------------------------------
SLUG_A="acme/widget"
SLUG_B="acme_widget"
[[ "${SLUG_A//[^[:alnum:]_.-]/_}" == "${SLUG_B//[^[:alnum:]_.-]/_}" ]] || \
  fail "test setup wrong: these keys must share a sanitised slug"
[[ "$(marker_path "$SLUG_A")" != "$(marker_path "$SLUG_B")" ]] || \
  fail "slug-colliding repo keys must still get distinct marker paths"
"$SCRIPT" --note-rendered --active 1 --session "$SID" --repo "$SLUG_A" >/dev/null
"$SCRIPT" --note-rendered --active 1 --session "$SID" --repo "$SLUG_B" >/dev/null
"$STATE_SH" --set ".repos[\"$SLUG_A\"].table_render[\"$SID\"].last_rendered_at=$(iso_minutes_ago 90)" >/dev/null
"$STATE_SH" --set ".repos[\"$SLUG_B\"].table_render[\"$SID\"].last_rendered_at=$(iso_minutes_ago 80)" >/dev/null
[[ -n "$("$SCRIPT" --tick --session "$SID" --repo "$SLUG_A")" ]] || fail "slug-A should fire once"
[[ -n "$("$SCRIPT" --tick --session "$SID" --repo "$SLUG_B")" ]] || fail "slug-B should fire once"
[[ -z "$("$SCRIPT" --tick --session "$SID" --repo "$SLUG_A")" ]] || \
  fail "slug-colliding keys must dedupe independently — slug-A repeated"
[[ -z "$("$SCRIPT" --tick --session "$SID" --repo "$SLUG_B")" ]] || \
  fail "slug-colliding keys must dedupe independently — slug-B repeated"
"$SCRIPT" --clear --session "$SID" --repo "$SLUG_A" || fail "clearing slug-A should succeed"
"$SCRIPT" --clear --session "$SID" --repo "$SLUG_B" || fail "clearing slug-B should succeed"
ok "repo keys that sanitise to the same slug still get distinct markers"

# --- 17. --clear drops the record and the marker ------------------------------
backdate 90
"$SCRIPT" --tick --session "$SID" --repo "$REPO" >/dev/null
"$SCRIPT" --clear --session "$SID" --repo "$REPO" || fail "--clear should succeed"
[[ ! -f "$(marker_path)" ]] || \
  fail "--clear should remove the dedupe marker"
run_check; V="$CHECK_OUT"
[[ "$V" == "unrecorded" ]] || fail "--clear should drop the record, got '$V'"
ok "--clear drops the render record and the dedupe marker"

# --- 18. Floor override is honored, and an invalid one warns and falls back --
OVERRIDDEN=$(CLAUDE_TABLE_FLOOR_S=1800 "$SCRIPT" --floor-seconds)
[[ "$OVERRIDDEN" == "1800" ]] || fail "CLAUDE_TABLE_FLOOR_S=1800 should be honored, got '$OVERRIDDEN'"
OVR_STATUS=$(CLAUDE_TABLE_FLOOR_S=1800 "$SCRIPT" --status --session "$SID" --repo "$REPO")
OVR_TRIP=$(printf '%s' "$OVR_STATUS" | jq -r '.trip_s')
OVR_POLL=$(printf '%s' "$OVR_STATUS" | jq -r '.poll_s')
(( OVR_TRIP + OVR_POLL <= 1800 )) || \
  fail "the derived invariant must hold under an override too (trip $OVR_TRIP + poll $OVR_POLL > 1800)"
BAD_ERR="$(CLAUDE_TABLE_FLOOR_S=notanumber "$SCRIPT" --floor-seconds 2>&1 >/dev/null)"
BAD_OUT="$(CLAUDE_TABLE_FLOOR_S=notanumber "$SCRIPT" --floor-seconds 2>/dev/null)"
[[ "$BAD_OUT" == "3600" ]] || fail "an invalid override should fall back to 3600, got '$BAD_OUT'"
[[ "$BAD_ERR" == *"ignoring invalid"* ]] || fail "an invalid override should warn on stderr, got '$BAD_ERR'"
TOO_SMALL="$(CLAUDE_TABLE_FLOOR_S=60 "$SCRIPT" --floor-seconds 2>/dev/null)"
[[ "$TOO_SMALL" == "3600" ]] || \
  fail "an override at or below the margin should fall back to 3600, got '$TOO_SMALL'"
ok "the floor override is honored, and an invalid one warns and falls back"

# --- 19. Usage errors ---------------------------------------------------------
"$SCRIPT" --note-rendered --session "$SID" --repo "$REPO" >/dev/null 2>&1
[[ $? -eq 2 ]] || fail "--note-rendered without --active should exit 2"
"$SCRIPT" --check --active -1 --session "$SID" --repo "$REPO" >/dev/null 2>&1
[[ $? -eq 2 ]] || fail "a negative --active should exit 2"
"$SCRIPT" --check --tick --session "$SID" --repo "$REPO" >/dev/null 2>&1
[[ $? -eq 2 ]] || fail "two modes should exit 2"
"$SCRIPT" --bogus >/dev/null 2>&1
[[ $? -eq 2 ]] || fail "an unknown flag should exit 2"
"$SCRIPT" >/dev/null 2>&1
[[ $? -eq 2 ]] || fail "no mode should exit 2"
ok "usage errors exit 2"

# --- 19a. Zero-padded counts are normalised, not passed through ---------------
#          A padded count passes ^[0-9]+$ AND is stored correctly by jq
#          (--argjson 010 records 10). That is what makes it dangerous: the
#          record is right and the shell is wrong, so they disagree silently.
#          Assert on the two places the shell reads the count, because the
#          stored value alone cannot show the bug.

# (a) "010" is octal EIGHT to `(( ))` and to `printf %d`, while the record says
#     ten — the floor line would quietly report a count the record contradicts.
#     Planted straight into the record: routing it through --active would prove
#     nothing, because jq normalises "010" to 10 on the way in whether or not
#     this script does, so only a padded value already ON DISK reaches the
#     shell's octal reading.
"$SCRIPT" --note-rendered --active 10 --session "$SID" --repo "$REPO" >/dev/null \
  || fail "setup: --note-rendered should succeed"
"$STATE_SH" --set ".repos[\"$REPO\"].table_render[\"$SID\"].active_pipelines=\"010\"" \
  >/dev/null || fail "could not plant a zero-padded recorded count"
backdate 90
TICK_TEN="$("$SCRIPT" --tick --session "$SID" --repo "$REPO" 2>&1)"
[[ "$TICK_TEN" == *"10 pipeline(s)"* ]] || \
  fail "the floor line must report ten, not printf's octal eight, got: $TICK_TEN"
"$SCRIPT" --clear --session "$SID" --repo "$REPO" >/dev/null 2>&1

# (b) "08"/"09" are a HARD arithmetic error, and an erroring (( )) returns
#     non-zero — which in --tick lands on `(( ACTIVE_RECORDED > 0 )) || exit 0`
#     and silently disarms the floor. A missed hourly table, not just noise.
#     Planted directly into the record: it is shared with /board (#1581) and is
#     a hand-editable JSON file, so it can arrive without passing --active.
"$SCRIPT" --note-rendered --active 8 --session "$SID" --repo "$REPO" >/dev/null \
  || fail "setup: --note-rendered should succeed"
"$STATE_SH" --set ".repos[\"$REPO\"].table_render[\"$SID\"].active_pipelines=\"08\"" \
  >/dev/null || fail "could not plant a zero-padded recorded count"
backdate 90
TICK_PADDED="$("$SCRIPT" --tick --session "$SID" --repo "$REPO" 2>&1)"
[[ "$TICK_PADDED" == *"TABLE FLOOR"* ]] || \
  fail "a padded recorded count silently disarmed the floor, got: '$TICK_PADDED'"
[[ "$TICK_PADDED" == *"8 pipeline(s)"* ]] || \
  fail "the floor line must report 8, not printf's octal reading, got: $TICK_PADDED"
[[ "$TICK_PADDED" != *"value too great"* && "$TICK_PADDED" != *"invalid octal"* ]] || \
  fail "a padded recorded count leaked a shell octal error: $TICK_PADDED"
"$SCRIPT" --clear --session "$SID" --repo "$REPO" >/dev/null 2>&1

# (c) The same padding must not upset --check's own arithmetic.
"$SCRIPT" --note-rendered --active 2 --session "$SID" --repo "$REPO" >/dev/null
CHECK_ERR="$("$SCRIPT" --check --active 09 --session "$SID" --repo "$REPO" 2>&1 >/dev/null)"
[[ -z "$CHECK_ERR" ]] || fail "--check --active 09 should be silent on stderr, got: $CHECK_ERR"
ok "zero-padded counts are normalised at every entry point (arg and record)"

# --- 19b. A repo key carrying jq syntax is REJECTED, never interpolated -------
#          REPO_KEY lands inside .repos["<key>"] in a jq path string. A `"` or
#          `]` closes that string early and the remainder parses as jq: the
#          write is redirected to another key, or the path stops parsing and
#          every freshness call fails. Rejecting (never squashing) is what keeps
#          the `/` in owner/name, so the path /board reads stays byte-identical.
STATE_BEFORE="$(jq -S -c '.repos' "$HOME/.claude/session-state.json")"
for BAD_REPO in 'org/repo"]|.x' 'org/repo"' 'org/re]po' 'org/re\po' 'org/re po'; do
  "$SCRIPT" --status --session "$SID" --repo "$BAD_REPO" >/dev/null 2>&1
  [[ $? -eq 2 ]] || fail "repo key '$BAD_REPO' should exit 2"
  "$SCRIPT" --note-rendered --active 1 --session "$SID" --repo "$BAD_REPO" >/dev/null 2>&1
  [[ $? -eq 2 ]] || fail "--note-rendered with repo key '$BAD_REPO' should exit 2"
done
# The rejection has to be what stopped the write — prove no key was created.
STATE_AFTER="$(jq -S -c '.repos' "$HOME/.claude/session-state.json")"
[[ "$STATE_BEFORE" == "$STATE_AFTER" ]] || \
  fail "a rejected repo key still altered state: $STATE_BEFORE -> $STATE_AFTER"

# Positive control: the assertions above pass vacuously if EVERY --repo is
# rejected. A legitimate owner/name — slash, dot, dash, underscore — must work.
"$SCRIPT" --note-rendered --active 1 --session "$SID" --repo 'my-org/my_repo.js' \
  >/dev/null || fail "a legitimate owner/name must still be accepted"
[[ "$(jq -r '.repos["my-org/my_repo.js"].table_render["'"$SID"'"].active_pipelines' \
  "$HOME/.claude/session-state.json")" == "1" ]] || \
  fail "a legitimate owner/name must write under its own unmangled key"
ok "repo keys carrying jq syntax are rejected; legitimate owner/name still works"

# --- 19c. A mixed-case --repo scopes to the LOWERCASE key --------------------
#          The validator accepts mixed case because repo names legitimately have
#          it; the scope key must not keep it. session-state.sh, handoff-state.sh
#          and polling-state-gate.sh all lowercase (issue #704), and /board
#          (#1581) reads this same record — a `.repos["Org/Repo"]` write lands
#          where nothing looks, and the armed tick polls a record no render
#          writes.
"$SCRIPT" --note-rendered --active 3 --surface cased \
  --session "$SID" --repo 'MixedOrg/MixedRepo' >/dev/null \
  || fail "a mixed-case repo key should be accepted"
[[ "$(jq -r '.repos["mixedorg/mixedrepo"].table_render["'"$SID"'"].active_pipelines' \
  "$HOME/.claude/session-state.json")" == "3" ]] || \
  fail "a mixed-case --repo must write under the lowercase scope key"
[[ "$(jq -r '.repos | has("MixedOrg/MixedRepo")' "$HOME/.claude/session-state.json")" == "false" ]] || \
  fail "a mixed-case scope key was created — it splits the scope from every other consumer"
# Round-trip: reading back with the same mixed-case spelling must find it.
CASED_STATUS="$("$SCRIPT" --status --session "$SID" --repo 'MixedOrg/MixedRepo')"
[[ "$(printf '%s' "$CASED_STATUS" | jq -r '.active_pipelines')" == "3" ]] || \
  fail "a mixed-case --repo must read back the record it just wrote, got: $CASED_STATUS"
ok "a mixed-case --repo scopes to the lowercase key and round-trips"

# --- 19d. The record is read WHOLE, in one read, not field by field ----------
#          Separate --get calls are separate processes reading the file afresh,
#          so they can straddle a concurrent --note-rendered and pair an old
#          timestamp with a new count — the exact two values that decide stale
#          vs idle. --note-rendered already writes the record as one atomic
#          --set; reading it whole is the other half of that guarantee.
#          Behavioural half: every field --status reports comes from that read.
"$SCRIPT" --note-rendered --active 5 --surface whole-read \
  --session "$SID" --repo "$REPO" >/dev/null || fail "setup: --note-rendered should succeed"
WHOLE="$("$SCRIPT" --status --session "$SID" --repo "$REPO")"
[[ "$(printf '%s' "$WHOLE" | jq -r '.active_pipelines')" == "5" ]] || \
  fail "--status lost active_pipelines through the single-read path: $WHOLE"
[[ "$(printf '%s' "$WHOLE" | jq -r '.surface')" == "whole-read" ]] || \
  fail "--status lost surface through the single-read path: $WHOLE"
[[ "$(printf '%s' "$WHOLE" | jq -r '.last_rendered_at')" =~ ^[0-9]{4}- ]] || \
  fail "--status lost last_rendered_at through the single-read path: $WHOLE"
# Structural half: no per-field state_get survives. One of those reappearing is
# how the race comes back, and it would not fail any behavioural assertion.
grep -qE "state_get '\.(last_rendered_at|active_pipelines|surface)'" "$SCRIPT" && \
  fail "a per-field state_get reintroduces the straddled-read race — read the record whole"
ok "the render record is read whole in one call, and --status reports every field from it"

# --- 19e. A FUTURE-dated render fails closed, it does not suppress the floor --
#          `now - rendered` goes negative, and every comparison is `age >= TRIP`,
#          so a negative age reads as maximally fresh: --check says fresh and
#          --tick stays silent until the wall clock catches up, which for a
#          skewed clock or an edited record could be hours. The floor failing
#          silent is the one direction it must never fail.
"$SCRIPT" --note-rendered --active 2 --session "$SID" --repo "$REPO" >/dev/null
FUTURE="$(TZ=UTC date -j -v+120M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d '120 minutes' +%Y-%m-%dT%H:%M:%SZ)"
"$STATE_SH" --set ".repos[\"$REPO\"].table_render[\"$SID\"].last_rendered_at=$FUTURE" \
  >/dev/null || fail "could not plant a future-dated render"
run_check --active 2; V="$CHECK_OUT"
[[ "$V" == "stale" && "$CHECK_RC" -eq 1 ]] || \
  fail "a future-dated render must fail closed to 'stale'/1, got '$V'/$CHECK_RC"
TICK_FUTURE="$("$SCRIPT" --tick --session "$SID" --repo "$REPO" 2>/dev/null)"
[[ "$TICK_FUTURE" == *"TABLE FLOOR"* ]] || \
  fail "a future-dated render silently suppressed the tick, got: '$TICK_FUTURE'"
FUTURE_ERR="$("$SCRIPT" --check --active 2 --session "$SID" --repo "$REPO" 2>&1 >/dev/null)"
[[ "$FUTURE_ERR" == *"FUTURE"* ]] || \
  fail "clock skew must be named on stderr so it is diagnosable, got: '$FUTURE_ERR'"
"$SCRIPT" --clear --session "$SID" --repo "$REPO" >/dev/null 2>&1
ok "a future-dated render fails closed and names the skew, instead of muting the floor"

# --- 19f. An EXPLICITLY empty --session / --repo is a usage error ------------
#          Omitting either legitimately defaults. Passing an empty one means the
#          caller's own variable was empty — a shell variable that did not
#          survive a compaction or a fresh process — and silently substituting
#          `default` or the cwd repo writes the render to one record while the
#          armed watch polls another. Both calls succeed, so the mismatch is
#          invisible and the floor fires forever, or never.
for MODE_ARGS in "--status" "--check" "--note-rendered --active 1"; do
  # shellcheck disable=SC2086
  "$SCRIPT" $MODE_ARGS --session "" --repo "$REPO" >/dev/null 2>&1
  [[ $? -eq 2 ]] || fail "$MODE_ARGS with an empty --session should exit 2"
  # shellcheck disable=SC2086
  "$SCRIPT" $MODE_ARGS --session "$SID" --repo "" >/dev/null 2>&1
  [[ $? -eq 2 ]] || fail "$MODE_ARGS with an empty --repo should exit 2"
done
# Positive control: OMITTING them still defaults, so this is a guard on the
# explicit-empty case only and not a blanket requirement.
"$SCRIPT" --status >/dev/null 2>&1
[[ $? -ne 2 ]] || fail "omitting --session/--repo must still default, not error"
ok "an explicitly empty --session or --repo is rejected; omitting them still defaults"

# --- 19g. Two session ids that SANITISE alike keep separate clocks ------------
#          Exactly the collision the repo component already solves with a
#          checksum: `${id//[^[:alnum:]_.-]/_}` maps `/` to `_` while letting `_`
#          through, so `a/b` and `a_b` squashed to one key and each render reset
#          the other's hour. The state path now uses the RAW id (a `/` is legal
#          in a jq string key) and the marker uses slug+checksum.
S_A="collide/one"
S_B="collide_one"
[[ "${S_A//[^[:alnum:]_.-]/_}" == "${S_B//[^[:alnum:]_.-]/_}" ]] || \
  fail "test setup wrong: these session ids must share a sanitised slug"
"$SCRIPT" --note-rendered --active 4 --session "$S_A" --repo "$REPO" >/dev/null \
  || fail "session '$S_A' should be accepted"
"$SCRIPT" --note-rendered --active 9 --session "$S_B" --repo "$REPO" >/dev/null \
  || fail "session '$S_B' should be accepted"
A_COUNT="$("$SCRIPT" --status --session "$S_A" --repo "$REPO" | jq -r '.active_pipelines')"
B_COUNT="$("$SCRIPT" --status --session "$S_B" --repo "$REPO" | jq -r '.active_pipelines')"
[[ "$A_COUNT" == "4" && "$B_COUNT" == "9" ]] || \
  fail "colliding session ids shared one clock: '$S_A'=$A_COUNT '$S_B'=$B_COUNT (want 4 and 9)"
[[ "$(marker_path "$REPO" "$S_A")" != "$(marker_path "$REPO" "$S_B")" ]] || \
  fail "colliding session ids share one dedupe marker"
# An ordinary UUID-shaped id must be UNCHANGED as a state key, or this fix would
# have moved every existing record — including the ones /board (#1581) reads.
UUIDISH="0b9c1d2e-3f40-5a61-8b72-9c0d1e2f3a4b"
"$SCRIPT" --note-rendered --active 1 --session "$UUIDISH" --repo "$REPO" >/dev/null \
  || fail "a UUID-shaped session id should be accepted"
[[ "$(jq -r ".repos[\"$REPO\"].table_render | has(\"$UUIDISH\")" \
  "$HOME/.claude/session-state.json")" == "true" ]] || \
  fail "a UUID-shaped session id must key the record verbatim, not a mangled form"
ok "session ids that sanitise alike keep separate clocks; ordinary ids key verbatim"

# --- 20. A state write it cannot perform is REPORTED, never swallowed --------
#         Both writing modes: --clear that silently fails to clear leaves a stale
#         record with the marker gone, which is exactly the combination that
#         re-fires the floor on a board nobody is watching.
chmod a-w "$HOME/.claude" 2>/dev/null
rm -f "$HOME/.claude/session-state.json" 2>/dev/null
WRITE_ERR="$("$SCRIPT" --note-rendered --active 1 --session "wr-$SID" --repo "$REPO" 2>&1 >/dev/null)"
WRITE_RC=$?
CLEAR_ERR="$("$SCRIPT" --clear --session "wr-$SID" --repo "$REPO" 2>&1 >/dev/null)"
CLEAR_RC=$?
chmod u+w "$HOME/.claude" 2>/dev/null
if [[ "$WRITE_RC" -eq 0 ]]; then
  # Running as root (CI containers sometimes do) defeats the permission bit;
  # skip rather than assert a guarantee the filesystem is not enforcing.
  ok "state-write failure path skipped (writes succeeded despite a read-only dir)"
else
  [[ "$WRITE_RC" -eq 5 ]] || fail "an unwritable state file should exit 5, got $WRITE_RC"
  [[ "$WRITE_ERR" == *"not updated"* ]] || \
    fail "an unwritable state file must be reported on stderr, got '$WRITE_ERR'"
  [[ "$CLEAR_RC" -eq 5 ]] || \
    fail "--clear must propagate a failed record deletion, got $CLEAR_RC"
  [[ "$CLEAR_ERR" == *"stale render record left in place"* ]] || \
    fail "a --clear that could not clear must say so on stderr, got '$CLEAR_ERR'"
  ok "a state write it cannot perform exits 5 and says so on stderr (--note-rendered and --clear)"
fi

# --- 21. The mechanism is specified once, against the canonical table spec ----
SPEC="$REPO_ROOT/.claude/reference/time-estimates.md"
grep -q 'Table freshness' "$SPEC" || \
  fail "time-estimates.md must define the freshness floor alongside the table spec"
grep -q 'table-freshness.sh' "$SPEC" || \
  fail "time-estimates.md must name the helper that owns the floor"
grep -q 'bgwork-ceiling\|silence ceiling' "$SPEC" || \
  fail "the spec must say the message ceiling and the table floor are complementary bounds (issue #1580 Notes)"
SCHEMA="$REPO_ROOT/.claude/reference/session-state-schema.json"
jq -e '.._table_render_comment? // empty' "$SCHEMA" >/dev/null 2>&1 || \
  grep -q '_table_render_comment' "$SCHEMA" || \
  fail "session-state-schema.json must document the table_render field"
grep -q 'Teardown is by data' "$SPEC" || \
  fail "the spec must state that teardown disarms by data, not by stopping the watch"
# Each wiring site must name the helper AND name its repo — an omitted --repo
# resolves from the cwd and can write a record the armed watch never polls.
for SKILL_PATH in subagent leave-by pause end; do
  SKILL_FILE="$REPO_ROOT/.claude/skills/$SKILL_PATH/SKILL.md"
  grep -q 'table-freshness' "$SKILL_FILE" || \
    fail "/$SKILL_PATH must wire the freshness clock (render, resolve, or teardown)"
  grep -qE 'REPO_KEY|--repo' "$SKILL_FILE" || \
    fail "/$SKILL_PATH calls table-freshness.sh without naming a repo"
done

# The list above was hand-written once and immediately drifted: the spec's
# teardown sentence named /end while the loop checked only three skills, so /end
# shipped with no teardown at all and nothing failed (caught in review on PR
# #1589). Derive the requirement from the spec instead of trusting the list —
# every flow the teardown sentence names must actually be wired.
TEARDOWN_LINE="$(grep -A2 'Teardown is by data' "$SPEC" | tr '\n' ' ')"
[[ -n "$TEARDOWN_LINE" ]] || fail "could not read the spec's teardown sentence"
NAMED_FLOWS="$(printf '%s' "$TEARDOWN_LINE" | grep -oE '`/[a-z][a-z-]*`' | tr -d '`/' | sort -u)"
[[ -n "$NAMED_FLOWS" ]] || \
  fail "the teardown sentence names no flows — it must name the ones that disarm the floor"
while read -r FLOW; do
  [[ -n "$FLOW" ]] || continue
  # Only flows that exist as skills are checkable; the spec also names prose
  # phrases like "the round's own completion", which have no SKILL.md.
  [[ -f "$REPO_ROOT/.claude/skills/$FLOW/SKILL.md" ]] || continue
  grep -q 'table-freshness' "$REPO_ROOT/.claude/skills/$FLOW/SKILL.md" || \
    fail "the spec's teardown sentence names /$FLOW, but /$FLOW never calls table-freshness.sh"
done <<< "$NAMED_FLOWS"
ok "the floor is specified once and every flow the spec names for teardown is wired"

# --- 22. The wiring has to actually work, not merely be present --------------
#         Four ways a site can name the helper and still guarantee nothing —
#         all four shipped in this PR's first two pushes and were caught in
#         review. "grep finds table-freshness" is not the same as "the clock
#         gets written".
SUBAGENT="$REPO_ROOT/.claude/skills/subagent/SKILL.md"
PAUSE="$REPO_ROOT/.claude/skills/pause/SKILL.md"

# (a) A count that is USED but never ASSIGNED. table-freshness.sh rejects an
#     empty --active, so the clock is never written and the armed watch polls a
#     record that does not exist — silent forever, while looking armed.
grep -q '\$ACTIVE_COUNT' "$SUBAGENT" || \
  fail "/subagent should pass a count to --active"
grep -qE '^ *ACTIVE_COUNT=' "$SUBAGENT" || \
  fail "/subagent uses \$ACTIVE_COUNT but never assigns it — the clock is never written"

# (b) That failure must not be swallowed. It is invisible from outside: the arm
#     still succeeds, so the thread believes the guarantee is live.
#     Matched on the invocation's own trailing `--surface <label> || true`, not
#     on `--note-rendered` anywhere in the line: the prose below the snippet
#     names both the flag and `|| true` while telling you not to combine them,
#     and a looser pattern flags that sentence instead of any real call.
grep -qE -- '--surface +[a-z-]+ *\|\| *true' "$SUBAGENT" && \
  fail "/subagent swallows a failed --note-rendered with '|| true' — report it instead"

# (c) The heartbeat record must be GATED on a table actually being emitted. An
#     ungated call lets a permitted one-liner restamp last_rendered_at, which
#     restarts the hour and hides an already-stale board.
grep -q 'TABLE_EMITTED' "$SUBAGENT" || \
  fail "/subagent records a render without gating on a table having been emitted"

# (b2) The arm must be gated on the record having been WRITTEN, not merely on a
#      non-empty repo key. Guarding the call but not the arm leaves every other
#      failure path — unset count, non-zero --note-rendered — arming a watch over
#      a record that does not exist: silent forever, and looking armed. This is
#      the gap the first version of guard (a) left behind.
grep -q 'CLOCK_RECORDED' "$SUBAGENT" || \
  fail "/subagent arms the floor without gating on the clock actually being recorded"

# (d) Round completion is a teardown site the spec names, and it needs a real
#     call — prose alone is what let (a)-(c) ship.
grep -qE '\-\-note-rendered --active 0' "$SUBAGENT" || \
  fail "/subagent never records the terminal board (--active 0) at round end"

# (e) /pause must PRE-resolve the helper in Step 0 like its siblings. Resolving
#     it inline at the call site means a missing helper produces no DEGRADED
#     line, and the disarm is simply skipped.
grep -qE '^TABLE_FRESHNESS_SH=\$\(resolve_script table-freshness\.sh\)' "$PAUSE" || \
  fail "/pause must resolve table-freshness.sh in Step 0, not inline at the call site"
ok "each wiring site assigns its count, gates its render, reports failures, and tears down"

echo
echo "All table-freshness.sh tests passed."
