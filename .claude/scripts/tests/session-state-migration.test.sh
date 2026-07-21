#!/usr/bin/env bash
# Unit tests for session-state.sh's legacy -> per-repo migration (issue #638).
#
# The defect being fixed: `.prs` was a flat map keyed by bare PR number, so two
# repos that both reached PR #84 silently overwrote each other, and `.root_repo`
# was one global scalar naming whichever repo wrote last. State is now scoped as
# `.repos["<owner>/<name>"].prs["<N>"]`.
#
# The migration is the risky half of that change — there is live state with 40+
# entries — so these tests pin the properties that matter most:
#   - no entry is ever dropped, including entries with no `owner_repo`
#   - entries are attributed by `owner_repo`, falling back to the repo identity
#     of their recorded `root_repo` checkout when that path still resolves
#   - it is idempotent (running twice changes nothing)
#   - already-scoped data wins over legacy data on conflict
#   - a corrupt legacy shape is left alone rather than silently discarded
#
# Uses a temporary HOME so it never touches the real ~/.claude/. Requires jq and
# git. Run from repo root:
#   bash .claude/scripts/tests/session-state-migration.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/.claude/scripts/session-state.sh"

TMP_HOME="$(mktemp -d)"
WORK_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_HOME" "$WORK_DIR"; }
trap cleanup EXIT
export HOME="$TMP_HOME"
mkdir -p "$HOME/.claude"
STATE_FILE="$HOME/.claude/session-state.json"

PASS=0
FAIL=0
check_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1)); echo "ok   — $desc"
  else
    FAIL=$((FAIL + 1)); echo "FAIL — $desc (expected '$expected', got '$actual')"
  fi
}

run() { bash "$SCRIPT" "$@"; }

# A real git checkout whose `origin` names a known repo, so the root_repo ->
# repo-identity fallback has something genuine to resolve. Worktree-style
# paths resolve through the same remote, which is the property that makes repo
# identity a safer scope key than the checkout path.
REAL_CHECKOUT="$WORK_DIR/checkout"
mkdir -p "$REAL_CHECKOUT"
git -C "$REAL_CHECKOUT" init --quiet
git -C "$REAL_CHECKOUT" remote add origin "https://github.com/org/resolved.git"

echo "== Migration: attribution, preservation, and layout =="
cat > "$STATE_FILE" <<JSON
{
  "root_repo": "$REAL_CHECKOUT",
  "prs": {
    "84":  {"owner_repo": "org/a", "phase": "B"},
    "85":  {"owner_repo": "org/b", "phase": "C"},
    "86":  {"root_repo": "$REAL_CHECKOUT", "phase": "A"},
    "87":  {"phase": "B"},
    "88":  {"root_repo": "/nonexistent/path/gone", "phase": "A"}
  },
  "greptile_daily": {"reviews_used": 3},
  "active_agents": [{"id": "a1"}]
}
JSON
run --migrate
check_eq "migration exits 0" "0" "$?"
check_eq "schema version bumped to 2" "2" "$(jq -r '.schema_version' "$STATE_FILE")"
check_eq "flat .prs removed" "null" "$(jq -c '.prs' "$STATE_FILE")"
check_eq "global .root_repo removed" "null" "$(jq -c '.root_repo' "$STATE_FILE")"
check_eq "every entry survives" "5" "$(jq '[.repos[].prs // {} | length] | add' "$STATE_FILE")"
check_eq "owner_repo attributes #84" "B" "$(jq -r '.repos["org/a"].prs["84"].phase' "$STATE_FILE")"
check_eq "owner_repo attributes #85" "C" "$(jq -r '.repos["org/b"].prs["85"].phase' "$STATE_FILE")"
check_eq "root_repo path attributes #86 via its remote" "A" "$(jq -r '.repos["org/resolved"].prs["86"].phase' "$STATE_FILE")"
check_eq "unattributable entry is preserved, not dropped" "B" "$(jq -r '.repos["_unknown"].prs["87"].phase' "$STATE_FILE")"
check_eq "unresolvable root_repo is preserved too" "A" "$(jq -r '.repos["_unknown"].prs["88"].phase' "$STATE_FILE")"
check_eq "global root_repo lands on its own repo" "$REAL_CHECKOUT" "$(jq -r '.repos["org/resolved"].root_repo' "$STATE_FILE")"
check_eq "unrelated top-level fields untouched" '{"greptile_daily":{"reviews_used":3},"active_agents":[{"id":"a1"}]}' \
  "$(jq -c '{greptile_daily, active_agents}' "$STATE_FILE")"

