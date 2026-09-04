#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
END="$ROOT/.claude/skills/end/SKILL.md"
PAUSE="$ROOT/.claude/skills/pause/SKILL.md"
END_RESUME="$ROOT/.claude/skills/end-resume/SKILL.md"
PAUSE_RESUME="$ROOT/.claude/skills/pause-resume/SKILL.md"
GO_ON="$ROOT/.claude/skills/go-on/SKILL.md"
SWEEP_SCRIPT="$ROOT/.claude/scripts/candidate-ownership.sh"
PM="$ROOT/.claude/skills/pm/SKILL.md"
PHASES="$ROOT/.claude/rules/phase-protocols.md"
SETTINGS="$ROOT/global-settings.json"
ARM_HOOK="$ROOT/.claude/hooks/bgwork-ceiling-arm.sh"
COMPLETE_HOOK="$ROOT/.claude/hooks/background-task-complete.sh"
GATE_HOOK="$ROOT/.claude/hooks/pause-launch-gate.sh"
REGISTRY="$ROOT/.claude/scripts/background-task-registry.sh"
PAUSE_SCRIPT="$ROOT/.claude/scripts/execution-pause.sh"
HANDOFF_CONTEXT="$ROOT/.claude/scripts/portable-handoff-context.sh"
HANDOFF_PUBLISH="$ROOT/.claude/scripts/portable-handoff-publish.sh"
HANDOFF_LINT="$ROOT/.claude/scripts/portable-handoff-lint.sh"
CHECKPOINT="$ROOT/.claude/hooks/checkpoint-handoff.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -Eq -- "$2" "$1" || fail "$(basename "$1") missing: $2"; }
# A negative assertion must never pass because the file was absent — an
# unreadable path makes `grep -q` fail, which reads identically to "not found".
hasnt() {
  [[ -r "$1" ]] || fail "$(basename "$1") is unreadable; cannot assert absence of: $2"
  grep -Eq -- "$2" "$1" && fail "$(basename "$1") must NOT contain: $2"
  return 0
}

