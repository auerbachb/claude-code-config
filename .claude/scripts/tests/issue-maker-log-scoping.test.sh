#!/usr/bin/env bash
# issue-maker-log-scoping.test.sh — offline regression tests for issue #1369:
# the /issue-maker session log colliding across concurrent conversations.
#
# THE INCIDENT (2026-08-26, ~4:20–4:26 PM ET)
#   SKILL.md derived the log path from `${CLAUDE_SESSION_ID:-default}`.
#   CLAUDE_SESSION_ID resolves EMPTY inside Bash tool subshells, so a
#   claude-code-config capture session and a concurrent still-point session both
#   landed on ~/.claude/handoffs/issue-maker-default-log.json. Three distinct
#   corruptions followed:
#     (a) `target_repo` flipped under the other session;
#     (b) the other session's issue surfaced inside this session's batch;
#     (c) a blanket `select(.status == "open")` offer stamp overwrote the
#         foreign row's `chip_task_id`.
#
# WHAT THIS SUITE ASSERTS
#   Every test runs the REAL production code, never a paraphrase:
#     - scripts/resolve-log.sh is executed directly;
#     - the SKILL.md bash is EXTRACTED by test-anchor via lib/skill-bash.sh, so
#       the skill and the test cannot drift apart.
#
#   Each corruption gets a paired NEGATIVE CONTROL that replays the pre-fix
#   behaviour and asserts it DOES corrupt. Without those, a scoping test passes
#   vacuously the moment the selector stops matching anything at all.
#
# Offline: no gh, no network, no git. Temp HOME throughout, so the real
# ~/.claude/handoffs is never touched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="${SCRIPT_DIR}/../../skills/issue-maker"
SKILL_MD="${SKILL_DIR}/SKILL.md"
RESOLVE_LOG="${SKILL_DIR}/scripts/resolve-log.sh"
SET_LOG="${SKILL_DIR}/scripts/set-log.sh"

# shellcheck source=.claude/scripts/tests/lib/skill-bash.sh
. "${SCRIPT_DIR}/lib/skill-bash.sh"

for required in "$SKILL_MD" "$RESOLVE_LOG" "$SET_LOG"; do
  if [[ ! -e "$required" ]]; then
    echo "FAIL: required file not found: $required" >&2; exit 1
  fi
done
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required by this suite" >&2; exit 1
fi

PASS=0; FAIL=0
ok()   { PASS=$(( PASS+1 )); echo "ok   — $1"; }
fail() { FAIL=$(( FAIL+1 )); echo "FAIL — $1"; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------------------------------------------------------------------------
# Extract the four production bash blocks up front. A missing or ambiguous
# anchor is a hard failure: a suite that silently ran zero lines of skill bash
# would stay green forever.
# ---------------------------------------------------------------------------
BLOCK_RESOLVE="$(extract_skill_bash "$SKILL_MD" issue-maker-step1-resolve-log)" || exit 1
BLOCK_HELPER="$(extract_skill_bash "$SKILL_MD" issue-maker-log-write-helper)"   || exit 1
BLOCK_STAMP="$(extract_skill_bash "$SKILL_MD" issue-maker-step9c-offer-stamp)"  || exit 1
BLOCK_RETARGET="$(extract_skill_bash "$SKILL_MD" issue-maker-step1-retarget-guard)" || exit 1
ok "all four SKILL.md test-anchors extract non-empty bash"

# make_home — a temp HOME with the issue-maker skill "installed" where the
# SKILL.md resolution loop looks for it.
make_home() {
  local d="$TMP_DIR/home-$1"
  mkdir -p "$d/.claude/handoffs" "$d/.claude/skills/issue-maker/scripts"
  cp "$RESOLVE_LOG" "$SET_LOG" "$d/.claude/skills/issue-maker/scripts/"
  chmod +x "$d/.claude/skills/issue-maker/scripts/"*.sh
  printf '%s' "$d"
}

# run_block — execute production bash with the harness environment the skill
# sees. CLAUDE_SESSION_ID is deliberately unset: that IS the precondition of
# the incident.
run_block() {
  local home="$1" conv="$2" body="$3"
  local f="$TMP_DIR/block-$$-$RANDOM.sh"
  printf '%s\n' "$body" > "$f"
  ( unset CLAUDE_SESSION_ID
    export HOME="$home" ISSUE_MAKER_CONV_ID="$conv"
    bash "$f" )
}

seed_log() {   # seed_log <path> <target_repo> <json-issues-array>
  jq -n --arg repo "$2" --argjson issues "$3" \
    '{schema_version:"1", session_id:"seeded", target_repo:$repo,
      mode:"default", created_at:"2026-08-26T20:00:00Z",
      last_updated_at:"2026-08-26T20:00:00Z", issues:$issues}' > "$1"
}

