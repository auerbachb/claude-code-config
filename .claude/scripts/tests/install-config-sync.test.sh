#!/bin/bash
# install-config-sync.test.sh — Tests for install-config-sync.sh and
# uninstall-config-sync.sh (issue #1524).
#
# Both scripts drive launchd, so `launchctl` and `uname` are stubbed on PATH:
# `uname` is forced to report Darwin (or Linux, for the platform-guard cases) so
# the suite behaves identically on the macOS dev machines and the ubuntu CI
# runner, and `launchctl` records its arguments to a log the assertions read.
# Nothing outside the throwaway HOME is written — in particular no real
# LaunchAgent is ever installed.
#
# Usage: bash .claude/scripts/tests/install-config-sync.test.sh
# Exit code: 0 = all pass, 1 = any fail

set -uo pipefail

PASS=0; FAIL=0; TOTAL=0
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
INSTALL="$REPO_ROOT/.claude/scripts/install-config-sync.sh"
UNINSTALL="$REPO_ROOT/.claude/scripts/uninstall-config-sync.sh"
TEMPLATE="$REPO_ROOT/.claude/scripts/com.user.claude-config-sync.plist"
LABEL="com.user.claude-config-sync"
GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

assert() {
  # NOTE: $condition is always a script-authored string (never user input).
  local description="$1" condition="$2"
  TOTAL=$((TOTAL + 1))
  if eval "$condition" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $description"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $description"
    FAIL=$((FAIL + 1))
  fi
}

section() { echo ""; echo -e "${BOLD}━━━ $1 ━━━${NC}"; }

# make_env <platform> — temp root with a stub bin dir and a throwaway HOME.
# Prints the temp root; $root/home is HOME and $root/bin goes first on PATH.
make_env() {
  local platform="$1" root bin
  root="$(mktemp -d)"
  bin="$root/bin"
  mkdir -p "$bin" "$root/home/.claude"

  cat > "$bin/uname" <<STUB
#!/bin/sh
# Only -s is consulted by the scripts under test.
printf '%s\n' "$platform"
STUB

  cat > "$bin/launchctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
if [ "$1" = "list" ]; then
  if [ "${LAUNCHCTL_LIST_EMPTY:-0}" != "1" ]; then
    printf -- '-\t0\tcom.user.claude-config-sync\n'
  fi
fi
exit 0
STUB

  chmod +x "$bin/uname" "$bin/launchctl"
  printf '%s' "$root"
}

# ── Prerequisites ─────────────────────────────────────────────────────────────

section "Prerequisites"
INSTALL_ERR="$(mktemp -t ics-help-err.XXXXXX)"
UNINSTALL_ERR="$(mktemp -t ucs-help-err.XXXXXX)"
trap 'rm -f "$INSTALL_ERR" "$UNINSTALL_ERR"' EXIT
assert "install-config-sync.sh exists and is executable" "[ -x '$INSTALL' ]"
assert "uninstall-config-sync.sh exists and is executable" "[ -x '$UNINSTALL' ]"
assert "the plist template exists" "[ -f '$TEMPLATE' ]"
assert "template carries all three placeholders" \
  "grep -q '__SHELL__' '$TEMPLATE' && grep -q '__SCRIPT_PATH__' '$TEMPLATE' && grep -q '__HOME__' '$TEMPLATE'"
assert "template sets RunAtLoad (survives reboot / runs at login)" \
  "grep -A1 '<key>RunAtLoad</key>' '$TEMPLATE' | grep -q '<true/>'"
assert "template sets StartInterval (periodic + sleep catch-up)" \
  "grep -A1 '<key>StartInterval</key>' '$TEMPLATE' | grep -qE '<integer>[0-9]+</integer>'"
# The template must itself be a valid plist — a placeholder inside <integer>
# would break that, which is why the interval substitution is anchored instead.
if command -v plutil >/dev/null 2>&1; then
  assert "template is a valid plist" "plutil -lint '$TEMPLATE'"
else
  echo "  (skipped: plutil not on PATH — template plist validation)"
fi
assert "install --help exits 0 with no stderr" \
  "out=\$(bash '$INSTALL' --help 2>'$INSTALL_ERR'); [ \$? -eq 0 ] && [ ! -s '$INSTALL_ERR' ] && [ -n \"\$out\" ]"
assert "install --help documents --interval and the exit-code contract" \
  "out=\$(bash '$INSTALL' --help 2>/dev/null); printf '%s' \"\$out\" | grep -q -- '--interval' && printf '%s' \"\$out\" | grep -q 'EXIT CODES'"
