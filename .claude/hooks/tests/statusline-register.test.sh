#!/usr/bin/env bash
# statusline-register.test.sh — Tests the statusLine sync in register-hooks.py (issue #779).
#
# statusLine is a top-level settings surface, not a hook event, so it gets its own
# suite: seeding, placeholder repair, user-customization preservation, the
# hands-off rule for someone else's status line, and --statusline-only isolation
# from hook registration. Plus the two wiring assertions that the surface is
# actually registered and actually resolved at install time.
#
# Offline: a temp HOME holds settings.json and a synthetic skills worktree
# provides the template. Nothing touches the real ~/.claude.
#
# Run from repo root: bash .claude/hooks/tests/statusline-register.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/.claude/hooks/register-hooks.py"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
SETTINGS="$HOME/.claude/settings.json"

PASS=0
FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
check_eq() { # expected actual label
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (expected: $1, got: $2)"; fi
}

# --------------------------------------------------------------------------
# Synthetic skills worktree: template + one hook + the statusline script.
# --------------------------------------------------------------------------
WT="$TMP/skills-worktree"
mkdir -p "$WT/.claude/hooks" "$WT/.claude/scripts"
printf '#!/bin/sh\nexit 0\n' > "$WT/.claude/hooks/demo-hook.sh"
printf '#!/bin/sh\necho line\n' > "$WT/.claude/scripts/statusline.sh"
chmod +x "$WT/.claude/hooks/demo-hook.sh" "$WT/.claude/scripts/statusline.sh"

PLACEHOLDER="/path/to/claude-code-config/.claude/scripts/statusline.sh"
RESOLVED="$WT/.claude/scripts/statusline.sh"

write_template() {
  jq -n --arg ph "$PLACEHOLDER" '{
    statusLine: {type:"command", command:$ph, padding:0, refreshInterval:10},
    hooks: {Stop: [{hooks: [{type:"command",
                             command:"/path/to/claude-code-config/.claude/hooks/demo-hook.sh",
                             timeout:5}]}]}
  }' > "$WT/global-settings.json"
}
write_template

write_settings() { printf '%s\n' "$1" > "$SETTINGS"; }
sl() { jq -r "$1" "$SETTINGS" 2>/dev/null; }
run_sut() { python3 "$SUT" "$@" >/dev/null 2>&1; }

# --------------------------------------------------------------------------
# 1. Seeding — no statusLine in live settings at all.
# --------------------------------------------------------------------------
write_settings '{"hooks":{}}'
run_sut --statusline-only "$WT"
check_eq 0 "$?" "seed: exit 0"
check_eq "$RESOLVED" "$(sl '.statusLine.command')" "seed: command resolved to the worktree path"
check_eq "command" "$(sl '.statusLine.type')" "seed: type carried from the template"
check_eq "10" "$(sl '.statusLine.refreshInterval')" "seed: refreshInterval carried from the template"
check_eq "0" "$(sl '.statusLine.padding')" "seed: padding carried from the template"

# --------------------------------------------------------------------------
# 2. Idempotent — a second run must not rewrite the file.
# --------------------------------------------------------------------------
BEFORE="$(cat "$SETTINGS")"
run_sut --statusline-only "$WT"
check_eq 0 "$?" "idempotent: exit 0 on a no-op run"
check_eq "$BEFORE" "$(cat "$SETTINGS")" "idempotent: settings.json byte-identical after a second run"

# --------------------------------------------------------------------------
# 3. Placeholder repair preserves the user's own sibling keys.
# --------------------------------------------------------------------------
write_settings "$(jq -n --arg ph "$PLACEHOLDER" '{hooks:{},
  statusLine:{type:"command", command:$ph, padding:2, refreshInterval:30}}')"
run_sut --statusline-only "$WT"
check_eq "$RESOLVED" "$(sl '.statusLine.command')" "repair: placeholder rewritten to the resolved path"
check_eq "2" "$(sl '.statusLine.padding')" "repair: user padding preserved"
check_eq "30" "$(sl '.statusLine.refreshInterval')" "repair: user refreshInterval preserved"

