#!/usr/bin/env bash
# handoff-scoping.test.sh — Tests for per-repo handoff scoping (issue #655).
#
# Coverage:
#   - --path mode: returns correct scoped or flat path
#   - --owner-repo flag: two repos at same PR number produce different paths
#   - --create / --get with scoped path
#   - Read-time owner_repo assertion (soft warn, not fail)
#   - Migration (handoff-migrate.sh): moves flat files, never deletes, idempotent
#   - Backward compat: flat fallback when --owner-repo not provided
#
# Discovered by CI auto-detection (hook-scripts.yml) — no workflow edits needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HANDOFF_STATE="${SCRIPT_DIR}/../handoff-state.sh"
MIGRATE="${SCRIPT_DIR}/../handoff-migrate.sh"

PASS=0
FAIL=0

ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail(){ echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
check() {
  local desc="$1"; local expected="$2"; local actual="$3"
  if [[ "$actual" == "$expected" ]]; then ok "$desc"
  else fail "$desc (expected: '$expected', got: '$actual')"; fi
}
check_contains() {
  local desc="$1"; local pattern="$2"; local actual="$3"
  if echo "$actual" | grep -qE "$pattern"; then ok "$desc"
  else fail "$desc (expected pattern '$pattern' not found in: '$actual')"; fi
}

# ---------------------------------------------------------------------------
# Setup: isolated tmp HOME so the script resolves $HOME/.claude/handoffs
# into our temp directory.  The script computes:
#   HANDOFF_DIR="${HOME}/.claude/handoffs"
# so we must set HOME and create .claude/handoffs/ there.
# ---------------------------------------------------------------------------
TMP_DIR="$(mktemp -d)"
export HOME="$TMP_DIR"
HANDOFF_DIR="${TMP_DIR}/.claude/handoffs"
mkdir -p "$HANDOFF_DIR"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. --path mode — flat (no --owner-repo)
# ---------------------------------------------------------------------------
echo ""
echo "=== 1. --path: flat (no --owner-repo) ==="
path_flat="$("$HANDOFF_STATE" --path 42)"
check "--path flat returns correct path" \
  "${HANDOFF_DIR}/pr-42-handoff.json" "$path_flat"

# ---------------------------------------------------------------------------
# 2. --path mode — scoped (with --owner-repo)
# ---------------------------------------------------------------------------
echo ""
echo "=== 2. --path: scoped (--owner-repo) ==="
path_scoped="$("$HANDOFF_STATE" --owner-repo "alice/myrepo" --path 42)"
check "--path scoped returns correct path" \
  "${HANDOFF_DIR}/alice/myrepo/pr-42-handoff.json" "$path_scoped"

# Two different repos, same PR number — different paths.
path_b="$("$HANDOFF_STATE" --owner-repo "bob/otherrepo" --path 42)"
check "--path: different repos at same PR produce different paths" \
  "${HANDOFF_DIR}/bob/otherrepo/pr-42-handoff.json" "$path_b"
if [[ "$path_scoped" != "$path_b" ]]; then ok "scoped paths do not collide"
else fail "scoped paths collide!"; fi

# ---------------------------------------------------------------------------
# 3. --owner-repo validation
# ---------------------------------------------------------------------------
echo ""
echo "=== 3. --owner-repo validation ==="
# Missing value
if ! out="$("$HANDOFF_STATE" --owner-repo "" --path 1 2>&1)"; then
  ok "--owner-repo '' is rejected"
else fail "--owner-repo '' should be rejected (got: $out)"; fi

# No slash
if ! out="$("$HANDOFF_STATE" --owner-repo "nodash" --path 1 2>&1)"; then
  ok "--owner-repo 'nodash' (no slash) is rejected"
else fail "--owner-repo 'nodash' should be rejected"; fi

# Path traversal
if ! out="$("$HANDOFF_STATE" --owner-repo "../evil/repo" --path 1 2>&1)"; then
  ok "--owner-repo '../evil/repo' is rejected"
else fail "--owner-repo '../evil/repo' should be rejected"; fi

# ---------------------------------------------------------------------------
# 4. --create / --get with scoped path
# ---------------------------------------------------------------------------
echo ""
echo "=== 4. --create / --get scoped ==="
BODY_A='{"schema_version":"1.0","pr_number":42,"head_sha":"aaaa","owner_repo":"alice/myrepo","phase_completed":"A"}'
BODY_B='{"schema_version":"1.0","pr_number":42,"head_sha":"bbbb","owner_repo":"bob/otherrepo","phase_completed":"A"}'

"$HANDOFF_STATE" --owner-repo "alice/myrepo" --create 42 "$BODY_A"
"$HANDOFF_STATE" --owner-repo "bob/otherrepo" --create 42 "$BODY_B"

# alice file exists at the scoped path
if [[ -f "${HANDOFF_DIR}/alice/myrepo/pr-42-handoff.json" ]]; then
  ok "alice/myrepo scoped file created"
else fail "alice/myrepo scoped file missing"; fi

# bob file exists at the scoped path
if [[ -f "${HANDOFF_DIR}/bob/otherrepo/pr-42-handoff.json" ]]; then
  ok "bob/otherrepo scoped file created"
else fail "bob/otherrepo scoped file missing"; fi

# flat path must NOT exist
if [[ ! -f "${HANDOFF_DIR}/pr-42-handoff.json" ]]; then
  ok "flat path not created when --owner-repo is used"
else fail "flat path was erroneously created"; fi

# Read back correct content per repo
sha_a="$("$HANDOFF_STATE" --owner-repo "alice/myrepo" --get 42 | jq -r '.head_sha')"
sha_b="$("$HANDOFF_STATE" --owner-repo "bob/otherrepo" --get 42 | jq -r '.head_sha')"
check "--get alice sha" "aaaa" "$sha_a"
check "--get bob sha"   "bbbb" "$sha_b"

# ---------------------------------------------------------------------------
# 5. Read-time owner_repo assertion (soft warn, not fail)
# Create a file at scoped path X but with a different owner_repo in the JSON.
# ---------------------------------------------------------------------------
echo ""
echo "=== 5. Read-time owner_repo assertion ==="
# Write a file at charlie/repo path with a mismatched stored owner_repo.
mkdir -p "${HANDOFF_DIR}/charlie/repo"
printf '%s\n' '{"owner_repo":"wrong/owner","pr_number":77,"head_sha":"zzz"}' \
  > "${HANDOFF_DIR}/charlie/repo/pr-77-handoff.json"
warn_out="$("$HANDOFF_STATE" --owner-repo "charlie/repo" --get 77 2>&1 >/dev/null || true)"
check_contains "mismatch warning emitted" "owner_repo mismatch" "$warn_out"

# Content still returned (--get exits 0 even on mismatch warning)
sha_warn="$("$HANDOFF_STATE" --owner-repo "charlie/repo" --get 77 2>/dev/null | jq -r '.head_sha')"
check "content still returned despite mismatch" "zzz" "$sha_warn"

# ---------------------------------------------------------------------------
# 6. Backward compat: flat path when --owner-repo not provided
# ---------------------------------------------------------------------------
echo ""
echo "=== 6. Backward compat: flat path ==="
BODY_FLAT='{"schema_version":"1.0","pr_number":99,"head_sha":"cccc","phase_completed":"B"}'
"$HANDOFF_STATE" --create 99 "$BODY_FLAT"
if [[ -f "${HANDOFF_DIR}/pr-99-handoff.json" ]]; then
  ok "flat file created when no --owner-repo"
else fail "flat file missing"; fi
sha_flat="$("$HANDOFF_STATE" --get 99 | jq -r '.head_sha')"
check "flat file readable without --owner-repo" "cccc" "$sha_flat"

# ---------------------------------------------------------------------------
# 7. --set with scoped path
# ---------------------------------------------------------------------------
echo ""
echo "=== 7. --set with scoped path ==="
"$HANDOFF_STATE" --owner-repo "alice/myrepo" --set 42 ".head_sha=updated_sha"
sha_updated="$("$HANDOFF_STATE" --owner-repo "alice/myrepo" --get 42 | jq -r '.head_sha')"
check "--set updates scoped file" "updated_sha" "$sha_updated"
# Bob's file unchanged
sha_b_after="$("$HANDOFF_STATE" --owner-repo "bob/otherrepo" --get 42 | jq -r '.head_sha')"
check "--set does not affect other repo" "bbbb" "$sha_b_after"

# ---------------------------------------------------------------------------
# 8. --delete with scoped path
# ---------------------------------------------------------------------------
echo ""
echo "=== 8. --delete scoped ==="
"$HANDOFF_STATE" --owner-repo "alice/myrepo" --delete 42
if [[ ! -f "${HANDOFF_DIR}/alice/myrepo/pr-42-handoff.json" ]]; then
  ok "--delete removes scoped file"
else fail "--delete did not remove scoped file"; fi
if [[ -f "${HANDOFF_DIR}/bob/otherrepo/pr-42-handoff.json" ]]; then
  ok "--delete only removes the correct repo's file"
else fail "--delete also removed bob/otherrepo file!"; fi

# ---------------------------------------------------------------------------
# 9. Migration (handoff-migrate.sh)
# ---------------------------------------------------------------------------
echo ""
echo "=== 9. Migration ==="

MIGRATE_TMP="$(mktemp -d)"
migrate_cleanup() { rm -rf "$MIGRATE_TMP"; }
trap "cleanup; migrate_cleanup" EXIT

# handoff-migrate.sh uses $HOME/.claude/handoffs — set HOME for that subshell
MIG_HANDOFF_DIR="${MIGRATE_TMP}/.claude/handoffs"
mkdir -p "$MIG_HANDOFF_DIR"
mkdir -p "${MIGRATE_TMP}/.claude"

# Flat file with embedded owner_repo
cat > "${MIG_HANDOFF_DIR}/pr-101-handoff.json" <<'JSON'
{"schema_version":"1.0","pr_number":101,"head_sha":"aaa","owner_repo":"org/repoa","phase_completed":"A"}
JSON

# Flat file without owner_repo (attributed via session-state)
cat > "${MIG_HANDOFF_DIR}/pr-102-handoff.json" <<'JSON'
{"schema_version":"1.0","pr_number":102,"head_sha":"bbb","phase_completed":"A"}
JSON

# Create a fake state file with attribution for PR 102
cat > "${MIGRATE_TMP}/.claude/session-state.json" <<'JSON'
{
  "repos": {
    "org/repob": {
      "prs": {
        "102": { "head_sha": "bbb", "owner_repo": "org/repob" }
      }
    }
  }
}
JSON

# Dry-run: no files moved
DRY_OUT="$(HOME="$MIGRATE_TMP" "$MIGRATE" 2>&1)"
check_contains "dry-run reports WOULD MOVE for pr-101" "WOULD MOVE.*pr-101" "$DRY_OUT"
if [[ -f "${MIG_HANDOFF_DIR}/pr-101-handoff.json" ]]; then
  ok "dry-run did not move pr-101"
else fail "dry-run moved pr-101 (should not have)"; fi

# Apply migration
HOME="$MIGRATE_TMP" "$MIGRATE" --apply
if [[ -f "${MIG_HANDOFF_DIR}/org/repoa/pr-101-handoff.json" ]]; then
  ok "pr-101 migrated to scoped path"
else fail "pr-101 not migrated"; fi
if [[ ! -f "${MIG_HANDOFF_DIR}/pr-101-handoff.json" ]]; then
  ok "flat pr-101 removed after migration"
else fail "flat pr-101 still present after migration"; fi

if [[ -f "${MIG_HANDOFF_DIR}/org/repob/pr-102-handoff.json" ]]; then
  ok "pr-102 migrated using session-state attribution"
else fail "pr-102 not migrated via session-state"; fi

# ---------------------------------------------------------------------------
# 9b. Migration: unattributable file goes to _unknown
# ---------------------------------------------------------------------------
echo ""
echo "=== 9b. Migration: unattributable -> _unknown ==="
MIG2_TMP="$(mktemp -d)"
mig2_cleanup() { rm -rf "$MIG2_TMP"; }
trap "cleanup; migrate_cleanup; mig2_cleanup" EXIT
MIG2_DIR="${MIG2_TMP}/.claude/handoffs"
mkdir -p "$MIG2_DIR"
cat > "${MIG2_DIR}/pr-999-handoff.json" <<'JSON'
{"schema_version":"1.0","pr_number":999,"head_sha":"zzz","phase_completed":"A"}
JSON
HOME="$MIG2_TMP" "$MIGRATE" --apply
if [[ -f "${MIG2_DIR}/_unknown/pr-999-handoff.json" ]]; then
  ok "unattributable file moved to _unknown"
else fail "unattributable file not moved to _unknown"; fi
if [[ ! -f "${MIG2_DIR}/pr-999-handoff.json" ]]; then
  ok "flat pr-999 removed after _unknown migration"
else fail "flat pr-999 still present"; fi

# ---------------------------------------------------------------------------
# 9c. Migration: idempotent (re-run is a no-op)
# ---------------------------------------------------------------------------
echo ""
echo "=== 9c. Migration: idempotent re-run ==="
HOME="$MIGRATE_TMP" "$MIGRATE" --apply
if [[ -f "${MIG_HANDOFF_DIR}/org/repoa/pr-101-handoff.json" ]]; then
  ok "re-run preserved migrated pr-101"
else fail "re-run broke pr-101"; fi

# ---------------------------------------------------------------------------
# 10. Case-divergence regression (issue #704) — mixed-case --owner-repo
#     must produce a lowercase path, not a case-preserved one.
# ---------------------------------------------------------------------------
echo ""
echo "=== 10. Mixed-case --owner-repo produces lowercase path (issue #704) ==="

path_mc="$("$HANDOFF_STATE" --owner-repo "AuerbachB/Skingod" --path 77)"
check "--path with mixed-case --owner-repo is lowercased" \
  "${HANDOFF_DIR}/auerbachb/skingod/pr-77-handoff.json" "$path_mc"

# Two callers using different-case spellings of the same repo must resolve
# to the same path and therefore the same file (no split-state).
path_mc_lc="$("$HANDOFF_STATE" --owner-repo "auerbachb/skingod" --path 77)"
check "lowercase and mixed-case --owner-repo resolve to the same path" \
  "$path_mc_lc" "$path_mc"

# Create via mixed-case slug; verify the file lands in the lowercase directory.
BODY_MC='{"schema_version":"1.0","pr_number":77,"head_sha":"mc01","owner_repo":"AuerbachB/Skingod","phase_completed":"A"}'
"$HANDOFF_STATE" --owner-repo "AuerbachB/Skingod" --create 77 "$BODY_MC"
if [[ -f "${HANDOFF_DIR}/auerbachb/skingod/pr-77-handoff.json" ]]; then
  ok "file created at lowercase path despite mixed-case --owner-repo"
else fail "file NOT created at lowercase path"; fi
# Use ls -1 rather than [[ -d ]] to check the on-disk case-preserved name.
# On macOS (case-insensitive filesystem), [[ -d "${HANDOFF_DIR}/AuerbachB" ]]
# returns true even when only auerbachb/ exists, because the filesystem treats
# the two names as identical.  ls -1 + grep -qx matches the literal entry name.
if ! ls -1 "${HANDOFF_DIR}" | grep -qx 'AuerbachB'; then
  ok "no mixed-case directory created"
else fail "mixed-case directory AuerbachB/ was erroneously created"; fi

# Read back via lowercase slug must work (same file).
sha_mc="$("$HANDOFF_STATE" --owner-repo "auerbachb/skingod" --get 77 | jq -r '.head_sha')"
check "--get via lowercase slug reads file created with mixed-case slug" "mc01" "$sha_mc"

# ---------------------------------------------------------------------------
# 11. Migration: mixed-case embedded owner_repo → lowercase scoped path
# ---------------------------------------------------------------------------
echo ""
echo "=== 11. Migration: mixed-case owner_repo migrates to lowercase path ==="

MIG3_TMP="$(mktemp -d)"
mig3_cleanup() { rm -rf "$MIG3_TMP"; }
trap "cleanup; migrate_cleanup; mig2_cleanup; mig3_cleanup" EXIT
MIG3_DIR="${MIG3_TMP}/.claude/handoffs"
mkdir -p "$MIG3_DIR"

# Flat file with a mixed-case embedded owner_repo.
cat > "${MIG3_DIR}/pr-301-handoff.json" <<'JSON'
{"schema_version":"1.0","pr_number":301,"head_sha":"mc02","owner_repo":"AuerbachB/Skingod","phase_completed":"A"}
JSON

HOME="$MIG3_TMP" "$MIGRATE" --apply

if [[ -f "${MIG3_DIR}/auerbachb/skingod/pr-301-handoff.json" ]]; then
  ok "mixed-case owner_repo migrated to lowercase scoped path"
else fail "mixed-case owner_repo NOT migrated to lowercase path"; fi

# Same case-insensitive-filesystem caveat as test 10: use ls -1 + grep -qx.
if ! ls -1 "${MIG3_DIR}" | grep -qx 'AuerbachB'; then
  ok "no mixed-case directory created during migration"
else fail "migration created a mixed-case directory AuerbachB/"; fi

if [[ ! -f "${MIG3_DIR}/pr-301-handoff.json" ]]; then
  ok "flat file removed after migration"
else fail "flat file still present after migration"; fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
