#!/usr/bin/env bash
# Offline tests for pm-human-tasks.sh and the /pm human-task wiring (issue #2563).
# catalog: tests — Tests for `pm-human-tasks.sh` and `/pm`'s human-task checkpoint: the open count from `owner-task.sh list --json` (an unreadable or missing list reported as unreadable, never zero), saving a new item with its receipt, skipping one already on the list for the same what and source (open or done), splitting a sub-agent `OWNER_ACTION:` line, not-saved lines carrying owner-task.sh's exit (public repo with no bucket, unreadable duplicate check), an ambiguous add resolved by a re-list, the skill's save and count blocks, and the module routing from the report modules
# covers: .claude/scripts/pm-human-tasks.sh .claude/skills/pm/SKILL.md .claude/skills/pm/modules/shared/human-tasks.md .claude/skills/pm/modules/rank/present.md .claude/skills/pm/modules/resume/present.md .claude/skills/pm/modules/flow/progress.md .claude/skills/pm/modules/day-tick.md .claude/skills/pm/scripts/dispatch-module.sh
# Stubs owner-task.sh (no network, nothing written to GitHub). Run from anywhere:
#   bash .claude/scripts/tests/pm-human-tasks.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO_ROOT/.claude/scripts/pm-human-tasks.sh"
SKILL="$REPO_ROOT/.claude/skills/pm"
MODULE="$SKILL/modules/shared/human-tasks.md"
# shellcheck source=lib/skill-bash.sh
source "$REPO_ROOT/.claude/scripts/tests/lib/skill-bash.sh"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "ok   — $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL — $1"; }
check_eq() {
  if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
check_contains() {
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1 (missing '$2' in: $3)"; fi
}
check_absent() {
  if [[ "$3" != *"$2"* ]]; then pass "$1"; else fail "$1 (unexpected '$2' in: $3)"; fi
}

# ---- stub owner-task.sh -------------------------------------------------------
# State: $TMP/tasks.json (the full list, open and done). Knobs:
#   $TMP/list-rc       list exits with this code, printing nothing
#   $TMP/list-garbage  list prints a non-array
#   $TMP/add-rc        add exits with this code (message on stderr)
#   $TMP/add-writes    with add-rc 1: the task is written anyway (ambiguous)
STUB="$TMP/bin/owner-task.sh"
mkdir -p "$TMP/bin"
cat > "$STUB" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/calls.log"
st="$TMP/tasks.json"
[ -f "\$st" ] || echo '[]' > "\$st"
verb="\$1"; shift
case "\$verb" in
  list)
    [ -f "$TMP/list-rc" ] && exit "\$(cat "$TMP/list-rc")"
    [ -f "$TMP/list-garbage" ] && { echo 'No human tasks.'; exit 0; }
    all=0
    for a in "\$@"; do [ "\$a" = --all ] && all=1; done
    jq -c --argjson all "\$all" 'map(select(\$all == 1 or .state == "open"))' "\$st"
    ;;
  add)
    what=""; why=""; src=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --what) what="\$2"; shift 2 ;;
        --why) why="\$2"; shift 2 ;;
        --source) src="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s|%s|%s\n' "\$what" "\$why" "\$src" >> "$TMP/adds.log"
    rc=0; [ -f "$TMP/add-rc" ] && rc="\$(cat "$TMP/add-rc")"
    if [ "\$rc" -eq 0 ] || [ -f "$TMP/add-writes" ]; then
      n=\$(jq length "\$st")
      jq --arg w "\$what" --arg y "\$why" --arg s "\$src" --arg id "ht-0000000\$n" \
        '. + [{id:\$id, repo:"acme/w", what:\$w, why:\$y, source:\$s, created_at:"2026-11-19T12:00:00Z", state:"open", done_at:null, proof:null}]' \
        "\$st" > "\$st.tmp" && mv "\$st.tmp" "\$st"
    fi
    if [ "\$rc" -ne 0 ]; then
      case "\$rc" in
        3) echo "owner-task: acme/w is public and no private bucket is set; nothing written" >&2 ;;
        *) echo "owner-task: could not write the task to acme/w#9" >&2 ;;
      esac
      exit "\$rc"
    fi
    echo "ht-0000000\$n"
    ;;
  *) echo "unexpected verb \$verb" >&2; exit 64 ;;
esac
STUBEOF
chmod +x "$STUB"
export OWNER_TASK_SH="$STUB"