issue_row() { # issue_row <number> <repo> <chip_task_id-or-null> [status]
  jq -nc --argjson n "$1" --arg repo "$2" --arg chip "$3" --arg st "${4:-open}" \
    '{number:$n, title:"seeded #\($n)",
      url:"https://github.com/\($repo)/issues/\($n)",
      labels:[], created_at:"2026-08-26T20:00:00Z", status:$st,
      chip_task_id:(if $chip == "null" then null else $chip end)}'
}

# =============================================================================
# TEST A — the log key is unique per conversation with CLAUDE_SESSION_ID unset
# =============================================================================
H_A="$(make_home a)"

PATH_S1="$(run_block "$H_A" "claude=1001|start=Wed Aug 26 16:20:00 2026" "$BLOCK_RESOLVE"$'\necho "$LOG"' 2>/dev/null | tail -n 1)"
PATH_S2="$(run_block "$H_A" "claude=2002|start=Wed Aug 26 16:21:00 2026" "$BLOCK_RESOLVE"$'\necho "$LOG"' 2>/dev/null | tail -n 1)"

if [[ -n "$PATH_S1" && -n "$PATH_S2" && "$PATH_S1" != "$PATH_S2" ]]; then
  ok "A1: two concurrent conversations resolve DISTINCT logs (no shared 'default')"
else
  fail "A1: concurrent conversations shared a log (s1='$PATH_S1' s2='$PATH_S2')"
fi

case "$PATH_S1" in
  */issue-maker-default-log.json) fail "A2: fallback still resolves the shared 'default' log" ;;
  */issue-maker-*-log.json)       ok   "A2: fallback key is not 'default' and keeps the issue-maker-*-log.json glob shape" ;;
  *)                              fail "A2: unexpected log path shape: $PATH_S1" ;;
esac

# Stability is what makes compaction recovery work: same conversation, later
# invocation, different cwd and shell depth -> same file.
PATH_S1_AGAIN="$( cd / && run_block "$H_A" "claude=1001|start=Wed Aug 26 16:20:00 2026" "$BLOCK_RESOLVE"$'\necho "$LOG"' 2>/dev/null | tail -n 1 )"
if [[ "$PATH_S1" == "$PATH_S1_AGAIN" ]]; then
  ok "A3: the same conversation re-resolves the SAME log across cwd drift (compaction recovery)"
else
  fail "A3: log path moved within one conversation ('$PATH_S1' -> '$PATH_S1_AGAIN')"
fi

STDERR_A="$(run_block "$H_A" "claude=3003|start=T3" "$BLOCK_RESOLVE" 2>&1 >/dev/null)"
if printf '%s' "$STDERR_A" | grep -q 'CLAUDE_SESSION_ID is unset'; then
  ok "A4: the derived-key fallback warns on stderr — it never happens silently"
else
  fail "A4: no fallback warning emitted (stderr: $STDERR_A)"
fi

# Collision backstop: a log that records a different session_id must be called
# out rather than written into.
seed_log "$H_A/.claude/handoffs/issue-maker-fallback-collide-log.json" "owner/other" "[]"
STDERR_COLLIDE="$(HOME="$H_A" CLAUDE_SESSION_ID="fallback-collide" \
  "$H_A/.claude/skills/issue-maker/scripts/resolve-log.sh" 2>&1 >/dev/null)"
