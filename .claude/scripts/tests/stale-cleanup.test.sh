#!/usr/bin/env bash
# stale-cleanup.test.sh — Offline tests for the invoking-repo scope contract
# (issue #697, contract from issue #687) in stale-cleanup.sh and
# dirty-main-guard.sh.
#
# Layout: repoA hosts a copy of the scripts (simulating the
# ~/.claude/skills-worktree checkout the bug was observed through) and carries
# its own stale branch as a regression tripwire; repoB is the invoking repo
# with stale/fresh/protected branches and worktrees. `gh` is stubbed on PATH;
# it serves a fixture PR list and records its cwd so the tests can prove the
# open-PR safety check runs inside the swept repo.
#
# Requires git, jq. Run from repo root: bash .claude/scripts/tests/stale-cleanup.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Redirect HOME: scripts append to $HOME/.claude/script-usage.log, and the
# temp git identity must not leak into (or depend on) the real ~/.gitconfig.
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"
git config --global user.email "test@example.com"
git config --global user.name "Test"
git config --global init.defaultBranch main

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }

check_json() {
  # $1 desc, $2 json, $3 jq boolean expr — passes when the expr is truthy.
  local desc="$1" json="$2" expr="$3"
  if printf '%s' "$json" | jq -e "$expr" >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

check_eq() {
  local desc="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    pass "$desc"
  else
    fail "$desc (want '$want', got '$got')"
  fi
}

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc (missing '$needle')"
  fi
}

OLD_DATE="2020-01-05T00:00:00"
commit_old() {
  GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" git -C "$1" commit -q -m "$2"
}

# ---- repoA: the repo the scripts live in (skills-worktree stand-in) ---------
REPO_A="$TMP/repoA"
mkdir -p "$REPO_A"
git -C "$REPO_A" init -q
echo "a" > "$REPO_A/README.md"
git -C "$REPO_A" add README.md
commit_old "$REPO_A" "repoA base"
# Stale branch in repoA — must NEVER surface when sweeping from repoB. Before
# the #697 fix, script-location resolution listed exactly this kind of ref.
git -C "$REPO_A" branch issue-999-repoa-stale
mkdir -p "$REPO_A/.claude/scripts"
cp "$REPO_ROOT/.claude/scripts/stale-cleanup.sh" \
   "$REPO_ROOT/.claude/scripts/repo-root.sh" \
   "$REPO_ROOT/.claude/scripts/dirty-main-guard.sh" \
   "$REPO_A/.claude/scripts/"
SUT="$REPO_A/.claude/scripts/stale-cleanup.sh"
GUARD="$REPO_A/.claude/scripts/dirty-main-guard.sh"

# ---- repoB: the invoking repo ------------------------------------------------
REPO_B="$TMP/repoB"
mkdir -p "$REPO_B"
git -C "$REPO_B" init -q
echo "b" > "$REPO_B/README.md"
git -C "$REPO_B" add README.md
commit_old "$REPO_B" "repoB old base"
OLD_SHA="$(git -C "$REPO_B" rev-parse HEAD)"
git -C "$REPO_B" branch issue-100-repob-stale "$OLD_SHA"   # stale
git -C "$REPO_B" branch issue-101-repob-pr "$OLD_SHA"      # old but has open PR
git -C "$REPO_B" branch develop "$OLD_SHA"                 # old but protected
git -C "$REPO_B" worktree add "$TMP/wtB-stale" -b issue-102-repob-wt "$OLD_SHA" >/dev/null 2>&1
git -C "$REPO_B" worktree add "$TMP/wtB-dirty" -b issue-103-repob-dirty "$OLD_SHA" >/dev/null 2>&1
echo "dirty" >> "$TMP/wtB-dirty/README.md"                 # uncommitted tracked change
echo "fresh" >> "$REPO_B/README.md"
git -C "$REPO_B" commit -q -am "repoB fresh tip"           # main tip is fresh (now)
git -C "$REPO_B" branch issue-104-repob-fresh              # fresh — appears nowhere
REPO_B_REAL="$(cd "$REPO_B" && pwd -P)"

mkdir -p "$TMP/plain"                                      # non-repo dir for T4