has "$END" '^name: end$'
has "$END" 'default: --window 5m'
has "$END" 'WINDOW_MINUTES=5'
has "$END" "10#\\\$_NORMALIZED"
has "$END" '1440'
has "$PAUSE" '^name: pause$'
has "$PAUSE" 'default: --window 15m'
has "$PAUSE" 'WINDOW_MINUTES=15'
has "$PAUSE" "10#\\\$_NORMALIZED"
has "$PAUSE" '1440'
has "$END" 'background-task-shutdown.md'
has "$PAUSE" 'background-task-shutdown.md'
has "$END" 'hard stop'
has "$PAUSE" 'hard stop'
has "$PAUSE" 'hard-stop exact'
has "$ARM_HOOK" 'CLAUDE_STATE_LOCK_TIMEOUT=3'
has "$ARM_HOOK" 'CLAUDE_STATE_RMW_MAX_RETRY=0'
has "$COMPLETE_HOOK" 'CLAUDE_STATE_LOCK_TIMEOUT=3'
has "$COMPLETE_HOOK" 'CLAUDE_STATE_RMW_MAX_RETRY=0'
has "$GATE_HOOK" 'CLAUDE_STATE_LOCK_TIMEOUT=3'
has "$GATE_HOOK" 'RC.*-eq 6'
has "$PAUSE_SCRIPT" 'execution-pause-markers'
has "$PAUSE_SCRIPT" 'chmod 700'
has "$REGISTRY" 'failed|stop_failed|rearmed'
has "$PAUSE" 'PAUSE_PERSISTED!=0'
has "$PAUSE" 'PAUSE_PERSISTED != 0.*INCOMPLETE SHUTDOWN'
# Issue #1576: /pause writes ONE session-keyed record, never the repo singleton.
has "$PAUSE" '\.repos\[.*\]\.pauses\[.*SESSION_ID'
hasnt "$PAUSE" '\.repos\[\\"\$REPO_KEY\\"\]\.pause='
has "$PAUSE" 'session_id'
# /pause-resume enumerates the union and keeps --marker as a short-circuit.
has "$PAUSE_RESUME" '\.repos\[.*\]\.pauses'
has "$PAUSE_RESUME" 'PAUSE_RECORDS'
has "$PAUSE_RESUME" 'RECORD_COUNT'
has "$PAUSE_RESUME" 'union member'
has "$PAUSE_RESUME" 'short-circuit'
has "$PAUSE_RESUME" 'state_path'
# "Could not look" is never "nothing there": an unreadable source may not be
# collapsed into the empty value an absent path returns.
has "$PAUSE_RESUME" 'STATE_UNREADABLE'
has "$PAUSE_RESUME" 'DEGRADED: could not read'
has "$PAUSE_RESUME" 'parked work may exist'
# The read helper must SET a variable, never print into a $() subshell that
# would discard the unreadable flag it set.
has "$PAUSE_RESUME" 'SLOT_VALUE'
# An empty SELECTION is not an empty UNION: markers survive a restore, so
# globbing after "all records already resumed" restores a finished board twice.
has "$PAUSE_RESUME" 'RECORDS_TOTAL'
has "$PAUSE_RESUME" 'already resumed\. Run /pause to park a new session'
# The AUTOMATIC glob is gated on RECORDS_TOTAL, not just RECORD_COUNT: records
# filtered as resumed — or dropped because a corrupt map made them unreadable —
# still leave a retained marker the glob would restore a second time.
has "$PAUSE_RESUME" '\-z "\$MARKER_PATH" && "\$RECORDS_TOTAL" -eq 0 && "\$PAUSES_DISCARDED" == false'
# RECORDS_TOTAL is counted AFTER a corrupt source is discarded, so it alone
# cannot tell "no records existed" from "we threw the source away".
has "$PAUSE_RESUME" 'PAUSES_DISCARDED=true'
# A scalar inside a recovery array must not abort jq and discard healthy records.
has "$PAUSE_RESUME" 'type != "object"'
has "$GO_ON" 'type != "object"'
# A corrupt pause source is unreadable, not empty — in all three readers, and by
# ONE shared rule (issue #1611): `slot_class` classifies a single slot as
# absent | present | unreadable, identically for the session-keyed map and the
# legacy singletons, and each reader degrades only the slot it names. Raising
# instead aborted the whole combine, so one damaged singleton discarded the
# healthy records read beside it. Parity of the three copies is pinned in
# pause-multisession.test.sh; here we only assert each reader carries it.
has "$PAUSE_RESUME" 'def slot_class\(\$kind\):'
has "$GO_ON" 'def slot_class\(\$kind\):'
has "$SWEEP_SCRIPT" 'def slot_class\(\$kind\):'
# The damaged slot is named individually rather than collapsing the source.
has "$PAUSE_RESUME" 'def slot_degraded\(\$name; \$kind\):'
has "$GO_ON" 'def slot_degraded\(\$name; \$kind\):'
has "$SWEEP_SCRIPT" 'def slot_degraded\(\$name; \$kind\):'
has "$PAUSE_RESUME" 'is not a pause record, or holds a malformed record'
has "$GO_ON" 'DEGRADED: pause slot\(s\) \$PAUSE_SLOTS_UNREADABLE unreadable'
has "$SWEEP_SCRIPT" 'not a pause record, or holds a malformed record'
# No reader may raise out of the combine any more — that is what threw away the
# surviving slots. (`error(` appears nowhere in these three pause programs.)
hasnt "$PAUSE_RESUME" 'error\("legacy'
hasnt "$GO_ON" 'error\("legacy'
hasnt "$SWEEP_SCRIPT" 'error\("legacy'
# A malformed VALUE inside an otherwise-valid map is corrupt too — `select`
# would drop it silently, reporting a clean no-op over a damaged board.
has "$PAUSE_RESUME" 'all\(\.value \| type == "object"\)'
has "$GO_ON" 'all\(\.value \| type == "object"\)'
has "$SWEEP_SCRIPT" 'all\(\.value \| type == "object"\)'
# The marker fallback must seed a selection entry — the Step 2 loop iterates
# PAUSE_RECORDS, so a marker board with no entry would never reach Steps 3-7.
has "$PAUSE_RESUME" 'session_id:"marker"'
has "$PAUSE_RESUME" 'RECORD_COUNT=1'
has "$PAUSE_RESUME" '\-n "\$STATE_PATH"'
# go-on's pause reads are tri-state, like probe A: only exit 3 is absent, and a
# failed read degrades THAT SLOT rather than breaking out of the loop.
has "$GO_ON" 'PAUSE_SLOTS_UNREADABLE'
has "$GO_ON" 'SLOT_RC == 3'
has "$GO_ON" 'for PAUSE_SLOT in pauses pause suspend'
# An unreadable receipt is not "no receipt": dispatching there re-runs a
# stoppage this session may already have resumed.
has "$GO_ON" 'RECEIPT_STATE'
has "$GO_ON" 'resume receipt for this session could not be read'
has "$GO_ON" 'legacy resume receipt could not be read'
# The un-resumed predicate: jq's // treats false as empty, so `.active // true`
# passes every resumed record and the whole enumeration silently no-ops.
# Match the CODE shape only — `(.active // true)` or `jq -r '.active // true'` —
# so the skills stay free to name the trap in prose, which they do.
has "$PAUSE_RESUME" 'active != false'
hasnt "$PAUSE_RESUME" "[(\"']\.active // true"
hasnt "$GO_ON" "[(\"']\.active // true"
has "$PAUSE_RESUME" 'STATE_KEY="suspend"'
has "$PAUSE_RESUME" 'handoffs/suspend-'
has "$PAUSE_RESUME" 'MARKER_NAME.*suspend-'
has "$PAUSE_RESUME" 'paused_at // \.suspended_at'
# Legacy singletons stay READ-ONLY inputs on the resume side only.
has "$PAUSE_RESUME" '\.repos\[.*\]\.suspend'
# Resume receipts are keyed per session too, and the legacy singleton is only
# consulted when it belongs to the reading session.
has "$GO_ON" '\.repos\[.*\]\.resumes\[.*SESSION_ID'
hasnt "$GO_ON" '\.repos\[\\"\$REPO_KEY\\"\]\.resume='
has "$GO_ON" 'LEGACY_SESSION'
# One sanitization rule, applied at every site that builds a session key.
has "$PAUSE" 'SESSION_ID//\[\^\[:alnum:\]_\.-\]'
has "$GO_ON" 'SESSION_ID//\[\^\[:alnum:\]_\.-\]'