if printf '%s' "$STDERR_COLLIDE" | grep -q "records session_id 'seeded'"; then
  ok "A5: collision backstop warns when the resolved log names another session"
else
  fail "A5: collision backstop silent (stderr: $STDERR_COLLIDE)"
fi

# NEGATIVE CONTROL — the pre-fix expression really did collide, so A1 is not
# passing on a technicality.
OLD_S1="$( ( unset CLAUDE_SESSION_ID; echo "issue-maker-${CLAUDE_SESSION_ID:-default}-log.json" ) )"
OLD_S2="$( ( unset CLAUDE_SESSION_ID; echo "issue-maker-${CLAUDE_SESSION_ID:-default}-log.json" ) )"
if [[ "$OLD_S1" == "$OLD_S2" && "$OLD_S1" == "issue-maker-default-log.json" ]]; then
  ok "A6 (negative control): the pre-fix \${CLAUDE_SESSION_ID:-default} expression DOES collide"
else
  fail "A6 (negative control): pre-fix expression did not reproduce the collision"
fi

# =============================================================================
# TEST B — the offer stamp cannot reach another repo's row
#          (reproduces corruption (c): issue #684's chip_task_id overwritten)
# =============================================================================
H_B="$(make_home b)"
LOG_B="$H_B/.claude/handoffs/issue-maker-batch-log.json"
MINE_ROW="$(issue_row 1370 auerbachb/claude-code-config null)"
FOREIGN_ROW="$(issue_row 684 auerbachb/still-point "offer-FOREIGN-DO-NOT-TOUCH")"
seed_log "$LOG_B" "auerbachb/claude-code-config" "[$MINE_ROW,$FOREIGN_ROW]"
FOREIGN_BEFORE="$(jq -S -c '.issues[] | select(.number == 684)' "$LOG_B")"

run_block "$H_B" "claude=1001|start=T1" \
"LOG='$LOG_B'
REPO='auerbachb/claude-code-config'
$BLOCK_HELPER
$BLOCK_STAMP" >/dev/null 2>&1
STAMP_RC=$?

FOREIGN_AFTER="$(jq -S -c '.issues[] | select(.number == 684)' "$LOG_B")"
MINE_AFTER="$(jq -r '.issues[] | select(.number == 1370) | .chip_task_id' "$LOG_B")"

if [[ $STAMP_RC -eq 0 ]]; then
  ok "B0: the extracted Step 9c offer stamp runs clean"
else
  fail "B0: extracted offer stamp exited $STAMP_RC"
fi
if [[ "$FOREIGN_BEFORE" == "$FOREIGN_AFTER" ]]; then
  ok "B1: the foreign repo's row is byte-identical after the offer stamp"
else
  fail "B1: foreign row mutated (before=$FOREIGN_BEFORE after=$FOREIGN_AFTER)"
fi
if [[ "$MINE_AFTER" == offer-* ]]; then
  ok "B2: this session's own open row IS stamped (the scoping did not over-narrow)"
else
  fail "B2: own row was not stamped (chip_task_id='$MINE_AFTER')"
fi

# NEGATIVE CONTROL — the blanket selector the skill used to carry, verbatim.
# The quoted heredoc keeps jq's `$tok` literal without the shell touching it.
cat > "$TMP_DIR/blanket.jq" <<'BLANKET_JQ'
(.issues[] | select(.status == "open") | .chip_task_id) = $tok
BLANKET_JQ
LOG_B_OLD="$H_B/.claude/handoffs/issue-maker-oldstyle-log.json"
seed_log "$LOG_B_OLD" "auerbachb/claude-code-config" "[$MINE_ROW,$FOREIGN_ROW]"
"$SET_LOG" "$LOG_B_OLD" "$(cat "$TMP_DIR/blanket.jq")" --arg tok "offer-BLANKET" >/dev/null 2>&1
FOREIGN_OLD="$(jq -r '.issues[] | select(.number == 684) | .chip_task_id' "$LOG_B_OLD")"
if [[ "$FOREIGN_OLD" == "offer-BLANKET" ]]; then
  ok "B3 (negative control): the pre-fix blanket select DOES overwrite the foreign chip_task_id"
