#!/usr/bin/env bash
# catalog: tests — Tests for `ownerless-state-retire.sh`: dry run writes nothing, apply retires only the listed records and keeps siblings, failed GitHub lookups write nothing, other repos are never touched, and the inventory then reads safe
#
# Builds its own fixtures (fake HOME, stub `gh`) so it never touches real
# session state or GitHub. Run from the repo root.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/.claude/scripts/ownerless-state-retire.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   — $*"; }

export HOME="$TMP/home"
mkdir -p "$HOME/.claude" "$TMP/bin"
STATE="$HOME/.claude/session-state.json"
REPO=acme/widgets
NOW=2026-11-18T00:00:00Z

# stub gh: `pr view N` answers from STUB_PR_STATES ("873=MERGED 900=OPEN ..."); everything else fails.
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1 $2" == "pr view" ]] || exit 1
[[ -n "${STUB_FAIL:-}" ]] && exit 1
for kv in ${STUB_PR_STATES:-}; do
  [[ "${kv%%=*}" == "$3" ]] && { echo "${kv#*=}"; exit 0; }
done
exit 1
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export STUB_PR_STATES="873=MERGED 948=CLOSED 900=OPEN"

fixture() {
  jq -n --arg r "$REPO" '{
    active_agents: {
      "a-merged":  {id:"a-merged", task:"issue-1", pr:873, phase:"B", status:"spawned", launched:"2026-11-15T00:00:00Z", owner_repo:$r},
      "a-closed":  {id:"a-closed", pr:948, phase:"A", status:"spawned", owner_repo:$r},
      "a-open":    {id:"a-open",   pr:900, phase:"A", status:"spawned", launched:"2026-11-17T00:00:00Z", owner_repo:$r},
      "a-old":     {id:"a-old", phase:"A", status:"spawned", launched:"2026-10-01T00:00:00Z", owner_repo:$r},
      "a-bare":    {id:"a-bare", phase:"A", status:"spawned"},
      "a-other":   {id:"a-other", pr:873, status:"spawned", launched:"2026-10-01T00:00:00Z", owner_repo:"elsewhere/else"},
      "a-owned":   {id:"a-owned", pr:873, status:"spawned", session_id:"sess-9", owner_repo:$r},
      "a-owned2":  {id:"a-owned2", pr:873, status:"spawned", session_id:"", session:"sess-live", owner_repo:$r},
      "a-done":    {id:"a-done", pr:873, status:"done", owner_repo:$r}
    },
    pipelines: {
      "2718": {started_at:"2026-10-05T08:00:00Z", pr:null},
      "2732": {started_at:"2026-10-05T08:00:00Z", pr:4355}
    },
    repos: {($r): {prs: {}}, "elsewhere/else": {prs: {"4355": {reviewer:"cr"}}}},
    unrelated: {keep: true}
  }' > "$STATE"
}
run() { "$SCRIPT" --repo "$REPO" --now "$NOW" "$@"; }

# ---- 1. dry run lists the plan and writes nothing --------------------------------------
fixture
before="$(shasum "$STATE")"
OUT="$(run)"; rc=$?
[[ $rc == 0 && "$(jq -r .mode <<<"$OUT")" == dry_run ]] || { echo "$OUT" >&2; fail "dry run did not succeed (rc=$rc)"; }
[[ "$(shasum "$STATE")" == "$before" ]] || fail "the dry run wrote to session-state"
got="$(jq -r '[.retire[].key] | sort | join(",")' <<<"$OUT")"
[[ "$got" == "a-closed,a-merged,a-old" ]] || { echo "$OUT" >&2; fail "dry run planned the wrong set: $got"; }
jq -e '.retire[] | select(.key=="a-merged") | .reason == "pr_finished" and (.detail|test("merged"))' >/dev/null <<<"$OUT" || fail "merged PR reason missing"
jq -e '.retire[] | select(.key=="a-old") | .reason == "aged_out"' >/dev/null <<<"$OUT" || fail "aged-out reason missing"
jq -e '.skipped[] | select(.key=="a-other") | .reason | test("another repo")' >/dev/null <<<"$OUT" || fail "another repo's record not skipped with a reason"
jq -e '.skipped[] | select(.key=="a-open")' >/dev/null <<<"$OUT" || fail "open-PR record not skipped"
jq -e '.skipped[] | select(.key=="2718") | .reason | test("include-unscoped")' >/dev/null <<<"$OUT" || fail "unscoped record not skipped without --include-unscoped"
ok "dry run lists what it would retire, with reasons, and writes nothing"

# ---- 2. apply changes only those records and preserves siblings -------------------------
OUT="$(run --apply)"; rc=$?
[[ $rc == 0 && "$(jq '.applied|length' <<<"$OUT")" == 3 ]] || { echo "$OUT" >&2; fail "apply did not retire the planned records (rc=$rc)"; }
for k in a-merged a-closed a-old; do
  jq -e --arg k "$k" '.active_agents[$k] | .status == "abandoned" and .outcome == "retired" and (.retired_reason|length>0) and .retired_at == "2026-11-18T00:00:00Z" and .id == $k' "$STATE" >/dev/null \
    || fail "$k was not marked terminal with its fields kept"
done
jq -e '.active_agents["a-merged"] | .task == "issue-1" and .phase == "B" and .pr == 873' "$STATE" >/dev/null || fail "retired record lost a field"
jq -e '.active_agents["a-open"].status == "spawned" and .active_agents["a-bare"].status == "spawned" and (.active_agents["a-bare"]|has("outcome")|not)' "$STATE" >/dev/null || fail "an unplanned record changed"
jq -e '.active_agents["a-other"] == {id:"a-other", pr:873, status:"spawned", launched:"2026-10-01T00:00:00Z", owner_repo:"elsewhere/else"}' "$STATE" >/dev/null || fail "another repo's record was modified"
jq -e '.active_agents["a-owned"].status == "spawned" and .active_agents["a-owned2"].status == "spawned" and .active_agents["a-done"].status == "done" and .unrelated.keep == true and (.pipelines["2718"]|has("outcome")|not)' "$STATE" >/dev/null || fail "a sibling field changed"
ok "apply retires only the listed records and preserves sibling records and fields"