has "$END_RESUME" 'execution-pause.sh --clear'
has "$PAUSE_RESUME" 'EXECUTION_PAUSE_SH.*clear --session'
has "$END_RESUME" 'unless --resume-refill'
has "$PAUSE_RESUME" 'only with --resume-refill'
has "$PAUSE_SCRIPT" 'end|pause'
has "$PM" 'rolling-window limit is temporary and auto-resuming'
has "$PM" 'execution-pause\.sh --activate --command pause --window-minutes 0'
has "$PM" 'Do not invoke the user-only `/end`'
has "$PM" 'execute `/end/SKILL\.md` Steps 0–6 inline'
has "$PM" '/end-resume --resume-refill'
has "$PAUSE_RESUME" 'stopped: true.*rearmed.*not'
has "$PAUSE_RESUME" '--status rearming --from-status stopped'
has "$PAUSE_RESUME" 'concurrent invocations single-writer'
has "$PAUSE" 'Immediate branch.*WINDOW_MINUTES == 0'
has "$PAUSE" 'MARKER_AUTO_DISCOVERABLE=false'
has "$PAUSE" 'Repository:.*exact owner/repo'
has "$PAUSE_RESUME" 'Repository:.*owner/repo'
has "$END_RESUME" '--from-status stopped'
has "$REGISTRY" 'rearming'
has "$END" 'portable-handoff-context\.sh'
has "$END" 'portable-handoff-publish\.sh'
has "$END" 'one deterministic filename'
has "$END" 'tracked and untracked'

