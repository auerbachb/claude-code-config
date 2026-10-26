#!/usr/bin/env bash
# ai-quotas-share.test.sh — coverage for the `launchers` and `share-config`
# actions of .claude/scripts/ai-quotas-setup.sh (issue #1851).
# catalog: tests — Tests the `launchers` and `share-config` actions of `ai-quotas-setup.sh` against a fake registry and a fake HOME — one zsh function per claude/codex account named from the nickname, resolution of the profile directory BY LABEL through `list --json` (asserted on a registry whose directories are named backwards, the #1850 shape, and exercised under a real zsh with stub `claude`/`codex` binaries), the tab-title escape, the collision refusal, the `source` line with `~/.zshrc` left untouched, the hand-written file moved to `.pre-share` and a generated one overwritten in place; and for share-config the symlinks, the settings/config copies, the `mcpServers` merge that keeps the profile's own fields, idempotent re-runs, `.pre-share` keepsakes, the skipped-when-primary-missing items, the self-share and cursor refusals, and the leak assertion that no fixture credential reaches any output or generated file
#
# WHAT IS UNDER TEST
#
# Two things the registry alone does not give the owner: a way to START a
# provider CLI against one account's profile, and a profile that behaves like
# the primary install. The properties that matter: the launcher never builds a
# path out of the label (the real directories are named backwards — #1850), a
# re-run changes nothing, nothing in the way is ever deleted, and no
# credential is read or printed.
#
# EVERYTHING IS A FAKE. HOME, the config, the profile root, the launchers
# path, and the primary install are all redirected into a temp tree. The
# profiles carry credential-SHAPED fixtures (`.credentials.json`, `auth.json`
# holding a known fake token) so the leak assertion is a real detector: an
# action that copied or printed one would fail it.
#
# Run from anywhere: bash .claude/scripts/tests/ai-quotas-share.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/ai-quotas-setup.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
[[ -x "$SCRIPT" ]] || { echo "FAIL — $SCRIPT is not executable"; exit 1; }

ZSH_BIN="$(command -v zsh 2>/dev/null || true)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAILED=0
ok()  { PASS=$((PASS + 1)); echo "ok   — $*"; }
bad() { FAILED=$((FAILED + 1)); echo "FAIL — $*" >&2; }

check_eq() { # <actual> <expected> <label>
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi
}
check_contains() { # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) bad "$3 (output did not contain '$2')" ;;
  esac
}
check_not_contains() { # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) bad "$3 (output unexpectedly contained '$2')" ;;
    *) ok "$3" ;;
  esac
}

FIXTURE_SECRET="FAKE-CRED-VALUE-7B3A9C"
ALL_OUTPUT="$TMP/all-output.log"
: > "$ALL_OUTPUT"

# --- harness -----------------------------------------------------------------
# One fake machine per case: a HOME with a primary ~/.claude and ~/.codex, a
# registry whose claude directories are named BACKWARDS against their labels
# (the real registry's shape, #1850), and a credential-shaped fixture in every
# profile.

WORK_LABEL="work@example.com"
PERSONAL_LABEL="personal@example.com"
LM_LABEL="lm@example.com"

new_case() { # <name>
  CASE_DIR="$TMP/case-$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-')"
  rm -rf "$CASE_DIR"
  FAKE_HOME="$CASE_DIR/home"
  CONFIG="$CASE_DIR/ai-quotas.json"
  PROFILES="$CASE_DIR/profiles"
  LAUNCHERS="$FAKE_HOME/.claude/ai-quotas/launchers.zsh"
  PRIMARY="$FAKE_HOME/.claude"
  PRIMARY_JSON="$FAKE_HOME/.claude.json"
  CODEX_PRIMARY="$FAKE_HOME/.codex"
  mkdir -p "$PRIMARY"/{skills,agents,rules,hooks,plugins,projects} "$CODEX_PRIMARY/rules"
  echo "primary CLAUDE.md" > "$PRIMARY/CLAUDE.md"
  echo "primary account-config" > "$PRIMARY/account-config.md"
  printf '{"theme":"dark","model":"opus"}\n' > "$PRIMARY/settings.json"
  chmod 600 "$PRIMARY/settings.json"
  printf '{"userID":"primary-user","oauthAccount":{"emailAddress":"primary@example.com"},"mcpServers":{"alpha":{"command":"alpha-mcp","env":{"ALPHA_KEY":"primary-alpha"}},"beta":{"command":"beta-mcp"}},"projects":{"/primary":{}}}\n' > "$PRIMARY_JSON"
  chmod 600 "$PRIMARY_JSON"
  printf 'model = "primary-model"\n' > "$CODEX_PRIMARY/config.toml"
  echo "primary codex rule" > "$CODEX_PRIMARY/rules/one.md"
  printf '# fake zshrc\nexport ZSHRC_UNTOUCHED=1\n' > "$FAKE_HOME/.zshrc"
  cp "$FAKE_HOME/.zshrc" "$CASE_DIR/zshrc.before"

  # Backwards on purpose: the WORK label lives in the directory named after
  # the PERSONAL label and vice versa. A launcher that built the path from the
  # label would start the wrong account and this suite would catch it.
  WORK_DIR="$PROFILES/$PERSONAL_LABEL/claude"
  PERSONAL_DIR="$PROFILES/$WORK_LABEL/claude"
  CODEX_PERSONAL_DIR="$PROFILES/$PERSONAL_LABEL/codex"
  CODEX_LM_DIR="$PROFILES/$LM_LABEL/codex"
  mkdir -p "$WORK_DIR" "$PERSONAL_DIR" "$CODEX_PERSONAL_DIR" "$CODEX_LM_DIR"
  local d
  for d in "$WORK_DIR" "$PERSONAL_DIR"; do
    printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$FIXTURE_SECRET" > "$d/.credentials.json"
    chmod 600 "$d/.credentials.json"
  done
  for d in "$CODEX_PERSONAL_DIR" "$CODEX_LM_DIR"; do
    printf '{"tokens":{"access_token":"%s"}}\n' "$FIXTURE_SECRET" > "$d/auth.json"
    chmod 600 "$d/auth.json"
  done
  write_registry
}

