#!/bin/bash
# install-backfill-review.test.sh — Tests for install-backfill-review.sh and
# uninstall-backfill-review.sh (issue #1941).
# catalog: tests — Tests `install-backfill-review.sh` / `uninstall-backfill-review.sh` against `launchctl` and `uname` stubs — placeholder and PATH rendering, `--interval`/`--repo-dir` validation, runner selection, lifecycle order and rollback, ledger-preserving teardown, and the non-Darwin guard
#
# Same harness as install-config-sync.test.sh: `uname` is stubbed to report
# Darwin (or Linux for the guard cases) so the suite behaves identically on the
# macOS dev machines and the ubuntu CI runner, and `launchctl` records its
# arguments to a log the assertions read. `gh`, `coderabbit` and `codeant` are
# stubs in their own directory so their appearance in the rendered PATH is an
# unambiguous signal. Nothing outside the throwaway HOME is written — no real
# LaunchAgent is ever installed or loaded.
#
# Usage: bash .claude/scripts/tests/install-backfill-review.test.sh
# Exit code: 0 = all pass, 1 = any fail

set -uo pipefail

PASS=0; FAIL=0; TOTAL=0
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
INSTALL="$REPO_ROOT/.claude/scripts/install-backfill-review.sh"
UNINSTALL="$REPO_ROOT/.claude/scripts/uninstall-backfill-review.sh"
TEMPLATE="$REPO_ROOT/.claude/scripts/com.user.claude-backfill-review.plist"
LABEL="com.user.claude-backfill-review"
BASE_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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

# make_env <platform> — temp root with stub dirs, a throwaway HOME and a git
# checkout fixture with an origin remote. Prints the temp root:
#   $root/bin    uname + launchctl stubs (first on PATH)
#   $root/tools  gh, coderabbit, codeant stubs (second on PATH)
#   $root/home   HOME
#   $root/repo   the checkout passed as --repo-dir
make_env() {
  local platform="$1" root bin tools
  root="$(mktemp -d)"
  bin="$root/bin"; tools="$root/tools"
  mkdir -p "$bin" "$tools" "$root/home/.claude" "$root/repo"

  cat > "$bin/uname" <<STUB
#!/bin/sh
printf '%s\n' "$platform"
STUB

  # LAUNCHCTL_FAIL_CMD fails ONE subcommand; LAUNCHCTL_LIST_LABEL makes the
  # listed label configurable (lookalike case); LAUNCHCTL_LIST_EMPTY lists none.
  cat > "$bin/launchctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
if [ -n "${LAUNCHCTL_FAIL_CMD:-}" ] && [ "$1" = "$LAUNCHCTL_FAIL_CMD" ]; then
  printf 'stub: %s refused\n' "$1" >&2
  exit 3
fi
if [ "$1" = "list" ]; then
  if [ "${LAUNCHCTL_LIST_EMPTY:-0}" != "1" ]; then
    printf -- '-\t0\t%s\n' "${LAUNCHCTL_LIST_LABEL:-com.user.claude-backfill-review}"
  fi
fi
exit 0
STUB

  local t
  for t in gh coderabbit codeant; do
    printf '#!/bin/sh\nexit 0\n' > "$tools/$t"
    chmod +x "$tools/$t"
  done
  chmod +x "$bin/uname" "$bin/launchctl"

  git init -q "$root/repo"
  git -C "$root/repo" remote add origin https://github.com/example/fixture.git

  printf '%s' "$root"
}

# run_install <root> [args...] — install with the stub PATH and throwaway HOME.
# Output goes to $root/out, exit status to $root/rc.
run_install() {
  local root="$1"; shift
  PATH="$root/bin:$root/tools:$PATH" HOME="$root/home" LAUNCHCTL_LOG="$root/launchctl.log" \
    bash "$INSTALL" "$@" > "$root/out" 2>&1
  echo $? > "$root/rc"
}