# Behavioral smoke for the helper chain named by the /end workflow: collect
# exact dirty state, stage those bytes, and update one deterministic target.
TMP_HANDOFF=$(mktemp -d)
trap 'rm -rf "$TMP_HANDOFF"' EXIT
mkdir -p "$TMP_HANDOFF/home/.claude"
export HOME="$TMP_HANDOFF/home"
git init -q "$TMP_HANDOFF/repo"
git -C "$TMP_HANDOFF/repo" symbolic-ref HEAD refs/heads/main
git -C "$TMP_HANDOFF/repo" config user.email "test@example.com"
git -C "$TMP_HANDOFF/repo" config user.name "Test"
printf 'seed\n' >"$TMP_HANDOFF/repo/tracked.txt"
git -C "$TMP_HANDOFF/repo" add tracked.txt
git -C "$TMP_HANDOFF/repo" commit -qm seed
git -C "$TMP_HANDOFF/repo" remote add origin https://github.com/test/portable-stop.git
printf 'changed\n' >"$TMP_HANDOFF/repo/tracked.txt"
printf 'new\n' >"$TMP_HANDOFF/repo/untracked.txt"
CONTEXT_JSON=$("$HANDOFF_CONTEXT" --cwd "$TMP_HANDOFF/repo" --session contract --no-remote)
jq -e '
  .repository.identity == "test/portable-stop"
  and .working_copy.tracked_changes == ["tracked.txt"]
  and .working_copy.untracked_changes == ["untracked.txt"]
' <<<"$CONTEXT_JSON" >/dev/null || fail "portable handoff context did not preserve tracked and untracked state"
(cd "$TMP_HANDOFF/repo" && "$CHECKPOINT" --stdout --no-remote \
  --out-dir "$TMP_HANDOFF/checkpoint-out") >"$TMP_HANDOFF/staged.md"
PUBLISHED_ONE=$("$HANDOFF_PUBLISH" --input "$TMP_HANDOFF/staged.md" \
  --repo test/portable-stop --session contract --out-dir "$TMP_HANDOFF/out" \
  --lint "$HANDOFF_LINT" --lint-root "$ROOT")
PUBLISHED_TWO=$("$HANDOFF_PUBLISH" --input "$TMP_HANDOFF/staged.md" \
  --repo test/portable-stop --session contract --out-dir "$TMP_HANDOFF/out" \
  --lint "$HANDOFF_LINT" --lint-root "$ROOT")
[[ "$PUBLISHED_ONE" == "$PUBLISHED_TWO" ]] || fail "portable handoff publisher target is not deterministic"
cmp -s "$TMP_HANDOFF/staged.md" "$PUBLISHED_TWO" || fail "portable handoff publisher changed the staged bytes"

[[ ! -e "$ROOT/.claude/skills/suspend" ]] || fail "retired suspend skill still exists"
[[ ! -e "$ROOT/.claude/skills/suspend-resume" ]] || fail "retired suspend-resume skill still exists"
[[ -f "$ROOT/.claude/skills/end/SKILL.md" ]] || fail "end skill is missing"
[[ -f "$ROOT/.claude/skills/end-resume/SKILL.md" ]] || fail "end-resume skill is missing"
LEGACY_SKILL="$ROOT/.claude/skills/""stop"
LEGACY_RESUME_SKILL="${LEGACY_SKILL}-resume"
[[ ! -e "$LEGACY_SKILL" ]] || fail "retired long-cessation skill directory still exists"
[[ ! -e "$LEGACY_RESUME_SKILL" ]] || fail "retired long-cessation resume directory still exists"

LEGACY_COMMAND="/""stop"

