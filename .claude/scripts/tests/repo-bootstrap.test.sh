#!/usr/bin/env bash
# Tests for repo-bootstrap.sh — file-set check/apply/report behavior.
#
# Covers: all files present, one file missing, all files missing,
# write failure mid-set, --help output, and exit-code contract.
#
# Requires: git, bash. Run from repo root:
#   bash .claude/scripts/tests/repo-bootstrap.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/.claude/scripts/repo-bootstrap.sh"

TMP="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP" "$TMP_HOME"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }

check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$desc"
  else
    fail "$desc (expected '$expected', got '$actual')"
  fi
}

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc (missing '$needle' in output)"
  fi
}

check_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc (unexpected '$needle' found in output)"
  fi
}

# Portable checksum: use md5 on macOS, md5sum on Linux.
file_checksum() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$1" | awk '{print $1}'
  else
    md5 -q "$1"
  fi
}

# --------------------------------------------------------------------------
# Stub gh and jq via a fake-bin directory on PATH.
# The SUT calls:
#   gh repo view --json nameWithOwner --jq '.nameWithOwner'  → owner/repo string
#   gh api repos/.../branches/main/protection/...            → simulate 404 (BP not configured)
# --------------------------------------------------------------------------
FAKE_BIN="$TMP/fake-bin"
mkdir -p "$FAKE_BIN"

# gh stub: route repo view (return plain owner/repo string) and api (404 for BP).
# The real `gh` CLI processes --jq and returns filtered output; our stub returns
# the string directly so the SUT sees what gh would produce.
cat > "$FAKE_BIN/gh" <<'STUB_EOF'
#!/usr/bin/env bash
if [[ "$1" == "repo" && "$2" == "view" ]]; then
  printf 'test-owner/test-repo\n'
  exit 0
fi
if [[ "$1" == "api" ]]; then
  # Simulate 404: branch protection not configured
  printf 'HTTP 404: Branch not protected\n' >&2
  exit 1
fi
printf 'stub-gh: unhandled: %s\n' "$*" >&2
exit 1
STUB_EOF
chmod +x "$FAKE_BIN/gh"

# jq stub: the SUT calls jq only after a gh api success (200). Since our gh stub
# always returns 404 for api calls, jq is never called in these tests — provide
# a no-op that exits 0 so the jq presence check passes.
cat > "$FAKE_BIN/jq" <<'STUB_EOF'
#!/usr/bin/env bash
# No-op stub: SUT only calls jq on a successful gh api response (200),
# which our gh stub never returns. Exit 0 to pass the presence check.
exit 0
STUB_EOF
chmod +x "$FAKE_BIN/jq"

export PATH="$FAKE_BIN:$PATH"

# Build a minimal git repo for the SUT to run in (needs git rev-parse --show-toplevel).
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git init -q -b main "$dir" 2>/dev/null || git init -q "$dir"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  printf 'init\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m "init"
}

# Derived from BOOTSTRAP_FILES in repo-bootstrap.sh — no second enumeration.
ALL_FILES=()
while IFS= read -r _entry; do
  ALL_FILES+=("${_entry%%|*}")
done < <(sed -n '/^BOOTSTRAP_FILES=(/,/^)/p' "$SUT" | grep -oE '"[^"]+\|[0-9]+"' | tr -d '"')
if [[ "${#ALL_FILES[@]}" -eq 0 ]]; then
  echo "FAIL — could not parse BOOTSTRAP_FILES from $SUT" >&2
  exit 1
fi

# --------------------------------------------------------------------------
# Case 1: all files present → --check exits 0, all [OK]
# --------------------------------------------------------------------------
REPO1="$TMP/repo-all-present"
make_repo "$REPO1"
for f in "${ALL_FILES[@]}"; do
  mkdir -p "$REPO1/$(dirname "$f")"
  printf 'stub\n' > "$REPO1/$f"
done