else
  fail "B3 (negative control): blanket select did not reproduce the corruption (got '$FOREIGN_OLD')"
fi

# A closed row of this session's own repo must also stay untouched — `mine`
# narrows by repo, and `status == "open"` still has to hold.
H_B2="$(make_home b2)"
LOG_B2="$H_B2/.claude/handoffs/issue-maker-closed-log.json"
CLOSED_ROW="$(issue_row 1200 auerbachb/claude-code-config null closed)"
seed_log "$LOG_B2" "auerbachb/claude-code-config" "[$MINE_ROW,$CLOSED_ROW]"
run_block "$H_B2" "claude=1001|start=T1" \
"LOG='$LOG_B2'
REPO='auerbachb/claude-code-config'
$BLOCK_HELPER
$BLOCK_STAMP" >/dev/null 2>&1
if [[ "$(jq -r '.issues[] | select(.number == 1200) | .chip_task_id' "$LOG_B2")" == "null" ]]; then
  ok "B4: a closed row in the same repo is still excluded (status filter retained)"
else
  fail "B4: closed row was stamped"
fi

# =============================================================================
# TEST C — retargeting target_repo over foreign entries warns instead of
#          flipping (reproduces corruption (a))
# =============================================================================
H_C="$(make_home c)"
LOG_C="$H_C/.claude/handoffs/issue-maker-retarget-log.json"
seed_log "$LOG_C" "auerbachb/still-point" "[$FOREIGN_ROW]"

RETARGET_BODY="LOG='$LOG_C'
$BLOCK_HELPER
$(printf '%s\n' "$BLOCK_RETARGET" | sed "s|^REPO=\"<owner/repo the user supplied>\"$|REPO=\"auerbachb/claude-code-config\"|")"
STDERR_C="$(run_block "$H_C" "claude=1001|start=T1" "$RETARGET_BODY" 2>&1 >/dev/null)"
TARGET_AFTER="$(jq -r '.target_repo' "$LOG_C")"

if [[ "$TARGET_AFTER" == "auerbachb/still-point" ]]; then
  ok "C1: target_repo is NOT silently flipped while foreign entries are present"
else
  fail "C1: target_repo flipped to '$TARGET_AFTER'"
fi
if printf '%s' "$STDERR_C" | grep -q 'refusing to retarget'; then
  ok "C2: the retarget guard warns on stderr, naming the refusal"
else
  fail "C2: no retarget warning (stderr: $STDERR_C)"
fi

# The guard must not block the legitimate case: no foreign entries -> write.
H_C2="$(make_home c2)"
LOG_C2="$H_C2/.claude/handoffs/issue-maker-retarget-ok-log.json"
seed_log "$LOG_C2" "" "[]"
RETARGET_OK="LOG='$LOG_C2'
$BLOCK_HELPER
$(printf '%s\n' "$BLOCK_RETARGET" | sed "s|^REPO=\"<owner/repo the user supplied>\"$|REPO=\"auerbachb/claude-code-config\"|")"
run_block "$H_C2" "claude=1001|start=T1" "$RETARGET_OK" >/dev/null 2>&1
if [[ "$(jq -r '.target_repo' "$LOG_C2")" == "auerbachb/claude-code-config" ]]; then
  ok "C3: a clean log still accepts the retarget (guard does not over-block)"
else
  fail "C3: retarget refused on a log with no foreign entries"
fi

