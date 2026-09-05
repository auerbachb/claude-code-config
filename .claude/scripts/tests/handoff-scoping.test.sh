#!/usr/bin/env bash
# handoff-scoping.test.sh — Tests for per-repo handoff scoping (issue #655).
# catalog: tests — Tests per-repo handoff path scoping in `handoff-state.sh`
#
# Coverage:
#   - --path mode: returns correct scoped or flat path
#   - --owner-repo flag: two repos at same PR number produce different paths
#   - --create / --get with scoped path
#   - Read-time owner_repo assertion (soft warn, not fail)
#   - Migration (handoff-migrate.sh): moves flat files, never deletes, idempotent
#   - Scope resolution (issue #1366): --owner-repo, then $CLAUDE_SESSION_REPO,
#     then the cwd origin; underivable + no flag refuses and writes nothing
#   - Legacy flat path reachable only via --legacy-flat / CLAUDE_HANDOFF_FLAT_OK=1
#   - --set rejects raw jq expressions rather than storing them (issue #1357)
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
# `--` before the pattern: a pattern that starts with a dash (e.g. "--owner-repo")
# is otherwise parsed by grep as options. `printf` rather than `echo` for the
# same reason on the input side.
check_contains() {
  local desc="$1"; local pattern="$2"; local actual="$3"
  if grep -qE -- "$pattern" <<<"$actual"; then ok "$desc"
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
# 1. --path mode — flat, reached by the explicit legacy escape (issue #1366)
#
#    Omitting --owner-repo no longer selects this path; it derives owner/repo
#    from the cwd or refuses (tests 13 and 14). --legacy-flat is now the only
#    flag-shaped way to ask for the flat layout.
# ---------------------------------------------------------------------------
echo ""
echo "=== 1. --path: flat (--legacy-flat) ==="
path_flat="$("$HANDOFF_STATE" --legacy-flat --path 42)"
check "--path --legacy-flat returns the flat path" \
  "${HANDOFF_DIR}/pr-42-handoff.json" "$path_flat"

# The two scope flags contradict each other, so asking for both is a usage
# error rather than a silent precedence rule.
both_rc=0
both_err="$("$HANDOFF_STATE" --owner-repo "alice/myrepo" --legacy-flat --path 42 2>&1 >/dev/null)" || both_rc=$?
check "--owner-repo + --legacy-flat exits 2" "2" "$both_rc"
check_contains "usage error names both flags" "mutually exclusive" "$both_err"

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
# 6. Legacy escape: --legacy-flat still reaches the flat path, silently
#    (issue #1366 — the flat layout survives, only its by-omission default is
#    gone, so pre-migration callers keep working when they say what they mean.)
# ---------------------------------------------------------------------------
echo ""
echo "=== 6. Legacy escape: --legacy-flat round-trip ==="
BODY_FLAT='{"schema_version":"1.0","pr_number":99,"head_sha":"cccc","phase_completed":"B"}'
flat_err="$("$HANDOFF_STATE" --legacy-flat --create 99 "$BODY_FLAT" 2>&1 >/dev/null)"
check "--legacy-flat write is silent" "" "$flat_err"
if [[ -f "${HANDOFF_DIR}/pr-99-handoff.json" ]]; then
  ok "flat file created with --legacy-flat"
else fail "flat file missing"; fi
sha_flat="$("$HANDOFF_STATE" --legacy-flat --get 99 | jq -r '.head_sha')"
check "flat file readable with --legacy-flat" "cccc" "$sha_flat"

# The env-var form of the same escape, for callers that cannot add a flag.
sha_flat_env="$(CLAUDE_HANDOFF_FLAT_OK=1 "$HANDOFF_STATE" --get 99 | jq -r '.head_sha')"
check "CLAUDE_HANDOFF_FLAT_OK=1 reaches the same file" "cccc" "$sha_flat_env"

# ...but it must never override a call that named its repo. The variable is
# ambient (exported around flat-layout sweeps); silently swallowing an explicit
# --owner-repo inside one would recreate the wrong-path write #1366 closes.
env_vs_flag="$(CLAUDE_HANDOFF_FLAT_OK=1 "$HANDOFF_STATE" --owner-repo "alice/myrepo" --path 99)"
check "explicit --owner-repo beats CLAUDE_HANDOFF_FLAT_OK" \
  "${HANDOFF_DIR}/alice/myrepo/pr-99-handoff.json" "$env_vs_flag"
env_vs_flag_err="$(CLAUDE_HANDOFF_FLAT_OK=1 "$HANDOFF_STATE" --owner-repo "alice/myrepo" --path 99 2>&1 >/dev/null)"
check_contains "and says the variable was overridden" \
  "CLAUDE_HANDOFF_FLAT_OK" "$env_vs_flag_err"

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
if ! grep -qx 'AuerbachB' <<<"$(ls -1 "${HANDOFF_DIR}")"; then
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
if ! grep -qx 'AuerbachB' <<<"$(ls -1 "${MIG3_DIR}")"; then
  ok "no mixed-case directory created during migration"
else fail "migration created a mixed-case directory AuerbachB/"; fi

if [[ ! -f "${MIG3_DIR}/pr-301-handoff.json" ]]; then
  ok "flat file removed after migration"
else fail "flat file still present after migration"; fi

# ---------------------------------------------------------------------------
# 12. Scoped write creates ONLY the scoped file (issue #1302, Test Plan item 1)
#
#     Section 4 asserts this for --create. The regression that shipped was in
#     --set/--append, so pin those two explicitly: a scoped write must never
#     leave a flat file behind for the next phase to diverge on.
# ---------------------------------------------------------------------------
echo ""
echo "=== 12. Scoped --set / --append leave no flat file (issue #1302) ==="

BODY_1302='{"schema_version":"1.0","pr_number":1302,"head_sha":"phaseA","owner_repo":"acme/widgets","reviewer":"cr","phase_completed":"A"}'
"$HANDOFF_STATE" --owner-repo "acme/widgets" --create 1302 "$BODY_1302"

# The Phase B write sequence, scoped.
"$HANDOFF_STATE" --owner-repo "acme/widgets" --set    1302 '.phase_completed="B"'
"$HANDOFF_STATE" --owner-repo "acme/widgets" --set    1302 '.reviewer=greptile'
"$HANDOFF_STATE" --owner-repo "acme/widgets" --set    1302 '.head_sha=phaseB'
"$HANDOFF_STATE" --owner-repo "acme/widgets" --append 1302 "threads_resolved" "PRRT_kwB"
"$HANDOFF_STATE" --owner-repo "acme/widgets" --append 1302 "files_changed"    "src/app.ts"

if [[ ! -f "${HANDOFF_DIR}/pr-1302-handoff.json" ]]; then
  ok "scoped --set/--append created no flat file"
else fail "scoped write leaked a flat file at ${HANDOFF_DIR}/pr-1302-handoff.json"; fi

# What a Phase C read of the scoped path sees (Test Plan items 2 and 3):
# Phase B's reviewer, Phase B's SHA, and the appended arrays — not Phase A's.
scoped_after="$("$HANDOFF_STATE" --owner-repo "acme/widgets" --get 1302)"
check "Phase C sees Phase B reviewer (greptile, not cr)" \
  "greptile" "$(echo "$scoped_after" | jq -r '.reviewer')"
check "Phase C sees Phase B head_sha" \
  "phaseB" "$(echo "$scoped_after" | jq -r '.head_sha')"
check "Phase C sees phase_completed=B" \
  "B" "$(echo "$scoped_after" | jq -r '.phase_completed')"
check "Phase C sees appended threads_resolved" \
  "PRRT_kwB" "$(echo "$scoped_after" | jq -r '.threads_resolved[0]')"
check "Phase C sees appended files_changed" \
  "src/app.ts" "$(echo "$scoped_after" | jq -r '.files_changed[0]')"

# ---------------------------------------------------------------------------
# 12b. The pre-fix failure mode, reproduced (issue #1302)
#
#      An unscoped write on the SAME PR number seeds a separate flat record and
#      leaves the scoped one untouched — the split-brain Phase C read.
# ---------------------------------------------------------------------------
echo ""
echo "=== 12b. Unscoped write diverges from the scoped record ==="

CLAUDE_HANDOFF_FLAT_OK=1 "$HANDOFF_STATE" --set 1302 '.reviewer=bugbot'

check "unscoped --set wrote the flat path" \
  "bugbot" "$("$HANDOFF_STATE" --legacy-flat --get 1302 | jq -r '.reviewer')"
check "scoped record was NOT updated by the unscoped write" \
  "greptile" "$("$HANDOFF_STATE" --owner-repo "acme/widgets" --get 1302 | jq -r '.reviewer')"

# ---------------------------------------------------------------------------
# 13. Omitted --owner-repo DERIVES the scoped path from the cwd (issue #1366).
#
#     This supersedes #1302's warn-and-proceed: a stderr line does not stop a
#     write that reports success, so the wrong path stayed reachable by the easy
#     default. Derivation removes the default instead of the path. Every mode
#     must agree, or a --path probe would name a file --create never wrote.
# ---------------------------------------------------------------------------
echo ""
echo "=== 13. Omitted --owner-repo derives the scoped path ==="

# A real checkout with an `origin` remote, so repo_identity() yields owner/repo.
FAKE_REPO="${TMP_DIR}/fake-checkout"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init -q 2>/dev/null
git -C "$FAKE_REPO" remote add origin "https://github.com/acme/widgets.git" 2>/dev/null

SCOPED_1400="${HANDOFF_DIR}/acme/widgets/pr-1400-handoff.json"

# `|| rc=$?` keeps `set -e` from aborting on a non-zero exit AND captures the
# real code — a bare `$?` after the assignment can only ever read 0 here.
derive_rc=0
derive_err="$(cd "$FAKE_REPO" && "$HANDOFF_STATE" --create 1400 '{"pr_number":1400,"head_sha":"drv"}' 2>&1 >/dev/null)" || derive_rc=$?
check "derived write exits 0" "0" "$derive_rc"
# Not silent: a derived write names its scope, so a write from a checkout whose
# origin is not the PR's repo is visible instead of merely succeeding (§16b(b)).
check_contains "derived write names its derived scope" "acme/widgets" "$derive_err"
if [[ -f "$SCOPED_1400" ]]; then
  ok "derived write landed on the SCOPED path"
else fail "derived write did not create $SCOPED_1400"; fi
if [[ -f "${HANDOFF_DIR}/pr-1400-handoff.json" ]]; then
  fail "derived write also created a flat file — the by-omission path is still live"
else ok "derived write created no flat file"; fi

# Every mode must resolve the same file the write chose.
check "--path agrees with the derived write" \
  "$SCOPED_1400" "$(cd "$FAKE_REPO" && "$HANDOFF_STATE" --path 1400)"
check "--get reads the derived file" "drv" \
  "$(cd "$FAKE_REPO" && "$HANDOFF_STATE" --get 1400 | jq -r '.head_sha')"
(cd "$FAKE_REPO" && "$HANDOFF_STATE" --set 1400 '.head_sha=drv2')
check "--set updates the derived file" "drv2" "$(jq -r '.head_sha' "$SCOPED_1400")"
(cd "$FAKE_REPO" && "$HANDOFF_STATE" --append 1400 "threads_replied" "t-1")
check "--append updates the derived file" "t-1" "$(jq -r '.threads_replied[0]' "$SCOPED_1400")"
(cd "$FAKE_REPO" && "$HANDOFF_STATE" --init 1400 '{"pr_number":9999}')
check "--init no-ops on the derived file" "1400" "$(jq -r '.pr_number' "$SCOPED_1400")"
(cd "$FAKE_REPO" && "$HANDOFF_STATE" --delete 1400)
if [[ ! -f "$SCOPED_1400" ]]; then ok "--delete removes the derived file"
else fail "--delete did not remove $SCOPED_1400"; fi

# $CLAUDE_SESSION_REPO outranks cwd derivation (session-state.sh precedence).
check "\$CLAUDE_SESSION_REPO outranks the cwd origin" \
  "${HANDOFF_DIR}/other/repo/pr-1402-handoff.json" \
  "$(cd "$FAKE_REPO" && CLAUDE_SESSION_REPO="Other/Repo" "$HANDOFF_STATE" --path 1402)"

# A set-but-unusable override is a refusal, not a silent fall-through to cwd:
# answering a different question than the one configured is how #1366 happened.
badenv_rc=0
badenv_err="$(cd "$FAKE_REPO" && CLAUDE_SESSION_REPO="notaslug" "$HANDOFF_STATE" --create 1403 '{"pr_number":1403}' 2>&1 >/dev/null)" || badenv_rc=$?
check "unusable \$CLAUDE_SESSION_REPO exits 2" "2" "$badenv_rc"
check_contains "and names the variable" "CLAUDE_SESSION_REPO" "$badenv_err"

# A scoped write in the same checkout stays silent (it named its own repo).
quiet_scoped="$(cd "$FAKE_REPO" && "$HANDOFF_STATE" --owner-repo "acme/widgets" --create 1401 '{"pr_number":1401}' 2>&1 >/dev/null)"
check "explicitly scoped write is silent" "" "$quiet_scoped"

# Deriving over an un-migrated flat file names it, rather than orphaning it.
: > "${HANDOFF_DIR}/pr-1404-handoff.json"
printf '%s\n' '{"pr_number":1404}' > "${HANDOFF_DIR}/pr-1404-handoff.json"
migrate_warn="$(cd "$FAKE_REPO" && "$HANDOFF_STATE" --path 1404 2>&1 >/dev/null)"
check_contains "derivation over a flat file names handoff-migrate.sh" \
  "handoff-migrate.sh" "$migrate_warn"
check_contains "and names the un-migrated file" \
  "pr-1404-handoff.json" "$migrate_warn"

# ---------------------------------------------------------------------------
# 14. No resolvable repo + no flag: refuse loudly, write nothing (issue #1366).
#
#     This is the case the flat path used to absorb. A write nobody reads is
#     worse than a refusal, because it reports success — so the repo-less caller
#     is now the one that must say --legacy-flat.
# ---------------------------------------------------------------------------
echo ""
echo "=== 14. Underivable context: refuse, write nothing ==="

NOREPO_DIR="${TMP_DIR}/not-a-repo"
mkdir -p "$NOREPO_DIR"

norepo_rc=0
norepo_err="$(cd "$NOREPO_DIR" && "$HANDOFF_STATE" --create 1500 '{"pr_number":1500,"head_sha":"nr"}' 2>&1 >/dev/null)" || norepo_rc=$?
check "no-repo write exits non-zero" "2" "$norepo_rc"
check_contains "refusal says nothing was written" "Nothing was read or written" "$norepo_err"
check_contains "refusal names the flag to pass" "--owner-repo" "$norepo_err"
check_contains "refusal names the legacy escape" "--legacy-flat" "$norepo_err"
if [[ -f "${HANDOFF_DIR}/pr-1500-handoff.json" ]]; then
  fail "refused write still created the flat file"
else ok "refused write created no flat file"; fi

# A git checkout with no `origin` also has no owner/repo to name.
NOORIGIN_DIR="${TMP_DIR}/no-origin"
mkdir -p "$NOORIGIN_DIR"
git -C "$NOORIGIN_DIR" init -q 2>/dev/null
noorigin_rc=0
(cd "$NOORIGIN_DIR" && "$HANDOFF_STATE" --set 1500 '.head_sha=nr2' >/dev/null 2>&1) || noorigin_rc=$?
check "origin-less checkout also refuses" "2" "$noorigin_rc"

# The repo-less caller keeps working by saying what it means.
norepo_flat_rc=0
(cd "$NOREPO_DIR" && "$HANDOFF_STATE" --legacy-flat --create 1500 '{"pr_number":1500,"head_sha":"nr"}') || norepo_flat_rc=$?
check "--legacy-flat works from a non-repo cwd" "0" "$norepo_flat_rc"
check "no-repo flat file readable" "nr" \
  "$(cd "$NOREPO_DIR" && "$HANDOFF_STATE" --legacy-flat --get 1500 | jq -r '.head_sha')"

# ---------------------------------------------------------------------------
# 15. dismiss-stale-bot-changes.sh --owner-repo scopes the handoff append
#     (issue #1302). Exercises the flag parsing and the flat-vs-scoped gating
#     without any network calls.
# ---------------------------------------------------------------------------
echo ""
echo "=== 15. dismiss-stale-bot-changes.sh --owner-repo ==="

DISMISS="${SCRIPT_DIR}/../dismiss-stale-bot-changes.sh"

if [[ ! -x "$DISMISS" ]]; then
  fail "dismiss-stale-bot-changes.sh not found at $DISMISS"
else
  # Flag validation is pure arg parsing — reached before any gh call.
  if ! out="$("$DISMISS" 5 --owner-repo "" 2>&1)"; then
    ok "--owner-repo '' is rejected"
  else fail "--owner-repo '' should be rejected (got: $out)"; fi

  if ! out="$("$DISMISS" 5 --owner-repo "nodash" 2>&1)"; then
    ok "--owner-repo 'nodash' (no slash) is rejected"
  else fail "--owner-repo 'nodash' should be rejected"; fi

  if ! out="$("$DISMISS" 5 --owner-repo "a/b/c" 2>&1)"; then
    ok "--owner-repo 'a/b/c' (extra slash) is rejected"
  else fail "--owner-repo 'a/b/c' should be rejected"; fi

  check_contains "--help documents --owner-repo" \
    "--owner-repo" "$("$DISMISS" --help 2>&1)"

  # ---- Functional: where does the append actually land? ----
  #
  # Stub `gh` so the whole dismissal path runs offline. The stub never invokes
  # `gh` itself (no `command -v` forwarding), so it cannot recurse into itself.
  STUB_DIR="${TMP_DIR}/stubbin"
  mkdir -p "$STUB_DIR"
  cat > "${STUB_DIR}/gh" <<'GHSTUB'
#!/usr/bin/env bash
# Minimal gh stub for dismiss-stale-bot-changes.sh — issue #1302 append scoping.
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  echo "acme/widgets"; exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
  echo "headsha1302"; exit 0
fi
if [[ "${1:-}" == "api" ]]; then
  for _arg in "$@"; do
    case "$_arg" in
      */reviews\?per_page=100)
        # One stale bot CHANGES_REQUESTED review, on a SHA that is not HEAD.
        echo '[{"id":777,"state":"CHANGES_REQUESTED","commit_id":"oldsha","user":{"login":"coderabbitai[bot]","type":"Bot"}}]'
        exit 0 ;;
      */dismissals)
        exit 0 ;;
    esac
  done
  echo '[]'; exit 0