OUT=$(cd "$REPO1" && bash "$SUT" --check 2>&1)
RC=$?
# Our gh stub returns 404 for branch protection, so a BP gap remains → exit 1.
# The file set must all be [OK] (no files missing), only the BP gap causes exit 1.
check_eq "case1: all files present, exits 1 (BP gap from stub 404)" "1" "$RC"
check_contains "case1: report has [OK] lines" "[OK]" "$OUT"
check_not_contains "case1: no [INSTALLED] lines" "[INSTALLED]" "$OUT"
# The Provisioned Files section must have no [MISSING] lines
PROVISIONED_SECTION="$(printf '%s\n' "$OUT" | sed -n '/^Provisioned Files:/,/^[A-Z]/p')"
check_not_contains "case1: no [MISSING] in Provisioned Files section" "[MISSING]" "$PROVISIONED_SECTION"
# Each file must appear in the output
for f in "${ALL_FILES[@]}"; do
  check_contains "case1: $f appears in output" "$f" "$OUT"
done

# --------------------------------------------------------------------------
# Case 2: one file missing (ac-gate.yml absent) → --check exits 1
# --------------------------------------------------------------------------
REPO2="$TMP/repo-one-missing"
make_repo "$REPO2"
for f in "${ALL_FILES[@]}"; do
  [[ "$f" == ".github/workflows/ac-gate.yml" ]] && continue
  mkdir -p "$REPO2/$(dirname "$f")"
  printf 'stub\n' > "$REPO2/$f"
done

OUT=$(cd "$REPO2" && bash "$SUT" --check 2>&1)
RC=$?
check_eq "case2: one missing, --check exits 1" "1" "$RC"
check_contains "case2: [MISSING] for ac-gate.yml" "[MISSING]" "$OUT"
check_contains "case2: ac-gate.yml named in output" "ac-gate.yml" "$OUT"

# --------------------------------------------------------------------------
# Case 2b: --apply installs only the missing file, leaves others byte-identical
# --------------------------------------------------------------------------
BEFORE_CR_SUM="$(file_checksum "$REPO2/.github/workflows/cr-plan-on-issue.yml")"
BEFORE_ACSH_SUM="$(file_checksum "$REPO2/.claude/scripts/ac-gate.sh")"
BEFORE_PIREF_SUM="$(file_checksum "$REPO2/.claude/scripts/pr-issue-ref.sh")"

OUT=$(cd "$REPO2" && bash "$SUT" --apply 2>&1)
RC=$?
# Branch protection is still missing (simulated 404), so exit 1 expected
check_eq "case2b: --apply exits 1 (BP gap remains)" "1" "$RC"
check_contains "case2b: [INSTALLED] for ac-gate.yml" "[INSTALLED]" "$OUT"

if [[ -f "$REPO2/.github/workflows/ac-gate.yml" ]]; then
  pass "case2b: ac-gate.yml installed"
else
  fail "case2b: ac-gate.yml not installed"
fi

AFTER_CR_SUM="$(file_checksum "$REPO2/.github/workflows/cr-plan-on-issue.yml")"
AFTER_ACSH_SUM="$(file_checksum "$REPO2/.claude/scripts/ac-gate.sh")"
AFTER_PIREF_SUM="$(file_checksum "$REPO2/.claude/scripts/pr-issue-ref.sh")"

check_eq "case2b: cr-plan-on-issue.yml unchanged" "$BEFORE_CR_SUM" "$AFTER_CR_SUM"
check_eq "case2b: ac-gate.sh unchanged" "$BEFORE_ACSH_SUM" "$AFTER_ACSH_SUM"
check_eq "case2b: pr-issue-ref.sh unchanged" "$BEFORE_PIREF_SUM" "$AFTER_PIREF_SUM"

# pr-issue-ref.sh must remain executable (it was already there as a stub, so
# mode was whatever we set — check installed ac-gate.yml doesn't change others)
if [[ -f "$REPO2/.claude/scripts/pr-issue-ref.sh" ]]; then
  pass "case2b: pr-issue-ref.sh still exists"