echo
echo "== Migration is idempotent =="
BEFORE="$(jq -S 'del(.last_updated)' "$STATE_FILE")"
run --migrate
AFTER="$(jq -S 'del(.last_updated)' "$STATE_FILE")"
check_eq "second migration is a no-op" "$BEFORE" "$AFTER"

echo
echo "== --dry-run previews without writing =="
cat > "$STATE_FILE" <<'JSON'
{"prs": {"84": {"owner_repo": "org/a", "phase": "B"}}}
JSON
DRY="$(run --migrate --dry-run)"
check_eq "dry-run output is already scoped" "B" "$(jq -r '.repos["org/a"].prs["84"].phase' <<<"$DRY")"
check_eq "dry-run left the file flat" "B" "$(jq -r '.prs["84"].phase' "$STATE_FILE")"

echo
echo "== Conflict: already-scoped data wins over legacy =="
cat > "$STATE_FILE" <<'JSON'
{
  "prs":   {"84": {"owner_repo": "org/a", "phase": "OLD", "legacy_only": true}},
  "repos": {"org/a": {"prs": {"84": {"phase": "NEW"}}}}
}
JSON
run --migrate
check_eq "scoped value wins on conflict" "NEW" "$(jq -r '.repos["org/a"].prs["84"].phase' "$STATE_FILE")"
check_eq "legacy-only fields still merge in" "true" "$(jq -r '.repos["org/a"].prs["84"].legacy_only' "$STATE_FILE")"

echo
echo "== A read migrates in memory but never rewrites the file =="
cat > "$STATE_FILE" <<'JSON'
{"prs": {"84": {"owner_repo": "org/a", "phase": "B"}}}
JSON
check_eq "read sees the scoped value" "B" "$(run --repo org/a --get '.prs["84"].phase')"
check_eq "read did not rewrite the file" "B" "$(jq -r '.prs["84"].phase' "$STATE_FILE")"
check_eq "another repo does not see it" "null" "$(run --repo org/b --get '.prs["84"].phase')"

echo
echo "== A write persists the migration =="
run --repo org/b --set '.prs["99"].phase=A'
check_eq "write migrated the legacy entry too" "B" "$(jq -r '.repos["org/a"].prs["84"].phase' "$STATE_FILE")"
check_eq "write landed in its own scope" "A" "$(jq -r '.repos["org/b"].prs["99"].phase' "$STATE_FILE")"
check_eq "flat .prs is gone after the write" "null" "$(jq -c '.prs' "$STATE_FILE")"

echo
echo "== Corrupt legacy shape is left alone, not discarded =="
cat > "$STATE_FILE" <<'JSON'
{"prs": "this is not an object"}
JSON
OUT="$(run --migrate 2>&1)"
check_eq "corrupt legacy .prs is preserved verbatim" "this is not an object" "$(jq -r '.prs' "$STATE_FILE")"
check_eq "and the refusal is reported" "1" "$(grep -c "malformed" <<<"$OUT")"

echo
echo "== Remote-URL forms all resolve to the same repo key =="
# An SSH remote must not collapse to an empty key: that would send every
# SSH-remote checkout into "_unknown" and leave the collision unfixed for it.
for form in \
  "https://github.com/org/urlforms.git" \
  "https://github.com/org/urlforms" \
  "git@github.com:org/urlforms.git" \
  "ssh://git@github.com:22/org/urlforms.git"; do
  d="$WORK_DIR/remote-$RANDOM$$"
  mkdir -p "$d"
  git -C "$d" init --quiet
  git -C "$d" remote add origin "$form"
  check_eq "remote form resolves: $form" "org/urlforms" "$( cd "$d" && run --repo-key )"
done

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: session-state.sh migration tests passed"