reset() { rm -f "$TMP/tasks.json" "$TMP/calls.log" "$TMP/adds.log" "$TMP/list-rc" "$TMP/list-garbage" "$TMP/add-rc" "$TMP/add-writes"; }
seed() { printf '%s\n' "$1" > "$TMP/tasks.json"; }
adds() { cat "$TMP/adds.log" 2>/dev/null || true; }

# ---- count --------------------------------------------------------------------
reset
seed '[{"id":"ht-a","repo":"acme/w","what":"Sign in to Railway","why":"sign-in: x","source":"#1","created_at":"t","state":"open","done_at":null,"proof":null},
       {"id":"ht-b","repo":"acme/w","what":"Fill X","why":"secret-value: y","source":"#2","created_at":"t","state":"open","done_at":null,"proof":null},
       {"id":"ht-c","repo":"acme/w","what":"Old","why":"sign-in: z","source":"#3","created_at":"t","state":"done","done_at":"t","proof":"p"}]'
out="$("$SCRIPT" count)"; rc=$?
check_eq "count: exit 0" 0 "$rc"
check_contains "count: two open, done one not counted" "HUMAN_TASKS=2" "$out"
check_contains "count: report line" "LINE=Human tasks: 2 open for this repo" "$out"
check_contains "count: list called with --json, without --all" "list --json" "$(cat "$TMP/calls.log")"
out="$("$SCRIPT" count --repo acme/w)"
check_contains "count: --repo names the repo and is passed through" "LINE=Human tasks: 2 open for acme/w" "$out"
check_contains "count: --repo forwarded" "list --json --repo acme/w" "$(cat "$TMP/calls.log")"

reset
out="$("$SCRIPT" count)"; rc=$?
check_eq "count: empty list exit 0" 0 "$rc"
check_contains "count: empty list is a real zero" "HUMAN_TASKS=0" "$out"

reset; echo 4 > "$TMP/list-rc"
out="$("$SCRIPT" count)"; rc=$?
check_eq "count: unreadable list exits 4" 4 "$rc"
check_contains "count: unreadable, not zero" "HUMAN_TASKS=unreadable" "$out"
check_absent "count: unreadable never prints 0 open" "0 open" "$out"
check_contains "count: unreadable line says so" "count unknown, not zero" "$out"
check_contains "count: unreadable line names the exit" "owner-task.sh exit 4" "$out"

reset; touch "$TMP/list-garbage"
out="$("$SCRIPT" count)"; rc=$?
check_eq "count: non-array output exits 4" 4 "$rc"
check_contains "count: non-array output is unreadable" "HUMAN_TASKS=unreadable" "$out"

reset
out="$(OWNER_TASK_SH="$TMP/missing.sh" "$SCRIPT" count)"; rc=$?
check_eq "count: missing owner-task.sh exits 7" 7 "$rc"
check_contains "count: missing owner-task.sh is unavailable" "HUMAN_TASKS=unavailable" "$out"
check_absent "count: missing owner-task.sh never prints 0 open" "0 open" "$out"

# ---- save ---------------------------------------------------------------------
reset
out="$("$SCRIPT" save --what "Sign in to Railway on the work profile" --why "sign-in: interactive login" --source "#77")"; rc=$?
check_eq "save: new item exit 0" 0 "$rc"
check_contains "save: saved" "RESULT=saved ID=ht-00000000" "$out"
check_contains "save: receipt line" "LINE=human task ht-00000000 saved: Sign in to Railway on the work profile (sign-in)" "$out"
check_eq "save: add called once with the fields" "Sign in to Railway on the work profile|sign-in: interactive login|#77" "$(adds)"
check_contains "save: duplicate check read open and done" "list --all --json" "$(cat "$TMP/calls.log")"

# Same what and source again: skipped, no second add.
out="$("$SCRIPT" save --what "Sign in to Railway  on the work profile " --why "sign-in: again" --source "#77")"; rc=$?
check_eq "save: duplicate exit 0" 0 "$rc"
check_contains "save: duplicate skipped" "RESULT=skipped ID=ht-00000000" "$out"
check_contains "save: duplicate line" "already on the list" "$out"
check_eq "save: duplicate not added" 1 "$(adds | wc -l | tr -d ' ')"

# Same what, other source: a separate task.
out="$("$SCRIPT" save --what "Sign in to Railway on the work profile" --why "sign-in: x" --source "#78")"
check_contains "save: other source is saved" "RESULT=saved" "$out"