# Fail closed: a guard that writes because its own check errored is no guard.
H_C3="$(make_home c3)"
LOG_C3="$H_C3/.claude/handoffs/issue-maker-corrupt-log.json"
printf '%s' '{ this is not json' > "$LOG_C3"
CORRUPT_BEFORE="$(cat "$LOG_C3")"
RETARGET_CORRUPT="LOG='$LOG_C3'
$BLOCK_HELPER
$(printf '%s\n' "$BLOCK_RETARGET" | sed "s|^REPO=\"<owner/repo the user supplied>\"$|REPO=\"auerbachb/claude-code-config\"|")"
STDERR_C3="$(run_block "$H_C3" "claude=1001|start=T1" "$RETARGET_CORRUPT" 2>&1 >/dev/null)"
if printf '%s' "$STDERR_C3" | grep -q 'could not read' && [[ "$CORRUPT_BEFORE" == "$(cat "$LOG_C3")" ]]; then
  ok "C4: an unreadable log refuses the retarget rather than treating the failed check as zero"
else
  fail "C4: unreadable log did not fail closed (stderr: $STDERR_C3)"
fi

# =============================================================================
# TEST D — the 2026-08-26 interleave, replayed end to end
# =============================================================================
H_D="$(make_home d)"
CONV_CFG="claude=4001|start=Wed Aug 26 16:20:00 2026"
CONV_SP="claude=4002|start=Wed Aug 26 16:21:00 2026"

LOG_CFG="$(run_block "$H_D" "$CONV_CFG" "$BLOCK_RESOLVE"$'\necho "$LOG"' 2>/dev/null | tail -n 1)"
LOG_SP="$(run_block  "$H_D" "$CONV_SP"  "$BLOCK_RESOLVE"$'\necho "$LOG"' 2>/dev/null | tail -n 1)"

seed_log "$LOG_CFG" "auerbachb/claude-code-config" "[$(issue_row 1367 auerbachb/claude-code-config null)]"
seed_log "$LOG_SP"  "auerbachb/still-point"        "[$(issue_row 684 auerbachb/still-point "offer-STILLPOINT")]"
SP_SNAPSHOT="$(cat "$LOG_SP")"

# The config session now does everything it did during the incident: retarget,
# file another issue, and stamp its offer batch-wide.
run_block "$H_D" "$CONV_CFG" \
"LOG='$LOG_CFG'
REPO='auerbachb/claude-code-config'
$BLOCK_HELPER
set_log '.issues += [\$row]' --argjson row '$(issue_row 1369 auerbachb/claude-code-config null)'
$BLOCK_STAMP" >/dev/null 2>&1

if [[ "$LOG_CFG" != "$LOG_SP" ]]; then
  ok "D1: the two concurrent sessions never shared a log file"
else
  fail "D1: both sessions resolved the same log"
fi
if [[ "$SP_SNAPSHOT" == "$(cat "$LOG_SP")" ]]; then
  ok "D2: the still-point session's log is byte-identical after the config session's full write sequence"
else
  fail "D2: the concurrent session's log changed"
fi
if [[ "$(jq -r '[.issues[].number] | sort | join(",")' "$LOG_CFG")" == "1367,1369" ]]; then
  ok "D3: no foreign issue leaked into the config session's batch"
else
  fail "D3: foreign issue present ($(jq -c '[.issues[].number]' "$LOG_CFG"))"
fi
if [[ "$(jq -r '.issues[] | select(.number == 684) | .chip_task_id' "$LOG_SP")" == "offer-STILLPOINT" ]]; then
  ok "D4: issue #684 keeps its own chip_task_id (the exact value repaired by hand during the incident)"
else
  fail "D4: #684's chip_task_id was overwritten"
fi
if [[ "$(jq -r '.target_repo' "$LOG_SP")" == "auerbachb/still-point" ]]; then
  ok "D5: the still-point session's target_repo survives the config session's writes"
else
  fail "D5: target_repo flipped across sessions"
fi

# =============================================================================
# TEST E — single-session flows are unchanged
# =============================================================================
H_E="$(make_home e)"
LOG_E="$(run_block "$H_E" "claude=5001|start=T5" "$BLOCK_RESOLVE"$'\necho "$LOG"' 2>/dev/null | tail -n 1)"
seed_log "$LOG_E" "auerbachb/claude-code-config" "[]"