# program_args <plist> — the <string> values of the ProgramArguments array, one
# per line, in order (portable: no plutil on the Linux runner).
program_args() {
  awk '/<key>ProgramArguments<\/key>/ { inkey = 1; next }
       inkey && /<array>/ { inarr = 1; next }
       inarr && /<\/array>/ { exit }
       inarr { sub(/^[[:space:]]*<string>/, ""); sub(/<\/string>[[:space:]]*$/, ""); print }' "$1"
}

# job_path <plist> — the rendered EnvironmentVariables PATH value.
job_path() {
  awk '/<key>PATH<\/key>/ { getline; sub(/^[[:space:]]*<string>/, ""); sub(/<\/string>[[:space:]]*$/, ""); print; exit }' "$1"
}

# seed_runner <dir> [skip-helper] — a stand-in runner plus its helpers.
seed_runner() {
  local dir="$1" skip="${2:-}" h
  mkdir -p "$dir/lib"
  printf '#!/bin/bash\n: # stand-in runner\n' > "$dir/backfill-review.sh"
  for h in unreviewed-merge-ledger.sh local-review.sh issue-file.sh issue-dedup.sh lib/backfill_review.py; do
    [[ "$h" == "$skip" ]] && continue
    printf '# stand-in\n' > "$dir/$h"
  done
}

# ── Prerequisites ─────────────────────────────────────────────────────────────

section "Prerequisites"
assert "install-backfill-review.sh exists and is executable" "[ -x '$INSTALL' ]"
assert "uninstall-backfill-review.sh exists and is executable" "[ -x '$UNINSTALL' ]"
assert "the plist template exists" "[ -f '$TEMPLATE' ]"
assert "template carries all five placeholders" \
  "grep -q '__SHELL__' '$TEMPLATE' && grep -q '__SCRIPT_PATH__' '$TEMPLATE' && grep -q '__REPO_DIR__' '$TEMPLATE' && grep -q '__PATH__' '$TEMPLATE' && grep -q '__HOME__' '$TEMPLATE'"
assert "template defaults StartInterval to 1800" \
  "grep -q '<integer>1800</integer>' <<<\"\$(grep -A1 '<key>StartInterval</key>' '$TEMPLATE')\""
if command -v plutil >/dev/null 2>&1; then
  assert "template is a valid plist" "plutil -lint '$TEMPLATE'"
else
  echo "  (skipped: plutil not on PATH — template plist validation)"
fi
assert "install --help exits 0 and documents --repo-dir, --interval and EXIT CODES" \
  "out=\$(bash '$INSTALL' --help 2>/dev/null) && grep -q -- '--repo-dir' <<<\"\$out\" && grep -q -- '--interval' <<<\"\$out\" && grep -q 'EXIT CODES' <<<\"\$out\""
assert "uninstall --help exits 0 and documents EXIT CODES" \
  "out=\$(bash '$UNINSTALL' --help 2>/dev/null) && grep -q 'EXIT CODES' <<<\"\$out\""

# ── Test 1: placeholders, ProgramArguments, PATH and lifecycle order ─────────

