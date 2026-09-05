#!/bin/bash
# install-config-sync.test.sh — Tests for install-config-sync.sh and
# uninstall-config-sync.sh (issue #1524).
# catalog: tests — Tests `install-config-sync.sh` / `uninstall-config-sync.sh` against `launchctl` and `uname` stubs — plist rendering, worktree-copy preference, `--interval` validation, teardown, and the non-Darwin guard
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

  # LAUNCHCTL_LIST_LABEL makes the emitted label configurable so a LOOKALIKE can
  # be tested. Hard-coding the exact label let a substring match pass: a
  # lifecycle script that checked for `com.user.claude-config-sync` as a
  # substring would treat `com.user.claude-config-sync-test` as our job.
  # LAUNCHCTL_FAIL_CMD makes ONE subcommand fail while the rest still succeed,
  # which is the only way to reach the enable/kickstart branches: launchd's real
  # failure here is partial, and a stub that fails everything would exit at
  # bootstrap instead.
  cat > "$bin/launchctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
if [ -n "${LAUNCHCTL_FAIL_CMD:-}" ] && [ "$1" = "$LAUNCHCTL_FAIL_CMD" ]; then
  printf 'stub: %s refused\n' "$1" >&2
  exit 3
fi
if [ "$1" = "list" ]; then
  if [ "${LAUNCHCTL_LIST_EMPTY:-0}" != "1" ]; then
    printf -- '-\t0\t%s\n' "${LAUNCHCTL_LIST_LABEL:-com.user.claude-config-sync}"
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
  # Order is the property under test, not mere presence: a bootout that ran
  # AFTER bootstrap would unload the job it just installed, and a presence-only
  # grep passes either way. Compare the first recorded verb.
  assert "launchctl bootout ran first (idempotent reinstall)" \
    "[ \"\$(awk 'NR==1{print \$1}' '$root/launchctl.log')\" = 'bootout' ]"
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

# ── Test 8: a lookalike label is not our job ────────────────────────────────
#
# Both lifecycle scripts compare the final `launchctl list` field literally
# (awk '$NF == want'). This pins that: with ONLY a lookalike listed, install
# must report its verification failure and uninstall must treat the job as
# absent. A regression to a substring match makes both read the lookalike as
# ours, and every other test in this suite would still pass.

test_8_lookalike_label_is_not_our_job() {
  section "Test 8: a lookalike LaunchAgent label is never mistaken for ours"

  local root home out rc lookalike
  root="$(make_env Darwin)"
  home="$root/home"
  lookalike="${LABEL}-test"

  # Install while launchctl lists ONLY the lookalike. Verification looks for
  # our exact label, does not find it, and must say so.
  out="$(PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
        LAUNCHCTL_LIST_LABEL="$lookalike" bash "$INSTALL" 2>&1)"
  rc=$?

  assert "the stub really emitted the lookalike, not our label" \
    "printf '%s' \"\$lookalike\" | grep -q -- '-test\$'"
  assert "install does not report success on a lookalike-only listing" \
    "[ $rc -ne 0 ] || ! printf '%s' \"\$out\" | grep -q 'verified'"

  # Uninstall with only the lookalike listed: our job is absent, so the
  # still-listed failure path (test 5) must NOT fire.
  out="$(PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
        LAUNCHCTL_LIST_LABEL="$lookalike" bash "$UNINSTALL" 2>&1)"
  rc=$?

  assert "uninstall exits 0 — the lookalike is not our job" "[ $rc -eq 0 ]"
  assert "uninstall does not claim our job is still listed" \
    "! printf '%s' \"\$out\" | grep -q 'still appears in launchctl list'"

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

# ── Test 9: a failed `enable` is an install failure, a failed kickstart is not ─
#
# `launchctl list` reports a job that is merely BOOTSTRAPPED, enabled or not, so
# the final verification cannot distinguish "loaded and running" from "loaded and
# permanently disabled". That makes a swallowed `enable` failure a FALSE PASS —
# the install reports success for a job that will never fire. Pinned here because
# every other test in this suite passes with both errors discarded.
#
# kickstart is the deliberate other half: it only forces the first run to happen
# immediately, so its failure must NOT fail the install.