# Portable retired-command scan (issue #1421). This block used to shell
# `rg --hidden ... | grep -Ev ... || true`. On a machine without ripgrep the
# pipeline died with 127, the substitution came back empty, the trailing
# `|| true` swallowed the failure, and the emptiness check below passed without
# a single file having been scanned — a guard reporting success precisely
# because it could not run. `grep -r` ships with every POSIX system, so the scan
# always runs here; a scan that genuinely cannot run fails closed instead.
#
# `--exclude-dir` stands in for the previous `!**/.git/**` and
# `!**/.claude/worktrees/**` globs (no tracked directory is named `worktrees`,
# and nested worktree checkouts are separate trees, not this repo's content).
# `-I` skips binaries so stray bytes in a generated artifact cannot masquerade
# as a source reference.
#
# Prints surviving matches and returns 0 when the scan ran; returns 2 when it
# could not run. It never returns an empty result for a scan that did not happen.
scan_legacy_command() {
  local target="$1" raw="" kept="" line="" probe="" residue="" rc=0
  raw=$(grep -rnFI --exclude-dir=.git --exclude-dir=worktrees \
    -e "$LEGACY_COMMAND" -- "$target") || rc=$?
  # 0 = matches, 1 = no matches; both mean the scan executed. 2+ is a scan error.
  (( rc <= 1 )) || return 2
  [[ -n "$raw" ]] || return 0
  # Compound forms carrying a pause/resume/re-arm/exit/widen prefix are ordinary
  # vocabulary, not references to the retired command. Filter per OCCURRENCE, not
  # per line: a `grep -Ev` drops the WHOLE line on a single compound match, so a
  # line carrying both `pause<cmd>` and a genuine bare `<cmd>` disappeared and the
  # guard passed despite the stale reference — the same vacuous-pass shape this
  # block exists to rule out. Strip the compound occurrences, then ask whether a
  # bare reference survives on that line; report the ORIGINAL line, not the residue.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    # `grep -rn` prefixes every hit with `<path>:<lineno>:`, and that path is the
    # ABSOLUTE one. Test the residue below the scan root only: a checkout sitting
    # under a directory named for the retired command (…<cmd>/repo) otherwise puts
    # the command in every hit's prefix and fails the guard on a clean tree. What
    # survives the strip is the repo-relative path plus content — and a
    # repo-relative path carrying the command IS content worth flagging.
    probe=${line#"$target"}
    # sed is the only command in this substitution, so its rc is read directly and
    # never after a pipe. A filter that cannot run fails closed; it never passes.
    residue=$(sed -E "s#(pause|resume|re-arm|exit|widen)${LEGACY_COMMAND}##g" <<<"$probe") \
      || return 2
    case "$residue" in
      *"$LEGACY_COMMAND"*) kept+="$line"$'\n' ;;
    esac
  done <<<"$raw"
  printf '%s' "$kept"
}

STALE_SCAN_RC=0
STALE_COMMANDS=$(scan_legacy_command "$ROOT") || STALE_SCAN_RC=$?
(( STALE_SCAN_RC == 0 )) || fail \
  "retired-command scan could not run over $ROOT (rc $STALE_SCAN_RC) — refusing to report success without having scanned"
if [[ -n "$STALE_COMMANDS" ]]; then
  printf '%s\n' "$STALE_COMMANDS"
  fail "retired project command remains referenced: $LEGACY_COMMAND"
fi

# Controls for the guard above: it must be able to FAIL, and it must say so when
# it cannot look. A scan that can only ever return "nothing found" is the vacuous
# pass this whole block exists to rule out (issue #1421).
SCAN_FIXTURE="$TMP_HANDOFF/scan-fixture"
mkdir -p "$SCAN_FIXTURE"

printf 'invoke %s here\n' "$LEGACY_COMMAND" >"$SCAN_FIXTURE/planted.txt"
PLANTED=$(scan_legacy_command "$SCAN_FIXTURE") \
  || fail "scan control: the scan could not run over its own fixture"