fi
exit 0
GHSTUB
  chmod +x "${STUB_DIR}/gh"

  # (a) Scoped --handoff-file + --owner-repo -> append lands on the SCOPED file.
  scoped_h="$("$HANDOFF_STATE" --owner-repo "acme/widgets" --path 1600)"
  "$HANDOFF_STATE" --owner-repo "acme/widgets" --create 1600 \
    '{"schema_version":"1.0","pr_number":1600,"head_sha":"headsha1302","owner_repo":"acme/widgets","phase_completed":"A"}'

  dismiss_rc=0
  PATH="${STUB_DIR}:$PATH" "$DISMISS" 1600 \
    --handoff-file "$scoped_h" --owner-repo "acme/widgets" >/dev/null 2>&1 || dismiss_rc=$?
  check "scoped dismissal run exits 0" "0" "$dismiss_rc"
  check "dismissed ID appended to the scoped handoff" "777" \
    "$("$HANDOFF_STATE" --owner-repo "acme/widgets" --get 1600 | jq -r '.stale_bot_reviews_dismissed[0] // ""')"
  if [[ ! -f "${HANDOFF_DIR}/pr-1600-handoff.json" ]]; then
    ok "scoped dismissal created no flat handoff"
  else fail "scoped dismissal leaked a flat handoff (pre-#1302 behavior)"; fi

  # (b) Flat --handoff-file, no --owner-repo -> append stays on the FLAT file.
  #     CLAUDE_HANDOFF_FLAT_OK marks this as a deliberate legacy-path caller.
  flat_h="${HANDOFF_DIR}/pr-1601-handoff.json"
  CLAUDE_HANDOFF_FLAT_OK=1 "$HANDOFF_STATE" --create 1601 \
    '{"schema_version":"1.0","pr_number":1601,"head_sha":"headsha1302","phase_completed":"A"}'

  dismiss_flat_rc=0
  PATH="${STUB_DIR}:$PATH" CLAUDE_HANDOFF_FLAT_OK=1 "$DISMISS" 1601 \
    --handoff-file "$flat_h" >/dev/null 2>&1 || dismiss_flat_rc=$?
  check "flat dismissal run exits 0" "0" "$dismiss_flat_rc"
  check "dismissed ID appended to the flat handoff" "777" \
    "$(CLAUDE_HANDOFF_FLAT_OK=1 "$HANDOFF_STATE" --get 1601 | jq -r '.stale_bot_reviews_dismissed[0] // ""')"
  if [[ ! -f "${HANDOFF_DIR}/acme/widgets/pr-1601-handoff.json" ]]; then
    ok "flat dismissal did not seed a scoped handoff"
  else fail "flat dismissal wrote a scoped handoff the caller never asked for"; fi
