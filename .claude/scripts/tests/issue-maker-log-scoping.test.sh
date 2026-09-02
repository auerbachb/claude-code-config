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
#
# The real conversation's CLAUDE_CODE_*_SESSION_ID DO reach a Bash tool subshell
# (that is exactly why resolve-log.sh can use them as a stable anchor), so they
# are unset here too — otherwise every fabricated conversation in this suite
# would inherit ONE ambient anchor. `anchor` is the explicit per-test override.
run_block() {
  local home="$1" conv="$2" body="$3" anchor="${4:-}"
  local f="$TMP_DIR/block-$$-$RANDOM.sh"
  printf '%s\n' "$body" > "$f"
  ( unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_CODE_HOST_SESSION_ID \
          ISSUE_MAKER_STABLE_ANCHOR
    export HOME="$home" ISSUE_MAKER_CONV_ID="$conv"
    if [[ -n "$anchor" ]]; then export ISSUE_MAKER_STABLE_ANCHOR="$anchor"; fi
    bash "$f" )
}

# resolve_key — call resolve-log.sh directly for the key alone. `mode` picks
# what is captured: "key" -> stdout, "err" -> stderr.
resolve_key() { # resolve_key <home> <conv> <anchor> [mode]
  local home="$1" conv="$2" anchor="$3" mode="${4:-key}"
  ( unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_CODE_HOST_SESSION_ID \
          ISSUE_MAKER_STABLE_ANCHOR
    export HOME="$home" ISSUE_MAKER_CONV_ID="$conv"
    if [[ -n "$anchor" ]]; then export ISSUE_MAKER_STABLE_ANCHOR="$anchor"; fi
    if [[ "$mode" == "err" ]]; then
      # No --key here: that mode prints the key and exits before the notes, so
      # asking for stderr means asking for the full path-resolving run.
      "$home/.claude/skills/issue-maker/scripts/resolve-log.sh" 2>&1 >/dev/null
    else
      "$home/.claude/skills/issue-maker/scripts/resolve-log.sh" --key 2>/dev/null
    fi )
}

marker_dir() { printf '%s' "$1/.claude/handoffs/.issue-maker-keys"; }