else
  fail "case2b: pr-issue-ref.sh missing after apply"
fi

# --------------------------------------------------------------------------
# Case 2c: --apply on an empty repo installs all files including 755 for pr-issue-ref.sh
# --------------------------------------------------------------------------
REPO2C="$TMP/repo-install-all"
make_repo "$REPO2C"

OUT=$(cd "$REPO2C" && bash "$SUT" --apply 2>&1)
RC=$?
check_eq "case2c: install all, exits 1 (BP gap remains)" "1" "$RC"

# pr-issue-ref.sh must be mode 755 (executable) after installation
if [[ -x "$REPO2C/.claude/scripts/pr-issue-ref.sh" ]]; then
  pass "case2c: pr-issue-ref.sh is executable after install"
else
  fail "case2c: pr-issue-ref.sh not executable after install"
fi

# All installed files must exist
for f in "${ALL_FILES[@]}"; do
  if [[ -f "$REPO2C/$f" ]]; then
    pass "case2c: $f installed"
  else
    fail "case2c: $f missing after install-all"
  fi
done

# --------------------------------------------------------------------------
# Case 3: all files missing → --check exits 1, lists ALL of them
# --------------------------------------------------------------------------
REPO3="$TMP/repo-all-missing"
make_repo "$REPO3"

OUT=$(cd "$REPO3" && bash "$SUT" --check 2>&1)
RC=$?
check_eq "case3: all missing, --check exits 1" "1" "$RC"

MISSING_LINES="$(printf '%s\n' "$OUT" | grep -c '\[MISSING\]' || true)"
if [[ "$MISSING_LINES" -ge "${#ALL_FILES[@]}" ]]; then
  pass "case3: all ${#ALL_FILES[@]} files listed as [MISSING]"
else
  fail "case3: expected >= ${#ALL_FILES[@]} [MISSING] lines, got $MISSING_LINES"
fi

# --------------------------------------------------------------------------
# Case 4: write failure mid-set → exits 5, no partial install reported clean
#
# Two .github/workflows/* files install successfully first; the third
# (.claude/scripts/ac-gate.sh) fails because .claude/scripts is unwritable.
# This exercises the genuine mid-set failure path: at least one file is on
# disk before the script aborts, proving the exit-5 guard fires after
# successful partial installs, not only on the very first attempted write.
# --------------------------------------------------------------------------
REPO4="$TMP/repo-write-failure"
if [[ "$EUID" -eq 0 ]]; then
  echo "skip — case4 requires a non-root runner (mode 555 does not block root writes)"
else
  make_repo "$REPO4"

  # Pre-create .claude/scripts as an unwritable directory.  mkdir -p succeeds
  # on an existing directory even at 555, so the script reaches the mktemp
  # step for ac-gate.sh and fails there — after both .github/workflows files
  # have already been installed.
  mkdir -p "$REPO4/.claude/scripts"
  chmod 555 "$REPO4/.claude/scripts"

  OUT=$(cd "$REPO4" && bash "$SUT" --apply 2>&1)
  RC=$?

  # Restore permissions so cleanup can remove the directory.
  chmod 755 "$REPO4/.claude/scripts"

  check_eq "case4: write failure exits 5" "5" "$RC"
  check_not_contains "case4: no [INSTALLED] lines on write failure" "[INSTALLED]" "$OUT"
  # The script exits 5 before printing the report, so no partial-install summary.
  check_not_contains "case4: no partial success message" "Branch protection gap remains" "$OUT"
  # Verify this is a genuine mid-set failure: the two .github/workflows/* files
  # must have been installed on disk before the failure on the third.
  check_eq "case4: cr-plan-on-issue.yml installed before failure" "1" \
    "$(test -f "$REPO4/.github/workflows/cr-plan-on-issue.yml" && echo 1 || echo 0)"
  check_eq "case4: ac-gate.yml installed before failure" "1" \
    "$(test -f "$REPO4/.github/workflows/ac-gate.yml" && echo 1 || echo 0)"
  check_contains "case4: write failure error names .claude/scripts" ".claude/scripts" "$OUT"