fi

# ---------------------------------------------------------------------------
# 16b. Derivation hazards that must not be silent (issue #1366 review round).
# ---------------------------------------------------------------------------
echo ""
echo "=== 16b. Derived-scope hazards ==="

DERIVE_REPO="${TMP_DIR}/derive-checkout"
mkdir -p "$DERIVE_REPO"
git -C "$DERIVE_REPO" init -q 2>/dev/null
git -C "$DERIVE_REPO" remote add origin "https://github.com/acme/widgets.git" 2>/dev/null

# (a) An un-migrated flat record + a derived scope = REFUSE every write.
#     Seeding a scoped file from {} would strand the flat record's other fields
#     while reporting success — the loss this issue exists to prevent.
printf '%s\n' '{"pr_number":970,"schema_version":"1.0","reviewer":"cr","findings_fixed":["f1"],"threads_replied":["t1"]}' \
  > "${HANDOFF_DIR}/pr-970-handoff.json"
for m in "--set 970 .head_sha=x" "--append 970 threads_replied t2" "--create 970 {}" "--delete 970"; do
  # shellcheck disable=SC2086
  d_rc=0; d_err="$(cd "$DERIVE_REPO" && "$HANDOFF_STATE" $m 2>&1 >/dev/null)" || d_rc=$?
  check "derived write refused: ${m%% *}" "2" "$d_rc"
  check_contains "  refusal names handoff-migrate.sh" "handoff-migrate.sh" "$d_err"
