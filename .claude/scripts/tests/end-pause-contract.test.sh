#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
END="$ROOT/.claude/skills/end/SKILL.md"
PAUSE="$ROOT/.claude/skills/pause/SKILL.md"
END_RESUME="$ROOT/.claude/skills/end-resume/SKILL.md"
PAUSE_RESUME="$ROOT/.claude/skills/pause-resume/SKILL.md"
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
has "$PAUSE" '\.repos\[.*\]\.pause='
has "$PAUSE_RESUME" 'STATE_KEY="suspend"'
has "$PAUSE_RESUME" 'handoffs/suspend-'
has "$PAUSE_RESUME" 'MARKER_NAME.*suspend-'
has "$PAUSE_RESUME" 'STATE_KEY="suspend"'
has "$PAUSE_RESUME" 'paused_at // \.suspended_at'

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
  local target="$1" raw="" kept="" rc=0
  raw=$(grep -rnFI --exclude-dir=.git --exclude-dir=worktrees \
    -e "$LEGACY_COMMAND" -- "$target") || rc=$?
  # 0 = matches, 1 = no matches; both mean the scan executed. 2+ is a scan error.
  (( rc <= 1 )) || return 2
  [[ -n "$raw" ]] || return 0
  # Compound forms carrying a pause/resume/re-arm/exit/widen prefix are ordinary
  # vocabulary, not references to the retired command. rc 1 here means every
  # line was filtered out — the success case; 2+ is a broken filter, not a pass.
  rc=0
  kept=$(grep -Ev "(pause|resume|re-arm|exit|widen)${LEGACY_COMMAND}" <<<"$raw") || rc=$?
  (( rc <= 1 )) || return 2
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