run_block "$H_E" "claude=5001|start=T5" \
"LOG='$LOG_E'
REPO='auerbachb/claude-code-config'
$BLOCK_HELPER
set_log '.issues += [\$row]' --argjson row '$(issue_row 900 auerbachb/claude-code-config null)'
set_log '.issues += [\$row]' --argjson row '$(issue_row 901 auerbachb/claude-code-config null)'
set_log '.mode = \$v' --arg v rapid-fire
$BLOCK_STAMP
set_log '(.issues[] | select(.number == (\$n|tonumber)) | .status) = \"closed\"' --arg n 901
set_log '.offer_accepted = true'" >/dev/null 2>&1
E_RC=$?

E_900="$(jq -r '.issues[] | select(.number == 900) | .chip_task_id' "$LOG_E")"
E_901_STATUS="$(jq -r '.issues[] | select(.number == 901) | .status' "$LOG_E")"
E_MODE="$(jq -r '.mode' "$LOG_E")"
E_ACCEPTED="$(jq -r '.offer_accepted' "$LOG_E")"
E_TOUCHED="$(jq -r '.last_updated_at' "$LOG_E")"

if [[ $E_RC -eq 0 && "$E_900" == offer-* && "$E_901_STATUS" == "closed" \
      && "$E_MODE" == "rapid-fire" && "$E_ACCEPTED" == "true" \
      && "$E_TOUCHED" != "2026-08-26T20:00:00Z" ]]; then
  ok "E1: create + stamp + retract + mode + accept all behave as before in a single session"
else
  fail "E1: single-session regression (rc=$E_RC chip='$E_900' status='$E_901_STATUS' mode='$E_MODE' accepted='$E_ACCEPTED' touched='$E_TOUCHED')"
fi

# The compaction recap read is untouched by the scoping change.
RECAP="$(jq -r '"\(([.issues[]|select(.status=="open")]|length)) open"' "$LOG_E")"
if [[ "$RECAP" == "1 open" ]]; then
  ok "E2: the Step 1 compaction recap still counts this session's open issues"
else
  fail "E2: recap count changed ('$RECAP')"
fi

# =============================================================================
# TEST F — the two ways the #1369 guarantee could still leak (CodeAnt, PR #1384)
#          F1/F2: one conversation must not split across two logs when two of
#          its invocations mint the marker at once.
#          F3-F5: an unverifiable log must not silence the collision backstop.
# =============================================================================
H_F="$(make_home f)"
CONV_F="claude=7007|start=Wed Aug 26 17:00:00 2026"

# The block is written ONCE and both racers read it. run_block names its temp
# file with $RANDOM, and forked subshells inherit the RNG state — two
# background copies would draw the same name and clobber each other.
printf '%s\n' "$BLOCK_RESOLVE"$'\necho "$LOG"' > "$TMP_DIR/f-block.sh"

# The environment goes on the command rather than through `export`, so this
# helper leaves the suite's own HOME untouched.
race_once() { # race_once <cwd> <outfile>
  ( unset CLAUDE_SESSION_ID
    cd "$1" || exit 1
    HOME="$H_F" ISSUE_MAKER_CONV_ID="$CONV_F" \
      bash "$TMP_DIR/f-block.sh" 2>/dev/null | tail -n 1 ) > "$2"
}

# F1 — a genuine concurrent mint: no marker yet, and the two callers run from
# DIFFERENT cwds, which is what makes their minted keys differ (cwd is folded
# into the digest). A parent and a subagent it spawned hit exactly this shape,
# since they share the `claude` ancestor that IS the conversation identity.
F_DIVERGED=""
for _i in 1 2 3 4 5 6 7 8; do
  rm -rf "${H_F:?}/.claude/handoffs/.issue-maker-keys"
  race_once / "$TMP_DIR/f-a" &
  race_once "$TMP_DIR" "$TMP_DIR/f-b" &
  wait
  F_A="$(cat "$TMP_DIR/f-a")"; F_B="$(cat "$TMP_DIR/f-b")"
  if [[ -z "$F_A" || -z "$F_B" ]]; then
    F_DIVERGED="empty result (a='$F_A' b='$F_B')"; break
  fi
  if [[ "$F_A" != "$F_B" ]]; then
    F_DIVERGED="'$F_A' != '$F_B'"; break
  fi