done
if [[ ! -f "${HANDOFF_DIR}/acme/widgets/pr-970-handoff.json" ]]; then
  ok "no partial scoped record was seeded"
else fail "a scoped record was seeded despite the refusal"; fi
check "the flat record is untouched" "f1" \
  "$(jq -r '.findings_fixed[0]' "${HANDOFF_DIR}/pr-970-handoff.json")"
# Both explicit escapes get past it.
(cd "$DERIVE_REPO" && "$HANDOFF_STATE" --legacy-flat --set 970 '.head_sha=flat') >/dev/null 2>&1
check "--legacy-flat updates the existing record" "flat" \
  "$(jq -r '.head_sha' "${HANDOFF_DIR}/pr-970-handoff.json")"
scoped_rc=0
(cd "$DERIVE_REPO" && "$HANDOFF_STATE" --owner-repo "acme/widgets" --set 970 '.head_sha=scoped') >/dev/null 2>&1 || scoped_rc=$?
check "--owner-repo starts a scoped record deliberately" "0" "$scoped_rc"

# (b) A derived WRITE names its scope; a derived READ stays silent.
w_err="$(cd "$DERIVE_REPO" && "$HANDOFF_STATE" --create 971 '{"pr_number":971}' 2>&1 >/dev/null)"
check_contains "derived write names the derived scope" "acme/widgets" "$w_err"
check_contains "  and names where it came from" "derived from" "$w_err"
check "derived read stays silent" "" \
  "$(cd "$DERIVE_REPO" && "$HANDOFF_STATE" --path 971 2>&1 >/dev/null)"