# ---- gh stub -----------------------------------------------------------------
# Serves an open PR on issue-101-repob-pr and records its cwd per call: the
# scope contract requires the open-PR check to run inside the swept repo.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$TMP/prs.json" <<'FIXTURE'
[{"headRefName":"issue-101-repob-pr","createdAt":"2026-07-01T00:00:00Z"}]
FIXTURE
cat > "$STUB_BIN/gh" <<STUB
#!/usr/bin/env bash
pwd -P >> "$TMP/gh-pwd.log"
case "\$*" in
  "pr list --search"*) cat "$TMP/prs.json" ;;
  *) echo "[]" ;;
esac
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

# ---- T1: cwd=repoB, script living in repoA → sweeps repoB --------------------
OUT="$(cd "$REPO_B" && "$SUT" --check --json 2>&1)"
RC=$?
check_eq "T1: exit 1 (stale items found)" 1 "$RC"
check_json "T1: repoB stale branch listed" "$OUT" \
  '.stale_local_branches | map(.branch) | index("issue-100-repob-stale") != null'
check_json "T1: repoB stale worktree listed" "$OUT" \
  '.stale_worktrees | any(.branch == "issue-102-repob-wt")'
check_json "T1: repoB main worktree skipped as main" "$OUT" \
  '.skipped_worktrees | any(.reason == "main worktree" and (.path | endswith("repoB")))'
check_json "T1: protected branch skipped" "$OUT" \
  '.skipped_local_branches | any(.branch == "develop" and .reason == "protected")'
check_json "T1: open-PR branch skipped" "$OUT" \
  '.skipped_local_branches | any(.branch == "issue-101-repob-pr" and .reason == "open PR")'
check_json "T1: checked-out branch skipped" "$OUT" \
  '.skipped_local_branches | any(.branch == "issue-103-repob-dirty" and .reason == "checked out in a worktree")'
check_json "T1: dirty worktree skipped" "$OUT" \
  '.skipped_worktrees | any((.path | endswith("wtB-dirty")) and .reason == "uncommitted tracked changes")'
check_json "T1: fresh branch appears nowhere" "$OUT" \
  '[.. | strings] | any(contains("issue-104-repob-fresh")) | not'
# Negative control — the tripwire for the #697 regression: nothing from repoA
# (its stale branch or any path under it) may appear in the output.
check_json "T1: no repoA refs leak into the sweep (negative control)" "$OUT" \
  '[.. | strings] | any(contains("repoA") or contains("issue-999")) | not'

# ---- T2: open-PR check ran inside the swept repo -----------------------------
GH_PWD="$(tail -1 "$TMP/gh-pwd.log" 2>/dev/null || echo "")"
check_eq "T2: gh pr list ran from repoB root" "$REPO_B_REAL" "$GH_PWD"

# ---- T1b: subdirectory of repoB still resolves repoB's root ------------------
mkdir -p "$REPO_B/subdir"
OUT="$(cd "$REPO_B/subdir" && "$SUT" --check --json 2>&1)"
check_json "T1b: sweep from a repoB subdirectory finds repoB's stale branch" "$OUT" \
  '.stale_local_branches | map(.branch) | index("issue-100-repob-stale") != null'

# ---- T3: --root override beats cwd -------------------------------------------
OUT="$(cd "$REPO_A" && "$SUT" --check --json --root "$REPO_B" 2>&1)"
RC=$?
check_eq "T3: exit 1 under --root" 1 "$RC"
check_json "T3: --root repoB sweeps repoB from repoA cwd" "$OUT" \
  '.stale_local_branches | map(.branch) | index("issue-100-repob-stale") != null'
check_json "T3: no repoA refs under --root (negative control)" "$OUT" \
  '[.. | strings] | any(contains("repoA") or contains("issue-999")) | not'
GH_PWD="$(tail -1 "$TMP/gh-pwd.log" 2>/dev/null || echo "")"
check_eq "T3: gh pr list pinned to --root repo, not cwd" "$REPO_B_REAL" "$GH_PWD"

# ---- T4: cwd outside any repo, no --root → exit 4 ----------------------------
ERR="$(cd "$TMP/plain" && "$SUT" --check 2>&1 >/dev/null)"
RC=$?
check_eq "T4: non-repo cwd exits 4" 4 "$RC"
check_contains "T4: error suggests --root" "--root" "$ERR"