# The default registry: four launchable accounts plus the cursor row.
write_registry() {
  jq -n --arg w "$WORK_LABEL" --arg p "$PERSONAL_LABEL" --arg l "$LM_LABEL" \
     --arg wd "$WORK_DIR" --arg pd "$PERSONAL_DIR" --arg cpd "$CODEX_PERSONAL_DIR" --arg cld "$CODEX_LM_DIR" \
     --arg cur "$PROFILES/cursor-x/cursor" '
    {schema_version: "1.0", accounts: [
      {provider: "codex",  label: $l, nickname: "GPT LM",          profile_dir: $cld, added_at: "2026-09-10T15:00:00Z"},
      {provider: "codex",  label: $p, nickname: "GPT Personal",    profile_dir: $cpd, added_at: "2026-09-10T15:12:00Z"},
      {provider: "claude", label: $w, nickname: "Claude Work",     profile_dir: $wd,  added_at: "2026-09-10T15:27:00Z"},
      {provider: "claude", label: $p, nickname: "Claude Personal", profile_dir: $pd,  added_at: "2026-09-10T15:27:01Z"},
      {provider: "cursor", label: "cursor-x", nickname: "Cursor",  profile_dir: $cur, added_at: "2026-09-10T15:48:00Z"}
    ]}' > "$CONFIG"
  chmod 600 "$CONFIG"
}

set_nickname() { # <label> <provider> <nickname|null>
  local tmp="$CONFIG.tmp"
  if [[ "$3" == "null" ]]; then
    jq --arg l "$1" --arg p "$2" '.accounts |= map(if .label == $l and .provider == $p then del(.nickname) else . end)' "$CONFIG" > "$tmp"
  else
    jq --arg l "$1" --arg p "$2" --arg n "$3" '.accounts |= map(if .label == $l and .provider == $p then .nickname = $n else . end)' "$CONFIG" > "$tmp"
  fi
  mv "$tmp" "$CONFIG"
}

OUT=""
RC=0
run() { # <args...> — never aborts the suite; sets OUT and RC
  OUT="$(HOME="$FAKE_HOME" \
        AI_QUOTAS_CONFIG="$CONFIG" \
        AI_QUOTAS_PROFILE_ROOT="$PROFILES" \
        AI_QUOTAS_PLATFORM="Linux" \
        "$SCRIPT" "$@" 2>&1)"
  RC=$?
  printf '%s\n' "$OUT" >> "$ALL_OUTPUT"
}

# Runs a launcher function under a real zsh with stub `claude`/`codex` CLIs
# that print the profile env var they received. HOME is the fake one, so the
# resolver's two durable candidates are absent and it falls through to the
# generating script — unless a case plants a stub at one of them.
STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
printf '#!/bin/sh\nprintf "STUB-CLAUDE dir=%%s args=%%s\\n" "${CLAUDE_CONFIG_DIR:-<unset>}" "$*"\n' > "$STUB_BIN/claude"
printf '#!/bin/sh\nprintf "STUB-CODEX dir=%%s args=%%s\\n" "${CODEX_HOME:-<unset>}" "$*"\n' > "$STUB_BIN/codex"
chmod +x "$STUB_BIN/claude" "$STUB_BIN/codex"

ZOUT=""
ZRC=0
run_launcher() { # <zsh snippet>
  ZOUT="$(HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" \
         AI_QUOTAS_CONFIG="$CONFIG" AI_QUOTAS_PROFILE_ROOT="$PROFILES" AI_QUOTAS_PLATFORM="Linux" \
         "$ZSH_BIN" -c "source '$LAUNCHERS'; $1" 2>&1)"
  ZRC=$?
  printf '%s\n' "$ZOUT" >> "$ALL_OUTPUT"
}