# (c) An ambient CLAUDE_HANDOFF_FLAT_OK=1 that bypasses a resolvable scope says so.
#     It is exported around sweeps, so unlike --legacy-flat it can cover calls
#     its author never considered.
env_err="$(cd "$DERIVE_REPO" && CLAUDE_HANDOFF_FLAT_OK=1 "$HANDOFF_STATE" --create 972 '{"pr_number":972}' 2>&1 >/dev/null)"
check_contains "ambient flat-OK note names the bypassed scope" "acme/widgets" "$env_err"
check "  and it still wrote flat" "972" \
  "$(jq -r '.pr_number' "${HANDOFF_DIR}/pr-972-handoff.json")"

# (d) Scope flags AFTER the mode flag are rejected, not discarded. Silently
#     ignoring a misplaced --legacy-flat would send an explicitly-flat write to
#     the derived scoped path instead.
for bad in "--path 973 --legacy-flat" "--create 973 {} --owner-repo a/b"; do
  # shellcheck disable=SC2086
  t_rc=0; t_err="$(cd "$DERIVE_REPO" && "$HANDOFF_STATE" $bad 2>&1 >/dev/null)" || t_rc=$?
  check "trailing scope flag rejected: ${bad}" "2" "$t_rc"
  check_contains "  and explains flag placement" "BEFORE the mode flag" "$t_err"
done

# ---------------------------------------------------------------------------
# 17. --set rejects a raw jq expression instead of storing its source text
#     (issue #1357).
#
#     The harm was the SILENT SUCCESS: `.notes + " ..."` stored its own source
#     over Phase A's notes, exited 0, and was only caught on read-back. A hard
#     failure leaves the prior value intact, so every case below asserts both
#     the non-zero exit AND that the field is unchanged.
# ---------------------------------------------------------------------------
echo ""
echo "=== 17. --set rejects raw jq expressions (issue #1357, guard from PR #1378) ==="

SET_OR=(--owner-repo "acme/widgets")
"$HANDOFF_STATE" "${SET_OR[@]}" --create 1357 \
  '{"pr_number":1357,"notes":"phase A notes","merge_gate_met":false}' >/dev/null