# distinct_marker_keys — every distinct key recorded across <home>'s markers.
# Adoption must never grow this set; minting always does.
distinct_marker_keys() {
  local d f; d="$(marker_dir "$1")"
  [[ -d "$d" ]] || return 0
  for f in "$d"/imk-*; do
    [[ -f "$f" ]] || continue
    head -n 1 "$f"
  done | LC_ALL=C sort -u
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
# TEST G — issue #1572: ONE conversation must not fragment across TWO logs when
#          its `claude` ancestor changes mid-conversation (sleep/wake, harness
#          reconnect). The mirror image of #1369, so every positive assertion
#          here is paired with the control that reproduces the fragmentation.
# =============================================================================
H_G="$(make_home g)"
G_ANCHOR="conv-alpha"
G_KEY_1="$(resolve_key "$H_G" "claude=8001|start=Mon Sep  1 22:29:54 2026" "$G_ANCHOR")"
# The ancestor walk now lands on a different `claude` process — a new pid AND a
# new start time, exactly what the overnight sleep produced.
G_KEY_2="$(resolve_key "$H_G" "claude=9002|start=Tue Sep  2 08:04:11 2026" "$G_ANCHOR")"

if [[ -n "$G_KEY_1" && "$G_KEY_1" == "$G_KEY_2" ]]; then
  ok "G1: a drifted ancestor identity resolves the ORIGINAL key, not a sibling log"
else
  fail "G1: key drifted mid-conversation ('$G_KEY_1' -> '$G_KEY_2')"
fi

# A third, still-different identity — so this exercises the adoption path again
# rather than the pointer marker G_KEY_2 just published.
G_ERR="$(resolve_key "$H_G" "claude=9003|start=Tue Sep  2 09:15:00 2026" "$G_ANCHOR" err)"
if printf '%s' "$G_ERR" | grep -q "kept its ORIGINAL key '$G_KEY_1'"; then
  ok "G2: adoption after drift is announced on stderr, naming the retained key"
else
  fail "G2: no drift note emitted (stderr: $G_ERR)"
fi

if [[ "$(distinct_marker_keys "$H_G" | wc -l | tr -d ' ')" == "1" ]]; then
  ok "G3: three drifted identities left exactly ONE key across all markers (nothing minted)"
else
  fail "G3: adoption minted a sibling key ($(distinct_marker_keys "$H_G" | tr '\n' ' '))"
fi

# NEGATIVE CONTROL — the same drift with NO anchor available. This is the
# pre-#1572 code path, and it must still fragment: without it G1 could pass on a
# resolver that had simply stopped distinguishing identities at all.
H_G_NC="$(make_home g-nc)"
NC_KEY_1="$(resolve_key "$H_G_NC" "claude=8001|start=Mon Sep  1 22:29:54 2026" "")"
NC_KEY_2="$(resolve_key "$H_G_NC" "claude=9002|start=Tue Sep  2 08:04:11 2026" "")"
if [[ -n "$NC_KEY_1" && -n "$NC_KEY_2" && "$NC_KEY_1" != "$NC_KEY_2" ]]; then
  ok "G4 (negative control): with no derivable anchor the SAME drift DOES fragment (the #1572 bug)"
else
  fail "G4 (negative control): drift did not reproduce ('$NC_KEY_1' vs '$NC_KEY_2')"
fi

# #1369 must not regress: two genuinely different conversations still separate.
H_G2="$(make_home g2)"
SEP_1="$(resolve_key "$H_G2" "claude=1001|start=T1" "conv-one")"
SEP_2="$(resolve_key "$H_G2" "claude=2002|start=T2" "conv-two")"
if [[ -n "$SEP_1" && -n "$SEP_2" && "$SEP_1" != "$SEP_2" ]]; then
  ok "G5: distinct anchors keep distinct conversations on distinct logs (#1369 holds)"
else
  fail "G5: two conversations merged onto one log ('$SEP_1' / '$SEP_2')"
fi

# A simulated identity must never borrow the AMBIENT conversation's anchor —
# otherwise the harness ids leaking into any subshell would merge every
# fabricated conversation onto one log.
H_G3="$(make_home g3)"
amb_key() {
  ( unset CLAUDE_SESSION_ID
    export HOME="$H_G3" ISSUE_MAKER_CONV_ID="$1"
    export CLAUDE_CODE_HOST_SESSION_ID="local_ambient-host-id"
    export CLAUDE_CODE_SESSION_ID="ambient-session-id"
    unset ISSUE_MAKER_STABLE_ANCHOR
    "$H_G3/.claude/skills/issue-maker/scripts/resolve-log.sh" --key 2>/dev/null )
}
AMB_1="$(amb_key "claude=3001|start=T3")"
AMB_2="$(amb_key "claude=4001|start=T4")"
if [[ -n "$AMB_1" && -n "$AMB_2" && "$AMB_1" != "$AMB_2" ]]; then
  ok "G6: an overridden identity ignores the ambient harness anchor (simulated conversations stay separate)"
else
  fail "G6: ambient anchor merged two overridden identities ('$AMB_1' / '$AMB_2')"
fi

# Ambiguity: two markers claim one anchor with DIFFERENT keys. Pick
# deterministically, name both on stderr, and mint nothing.
H_G4="$(make_home g4)"
MD_G4="$(marker_dir "$H_G4")"
mkdir -p "$MD_G4"
printf 'fallback-aaaaaaaaaaaaaaaaaaaa\nident=old-a\nanchor=conv-amb\nepoch=1000\n' > "$MD_G4/imk-older"
printf 'fallback-bbbbbbbbbbbbbbbbbbbb\nident=old-b\nanchor=conv-amb\nepoch=2000\n' > "$MD_G4/imk-newer"
AMBIG_KEY="$(resolve_key "$H_G4" "claude=6001|start=T6" "conv-amb")"
AMBIG_ERR="$(resolve_key "$H_G4" "claude=6002|start=T7" "conv-amb" err)"

if [[ "$AMBIG_KEY" == "fallback-bbbbbbbbbbbbbbbbbbbb" ]]; then
  ok "G7: ambiguous candidates resolve deterministically to the newest recorded epoch"
else
  fail "G7: ambiguity resolved to '$AMBIG_KEY' instead of the newest-epoch key"
fi
if printf '%s' "$AMBIG_ERR" | grep -q 'imk-older' && printf '%s' "$AMBIG_ERR" | grep -q 'imk-newer' \
   && printf '%s' "$AMBIG_ERR" | grep -q 'DIFFERENT keys'; then
  ok "G8: the ambiguity WARN names every candidate marker rather than picking silently"
else
  fail "G8: ambiguity was not warned about by name (stderr: $AMBIG_ERR)"
fi
if [[ "$(distinct_marker_keys "$H_G4" | wc -l | tr -d ' ')" == "2" ]]; then
  ok "G9: no THIRD key was minted while candidates existed"
else
  fail "G9: a new key was minted despite candidates ($(distinct_marker_keys "$H_G4" | tr '\n' ' '))"
fi

# A pre-#1572 one-line marker must still be readable, and must gain an anchor on
# its next hit — that migration is the only thing that makes an ALREADY-running
# conversation drift-recoverable.
H_G5="$(make_home g5)"
LEG_KEY="$(resolve_key "$H_G5" "claude=5005|start=TL" "conv-legacy")"
LEG_MARKER="$(ls "$(marker_dir "$H_G5")"/imk-* 2>/dev/null | head -n 1)"
printf '%s\n' "$LEG_KEY" > "$LEG_MARKER"   # downgrade to the pre-#1572 format
LEG_AGAIN="$(resolve_key "$H_G5" "claude=5005|start=TL" "conv-legacy")"
if [[ "$LEG_AGAIN" == "$LEG_KEY" ]]; then
  ok "G10: a legacy single-line marker is still read as this conversation's key"
else
  fail "G10: legacy marker not honoured ('$LEG_KEY' -> '$LEG_AGAIN')"
fi
if grep -q '^anchor=conv-legacy$' "$LEG_MARKER"; then
  ok "G11: the legacy marker is migrated in place to carry the anchor"
else
  fail "G11: legacy marker was not migrated (content: $(cat "$LEG_MARKER"))"
fi
LEG_DRIFT="$(resolve_key "$H_G5" "claude=5006|start=TM" "conv-legacy")"
if [[ "$LEG_DRIFT" == "$LEG_KEY" ]]; then
  ok "G12: a conversation that started pre-#1572 survives its first drift after migration"
else
  fail "G12: post-migration drift still fragmented ('$LEG_KEY' -> '$LEG_DRIFT')"
fi

# set-log.sh stays loud on a missing path — the failure that made the original
# #1572 fragmentation visible at all.
MISSING_LOG="$TMP_DIR/no-such-session-log.json"
SETLOG_ERR="$("$SET_LOG" "$MISSING_LOG" '.mode = $v' --arg v rapid-fire 2>&1 >/dev/null)"
SETLOG_RC=$?
if [[ $SETLOG_RC -ne 0 ]] && printf '%s' "$SETLOG_ERR" | grep -q "$MISSING_LOG"; then
  ok "G13: set-log.sh on a missing path exits non-zero and names the path"
else
  fail "G13: set-log.sh missing-path failure was quiet (rc=$SETLOG_RC stderr: $SETLOG_ERR)"
fi
if [[ ! -e "$MISSING_LOG" ]]; then
  ok "G14: the failed set-log write created nothing"
else
  fail "G14: set-log.sh created the missing log instead of failing"
fi

# An invocation that cannot derive an anchor must not ERASE the one already
# recorded: the cost would be invisible until the NEXT drift, which is precisely
# when the recovery is needed.
H_G6="$(make_home g6)"
KEEP_KEY="$(resolve_key "$H_G6" "claude=4004|start=TK" "conv-keep")"
KEEP_MARKER="$(ls "$(marker_dir "$H_G6")"/imk-* 2>/dev/null | head -n 1)"
# A sentinel epoch, so "the anchor survived" cannot pass just because the
# anchor-less run never touched the marker at all.
printf 'epoch=SENTINEL\n' >> "$KEEP_MARKER"
# Resolving again with the same identity must return the SAME key: that is the
# anti-vacuity guard here — it proves the anchor-less run really did read and use
# this marker, so "the anchor survived" cannot pass on a resolver that quietly
# stopped resolving at all. Whether the marker was REWRITTEN is asserted in
# group H, where leaving it alone is the point.
KEEP_AGAIN="$(resolve_key "$H_G6" "claude=4004|start=TK" "")"   # same identity, no anchor
if [[ "$KEEP_AGAIN" == "$KEEP_KEY" ]] && grep -q '^anchor=conv-keep$' "$KEEP_MARKER"; then
  ok "G16: an anchor-less invocation resolves the same key and preserves the anchor already recorded"
else
  fail "G16: the recorded anchor was erased or the key moved ('$KEEP_KEY' -> '$KEEP_AGAIN', content: $(cat "$KEEP_MARKER"))"
fi
KEEP_DRIFT="$(resolve_key "$H_G6" "claude=4005|start=TL" "conv-keep")"
if [[ "$KEEP_DRIFT" == "$KEEP_KEY" ]]; then
  ok "G17: drift recovery still works after an anchor-less invocation"
else
  fail "G17: anchor-less invocation cost the conversation its drift recovery ('$KEEP_KEY' -> '$KEEP_DRIFT')"
fi

# NEGATIVE CONTROL for the publish primitive, now that a marker is a MULTI-LINE
# record. A `noclobber` redirect wins the race but creates an EMPTY file and
# writes after, so a loser reading in that window sees no key and re-mints its
# own — one conversation on two logs again. Linking an already-written temp file
# both refuses an existing target and is complete from the instant it appears.
LN_DIR="$TMP_DIR/publish-primitive"
mkdir -p "$LN_DIR"
LN_TARGET="$LN_DIR/marker"
printf 'fallback-aaaaaaaaaaaaaaaaaaaa\nanchor=x\n' > "$LN_DIR/staged-a"
printf 'fallback-bbbbbbbbbbbbbbbbbbbb\nanchor=x\n' > "$LN_DIR/staged-b"
ln "$LN_DIR/staged-a" "$LN_TARGET" 2>/dev/null
LN_SECOND_RC=0
ln "$LN_DIR/staged-b" "$LN_TARGET" 2>/dev/null || LN_SECOND_RC=$?
LN_WINNER="$(head -n 1 "$LN_TARGET")"
: > "$LN_DIR/created-then-written"          # the create half of a noclobber publish
NC_WINDOW="$(head -n 1 "$LN_DIR/created-then-written")"
if [[ $LN_SECOND_RC -ne 0 && "$LN_WINNER" == "fallback-aaaaaaaaaaaaaaaaaaaa" && -z "$NC_WINDOW" ]]; then
  ok "G15 (negative control): the link publish refuses an existing marker AND lands complete, where create-then-write is observably keyless first"
else
  fail "G15 (negative control): publish primitives misbehaved (second-ln rc=$LN_SECOND_RC winner='$LN_WINNER' window='$NC_WINDOW')"
fi

# =============================================================================
# TEST H — the two unlocked-write races CodeAnt flagged on PR #1575. Both are
#          narrow, and both end in the SAME failure the rest of this file exists
#          to prevent: one conversation on two logs.
#            H1:    an anchor-less run must not write the marker at all, so it
#                   cannot revert an anchor a concurrent run just recorded.
#            H2-H3: a marker caught mid-write must be waited out and adopted,
#                   never mistaken for corruption and overwritten.
# =============================================================================
# A SENTINEL line, not a byte-compare of the untouched record: pre-fix,
# write_marker rewrote the marker with the same key, ident and anchor and only a
# fresh epoch, so two runs inside one second produced IDENTICAL content and a
# plain before/after compare passed vacuously against the very code it was meant
# to catch. Replacing the file wipes the sentinel; leaving it alone keeps it.
H_H1="$(make_home h1)"
H1_KEY="$(resolve_key "$H_H1" "claude=7001|start=TH" "conv-h1")"
H1_MARKER="$(ls "$(marker_dir "$H_H1")"/imk-* 2>/dev/null | head -n 1)"
printf 'sentinel=H1\n' >> "$H1_MARKER"
H1_AGAIN="$(resolve_key "$H_H1" "claude=7001|start=TH" "")"   # anchor-less, same identity
if [[ "$H1_AGAIN" == "$H1_KEY" ]] && grep -q '^sentinel=H1$' "$H1_MARKER"; then
  ok "H1: an anchor-less invocation resolves the marker WITHOUT rewriting it (so it cannot revert a concurrent anchor update)"
else
  fail "H1: the anchor-less invocation rewrote the marker ('$H1_KEY' -> '$H1_AGAIN'; content: $(cat "$H1_MARKER"))"
fi

# G17 already covers the other half — that drift recovery still WORKS after an
# anchor-less run — so it is not restated here.

# The publish window. A `noclobber` publish creates the marker EMPTY and writes
# after, so a racer can read a keyless marker that is about to be perfectly good.
# Reading once sent that racer down the re-mint arm, destroying the winner's
# marker and keeping its own key.
#
# Driven by a `sleep` shim rather than a real background writer: the winner's
# record appears IF AND ONLY IF the resolver actually paused to re-read. That
# makes the test deterministic under any load AND makes it impossible to pass on
# a read-once resolver — a timed background write could satisfy neither.
H_H4="$(make_home h4)"
H4_KEY="$(resolve_key "$H_H4" "claude=7004|start=TN" "conv-h4")"
H4_MARKER="$(ls "$(marker_dir "$H_H4")"/imk-* 2>/dev/null | head -n 1)"
H4_WINNER="fallback-cccccccccccccccccccc"
SHIM_DIR="$TMP_DIR/shim-h4"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/sleep" <<EOF
#!/usr/bin/env bash
# Stands in for the instant a racing publisher completes its noclobber write.
if [ ! -s "$H4_MARKER" ]; then
  printf '%s\nident=winner\nanchor=conv-h4\nepoch=9999\n' "$H4_WINNER" > "$H4_MARKER"
fi
exit 0
EOF
chmod +x "$SHIM_DIR/sleep"
: > "$H4_MARKER"                       # the create half of a noclobber publish
H4_RESOLVED="$( unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_CODE_HOST_SESSION_ID
  export HOME="$H_H4" ISSUE_MAKER_CONV_ID="claude=7004|start=TN" \
         ISSUE_MAKER_STABLE_ANCHOR="conv-h4" PATH="$SHIM_DIR:$PATH"
  "$H_H4/.claude/skills/issue-maker/scripts/resolve-log.sh" --key 2>/dev/null )"