[[ -n "$PLANTED" ]] \
  || fail "scan control: a planted retired-command reference was not caught — the scan is not scanning"

printf 'pause%s and resume%s\n' "$LEGACY_COMMAND" "$LEGACY_COMMAND" >"$SCAN_FIXTURE/planted.txt"
COMPOUND=$(scan_legacy_command "$SCAN_FIXTURE") \
  || fail "scan control: the scan could not run over its own fixture"
[[ -z "$COMPOUND" ]] \
  || fail "scan control: legitimate compound forms were flagged as stale references"

# A compound form and a genuine bare reference on the SAME line. Whole-line
# filtering dropped this line and reported clean; the per-occurrence filter must
# still surface it, or the guard is maskable by one adjacent legitimate word.
printf 'pause%s and also invoke %s here\n' "$LEGACY_COMMAND" "$LEGACY_COMMAND" \
  >"$SCAN_FIXTURE/planted.txt"
MIXED=$(scan_legacy_command "$SCAN_FIXTURE") \
  || fail "scan control: the scan could not run over its own fixture"
[[ -n "$MIXED" ]] \
  || fail "scan control: a stale reference sharing a line with a compound form was masked by the filter"

# A checkout whose own absolute path carries the retired command. `grep -rn`
# stamps that path onto every hit, so testing the whole line flagged a clean tree.
# The scan root here sits UNDER a directory named for the command; the file below
# it holds only a legitimate compound form.
PATHY_ROOT="$TMP_HANDOFF/${LEGACY_COMMAND#/}/inner"
mkdir -p "$PATHY_ROOT"
printf 'pause%s only\n' "$LEGACY_COMMAND" >"$PATHY_ROOT/doc.txt"
PATHY=$(scan_legacy_command "$PATHY_ROOT") \
  || fail "scan control: the scan could not run over its path fixture"
[[ -z "$PATHY" ]] \
  || fail "scan control: a checkout path containing the retired command tripped the guard on a clean tree"

# …and the same root must still catch a genuine reference, so the prefix strip
# cannot be hiding real content along with the path.
printf 'invoke %s here\n' "$LEGACY_COMMAND" >"$PATHY_ROOT/doc.txt"
PATHY_REAL=$(scan_legacy_command "$PATHY_ROOT") \
  || fail "scan control: the scan could not run over its path fixture"
[[ -n "$PATHY_REAL" ]] \
  || fail "scan control: the scan-root prefix strip swallowed a genuine reference"

UNSCANNABLE_RC=0
scan_legacy_command "$SCAN_FIXTURE/no-such-target" >/dev/null 2>&1 || UNSCANNABLE_RC=$?
(( UNSCANNABLE_RC == 2 )) \
  || fail "scan control: an unscannable target returned $UNSCANNABLE_RC, not the fail-closed code 2"

DUPLICATE_NAMES=$(find "$ROOT/.claude/skills" -name SKILL.md -type f -exec \
  awk '/^name: / { print substr($0, 7); exit }' {} \; | sort | uniq -d)
[[ -z "$DUPLICATE_NAMES" ]] || fail "duplicate skill name(s): $DUPLICATE_NAMES"

for edge in 'A→A' 'A→B' 'B→B' 'B→C'; do has "$PHASES" "$edge"; done
has "$PHASES" 'execution-pause.sh --status'
has "$PHASES" 'refill.paused'

jq -e '
  .hooks.PreToolUse[] | select(.matcher == "Agent|Workflow|Monitor|Bash")
  | .hooks[] | select(.command | endswith("/pause-launch-gate.sh"))
' "$SETTINGS" >/dev/null || fail "PreToolUse pause launch gate is not registered"
jq -e '
  .hooks.SubagentStop[].hooks[]
  | select(.command | endswith("/background-task-complete.sh"))
' "$SETTINGS" >/dev/null || fail "SubagentStop registry completion hook is not registered"

echo "OK: end/pause command contract tests passed"