assert "uninstall --help exits 0 with no stderr" \
  "out=\$(bash '$UNINSTALL' --help 2>'$UNINSTALL_ERR'); [ \$? -eq 0 ] && [ ! -s '$UNINSTALL_ERR' ] && [ -n \"\$out\" ]"
assert "uninstall --help documents --remove-state and the exit-code contract" \
  "out=\$(bash '$UNINSTALL' --help 2>/dev/null); printf '%s' \"\$out\" | grep -q -- '--remove-state' && printf '%s' \"\$out\" | grep -q 'EXIT CODES'"

# ── Test 1: one command renders and bootstraps the LaunchAgent ───────────────

test_1_install_renders_plist() {
  section "Test 1: one command registers the job with launchd"

  local root home plist out rc
  root="$(make_env Darwin)"
  home="$root/home"
  plist="$home/Library/LaunchAgents/${LABEL}.plist"

  # No skills worktree yet — the installer must fall back to this checkout.
  out="$(PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
        bash "$INSTALL" 2>&1)"
  rc=$?

  assert "install exits 0" "[ $rc -eq 0 ]"
  assert "install reports PASS" "printf '%s' \"\$out\" | grep -q '^PASS:'"
  assert "the LaunchAgent plist was written" "[ -f '$plist' ]"
  assert "no placeholder survives substitution" \
    "! grep -qE '__(SHELL|SCRIPT_PATH|HOME)__' '$plist'"
  assert "plist points at claude-config-sync.sh" \
    "grep -q 'claude-config-sync.sh' '$plist'"
  assert "plist runs it with --quiet" "grep -q '<string>--quiet</string>' '$plist'"
  assert "plist keeps RunAtLoad true" \
    "grep -A1 '<key>RunAtLoad</key>' '$plist' | grep -q '<true/>'"
  assert "plist defaults to an hourly StartInterval" \
    "grep -A1 '<key>StartInterval</key>' '$plist' | grep -q '<integer>3600</integer>'"
  assert "log paths land under the throwaway HOME" \
    "grep -q '$home/.claude/logs/config-sync-stdout.log' '$plist'"
  assert "the log directory was created" "[ -d '$home/.claude/logs' ]"
  if command -v plutil >/dev/null 2>&1; then
    assert "the rendered plist is valid — launchd never sees a broken one" \
      "plutil -lint '$plist'"
  fi

  # launchd wiring: bootout (idempotent) → bootstrap → enable → kickstart.
  assert "launchctl bootout ran first (idempotent reinstall)" \
    "grep -q '^bootout ' '$root/launchctl.log'"
  assert "launchctl bootstrap ran" "grep -q '^bootstrap ' '$root/launchctl.log'"
  assert "launchctl enable ran" "grep -q '^enable ' '$root/launchctl.log'"
  assert "launchctl kickstart ran" "grep -q '^kickstart ' '$root/launchctl.log'"
  assert "install verified with launchctl list" "grep -q '^list' '$root/launchctl.log'"

  rm -rf "$root"
}

# ── Test 2: the worktree copy wins when one exists ──────────────────────────

test_2_prefers_worktree_copy() {
  section "Test 2: the plist points at the main-pinned worktree copy when present"

  local root home wt_script plist
  root="$(make_env Darwin)"
  home="$root/home"
  wt_script="$home/.claude/skills-worktree/.claude/scripts/claude-config-sync.sh"
  plist="$home/Library/LaunchAgents/${LABEL}.plist"

  mkdir -p "$(dirname "$wt_script")"
  printf '#!/bin/bash\n: # stand-in for the worktree copy\n' > "$wt_script"

  local out
  out="$(PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
        bash "$INSTALL" 2>&1)"

  assert "plist points into the skills worktree" \
    "grep -q '$home/.claude/skills-worktree/.claude/scripts/claude-config-sync.sh' '$plist'"
  assert "install says which copy it chose" \
    "printf '%s' \"\$out\" | grep -q 'skills worktree'"

  rm -rf "$root"
}

# ── Test 3: --interval override and its validation ──────────────────────────