# Launcher names only — the two `_ai_` helpers are asserted separately.
function_names() { grep -oE '^[a-z0-9-]+\(\)' "$LAUNCHERS" | tr -d '()' | tr '\n' ' ' | sed 's/ $//'; }
helper_names() { grep -oE '^_ai_[a-z_]+\(\)' "$LAUNCHERS" | tr -d '()' | tr '\n' ' ' | sed 's/ $//'; }
zshrc_untouched() { cmp -s "$FAKE_HOME/.zshrc" "$CASE_DIR/zshrc.before" && echo untouched || echo CHANGED; }
link_target() { readlink "$1" 2>/dev/null || echo "<not-a-link>"; }
count_pre_share() { find "$1" -maxdepth 1 -name '*.pre-share*' | wc -l | tr -d ' '; }

echo "== ai-quotas-setup.sh launchers / share-config =="

# --- 1. usage ----------------------------------------------------------------

new_case "usage"
run launchers extra
check_eq "$RC" "3" "launchers takes no arguments"
run share-config
check_eq "$RC" "3" "share-config requires a label"
run share-config a b c
check_eq "$RC" "3" "share-config takes at most <label> <provider>"
run launchers --json
check_eq "$RC" "3" "--json applies to list only, launchers included"
run --help
check_contains "$OUT" "launchers" "--help documents launchers"
check_contains "$OUT" "share-config" "--help documents share-config"

# --- 2. launchers: the file, its names, and its resolution ------------------

new_case "launchers-basic"
run launchers
check_eq "$RC" "0" "launchers exits 0"
check_eq "$(test -f "$LAUNCHERS" && echo present || echo absent)" "present" "the launchers file was written"
check_eq "$(helper_names)" "_ai_profile_dir _ai_launch" "the two resolver/launch helpers are defined"
check_eq "$(function_names)" "claude-work claude-personal codex-lm codex-personal" \
  "one function per claude/codex account, claude first then codex, named <provider>-<nickname slug> with the provider word dropped"
check_contains "$OUT" "4 launcher(s): claude-work claude-personal codex-lm codex-personal" "the summary names them in file order"
check_contains "$OUT" "skipped cursor 'cursor-x'" "the cursor account is skipped with a note"
check_contains "$OUT" "never edits it" "the source line is printed with the never-edits note"
check_contains "$OUT" "source \"\$HOME/.claude/ai-quotas/launchers.zsh\"" "the source line uses \$HOME for a file under HOME"
check_eq "$(zshrc_untouched)" "untouched" "the .zshrc under HOME was not edited"
check_contains "$(cat "$LAUNCHERS")" "list --json" "the resolver asks the registry through list --json"
check_contains "$(cat "$LAUNCHERS")" 'select(.provider == $p and .label == $l) | .profile_dir' "and selects profile_dir by provider and label"
check_contains "$(cat "$LAUNCHERS")" 'CLAUDE_CONFIG_DIR="$dir" command claude "$@"' "claude launches with CLAUDE_CONFIG_DIR set to the resolved dir"
check_contains "$(cat "$LAUNCHERS")" 'CODEX_HOME="$dir" command codex "$@"' "codex launches with CODEX_HOME set to the resolved dir"
check_contains "$(cat "$LAUNCHERS")" "_ai_launch claude '$WORK_LABEL' 'Claude Work'" "the work launcher passes its label and nickname"
check_not_contains "$(cat "$LAUNCHERS")" "$PROFILES" "no profile directory is baked into the file — it is resolved at run time"
check_eq "$(stat -f '%Lp' "$LAUNCHERS" 2>/dev/null || stat -c '%a' "$LAUNCHERS")" "600" "the file is mode 600, like the registry whose labels it carries"
check_contains "$(cat "$LAUNCHERS")" "[[ -t 1 ]] && printf '\\e]1;%s\\a\\e]2;%s\\a' \"\$nick\" \"\$nick\"" "the title escape is guarded on stdout being a terminal"
check_not_contains "$(cat "$LAUNCHERS")" "$(date -u +%Y-%m-%d)" "no timestamp in the file — a re-run over the same registry is byte-identical"
cp "$LAUNCHERS" "$CASE_DIR/launchers.first"
run launchers
check_eq "$(cmp -s "$LAUNCHERS" "$CASE_DIR/launchers.first" && echo identical || echo DIFFERENT)" "identical" "and it is"

if [[ -n "$ZSH_BIN" ]]; then
  check_eq "$("$ZSH_BIN" -n "$LAUNCHERS" >/dev/null 2>&1 && echo parses || echo SYNTAX-ERROR)" "parses" "the file parses under zsh"
  run_launcher "claude-work --flag one"
  check_eq "$ZRC" "0" "claude-work runs"
  check_contains "$ZOUT" "STUB-CLAUDE dir=$WORK_DIR args=--flag one" \
    "claude-work resolves the WORK label to the directory named after the PERSONAL label (by label, not by path) and forwards its args"
  check_not_contains "$ZOUT" $'\e]1;' "with stdout a pipe, no title escape is emitted into it"
  # The title path needs a real terminal on stdout; python's pty module gives
  # one on macOS and Linux alike. Skipped, with a line, where python3 is absent.
  if command -v python3 >/dev/null 2>&1; then
    PTY_OUT="$(HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" \
      AI_QUOTAS_CONFIG="$CONFIG" AI_QUOTAS_PROFILE_ROOT="$PROFILES" AI_QUOTAS_PLATFORM="Linux" \
      python3 -I -c '