done
if [[ -z "$F_DIVERGED" ]]; then
  ok "F1: concurrent mints in ONE conversation converge on a single log (8 attempts)"
else
  fail "F1: one conversation split across two logs under a concurrent mint — $F_DIVERGED"
fi

# NEGATIVE CONTROL — isolate the publish primitive itself, so F1 cannot pass
# just because the race never actually interleaved on this machine.
NC_MARK="$TMP_DIR/nc-marker"
printf 'fallback-aaaaaaaaaaaaaaaaaaaa\n' > "$NC_MARK"
NC_TMP="$(mktemp "$TMP_DIR/nc.XXXXXX")"
printf 'fallback-bbbbbbbbbbbbbbbbbbbb\n' > "$NC_TMP"
mv "$NC_TMP" "$NC_MARK"                     # the pre-fix publish
NC_OLD="$(head -n 1 "$NC_MARK")"

printf 'fallback-aaaaaaaaaaaaaaaaaaaa\n' > "$NC_MARK"
( set -o noclobber; printf 'fallback-bbbbbbbbbbbbbbbbbbbb\n' > "$NC_MARK" ) 2>/dev/null || true
NC_NEW="$(head -n 1 "$NC_MARK")"

if [[ "$NC_OLD" == "fallback-bbbbbbbbbbbbbbbbbbbb" && "$NC_NEW" == "fallback-aaaaaaaaaaaaaaaaaaaa" ]]; then
  ok "F2 (negative control): the pre-fix mv publish DOES clobber a concurrent winner; the exclusive create does not"
else
  fail "F2 (negative control): publish primitives misbehaved (mv->'$NC_OLD' excl->'$NC_NEW')"
fi

# F3 — a log that cannot be parsed is NOT "no owner recorded". Pre-fix both
# collapsed to an empty session_id and the backstop said nothing, which is
# silence in precisely the case where ownership is least verifiable.
BAD_LOG="$H_F/.claude/handoffs/issue-maker-fallback-corrupt-log.json"
printf '{ this is not json' > "$BAD_LOG"
STDERR_BAD="$(HOME="$H_F" CLAUDE_SESSION_ID="fallback-corrupt" \
  "$H_F/.claude/skills/issue-maker/scripts/resolve-log.sh" 2>&1 >/dev/null)"
if printf '%s' "$STDERR_BAD" | grep -q 'could not read session_id'; then
  ok "F3: a corrupt log warns that ownership could NOT be verified"
else
  fail "F3: corrupt log silently skipped the collision backstop (stderr: $STDERR_BAD)"
fi

# NEGATIVE CONTROL — the pre-fix read really did swallow the failure.
NC_SID="$(jq -r '.session_id // ""' "$BAD_LOG" 2>/dev/null || true)"
if [[ -z "$NC_SID" ]]; then
  ok "F4 (negative control): the pre-fix read collapses a corrupt log to an empty session_id, so the backstop stayed silent"
else
  fail "F4 (negative control): corrupt log did not reproduce the empty read (got '$NC_SID')"
fi

# F5 — the mirror image: a VALID log that simply records no session_id must
# stay quiet, or the new warning would fire on every fresh capture.
OK_LOG="$H_F/.claude/handoffs/issue-maker-fallback-nosid-log.json"
printf '{"schema_version":"1","issues":[]}' > "$OK_LOG"
STDERR_OK="$(HOME="$H_F" CLAUDE_SESSION_ID="fallback-nosid" \
  "$H_F/.claude/skills/issue-maker/scripts/resolve-log.sh" 2>&1 >/dev/null)"
if printf '%s' "$STDERR_OK" | grep -q 'could not read session_id'; then
  fail "F5: a valid log with no session_id wrongly warned (stderr: $STDERR_OK)"
else
  ok "F5: a valid log with no session_id stays quiet — the new warning is read-failure only"
fi

# =============================================================================
echo
echo "issue-maker-log-scoping: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