for expr in '.notes + " appended"' '(.threads // [])' '.a|tostring' '.findings | length'; do
  rc=0
  err="$("$HANDOFF_STATE" "${SET_OR[@]}" --set 1357 ".notes=${expr}" 2>&1 >/dev/null)" || rc=$?
  check "rejected: ${expr}" "4" "$rc"
  check_contains "  names it an unevaluated jq expression" "unevaluated jq expression" "$err"
done
check "notes survived every rejection" "phase A notes" \
  "$("$HANDOFF_STATE" "${SET_OR[@]}" --get 1357 | jq -r '.notes')"

# Genuine strings must still be stored — especially path-shaped ones, which are
# valid jq SYNTAX (path, divide, path) and would trip a parse-only heuristic.
for lit in 'Fixed in abc1234' '.github/workflows/ci.yml' '.claude/scripts/x.sh' \
           'empty' 'length' '2026-08-27T10:00:00Z' '.head_sha' \
           '(WIP)' '(none)' '(P0)' '(TBD)' \
           '.github/workflows/ci.yml, .claude/scripts/x.sh' \
           '.claude/rules/a.md and .claude/rules/b.md'; do
  lit_rc=0
  "$HANDOFF_STATE" "${SET_OR[@]}" --set 1357 ".notes=${lit}" >/dev/null 2>&1 || lit_rc=$?
  check "accepted literal: ${lit}" "0" "$lit_rc"
  check "  stored verbatim" "$lit" \
    "$("$HANDOFF_STATE" "${SET_OR[@]}" --get 1357 | jq -r '.notes')"
done

# Issue #853 must not regress: false/null/numbers stay JSON literals, not the
# truthy strings "false"/"null" a `jq -e .` probe would have produced.
"$HANDOFF_STATE" "${SET_OR[@]}" --set 1357 '.merge_gate_met=false' >/dev/null
"$HANDOFF_STATE" "${SET_OR[@]}" --set 1357 '.reviewer=null' >/dev/null
"$HANDOFF_STATE" "${SET_OR[@]}" --set 1357 '.count=42' >/dev/null
check "#853: false/null/42 keep their JSON types" "boolean,null,number" \
  "$("$HANDOFF_STATE" "${SET_OR[@]}" --get 1357 \
     | jq -r '[(.merge_gate_met|type),(.reviewer|type),(.count|type)]|join(",")')"

# Escape hatch: a JSON-quoted value takes the --argjson branch untouched.
"$HANDOFF_STATE" "${SET_OR[@]}" --set 1357 '.notes="literally .a + .b"' >/dev/null
check "JSON-quoted literal bypasses the guard" "literally .a + .b" \
  "$("$HANDOFF_STATE" "${SET_OR[@]}" --get 1357 | jq -r '.notes')"

echo ""
echo "=== 18. --require-existing: update-only writes (CodeAnt, PR #1423) ==="
# --set/--append seed from `{}` when the target is absent, so they are silently
# CREATING operations. dismiss-stale-bot-changes.sh does not want that: it tests
# for the handoff itself and skips when there is none. That test is outside the
# helper's lock, so a delete or migration landing in the window turned its skip
# into a partial record holding only the appended array. --require-existing moves
# the check inside the lock.
REQ_OR=(--owner-repo "acme/widgets")
REQ_FILE="$HOME/.claude/handoffs/acme/widgets/pr-1423-handoff.json"
rm -f "$REQ_FILE"

req_rc=0
req_err="$("$HANDOFF_STATE" "${REQ_OR[@]}" --require-existing \
  --append 1423 stale_bot_reviews_dismissed '"r1"' 2>&1 >/dev/null)" || req_rc=$?
check "--append on an absent target exits 3" "3" "$req_rc"
check_contains "  refusal names the flag" "--require-existing" "$req_err"
check "  and seeded no partial record" "0" "$(test -e "$REQ_FILE" && echo 1 || echo 0)"

req_rc=0
"$HANDOFF_STATE" "${REQ_OR[@]}" --require-existing --set 1423 '.head_sha=abc1234' \
  >/dev/null 2>&1 || req_rc=$?
check "--set on an absent target exits 3 too" "3" "$req_rc"
check "  and still seeded nothing" "0" "$(test -e "$REQ_FILE" && echo 1 || echo 0)"

# Default behavior is untouched: without the flag, seeding still happens. This is
# what every existing caller was written against.
"$HANDOFF_STATE" "${REQ_OR[@]}" --append 1423 stale_bot_reviews_dismissed '"r1"' >/dev/null
check "without the flag, --append still seeds a record" "1" \
  "$(test -f "$REQ_FILE" && echo 1 || echo 0)"

# And once a record exists the flag is transparent — it gates creation, not writes.
rm -f "$REQ_FILE"
"$HANDOFF_STATE" "${REQ_OR[@]}" --create 1423 \
  '{"pr_number":1423,"reviewer":"cr","findings_fixed":["f1"]}' >/dev/null
req_rc=0
"$HANDOFF_STATE" "${REQ_OR[@]}" --require-existing \
  --append 1423 stale_bot_reviews_dismissed '"r9"' >/dev/null 2>&1 || req_rc=$?
check "--require-existing appends normally to an existing record" "0" "$req_rc"
check "  the append landed" "r9" \
  "$("$HANDOFF_STATE" "${REQ_OR[@]}" --get 1423 | jq -r '.stale_bot_reviews_dismissed[-1]')"
check "  and preserved the fields already there" "cr,f1" \
  "$("$HANDOFF_STATE" "${REQ_OR[@]}" --get 1423 | jq -r '[.reviewer,.findings_fixed[0]]|join(",")')"

