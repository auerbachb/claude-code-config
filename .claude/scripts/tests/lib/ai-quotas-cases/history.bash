#!/usr/bin/env bash
# Source-only quota fixture group: history. Run ai-quotas.test.sh.
# shellcheck source=../ai-quotas-fixtures.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-quotas-fixtures.bash"

# --- 17. snapshot history, nicknames, and the compact table (#1700) ----------
#
# The history file is what the burn-rate projection in #1701 reads, so what is
# asserted here is its SHAPE and its honesty: one line per row that actually
# produced a figure, nothing at all for a row that did not, the source of the
# run, and a mode that keeps it to this user. The compact table is asserted by
# MEASURING it — a five-account render whose widest line has to fit inside 100
# columns — rather than by eyeballing a fixture.

HISTORY="$CASE_HOME/.claude/ai-quotas-history.jsonl"





# The table only, from its header to the blank line that follows it. The
# advisory prose under it is deliberately excluded: the display-only sentence
# is a fixed hundred-plus-column sentence, and measuring it would turn the
# width assertion into a statement about that sentence rather than the table.




# --- 17a. one line per successfully read row per run -------------------------

overage_case 40 50
run
check_eq "$RC" "0" "a run that records history still exits 0"
check_eq "$(history_count)" "2" "one snapshot line per row is appended"
run
check_eq "$(history_count)" "4" "a second run APPENDS its own set rather than replacing the first"
check_eq "$(history_lines | jq -s 'length' 2>/dev/null || echo PARSE-ERROR)" "4" \
  "every line parses as JSON — the file really is JSONL"
check_eq "$(ls -l "$HISTORY" | cut -c1-10)" "-rw-------" "the history file is mode 600"

# The exact field set #1701 will read, asserted as a sorted key list rather
# than field by field, so a key silently added or dropped fails here instead
# of in the consumer six weeks later.
check_eq "$(history_lines | tail -n 1 | jq -r '[keys_unsorted[]] | sort | join(",")')" \
  "label,nickname,provider,resets_at_epoch,source,ts,used_pct,window,window_start_epoch" \
  "a snapshot carries exactly the documented fields"
# The window this reading belongs to, recorded rather than re-derived later
# (#1701). A weekly Codex window is its reset minus its own reported duration,
# which is the figure the projection places every other reading against.
check_eq "$(history_lines | jq -r 'select(.provider == "codex") | .window_start_epoch' | tail -n 1)" \
  "$(( WEEK_RESET - 604800 ))" \
  "and the start of the window it was reported for"
check_eq "$(history_lines | tail -n 1 | jq -r '.ts')" "2026-09-08T20:00:00Z" \
  "the snapshot timestamp is the run clock, not a second-order guess at it"
check_eq "$(history_lines | jq -r 'select(.provider == "codex") | .used_pct' | tail -n 1)" "50" \
  "the recorded percentage is the one the row reported"
check_eq "$(history_lines | jq -r 'select(.provider == "codex") | .window' | tail -n 1)" "7-day" \
  "and the window it was reported for"
check_eq "$(history_lines | jq -r '.source' | sort -u | tr '\n' ' ' | sed 's/ $//')" "manual" \
  "a hand-run /quotas records its snapshots as manual"

# --- 17b. a row that could not be read appends NOTHING -----------------------
#
# Discriminating on purpose: the config holds one account that reads and one
# that cannot, so "no line for the failed row" cannot pass by the file simply
# being empty.

reset_state
C_OK="$(seed_claude_profile claude-one@example.com "Claude Code-credentials-AAA")"
X_BAD="$(seed_codex_profile codex-nologin@example.com "")"
write_config \
  "$(account_json claude claude-one@example.com "$C_OK" "Claude Code-credentials-AAA")" \
  "$(account_json codex codex-nologin@example.com "$X_BAD")"
run
check_eq "$RC" "0" "a failed row does not fail the run"
check_contains "$OUT" "needs-login" "control(+): the failing account really did fail"
check_eq "$(history_count)" "1" "a row with no figure appends no snapshot line"
check_eq "$(history_lines | jq -r '.provider')" "claude" \
  "control(+): the row that did read appended exactly one"

# --- 17b-ii. a history path that is a symlink is refused ---------------------
#
# `-f` and `-e` both FOLLOW a link, so without an explicit check the chmod
# would retarget an unrelated file's mode and the append would write quota
# JSON into it — and a DANGLING link would be followed into existence.

overage_case 40 50
SYMLINK_TARGET="$TMP/not-the-history.txt"
printf 'pre-existing content\n' > "$SYMLINK_TARGET"
chmod 644 "$SYMLINK_TARGET"
mkdir -p "$(dirname "$HISTORY")"
rm -f "$HISTORY"
ln -s "$SYMLINK_TARGET" "$HISTORY"
run
check_eq "$RC" "0" "a symlinked history path does not fail the run"
check_contains "$ERR" "symbolic link" "it says why nothing was recorded, on stderr like every other warn"
check_eq "$(cat "$SYMLINK_TARGET")" "pre-existing content" \
  "the link target is not written to"
check_eq "$(ls -l "$SYMLINK_TARGET" | cut -c1-10)" "-rw-r--r--" \
  "and its mode is left alone — the chmod never reached it"

# The dangling half of the same rule: `-e` is false for a link to nothing, so
# the create branch would bring the target into existence.
overage_case 40 50
DANGLING_TARGET="$TMP/never-created.jsonl"
rm -f "$DANGLING_TARGET"
mkdir -p "$(dirname "$HISTORY")"
rm -f "$HISTORY"
ln -s "$DANGLING_TARGET" "$HISTORY"
run
check_eq "$RC" "0" "a dangling symlink does not fail the run either"
check_eq "$(test -e "$DANGLING_TARGET" && echo created || echo absent)" "absent" \
  "and its target is not created"

# --- 17c. --quiet is the unattended run --------------------------------------

overage_case 40 50
run --quiet
check_eq "$RC" "0" "--quiet exits 0"
check_eq "$(history_lines | jq -r '.source' | sort -u | tr '\n' ' ' | sed 's/ $//')" "scheduled" \
  "--quiet records its snapshots as scheduled"
check_contains "$OUT" "OVERAGE" "control(+): --quiet still prints the report itself"
check_not_contains "$OUT" "Display only" "--quiet drops the trailing advisory prose"
check_not_contains "$OUT" "LAST SNAPSHOT" \
  "and the snapshot footer, which under --quiet would only tell the job log about itself"