test_3_interval_option() {
  section "Test 3: --interval overrides the schedule and rejects bad values"

  local root home plist rc
  root="$(make_env Darwin)"
  home="$root/home"
  plist="$home/Library/LaunchAgents/${LABEL}.plist"

  PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
    bash "$INSTALL" --interval 900 >/dev/null 2>&1
  rc=$?

  assert "install with --interval exits 0" "[ $rc -eq 0 ]"
  assert "StartInterval reflects the override" \
    "grep -A1 '<key>StartInterval</key>' '$plist' | grep -q '<integer>900</integer>'"
  # The substitution is anchored to the StartInterval key, so no other integer
  # sharing the default value may be rewritten.
  assert "no stray <integer>900</integer> anywhere else in the plist" \
    "[ \"\$(grep -c '<integer>900</integer>' '$plist')\" -eq 1 ]"

  # Capture the status BEFORE calling assert: `$?` inside the condition string
  # is evaluated by assert's own eval, where it would report assert's bookkeeping
  # rather than the command under test.
  PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
    bash "$INSTALL" --interval nonsense >/dev/null 2>&1
  local rc_bad=$?
  assert "a non-numeric --interval is a usage error (exit 2)" "[ $rc_bad -eq 2 ]"

  PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
    bash "$INSTALL" --interval 5 >/dev/null 2>&1
  local rc_small=$?
  assert "an absurdly small --interval is rejected (exit 2)" "[ $rc_small -eq 2 ]"

  rm -rf "$root"
}

# ── Test 4: uninstall unloads, removes, and verifies ────────────────────────

test_4_uninstall() {
  section "Test 4: uninstall unloads the job and removes the plist"

  local root home plist out rc
  root="$(make_env Darwin)"
  home="$root/home"
  plist="$home/Library/LaunchAgents/${LABEL}.plist"

  PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
    bash "$INSTALL" >/dev/null 2>&1
  assert "(setup) plist installed" "[ -f '$plist' ]"

  # Seed state so --remove-state has something to remove.
  mkdir -p "$home/.claude/logs"
  printf '{}' > "$home/.claude/logs/claude-config-sync-state.json"
  printf '{}' > "$home/.claude/sync-restart-recommended.json"

  : > "$root/launchctl.log"
  out="$(PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
        LAUNCHCTL_LIST_EMPTY=1 bash "$UNINSTALL" 2>&1)"
  rc=$?

  assert "uninstall exits 0" "[ $rc -eq 0 ]"
  assert "uninstall reports PASS" "printf '%s' \"\$out\" | grep -q '^PASS:'"
  assert "the plist is gone" "[ ! -f '$plist' ]"
  assert "both bootout spellings were tried" \
    "[ \"\$(grep -c '^bootout ' '$root/launchctl.log')\" -ge 2 ]"
  assert "state is retained by default" \
    "[ -f '$home/.claude/logs/claude-config-sync-state.json' ]"
  assert "retained state is announced" \
    "printf '%s' \"\$out\" | grep -q 'State retained'"

  # Reinstall then remove with --remove-state.
  PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
    bash "$INSTALL" >/dev/null 2>&1
  PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
    LAUNCHCTL_LIST_EMPTY=1 bash "$UNINSTALL" --remove-state >/dev/null 2>&1
  assert "--remove-state removes the state file" \
    "[ ! -f '$home/.claude/logs/claude-config-sync-state.json' ]"
  assert "--remove-state removes the marker" \
    "[ ! -f '$home/.claude/sync-restart-recommended.json' ]"

  PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
    bash "$UNINSTALL" --bogus >/dev/null 2>&1
  local rc_bogus=$?
  assert "an unknown uninstall flag is a usage error (exit 2)" "[ $rc_bogus -eq 2 ]"

  rm -rf "$root"
}

# ── Test 5: a still-listed job after uninstall is reported, not swallowed ───

test_5_uninstall_failure_is_loud() {
  section "Test 5: a job still listed after bootout fails loudly"

  local root home out rc
  root="$(make_env Darwin)"
  home="$root/home"

  PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
    bash "$INSTALL" >/dev/null 2>&1

  # LAUNCHCTL_LIST_EMPTY unset ⇒ the stub keeps listing the label.
  out="$(PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
        bash "$UNINSTALL" 2>&1)"
  rc=$?

  assert "uninstall exits 1 when the job is still listed" "[ $rc -eq 1 ]"
  assert "the failure is stated on stderr" \
    "printf '%s' \"\$out\" | grep -q 'still appears in launchctl list'"

  rm -rf "$root"
}

# ── Test 6: non-Darwin platform guard ───────────────────────────────────────