# ---- 3. unscoped records need the flag; one whose PR another repo tracks is left alone -----
OUT="$(run --include-unscoped)"
got="$(jq -r '[.retire[].key] | sort | join(",")' <<<"$OUT")"
[[ "$got" == "2718" ]] || { echo "$OUT" >&2; fail "unscoped plan wrong: $got"; }
jq -e '.skipped[] | select(.key=="2732") | .reason | test("another repo tracks")' >/dev/null <<<"$OUT" || fail "unscoped record naming another repo's PR was not skipped"
jq -e '.skipped[] | select(.key=="a-bare") | .reason | test("no timestamp and no PR")' >/dev/null <<<"$OUT" || fail "record with no timestamp and no PR was not skipped"
ok "unscoped records need --include-unscoped; another repo's PR and no-evidence records are skipped"

# ---- 4. a failed GitHub lookup leaves every record unchanged and exits non-zero ----------
fixture
before="$(shasum "$STATE")"
STUB_FAIL=1 run --apply >/dev/null 2>&1; rc=$?
[[ $rc == 4 ]] || fail "failed lookup should exit 4 (got $rc)"
[[ "$(shasum "$STATE")" == "$before" ]] || fail "a failed lookup changed session-state"
STUB_PR_STATES="873=MERGED" run --apply >/dev/null 2>&1; rc=$?
[[ $rc == 4 && "$(shasum "$STATE")" == "$before" ]] || fail "one failed lookup among good ones still wrote"
ok "a failed GitHub lookup writes nothing and exits 4"

# ---- 5. a live runtime id blocks the age rule; an unreadable registry turns it off -------
"$ROOT/.claude/scripts/background-task-registry.sh" --repo "$REPO" --register --session s-live \
  --task-id a-old --type agent >/dev/null || fail "could not register fixture task"
OUT="$(run)"
jq -e '.skipped[] | select(.key=="a-old") | .reason | test("live runtime")' >/dev/null <<<"$OUT" || { echo "$OUT" >&2; fail "a live runtime id did not block the age rule"; }
"$ROOT/.claude/scripts/background-task-registry.sh" --repo "$REPO" --transition --session s-live --task-id a-old --status stopped >/dev/null
ok "a live runtime id keeps an old record"

# ---- 6. a lone record in an otherwise minimal state file is retired ------------------------
jq -n '{active_agents:{"a-merged":{id:"a-merged",pr:873,status:"spawned",launched:"2026-11-15T00:00:00Z",owner_repo:"acme/widgets"}}}' > "$STATE"
run --apply >/dev/null || fail "apply on a single record failed"
jq -e '.active_agents["a-merged"].outcome == "retired"' "$STATE" >/dev/null || fail "single record not retired"
OUT="$(run)"
[[ "$(jq '.retire|length' <<<"$OUT")" == 0 ]] || fail "a retired record was planned again"
ok "a retired record is terminal: a second run plans nothing"

# ---- 7. a record that changed since the plan is left as it is ------------------------------
# Simulate the race: a stub session-state.sh that rewrites the record just before the real CAS.
fixture
mkdir -p "$TMP/race"
cp "$ROOT/.claude/scripts/ownerless-state-retire.sh" "$TMP/race/"
cp "$ROOT/.claude/scripts/background-task-registry.sh" "$TMP/race/" 2>/dev/null || true
for f in "$ROOT"/.claude/scripts/*.sh; do [[ -e "$TMP/race/$(basename "$f")" ]] || ln -s "$f" "$TMP/race/$(basename "$f")"; done
rm -f "$TMP/race/session-state.sh"
cat > "$TMP/race/session-state.sh" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == --cas ]]; then
    jq '.active_agents["a-merged"].session_id = "sess-late"' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    break
  fi
done
exec "$ROOT/.claude/scripts/session-state.sh" "\$@"
EOF
chmod +x "$TMP/race/session-state.sh"
OUT="$("$TMP/race/ownerless-state-retire.sh" --repo "$REPO" --now "$NOW" --apply)"; rc=$?
[[ $rc == 1 ]] || { echo "$OUT" >&2; fail "a changed record should make apply exit 1 (got $rc)"; }
jq -e '.failed[] | select(.key=="a-merged") | .reason | test("changed")' >/dev/null <<<"$OUT" || fail "changed record not reported"
jq -e '.active_agents["a-merged"] | .status == "spawned" and .session_id == "sess-late" and (has("outcome")|not)' "$STATE" >/dev/null || fail "a changed record was overwritten"
ok "a record that changed between plan and write is left as it is"

# ---- 8. usage --------------------------------------------------------------------------------
"$SCRIPT" >/dev/null 2>&1; [[ $? == 2 ]] || fail "missing --repo should exit 2"
"$SCRIPT" --repo bad >/dev/null 2>&1; [[ $? == 2 ]] || fail "bad --repo should exit 2"
"$SCRIPT" --repo "$REPO" --bogus >/dev/null 2>&1; [[ $? == 2 ]] || fail "unknown flag should exit 2"
grep -q 'ownerless-state-retire.sh' <<<"$("$SCRIPT" --help)" || fail "--help missing"
ok "usage errors and --help"

echo "all ownerless-state-retire tests passed"