import os, pty, sys
buf = bytearray()
def reader(fd):
    data = os.read(fd, 4096)
    buf.extend(data)
    return data
pty.spawn([sys.argv[1], "-c", sys.argv[2]], reader)
sys.stdout.buffer.write(bytes(buf))
' "$ZSH_BIN" "source '$LAUNCHERS'; claude-work" 2>/dev/null | cat -v)"
    check_contains "$PTY_OUT" '^[]1;Claude Work^G^[]2;Claude Work^G' "with stdout a terminal, the tab and window title are set to the nickname first"
    check_contains "$PTY_OUT" "STUB-CLAUDE dir=" "and the CLI still launches"
  else
    echo "skip — python3 not installed; the terminal-title case did not execute"
  fi
  run_launcher "claude-personal"
  check_contains "$ZOUT" "STUB-CLAUDE dir=$PERSONAL_DIR args=" "claude-personal resolves to the other backwards-named directory"
  run_launcher "codex-personal --model x"
  check_contains "$ZOUT" "STUB-CODEX dir=$CODEX_PERSONAL_DIR args=--model x" "codex-personal sets CODEX_HOME"
  run_launcher "codex-lm"
  check_contains "$ZOUT" "STUB-CODEX dir=$CODEX_LM_DIR args=" "codex-lm sets CODEX_HOME"

  # A planted stub at the durable ~/.claude/scripts location wins over the
  # generating script, which is the order the file promises.
  mkdir -p "$FAKE_HOME/.claude/scripts"
  printf '#!/bin/sh\nprintf %%s '"'"'[{"provider":"claude","label":"%s","profile_dir":"%s"}]'"'"'\n' "$WORK_LABEL" "$CODEX_LM_DIR" > "$FAKE_HOME/.claude/scripts/ai-quotas-setup.sh"
  chmod +x "$FAKE_HOME/.claude/scripts/ai-quotas-setup.sh"
  run_launcher "claude-work"
  check_contains "$ZOUT" "STUB-CLAUDE dir=$CODEX_LM_DIR" "the resolver prefers ~/.claude/scripts/ai-quotas-setup.sh over the generating script"
  rm -rf "$FAKE_HOME/.claude/scripts"

  # The registry row goes away: the launcher refuses instead of guessing.
  jq '.accounts |= map(select(.label != "'"$WORK_LABEL"'" or .provider != "claude"))' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  run_launcher "claude-work"
  check_eq "$ZRC" "1" "a launcher whose account was removed returns 1"
  check_contains "$ZOUT" "no claude profile registered for $WORK_LABEL" "and says which account is missing"
  check_not_contains "$ZOUT" "STUB-CLAUDE" "control(-): nothing was launched"
else
  echo "skip — zsh not installed; the run-under-zsh cases did not execute"
fi

# --- 3. launchers: naming rules ---------------------------------------------

new_case "launchers-naming"
set_nickname "$WORK_LABEL" claude null
set_nickname "$PERSONAL_LABEL" codex "Codex"
set_nickname "$LM_LABEL" codex "O'Brien & Co. (LM)"
run launchers
check_eq "$RC" "0" "naming case exits 0"
check_eq "$(function_names)" "claude-work claude-personal codex-o-brien-co-lm codex-personal" \
  "no nickname falls back to the label's local part; a nickname that is only the provider word does too; punctuation collapses to dashes"
check_contains "$(cat "$LAUNCHERS")" "'O'\\''Brien & Co. (LM)'" "an apostrophe in a nickname is escaped for zsh"
check_contains "$(cat "$LAUNCHERS")" "_ai_launch claude '$WORK_LABEL' 'claude-work'" "with no nickname the tab title falls back to the function name"
if [[ -n "$ZSH_BIN" ]]; then
  check_eq "$("$ZSH_BIN" -n "$LAUNCHERS" >/dev/null 2>&1 && echo parses || echo SYNTAX-ERROR)" "parses" "the escaped file still parses under zsh"
  run_launcher "codex-o-brien-co-lm"
  check_contains "$ZOUT" "STUB-CODEX dir=$CODEX_LM_DIR" "and the escaped function launches"
  check_contains "$(cat "$LAUNCHERS")" "_ai_launch codex '$LM_LABEL' 'O'\\''Brien & Co. (LM)'" "carrying the apostrophe as the title argument"
fi

new_case "launchers-duplicate-row"
jq '.accounts += [.accounts[2] | .nickname = "Claude Again"]' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run launchers
check_eq "$RC" "3" "a (provider, label) pair registered twice is refused"
check_contains "$OUT" "holds claude '$WORK_LABEL' twice" "naming the pair"
check_eq "$(test -e "$LAUNCHERS" && echo present || echo absent)" "absent" "control(-): nothing was written"

new_case "launchers-collision"
set_nickname "$PERSONAL_LABEL" claude "Work"
run launchers
check_eq "$RC" "3" "two accounts that would both define claude-work are refused"
check_contains "$OUT" "launcher name 'claude-work' would be defined by both" "naming the collision"
check_contains "$OUT" "$WORK_LABEL" "and the first account"
check_contains "$OUT" "$PERSONAL_LABEL" "and the second"
check_eq "$(test -e "$LAUNCHERS" && echo present || echo absent)" "absent" "control(-): nothing was written"