# Misplaced after the mode flag it is rejected like any other leading flag,
# rather than being silently discarded (issue #1366's trailing-flag rule).
req_rc=0
req_err="$("$HANDOFF_STATE" "${REQ_OR[@]}" --get 1423 --require-existing 2>&1 >/dev/null)" || req_rc=$?
check "trailing --require-existing is rejected" "2" "$req_rc"
check_contains "  and explains flag placement" "must come BEFORE the mode flag" "$req_err"

# ---------------------------------------------------------------------------
# 19. Caller-side conformance: update call sites opt into --require-existing
#     (issue #1603)
#
#     Section 18 proves the flag works. This one proves our own callers pass it.
#     The regression it pins is a real incident: a Phase B agent's final `notes`
#     write landed moments after Phase C merged and the parent deleted the
#     record, so the seed-from-`{}` default recreated a one-key file with a null
#     phase_completed — which reads as "Phase A never completed" to every later
#     reader. These are the update call sites; a creation (--create) must NOT
#     carry the flag, and that is asserted too.
# ---------------------------------------------------------------------------
echo "=== 19. caller-side conformance: --require-existing on update call sites (issue #1603) ==="

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Predicate, reused for the real files and for the negative control below.
# Prints one line per offending OR=() definition; empty output == conformant.
# `grep || true` because a conformant file legitimately matches nothing, and
# the caller runs under `set -e`.
bad_or_arrays() {
  local file="$1"
  grep -n 'OR=(--owner-repo' -- "$file" 2>/dev/null | grep -v -- '--require-existing' || true
}

for _tpl in \
    "${REPO_ROOT}/.claude/agents/phase-b-reviewer.md" \
    "${REPO_ROOT}/.claude/skills/subagent/SKILL.md"; do
  _rel="${_tpl#"$REPO_ROOT"/}"
  if [[ ! -f "$_tpl" ]]; then
    fail "$_rel exists"
    continue
  fi
  check "every OR=() in $_rel carries --require-existing" "" "$(bad_or_arrays "$_tpl")"
  # The array has to exist at all — an empty result would otherwise pass
  # vacuously if the block were renamed or deleted.
  _or_count="$(grep -c 'OR=(--owner-repo' -- "$_tpl" || true)"
  if [[ "${_or_count:-0}" -ge 1 ]]; then ok "  and $_rel still defines one"
  else fail "  and $_rel still defines one (found none — did the block move?)"; fi
done

# Negative control: the predicate must actually FAIL on a stripped copy. Without
# this the two checks above pass just as happily against a grep that matches
# nothing (memory: guards that pass by not running).
NEG_TPL="${TMP_DIR}/neg-phase-b.md"
sed 's/OR=(--owner-repo \(.*\) --require-existing)/OR=(--owner-repo \1)/' \
  "${REPO_ROOT}/.claude/agents/phase-b-reviewer.md" > "$NEG_TPL"
neg_out="$(bad_or_arrays "$NEG_TPL")"
if [[ -n "$neg_out" ]]; then ok "negative control: predicate flags a stripped OR=() array"
else fail "negative control: predicate did NOT flag a stripped OR=() array"; fi

# Phase A creates the record, so its --create must stay flagless.
PHASE_A="${REPO_ROOT}/.claude/agents/phase-a-fixer.md"
# Match the invocation line only — the surrounding prose deliberately names both
# the flag and --create while explaining why the create does not take it.
create_lines="$(grep -n -- '^"\$HANDOFF_STATE_SH".*--create' "$PHASE_A" | grep -- '--require-existing' || true)"
create_all="$(grep -c -- '^"\$HANDOFF_STATE_SH".*--create' "$PHASE_A" || true)"
if [[ "${create_all:-0}" -ge 1 ]]; then ok "phase-a-fixer.md still shows a --create invocation"
else fail "phase-a-fixer.md still shows a --create invocation (found none — did Step 6 move?)"; fi
check "phase-a-fixer.md --create does NOT carry --require-existing" "" "$create_lines"

# Both agent definitions explain what exit 3 means, so an agent that hits it
# does not "fix" it by recreating the record.
for _tpl in "$PHASE_A" "${REPO_ROOT}/.claude/agents/phase-b-reviewer.md"; do
  _rel="${_tpl#"$REPO_ROOT"/}"
  _body="$(cat "$_tpl")"
  check_contains "$_rel explains exit 3" 'exit 3 = the handoff is gone' "$_body"
done

# polling-state-gate.sh refreshes head_sha on a record it tested for OUTSIDE the
# lock — the same TOCTOU shape.
PSG="${REPO_ROOT}/.claude/scripts/polling-state-gate.sh"
psg_body="$(cat "$PSG")"
check_contains "polling-state-gate.sh head_sha refresh is update-only" \
  '--require-existing' "$psg_body"
psg_bad="$(grep -n -- '--set "\$PR_NUMBER" "\.head_sha=' "$PSG" | grep -v -- '--require-existing' || true)"
# The flag sits on the preceding continuation line, so a same-line grep would be
# the wrong assertion; what matters is that no --set of .head_sha appears
# without the flag somewhere in its own invocation. Assert the paired form.
if [[ -n "$psg_bad" ]]; then
  # Re-check by joining continuations before deciding.
  joined="$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$PSG")"
  psg_bad="$(printf '%s\n' "$joined" | grep -n -- '--set "\$PR_NUMBER" "\.head_sha=' | grep -v -- '--require-existing' || true)"