test_1_install_renders_and_loads() {
  section "Test 1: one command renders the plist and loads it in order"

  local root home plist toplevel jp
  root="$(make_env Darwin)"
  home="$root/home"
  plist="$home/Library/LaunchAgents/${LABEL}.plist"
  toplevel="$(git -C "$root/repo" rev-parse --show-toplevel)"

  run_install "$root" --repo-dir "$root/repo"

  assert "install exits 0" "[ \"\$(cat '$root/rc')\" = 0 ]"
  assert "install reports PASS" "grep -q '^PASS:' '$root/out'"
  assert "the LaunchAgent plist was written" "[ -f '$plist' ]"
  assert "no placeholder survives substitution" \
    "! grep -qE '__(SHELL|SCRIPT_PATH|REPO_DIR|PATH|HOME)__' '$plist'"
  # With no skills worktree, the runner is this checkout's copy.
  printf '%s\n' /bin/bash "$REPO_ROOT/.claude/scripts/backfill-review.sh" --repo-dir "$toplevel" > "$root/want-args"
  program_args "$plist" > "$root/got-args"
  assert "ProgramArguments is exactly /bin/bash, the runner, --repo-dir, the checkout top level" \
    "diff -q '$root/want-args' '$root/got-args'"
  assert "default StartInterval is 1800 (30 minutes)" \
    "grep -q '<integer>1800</integer>' <<<\"\$(grep -A1 '<key>StartInterval</key>' '$plist')\""
  assert "log paths land under the throwaway HOME" \
    "grep -q '$home/.claude/logs/backfill-review-stdout.log' '$plist'"
  assert "the log directory was created" "[ -d '$home/.claude/logs' ]"

  jp="$(job_path "$plist")"
  assert "PATH starts with the stub tool directory (gh, coderabbit, codeant)" \
    "[[ '$jp' == '$root/tools:'* ]]"
  # Every base directory is present; a tool already living in one of them (git
  # in /usr/bin, say) moves that entry earlier rather than repeating it.
  local base_missing="" d
  for d in ${BASE_PATH//:/ }; do
    case ":$jp:" in *":$d:"*) ;; *) base_missing="$base_missing $d" ;; esac
  done
  assert "PATH carries every base system directory" "[ -z '$base_missing' ]"
  assert "PATH ends with the last base directory (base comes after the tools)" \
    "[[ '$jp' == *':/sbin' ]]"
  assert "PATH carries no duplicate entries" \
    "[ -z \"\$(tr ':' '\n' <<<'$jp' | sort | uniq -d)\" ]"
  assert "PATH includes git's directory" \
    "case ':$jp:' in *\":\$(dirname \"\$(command -v git)\"):\"*) true ;; *) false ;; esac"
  if command -v plutil >/dev/null 2>&1; then
    assert "the rendered plist is valid" "plutil -lint '$plist'"
  fi

  # Full relative order of the lifecycle verbs, not mere presence.
  assert "launchctl verbs run bootout → bootstrap → enable → kickstart → list" \
    "[ \"\$(awk '{print \$1}' '$root/launchctl.log' | tr '\n' ' ')\" = 'bootout bootstrap enable kickstart list ' ]"
  assert "bootstrap targets the gui domain and the installed plist" \
    "grep -q \"^bootstrap gui/[0-9]* $plist\\\$\" '$root/launchctl.log'"
  assert "install prints the one-off --ignore-window command" \
    "grep -q -- '--ignore-window' '$root/out'"

  rm -rf "$root"
}

# ── Test 2: a checkout path with spaces and & stays one escaped argument ────

test_2_special_char_checkout() {
  section "Test 2: a checkout path with spaces and & renders as one argument"

  local root plist repo toplevel expected
  root="$(make_env Darwin)"
  repo="$root/my repo & co"
  git init -q "$repo"
  git -C "$repo" remote add origin https://github.com/example/fixture.git
  toplevel="$(git -C "$repo" rev-parse --show-toplevel)"
  plist="$root/home/Library/LaunchAgents/${LABEL}.plist"

  run_install "$root" --repo-dir "$repo"

  assert "install exits 0" "[ \"\$(cat '$root/rc')\" = 0 ]"
  expected="<string>${toplevel//&/&amp;}</string>"
  assert "the checkout is one <string> with & rendered as &amp;" \
    "grep -Fq \"\$expected\" '$plist'"
  assert "ProgramArguments still has exactly four entries" \
    "[ \"\$(program_args '$plist' | wc -l | tr -d ' ')\" = 4 ]"
  if command -v plutil >/dev/null 2>&1; then
    assert "the rendered plist is valid" "plutil -lint '$plist'"
  fi

  rm -rf "$root"
}

# ── Test 3: --interval and argument validation ──────────────────────────────