new_case "launchers-empty"
jq '.accounts |= map(select(.provider == "cursor"))' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run launchers
check_eq "$RC" "0" "a registry with only a cursor account still exits 0"
check_eq "$(helper_names)" "_ai_profile_dir _ai_launch" "and writes the helpers"
check_eq "$(function_names)" "" "with no launchers"
check_contains "$OUT" "0 launcher(s)" "saying so"

# --- 4. launchers: what is already there --------------------------------------

new_case "launchers-pre-existing"
mkdir -p "$(dirname "$LAUNCHERS")"
printf '# hand-written launchers\nclaude-work() { echo hand; }\n' > "$LAUNCHERS"
run launchers
check_eq "$RC" "0" "a hand-written file in the way does not fail the run"
check_eq "$(cat "$LAUNCHERS.pre-share")" $'# hand-written launchers\nclaude-work() { echo hand; }' "it was moved aside as launchers.zsh.pre-share, byte for byte"
check_contains "$OUT" "moved the previous launchers.zsh aside to launchers.zsh.pre-share" "and the move is reported"
check_eq "$(function_names)" "claude-work claude-personal codex-lm codex-personal" "the generated file took its place"
run launchers
check_eq "$RC" "0" "a second run exits 0"
check_eq "$(count_pre_share "$(dirname "$LAUNCHERS")")" "1" "a generated file is overwritten in place — no second keepsake"
check_not_contains "$OUT" "moved the previous" "and no move is reported"
printf '# another hand-written file\n' > "$LAUNCHERS"
run launchers
check_eq "$(count_pre_share "$(dirname "$LAUNCHERS")")" "2" "a second foreign file gets a timestamped keepsake when .pre-share is taken"
check_eq "$(test -f "$LAUNCHERS.pre-share" && grep -c 'hand-written launchers' "$LAUNCHERS.pre-share")" "1" "and the first keepsake is untouched"

# An override path a shell would expand inside double quotes must reach the
# printed source line single-quoted, or pasting it into ~/.zshrc runs it.
new_case "launchers-source-line-hostile-path"
HOSTILE_DIR="$FAKE_HOME/we\"ird\$(touch \"$CASE_DIR/pwned\")\`id\`"
mkdir -p "$HOSTILE_DIR"
NOHOME_OUT="$(HOME="$FAKE_HOME" AI_QUOTAS_CONFIG="$CONFIG" AI_QUOTAS_PROFILE_ROOT="$PROFILES" AI_QUOTAS_PLATFORM=Linux \
  AI_QUOTAS_LAUNCHERS_FILE="$HOSTILE_DIR/l.zsh" "$SCRIPT" launchers 2>&1)" && NOHOME_RC=0 || NOHOME_RC=$?
printf '%s\n' "$NOHOME_OUT" >> "$ALL_OUTPUT"
check_eq "$NOHOME_RC" "0" "a hostile override path still generates"
SOURCE_LINE="$(printf '%s\n' "$NOHOME_OUT" | grep '&& source ' | sed 's/^  //')"
check_contains "$SOURCE_LINE" "source '$HOSTILE_DIR/l.zsh'" "the source line single-quotes a path with \$( ), backticks, or quotes in it"
check_not_contains "$SOURCE_LINE" '"$HOME/' "and does not use the \$HOME form for it"
if [[ -n "$ZSH_BIN" ]]; then
  HOME="$FAKE_HOME" "$ZSH_BIN" -c "$SOURCE_LINE; whence -w claude-work" > "$CASE_DIR/sourced.out" 2>&1
  check_contains "$(cat "$CASE_DIR/sourced.out")" "claude-work: function" "pasting the printed line sources the file"
  check_eq "$(test -e "$CASE_DIR/pwned" && echo RAN || echo inert)" "inert" "and the \$( ) in the path did not run"
fi

new_case "launchers-home-unset"
NOHOME_OUT="$(env -u HOME AI_QUOTAS_CONFIG="$CONFIG" AI_QUOTAS_PROFILE_ROOT="$PROFILES" AI_QUOTAS_PLATFORM=Linux "$SCRIPT" launchers 2>&1)" && NOHOME_RC=0 || NOHOME_RC=$?
check_eq "$NOHOME_RC" "5" "launchers with HOME unset and no override is refused"
check_contains "$NOHOME_OUT" "AI_QUOTAS_LAUNCHERS_FILE" "naming the override that lifts it"
NOHOME_OUT="$(env -u HOME AI_QUOTAS_CONFIG="$CONFIG" AI_QUOTAS_PROFILE_ROOT="$PROFILES" AI_QUOTAS_PLATFORM=Linux AI_QUOTAS_LAUNCHERS_FILE="$CASE_DIR/elsewhere/l.zsh" "$SCRIPT" launchers 2>&1)" && NOHOME_RC=0 || NOHOME_RC=$?
check_eq "$NOHOME_RC" "0" "with the override it runs HOME-less"
check_contains "$NOHOME_OUT" "source '$CASE_DIR/elsewhere/l.zsh'" "and prints the literal path, single-quoted, in the source line"
printf '%s\n' "$NOHOME_OUT" >> "$ALL_OUTPUT"

