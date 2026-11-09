#!/usr/bin/env bash
# Regression checks for issue-claim renewal and tracking-parent wiring (issue #1927).
# catalog: tests — Asserts /subagent, /start-issue and /wrap renew the claim at their documented points, stop on exit 5, and that Form B stays identical in both copies
#
# The renewal mechanism (#1914) only keeps live work claimed if the long-running
# callers actually call it. These checks pin the wiring in the skill text:
#   * each of the three skills runs `--renew` with an explicit `--holder` and
#     names exit 5 as a stop;
#   * /subagent captures the holder from `--claim --json`, renews at the 30-min
#     cadence and says never on every tick;
#   * /wrap renews before its /fixpr wait dispatch, not after it;
#   * the Form B claim bullet is byte-identical in chip-launching.md and
#     /start-issue, and the canonical Form A bullet keeps direct and delegated pickup separate.
#
# Run from repo root: bash .claude/scripts/tests/claim-renewal-wiring.test.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUBAGENT="$REPO_ROOT/.claude/skills/subagent/SKILL.md"
START="$REPO_ROOT/.claude/skills/start-issue/SKILL.md"
WRAP="$REPO_ROOT/.claude/skills/wrap/SKILL.md"
CHIP="$REPO_ROOT/.claude/reference/chip-launching.md"
RULE="$REPO_ROOT/.claude/rules/issue-planning.md"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   — $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }
has()  { # has <desc> <file> <fixed-string>; an unreadable file was already failed once above
  [[ -r "$2" ]] || return 0
  if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1 (missing in ${2#"$REPO_ROOT"/}: $3)"; fi
}
first_line() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }

for f in "$SUBAGENT" "$START" "$WRAP" "$CHIP" "$RULE"; do
  [[ -r "$f" ]] || bad "readable: ${f#"$REPO_ROOT"/}"
done

# --- /subagent ---------------------------------------------------------------
has "/subagent claims with --json to capture the holder" "$SUBAGENT" '--claim --json'
has "/subagent records claim_holder"                     "$SUBAGENT" 'pipelines[\"{ISSUE_NUMBER}\"].claim_holder='
has "/subagent renews with the recorded holder"          "$SUBAGENT" '--renew --holder "$C_HOLDER"'
has "/subagent renews before successor launches"         "$SUBAGENT" 'immediately before launching any successor'
has "/subagent 30-minute cadence"                        "$SUBAGENT" '**≥30 minutes** old'
has "/subagent never renews on every tick"               "$SUBAGENT" 'Never renew on every tick'
has "/subagent exit 5 blocks the successor"              "$SUBAGENT" 'Exit 5 → launch nothing for that issue'
has "/subagent Phase C prompt hands the pair to /wrap"   "$SUBAGENT" 'CLAIM_PAIRS="{ISSUE_NUMBER} {CLAIM_HOLDER}"'

# Run the real parent-state gate after its surrounding claim check succeeded.
# shellcheck source=lib/skill-bash.sh
source "$REPO_ROOT/.claude/scripts/tests/lib/skill-bash.sh"
PARENT_GATE=$(extract_skill_bash "$SUBAGENT" subagent-decomposition-parent-open)
run_parent_gate() {
  local state="$1" native_rc="$2" expected_rc="$3" name="$4" out rc=0 fixture
  fixture='
    gh() {
      [[ "$*" == "issue view 873 --json state --jq .state" ]] || return 99
      printf "%s\n" "$NATIVE_STATE"
      return "$NATIVE_RC"
    }'
  out=$(
    PARENT=873 NATIVE_STATE="$state" NATIVE_RC="$native_rc" \
      "$BASH" -c "$fixture"$'\n'"$PARENT_GATE"$'\n''printf "%s\n" CREATE' 2>&1
  ) || rc=$?
  if [[ "$rc" == "$expected_rc" ]] &&
     { [[ "$rc" == 0 && "$out" == CREATE ]] ||
       [[ "$rc" != 0 && "$out" != *CREATE* && "$out" == *"not confirmed open"* ]]; }; then
    ok "$name"
  else
    bad "$name (rc=$rc; output=$out)"
  fi
}
run_parent_gate OPEN   0 0 "native OPEN parent permits child filing"
run_parent_gate CLOSED 0 5 "closed tracking parent blocks child filing"
run_parent_gate OPEN   1 5 "failed native read blocks filing even if it printed OPEN"
run_parent_gate ''     0 5 "missing native state blocks child filing"

# --- /wrap -------------------------------------------------------------------
has "/wrap renews with a handed-over holder"   "$WRAP" '--renew --holder "$C_HOLDER"'
has "/wrap exit 5 stops the merge"             "$WRAP" "5) echo \"BLOCKED: lost ownership"
has "/wrap never adopts a GitHub holder"       "$WRAP" 'never adopt a `claimant_holder`'
RENEW_AT=$(first_line "$WRAP" '--renew --holder')
LOOP_AT=$(first_line "$WRAP" '**Recovery loop**')
if [[ -n "$RENEW_AT" && -n "$LOOP_AT" && "$RENEW_AT" -lt "$LOOP_AT" ]]; then
  ok "/wrap renewal precedes the recovery loop's /fixpr dispatch"
else
  bad "/wrap renewal does not precede the recovery loop (renew=$RENEW_AT loop=$LOOP_AT)"
fi

# --- /start-issue + Form B ---------------------------------------------------
has "/start-issue Form B renews before waits" "$START" '--renew --holder "{CLAIM_HOLDER}"'
has "/start-issue Form B names exit 5"        "$START" 'exit 5 → stop and report lost ownership'

formb() { grep -F -- '- This issue is already claimed for you (holder `{CLAIM_HOLDER}`)' "$1"; }
FB_CHIP=$(formb "$CHIP"); FB_START=$(formb "$START")
if [[ -n "$FB_CHIP" && "$FB_CHIP" == "$FB_START" ]]; then
  ok "Form B identical in chip-launching.md and /start-issue"
else
  bad "Form B differs between chip-launching.md and /start-issue (or is missing)"
fi
if [[ "$FB_CHIP" == *'then run `<N> --renew --holder "{CLAIM_HOLDER}"` on it'* ]]; then
  ok "Form B confirms the inherited claim without acquiring one"
else
  bad "Form B does not start with a renew-only claim check"
fi
if [[ "$FB_CHIP" == *"renews the claim when due"* && "$FB_CHIP" != *"It is a no-op"* ]]; then
  ok "Form B says it renews when due"
else
  bad "Form B still describes the reaffirm as a pure no-op"
fi
FORMA=$(grep -F -- '- Claim the issue before anything else.' "$CHIP")
if [[ "$FORMA" == *'--check --holder "$CLAIM_HOLDER"'* &&
      "$FORMA" == *'--claim --holder "$CLAIM_HOLDER" --json'* &&
      "$FORMA" == *'--renew --holder "$CLAIM_HOLDER"'* &&
      "$FORMA" == *'chip-claim-receipt.sh save WORKTREE OWNER/REPO N "$CLAIM_HOLDER"'* &&
      "$FORMA" == *'chip-claim-receipt.sh read WORKTREE OWNER/REPO N'* &&
      "$FORMA" == *'at least every 30 minutes of long coding'* &&
      "$FORMA" == *'as `CLAIM_PAIRS`'* ]]; then
  ok "Form A carries its acquired holder into periodic renewal, recovery and wrap"
else
  bad "Form A does not preserve the holder through the pipeline"
fi
if [[ "$FORMA" == *'only check ownership read-only for each issue'* &&
      "$FORMA" == *'let `/subagent` Step 6.0 acquire each eligible claim'* ]]; then
  ok "Form A leaves delegated acquisition to /subagent Step 6.0"
else
  bad "Form A can claim on behalf of a delegated pipeline"
fi

# --- rule --------------------------------------------------------------------
has "issue-planning step 0 names --renew --holder" "$RULE" '`--renew --holder <token>`'
has "issue-planning step 0 names the exit-5 stop"  "$RULE" 'exit 5 → **STOP**, report lost ownership'

echo
echo "claim-renewal-wiring.test.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
