#!/usr/bin/env bash
# catalog: tests — Tests for run-mode.sh: set/get round trips, fail-open reads, repo isolation, _unknown refusal
# covers: .claude/scripts/run-mode.sh .claude/scripts/session-state.sh
#
# Runs against a temporary HOME with the real session-state.sh. Never touches the user's state.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$(cd "$here/.." && pwd)"
RUN_MODE="$scripts/run-mode.sh"

tmp_home="$(mktemp -d)"
trap 'rm -rf "$tmp_home"' EXIT
export HOME="$tmp_home"
unset CLAUDE_SESSION_REPO
state_file="$tmp_home/.claude/session-state.json"

pass=0
fail=0
# t NAME CMD... : pass when CMD exits 0.
t() {
  local name="$1"; shift
  if "$@"; then
    pass=$((pass + 1)); printf 'ok - %s\n' "$name"
  else
    fail=$((fail + 1)); printf 'not ok - %s\n' "$name"
  fi
}
eq() { [[ "$1" == "$2" ]]; }
no_state_file() { [[ ! -e "$state_file" ]]; }
rc_is() { # rc_is EXPECTED CMD...
  local want="$1"; shift
  "$@" >/dev/null 2>&1; [[ $? -eq "$want" ]]
}
stored_mode() { jq -r --arg k "$1" '.repos[$k].run_mode // "absent"' "$state_file"; }

repo_a="owner-a/repo-a"
repo_b="owner-b/repo-b"

# 1. Each mode can be set and read back under one repo.
for m in default speed cheap; do
  "$RUN_MODE" set "$m" --repo "$repo_a" >/dev/null 2>&1
  t "set $m then get reads $m" eq "$("$RUN_MODE" get --repo "$repo_a" 2>/dev/null)" "$m"
done

# 2. Machine lines: changed on a real change, unchanged on a same-value set.
"$RUN_MODE" set speed --repo "$repo_a" >/dev/null 2>&1
out=$("$RUN_MODE" set speed --repo "$repo_a" 2>/dev/null)
t "same-value set prints 'unchanged speed'" eq "$out" "unchanged speed"
out=$("$RUN_MODE" set cheap --repo "$repo_a" 2>/dev/null)
t "change prints 'changed speed cheap'" eq "$out" "changed speed cheap"

# 3. Invalid value exits 2 and leaves stored state byte-identical (mode stored).
before=$(cat "$state_file")
t "invalid set exits 2 when a mode is stored" rc_is 2 "$RUN_MODE" set turbo --repo "$repo_a"
after=$(cat "$state_file")
t "invalid set leaves state byte-identical when a mode is stored" eq "$before" "$after"
t "stored mode unchanged after invalid set" eq "$("$RUN_MODE" get --repo "$repo_a")" cheap

# 4. Invalid value with no stored mode writes nothing.
rm -f "$state_file"
t "invalid set exits 2 when no mode is stored" rc_is 2 "$RUN_MODE" set bogus --repo "$repo_b"
t "invalid set with no stored mode writes no state file" no_state_file

# 5. Fail-open reads: each returns default with exit 0.
rm -f "$state_file"
t "no state file reads default exit 0" rc_is 0 "$RUN_MODE" get --repo "$repo_a"
t "no state file prints default" eq "$("$RUN_MODE" get --repo "$repo_a" 2>/dev/null)" default

mkdir -p "$(dirname "$state_file")"
printf '%s' '{"schema_version":2,"repos":{"owner-a/repo-a":{"run_mode":"turbo"}}}' >"$state_file"
t "stored non-enum string prints default" eq "$("$RUN_MODE" get --repo "$repo_a" 2>/dev/null)" default
printf '%s' '{"schema_version":2,"repos":{"owner-a/repo-a":{"run_mode":"speed\n"}}}' >"$state_file"
t "stored speed with trailing newline prints default" eq "$("$RUN_MODE" get --repo "$repo_a" 2>/dev/null)" default

printf '%s' '{"schema_version":2,"repos":{"owner-a/repo-a":{"run_mode":42}}}' >"$state_file"
t "stored number prints default" eq "$("$RUN_MODE" get --repo "$repo_a" 2>/dev/null)" default

printf '%s' '{"schema_version":2,"repos":{"owner-a/repo-a":{"run_mode":{"x":1}}}}' >"$state_file"
t "stored object prints default" eq "$("$RUN_MODE" get --repo "$repo_a" 2>/dev/null)" default
t "stored object reads exit 0" rc_is 0 "$RUN_MODE" get --repo "$repo_a"
# An unconfirmed stored value must not be mistaken for a confirmed default: set default writes.
t "set default over an unconfirmed stored object writes and reports unknown old value" eq \
  "$("$RUN_MODE" set default --repo "$repo_a" 2>/dev/null)" "changed unknown default"
t "that write replaced the stored object with a valid mode" eq "$(stored_mode "$repo_a")" default

printf '%s' '{ malformed' >"$state_file"
t "malformed state prints default" eq "$("$RUN_MODE" get --repo "$repo_a" 2>/dev/null)" default
t "malformed state reads exit 0" rc_is 0 "$RUN_MODE" get --repo "$repo_a"

t "missing state helper prints default" eq \
  "$("$RUN_MODE" get --state-helper "$tmp_home/missing-helper.sh" --repo "$repo_a" 2>/dev/null)" default
t "missing state helper reads exit 0" rc_is 0 "$RUN_MODE" get --state-helper "$tmp_home/missing-helper.sh" --repo "$repo_a"

# 6. Repo isolation: a write to repo A leaves repo B unchanged; mode sits under the repo key.
rm -f "$state_file"
"$RUN_MODE" set speed --repo "$repo_a" >/dev/null 2>&1
"$RUN_MODE" set cheap --repo "$repo_b" >/dev/null 2>&1
"$RUN_MODE" set default --repo "$repo_a" >/dev/null 2>&1
t "repo B keeps cheap after repo A changes" eq "$("$RUN_MODE" get --repo "$repo_b")" cheap
t "mode sits under .repos[repo_a].run_mode" eq "$(stored_mode "$repo_a")" default

# 7. _unknown and unresolved repos: set refuses with exit 5 and writes nothing; get reads default.
rm -f "$state_file"
t "set refuses _unknown with exit 5" rc_is 5 "$RUN_MODE" set cheap --repo _unknown
t "set on _unknown writes no state file" no_state_file
t "get for _unknown prints default" eq "$("$RUN_MODE" get --repo _unknown 2>/dev/null)" default
t "set outside any repo exits 5" bash -c "cd \"$tmp_home\" && \"$RUN_MODE\" set speed >/dev/null 2>&1; [[ \$? -eq 5 ]]"

# 8. names prints the three valid names.
t "names prints default, speed, cheap in order" eq "$("$RUN_MODE" names | paste -sd' ' -)" "default speed cheap"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
