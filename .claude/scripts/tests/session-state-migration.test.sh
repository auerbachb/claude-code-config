#!/usr/bin/env bash
# Unit tests for session-state.sh's legacy -> per-repo migration (issue #638).
# catalog: tests — Tests the legacy-flat → per-repo migration in `session-state.sh`
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
# covers:
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
# active_agents rides the same write: the legacy array is migrated to the keyed
# map on any write pipeline (issue #1631), so "untouched" here means the value
# survives, not that its shape does.
check_eq "unrelated top-level fields untouched" '{"greptile_daily":{"reviews_used":3},"active_agents":{"a1":{"id":"a1"}}}' \
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
echo "== Case-divergence regression (issue #704): mixed-case remote lowercased =="
# repo_key_from_remote_url() must lowercase so a mixed-case origin remote
# (e.g. AuerbachB/Skingod) produces the same .repos scope key as the lowercase
# form (auerbachb/skingod) that polling-state-gate.sh's repo_identity() emits.
for mc_form in \
  "https://github.com/AuerbachB/Skingod.git" \
  "git@github.com:AuerbachB/Skingod.git" \
  "ssh://git@github.com:22/AuerbachB/Skingod.git"; do
  d="$WORK_DIR/case-$RANDOM$$"
  mkdir -p "$d"
  git -C "$d" init --quiet
  git -C "$d" remote add origin "$mc_form"
  check_eq "mixed-case remote lowercased: $mc_form" "auerbachb/skingod" \
    "$( cd "$d" && run --repo-key )"
done

# --repo flag with mixed-case must also lowercase (covers REPO_ARG branch of
# resolve_repo_key, which bypasses repo_key_from_remote_url entirely).
check_eq "--repo flag with mixed case lowercased" "auerbachb/skingod" \
  "$(run --repo AuerbachB/Skingod --repo-key)"

echo
echo "== Case-divergence regression (issue #704): mixed-case owner_repo in migration =="
# A legacy flat entry whose owner_repo carries GitHub's canonical mixed case
# must migrate into the lowercase .repos scope, not a mixed-case one.
cat > "$STATE_FILE" <<'JSON'
{
  "prs": {
    "200": {"owner_repo": "AuerbachB/Skingod", "phase": "A"},
    "201": {"owner_repo": "Org/CAPS",           "phase": "B"}
  }
}
JSON
run --migrate
check_eq "mixed-case owner_repo #200 lands in lowercase scope" "A" \
  "$(jq -r '.repos["auerbachb/skingod"].prs["200"].phase' "$STATE_FILE")"
check_eq "mixed-case owner_repo #201 lands in lowercase scope" "B" \
  "$(jq -r '.repos["org/caps"].prs["201"].phase' "$STATE_FILE")"
check_eq "no mixed-case scope created for #200" "null" \
  "$(jq -r '.repos["AuerbachB/Skingod"] // "null"' "$STATE_FILE")"
check_eq "no mixed-case scope created for #201" "null" \
  "$(jq -r '.repos["Org/CAPS"] // "null"' "$STATE_FILE")"

# --- issue #2433: --migrate is locked and skips no-op rewrites ---------------
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

echo
echo "== issue #2433: a no-op --migrate leaves bytes and mtime untouched =="
# Already migrated by the previous case; backdate the file so a rewrite shows.
touch -t 202001010000 "$STATE_FILE"
BEFORE_BYTES="$(cat "$STATE_FILE")"
BEFORE_MTIME="$(mtime_of "$STATE_FILE")"
run --migrate; RC=$?
check_eq "no-op --migrate exits 0" "0" "$RC"
check_eq "bytes unchanged" "$BEFORE_BYTES" "$(cat "$STATE_FILE")"
check_eq "mtime unchanged" "$BEFORE_MTIME" "$(mtime_of "$STATE_FILE")"
check_eq "--dry-run still prints the document" "B" "$(run --migrate --dry-run | jq -r '.repos["org/caps"].prs["201"].phase')"

echo
echo "== issue #2433: a concurrent --set is serialized behind --migrate =="
cat > "$STATE_FILE" <<'JSON'
{ "prs": { "300": {"owner_repo": "org/serial", "phase": "A"} } }
JSON
SHIM="$WORK_DIR/jq-shim"; PARK="$WORK_DIR/park"; mkdir -p "$SHIM" "$PARK"
REAL_JQ="$(command -v jq)"
# Parks the FIRST jq call that runs the migrate filter UNDER THE LOCK (the
# unlocked no-op pre-check runs first and must not park), only in the process
# that carries MIG_PARK (the --migrate under test), until released.
cat > "$SHIM/jq" <<SH
#!/bin/bash
if [[ -n "\${MIG_PARK:-}" && ! -e "\$MIG_PARK/parked" && "\$*" == *"migrate("* && -d "$STATE_FILE.lock" ]]; then
  : > "\$MIG_PARK/parked"
  while [[ ! -e "\$MIG_PARK/release" ]]; do sleep 0.05; done
fi
exec "$REAL_JQ" "\$@"
SH
chmod +x "$SHIM/jq"
( PATH="$SHIM:$PATH" MIG_PARK="$PARK" run --migrate; echo "$?" > "$PARK/mig.rc" ) &
MIG_PID=$!
for _ in $(seq 1 200); do [[ -e "$PARK/parked" ]] && break; sleep 0.05; done
check_eq "(setup) --migrate parked inside its jq pass" "1" "$([[ -e "$PARK/parked" ]] && echo 1 || echo 0)"
# The serialization claim rests on --migrate holding the lock while parked.
check_eq "--migrate holds the state lock while parked" "1" "$([[ -d "$STATE_FILE.lock" ]] && echo 1 || echo 0)"
( CLAUDE_STATE_LOCK_TIMEOUT=30 run --set '.marker="kept"'; echo "$?" > "$PARK/set.rc" ) &
SET_PID=$!
sleep 0.5
check_eq "the concurrent --set is waiting on the lock" "0" "$([[ -e "$PARK/set.rc" ]] && echo 1 || echo 0)"
: > "$PARK/release"
wait "$MIG_PID" "$SET_PID"
check_eq "--migrate exited 0" "0" "$(cat "$PARK/mig.rc")"
check_eq "--set exited 0" "0" "$(cat "$PARK/set.rc")"
check_eq "the concurrent --set value survived" "kept" "$(jq -r '.marker' "$STATE_FILE")"
check_eq "the migration landed too" "A" "$(jq -r '.repos["org/serial"].prs["300"].phase' "$STATE_FILE")"

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: session-state.sh migration tests passed"