fi

# --------------------------------------------------------------------------
# Case 4c: symlink at target path → [SYMLINK] reported (not [OK]), gap exit,
#          --apply does not overwrite the symlink
# --------------------------------------------------------------------------
REPO4C="$TMP/repo-symlink-at-target"
make_repo "$REPO4C"
# Install all files except cr-plan-on-issue.yml (replaced by a symlink).
for f in "${ALL_FILES[@]}"; do
  [[ "$f" == ".github/workflows/cr-plan-on-issue.yml" ]] && continue
  mkdir -p "$REPO4C/$(dirname "$f")"
  printf 'stub\n' > "$REPO4C/$f"
done
# Place a symlink to an external regular file at the provisioned target path.
EXTERNAL_FILE="$TMP/external-file"
printf 'external\n' > "$EXTERNAL_FILE"
mkdir -p "$REPO4C/.github/workflows"
ln -s "$EXTERNAL_FILE" "$REPO4C/.github/workflows/cr-plan-on-issue.yml"

# --check: symlink is a gap → exit 1; report must show [SYMLINK], not [OK].
OUT=$(cd "$REPO4C" && bash "$SUT" --check 2>&1)
RC=$?
check_eq "case4c: --check exits 1 with symlink at target" "1" "$RC"
check_contains "case4c: [SYMLINK] reported for symlinked path" "[SYMLINK]" "$OUT"
SYMLINK_LINE="$(printf '%s\n' "$OUT" | grep "cr-plan-on-issue.yml")"
check_not_contains "case4c: symlink not classified as [OK]" "[OK]" "$SYMLINK_LINE"

# --apply: symlink must be skipped (not overwritten); [SYMLINK] still in report.
OUT=$(cd "$REPO4C" && bash "$SUT" --apply 2>&1)
RC=$?
check_eq "case4c: --apply exits 1 (symlink gap remains)" "1" "$RC"
check_contains "case4c: --apply still reports [SYMLINK]" "[SYMLINK]" "$OUT"
# The symlink must still exist and still point to the external file.
check_eq "case4c: --apply did not replace symlink with regular file" "1" \
  "$(test -L "$REPO4C/.github/workflows/cr-plan-on-issue.yml" && echo 1 || echo 0)"

check_eq "case4c: --apply preserved symlink destination" "$EXTERNAL_FILE" \
  "$(readlink "$REPO4C/.github/workflows/cr-plan-on-issue.yml")"
# --------------------------------------------------------------------------
# Case 5: --apply with all files present → exits 1 (only BP gap), no installs
# --------------------------------------------------------------------------
REPO5="$TMP/repo-all-present-apply"
make_repo "$REPO5"
for f in "${ALL_FILES[@]}"; do
  mkdir -p "$REPO5/$(dirname "$f")"
  printf 'stub\n' > "$REPO5/$f"
done

OUT=$(cd "$REPO5" && bash "$SUT" --apply 2>&1)
RC=$?
check_eq "case5: all present, --apply exits 1 (BP gap only)" "1" "$RC"
check_not_contains "case5: no [INSTALLED] lines when all present" "[INSTALLED]" "$OUT"

# --------------------------------------------------------------------------
# Case 6: --help output names the set, not individual file paths
# --------------------------------------------------------------------------
HELP_OUT=$(bash "$SUT" --help 2>&1)
HELP_RC=$?
# --help mentions the concept of provisioned files and the reference doc
check_contains "case6: --help mentions provisioned files concept" "Provisioned files" "$HELP_OUT"
check_contains "case6: --help mentions file-set reference" "repo-bootstrap-workflows" "$HELP_OUT"
check_eq "case6: --help exits 0" "0" "$HELP_RC"