test_3_arguments() {
  section "Test 3: --interval overrides; bad arguments exit 2 and write nothing"

  local root plist
  root="$(make_env Darwin)"
  plist="$root/home/Library/LaunchAgents/${LABEL}.plist"

  run_install "$root" --repo-dir "$root/repo" --interval 900
  assert "--interval 900 exits 0" "[ \"\$(cat '$root/rc')\" = 0 ]"
  assert "--interval 900 renders 900" \
    "grep -q '<integer>900</integer>' <<<\"\$(grep -A1 '<key>StartInterval</key>' '$plist')\""

  run_install "$root" --repo-dir "$root/repo" --interval 0900
  assert "a leading-zero interval is read as base 10" \
    "grep -q '<integer>900</integer>' <<<\"\$(grep -A1 '<key>StartInterval</key>' '$plist')\""

  rm -f "$plist" "$root/launchctl.log"
  run_install "$root" --repo-dir "$root/repo" --interval nonsense
  assert "--interval nonsense exits 2" "[ \"\$(cat '$root/rc')\" = 2 ]"
  run_install "$root" --repo-dir "$root/repo" --interval 5
  assert "--interval 5 (below 60) exits 2" "[ \"\$(cat '$root/rc')\" = 2 ]"
  run_install "$root"
  assert "missing --repo-dir exits 2" "[ \"\$(cat '$root/rc')\" = 2 ]"
  run_install "$root" --repo-dir
  assert "--repo-dir with no value exits 2" "[ \"\$(cat '$root/rc')\" = 2 ]"
  run_install "$root" --repo-dir "$root/repo" --bogus
  assert "an unknown flag exits 2" "[ \"\$(cat '$root/rc')\" = 2 ]"
  assert "no usage error wrote a plist" "[ ! -f '$plist' ]"
  assert "no usage error called launchctl" "[ ! -s '$root/launchctl.log' ]"

  rm -rf "$root"
}

# ── Test 4: checkout validation fails before any write ──────────────────────

test_4_checkout_validation() {
  section "Test 4: a non-git or origin-less checkout exits 1 with no writes"

  local root plist
  root="$(make_env Darwin)"
  plist="$root/home/Library/LaunchAgents/${LABEL}.plist"

  mkdir -p "$root/not-a-repo"
  run_install "$root" --repo-dir "$root/not-a-repo"
  assert "a non-git directory exits 1" "[ \"\$(cat '$root/rc')\" = 1 ]"
  assert "and says it is not a git checkout" "grep -q 'not inside a git checkout' '$root/out'"

  run_install "$root" --repo-dir "$root/does-not-exist"
  assert "a missing directory exits 1" "[ \"\$(cat '$root/rc')\" = 1 ]"

  git init -q "$root/no-origin"
  run_install "$root" --repo-dir "$root/no-origin"
  assert "a checkout without origin exits 1" "[ \"\$(cat '$root/rc')\" = 1 ]"
  assert "and names the missing origin" "grep -q 'no origin remote' '$root/out'"

  assert "no plist was written" "[ ! -f '$plist' ]"
  assert "no launchctl call was made" "[ ! -s '$root/launchctl.log' ]"

  rm -rf "$root"
}

# ── Test 5: runner selection ─────────────────────────────────────────────────

test_5_runner_selection() {
  section "Test 5: the complete skills-worktree runner wins; an incomplete one does not"

  local root plist wt
  root="$(make_env Darwin)"
  plist="$root/home/Library/LaunchAgents/${LABEL}.plist"
  wt="$root/home/.claude/skills-worktree/.claude/scripts"

  seed_runner "$wt" issue-dedup.sh
  run_install "$root" --repo-dir "$root/repo"
  assert "a worktree copy missing a helper is skipped for this checkout's copy" \
    "[ \"\$(program_args '$plist' | sed -n 2p)\" = '$REPO_ROOT/.claude/scripts/backfill-review.sh' ]"
  assert "and the output says the copy is NOT pinned to main" "grep -q 'NOT pinned to main' '$root/out'"

  seed_runner "$wt"
  run_install "$root" --repo-dir "$root/repo"
  assert "a complete worktree copy is chosen" \
    "[ \"\$(program_args '$plist' | sed -n 2p)\" = '$wt/backfill-review.sh' ]"
  assert "and the output says it is pinned to main" "grep -q 'pinned to main' '$root/out'"

  rm -rf "$root"
}

# ── Test 6: a missing required tool fails before any write ──────────────────