# ---- T5: caller's-current-worktree safety skip survives ----------------------
OUT="$(cd "$TMP/wtB-stale" && "$SUT" --check --json 2>&1)"
check_json "T5: caller's worktree skipped, not stale" "$OUT" \
  '(.skipped_worktrees | any((.path | endswith("wtB-stale")) and (.reason | contains("current worktree"))))
   and (.stale_worktrees | any(.path | endswith("wtB-stale")) | not)'

# ---- T6: --root with a missing value is a usage error ------------------------
( cd "$REPO_B" && "$SUT" --check --root >/dev/null 2>&1 )
check_eq "T6: bare --root exits 3" 3 "$?"
( cd "$TMP/plain" && "$SUT" --check --root "$TMP/plain" >/dev/null 2>&1 )
check_eq "T6b: --root at a non-repo path exits 4" 4 "$?"

# ---- T7: dirty-main-guard resolves the invoking repo -------------------------
# repoA's main is made dirty; repoB gets an origin and a clean pushed main.
# Before the #697 fix the guard resolved repoA (the script's repo) and could
# never report on repoB at all.
echo "dirty-a" >> "$REPO_A/README.md"
git init -q --bare "$TMP/originB.git"
git -C "$REPO_B" remote add origin "$TMP/originB.git"
git -C "$REPO_B" push -q origin main 2>/dev/null

OUT="$(cd "$REPO_B" && "$GUARD" --check --no-fetch)"
RC=$?
check_eq "T7a: clean repoB reports clean (repoA dirt invisible)" 0 "$RC"
check_eq "T7a: output is 'clean'" "clean" "$OUT"

echo "unpushed" >> "$REPO_B/README.md"
git -C "$REPO_B" commit -q -am "unpushed on main"
OUT="$(cd "$REPO_B" && "$GUARD" --check --no-fetch)"
RC=$?
check_eq "T7b: unpushed commit on repoB main exits 1" 1 "$RC"
check_contains "T7b: reports unpushed commit" "unpushed commit" "$OUT"

# ---- T8: --json root key + --root= form + flag-like values (issue #707) ------
OUT="$(cd "$REPO_B" && "$SUT" --check --json 2>&1)"
check_json "T8a: --json includes top-level root ending in repoB" "$OUT" \
  '.root | endswith("/repoB")'
check_json "T8a: all documented JSON keys present alongside root" "$OUT" \
  'has("root") and has("stale_days") and has("threshold_ts")
   and has("stale_worktrees") and has("stale_local_branches") and has("stale_remote_branches")
   and has("skipped_worktrees") and has("skipped_local_branches") and has("skipped_remote_branches")'

# --root=<path> must behave exactly like the two-arg form.
OUT_TWOARG="$(cd "$TMP/plain" && "$SUT" --check --json --root "$REPO_B" 2>&1)"
RC_TWOARG=$?
OUT_EQFORM="$(cd "$TMP/plain" && "$SUT" --check --json --root="$REPO_B" 2>&1)"
RC_EQFORM=$?
check_eq "T8b: --root=<path> exit code matches two-arg form" "$RC_TWOARG" "$RC_EQFORM"
check_eq "T8b: --root=<path> resolves the same root" \
  "$(printf '%s' "$OUT_TWOARG" | jq -r '.root')" \
  "$(printf '%s' "$OUT_EQFORM" | jq -r '.root')"

# Empty or flag-like --root values are usage errors (3), never resolution
# failures (4) — `--root --json` previously swallowed --json as the path.
( cd "$REPO_B" && "$SUT" --check --root --json >/dev/null 2>&1 )
check_eq "T8c: --root with flag-like value exits 3" 3 "$?"
( cd "$REPO_B" && "$SUT" --check --root=--json >/dev/null 2>&1 )
check_eq "T8c: --root= with flag-like value exits 3" 3 "$?"
( cd "$REPO_B" && "$SUT" --check --root= >/dev/null 2>&1 )
check_eq "T8c: --root= with empty value exits 3" 3 "$?"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "OK: stale-cleanup.sh + dirty-main-guard.sh — invoking-repo scope verified (issue #697)"