# --- 5. share-config: a claude profile ---------------------------------------

new_case "share-claude"
# Things in the way: a plugins dir of the profile's own, a settings file that
# differs, a .claude.json with login fields and one MCP server of its own.
mkdir -p "$WORK_DIR/plugins/own"
printf '{"theme":"light"}\n' > "$WORK_DIR/settings.json"
printf '{"userID":"work-user","oauthAccount":{"emailAddress":"%s"},"hasCompletedOnboarding":true,"mcpServers":{"local":{"command":"local-mcp"},"alpha":{"command":"old-alpha"}}}\n' "$WORK_LABEL" > "$WORK_DIR/.claude.json"
chmod 600 "$WORK_DIR/.claude.json"
run share-config "$WORK_LABEL" claude
check_eq "$RC" "0" "share-config on a claude profile exits 0"
check_contains "$OUT" "share-config claude '$WORK_LABEL' ($WORK_DIR) from $PRIMARY" "the header names the profile and the primary"
for name in skills agents rules hooks plugins projects CLAUDE.md account-config.md; do
  check_eq "$(link_target "$WORK_DIR/$name")" "$PRIMARY/$name" "$name is a symlink to the primary $name"
done
check_eq "$(test -d "$WORK_DIR/plugins.pre-share/own" && echo kept || echo LOST)" "kept" "the profile's own plugins dir was moved aside, not deleted"
check_eq "$(cat "$WORK_DIR/settings.json")" '{"theme":"dark","model":"opus"}' "settings.json is a copy of the primary"
check_eq "$(test -L "$WORK_DIR/settings.json" && echo link || echo file)" "file" "a copy, not a link"
check_eq "$(stat -f '%Lp' "$WORK_DIR/settings.json" 2>/dev/null || stat -c '%a' "$WORK_DIR/settings.json")" "600" "carrying the primary's 600 mode"
check_eq "$(cat "$WORK_DIR/settings.json.pre-share")" '{"theme":"light"}' "the old settings.json is the keepsake"
check_eq "$(jq -r '.oauthAccount.emailAddress' "$WORK_DIR/.claude.json")" "$WORK_LABEL" ".claude.json keeps the profile's own login field"
check_eq "$(jq -r '.userID' "$WORK_DIR/.claude.json")" "work-user" "and its own userID — nothing of the primary's identity came across"
check_eq "$(jq -r '.hasCompletedOnboarding' "$WORK_DIR/.claude.json")" "true" "and its onboarding state"
check_eq "$(jq -r '.mcpServers | keys | join(",")' "$WORK_DIR/.claude.json")" "alpha,beta,local" "mcpServers is the union of the profile's own and the primary's"
check_eq "$(jq -r '.mcpServers.alpha.command' "$WORK_DIR/.claude.json")" "alpha-mcp" "the primary wins on a shared server name"
check_eq "$(jq -r 'has("projects")' "$WORK_DIR/.claude.json")" "false" "the primary's other keys (projects) did not come across"
check_eq "$(jq -r '.mcpServers.alpha' "$WORK_DIR/.claude.json.pre-share" | jq -r .command)" "old-alpha" "the old .claude.json is the keepsake"
check_eq "$(stat -f '%Lp' "$WORK_DIR/.claude.json" 2>/dev/null || stat -c '%a' "$WORK_DIR/.claude.json")" "600" "the merged file keeps the profile file's mode"
check_contains "$OUT" "merged  2 primary mcpServers into .claude.json" "the merge reports a count"
check_not_contains "$OUT" "alpha-mcp" "and never an entry"
check_not_contains "$OUT" "primary-alpha" "nor an env value"
check_contains "$OUT" "linked 8, copied 1, merged 1, kept 0, moved aside 3, skipped 0" "the summary adds up"
check_contains "$OUT" "Nothing was deleted" "and says nothing was deleted"
check_eq "$(cat "$WORK_DIR/.credentials.json")" "{\"claudeAiOauth\":{\"accessToken\":\"$FIXTURE_SECRET\"}}" "the profile's credential file is untouched"
# script-usage.log is the script's own telemetry line, written under HOME on every run.
primary_listing() { local f out=""; for f in "$PRIMARY"/*; do f="$(basename "$f")"; [[ "$f" == script-usage.log ]] || out+="$f "; done; printf '%s' "$out"; }
check_eq "$(primary_listing)" "CLAUDE.md account-config.md agents hooks plugins projects rules settings.json skills " "the primary install is untouched"

run share-config "$WORK_LABEL" claude
check_eq "$RC" "0" "a second run exits 0"
check_contains "$OUT" "linked 0, copied 0, merged 0, kept 10, moved aside 0, skipped 0" "and changes nothing — every item is kept"
check_eq "$(count_pre_share "$WORK_DIR")" "3" "no new keepsakes on the re-run"

# A link pointing somewhere else is a thing in the way too.
rm "$WORK_DIR/skills"; ln -s "$CASE_DIR/elsewhere" "$WORK_DIR/skills"
run share-config "$WORK_LABEL" claude
check_eq "$(link_target "$WORK_DIR/skills")" "$PRIMARY/skills" "a symlink to the wrong place is replaced"
check_eq "$(link_target "$WORK_DIR/skills.pre-share")" "$CASE_DIR/elsewhere" "and kept as a keepsake link"

# The label is enough when it names one account.
new_case "share-claude-by-label-only"
run share-config "$WORK_LABEL"
check_eq "$RC" "0" "an unambiguous label needs no provider"
run share-config "$PERSONAL_LABEL"
check_eq "$RC" "3" "a label under two providers must name one"
run share-config "nobody@example.com"
check_eq "$RC" "4" "an unknown label is exit 4"

# --- 6. share-config: a codex profile ----------------------------------------

new_case "share-codex"
printf 'model = "old"\n' > "$CODEX_LM_DIR/config.toml"
run share-config "$LM_LABEL" codex
check_eq "$RC" "0" "share-config on a codex profile exits 0"
check_eq "$(link_target "$CODEX_LM_DIR/rules")" "$CODEX_PRIMARY/rules" "rules is a symlink to the primary CODEX_HOME rules"
check_eq "$(cat "$CODEX_LM_DIR/config.toml")" 'model = "primary-model"' "config.toml is a copy of the primary"
check_eq "$(cat "$CODEX_LM_DIR/config.toml.pre-share")" 'model = "old"' "the old config.toml is the keepsake"
check_eq "$(test -e "$CODEX_LM_DIR/skills" -o -L "$CODEX_LM_DIR/skills" && echo present || echo absent)" "absent" "no claude item was created in a codex profile"
check_contains "$OUT" "linked 1, copied 1, merged 0, kept 0, moved aside 1, skipped 0" "the codex summary adds up"
check_eq "$(cat "$CODEX_LM_DIR/auth.json")" "{\"tokens\":{\"access_token\":\"$FIXTURE_SECRET\"}}" "auth.json is untouched"
run share-config "$LM_LABEL" codex
check_contains "$OUT" "kept 2, moved aside 0" "and a re-run keeps both"

# --- 7. share-config: refusals and skips --------------------------------------

new_case "share-refusals"
run share-config cursor-x
check_eq "$RC" "3" "a cursor account is refused"
check_contains "$OUT" "Cursor IDE holds that login" "saying why"

# The one way to wreck the primary install: a profile_dir that IS it.
jq --arg d "$PRIMARY" '.accounts |= map(if .provider == "claude" and .label == "'"$WORK_LABEL"'" then .profile_dir = $d else . end)' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run share-config "$WORK_LABEL" claude
check_eq "$RC" "3" "a profile_dir that resolves to the primary install is refused"
check_contains "$OUT" "resolves to the primary install itself" "saying so"
check_eq "$(test -d "$PRIMARY/skills" -a ! -L "$PRIMARY/skills" && echo intact || echo DAMAGED)" "intact" "control(-): the primary skills dir is still a real directory"
check_eq "$(count_pre_share "$PRIMARY")" "0" "control(-): and nothing in the primary was moved aside"
# Through a symlink too.
ln -s "$PRIMARY" "$CASE_DIR/alias-to-primary"
jq --arg d "$CASE_DIR/alias-to-primary" '.accounts |= map(if .provider == "claude" and .label == "'"$WORK_LABEL"'" then .profile_dir = $d else . end)' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run share-config "$WORK_LABEL" claude
check_eq "$RC" "3" "a symlinked profile_dir that resolves to the primary is refused too"
write_registry

rm -rf "$WORK_DIR"
run share-config "$WORK_LABEL" claude
check_eq "$RC" "5" "a missing profile directory is exit 5"
check_contains "$OUT" "run 'relogin $WORK_LABEL claude' first" "pointing at relogin"

new_case "share-primary-items-missing"
rm -rf "$PRIMARY/agents" "$PRIMARY/account-config.md" "$PRIMARY/settings.json"
run share-config "$WORK_LABEL" claude
check_eq "$RC" "0" "missing primary items do not fail the run"
check_eq "$(test -e "$WORK_DIR/agents" -o -L "$WORK_DIR/agents" && echo present || echo absent)" "absent" "no dangling symlink for a missing primary agents dir"
check_eq "$(test -e "$WORK_DIR/settings.json" && echo present || echo absent)" "absent" "no settings.json copied when the primary has none"
check_contains "$OUT" "skipped agents" "each skip is reported"
check_contains "$OUT" "linked 6, copied 0, merged 1, kept 0, moved aside 0, skipped 3" "and counted"

new_case "share-no-mcp-servers"
printf '{"userID":"primary-user","mcpServers":{}}\n' > "$PRIMARY_JSON"
run share-config "$WORK_LABEL" claude
check_eq "$RC" "0" "a primary with no mcpServers still runs"
check_eq "$(test -e "$WORK_DIR/.claude.json" && echo present || echo absent)" "absent" "and writes no .claude.json into the profile"
check_contains "$OUT" "skipped .claude.json — the primary install has no mcpServers" "saying why"
rm -f "$PRIMARY_JSON"
run share-config "$WORK_LABEL" claude
check_contains "$OUT" "skipped .claude.json — $PRIMARY_JSON does not exist" "a missing primary .claude.json is a skip, not a failure"

new_case "share-profile-json-unparseable"
printf '{not json' > "$WORK_DIR/.claude.json"
run share-config "$WORK_LABEL" claude
check_eq "$RC" "5" "an unparseable profile .claude.json is exit 5"
check_eq "$(cat "$WORK_DIR/.claude.json")" '{not json' "and is never rewritten"
check_eq "$(link_target "$WORK_DIR/skills")" "$PRIMARY/skills" "the links before it were still made"

new_case "share-profile-json-in-the-way"
mkdir -p "$WORK_DIR/.claude.json/stray"
run share-config "$WORK_LABEL" claude
check_eq "$RC" "0" "a DIRECTORY at .claude.json does not fail the run"
check_eq "$(test -d "$WORK_DIR/.claude.json.pre-share/stray" && echo kept || echo LOST)" "kept" "it is moved aside as .claude.json.pre-share"
check_eq "$(test -f "$WORK_DIR/.claude.json" && echo file || echo other)" "file" "and a real file holds the merge"
check_eq "$(jq -r '.mcpServers | keys | join(",")' "$WORK_DIR/.claude.json")" "alpha,beta" "with the primary servers"
check_eq "$(test -e "$WORK_DIR/.claude.json.pre-share/.claude.json" -o -e "$WORK_DIR/.claude.json.pre-share/stray/.claude.json" && echo INSIDE || echo clean)" "clean" "control(-): nothing was dropped inside the directory"
rm -rf "$WORK_DIR/.claude.json" "$WORK_DIR/.claude.json.pre-share"
ln -s "$CASE_DIR/nowhere.json" "$WORK_DIR/.claude.json"
run share-config "$WORK_LABEL" claude
check_eq "$RC" "0" "a dangling symlink at .claude.json does not fail the run"
check_eq "$(link_target "$WORK_DIR/.claude.json.pre-share")" "$CASE_DIR/nowhere.json" "it is moved aside as a keepsake link"
check_eq "$(test -f "$WORK_DIR/.claude.json" -a ! -L "$WORK_DIR/.claude.json" && echo file || echo other)" "file" "and a real file holds the merge"
check_eq "$(test -e "$CASE_DIR/nowhere.json" && echo WRITTEN || echo untouched)" "untouched" "control(-): nothing was written through the link"

new_case "share-profile-json-absent"
run share-config "$WORK_LABEL" claude
check_eq "$RC" "0" "a profile with no .claude.json yet is fine"
check_eq "$(jq -r '.mcpServers | keys | join(",")' "$WORK_DIR/.claude.json")" "alpha,beta" "it is created holding only the merged mcpServers"
check_eq "$(jq -r 'keys | join(",")' "$WORK_DIR/.claude.json")" "mcpServers" "and nothing else"
check_eq "$(stat -f '%Lp' "$WORK_DIR/.claude.json" 2>/dev/null || stat -c '%a' "$WORK_DIR/.claude.json")" "600" "at mode 600"

new_case "share-home-unset"
NOHOME_OUT="$(env -u HOME AI_QUOTAS_CONFIG="$CONFIG" AI_QUOTAS_PROFILE_ROOT="$PROFILES" AI_QUOTAS_PLATFORM=Linux "$SCRIPT" share-config "$WORK_LABEL" claude 2>&1)" && NOHOME_RC=0 || NOHOME_RC=$?
check_eq "$NOHOME_RC" "5" "share-config with HOME unset and no primary override is refused"
check_contains "$NOHOME_OUT" "AI_QUOTAS_PRIMARY_CLAUDE_DIR" "naming the override"
NOHOME_OUT="$(env -u HOME AI_QUOTAS_CONFIG="$CONFIG" AI_QUOTAS_PROFILE_ROOT="$PROFILES" AI_QUOTAS_PLATFORM=Linux AI_QUOTAS_PRIMARY_CLAUDE_DIR="$PRIMARY" AI_QUOTAS_PRIMARY_CLAUDE_JSON="$PRIMARY_JSON" "$SCRIPT" share-config "$WORK_LABEL" claude 2>&1)" && NOHOME_RC=0 || NOHOME_RC=$?
check_eq "$NOHOME_RC" "0" "with both overrides it runs HOME-less"
check_eq "$(link_target "$WORK_DIR/rules")" "$PRIMARY/rules" "against the overridden primary"
printf '%s\n' "$NOHOME_OUT" >> "$ALL_OUTPUT"

# --- 8. no case, anywhere, leaked a credential --------------------------------

check_eq "$(grep -c "$FIXTURE_SECRET" "$ALL_OUTPUT" || true)" "0" \
  "the fixture credential never reached stdout or stderr of any case"
check_eq "$(grep -rl "$FIXTURE_SECRET" "$TMP" --include='launchers.zsh*' --include='.claude.json*' --include='settings.json*' --include='config.toml*' 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "nor any file either action wrote"

# --- summary -----------------------------------------------------------------

echo
echo "passed: $PASS   failed: $FAILED"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
