#!/usr/bin/env bash
# Repo-invariant checks for usage-limit-record.sh (split from the monolith
# by Issue #1071). Tests here verify repo-wide contracts rather than hook
# runtime behavior: hook registration, retired-manifest absence, no spend
# estimation, safety-rule wording, and the signal-audit doc.
#
# Self-contained — defines its own helpers. No shared harness.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/usage-limit-record.sh"
SETTINGS="$REPO_ROOT/global-settings.json"
SETUP_SCRIPT="$REPO_ROOT/setup-skills-worktree.sh"
AUDIT_DOC="$REPO_ROOT/.claude/reference/usage-limit-signal-audit-2026-07.md"
SAFETY_RULE="$REPO_ROOT/.claude/rules/safety.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# --- 1. Registration: one entry carrying matcher + command + timeout together ---
# Checked as a single conjunction on purpose. Split assertions would accept a
# matcher on one group and the timeout on another — a registration that looks
# valid to the tests but is not the one the runtime fires.
python3 - "$SETTINGS" <<'PY' || fail "no single StopFailure entry has matcher rate_limit + usage-limit-record.sh + timeout 5"
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
ok = any(
    g.get("matcher") == "rate_limit"
    and any(
        h.get("command", "").endswith("usage-limit-record.sh") and h.get("timeout") == 5
        for h in g.get("hooks", [])
    )
    for g in data.get("hooks", {}).get("StopFailure", [])
)
sys.exit(0 if ok else 1)
PY

# --- 2. HOOKS_MANIFEST must NOT be defined in setup-skills-worktree.sh ---
# HOOKS_MANIFEST was retired by issue #1019 — global-settings.json is now the
# single source of truth (verified above in test 1), so there is no second
# timeout source to drift.  This check guards against re-introduction of the
# duplicated manifest array.
if grep -q "HOOKS_MANIFEST=" "$SETUP_SCRIPT" 2>/dev/null; then
  fail "HOOKS_MANIFEST array is still defined in setup-skills-worktree.sh — it should have been retired (issue #1019)"
fi

# --- 3. No local spend/quota estimation in any executable line ---
# The whole point of the issue: the trigger must be the upstream signal only.
# Comments are stripped first — the hook's own header *describes* the ban, and
# matching that prose would fail the test for saying the right thing.
CODE_ONLY="$TMP_DIR/hook-code-only.sh"
sed -e 's/[[:space:]]*#.*$//' "$HOOK" | grep -v '^[[:space:]]*$' >"$CODE_ONLY"
if grep -nEi 'input_tokens|output_tokens|cache_read|used_percentage|spend|budget_remaining|estimate' "$CODE_ONLY"; then
  fail "hook computes/reads token or spend accounting — the trigger must be the upstream error signal only"
fi

# --- 4. safety.md's quota prohibition is intact and unamended ---
grep -q 'MUST NOT gate agent decisions' "$SAFETY_RULE" \
  || fail "safety.md quota prohibition text is missing or was altered"

# --- 5. The gating finding doc exists and states the verdict ---
[[ -f "$AUDIT_DOC" ]] || fail "signal-investigation finding doc is missing"
grep -q 'Verdict' "$AUDIT_DOC" || fail "finding doc does not state a verdict"

echo "PASS: usage-limit-record-registration.sh"