# A done task with the same what and source is still a duplicate.
reset
seed '[{"id":"ht-done","repo":"acme/w","what":"Fill STRIPE_KEY in .env","why":"secret-value: x","source":"#5","created_at":"t","state":"done","done_at":"t","proof":"p"}]'
out="$("$SCRIPT" save --what "Fill STRIPE_KEY in .env" --why "secret-value: x" --source "#5")"
check_contains "save: done duplicate skipped" "RESULT=skipped ID=ht-done" "$out"
check_eq "save: done duplicate not added" "" "$(adds)"

# OWNER_ACTION lines, both forms.
reset
out="$("$SCRIPT" save --owner-action "OWNER_ACTION: secret-value: Fill in STRIPE_PUBLISHABLE in .env — only the operator holds the dashboard login" --source "https://github.com/acme/w/pull/9")"
check_contains "owner-action: saved" "RESULT=saved" "$out"
check_eq "owner-action: split into what and why" "Fill in STRIPE_PUBLISHABLE in .env|secret-value: only the operator holds the dashboard login|https://github.com/acme/w/pull/9" "$(adds)"
check_contains "owner-action: receipt names the reason" "(secret-value)" "$out"
out="$("$SCRIPT" save --owner-action "OWNER_ACTION=physical-device: Run the live test on the phone" --source "#10")"
check_contains "owner-action: extract form without detail saved" "RESULT=saved" "$out"
check_contains "owner-action: missing detail gets a free-text placeholder" "Run the live test on the phone|physical-device: reported by a sub-agent without detail|#10" "$(adds)"
reset
rc=0; out="$("$SCRIPT" save --owner-action "OWNER_ACTION: Sign in to the dashboard" --source "#1" 2>/dev/null)" || rc=$?
check_eq "owner-action: line with no reason exits 2" 2 "$rc"
check_contains "owner-action: no reason ends as not saved" "RESULT=not_saved EXIT=2" "$out"
check_contains "owner-action: not-saved line names the missing reason" "names no why-human reason" "$out"
check_eq "owner-action: no reason writes nothing" "" "$(adds)"
"$SCRIPT" save --what "x" --why "sign-in: y" >/dev/null 2>&1; rc=$?
check_eq "save: --source required" 2 "$rc"

# Not saved: public repo with no bucket.
reset; echo 3 > "$TMP/add-rc"
out="$("$SCRIPT" save --what "Accept the Vercel team invite" --why "legal-agreement: his name" --source "#4")"; rc=$?
check_eq "not saved: owner-task.sh exit carried" 3 "$rc"
check_contains "not saved: result" "RESULT=not_saved EXIT=3" "$out"
check_contains "not saved: line names the item" "LINE=not saved to the human-task list: Accept the Vercel team invite" "$out"
check_contains "not saved: line names why" "no private bucket is set" "$out"

# Not saved: the duplicate check could not read the list; nothing is added.
reset; echo 4 > "$TMP/list-rc"
out="$("$SCRIPT" save --what "Sign in" --why "sign-in: x" --source "#4")"; rc=$?
check_eq "unreadable list: exit 4" 4 "$rc"
check_contains "unreadable list: not saved" "RESULT=not_saved EXIT=4" "$out"
check_eq "unreadable list: add never called" "" "$(adds)"

# Ambiguous add (exit 1) that did land: reported saved, never re-added.
reset; echo 1 > "$TMP/add-rc"; touch "$TMP/add-writes"
out="$("$SCRIPT" save --what "Sign in to Fly" --why "sign-in: x" --source "#6")"; rc=$?
check_eq "ambiguous add that landed: exit 0" 0 "$rc"
check_contains "ambiguous add that landed: saved" "RESULT=saved ID=ht-00000000" "$out"
check_eq "ambiguous add: exactly one add" 1 "$(adds | wc -l | tr -d ' ')"
# Ambiguous add that did not land: not saved.
reset; echo 1 > "$TMP/add-rc"
out="$("$SCRIPT" save --what "Sign in to Fly" --why "sign-in: x" --source "#6")"; rc=$?
check_eq "ambiguous add that failed: exit 1" 1 "$rc"
check_contains "ambiguous add that failed: not saved" "RESULT=not_saved EXIT=1" "$out"