# A stale-but-absolute path from an earlier worktree location is repaired too.
write_settings "$(jq -n '{hooks:{},
  statusLine:{type:"command", command:"/old/location/.claude/scripts/statusline.sh"}}')"
run_sut --statusline-only "$WT"
check_eq "$RESOLVED" "$(sl '.statusLine.command')" "repair: stale absolute path rewritten"

# --------------------------------------------------------------------------
# 4. Someone else's status line is never touched.
# --------------------------------------------------------------------------
CUSTOM='/Users/someone/bin/my-own-statusline.sh'
write_settings "$(jq -n --arg c "$CUSTOM" '{hooks:{}, statusLine:{type:"command", command:$c}}')"
run_sut --statusline-only "$WT"
check_eq "$CUSTOM" "$(sl '.statusLine.command')" "custom status line: left untouched"

# A non-object statusLine is malformed user config — warn, do not overwrite.
write_settings '{"hooks":{},"statusLine":"not-an-object"}'
run_sut --statusline-only "$WT"
check_eq 0 "$?" "non-object statusLine: exit 0"
check_eq "not-an-object" "$(sl '.statusLine')" "non-object statusLine: left untouched"

# --------------------------------------------------------------------------
# 5. Missing script — skip with a warning rather than register a broken path.
# --------------------------------------------------------------------------
MISSING_WT="$TMP/missing-script-wt"
mkdir -p "$MISSING_WT/.claude/hooks" "$MISSING_WT/.claude/scripts"
cp "$WT/global-settings.json" "$MISSING_WT/global-settings.json"
write_settings '{"hooks":{}}'
run_sut --statusline-only "$MISSING_WT"
check_eq 0 "$?" "missing script: exit 0"
check_eq "null" "$(sl '.statusLine')" "missing script: no statusLine registered"

# --------------------------------------------------------------------------
# 6. --statusline-only must not register hooks.
# --------------------------------------------------------------------------
write_settings '{"hooks":{}}'
run_sut --statusline-only "$WT"
check_eq "0" "$(jq '[.hooks[]?] | length' "$SETTINGS")" "--statusline-only: no hook events registered"
check_eq "$RESOLVED" "$(sl '.statusLine.command')" "--statusline-only: statusLine still synced"

# --------------------------------------------------------------------------
# 7. Full mode does both.
# --------------------------------------------------------------------------
write_settings '{"hooks":{}}'
run_sut "$WT"
check_eq "$WT/.claude/hooks/demo-hook.sh" \
  "$(jq -r '.hooks.Stop[0].hooks[0].command' "$SETTINGS")" "full mode: hook registered"
check_eq "$RESOLVED" "$(sl '.statusLine.command')" "full mode: statusLine synced in the same run"

# A template with no statusLine key must still register hooks.
jq 'del(.statusLine)' "$WT/global-settings.json" > "$WT/global-settings.json.tmp"
mv "$WT/global-settings.json.tmp" "$WT/global-settings.json"
write_settings '{"hooks":{}}'
run_sut "$WT"
check_eq "$WT/.claude/hooks/demo-hook.sh" \
  "$(jq -r '.hooks.Stop[0].hooks[0].command' "$SETTINGS")" "template without statusLine: hooks still registered"
check_eq "null" "$(sl '.statusLine')" "template without statusLine: nothing invented"
write_template

# --------------------------------------------------------------------------
# 7b. A malformed live `hooks` section must not strand the statusLine surface.
# --------------------------------------------------------------------------
# session-start-sync.sh runs this script every session, and that run is the only
# recurring thing that ever repairs a statusLine path. Aborting on a bad `hooks`
# value would disable it for good, so hook work is skipped while the independent
# surface still syncs. The exit code must keep reporting the hooks failure, and
# the user's malformed value must survive byte-for-byte — it is not ours to
# "fix" by guessing.
write_settings '{"hooks":"not-an-object"}'
run_sut "$WT"; RC=$?
check_eq 1 "$RC" "malformed hooks: exit 1 still reports the hook failure"
check_eq "$RESOLVED" "$(sl '.statusLine.command')" "malformed hooks: statusLine still synced"
check_eq "not-an-object" "$(sl '.hooks')" "malformed hooks: user's value left untouched"