test_6_missing_required_tool() {
  section "Test 6: a missing required tool (gh) exits 1 with no writes"

  local root sys t p plist
  root="$(make_env Darwin)"
  plist="$root/home/Library/LaunchAgents/${LABEL}.plist"
  # A PATH holding only what the installer needs, minus gh: symlink each tool.
  sys="$root/sys"; mkdir -p "$sys"
  for t in git jq python3 dirname date id mkdir sed mktemp mv cp chmod rm awk basename cat; do
    p="$(command -v "$t" 2>/dev/null || true)"
    [[ -n "$p" ]] && ln -s "$p" "$sys/$t"
  done
  rm -f "$root/tools/gh"

  PATH="$root/bin:$root/tools:$sys" HOME="$root/home" LAUNCHCTL_LOG="$root/launchctl.log" \
    "$(command -v bash)" "$INSTALL" --repo-dir "$root/repo" > "$root/out" 2>&1
  local rc=$?
  assert "install exits 1 without gh" "[ $rc -eq 1 ]"
  assert "and names gh" "grep -q 'gh not found' '$root/out'"
  assert "no plist was written" "[ ! -f '$plist' ]"
  assert "no launchctl call was made" "[ ! -s '$root/launchctl.log' ]"

  rm -rf "$root"
}

# ── Test 7: launchctl failure branches ──────────────────────────────────────

test_7_launchctl_failures() {
  section "Test 7: bootstrap rolls back, enable is fatal, kickstart only warns"

  local root plist rc
  root="$(make_env Darwin)"
  plist="$root/home/Library/LaunchAgents/${LABEL}.plist"

  # A previous install to roll back to.
  run_install "$root" --repo-dir "$root/repo" --interval 600
  cp "$plist" "$root/prev.plist"

  : > "$root/launchctl.log"
  PATH="$root/bin:$root/tools:$PATH" HOME="$root/home" LAUNCHCTL_LOG="$root/launchctl.log" \
    LAUNCHCTL_FAIL_CMD=bootstrap bash "$INSTALL" --repo-dir "$root/repo" > "$root/out" 2>&1
  rc=$?
  assert "a refused bootstrap exits 1" "[ $rc -eq 1 ]"
  assert "the previous plist is restored byte for byte" "cmp -s '$root/prev.plist' '$plist'"
  assert "no .prev backup is left behind" \
    "[ -z \"\$(ls '$root/home/Library/LaunchAgents' | grep '\\.prev\\.')\" ]"

  PATH="$root/bin:$root/tools:$PATH" HOME="$root/home" LAUNCHCTL_LOG="$root/launchctl.log" \
    LAUNCHCTL_FAIL_CMD=enable bash "$INSTALL" --repo-dir "$root/repo" > "$root/out" 2>&1
  rc=$?
  assert "a refused enable exits 1" "[ $rc -eq 1 ]"
  assert "and prints the enable recovery command" "grep -q 'launchctl enable gui/' '$root/out'"

  PATH="$root/bin:$root/tools:$PATH" HOME="$root/home" LAUNCHCTL_LOG="$root/launchctl.log" \
    LAUNCHCTL_FAIL_CMD=kickstart bash "$INSTALL" --repo-dir "$root/repo" > "$root/out" 2>&1
  rc=$?
  assert "a refused kickstart still exits 0" "[ $rc -eq 0 ]"
  assert "and warns about it" "grep -q '^WARN: launchctl kickstart' '$root/out'"

  PATH="$root/bin:$root/tools:$PATH" HOME="$root/home" LAUNCHCTL_LOG="$root/launchctl.log" \
    LAUNCHCTL_LIST_LABEL="${LABEL}-test" bash "$INSTALL" --repo-dir "$root/repo" > "$root/out" 2>&1
  rc=$?
  assert "a lookalike label in launchctl list fails verification" "[ $rc -eq 1 ]"

  rm -rf "$root"
}

# ── Test 8: uninstall keeps the ledger ──────────────────────────────────────