# Ambiguous add and the re-list fails too: unconfirmed, never "not saved".
reset; echo 1 > "$TMP/add-rc"; touch "$TMP/add-writes"
cat > "$TMP/bin/relist-fails.sh" <<WRAP
#!/usr/bin/env bash
if [ "\$1" = list ] && [ -f "$TMP/adds.log" ]; then exit 4; fi
exec "$STUB" "\$@"
WRAP
chmod +x "$TMP/bin/relist-fails.sh"
out="$(OWNER_TASK_SH="$TMP/bin/relist-fails.sh" "$SCRIPT" save --what "Sign in to Fly" --why "sign-in: x" --source "#6")"; rc=$?
check_eq "ambiguous add, re-list unreadable: exit 1" 1 "$rc"
check_contains "ambiguous add, re-list unreadable: unconfirmed" "RESULT=unconfirmed EXIT=1" "$out"
check_absent "ambiguous add, re-list unreadable: never not_saved" "not_saved" "$out"
check_contains "ambiguous add, re-list unreadable: line says check first" "check owner-task.sh list before saving it again" "$out"

# ---- the skill's blocks -------------------------------------------------------
SAVE_BLOCK="$(extract_skill_bash "$MODULE" pm-human-tasks-save)" || { fail "save block extract"; SAVE_BLOCK=""; }
COUNT_BLOCK="$(extract_skill_bash "$MODULE" pm-human-tasks-count)" || { fail "count block extract"; COUNT_BLOCK=""; }

reset
out="$(PM_HUMAN_TASKS_SH="$SCRIPT" PM_HT_ACTION="OWNER_ACTION: sign-in: Sign in to Railway — 2FA on his phone" PM_HT_SOURCE="#12" bash -c "$SAVE_BLOCK")"
check_eq "skill save block: prints the receipt" "human task ht-00000000 saved: Sign in to Railway (sign-in)" "$out"
out="$(PM_HUMAN_TASKS_SH="$SCRIPT" PM_HT_WHAT="Sign in to Railway" PM_HT_WHY="sign-in: 2FA" PM_HT_SOURCE="#12" bash -c "$SAVE_BLOCK")"
check_contains "skill save block: duplicate skipped" "already on the list" "$out"
out="$(PM_HUMAN_TASKS_SH="$SCRIPT" bash -c "$COUNT_BLOCK")"
check_eq "skill count block: prints the count" "Human tasks: 1 open for this repo" "$out"
echo 3 > "$TMP/add-rc"
out="$(PM_HUMAN_TASKS_SH="$SCRIPT" PM_HT_WHAT="Accept terms" PM_HT_WHY="legal-agreement: x" PM_HT_SOURCE="#13" bash -c "$SAVE_BLOCK")"; rc=$?
check_eq "skill save block: a failed save does not stop the run" 0 "$rc"
check_contains "skill save block: failed save printed" "not saved to the human-task list: Accept terms" "$out"
echo 4 > "$TMP/list-rc"
out="$(PM_HUMAN_TASKS_SH="$SCRIPT" bash -c "$COUNT_BLOCK")"
check_contains "skill count block: unreadable is not zero" "count unknown, not zero" "$out"
out="$(PM_HUMAN_TASKS_SH="" bash -c "$COUNT_BLOCK")"
check_eq "skill count block: helper missing" "Human tasks: count unknown (pm-human-tasks.sh not found)" "$out"
out="$(PM_HUMAN_TASKS_SH="" PM_HT_WHAT="x" PM_HT_WHY="sign-in: y" PM_HT_SOURCE="#1" bash -c "$SAVE_BLOCK")"
check_contains "skill save block: helper missing says not saved" "not saved to the human-task list" "$out"

# ---- wiring -------------------------------------------------------------------
chosen="$("$SKILL/scripts/dispatch-module.sh" shared human-tasks)"
check_eq "dispatcher: shared:human-tasks resolves" "$MODULE" "$chosen"
check_contains "SKILL: resolves the helper in Step 0" 'PM_HUMAN_TASKS_SH=$(resolve_script pm-human-tasks.sh || true)' "$(cat "$SKILL/SKILL.md")"
check_contains "SKILL: routing row" '| `shared:human-tasks` |' "$(cat "$SKILL/SKILL.md")"
for f in rank/present.md resume/present.md flow/progress.md day-tick.md; do
  if grep -qiF 'read `shared:human-tasks`' "$SKILL/modules/$f"; then
    pass "module $f routes to shared:human-tasks"
  else
    fail "module $f routes to shared:human-tasks"
  fi
done
module_text="$(cat "$MODULE")"
check_contains "module: saves without asking in day and unattended runs" "a \`/pm day\` tick and an unattended run (presence away) all save the same way" "$module_text"
check_contains "module: never zero for an unreadable list" "never report an unreadable or missing list as zero" "$module_text"
check_contains "module: reading is handed to the script" "lean-orchestrator.md" "$module_text"

echo
echo "pm-human-tasks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