fi
check "no unflagged .head_sha refresh remains in polling-state-gate.sh" "" "$psg_bad"

# That refusal must distinguish the flag's two exit-3 causes. Phase C DELETING
# the record is the case --require-existing exists for; handoff-migrate.sh
# MOVING a flat record to its scoped path is not — the record still exists, and
# failing --ensure-session over a rename strands polling on a handoff that is
# sitting right there (CodeAnt, PR #1606). The flat branch must retry once
# against the migrated record before concluding deletion.
check_contains "  exit 3 retries the migrated record before refusing" \
  'retrying against the migrated record' "$psg_body"
# The retry has to be scoped (--owner-repo) — retrying --legacy-flat would hit
# the same vanished path — and still flagged, or it re-seeds what it refused.
psg_joined="$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$PSG")"
psg_retry="$(printf '%s\n' "$psg_joined" \
  | grep -cE -- '--owner-repo "\$owner_repo" --require-existing +--set "\$PR_NUMBER" "\.head_sha=' || true)"
check "  the migrated-record retry is scoped and still flagged" "1" "$psg_retry"
# Guarded to the flat branch only: the scoped path is migration's destination,
# never its source, so a scoped exit 3 is always a real deletion.
check_contains "  the retry is guarded to the --legacy-flat branch" \
  'set_or_flag\[0\]\}" == "--legacy-flat"' "$psg_body"
# And a retry that itself fails must still reach the refusal, not fall through
# to a silent success.
check_contains "  a failed retry still refuses" \
  'migrated_rc" -ne 0' "$psg_body"
# Negative control: the predicates must fail on a copy with the retry stripped.
psg_stripped="${TMP_DIR}/psg-no-migration-retry.sh"
grep -v -e 'retrying against the migrated record' -e 'migrated_rc' "$PSG" > "$psg_stripped"
psg_neg="$(grep -c -e 'retrying against the migrated record' -e 'migrated_rc' "$psg_stripped" || true)"
check "  negative control: predicates flag a stripped migration retry" "0" "$psg_neg"

# dismiss-stale-bot-changes.sh appends stale_bot_reviews_dismissed under the flag
# (PR #1423). It also PRINTS a recovery command when that append hits exit 3; the
# printed command has to carry the flag too, or following the advice recreates
# exactly the hollow record the append refused to write (issue #1603).
DSB="${REPO_ROOT}/.claude/scripts/dismiss-stale-bot-changes.sh"
dsb_appends="$(grep -n -- '--append "\$PR_NUMBER" "stale_bot_reviews_dismissed"' "$DSB" || true)"
if [[ -n "$dsb_appends" ]]; then ok "dismiss-stale-bot-changes.sh still appends stale_bot_reviews_dismissed"
else fail "dismiss-stale-bot-changes.sh still appends stale_bot_reviews_dismissed (found none)"; fi
# The flag sits on the line above the --append, so join continuations first.
dsb_joined="$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$DSB")"
dsb_bad="$(printf '%s\n' "$dsb_joined" \
  | grep -n -- '--append "\$PR_NUMBER" "stale_bot_reviews_dismissed"' \
  | grep -v -- '--require-existing' || true)"
check "the live append carries --require-existing" "" "$dsb_bad"

dsb_advice="$(grep -n -- 'stale_bot_reviews_dismissed .\\"\$_ds_m' "$DSB" || true)"
if [[ -n "$dsb_advice" ]]; then ok "  and it still prints a recovery command"
else fail "  and it still prints a recovery command (found none — did the message change?)"; fi
dsb_advice_bad="$(printf '%s\n' "$dsb_advice" | grep -v -- '--require-existing' || true)"
check "  whose printed command also carries --require-existing" "" "$dsb_advice_bad"

# That printed command inherits the scope the append was using. On the
# --legacy-flat branch the warning names TWO causes, and for the migration one
# the flat path is gone for good: following the advice verbatim re-targets the
# deleted file and, with --require-existing, records nothing (CodeAnt, PR #1606).
# So the exit-3 branch must also name the scoped substitution.
dsb_migration_note="$(grep -c -- 'in place of .--legacy-flat' "$DSB" || true)"
if [[ "$dsb_migration_note" -ge 1 ]]; then
  ok "  and names the --owner-repo substitution for the migration cause"
else
  fail "  and names the --owner-repo substitution for the migration cause (found none)"
fi
# Both arms — a known owner/repo is spelled out, an unknown one is a placeholder.
dsb_note_concrete="$(grep -c -- "owner-repo \$_ds_owner_repo' in place of" "$DSB" || true)"
dsb_note_placeholder="$(grep -c -- "owner-repo <owner>/<repo>' (the migrated scope)" "$DSB" || true)"
check "  concrete arm names the resolved owner/repo" "1" "$dsb_note_concrete"
check "  placeholder arm covers an unknown owner/repo" "1" "$dsb_note_placeholder"
# Negative control: the predicate must actually fail on a file without the note.
dsb_stripped="${TMP_DIR}/dsb-no-migration-note.sh"
grep -v -- 'in place of .--legacy-flat' "$DSB" > "$dsb_stripped"
dsb_neg="$(grep -c -- 'in place of .--legacy-flat' "$dsb_stripped" || true)"
check "  negative control: predicate flags a stripped migration note" "0" "$dsb_neg"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