if [[ "$H4_RESOLVED" == "$H4_WINNER" ]]; then
  ok "H2: a marker caught mid-write is re-read and ADOPTED, not overwritten"
else
  fail "H2: the in-flight marker was overwritten ('$H4_RESOLVED' instead of '$H4_WINNER'; first key was '$H4_KEY')"
fi

# CONTROL — the wait is BOUNDED. A marker that never completes must still fall
# through to a well-formed re-mint rather than blocking the resolve forever.
H_H5="$(make_home h5)"
H5_KEY="$(resolve_key "$H_H5" "claude=7005|start=TO" "conv-h5")"
H5_MARKER="$(ls "$(marker_dir "$H_H5")"/imk-* 2>/dev/null | head -n 1)"
: > "$H5_MARKER"
H5_RESOLVED="$(resolve_key "$H_H5" "claude=7005|start=TO" "conv-h5")"
case "$H5_RESOLVED" in
  fallback-[0-9a-f]*)
    ok "H3 (control): a marker that never completes still falls through to a well-formed re-mint" ;;
  *)
    fail "H3 (control): permanently-empty marker did not re-mint (got '$H5_RESOLVED'; first key was '$H5_KEY')" ;;
esac

# =============================================================================
echo
echo "issue-maker-log-scoping: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