test_6_platform_guard() {
  section "Test 6: non-Darwin hosts — installer refuses, uninstaller no-ops"

  local root home out rc
  root="$(make_env Linux)"
  home="$root/home"

  out="$(PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
        bash "$INSTALL" 2>&1)"
  rc=$?
  assert "installer exits 1 on a non-Darwin host" "[ $rc -eq 1 ]"
  assert "installer says it is macOS-only" "printf '%s' \"\$out\" | grep -q 'macOS-only'"
  assert "installer wrote no plist" \
    "[ ! -f '$home/Library/LaunchAgents/${LABEL}.plist' ]"
  assert "installer called no launchctl" "[ ! -s '$root/launchctl.log' ]"

  out="$(PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
        bash "$UNINSTALL" 2>&1)"
  rc=$?
  assert "uninstaller no-ops with exit 0 on a non-Darwin host" "[ $rc -eq 0 ]"
  assert "uninstaller says there is nothing to remove" \
    "printf '%s' \"\$out\" | grep -q 'macOS-only'"

  # The guard must sit before any $HOME expansion (issue #1430's lesson), so it
  # holds even with HOME unset.
  out="$(env -u HOME PATH="$root/bin:$PATH" bash "$UNINSTALL" 2>&1)"
  rc=$?
  assert "uninstaller still exits 0 with HOME unset on a non-Darwin host" "[ $rc -eq 0 ]"
  assert "and takes the documented guard path rather than aborting on unset HOME" \
    "printf '%s' \"\$out\" | grep -q 'macOS-only'"

  rm -rf "$root"
}

# ── Test 7: metacharacter paths survive the sed substitution ────────────────
#
# The placeholder substitutions are `#`-delimited, so the replacement text must
# escape `#` (the delimiter), `&` (the whole-match backreference) AND `\` (which
# starts an escape). The escaper covered the first two only, so a HOME
# containing a backslash had it silently DROPPED — `a\b` rendered as `ab`, and
# launchd was handed a plist pointing at a directory that does not exist.

test_7_metacharacter_paths_survive_substitution() {
  section "Test 7: paths carrying \\ # & survive placeholder substitution"

  local root home plist rc expected
  root="$(make_env Darwin)"
  # Every character the replacement side treats as special, in one directory
  # name. Legal on APFS, and the whole point is that the installer must not
  # silently mangle it. Deliberately NO apostrophe: assert() eval's its
  # condition, and the paths below are interpolated inside single quotes there.
  home="$root/home/back\\slash hash#tag amp&sand"
  mkdir -p "$home/.claude"
  plist="$home/Library/LaunchAgents/${LABEL}.plist"

  PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
    bash "$INSTALL" >/dev/null 2>&1
  rc=$?

  assert "install exits 0 with metacharacters in HOME" "[ $rc -eq 0 ]"
  assert "the plist was written" "[ -f '$plist' ]"
  assert "no placeholder survives substitution" \
    "! grep -qE '__(SHELL|SCRIPT_PATH|HOME)__' '$plist'"
  # The load-bearing assertion: the path is reproduced character for character,
  # modulo the ONE transformation the plist legitimately applies — `&` becomes
  # the XML entity. `\` and `#` must survive untouched. Pre-fix the backslash
  # vanished (a\b rendered as ab), so this fails on the old escaper.
  expected="${home//&/&amp;}/.claude/logs/config-sync-stdout.log"
  assert "the backslash- and hash-bearing HOME survives verbatim in the log paths" \
    "grep -Fq \"\$expected\" '$plist'"
  # Control, evaluated HERE rather than inside assert's eval: interpolating a
  # backslash-bearing path into an eval'd string is its own quoting hazard, and
  # a control that fails for the wrong reason proves nothing.
  local has_backslash=no
  case "$home" in *\\*) has_backslash=yes ;; esac
  assert "(control) the raw path really did contain a backslash to lose" \
    "[ '$has_backslash' = 'yes' ]"
  assert "the directory the plist names actually exists" \
    "[ -d '$home/.claude/logs' ]"
  if command -v plutil >/dev/null 2>&1; then
    assert "the rendered plist is still valid XML" "plutil -lint '$plist'"
  fi

  rm -rf "$root"
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  install/uninstall-config-sync.sh test suite (issue #1524)   ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"

test_1_install_renders_plist
test_7_metacharacter_paths_survive_substitution
test_2_prefers_worktree_copy
test_3_interval_option
test_4_uninstall
test_5_uninstall_failure_is_loud
test_6_platform_guard

echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
if [ $FAIL -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED${NC}: $PASS/$TOTAL tests"
  exit 0
else
  echo -e "${RED}${BOLD}FAILURES${NC}: $FAIL/$TOTAL tests failed ($PASS passed)"
  exit 1
fi