test_8_uninstall() {
  section "Test 8: uninstall unloads, removes the plist and keeps the ledger"

  local root home plist out rc
  root="$(make_env Darwin)"
  home="$root/home"
  plist="$home/Library/LaunchAgents/${LABEL}.plist"
  run_install "$root" --repo-dir "$root/repo"
  printf '{"schema_version":1,"entries":[]}\n' > "$home/.claude/unreviewed-merges.json"
  : > "$root/launchctl.log"

  out="$(PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
        LAUNCHCTL_LIST_EMPTY=1 bash "$UNINSTALL" 2>&1)"
  rc=$?
  assert "uninstall exits 0" "[ $rc -eq 0 ]"
  assert "uninstall reports PASS" "grep -q '^PASS:' <<<\"\$out\""
  assert "the plist was removed" "[ ! -f '$plist' ]"
  assert "bootout ran" "grep -q '^bootout ' '$root/launchctl.log'"
  assert "the ledger is still in place" "[ -s '$home/.claude/unreviewed-merges.json' ]"
  assert "uninstall says the ledger was kept" "grep -q 'Ledger kept' <<<\"\$out\""

  PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
    bash "$UNINSTALL" >/dev/null 2>&1
  rc=$?
  assert "a job still listed after bootout exits 1" "[ $rc -eq 1 ]"

  PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
    LAUNCHCTL_FAIL_CMD=list bash "$UNINSTALL" >/dev/null 2>&1
  rc=$?
  assert "a failing launchctl list fails closed (exit 1)" "[ $rc -eq 1 ]"

  PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
    bash "$UNINSTALL" --bogus >/dev/null 2>&1
  rc=$?
  assert "an unknown flag exits 2" "[ $rc -eq 2 ]"

  rm -rf "$root"
}

# ── Test 9: non-Darwin platform guard ───────────────────────────────────────

test_9_platform_guard() {
  section "Test 9: non-Darwin hosts — both scripts exit 1 and touch nothing"

  local root home rc out
  root="$(make_env Linux)"
  home="$root/home"

  run_install "$root" --repo-dir "$root/repo"
  assert "installer exits 1 on a non-Darwin host" "[ \"\$(cat '$root/rc')\" = 1 ]"
  assert "installer says it is macOS-only" "grep -q 'macOS-only' '$root/out'"

  out="$(PATH="$root/bin:$PATH" HOME="$home" LAUNCHCTL_LOG="$root/launchctl.log" \
        bash "$UNINSTALL" 2>&1)"
  rc=$?
  assert "uninstaller exits 1 on a non-Darwin host" "[ $rc -eq 1 ]"
  assert "uninstaller says it is macOS-only" "grep -q 'macOS-only' <<<\"\$out\""

  out="$(env -u HOME PATH="$root/bin:$PATH" bash "$UNINSTALL" 2>&1)"
  rc=$?
  assert "uninstaller takes the guard path with HOME unset" \
    "[ $rc -eq 1 ] && grep -q 'macOS-only' <<<\"\$out\""
  out="$(env -u HOME PATH="$root/bin:$PATH" bash "$INSTALL" --repo-dir "$root/repo" 2>&1)"
  rc=$?
  assert "installer takes the guard path with HOME unset" \
    "[ $rc -eq 1 ] && grep -q 'macOS-only' <<<\"\$out\""

  assert "no plist was written" "[ ! -d '$home/Library/LaunchAgents' ]"
  assert "no launchctl call was made" "[ ! -s '$root/launchctl.log' ]"

  rm -rf "$root"
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}install/uninstall-backfill-review.sh test suite (issue #1941)${NC}"

test_1_install_renders_and_loads
test_2_special_char_checkout
test_3_arguments
test_4_checkout_validation
test_5_runner_selection
test_6_missing_required_tool
test_7_launchctl_failures
test_8_uninstall
test_9_platform_guard

echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
if [ $FAIL -eq 0 ]; then
  echo -e "${GREEN}${BOLD}ALL PASSED${NC}: $PASS/$TOTAL tests"
  exit 0
else
  echo -e "${RED}${BOLD}FAILURES${NC}: $FAIL/$TOTAL tests failed ($PASS passed)"
  exit 1
fi