# --------------------------------------------------------------------------
# Case 7: drift guard — installed content must match canonical sources
#
# For every entry in BOOTSTRAP_FILES, verify that the content repo-bootstrap.sh
# would provision (via get_file_content) is byte-for-byte identical to the
# canonical file at the same path in this repository.
#
# Strategy: install all files into a fresh repo via --apply, then diff each
# installed file against the canonical source in REPO_ROOT.  If any differ,
# the embedded heredoc has drifted from the canonical file.
# --------------------------------------------------------------------------
REPO7="$TMP/repo-drift-guard"
make_repo "$REPO7"

# --apply exits 1 when only the branch-protection gap remains; that is
# the expected outcome here — all files are installed and only the BP gap
# remains.  Capture the exit code so we can reject unexpected failures
# (e.g. exit 5 = write failure) without masking them with '|| true'.
cd "$REPO7" && bash "$SUT" --apply >/dev/null 2>&1; APPLY7_RC=$?
cd - >/dev/null
if [[ "$APPLY7_RC" -ne 0 && "$APPLY7_RC" -ne 1 ]]; then
  fail "case7: --apply exited $APPLY7_RC (expected 0 or 1 for BP-gap-only)"
fi

DRIFT_FOUND=0
for f in "${ALL_FILES[@]}"; do
  INSTALLED="$REPO7/$f"
  CANONICAL="$REPO_ROOT/$f"
  if [[ ! -f "$CANONICAL" ]]; then
    fail "case7: canonical source not found in this repo — $f"
    DRIFT_FOUND=1
    continue
  fi
  if [[ ! -f "$INSTALLED" ]]; then
    fail "case7: --apply did not install — $f"
    DRIFT_FOUND=1
    continue
  fi
  if diff -q "$CANONICAL" "$INSTALLED" >/dev/null 2>&1; then
    pass "case7: embedded copy matches canonical — $f"
  else
    fail "case7: drift detected — embedded copy in repo-bootstrap.sh differs from $f"
    DRIFT_FOUND=1
  fi
done
if [[ "$DRIFT_FOUND" -eq 0 ]]; then
  pass "case7: all provisioned files match their canonical sources in this repo"
fi

# --------------------------------------------------------------------------
# Case 8: telemetry must never change the exit contract (issue #1430)
#
# The usage-log append ran unguarded before argument parsing: with no
# ~/.claude under HOME, `set -e` killed the script at that line before
# --help or the usage error could answer, and an unset HOME died on the
# `set -u` expansion. Both must now fall through, with no bash redirect
# diagnostic on stderr (stderr-first ordering per issue #1406).
# --------------------------------------------------------------------------
RC=0
ERR="$(env -u HOME bash "$SUT" --help 2>&1 >/dev/null)" || RC=$?
check_eq "case8: --help exits 0 with HOME unset" "0" "$RC"
check_eq "case8: no stderr with HOME unset" "" "$ERR"

RC=0
ERR="$(HOME="$TMP/case8-no-such-home" bash "$SUT" not-a-flag 2>&1 >/dev/null)" || RC=$?
check_eq "case8: unknown arg still exits 2 when \$HOME/.claude is missing" "2" "$RC"
check_contains "case8: the script's own usage error is intact" "unknown argument" "$ERR"
check_not_contains "case8: no script-usage.log diagnostic leaks" "script-usage.log" "$ERR"

# Positive control: with the sandbox ~/.claude present the invocation logs.
: > "$HOME/.claude/script-usage.log"
bash "$SUT" --help >/dev/null 2>&1
check_eq "case8: append still lands when ~/.claude exists" "1" \
  "$(grep -c 'repo-bootstrap.sh' "$HOME/.claude/script-usage.log")"

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: repo-bootstrap.sh — file-set check/apply/report/failure paths locked in (issue #1282)"