test_9_enable_failure_fails_install() {
  section "Test 9: a refused enable fails the install; a refused kickstart does not"

  local root home out rc
  root="$(make_env Darwin)"
  home="$root/home"

  # enable refused — the job is loaded but disabled and would never run.
  out="$(PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
         LAUNCHCTL_FAIL_CMD=enable bash "$INSTALL" 2>&1)" && rc=0 || rc=$?

  assert "install exits 1 when launchctl enable is refused" "[ $rc -eq 1 ]"
  assert "the install does not report PASS" \
    "! printf '%s' \"\$out\" | grep -q '^PASS'"
  assert "the disabled-but-loaded state is named" \
    "printf '%s' \"\$out\" | grep -q 'loaded but disabled'"
  assert "launchctl's own error is surfaced" \
    "printf '%s' \"\$out\" | grep -q 'stub: enable refused'"
  assert "recovery instructions name the enable command" \
    "printf '%s' \"\$out\" | grep -q 'launchctl enable '"

  # kickstart refused — the job is loaded AND enabled, so the interval still
  # fires. A warning, not a failure.
  : > "$root/launchctl.log"
  out="$(PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
         LAUNCHCTL_FAIL_CMD=kickstart bash "$INSTALL" 2>&1)" && rc=0 || rc=$?

  assert "install still exits 0 when only kickstart is refused" "[ $rc -eq 0 ]"
  assert "the install still reports PASS" \
    "printf '%s' \"\$out\" | grep -q '^PASS'"
  assert "the skipped immediate run is warned about, not swallowed" \
    "printf '%s' \"\$out\" | grep -q '^WARN: launchctl kickstart'"

  rm -rf "$root"
}

# ── Test 10: an unreadable worktree script falls back to the local copy ──────
#
# The plist points launchd at whichever copy is selected here, so selecting one
# that cannot be read installs a scheduler that fails on every tick with nothing
# in the install output to say why. `-f` alone accepted that file; `-r` is what
# makes the check match how the path is actually used.

test_9b_uninstall_fails_closed_when_list_unverifiable() {
  section "Test 9b: uninstall fails closed when 'launchctl list' itself fails"

  # Static regression (CodeAnt 3920024445, PR #1553): the verify step used
  # `launchctl list 2>/dev/null || true`, so a failed launchctl read became an
  # empty listing and the uninstall printed PASS without verifying anything.
  assert "uninstall captures launchctl list's own exit status" \
    "grep -q 'launchctl_rc=' '$UNINSTALL'"
  assert "and no longer swallows a failed listing as empty" \
    "! grep -q 'launchctl list 2>/dev/null || true' '$UNINSTALL'"
  assert "an unverifiable listing is a loud failure" \
    "grep -q 'could not verify the unload' '$UNINSTALL'"

  # Behavioral (CR 3920136612): actually fail the stub's `list` subcommand and
  # prove the control flow — exit 1 with the could-not-verify message, never a
  # PASS printed over an unverified unload.
  local root home out rc
  root="$(make_env Darwin)"
  home="$root/home"
  PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
    bash "$INSTALL" >/dev/null 2>&1
  rc=0
  out="$(PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
        LAUNCHCTL_FAIL_CMD=list bash "$UNINSTALL" 2>&1)" || rc=$?
  assert "uninstall exits 1 when 'launchctl list' itself fails" "[ $rc -eq 1 ]"
  assert "and reports the unverifiable unload" \
    "printf '%s' \"\$out\" | grep -q 'could not verify the unload'"
  assert "(control) no PASS was printed on the unverified path" \
    "! printf '%s' \"\$out\" | grep -q 'PASS:'"
  rm -rf "$root"
}

test_10_unreadable_worktree_script_falls_back() {
  section "Test 10: an unreadable worktree script is not chosen for the plist"

  local root home wt_script out
  root="$(make_env Darwin)"
  home="$root/home"
  wt_script="$home/.claude/skills-worktree/.claude/scripts/claude-config-sync.sh"

  mkdir -p "$(dirname "$wt_script")"
  printf '#!/bin/bash\n' > "$wt_script"
  chmod 000 "$wt_script"

  # A root-owned test runner can read a 000 file, which would make this vacuous.
  if [[ -r "$wt_script" ]]; then
    echo "  (skipped: this user can read a 0000-mode file — no readability to test)"
    rm -rf "$root"
    return 0
  fi

  local rc=0
  out="$(PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
        bash "$INSTALL" 2>&1)" || rc=$?

  # The fallback is only a fallback if it WORKS: an installer that picks the
  # local checkout and then fails would still print the expected text, so the
  # text asserts below would pass vacuously without this.
  assert "the fallback install succeeds (exit 0)" "[ $rc -eq 0 ]"
  assert "the install did not select the unreadable worktree copy" \
    "! printf '%s' \"\$out\" | grep -q 'skills worktree (pinned to main)'"
  assert "it fell back to this checkout and said so" \
    "printf '%s' \"\$out\" | grep -q 'no skills worktree yet'"

  chmod 644 "$wt_script" 2>/dev/null || true
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
test_8_lookalike_label_is_not_our_job
test_9_enable_failure_fails_install
test_9b_uninstall_fails_closed_when_list_unverifiable
test_10_unreadable_worktree_script_falls_back

echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
if [ $FAIL -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED${NC}: $PASS/$TOTAL tests"
  exit 0
else
  echo -e "${RED}${BOLD}FAILURES${NC}: $FAIL/$TOTAL tests failed ($PASS passed)"
  exit 1
fi