# A single malformed EVENT must not abort the run either — the same reasoning
# one level down. The other events still register and statusLine still syncs.
write_settings '{"hooks":{"Stop":"not-a-list"}}'
run_sut "$WT"; RC=$?
check_eq 1 "$RC" "malformed hooks event: exit 1 still reports the hook failure"
check_eq "$RESOLVED" "$(sl '.statusLine.command')" "malformed hooks event: statusLine still synced"
check_eq '"not-a-list"' "$(jq -c '.hooks.Stop' "$SETTINGS")" \
  "malformed hooks event: user's value left untouched"

# Same isolation under --statusline-only, where hooks are out of scope entirely.
# Their shape must not even colour the exit code: setup-skills-worktree.sh
# Step 6b reads any non-zero exit as "statusLine sync failed" and warns about a
# placeholder path that was in fact written correctly.
write_settings '{"hooks":[1,2,3]}'
run_sut --statusline-only "$WT"; RC=$?
check_eq 0 "$RC" "malformed hooks + --statusline-only: exit 0, hooks are out of scope"
check_eq "$RESOLVED" "$(sl '.statusLine.command')" \
  "malformed hooks + --statusline-only: statusLine still synced"
check_eq "[1,2,3]" "$(jq -c '.hooks' "$SETTINGS")" \
  "malformed hooks + --statusline-only: user's value left untouched"

# An unparseable settings.json is a different case and must still hard-stop:
# there is no safe write when the prior contents cannot be read back.
write_settings '{"hooks":'
run_sut --statusline-only "$WT"; RC=$?
check_eq 1 "$RC" "unparseable settings.json: exit 1, no write attempted"
check_eq '{"hooks":' "$(cat "$SETTINGS")" "unparseable settings.json: file left byte-identical"

# --------------------------------------------------------------------------
# 8. Wiring — the real repo must actually declare and resolve this surface.
# --------------------------------------------------------------------------
REAL_TEMPLATE="$REPO_ROOT/global-settings.json"
check_eq "$PLACEHOLDER" "$(jq -r '.statusLine.command' "$REAL_TEMPLATE")" \
  "wiring: global-settings.json registers statusline.sh with the placeholder path"
check_eq "command" "$(jq -r '.statusLine.type' "$REAL_TEMPLATE")" \
  "wiring: statusLine is a command-type entry"
# refreshInterval is in SECONDS and the harness clamps it to >= 1.
REFRESH="$(jq -r '.statusLine.refreshInterval' "$REAL_TEMPLATE")"
if [[ "$REFRESH" =~ ^[0-9]+$ ]] && (( REFRESH >= 1 )); then
  ok "wiring: refreshInterval is an integer >= 1 second"
else
  bad "wiring: refreshInterval is an integer >= 1 second (got: $REFRESH)"
fi

if grep -q -- '--statusline-only' "$REPO_ROOT/setup-skills-worktree.sh"; then
  ok "wiring: setup-skills-worktree.sh resolves the statusLine path at install time"
else
  bad "wiring: setup-skills-worktree.sh resolves the statusLine path at install time"
fi

# setup.sh's generic top-level merge must NOT seed statusLine: it would copy the
# placeholder path verbatim, and the skills worktree is pinned to origin/main, so
# a statusline.sh still on a feature branch cannot be resolved afterwards — the
# placeholder would survive in settings.json and break
# tests/test-setup.sh's "No placeholder paths" invariant. Registration owns it.
if grep -qE '^SKIP_KEYS = \{.*"statusLine".*\}' "$REPO_ROOT/setup.sh"; then
  ok "wiring: setup.sh skips statusLine in its generic merge (no unresolvable placeholder)"
else
  bad "wiring: setup.sh skips statusLine in its generic merge (no unresolvable placeholder)"
fi

if [[ -x "$REPO_ROOT/.claude/scripts/statusline.sh" ]]; then
  ok "wiring: statusline.sh is committed executable"
else
  bad "wiring: statusline.sh is committed executable"
fi

echo "----------------------------------------"
echo "statusline-register.test.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
